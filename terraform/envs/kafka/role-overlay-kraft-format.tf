/*
 * role-overlay-kraft-format.tf -- format each broker's KRaft storage with a
 * per-cluster cluster-UUID, then start + verify the two KRaft clusters.
 *
 * Two sequential null_resources, each independently `-target`-able:
 *
 *   1. kafka_kraft_format -- per cluster: recover the existing cluster-UUID
 *      from a node's meta.properties (idempotent re-run) or generate a fresh
 *      one on first apply; `kafka-storage format --cluster-id <uuid>
 *      --ignore-formatted` on every enabled node.
 *   2. kafka_broker_start_verify -- enable + start kafka.service on every
 *      enabled node; wait for the KRaft metadata quorum to elect a leader;
 *      assert a replication-factor-3 produce/consume round-trip per cluster
 *      (the 0.H.1 exit gate).
 *
 * The cluster UUID never persists to Terraform state -- it lives in each
 * node's meta.properties (written by kafka-storage format) and is recovered
 * from there on re-run. Generating a NEW uuid on a re-run would conflict with
 * the already-formatted dirs; --ignore-formatted + uuid-recovery makes the
 * whole overlay idempotent.
 */

locals {
  # Per-cluster bring-up table: name + enabled gate + the enabled nodes.
  kafka_clusters = [
    {
      name    = "east"
      enabled = var.enable_kafka_east
      nodes = [
        for n in local.kafka_east_all : { node_id = n.node_id, vmnet10 = n.vmnet10, vmnet11 = n.vmnet11 }
        if n.enabled
      ]
    },
    {
      name    = "west"
      enabled = var.enable_kafka_west
      nodes = [
        for n in local.kafka_west_all : { node_id = n.node_id, vmnet10 = n.vmnet10, vmnet11 = n.vmnet11 }
        if n.enabled
      ]
    },
  ]
}

# ─── 1. Format KRaft storage (per-cluster UUID) ───────────────────────────
resource "null_resource" "kafka_kraft_format" {
  count = var.enable_kafka_cluster && var.enable_kraft_format ? 1 : 0

  triggers = {
    # Keyed only on the cluster table + this overlay's version. Deliberately
    # NOT on null_resource.kafka_broker_config's id -- that id-trigger
    # cascaded re-runs from the nftables/broker-config chain. `kafka-storage
    # format --ignore-formatted` is a mode-agnostic no-op on an
    # already-formatted dir, so re-running is harmless, but the cascade is
    # still wrong. Ordering is handled by depends_on.
    clusters  = jsonencode(local.kafka_clusters)
    overlay_v = "2" # v2 (0.H.4) = dropped the `config_id` id-trigger (the nftables->broker-config->kraft-format->broker-start cascade). v1 = original.
  }

  depends_on = [null_resource.kafka_broker_config]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $user    = '${var.kafka_node_user}'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $kafka   = '/opt/kafka/bin'
      $props   = '/etc/nexus-kafka/server.properties'

      $clusters = @'
${jsonencode(local.kafka_clusters)}
'@ | ConvertFrom-Json

      foreach ($c in $clusters) {
        if (-not $c.enabled -or $c.nodes.Count -eq 0) {
          Write-Host "[kraft-format] cluster '$($c.name)' disabled or empty -- skipping"
          continue
        }
        $firstIp = $c.nodes[0].vmnet11

        # Recover an existing cluster-UUID from meta.properties, else mint one.
        $metaPath = '/var/lib/kafka/data/meta.properties'
        $existing = (ssh @sshOpts "$user@$firstIp" "sudo grep -h '^cluster.id=' $metaPath 2>/dev/null | head -1 | cut -d= -f2" 2>&1 | Out-String).Trim()
        if ($existing -match '^[A-Za-z0-9_-]{16,}$') {
          $clusterId = $existing
          Write-Host "[kraft-format] cluster '$($c.name)': recovered existing cluster-id $clusterId"
        } else {
          $clusterId = (ssh @sshOpts "$user@$firstIp" "$kafka/kafka-storage.sh random-uuid" 2>&1 | Out-String).Trim()
          if ($clusterId -notmatch '^[A-Za-z0-9_-]{16,}$') {
            throw "[kraft-format] cluster '$($c.name)': failed to obtain a cluster-id (got '$clusterId')"
          }
          Write-Host "[kraft-format] cluster '$($c.name)': minted cluster-id $clusterId"
        }

        foreach ($n in $c.nodes) {
          $ip = $n.vmnet11
          Write-Host "[kraft-format] $${ip}: kafka-storage format (node $($n.node_id), cluster $($c.name))"
          # --ignore-formatted makes the format a no-op on an already-formatted
          # dir, so re-applies are clean. Run as the kafka user (owns the data dir).
          $fmt = "sudo -u kafka $kafka/kafka-storage.sh format --cluster-id $clusterId --config $props --ignore-formatted && echo FORMAT_OK"
          $out = (ssh @sshOpts "$user@$ip" $fmt 2>&1 | Out-String)
          if ($out -notmatch 'FORMAT_OK') {
            throw "[kraft-format] $${ip}: kafka-storage format failed -- $out"
          }
          Write-Host "[kraft-format] $${ip}: storage formatted"
        }
      }

      Write-Host "[kraft-format] all enabled clusters formatted"
    PWSH
  }
}

# ─── 2. Start brokers + verify KRaft quorum + RF=3 round-trip ─────────────
resource "null_resource" "kafka_broker_start_verify" {
  count = var.enable_kafka_cluster && var.enable_kraft_format ? 1 : 0

  triggers = {
    # Keyed only on the cluster table + this overlay's version. Deliberately
    # NOT on null_resource.kafka_kraft_format's id -- that id-trigger was the
    # tail of the nftables->broker-config->kraft-format->broker-start cascade
    # that re-ran this overlay's PLAINTEXT quorum probe against the (post-
    # 0.H.2) mTLS brokers (a PLAINTEXT client hitting an SSL listener OOMs
    # reading the TLS bytes as a message length). Ordering is via depends_on;
    # the probe below is now mode-aware.
    clusters  = jsonencode(local.kafka_clusters)
    overlay_v = "2" # v2 (0.H.4) = dropped the `format_id` id-trigger + the quorum/RF=3 probes are now mTLS-aware (detect /etc/nexus-kafka/client-ssl.properties -> probe with --command-config). v1 = original PLAINTEXT-only probe.
  }

  depends_on = [null_resource.kafka_kraft_format]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $user    = '${var.kafka_node_user}'
      $timeout = ${var.kafka_cluster_timeout_minutes}
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $kafka   = '/opt/kafka/bin'

      $clusters = @'
${jsonencode(local.kafka_clusters)}
'@ | ConvertFrom-Json

      foreach ($c in $clusters) {
        if (-not $c.enabled -or $c.nodes.Count -eq 0) {
          Write-Host "[broker-start] cluster '$($c.name)' disabled or empty -- skipping"
          continue
        }

        # KRaft controllers race each other at boot -- enable + start every
        # node, THEN wait for quorum (big-bang, like the Nomad-TLS
        # parallel-restart lesson). systemctl start --no-block so a slow peer
        # doesn't serialize the loop.
        foreach ($n in $c.nodes) {
          $ip = $n.vmnet11
          Write-Host "[broker-start] $${ip}: enable + start kafka.service ($($c.name) node $($n.node_id))"
          $start = "sudo systemctl enable kafka.service && sudo systemctl start --no-block kafka.service && echo START_OK"
          $out = (ssh @sshOpts "$user@$ip" $start 2>&1 | Out-String)
          if ($out -notmatch 'START_OK') {
            throw "[broker-start] $${ip}: kafka.service enable/start failed -- $out"
          }
        }

        # Wait for the metadata quorum to elect a leader (probe from node 1).
        $probeIp = $c.nodes[0].vmnet11

        # Detect the broker's wire mode. /etc/nexus-kafka/client-ssl.properties
        # is written ONLY once role-overlay-kafka-tls.tf has flipped the broker
        # to mTLS, so it is the reliable "is this broker SSL" marker -- robust
        # to a stale PLAINTEXT server.properties left on disk by a re-run of
        # role-overlay-broker-config.tf. A PLAINTEXT kafka client hitting an
        # SSL listener OOMs (it reads the TLS handshake bytes as a Kafka
        # message-length and tries to allocate that many GB of heap). When the
        # broker is mTLS the CLI also needs sudo to read the 0640 root:kafka
        # keystore.
        $clientCfg = '/etc/nexus-kafka/client-ssl.properties'
        $tlsOn = ((ssh @sshOpts "$user@$probeIp" "sudo test -f $clientCfg && echo TLS_ON" 2>&1 | Out-String).Trim() -match 'TLS_ON')
        $cmdCfg  = if ($tlsOn) { "--command-config $clientCfg" } else { "" }
        $prodCfg = if ($tlsOn) { "--producer.config $clientCfg" } else { "" }
        $consCfg = if ($tlsOn) { "--consumer.config $clientCfg" } else { "" }
        $sudoPfx = if ($tlsOn) { "sudo " } else { "" }
        Write-Host "[broker-start] cluster '$($c.name)': broker wire mode = $(if ($tlsOn) {'mTLS'} else {'PLAINTEXT'})"

        Write-Host "[broker-start] cluster '$($c.name)': waiting for KRaft metadata quorum..."
        $deadline = (Get-Date).AddMinutes($timeout)
        $quorumOk = $false
        while ((Get-Date) -lt $deadline) {
          $status = (ssh @sshOpts "$user@$probeIp" "$sudoPfx$kafka/kafka-metadata-quorum.sh --bootstrap-server localhost:9092 $cmdCfg describe --status 2>/dev/null" 2>&1 | Out-String)
          # Healthy: a LeaderId line with a non-negative id + 3 voters.
          if ($status -match 'LeaderId:\s*\d+' -and $status -match 'CurrentVoters:.*\d+.*\d+.*\d+') {
            $quorumOk = $true
            break
          }
          Start-Sleep -Seconds 10
        }
        if (-not $quorumOk) {
          $diag = (ssh @sshOpts "$user@$probeIp" "$sudoPfx$kafka/kafka-metadata-quorum.sh --bootstrap-server localhost:9092 $cmdCfg describe --status 2>&1; sudo journalctl -u kafka -n 20 --no-pager" 2>&1 | Out-String)
          throw "[broker-start] cluster '$($c.name)': KRaft quorum never converged after $timeout min`n$diag"
        }
        Write-Host "[broker-start] cluster '$($c.name)': KRaft quorum has a leader + 3 voters"

        # RF=3 produce/consume round-trip (the 0.H.1 exit gate).
        $token = "kraft-rt-$(Get-Random)-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
        $topic = "nexus-smoke-$($c.name)"
        $rt = @"
set -e
$sudoPfx$kafka/kafka-topics.sh --bootstrap-server localhost:9092 $cmdCfg --create --if-not-exists --topic $topic --partitions 3 --replication-factor 3
echo '$token' | $sudoPfx$kafka/kafka-console-producer.sh --bootstrap-server localhost:9092 $prodCfg --topic $topic
$sudoPfx$kafka/kafka-console-consumer.sh --bootstrap-server localhost:9092 $consCfg --topic $topic --from-beginning --timeout-ms 15000 2>/dev/null
"@
        $rtOut = (ssh @sshOpts "$user@$probeIp" $rt 2>&1 | Out-String)
        if ($rtOut -notmatch [regex]::Escape($token)) {
          throw "[broker-start] cluster '$($c.name)': RF=3 round-trip failed -- token '$token' not seen`n$rtOut"
        }
        Write-Host "[broker-start] cluster '$($c.name)': RF=3 round-trip OK (token round-tripped)"
      }

      Write-Host "[broker-start] OK -- all enabled KRaft clusters live (0.H.1 exit gate met)"
    PWSH
  }
}

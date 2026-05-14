/*
 * role-overlay-mm2.tf -- Phase 0.H.5
 *
 * Brings up the MirrorMaker 2 cross-cluster DR pair (mm2-1/mm2-2) and runs
 * the Phase 0.H exit gate (produce a record to kafka-east -> it appears
 * mirrored on kafka-west, and the reverse).
 *
 * Topology -- one FLOW per node, deterministic (research-confirmed):
 *   mm2-1  east->west   (produces INTO west;  --clusters west)
 *   mm2-2  west->east   (produces INTO east;  --clusters east)
 * The two nodes do NOT cluster with each other -- each runs `connect-mirror-
 * maker.sh` in dedicated mode against the one flow its mm2.properties enables.
 *
 * Pre-req: role-overlay-ecosystem-tls.tf rendered /etc/nexus-kafka/tls/
 * {keystore,truststore}.pem + /etc/nexus-kafka/client-ssl.properties on both
 * mm2 nodes (mm2-1/mm2-2 are in kafka_ecosystem_tls_specs).
 *
 * Steps (single count-gated resource, loops the pair in PowerShell):
 *   1. Per node: render /etc/nexus-kafka/mm2.properties (the COMMON base --
 *      both clusters registered, per-cluster mTLS -- with only THIS node's
 *      one flow enabled=true) + a systemd drop-in
 *      /etc/systemd/system/mm2.service.d/10-clusters.conf that appends
 *      `--clusters <target>` to the baked unit's ExecStart (the baked
 *      mm2.service.j2 ExecStart carries no flags). Belt + suspenders: the
 *      enabled= line alone already pins the direction; --clusters additionally
 *      pins where the Connect-internal mm2-{offsets,configs,status}.*.internal
 *      topics land.
 *   2. Sequential start: mm2-1 first, then mm2-2 (disjoint topic sets, but
 *      sequential keeps journal diagnosis clean during a cold bring-up).
 *   3. Per node: journal sanity (no SSLHandshakeException / Failed
 *      authentication; the MM2 connectors are mentioned), the `heartbeats`
 *      topic appears on the TARGET cluster (strongest single liveness signal
 *      -- proves the HeartbeatConnector is producing), then the exit-gate
 *      produce->mirror->consume round-trip for that node's flow.
 *
 * TLS notes (research-confirmed for Apache Kafka 3.8):
 *   - MM2 dedicated mode: cluster-level `<alias>.ssl.*` / `<alias>.security.
 *     protocol` AUTO-CASCADE to the producer/consumer/admin clients
 *     (MirrorMakerConfig.clusterProps() does putIfAbsent("producer."+k,...)).
 *     Write the SSL block ONCE per alias -- the opposite of standalone
 *     Connect, which needs producer./consumer./admin. duplicated.
 *   - All MM2 clients are Kafka clients -> ssl.keystore.type=PEM works; the
 *     PEM pair is used throughout. The .p12 files are NOT used: the embedded
 *     Connect REST server is OFF by default (dedicated.mode.enable.internal.
 *     rest=false) and is only needed for multi-node MM2 coordination, which
 *     this one-node-per-flow topology does not have -- so the Apache-Kafka-
 *     RestServer-rejects-PEM problem never arises here.
 *   - DefaultReplicationPolicy: a topic `T` on `east` is mirrored to `west`
 *     as `east.T` (source-alias prefix). The prefix is what makes the
 *     bidirectional pair loop-safe.
 *
 * Selective ops: var.enable_mm2 AND var.enable_mm2_config
 *                AND var.enable_ecosystem_tls.
 */

locals {
  # kafka-west bootstrap, BARE host:port form -- the east form lives in
  # role-overlay-connect.tf (local.kafka_east_bootstrap_bare). MM2's
  # `<alias>.bootstrap.servers` takes the bare form + a sibling
  # `<alias>.security.protocol=SSL` (not the SSL:// scheme prefix).
  kafka_west_bootstrap_bare = join(",", [for n in local.kafka_west_all : "${n.vmnet10}:9092"])

  # One spec per MM2 node. `src`/`dst` = the replication flow this node owns;
  # `clusters_arg` = the cluster it produces INTO (the --clusters value);
  # `e2w`/`w2e` = the two `<src>-><dst>.enabled` lines (exactly one true).
  kafka_mm2_specs = concat(
    var.enable_mm2 && var.enable_mm2_1 ? [{
      host         = "mm2-1"
      vmnet10      = "192.168.10.85"
      vmnet11      = "192.168.70.85"
      src          = "east"
      dst          = "west"
      clusters_arg = "west"
      e2w          = "true"
      w2e          = "false"
    }] : [],
    var.enable_mm2 && var.enable_mm2_2 ? [{
      host         = "mm2-2"
      vmnet10      = "192.168.10.86"
      vmnet11      = "192.168.70.86"
      src          = "west"
      dst          = "east"
      clusters_arg = "east"
      e2w          = "false"
      w2e          = "true"
    }] : [],
  )
}

resource "null_resource" "kafka_mm2" {
  count = var.enable_kafka_cluster && var.enable_mm2 && var.enable_mm2_config && var.enable_ecosystem_tls && length(local.kafka_mm2_specs) > 0 ? 1 : 0

  triggers = {
    # Keyed only on this overlay's OWN inputs (node set + the two bootstrap
    # strings + overlay version). Ordering after the keystore render is via
    # depends_on -- NOT a kafka_ecosystem_tls id trigger, which would re-run
    # this overlay every time the ecosystem-node set changes (the
    # role-overlay-kafka-tls.tf va_ids lesson, sealed in every 0.H overlay).
    nodes          = jsonencode(local.kafka_mm2_specs)
    east_bootstrap = local.kafka_east_bootstrap_bare
    west_bootstrap = local.kafka_west_bootstrap_bare
    mm2_config_v   = "1" # v1 = MM2 dedicated mode, one flow per node (mm2-1 east->west, mm2-2 west->east); per-cluster mTLS via <alias>.ssl.* PEM (auto-cascades to producer/consumer/admin in dedicated mode); systemd drop-in appends --clusters; embedded Connect REST left OFF (default; no multi-node coordination); lab-snappy refresh intervals (10s); exit-gate produce->mirror->consume round-trip both directions.

    destroy_mm2_ips  = join(",", [for n in local.kafka_mm2_specs : n.vmnet11])
    destroy_ssh_user = var.kafka_node_user
  }

  depends_on = [null_resource.kafka_ecosystem_tls]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser       = '${var.kafka_node_user}'
      $eastBootstrap = '${local.kafka_east_bootstrap_bare}'
      $westBootstrap = '${local.kafka_west_bootstrap_bare}'
      $clientCfg     = '/etc/nexus-kafka/client-ssl.properties'
      $sshOpts       = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $nodes = @'
${jsonencode(local.kafka_mm2_specs)}
'@ | ConvertFrom-Json

      if ($nodes.Count -eq 0) {
        Write-Host "[mm2] no enabled MirrorMaker 2 nodes -- nothing to do"
        exit 0
      }

      # ─── Step 1: per-node render mm2.properties + the --clusters drop-in ──
      foreach ($n in $nodes) {
        $hostName    = $n.host
        $ip          = $n.vmnet11
        $e2w         = $n.e2w
        $w2e         = $n.w2e
        $clustersArg = $n.clusters_arg

        # The COMMON base -- identical between the two nodes except the two
        # `enabled` lines. Per-cluster `<alias>.ssl.*` cascades to the
        # producer/consumer/admin clients in dedicated mode (write once).
        $props = @"
# Generated by role-overlay-mm2.tf -- Phase 0.H.5. Do not edit by hand.
# Node: $hostName   flow: $($n.src)->$($n.dst)   --clusters $clustersArg

# --- cluster registry ---
clusters = east, west
east.bootstrap.servers = $eastBootstrap
west.bootstrap.servers = $westBootstrap

# --- replication flows (this node enables exactly ONE direction) ---
east->west.enabled = $e2w
east->west.topics = .*
west->east.enabled = $w2e
west->east.topics = .*

# --- mirrored data-topic RF on the target (3-node clusters) ---
replication.factor = 3
tasks.max = 4

# --- MM2 internal-topic RF ---
checkpoints.topic.replication.factor = 3
heartbeats.topic.replication.factor = 3
offset-syncs.topic.replication.factor = 3

# --- Connect-internal storage-topic RF, scoped per target cluster ---
east.offset.storage.replication.factor = 3
east.config.storage.replication.factor = 3
east.status.storage.replication.factor = 3
west.offset.storage.replication.factor = 3
west.config.storage.replication.factor = 3
west.status.storage.replication.factor = 3

# --- lab-snappy refresh (production DR would raise these toward defaults) ---
refresh.topics.interval.seconds = 10
sync.topic.configs.interval.seconds = 10
refresh.groups.interval.seconds = 10
emit.heartbeats.interval.seconds = 5
emit.checkpoints.interval.seconds = 5

emit.heartbeats.enabled = true
emit.checkpoints.enabled = true

# --- replication policy (DefaultReplicationPolicy = source-alias prefix;
#     the prefix keeps the bidirectional pair loop-safe) ---
replication.policy.class = org.apache.kafka.connect.mirror.DefaultReplicationPolicy
replication.policy.separator = .

# --- east cluster mTLS (cascades to producer/consumer/admin in dedicated mode) ---
east.security.protocol = SSL
east.ssl.keystore.type = PEM
east.ssl.keystore.location = /etc/nexus-kafka/tls/keystore.pem
east.ssl.truststore.type = PEM
east.ssl.truststore.location = /etc/nexus-kafka/tls/truststore.pem
east.ssl.endpoint.identification.algorithm = https

# --- west cluster mTLS (cascades to producer/consumer/admin in dedicated mode) ---
west.security.protocol = SSL
west.ssl.keystore.type = PEM
west.ssl.keystore.location = /etc/nexus-kafka/tls/keystore.pem
west.ssl.truststore.type = PEM
west.ssl.truststore.location = /etc/nexus-kafka/tls/truststore.pem
west.ssl.endpoint.identification.algorithm = https
"@

        # systemd drop-in -- the baked mm2.service.j2 ExecStart has no flags;
        # reset it (ExecStart=) then re-specify with `--clusters <target>`.
        $dropin = @"
# Generated by role-overlay-mm2.tf -- Phase 0.H.5. Appends --clusters to the
# baked mm2.service ExecStart so this node's Connect-internal topics land in
# the cluster it produces into ($clustersArg).
[Service]
ExecStart=
ExecStart=/opt/kafka/bin/connect-mirror-maker.sh /etc/nexus-kafka/mm2.properties --clusters $clustersArg
"@

        $propsB64  = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($props  -replace "`r`n","`n")))
        $dropinB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($dropin -replace "`r`n","`n")))

        $stage = @"
set -euo pipefail
echo '$propsB64' | base64 -d | sudo tee /etc/nexus-kafka/mm2.properties > /dev/null
sudo chown root:kafka /etc/nexus-kafka/mm2.properties
sudo chmod 0640 /etc/nexus-kafka/mm2.properties

sudo mkdir -p /etc/systemd/system/mm2.service.d
echo '$dropinB64' | base64 -d | sudo tee /etc/systemd/system/mm2.service.d/10-clusters.conf > /dev/null
sudo chown root:root /etc/systemd/system/mm2.service.d/10-clusters.conf
sudo chmod 0644 /etc/systemd/system/mm2.service.d/10-clusters.conf

sudo systemctl daemon-reload
echo MM2_STAGE_OK
"@
        Write-Host "[mm2 $hostName] rendering mm2.properties ($($n.src)->$($n.dst)) + --clusters $clustersArg drop-in"
        $stageOut = ($stage -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $stageOut -notmatch 'MM2_STAGE_OK') {
          Write-Host $stageOut.Trim()
          throw "[mm2 $hostName] config render failed (rc=$LASTEXITCODE)"
        }
      }

      # ─── Step 2: sequential start (disjoint topic sets, but sequential ───
      #     keeps the journal readable during a cold bring-up) ─────────────
      foreach ($n in $nodes) {
        $hostName = $n.host
        $ip       = $n.vmnet11
        Write-Host "[mm2 $hostName] enabling + starting mm2.service"
        $start = "sudo systemctl reset-failed mm2.service 2>/dev/null || true; sudo systemctl enable mm2.service && sudo systemctl restart mm2.service && echo MM2_START_OK"
        $out = (ssh @sshOpts "$sshUser@$ip" $start 2>&1 | Out-String)
        if ($out -notmatch 'MM2_START_OK') {
          throw "[mm2 $hostName] mm2.service start failed -- $out"
        }

        # Type=simple -- is-active flips to `active` as soon as the JVM is up.
        # The real readiness signal (connectors RUNNING / heartbeats topic) is
        # checked in Step 3; here we just confirm the process did not crash.
        Write-Host "[mm2 $hostName] waiting for mm2.service to settle active..."
        $deadline = (Get-Date).AddMinutes(2)
        $active = $false
        while ((Get-Date) -lt $deadline) {
          $status = (ssh @sshOpts "$sshUser@$ip" "systemctl is-active mm2.service" 2>&1 | Out-String).Trim()
          if ($status -eq 'active') {
            Start-Sleep -Seconds 5
            $status2 = (ssh @sshOpts "$sshUser@$ip" "systemctl is-active mm2.service" 2>&1 | Out-String).Trim()
            if ($status2 -eq 'active') { $active = $true; break }
          }
          Start-Sleep -Seconds 5
        }
        if (-not $active) {
          $journal = (ssh @sshOpts "$sshUser@$ip" "sudo journalctl -u mm2.service --no-pager -n 50" 2>&1 | Out-String)
          Write-Host $journal
          throw "[mm2 $hostName] mm2.service did not stay active within 2 min"
        }
        Write-Host "[mm2 $hostName] mm2.service active"
      }

      # ─── Step 3: per-node verify -- journal sanity, heartbeats topic on ──
      #     the target cluster, then the exit-gate round-trip ──────────────
      foreach ($n in $nodes) {
        $hostName = $n.host
        $ip       = $n.vmnet11
        $src      = $n.src
        $dst      = $n.dst
        $srcBootstrap = if ($src -eq 'east') { $eastBootstrap } else { $westBootstrap }
        $dstBootstrap = if ($dst -eq 'east') { $eastBootstrap } else { $westBootstrap }

        Write-Host ""
        Write-Host "[mm2 $hostName] verifying $src->$dst flow"

        # 3a: the `heartbeats` topic appears on the TARGET cluster -- the
        # strongest single liveness signal (HeartbeatConnector is producing).
        # The kafka CLI tools run under `sudo`: /etc/nexus-kafka is 0750
        # root:kafka, so nexusadmin cannot traverse it to read client-ssl.
        # properties / the keystore (the consul.d 0750 lesson, Kafka edition).
        $hbReady = $false
        $deadline = (Get-Date).AddMinutes(4)
        while ((Get-Date) -lt $deadline) {
          $topics = (ssh @sshOpts "$sshUser@$ip" "sudo /opt/kafka/bin/kafka-topics.sh --bootstrap-server $dstBootstrap --command-config $clientCfg --list 2>/dev/null" 2>&1 | Out-String)
          if ($topics -match '(?m)^heartbeats\r?$') { $hbReady = $true; break }
          Start-Sleep -Seconds 10
        }
        if (-not $hbReady) {
          $journal = (ssh @sshOpts "$sshUser@$ip" "sudo journalctl -u mm2.service --no-pager -n 80" 2>&1 | Out-String)
          Write-Host $journal
          throw "[mm2 $hostName] heartbeats topic never appeared on the $dst cluster within 4 min"
        }
        Write-Host "[mm2 $hostName] heartbeats topic live on the $dst cluster"

        # 3b: journal sanity -- no TLS/auth failures, MM2 connectors mentioned.
        $journal = (ssh @sshOpts "$sshUser@$ip" "sudo journalctl -u mm2.service --no-pager -n 400" 2>&1 | Out-String)
        if ($journal -match 'SSLHandshakeException' -or $journal -match 'Failed authentication') {
          Write-Host $journal
          throw "[mm2 $hostName] journal shows a TLS/auth failure -- mTLS to the brokers is broken"
        }
        if ($journal -notmatch 'MirrorSourceConnector' -or $journal -notmatch 'MirrorHeartbeatConnector') {
          Write-Host $journal
          throw "[mm2 $hostName] journal does not mention the MM2 connectors -- dedicated mode did not start the flow"
        }
        Write-Host "[mm2 $hostName] journal clean (connectors started, no TLS/auth errors)"

        # 3c: exit-gate round-trip -- produce a unique token to `dr-gate-test`
        # on the SOURCE cluster, then consume the mirrored `<src>.dr-gate-test`
        # on the TARGET cluster. Topic create tolerates an existing topic
        # (idempotent across re-applies); the token is fresh each run so the
        # consume proves THIS run's mirroring, not a stale record.
        $token       = "dr-gate-token-$hostName-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
        $mirrorTopic = "$src.dr-gate-test"

        Write-Host "[mm2 $hostName] exit-gate: create dr-gate-test on $src"
        $createCmd = "sudo /opt/kafka/bin/kafka-topics.sh --bootstrap-server $srcBootstrap --command-config $clientCfg --create --topic dr-gate-test --partitions 3 --replication-factor 3 2>&1 | grep -qE 'Created topic|already exists' && echo TOPIC_READY || echo TOPIC_FAIL"
        $createOut = (ssh @sshOpts "$sshUser@$ip" $createCmd 2>&1 | Out-String)
        if ($createOut -notmatch 'TOPIC_READY') {
          throw "[mm2 $hostName] could not create/confirm dr-gate-test on $src -- $createOut"
        }

        Write-Host "[mm2 $hostName] exit-gate: produce $token to dr-gate-test on $src"
        $produceCmd = "echo '$token' | sudo /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server $srcBootstrap --producer.config $clientCfg --topic dr-gate-test && echo PRODUCE_OK"
        $produceOut = (ssh @sshOpts "$sshUser@$ip" $produceCmd 2>&1 | Out-String)
        if ($produceOut -notmatch 'PRODUCE_OK') {
          throw "[mm2 $hostName] produce to dr-gate-test on $src failed -- $produceOut"
        }

        Write-Host "[mm2 $hostName] exit-gate: waiting for $token to mirror to $mirrorTopic on $dst"
        $consumeCmd = "sudo /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server $dstBootstrap --consumer.config $clientCfg --topic $mirrorTopic --from-beginning --timeout-ms 30000 2>/dev/null"
        $mirrored = $false
        $deadline = (Get-Date).AddMinutes(3)
        while ((Get-Date) -lt $deadline) {
          $consumeOut = (ssh @sshOpts "$sshUser@$ip" $consumeCmd 2>&1 | Out-String)
          if ($consumeOut -match [regex]::Escape($token)) { $mirrored = $true; break }
          Start-Sleep -Seconds 5
        }
        if (-not $mirrored) {
          $journal = (ssh @sshOpts "$sshUser@$ip" "sudo journalctl -u mm2.service --no-pager -n 80" 2>&1 | Out-String)
          Write-Host $journal
          throw "[mm2 $hostName] EXIT GATE FAILED -- $token never appeared on $mirrorTopic ($dst) within 3 min"
        }
        Write-Host "[mm2 $hostName] EXIT GATE OK -- $token produced to $src/dr-gate-test mirrored to $dst/$mirrorTopic"
      }

      Write-Host ""
      Write-Host "[mm2] OK -- MirrorMaker 2 DR pair live ($($nodes.Count) node(s)); cross-cluster replication verified both directions over mTLS"
    PWSH
  }

  # Destroy: stop + disable mm2.service + remove the rendered config + the
  # systemd drop-in on each node. Idempotent.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${self.triggers.destroy_ssh_user}'
      $ips     = '${self.triggers.destroy_mm2_ips}' -split ','
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      foreach ($ip in $ips) {
        if (-not $ip) { continue }
        Write-Host "[mm2 destroy] $${ip}: stopping mm2.service + removing config + drop-in"
        ssh @sshOpts "$sshUser@$ip" "sudo systemctl disable --now mm2.service 2>/dev/null; sudo rm -f /etc/nexus-kafka/mm2.properties /etc/systemd/system/mm2.service.d/10-clusters.conf; sudo rmdir /etc/systemd/system/mm2.service.d 2>/dev/null; sudo systemctl daemon-reload" 2>$null
      }
      exit 0
    PWSH
  }
}

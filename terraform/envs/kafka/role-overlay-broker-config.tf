/*
 * role-overlay-broker-config.tf -- render /etc/nexus-kafka/server.properties
 * on every enabled broker.
 *
 * Combined-mode KRaft (process.roles=broker,controller), 3-node quorum per
 * cluster, replication factor 3. All listeners on the VMnet10 backplane:
 * PLAINTEXT 9092 bound on 0.0.0.0 (so a broker-local `localhost:9092` smoke
 * works) + advertised on the VMnet10 IP; CONTROLLER 9093 bound + advertised
 * on the VMnet10 IP. 0.H.2 swaps PLAINTEXT for SSL/mTLS from Vault PKI.
 *
 * The cluster UUID is NOT in server.properties -- role-overlay-kraft-format.tf
 * passes it to `kafka-storage format`. This overlay only renders config;
 * kraft-format does format + start + verify.
 *
 * Terraform computes the full enabled-broker table (node.id, VMnet10 IP, the
 * per-cluster controller.quorum.voters string) and hands it to PowerShell as
 * a JSON blob -- no fragile bool interpolation into the heredoc.
 */

locals {
  # All three nodes of each cluster (quorum-voters always lists all three;
  # per-VM enable toggles only affect which clones exist + get configured).
  kafka_east_all = [
    { node_id = 1, vmnet10 = "192.168.10.21", vmnet11 = "192.168.70.21", enabled = var.enable_kafka_east_1 },
    { node_id = 2, vmnet10 = "192.168.10.22", vmnet11 = "192.168.70.22", enabled = var.enable_kafka_east_2 },
    { node_id = 3, vmnet10 = "192.168.10.23", vmnet11 = "192.168.70.23", enabled = var.enable_kafka_east_3 },
  ]
  kafka_west_all = [
    { node_id = 1, vmnet10 = "192.168.10.24", vmnet11 = "192.168.70.24", enabled = var.enable_kafka_west_1 },
    { node_id = 2, vmnet10 = "192.168.10.25", vmnet11 = "192.168.70.25", enabled = var.enable_kafka_west_2 },
    { node_id = 3, vmnet10 = "192.168.10.26", vmnet11 = "192.168.70.26", enabled = var.enable_kafka_west_3 },
  ]

  kafka_east_quorum = join(",", [for n in local.kafka_east_all : "${n.node_id}@${n.vmnet10}:9093"])
  kafka_west_quorum = join(",", [for n in local.kafka_west_all : "${n.node_id}@${n.vmnet10}:9093"])

  # The enabled-broker table the overlay actually acts on: one object per
  # broker that (a) has its cluster gate on and (b) has its per-VM toggle on.
  kafka_enabled_brokers = concat(
    var.enable_kafka_east ? [
      for n in local.kafka_east_all : {
        cluster = "east"
        node_id = n.node_id
        vmnet10 = n.vmnet10
        vmnet11 = n.vmnet11
        quorum  = local.kafka_east_quorum
      } if n.enabled
    ] : [],
    var.enable_kafka_west ? [
      for n in local.kafka_west_all : {
        cluster = "west"
        node_id = n.node_id
        vmnet10 = n.vmnet10
        vmnet11 = n.vmnet11
        quorum  = local.kafka_west_quorum
      } if n.enabled
    ] : [],
  )
}

resource "null_resource" "kafka_broker_config" {
  count = var.enable_kafka_cluster && var.enable_broker_config ? 1 : 0

  triggers = {
    # Keyed only on the broker SET + this overlay's version. Deliberately NOT
    # on null_resource.kafka_nftables_backplane's id -- that id-trigger made
    # this overlay re-run every time the nftables overlay re-ran (e.g. when a
    # later sub-phase extended it to new ecosystem nodes), and a re-run here
    # re-renders PLAINTEXT server.properties, CLOBBERING the SSL config that
    # role-overlay-kafka-tls.tf flipped in on 0.H.2. Ordering after nftables
    # is handled by depends_on. (The role-overlay-kafka-tls.tf va_ids lesson.)
    east_1    = length(module.kafka_east_1) > 0 ? module.kafka_east_1[0].vm_name : "absent"
    east_2    = length(module.kafka_east_2) > 0 ? module.kafka_east_2[0].vm_name : "absent"
    east_3    = length(module.kafka_east_3) > 0 ? module.kafka_east_3[0].vm_name : "absent"
    west_1    = length(module.kafka_west_1) > 0 ? module.kafka_west_1[0].vm_name : "absent"
    west_2    = length(module.kafka_west_2) > 0 ? module.kafka_west_2[0].vm_name : "absent"
    west_3    = length(module.kafka_west_3) > 0 ? module.kafka_west_3[0].vm_name : "absent"
    brokers   = jsonencode(local.kafka_enabled_brokers)
    overlay_v = "2" # v2 (0.H.4) = dropped the `nftables_id` id-trigger (it cascaded re-runs that clobbered the post-0.H.2 SSL server.properties) + added the client-ssl.properties skip-guard so a re-run never overwrites a TLS-flipped broker. v1 = original PLAINTEXT render.
  }

  depends_on = [null_resource.kafka_nftables_backplane]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $user    = '${var.kafka_node_user}'
      $timeout = ${var.kafka_cluster_timeout_minutes}
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      # Terraform-computed enabled-broker table (JSON -> PS objects).
      $brokers = @'
${jsonencode(local.kafka_enabled_brokers)}
'@ | ConvertFrom-Json

      if ($brokers.Count -eq 0) {
        Write-Host "[broker-config] no enabled brokers -- nothing to do"
        exit 0
      }

      function Render-ServerProperties {
        param([int]$NodeId, [string]$Vmnet10, [string]$Quorum, [string]$Cluster)
        @"
# Generated by role-overlay-broker-config.tf -- Phase 0.H.1. Do not edit by hand.
# Cluster: $Cluster   node.id: $NodeId   backplane: $Vmnet10
process.roles=broker,controller
node.id=$NodeId
controller.quorum.voters=$Quorum

listeners=PLAINTEXT://0.0.0.0:9092,CONTROLLER://$${Vmnet10}:9093
advertised.listeners=PLAINTEXT://$${Vmnet10}:9092
controller.listener.names=CONTROLLER
inter.broker.listener.name=PLAINTEXT
listener.security.protocol.map=PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT

log.dirs=/var/lib/kafka/data
num.partitions=3
default.replication.factor=3
offsets.topic.replication.factor=3
transaction.state.log.replication.factor=3
transaction.state.log.min.isr=2
min.insync.replicas=2
auto.create.topics.enable=false
"@
      }

      foreach ($b in $brokers) {
        $ip = $b.vmnet11

        Write-Host "[broker-config] $${ip}: waiting for SSH + firstboot marker..."
        $deadline = (Get-Date).AddMinutes($timeout)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
          $probe = (ssh @sshOpts "$user@$ip" "test -f /var/lib/kafka-node-firstboot-done && echo READY" 2>&1 | Out-String).Trim()
          if ($probe -match 'READY') { $ready = $true; break }
          Start-Sleep -Seconds 15
        }
        if (-not $ready) { throw "[broker-config] $${ip}: SSH + firstboot marker never ready after $timeout min" }

        # Skip-guard: /etc/nexus-kafka/client-ssl.properties exists ONLY once
        # role-overlay-kafka-tls.tf has flipped this broker to mTLS. If it's
        # present, kafka-tls owns server.properties (the SSL variant) -- this
        # 0.H.1 overlay must NOT clobber it with the PLAINTEXT render. It only
        # renders on a still-PLAINTEXT broker (cold rebuild, pre-flip).
        $flipped = (ssh @sshOpts "$user@$ip" "sudo test -f /etc/nexus-kafka/client-ssl.properties && echo TLS_FLIPPED" 2>&1 | Out-String).Trim()
        if ($flipped -match 'TLS_FLIPPED') {
          Write-Host "[broker-config] $${ip}: already TLS-flipped -- leaving server.properties to role-overlay-kafka-tls.tf"
          continue
        }

        $props = (Render-ServerProperties -NodeId $b.node_id -Vmnet10 $b.vmnet10 -Quorum $b.quorum -Cluster $b.cluster) -replace "`r`n", "`n"
        Write-Host "[broker-config] $${ip}: rendering server.properties ($($b.cluster) node $($b.node_id))"
        $remote = "tr -d '\r' | sudo tee /etc/nexus-kafka/server.properties > /dev/null && sudo chown root:kafka /etc/nexus-kafka/server.properties && sudo chmod 640 /etc/nexus-kafka/server.properties && echo PROPS_OK"
        $out = ($props | ssh @sshOpts "$user@$ip" $remote 2>&1 | Out-String)
        if ($out -notmatch 'PROPS_OK') {
          throw "[broker-config] $${ip}: server.properties render failed -- $out"
        }
        Write-Host "[broker-config] $${ip}: server.properties rendered"
      }

      Write-Host "[broker-config] server.properties rendered on $($brokers.Count) enabled broker(s)"
    PWSH
  }
}

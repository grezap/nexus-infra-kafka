/*
 * role-overlay-schema-registry.tf -- Phase 0.H.3
 *
 * Brings up the Confluent Schema Registry HA pair (schema-registry-1/2).
 * Both nodes are Kafka clients of the kafka-east cluster: they back the
 * schema store on the `_schemas` topic and elect a leader via Kafka group
 * coordination (no ZooKeeper -- removed in Confluent 7.0). The leader owns
 * writes; followers transparently forward writes over the inter-instance
 * HTTPS channel.
 *
 * Pre-req: role-overlay-ecosystem-tls.tf has rendered /etc/nexus-kafka/tls/
 * {keystore,truststore}.pem + /etc/nexus-kafka/client-ssl.properties on both
 * SR nodes.
 *
 * Steps (single count-gated resource, loops the pair in PowerShell):
 *   1. Pre-create the `_schemas` topic from schema-registry-1 (partitions=1,
 *      RF=3, cleanup.policy=compact, min.insync.replicas=2). SR would
 *      auto-create it via an explicit AdminClient call even though the
 *      brokers run auto.create.topics.enable=false, but pre-creating makes
 *      the topic settings deterministic. --if-not-exists -> idempotent.
 *   2. Render /etc/nexus-kafka/schema-registry.properties per node
 *      (host.name = this node's VMnet10 IP for leader-forwarding).
 *   3. enable + start schema-registry.service on both.
 *   4. Wait for each node's https://<ip>:8081/subjects to answer.
 *   5. HA verify: register a schema on node-1, fetch it from node-2 (proves
 *      both nodes share the _schemas backing log + leader-forwarding works).
 *
 * TLS: mTLS to the brokers (kafkastore.ssl.* -- the brokers require client
 * certs); the SR REST listener is HTTPS server-side only
 * (ssl.client.authentication=NONE), matching the consul-tls operator-API
 * precedent (https.verify_incoming=false). The SR pair's inter-instance
 * leader-forwarding uses HTTPS (inter.instance.protocol=https) over the same
 * keystore.
 *
 * Selective ops: var.enable_schema_registry AND var.enable_schema_registry_config
 *                AND var.enable_ecosystem_tls.
 */

locals {
  # Enabled Schema Registry nodes.
  kafka_sr_specs = concat(
    var.enable_schema_registry && var.enable_schema_registry_1 ? [{ host = "schema-registry-1", vmnet10 = "192.168.10.91", vmnet11 = "192.168.70.91" }] : [],
    var.enable_schema_registry && var.enable_schema_registry_2 ? [{ host = "schema-registry-2", vmnet10 = "192.168.10.92", vmnet11 = "192.168.70.92" }] : [],
  )
  # kafka-east broker bootstrap list over the VMnet10 backplane (SSL).
  kafka_east_bootstrap = join(",", [for n in local.kafka_east_all : "SSL://${n.vmnet10}:9092"])
}

resource "null_resource" "kafka_schema_registry" {
  count = var.enable_kafka_cluster && var.enable_schema_registry && var.enable_schema_registry_config && var.enable_ecosystem_tls && length(local.kafka_sr_specs) > 0 ? 1 : 0

  triggers = {
    # Keyed only on this overlay's OWN inputs (SR node set / broker
    # bootstrap / overlay version). Ordering after the keystore render is
    # handled by depends_on -- NOT by a kafka_ecosystem_tls id trigger,
    # which would needlessly re-run this overlay (= an SR pair restart)
    # every time the ecosystem-node set grows in a later sub-phase (the
    # role-overlay-kafka-tls.tf va_ids lesson).
    nodes       = jsonencode(local.kafka_sr_specs)
    bootstrap   = local.kafka_east_bootstrap
    sr_config_v = "2" # v2 (0.H.4) = dropped the `tls_id` trigger (kafka_ecosystem_tls id) -- it churned this overlay every time a later sub-phase added ecosystem nodes. v1 = HA pair, mTLS kafkastore, HTTPS REST listener (PEM, client-auth NONE), _schemas pre-created (1 part / RF 3 / compact).

    destroy_sr_ips   = join(",", [for n in local.kafka_sr_specs : n.vmnet11])
    destroy_ssh_user = var.kafka_node_user
  }

  depends_on = [null_resource.kafka_ecosystem_tls]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser   = '${var.kafka_node_user}'
      $bootstrap = '${local.kafka_east_bootstrap}'
      $kafka     = '/opt/kafka/bin'
      $confluent = '/opt/confluent/bin'
      $clientCfg = '/etc/nexus-kafka/client-ssl.properties'
      $caFile    = '/etc/ssl/certs/kafka-ca.pem'
      $sshOpts   = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $nodes = @'
${jsonencode(local.kafka_sr_specs)}
'@ | ConvertFrom-Json

      if ($nodes.Count -eq 0) {
        Write-Host "[schema-registry] no enabled SR nodes -- nothing to do"
        exit 0
      }

      $firstIp = $nodes[0].vmnet11

      # ─── Step 1: pre-create the _schemas topic (idempotent) ─────────────
      Write-Host "[schema-registry] pre-creating the _schemas topic from $($nodes[0].host)..."
      $mkTopic = "sudo $kafka/kafka-topics.sh --bootstrap-server $bootstrap --command-config $clientCfg --create --if-not-exists --topic _schemas --partitions 1 --replication-factor 3 --config cleanup.policy=compact --config min.insync.replicas=2 && echo SCHEMAS_OK"
      $mkOut = (ssh @sshOpts "$sshUser@$firstIp" $mkTopic 2>&1 | Out-String)
      if ($mkOut -notmatch 'SCHEMAS_OK') {
        throw "[schema-registry] _schemas topic create failed -- $mkOut"
      }
      Write-Host "[schema-registry] _schemas topic present (1 partition, RF=3, compact)"

      # ─── Step 2+3: render config + enable/start on each SR node ──────────
      foreach ($n in $nodes) {
        $hostName = $n.host
        $ip       = $n.vmnet11
        $vmnet10  = $n.vmnet10

        $props = @"
# Generated by role-overlay-schema-registry.tf -- Phase 0.H.3. Do not edit by hand.
# Node: $hostName   host.name (inter-instance): $vmnet10

# --- HA pair: Kafka-group leader election (no ZooKeeper) ---
schema.registry.group.id=schema-registry
host.name=$vmnet10
leader.eligibility=true

# --- REST listener (HTTPS, server-side TLS; operator API -- no client cert) ---
listeners=https://0.0.0.0:8081
inter.instance.protocol=https
ssl.keystore.type=PEM
ssl.keystore.location=/etc/nexus-kafka/tls/keystore.pem
ssl.truststore.type=PEM
ssl.truststore.location=/etc/nexus-kafka/tls/truststore.pem
ssl.client.authentication=NONE

# --- Kafka store: the _schemas topic on kafka-east, over mTLS ---
kafkastore.bootstrap.servers=$bootstrap
kafkastore.security.protocol=SSL
kafkastore.ssl.keystore.type=PEM
kafkastore.ssl.keystore.location=/etc/nexus-kafka/tls/keystore.pem
kafkastore.ssl.truststore.type=PEM
kafkastore.ssl.truststore.location=/etc/nexus-kafka/tls/truststore.pem
kafkastore.ssl.endpoint.identification.algorithm=https
kafkastore.topic=_schemas
kafkastore.topic.replication.factor=3
"@
        $propsB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($props -replace "`r`n","`n")))

        $stage = @"
set -euo pipefail
echo '$propsB64' | base64 -d | sudo tee /etc/nexus-kafka/schema-registry.properties > /dev/null
sudo chown root:kafka /etc/nexus-kafka/schema-registry.properties
sudo chmod 0640 /etc/nexus-kafka/schema-registry.properties
sudo systemctl reset-failed schema-registry.service 2>/dev/null || true
sudo systemctl enable schema-registry.service
sudo systemctl restart schema-registry.service
echo SR_START_OK
"@
        Write-Host "[schema-registry $hostName] rendering config + starting schema-registry.service"
        $stageOut = ($stage -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $stageOut -notmatch 'SR_START_OK') {
          Write-Host $stageOut.Trim()
          throw "[schema-registry $hostName] config render / service start failed (rc=$LASTEXITCODE)"
        }
      }

      # ─── Step 4: wait for each node's HTTPS :8081/subjects ──────────────
      foreach ($n in $nodes) {
        $hostName = $n.host
        $ip       = $n.vmnet11
        Write-Host "[schema-registry $hostName] waiting for https://$($ip):8081/subjects ..."
        $deadline = (Get-Date).AddMinutes(5)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
          $code = (ssh @sshOpts "$sshUser@$ip" "curl -s -o /dev/null -w '%%{http_code}' --cacert $caFile https://localhost:8081/subjects 2>/dev/null" 2>&1 | Out-String).Trim()
          if ($code -match '200') { $ready = $true; break }
          Start-Sleep -Seconds 5
        }
        if (-not $ready) {
          $journal = (ssh @sshOpts "$sshUser@$ip" "sudo journalctl -u schema-registry.service --no-pager -n 40" 2>&1 | Out-String)
          Write-Host $journal
          throw "[schema-registry $hostName] REST listener not ready on :8081 within 5 min"
        }
        Write-Host "[schema-registry $hostName] REST listener live (HTTPS :8081)"
      }

      # ─── Step 5: HA verify -- register on node-1, fetch from the last ───
      if ($nodes.Count -ge 2) {
        $regIp   = $nodes[0].vmnet11
        $fetchIp = $nodes[-1].vmnet11
        $subject = "nexus-smoke-0h3-$(Get-Random)"
        Write-Host "[schema-registry] HA check: register schema on $($nodes[0].host), fetch from $($nodes[-1].host)..."
        # The SR API body is {"schema": "<the schema as a JSON string>"} -- the
        # outer object uses plain quotes; only the inner schema-string quotes
        # are \"-escaped (JSON string escaping). Single-quoted PS literal, then
        # wrapped in '...' in the remote bash command -- no shell escaping.
        $schemaJson = '{"schema": "{\"type\":\"record\",\"name\":\"NexusSmoke\",\"fields\":[{\"name\":\"id\",\"type\":\"string\"}]}"}'
        $reg = "curl -s --cacert $caFile -X POST -H 'Content-Type: application/vnd.schemaregistry.v1+json' --data '$schemaJson' https://localhost:8081/subjects/$subject/versions"
        $regOut = (ssh @sshOpts "$sshUser@$regIp" $reg 2>&1 | Out-String).Trim()
        if ($regOut -notmatch '"id"\s*:\s*\d+') {
          throw "[schema-registry] schema register on $($nodes[0].host) failed -- $regOut"
        }
        Write-Host "[schema-registry] registered: $regOut"
        $fetch = "curl -s -o /dev/null -w '%%{http_code}' --cacert $caFile https://localhost:8081/subjects/$subject/versions/1"
        $fetchCode = (ssh @sshOpts "$sshUser@$fetchIp" $fetch 2>&1 | Out-String).Trim()
        if ($fetchCode -notmatch '200') {
          throw "[schema-registry] fetch of $subject from $($nodes[-1].host) returned '$fetchCode' (expected 200) -- HA pair not sharing the _schemas log"
        }
        Write-Host "[schema-registry] HA OK -- schema registered on $($nodes[0].host) is readable from $($nodes[-1].host)"
        # Clean up the smoke subject.
        ssh @sshOpts "$sshUser@$regIp" "curl -s -o /dev/null --cacert $caFile -X DELETE https://localhost:8081/subjects/$subject" 2>&1 | Out-Null
      }

      Write-Host ""
      Write-Host "[schema-registry] OK -- Schema Registry HA pair live on HTTPS :8081 (mTLS to kafka-east)"
    PWSH
  }

  # Destroy: stop + disable schema-registry.service + remove the rendered
  # config on each SR node. Idempotent.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${self.triggers.destroy_ssh_user}'
      $ips     = '${self.triggers.destroy_sr_ips}' -split ','
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      foreach ($ip in $ips) {
        if (-not $ip) { continue }
        Write-Host "[schema-registry destroy] $${ip}: stopping schema-registry.service + removing config"
        ssh @sshOpts "$sshUser@$ip" "sudo systemctl disable --now schema-registry.service 2>/dev/null; sudo rm -f /etc/nexus-kafka/schema-registry.properties" 2>$null
      }
      exit 0
    PWSH
  }
}

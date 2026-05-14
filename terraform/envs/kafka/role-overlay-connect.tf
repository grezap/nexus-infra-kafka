/*
 * role-overlay-connect.tf -- Phase 0.H.4
 *
 * Brings up the Kafka Connect distributed cluster (kafka-connect-1/2) +
 * installs the Debezium connector plugins. The two workers share one
 * `group.id` (Kafka-group cluster membership); each is a Kafka client of
 * the kafka-east brokers over mutual TLS and serves its own HTTPS REST
 * listener on :8083.
 *
 * Pre-req: role-overlay-ecosystem-tls.tf rendered /etc/nexus-kafka/tls/
 * {keystore,truststore}.pem on both workers.
 *
 * Steps (single count-gated resource, loops the pair in PowerShell):
 *   1. Per worker: install the Debezium connector plugins (postgres +
 *      sqlserver) under /opt/connect-plugins (idempotent -- skips a plugin
 *      dir that already exists); render connect-distributed.properties.
 *   2. Sequential start: enable + start connect-distributed.service on
 *      worker-1, wait for its HTTPS REST listener; then worker-2 (it joins
 *      the existing cluster). Sequential avoids the 2-worker race to
 *      AdminClient-create the 3 internal topics -- worker-1 creates them,
 *      worker-2 joins. (Connect self-creates its internal topics via an
 *      explicit AdminClient call -- works with the brokers'
 *      auto.create.topics.enable=false; there are no ACLs.)
 *   3. Verify: /connector-plugins on a worker lists the Debezium
 *      connector classes.
 *
 * TLS notes (research-confirmed for Confluent 7.7):
 *   - Connect's top-level ssl.* does NOT cascade to the per-connector
 *     producer/consumer/admin clients -- the SSL block is repeated under
 *     the producer. / consumer. / admin. prefixes.
 *   - Connect's REST listener uses the KIP-208 `listeners.https.ssl.*`
 *     prefix (NOT the bare ssl.* that Schema Registry uses).
 *   - bootstrap.servers is the bare host:port form + security.protocol=SSL
 *     (not the SSL:// scheme prefix).
 *   - REST listener is server-side TLS only (client.auth=none) -- the
 *     consul-tls operator-API precedent.
 *
 * Selective ops: var.enable_kafka_connect AND var.enable_kafka_connect_config
 *                AND var.enable_ecosystem_tls.
 */

locals {
  kafka_connect_specs = concat(
    var.enable_kafka_connect && var.enable_kafka_connect_1 ? [{ host = "kafka-connect-1", vmnet10 = "192.168.10.95", vmnet11 = "192.168.70.95" }] : [],
    var.enable_kafka_connect && var.enable_kafka_connect_2 ? [{ host = "kafka-connect-2", vmnet10 = "192.168.10.96", vmnet11 = "192.168.70.96" }] : [],
  )
  # kafka-east bootstrap, BARE host:port form (Connect + ksqlDB take bare
  # bootstrap.servers + a separate security.protocol=SSL -- not the SSL://
  # scheme prefix that Schema Registry / the kafka CLI accept).
  kafka_east_bootstrap_bare = join(",", [for n in local.kafka_east_all : "${n.vmnet10}:9092"])
}

resource "null_resource" "kafka_connect" {
  count = var.enable_kafka_cluster && var.enable_kafka_connect && var.enable_kafka_connect_config && var.enable_ecosystem_tls && length(local.kafka_connect_specs) > 0 ? 1 : 0

  triggers = {
    # Keyed only on this overlay's OWN inputs (worker set / bootstrap /
    # Debezium version / overlay version). Ordering after the keystore
    # render is handled by depends_on -- NOT by a kafka_ecosystem_tls id
    # trigger, which would needlessly re-run this overlay every time the
    # ecosystem-node set grows (the role-overlay-kafka-tls.tf va_ids lesson).
    nodes            = jsonencode(local.kafka_connect_specs)
    bootstrap        = local.kafka_east_bootstrap_bare
    debezium_version = var.debezium_version
    connect_config_v = "1" # v1 = 2-worker distributed cluster, mTLS Kafka client (producer./consumer./admin. prefixed, PEM), KIP-208 HTTPS REST listener (PKCS#12 -- Apache Kafka's Connect RestServer rejects PEM), Debezium postgres+sqlserver plugins, sequential start.

    destroy_connect_ips = join(",", [for n in local.kafka_connect_specs : n.vmnet11])
    destroy_ssh_user    = var.kafka_node_user
  }

  depends_on = [null_resource.kafka_ecosystem_tls]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser   = '${var.kafka_node_user}'
      $bootstrap = '${local.kafka_east_bootstrap_bare}'
      $dbzVer    = '${var.debezium_version}'
      $p12Pass   = '${var.kafka_keystore_password}'
      $caFile    = '/etc/ssl/certs/kafka-ca.pem'
      $sshOpts   = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $nodes = @'
${jsonencode(local.kafka_connect_specs)}
'@ | ConvertFrom-Json

      if ($nodes.Count -eq 0) {
        Write-Host "[connect] no enabled Connect workers -- nothing to do"
        exit 0
      }

      # ─── Debezium plugin installer (literal; __DBZ_VER__ substituted) ───
      $dbzScript = @'
#!/bin/bash
set -euo pipefail
PLUGIN_DIR=/opt/connect-plugins
DBZ_VER="__DBZ_VER__"

# DNS guard -- the deb13 baseline can land with an empty /etc/resolv.conf.
if ! getent hosts repo1.maven.org >/dev/null 2>&1; then
  echo "[debezium] pointing /etc/resolv.conf at nexus-gateway dnsmasq"
  echo "nameserver 192.168.70.1" | sudo tee /etc/resolv.conf > /dev/null
fi

sudo mkdir -p "$PLUGIN_DIR"
for conn in postgres sqlserver; do
  dest="$PLUGIN_DIR/debezium-connector-$conn"
  if [ -d "$dest" ]; then
    echo "[debezium] debezium-connector-$conn already present -- skipping"
    continue
  fi
  cd /tmp
  tgz="debezium-connector-$conn-$DBZ_VER-plugin.tar.gz"
  url="https://repo1.maven.org/maven2/io/debezium/debezium-connector-$conn/$DBZ_VER/$tgz"
  curl -fsSL "$url" -o "$tgz"
  curl -fsSL "$url.sha1" -o "$tgz.sha1"
  echo "$(cat "$tgz.sha1")  $tgz" | sha1sum -c -
  sudo tar -xzf "$tgz" -C "$PLUGIN_DIR"
  rm -f "$tgz" "$tgz.sha1"
  echo "[debezium] installed debezium-connector-$conn $DBZ_VER"
done
sudo chown -R kafka:kafka "$PLUGIN_DIR"
echo DBZ_OK
'@
      $dbzScript = $dbzScript -replace '__DBZ_VER__', $dbzVer
      $dbzB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($dbzScript -replace "`r`n","`n")))

      # ─── Step 1: per worker -- install Debezium + render config ─────────
      foreach ($n in $nodes) {
        $hostName = $n.host
        $ip       = $n.vmnet11
        $vmnet10  = $n.vmnet10

        $props = @"
# Generated by role-overlay-connect.tf -- Phase 0.H.4. Do not edit by hand.
# Worker: $hostName   rest.advertised: $vmnet10

# --- Connect cluster identity (group.id identical across the worker pair) ---
group.id=nexus-connect-east
key.converter=org.apache.kafka.connect.json.JsonConverter
value.converter=org.apache.kafka.connect.json.JsonConverter
key.converter.schemas.enable=false
value.converter.schemas.enable=false

config.storage.topic=nexus-connect-east-configs
offset.storage.topic=nexus-connect-east-offsets
status.storage.topic=nexus-connect-east-status
config.storage.replication.factor=3
offset.storage.replication.factor=3
status.storage.replication.factor=3
offset.storage.partitions=25
status.storage.partitions=5

plugin.path=/opt/connect-plugins

# --- worker's own Kafka client (mTLS) ---
bootstrap.servers=$bootstrap
security.protocol=SSL
ssl.keystore.type=PEM
ssl.keystore.location=/etc/nexus-kafka/tls/keystore.pem
ssl.truststore.type=PEM
ssl.truststore.location=/etc/nexus-kafka/tls/truststore.pem
ssl.endpoint.identification.algorithm=https

# --- producer override (source connectors) -- top-level ssl.* does NOT cascade ---
producer.security.protocol=SSL
producer.ssl.keystore.type=PEM
producer.ssl.keystore.location=/etc/nexus-kafka/tls/keystore.pem
producer.ssl.truststore.type=PEM
producer.ssl.truststore.location=/etc/nexus-kafka/tls/truststore.pem
producer.ssl.endpoint.identification.algorithm=https

# --- consumer override (sink connectors) ---
consumer.security.protocol=SSL
consumer.ssl.keystore.type=PEM
consumer.ssl.keystore.location=/etc/nexus-kafka/tls/keystore.pem
consumer.ssl.truststore.type=PEM
consumer.ssl.truststore.location=/etc/nexus-kafka/tls/truststore.pem
consumer.ssl.endpoint.identification.algorithm=https

# --- admin override (internal-topic creation via AdminClient) ---
admin.security.protocol=SSL
admin.ssl.keystore.type=PEM
admin.ssl.keystore.location=/etc/nexus-kafka/tls/keystore.pem
admin.ssl.truststore.type=PEM
admin.ssl.truststore.location=/etc/nexus-kafka/tls/truststore.pem
admin.ssl.endpoint.identification.algorithm=https

# --- REST listener (HTTPS, server-side TLS; KIP-208 listeners.https. prefix) ---
# PKCS#12 (NOT PEM) -- Apache Kafka's Connect RestServer passes the keystore
# type straight to Jetty's KeyStore.getInstance(), which has no "PEM"
# provider ("NoSuchAlgorithmException: PEM KeyStore not available"). Schema
# Registry / REST Proxy accept PEM only because they use Confluent rest-utils
# with its PEM->keystore helper. The Kafka client blocks above stay PEM.
listeners=https://0.0.0.0:8083
listeners.https.ssl.keystore.type=PKCS12
listeners.https.ssl.keystore.location=/etc/nexus-kafka/tls/keystore.p12
listeners.https.ssl.keystore.password=$p12Pass
listeners.https.ssl.truststore.type=PKCS12
listeners.https.ssl.truststore.location=/etc/nexus-kafka/tls/truststore.p12
listeners.https.ssl.truststore.password=$p12Pass
listeners.https.ssl.client.auth=none
rest.advertised.host.name=$vmnet10
rest.advertised.port=8083
rest.advertised.listener=https
"@
        $propsB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($props -replace "`r`n","`n")))

        $stage = @"
set -euo pipefail
echo '$dbzB64' | base64 -d | tr -d '\r' > /tmp/install-debezium.sh
bash /tmp/install-debezium.sh
rm -f /tmp/install-debezium.sh
echo '$propsB64' | base64 -d | sudo tee /etc/nexus-kafka/connect-distributed.properties > /dev/null
sudo chown root:kafka /etc/nexus-kafka/connect-distributed.properties
sudo chmod 0640 /etc/nexus-kafka/connect-distributed.properties
echo CONNECT_STAGE_OK
"@
        Write-Host "[connect $hostName] installing Debezium plugins + rendering connect-distributed.properties"
        $stageOut = ($stage -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $stageOut -notmatch 'CONNECT_STAGE_OK' -or $stageOut -notmatch 'DBZ_OK') {
          Write-Host $stageOut.Trim()
          throw "[connect $hostName] Debezium install / config render failed (rc=$LASTEXITCODE)"
        }
      }

      # ─── Step 2: sequential start (worker-1 creates the internal topics; ──
      #     worker-2 joins the existing cluster -- no 2-worker create race) ──
      foreach ($n in $nodes) {
        $hostName = $n.host
        $ip       = $n.vmnet11
        Write-Host "[connect $hostName] enabling + starting connect-distributed.service"
        $start = "sudo systemctl reset-failed connect-distributed.service 2>/dev/null || true; sudo systemctl enable connect-distributed.service && sudo systemctl restart connect-distributed.service && echo CONNECT_START_OK"
        $out = (ssh @sshOpts "$sshUser@$ip" $start 2>&1 | Out-String)
        if ($out -notmatch 'CONNECT_START_OK') {
          throw "[connect $hostName] connect-distributed.service start failed -- $out"
        }

        Write-Host "[connect $hostName] waiting for https://$($ip):8083/ ..."
        $deadline = (Get-Date).AddMinutes(8)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
          $body = (ssh @sshOpts "$sshUser@$ip" "curl -s --cacert $caFile https://localhost:8083/ 2>/dev/null" 2>&1 | Out-String).Trim()
          if ($body -match '"version"') { $ready = $true; break }
          Start-Sleep -Seconds 5
        }
        if (-not $ready) {
          $journal = (ssh @sshOpts "$sshUser@$ip" "sudo journalctl -u connect-distributed.service --no-pager -n 40" 2>&1 | Out-String)
          Write-Host $journal
          throw "[connect $hostName] REST listener not ready on :8083 within 8 min"
        }
        Write-Host "[connect $hostName] REST listener live (HTTPS :8083)"
      }

      # ─── Step 3: verify the Debezium connector classes are registered ──
      $probeIp = $nodes[0].vmnet11
      $plugins = (ssh @sshOpts "$sshUser@$probeIp" "curl -s --cacert $caFile https://localhost:8083/connector-plugins 2>/dev/null" 2>&1 | Out-String)
      if ($plugins -notmatch 'io\.debezium\.connector\.postgresql\.PostgresConnector') {
        throw "[connect] /connector-plugins is missing the Debezium PostgresConnector`n$plugins"
      }
      if ($plugins -notmatch 'io\.debezium\.connector\.sqlserver\.SqlServerConnector') {
        throw "[connect] /connector-plugins is missing the Debezium SqlServerConnector`n$plugins"
      }
      Write-Host "[connect] Debezium connector classes registered (Postgres + SqlServer)"

      Write-Host ""
      Write-Host "[connect] OK -- Kafka Connect distributed cluster live on HTTPS :8083 (mTLS to kafka-east; Debezium plugins loaded)"
    PWSH
  }

  # Destroy: stop + disable connect-distributed.service + remove the rendered
  # config on each worker. The /opt/connect-plugins Debezium JARs are left
  # in place (harmless; a re-apply's installer skips an existing plugin dir).
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${self.triggers.destroy_ssh_user}'
      $ips     = '${self.triggers.destroy_connect_ips}' -split ','
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      foreach ($ip in $ips) {
        if (-not $ip) { continue }
        Write-Host "[connect destroy] $${ip}: stopping connect-distributed.service + removing config"
        ssh @sshOpts "$sshUser@$ip" "sudo systemctl disable --now connect-distributed.service 2>/dev/null; sudo rm -f /etc/nexus-kafka/connect-distributed.properties" 2>$null
      }
      exit 0
    PWSH
  }
}

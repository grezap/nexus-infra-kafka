/*
 * role-overlay-ecosystem-tls.tf -- Phase 0.H.3
 *
 * Renders a Vault-PKI PEM keystore + truststore on every enabled ECOSYSTEM
 * node (schema-registry / kafka-rest now; kafka-connect / ksqldb / mm2 join
 * in 0.H.4-0.H.5). The ecosystem services are Kafka CLIENTS of the brokers'
 * mTLS listeners (ssl.client.auth=required), so each needs its own client
 * keystore -- and they also serve their own HTTPS listeners from the same
 * cert (Confluent 7.7's Jetty REST listeners accept ssl.keystore.type=PEM).
 *
 * This is the ecosystem-node analogue of role-overlay-kafka-tls.tf's Phase 1
 * (cert render): install kafka-tls-split.sh + drop the per-host Vault Agent
 * PKI template (60-template-kafka-tls.hcl) + restart nexus-vault-agent +
 * wait for the bundle + run the split. It does NOT touch any role service --
 * the per-service overlays (role-overlay-schema-registry.tf,
 * role-overlay-rest.tf, ...) render config + enable the service afterward.
 *
 * Per-node, sequential -- nothing here coordinates across nodes or restarts
 * a running service, so there is no big-bang concern (unlike the broker
 * mTLS flip in role-overlay-kafka-tls.tf).
 *
 * The split script + client-ssl.properties are deliberately the SAME content
 * as role-overlay-kafka-tls.tf uses for the brokers (keystore.pem = PKCS#8
 * key + leaf + intermediate; truststore.pem = intermediate; client config
 * points the CLI tools at that keystore). Kept inline per-overlay, matching
 * the established consul-tls / nomad-tls pattern in nexus-infra-swarm-nomad.
 *
 * Selective ops: var.enable_ecosystem_tls AND var.enable_kafka_vault_agents.
 */

locals {
  # Enabled ecosystem nodes that need a PKI keystore. 0.H.3 = the
  # schema-registry pair + the REST proxy; 0.H.4 = the Connect cluster +
  # the ksqlDB pair; 0.H.5 = mm2.
  kafka_ecosystem_tls_specs = concat(
    var.enable_schema_registry && var.enable_schema_registry_1 ? [{ host = "schema-registry-1", vmnet10 = "192.168.10.91", vmnet11 = "192.168.70.91" }] : [],
    var.enable_schema_registry && var.enable_schema_registry_2 ? [{ host = "schema-registry-2", vmnet10 = "192.168.10.92", vmnet11 = "192.168.70.92" }] : [],
    var.enable_kafka_rest && var.enable_kafka_rest_1 ? [{ host = "kafka-rest-1", vmnet10 = "192.168.10.88", vmnet11 = "192.168.70.88" }] : [],
    var.enable_kafka_connect && var.enable_kafka_connect_1 ? [{ host = "kafka-connect-1", vmnet10 = "192.168.10.95", vmnet11 = "192.168.70.95" }] : [],
    var.enable_kafka_connect && var.enable_kafka_connect_2 ? [{ host = "kafka-connect-2", vmnet10 = "192.168.10.96", vmnet11 = "192.168.70.96" }] : [],
    var.enable_ksqldb && var.enable_ksqldb_1 ? [{ host = "ksqldb-1", vmnet10 = "192.168.10.97", vmnet11 = "192.168.70.97" }] : [],
    var.enable_ksqldb && var.enable_ksqldb_2 ? [{ host = "ksqldb-2", vmnet10 = "192.168.10.98", vmnet11 = "192.168.70.98" }] : [],
    var.enable_mm2 && var.enable_mm2_1 ? [{ host = "mm2-1", vmnet10 = "192.168.10.85", vmnet11 = "192.168.70.85" }] : [],
    var.enable_mm2 && var.enable_mm2_2 ? [{ host = "mm2-2", vmnet10 = "192.168.10.86", vmnet11 = "192.168.70.86" }] : [],
  )
}

resource "null_resource" "kafka_ecosystem_tls" {
  count = var.enable_kafka_cluster && var.enable_ecosystem_tls && var.enable_kafka_vault_agents && length(local.kafka_ecosystem_tls_specs) > 0 ? 1 : 0

  triggers = {
    # Re-run only when the ecosystem-node SET changes (node added/removed) or
    # the PKI role / overlay version changes. Deliberately NOT keyed on the
    # Vault Agent resource ids -- same rationale as role-overlay-kafka-tls.tf:
    # agent ids rotate on every security-env apply but the node's cert
    # doesn't, and the surgical kafka_vault_agent destroy preserves
    # 60-template-kafka-tls.hcl. Ordering is via depends_on.
    pki_role_name   = var.vault_pki_kafka_role_name
    nodes           = jsonencode(local.kafka_ecosystem_tls_specs)
    ecosystem_tls_v = "3" # v3 (0.H.4) = truststore.p12 built via `keytool -importcert` -- the v2 `openssl pkcs12 -export -nokeys` form produced a cert bag Java loads as EMPTY ("trustAnchors must be non-empty"). v2 = the split script also emits keystore.p12 + truststore.p12 (PKCS#12) -- Kafka Connect's + ksqlDB's REST listeners reject ssl.keystore.type=PEM, unlike Schema Registry / REST Proxy. v1 = PEM keystore/truststore + client-ssl.properties; PKCS#1->PKCS#8 key conversion.

    # Frozen for the destroy provisioner.
    destroy_node_ips = join(",", [for n in local.kafka_ecosystem_tls_specs : n.vmnet11])
    destroy_ssh_user = var.kafka_node_user
  }

  depends_on = [null_resource.kafka_vault_agent]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${var.kafka_node_user}'
      $pkiRole = '${var.vault_pki_kafka_role_name}'
      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $nodes = @'
${jsonencode(local.kafka_ecosystem_tls_specs)}
'@ | ConvertFrom-Json

      if ($nodes.Count -eq 0) {
        Write-Host "[ecosystem-tls] no enabled ecosystem nodes -- nothing to do"
        exit 0
      }

      # ─── Common artifact: the bundle-split post-render script ────────────
      # Single-quoted here-string -- everything literal, no PS interpolation.
      # Same content as role-overlay-kafka-tls.tf's split script (the brokers
      # and the ecosystem nodes both produce keystore.pem + truststore.pem in
      # /etc/nexus-kafka/tls/).
      $splitScript = @'
#!/bin/bash
set -euo pipefail
BUNDLE=/etc/nexus-kafka/tls/bundle.pem
DEST=/etc/nexus-kafka/tls
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

awk -v tmp="$TMP" '
  /-----BEGIN/ { n++; file=tmp"/block-"n }
  { if (n>0) print > file }
' "$BUNDLE"

LEAF=""
KEY=""
CA=""
for f in "$TMP"/block-*; do
  hdr=$(head -1 "$f")
  case "$hdr" in
    *"PRIVATE KEY"*)
      KEY=$f
      ;;
    *"BEGIN CERTIFICATE"*)
      if [ -z "$LEAF" ]; then LEAF=$f; else CA=$f; fi
      ;;
  esac
done

if [ -z "$LEAF" ] || [ -z "$KEY" ] || [ -z "$CA" ]; then
  echo "[kafka-tls-split] ERROR: bundle missing one of leaf/key/ca" >&2
  ls -la "$TMP" >&2
  exit 1
fi

# Vault PKI issues RSA keys in PKCS#1 (-----BEGIN RSA PRIVATE KEY-----), but
# the Java consumers (Kafka client, Confluent Schema Registry / REST Proxy)
# only accept PKCS#8 (-----BEGIN PRIVATE KEY-----). Convert (idempotent).
openssl pkcs8 -topk8 -nocrypt -in "$KEY" -out "$TMP/key-pkcs8.pem"

cat "$TMP/key-pkcs8.pem" "$LEAF" "$CA" > "$TMP/keystore.pem"
cp "$CA" "$TMP/truststore.pem"

# PKCS#12 keystore + truststore alongside the PEM pair. Apache Kafka's
# Connect RestServer + ksqlDB's KsqlRestConfig reject ssl.keystore.type=PEM
# (only JKS/PKCS12/BCFKS) -- unlike Confluent rest-utils (Schema Registry /
# REST Proxy), which accepts PEM. The Kafka-client connections everywhere
# still use the PEM pair; only the Connect/ksqlDB REST listeners use these
# .p12 files. openssl for both -- no keytool dependency.
P12_PASS="__P12_PASS__"
# Keystore: openssl builds a proper PrivateKeyEntry (key + leaf + CA chain).
openssl pkcs12 -export -in "$LEAF" -inkey "$TMP/key-pkcs8.pem" -certfile "$CA" \
  -name kafka-node -passout pass:"$P12_PASS" -out "$TMP/keystore.p12"
# Truststore: keytool, NOT `openssl pkcs12 -export -nokeys` -- the openssl
# form produces a cert bag that Java does NOT load as a trustedCertEntry
# ("trustAnchors parameter must be non-empty"). keytool -importcert writes a
# proper trustedCertEntry. keytool ships with the Temurin JDK (on PATH via
# update-alternatives).
rm -f "$TMP/truststore.p12"
keytool -importcert -noprompt -alias kafka-ca -file "$CA" \
  -keystore "$TMP/truststore.p12" -storetype PKCS12 -storepass "$P12_PASS"

install -m 0640 -o root -g kafka "$TMP/keystore.pem"   "$DEST/keystore.pem"
install -m 0644 -o root -g kafka "$TMP/truststore.pem" "$DEST/truststore.pem"
install -m 0640 -o root -g kafka "$TMP/keystore.p12"   "$DEST/keystore.p12"
install -m 0640 -o root -g kafka "$TMP/truststore.p12" "$DEST/truststore.p12"
install -m 0644 -o root -g root  "$CA"                 /etc/ssl/certs/kafka-ca.pem

echo "[kafka-tls-split] $(date -u +%FT%TZ) bundle split: keystore.{pem,p12} + truststore.{pem,p12} (+ /etc/ssl/certs/kafka-ca.pem)"
'@
      $splitScript = $splitScript -replace '__P12_PASS__', '${var.kafka_keystore_password}'

      # Client SSL config -- lets the kafka CLI tools (run via sudo on an
      # ecosystem node) talk to the mTLS brokers using this node's keystore.
      $clientSslConfig = @'
# /etc/nexus-kafka/client-ssl.properties -- Phase 0.H.3.
# Kafka CLI client config for mTLS. The node's own PKI keystore doubles as
# the client identity (the kafka-broker PKI role has client_flag=true).
security.protocol=SSL
ssl.keystore.type=PEM
ssl.keystore.location=/etc/nexus-kafka/tls/keystore.pem
ssl.truststore.type=PEM
ssl.truststore.location=/etc/nexus-kafka/tls/truststore.pem
ssl.endpoint.identification.algorithm=https
'@

      $splitB64     = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($splitScript     -replace "`r`n","`n")))
      $clientSslB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($clientSslConfig -replace "`r`n","`n")))

      # ─── Per-node cert render (sequential -- no service coordination) ────
      foreach ($n in $nodes) {
        $hostName = $n.host
        $ip       = $n.vmnet11
        $cn       = "$hostName.kafka.nexus.lab"
        $altNames = "$hostName,$hostName.nexus.lab,$hostName.kafka.nexus.lab,localhost"
        $ipSans   = "$($n.vmnet10),$($n.vmnet11),127.0.0.1"

        Write-Host ""
        Write-Host "[ecosystem-tls $hostName] rendering PKI keystore + truststore"

        # Per-host Vault Agent PKI template (same shape as the broker one).
        $vaultAgentTemplate = @"
# 60-template-kafka-tls.hcl -- Phase 0.H.3 (rendered for $hostName).
# Issues a kafka-tier TLS leaf from pki_int/roles/$pkiRole and writes one
# bundle file; the post-render command splits it into keystore + truststore.

template {
  contents = <<EOT
{{- with pkiCert `"pki_int/issue/$pkiRole`" `"common_name=$cn`" `"alt_names=$altNames`" `"ip_sans=$ipSans`" `"ttl=2160h`" }}
{{ .Cert }}
{{ .Key }}
{{ .CA }}
{{- end }}
EOT

  destination     = "/etc/nexus-kafka/tls/bundle.pem"
  perms           = "0640"
  user            = "root"
  group           = "kafka"
  command         = "/usr/local/sbin/kafka-tls-split.sh"
  command_timeout = "30s"
}
"@
        $vaB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($vaultAgentTemplate -replace "`r`n","`n")))

        $stage1 = @"
set -euo pipefail
sudo mkdir -p /etc/nexus-kafka/tls
sudo chown root:kafka /etc/nexus-kafka/tls
sudo chmod 0750 /etc/nexus-kafka/tls

echo '$splitB64' | base64 -d | sudo tee /usr/local/sbin/kafka-tls-split.sh > /dev/null
sudo chown root:root /usr/local/sbin/kafka-tls-split.sh
sudo chmod 0755 /usr/local/sbin/kafka-tls-split.sh

echo '$vaB64' | base64 -d | sudo tee /etc/vault-agent/60-template-kafka-tls.hcl > /dev/null
sudo chown root:root /etc/vault-agent/60-template-kafka-tls.hcl
sudo chmod 0644 /etc/vault-agent/60-template-kafka-tls.hcl

sudo systemctl restart nexus-vault-agent.service

# Wait for bundle.pem, then run the split manually -- pkiCert results are
# CACHED by the Vault Agent, so a restart with an unchanged cert does NOT
# fire the command-on-render trigger. Manual invocation is idempotent.
for i in 1 2 3 4 5 6 7 8 9 10; do
  sudo test -s /etc/nexus-kafka/tls/bundle.pem && break
  sleep 2
done
if ! sudo test -s /etc/nexus-kafka/tls/bundle.pem; then
  echo "[stage1] ERROR: bundle.pem not rendered within 20s after vault-agent restart" >&2
  sudo journalctl -u nexus-vault-agent.service --no-pager -n 20 >&2
  exit 1
fi
sudo /usr/local/sbin/kafka-tls-split.sh

echo '$clientSslB64' | base64 -d | sudo tee /etc/nexus-kafka/client-ssl.properties > /dev/null
sudo chown root:kafka /etc/nexus-kafka/client-ssl.properties
sudo chmod 0644 /etc/nexus-kafka/client-ssl.properties
echo STAGE1_OK
"@
        $stage1Lf  = $stage1 -replace "`r`n", "`n"
        $stage1Out = $stage1Lf | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $stage1Out -notmatch 'STAGE1_OK') {
          Write-Host $stage1Out.Trim()
          throw "[ecosystem-tls $hostName] cert render failed (rc=$LASTEXITCODE)"
        }

        # Wait for the cert files + verify the CN.
        $deadline = (Get-Date).AddSeconds(60)
        $rendered = $false
        while ((Get-Date) -lt $deadline) {
          $check = (ssh @sshOpts "$sshUser@$ip" "sudo test -s /etc/nexus-kafka/tls/keystore.pem && sudo test -s /etc/nexus-kafka/tls/truststore.pem && sudo openssl x509 -in /etc/nexus-kafka/tls/keystore.pem -noout -subject 2>/dev/null | grep -q '$cn' && echo OK" 2>&1 | Out-String).Trim()
          if ($check -match 'OK') { $rendered = $true; break }
          Start-Sleep -Seconds 3
        }
        if (-not $rendered) {
          $journal = (ssh @sshOpts "$sshUser@$ip" "sudo journalctl -u nexus-vault-agent.service --no-pager -n 40" 2>&1 | Out-String)
          Write-Host $journal
          throw "[ecosystem-tls $hostName] cert files not rendered (CN=$cn) within 60s"
        }
        Write-Host "[ecosystem-tls $hostName] keystore + truststore rendered (CN=$cn)"
      }

      Write-Host ""
      Write-Host "[ecosystem-tls] OK -- $($nodes.Count) ecosystem node(s) have PKI keystore + truststore + client-ssl.properties"
    PWSH
  }

  # Destroy: remove the cert artifacts + Vault Agent template, restart the
  # agent. Idempotent. (No role service to restart -- the per-service
  # overlays own that.)
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${self.triggers.destroy_ssh_user}'
      $ips     = '${self.triggers.destroy_node_ips}' -split ','
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      foreach ($ip in $ips) {
        if (-not $ip) { continue }
        Write-Host "[ecosystem-tls destroy] $${ip}: removing TLS artifacts"
        ssh @sshOpts "$sshUser@$ip" "sudo rm -f /etc/vault-agent/60-template-kafka-tls.hcl /usr/local/sbin/kafka-tls-split.sh /etc/nexus-kafka/tls/bundle.pem /etc/nexus-kafka/tls/keystore.pem /etc/nexus-kafka/tls/truststore.pem /etc/nexus-kafka/client-ssl.properties /etc/ssl/certs/kafka-ca.pem; sudo systemctl restart nexus-vault-agent.service 2>/dev/null || true" 2>$null
      }
      exit 0
    PWSH
  }
}

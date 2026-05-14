/*
 * role-overlay-kafka-vault-agents.tf -- Phase 0.H.2
 *
 * Installs Vault Agent as a `nexus-vault-agent` systemd service on each of
 * the 6 kafka-node broker clones. Linear port of nexus-infra-swarm-nomad's
 * role-overlay-swarm-vault-agents.tf (0.E.2 pattern) to the Kafka tier.
 *
 * Each agent authenticates to vault-1 via its narrow AppRole (provisioned by
 * nexus-infra-vmware/terraform/envs/security/role-overlay-vault-agent-kafka-
 * approles.tf, which writes per-host JSON sidecars to
 * $HOME/.nexus/vault-agent-kafka-<host>.json on the build host).
 *
 * Cross-env coupling: reads the AppRole creds JSON sidecars. ERROR (not
 * WARN+skip) if absent -- a silent skip leaves terraform thinking the agent
 * was installed when it wasn't (the 0.E.2 swarm v1 bug). Operator order:
 *   1. nexus-infra-vmware: pwsh -File scripts/security.ps1 apply
 *      (creates the 6 kafka sidecars + the kafka-broker PKI role)
 *   2. nexus-infra-kafka:  pwsh -File scripts/kafka.ps1 apply
 *      (0.H.1 brings up the plaintext clusters; this file + role-overlay-
 *       kafka-tls.tf then flip to mTLS)
 *
 * Per-host resource pattern (for_each over a filtered map) so each agent is
 * independently `-target`-able for iteration.
 *
 * Vault Agent config: directory mode (`-config=/etc/vault-agent/`) merges
 * all *.hcl at startup. This file writes 00-base.hcl (auto_auth approle +
 * sink + vault address). role-overlay-kafka-tls.tf drops the PKI template
 * stanza as 60-template-kafka-tls.hcl without rewriting the base.
 *
 * Selective ops: var.enable_kafka_vault_agents (master) AND per-host
 *                var.enable_kafka_<hostname>_vault_agent.
 *
 * Reachability invariant: Vault Agent runs as root, binds no network ports
 * (sink "file" only). No firewall changes. SSH from the build host
 * unaffected.
 */

locals {
  kafka_vault_agent_specs = {
    "kafka-east-1" = { vm_ip = "192.168.70.21", cluster = "east", enabled = var.enable_kafka_east_1_vault_agent }
    "kafka-east-2" = { vm_ip = "192.168.70.22", cluster = "east", enabled = var.enable_kafka_east_2_vault_agent }
    "kafka-east-3" = { vm_ip = "192.168.70.23", cluster = "east", enabled = var.enable_kafka_east_3_vault_agent }
    "kafka-west-1" = { vm_ip = "192.168.70.24", cluster = "west", enabled = var.enable_kafka_west_1_vault_agent }
    "kafka-west-2" = { vm_ip = "192.168.70.25", cluster = "west", enabled = var.enable_kafka_west_2_vault_agent }
    "kafka-west-3" = { vm_ip = "192.168.70.26", cluster = "west", enabled = var.enable_kafka_west_3_vault_agent }
  }

  kafka_vault_agent_active = {
    for host, spec in local.kafka_vault_agent_specs : host => spec
    if var.enable_kafka_cluster && var.enable_kafka_vault_agents && spec.enabled
  }

  # Terraform's pathexpand() only handles `~`, NOT `$HOME`. Variable defaults
  # are `$HOME/.nexus/...` (matches the PowerShell-side convention used by
  # the nexus-infra-vmware security overlays), so substitute $HOME -> ~ before
  # expansion.
  kafka_va_creds_dir_expanded = pathexpand(replace(var.vault_agent_kafka_creds_dir, "$HOME", "~"))
  kafka_va_ca_bundle_expanded = pathexpand(replace(var.vault_pki_ca_bundle_path, "$HOME", "~"))
}

resource "null_resource" "kafka_vault_agent" {
  for_each = local.kafka_vault_agent_active

  triggers = {
    creds_file_path = "${local.kafka_va_creds_dir_expanded}/vault-agent-${each.key}.json"
    # Re-run when the security env rotates the secret-id (every apply does).
    creds_file_hash = filesha256("${local.kafka_va_creds_dir_expanded}/vault-agent-${each.key}.json")
    # Chain after the 0.H.1 bring-up so the cluster is plaintext-healthy
    # before we install the agent that 0.H.2 mTLS depends on.
    start_verify_id    = length(null_resource.kafka_broker_start_verify) > 0 ? null_resource.kafka_broker_start_verify[0].id : "disabled"
    vault_version      = var.vault_agent_version
    kafka_va_overlay_v = "1" # v1 = original. Systemd unit ships with RuntimeDirectory=nexus-vault-agent (the canonical /var/run tmpfs-wipe reboot-survival fix, per memory/feedback_systemd_runtime_directory_tmpfs.md).

    # Frozen for the destroy provisioner -- terraform restricts destroy
    # provisioners to `self`, `count.index`, `each.key`.
    destroy_vm_ip    = each.value.vm_ip
    destroy_ssh_user = var.kafka_node_user
  }

  depends_on = [null_resource.kafka_broker_start_verify]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName     = '${each.key}'
      $vmIp         = '${each.value.vm_ip}'
      $cluster      = '${each.value.cluster}'
      $vaultVersion = '${var.vault_agent_version}'
      $credsFile    = '${local.kafka_va_creds_dir_expanded}/vault-agent-${each.key}.json'
      $caBundlePath = '${local.kafka_va_ca_bundle_expanded}'
      $sshUser      = '${var.kafka_node_user}'

      # Pre-flight: AppRole creds JSON must exist (security env writes it).
      # ERROR (not WARN+skip) -- mirrors the 0.E.2 v2 fix.
      if (-not (Test-Path $credsFile)) {
        throw "[kafka-va $hostName] creds file $credsFile missing -- run nexus-infra-vmware/scripts/security.ps1 apply FIRST to provision the 6 kafka AppRole sidecars."
      }
      $creds     = Get-Content $credsFile | ConvertFrom-Json
      $roleId    = $creds.role_id
      $secretId  = $creds.secret_id
      $vaultAddr = $creds.vault_addr
      if (-not $roleId -or -not $secretId) {
        throw "[kafka-va $hostName] creds JSON missing role_id or secret_id"
      }

      # Pre-flight: CA bundle must exist (PKI root distributed to build host
      # at 0.D.2). The Vault Agent uses it to verify the vault server cert.
      if (-not (Test-Path $caBundlePath)) {
        throw "[kafka-va $hostName] CA bundle $caBundlePath missing -- run security env apply (PKI distribute) first."
      }

      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      # Step 1: probe -- already installed + active?
      $probe = (ssh @sshOpts "$sshUser@$vmIp" "test -x /usr/local/bin/vault && /usr/local/bin/vault version 2>/dev/null && systemctl is-active nexus-vault-agent.service 2>/dev/null" 2>&1 | Out-String).Trim()
      if ($probe -match "Vault v$vaultVersion" -and $probe -match '(?m)^active$') {
        Write-Host "[kafka-va $hostName] already installed at v$vaultVersion + service active; skipping."
        exit 0
      }

      Write-Host "[kafka-va $hostName] installing Vault Agent v$vaultVersion (cluster=$cluster)"

      # Step 2: install vault binary (skip if already at expected version).
      $installScript = @"
set -euo pipefail

# Step 2.0: ensure DNS resolution works before any outbound HTTP. The deb13
# baseline can land with an empty /etc/resolv.conf on fresh clones (dhcpcd at
# build time -> systemd-networkd at clone time, no systemd-resolved). Cluster
# ops use direct IPs so this only surfaces on the first outbound curl.
# nexus-gateway's dnsmasq is the canonical lab resolver at 192.168.70.1.
if ! getent hosts releases.hashicorp.com >/dev/null 2>&1; then
  echo "[kafka-va install] /etc/resolv.conf has no working resolver; pointing at nexus-gateway dnsmasq"
  echo "nameserver 192.168.70.1" | sudo tee /etc/resolv.conf > /dev/null
fi

if [ -x /usr/local/bin/vault ] && /usr/local/bin/vault version 2>/dev/null | grep -qF "Vault v$vaultVersion"; then
  echo "vault binary v$vaultVersion already installed"
else
  cd /tmp
  zip="vault_$${vaultVersion}_linux_amd64.zip"
  sums="vault_$${vaultVersion}_SHA256SUMS"
  curl -fsSL "https://releases.hashicorp.com/vault/$${vaultVersion}/`$zip"  -o "`$zip"
  curl -fsSL "https://releases.hashicorp.com/vault/$${vaultVersion}/`$sums" -o "`$sums"
  grep "`$zip" "`$sums" | sha256sum -c -
  unzip -o "`$zip"
  sudo install -m 755 -o root -g root vault /usr/local/bin/vault
  rm -f "`$zip" "`$sums" vault
  echo "vault binary v$vaultVersion installed"
fi

# Step 3: directories + ownership
sudo mkdir -p /etc/vault-agent /var/run/nexus-vault-agent /var/log/nexus-vault-agent
sudo chown root:root /etc/vault-agent
sudo chmod 0755 /etc/vault-agent
"@
      $installB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($installScript))
      $installOut = ssh @sshOpts "$sshUser@$vmIp" "echo '$installB64' | base64 -d | bash" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0) {
        Write-Host $installOut.Trim()
        throw "[kafka-va $hostName] vault binary install failed (rc=$LASTEXITCODE)"
      }
      Write-Host $installOut.Trim()

      # Step 4: stage role-id + secret-id + CA bundle
      $roleIdTmp   = New-TemporaryFile
      $secretIdTmp = New-TemporaryFile
      try {
        # Write the credentials WITHOUT a trailing newline -- Vault Agent reads
        # the entire file content as the credential value; a trailing newline
        # becomes part of the role-id/secret-id and breaks AppRole auth.
        [System.IO.File]::WriteAllText($roleIdTmp.FullName, $roleId)
        [System.IO.File]::WriteAllText($secretIdTmp.FullName, $secretId)

        scp @sshOpts $roleIdTmp.FullName "$${sshUser}@$${vmIp}:/tmp/role-id"
        scp @sshOpts $secretIdTmp.FullName "$${sshUser}@$${vmIp}:/tmp/secret-id"
        scp @sshOpts $caBundlePath "$${sshUser}@$${vmIp}:/tmp/ca-bundle.crt"

        $stageScript = @"
set -euo pipefail
sudo install -m 0400 -o root -g root /tmp/role-id      /etc/vault-agent/role-id
sudo install -m 0400 -o root -g root /tmp/secret-id    /etc/vault-agent/secret-id
sudo install -m 0644 -o root -g root /tmp/ca-bundle.crt /etc/vault-agent/ca-bundle.crt
sudo rm -f /tmp/role-id /tmp/secret-id /tmp/ca-bundle.crt
"@
        $stageB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($stageScript))
        $stageOut = ssh @sshOpts "$sshUser@$vmIp" "echo '$stageB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          Write-Host $stageOut.Trim()
          throw "[kafka-va $hostName] credential staging failed (rc=$LASTEXITCODE)"
        }
      } finally {
        Remove-Item $roleIdTmp.FullName -Force -ErrorAction SilentlyContinue
        Remove-Item $secretIdTmp.FullName -Force -ErrorAction SilentlyContinue
      }

      # Step 5: write 00-base.hcl + nexus-vault-agent.service
      $baseConfig = @"
# 00-base.hcl -- Phase 0.H.2. auto_auth (approle) + sink + vault address.
# role-overlay-kafka-tls.tf drops 60-template-kafka-tls.hcl in this dir to
# add the PKI cert template stanza without rewriting this file.

pid_file = "/var/run/nexus-vault-agent/agent.pid"

vault {
  address = "$vaultAddr"
  ca_cert = "/etc/vault-agent/ca-bundle.crt"
}

auto_auth {
  method "approle" {
    config = {
      role_id_file_path                   = "/etc/vault-agent/role-id"
      secret_id_file_path                 = "/etc/vault-agent/secret-id"
      remove_secret_id_file_after_reading = false
    }
  }
  sink "file" {
    config = {
      path = "/var/run/nexus-vault-agent/token"
      mode = 0640
    }
  }
}
"@

      $unitFile = @"
[Unit]
Description=Nexus Vault Agent (Phase 0.H.2 -- Kafka broker mTLS)
Documentation=https://developer.hashicorp.com/vault/docs/agent
Requires=network-online.target
After=network-online.target kafka-node-firstboot.service
ConditionFileIsExecutable=/usr/local/bin/vault

[Service]
Type=simple
User=root
Group=root
# RuntimeDirectory= -- systemd auto-creates /run/nexus-vault-agent (=
# /var/run/nexus-vault-agent) on every service start. Critical because
# /var/run is tmpfs: an install-time `mkdir` does NOT survive host reboots
# and the agent would crash-loop on "error creating file sink: no such file
# or directory". Per memory/feedback_systemd_runtime_directory_tmpfs.md.
RuntimeDirectory=nexus-vault-agent
RuntimeDirectoryMode=0755
LogsDirectory=nexus-vault-agent
LogsDirectoryMode=0755
ExecStart=/usr/local/bin/vault agent -config=/etc/vault-agent/
ExecReload=/bin/kill -HUP `$MAINPID
KillMode=process
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
StandardOutput=append:/var/log/nexus-vault-agent/agent.log
StandardError=append:/var/log/nexus-vault-agent/agent.log

[Install]
WantedBy=multi-user.target
"@

      $configB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($baseConfig))
      $unitB64   = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($unitFile))

      $finalScript = @"
set -euo pipefail
echo '$configB64' | base64 -d | sudo tee /etc/vault-agent/00-base.hcl > /dev/null
sudo chown root:root /etc/vault-agent/00-base.hcl
sudo chmod 0644 /etc/vault-agent/00-base.hcl

echo '$unitB64' | base64 -d | sudo tee /etc/systemd/system/nexus-vault-agent.service > /dev/null
sudo chown root:root /etc/systemd/system/nexus-vault-agent.service
sudo chmod 0644 /etc/systemd/system/nexus-vault-agent.service

sudo systemctl daemon-reload
sudo systemctl enable --now nexus-vault-agent.service
"@
      $finalB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($finalScript))
      $finalOut = ssh @sshOpts "$sshUser@$vmIp" "echo '$finalB64' | base64 -d | bash" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0) {
        Write-Host $finalOut.Trim()
        throw "[kafka-va $hostName] config/service setup failed (rc=$LASTEXITCODE)"
      }
      Write-Host $finalOut.Trim()

      # Step 6: verify service active + token sink populated
      Start-Sleep -Seconds 5
      $verifyDeadline = (Get-Date).AddSeconds(30)
      $serviceActive = $false
      while ((Get-Date) -lt $verifyDeadline) {
        $status = (ssh @sshOpts "$sshUser@$vmIp" "systemctl is-active nexus-vault-agent.service" 2>&1 | Out-String).Trim()
        if ($status -eq 'active') { $serviceActive = $true; break }
        Start-Sleep -Seconds 3
      }
      if (-not $serviceActive) {
        $journal = (ssh @sshOpts "$sshUser@$vmIp" "sudo journalctl -u nexus-vault-agent.service --no-pager -n 30" 2>&1 | Out-String)
        Write-Host $journal
        throw "[kafka-va $hostName] nexus-vault-agent.service failed to reach active within 30s"
      }
      Write-Host "[kafka-va $hostName] nexus-vault-agent.service active"

      # Token sink populated? (proves AppRole auth succeeded)
      $tokenCheck = (ssh @sshOpts "$sshUser@$vmIp" "sudo test -s /var/run/nexus-vault-agent/token && echo TOKEN_PRESENT" 2>&1 | Out-String).Trim()
      if ($tokenCheck -notmatch 'TOKEN_PRESENT') {
        $journal = (ssh @sshOpts "$sshUser@$vmIp" "sudo journalctl -u nexus-vault-agent.service --no-pager -n 30" 2>&1 | Out-String)
        Write-Host $journal
        throw "[kafka-va $hostName] AppRole login appears to have failed (token sink empty)"
      }
      Write-Host "[kafka-va $hostName] AppRole authenticated; token sink populated"
    PWSH
  }

  # Destroy: stop + disable + remove the agent. Idempotent. Only `self`,
  # `count.index`, `each.key` are reachable in a destroy provisioner -- vm_ip
  # + ssh_user are frozen into triggers above.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $vmIp     = '${self.triggers.destroy_vm_ip}'
      $sshUser  = '${self.triggers.destroy_ssh_user}'
      $sshOpts  = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      Write-Host "[kafka-va destroy] $${hostName}: stopping nexus-vault-agent + cleaning files"
      ssh @sshOpts "$sshUser@$vmIp" "sudo systemctl disable --now nexus-vault-agent.service 2>/dev/null; sudo rm -rf /etc/vault-agent /var/run/nexus-vault-agent /var/log/nexus-vault-agent /etc/systemd/system/nexus-vault-agent.service; sudo systemctl daemon-reload" 2>$null
      exit 0
    PWSH
  }
}

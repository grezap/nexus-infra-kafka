/*
 * role-overlay-kafka-acl-authorizer.tf -- Phase 0.H.7 -- Kafka ACL enforcement
 *
 * Enables the KRaft-native StandardAuthorizer on both clusters so the
 * `nexus acl kafka-east|kafka-west ...` verb (nexus-cli v0.6.7) actually
 * ENFORCES -- before this overlay the brokers carried no `authorizer.class.name`,
 * so kafka-acls.sh returned `SecurityDisabledException: No Authorizer is
 * configured on the broker` and every principal had implicit full access.
 *
 * Why a NEW overlay (not folded into role-overlay-kafka-tls.tf): ACL
 * enforcement is an independently-gated capability (`var.enable_kafka_acl_
 * authorizer`) layered ON TOP of the mTLS server.properties that kafka-tls
 * owns. This overlay APPENDS its stanza idempotently (sed-delete the prior
 * block, then `tee -a`) so a kafka-tls re-render followed by this overlay
 * re-running converges cleanly; ordering is guaranteed by `depends_on`.
 *
 * --- super.users (get this right or lock out the whole platform) -----------
 *
 * StandardAuthorizer is deny-by-default once `allow.everyone.if.no.acl.found
 * =false`. Every node that talks to a broker authenticates with its OWN
 * Vault-PKI client cert, and Kafka's default principal builder maps the cert
 * to `User:CN=<host>.kafka.nexus.lab` (single-RDN DN, DEFAULT mapping -- no
 * ssl.principal.mapping.rules set). super.users must therefore list EVERY
 * platform identity that connects to a broker, or that connection is denied:
 *
 *   - the 6 brokers          (inter-broker replication + the controller quorum;
 *                             a missing broker principal collapses the ISR)
 *   - the 9 ecosystem nodes  (Schema Registry, REST Proxy, Kafka Connect,
 *                             ksqlDB, MirrorMaker 2 -- all are Kafka CLIENTS;
 *                             omitting them breaks the running ecosystem)
 *
 * All 15 are listed on BOTH clusters (an ecosystem node may connect to either;
 * MM2 connects to both). Listing the full set on both is harmless -- a west
 * broker principal is simply never seen on east. Ordinary APPLICATION
 * principals (anything not in this list) stay deny-by-default, which is exactly
 * what makes `nexus acl <cluster> grant ...` a meaningful operation. See
 * nexus-cli ADR-0018.
 *
 * --- Rolling (NOT big-bang) restart ----------------------------------------
 *
 * Unlike the kafka-tls wire-format flip (which MUST be a parallel big-bang per
 * the consul/nomad lesson -- a half-PLAINTEXT/half-SSL quorum can't elect),
 * enabling an authorizer is NOT a wire-format change: the listeners stay SSL
 * throughout. So a ONE-AT-A-TIME rolling restart is correct and safer -- the
 * KRaft controller quorum keeps a leader (2 of 3 always up) the entire time.
 * Each cluster rolls followers first, the quorum leader last, waiting for the
 * restarted node to rejoin (lag 0) before moving on. (Live-validated on a
 * follower canary before the full roll -- nexus-cli v0.6.7 session.)
 *
 * Idempotency: re-applying with the authorizer already present is a no-op
 * (sed-delete removes the prior block, the appended block is byte-identical,
 * the restart still succeeds). Selective ops: var.enable_kafka_acl_authorizer.
 */

locals {
  # The FULL platform principal set -- all 15 tier nodes. Hardcoded (not derived
  # from the enabled-broker table) so super.users is always the complete
  # identity set even when a broker is temporarily toggled off: a disabled
  # broker that is later re-enabled must still be a super user the instant it
  # rejoins, and the ecosystem principals are never in the broker table at all.
  kafka_acl_super_principals = [
    "User:CN=kafka-east-1.kafka.nexus.lab",
    "User:CN=kafka-east-2.kafka.nexus.lab",
    "User:CN=kafka-east-3.kafka.nexus.lab",
    "User:CN=kafka-west-1.kafka.nexus.lab",
    "User:CN=kafka-west-2.kafka.nexus.lab",
    "User:CN=kafka-west-3.kafka.nexus.lab",
    "User:CN=schema-registry-1.kafka.nexus.lab",
    "User:CN=schema-registry-2.kafka.nexus.lab",
    "User:CN=kafka-connect-1.kafka.nexus.lab",
    "User:CN=kafka-connect-2.kafka.nexus.lab",
    "User:CN=ksqldb-1.kafka.nexus.lab",
    "User:CN=ksqldb-2.kafka.nexus.lab",
    "User:CN=kafka-rest-1.kafka.nexus.lab",
    "User:CN=mm2-1.kafka.nexus.lab",
    "User:CN=mm2-2.kafka.nexus.lab",
  ]

  # super.users separator in Kafka is the semicolon (commas are legal inside a
  # DN, so Kafka uses ';' between principals).
  kafka_acl_super_users = join(";", local.kafka_acl_super_principals)

  # The exact stanza appended to each broker's /etc/nexus-kafka/server.properties.
  # The sentinel comment line is what the idempotent sed-delete keys on.
  kafka_acl_block = join("\n", [
    "# --- Phase 0.H.7 ACL authorizer (nexus-cli v0.6.7) ---",
    "authorizer.class.name=org.apache.kafka.metadata.authorizer.StandardAuthorizer",
    "super.users=${local.kafka_acl_super_users}",
    "allow.everyone.if.no.acl.found=false",
  ])
}

resource "null_resource" "kafka_acl_authorizer" {
  count = var.enable_kafka_cluster && var.enable_kafka_tls && var.enable_kafka_acl_authorizer ? 1 : 0

  triggers = {
    # Re-run when the broker SET changes, when super.users changes, or on an
    # explicit version bump. NOT keyed on null_resource.kafka_tls.id (the
    # id-trigger-cascade anti-pattern -- ADR-0022): ordering is via depends_on.
    brokers      = jsonencode(local.kafka_enabled_brokers)
    super_users  = local.kafka_acl_super_users
    authorizer_v = "1" # v1 (0.H.7) = StandardAuthorizer + 15-principal super.users + allow.everyone.if.no.acl.found=false; rolling per-cluster restart.

    # Frozen for the destroy provisioner.
    destroy_broker_ips = join(",", [for b in local.kafka_enabled_brokers : "${b.cluster}:${b.node_id}:${b.vmnet11}:${b.vmnet10}"])
    destroy_ssh_user   = var.kafka_node_user
  }

  depends_on = [null_resource.kafka_tls]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser   = '${var.kafka_node_user}'
      $timeout   = ${var.kafka_cluster_timeout_minutes}
      $kafka     = '/opt/kafka/bin'
      $clientCfg = '/etc/nexus-kafka/client-ssl.properties'
      $sshOpts   = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $brokers = @'
${jsonencode(local.kafka_enabled_brokers)}
'@ | ConvertFrom-Json

      if ($brokers.Count -eq 0) {
        Write-Host "[kafka-acl] no enabled brokers -- nothing to do"
        exit 0
      }

      # The ACL stanza (single-quoted here-string -- literal). The leading
      # sentinel comment is what the idempotent sed-delete removes first.
      $aclBlock = @'
${local.kafka_acl_block}
'@
      $aclB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($aclBlock -replace "`r`n","`n")))

      # ─── Phase 1 (per-node, sequential, NO restart): append the stanza ──────
      foreach ($b in $brokers) {
        $hostName = "kafka-$($b.cluster)-$($b.node_id)"
        $ip       = $b.vmnet11
        Write-Host "[kafka-acl $hostName] appending StandardAuthorizer stanza to server.properties"
        # NOTE: literal path inlined (no bash `F=` var) -- a `\$F` in a PowerShell
        # here-string does NOT escape the `$` (backslash is not the PS escape
        # char; backtick is), so `$F` would PS-interpolate to empty and break
        # `cp`/`sed`. Inlining the path sidesteps the whole bash-$-in-PS-heredoc
        # trap (feedback_terraform_heredoc_powershell). Surfaced by the v0.6.7
        # cold-rebuild (the live enable used a separate bash path).
        $stage = @"
set -euo pipefail
sudo test -f /etc/nexus-kafka/server.properties.pre-acl || sudo cp /etc/nexus-kafka/server.properties /etc/nexus-kafka/server.properties.pre-acl
# Idempotent: strip any prior authorizer block + its scalar keys, then append.
sudo sed -i '/^# --- Phase 0.H.7 ACL authorizer/d;/^authorizer.class.name=/d;/^super.users=/d;/^allow.everyone.if.no.acl.found=/d' /etc/nexus-kafka/server.properties
echo '$aclB64' | base64 -d | sudo tee -a /etc/nexus-kafka/server.properties > /dev/null
sudo chown root:kafka /etc/nexus-kafka/server.properties
sudo chmod 0640 /etc/nexus-kafka/server.properties
echo STAGE_OK
"@
        $out = ($stage -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $out -notmatch 'STAGE_OK') {
          Write-Host $out.Trim()
          throw "[kafka-acl $hostName] failed to append authorizer stanza (rc=$LASTEXITCODE)"
        }
      }

      # ─── Phase 2 (per-cluster ROLLING restart, followers first) ─────────────
      $clusterNames = ($brokers | ForEach-Object { $_.cluster } | Select-Object -Unique)
      foreach ($cl in $clusterNames) {
        $clNodes  = @($brokers | Where-Object { $_.cluster -eq $cl })
        $probeIp  = $clNodes[0].vmnet11
        $probeBp  = $clNodes[0].vmnet10

        # Find the current quorum leader (restart it LAST to avoid an extra
        # election mid-roll). describe --replication marks one node 'Leader'.
        $repl = (ssh @sshOpts "$sshUser@$probeIp" "sudo $kafka/kafka-metadata-quorum.sh --bootstrap-server SSL://$${probeBp}:9092 --command-config $clientCfg describe --replication 2>/dev/null" 2>&1 | Out-String)
        $leaderId = $null
        foreach ($line in ($repl -split "`n")) {
          if ($line -match '^\s*(\d+)\s.*Leader\s*$') { $leaderId = [int]$Matches[1] }
        }
        $ordered = @($clNodes | Where-Object { $_.node_id -ne $leaderId }) + @($clNodes | Where-Object { $_.node_id -eq $leaderId })

        foreach ($node in $ordered) {
          $nIp = $node.vmnet11
          $nBp = $node.vmnet10
          $nm  = "kafka-$($node.cluster)-$($node.node_id)"
          Write-Host "[kafka-acl] rolling restart $nm$(if ($node.node_id -eq $leaderId) {' (quorum leader, last)'})"
          ssh @sshOpts "$sshUser@$nIp" "sudo systemctl reset-failed kafka.service 2>/dev/null; sudo systemctl restart kafka.service" 2>&1 | Out-Null
          if ($LASTEXITCODE -ne 0) { throw "[kafka-acl] $nm restart failed (rc=$LASTEXITCODE)" }

          # Wait for this node to rejoin the quorum (active + caught up, lag 0).
          $deadline = (Get-Date).AddMinutes($timeout)
          $ok = $false
          while ((Get-Date) -lt $deadline) {
            $active = (ssh @sshOpts "$sshUser@$nIp" "systemctl is-active kafka.service" 2>&1 | Out-String).Trim()
            if ($active -eq 'active') {
              $r = (ssh @sshOpts "$sshUser@$probeIp" "sudo $kafka/kafka-metadata-quorum.sh --bootstrap-server SSL://$${probeBp}:9092 --command-config $clientCfg describe --replication 2>/dev/null" 2>&1 | Out-String)
              $maxlag = ($r -split "`n" | Select-Object -Skip 1 | ForEach-Object { ($_ -split '\s+')[2] } | Where-Object { $_ -match '^\d+$' } | Measure-Object -Maximum).Maximum
              if (($r -match 'Leader') -and ($maxlag -eq 0)) { $ok = $true; break }
            }
            Start-Sleep -Seconds 6
          }
          if (-not $ok) {
            $j = (ssh @sshOpts "$sshUser@$nIp" "sudo journalctl -u kafka.service --no-pager -n 25" 2>&1 | Out-String)
            throw "[kafka-acl] $nm did not rejoin the quorum within $timeout min; journal:`n$j"
          }
          Write-Host "[kafka-acl] $nm rejoined the quorum (lag 0)"
        }

        # ─── Phase 3 (verify): kafka-acls --list now works (authorizer live) ──
        $listOut = (ssh @sshOpts "$sshUser@$probeIp" "sudo $kafka/kafka-acls.sh --bootstrap-server SSL://$${probeBp}:9092 --command-config $clientCfg --list 2>&1; echo RC=`$?" 2>&1 | Out-String)
        if ($listOut -match 'SecurityDisabledException' -or $listOut -notmatch 'RC=0') {
          throw "[kafka-acl] kafka-$cl : authorizer not active after roll -- kafka-acls --list failed:`n$listOut"
        }
        Write-Host "[kafka-acl] kafka-$cl : StandardAuthorizer ENFORCING (kafka-acls --list OK)"
      }

      Write-Host ""
      Write-Host "[kafka-acl] OK -- both KRaft clusters enforce StandardAuthorizer (super.users = 15 platform principals)"
    PWSH
  }

  # Destroy: strip the authorizer stanza + rolling restart so the cluster falls
  # back to the no-ACL (implicit-allow) state -- mirrors kafka-tls's destroy.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${self.triggers.destroy_ssh_user}'
      $recs    = '${self.triggers.destroy_broker_ips}' -split ','
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      foreach ($rec in $recs) {
        if (-not $rec) { continue }
        $parts = $rec -split ':'
        $ip = $parts[2]
        Write-Host "[kafka-acl destroy] $${ip}: removing authorizer stanza + restarting kafka.service"
        # literal path inlined -- see the create-provisioner note on the
        # \$F-in-PS-heredoc trap.
        $remote = @"
set -euo pipefail
sudo sed -i '/^# --- Phase 0.H.7 ACL authorizer/d;/^authorizer.class.name=/d;/^super.users=/d;/^allow.everyone.if.no.acl.found=/d' /etc/nexus-kafka/server.properties
sudo systemctl reset-failed kafka.service 2>/dev/null || true
sudo systemctl restart kafka.service
"@
        ($remote -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>$null
      }
      exit 0
    PWSH
  }
}

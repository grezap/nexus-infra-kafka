/*
 * role-overlay-nftables-backplane.tf -- push the kafka-node nftables ruleset
 * to every broker + `nft -f` for atomic replacement.
 *
 * Why a runtime overlay when the template already bakes
 * packer/kafka-node/files/nftables.conf:
 *   - A clone built from an OLDER kafka-node template still converges to the
 *     CURRENT ruleset (no template rebuild needed for a firewall tweak).
 *   - On a cold rebuild the baked file is already current, so this overlay is
 *     idempotent (push-identical-content + `nft -f` is a clean no-op).
 *   - Per memory/feedback_nftables_runtime_add_after_drop.md: patch the file
 *     + `nft -f` (atomic replace, also persistent) -- never runtime `nft add`
 *     (lands after the counter-drop, unreachable).
 *
 * The ruleset's `iifname "nic1" ip saddr 192.168.10.0/24 accept` line is what
 * makes KRaft work: controller quorum (9093) + inter-broker replication
 * (9092) flow over the VMnet10 backplane. Per
 * memory/feedback_cluster_template_nftables_backplane.md, without a VMnet10
 * accept rule "ping works, /dev/tcp blocked, cluster software stuck no-leader".
 *
 * SSH transit: LF-normalized plaintext piped to ssh stdin + `bash -s` with
 * `tr -d '\r'` as the first remote stage (memory/feedback_pwsh_ssh_stdin_cr_injection.md
 * + feedback_ssh_stage1_size_limit.md -- the ruleset is well under the 6 KB
 * argv cliff but stdin-pipe is the canonical robust transit anyway).
 */

locals {
  # Broker VMnet11 IPs (canon: vms.yaml lines 88-90). Only the brokers exist
  # in 0.H.1; the ecosystem IPs join this list in 0.H.3.
  kafka_broker_ips = compact([
    var.enable_kafka_east && var.enable_kafka_east_1 ? "192.168.70.21" : "",
    var.enable_kafka_east && var.enable_kafka_east_2 ? "192.168.70.22" : "",
    var.enable_kafka_east && var.enable_kafka_east_3 ? "192.168.70.23" : "",
    var.enable_kafka_west && var.enable_kafka_west_1 ? "192.168.70.24" : "",
    var.enable_kafka_west && var.enable_kafka_west_2 ? "192.168.70.25" : "",
    var.enable_kafka_west && var.enable_kafka_west_3 ? "192.168.70.26" : "",
  ])
  nftables_conf_path = abspath("${path.module}/../../../packer/kafka-node/files/nftables.conf")
}

resource "null_resource" "kafka_nftables_backplane" {
  count = var.enable_kafka_cluster && var.enable_nftables_backplane ? 1 : 0

  triggers = {
    east_1            = length(module.kafka_east_1) > 0 ? module.kafka_east_1[0].vm_name : "absent"
    east_2            = length(module.kafka_east_2) > 0 ? module.kafka_east_2[0].vm_name : "absent"
    east_3            = length(module.kafka_east_3) > 0 ? module.kafka_east_3[0].vm_name : "absent"
    west_1            = length(module.kafka_west_1) > 0 ? module.kafka_west_1[0].vm_name : "absent"
    west_2            = length(module.kafka_west_2) > 0 ? module.kafka_west_2[0].vm_name : "absent"
    west_3            = length(module.kafka_west_3) > 0 ? module.kafka_west_3[0].vm_name : "absent"
    nftables_conf_sha = filesha256(local.nftables_conf_path)
    overlay_v         = "1"
  }

  depends_on = [
    module.kafka_east_1, module.kafka_east_2, module.kafka_east_3,
    module.kafka_west_1, module.kafka_west_2, module.kafka_west_3,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ips     = @('${join("','", local.kafka_broker_ips)}')
      $user    = '${var.kafka_node_user}'
      $timeout = ${var.kafka_cluster_timeout_minutes}
      $confSrc = '${local.nftables_conf_path}'

      # LF-normalize the ruleset for stdin transit.
      $ruleset = (Get-Content -Raw $confSrc) -replace "`r`n", "`n"

      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      foreach ($ip in $ips) {
        # Wait for SSH + the firstboot marker (firstboot must have renamed the
        # NICs + set up the VMnet10 backplane before the ruleset's nic1 rule
        # means anything).
        Write-Host "[nftables] $${ip}: waiting for SSH + firstboot marker..."
        $deadline = (Get-Date).AddMinutes($timeout)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
          $probe = (ssh @sshOpts "$user@$ip" "test -f /var/lib/kafka-node-firstboot-done && echo READY" 2>&1 | Out-String).Trim()
          if ($probe -match 'READY') { $ready = $true; break }
          Start-Sleep -Seconds 15
        }
        if (-not $ready) { throw "[nftables] $${ip}: SSH + firstboot marker never ready after $timeout min" }

        Write-Host "[nftables] $${ip}: pushing ruleset + nft -f"
        # Pipe the LF-normalized ruleset to a remote command that strips any
        # residual CR, writes /etc/nftables.conf atomically, reloads, and
        # ensures the nftables unit is enabled. ssh runs the command string
        # with the piped ruleset on its stdin.
        $remote = "tr -d '\r' | sudo tee /etc/nftables.conf > /dev/null && sudo nft -f /etc/nftables.conf && sudo systemctl enable nftables --now && echo NFT_OK"
        $out = ($ruleset | ssh @sshOpts "$user@$ip" $remote 2>&1 | Out-String)
        if ($out -notmatch 'NFT_OK') {
          throw "[nftables] $${ip}: ruleset push/reload failed -- $out"
        }
        Write-Host "[nftables] $${ip}: ruleset applied"
      }

      Write-Host "[nftables] all $($ips.Count) broker(s) converged on the kafka-node ruleset"
    PWSH
  }
}

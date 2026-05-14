#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.H.5 smoke gate -- MirrorMaker 2 cross-cluster DR pair + the
  Phase 0.H exit gate.

.DESCRIPTION
  Verifies the 0.H.5 exit gate: mm2-1/mm2-2 run `connect-mirror-maker.sh` in
  dedicated mode (mm2-1 east->west, mm2-2 west->east), each holds a Vault-PKI
  keystore, talks to BOTH KRaft clusters over mTLS, and actively mirrors --
  proven by the `heartbeats` topic on each target cluster and a fresh
  produce->mirror->consume round-trip in both directions (the Phase 0.H
  exit gate: produce a record to kafka-east -> it appears on kafka-west).

  Scoped to the two 0.H.5 MM2 nodes -- the brokers + the 0.H.3/0.H.4
  ecosystem nodes are covered by their own gates.

  Probe robustness per memory/feedback_smoke_gate_probe_robustness.md:
  marker-token `-match` (not strict equality). Each check echoes
  [OK]/[FAIL]; exits 1 on any FAIL, 0 on all-green.

.PARAMETER Strict
  Fail on warnings. Default: false.

.NOTES
  Kafka CLI probes run ON an MM2 node via /opt/kafka/bin tools +
  /etc/nexus-kafka/client-ssl.properties (PEM client identity) -- the MM2
  nodes can reach BOTH clusters over the VMnet10 backplane.
#>

[CmdletBinding()]
param(
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

$user = 'nexusadmin'
# Canon: vms.yaml lines 85-86 (mm2-1/mm2-2).
$mm2Ips = @('192.168.70.85', '192.168.70.86')

# Bare VMnet10 bootstrap strings for the two KRaft clusters.
$eastBootstrap = '192.168.10.21:9092,192.168.10.22:9092,192.168.10.23:9092'
$westBootstrap = '192.168.10.24:9092,192.168.10.25:9092,192.168.10.26:9092'
$clientCfg     = '/etc/nexus-kafka/client-ssl.properties'

# Per-node flow facts. mm2-1 owns east->west; mm2-2 owns west->east.
$flow = @{
    '192.168.70.85' = @{ host = 'mm2-1'; src = 'east'; dst = 'west'; clustersArg = 'west'; srcBootstrap = $eastBootstrap; dstBootstrap = $westBootstrap; mirrorTopic = 'east.dr-gate-test' }
    '192.168.70.86' = @{ host = 'mm2-2'; src = 'west'; dst = 'east'; clustersArg = 'east'; srcBootstrap = $westBootstrap; dstBootstrap = $eastBootstrap; mirrorTopic = 'west.dr-gate-test' }
}

$sshOpts = @('-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')

$failures = @()
$warnings = @()

function Write-Section([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Test-Check {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Probe
    )
    try {
        $result = & $Probe
        if ($result) {
            Write-Host "[OK]   $Description" -ForegroundColor Green
            return $true
        } else {
            Write-Host "[FAIL] $Description" -ForegroundColor Red
            $script:failures += $Description
            return $false
        }
    } catch {
        Write-Host "[FAIL] $Description ($($_.Exception.Message))" -ForegroundColor Red
        $script:failures += "$Description ($($_.Exception.Message))"
        return $false
    }
}

function Invoke-RemoteCommand {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$Command
    )
    return (ssh @sshOpts "$user@$Ip" $Command 2>&1 | Out-String).Trim()
}

# ─── Section 1: per-node SSH reachability ─────────────────────────────────
Write-Section 'Per-node SSH reachability (MM2 nodes)'
foreach ($ip in $mm2Ips) {
    Test-Check -Description "$ip : SSH echo probe" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'echo nexus-smoke-marker'
        $out -match 'nexus-smoke-marker'
    } | Out-Null
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "FAIL early: $($failures.Count) reachability check(s) failed; skipping later sections." -ForegroundColor Red
    exit 1
}

# ─── Section 2: firstboot completion ──────────────────────────────────────
Write-Section 'kafka-node firstboot completion'
foreach ($ip in $mm2Ips) {
    Test-Check -Description "$ip : /var/lib/kafka-node-firstboot-done present" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'test -f /var/lib/kafka-node-firstboot-done && echo done'
        $out -match 'done'
    } | Out-Null
}

# ─── Section 3: hostname + node-identity mapping ──────────────────────────
Write-Section 'Hostname + node-identity mapping'
foreach ($ip in $mm2Ips) {
    $f = $flow[$ip]
    Test-Check -Description "$ip : hostname == $($f.host)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'hostname'
        $out -match "^$($f.host)$"
    } | Out-Null
    Test-Check -Description "$ip : node-identity.env role=mm2" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo cat /etc/nexus-kafka/node-identity.env'
        $out -match 'NEXUS_ROLE=mm2'
    } | Out-Null
}

# ─── Section 4: nexus-vault-agent.service ─────────────────────────────────
Write-Section 'nexus-vault-agent.service active + AppRole token sink populated'
foreach ($ip in $mm2Ips) {
    Test-Check -Description "$ip : nexus-vault-agent.service active" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active nexus-vault-agent.service'
        $out -match '^active$'
    } | Out-Null
    Test-Check -Description "$ip : Vault Agent token sink populated (AppRole auth OK)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /var/run/nexus-vault-agent/token && echo TOKEN_PRESENT'
        $out -match 'TOKEN_PRESENT'
    } | Out-Null
}

# ─── Section 5: PKI cert material ─────────────────────────────────────────
Write-Section 'PKI cert material rendered (keystore + truststore + CN)'
foreach ($ip in $mm2Ips) {
    $f  = $flow[$ip]
    $cn = "$($f.host).kafka.nexus.lab"
    Test-Check -Description "$ip : /etc/nexus-kafka/tls/keystore.pem present" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nexus-kafka/tls/keystore.pem && echo present'
        $out -match 'present'
    } | Out-Null
    Test-Check -Description "$ip : /etc/nexus-kafka/tls/truststore.pem present" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nexus-kafka/tls/truststore.pem && echo present'
        $out -match 'present'
    } | Out-Null
    Test-Check -Description "$ip : leaf cert CN == $cn" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo openssl x509 -in /etc/nexus-kafka/tls/keystore.pem -noout -subject 2>/dev/null'
        $out -match [regex]::Escape($cn)
    } | Out-Null
    Test-Check -Description "$ip : /etc/nexus-kafka/client-ssl.properties present" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nexus-kafka/client-ssl.properties && echo present'
        $out -match 'present'
    } | Out-Null
}

# ─── Section 6: role service + config + --clusters drop-in ────────────────
Write-Section 'mm2.service active + config + --clusters drop-in'
foreach ($ip in $mm2Ips) {
    $f = $flow[$ip]
    Test-Check -Description "$ip : mm2.service active" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active mm2.service'
        $out -match '^active$'
    } | Out-Null
    Test-Check -Description "$ip ($($f.host)) : mm2.properties enables ONLY the $($f.src)->$($f.dst) flow" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo cat /etc/nexus-kafka/mm2.properties'
        $enabledLine   = "$($f.src)->$($f.dst).enabled = true"
        $disabledLine  = "$($f.dst)->$($f.src).enabled = false"
        ($out -match [regex]::Escape($enabledLine)) -and ($out -match [regex]::Escape($disabledLine))
    } | Out-Null
    Test-Check -Description "$ip ($($f.host)) : ExecStart drop-in appends --clusters $($f.clustersArg)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo cat /etc/systemd/system/mm2.service.d/10-clusters.conf'
        $out -match [regex]::Escape("--clusters $($f.clustersArg)")
    } | Out-Null
    Test-Check -Description "$ip ($($f.host)) : mm2.properties has per-cluster mTLS for east + west" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo cat /etc/nexus-kafka/mm2.properties'
        ($out -match 'east\.security\.protocol = SSL') -and ($out -match 'west\.security\.protocol = SSL') -and ($out -match 'east\.ssl\.keystore\.type = PEM')
    } | Out-Null
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "FAIL early: $($failures.Count) pre-functional check(s) failed; skipping functional probes." -ForegroundColor Red
    exit 1
}

# ─── Section 7: MM2 journal sanity ────────────────────────────────────────
Write-Section 'MM2 journal sanity (connectors started, no TLS/auth errors)'
foreach ($ip in $mm2Ips) {
    $f = $flow[$ip]
    Test-Check -Description "$ip ($($f.host)) : journal mentions an MM2 connector (dedicated-mode flow started)" -Probe {
        # MirrorSourceConnector floods the journal tail on a busy cluster (an
        # offset-reset line per mirrored partition); MirrorHeartbeatConnector's
        # one-shot startup line can fall out of the -n 400 window. Section 8's
        # heartbeats-topic check already proves the HeartbeatConnector ran, so
        # require ANY MM2 connector class here.
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo journalctl -u mm2.service --no-pager -n 400'
        $out -match 'Mirror(Source|Heartbeat|Checkpoint)Connector'
    } | Out-Null
    Test-Check -Description "$ip ($($f.host)) : journal has no SSLHandshakeException / Failed authentication" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo journalctl -u mm2.service --no-pager -n 400'
        -not (($out -match 'SSLHandshakeException') -or ($out -match 'Failed authentication'))
    } | Out-Null
}

# ─── Section 8: cross-cluster mirroring -- heartbeats + internal topics ───
# The kafka CLI tools run under `sudo`: /etc/nexus-kafka is 0750 root:kafka,
# so nexusadmin cannot traverse it to read client-ssl.properties / the
# keystore (the consul.d 0750-traverse lesson, Kafka edition).
Write-Section 'Cross-cluster mirroring (heartbeats + MM2 internal topics on the target)'
foreach ($ip in $mm2Ips) {
    $f = $flow[$ip]
    Test-Check -Description "$($f.host) : heartbeats topic live on the $($f.dst) cluster" -Probe {
        $cmd = "sudo /opt/kafka/bin/kafka-topics.sh --bootstrap-server $($f.dstBootstrap) --command-config $clientCfg --list 2>/dev/null"
        $out = Invoke-RemoteCommand -Ip $ip -Command $cmd
        $out -match '(?m)^heartbeats\r?$'
    } | Out-Null
    Test-Check -Description "$($f.host) : MM2 internal topics (mm2-{offsets,configs,status}.$($f.src).internal) on $($f.dst)" -Probe {
        $cmd = "sudo /opt/kafka/bin/kafka-topics.sh --bootstrap-server $($f.dstBootstrap) --command-config $clientCfg --list 2>/dev/null"
        $out = Invoke-RemoteCommand -Ip $ip -Command $cmd
        ($out -match "mm2-offsets\.$($f.src)\.internal") -and ($out -match "mm2-configs\.$($f.src)\.internal") -and ($out -match "mm2-status\.$($f.src)\.internal")
    } | Out-Null
}

# ─── Section 9: Phase 0.H exit gate -- produce -> mirror -> consume ───────
Write-Section 'Phase 0.H EXIT GATE -- produce -> mirror -> consume (both directions)'
foreach ($ip in $mm2Ips) {
    $f = $flow[$ip]
    Test-Check -Description "$($f.host) : record produced to $($f.src)/dr-gate-test appears on $($f.dst)/$($f.mirrorTopic)" -Probe {
        $token = "smoke-dr-token-$($f.host)-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"

        # Topic create -- tolerate an existing topic (the overlay already
        # created it; this keeps the gate independently re-runnable). kafka
        # CLI under `sudo` -- the /etc/nexus-kafka 0750-traverse rule.
        $createCmd = "sudo /opt/kafka/bin/kafka-topics.sh --bootstrap-server $($f.srcBootstrap) --command-config $clientCfg --create --topic dr-gate-test --partitions 3 --replication-factor 3 2>&1 | grep -qE 'Created topic|already exists' && echo TOPIC_READY || echo TOPIC_FAIL"
        $createOut = Invoke-RemoteCommand -Ip $ip -Command $createCmd
        if ($createOut -notmatch 'TOPIC_READY') { return $false }

        # Produce a fresh token to the source cluster.
        $produceCmd = "echo '$token' | sudo /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server $($f.srcBootstrap) --producer.config $clientCfg --topic dr-gate-test && echo PRODUCE_OK"
        $produceOut = Invoke-RemoteCommand -Ip $ip -Command $produceCmd
        if ($produceOut -notmatch 'PRODUCE_OK') { return $false }

        # Consume the mirrored topic on the target cluster -- retry until the
        # fresh token shows up (MM2 discovers + mirrors within ~10-20s).
        $consumeCmd = "sudo /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server $($f.dstBootstrap) --consumer.config $clientCfg --topic $($f.mirrorTopic) --from-beginning --timeout-ms 30000 2>/dev/null"
        $deadline = (Get-Date).AddMinutes(3)
        while ((Get-Date) -lt $deadline) {
            $consumeOut = Invoke-RemoteCommand -Ip $ip -Command $consumeCmd
            if ($consumeOut -match [regex]::Escape($token)) { return $true }
            Start-Sleep -Seconds 5
        }
        return $false
    } | Out-Null
}

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "ALL 0.H.5 SMOKE CHECKS PASSED" -ForegroundColor Green
    Write-Host "Exit gate met: MirrorMaker 2 DR pair live (mm2-1 east->west, mm2-2" -ForegroundColor Green
    Write-Host "west->east) -- Vault-PKI keystores, per-cluster mTLS, heartbeats +" -ForegroundColor Green
    Write-Host "internal topics on both targets, and a fresh produce->mirror->consume" -ForegroundColor Green
    Write-Host "round-trip verified in BOTH directions. Phase 0.H exit gate cleared." -ForegroundColor Green
    if ($warnings.Count -gt 0 -and $Strict) {
        Write-Host "Warnings (Strict mode): $($warnings.Count)" -ForegroundColor Yellow
        $warnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
        exit 1
    }
    exit 0
} else {
    Write-Host "FAILED: $($failures.Count) check(s)" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

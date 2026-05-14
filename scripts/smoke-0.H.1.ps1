#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.H.1 smoke gate -- two 3-node KRaft clusters bring-up.

.DESCRIPTION
  Verifies the 0.H.1 exit gate: kafka-east + kafka-west each elect a KRaft
  controller quorum and pass a replication-factor-3 produce/consume
  round-trip.

  Probe robustness per memory/feedback_smoke_gate_probe_robustness.md:
  marker-token `-match` (not strict equality) to tolerate sudo's "unable
  to resolve host" stderr noise. Each check echoes [OK]/[FAIL]; exits 1 on
  any FAIL, 0 on all-green.

  Ordered cheapest-first: SSH reachability -> firstboot -> hostname/identity
  -> kafka.service state -> KRaft quorum -> RF=3 round-trip. Failing early
  on a dead node short-circuits the slower cluster-shape probes.

.PARAMETER Strict
  Fail on warnings. Default: false.

.NOTES
  No external dependencies beyond ssh + the build host's ssh-agent + the
  canonical lab SSH key. Brokers run PLAINTEXT on the VMnet10 backplane in
  0.H.1; 0.H.2 adds mTLS.
#>

[CmdletBinding()]
param(
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

$user = 'nexusadmin'
# Canon: vms.yaml lines 88-90.
$eastIps = @('192.168.70.21', '192.168.70.22', '192.168.70.23')
$westIps = @('192.168.70.24', '192.168.70.25', '192.168.70.26')
$allIps  = $eastIps + $westIps

$sshOpts = @('-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')
$kafkaBin = '/opt/kafka/bin'

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
Write-Section 'Per-node SSH reachability'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : SSH echo probe" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'echo nexus-smoke-marker'
        $out -match 'nexus-smoke-marker'
    } | Out-Null
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "FAIL early: $($failures.Count) reachability check(s) failed; skipping cluster probes." -ForegroundColor Red
    exit 1
}

# ─── Section 2: firstboot completion ──────────────────────────────────────
Write-Section 'kafka-node firstboot completion'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : /var/lib/kafka-node-firstboot-done present" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'test -f /var/lib/kafka-node-firstboot-done && echo done'
        $out -match 'done'
    } | Out-Null
}

# ─── Section 3: hostname + node-identity mapping ──────────────────────────
Write-Section 'Hostname + node-identity mapping (canonical IPs -> identity)'
$expected = @{
    '192.168.70.21' = @{ host = 'kafka-east-1'; cluster = 'east'; node_id = '1' }
    '192.168.70.22' = @{ host = 'kafka-east-2'; cluster = 'east'; node_id = '2' }
    '192.168.70.23' = @{ host = 'kafka-east-3'; cluster = 'east'; node_id = '3' }
    '192.168.70.24' = @{ host = 'kafka-west-1'; cluster = 'west'; node_id = '1' }
    '192.168.70.25' = @{ host = 'kafka-west-2'; cluster = 'west'; node_id = '2' }
    '192.168.70.26' = @{ host = 'kafka-west-3'; cluster = 'west'; node_id = '3' }
}
foreach ($ip in $allIps) {
    $e = $expected[$ip]
    Test-Check -Description "$ip : hostname == $($e.host)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'hostname'
        $out -match "^$($e.host)$"
    } | Out-Null
    Test-Check -Description "$ip : node-identity.env role=broker cluster=$($e.cluster) node_id=$($e.node_id)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo cat /etc/nexus-kafka/node-identity.env'
        ($out -match 'NEXUS_ROLE=broker') -and ($out -match "NEXUS_CLUSTER=$($e.cluster)") -and ($out -match "NEXUS_NODE_ID=$($e.node_id)")
    } | Out-Null
}

# ─── Section 4: kafka.service state ───────────────────────────────────────
Write-Section 'kafka.service active on every broker'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : kafka.service active" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active kafka.service'
        $out -match '^active$'
    } | Out-Null
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "FAIL early: $($failures.Count) service-state check(s) failed; skipping KRaft probes." -ForegroundColor Red
    exit 1
}

# ─── Section 5: KRaft quorum + RF=3 round-trip (the 0.H.1 exit gate) ──────
Write-Section 'KRaft quorum + RF=3 round-trip (0.H.1 exit gate)'
$clusters = @(
    @{ name = 'east'; probeIp = $eastIps[0] }
    @{ name = 'west'; probeIp = $westIps[0] }
)
foreach ($c in $clusters) {
    $probeIp = $c.probeIp

    Test-Check -Description "kafka-$($c.name) : KRaft metadata quorum has a leader" -Probe {
        $out = Invoke-RemoteCommand -Ip $probeIp -Command "$kafkaBin/kafka-metadata-quorum.sh --bootstrap-server localhost:9092 describe --status 2>/dev/null"
        $out -match 'LeaderId:\s*\d+'
    } | Out-Null

    Test-Check -Description "kafka-$($c.name) : KRaft quorum has 3 current voters" -Probe {
        $out = Invoke-RemoteCommand -Ip $probeIp -Command "$kafkaBin/kafka-metadata-quorum.sh --bootstrap-server localhost:9092 describe --status 2>/dev/null"
        # CurrentVoters line lists 3 voter ids.
        if ($out -match 'CurrentVoters:\s*\[([^\]]*)\]') {
            $voters = ($Matches[1] -split ',').Where({ $_.Trim() -ne '' })
            return $voters.Count -eq 3
        }
        return $false
    } | Out-Null

    Test-Check -Description "kafka-$($c.name) : RF=3 produce/consume round-trip" -Probe {
        $token = "smoke-0H1-$($c.name)-$(Get-Random)"
        $topic = "nexus-smoke-0h1-$($c.name)"
        $rt = "set -e; " +
              "$kafkaBin/kafka-topics.sh --bootstrap-server localhost:9092 --create --if-not-exists --topic $topic --partitions 3 --replication-factor 3; " +
              "echo '$token' | $kafkaBin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic $topic; " +
              "$kafkaBin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic $topic --from-beginning --timeout-ms 15000 2>/dev/null"
        $out = Invoke-RemoteCommand -Ip $probeIp -Command $rt
        $out -match [regex]::Escape($token)
    } | Out-Null

    Test-Check -Description "kafka-$($c.name) : describe-topic shows RF=3 on all partitions" -Probe {
        $topic = "nexus-smoke-0h1-$($c.name)"
        $out = Invoke-RemoteCommand -Ip $probeIp -Command "$kafkaBin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic $topic 2>/dev/null"
        # 3 partition lines, each "ReplicationFactor: 3" in the summary line + 3 replicas listed.
        ($out -match 'ReplicationFactor:\s*3') -and (($out -split "`n").Where({ $_ -match 'Partition:\s*\d' }).Count -eq 3)
    } | Out-Null
}

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "ALL 0.H.1 SMOKE CHECKS PASSED" -ForegroundColor Green
    Write-Host "Exit gate met: kafka-east + kafka-west each have a KRaft controller quorum + RF=3 round-trip." -ForegroundColor Green
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

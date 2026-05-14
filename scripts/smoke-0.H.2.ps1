#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.H.2 smoke gate -- Kafka broker mutual TLS.

.DESCRIPTION
  Verifies the 0.H.2 exit gate: both KRaft clusters (kafka-east + kafka-west)
  run on mutual TLS -- per-node Vault PKI leaf certs, SSL on the client +
  controller listeners, ssl.client.auth=required everywhere -- and each
  cluster still elects a controller quorum and passes an RF=3 produce/consume
  round-trip OVER mTLS.

  Supersedes smoke-0.H.1.ps1's KRaft checks: after 0.H.2 the brokers are
  SSL-only, so the PLAINTEXT-bootstrap probes in the 0.H.1 gate no longer
  apply. This gate re-runs the protocol-agnostic checks (reachability,
  firstboot, identity, service-active) and replaces the cluster-shape probes
  with their mTLS equivalents, plus the 0.H.2-specific TLS material checks.

  Probe robustness per memory/feedback_smoke_gate_probe_robustness.md:
  marker-token `-match` (not strict equality) to tolerate sudo's "unable to
  resolve host" stderr noise. Each check echoes [OK]/[FAIL]; exits 1 on any
  FAIL, 0 on all-green.

  Ordered cheapest-first: reachability -> firstboot -> identity -> vault-agent
  -> TLS material -> server.properties -> kafka.service -> SSL listener ->
  KRaft quorum over mTLS -> RF=3 round-trip over mTLS.

.PARAMETER Strict
  Fail on warnings. Default: false.

.NOTES
  No external dependencies beyond ssh + the build host's ssh-agent + the
  canonical lab SSH key. The kafka CLI tools are run on the broker via sudo
  (keystore.pem is 0640 root:kafka) pointing --command-config at
  /etc/nexus-kafka/client-ssl.properties.
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

$sshOpts   = @('-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')
$kafkaBin  = '/opt/kafka/bin'
$clientCfg = '/etc/nexus-kafka/client-ssl.properties'

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
    Write-Host "FAIL early: $($failures.Count) reachability check(s) failed; skipping later sections." -ForegroundColor Red
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

# ─── Section 4: nexus-vault-agent.service ─────────────────────────────────
Write-Section 'nexus-vault-agent.service active + AppRole token sink populated'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : nexus-vault-agent.service active" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active nexus-vault-agent.service'
        $out -match '^active$'
    } | Out-Null
    Test-Check -Description "$ip : Vault Agent token sink populated (AppRole auth OK)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /var/run/nexus-vault-agent/token && echo TOKEN_PRESENT'
        $out -match 'TOKEN_PRESENT'
    } | Out-Null
}

# ─── Section 5: mTLS cert material ────────────────────────────────────────
Write-Section 'PKI cert material rendered (keystore + truststore + CN)'
foreach ($ip in $allIps) {
    $e = $expected[$ip]
    $cn = "$($e.host).kafka.nexus.lab"
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
}

# ─── Section 6: server.properties is mTLS ─────────────────────────────────
Write-Section 'server.properties flipped to mutual TLS'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : listeners use SSL (SSL://0.0.0.0:9092)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo grep -E '^listeners=' /etc/nexus-kafka/server.properties"
        $out -match 'SSL://0\.0\.0\.0:9092'
    } | Out-Null
    Test-Check -Description "$ip : no PLAINTEXT token left in server.properties" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo grep -c PLAINTEXT /etc/nexus-kafka/server.properties || true"
        $out -match '^0$'
    } | Out-Null
    Test-Check -Description "$ip : ssl.client.auth=required (mutual TLS)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "sudo grep -E '^ssl.client.auth=' /etc/nexus-kafka/server.properties"
        $out -match 'ssl\.client\.auth=required'
    } | Out-Null
}

# ─── Section 7: kafka.service state ───────────────────────────────────────
Write-Section 'kafka.service active on every broker'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : kafka.service active" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active kafka.service'
        $out -match '^active$'
    } | Out-Null
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "FAIL early: $($failures.Count) pre-cluster check(s) failed; skipping KRaft probes." -ForegroundColor Red
    exit 1
}

# ─── Section 8: SSL listener presents a cert on 9092 ──────────────────────
Write-Section 'SSL listener on :9092 presents a server certificate'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : openssl s_client handshake against localhost:9092 yields a cert" -Probe {
        # ssl.client.auth=required means the handshake ultimately fails without
        # a client cert, but the server still presents its certificate first --
        # which is enough to prove :9092 speaks TLS, not PLAINTEXT.
        $out = Invoke-RemoteCommand -Ip $ip -Command 'echo | timeout 10 openssl s_client -connect localhost:9092 2>&1'
        $out -match 'BEGIN CERTIFICATE'
    } | Out-Null
}

# ─── Section 9: KRaft quorum + RF=3 round-trip over mTLS ──────────────────
Write-Section 'KRaft quorum + RF=3 round-trip over mTLS (0.H.2 exit gate)'
$clusters = @(
    @{ name = 'east'; probeIp = $eastIps[0] }
    @{ name = 'west'; probeIp = $westIps[0] }
)
foreach ($c in $clusters) {
    $probeIp = $c.probeIp

    Test-Check -Description "kafka-$($c.name) : KRaft metadata quorum has a leader (over mTLS)" -Probe {
        $out = Invoke-RemoteCommand -Ip $probeIp -Command "sudo $kafkaBin/kafka-metadata-quorum.sh --bootstrap-server localhost:9092 --command-config $clientCfg describe --status 2>/dev/null"
        $out -match 'LeaderId:\s*\d+'
    } | Out-Null

    Test-Check -Description "kafka-$($c.name) : KRaft quorum has 3 current voters (over mTLS)" -Probe {
        $out = Invoke-RemoteCommand -Ip $probeIp -Command "sudo $kafkaBin/kafka-metadata-quorum.sh --bootstrap-server localhost:9092 --command-config $clientCfg describe --status 2>/dev/null"
        if ($out -match 'CurrentVoters:\s*\[([^\]]*)\]') {
            $voters = ($Matches[1] -split ',').Where({ $_.Trim() -ne '' })
            return $voters.Count -eq 3
        }
        return $false
    } | Out-Null

    Test-Check -Description "kafka-$($c.name) : RF=3 produce/consume round-trip over mTLS" -Probe {
        $token = "smoke-0H2-$($c.name)-$(Get-Random)"
        $topic = "nexus-smoke-0h2-$($c.name)"
        $rt = "set -e; " +
              "sudo $kafkaBin/kafka-topics.sh --bootstrap-server localhost:9092 --command-config $clientCfg --create --if-not-exists --topic $topic --partitions 3 --replication-factor 3; " +
              "echo '$token' | sudo $kafkaBin/kafka-console-producer.sh --bootstrap-server localhost:9092 --producer.config $clientCfg --topic $topic; " +
              "sudo $kafkaBin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --consumer.config $clientCfg --topic $topic --from-beginning --timeout-ms 15000 2>/dev/null"
        $out = Invoke-RemoteCommand -Ip $probeIp -Command $rt
        $out -match [regex]::Escape($token)
    } | Out-Null

    Test-Check -Description "kafka-$($c.name) : describe-topic shows RF=3 on all partitions (over mTLS)" -Probe {
        $topic = "nexus-smoke-0h2-$($c.name)"
        $out = Invoke-RemoteCommand -Ip $probeIp -Command "sudo $kafkaBin/kafka-topics.sh --bootstrap-server localhost:9092 --command-config $clientCfg --describe --topic $topic 2>/dev/null"
        ($out -match 'ReplicationFactor:\s*3') -and (($out -split "`n").Where({ $_ -match 'Partition:\s*\d' }).Count -eq 3)
    } | Out-Null
}

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "ALL 0.H.2 SMOKE CHECKS PASSED" -ForegroundColor Green
    Write-Host "Exit gate met: kafka-east + kafka-west run on mutual TLS -- per-node Vault PKI" -ForegroundColor Green
    Write-Host "leaf certs, SSL client + controller listeners, ssl.client.auth=required," -ForegroundColor Green
    Write-Host "KRaft quorum + RF=3 round-trip both verified over mTLS." -ForegroundColor Green
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

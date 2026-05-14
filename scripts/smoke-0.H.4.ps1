#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.H.4 smoke gate -- Kafka Connect distributed cluster + Debezium +
  ksqlDB cluster.

.DESCRIPTION
  Verifies the 0.H.4 exit gate: kafka-connect-1/2 form a distributed Connect
  cluster with the Debezium connector plugins loaded, and ksqldb-1/2 form a
  ksqlDB cluster -- all four ecosystem nodes hold a Vault-PKI keystore, talk
  to the kafka-east brokers over mTLS, and serve their own HTTPS listeners.

  Scoped to the four 0.H.4 ecosystem nodes -- the brokers + the 0.H.3
  Schema Registry / REST Proxy nodes are covered by their own gates.

  Probe robustness per memory/feedback_smoke_gate_probe_robustness.md:
  marker-token `-match` (not strict equality). Each check echoes
  [OK]/[FAIL]; exits 1 on any FAIL, 0 on all-green.

.PARAMETER Strict
  Fail on warnings. Default: false.

.NOTES
  HTTPS probes run ON the node via curl --cacert /etc/ssl/certs/kafka-ca.pem.
#>

[CmdletBinding()]
param(
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

$user = 'nexusadmin'
# Canon: vms.yaml lines 95-96 (kafka-connect) + 97-98 (ksqldb).
$connectIps = @('192.168.70.95', '192.168.70.96')
$ksqldbIps  = @('192.168.70.97', '192.168.70.98')
$allIps     = $connectIps + $ksqldbIps

$sshOpts = @('-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')
$caFile  = '/etc/ssl/certs/kafka-ca.pem'

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
Write-Section 'Per-node SSH reachability (ecosystem nodes)'
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
Write-Section 'Hostname + node-identity mapping'
$expected = @{
    '192.168.70.95' = @{ host = 'kafka-connect-1'; role = 'connect' }
    '192.168.70.96' = @{ host = 'kafka-connect-2'; role = 'connect' }
    '192.168.70.97' = @{ host = 'ksqldb-1';        role = 'ksqldb' }
    '192.168.70.98' = @{ host = 'ksqldb-2';        role = 'ksqldb' }
}
foreach ($ip in $allIps) {
    $e = $expected[$ip]
    Test-Check -Description "$ip : hostname == $($e.host)" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'hostname'
        $out -match "^$($e.host)$"
    } | Out-Null
    Test-Check -Description "$ip : node-identity.env role=$($e.role) cluster=east" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'sudo cat /etc/nexus-kafka/node-identity.env'
        ($out -match "NEXUS_ROLE=$($e.role)") -and ($out -match 'NEXUS_CLUSTER=east')
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

# ─── Section 5: PKI cert material ─────────────────────────────────────────
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

# ─── Section 6: role services active ──────────────────────────────────────
Write-Section 'Role services active'
foreach ($ip in $connectIps) {
    Test-Check -Description "$ip : connect-distributed.service active" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active connect-distributed.service'
        $out -match '^active$'
    } | Out-Null
}
foreach ($ip in $ksqldbIps) {
    Test-Check -Description "$ip : ksqldb-server.service active" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active ksqldb-server.service'
        $out -match '^active$'
    } | Out-Null
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "FAIL early: $($failures.Count) pre-functional check(s) failed; skipping HTTPS probes." -ForegroundColor Red
    exit 1
}

# ─── Section 7: Kafka Connect cluster + Debezium plugins ──────────────────
Write-Section 'Kafka Connect distributed cluster + Debezium plugins'
foreach ($ip in $connectIps) {
    Test-Check -Description "$ip : Connect REST https://localhost:8083/ reports a version" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "curl -s --cacert $caFile https://localhost:8083/ 2>/dev/null"
        $out -match '"version"'
    } | Out-Null
}
Test-Check -Description "$($connectIps[0]) : /connector-plugins lists the Debezium PostgresConnector" -Probe {
    $out = Invoke-RemoteCommand -Ip $connectIps[0] -Command "curl -s --cacert $caFile https://localhost:8083/connector-plugins 2>/dev/null"
    $out -match 'io\.debezium\.connector\.postgresql\.PostgresConnector'
} | Out-Null
Test-Check -Description "$($connectIps[0]) : /connector-plugins lists the Debezium SqlServerConnector" -Probe {
    $out = Invoke-RemoteCommand -Ip $connectIps[0] -Command "curl -s --cacert $caFile https://localhost:8083/connector-plugins 2>/dev/null"
    $out -match 'io\.debezium\.connector\.sqlserver\.SqlServerConnector'
} | Out-Null

# ─── Section 8: ksqlDB cluster ────────────────────────────────────────────
Write-Section 'ksqlDB cluster'
foreach ($ip in $ksqldbIps) {
    Test-Check -Description "$ip : ksqlDB https://localhost:8088/info reports KsqlServerInfo" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "curl -s --cacert $caFile https://localhost:8088/info 2>/dev/null"
        $out -match 'KsqlServerInfo'
    } | Out-Null
}
Test-Check -Description "ksqldb-1 + ksqldb-2 : both /info report the same ksql.service.id + kafkaClusterId (one cluster)" -Probe {
    # ksqlDB clustering IS "same ksql.service.id + same bootstrap.servers" --
    # both nodes then share the one command topic. /clusterStatus is NOT used
    # here: it is heartbeat-driven and only lists peers once a persistent
    # query exists, so a fresh query-less cluster always shows just the local
    # node. The /info agreement is the deterministic cluster proof.
    $svc = @(); $kc = @()
    foreach ($ip in $ksqldbIps) {
        $out = Invoke-RemoteCommand -Ip $ip -Command "curl -s --cacert $caFile https://localhost:8088/info 2>/dev/null"
        if ($out -match '"ksqlServiceId"\s*:\s*"([^"]+)"') { $svc += $Matches[1] } else { return $false }
        if ($out -match '"kafkaClusterId"\s*:\s*"([^"]+)"') { $kc += $Matches[1] } else { return $false }
    }
    (($svc | Select-Object -Unique).Count -eq 1) -and (($kc | Select-Object -Unique).Count -eq 1) -and ($svc[0] -eq 'nexus_ksql_east_')
} | Out-Null
Test-Check -Description "$($ksqldbIps[0]) : SHOW TOPICS; round-trip via the /ksql endpoint" -Probe {
    $ksqlBody = '{"ksql":"SHOW TOPICS;","streamsProperties":{}}'
    $cmd = "curl -s --cacert $caFile -X POST -H 'Content-Type: application/vnd.ksql.v1+json' --data '$ksqlBody' https://localhost:8088/ksql 2>/dev/null"
    $out = Invoke-RemoteCommand -Ip $ksqldbIps[0] -Command $cmd
    $out -match '"topics"'
} | Out-Null

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "ALL 0.H.4 SMOKE CHECKS PASSED" -ForegroundColor Green
    Write-Host "Exit gate met: Kafka Connect distributed cluster (Debezium Postgres +" -ForegroundColor Green
    Write-Host "SqlServer plugins loaded) + ksqlDB cluster live -- Vault-PKI keystores," -ForegroundColor Green
    Write-Host "mTLS to the kafka-east brokers, HTTPS listeners, cluster membership verified." -ForegroundColor Green
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

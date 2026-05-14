#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.H.3 smoke gate -- Schema Registry HA pair + Confluent REST Proxy.

.DESCRIPTION
  Verifies the 0.H.3 exit gate: schema-registry-1/2 form a live HA pair and
  kafka-rest-1 is live -- all three ecosystem nodes hold a Vault-PKI
  keystore, talk to the kafka-east brokers over mTLS, and serve their own
  HTTPS listeners. The functional checks are an end-to-end schema
  register/fetch round-trip across the SR HA pair and a REST Proxy
  produce/consume round-trip.

  Scoped to the three 0.H.3 ecosystem nodes -- the broker tier is covered by
  smoke-0.H.2.ps1 (the brokers are unchanged by 0.H.3).

  Probe robustness per memory/feedback_smoke_gate_probe_robustness.md:
  marker-token `-match` (not strict equality) to tolerate sudo's "unable to
  resolve host" stderr noise. Each check echoes [OK]/[FAIL]; exits 1 on any
  FAIL, 0 on all-green.

.PARAMETER Strict
  Fail on warnings. Default: false.

.NOTES
  No external dependencies beyond ssh + the build host's ssh-agent + the
  canonical lab SSH key. HTTPS probes run ON the node via curl --cacert
  /etc/ssl/certs/kafka-ca.pem.
#>

[CmdletBinding()]
param(
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

$user = 'nexusadmin'
# Canon: vms.yaml lines 91-92 (schema-registry) + line 110 (kafka-rest).
$srIps   = @('192.168.70.91', '192.168.70.92')
$restIp  = '192.168.70.88'
$allIps  = $srIps + $restIp

$sshOpts = @('-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')
$caFile  = '/etc/ssl/certs/kafka-ca.pem'
$kafkaBin = '/opt/kafka/bin'
$clientCfg = '/etc/nexus-kafka/client-ssl.properties'
# An ecosystem node has no broker on its own localhost:9092 -- kafka CLI
# probes from these nodes must target a real broker over the VMnet10
# backplane. The kafka CLI accepts the SSL:// scheme prefix; the security
# protocol + keystore come from --command-config.
$eastBroker = 'SSL://192.168.10.21:9092'

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
    '192.168.70.91' = @{ host = 'schema-registry-1'; role = 'schema-registry' }
    '192.168.70.92' = @{ host = 'schema-registry-2'; role = 'schema-registry' }
    '192.168.70.88' = @{ host = 'kafka-rest-1';      role = 'rest' }
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
foreach ($ip in $srIps) {
    Test-Check -Description "$ip : schema-registry.service active" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active schema-registry.service'
        $out -match '^active$'
    } | Out-Null
}
Test-Check -Description "$restIp : kafka-rest.service active" -Probe {
    $out = Invoke-RemoteCommand -Ip $restIp -Command 'systemctl is-active kafka-rest.service'
    $out -match '^active$'
} | Out-Null

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "FAIL early: $($failures.Count) pre-functional check(s) failed; skipping HTTPS + round-trip probes." -ForegroundColor Red
    exit 1
}

# ─── Section 7: HTTPS listeners ───────────────────────────────────────────
Write-Section 'HTTPS listeners answer (mTLS to brokers proven by /topics)'
foreach ($ip in $srIps) {
    Test-Check -Description "$ip : Schema Registry https://localhost:8081/subjects -> 200" -Probe {
        $out = Invoke-RemoteCommand -Ip $ip -Command "curl -s -o /dev/null -w '%{http_code}' --cacert $caFile https://localhost:8081/subjects 2>/dev/null"
        $out -match '200'
    } | Out-Null
}
Test-Check -Description "$restIp : REST Proxy https://localhost:8082/topics returns a JSON array" -Probe {
    $out = Invoke-RemoteCommand -Ip $restIp -Command "curl -s --cacert $caFile https://localhost:8082/topics 2>/dev/null"
    $out -match '^\['
} | Out-Null

# ─── Section 8: _schemas topic shape ──────────────────────────────────────
Write-Section '_schemas topic shape'
Test-Check -Description "schema-registry-1 : _schemas topic exists with ReplicationFactor 3 (probed over mTLS)" -Probe {
    $out = Invoke-RemoteCommand -Ip $srIps[0] -Command "sudo $kafkaBin/kafka-topics.sh --bootstrap-server $eastBroker --command-config $clientCfg --describe --topic _schemas 2>/dev/null"
    ($out -match '_schemas') -and ($out -match 'ReplicationFactor:\s*3')
} | Out-Null

# ─── Section 9: Schema Registry HA round-trip ─────────────────────────────
Write-Section 'Schema Registry HA round-trip (register on SR-1, fetch from SR-2)'
$srSubject = "nexus-smoke-0h3-$(Get-Random)"
# SR API body: {"schema": "<schema as a JSON string>"} -- outer object uses
# plain quotes; only the inner schema-string quotes are \"-escaped. PS
# single-quoted literal; wrapped in '...' in the remote bash command.
$srSchema  = '{"schema": "{\"type\":\"record\",\"name\":\"NexusSmoke\",\"fields\":[{\"name\":\"id\",\"type\":\"string\"}]}"}'
Test-Check -Description "register schema '$srSubject' on schema-registry-1 -> {id:N}" -Probe {
    $reg = "curl -s --cacert $caFile -X POST -H 'Content-Type: application/vnd.schemaregistry.v1+json' --data '$srSchema' https://localhost:8081/subjects/$srSubject/versions"
    $out = Invoke-RemoteCommand -Ip $srIps[0] -Command $reg
    $out -match '"id"\s*:\s*\d+'
} | Out-Null
Test-Check -Description "fetch schema '$srSubject' from schema-registry-2 -> 200 (HA pair shares _schemas)" -Probe {
    $out = Invoke-RemoteCommand -Ip $srIps[1] -Command "curl -s -o /dev/null -w '%{http_code}' --cacert $caFile https://localhost:8081/subjects/$srSubject/versions/1 2>/dev/null"
    $out -match '200'
} | Out-Null
# Best-effort cleanup of the smoke subject.
Invoke-RemoteCommand -Ip $srIps[0] -Command "curl -s -o /dev/null --cacert $caFile -X DELETE https://localhost:8081/subjects/$srSubject 2>/dev/null" | Out-Null

# ─── Section 10: REST Proxy produce/consume round-trip ────────────────────
Write-Section 'REST Proxy produce/consume round-trip (over HTTPS + mTLS)'
$restToken = "rest-0h3-$(Get-Random)"
$restTopic = "nexus-smoke-0h3-rest"
Test-Check -Description "$restIp : produce -> consume round-trip via REST Proxy carries token" -Probe {
    $consumer = "smoke-$(Get-Random)"
    # The brokers run auto.create.topics.enable=false, so the test topic must
    # be pre-created (REST Proxy does not auto-create). JSON payloads wrapped
    # in '...' in the remote bash command -- plain double-quotes only
    # (PS "" -> a literal "). The first REST consumer fetch after subscribe
    # usually returns [] while the group is assigned, so fetch in a loop.
    $seq = "set -e; " +
           "sudo $kafkaBin/kafka-topics.sh --bootstrap-server $eastBroker --command-config $clientCfg --create --if-not-exists --topic $restTopic --partitions 3 --replication-factor 3 >/dev/null 2>&1; " +
           "curl -s -o /dev/null --cacert $caFile -X POST -H 'Content-Type: application/vnd.kafka.json.v2+json' -H 'Accept: application/vnd.kafka.v2+json' --data '{""records"":[{""value"":{""tok"":""$restToken""}}]}' https://localhost:8082/topics/$restTopic; " +
           "curl -s -o /dev/null --cacert $caFile -X POST -H 'Content-Type: application/vnd.kafka.v2+json' --data '{""name"":""$consumer"",""format"":""json"",""auto.offset.reset"":""earliest""}' https://localhost:8082/consumers/smoke-0h3; " +
           "curl -s -o /dev/null --cacert $caFile -X POST -H 'Content-Type: application/vnd.kafka.v2+json' --data '{""topics"":[""$restTopic""]}' https://localhost:8082/consumers/smoke-0h3/instances/$consumer/subscription; " +
           "OUT=''; for i in 1 2 3 4 5 6; do sleep 3; OUT=`$(curl -s --cacert $caFile -H 'Accept: application/vnd.kafka.json.v2+json' https://localhost:8082/consumers/smoke-0h3/instances/$consumer/records); printf '%s' ""`$OUT"" | grep -q '$restToken' && break; done; " +
           "printf '%s\n' ""`$OUT""; " +
           "curl -s -o /dev/null --cacert $caFile -X DELETE https://localhost:8082/consumers/smoke-0h3/instances/$consumer; " +
           "sudo $kafkaBin/kafka-topics.sh --bootstrap-server $eastBroker --command-config $clientCfg --delete --topic $restTopic >/dev/null 2>&1 || true"
    $out = Invoke-RemoteCommand -Ip $restIp -Command $seq
    $out -match [regex]::Escape($restToken)
} | Out-Null

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "ALL 0.H.3 SMOKE CHECKS PASSED" -ForegroundColor Green
    Write-Host "Exit gate met: Schema Registry HA pair + REST Proxy live -- Vault-PKI" -ForegroundColor Green
    Write-Host "keystores, mTLS to the kafka-east brokers, HTTPS listeners, an HA" -ForegroundColor Green
    Write-Host "schema round-trip across the pair + a REST produce/consume round-trip." -ForegroundColor Green
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

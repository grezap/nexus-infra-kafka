#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Operator wrapper for the kafka env -- pwsh-native equivalent of the
  bash-shaped Makefile targets.

.DESCRIPTION
  Mirrors nexus-infra-swarm-nomad/scripts/swarm.ps1 (per
  memory/feedback_build_host_pwsh_native.md -- GNU make is not installed
  on the build host; pwsh wrappers are canonical). apply/destroy/smoke/
  cycle/plan/validate verbs against terraform/envs/kafka/ + delegates
  smoke to scripts/smoke-0.H.<N>.ps1.

  Pre-flight dependency: nexus-gateway must have the kafka dnsmasq
  dhcp-host reservations active (managed in nexus-infra-vmware's
  foundation env via role-overlay-gateway-kafka-reservations.tf). This
  wrapper does NOT check or apply those reservations -- foundation
  ownership stays separate.

.PARAMETER Verb
  apply    -- terraform apply -auto-approve in terraform/envs/kafka
  destroy  -- terraform destroy -auto-approve
  smoke    -- run the active phase smoke gate (default 0.H.1)
  cycle    -- destroy -> apply -> smoke (halts on first failure)
  plan     -- terraform plan
  validate -- terraform fmt -check -recursive + terraform validate

.PARAMETER Phase
  Which smoke phase to run. '0.H.5' (default) is the active phase
  (MirrorMaker 2 cross-cluster DR pair + the Phase 0.H exit gate).
  '0.H.4' = Kafka Connect + Debezium + ksqlDB; '0.H.3' = Schema Registry
  HA pair + REST Proxy; '0.H.2' = the broker-mTLS gate; '0.H.1' = the
  PLAINTEXT bring-up gate (valid only before 0.H.2 flipped the clusters
  to mTLS). Later sub-phases add their own gates.

.PARAMETER Vars
  Array of "key=value" pairs forwarded to terraform as -var flags.

.PARAMETER SmokeArgs
  Hashtable forwarded to the smoke script.

.EXAMPLE
  pwsh -File scripts\kafka.ps1 cycle

.EXAMPLE
  # bring up only the east KRaft cluster (skip west); useful for iterating
  pwsh -File scripts\kafka.ps1 apply -Vars enable_kafka_west=false

.EXAMPLE
  # clones + KRaft format only, no broker start (inspect server.properties)
  pwsh -File scripts\kafka.ps1 apply -Vars enable_kraft_format=false

.NOTES
  See scripts/smoke-0.H.<N>.ps1 for the underlying check definitions.
  See nexus-infra-swarm-nomad/scripts/swarm.ps1 for the same shape.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('apply', 'destroy', 'smoke', 'cycle', 'plan', 'validate')]
    [string]$Verb,

    [ValidateSet('0.H.1', '0.H.2', '0.H.3', '0.H.4', '0.H.5')]
    [string]$Phase = '0.H.5',

    [string[]]$Vars = @(),

    [hashtable]$SmokeArgs = @{}
)

$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSScriptRoot
$envDir    = Join-Path $repoRoot 'terraform\envs\kafka'
$smokePath = Join-Path $repoRoot ("scripts\smoke-{0}.ps1" -f $Phase)

function Write-Step([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Invoke-Terraform {
    param([Parameter(Mandatory)][string[]]$TfArgs)
    Push-Location $envDir
    try {
        & terraform @TfArgs
        if ($LASTEXITCODE -ne 0) {
            throw "terraform $($TfArgs[0]) failed (exit $LASTEXITCODE)"
        }
    } finally {
        Pop-Location
    }
}

function Get-VarFlags {
    # Accept both PS array form and comma-joined-string form (pwsh -File
    # doesn't tokenize commas like interactive PS does).
    $flags = @()
    foreach ($v in $Vars) {
        foreach ($piece in ($v -split ',')) {
            $trimmed = $piece.Trim()
            if ($trimmed) { $flags += @('-var', $trimmed) }
        }
    }
    return $flags
}

function Invoke-Apply {
    Write-Step 'terraform apply -auto-approve'
    $argv = @('apply', '-auto-approve')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Destroy {
    Write-Step 'terraform destroy -auto-approve'
    Invoke-Terraform @('destroy', '-auto-approve')
}

function Invoke-Smoke {
    Write-Step "pwsh -File $(Split-Path -Leaf $smokePath) (phase $Phase)"
    if (-not (Test-Path $smokePath)) {
        throw "smoke script not found for phase $Phase`: $smokePath"
    }
    & pwsh -NoProfile -File $smokePath @SmokeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "smoke gate failed (exit $LASTEXITCODE)"
    }
}

function Invoke-Plan {
    Write-Step 'terraform plan'
    $argv = @('plan')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Validate {
    Write-Step 'terraform fmt -check -recursive'
    Invoke-Terraform @('fmt', '-check', '-recursive')
    Write-Step 'terraform validate'
    Invoke-Terraform @('validate')
}

# ─── Dispatch ─────────────────────────────────────────────────────────────
switch ($Verb) {
    'apply'    { Invoke-Apply }
    'destroy'  { Invoke-Destroy }
    'smoke'    { Invoke-Smoke }
    'plan'     { Invoke-Plan }
    'validate' { Invoke-Validate }
    'cycle' {
        Invoke-Destroy
        Invoke-Apply
        Invoke-Smoke
    }
}

Write-Host ''
Write-Host "kafka $Verb complete" -ForegroundColor Green

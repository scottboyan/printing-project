# file_name    : processors/registry/set-code-registry-entry-status.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Advance code entries through the lifecycle, forwards only, stamping
#                the write-once timestamp for the new status.
# related_docs : IB0192 (R6 minted/printed/assigned, write-once timestamps);
#                IB0193 (WP04.T01, WP07.T06)

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,

    # Omit to advance every entry in the registry.
    [Parameter()][string[]]$Codes = @(),

    [Parameter(Mandatory)][ValidateSet('minted', 'printed', 'assigned')][string]$Status,

    [Parameter()][string]$AssignedTo
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'code-registry-lib.ps1')

$result = [ordered]@{ Success = $false; Reason = $null; Updated = 0; Failures = @() }
$failures = [System.Collections.Generic.List[string]]::new()

$registry = Get-CodeRegistry -Path $Path

$writable = Test-RegistryWritable -Registry $registry
if (-not $writable.IsWritable) {
    $result.Reason   = $writable.Reason
    $result.Failures = @($writable.Reason)
    return [pscustomobject]$result
}

$targets = [System.Collections.Generic.List[object]]::new()
if ($Codes.Count -eq 0) {
    foreach ($entry in @($registry.codes)) { $targets.Add($entry) }
} else {
    foreach ($code in $Codes) {
        $entry = Get-RegistryCodeEntry -Registry $registry -Code $code
        if ($null -eq $entry) { $failures.Add("Code '$code' is not in this registry."); continue }
        $targets.Add($entry)
    }
}

$newRank   = Get-CodeStatusRank -Status $Status
$timestamp = Get-RegistryTimestamp
$stampField = switch ($Status) {
    'minted'   { 'minted_at' }
    'printed'  { 'printed_at' }
    'assigned' { 'assigned_at' }
}

# Validate every transition before writing any of them: a half-advanced registry
# after an irreversible physical act is worse than a refused one.
foreach ($entry in $targets) {
    $currentRank = Get-CodeStatusRank -Status $entry.status
    if ($currentRank -lt 0) {
        $failures.Add("Code '$($entry.code)' has unrecognized current status '$($entry.status)'.")
        continue
    }
    if ($newRank -lt $currentRank) {
        $failures.Add("Code '$($entry.code)' is '$($entry.status)' and cannot move backwards to '$Status'. Status never moves backwards (IB0192 R6).")
        continue
    }
    if ($null -ne $entry.$stampField) {
        $failures.Add("Code '$($entry.code)' already has $stampField set to '$($entry.$stampField)'. The timestamp fields are write-once (IB0192).")
    }
}

if ($failures.Count -gt 0) {
    $result.Failures = $failures.ToArray()
    $result.Reason   = "$($failures.Count) transition(s) refused; nothing was written."
    return [pscustomobject]$result
}

$updated = 0
foreach ($entry in $targets) {
    $entry.status      = $Status
    $entry.$stampField = $timestamp
    if ($Status -eq 'assigned' -and $PSBoundParameters.ContainsKey('AssignedTo')) {
        $entry.assigned_to = $AssignedTo
    }
    $updated++
}

Save-CodeRegistry -Registry $registry -Path $Path

$result.Success = $true
$result.Updated = $updated
return [pscustomobject]$result

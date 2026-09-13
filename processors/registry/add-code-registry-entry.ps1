# file_name    : processors/registry/add-code-registry-entry.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Append one code entry to a series registry, refusing a duplicate
#                within the series.
# related_docs : IB0192 (registry schema, R6 minted is irreversible); IB0193 (WP04.T01)
#
# Refusal is a RETURNED failure, not a thrown string, so a caller minting forty
# codes can report every rejection rather than stopping at the first.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Code,
    [Parameter(Mandatory)][string]$Display,
    [Parameter(Mandatory)][string]$Url,
    [Parameter()][int]$Sequence = 0,
    [Parameter()][string]$Status = 'minted'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'code-registry-lib.ps1')
# Which series a code belongs to is codec knowledge, not registry knowledge, so it
# comes from the codes domain library rather than being re-derived here.
. (Join-Path $PSScriptRoot '..' 'codes' 'artifact-code-lib.ps1')

$result = [ordered]@{ Success = $false; Reason = $null; Entry = $null; Count = 0 }

$registry = Get-CodeRegistry -Path $Path
$result.Count = @($registry.codes).Count

$writable = Test-RegistryWritable -Registry $registry
if (-not $writable.IsWritable) {
    $result.Reason = $writable.Reason
    return [pscustomobject]$result
}

$codeSeries = Get-ArtifactCodePart -CanonicalCode $Code -Part 'Series'
if ($codeSeries -ne $registry.series) {
    $result.Reason = "Code '$Code' is in series '$codeSeries' but this registry is series '$($registry.series)'."
    return [pscustomobject]$result
}

if ($null -ne (Get-RegistryCodeEntry -Registry $registry -Code $Code)) {
    $result.Reason = "Code '$Code' is already recorded in series $($registry.series). A minted code is permanently spent and is never minted again (IB0192 R6)."
    return [pscustomobject]$result
}

if ($Sequence -le 0) { $Sequence = @($registry.codes).Count + 1 }

# One self-contained document per code, shaped for direct Firestore import (IB0192 R7).
$entry = [pscustomobject][ordered]@{
    code        = $Code
    display     = $Display
    url         = $Url
    sequence    = $Sequence
    sheet       = $null
    cell        = $null
    status      = $Status
    minted_at   = Get-RegistryTimestamp
    printed_at  = $null
    assigned_at = $null
    assigned_to = $null
}

$codes = [System.Collections.Generic.List[object]]::new()
foreach ($existing in @($registry.codes)) { $codes.Add($existing) }
$codes.Add($entry)
$registry.codes = $codes.ToArray()

Save-CodeRegistry -Registry $registry -Path $Path

$result.Success = $true
$result.Entry   = $entry
$result.Count   = @($registry.codes).Count
return [pscustomobject]$result

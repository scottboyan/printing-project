# file_name    : processors/codes/test-artifact-code.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Normalize and validate one artifact code. Returns a result object
#                carrying the canonical form, or a reason on failure.
# related_docs : IB0192 (normalization rules, check character R5); IB0193 (WP03.T01)

[CmdletBinding()]
param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Code
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'artifact-code-lib.ps1')

$normalized = ConvertTo-NormalizedArtifactCode -InputCode $Code

$result = [ordered]@{
    IsValid   = $false
    Canonical = $null
    Series    = $null
    Random    = $null
    Check     = $null
    Reason    = $null
    Input     = $Code
}

if (-not $normalized.IsValid) {
    $result.Reason = $normalized.Reason
    return [pscustomobject]$result
}

$canonical = $normalized.Canonical
$payload   = Get-ArtifactCodePart -CanonicalCode $canonical -Part 'Payload'
$actual    = Get-ArtifactCodePart -CanonicalCode $canonical -Part 'Check'
$expected  = Get-ArtifactCodeCheckCharacter -Payload $payload

if ($actual -ne $expected) {
    $result.Canonical = $canonical
    $result.Reason    = "Check character is '$actual' but the payload '$payload' computes '$expected'."
    return [pscustomobject]$result
}

$result.IsValid   = $true
$result.Canonical = $canonical
$result.Series    = Get-ArtifactCodePart -CanonicalCode $canonical -Part 'Series'
$result.Random    = Get-ArtifactCodePart -CanonicalCode $canonical -Part 'Random'
$result.Check     = $actual
return [pscustomobject]$result

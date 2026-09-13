# file_name    : processors/registry/test-code-registry.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Validate a series registry file: schema conformance, duplicate scan,
#                check-character validity of every entry, and count agreement.
# related_docs : IB0192 (registry schema, Verification Steps); IB0193 (WP04.T01)
#
# Returns a structured result listing EVERY failure, so a caller can report them all
# at once rather than stopping at the first.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'code-registry-lib.ps1')
# Check-character validity is codec knowledge; it comes from the codes domain.
. (Join-Path $PSScriptRoot '..' 'codes' 'artifact-code-lib.ps1')

$failures = [System.Collections.Generic.List[string]]::new()

$result = [ordered]@{
    IsValid  = $false
    Path     = $Path
    Series   = $null
    Count    = 0
    Failures = @()
}

if (-not (Test-Path -LiteralPath $Path)) {
    $failures.Add("Registry file not found: $Path")
    $result.Failures = $failures.ToArray()
    return [pscustomobject]$result
}

try {
    $registry = Get-CodeRegistry -Path $Path
} catch {
    $failures.Add("Registry is not parseable JSON: $($_.Exception.Message)")
    $result.Failures = $failures.ToArray()
    return [pscustomobject]$result
}

# --- document-level schema ---
foreach ($field in 'schema_version', 'kind', 'series', 'series_name', 'serialized', 'status', 'algorithm', 'minted_at', 'minted_by', 'count', 'codes') {
    if ($registry.PSObject.Properties.Name -notcontains $field) {
        $failures.Add("Missing required document field '$field'.")
    }
}

if ($registry.PSObject.Properties.Name -contains 'kind' -and $registry.kind -ne 'artifact_code_series') {
    $failures.Add("Field 'kind' is '$($registry.kind)', expected 'artifact_code_series'.")
}

if ($registry.PSObject.Properties.Name -contains 'series') {
    $result.Series = $registry.series
    # IB0192: series is a STRING so the zero padding is part of the value. A file
    # whose series deserializes as a number has lost that and must not pass.
    if ($registry.series -isnot [string]) {
        $failures.Add("Field 'series' must be a string, not $($registry.series.GetType().Name). The zero padding is part of the value (IB0192).")
    } elseif ($registry.series -notmatch '^[0-9A-HJKMNP-TV-Z]{3}$') {
        $failures.Add("Field 'series' is '$($registry.series)', which is not three characters from the Crockford alphabet.")
    }
}

if ($registry.PSObject.Properties.Name -contains 'status' -and $registry.status -notin @('open', 'closed')) {
    $failures.Add("Field 'status' is '$($registry.status)', expected 'open' or 'closed'.")
}

# --- code entries ---
$codes = @()
if ($registry.PSObject.Properties.Name -contains 'codes') { $codes = @($registry.codes) }
$result.Count = $codes.Count

if ($registry.PSObject.Properties.Name -contains 'count' -and $registry.count -ne $codes.Count) {
    $failures.Add("Field 'count' is $($registry.count) but the codes array holds $($codes.Count) entries.")
}

$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$seenSequence = [System.Collections.Generic.HashSet[int]]::new()

foreach ($entry in $codes) {
    foreach ($field in 'code', 'display', 'url', 'sequence', 'sheet', 'cell', 'status', 'minted_at', 'printed_at', 'assigned_at', 'assigned_to') {
        if ($entry.PSObject.Properties.Name -notcontains $field) {
            $failures.Add("Entry '$(if ($entry.PSObject.Properties.Name -contains 'code') { $entry.code } else { '<no code>' })' is missing required field '$field'.")
        }
    }
    if ($entry.PSObject.Properties.Name -notcontains 'code') { continue }

    $code = $entry.code

    if (-not $seen.Add($code)) {
        $failures.Add("Code '$code' appears more than once. A minted code is permanently spent (IB0192 R6).")
    }

    $normalized = ConvertTo-NormalizedArtifactCode -InputCode $code
    if (-not $normalized.IsValid) {
        $failures.Add("Code '$code' is malformed: $($normalized.Reason)")
    } else {
        if ($normalized.Canonical -cne $code) {
            $failures.Add("Code '$code' is not stored in canonical form (normalizes to '$($normalized.Canonical)').")
        }
        $payload  = Get-ArtifactCodePart -CanonicalCode $normalized.Canonical -Part 'Payload'
        $expected = Get-ArtifactCodeCheckCharacter -Payload $payload
        $actual   = Get-ArtifactCodePart -CanonicalCode $normalized.Canonical -Part 'Check'
        if ($actual -ne $expected) {
            $failures.Add("Code '$code' has check character '$actual' but payload '$payload' computes '$expected'.")
        }
        $entrySeries = Get-ArtifactCodePart -CanonicalCode $normalized.Canonical -Part 'Series'
        if ($registry.PSObject.Properties.Name -contains 'series' -and $entrySeries -ne $registry.series) {
            $failures.Add("Code '$code' is in series '$entrySeries' but the registry is series '$($registry.series)'.")
        }
    }

    if ($entry.PSObject.Properties.Name -contains 'status' -and (Get-CodeStatusRank -Status $entry.status) -lt 0) {
        $failures.Add("Code '$code' has status '$($entry.status)', expected one of minted, printed, assigned.")
    }

    if ($entry.PSObject.Properties.Name -contains 'sequence') {
        if (-not $seenSequence.Add([int]$entry.sequence)) {
            $failures.Add("Sequence $($entry.sequence) is used by more than one code.")
        }
    }

    # A status implies its timestamp. printed without printed_at is an unauditable
    # record of an irreversible act.
    if ($entry.PSObject.Properties.Name -contains 'status') {
        if ($entry.status -eq 'printed'  -and $null -eq $entry.printed_at)  { $failures.Add("Code '$code' is 'printed' but printed_at is null.") }
        if ($entry.status -eq 'assigned' -and $null -eq $entry.assigned_at) { $failures.Add("Code '$code' is 'assigned' but assigned_at is null.") }
    }
}

$result.Failures = $failures.ToArray()
$result.IsValid  = ($failures.Count -eq 0)
return [pscustomobject]$result

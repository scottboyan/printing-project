# file_name    : processors/registry/code-registry-lib.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Shared load, save, and invariant primitives for series registries.
# related_docs : IB0192 (registry schema, R6 states, R7); IB0193 (KDR-22);
#                doc_2007 (§4.1 strict mode inheritance)
#
# THIS IS NOT AN ENTRY POINT. Dot-sourced domain library, not a processor. Per
# doc_2007 §4.1 it deliberately does NOT call Set-StrictMode, which would leak into
# every caller. Every function here is correct under Set-StrictMode -Version Latest.

# IB0192 R6: a code passes through these states and never moves backwards.
# minted   - the code exists and is permanently spent
# printed  - committed to physical stock
# assigned - bound to a specific physical object
$script:CodeStatusOrder = @{ 'minted' = 1; 'printed' = 2; 'assigned' = 3 }

function Get-CodeStatusRank {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Status)

    if (-not $script:CodeStatusOrder.ContainsKey($Status)) { return -1 }
    return $script:CodeStatusOrder[$Status]
}

function Get-RegistryTimestamp {
    return [System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Get-CodeRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Registry not found: $Path" }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    # -DateKind String is load-bearing. Without it ConvertFrom-Json turns every
    # ISO-8601 timestamp into a [datetime], which then renders in the host's local
    # format in any message that quotes it, and re-serializes through a timezone
    # conversion on a machine whose locale differs from this one. The registry is the
    # committed system of record: timestamps go in and come out as the exact strings
    # that were written.
    return ($raw | ConvertFrom-Json -DateKind String)
}

function Save-CodeRegistry {
    <#
        Writes UTF-8 without a BOM and with LF endings, so the committed registry is
        byte-stable across machines and a diff shows only real changes.

        'codes' is forced to an array: PowerShell will serialize a single-element
        collection as a bare object, which would silently break the schema for a
        one-code series.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Registry,
        [Parameter(Mandatory)][string]$Path
    )

    $Registry.codes = @($Registry.codes)
    $Registry.count = @($Registry.codes).Count

    $json = $Registry | ConvertTo-Json -Depth 10
    $json = $json -replace "`r`n", "`n"
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $json + "`n", $encoding)
}

function Test-RegistryWritable {
    <#
        IB0192: no further codes are ever minted into a closed series, and this
        repository extends that to any write. Closing is the irreversible act that
        makes a printed run auditable.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Registry)

    $result = [ordered]@{ IsWritable = $false; Reason = $null }
    if ($Registry.status -eq 'closed') {
        $result.Reason = "Series $($Registry.series) is closed. No further writes are accepted (IB0192 series registry)."
        return [pscustomobject]$result
    }
    $result.IsWritable = $true
    return [pscustomobject]$result
}

function Get-RegistryCodeEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Registry,
        [Parameter(Mandatory)][string]$Code
    )

    foreach ($entry in @($Registry.codes)) {
        if ($entry.code -eq $Code) { return $entry }
    }
    return $null
}

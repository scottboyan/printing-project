# file_name    : processors/registry/new-code-registry.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Create a series registry document with algorithm provenance and
#                metadata, and write it to disk.
# related_docs : IB0192 (registry file schema, R7); IB0193 (KDR-22, WP04.T01)

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Series,
    [Parameter(Mandatory)][string]$SeriesName,
    [Parameter(Mandatory)][string]$Path,
    [Parameter()][bool]$Serialized = $true,
    [Parameter()][string]$MintedBy = 'printing-project/orchestrators/new-artifact-code-series.ps1',
    [Parameter()][switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'code-registry-lib.ps1')

$result = [ordered]@{ Success = $false; Reason = $null; Registry = $null; Path = $Path }

if ((Test-Path -LiteralPath $Path) -and -not $Force) {
    $result.Reason = "Registry already exists at $Path. Minting into an existing series requires an explicit override."
    return [pscustomobject]$result
}

$parent = Split-Path -Parent $Path
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}

# The algorithm block is provenance: it records which spec the file was written
# against, so a reader years from now can tell whether the codes inside were minted
# under the format they are reading about.
$registry = [ordered]@{
    schema_version = 1
    kind           = 'artifact_code_series'
    series         = $Series          # STRING, never coerced to a number: the zero
                                      # padding is part of the value (IB0192).
    series_name    = $SeriesName
    serialized     = $Serialized
    status         = 'open'
    algorithm      = [ordered]@{
        spec         = 'IB0192'
        alphabet     = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
        series_chars = 3
        random_chars = 6
        check        = 'luhn-mod-32'
    }
    minted_at      = Get-RegistryTimestamp
    minted_by      = $MintedBy
    count          = 0
    codes          = @()
}

$obj = [pscustomobject]$registry
Save-CodeRegistry -Registry $obj -Path $Path

$result.Success  = $true
$result.Registry = $obj
return [pscustomobject]$result

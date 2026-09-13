# file_name    : processors/registry/set-code-registry-placement.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Record where a code was placed on a sheet, so a printed sheet can be
#                reconciled against the registry after the fact.
# related_docs : IB0192 (sheet and cell fields); IB0193 (WP06.T02)

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,

    # One hashtable per placement: @{ Code = '...'; Sheet = 1; Cell = 1 }
    # Passed as a batch so the file is read and written once rather than per code.
    [Parameter(Mandatory)][hashtable[]]$Placements
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

$updated = 0
foreach ($placement in $Placements) {
    foreach ($key in 'Code', 'Sheet', 'Cell') {
        if (-not $placement.ContainsKey($key)) {
            $failures.Add("Placement is missing key '$key'.")
        }
    }
    if (-not ($placement.ContainsKey('Code') -and $placement.ContainsKey('Sheet') -and $placement.ContainsKey('Cell'))) { continue }

    $entry = Get-RegistryCodeEntry -Registry $registry -Code $placement['Code']
    if ($null -eq $entry) {
        $failures.Add("Code '$($placement['Code'])' is not in this registry.")
        continue
    }
    $entry.sheet = [int]$placement['Sheet']
    $entry.cell  = [int]$placement['Cell']
    $updated++
}

if ($failures.Count -gt 0) {
    $result.Failures = $failures.ToArray()
    $result.Reason   = "$($failures.Count) placement(s) could not be applied; nothing was written."
    return [pscustomobject]$result
}

Save-CodeRegistry -Registry $registry -Path $Path

$result.Success = $true
$result.Updated = $updated
return [pscustomobject]$result

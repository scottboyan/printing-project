# file_name    : processors/registry/close-code-registry.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Close a series. No further writes are accepted afterwards.
# related_docs : IB0192 (a series is closed when its print run completes);
#                IB0193 (WP07.T06)

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'code-registry-lib.ps1')

$result = [ordered]@{ Success = $false; Reason = $null; Series = $null; Count = 0 }

$registry = Get-CodeRegistry -Path $Path
$result.Series = $registry.series
$result.Count  = @($registry.codes).Count

if ($registry.status -eq 'closed') {
    $result.Reason = "Series $($registry.series) is already closed."
    return [pscustomobject]$result
}

$registry.status = 'closed'
if ($registry.PSObject.Properties.Name -notcontains 'closed_at') {
    $registry | Add-Member -NotePropertyName 'closed_at' -NotePropertyValue (Get-RegistryTimestamp)
} else {
    $registry.closed_at = Get-RegistryTimestamp
}

Save-CodeRegistry -Registry $registry -Path $Path

$result.Success = $true
return [pscustomobject]$result

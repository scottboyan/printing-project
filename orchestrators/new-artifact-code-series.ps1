# file_name    : orchestrators/new-artifact-code-series.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Mint N codes into a new series registry.
# related_docs : IB0192 (format and registry); IB0193 (WP06.T01, KDR-4, KDR-6)
#
# ORCHESTRATOR. Sequences processors and reports. Contains no domain logic: no
# alphabet, no check-character arithmetic, no knowledge of what Crockford Base32 is.
# Every processor call uses a HASHTABLE SPLAT (KDR-6, doc_2007 1.1).

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Series,
    [Parameter(Mandatory)][int]$Count,
    [Parameter(Mandatory)][string]$SeriesName,

    [Parameter()][string]$RegistryPath,

    # Minting into an existing series is refused unless this is set. A minted code is
    # permanently spent, so reminting is the one mistake that cannot be undone.
    [Parameter()][switch]$AllowExistingSeries
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$mintProcessor     = Join-Path $root 'processors/codes/new-artifact-code.ps1'
$convertProcessor  = Join-Path $root 'processors/codes/convert-artifact-code-format.ps1'
$newRegistry       = Join-Path $root 'processors/registry/new-code-registry.ps1'
$addEntry          = Join-Path $root 'processors/registry/add-code-registry-entry.ps1'
$validateRegistry  = Join-Path $root 'processors/registry/test-code-registry.ps1'

if (-not $PSBoundParameters.ContainsKey('RegistryPath') -or [string]::IsNullOrWhiteSpace($RegistryPath)) {
    $RegistryPath = Join-Path $root "data/series/series-$Series.json"
}

Write-Host ''
Write-Host "Mint series $Series - $SeriesName"
Write-Host "  registry : $RegistryPath"
Write-Host "  count    : $Count"
Write-Host ''

# --- 1. create the registry -------------------------------------------------
$params = @{
    Series     = $Series
    SeriesName = $SeriesName
    Path       = $RegistryPath
}
if ($AllowExistingSeries) { $params['Force'] = $true }

$created = & $newRegistry @params
if (-not $created.Success) {
    Write-Host "FAILED: $($created.Reason)" -ForegroundColor Red
    exit 1
}
Write-Host "  [1/4] registry created, status '$($created.Registry.status)'"

# --- 2. mint the codes ------------------------------------------------------
$params = @{
    Series = $Series
    Count  = $Count
}
$minted = & $mintProcessor @params
Write-Host "  [2/4] minted $($minted.Count) codes"

# --- 3. record each code ----------------------------------------------------
$recorded = 0
$refusals = [System.Collections.Generic.List[string]]::new()

foreach ($code in $minted) {
    $params = @{ Code = $code.Code; Format = 'Display' }
    $display = & $convertProcessor @params

    $params = @{ Code = $code.Code; Format = 'Url' }
    $url = & $convertProcessor @params

    $params = @{
        Path    = $RegistryPath
        Code    = $code.Code
        Display = $display
        Url     = $url
    }
    $added = & $addEntry @params

    if ($added.Success) { $recorded++ }
    else { $refusals.Add("$($code.Code): $($added.Reason)") }
}

Write-Host "  [3/4] recorded $recorded of $($minted.Count)"
foreach ($refusal in $refusals) { Write-Host "        refused $refusal" -ForegroundColor Yellow }

# --- 4. validate the finished file ------------------------------------------
$params = @{ Path = $RegistryPath }
$validation = & $validateRegistry @params

if ($validation.IsValid) {
    Write-Host "  [4/4] registry validates: $($validation.Count) codes in series $($validation.Series)"
} else {
    Write-Host "  [4/4] registry FAILED validation:" -ForegroundColor Red
    foreach ($failure in $validation.Failures) { Write-Host "        $failure" -ForegroundColor Red }
}

Write-Host ''
if ($validation.IsValid -and $refusals.Count -eq 0 -and $recorded -eq $Count) {
    Write-Host "RESULT: PASS - $recorded codes minted into series $Series" -ForegroundColor Green
    Write-Host ''
    exit 0
}

Write-Host "RESULT: FAIL" -ForegroundColor Red
Write-Host ''
exit 1

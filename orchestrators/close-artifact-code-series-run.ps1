# file_name    : orchestrators/close-artifact-code-series-run.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-14
# last_updated : 2026-09-14
# purpose      : Close out a print run: advance every code to printed, close the
#                series, and write the run record.
# related_docs : IB0192 (R6 states, closed series); IB0193 (WP07.T06, KDR-22)
#
# ORCHESTRATOR. Sequences processors and reports. It writes the run record itself
# because that is reporting, not domain logic; every change to the registry goes
# through a registry processor.
#
# This runs AFTER the physical act. Advancing to printed is irreversible by design:
# a code committed to stock is permanently spent whether or not the sheet survives.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Series,

    [Parameter(Mandatory)][string]$Printer,
    [Parameter(Mandatory)][string]$Stock,

    [Parameter()][string]$Operator   = 'Scott Boyan',
    [Parameter()][string]$PrintPath  = 'Microsoft Edge built-in PDF viewer on Windows 11',
    [Parameter()][string]$Scaling    = '100%, fit-to-page disabled; PDFs pin /PrintScaling /None',
    [Parameter()][string[]]$ScanVerified = @(),
    [Parameter()][string]$Notes,

    [Parameter()][string]$RegistryPath,
    [Parameter()][string]$OutputDirectory,
    [Parameter()][string]$DocsDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$setStatus        = Join-Path $root 'processors/registry/set-code-registry-entry-status.ps1'
$closeRegistry    = Join-Path $root 'processors/registry/close-code-registry.ps1'
$validateRegistry = Join-Path $root 'processors/registry/test-code-registry.ps1'

if (-not $PSBoundParameters.ContainsKey('RegistryPath') -or [string]::IsNullOrWhiteSpace($RegistryPath)) {
    $RegistryPath = Join-Path $root "data/series/series-$Series.json"
}
if (-not $PSBoundParameters.ContainsKey('OutputDirectory') -or [string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $root 'out'
}
if (-not $PSBoundParameters.ContainsKey('DocsDirectory') -or [string]::IsNullOrWhiteSpace($DocsDirectory)) {
    $DocsDirectory = Join-Path $root 'docs'
}

Write-Host ''
Write-Host "Close the Series $Series print run"
Write-Host "  registry : $RegistryPath"
Write-Host ''

# --- 1. validate before changing anything -----------------------------------
$params = @{ Path = $RegistryPath }
$validation = & $validateRegistry @params
if (-not $validation.IsValid) {
    Write-Host 'FAILED: registry does not validate; nothing was changed.' -ForegroundColor Red
    foreach ($failure in $validation.Failures) { Write-Host "  $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "  [1/4] registry validates: $($validation.Count) codes"

# --- 2. advance every entry to printed --------------------------------------
$params = @{ Path = $RegistryPath; Status = 'printed' }
$advanced = & $setStatus @params
if (-not $advanced.Success) {
    Write-Host 'FAILED: could not advance the entries to printed:' -ForegroundColor Red
    foreach ($failure in $advanced.Failures) { Write-Host "  $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "  [2/4] advanced $($advanced.Updated) codes to printed"

# --- 3. close the series ----------------------------------------------------
# Must follow the status advance: a closed series refuses every write.
$params = @{ Path = $RegistryPath }
$closed = & $closeRegistry @params
if (-not $closed.Success) {
    Write-Host "FAILED: could not close the series: $($closed.Reason)" -ForegroundColor Red
    exit 1
}
Write-Host "  [3/4] series $($closed.Series) closed with $($closed.Count) codes"

# --- 4. the run record ------------------------------------------------------
if (-not (Test-Path -LiteralPath $DocsDirectory)) {
    New-Item -ItemType Directory -Path $DocsDirectory -Force | Out-Null
}

$registry = Get-Content -LiteralPath $RegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json -DateKind String

# The verification transcript lives in out/, which is not committed. A run record
# that cites evidence nobody can read later is not a record, so it is copied in.
$transcriptSource = Join-Path $OutputDirectory "series-$Series-verification.json"
$transcriptName   = "series-$Series-verification.json"
$transcriptNote   = 'not found at close-out'
if (Test-Path -LiteralPath $transcriptSource) {
    Copy-Item -LiteralPath $transcriptSource -Destination (Join-Path $DocsDirectory $transcriptName) -Force
    $transcriptNote = "docs/$transcriptName"
}
$manifestSource = Join-Path $OutputDirectory "series-$Series-sheet-manifest.json"
$manifestName   = "series-$Series-sheet-manifest.json"
$manifestNote   = 'not found at close-out'
if (Test-Path -LiteralPath $manifestSource) {
    Copy-Item -LiteralPath $manifestSource -Destination (Join-Path $DocsDirectory $manifestName) -Force
    $manifestNote = "docs/$manifestName"
}

$sheetRows = foreach ($file in (Get-ChildItem -Path $OutputDirectory -Filter "series-$Series-sheet-*.pdf" |
        Where-Object { $_.Name -notlike '*-proof.pdf' } | Sort-Object Name)) {
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "| ``$($file.Name)`` | $('{0:N0}' -f $file.Length) | ``$hash`` |"
}

$scanRows = foreach ($entry in $ScanVerified) {
    $parts = $entry -split ':'
    $code = $registry.codes | Where-Object { $_.sheet -eq [int]$parts[0] -and $_.cell -eq [int]$parts[1] }
    "| $($parts[0]) | $($parts[1]) | ``$($code.display)`` | $($code.url) |"
}

$utcNow = [System.DateTime]::UtcNow
$record = @"
# Series $Series print run record

| | |
|---|---|
| **Series** | ``$($registry.series)`` — $($registry.series_name) |
| **Codes** | $($registry.count), all at ``printed`` |
| **Series status** | ``$($registry.status)`` |
| **Closed (UTC)** | $($utcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')) |
| **Operator** | $Operator |
| **Printer** | $Printer |
| **Stock** | $Stock |
| **Print path** | $PrintPath |
| **Scaling** | $Scaling |

Governed by IB0192 (code format and registry) and IB0193 (this repository and the
Series 2 run), both in ``play-engine-project``.

## What was printed

| File | Bytes | SHA-256 |
|---|---|---|
$($sheetRows -join "`n")

Sheet and cell for every code: $manifestNote

## Pre-print verification (KDR-20)

Every QR was decoded out of the rendered PDFs at 400 dpi, per cell region, and
matched against the registry entry for that cell before anything was printed.

Transcript: $transcriptNote

The gate was also exercised against deliberately corrupted copies — two codes
swapped between cells, a registry code replaced with a valid but unprinted one, and
a registry entry removed — and refused all three with a non-zero exit.

## Physical verification (WP07.T03, T05)

The layout was calibrated over five rounds against plain-paper proofs read on a
transillumination rig against blank stock, until the heavy proof guide aligned with
the die-cut kerf line. The calibration is recorded in ``templates/avery-94106.json``
and is valid only for the print path named above.

Labels scanned from the printed sheets with a phone camera:

| Sheet | Cell | Code | Resolved URL |
|---|---|---|---|
$($scanRows -join "`n")

Per IB0191 Gate A the interim ``/artifact/{code}`` route does not exist yet, so these
resolve to the site's not-found page. That is expected: the check here is that the
scanned URL string is correct, not that the page is useful.

## Notes

$(if ($PSBoundParameters.ContainsKey('Notes') -and -not [string]::IsNullOrWhiteSpace($Notes)) { $Notes } else { 'None.' })

## Closing

Series $Series is closed. No further codes are ever minted into it (IB0192). Every
code is at ``printed`` and is permanently spent whether or not the label it sits on is
ever applied to an object.
"@

$recordPath = Join-Path $DocsDirectory "series-$Series-run-record.md"
$record = $record -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($recordPath, $record + "`n", [System.Text.UTF8Encoding]::new($false))
Write-Host "  [4/4] run record: $recordPath"

# --- final validation -------------------------------------------------------
$params = @{ Path = $RegistryPath }
$final = & $validateRegistry @params

Write-Host ''
if ($final.IsValid) {
    Write-Host ("RESULT: PASS - series {0} closed, {1} codes at printed" -f $registry.series, $registry.count) -ForegroundColor Green
    Write-Host ''
    exit 0
}

Write-Host 'RESULT: FAIL - the registry no longer validates:' -ForegroundColor Red
foreach ($failure in $final.Failures) { Write-Host "  $failure" -ForegroundColor Red }
Write-Host ''
exit 1

# file_name    : orchestrators/verify-label-sheet-pdf.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : The pre-print gate. Decode every QR out of the built sheets and
#                match it against the registry before anything is printed.
# related_docs : IB0193 (WP06.T03, KDR-20, KDR-15, KDR-14, KDR-4, KDR-6)
#
# ORCHESTRATOR. Sequences processors and reports. Exits non-zero on any failure.
#
# This is one of the two steps that make an irreversible act safe, and it is
# precisely the step a rushed run is tempted to skip. It decodes what is actually in
# the RENDERED PDF, not the images that were handed to the composer, so it catches a
# symbol that was encoded correctly and then placed, scaled, or clipped wrongly.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Series,

    [Parameter()][string]$RegistryPath,
    [Parameter()][string]$OutputDirectory,
    [Parameter()][string]$ProductId = '94106',
    [Parameter()][string[]]$SheetPaths = @(),
    [Parameter()][int]$Dpi = 400,

    # KDR-15: https, apex host, no www, no trailing slash.
    [Parameter()][string]$UrlBase = 'https://scottboyan.com/artifact'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$getTemplate      = Join-Path $root 'processors/layout/get-label-template.ps1'
$testPdf          = Join-Path $root 'processors/pdf/test-pdf-properties.ps1'
$readSymbols      = Join-Path $root 'processors/pdf/read-pdf-qr-symbols.ps1'
$validateRegistry = Join-Path $root 'processors/registry/test-code-registry.ps1'

if (-not $PSBoundParameters.ContainsKey('RegistryPath') -or [string]::IsNullOrWhiteSpace($RegistryPath)) {
    $RegistryPath = Join-Path $root "data/series/series-$Series.json"
}
if (-not $PSBoundParameters.ContainsKey('OutputDirectory') -or [string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $root 'out'
}

$failures   = [System.Collections.Generic.List[string]]::new()
$checks     = [System.Collections.Generic.List[object]]::new()
$startedUtc = [System.DateTime]::UtcNow

function Add-Check {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $checks.Add([pscustomobject][ordered]@{ Check = $Name; Passed = $Passed; Detail = $Detail })
    if (-not $Passed) { $failures.Add("$Name - $Detail") }
}

Write-Host ''
Write-Host "Pre-print verification, series $Series"
Write-Host "  registry : $RegistryPath"
Write-Host "  dpi      : $Dpi"
Write-Host ''

# --- 1. registry ------------------------------------------------------------
$params = @{ Path = $RegistryPath }
$validation = & $validateRegistry @params
Add-Check -Name 'registry validates' -Passed $validation.IsValid -Detail $(
    if ($validation.IsValid) { "$($validation.Count) codes in series $($validation.Series)" }
    else { $validation.Failures -join '; ' })

if (-not $validation.IsValid) {
    Write-Host "  [1/4] registry FAILED" -ForegroundColor Red
    foreach ($failure in $validation.Failures) { Write-Host "        $failure" -ForegroundColor Red }
    Write-Host ''
    Write-Host "RESULT: FAIL - do not print" -ForegroundColor Red
    Write-Host ''
    exit 1
}
Write-Host "  [1/4] registry validates: $($validation.Count) codes"

$registry = Get-Content -LiteralPath $RegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json -DateKind String

# --- 2. locate the sheets ---------------------------------------------------
if ($SheetPaths.Count -eq 0) {
    $SheetPaths = @(Get-ChildItem -Path $OutputDirectory -Filter "series-$Series-sheet-*.pdf" |
        Where-Object { $_.Name -notlike '*-proof.pdf' } |
        Sort-Object Name | ForEach-Object { $_.FullName })
}
if ($SheetPaths.Count -eq 0) {
    Write-Host "FAILED: no sheets found in $OutputDirectory for series $Series." -ForegroundColor Red
    exit 1
}
Write-Host "  [2/4] $($SheetPaths.Count) sheet(s) to verify"

$params = @{ ProductId = $ProductId }
$template = & $getTemplate @params

$regions = [System.Collections.Generic.List[hashtable]]::new()
foreach ($cell in $template.Cells) {
    $regions.Add(@{
        Name   = $cell.Number
        Left   = $cell.Box.Left
        Bottom = $cell.Box.Bottom
        Width  = $cell.Box.Width
        Height = $cell.Box.Height
    })
}

# --- 3. per sheet: properties, then every symbol -----------------------------
$decodedPayloads = [System.Collections.Generic.List[string]]::new()
$expectedTotal   = 0

$sheetNumber = 0
foreach ($sheetPath in $SheetPaths) {
    $sheetNumber++
    $sheetName = Split-Path -Leaf $sheetPath

    $params = @{ Path = $sheetPath }
    $properties = & $testPdf @params
    Add-Check -Name "$sheetName properties" -Passed $properties.IsValid -Detail $(
        if ($properties.IsValid) { "1 page, $($properties.Width)x$($properties.Height), /PrintScaling $($properties.PrintScaling)" }
        else { $properties.Failures -join '; ' })

    # Which codes the registry says are on this sheet.
    $expected = @($registry.codes | Where-Object { $null -ne $_.sheet -and [int]$_.sheet -eq $sheetNumber } | Sort-Object -Property cell)
    $expectedTotal += $expected.Count

    Add-Check -Name "$sheetName has registry placements" -Passed ($expected.Count -gt 0) `
        -Detail "$($expected.Count) codes recorded on sheet $sheetNumber"

    $params = @{ Path = $sheetPath; Regions = $regions.ToArray(); Dpi = $Dpi }
    $decoded = & $readSymbols @params

    $expectedCells = @($expected | ForEach-Object { [int]$_.cell })
    $decodedCells  = @($decoded.Symbols | Where-Object { $_.Decoded } | ForEach-Object { [int]$_.Name })

    Add-Check -Name "$sheetName symbol count" -Passed ($decodedCells.Count -eq $expected.Count) `
        -Detail "$($decodedCells.Count) symbols decoded, $($expected.Count) expected"

    # A symbol in a cell the registry does not claim means the sheet carries a label
    # that is not recorded anywhere. That is unauditable and must fail.
    $unexpected = @($decodedCells | Where-Object { $expectedCells -notcontains $_ })
    Add-Check -Name "$sheetName no unrecorded symbols" -Passed ($unexpected.Count -eq 0) `
        -Detail $(if ($unexpected.Count -eq 0) { 'none' } else { "cells $($unexpected -join ', ') carry a symbol the registry does not record" })

    foreach ($entry in $expected) {
        $cellNumber = [int]$entry.cell
        $symbol = @($decoded.Symbols | Where-Object { [int]$_.Name -eq $cellNumber })

        if ($symbol.Count -eq 0 -or -not $symbol[0].Decoded) {
            Add-Check -Name "$sheetName cell $cellNumber decodes" -Passed $false `
                -Detail "no symbol decoded for $($entry.code)"
            continue
        }

        $payload = $symbol[0].Payload
        $decodedPayloads.Add($payload)

        # KDR-15 exactly: the payload must be the URL base and this cell's code, with
        # nothing else. -cne is deliberate: the comparison is case-sensitive.
        $wanted = "$UrlBase/$($entry.code)"
        $matched = ($payload -cne $null) -and ($payload -ceq $wanted)
        Add-Check -Name "$sheetName cell $cellNumber payload" -Passed $matched `
            -Detail $(if ($matched) { $payload } else { "decoded '$payload', registry expects '$wanted'" })

        # The registry's own url field must agree with what was printed.
        Add-Check -Name "$sheetName cell $cellNumber matches registry url" -Passed ($payload -ceq $entry.url) `
            -Detail $(if ($payload -ceq $entry.url) { 'match' } else { "decoded '$payload', registry url '$($entry.url)'" })
    }

    $sheetFailures = @($checks | Where-Object { -not $_.Passed -and $_.Check -like "$sheetName*" })
    if ($sheetFailures.Count -eq 0) {
        Write-Host "  [3/4] $sheetName : $($decodedCells.Count)/$($expected.Count) symbols, all matching" -ForegroundColor Green
    } else {
        Write-Host "  [3/4] $sheetName : $($sheetFailures.Count) FAILURE(S)" -ForegroundColor Red
        foreach ($f in $sheetFailures) { Write-Host "        $($f.Check): $($f.Detail)" -ForegroundColor Red }
    }
}

# --- 4. cross-sheet: every symbol distinct, every code accounted for ---------
$distinct = @($decodedPayloads | Sort-Object -Unique)
Add-Check -Name 'all symbols distinct' -Passed ($distinct.Count -eq $decodedPayloads.Count) `
    -Detail "$($distinct.Count) distinct of $($decodedPayloads.Count) decoded"

Add-Check -Name 'every registry code placed' -Passed ($expectedTotal -eq $validation.Count) `
    -Detail "$expectedTotal placed of $($validation.Count) in the registry"

Add-Check -Name 'every registry code decoded' -Passed ($decodedPayloads.Count -eq $validation.Count) `
    -Detail "$($decodedPayloads.Count) decoded of $($validation.Count) in the registry"

$unplaced = @($registry.codes | Where-Object { $null -eq $_.sheet -or $null -eq $_.cell })
Add-Check -Name 'no unplaced codes' -Passed ($unplaced.Count -eq 0) `
    -Detail $(if ($unplaced.Count -eq 0) { 'none' } else { "$($unplaced.Count) codes have no sheet or cell" })

Write-Host "  [4/4] $($distinct.Count) distinct payloads across $($SheetPaths.Count) sheet(s)"

# --- transcript -------------------------------------------------------------
$passed = ($failures.Count -eq 0)
$transcriptPath = Join-Path $OutputDirectory ("series-{0}-verification.json" -f $Series)
$transcript = [ordered]@{
    kind          = 'preprint_verification_transcript'
    spec          = 'IB0193 WP06.T03 / KDR-20'
    series        = $Series
    verified_at   = $startedUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
    registry      = $RegistryPath
    product_id    = $ProductId
    render_dpi    = $Dpi
    sheets        = @($SheetPaths)
    codes_in_registry = $validation.Count
    symbols_decoded   = $decodedPayloads.Count
    distinct_payloads = $distinct.Count
    result        = if ($passed) { 'PASS' } else { 'FAIL' }
    checks_run    = $checks.Count
    failures      = @($failures.ToArray())
    checks        = @($checks.ToArray())
}
$json = ($transcript | ConvertTo-Json -Depth 8) -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($transcriptPath, $json + "`n", [System.Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host "Transcript: $transcriptPath"
Write-Host ''
if ($passed) {
    Write-Host ("RESULT: PASS - {0} checks, {1} symbols across {2} sheet(s), all distinct and all matching the registry" -f `
        $checks.Count, $decodedPayloads.Count, $SheetPaths.Count) -ForegroundColor Green
    Write-Host ''
    exit 0
}

Write-Host ("RESULT: FAIL - {0} of {1} checks failed. DO NOT PRINT." -f $failures.Count, $checks.Count) -ForegroundColor Red
foreach ($failure in $failures) { Write-Host "  $failure" -ForegroundColor Red }
Write-Host ''
exit 1

# file_name    : orchestrators/build-artifact-label-sheets.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Turn a series registry into print-ready label sheets.
# related_docs : IB0193 (WP06.T02, KDR-13, KDR-15, KDR-17, KDR-4, KDR-6)
#
# ORCHESTRATOR. Sequences processors and reports. It lays out no grid, computes no
# coordinates, and builds no QR: it chunks the registry into sheets and hands each
# chunk to the layout processor. Every processor call uses a HASHTABLE SPLAT.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Series,

    [Parameter()][string]$RegistryPath,
    [Parameter()][string]$OutputDirectory,
    [Parameter()][string]$ProductId = '94106',

    # KDR-17: action line above, QR centred, display code below. No rotated text.
    [Parameter()][string]$ActionLine = 'FIND IT!  SNAP IT!  MOVE IT!  SEND IT!',

    # Draws cell and safe-area guides. For the WP07.T03 plain-paper calibration
    # proof only - never for a sheet that goes onto label stock.
    [Parameter()][switch]$Guides
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$getTemplate      = Join-Path $root 'processors/layout/get-label-template.ps1'
$newSheet         = Join-Path $root 'processors/layout/new-label-sheet-pdf.ps1'
$newQr            = Join-Path $root 'processors/qr/new-qr-image.ps1'
$setPlacement     = Join-Path $root 'processors/registry/set-code-registry-placement.ps1'
$validateRegistry = Join-Path $root 'processors/registry/test-code-registry.ps1'

if (-not $PSBoundParameters.ContainsKey('RegistryPath') -or [string]::IsNullOrWhiteSpace($RegistryPath)) {
    $RegistryPath = Join-Path $root "data/series/series-$Series.json"
}
if (-not $PSBoundParameters.ContainsKey('OutputDirectory') -or [string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $root 'out'
}

Write-Host ''
Write-Host "Build label sheets for series $Series"
Write-Host "  registry : $RegistryPath"
Write-Host "  output   : $OutputDirectory"
Write-Host "  product  : $ProductId"
if ($Guides) { Write-Host "  guides   : ON - calibration proof only, not for label stock" -ForegroundColor Yellow }
Write-Host ''

# --- 1. validate the registry before building anything from it --------------
$params = @{ Path = $RegistryPath }
$validation = & $validateRegistry @params
if (-not $validation.IsValid) {
    Write-Host "FAILED: registry does not validate:" -ForegroundColor Red
    foreach ($failure in $validation.Failures) { Write-Host "  $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "  [1/5] registry validates: $($validation.Count) codes"

# Reading the registry is not domain logic; interpreting a code would be, and this
# orchestrator does not. It takes the code, display and url fields as recorded.
$registry = Get-Content -LiteralPath $RegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json -DateKind String
$entries = @($registry.codes | Sort-Object -Property sequence)

# --- 2. template ------------------------------------------------------------
$params = @{ ProductId = $ProductId }
$template = & $getTemplate @params
$perSheet = $template.CellsPerSheet
Write-Host "  [2/5] template $($template.ProductName): $perSheet cells, margins L$($template.Margins.Left) R$($template.Margins.Right) T$($template.Margins.Top) B$($template.Margins.Bottom) pt"

$sheetCount = [math]::Ceiling($entries.Count / $perSheet)
if ($sheetCount -eq 0) {
    Write-Host "FAILED: registry holds no codes." -ForegroundColor Red
    exit 1
}

# --- 3. build each sheet ----------------------------------------------------
$manifest   = [System.Collections.Generic.List[object]]::new()
$placements = [System.Collections.Generic.List[hashtable]]::new()
$sheetPaths = [System.Collections.Generic.List[string]]::new()

for ($sheet = 1; $sheet -le $sheetCount; $sheet++) {
    $chunk = @($entries | Select-Object -Skip (($sheet - 1) * $perSheet) -First $perSheet)

    $content = [System.Collections.Generic.List[hashtable]]::new()
    $cell = 0
    foreach ($entry in $chunk) {
        $cell++

        $params = @{ Payload = $entry.url }
        $symbol = & $newQr @params

        $content.Add(@{
            Cell       = $cell
            ImageBytes = $symbol.Bytes
            TopText    = $ActionLine
            BottomText = $entry.display
        })

        $placements.Add(@{ Code = $entry.code; Sheet = $sheet; Cell = $cell })
        $manifest.Add([pscustomobject][ordered]@{
            Sheet = $sheet; Cell = $cell; Code = $entry.code
            Display = $entry.display; Url = $entry.url
            QrVersion = $symbol.Version; QrModules = $symbol.SymbolModules
        })
    }

    $suffix = if ($Guides) { '-proof' } else { '' }
    $sheetPath = Join-Path $OutputDirectory ("series-{0}-sheet-{1}{2}.pdf" -f $Series, $sheet, $suffix)

    $params = @{
        Template   = $template
        Content    = $content.ToArray()
        OutputPath = $sheetPath
        Title      = "Series $Series sheet $sheet of $sheetCount"
    }
    if ($Guides) { $params['DrawGuides'] = $true }

    $composed = & $newSheet @params
    $sheetPaths.Add($composed.Path)

    $fitted = @($composed.Placements | ForEach-Object { $_.TopTextSize } | Sort-Object -Unique)
    Write-Host ("  [3/5] sheet {0}: {1} labels, {2:N0} bytes, action line at {3} pt" -f `
        $sheet, $composed.CellCount, $composed.Bytes, ($fitted -join '/'))
}

# --- 4. record placement back into the registry -----------------------------
$params = @{
    Path       = $RegistryPath
    Placements = $placements.ToArray()
}
$placed = & $setPlacement @params
if (-not $placed.Success) {
    Write-Host "FAILED: could not record placement:" -ForegroundColor Red
    foreach ($failure in $placed.Failures) { Write-Host "  $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "  [4/5] recorded sheet and cell for $($placed.Updated) codes"

# --- 5. write the manifest --------------------------------------------------
$manifestPath = Join-Path $OutputDirectory ("series-{0}-sheet-manifest.json" -f $Series)
$manifestDocument = [ordered]@{
    kind          = 'label_sheet_manifest'
    series        = $Series
    product_id    = $ProductId
    built_at      = [System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    sheet_count   = $sheetCount
    labels        = $manifest.Count
    sheets        = @($sheetPaths.ToArray())
    placements    = @($manifest.ToArray())
}
$json = ($manifestDocument | ConvertTo-Json -Depth 8) -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($manifestPath, $json + "`n", [System.Text.UTF8Encoding]::new($false))
Write-Host "  [5/5] manifest: $manifestPath"

Write-Host ''
Write-Host "Sheets:"
foreach ($path in $sheetPaths) { Write-Host "  $path" }
Write-Host ''
Write-Host ("RESULT: PASS - {0} sheets, {1} labels" -f $sheetCount, $manifest.Count) -ForegroundColor Green
Write-Host ''
exit 0

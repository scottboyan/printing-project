# file_name    : orchestrators/adjust-label-template-calibration.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Apply printer calibration adjustments to a label template from the
#                measurements taken off a physical proof, and report before/after.
# related_docs : IB0193 (KDR-12, KDR-4, KDR-6, WP07.T03 adjust-and-reproof loop)
#
# ORCHESTRATOR. Sequences processors and reports. It converts nothing, computes no
# geometry, and holds no measurements of its own.
#
# This is the operator's tool for the calibration loop: measure the proof, run this,
# rebuild, reproof. Adjustments are in MILLIMETRES and in the directions the sheet is
# actually measured in - up and right - so nothing has to be converted by hand.
#
# EXAMPLES
#
#   Every row up half a millimetre, row 3 up a full millimetre:
#     -ProductId 94106 -RowsUp @{ 1 = 0.5; 2 = 0.5; 3 = 1.0; 4 = 0.5; 5 = 0.5 }
#
#   Whole grid 1.5 mm right:
#     -ProductId 94106 -GlobalRight 1.5
#
#   Second column left a third of a millimetre:
#     -ProductId 94106 -ColumnsRight @{ 2 = -0.33 }
#
#   Show what a change would do without writing it:
#     -ProductId 94106 -RowsUp @{ 5 = 0.25 } -WhatIf
#
#   Start over on a different printer:
#     -ProductId 94106 -Reset

[CmdletBinding()]
param(
    # The Avery product number, e.g. 94106. Selects templates/avery-<id>.json.
    [Parameter(Mandatory)][string]$ProductId,

    # Row number (1 = TOP) -> millimetres UP. Negative moves the row down.
    [Parameter()][hashtable]$RowsUp = @{},

    # Column number (1 = LEFT) -> millimetres RIGHT. Negative moves the column left.
    [Parameter()][hashtable]$ColumnsRight = @{},

    # Move the entire grid.
    [Parameter()][double]$GlobalRight = 0.0,
    [Parameter()][double]$GlobalUp    = 0.0,

    # Set the values outright instead of adding to what is already there.
    [Parameter()][switch]$Absolute,

    # Zero the calibration before applying anything.
    [Parameter()][switch]$Reset,

    # Why this adjustment was made. Recorded in the template's calibration history.
    [Parameter()][string]$Note,

    # Report the change without writing it.
    [Parameter()][switch]$WhatIf,

    [Parameter()][string]$TemplateDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$setCalibration = Join-Path $root 'processors/layout/set-label-template-calibration.ps1'
$getTemplate    = Join-Path $root 'processors/layout/get-label-template.ps1'

if (-not $PSBoundParameters.ContainsKey('TemplateDirectory') -or [string]::IsNullOrWhiteSpace($TemplateDirectory)) {
    $TemplateDirectory = Join-Path $root 'templates'
}
$templatePath = Join-Path $TemplateDirectory "avery-$ProductId.json"

if (-not (Test-Path -LiteralPath $templatePath)) {
    $available = @(Get-ChildItem -Path $TemplateDirectory -Filter 'avery-*.json' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.BaseName -replace '^avery-', '' })
    Write-Host "FAILED: no template for product id '$ProductId'. Available: $(if ($available.Count) { $available -join ', ' } else { '(none)' })." -ForegroundColor Red
    exit 1
}

# -WhatIf works on a throwaway copy, so the real template is never touched and the
# reported result is the genuine article rather than a prediction.
$workingDirectory = $TemplateDirectory
$workingPath      = $templatePath
$staging          = $null
if ($WhatIf) {
    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    $workingDirectory = $staging
    $workingPath      = Join-Path $staging "avery-$ProductId.json"
    Copy-Item -LiteralPath $templatePath -Destination $workingPath
}

Write-Host ''
Write-Host "Calibrate template avery-$ProductId"
Write-Host "  file : $templatePath"
Write-Host "  mode : $(if ($Absolute) { 'absolute' } else { 'relative (adds to current)' })$(if ($Reset) { ' after reset' } else { '' })"
if ($WhatIf) { Write-Host "  DRY RUN - nothing will be written" -ForegroundColor Yellow }
Write-Host ''

try {
    $params = @{
        TemplatePath   = $workingPath
        RowsUpMm       = $RowsUp
        ColumnsRightMm = $ColumnsRight
        GlobalRightMm  = $GlobalRight
        GlobalUpMm     = $GlobalUp
    }
    if ($Absolute) { $params['Absolute'] = $true }
    if ($Reset)    { $params['Reset']    = $true }
    if ($PSBoundParameters.ContainsKey('Note')) { $params['Note'] = $Note }

    $result = & $setCalibration @params

    Write-Host "  [1/2] applied: $($result.Change)"
    Write-Host ''
    Write-Host ('  {0,-8} {1,10} {2,10} {3,10}' -f 'axis', 'before mm', 'after mm', 'delta mm')
    Write-Host ('  {0,-8} {1,10} {2,10} {3,10}' -f '--------', '---------', '--------', '--------')
    Write-Host ('  {0,-8} {1,10:N3} {2,10:N3} {3,10:N3}' -f 'global x', $result.GlobalBefore.RightMm, $result.GlobalAfter.RightMm, ($result.GlobalAfter.RightMm - $result.GlobalBefore.RightMm))
    Write-Host ('  {0,-8} {1,10:N3} {2,10:N3} {3,10:N3}' -f 'global y', $result.GlobalBefore.UpMm, $result.GlobalAfter.UpMm, ($result.GlobalAfter.UpMm - $result.GlobalBefore.UpMm))
    foreach ($row in $result.Rows) {
        $marker = if ($row.Delta -ne 0) { '  <-' } else { '' }
        Write-Host (('  {0,-8} {1,10:N3} {2,10:N3} {3,10:N3}' -f "row $($row.Row)", $row.Before, $row.After, $row.Delta) + $marker)
    }
    foreach ($column in $result.Columns) {
        $marker = if ($column.Delta -ne 0) { '  <-' } else { '' }
        Write-Host (('  {0,-8} {1,10:N3} {2,10:N3} {3,10:N3}' -f "col $($column.Column)", $column.Before, $column.After, $column.Delta) + $marker)
    }
    Write-Host ''

    $params = @{ ProductId = $ProductId; TemplateDirectory = $workingDirectory }
    $template = & $getTemplate @params
    Write-Host ('  [2/2] template loads: {0} cells, margins L{1:N2} R{2:N2} T{3:N2} B{4:N2} pt' -f `
        $template.Cells.Count, $template.Margins.Left, $template.Margins.Right, $template.Margins.Top, $template.Margins.Bottom)
}
finally {
    if ($null -ne $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($WhatIf) {
    Write-Host 'RESULT: DRY RUN - the template was not modified.' -ForegroundColor Yellow
    Write-Host ''
    exit 0
}

Write-Host 'RESULT: PASS - calibration written.' -ForegroundColor Green
Write-Host ''
Write-Host 'Next, rebuild and reproof:'
Write-Host '  pwsh -File orchestrators/build-artifact-label-sheets.ps1 -Series 002'
Write-Host '  pwsh -File orchestrators/build-artifact-label-sheets.ps1 -Series 002 -Guides'
Write-Host '  pwsh -File orchestrators/verify-label-sheet-pdf.ps1 -Series 002'
Write-Host ''
exit 0

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
#   Die-cut guides on the proof sheet are 1.7 mm too far out on every side:
#     -ProductId 94106 -GuidesInward 1.7
#
#   Show what a change would do without writing it:
#     -ProductId 94106 -RowsUp @{ 5 = 0.25 } -WhatIf
#
#   Print the current calibration and change nothing:
#     -ProductId 94106 -Show
#
#   Take back the last round because it made registration worse:
#     -ProductId 94106 -Undo
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

    # Millimetres to pull the die-cut guide INWARD from the cell box, on every side.
    # Positive shrinks the drawn box; use when the guides on a proof sit outside the
    # actual cut. This is a measurement of the STOCK, not of the printer.
    [Parameter()][double]$GuidesInward = 0.0,

    # Set the values outright instead of adding to what is already there.
    [Parameter()][switch]$Absolute,

    # Zero the calibration before applying anything.
    [Parameter()][switch]$Reset,

    # Revert the most recent round.
    [Parameter()][switch]$Undo,

    # Print the current calibration and exit without changing anything.
    [Parameter()][switch]$Show,

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

# -Show is strictly read-only: it never reaches the write path at all, rather than
# writing and reverting. The safest way not to change a file is not to open it for
# writing.
if ($Show) {
    $params = @{ ProductId = $ProductId; TemplateDirectory = $TemplateDirectory }
    $template = & $getTemplate @params
    $calibration = (Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8 | ConvertFrom-Json).calibration
    $mmToPt = 72.0 / 25.4

    Write-Host ''
    Write-Host "Calibration for avery-$ProductId"
    Write-Host "  file : $templatePath"
    Write-Host ''
    Write-Host ('  {0,-9} {1,10} {2,11}' -f 'axis', 'mm', 'pt')
    Write-Host ('  {0,-9} {1,10} {2,11}' -f '---------', '---------', '----------')
    Write-Host ('  {0,-9} {1,10:N3} {2,11:N3}' -f 'global x', $calibration.global_offset_mm.x, ($calibration.global_offset_mm.x * $mmToPt))
    Write-Host ('  {0,-9} {1,10:N3} {2,11:N3}' -f 'global y', $calibration.global_offset_mm.y, ($calibration.global_offset_mm.y * $mmToPt))
    $index = 0
    foreach ($value in @($calibration.row_offsets_mm))    { $index++; Write-Host ('  {0,-9} {1,10:N3} {2,11:N3}' -f "row $index", $value, ($value * $mmToPt)) }
    $index = 0
    foreach ($value in @($calibration.column_offsets_mm)) { $index++; Write-Host ('  {0,-9} {1,10:N3} {2,11:N3}' -f "col $index", $value, ($value * $mmToPt)) }
    $inset = if ($calibration.PSObject.Properties.Name -contains 'guide_inset_mm') { [double]$calibration.guide_inset_mm } else { 0.0 }
    Write-Host ('  {0,-9} {1,10:N3} {2,11:N3}' -f 'guides in', $inset, ($inset * $mmToPt))

    $cell = $template.Cells[0]
    Write-Host ''
    Write-Host ('  effective margins  : L{0:N2} R{1:N2} T{2:N2} B{3:N2} pt' -f $template.Margins.Left, $template.Margins.Right, $template.Margins.Top, $template.Margins.Bottom)
    Write-Host ('  cell box (bleed)   : {0:N3} x {1:N3} pt = {2:N3} x {3:N3} mm' -f $cell.Box.Width, $cell.Box.Height, ($cell.Box.Width / $mmToPt), ($cell.Box.Height / $mmToPt))
    Write-Host ('  die-cut guide box  : {0:N3} x {1:N3} pt = {2:N3} x {3:N3} mm = {4:N4} in' -f `
        $cell.DieCut.Width, $cell.DieCut.Height, ($cell.DieCut.Width / $mmToPt), ($cell.DieCut.Height / $mmToPt), ($cell.DieCut.Width / 72))
    Write-Host ('  safe area          : {0:N3} x {1:N3} pt' -f $cell.SafeArea.Width, $cell.SafeArea.Height)

    Write-Host ''
    Write-Host '  history:'
    foreach ($round in @($calibration.history)) {
        # Entries written before a field existed simply do not carry it, and under
        # Set-StrictMode -Version Latest reading a missing property throws rather
        # than returning null (doc_2007 4.1). Every field is probed, not assumed.
        $fields = $round.PSObject.Properties.Name
        $mode   = if ($fields -contains 'mode')  { $round.mode }  else { 'relative' }
        $note   = if ($fields -contains 'after') { "  ($($round.after))" } else { '' }
        $when   = if ($fields -contains 'on')    { $round.on }    else { '(undated)' }
        $what   = if ($fields -contains 'change'){ $round.change } else { '(unrecorded)' }
        Write-Host ("    {0}  [{1}] {2}{3}" -f $when, $mode, $what, $note)
    }
    # Assigned inside the branch, not returned from it. An if-statement that returns
    # an EMPTY collection yields $null, because PowerShell unrolls it to nothing - and
    # $null.Count then throws under Set-StrictMode -Version Latest. Direct assignment
    # of @() keeps it an array with a Count of 0.
    $undone = @()
    if ($calibration.PSObject.Properties.Name -contains 'undone') {
        $undone = @($calibration.undone)
    }
    if ($undone.Count -gt 0) {
        Write-Host ''
        Write-Host '  undone:'
        foreach ($round in $undone) {
            $fields = $round.PSObject.Properties.Name
            $when = if ($fields -contains 'on')     { $round.on }     else { '(undated)' }
            $what = if ($fields -contains 'change') { $round.change } else { '(unrecorded)' }
            Write-Host ("    {0}  {1}" -f $when, $what)
        }
    }
    Write-Host ''
    exit 0
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
    }
    # Forwarded ONLY when the operator actually passed them, so that -Absolute sets
    # what they named and leaves everything else alone. Passing these unconditionally
    # would hand the processor a 0.0 default it could not distinguish from a
    # deliberate zero.
    if ($PSBoundParameters.ContainsKey('GlobalRight'))  { $params['GlobalRightMm']  = $GlobalRight }
    if ($PSBoundParameters.ContainsKey('GlobalUp'))     { $params['GlobalUpMm']     = $GlobalUp }
    if ($PSBoundParameters.ContainsKey('GuidesInward')) { $params['GuidesInwardMm'] = $GuidesInward }
    if ($Absolute) { $params['Absolute'] = $true }
    if ($Reset)    { $params['Reset']    = $true }
    if ($Undo)     { $params['Undo']     = $true }
    if ($PSBoundParameters.ContainsKey('Note')) { $params['Note'] = $Note }

    $result = & $setCalibration @params

    Write-Host "  [1/2] applied: $($result.Change)"
    Write-Host ''
    $mmToPt = 72.0 / 25.4
    Write-Host ('  {0,-9} {1,10} {2,10} {3,10} {4,11}' -f 'axis', 'before mm', 'after mm', 'delta mm', 'after pt')
    Write-Host ('  {0,-9} {1,10} {2,10} {3,10} {4,11}' -f '---------', '---------', '--------', '--------', '----------')

    $line = {
        param($Label, $Before, $After)
        $delta  = [math]::Round($After - $Before, 4)
        $marker = if ($delta -ne 0) { '  <-' } else { '' }
        Write-Host (('  {0,-9} {1,10:N3} {2,10:N3} {3,10:N3} {4,11:N3}' -f $Label, $Before, $After, $delta, ($After * $mmToPt)) + $marker)
    }

    & $line 'global x' $result.GlobalBefore.RightMm $result.GlobalAfter.RightMm
    & $line 'global y' $result.GlobalBefore.UpMm    $result.GlobalAfter.UpMm
    foreach ($row in $result.Rows)       { & $line "row $($row.Row)"       $row.Before    $row.After }
    foreach ($column in $result.Columns) { & $line "col $($column.Column)" $column.Before $column.After }
    & $line 'guides in' $result.GuideInsetBefore $result.GuideInsetAfter
    Write-Host ''
    Write-Host ('  die-cut guide box: {0:N3} x {1:N3} pt = {2:N3} x {3:N3} mm = {4:N4} x {5:N4} in' -f `
        $result.DieCutWidthPt, $result.DieCutHeightPt,
        ($result.DieCutWidthPt / $mmToPt), ($result.DieCutHeightPt / $mmToPt),
        ($result.DieCutWidthPt / 72), ($result.DieCutHeightPt / 72))
    Write-Host ('  calibration rounds recorded: {0}' -f $result.HistoryDepth)
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

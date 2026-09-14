# file_name    : processors/layout/set-label-template-calibration.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Apply printer calibration adjustments to a label template, in
#                millimetres, validating the result before writing it.
# related_docs : IB0193 (KDR-12, R3 bleed vs die-cut, WP07.T03 adjust-and-reproof)
#
# Adjustments arrive in MILLIMETRES and in the operator's own directions - up, right,
# inward - because that is how a physical proof is measured. Conversion to points and
# to PDF-native axes happens in the layout domain, never in the operator's head.
#
# The derived grid is never touched. Only the calibration block moves.
#
# Every round records the FULL RESULTING STATE in the history, not just its delta.
# That is what makes an undo possible: a calibration loop is physical and iterative,
# and a round that makes registration worse has to be reversible without the operator
# reconstructing arithmetic from a list of increments.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TemplatePath,

    # Row number (1 = top) -> millimetres UP. Negative moves down.
    [Parameter()][hashtable]$RowsUpMm = @{},

    # Column number (1 = left) -> millimetres RIGHT. Negative moves left.
    [Parameter()][hashtable]$ColumnsRightMm = @{},

    [Parameter()][double]$GlobalRightMm = 0.0,
    [Parameter()][double]$GlobalUpMm    = 0.0,

    # Millimetres to pull the die-cut guide INWARD from the cell box, per side.
    # Positive shrinks the drawn box toward the centre of the cell.
    [Parameter()][double]$GuidesInwardMm = 0.0,

    # Default is RELATIVE: adjustments add to what is already there, because that is
    # what an operator reads off a proof - "this row needs another half a millimetre".
    [Parameter()][switch]$Absolute,

    # Zero the whole calibration before applying anything. Use when moving to a
    # different printer, where the previous corrections mean nothing.
    [Parameter()][switch]$Reset,

    # Revert the most recent round, restoring the state recorded before it.
    [Parameter()][switch]$Undo,

    [Parameter()][string]$Note
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$getTemplate = Join-Path $PSScriptRoot 'get-label-template.ps1'

if (-not (Test-Path -LiteralPath $TemplatePath)) { throw "Template not found: $TemplatePath" }

$template = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8 | ConvertFrom-Json

$rowCount    = @($template.grid.row_origins_pt).Count
$columnCount = @($template.grid.column_origins_pt).Count

$round = { param($v) [math]::Round([double]$v, 4) }

function Get-ZeroState {
    return [ordered]@{
        global_x       = 0.0
        global_y       = 0.0
        rows           = @(@(0.0) * $rowCount)
        columns        = @(@(0.0) * $columnCount)
        guide_inset_mm = 0.0
    }
}

# --- current state ----------------------------------------------------------
$current  = Get-ZeroState
$history  = @()
$undone   = @()

if ($template.PSObject.Properties.Name -contains 'calibration') {
    $calibration = $template.calibration
    if ($calibration.unit -ne 'mm') {
        throw "Template $TemplatePath declares calibration unit '$($calibration.unit)'; this processor understands 'mm' only."
    }
    if ($calibration.PSObject.Properties.Name -contains 'history') { $history = @($calibration.history) }
    if ($calibration.PSObject.Properties.Name -contains 'undone')  { $undone  = @($calibration.undone) }

    if (-not $Reset) {
        $current.global_x = [double]$calibration.global_offset_mm.x
        $current.global_y = [double]$calibration.global_offset_mm.y

        if ($calibration.PSObject.Properties.Name -contains 'row_offsets_mm') {
            $existing = @($calibration.row_offsets_mm | ForEach-Object { [double]$_ })
            if ($existing.Count -eq $rowCount) { $current.rows = $existing }
        }
        if ($calibration.PSObject.Properties.Name -contains 'column_offsets_mm') {
            $existing = @($calibration.column_offsets_mm | ForEach-Object { [double]$_ })
            if ($existing.Count -eq $columnCount) { $current.columns = $existing }
        }
        if ($calibration.PSObject.Properties.Name -contains 'guide_inset_mm') {
            $current.guide_inset_mm = [double]$calibration.guide_inset_mm
        }
    }
}

# --- work out the new state -------------------------------------------------
$changes = [System.Collections.Generic.List[string]]::new()
$new = [ordered]@{
    global_x       = $current.global_x
    global_y       = $current.global_y
    rows           = @($current.rows)
    columns        = @($current.columns)
    guide_inset_mm = $current.guide_inset_mm
}

if ($Undo) {
    if ($history.Count -eq 0) {
        throw "There is no calibration round to undo; the history for $TemplatePath is empty."
    }
    $reverted = $history[-1]
    $history  = @($history | Select-Object -First ($history.Count - 1))

    # Restore the state recorded before the reverted round, which is the state_after
    # of whatever now sits at the end of the history.
    if ($history.Count -gt 0 -and $history[-1].PSObject.Properties.Name -contains 'state_after') {
        $previous = $history[-1].state_after
        $new.global_x       = [double]$previous.global_x
        $new.global_y       = [double]$previous.global_y
        $new.rows           = @($previous.rows    | ForEach-Object { [double]$_ })
        $new.columns        = @($previous.columns | ForEach-Object { [double]$_ })
        $new.guide_inset_mm = [double]$previous.guide_inset_mm
    } else {
        $new = Get-ZeroState
    }
    $undone = @($undone) + @($reverted)
    $changes.Add("undo of: $($reverted.change)")
}
else {
    # Validate every requested adjustment before applying any of them.
    foreach ($key in $RowsUpMm.Keys) {
        $number = [int]$key
        if ($number -lt 1 -or $number -gt $rowCount) {
            throw "Row $number does not exist; this template has $rowCount rows, numbered 1 (top) to $rowCount (bottom)."
        }
    }
    foreach ($key in $ColumnsRightMm.Keys) {
        $number = [int]$key
        if ($number -lt 1 -or $number -gt $columnCount) {
            throw "Column $number does not exist; this template has $columnCount columns, numbered 1 (left) to $columnCount (right)."
        }
    }

    if ($Reset) { $changes.Add('reset to zero') }

    # In absolute mode, only the values the caller ACTUALLY PASSED are set. Without
    # this, '-GuidesInward 1.5875 -Absolute' would take the unpassed GlobalRightMm at
    # its 0.0 default and silently wipe a calibration built over five proof rounds -
    # the exact shape of failure this repository keeps guarding against, where the
    # call succeeds and the damage is only visible on the next sheet of stock.
    if ($PSBoundParameters.ContainsKey('GlobalRightMm')) {
        $new.global_x = if ($Absolute) { $GlobalRightMm } else { $new.global_x + $GlobalRightMm }
    }
    if ($PSBoundParameters.ContainsKey('GlobalUpMm')) {
        $new.global_y = if ($Absolute) { $GlobalUpMm } else { $new.global_y + $GlobalUpMm }
    }
    if ($GlobalRightMm -ne 0) { $changes.Add("global x {0:+0.###;-0.###} mm" -f $GlobalRightMm) }
    if ($GlobalUpMm    -ne 0) { $changes.Add("global y {0:+0.###;-0.###} mm up" -f $GlobalUpMm) }

    foreach ($key in ($RowsUpMm.Keys | Sort-Object)) {
        $index = [int]$key - 1
        $value = [double]$RowsUpMm[$key]
        $new.rows[$index] = if ($Absolute) { $value } else { $new.rows[$index] + $value }
        $changes.Add("row $key {0:+0.###;-0.###} mm up" -f $value)
    }
    foreach ($key in ($ColumnsRightMm.Keys | Sort-Object)) {
        $index = [int]$key - 1
        $value = [double]$ColumnsRightMm[$key]
        $new.columns[$index] = if ($Absolute) { $value } else { $new.columns[$index] + $value }
        $changes.Add("column $key {0:+0.###;-0.###} mm right" -f $value)
    }

    if ($PSBoundParameters.ContainsKey('GuidesInwardMm')) {
        $new.guide_inset_mm = if ($Absolute) { $GuidesInwardMm } else { $new.guide_inset_mm + $GuidesInwardMm }
        if ($Absolute) { $changes.Add("guide inset set to {0:0.####} mm" -f $GuidesInwardMm) }
        elseif ($GuidesInwardMm -ne 0) { $changes.Add("guides {0:+0.###;-0.###} mm inward" -f $GuidesInwardMm) }
    }
}

# Rounding keeps repeated relative adjustments from accumulating floating-point dust
# in a file a human reads. 0.0001 mm is a tenth of a micron.
$new.global_x       = & $round $new.global_x
$new.global_y       = & $round $new.global_y
$new.rows           = @($new.rows    | ForEach-Object { & $round $_ })
$new.columns        = @($new.columns | ForEach-Object { & $round $_ })
$new.guide_inset_mm = & $round $new.guide_inset_mm

# --- history ----------------------------------------------------------------
$entry = [ordered]@{
    on          = [System.DateTime]::UtcNow.ToString('yyyy-MM-dd')
    by          = 'operator'
    mode        = if ($Undo) { 'undo' } elseif ($Absolute) { 'absolute' } else { 'relative' }
    change      = if ($changes.Count -gt 0) { $changes -join '; ' } else { 'no change' }
    state_after = $new
}
if ($PSBoundParameters.ContainsKey('Note') -and -not [string]::IsNullOrWhiteSpace($Note)) {
    $entry['after'] = $Note
}
$history = @($history) + @([pscustomobject]$entry)

$existingNote = 'PRINTER calibration, not a correction to the derived grid. The column and row origins remain exactly as extracted from the physically verified Series 1 sheet and must not be edited to absorb these offsets; keeping them separate is what lets a run on a different printer reset calibration to zero without losing the provenance of the grid. IB0193 WP07.T03 anticipates this: report the observed offset, adjust, reproof.'
$existingWhy  = 'The derived grid above is points, because that is what was extracted from the PDF and it must not be touched. This block is millimetres because it records what the OPERATOR measured on a physical proof, and round-tripping their measurement through a hand-converted point value is where a transcription error would enter. The layout processor does the one conversion, at full double precision.'
if ($template.PSObject.Properties.Name -contains 'calibration') {
    if ($template.calibration.PSObject.Properties.Name -contains 'note')   { $existingNote = $template.calibration.note }
    if ($template.calibration.PSObject.Properties.Name -contains 'why_mm') { $existingWhy  = $template.calibration.why_mm }
}

$newCalibration = [ordered]@{
    unit              = 'mm'
    why_mm            = $existingWhy
    sign_convention   = 'x positive moves the layout RIGHT on the page. y and every row offset positive move it UP the page. guide_inset_mm positive pulls the die-cut guide INWARD from the cell box on every side. row_offsets_mm is parallel to grid.row_origins_pt and is listed TOP ROW FIRST; column_offsets_mm is parallel to grid.column_origins_pt and is listed LEFT COLUMN FIRST.'
    global_offset_mm  = [ordered]@{ x = $new.global_x; y = $new.global_y }
    row_offsets_mm    = @($new.rows)
    column_offsets_mm = @($new.columns)
    guide_inset_mm    = $new.guide_inset_mm
    guide_inset_note  = 'How far inside the 117 pt cell box the physical die-cut sits, measured by the operator on a transillumination rig. IB0193 R3 records that the extraction could not settle which part of the cell is bleed and which is die-cut; this is the empirical answer for this stock.'
    note              = $existingNote
    history           = @($history)
    undone            = @($undone)
}

$template | Add-Member -NotePropertyName 'calibration' -NotePropertyValue ([pscustomobject]$newCalibration) -Force

# --- validate by loading it, BEFORE overwriting the real file ---------------
# A calibration that pushes a cell off the media, or that puts the safe area outside
# the die-cut, must not be able to leave the template in a state that cannot produce
# a sheet.
$staging = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging -Force | Out-Null
try {
    $productId = $template.product_id
    $stagedPath = Join-Path $staging "avery-$productId.json"
    $json = ($template | ConvertTo-Json -Depth 12) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($stagedPath, $json + "`n", [System.Text.UTF8Encoding]::new($false))

    $params = @{ ProductId = $productId; TemplateDirectory = $staging }
    $loaded = & $getTemplate @params

    # Only now is the real file replaced.
    [System.IO.File]::WriteAllText($TemplatePath, $json + "`n", [System.Text.UTF8Encoding]::new($false))
}
finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}

$rowReport = for ($i = 0; $i -lt $rowCount; $i++) {
    [pscustomobject][ordered]@{
        Row = $i + 1; Before = $current.rows[$i]; After = $new.rows[$i]
        Delta = & $round ($new.rows[$i] - $current.rows[$i])
    }
}
$columnReport = for ($i = 0; $i -lt $columnCount; $i++) {
    [pscustomobject][ordered]@{
        Column = $i + 1; Before = $current.columns[$i]; After = $new.columns[$i]
        Delta = & $round ($new.columns[$i] - $current.columns[$i])
    }
}

$firstCell = $loaded.Cells[0]
return [pscustomobject][ordered]@{
    TemplatePath     = $TemplatePath
    ProductId        = $template.product_id
    GlobalBefore     = [pscustomobject][ordered]@{ RightMm = $current.global_x; UpMm = $current.global_y }
    GlobalAfter      = [pscustomobject][ordered]@{ RightMm = $new.global_x;     UpMm = $new.global_y }
    GuideInsetBefore = $current.guide_inset_mm
    GuideInsetAfter  = $new.guide_inset_mm
    Rows             = @($rowReport)
    Columns          = @($columnReport)
    Margins          = $loaded.Margins
    DieCutWidthPt    = $firstCell.DieCut.Width
    DieCutHeightPt   = $firstCell.DieCut.Height
    Change           = $entry.change
    HistoryDepth     = @($history).Count
}

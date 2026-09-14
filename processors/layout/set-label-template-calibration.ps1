# file_name    : processors/layout/set-label-template-calibration.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Apply printer calibration adjustments to a label template, in
#                millimetres, validating the result before writing it.
# related_docs : IB0193 (KDR-12, WP07.T03 adjust-and-reproof loop)
#
# Adjustments arrive in MILLIMETRES and in the operator's own directions - up and
# right - because that is how a physical proof is measured. Conversion to points and
# to PDF-native axes happens in the layout domain, never in the operator's head.
#
# The derived grid is never touched. Only the calibration block moves.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TemplatePath,

    # Row number (1 = top) -> millimetres UP. Negative moves down.
    [Parameter()][hashtable]$RowsUpMm = @{},

    # Column number (1 = left) -> millimetres RIGHT. Negative moves left.
    [Parameter()][hashtable]$ColumnsRightMm = @{},

    [Parameter()][double]$GlobalRightMm = 0.0,
    [Parameter()][double]$GlobalUpMm    = 0.0,

    # Default is RELATIVE: adjustments add to what is already there, because that is
    # what an operator reads off a proof - "this row needs another half a millimetre".
    # Absolute replaces the current values outright.
    [Parameter()][switch]$Absolute,

    # Zero the whole calibration before applying anything. Use when moving to a
    # different printer, where the previous corrections mean nothing.
    [Parameter()][switch]$Reset,

    [Parameter()][string]$Note
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$getTemplate = Join-Path $PSScriptRoot 'get-label-template.ps1'

if (-not (Test-Path -LiteralPath $TemplatePath)) { throw "Template not found: $TemplatePath" }

$template = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8 | ConvertFrom-Json

$rowCount    = @($template.grid.row_origins_pt).Count
$columnCount = @($template.grid.column_origins_pt).Count

# --- current state ----------------------------------------------------------
$currentGlobalX = 0.0
$currentGlobalY = 0.0
$currentRows    = @(0.0) * $rowCount
$currentColumns = @(0.0) * $columnCount

if (-not $Reset -and $template.PSObject.Properties.Name -contains 'calibration') {
    $calibration = $template.calibration
    if ($calibration.unit -ne 'mm') {
        throw "Template $TemplatePath declares calibration unit '$($calibration.unit)'; this processor understands 'mm' only."
    }
    $currentGlobalX = [double]$calibration.global_offset_mm.x
    $currentGlobalY = [double]$calibration.global_offset_mm.y

    if ($calibration.PSObject.Properties.Name -contains 'row_offsets_mm') {
        $existing = @($calibration.row_offsets_mm | ForEach-Object { [double]$_ })
        if ($existing.Count -eq $rowCount) { $currentRows = $existing }
    }
    if ($calibration.PSObject.Properties.Name -contains 'column_offsets_mm') {
        $existing = @($calibration.column_offsets_mm | ForEach-Object { [double]$_ })
        if ($existing.Count -eq $columnCount) { $currentColumns = $existing }
    }
}

# --- validate the requested adjustments before applying any of them ---------
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

# --- apply ------------------------------------------------------------------
$newGlobalX = if ($Absolute) { $GlobalRightMm } else { $currentGlobalX + $GlobalRightMm }
$newGlobalY = if ($Absolute) { $GlobalUpMm }    else { $currentGlobalY + $GlobalUpMm }

$newRows = @($currentRows)
foreach ($key in $RowsUpMm.Keys) {
    $index = [int]$key - 1
    $value = [double]$RowsUpMm[$key]
    $newRows[$index] = if ($Absolute) { $value } else { $newRows[$index] + $value }
}

$newColumns = @($currentColumns)
foreach ($key in $ColumnsRightMm.Keys) {
    $index = [int]$key - 1
    $value = [double]$ColumnsRightMm[$key]
    $newColumns[$index] = if ($Absolute) { $value } else { $newColumns[$index] + $value }
}

# Rounding to 4 decimal places keeps repeated relative adjustments from accumulating
# floating-point dust in a file a human reads. 0.0001 mm is a tenth of a micron.
$round = { param($v) [math]::Round([double]$v, 4) }
$newGlobalX = & $round $newGlobalX
$newGlobalY = & $round $newGlobalY
$newRows    = @($newRows    | ForEach-Object { & $round $_ })
$newColumns = @($newColumns | ForEach-Object { & $round $_ })

# --- build the new calibration block ----------------------------------------
$history = @()
if (-not $Reset -and $template.PSObject.Properties.Name -contains 'calibration' -and
    $template.calibration.PSObject.Properties.Name -contains 'history') {
    $history = @($template.calibration.history)
}

$changes = [System.Collections.Generic.List[string]]::new()
if ($GlobalRightMm -ne 0) { $changes.Add("global x {0:+0.###;-0.###} mm" -f $GlobalRightMm) }
if ($GlobalUpMm    -ne 0) { $changes.Add("global y {0:+0.###;-0.###} mm up" -f $GlobalUpMm) }
foreach ($key in ($RowsUpMm.Keys | Sort-Object)) {
    $changes.Add("row $key {0:+0.###;-0.###} mm up" -f [double]$RowsUpMm[$key])
}
foreach ($key in ($ColumnsRightMm.Keys | Sort-Object)) {
    $changes.Add("column $key {0:+0.###;-0.###} mm right" -f [double]$ColumnsRightMm[$key])
}
if ($Reset) { $changes.Insert(0, 'reset to zero') }

$entry = [ordered]@{
    on     = [System.DateTime]::UtcNow.ToString('yyyy-MM-dd')
    by     = 'operator'
    mode   = if ($Absolute) { 'absolute' } else { 'relative' }
    change = if ($changes.Count -gt 0) { $changes -join '; ' } else { 'no change' }
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
    sign_convention   = 'x positive moves the layout RIGHT on the page. y and every row offset positive move it UP the page. row_offsets_mm is parallel to grid.row_origins_pt and is listed TOP ROW FIRST; column_offsets_mm is parallel to grid.column_origins_pt and is listed LEFT COLUMN FIRST.'
    global_offset_mm  = [ordered]@{ x = $newGlobalX; y = $newGlobalY }
    row_offsets_mm    = @($newRows)
    column_offsets_mm = @($newColumns)
    note              = $existingNote
    history           = @($history)
}

$template | Add-Member -NotePropertyName 'calibration' -NotePropertyValue ([pscustomobject]$newCalibration) -Force

# --- validate by loading it, BEFORE overwriting the real file ---------------
# A calibration that pushes a cell off the media, or that is otherwise unloadable,
# must not be able to leave the template in a state that cannot produce a sheet.
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
        Row = $i + 1; Before = $currentRows[$i]; After = $newRows[$i]
        Delta = & $round ($newRows[$i] - $currentRows[$i])
    }
}
$columnReport = for ($i = 0; $i -lt $columnCount; $i++) {
    [pscustomobject][ordered]@{
        Column = $i + 1; Before = $currentColumns[$i]; After = $newColumns[$i]
        Delta = & $round ($newColumns[$i] - $currentColumns[$i])
    }
}

return [pscustomobject][ordered]@{
    TemplatePath  = $TemplatePath
    ProductId     = $template.product_id
    GlobalBefore  = [pscustomobject][ordered]@{ RightMm = $currentGlobalX; UpMm = $currentGlobalY }
    GlobalAfter   = [pscustomobject][ordered]@{ RightMm = $newGlobalX;     UpMm = $newGlobalY }
    Rows          = @($rowReport)
    Columns       = @($columnReport)
    Margins       = $loaded.Margins
    Change        = $entry.change
}

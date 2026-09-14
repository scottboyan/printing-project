# file_name    : processors/layout/get-label-template.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Return the sheet template for a label product id, with its twenty
#                cell boxes and safe areas materialized.
# related_docs : IB0193 (KDR-11, KDR-12, KDR-13, WP05.T02)
#
# The geometry itself lives in templates/*.json, not here. This processor reads that
# data and materializes the cell grid from it; it holds no measurements of its own.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProductId,
    [Parameter()][string]$TemplateDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $PSBoundParameters.ContainsKey('TemplateDirectory') -or [string]::IsNullOrWhiteSpace($TemplateDirectory)) {
    $TemplateDirectory = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'templates'
}

$path = Join-Path $TemplateDirectory "avery-$ProductId.json"
if (-not (Test-Path -LiteralPath $path)) {
    $available = @(Get-ChildItem -Path $TemplateDirectory -Filter 'avery-*.json' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.BaseName -replace '^avery-', '' })
    throw "No label template for product id '$ProductId'. Available: $(if ($available.Count) { $available -join ', ' } else { '(none)' })."
}

$template = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json

# Printer calibration, applied to every origin as the cells are materialized. It is
# kept separate from the derived origins on purpose: the grid in the template is the
# geometry extracted from the physically verified Series 1 sheet, and this is a
# per-printer correction sitting on top of it. Absorbing one into the other would
# destroy the provenance of both.
#
# The calibration block is in MILLIMETRES because that is what the operator measures
# on a physical proof. This is the single place the conversion happens.
$pointsPerMillimetre = 72.0 / 25.4

$offsetX       = 0.0
$offsetY       = 0.0
$rowOffsets    = @()
$columnOffsets = @()

if ($template.PSObject.Properties.Name -contains 'calibration') {
    $calibration = $template.calibration

    if ($calibration.unit -ne 'mm') {
        throw "Template $path declares calibration unit '$($calibration.unit)'; this processor understands 'mm' only."
    }

    $offsetX = [double]$calibration.global_offset_mm.x * $pointsPerMillimetre
    $offsetY = [double]$calibration.global_offset_mm.y * $pointsPerMillimetre

    # An offset array that does not line up with its axis would silently apply the
    # wrong correction to the wrong row or column, which is exactly the class of
    # error a calibration pass exists to remove.
    if ($calibration.PSObject.Properties.Name -contains 'row_offsets_mm') {
        $rowOffsets = @($calibration.row_offsets_mm | ForEach-Object { [double]$_ * $pointsPerMillimetre })
        $rowCount = @($template.grid.row_origins_pt).Count
        if ($rowOffsets.Count -ne $rowCount) {
            throw "Template $path declares $($rowOffsets.Count) row offsets but the grid has $rowCount rows. row_offsets_mm must be parallel to grid.row_origins_pt, top row first."
        }
    }

    if ($calibration.PSObject.Properties.Name -contains 'column_offsets_mm') {
        $columnOffsets = @($calibration.column_offsets_mm | ForEach-Object { [double]$_ * $pointsPerMillimetre })
        $columnCount = @($template.grid.column_origins_pt).Count
        if ($columnOffsets.Count -ne $columnCount) {
            throw "Template $path declares $($columnOffsets.Count) column offsets but the grid has $columnCount columns. column_offsets_mm must be parallel to grid.column_origins_pt, left column first."
        }
    }
}

# Materialize the cells as the Cartesian product of the row and column origins, in
# row-major order from the top-left. Coordinates are PDF-native: origin bottom-left,
# y increasing upward. Row origins are listed top row first, which is why the row
# loop is the outer one.
$cells = [System.Collections.Generic.List[object]]::new()
$number = 0
$rowIndex = -1
foreach ($rowOrigin in $template.grid.row_origins_pt) {
    $rowIndex++
    # Per-row correction on top of the global one. Positive moves the row UP the
    # page, which is +y in PDF-native coordinates.
    $rowOffset = if ($rowIndex -lt $rowOffsets.Count) { $rowOffsets[$rowIndex] } else { 0.0 }

    $columnIndex = -1
    foreach ($columnOrigin in $template.grid.column_origins_pt) {
        $columnIndex++
        $number++
        # Per-column correction on top of the global one. Positive moves the column
        # RIGHT across the page, which is +x in PDF-native coordinates.
        $columnOffset = if ($columnIndex -lt $columnOffsets.Count) { $columnOffsets[$columnIndex] } else { 0.0 }

        $x = [double]$columnOrigin + $offsetX + $columnOffset
        $y = [double]$rowOrigin + $offsetY + $rowOffset
        $cells.Add([pscustomobject][ordered]@{
            Number   = $number
            OriginX  = [double]$x
            OriginY  = [double]$y
            Box      = [pscustomobject][ordered]@{
                Left   = [double]$x + $template.cell.offset_x_pt
                Bottom = [double]$y + $template.cell.offset_y_pt
                Width  = [double]$template.cell.width_pt
                Height = [double]$template.cell.height_pt
            }
            SafeArea = [pscustomobject][ordered]@{
                Left   = [double]$x + $template.safe_area.offset_x_pt
                Bottom = [double]$y + $template.safe_area.offset_y_pt
                Width  = [double]$template.safe_area.width_pt
                Height = [double]$template.safe_area.height_pt
            }
        })
    }
}

$expected = $template.grid.cells_per_sheet
if ($cells.Count -ne $expected) {
    throw "Template $path declares $expected cells per sheet but its origins produce $($cells.Count)."
}

# A calibration offset large enough to push a cell off the media is a
# configuration error, and one that would only be discovered after printing.
foreach ($cell in $cells) {
    $right = $cell.Box.Left + $cell.Box.Width
    $top   = $cell.Box.Bottom + $cell.Box.Height
    if ($cell.Box.Left -lt 0 -or $cell.Box.Bottom -lt 0 -or
        $right -gt [double]$template.page.width_pt -or $top -gt [double]$template.page.height_pt) {
        throw "Cell $($cell.Number) falls outside the $($template.page.width_pt) x $($template.page.height_pt) pt page after the calibration offset ($offsetX, $offsetY): box is ($($cell.Box.Left), $($cell.Box.Bottom)) to ($right, $top)."
    }
}

# Computed margins, so a caller can assert the sheet is the one the brief specifies
# rather than trusting the file.
$leftEdges   = @($cells | ForEach-Object { $_.Box.Left })
$bottomEdges = @($cells | ForEach-Object { $_.Box.Bottom })
$rightEdges  = @($cells | ForEach-Object { $_.Box.Left + $_.Box.Width })
$topEdges    = @($cells | ForEach-Object { $_.Box.Bottom + $_.Box.Height })

return [pscustomobject][ordered]@{
    ProductId   = $template.product_id
    ProductName = $template.product_name
    Page        = [pscustomobject][ordered]@{
        Width  = [double]$template.page.width_pt
        Height = [double]$template.page.height_pt
        Name   = $template.page.size_name
    }
    Columns        = [int]$template.grid.columns
    Rows           = [int]$template.grid.rows
    CellsPerSheet  = [int]$template.grid.cells_per_sheet
    CornerRadius   = [double]$template.cell.corner_radius_pt
    CalibrationOffset = [pscustomobject][ordered]@{
        X             = $offsetX
        Y             = $offsetY
        RowOffsets    = $rowOffsets
        ColumnOffsets = $columnOffsets
    }
    Cells          = $cells.ToArray()
    Margins        = [pscustomobject][ordered]@{
        Left   = ($leftEdges   | Measure-Object -Minimum).Minimum
        Right  = [double]$template.page.width_pt  - ($rightEdges | Measure-Object -Maximum).Maximum
        Bottom = ($bottomEdges | Measure-Object -Minimum).Minimum
        Top    = [double]$template.page.height_pt - ($topEdges   | Measure-Object -Maximum).Maximum
    }
    Provenance  = $template.provenance
    SourcePath  = $path
}

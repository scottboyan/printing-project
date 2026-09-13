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

# Printer calibration offset, applied to every origin as the cells are materialized.
# It is kept separate from the derived origins on purpose: the grid in the template
# is the geometry extracted from the physically verified Series 1 sheet, and this is
# a per-printer correction sitting on top of it. Absorbing one into the other would
# destroy the provenance of both.
$offsetX = 0.0
$offsetY = 0.0
if ($template.PSObject.Properties.Name -contains 'calibration_offset_pt') {
    $offsetX = [double]$template.calibration_offset_pt.x
    $offsetY = [double]$template.calibration_offset_pt.y
}

# Materialize the cells as the Cartesian product of the row and column origins, in
# row-major order from the top-left. Coordinates are PDF-native: origin bottom-left,
# y increasing upward. Row origins are listed top row first, which is why the row
# loop is the outer one.
$cells = [System.Collections.Generic.List[object]]::new()
$number = 0
foreach ($rowOrigin in $template.grid.row_origins_pt) {
    foreach ($columnOrigin in $template.grid.column_origins_pt) {
        $number++
        $x = [double]$columnOrigin + $offsetX
        $y = [double]$rowOrigin + $offsetY
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
    CalibrationOffset = [pscustomobject][ordered]@{ X = $offsetX; Y = $offsetY }
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

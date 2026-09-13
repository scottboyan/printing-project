# file_name    : processors/pdf/read-pdf-qr-symbols.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Rasterize a PDF page and decode the QR symbols it contains, either
#                per named region or across the whole page.
# related_docs : IB0193 (KDR-20 pre-print verification, WP06.T03);
#                lib/manifest.json (vendored Docnet.Core/pdfium and ZXing.Net)
#
# This decodes what is actually IN THE RENDERED PDF, not the image that was handed
# to the composer. That distinction is the entire value of the gate: it catches a
# symbol that was encoded correctly and then placed, scaled, or clipped wrongly.
#
# Regions, when given, are decoded one at a time from a crop of the page raster.
# Cropping is deliberate rather than relying on multi-symbol detection: it proves
# each symbol is in the cell it is supposed to be in, which whole-page detection
# cannot establish.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,

    [Parameter()][int]$PageIndex = 0,

    # Rendering resolution. 400 dpi matches the Series 1 digital decode evidence.
    [Parameter()][ValidateRange(72, 1200)][int]$Dpi = 400,

    # One hashtable per region, in PDF-native coordinates (origin bottom-left):
    #   @{ Name = 1; Left = 36; Bottom = 639; Width = 117; Height = 117 }
    # When omitted, the whole page is decoded as a single region.
    [Parameter()][hashtable[]]$Regions = @(),

    [Parameter()][string]$LibraryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $PSBoundParameters.ContainsKey('LibraryPath') -or [string]::IsNullOrWhiteSpace($LibraryPath)) {
    $LibraryPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'lib'
}

Add-Type -Path (Join-Path $LibraryPath 'Docnet.Core.dll')
Add-Type -Path (Join-Path $LibraryPath 'zxing.dll')

if (-not (Test-Path -LiteralPath $Path)) { throw "PDF not found: $Path" }

$scale       = $Dpi / 72.0
$pdfBytes    = [System.IO.File]::ReadAllBytes($Path)
$pageWidthPt = 0.0
$pageHeightPt = 0.0
$raster      = $null
$rasterWidth = 0
$rasterHeight = 0

# DocLib.Instance is a process-wide singleton whose Dispose() makes it unusable for
# the remainder of the process. Only the readers below are disposed.
$library = [Docnet.Core.DocLib]::Instance
$reader  = $library.GetDocReader($pdfBytes, [Docnet.Core.Models.PageDimensions]::new($scale))
try {
    $pageCount = $reader.GetPageCount()
    if ($PageIndex -ge $pageCount) {
        throw "Page index $PageIndex is out of range; the document has $pageCount page(s)."
    }
    $pageReader = $reader.GetPageReader($PageIndex)
    try {
        $raster       = $pageReader.GetImage()          # BGRA32, row-major, top-down
        $rasterWidth  = $pageReader.GetPageWidth()
        $rasterHeight = $pageReader.GetPageHeight()
    }
    finally { $pageReader.Dispose() }
}
finally { $reader.Dispose() }

$pageWidthPt  = $rasterWidth  / $scale
$pageHeightPt = $rasterHeight / $scale

$barcodeReader = [ZXing.BarcodeReaderGeneric]::new()
$barcodeReader.AutoRotate = $true
$barcodeReader.Options.TryHarder = $true
$barcodeReader.Options.PureBarcode = $false
$barcodeReader.Options.PossibleFormats = [System.Collections.Generic.List[ZXing.BarcodeFormat]]::new()
$barcodeReader.Options.PossibleFormats.Add([ZXing.BarcodeFormat]::QR_CODE)

function Read-RegionPayload {
    param(
        [Parameter(Mandatory)][int]$Left,
        [Parameter(Mandatory)][int]$Top,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height
    )

    $crop = [byte[]]::new($Width * $Height * 4)
    for ($row = 0; $row -lt $Height; $row++) {
        $sourceOffset = (($Top + $row) * $rasterWidth + $Left) * 4
        $targetOffset = ($row * $Width) * 4
        [System.Array]::Copy($raster, $sourceOffset, $crop, $targetOffset, $Width * 4)
    }
    $source = [ZXing.RGBLuminanceSource]::new($crop, $Width, $Height, [ZXing.RGBLuminanceSource+BitmapFormat]::BGRA32)
    return $barcodeReader.Decode($source)
}

$effectiveRegions = $Regions
if ($effectiveRegions.Count -eq 0) {
    $effectiveRegions = @(@{ Name = 'page'; Left = 0.0; Bottom = 0.0; Width = $pageWidthPt; Height = $pageHeightPt })
}

$results = [System.Collections.Generic.List[object]]::new()
foreach ($region in $effectiveRegions) {
    foreach ($key in 'Name', 'Left', 'Bottom', 'Width', 'Height') {
        if (-not $region.ContainsKey($key)) { throw "Every region must carry a '$key' key." }
    }

    # PDF-native bottom-left origin to top-down raster pixels.
    $left   = [int][math]::Floor([double]$region['Left'] * $scale)
    $top    = [int][math]::Floor(($pageHeightPt - [double]$region['Bottom'] - [double]$region['Height']) * $scale)
    $width  = [int][math]::Ceiling([double]$region['Width'] * $scale)
    $height = [int][math]::Ceiling([double]$region['Height'] * $scale)

    # Clamp to the raster so a region touching the page edge cannot read out of bounds.
    if ($left -lt 0) { $width += $left; $left = 0 }
    if ($top  -lt 0) { $height += $top; $top = 0 }
    if (($left + $width)  -gt $rasterWidth)  { $width  = $rasterWidth  - $left }
    if (($top  + $height) -gt $rasterHeight) { $height = $rasterHeight - $top }

    $payload = $null
    $decoded = $false
    if ($width -gt 0 -and $height -gt 0) {
        $decodeResult = Read-RegionPayload -Left $left -Top $top -Width $width -Height $height
        if ($null -ne $decodeResult) {
            $payload = $decodeResult.Text
            $decoded = $true
        }
    }

    $results.Add([pscustomobject][ordered]@{
        Name    = $region['Name']
        Decoded = $decoded
        Payload = $payload
        Region  = [pscustomobject][ordered]@{ Left = $left; Top = $top; Width = $width; Height = $height }
    })
}

return [pscustomobject][ordered]@{
    Path         = $Path
    PageIndex    = $PageIndex
    Dpi          = $Dpi
    PageWidthPt  = [math]::Round($pageWidthPt, 2)
    PageHeightPt = [math]::Round($pageHeightPt, 2)
    RasterWidth  = $rasterWidth
    RasterHeight = $rasterHeight
    Symbols      = $results.ToArray()
    DecodedCount = @($results | Where-Object { $_.Decoded }).Count
}

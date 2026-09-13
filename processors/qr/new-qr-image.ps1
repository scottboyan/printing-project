# file_name    : processors/qr/new-qr-image.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Render a QR symbol for an arbitrary payload at a requested size.
# related_docs : IB0193 (KDR-16 level M with the standard 4-module quiet zone,
#                WP05.T01); lib/manifest.json (vendored QRCoder)
#
# Knows nothing about artifacts, codes, or series: it takes a payload string and
# returns an image. The bitmap format is deliberate and recorded in the manifest -
# PDFsharp rejects QRCoder's 1-bit PNG output with "Unsupported image format", so
# the 24bpp BMP renderer is the one that composes.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Payload,

    [Parameter()][ValidateSet('L', 'M', 'Q', 'H')][string]$ErrorCorrection = 'M',

    # Pixels per module. The rendered symbol is (modules + 8) * this, where the 8 is
    # the four-module quiet zone on each side.
    [Parameter()][ValidateRange(1, 200)][int]$PixelsPerModule = 20,

    # When given, the image is written here and the path is returned alongside the
    # bytes. When omitted, only the bytes are returned; nothing touches the disk.
    [Parameter()][string]$OutputPath,

    [Parameter()][string]$LibraryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $PSBoundParameters.ContainsKey('LibraryPath') -or [string]::IsNullOrWhiteSpace($LibraryPath)) {
    $LibraryPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'lib'
}

Add-Type -Path (Join-Path $LibraryPath 'QRCoder.dll')

$level = switch ($ErrorCorrection) {
    'L' { [QRCoder.QRCodeGenerator+ECCLevel]::L }
    'M' { [QRCoder.QRCodeGenerator+ECCLevel]::M }
    'Q' { [QRCoder.QRCodeGenerator+ECCLevel]::Q }
    'H' { [QRCoder.QRCodeGenerator+ECCLevel]::H }
}

$generator = [QRCoder.QRCodeGenerator]::new()
try {
    $data = $generator.CreateQrCode($Payload, $level)
}
finally {
    $generator.Dispose()
}

try {
    $renderer = [QRCoder.BitmapByteQRCode]::new($data)
    # KDR-16 requires the standard 4-module quiet zone in the rendered symbol. This
    # renderer always draws the full module matrix, which already carries it - it
    # exposes no toggle at all, unlike PngByteQRCode. There is deliberately no
    # IncludeQuietZone parameter on this processor: a parameter that cannot be
    # honoured would be a lie, and the quiet zone is mandatory here in any case.
    # The invariant is asserted below.
    $bytes    = $renderer.GetGraphic($PixelsPerModule)

    # Read the symbol's properties BEFORE disposing the data, not after.
    $version    = $data.Version
    $matrixSize = $data.ModuleMatrix.Count
}
finally {
    $data.Dispose()
}

$written = $null
if ($PSBoundParameters.ContainsKey('OutputPath') -and -not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $parent = Split-Path -Parent $OutputPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllBytes($OutputPath, $bytes)
    $written = $OutputPath
}

# QRCodeData.ModuleMatrix carries the four-module quiet zone on each side, so the
# symbol's own module count is the matrix minus eight. A version 3 symbol is 29 x 29
# inside a 37 x 37 matrix.
$symbolModules = $matrixSize - 8

# Assert the quiet zone actually made it into the pixels rather than trusting the
# library. BMP stores width as a little-endian int32 at byte offset 18.
$renderedWidth = [System.BitConverter]::ToInt32($bytes, 18)
$expectedWidth = $matrixSize * $PixelsPerModule
if ($renderedWidth -ne $expectedWidth) {
    throw "Rendered symbol is $renderedWidth px wide but the $matrixSize-module matrix at $PixelsPerModule px/module requires $expectedWidth px. The 4-module quiet zone required by KDR-16 may be missing."
}

return [pscustomobject][ordered]@{
    Payload         = $Payload
    Version         = $version
    ErrorCorrection = $ErrorCorrection
    SymbolModules   = $symbolModules
    ModuleCount     = $matrixSize
    PixelsPerModule = $PixelsPerModule
    QuietZoneModules = 4
    PixelWidth      = $renderedWidth
    Format          = 'bmp'
    Bytes           = $bytes
    Path            = $written
}

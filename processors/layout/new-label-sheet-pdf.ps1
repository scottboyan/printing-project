# file_name    : processors/layout/new-label-sheet-pdf.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Compose one label sheet PDF from a template and a list of per-cell
#                content.
# related_docs : IB0193 (KDR-13 safe area, KDR-14 print scaling, KDR-17 layout,
#                WP05.T03); lib/manifest.json (vendored PDFsharp and fonts)
#
# GENERIC BY CONTRACT. This processor places content into cells. It knows nothing
# about artifacts, codes, series, or what the image depicts. Each content item is a
# hashtable:
#
#   @{ Cell = 1; ImageBytes = [byte[]]; TopText = 'string'; BottomText = 'string' }
#
# ImageBytes, TopText and BottomText are each optional; a cell may carry any subset.
# Cells not named in the content list are left empty.

[CmdletBinding()]
param(
    [Parameter(Mandatory)]$Template,

    [Parameter(Mandatory)][hashtable[]]$Content,

    [Parameter(Mandatory)][string]$OutputPath,

    [Parameter()][string]$Title,

    # Point sizes are starting points. Text that will not fit the safe area at the
    # requested size is stepped down until it does, and the size actually used comes
    # back in the result - see the auto-fit note below.
    [Parameter()][double]$TopTextSize    = 5.5,
    [Parameter()][double]$BottomTextSize = 7.0,

    [Parameter()][double]$ImageSize = 72.0,

    # Draws an outline of each cell box and safe area. For the plain-paper
    # calibration proof (KDR-21) only; never for a sheet that goes onto label stock.
    [Parameter()][switch]$DrawGuides,

    # Stroke weight in points for the cell-box guide. Heavy enough to read through
    # the sheet on a transillumination rig; the safe-area guide is drawn at a third
    # of this so the die-cut boundary stays the dominant line.
    [Parameter()][ValidateRange(0.1, 6.0)][double]$GuideWeight = 1.2,

    [Parameter()][string]$LibraryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $PSBoundParameters.ContainsKey('LibraryPath') -or [string]::IsNullOrWhiteSpace($LibraryPath)) {
    $LibraryPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'lib'
}

# Load order matters: PDFsharp's transitive dependencies must be resolvable before
# its own types are touched. They are vendored beside it (KDR-19).
Add-Type -Path (Join-Path $LibraryPath 'Microsoft.Extensions.DependencyInjection.Abstractions.dll')
Add-Type -Path (Join-Path $LibraryPath 'Microsoft.Extensions.Logging.Abstractions.dll')
Add-Type -Path (Join-Path $LibraryPath 'PdfSharp.dll')

# PDFsharp 6 ships no default font resolver: XFont('Arial', 7) throws outright. The
# resolver below is backed by the vendored DejaVu faces so the sheet does not depend
# on which fonts happen to be installed on the machine doing the printing.
if (-not ('VendoredLabelFontResolver' -as [type])) {
    $resolverSource = @'
using System;
using System.IO;
using PdfSharp.Fonts;

public sealed class VendoredLabelFontResolver : IFontResolver
{
    private readonly string _directory;

    public VendoredLabelFontResolver(string directory)
    {
        _directory = directory;
    }

    public FontResolverInfo ResolveTypeface(string familyName, bool isBold, bool isItalic)
    {
        string family = (familyName ?? string.Empty).ToLowerInvariant();
        if (family.Contains("mono")) return new FontResolverInfo("mono-bold");
        if (isBold || family.Contains("bold")) return new FontResolverInfo("sans-bold");
        return new FontResolverInfo("sans");
    }

    public byte[] GetFont(string faceName)
    {
        string file;
        switch (faceName)
        {
            case "mono-bold": file = "DejaVuSansMono-Bold.ttf"; break;
            case "sans-bold": file = "DejaVuSans-Bold.ttf";     break;
            case "sans":      file = "DejaVuSans.ttf";          break;
            default: throw new InvalidOperationException("Unknown face: " + faceName);
        }
        return File.ReadAllBytes(Path.Combine(_directory, file));
    }
}
'@
    # Passing -ReferencedAssemblies replaces Add-Type's default reference set, so the
    # framework reference assemblies shipped with PowerShell must be listed too.
    $references = @( (Join-Path $LibraryPath 'PdfSharp.dll') )
    $references += (Get-ChildItem -Path (Join-Path $PSHOME 'ref') -Filter '*.dll').FullName
    Add-Type -TypeDefinition $resolverSource -ReferencedAssemblies $references
}

if ($null -eq [PdfSharp.Fonts.GlobalFontSettings]::FontResolver) {
    [PdfSharp.Fonts.GlobalFontSettings]::FontResolver =
        [VendoredLabelFontResolver]::new((Join-Path $LibraryPath 'fonts'))
}

$cellsByNumber = @{}
foreach ($cell in $Template.Cells) { $cellsByNumber[[int]$cell.Number] = $cell }

foreach ($item in $Content) {
    if (-not $item.ContainsKey('Cell')) { throw "Every content item must carry a 'Cell' key." }
    $number = [int]$item['Cell']
    if (-not $cellsByNumber.ContainsKey($number)) {
        throw "Cell $number is not on this template, which has $($Template.CellsPerSheet) cells."
    }
}

$parent = Split-Path -Parent $OutputPath
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}

$pageWidth  = [double]$Template.Page.Width
$pageHeight = [double]$Template.Page.Height

$document = [PdfSharp.Pdf.PdfDocument]::new()
$placements = [System.Collections.Generic.List[object]]::new()
$tempFiles  = [System.Collections.Generic.List[string]]::new()

try {
    if ($PSBoundParameters.ContainsKey('Title') -and -not [string]::IsNullOrWhiteSpace($Title)) {
        $document.Info.Title = $Title
    }

    # KDR-14. The Series 1 sheet survived printing because Avery's exporter pinned
    # this and the operator printed at 100%. PdfViewerPreferences exposes no
    # PrintScaling property, so it is set on the underlying dictionary.
    $document.ViewerPreferences.Elements.SetName('/PrintScaling', '/None')

    $page = $document.AddPage()
    $page.Width  = [PdfSharp.Drawing.XUnit]::FromPoint($pageWidth)
    $page.Height = [PdfSharp.Drawing.XUnit]::FromPoint($pageHeight)

    $gfx = [PdfSharp.Drawing.XGraphics]::FromPdfPage($page)
    try {
        $black = [PdfSharp.Drawing.XBrushes]::Black

        if ($DrawGuides) {
            # The cell box is the die-cut boundary and is what the operator lines up
            # on a transillumination rig, so it is drawn solid black and heavy enough
            # to read through the sheet when backlit. A hairline grey does not show
            # through. The safe area stays light and dotted: it is a secondary
            # reference and must not compete with the boundary being judged.
            $guidePen = [PdfSharp.Drawing.XPen]::new([PdfSharp.Drawing.XColors]::Black, $GuideWeight)
            $safePen  = [PdfSharp.Drawing.XPen]::new([PdfSharp.Drawing.XColors]::Gray, ($GuideWeight / 3.0))
            $safePen.DashStyle = [PdfSharp.Drawing.XDashStyle]::Dot
            foreach ($cell in $Template.Cells) {
                # Guides are drawn on the DIE-CUT, not the bleed box. The die-cut is
                # what the operator lines the stock up against; drawing the bleed box
                # would have them calibrating to an edge that does not exist on the
                # physical sheet. With no measured inset the two are identical.
                $gfx.DrawRoundedRectangle($guidePen, $cell.DieCut.Left, ($pageHeight - $cell.DieCut.Bottom - $cell.DieCut.Height),
                    $cell.DieCut.Width, $cell.DieCut.Height, ($Template.CornerRadius * 2), ($Template.CornerRadius * 2))
                $gfx.DrawRectangle($safePen, $cell.SafeArea.Left, ($pageHeight - $cell.SafeArea.Bottom - $cell.SafeArea.Height),
                    $cell.SafeArea.Width, $cell.SafeArea.Height)
            }
        }

        foreach ($item in $Content) {
            $cell = $cellsByNumber[[int]$item['Cell']]
            $safe = $cell.SafeArea

            # XGraphics draws with the origin at the TOP-left and y increasing
            # downward. The template is PDF-native: origin bottom-left, y up. Every
            # y below is converted here, once, rather than in the caller.
            $safeTopY    = $pageHeight - $safe.Bottom - $safe.Height
            $safeBottomY = $pageHeight - $safe.Bottom
            $centreX     = $safe.Left + ($safe.Width / 2.0)

            $record = [ordered]@{
                Cell = [int]$item['Cell']; TopTextSize = $null; BottomTextSize = $null
                ImageBox = $null; TopTextWidth = $null; BottomTextWidth = $null
            }

            # --- top text, anchored to the top of the safe area ---
            if ($item.ContainsKey('TopText') -and -not [string]::IsNullOrWhiteSpace($item['TopText'])) {
                $fitted = $null
                # Auto-fit. The action line specified in IB0193 measures 105.68 pt at
                # 5.5 pt in this face, which overruns the 100 pt safe area. Content is
                # stepped down until it fits rather than being allowed to cross a
                # die-cut, and the size actually used is reported back.
                for ($size = $TopTextSize; $size -ge 3.0; $size -= 0.1) {
                    $candidate = [PdfSharp.Drawing.XFont]::new('sans', $size)
                    $width = $gfx.MeasureString($item['TopText'], $candidate).Width
                    if ($width -le $safe.Width) { $fitted = @{ Font = $candidate; Width = $width; Size = $size }; break }
                }
                if ($null -eq $fitted) {
                    throw "Cell $($record.Cell): top text does not fit the $($safe.Width) pt safe area even at 3 pt."
                }
                $height = $fitted.Font.GetHeight()
                $gfx.DrawString($item['TopText'], $fitted.Font, $black,
                    ($centreX - ($fitted.Width / 2.0)), ($safeTopY + $height))
                $record.TopTextSize  = [math]::Round($fitted.Size, 2)
                $record.TopTextWidth = [math]::Round($fitted.Width, 2)
            }

            # --- bottom text, anchored to the bottom of the safe area ---
            if ($item.ContainsKey('BottomText') -and -not [string]::IsNullOrWhiteSpace($item['BottomText'])) {
                $fitted = $null
                for ($size = $BottomTextSize; $size -ge 3.0; $size -= 0.1) {
                    $candidate = [PdfSharp.Drawing.XFont]::new('mono', $size)
                    $width = $gfx.MeasureString($item['BottomText'], $candidate).Width
                    if ($width -le $safe.Width) { $fitted = @{ Font = $candidate; Width = $width; Size = $size }; break }
                }
                if ($null -eq $fitted) {
                    throw "Cell $($record.Cell): bottom text does not fit the $($safe.Width) pt safe area even at 3 pt."
                }
                $gfx.DrawString($item['BottomText'], $fitted.Font, $black,
                    ($centreX - ($fitted.Width / 2.0)), ($safeBottomY - 1.5))
                $record.BottomTextSize  = [math]::Round($fitted.Size, 2)
                $record.BottomTextWidth = [math]::Round($fitted.Width, 2)
            }

            # --- image, centred in the space between the two text lines ---
            if ($item.ContainsKey('ImageBytes') -and $null -ne $item['ImageBytes']) {
                $topReserve    = if ($null -ne $record.TopTextSize)    { $record.TopTextSize * 1.6 } else { 0 }
                $bottomReserve = if ($null -ne $record.BottomTextSize) { $record.BottomTextSize * 1.9 } else { 0 }
                $available     = $safe.Height - $topReserve - $bottomReserve

                $drawSize = [math]::Min($ImageSize, $available)
                if ($drawSize -le 0) { throw "Cell $($record.Cell): no room left for the image inside the safe area." }

                # XImage.FromStream on a MemoryStream is not reliable across PDFsharp
                # builds for this format; a temp file is the dependable path and is
                # removed before this processor returns.
                $temp = [System.IO.Path]::GetTempFileName()
                $bmp  = [System.IO.Path]::ChangeExtension($temp, '.bmp')
                Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
                [System.IO.File]::WriteAllBytes($bmp, [byte[]]$item['ImageBytes'])
                $tempFiles.Add($bmp)

                $image = [PdfSharp.Drawing.XImage]::FromFile($bmp)
                try {
                    $imageX = $centreX - ($drawSize / 2.0)
                    $imageY = $safeTopY + $topReserve + (($available - $drawSize) / 2.0)
                    $gfx.DrawImage($image, $imageX, $imageY, $drawSize, $drawSize)
                    $record.ImageBox = [pscustomobject][ordered]@{
                        Left = [math]::Round($imageX, 2); Top = [math]::Round($imageY, 2)
                        Size = [math]::Round($drawSize, 2)
                    }
                }
                finally { $image.Dispose() }
            }

            $placements.Add([pscustomobject]$record)
        }
    }
    finally {
        $gfx.Dispose()
    }

    $document.Save($OutputPath)
}
finally {
    $document.Dispose()
    foreach ($temp in $tempFiles) {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

return [pscustomobject][ordered]@{
    Path       = $OutputPath
    Bytes      = (Get-Item -LiteralPath $OutputPath).Length
    PageWidth  = $pageWidth
    PageHeight = $pageHeight
    CellCount  = @($Content).Count
    Placements = $placements.ToArray()
}

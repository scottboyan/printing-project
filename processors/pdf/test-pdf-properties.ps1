# file_name    : processors/pdf/test-pdf-properties.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Assert page count, media box, and print-scaling flag on a PDF.
# related_docs : IB0193 (KDR-14, WP05.T04); lib/manifest.json (vendored PDFsharp)
#
# Returns a structured result rather than throwing, so an orchestrator can report
# every failure at once instead of stopping at the first.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,

    [Parameter()][int]$ExpectedPageCount = 1,
    [Parameter()][double]$ExpectedWidth  = 612,
    [Parameter()][double]$ExpectedHeight = 792,
    [Parameter()][string]$ExpectedPrintScaling = '/None',

    [Parameter()][string]$LibraryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $PSBoundParameters.ContainsKey('LibraryPath') -or [string]::IsNullOrWhiteSpace($LibraryPath)) {
    $LibraryPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'lib'
}

Add-Type -Path (Join-Path $LibraryPath 'Microsoft.Extensions.DependencyInjection.Abstractions.dll')
Add-Type -Path (Join-Path $LibraryPath 'Microsoft.Extensions.Logging.Abstractions.dll')
Add-Type -Path (Join-Path $LibraryPath 'PdfSharp.dll')

$failures = [System.Collections.Generic.List[string]]::new()

$result = [ordered]@{
    IsValid      = $false
    Path         = $Path
    PageCount    = $null
    Width        = $null
    Height       = $null
    PrintScaling = $null
    Failures     = @()
}

if (-not (Test-Path -LiteralPath $Path)) {
    $failures.Add("PDF not found: $Path")
    $result.Failures = $failures.ToArray()
    return [pscustomobject]$result
}

$document = $null
try {
    $document = [PdfSharp.Pdf.IO.PdfReader]::Open($Path, [PdfSharp.Pdf.IO.PdfDocumentOpenMode]::InformationOnly)

    $result.PageCount = $document.PageCount
    if ($document.PageCount -ne $ExpectedPageCount) {
        $failures.Add("Page count is $($document.PageCount), expected $ExpectedPageCount.")
    }

    if ($document.PageCount -ge 1) {
        $mediaBox = $document.Pages[0].MediaBox
        $result.Width  = [double]$mediaBox.Width
        $result.Height = [double]$mediaBox.Height

        # 0.01 pt is far below anything a printer can resolve; it exists only to keep
        # a floating-point representation difference from failing a correct sheet.
        if ([math]::Abs($result.Width - $ExpectedWidth) -gt 0.01) {
            $failures.Add("Media box width is $($result.Width) pt, expected $ExpectedWidth pt.")
        }
        if ([math]::Abs($result.Height - $ExpectedHeight) -gt 0.01) {
            $failures.Add("Media box height is $($result.Height) pt, expected $ExpectedHeight pt.")
        }
    }

    # KDR-14. Without this the printer may fit-to-page and land every symbol off its
    # die-cut, which is the failure mode that historically ruins label runs.
    $preferences = $document.Internals.Catalog.Elements.GetDictionary('/ViewerPreferences')
    if ($null -eq $preferences) {
        $failures.Add("Document has no /ViewerPreferences, so /PrintScaling is unset (KDR-14).")
    } else {
        $scaling = $preferences.Elements.GetName('/PrintScaling')
        $result.PrintScaling = $scaling
        if ($scaling -ne $ExpectedPrintScaling) {
            $failures.Add("/PrintScaling is '$scaling', expected '$ExpectedPrintScaling' (KDR-14).")
        }
    }
}
catch {
    $failures.Add("Could not read the PDF: $($_.Exception.Message)")
}
finally {
    if ($null -ne $document) { $document.Dispose() }
}

$result.Failures = $failures.ToArray()
$result.IsValid  = ($failures.Count -eq 0)
return [pscustomobject]$result

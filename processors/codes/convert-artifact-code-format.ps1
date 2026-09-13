# file_name    : processors/codes/convert-artifact-code-format.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Convert one artifact code between its canonical, display, and URL
#                forms.
# related_docs : IB0192 (form table); IB0193 (KDR-15 payload shape)

[CmdletBinding()]
param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Code,
    [Parameter(Mandatory)][ValidateSet('Canonical', 'Display', 'Url')][string]$Format,

    # KDR-15: https, apex host, no www, no trailing slash. Parameterized rather than
    # hard-coded so this processor is not welded to one campaign's host, but the
    # default IS the normative route and callers are not expected to override it.
    [Parameter()][string]$UrlBase = 'https://scottboyan.com/artifact'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'artifact-code-lib.ps1')

$normalized = ConvertTo-NormalizedArtifactCode -InputCode $Code
if (-not $normalized.IsValid) {
    throw "Cannot convert '$Code': $($normalized.Reason)"
}
$canonical = $normalized.Canonical

# Normalization settles alphabet and length. The check character is verified here as
# well, because the output of this processor is printed onto physical stock: a code
# that fails its own check character must never reach a label, and this is the last
# place before the QR payload is built that can say so.
$payload  = Get-ArtifactCodePart -CanonicalCode $canonical -Part 'Payload'
$expected = Get-ArtifactCodeCheckCharacter -Payload $payload
$actual   = Get-ArtifactCodePart -CanonicalCode $canonical -Part 'Check'
if ($actual -ne $expected) {
    throw "Cannot convert '$Code': check character is '$actual' but payload '$payload' computes '$expected'."
}

switch ($Format) {
    'Canonical' { return $canonical }
    'Display'   {
        # SSS-RRRRRR-C. Separators are presentation only.
        $series = Get-ArtifactCodePart -CanonicalCode $canonical -Part 'Series'
        $random = Get-ArtifactCodePart -CanonicalCode $canonical -Part 'Random'
        $check  = Get-ArtifactCodePart -CanonicalCode $canonical -Part 'Check'
        return "$series-$random-$check"
    }
    'Url'       { return "$($UrlBase.TrimEnd('/'))/$canonical" }
}

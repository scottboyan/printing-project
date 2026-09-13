# file_name    : processors/codes/new-artifact-code.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Mint artifact codes for a series, using the cryptographic RNG and
#                applying the denylist screen.
# related_docs : IB0192 (R4 randomness, Generation); IB0193 (KDR-10);
#                doc_2007 (§2.1 array return)
#
# RETURN SHAPE: always an array, even for Count = 1, returned with the ',' idiom so
# the pipeline does not unroll it. Per doc_2007 §2.1 the caller must NOT wrap the
# call in @() - that would nest the array one level deeper.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Series,

    [Parameter()][ValidateRange(1, 1000000)][int]$Count = 1,

    # Codes already spent in this series. The caller owns the registry; this
    # processor only needs to know what it must not produce. Codes minted within
    # this batch are tracked internally and need not be fed back in.
    [Parameter()][string[]]$ExistingCodes = @(),

    [Parameter()][string]$DenylistPath,

    # Bounded so a pathological screen cannot spin forever. With 1,073,741,824
    # values per series this ceiling is unreachable in practice; it exists to fail
    # loudly rather than hang if the denylist is ever made absurd.
    [Parameter()][int]$MaxAttemptsPerCode = 10000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'artifact-code-lib.ps1')

$allocatable = Test-ArtifactCodeSeriesAllocatable -Series $Series
if (-not $allocatable.IsAllocatable) {
    throw "Refusing to mint into series '$Series': $($allocatable.Reason)"
}

if (-not $PSBoundParameters.ContainsKey('DenylistPath') -or [string]::IsNullOrWhiteSpace($DenylistPath)) {
    $DenylistPath = Join-Path $PSScriptRoot 'code-denylist.json'
}
# Parsed once for the whole batch. Re-reading per code made a 5,000-code mint take
# minutes for no benefit.
$denylist = Get-Content -LiteralPath $DenylistPath -Raw -Encoding UTF8 | ConvertFrom-Json

$alphabet = Get-ArtifactCodeAlphabet

$spent = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($existing in $ExistingCodes) {
    if (-not [string]::IsNullOrWhiteSpace($existing)) { [void]$spent.Add($existing.Trim().ToUpperInvariant()) }
}

function Test-DeniedRandomPart {
    param([Parameter(Mandatory)][string]$RandomPart)

    foreach ($substring in $denylist.substrings) {
        if ($RandomPart.Contains($substring, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }

    foreach ($rule in $denylist.rules) {
        switch ($rule.kind) {
            'max_identical_run' {
                $run = 1
                for ($i = 1; $i -lt $RandomPart.Length; $i++) {
                    if ($RandomPart[$i] -eq $RandomPart[$i - 1]) {
                        $run++
                        if ($run -gt $rule.value) { return $true }
                    } else { $run = 1 }
                }
            }
            'exact_match' {
                foreach ($value in $rule.values) {
                    if ($RandomPart -eq $value) { return $true }
                }
            }
            default { throw "Unknown denylist rule kind '$($rule.kind)' in $DenylistPath." }
        }
    }
    return $false
}

$minted = [System.Collections.Generic.List[object]]::new()

# IB0192 R4: cryptographic RNG only. Get-Random is a seeded PRNG whose output is
# predictable from its seed, and non-guessable is a stated requirement.
# The alphabet has exactly 32 symbols and a byte has 256 values, so 'byte -band 31'
# is exactly uniform - eight complete cycles of 32, no rejection sampling and no
# modulo bias. Any '%' against a non-power-of-two alphabet would introduce bias.
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try {
    for ($n = 0; $n -lt $Count; $n++) {
        $accepted = $false
        for ($attempt = 1; $attempt -le $MaxAttemptsPerCode; $attempt++) {
            $bytes = [byte[]]::new(6)
            $rng.GetBytes($bytes)

            $chars = [char[]]::new(6)
            for ($i = 0; $i -lt 6; $i++) {
                $chars[$i] = $alphabet[$bytes[$i] -band 31]
            }
            $randomPart = -join $chars

            if (Test-DeniedRandomPart -RandomPart $randomPart) { continue }

            $payload = $Series + $randomPart
            $code    = $payload + (Get-ArtifactCodeCheckCharacter -Payload $payload)

            if (-not $spent.Add($code)) { continue }

            $minted.Add([pscustomobject][ordered]@{
                Code     = $code
                Series   = $Series
                Random   = $randomPart
                Check    = $code.Substring(9, 1)
                Attempts = $attempt
            })
            $accepted = $true
            break
        }
        if (-not $accepted) {
            throw "Failed to mint code $($n + 1) of $Count for series '$Series' within $MaxAttemptsPerCode attempts. Check the denylist at $DenylistPath and the size of the spent set ($($spent.Count) entries)."
        }
    }
}
finally {
    $rng.Dispose()
}

return , $minted.ToArray()

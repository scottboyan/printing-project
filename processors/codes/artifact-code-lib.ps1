# file_name    : processors/codes/artifact-code-lib.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Shared codec primitives for the artifact code format. Dot-sourced
#                by the processors in this domain so that the alphabet and the check
#                character exist in exactly one place.
# related_docs : IB0192 (normative format: alphabet R1, structure R2, check R5);
#                IB0193 (KDR-7); doc_2007 (§4.1 strict mode inheritance)
#
# THIS IS NOT AN ENTRY POINT. It is a dot-sourced domain library, not a processor.
# Per doc_2007 §4.1 it deliberately does NOT call Set-StrictMode: strict mode is
# session state, and a dot-sourced file would leak its setting into every caller.
# Every function here is written to be correct under Set-StrictMode -Version Latest.

# IB0192: Crockford Base32. Index 0 is '0', index 31 is 'Z'. I, L, O, U excluded.
$script:ArtifactCodeAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'

function Get-ArtifactCodeAlphabet {
    return $script:ArtifactCodeAlphabet
}

function Get-ArtifactCodeSymbolValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][char]$Symbol)

    $index = $script:ArtifactCodeAlphabet.IndexOf($Symbol)
    if ($index -lt 0) { throw "Character '$Symbol' is not in the artifact code alphabet." }
    return $index
}

function Get-ArtifactCodeCheckCharacter {
    <#
        Luhn mod 32 over the payload, exactly as IB0192 specifies.

        The parity convention is the detail most likely to be reimplemented wrongly:
        the factor begins at 2 on the RIGHTMOST payload character, not the leftmost.
        The eight IB0192 test vectors are the tiebreaker and are asserted in
        tests/artifact-code.Tests.ps1.

        Length-agnostic by design: only the payload width changes if the format
        ever does.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Payload)

    $sum    = 0
    $factor = 2
    for ($i = $Payload.Length - 1; $i -ge 0; $i--) {
        $addend = $factor * (Get-ArtifactCodeSymbolValue -Symbol $Payload[$i])
        if ($addend -gt 31) {
            $addend = [math]::Floor($addend / 32) + ($addend % 32)
        }
        $sum += $addend
        $factor = if ($factor -eq 2) { 1 } else { 2 }
    }
    $remainder = $sum % 32
    $check     = (32 - $remainder) % 32
    return $script:ArtifactCodeAlphabet[$check]
}

function ConvertTo-NormalizedArtifactCode {
    <#
        IB0192 input normalization, applied in the specified order. Returns a result
        object rather than throwing, so a caller can report the reason.

        Steps 1-4 normalize. Step 5 rejects U and any out-of-alphabet character.
        Step 6 rejects on length. Both run BEFORE the check character is consulted,
        which is what catches a dropped or added leading zero: a leading zero
        contributes factor x 0 = 0 to the sum and does not shift any other
        character's factor, so it does not change the check character at all.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$InputCode)

    $result = [ordered]@{
        IsValid   = $false
        Canonical = $null
        Reason    = $null
    }

    # 1. trim  2. strip separators  3. uppercase
    $work = $InputCode.Trim()
    $work = $work -replace '[-\s_]', ''
    $work = $work.ToUpperInvariant()

    # 4. fold the confusable forms: I and L read as 1, O reads as 0
    $work = $work -replace '[IL]', '1'
    $work = $work -replace 'O', '0'

    # 5. reject U explicitly, then anything else outside the alphabet
    if ($work.Contains('U')) {
        $result.Reason = "Contains 'U', which is excluded from the alphabet and is not folded."
        return [pscustomobject]$result
    }
    foreach ($c in $work.ToCharArray()) {
        if ($script:ArtifactCodeAlphabet.IndexOf($c) -lt 0) {
            $result.Reason = "Contains '$c', which is not in the artifact code alphabet."
            return [pscustomobject]$result
        }
    }

    # 6. length, before the check character is consulted
    if ($work.Length -ne 10) {
        $result.Reason = "Length is $($work.Length) after normalization; a canonical code is exactly 10 characters."
        return [pscustomobject]$result
    }

    $result.IsValid   = $true
    $result.Canonical = $work
    return [pscustomobject]$result
}

function Get-ArtifactCodePart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CanonicalCode,
        [Parameter(Mandatory)][ValidateSet('Series', 'Random', 'Payload', 'Check')][string]$Part
    )

    switch ($Part) {
        'Series'  { return $CanonicalCode.Substring(0, 3) }
        'Random'  { return $CanonicalCode.Substring(3, 6) }
        'Payload' { return $CanonicalCode.Substring(0, 9) }
        'Check'   { return $CanonicalCode.Substring(9, 1) }
    }
}

function Test-ArtifactCodeSeriesAllocatable {
    <#
        IB0192 R2.1: validation accepts the full three-character Crockford space,
        but an ALLOCATOR issues zero-padded decimal 001-999 only. 000 is reserved so
        an all-zero code is never a live artifact; 001 is the unserialized Prague and
        Vienna cards and no codes exist in it.

        Returns a result object. Minting is the only path that consults this.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Series)

    $result = [ordered]@{ IsAllocatable = $false; Reason = $null }

    if ($Series -notmatch '^[0-9]{3}$') {
        $result.Reason = "Series '$Series' is not zero-padded decimal. Allocation issues 001-999; values above 999 in the Crockford space are reserved and unallocated (IB0192 R2.1)."
        return [pscustomobject]$result
    }
    if ($Series -eq '000') {
        $result.Reason = "Series 000 is reserved and never allocated, so that an all-zero code is never a live artifact (IB0192 R2.1)."
        return [pscustomobject]$result
    }
    if ($Series -eq '001') {
        $result.Reason = "Series 001 is the unserialized Prague and Vienna cards. No codes are ever minted into it (IB0192 series registry)."
        return [pscustomobject]$result
    }

    $result.IsAllocatable = $true
    return [pscustomobject]$result
}

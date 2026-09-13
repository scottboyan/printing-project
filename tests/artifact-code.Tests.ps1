# file_name    : tests/artifact-code.Tests.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Pin the code format to IB0192 rather than to the implementation.
# related_docs : IB0192 (test vectors, R5 measurements, Verification Steps);
#                IB0193 (WP03.T02); doc_2007 (1.3 cover the call site)

BeforeAll {
    Set-StrictMode -Version Latest

    $script:CodesDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'processors/codes'
    $script:Mint     = Join-Path $script:CodesDir 'new-artifact-code.ps1'
    $script:Validate = Join-Path $script:CodesDir 'test-artifact-code.ps1'
    $script:Convert  = Join-Path $script:CodesDir 'convert-artifact-code-format.ps1'

    . (Join-Path $script:CodesDir 'artifact-code-lib.ps1')
}

Describe 'IB0192 test vectors (normative)' {
    # These are the tiebreaker for the Luhn mod 32 parity convention. If any one of
    # them fails, the implementation is not the specified format, whatever else passes.
    It 'computes check character <Check> for payload <Payload>' -ForEach @(
        @{ Payload = '002000000'; Check = 'W' }
        @{ Payload = '00200000A'; Check = '8' }
        @{ Payload = '002ZZZZZZ'; Check = '2' }
        @{ Payload = '00212345A'; Check = 'K' }
        @{ Payload = '050ABCDEF'; Check = '9' }
        @{ Payload = '999ZZZZZZ'; Check = 'S' }
        @{ Payload = '000000000'; Check = '0' }
        @{ Payload = '0027X9K2M'; Check = 'Z' }
    ) {
        Get-ArtifactCodeCheckCharacter -Payload $Payload | Should -BeExactly $Check
    }

    It 'validates the full canonical code for payload <Payload>' -ForEach @(
        @{ Payload = '002000000'; Check = 'W' }
        @{ Payload = '00200000A'; Check = '8' }
        @{ Payload = '002ZZZZZZ'; Check = '2' }
        @{ Payload = '00212345A'; Check = 'K' }
        @{ Payload = '050ABCDEF'; Check = '9' }
        @{ Payload = '999ZZZZZZ'; Check = 'S' }
        @{ Payload = '000000000'; Check = '0' }
        @{ Payload = '0027X9K2M'; Check = 'Z' }
    ) {
        $params = @{ Code = "$Payload$Check" }
        $result = & $script:Validate @params
        $result.IsValid   | Should -BeTrue
        $result.Canonical | Should -BeExactly "$Payload$Check"
    }
}

Describe 'IB0192 R5 error detection (exhaustive)' {
    It 'detects all 279 single-character substitutions on 0027X9K2M' {
        $reference = '0027X9K2M'
        $expected  = Get-ArtifactCodeCheckCharacter -Payload $reference
        $alphabet  = Get-ArtifactCodeAlphabet

        $tested = 0
        $missed = 0
        for ($i = 0; $i -lt $reference.Length; $i++) {
            foreach ($c in $alphabet.ToCharArray()) {
                if ($c -eq $reference[$i]) { continue }
                $tested++
                $mutated = $reference.Substring(0, $i) + $c + $reference.Substring($i + 1)
                if ((Get-ArtifactCodeCheckCharacter -Payload $mutated) -eq $expected) { $missed++ }
            }
        }
        $tested | Should -Be 279
        $missed | Should -Be 0
    }

    It 'misses exactly 16 of 7936 adjacent transpositions on 0027X9K2M' {
        # This figure, not the vectors, is what proves the parity convention. The
        # factor starts at 2 on the RIGHTMOST payload character; starting it at the
        # left produces a different miss count.
        $reference = '0027X9K2M'
        $alphabet  = Get-ArtifactCodeAlphabet

        $tested = 0
        $missed = 0
        for ($i = 0; $i -lt $reference.Length - 1; $i++) {
            foreach ($a in $alphabet.ToCharArray()) {
                foreach ($b in $alphabet.ToCharArray()) {
                    if ($a -eq $b) { continue }
                    $tested++
                    $head = $reference.Substring(0, $i)
                    $tail = $reference.Substring($i + 2)
                    $one = Get-ArtifactCodeCheckCharacter -Payload ($head + $a + $b + $tail)
                    $two = Get-ArtifactCodeCheckCharacter -Payload ($head + $b + $a + $tail)
                    if ($one -eq $two) { $missed++ }
                }
            }
        }
        $tested | Should -Be 7936
        $missed | Should -Be 16
    }
}

Describe 'IB0192 input normalization' {
    It 'folds <Raw> to the canonical code' -ForEach @(
        @{ Raw = 'oo2-7x9k2m-z' }
        @{ Raw = '002 7X9K2M Z' }
        @{ Raw = '0027X9K2MZ' }
        @{ Raw = '  002_7X9K2M_Z  ' }
    ) {
        $params = @{ Code = $Raw }
        (& $script:Validate @params).Canonical | Should -BeExactly '0027X9K2MZ'
    }

    It 'folds I and L to 1 and O to 0' {
        # 002I2345AK normalizes to 00212345AK, a known good vector.
        foreach ($raw in '002I2345AK', '002l2345AK', 'OO2I2345AK', 'oo2L2345ak') {
            $params = @{ Code = $raw }
            (& $script:Validate @params).Canonical | Should -BeExactly '00212345AK'
        }
    }

    It 'rejects U rather than folding it' {
        $params = @{ Code = '0027X9K2MU' }
        $result = & $script:Validate @params
        $result.IsValid | Should -BeFalse
        $result.Reason  | Should -Match 'U'
    }

    It 'rejects a nine-character input on length before consulting the check character' {
        # A leading zero contributes 0 to the sum and does not shift any other
        # character factor, so dropping one does NOT change the check character.
        # The length rule is the only thing that catches it, which is why it runs first.
        $params = @{ Code = '027X9K2MZ' }
        $result = & $script:Validate @params
        $result.IsValid | Should -BeFalse
        $result.Reason  | Should -Match 'Length is 9'
    }

    It 'confirms a dropped leading zero does not change the check character' {
        # The safety consequence stated in IB0192: this class of error is caught by
        # the length rule, never by the check character.
        Get-ArtifactCodeCheckCharacter -Payload '002000000' |
            Should -BeExactly (Get-ArtifactCodeCheckCharacter -Payload '02000000')
    }

    It 'rejects a wrong check character' {
        $params = @{ Code = '0027X9K2MA' }
        $result = & $script:Validate @params
        $result.IsValid | Should -BeFalse
        $result.Reason  | Should -Match 'computes'
    }

    It 'rejects an empty input on length' {
        $params = @{ Code = '' }
        (& $script:Validate @params).IsValid | Should -BeFalse
    }
}

Describe 'IB0192 code forms' {
    It 'converts to <Format>' -ForEach @(
        @{ Format = 'Canonical'; Expected = '0027X9K2MZ' }
        @{ Format = 'Display';   Expected = '002-7X9K2M-Z' }
        @{ Format = 'Url';       Expected = 'https://scottboyan.com/artifact/0027X9K2MZ' }
    ) {
        $params = @{ Code = '0027X9K2MZ'; Format = $Format }
        & $script:Convert @params | Should -BeExactly $Expected
    }

    It 'accepts any input form and returns the same URL' {
        foreach ($form in '0027X9K2MZ', '002-7X9K2M-Z', 'oo2-7x9k2m-z') {
            $params = @{ Code = $form; Format = 'Url' }
            & $script:Convert @params | Should -BeExactly 'https://scottboyan.com/artifact/0027X9K2MZ'
        }
    }

    It 'emits a KDR-15 conforming URL: https, apex host, no www, no trailing slash' {
        $params = @{ Code = '0027X9K2MZ'; Format = 'Url' }
        $url = & $script:Convert @params
        $url | Should -Match ([regex]'^https://scottboyan\.com/artifact/[0-9A-HJKMNP-TV-Z]{10}$')
        $url | Should -Not -Match 'www'
        $url.EndsWith('/') | Should -BeFalse
    }

    It 'refuses to convert an invalid code' {
        $params = @{ Code = '0027X9K2MA'; Format = 'Url' }
        { & $script:Convert @params } | Should -Throw
    }
}

Describe 'IB0192 R4 generation' {
    It 'mints 5000 codes with no duplicates, all self-validating' {
        $params = @{ Series = '002'; Count = 5000 }
        $codes = & $script:Mint @params
        $codes.Count | Should -Be 5000

        $unique = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($c in $codes) { [void]$unique.Add($c.Code) }
        $unique.Count | Should -Be 5000

        foreach ($c in $codes) {
            $payload = Get-ArtifactCodePart -CanonicalCode $c.Code -Part 'Payload'
            Get-ArtifactCodeCheckCharacter -Payload $payload | Should -BeExactly $c.Check
        }
    }

    It 'returns an array even for a single code (doc_2007 2.1)' {
        $params = @{ Series = '002' }
        $result = & $script:Mint @params
        $result -is [array] | Should -BeTrue
        $result.Count | Should -Be 1
    }

    It 'honours ExistingCodes and never remints them' {
        $params = @{ Series = '002'; Count = 200 }
        $first = & $script:Mint @params
        $existing = @($first | ForEach-Object { $_.Code })

        $params = @{ Series = '002'; Count = 200; ExistingCodes = $existing }
        $second = & $script:Mint @params

        $overlap = @($second | Where-Object { $existing -contains $_.Code })
        $overlap.Count | Should -Be 0
    }

    It 'refuses to mint into reserved or non-decimal series <Series>' -ForEach @(
        @{ Series = '000' }
        @{ Series = '001' }
        @{ Series = '1AB' }
        @{ Series = '99'  }
        @{ Series = ''    }
    ) {
        $params = @{ Series = $Series }
        { & $script:Mint @params } | Should -Throw
    }

    It 'mints into series 050 and 999, which are allocatable' {
        foreach ($s in '050', '999') {
            $params = @{ Series = $s; Count = 2 }
            $codes = & $script:Mint @params
            $codes.Count | Should -Be 2
            foreach ($c in $codes) { $c.Code.Substring(0, 3) | Should -BeExactly $s }
        }
    }

    It 'draws every symbol of the alphabet across a large sample' {
        $params = @{ Series = '002'; Count = 2000 }
        $codes = & $script:Mint @params
        $seen = [System.Collections.Generic.HashSet[char]]::new()
        foreach ($c in $codes) { foreach ($ch in $c.Random.ToCharArray()) { [void]$seen.Add($ch) } }
        $seen.Count | Should -Be 32
    }

    It 'applies the denylist screen' {
        $denylist = Get-Content (Join-Path $script:CodesDir 'code-denylist.json') -Raw | ConvertFrom-Json
        $params = @{ Series = '002'; Count = 2000 }
        $codes = & $script:Mint @params
        foreach ($c in $codes) {
            foreach ($bad in $denylist.substrings) {
                $c.Random.Contains($bad) | Should -BeFalse -Because "denylisted substring $bad must never survive the screen"
            }
        }
    }
}

Describe 'KDR-10: Get-Random is forbidden on the minting path' {
    It 'has no Get-Random command invocation in any codes processor' {
        # An AST assertion, not a text search: the mint processor carries a comment
        # explaining why Get-Random is forbidden, and a grep would flag that comment.
        # doc_2007 1.3 is the precedent - cover the call site, and cover it properly.
        $files = Get-ChildItem -Path $script:CodesDir -Filter '*.ps1'
        $files.Count | Should -BeGreaterThan 0

        foreach ($file in $files) {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            $errors.Count | Should -Be 0 -Because "$($file.Name) must parse cleanly"

            $commands = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
            foreach ($command in $commands) {
                $name = $command.GetCommandName()
                if ($null -ne $name) {
                    $name | Should -Not -Be 'Get-Random' -Because "$($file.Name) is on the minting path (KDR-10)"
                }
            }
        }
    }

    It 'uses RandomNumberGenerator in the mint processor' {
        (Get-Content $script:Mint -Raw) | Should -Match 'RandomNumberGenerator'
    }
}

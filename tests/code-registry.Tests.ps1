# file_name    : tests/code-registry.Tests.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Pester coverage for the registry invariants.
# related_docs : IB0192 (registry schema, R6 states, write-once timestamps);
#                IB0193 (WP04.T02, KDR-22)

BeforeAll {
    Set-StrictMode -Version Latest

    $root = Split-Path -Parent $PSScriptRoot
    $script:RegistryDir = Join-Path $root 'processors/registry'
    $script:CodesDir    = Join-Path $root 'processors/codes'

    $script:NewRegistry = Join-Path $script:RegistryDir 'new-code-registry.ps1'
    $script:AddEntry    = Join-Path $script:RegistryDir 'add-code-registry-entry.ps1'
    $script:TestReg     = Join-Path $script:RegistryDir 'test-code-registry.ps1'
    $script:SetPlace    = Join-Path $script:RegistryDir 'set-code-registry-placement.ps1'
    $script:SetStatus   = Join-Path $script:RegistryDir 'set-code-registry-entry-status.ps1'
    $script:CloseReg    = Join-Path $script:RegistryDir 'close-code-registry.ps1'

    $script:Mint    = Join-Path $script:CodesDir 'new-artifact-code.ps1'
    $script:Convert = Join-Path $script:CodesDir 'convert-artifact-code-format.ps1'

    # A fresh registry per test, in the test drive, never under data/series.
    function New-TestRegistry {
        param([int]$CodeCount = 3, [string]$Series = '002')

        $path = Join-Path $TestDrive "series-$Series-$([System.Guid]::NewGuid().ToString('N')).json"
        $params = @{ Series = $Series; SeriesName = "Test series $Series"; Path = $path }
        $created = & $script:NewRegistry @params
        if (-not $created.Success) { throw "could not create test registry: $($created.Reason)" }

        if ($CodeCount -gt 0) {
            $params = @{ Series = $Series; Count = $CodeCount }
            foreach ($code in (& $script:Mint @params)) {
                $params = @{ Code = $code.Code; Format = 'Display' }
                $display = & $script:Convert @params
                $params = @{ Code = $code.Code; Format = 'Url' }
                $url = & $script:Convert @params

                $params = @{ Path = $path; Code = $code.Code; Display = $display; Url = $url }
                $added = & $script:AddEntry @params
                if (-not $added.Success) { throw "could not add test code: $($added.Reason)" }
            }
        }
        return $path
    }
}

Describe 'Registry creation' {
    It 'emits a document that validates against the IB0192 schema' {
        $path = New-TestRegistry -CodeCount 3
        $params = @{ Path = $path }
        $result = & $script:TestReg @params
        $result.IsValid | Should -BeTrue -Because ($result.Failures -join '; ')
        $result.Count   | Should -Be 3
    }

    It 'stores series as a string so the zero padding survives' {
        $path = New-TestRegistry -CodeCount 1
        $registry = Get-Content $path -Raw | ConvertFrom-Json -DateKind String
        $registry.series | Should -BeOfType [string]
        $registry.series | Should -BeExactly '002'
        (Get-Content $path -Raw) | Should -Match '"series": "002"'
    }

    It 'records algorithm provenance' {
        $path = New-TestRegistry -CodeCount 0
        $registry = Get-Content $path -Raw | ConvertFrom-Json -DateKind String
        $registry.algorithm.spec         | Should -BeExactly 'IB0192'
        $registry.algorithm.alphabet     | Should -BeExactly '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
        $registry.algorithm.series_chars | Should -Be 3
        $registry.algorithm.random_chars | Should -Be 6
        $registry.algorithm.check        | Should -BeExactly 'luhn-mod-32'
    }

    It 'refuses to overwrite an existing registry without an override' {
        $path = New-TestRegistry -CodeCount 1
        $params = @{ Series = '002'; SeriesName = 'Again'; Path = $path }
        $result = & $script:NewRegistry @params
        $result.Success | Should -BeFalse
        $result.Reason  | Should -Match 'already exists'
    }

    It 'writes each code entry as a self-contained document for Firestore import' {
        $path = New-TestRegistry -CodeCount 2
        $registry = Get-Content $path -Raw | ConvertFrom-Json -DateKind String
        foreach ($entry in $registry.codes) {
            foreach ($field in 'code', 'display', 'url', 'sequence', 'sheet', 'cell', 'status', 'minted_at', 'printed_at', 'assigned_at', 'assigned_to') {
                $entry.PSObject.Properties.Name | Should -Contain $field
            }
            $entry.url | Should -BeExactly "https://scottboyan.com/artifact/$($entry.code)"
        }
    }
}

Describe 'Duplicate refusal' {
    It 'refuses a duplicate code and returns the refusal rather than throwing' {
        $path = New-TestRegistry -CodeCount 2
        $registry = Get-Content $path -Raw | ConvertFrom-Json -DateKind String
        $existing = $registry.codes[0]

        $params = @{ Path = $path; Code = $existing.code; Display = $existing.display; Url = $existing.url }
        $result = & $script:AddEntry @params

        $result.Success | Should -BeFalse
        $result.Reason  | Should -Match 'already recorded'
        $result.Count   | Should -Be 2   # unchanged
    }

    It 'refuses a code belonging to a different series' {
        $path = New-TestRegistry -CodeCount 1
        $params = @{ Path = $path; Code = '050ABCDEF9'; Display = '050-ABCDEF-9'; Url = 'https://scottboyan.com/artifact/050ABCDEF9' }
        $result = & $script:AddEntry @params
        $result.Success | Should -BeFalse
        $result.Reason  | Should -Match 'series'
    }
}

Describe 'Closed-series refusal' {
    It 'refuses every write once the series is closed' {
        $path = New-TestRegistry -CodeCount 2

        $params = @{ Path = $path }
        (& $script:CloseReg @params).Success | Should -BeTrue

        $params = @{ Path = $path; Code = '002ZZZZZZ2'; Display = '002-ZZZZZZ-2'; Url = 'https://scottboyan.com/artifact/002ZZZZZZ2' }
        $add = & $script:AddEntry @params
        $add.Success | Should -BeFalse
        $add.Reason  | Should -Match 'closed'

        $params = @{ Path = $path; Status = 'printed' }
        $status = & $script:SetStatus @params
        $status.Success | Should -BeFalse
        $status.Reason  | Should -Match 'closed'

        $params = @{ Path = $path; Placements = @(@{ Code = '002ZZZZZZ2'; Sheet = 1; Cell = 1 }) }
        $place = & $script:SetPlace @params
        $place.Success | Should -BeFalse
        $place.Reason  | Should -Match 'closed'
    }

    It 'refuses to close a series twice' {
        $path = New-TestRegistry -CodeCount 1
        $params = @{ Path = $path }
        (& $script:CloseReg @params).Success | Should -BeTrue
        $second = & $script:CloseReg @params
        $second.Success | Should -BeFalse
        $second.Reason  | Should -Match 'already closed'
    }
}

Describe 'Status advances forwards only' {
    It 'advances minted to printed and stamps printed_at' {
        $path = New-TestRegistry -CodeCount 3
        $params = @{ Path = $path; Status = 'printed' }
        $result = & $script:SetStatus @params
        $result.Success | Should -BeTrue
        $result.Updated | Should -Be 3

        $registry = Get-Content $path -Raw | ConvertFrom-Json -DateKind String
        foreach ($entry in $registry.codes) {
            $entry.status     | Should -BeExactly 'printed'
            $entry.printed_at | Should -Not -BeNullOrEmpty
            $entry.printed_at | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z'
        }
    }

    It 'refuses a backwards transition' {
        $path = New-TestRegistry -CodeCount 2
        $params = @{ Path = $path; Status = 'printed' }
        (& $script:SetStatus @params).Success | Should -BeTrue

        $params = @{ Path = $path; Status = 'minted' }
        $result = & $script:SetStatus @params
        $result.Success     | Should -BeFalse
        $result.Failures[0] | Should -Match 'backwards'
    }

    It 'refuses to overwrite a write-once timestamp' {
        $path = New-TestRegistry -CodeCount 2
        $params = @{ Path = $path; Status = 'printed' }
        (& $script:SetStatus @params).Success | Should -BeTrue

        $params = @{ Path = $path; Status = 'printed' }
        $result = & $script:SetStatus @params
        $result.Success     | Should -BeFalse
        $result.Failures[0] | Should -Match 'write-once'
    }

    It 'refuses the whole batch when any single transition is refused' {
        # A half-advanced registry after an irreversible physical act is worse than
        # a refused one.
        $path = New-TestRegistry -CodeCount 3
        $registry = Get-Content $path -Raw | ConvertFrom-Json -DateKind String
        $one = $registry.codes[0].code

        $params = @{ Path = $path; Codes = @($one); Status = 'printed' }
        (& $script:SetStatus @params).Success | Should -BeTrue

        # Now advance ALL of them: the first already has printed_at, so nothing moves.
        $params = @{ Path = $path; Status = 'printed' }
        $result = & $script:SetStatus @params
        $result.Success | Should -BeFalse

        $after = Get-Content $path -Raw | ConvertFrom-Json -DateKind String
        $stillMinted = @($after.codes | Where-Object { $_.status -eq 'minted' })
        $stillMinted.Count | Should -Be 2 -Because 'no partial write may have occurred'
    }

    It 'reports an unknown code rather than silently skipping it' {
        $path = New-TestRegistry -CodeCount 1
        $params = @{ Path = $path; Codes = @('002ZZZZZZ2'); Status = 'printed' }
        $result = & $script:SetStatus @params
        $result.Success     | Should -BeFalse
        $result.Failures[0] | Should -Match 'not in this registry'
    }
}

Describe 'Placement' {
    It 'records sheet and cell' {
        $path = New-TestRegistry -CodeCount 3
        $registry = Get-Content $path -Raw | ConvertFrom-Json -DateKind String
        $codes = @($registry.codes | ForEach-Object { $_.code })

        $params = @{ Path = $path; Placements = @(
            @{ Code = $codes[0]; Sheet = 1; Cell = 1 },
            @{ Code = $codes[1]; Sheet = 1; Cell = 20 },
            @{ Code = $codes[2]; Sheet = 2; Cell = 7 }
        ) }
        $result = & $script:SetPlace @params
        $result.Success | Should -BeTrue
        $result.Updated | Should -Be 3

        $after = Get-Content $path -Raw | ConvertFrom-Json -DateKind String
        $after.codes[0].sheet | Should -Be 1
        $after.codes[0].cell  | Should -Be 1
        $after.codes[2].sheet | Should -Be 2
        $after.codes[2].cell  | Should -Be 7
    }

    It 'writes nothing when any placement names an unknown code' {
        $path = New-TestRegistry -CodeCount 2
        $registry = Get-Content $path -Raw | ConvertFrom-Json -DateKind String
        $known = $registry.codes[0].code

        $params = @{ Path = $path; Placements = @(
            @{ Code = $known;        Sheet = 1; Cell = 1 },
            @{ Code = '002ZZZZZZ2';  Sheet = 1; Cell = 2 }
        ) }
        $result = & $script:SetPlace @params
        $result.Success | Should -BeFalse

        $after = Get-Content $path -Raw | ConvertFrom-Json -DateKind String
        $after.codes[0].sheet | Should -BeNullOrEmpty -Because 'nothing may be written when any placement fails'
    }
}

Describe 'Validation catches corruption' {
    It 'fails a registry containing a code with a bad check character' {
        $path = New-TestRegistry -CodeCount 3
        $raw = Get-Content $path -Raw
        $registry = $raw | ConvertFrom-Json -DateKind String
        $good = $registry.codes[0].code
        $swap = if ($good[9] -eq 'A') { 'B' } else { 'A' }
        $bad  = $good.Substring(0, 9) + $swap

        $corrupted = Join-Path $TestDrive "bad-$([System.Guid]::NewGuid().ToString('N')).json"
        [System.IO.File]::WriteAllText($corrupted, $raw.Replace($good, $bad), [System.Text.UTF8Encoding]::new($false))

        $params = @{ Path = $corrupted }
        $result = & $script:TestReg @params
        $result.IsValid | Should -BeFalse
        ($result.Failures -join '; ') | Should -Match 'check character'
    }

    It 'fails a registry containing a duplicated code' {
        $path = New-TestRegistry -CodeCount 3
        $registry = Get-Content $path -Raw | ConvertFrom-Json -DateKind String
        $registry.codes[1].code = $registry.codes[0].code

        $corrupted = Join-Path $TestDrive "dup-$([System.Guid]::NewGuid().ToString('N')).json"
        [System.IO.File]::WriteAllText($corrupted, ($registry | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))

        $params = @{ Path = $corrupted }
        $result = & $script:TestReg @params
        $result.IsValid | Should -BeFalse
        ($result.Failures -join '; ') | Should -Match 'more than once'
    }

    It 'fails a registry whose series has been coerced to a number' {
        $path = New-TestRegistry -CodeCount 2
        $raw = (Get-Content $path -Raw).Replace('"series": "002"', '"series": 2')
        $corrupted = Join-Path $TestDrive "num-$([System.Guid]::NewGuid().ToString('N')).json"
        [System.IO.File]::WriteAllText($corrupted, $raw, [System.Text.UTF8Encoding]::new($false))

        $params = @{ Path = $corrupted }
        $result = & $script:TestReg @params
        $result.IsValid | Should -BeFalse
        ($result.Failures -join '; ') | Should -Match 'must be a string'
    }

    It 'fails a registry whose count disagrees with the codes array' {
        $path = New-TestRegistry -CodeCount 2
        $raw = (Get-Content $path -Raw).Replace('"count": 2', '"count": 5')
        $corrupted = Join-Path $TestDrive "count-$([System.Guid]::NewGuid().ToString('N')).json"
        [System.IO.File]::WriteAllText($corrupted, $raw, [System.Text.UTF8Encoding]::new($false))

        $params = @{ Path = $corrupted }
        $result = & $script:TestReg @params
        $result.IsValid | Should -BeFalse
        ($result.Failures -join '; ') | Should -Match 'count'
    }

    It 'fails a registry claiming printed with no printed_at' {
        $path = New-TestRegistry -CodeCount 2
        $registry = Get-Content $path -Raw | ConvertFrom-Json -DateKind String
        $registry.codes[0].status = 'printed'

        $corrupted = Join-Path $TestDrive "nostamp-$([System.Guid]::NewGuid().ToString('N')).json"
        [System.IO.File]::WriteAllText($corrupted, ($registry | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))

        $params = @{ Path = $corrupted }
        $result = & $script:TestReg @params
        $result.IsValid | Should -BeFalse
        ($result.Failures -join '; ') | Should -Match 'printed_at is null'
    }

    It 'reports a missing file rather than throwing' {
        $params = @{ Path = (Join-Path $TestDrive 'does-not-exist.json') }
        $result = & $script:TestReg @params
        $result.IsValid     | Should -BeFalse
        $result.Failures[0] | Should -Match 'not found'
    }
}

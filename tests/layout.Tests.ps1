# file_name    : tests/layout.Tests.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Pin the derived sheet geometry to IB0193 and cover the printer
#                calibration mechanism and print/proof parity.
# related_docs : IB0193 (KDR-11, KDR-12, KDR-13, WP05.T02, WP07.T03)
#
# The split here is deliberate. The DERIVED grid is normative and must never drift,
# so it is pinned to the literal values in the brief. The CALIBRATION is per-printer
# and changes every proof round, so it is tested through a fixture rather than by
# pinning whatever the operator's current offsets happen to be. Pinning those would
# make the suite fail on every calibration pass, which trains people to ignore it.

BeforeAll {
    Set-StrictMode -Version Latest

    $script:Root         = Split-Path -Parent $PSScriptRoot
    $script:GetTemplate  = Join-Path $script:Root 'processors/layout/get-label-template.ps1'
    $script:NewSheet     = Join-Path $script:Root 'processors/layout/new-label-sheet-pdf.ps1'
    $script:NewQr        = Join-Path $script:Root 'processors/qr/new-qr-image.ps1'
    $script:TemplateDir  = Join-Path $script:Root 'templates'
    $script:MmToPt       = 72.0 / 25.4

    function New-TemplateFixture {
        param([hashtable]$Calibration, [string]$ProductId)

        $source = Get-Content (Join-Path $script:TemplateDir 'avery-94106.json') -Raw | ConvertFrom-Json
        if ($null -eq $Calibration) {
            $source.PSObject.Properties.Remove('calibration')
        } else {
            $source.calibration = [pscustomobject]$Calibration
        }
        $directory = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $path = Join-Path $directory "avery-$ProductId.json"
        [System.IO.File]::WriteAllText($path, ($source | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))
        return $directory
    }
}

Describe 'IB0193 derived geometry (normative, must never drift)' {
    It 'keeps the column and row origins extracted from the Series 1 sheet' {
        $template = Get-Content (Join-Path $script:TemplateDir 'avery-94106.json') -Raw | ConvertFrom-Json
        @($template.grid.column_origins_pt) | Should -Be @(36, 180, 324, 468)
        @($template.grid.row_origins_pt)    | Should -Be @(639, 490.5, 342, 193.5, 45)
        $template.grid.column_pitch_pt      | Should -Be 144.0
        $template.grid.row_pitch_pt         | Should -Be 148.5
    }

    It 'keeps the page, cell, and safe area the brief specifies' {
        $template = Get-Content (Join-Path $script:TemplateDir 'avery-94106.json') -Raw | ConvertFrom-Json
        $template.page.width_pt        | Should -Be 612
        $template.page.height_pt       | Should -Be 792
        $template.cell.width_pt        | Should -Be 117
        $template.cell.height_pt       | Should -Be 117
        $template.cell.offset_x_pt     | Should -Be -4.5
        $template.cell.offset_y_pt     | Should -Be -4.5
        $template.safe_area.width_pt   | Should -Be 100
        $template.safe_area.height_pt  | Should -Be 100
        $template.grid.cells_per_sheet | Should -Be 20
    }

    It 'produces the 31.5 / 40.5 pt margins of IB0193 when calibration is zero' {
        # This is WP05.T02's success criterion. It holds for the DERIVED grid, so the
        # calibration is removed for the assertion rather than the criterion being
        # quietly restated to match whatever the printer needed.
        $directory = New-TemplateFixture -Calibration $null -ProductId '94106'
        $params = @{ ProductId = '94106'; TemplateDirectory = $directory }
        $template = & $script:GetTemplate @params

        $template.Cells.Count      | Should -Be 20
        $template.Margins.Left     | Should -Be 31.5
        $template.Margins.Right    | Should -Be 31.5
        $template.Margins.Top      | Should -Be 40.5
        $template.Margins.Bottom   | Should -Be 40.5
    }

    It 'numbers cells row-major from the top-left' {
        $directory = New-TemplateFixture -Calibration $null -ProductId '94106'
        $params = @{ ProductId = '94106'; TemplateDirectory = $directory }
        $template = & $script:GetTemplate @params

        $template.Cells[0].Number  | Should -Be 1
        $template.Cells[0].OriginX | Should -Be 36
        $template.Cells[0].OriginY | Should -Be 639
        $template.Cells[3].OriginX | Should -Be 468
        $template.Cells[3].OriginY | Should -Be 639
        $template.Cells[4].OriginX | Should -Be 36
        $template.Cells[4].OriginY | Should -Be 490.5
        $template.Cells[19].OriginX | Should -Be 468
        $template.Cells[19].OriginY | Should -Be 45
    }
}

Describe 'Printer calibration' {
    It 'applies a global offset in millimetres to every cell' {
        $directory = New-TemplateFixture -ProductId '94106' -Calibration @{
            unit = 'mm'; global_offset_mm = @{ x = -2.0; y = 1.0 }; row_offsets_mm = @(0, 0, 0, 0, 0)
        }
        $params = @{ ProductId = '94106'; TemplateDirectory = $directory }
        $template = & $script:GetTemplate @params

        [math]::Abs($template.Cells[0].OriginX - ((36 - (2.0 * $script:MmToPt)))) | Should -BeLessThan 0.0001
        [math]::Abs($template.Cells[0].OriginY - ((639 + (1.0 * $script:MmToPt)))) | Should -BeLessThan 0.0001
        [math]::Abs($template.Cells[19].OriginX - ((468 - (2.0 * $script:MmToPt)))) | Should -BeLessThan 0.0001
        [math]::Abs($template.Cells[19].OriginY - ((45 + (1.0 * $script:MmToPt)))) | Should -BeLessThan 0.0001
    }

    It 'applies a per-row offset to that row only, top row first' {
        # Row offsets are the easiest thing to wire to the wrong row, and the error
        # is invisible until a sheet is printed and measured.
        $directory = New-TemplateFixture -ProductId '94106' -Calibration @{
            unit = 'mm'; global_offset_mm = @{ x = 0.0; y = 0.0 }
            row_offsets_mm = @(0, 0, 0, 0.5, 0.75)
        }
        $params = @{ ProductId = '94106'; TemplateDirectory = $directory }
        $template = & $script:GetTemplate @params

        # Rows 1-3 (cells 1-12) untouched: cell number -> expected row origin.
        $untouched = @{ 1 = 639.0; 4 = 639.0; 5 = 490.5; 8 = 490.5; 9 = 342.0; 12 = 342.0 }
        foreach ($number in $untouched.Keys) {
            $cell = $template.Cells | Where-Object { $_.Number -eq $number }
            [math]::Abs($cell.OriginY - $untouched[$number]) | Should -BeLessThan 0.0001 -Because "cell $number is in an uncalibrated row"
        }
        # Row 4 is cells 13-16, up 0.5 mm.
        foreach ($number in 13, 16) {
            $cell = $template.Cells | Where-Object { $_.Number -eq $number }
            [math]::Abs($cell.OriginY - ((193.5 + (0.5 * $script:MmToPt)))) | Should -BeLessThan 0.0001
        }
        # Row 5 is cells 17-20, up 0.75 mm.
        foreach ($number in 17, 20) {
            $cell = $template.Cells | Where-Object { $_.Number -eq $number }
            [math]::Abs($cell.OriginY - ((45 + (0.75 * $script:MmToPt)))) | Should -BeLessThan 0.0001
        }
    }

    It 'leaves the column and row pitch untouched by a global offset' {
        $directory = New-TemplateFixture -ProductId '94106' -Calibration @{
            unit = 'mm'; global_offset_mm = @{ x = -1.675; y = 0.0 }; row_offsets_mm = @(0, 0, 0, 0, 0)
        }
        $params = @{ ProductId = '94106'; TemplateDirectory = $directory }
        $template = & $script:GetTemplate @params

        $row1 = @($template.Cells | Where-Object { $_.Number -le 4 } | Sort-Object Number)
        for ($i = 1; $i -lt $row1.Count; $i++) {
            [math]::Abs(($row1[$i].OriginX - $row1[$i - 1].OriginX) - (144.0)) | Should -BeLessThan 0.0001
        }
    }

    It 'refuses a row-offset array that does not match the number of rows' {
        $directory = New-TemplateFixture -ProductId '94106' -Calibration @{
            unit = 'mm'; global_offset_mm = @{ x = 0.0; y = 0.0 }; row_offsets_mm = @(0, 0, 0)
        }
        $params = @{ ProductId = '94106'; TemplateDirectory = $directory }
        { & $script:GetTemplate @params } | Should -Throw '*must be parallel*'
    }

    It 'refuses a unit it does not understand' {
        $directory = New-TemplateFixture -ProductId '94106' -Calibration @{
            unit = 'inches'; global_offset_mm = @{ x = 0.0; y = 0.0 }
        }
        $params = @{ ProductId = '94106'; TemplateDirectory = $directory }
        { & $script:GetTemplate @params } | Should -Throw '*mm*'
    }

    It 'refuses an offset that would push a cell off the media' {
        $directory = New-TemplateFixture -ProductId '94106' -Calibration @{
            unit = 'mm'; global_offset_mm = @{ x = -20.0; y = 0.0 }; row_offsets_mm = @(0, 0, 0, 0, 0)
        }
        $params = @{ ProductId = '94106'; TemplateDirectory = $directory }
        { & $script:GetTemplate @params } | Should -Throw '*outside*'
    }
}

Describe 'Print and proof sheets stay in exact parity' {
    It 'places identical content whether or not guides are drawn' {
        # The operator iterates registration on the proof sheet and prints from the
        # plain sheet. If the two ever diverged geometrically, every proof would be
        # calibrating something that is not what gets printed.
        $params = @{ ProductId = '94106' }
        $template = & $script:GetTemplate @params

        $params = @{ Payload = 'https://scottboyan.com/artifact/0027X9K2MZ' }
        $symbol = & $script:NewQr @params

        $content = @(
            @{ Cell = 1;  ImageBytes = $symbol.Bytes; TopText = 'FIND IT!  SNAP IT!'; BottomText = '002-7X9K2M-Z' }
            @{ Cell = 13; ImageBytes = $symbol.Bytes; TopText = 'FIND IT!  SNAP IT!'; BottomText = '002-7X9K2M-Z' }
            @{ Cell = 20; ImageBytes = $symbol.Bytes; TopText = 'FIND IT!  SNAP IT!'; BottomText = '002-7X9K2M-Z' }
        )

        $params = @{ Template = $template; Content = $content; OutputPath = (Join-Path $TestDrive 'plain.pdf') }
        $plain = & $script:NewSheet @params

        $params = @{ Template = $template; Content = $content; OutputPath = (Join-Path $TestDrive 'proof.pdf'); DrawGuides = $true; GuideWeight = 1.2 }
        $proof = & $script:NewSheet @params

        $plain.Placements.Count | Should -Be $proof.Placements.Count
        for ($i = 0; $i -lt $plain.Placements.Count; $i++) {
            $a = $plain.Placements[$i]
            $b = $proof.Placements[$i]
            $b.Cell           | Should -Be $a.Cell
            $b.TopTextSize    | Should -Be $a.TopTextSize
            $b.BottomTextSize | Should -Be $a.BottomTextSize
            $b.ImageBox.Left  | Should -Be $a.ImageBox.Left
            $b.ImageBox.Top   | Should -Be $a.ImageBox.Top
            $b.ImageBox.Size  | Should -Be $a.ImageBox.Size
        }
    }
}

Describe 'Per-column calibration' {
    It 'applies a per-column offset to that column only, left column first' {
        $directory = New-TemplateFixture -ProductId '94106' -Calibration @{
            unit = 'mm'; global_offset_mm = @{ x = 0.0; y = 0.0 }
            row_offsets_mm = @(0, 0, 0, 0, 0); column_offsets_mm = @(0, -0.4, 0, 0.6)
        }
        $params = @{ ProductId = '94106'; TemplateDirectory = $directory }
        $template = & $script:GetTemplate @params

        # Columns are cells n, n+1, n+2, n+3 within each row.
        $expected = @{ 1 = 36.0; 2 = 180.0 - (0.4 * $script:MmToPt); 3 = 324.0; 4 = 468.0 + (0.6 * $script:MmToPt) }
        foreach ($column in 1, 2, 3, 4) {
            foreach ($row in 0, 4) {          # first row and second row
                $cell = $template.Cells | Where-Object { $_.Number -eq ($row + $column) }
                [math]::Abs($cell.OriginX - $expected[$column]) | Should -BeLessThan 0.0001 -Because "cell $($row + $column) is in column $column"
            }
        }
    }

    It 'refuses a column-offset array that does not match the number of columns' {
        $directory = New-TemplateFixture -ProductId '94106' -Calibration @{
            unit = 'mm'; global_offset_mm = @{ x = 0.0; y = 0.0 }; column_offsets_mm = @(0, 0)
        }
        $params = @{ ProductId = '94106'; TemplateDirectory = $directory }
        { & $script:GetTemplate @params } | Should -Throw '*must be parallel*'
    }

    It 'keeps row and column offsets independent' {
        $directory = New-TemplateFixture -ProductId '94106' -Calibration @{
            unit = 'mm'; global_offset_mm = @{ x = 0.0; y = 0.0 }
            row_offsets_mm = @(0, 0, 0, 0, 1.0); column_offsets_mm = @(0, 0, 0, 1.0)
        }
        $params = @{ ProductId = '94106'; TemplateDirectory = $directory }
        $template = & $script:GetTemplate @params

        # Cell 20 is bottom row, rightmost column: both offsets apply.
        $cell20 = $template.Cells | Where-Object { $_.Number -eq 20 }
        [math]::Abs($cell20.OriginY - (45 + (1.0 * $script:MmToPt)))  | Should -BeLessThan 0.0001
        [math]::Abs($cell20.OriginX - (468 + (1.0 * $script:MmToPt))) | Should -BeLessThan 0.0001

        # Cell 17 is bottom row, leftmost column: row offset only.
        $cell17 = $template.Cells | Where-Object { $_.Number -eq 17 }
        [math]::Abs($cell17.OriginY - (45 + (1.0 * $script:MmToPt))) | Should -BeLessThan 0.0001
        [math]::Abs($cell17.OriginX - 36.0)                          | Should -BeLessThan 0.0001
    }
}

Describe 'Calibration adjustment processor' {
    BeforeAll {
        $script:SetCalibration = Join-Path $script:Root 'processors/layout/set-label-template-calibration.ps1'

        function New-WritableTemplate {
            $directory = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            $path = Join-Path $directory 'avery-94106.json'
            Copy-Item (Join-Path $script:TemplateDir 'avery-94106.json') $path
            return $path
        }
    }

    It 'adds to the current value by default' {
        $path = New-WritableTemplate
        $before = (Get-Content $path -Raw | ConvertFrom-Json).calibration.row_offsets_mm[4]

        $params = @{ TemplatePath = $path; RowsUpMm = @{ 5 = 0.25 } }
        $result = & $script:SetCalibration @params

        $result.Rows[4].Before | Should -Be $before
        $result.Rows[4].After  | Should -Be ([math]::Round($before + 0.25, 4))
        $result.Rows[4].Delta  | Should -Be 0.25
    }

    It 'replaces the current value in absolute mode' {
        $path = New-WritableTemplate
        $params = @{ TemplatePath = $path; RowsUpMm = @{ 5 = 0.25 }; Absolute = $true }
        $result = & $script:SetCalibration @params
        $result.Rows[4].After | Should -Be 0.25
    }

    It 'zeroes everything on reset' {
        $path = New-WritableTemplate
        $params = @{ TemplatePath = $path; Reset = $true }
        $result = & $script:SetCalibration @params

        $result.GlobalAfter.RightMm | Should -Be 0
        $result.GlobalAfter.UpMm    | Should -Be 0
        foreach ($row in $result.Rows)       { $row.After    | Should -Be 0 }
        foreach ($column in $result.Columns) { $column.After | Should -Be 0 }
    }

    It 'never touches the derived grid' {
        $path = New-WritableTemplate
        $params = @{ TemplatePath = $path; RowsUpMm = @{ 2 = 1.5 }; ColumnsRightMm = @{ 3 = -0.75 }; GlobalRightMm = 2.0 }
        $null = & $script:SetCalibration @params

        $after = Get-Content $path -Raw | ConvertFrom-Json
        @($after.grid.column_origins_pt) | Should -Be @(36, 180, 324, 468)
        @($after.grid.row_origins_pt)    | Should -Be @(639, 490.5, 342, 193.5, 45)
        $after.cell.width_pt             | Should -Be 117
        $after.provenance.derived_from   | Should -Match '94106-Prague-QR.pdf'
    }

    It 'refuses a row or column that does not exist' {
        $path = New-WritableTemplate
        $params = @{ TemplatePath = $path; RowsUpMm = @{ 6 = 0.5 } }
        { & $script:SetCalibration @params } | Should -Throw '*Row 6 does not exist*'

        $params = @{ TemplatePath = $path; ColumnsRightMm = @{ 9 = 0.5 } }
        { & $script:SetCalibration @params } | Should -Throw '*Column 9 does not exist*'
    }

    It 'leaves the template untouched when the result would be invalid' {
        # The validate-then-write order is the point: a calibration that cannot
        # produce a sheet must not be able to destroy a template that could.
        $path = New-WritableTemplate
        $original = Get-Content $path -Raw

        $params = @{ TemplatePath = $path; GlobalRightMm = -50.0 }
        { & $script:SetCalibration @params } | Should -Throw '*outside*'

        (Get-Content $path -Raw) | Should -BeExactly $original
    }

    It 'appends to the calibration history rather than replacing it' {
        $path = New-WritableTemplate
        $before = @((Get-Content $path -Raw | ConvertFrom-Json).calibration.history).Count

        $params = @{ TemplatePath = $path; RowsUpMm = @{ 1 = 0.1 }; Note = 'test round' }
        $null = & $script:SetCalibration @params

        $history = @((Get-Content $path -Raw | ConvertFrom-Json).calibration.history)
        $history.Count | Should -Be ($before + 1)
        $history[-1].change | Should -Match 'row 1'
        $history[-1].after  | Should -BeExactly 'test round'
    }
}

Describe 'Die-cut guide inset' {
    It 'is the cell box itself when nothing has been measured' {
        # The honest default: before anyone has measured the stock, the best available
        # statement about the die-cut is the cell box. IB0193 R3 leaves it open.
        $directory = New-TemplateFixture -ProductId '94106' -Calibration @{
            unit = 'mm'; global_offset_mm = @{ x = 0.0; y = 0.0 }
        }
        $params = @{ ProductId = '94106'; TemplateDirectory = $directory }
        $template = & $script:GetTemplate @params

        $cell = $template.Cells[0]
        $cell.DieCut.Width  | Should -Be $cell.Box.Width
        $cell.DieCut.Height | Should -Be $cell.Box.Height
        $cell.DieCut.Left   | Should -Be $cell.Box.Left
        $cell.DieCut.Bottom | Should -Be $cell.Box.Bottom
    }

    It 'pulls the die-cut in by the measured inset on all four sides' {
        $directory = New-TemplateFixture -ProductId '94106' -Calibration @{
            unit = 'mm'; global_offset_mm = @{ x = 0.0; y = 0.0 }; guide_inset_mm = 1.7
        }
        $params = @{ ProductId = '94106'; TemplateDirectory = $directory }
        $template = & $script:GetTemplate @params

        $inset = 1.7 * $script:MmToPt
        foreach ($cell in $template.Cells) {
            [math]::Abs($cell.DieCut.Width  - (117 - 2 * $inset)) | Should -BeLessThan 0.0001
            [math]::Abs($cell.DieCut.Height - (117 - 2 * $inset)) | Should -BeLessThan 0.0001
            [math]::Abs($cell.DieCut.Left   - ($cell.Box.Left   + $inset)) | Should -BeLessThan 0.0001
            [math]::Abs($cell.DieCut.Bottom - ($cell.Box.Bottom + $inset)) | Should -BeLessThan 0.0001
        }
    }

    It 'keeps the die-cut concentric with the cell box' {
        $directory = New-TemplateFixture -ProductId '94106' -Calibration @{
            unit = 'mm'; global_offset_mm = @{ x = -2.175; y = 0.0 }
            row_offsets_mm = @(0.5, 0.5, 1.0, 1.0, 1.25); guide_inset_mm = 1.7
        }
        $params = @{ ProductId = '94106'; TemplateDirectory = $directory }
        $template = & $script:GetTemplate @params

        foreach ($cell in $template.Cells) {
            $boxCentreX = $cell.Box.Left + ($cell.Box.Width / 2)
            $cutCentreX = $cell.DieCut.Left + ($cell.DieCut.Width / 2)
            $boxCentreY = $cell.Box.Bottom + ($cell.Box.Height / 2)
            $cutCentreY = $cell.DieCut.Bottom + ($cell.DieCut.Height / 2)
            [math]::Abs($cutCentreX - $boxCentreX) | Should -BeLessThan 0.0001
            [math]::Abs($cutCentreY - $boxCentreY) | Should -BeLessThan 0.0001
        }
    }

    It 'refuses an inset that would put the safe area outside the die-cut' {
        # 117 pt cell, 100 pt safe area: more than 8.5 pt of inset clips content.
        $directory = New-TemplateFixture -ProductId '94106' -Calibration @{
            unit = 'mm'; global_offset_mm = @{ x = 0.0; y = 0.0 }; guide_inset_mm = 4.0
        }
        $params = @{ ProductId = '94106'; TemplateDirectory = $directory }
        { & $script:GetTemplate @params } | Should -Throw '*outside the die-cut*'
    }
}

Describe 'Calibration undo' {
    BeforeAll {
        $script:SetCal = Join-Path $script:Root 'processors/layout/set-label-template-calibration.ps1'

        function New-CalTemplate {
            $directory = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            $path = Join-Path $directory 'avery-94106.json'
            Copy-Item (Join-Path $script:TemplateDir 'avery-94106.json') $path
            return $path
        }
    }

    It 'restores the exact state from before the last round' {
        $path = New-CalTemplate
        $before = (Get-Content $path -Raw | ConvertFrom-Json).calibration

        $params = @{ TemplatePath = $path; RowsUpMm = @{ 3 = 4.0 }; GlobalRightMm = 2.0; GuidesInwardMm = 0.4 }
        $null = & $script:SetCal @params

        $params = @{ TemplatePath = $path; Undo = $true }
        $null = & $script:SetCal @params

        $after = (Get-Content $path -Raw | ConvertFrom-Json).calibration
        $after.global_offset_mm.x | Should -Be $before.global_offset_mm.x
        $after.global_offset_mm.y | Should -Be $before.global_offset_mm.y
        $after.guide_inset_mm     | Should -Be $before.guide_inset_mm
        ($after.row_offsets_mm -join ',')    | Should -BeExactly ($before.row_offsets_mm -join ',')
        ($after.column_offsets_mm -join ',') | Should -BeExactly ($before.column_offsets_mm -join ',')
    }

    It 'moves the reverted round to the undone log rather than discarding it' {
        $path = New-CalTemplate
        $params = @{ TemplatePath = $path; RowsUpMm = @{ 2 = 3.0 }; Note = 'bad round' }
        $null = & $script:SetCal @params

        $params = @{ TemplatePath = $path; Undo = $true }
        $null = & $script:SetCal @params

        $calibration = (Get-Content $path -Raw | ConvertFrom-Json).calibration
        $undone = @($calibration.undone)
        $undone.Count | Should -BeGreaterThan 0
        $undone[-1].change | Should -Match 'row 2'
    }

    It 'refuses to undo when there is no history' {
        $path = New-CalTemplate

        # Reset still records a round, so the history is stripped to reach the
        # genuinely empty case.
        $document = Get-Content $path -Raw | ConvertFrom-Json
        $document.calibration.history = @()
        [System.IO.File]::WriteAllText($path, ($document | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))

        $params = @{ TemplatePath = $path; Undo = $true }
        { & $script:SetCal @params } | Should -Throw '*no calibration round to undo*'
    }
}

Describe 'Calibration orchestrator read-only modes' {
    BeforeAll {
        $script:Adjust = Join-Path $script:Root 'orchestrators/adjust-label-template-calibration.ps1'

        function New-CalDirectory {
            $directory = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            Copy-Item (Join-Path $script:TemplateDir 'avery-94106.json') (Join-Path $directory 'avery-94106.json')
            return $directory
        }
    }

    It 'leaves the template byte-identical under -Show' {
        $directory = New-CalDirectory
        $path = Join-Path $directory 'avery-94106.json'
        $before = Get-Content $path -Raw

        $params = @{ ProductId = '94106'; TemplateDirectory = $directory; Show = $true }
        & $script:Adjust @params | Out-Null

        (Get-Content $path -Raw) | Should -BeExactly $before
    }

    It 'leaves the template byte-identical under -WhatIf' {
        $directory = New-CalDirectory
        $path = Join-Path $directory 'avery-94106.json'
        $before = Get-Content $path -Raw

        $params = @{ ProductId = '94106'; TemplateDirectory = $directory; RowsUp = @{ 1 = 1.0 }; GlobalRight = 3.0; WhatIf = $true }
        & $script:Adjust @params | Out-Null

        (Get-Content $path -Raw) | Should -BeExactly $before
    }
}

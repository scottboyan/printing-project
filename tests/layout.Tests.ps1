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

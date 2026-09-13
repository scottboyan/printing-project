# file_name    : tests/architecture.Tests.ps1
# author       : Scott Boyan; Claude Opus 5
# created      : 2026-09-13
# last_updated : 2026-09-13
# purpose      : Enforce the orchestrator/processor boundary and the splat rule so
#                they cannot erode silently.
# related_docs : IB0193 (KDR-4, KDR-5, KDR-6, R2); doc_2007 (1.1, 1.3, 4.1)
#
# doc_2007 1.3 is explicit that a callee test suite cannot catch a misbinding splat:
# 64 of 64 tests passed against a healer that every real caller misbound, because
# every test splatted a hashtable. The assertion has to be made against the CALL
# SITE, in the AST. That is what this file does.

BeforeAll {
    Set-StrictMode -Version Latest

    $script:Root          = Split-Path -Parent $PSScriptRoot
    $script:Orchestrators = @(Get-ChildItem -Path (Join-Path $script:Root 'orchestrators') -Filter '*.ps1' -File)
    $script:Processors    = @(Get-ChildItem -Path (Join-Path $script:Root 'processors') -Filter '*.ps1' -File -Recurse)
    $script:AllScripts    = $script:Orchestrators + $script:Processors

    function Get-ScriptAst {
        param([string]$Path)
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        return [pscustomobject]@{ Ast = $ast; Tokens = $tokens; Errors = $errors }
    }
}

Describe 'Everything parses' {
    It 'parses every orchestrator and processor without error' {
        foreach ($file in $script:AllScripts) {
            $parsed = Get-ScriptAst -Path $file.FullName
            # @() around the messages is load-bearing under Set-StrictMode -Version
            # Latest: .Message on an EMPTY ParseError collection throws
            # PropertyNotFoundException, so the -Because string would blow up on
            # exactly the files that are fine. doc_2007 4.1, met in our own test.
            $messages = @($parsed.Errors | ForEach-Object { $_.Message })
            $parsed.Errors.Count | Should -Be 0 -Because "$($file.Name): $($messages -join '; ')"
        }
    }
}

Describe 'KDR-6: hashtable splat only, never an array splat' {
    It 'splats only variables that were assigned a hashtable literal' {
        # An array splat into a .ps1 binds positionally and fails SILENTLY when the
        # callee has no [CmdletBinding()]. This walks every splatted variable back to
        # its assignment and requires a hashtable there.
        $offences = [System.Collections.Generic.List[string]]::new()

        foreach ($file in $script:AllScripts) {
            $parsed = Get-ScriptAst -Path $file.FullName
            $ast = $parsed.Ast

            $splatted = $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Splatted
            }, $true)

            foreach ($use in $splatted) {
                $name = $use.VariablePath.UserPath

                $assignments = @($ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $n.Left.VariablePath.UserPath -eq $name
                }, $true))

                if ($assignments.Count -eq 0) {
                    $offences.Add("$($file.Name): splats `$$name which is never assigned in this file")
                    continue
                }

                foreach ($assignment in $assignments) {
                    $rhs = $assignment.Right.Extent.Text.TrimStart()
                    $isHashtable = $rhs.StartsWith('@{') -or $rhs.StartsWith('[ordered]@{')
                    if (-not $isHashtable) {
                        $offences.Add("$($file.Name) line $($assignment.Extent.StartLineNumber): `$$name is splatted but assigned '$($rhs.Split([Environment]::NewLine)[0])' - only a hashtable may be splatted (KDR-6, doc_2007 1.1)")
                    }
                }
            }
        }

        $offences -join "`n" | Should -BeExactly ''
    }

    It 'has at least one splatted call, so the assertion above is not vacuous' {
        $total = 0
        foreach ($file in $script:Orchestrators) {
            $parsed = Get-ScriptAst -Path $file.FullName
            $total += @($parsed.Ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Splatted
            }, $true)).Count
        }
        $total | Should -BeGreaterThan 5
    }
}

Describe 'KDR-4: orchestrators are the only entry points' {
    It 'has at least one orchestrator' {
        $script:Orchestrators.Count | Should -BeGreaterThan 0
    }

    It 'never invokes an orchestrator from a processor' {
        # A processor must not CALL an orchestrator; that would make an orchestrator
        # reachable as a subroutine and invert the boundary.
        #
        # Asserted against invocations in the AST rather than against the file text.
        # new-code-registry.ps1 legitimately carries the string
        # 'printing-project/orchestrators/new-artifact-code-series.ps1' as the default
        # minted_by provenance value written INTO the registry - a recorded fact about
        # who minted a series, not a call. A text search flags it; the AST does not.
        foreach ($file in $script:Processors) {
            $parsed = Get-ScriptAst -Path $file.FullName

            $invocations = $parsed.Ast.FindAll({
                param($n) $n -is [System.Management.Automation.Language.CommandAst]
            }, $true)

            foreach ($invocation in $invocations) {
                $target = $invocation.CommandElements[0].Extent.Text
                $target | Should -Not -Match 'orchestrator' -Because "$($file.Name) line $($invocation.Extent.StartLineNumber) invokes an orchestrator"
            }
        }
    }
}

Describe 'KDR-5: orchestrators contain no domain logic' {
    It 'contains no Crockford alphabet literal' {
        foreach ($file in $script:Orchestrators) {
            (Get-Content $file.FullName -Raw) |
                Should -Not -Match '0123456789ABCDEFGHJKMNPQRSTVWXYZ' -Because "$($file.Name) would be holding the alphabet (KDR-5)"
        }
    }

    It 'contains no check-character arithmetic' {
        foreach ($file in $script:Orchestrators) {
            $text = Get-Content $file.FullName -Raw
            $text | Should -Not -Match '\-band\s+31' -Because "$($file.Name) would be computing symbols"
            $text | Should -Not -Match '%\s*32'      -Because "$($file.Name) would be computing a check character"
        }
    }

    It 'contains no sheet geometry' {
        # The grid lives in templates/*.json and is materialized by a layout
        # processor. An orchestrator that knows a coordinate has taken on layout.
        foreach ($file in $script:Orchestrators) {
            $text = Get-Content $file.FullName -Raw
            foreach ($magic in '639', '490.5', '193.5', '148.5', '144.0', '117') {
                $text | Should -Not -Match ([regex]::Escape($magic)) -Because "$($file.Name) would be holding grid geometry (KDR-5, KDR-12)"
            }
        }
    }
}

Describe 'Processors are well-formed' {
    It 'declares CmdletBinding, so a misbound call is loud rather than silent' {
        # doc_2007 1.1: a script WITHOUT CmdletBinding binds what it can positionally
        # and drops the rest into $args with no error at all. With it, the call throws
        # and points at the call site.
        foreach ($file in $script:Processors) {
            if ($file.Name -like '*-lib.ps1') { continue }   # dot-sourced libraries take no parameters
            (Get-Content $file.FullName -Raw) | Should -Match '\[CmdletBinding\(\)\]' -Because "$($file.Name) is invoked with a splat"
        }
    }

    It 'sets StrictMode Latest in every processor but never in a dot-sourced library' {
        # doc_2007 4.1: strict mode is session state. A dot-sourced library that sets
        # it would leak the setting into every caller.
        #
        # Asserted against invocations in the AST, not the file text: both library
        # files carry a comment explaining precisely why they do NOT call
        # Set-StrictMode, and a text search flags the explanation as the violation.
        foreach ($file in $script:Processors) {
            $parsed = Get-ScriptAst -Path $file.FullName

            $strictModeCalls = @($parsed.Ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'Set-StrictMode'
            }, $true))

            if ($file.Name -like '*-lib.ps1') {
                $strictModeCalls.Count | Should -Be 0 -Because "$($file.Name) is dot-sourced and would leak its mode into every caller"
            } else {
                $strictModeCalls.Count | Should -BeGreaterThan 0 -Because "$($file.Name) must be clean under strict mode on its own terms"
                $strictModeCalls[0].Extent.Text | Should -Match 'Latest' -Because "$($file.Name) must use -Version Latest"
            }
        }
    }

    It 'carries the script header convention' {
        foreach ($file in $script:AllScripts) {
            $head = (Get-Content $file.FullName -TotalCount 10) -join "`n"
            foreach ($field in 'file_name', 'author', 'created', 'last_updated', 'purpose', 'related_docs') {
                $head | Should -Match $field -Because "$($file.Name) is missing '$field' from its header"
            }
        }
    }

    It 'files processors by domain, never by job' {
        $allowed = @('codes', 'registry', 'qr', 'layout', 'pdf')
        $directories = @(Get-ChildItem -Path (Join-Path $script:Root 'processors') -Directory | ForEach-Object { $_.Name })
        foreach ($directory in $directories) {
            $allowed | Should -Contain $directory -Because "processors are filed by domain, never by job (KDR-5)"
        }
    }
}

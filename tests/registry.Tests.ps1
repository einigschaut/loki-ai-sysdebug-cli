# tests/registry.Tests.ps1 — command registry = single source of truth + consistency gate (CLAUDE.md §3, ADR-0002).
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\i18n.ps1"
    . "$PSScriptRoot\..\src\lib\registry.ps1"
    Initialize-LokiI18n -AppRoot (Resolve-Path "$PSScriptRoot\..\src").Path -Locale 'en' | Out-Null

    # Register fake commands globally so Get-Command sees them. Prefix 'ztest' -> can be cleaned up in a targeted way.
    function global:Register-FakeCmd {
        param([string]$Name, [hashtable]$Meta, [switch]$NoHandler)
        $sb = { $Meta }.GetNewClosure()
        New-Item -Path "Function:global:Get-LokiCmdMeta_$Name" -Value $sb -Force | Out-Null
        if (-not $NoHandler) {
            New-Item -Path "Function:global:Invoke-LokiCmd_$Name" -Value { param($Context) 0 } -Force | Out-Null
        }
    }
    function global:Unregister-FakeCmd {
        Get-ChildItem Function:\ |
            Where-Object { $_.Name -like 'Get-LokiCmdMeta_ztest*' -or $_.Name -like 'Invoke-LokiCmd_ztest*' } |
            ForEach-Object { Remove-Item "Function:\$($_.Name)" -Force }
    }

    # Synthetic registry (pscustomobjects) for suggestion/format — without function enumeration.
    $script:SynthReg = @(
        [pscustomobject]@{ Name = 'status';  Summary = 'Check';  Usage = 'loki status';  Group = 'Health'; Examples = @('loki status'); Flags = @() }
        [pscustomobject]@{ Name = 'version'; Summary = 'Ver';    Usage = 'loki version'; Group = 'Health'; Examples = @();             Flags = @() }
    )
}

AfterAll  {
    Remove-Item Function:\Register-FakeCmd  -ErrorAction SilentlyContinue
    Remove-Item Function:\Unregister-FakeCmd -ErrorAction SilentlyContinue
}

Describe 'Get-LokiCommandRegistry (consistency gate)' {

    AfterEach { Unregister-FakeCmd }

    It 'builds a validated registry from meta+handler and sorts by Group,Name' {
        Register-FakeCmd -Name 'ztest_bravo' -Meta @{ Name = 'ztest_bravo'; Summary = 'B'; Usage = 'loki ztest_bravo'; Group = 'ZTest' }
        Register-FakeCmd -Name 'ztest_alpha' -Meta @{ Name = 'ztest_alpha'; Summary = 'A'; Usage = 'loki ztest_alpha'; Group = 'ZTest' }
        $mine = @((Get-LokiCommandRegistry) | Where-Object { $_.Group -eq 'ZTest' })
        $mine.Count          | Should -Be 2
        $mine[0].Name        | Should -Be 'ztest_alpha'
        $mine[0].Handler     | Should -Be 'Invoke-LokiCmd_ztest_alpha'
    }

    # Guard 1: meta without a handler = orphaned command -> MUST throw.
    It 'throws when the handler is missing (dead/orphaned command)' {
        Register-FakeCmd -Name 'ztest_orphan' -Meta @{ Name = 'ztest_orphan'; Summary = 'O'; Usage = 'u'; Group = 'ZTest' } -NoHandler
        { Get-LokiCommandRegistry } | Should -Throw -ExpectedMessage '*handler*missing*'
    }

    # Guard 2: incomplete meta -> MUST throw.
    It 'throws on incomplete meta (required field Group is missing)' {
        Register-FakeCmd -Name 'ztest_bad' -Meta @{ Name = 'ztest_bad'; Summary = 'x'; Usage = 'u' }
        { Get-LokiCommandRegistry } | Should -Throw -ExpectedMessage '*Group*'
    }

    It 'does not throw when there are no matching fakes' {
        { Get-LokiCommandRegistry } | Should -Not -Throw
    }
}

Describe 'Get-LokiLevenshtein' {
    It 'distance(<A>,<B>) = <D>' -ForEach @(
        @{ A = 'kitten'; B = 'sitting'; D = 3 }
        @{ A = 'version'; B = 'verion'; D = 1 }
        @{ A = 'same';   B = 'same';   D = 0 }
        @{ A = '';       B = 'abc';    D = 3 }
        @{ A = 'abc';    B = '';       D = 3 }
    ) {
        Get-LokiLevenshtein -A $A -B $B | Should -Be $D
    }
}

Describe 'Get-LokiSuggestion' {
    It 'suggests the nearest command on a typo' {
        Get-LokiSuggestion -Name 'verion' -Registry $script:SynthReg | Should -Be 'version'
    }
    It 'returns $null when nothing is close enough' {
        Get-LokiSuggestion -Name 'zzzzzz' -Registry $script:SynthReg | Should -BeNullOrEmpty
    }
}

Describe 'Format-LokiHelp' {
    It 'overall help lists group + all commands' {
        $h = Format-LokiHelp -Registry $script:SynthReg -AppVersion '1.0.0'
        $h | Should -BeLike '*HEALTH*'
        $h | Should -BeLike '*status*'
        $h | Should -BeLike '*Check*'
        $h | Should -BeLike '*version*'
    }
    It 'command help shows title, usage, and examples' {
        $h = Format-LokiHelp -Registry $script:SynthReg -CommandName 'status'
        $h | Should -BeLike '*loki status - Check*'
        $h | Should -BeLike '*Usage: loki status*'
        $h | Should -BeLike '*Examples:*'
    }
    It 'unknown command => clear message' {
        Format-LokiHelp -Registry $script:SynthReg -CommandName 'nope' | Should -BeLike '*Unknown command: nope*'
    }
    It 'renders flags when present' {
        $reg = @([pscustomobject]@{ Name = 'fix'; Summary = 'Fix'; Usage = 'loki fix'; Group = 'Diag';
                    Examples = @(); Flags = @([pscustomobject]@{ Flag = '--dry-run'; Desc = 'nur zeigen' }) })
        $h = Format-LokiHelp -Registry $reg -CommandName 'fix'
        $h | Should -BeLike '*--dry-run*'
        $h | Should -BeLike '*nur zeigen*'
    }
}

# tests/offline.Tests.ps1 — contract stub (scaffolding). Add behaviour tests (break every guard once)!
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\i18n.ps1"
    . "$PSScriptRoot\..\src\lib\ui.ps1"
    . "$PSScriptRoot\..\src\lib\exitcodes.ps1"
    . "$PSScriptRoot\..\src\commands\offline.ps1"
    Initialize-LokiUi -NoColor
    Initialize-LokiI18n -AppRoot (Resolve-Path "$PSScriptRoot\..\src").Path -Locale 'en' | Out-Null
}

Describe 'Command offline' {
    It 'metadata is complete (Name == file name)' {
        $m = Get-LokiCmdMeta_offline
        $m.Name    | Should -Be 'offline'
        $m.Summary | Should -Not -BeNullOrEmpty
        $m.Usage   | Should -Not -BeNullOrEmpty
        $m.Group   | Should -Not -BeNullOrEmpty
    }
    It 'handler is defined and returns an exit code' {
        (Get-Command Invoke-LokiCmd_offline -CommandType Function) | Should -Not -BeNullOrEmpty
        $ctx  = @{ AppRoot = 'x'; Version = '0'; Args = @(); Flags = @{}; Registry = @() }
        $code = Invoke-LokiCmd_offline $ctx
        ([int]$code) | Should -BeOfType [int]
    }
    It 'the Summary is a resolvable i18n key, not literal prose (ADR-0004)' {
        # help/README render Summary through Get-LokiText; a key that resolves to itself never got a catalog entry.
        $key = (Get-LokiCmdMeta_offline).Summary
        (Get-LokiText $key) | Should -Not -Be $key
    }
    It 'the scaffold shows usage until --analyze is wired (task #17)' {
        $ctx = @{ AppRoot = 'x'; Version = '0'; Args = @(); Flags = @{}; Registry = @() }
        (Invoke-LokiCmd_offline $ctx) | Should -Be (Get-LokiExitCode 'Usage')
    }
    # TODO (task #17): --analyze orchestration -> integrity preflight fatal paths (not-installed 5 / mismatch 1),
    #                  exit-code mapping, dump read-only, and the real-engine run (task #18).
}
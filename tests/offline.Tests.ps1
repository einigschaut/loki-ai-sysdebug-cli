# tests/offline.Tests.ps1 — contract stub (scaffolding). Add behaviour tests (break every guard once)!
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\i18n.ps1"
    . "$PSScriptRoot\..\src\lib\ui.ps1"
    . "$PSScriptRoot\..\src\lib\exitcodes.ps1"
    . "$PSScriptRoot\..\src\lib\offline.ps1"
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

Describe 'Get-LokiOfflineContextSize (the context policy ADR-0015 left to the command slice)' {
    It 'sizes a typical dump to a small window, well under the analyze ceiling' {
        # The small tier declares 262144 tokens; a ~2.5 KB dump must NOT reserve a quarter-million-token window.
        $ctx = Get-LokiOfflineContextSize -ModelMaxContext 262144 -DumpChars 2500
        $ctx | Should -BeGreaterThan 2048
        $ctx | Should -BeLessOrEqual 16384
    }
    It 'never returns 0 or below the floor when the model allows it (Get-LokiLlamaServerArgs throws on 0)' {
        Get-LokiOfflineContextSize -ModelMaxContext 32768 -DumpChars 0 | Should -BeGreaterOrEqual 2048
    }
    It 'caps a huge dump at the analyze ceiling, not at the model max' {
        Get-LokiOfflineContextSize -ModelMaxContext 262144 -DumpChars 200000 | Should -Be 16384
    }
    It 'never exceeds the model max, even when that max is below our floor (break-the-guard)' {
        # A model whose declared context is smaller than our floor must win -- we cannot ask for more than exists.
        Get-LokiOfflineContextSize -ModelMaxContext 1024 -DumpChars 0 | Should -Be 1024
    }
    It 'always returns a multiple of 256 (a clean, reproducible window)' {
        foreach ($chars in 0, 500, 2500, 9000, 50000) {
            ((Get-LokiOfflineContextSize -ModelMaxContext 131072 -DumpChars $chars) % 256) | Should -Be 0
        }
    }
    It 'grows with the dump until it hits the ceiling (monotonic)' {
        $a = Get-LokiOfflineContextSize -ModelMaxContext 131072 -DumpChars 2000
        $b = Get-LokiOfflineContextSize -ModelMaxContext 131072 -DumpChars 20000
        $b | Should -BeGreaterOrEqual $a
    }
    It 'rejects a non-positive model max rather than inventing a window' {
        { Get-LokiOfflineContextSize -ModelMaxContext 0 -DumpChars 100 } | Should -Throw
    }
}
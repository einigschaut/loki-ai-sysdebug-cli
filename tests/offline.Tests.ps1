# tests/offline.Tests.ps1 — contract stub (scaffolding). Add behaviour tests (break every guard once)!
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\i18n.ps1"
    . "$PSScriptRoot\..\src\lib\ui.ps1"
    . "$PSScriptRoot\..\src\lib\exitcodes.ps1"
    . "$PSScriptRoot\..\src\lib\collect.ps1"   # ConvertTo-LokiCollectText, for Read-LokiOfflineDump's .json path
    . "$PSScriptRoot\..\src\lib\engine.ps1"    # Get-LokiEngineManifest (mocked in the command tests)
    . "$PSScriptRoot\..\src\lib\models.ps1"    # Get-LokiModelManifest / Get-LokiModelLayout
    . "$PSScriptRoot\..\src\lib\agent.ps1"     # Invoke-LokiWithEngine (mocked -- the preflight guard lives here)
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

Describe 'Get-LokiOfflineFailure (Reason -> exit code + message; mirrors the integrity 1-vs-5 split)' {
    It 'a present-but-mismatched model is tampering -> GeneralError + tampered' {
        $f = Get-LokiOfflineFailure -Reason 'model-unverified' -Detail 'mismatch'
        $f.ExitName | Should -Be 'GeneralError'
        $f.MessageKey | Should -Be 'offline.tampered'
    }
    It 'an absent model is incomplete, not tampering -> OfflineEngineMissing + notSetup' {
        $f = Get-LokiOfflineFailure -Reason 'model-unverified' -Detail 'not-installed'
        $f.ExitName | Should -Be 'OfflineEngineMissing'
        $f.MessageKey | Should -Be 'offline.notSetup'
    }
    It 'an unreadable model is undetermined, never tampering -> OfflineEngineMissing' {
        (Get-LokiOfflineFailure -Reason 'model-unverified' -Detail 'unreadable').ExitName | Should -Be 'OfflineEngineMissing'
    }
    It 'a broken engine chain is do-not-trust (1); an absent engine is incomplete (5)' {
        (Get-LokiOfflineFailure -Reason 'engine-unverified' -Detail 'archive-missing').ExitName | Should -Be 'GeneralError'
        (Get-LokiOfflineFailure -Reason 'engine-unverified' -Detail 'engine-not-installed').ExitName | Should -Be 'OfflineEngineMissing'
    }
    It 'a runtime that fails its SIGNATURE is tampering (1); absent/old is cannot-run-here (5)' {
        (Get-LokiOfflineFailure -Reason 'runtime-unavailable' -Detail 'not-microsoft-signed').ExitName | Should -Be 'GeneralError'
        (Get-LokiOfflineFailure -Reason 'runtime-unavailable' -Detail 'too-old').ExitName | Should -Be 'OfflineEngineMissing'
    }
    It 'not enough RAM is a machine limit, not a broken stick -> OfflineEngineMissing' {
        (Get-LokiOfflineFailure -Reason 'insufficient-ram').ExitName | Should -Be 'OfflineEngineMissing'
    }
    It 'an orphaned engine -> GeneralError + orphan' {
        (Get-LokiOfflineFailure -Reason 'engine-already-running').MessageKey | Should -Be 'offline.orphan'
    }
    It 'BREAK-THE-GUARD: a Reason nobody foresaw fails to GeneralError, never to Ok' {
        $f = Get-LokiOfflineFailure -Reason 'some-reason-from-a-future-refactor'
        $f.ExitName | Should -Be 'GeneralError'
        $f.ExitName | Should -Not -Be 'Ok'
        $f.MessageKey | Should -Be 'offline.engineFailed'
    }
    It 'every message key it can return actually resolves in the catalog (no dangling key)' {
        $rows = @(
            @('model-unverified', 'mismatch'), @('model-unverified', 'not-installed'),
            @('engine-unverified', 'archive-missing'), @('engine-unverified', 'engine-not-installed'),
            @('runtime-unavailable', 'not-signed'), @('runtime-unavailable', 'too-old'),
            @('insufficient-ram', ''), @('server-exe-missing', ''), @('engine-already-running', ''), @('whatever', '')
        )
        foreach ($r in $rows) {
            $key = (Get-LokiOfflineFailure -Reason $r[0] -Detail $r[1]).MessageKey
            (Get-LokiText $key) | Should -Not -Be $key
        }
    }
}

Describe 'Read-LokiOfflineDump (read-only; renders a collect .json)' {
    It 'reports not-found for a path that does not exist' {
        (Read-LokiOfflineDump -Path (Join-Path $TestDrive 'nope.txt')).Reason | Should -Be 'not-found'
    }
    It 'reports empty for a whitespace-only file' {
        $p = Join-Path $TestDrive 'empty.txt'; Set-Content -LiteralPath $p -Value '   ' -Encoding utf8
        (Read-LokiOfflineDump -Path $p).Reason | Should -Be 'empty'
    }
    It 'returns a rendered .txt as-is' {
        $p = Join-Path $TestDrive 'dump.txt'; Set-Content -LiteralPath $p -Value "loki collect`n  FreeGB : 1.8" -Encoding utf8
        $r = Read-LokiOfflineDump -Path $p
        $r.Ok | Should -BeTrue
        $r.Text | Should -Match 'FreeGB : 1.8'
    }
    It 'renders a collect .json to text -- the model reads what a human would, not raw JSON' {
        $dump = [pscustomobject]@{
            CreatedAt = ([datetime]'2026-07-16 14:30:00')
            Batteries = @([pscustomobject]@{ Id = 'network'; Status = 'ok'; DurationMs = 100; Error = $null
                    Data = [pscustomobject]@{ Reachable = $false
                        Adapters = @([pscustomobject]@{ Description = 'Intel'; IpAddress = @('169.254.14.203') }) } })
        }
        $json = ConvertTo-LokiCollectJson -Document (ConvertTo-LokiCollectDocument -Dump $dump -LokiVersion '0.9.1')
        $p = Join-Path $TestDrive 'dump.json'; Set-Content -LiteralPath $p -Value $json -Encoding utf8
        $r = Read-LokiOfflineDump -Path $p
        $r.Ok | Should -BeTrue
        $r.Text | Should -Match '169\.254\.14\.203'
        $r.Text | Should -Not -Match '"Batteries"'
    }
    It 'does not modify the file it reads (the footprint guarantee starts with the input)' {
        $p = Join-Path $TestDrive 'ro.txt'; Set-Content -LiteralPath $p -Value 'content' -Encoding utf8
        $before = [System.IO.File]::ReadAllBytes($p)
        [void](Read-LokiOfflineDump -Path $p)
        ([System.IO.File]::ReadAllBytes($p) -join ',') | Should -Be ($before -join ',')
    }
}

Describe 'Invoke-LokiEngineChat (loopback transport)' {
    It 'returns the assistant content on a well-formed response' {
        Mock Invoke-RestMethod { @{ choices = @(@{ message = @{ content = 'VERDICT: disk full' } }) } }
        $r = Invoke-LokiEngineChat -BaseUri 'http://127.0.0.1:9' -Messages @(@{ role = 'user'; content = 'x' })
        $r.Ok | Should -BeTrue
        $r.Content | Should -Be 'VERDICT: disk full'
    }
    It 'a transport failure is a Reason, not a throw' {
        Mock Invoke-RestMethod { throw 'connection refused' }
        $r = Invoke-LokiEngineChat -BaseUri 'http://127.0.0.1:9' -Messages @(@{ role = 'user'; content = 'x' })
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'engine-request-failed'
    }
    It 'an empty answer is reported, not passed off as a result' {
        Mock Invoke-RestMethod { @{ choices = @(@{ message = @{ content = '   ' } }) } }
        (Invoke-LokiEngineChat -BaseUri 'http://127.0.0.1:9' -Messages @(@{ role = 'user'; content = 'x' })).Reason | Should -Be 'engine-empty-answer'
    }
}

Describe 'Invoke-LokiOfflineAnalyze (the guard is the harness; we must honour its refusal)' {
    BeforeAll {
        function global:New-FakeModel { @{ Id = 'small'; Model = 'Qwen3-4B'; ContextTokens = 262144; ResidentGB = 4.5 } }
    }
    AfterAll { Remove-Item Function:\New-FakeModel -ErrorAction SilentlyContinue }

    It 'BREAK-THE-GUARD: when the preflight refuses (model-unverified), NO chat is attempted' {
        Mock Invoke-LokiWithEngine { @{ Ok = $false; Reason = 'model-unverified'; Detail = 'mismatch' } }
        Mock Invoke-LokiEngineChat { @{ Ok = $true; Content = 'should never be called' } }
        $r = Invoke-LokiOfflineAnalyze -AppRoot 'x' -Engine @{} -Runtime @{} -Model (New-FakeModel) -DumpText 'dump'
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'model-unverified'
        Should -Invoke Invoke-LokiEngineChat -Times 0 -Exactly
    }
    It 'happy path: engine ready, chat answers -> Analysis returned' {
        Mock Invoke-LokiWithEngine { $res = & $Body @{ Port = 1; BaseUri = 'http://127.0.0.1:1'; Process = $null }; @{ Ok = $true; Reason = 'ok'; Result = $res } }
        Mock Invoke-LokiEngineChat { @{ Ok = $true; Content = 'VERDICT: clean'; Reason = 'ok' } }
        $r = Invoke-LokiOfflineAnalyze -AppRoot 'x' -Engine @{} -Runtime @{} -Model (New-FakeModel) -DumpText 'dump'
        $r.Ok | Should -BeTrue
        $r.Analysis | Should -Be 'VERDICT: clean'
    }
    It 'a chat failure inside a ready engine is propagated, not swallowed' {
        Mock Invoke-LokiWithEngine { $res = & $Body @{ Port = 1; BaseUri = 'http://127.0.0.1:1'; Process = $null }; @{ Ok = $true; Reason = 'ok'; Result = $res } }
        Mock Invoke-LokiEngineChat { @{ Ok = $false; Reason = 'engine-empty-answer' } }
        $r = Invoke-LokiOfflineAnalyze -AppRoot 'x' -Engine @{} -Runtime @{} -Model (New-FakeModel) -DumpText 'dump'
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'engine-empty-answer'
    }
}

Describe 'Command offline --analyze (wiring + Reason -> exit-code mapping)' {
    BeforeAll {
        function global:New-OfflineCtx { param([string[]]$A = @()) @{ AppRoot = 'TestDrive:\stick'; Version = 't'; Args = $A; Flags = @{}; Registry = @() } }
        $script:goodDump = Join-Path $TestDrive 'good.txt'
        Set-Content -LiteralPath $script:goodDump -Value "loki collect`n  FreeGB : 1.8" -Encoding utf8
        # The manifests are mocked -- these tests are about the command's WIRING, not the pinned catalog on the stick.
        Mock Get-LokiEngineManifest { @{ Engine = @{}; Runtime = @{} } }
        Mock Get-LokiModelManifest { , @(@{ Id = 'small'; Model = 'Qwen3-4B'; ContextTokens = 262144; ResidentGB = 4.5; Default = $true }) }
    }
    AfterAll { Remove-Item Function:\New-OfflineCtx -ErrorAction SilentlyContinue }

    It 'no --analyze -> Usage exit' {
        (Invoke-LokiCmd_offline (New-OfflineCtx @())) | Should -Be (Get-LokiExitCode 'Usage')
    }
    It '--analyze with no dump path -> Usage exit' {
        (Invoke-LokiCmd_offline (New-OfflineCtx @('--analyze'))) | Should -Be (Get-LokiExitCode 'Usage')
    }
    It '--analyze on a missing dump -> Usage exit (nothing to analyze)' {
        (Invoke-LokiCmd_offline (New-OfflineCtx @('--analyze', (Join-Path $TestDrive 'nope.txt')))) | Should -Be (Get-LokiExitCode 'Usage')
    }
    It 'a good dump + a clean analysis -> prints it and exits Ok' {
        Mock Invoke-LokiOfflineAnalyze { @{ Ok = $true; Reason = 'ok'; Analysis = 'VERDICT: disk nearly full' } }
        (Invoke-LokiCmd_offline (New-OfflineCtx @('--analyze', $script:goodDump))) | Should -Be (Get-LokiExitCode 'Ok')
    }
    It 'a tampered model -> GeneralError(1), the do-not-trust answer' {
        Mock Invoke-LokiOfflineAnalyze { @{ Ok = $false; Reason = 'model-unverified'; Detail = 'mismatch' } }
        (Invoke-LokiCmd_offline (New-OfflineCtx @('--analyze', $script:goodDump))) | Should -Be (Get-LokiExitCode 'GeneralError')
    }
    It 'a machine too small -> OfflineEngineMissing(5), not a crash' {
        Mock Invoke-LokiOfflineAnalyze { @{ Ok = $false; Reason = 'insufficient-ram' } }
        (Invoke-LokiCmd_offline (New-OfflineCtx @('--analyze', $script:goodDump))) | Should -Be (Get-LokiExitCode 'OfflineEngineMissing')
    }
}
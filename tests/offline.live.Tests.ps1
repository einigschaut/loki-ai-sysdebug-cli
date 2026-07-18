# tests/offline.live.Tests.ps1 -- the ONE real-engine run for `offline --analyze` (ADR-0015 section 6, CLAUDE.md 6:
# "the real engine starts at least once for real"). Every other offline test mocks the harness; this one does not.
#
# OPT-IN, because it starts a multi-GB llama-server and loads a real model -- it must never run in CI or slow the
# default gate. It SKIPS unless BOTH are set:
#     $env:LOKI_LIVE_OFFLINE = '1'
#     $env:LOKI_LIVE_STICK   = <path to a real Loki stick with the engine + Qwen3-4B installed>
#
# The RAM-fit verdict is the ONE thing stubbed (Get-LokiTierFit -> fits), exactly as ADR-0015's live-gate did: the
# 25%-of-installed reserve is a DESIGN.md/ADR-0013 question, not this slice's, and on a healthy dev box it refuses
# the small tier by a few hundred MB while the machine can plainly run it. Everything else is REAL -- the integrity
# preflight (engine + model hashed against their pins), the runtime check, the model load, the chat, the clean kill.
Set-StrictMode -Version Latest

BeforeAll {
    # The full lib graph, like the dispatcher loads it -- the live path exercises the real Resolve-LokiEnginePreflight
    # and everything under it, so nothing may be mocked away except the one RAM verdict below.
    Get-ChildItem "$PSScriptRoot\..\src\lib" -Filter *.ps1 | ForEach-Object { . $_.FullName }
    Initialize-LokiI18n -AppRoot (Resolve-Path "$PSScriptRoot\..\src").Path -Locale 'en' | Out-Null

    $script:liveStick = [string]$env:LOKI_LIVE_STICK
    $script:liveOn = ($env:LOKI_LIVE_OFFLINE -eq '1') -and (-not [string]::IsNullOrWhiteSpace($script:liveStick)) -and
        (Test-Path -LiteralPath $script:liveStick)
}

Describe 'offline --analyze against the REAL engine (opt-in; ADR-0015 section 6)' {
    It 'loads Qwen3-4B, analyzes a real dump, returns a verdict, and leaves ZERO orphans' {
        if (-not $script:liveOn) {
            Set-ItResult -Skipped -Because 'opt-in: set LOKI_LIVE_OFFLINE=1 and LOKI_LIVE_STICK=<real stick> to run it'
            return
        }
        # Stub ONLY the RAM-fit verdict (ADR-0015). Integrity, runtime, model load, chat and kill all stay real.
        Mock Get-LokiTierFit { @{ Verdict = 'fits'; NeedFreeGB = 0 } }

        $engineData = Get-LokiEngineManifest -Path (Join-Path $script:liveStick 'engine\manifest.psd1')
        $models = Get-LokiModelManifest -Path (Get-LokiModelLayout -AppRoot $script:liveStick).ManifestPath
        $model = @($models) | Where-Object { $_.Id -eq 'small' } | Select-Object -First 1
        $model | Should -Not -BeNullOrEmpty -Because 'the small tier (Qwen3-4B) must be installed on the live stick'

        $serverExe = (Get-LokiEngineLayout -AppRoot $script:liveStick -Engine $engineData.Engine).ServerExePath
        @(Get-LokiEngineOrphan -ServerExePath $serverExe).Count |
            Should -Be 0 -Because 'no engine from this stick may already be running when the test starts'

        # A realistic multi-battery dump (what the real collector renders), carrying an unambiguous C: fault so the
        # run is a plausible analyze -- but note the assertions below test the HARNESS, not the diagnosis.
        $dumpText = @'
loki collect -- raw diagnostic dump
  tool         : loki collect 0.9.1
  created      : 2026-07-18T09:00:00.0000000+02:00
  schema       : 1

[collected] os (120 ms)
  Caption            : Microsoft Windows 11 Pro
  UptimeHours        : 52.4

[collected] storage (100 ms)
  Disks:
    Drive              : C:
    SizeGB             : 476.3
    FreeGB             : 1.8
    PercentFree        : 0.4

    Drive              : D:
    SizeGB             : 931.5
    FreeGB             : 640.2
    PercentFree        : 68.7

[collected] network (90 ms)
  Reachable          : true
'@

        $res = Invoke-LokiOfflineAnalyze -AppRoot $script:liveStick -Engine $engineData.Engine `
            -Runtime $engineData.Runtime -Model $model -DumpText $dumpText -TimeoutSec 300

        $res.Ok | Should -BeTrue -Because ('the real engine should answer; got ' + ($res | ConvertTo-Json -Depth 4 -Compress))
        $res.Analysis | Should -Not -BeNullOrEmpty
        # This proves the ROUND-TRIP through the real engine, not the model's accuracy (that is the tier eval's job,
        # and coupling a harness test to what a model concludes on a given day makes it flaky). A well-formed contract
        # answer -- system prompt -> dump -> model -> the shape we asked for, parsed back -- is the bar here.
        $res.Analysis | Should -Match '(?i)VERDICT'
        $res.Analysis | Should -Match '(?i)CONFIDENCE'

        # THE guarantee this whole harness exists to make: no llama-server from this stick survives the call.
        @(Get-LokiEngineOrphan -ServerExePath $serverExe).Count |
            Should -Be 0 -Because 'Invoke-LokiWithEngine must clean-kill the engine in its finally block'
    }
}

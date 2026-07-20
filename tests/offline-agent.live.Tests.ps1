# tests/offline-agent.live.Tests.ps1 -- the ONE real-engine run for `offline --agent` (ADR-0015 section 6, CLAUDE.md 6:
# "the real engine starts at least once for real"). Every other agent test mocks the engine + child; this one does not.
#
# OPT-IN, because it starts a multi-GB llama-server and drives a real multi-turn loop -- it must never run in CI or slow
# the default gate. It SKIPS unless BOTH are set:
#     $env:LOKI_LIVE_AGENT = '1'
#     $env:LOKI_LIVE_STICK = <path to a real Loki stick with the engine + an AGENT-CAPABLE (mid+, ~8B) model installed>
# and it SKIPS with a clear reason if the stick has no agent-capable model (e.g. only the small Qwen3-4B tier) -- the
# agent floor is `mid` (DESIGN.md 3 / ADR-0021), so a below-floor stick cannot exercise this path.
#
# The RAM-fit verdict is the ONE thing stubbed (Get-LokiTierFit -> fits), exactly as ADR-0015's live gate did: the
# 25%-of-installed reserve is a DESIGN.md/ADR-0013 question, not this slice's. Everything else is REAL -- the integrity
# preflight (engine + model hashed against their pins), the runtime check, the model load, the multi-turn chat, the
# gated read-only command execution against this very machine, and the clean kill.
Set-StrictMode -Version Latest

BeforeAll {
    # The full lib graph, like the dispatcher loads it -- the live path exercises the real Resolve-LokiEnginePreflight,
    # Resolve-LokiCommandDecision, and the child-process executor, so nothing may be mocked except the one RAM verdict.
    Get-ChildItem "$PSScriptRoot\..\src\lib" -Filter *.ps1 | ForEach-Object { . $_.FullName }
    Initialize-LokiI18n -AppRoot (Resolve-Path "$PSScriptRoot\..\src").Path -Locale 'en' | Out-Null

    $script:liveStick = [string]$env:LOKI_LIVE_STICK
    $script:liveOn = ($env:LOKI_LIVE_AGENT -eq '1') -and (-not [string]::IsNullOrWhiteSpace($script:liveStick)) -and
        (Test-Path -LiteralPath $script:liveStick)
}

Describe 'offline --agent against the REAL engine (opt-in; ADR-0015 section 6)' {
    It 'runs the read-only loop with a capable model, returns an answer, and leaves ZERO orphans' {
        if (-not $script:liveOn) {
            Set-ItResult -Skipped -Because 'opt-in: set LOKI_LIVE_AGENT=1 and LOKI_LIVE_STICK=<real stick> to run it'
            return
        }
        # Stub ONLY the RAM-fit verdict (ADR-0015). Integrity, runtime, model load, the loop, command execution and the
        # kill all stay real.
        Mock Get-LokiTierFit { @{ Verdict = 'fits'; NeedFreeGB = 0 } }

        $engineData = Get-LokiEngineManifest -Path (Join-Path $script:liveStick 'engine\manifest.psd1')
        $layout = Get-LokiModelLayout -AppRoot $script:liveStick
        $models = Get-LokiModelManifest -Path $layout.ManifestPath
        # Filter to what is actually ON the stick BEFORE the capability check. The manifest lists EVERY tier (mid/8B+
        # among them), so choosing an agent-capable model from the manifest can pick a tier that was never downloaded
        # and then fail preflight with model-unverified/not-installed instead of skipping. Get-LokiInstalledTiers is
        # presence + pinned size, so a small-only rig correctly yields no agent-capable model and this SKIPS -- which
        # is exactly what the file header promises for a below-floor stick.
        $installed = Get-LokiInstalledTiers -Models $models -ModelsDir $layout.Dir
        $model = @($installed) | Where-Object { Test-LokiOfflineAgentCapable -Model $_ } | Select-Object -First 1
        if ($null -eq $model) {
            Set-ItResult -Skipped -Because 'no agent-capable (mid+, ~8B) model is INSTALLED on the live stick; the agent floor cannot be exercised'
            return
        }

        $serverExe = (Get-LokiEngineLayout -AppRoot $script:liveStick -Engine $engineData.Engine).ServerExePath
        @(Get-LokiEngineOrphan -ServerExePath $serverExe).Count |
            Should -Be 0 -Because 'no engine from this stick may already be running when the test starts'

        # A short, bounded run: enough turns for the model to gather a fact and answer, capped so a slow CPU model
        # cannot make the test hang. The assertions test the HARNESS (a well-formed loop that clean-kills), NOT the
        # model's diagnostic accuracy -- coupling a harness test to what a model concludes makes it flaky.
        $res = Invoke-LokiOfflineAgent -AppRoot $script:liveStick -Engine $engineData.Engine `
            -Runtime $engineData.Runtime -Model $model -MaxIterations 4 -TimeBudgetSec 300

        $res.Ok | Should -BeTrue -Because ('the real engine should answer; got ' + ($res | ConvertTo-Json -Depth 4 -Compress))
        $res.Answer | Should -Not -BeNullOrEmpty
        $res.StopReason | Should -BeIn @('final', 'iteration-cap', 'time-cap', 'stuck')

        # THE guarantee this whole harness exists to make: no llama-server from this stick survives the call.
        @(Get-LokiEngineOrphan -ServerExePath $serverExe).Count |
            Should -Be 0 -Because 'Invoke-LokiWithEngine must clean-kill the engine in its finally block'
    }
}

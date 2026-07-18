# tests/offline-agent.Tests.ps1 -- the offline AGENT loop (security core, ADR-0021). Slice 2a #19 scaffold: the ~8B
# capability floor, the tier-rank drift guard, the WIP loop-entry boundary, and the command's --agent wiring (decline
# below the floor, ambiguity, routing). #20-#23 add the tool-protocol, gated-execution, cap, and injection tests as
# those parts land -- and replace the WIP-boundary test with the real loop.
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\i18n.ps1"
    . "$PSScriptRoot\..\src\lib\ui.ps1"
    . "$PSScriptRoot\..\src\lib\exitcodes.ps1"
    . "$PSScriptRoot\..\src\lib\collect.ps1"    # ConvertTo-LokiCollectText (Read-LokiOfflineDump's .json path, via offline.ps1)
    . "$PSScriptRoot\..\src\lib\engine.ps1"     # Get-LokiEngineManifest (mocked in the command tests)
    . "$PSScriptRoot\..\src\lib\models.ps1"     # Get-LokiModelManifest / Get-LokiModelLayout
    . "$PSScriptRoot\..\src\lib\allowlist.ps1"  # Get-LokiAllowDecision (the gate the loop will use, #21)
    . "$PSScriptRoot\..\src\lib\agent.ps1"      # Invoke-LokiWithEngine (the engine harness the loop will use, #22)
    . "$PSScriptRoot\..\src\lib\offline.ps1"    # Invoke-LokiEngineChat / Protect-LokiOfflineDumpText / Get-LokiOfflineFailure
    . "$PSScriptRoot\..\src\lib\offline-agent.ps1"
    . "$PSScriptRoot\..\src\commands\offline.ps1"
    Initialize-LokiUi -NoColor
    Initialize-LokiI18n -AppRoot (Resolve-Path "$PSScriptRoot\..\src").Path -Locale 'en' | Out-Null
}

Describe 'Test-LokiOfflineAgentCapable (the ~8B agent floor is the mid tier, DESIGN.md 3 / ADR-0021)' {
    It 'tier <Tier> at-or-above the floor = <Expected>' -TestCases @(
        @{ Tier = 'nano';          Expected = $false }
        @{ Tier = 'small';         Expected = $false }
        @{ Tier = 'mid';           Expected = $true  }
        @{ Tier = 'large';         Expected = $true  }
        @{ Tier = 'large-longctx'; Expected = $true  }
        @{ Tier = 'max';           Expected = $true  }
        @{ Tier = 'max-ceiling';   Expected = $true  }
    ) {
        (Test-LokiOfflineAgentCapable -Model @{ Id = $Tier }) | Should -Be $Expected
    }

    It 'fails SAFE: an unknown/renamed tier id is treated as below the floor (not agent-capable)' {
        (Test-LokiOfflineAgentCapable -Model @{ Id = 'ultra-9000' }) | Should -BeFalse
        (Test-LokiOfflineAgentCapable -Model @{ Id = '' })           | Should -BeFalse
    }
}

Describe 'Tier-rank drift guard (a new catalog tier nobody ranked must fail a test, not silently decline)' {
    It 'every tier id in the real model manifest is present in the capability rank' {
        $rank = Get-LokiOfflineTierRank
        $manifestPath = Join-Path (Resolve-Path "$PSScriptRoot\..\src").Path 'models\manifest.psd1'
        $models = Get-LokiModelManifest -Path $manifestPath   # assign FIRST: Get-LokiModelManifest ends in `return , $models`,
        foreach ($m in @($models)) {                          # so @(FUNC) collapses the catalog to one element. THEN wrap.
            $rank | Should -Contain ([string]$m.Id) -Because "tier '$($m.Id)' is in the manifest but not ranked in lib/offline-agent.ps1"
        }
    }
}

Describe 'Invoke-LokiOfflineAgent (WIP boundary -- #20-#22 replace this with the real loop)' {
    It 'throws an explicit not-yet-wired error rather than pretending to run' {
        # A security core must never ship a loop that only looks like it runs (CLAUDE.md 9). This guard is replaced by
        # real loop tests when #20-#22 land; its presence documents that the scaffold does not fake the loop.
        { Invoke-LokiOfflineAgent -AppRoot 'x' -Engine @{} -Runtime @{} -Model @{ Id = 'mid' } } |
            Should -Throw '*not yet wired*'
    }
}

Describe 'Command offline --agent (wiring: floor decline, ambiguity, routing)' {
    BeforeAll {
        function global:New-OfflineCtx { param([string[]]$A = @()) @{ AppRoot = 'TestDrive:\stick'; Version = 't'; Args = $A; Flags = @{}; Registry = @() } }
        Mock Get-LokiEngineManifest { @{ Engine = @{}; Runtime = @{} } }
    }
    AfterAll { Remove-Item Function:\New-OfflineCtx -ErrorAction SilentlyContinue }

    It '--agent AND --analyze together -> Usage (ambiguous, never a silent pick of one)' {
        Mock Get-LokiModelManifest { , @(@{ Id = 'mid'; Model = 'the-8B'; ContextTokens = 40960; ResidentGB = 7.0; Default = $true }) }
        (Invoke-LokiCmd_offline (New-OfflineCtx @('--agent', '--analyze', 'x'))) | Should -Be (Get-LokiExitCode 'Usage')
    }

    It 'a below-floor model (small) -> declines OfflineEngineMissing(5) and NEVER enters the loop' {
        Mock Get-LokiModelManifest { , @(@{ Id = 'small'; Model = 'Qwen3-4B'; ContextTokens = 262144; ResidentGB = 4.5; Default = $true }) }
        Mock Invoke-LokiOfflineAgent { }   # if this is ever called for a small model, the security floor has failed
        (Invoke-LokiCmd_offline (New-OfflineCtx @('--agent'))) | Should -Be (Get-LokiExitCode 'OfflineEngineMissing')
        Should -Invoke Invoke-LokiOfflineAgent -Times 0
    }

    It 'an empty model manifest -> OfflineEngineMissing(5), not a crash (no model to run the agent)' {
        Mock Get-LokiModelManifest { , @() }
        (Invoke-LokiCmd_offline (New-OfflineCtx @('--agent'))) | Should -Be (Get-LokiExitCode 'OfflineEngineMissing')
    }

    It 'a capable model (mid) -> routes to the agent loop with that model (the loop itself is #20-#22)' {
        Mock Get-LokiModelManifest { , @(@{ Id = 'mid'; Model = 'the-8B'; ContextTokens = 40960; ResidentGB = 7.0; Default = $true }) }
        Mock Invoke-LokiOfflineAgent { }   # stand in for the (WIP) loop so the test exercises ROUTING, not the throw
        (Invoke-LokiCmd_offline (New-OfflineCtx @('--agent'))) | Out-Null
        Should -Invoke Invoke-LokiOfflineAgent -Times 1 -ParameterFilter { $Model.Id -eq 'mid' }
    }
}

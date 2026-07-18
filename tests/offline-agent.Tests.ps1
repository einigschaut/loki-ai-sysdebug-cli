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

Describe 'Get-LokiOfflineAgentToolset (the model move set: run_command + final_answer, ADR-0021)' {
    BeforeAll { $script:tools = Get-LokiOfflineAgentToolset }

    It 'exposes exactly the two tools, in order, and no more' {
        @($script:tools).Count | Should -Be 2
        (@($script:tools | ForEach-Object { $_.function.name }) -join ',') | Should -Be 'run_command,final_answer'
    }
    It 'every tool is an OpenAI function with a single required string argument' {
        foreach ($t in $script:tools) {
            $t.type | Should -Be 'function'
            $t.function.parameters.type | Should -Be 'object'
            @($t.function.parameters.required).Count | Should -Be 1
            $argName = @($t.function.parameters.required)[0]
            $t.function.parameters.properties.$argName.type | Should -Be 'string'
        }
    }
    It 'serializes to a JSON array with array-typed `required` (the exact shape llama-server receives)' {
        # PS 5.1 ConvertTo-Json can collapse a single-element array to a scalar; if `required` came out as a bare
        # "command" instead of ["command"], the tool schema the engine is handed would be malformed. Assert the wire
        # shape directly (whitespace-stripped so formatting does not matter).
        $json = ConvertTo-Json -InputObject $script:tools -Depth 10
        $json.TrimStart().StartsWith('[') | Should -BeTrue
        $json | Should -Match 'run_command'
        $json | Should -Match 'final_answer'
        $flat = ($json -replace '\s', '')
        $flat | Should -Match '"required":\["command"\]'
        $flat | Should -Match '"required":\["answer"\]'
    }
}

Describe 'ConvertFrom-LokiAgentToolCall (engine reply -> next move; fail-safe, never a half-read command)' {
    It 'a run_command call -> Kind run + the command, trimmed' {
        $tc = @([pscustomobject]@{ function = [pscustomobject]@{ name = 'run_command'; arguments = '{"command":"  Get-Volume  "}' } })
        $move = ConvertFrom-LokiAgentToolCall -ToolCalls $tc
        $move.Kind    | Should -Be 'run'
        $move.Command | Should -Be 'Get-Volume'
    }
    It 'a final_answer call -> Kind final + the answer' {
        $tc = @([pscustomobject]@{ function = [pscustomobject]@{ name = 'final_answer'; arguments = '{"answer":"disk C: is full"}' } })
        (ConvertFrom-LokiAgentToolCall -ToolCalls $tc).Answer | Should -Be 'disk C: is full'
    }
    It 'plain prose with no tool call -> Kind final (a model that did not tool-call is still heard)' {
        (ConvertFrom-LokiAgentToolCall -Content 'VERDICT: nothing wrong').Kind | Should -Be 'final'
    }
    It 'FAIL-SAFE: malformed argument JSON -> none, never a half-read run' {
        $tc = @([pscustomobject]@{ function = [pscustomobject]@{ name = 'run_command'; arguments = '{"command": "Get-Vol' } })
        (ConvertFrom-LokiAgentToolCall -ToolCalls $tc).Kind | Should -Be 'none'
    }
    It 'FAIL-SAFE: run_command with an empty command -> none' {
        $tc = @([pscustomobject]@{ function = [pscustomobject]@{ name = 'run_command'; arguments = '{"command":"   "}' } })
        (ConvertFrom-LokiAgentToolCall -ToolCalls $tc).Kind | Should -Be 'none'
    }
    It 'FAIL-SAFE: an unknown tool name -> none (never guessed into run)' {
        $tc = @([pscustomobject]@{ function = [pscustomobject]@{ name = 'delete_everything'; arguments = '{}' } })
        (ConvertFrom-LokiAgentToolCall -ToolCalls $tc).Kind | Should -Be 'none'
    }
    It 'FAIL-SAFE: neither a tool call nor content -> none' {
        (ConvertFrom-LokiAgentToolCall).Kind | Should -Be 'none'
    }
    It 'takes only the FIRST tool call -- one fact per turn (a smuggled second command is ignored)' {
        $tc = @(
            [pscustomobject]@{ function = [pscustomobject]@{ name = 'run_command';  arguments = '{"command":"Get-Volume"}' } },
            [pscustomobject]@{ function = [pscustomobject]@{ name = 'run_command';  arguments = '{"command":"Remove-Item C:\\"}' } }
        )
        (ConvertFrom-LokiAgentToolCall -ToolCalls $tc).Command | Should -Be 'Get-Volume'
    }
}

Describe 'Invoke-LokiEngineChat -Tools (the transport carries the move set and reads tool_calls back)' {
    It 'sends the tools in the payload and returns tool_calls -- a null-content tool reply is still Ok' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{ choices = @([pscustomobject]@{ message = [pscustomobject]@{
                        content    = $null
                        tool_calls = @([pscustomobject]@{ function = [pscustomobject]@{ name = 'run_command'; arguments = '{"command":"Get-Volume"}' } })
                    } }) }
        }
        $res = Invoke-LokiEngineChat -BaseUri 'http://127.0.0.1:1' -Messages @(@{ role = 'user'; content = 'go' }) -Tools (Get-LokiOfflineAgentToolset)
        $res.Ok | Should -BeTrue
        @($res.ToolCalls).Count | Should -Be 1
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { ($Body -match '"tools"') -and ($Body -match 'run_command') }
    }
    It 'without -Tools the payload has no tools key (the analyze path is unchanged)' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{ choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = 'VERDICT: ok' } }) }
        }
        $res = Invoke-LokiEngineChat -BaseUri 'http://127.0.0.1:1' -Messages @(@{ role = 'user'; content = 'go' })
        $res.Content | Should -Be 'VERDICT: ok'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Body -notmatch '"tools"' }
    }
}

Describe 'Invoke-LokiOfflineAgent (WIP boundary -- #21-#22 replace this with the real loop)' {
    It 'throws an explicit not-yet-wired error rather than pretending to run' {
        # A security core must never ship a loop that only looks like it runs (CLAUDE.md 9). This guard is replaced by
        # real loop tests when #21-#22 land; its presence documents that the scaffold does not fake the loop.
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

# tests/guide.Tests.ps1 -- the guided mode. The handler is deliberately NOT invoked here: it prompts, and a test
# suite that can block on Read-Host is a suite nobody trusts to run unattended. Everything that DECIDES anything
# lives in lib/guide.ps1 as pure functions, which is exactly why it was put there (CLAUDE.md section 2 and 6).
Set-StrictMode -Version Latest

BeforeAll {
    Get-ChildItem "$PSScriptRoot\..\src\lib" -Filter *.ps1 | ForEach-Object { . $_.FullName }
    . "$PSScriptRoot\..\src\commands\guide.ps1"
    Initialize-LokiUi -NoColor

    # A facts hashtable shaped like Get-LokiGuideState returns one. Global on purpose: Pester 5+ does not carry a
    # plain BeforeAll function into the It scope.
    function global:New-LokiTestState {
        param(
            [bool]$EngineOk = $true,
            [int]$Fitting = 1,
            [int]$AgentFitting = 1,
            [int]$AgentInstalled = 1,
            [int]$Dumps = 1,
            [bool]$Auth = $true,
            [bool]$Online = $true
        )
        $mkTier = { param($n) 1..$n | ForEach-Object { @{ Id = 'mid'; ResidentGB = 7.0 } } }
        $mkDump = {
            param($n)
            1..$n | ForEach-Object {
                [pscustomobject]@{ Name = "dump-$_.json"; FullName = "C:\stick\reports\dump-$_.json" }
            }
        }
        return @{
            EngineOk       = $EngineOk
            EngineDetail   = ''
            Tiers          = @(& $mkTier $AgentInstalled)
            FittingTiers   = @(if ($Fitting -gt 0) { & $mkTier $Fitting } else { @() })
            AgentTiers     = @(if ($AgentFitting -gt 0) { & $mkTier $AgentFitting } else { @() })
            AgentInstalled = @(if ($AgentInstalled -gt 0) { & $mkTier $AgentInstalled } else { @() })
            Dumps          = @(if ($Dumps -gt 0) { & $mkDump $Dumps } else { @() })
            AuthPresent    = $Auth
            AuthMethod     = 'api'
            Online         = $Online
            TotalRamGB     = 32.0
        }
    }

    function global:Get-LokiTestOption {
        param($State, [string]$Id)
        # ASSIGN FIRST, then wrap -- Get-LokiGuideMenu ends in `return , @(...)`.
        $opts = Get-LokiGuideMenu -State $State
        return (@($opts) | Where-Object { $_.Id -eq $Id } | Select-Object -First 1)
    }
}

Describe 'Command guide' {
    It 'metadata is complete (Name == file name)' {
        $m = Get-LokiCmdMeta_guide
        $m.Name | Should -Be 'guide'
        $m.Summary | Should -Be 'guide.summary'
        $m.Usage | Should -Not -BeNullOrEmpty
        $m.Group | Should -Not -BeNullOrEmpty
    }
    It 'handler is defined (not invoked here -- it prompts)' {
        (Get-Command Invoke-LokiCmd_guide -CommandType Function) | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-LokiGuideMenu -- the menu model' {
    It 'the list survives @(): assign-then-wrap, not @(FUNC)' {
        # Guards the comma-return trap that has bitten this repo repeatedly: `return , @(...)` means @(FUNC)
        # collapses to ONE element, so a menu of six would silently render as one.
        $opts = Get-LokiGuideMenu -State (New-LokiTestState)
        @($opts).Count | Should -Be 6
    }

    It 'numbers are stable and independent of availability' {
        # Rule 1 in lib/guide.ps1: the technician who uses this daily must be able to build muscle memory.
        $a = Get-LokiGuideMenu -State (New-LokiTestState)
        $b = Get-LokiGuideMenu -State (New-LokiTestState -EngineOk $false -Fitting 0 -AgentFitting 0 -AgentInstalled 0 -Dumps 0 -Auth $false -Online $false)
        $rich = @($a)
        $bare = @($b)
        ($rich | ForEach-Object { $_.Id }) -join ',' | Should -Be (($bare | ForEach-Object { $_.Id }) -join ',')
        ($bare | ForEach-Object { $_.Number }) -join ',' | Should -Be '1,2,3,4,5,6'
    }

    It 'every unavailable entry carries BOTH a reason and a remedy' {
        # Rule 2: "not available" on its own teaches nothing, which is the entire failure this command replaces.
        $produced = Get-LokiGuideMenu -State (New-LokiTestState -EngineOk $false -Fitting 0 -AgentFitting 0 -AgentInstalled 0 -Dumps 0 -Auth $false -Online $false)
        $opts = @($produced)
        $unavailable = @($opts | Where-Object { -not $_.Available })
        $unavailable.Count | Should -BeGreaterThan 0
        foreach ($o in $unavailable) {
            $o.ReasonKey | Should -Not -BeNullOrEmpty -Because "$($o.Id) must say why"
            $o.RemedyKey | Should -Not -BeNullOrEmpty -Because "$($o.Id) must say what helps"
        }
    }

    It '<id> is available whatever the machine looks like' -ForEach @(
        @{ id = 'collect' }, @{ id = 'doctor' }
    ) {
        $state = New-LokiTestState -EngineOk $false -Fitting 0 -AgentFitting 0 -AgentInstalled 0 -Dumps 0 -Auth $false -Online $false
        (Get-LokiTestOption -State $state -Id $id).Available | Should -BeTrue
    }

    It 'analyze: <case>' -ForEach @(
        @{ case = 'no engine -> setup';        f = @{ EngineOk = $false };            reason = 'guide.reason.noEngine' }
        @{ case = 'no fitting tier -> hwscan'; f = @{ Fitting = 0 };                  reason = 'guide.reason.noFittingTier' }
        @{ case = 'no dump -> collect first';  f = @{ Dumps = 0 };                    reason = 'guide.reason.noDump' }
    ) {
        $o = Get-LokiTestOption -State (New-LokiTestState @f) -Id 'analyze'
        $o.Available | Should -BeFalse
        $o.ReasonKey | Should -Be $reason
    }

    It 'analyze is available and names the NEWEST dump in its teaching line' {
        $o = Get-LokiTestOption -State (New-LokiTestState -Dumps 3) -Id 'analyze'
        $o.Available | Should -BeTrue
        # Get-LokiGuideState sorts newest-first, so index 0 is the one the operator almost certainly means.
        $o.Args[0] | Should -Be '--analyze'
        $o.Args[1] | Should -Be 'C:\stick\reports\dump-1.json'
        $o.Teach | Should -BeLike '*dump-1.json'
    }

    It 'agent: an installed-but-too-large model does NOT get told to download it again' {
        # Found on the very first real run against a provisioned stick: `mid` was installed and merely did not fit
        # the free RAM, and the remedy said "run loki setup --tier mid". Confidently wrong advice is worse than
        # none, so the two causes are now distinct.
        $o = Get-LokiTestOption -State (New-LokiTestState -AgentFitting 0 -AgentInstalled 1) -Id 'agent'
        $o.Available | Should -BeFalse
        $o.ReasonKey | Should -Be 'guide.reason.agentTierTooBig'
        $o.RemedyKey | Should -Be 'guide.remedy.freeMemory'
    }

    It 'agent: nothing agent-capable installed -> that IS a download' {
        $o = Get-LokiTestOption -State (New-LokiTestState -AgentFitting 0 -AgentInstalled 0) -Id 'agent'
        $o.ReasonKey | Should -Be 'guide.reason.noAgentTier'
        $o.RemedyKey | Should -Be 'guide.remedy.setupMid'
    }

    It '<id>: no auth -> auth reason; auth but unreachable -> offline reason' -ForEach @(
        @{ id = 'ask' }, @{ id = 'chat' }
    ) {
        (Get-LokiTestOption -State (New-LokiTestState -Auth $false) -Id $id).ReasonKey | Should -Be 'guide.reason.noAuth'
        (Get-LokiTestOption -State (New-LokiTestState -Online $false) -Id $id).ReasonKey | Should -Be 'guide.reason.offline'
        (Get-LokiTestOption -State (New-LokiTestState) -Id $id).Available | Should -BeTrue
    }

    It 'BREAK-THE-GUARD: an id with no availability rule comes back unavailable, never silently available' {
        $opts = Get-LokiGuideMenu -State (New-LokiTestState) -Order @('collect', 'not-a-real-option')
        $bad = @($opts) | Where-Object { $_.Id -eq 'not-a-real-option' } | Select-Object -First 1
        $bad.Available | Should -BeFalse
        $bad.ReasonKey | Should -Be 'guide.reason.unknown'
    }
}

Describe 'Resolve-LokiGuideChoice' {
    BeforeAll {
        # ASSIGN FIRST, then wrap. Writing @(Get-LokiGuideMenu ...) here yields ONE element -- the whole
        # option array -- and every $o.Number below then reads back as an Object[]. Written wrong once, on the
        # same day as the test three Describes up that exists to catch exactly this.
        $produced = Get-LokiGuideMenu -State (New-LokiTestState -EngineOk $false)
        $script:opts = @($produced)
    }

    It '<label> quits' -ForEach @(
        @{ label = 'empty (Enter)'; text = '' }, @{ label = 'q'; text = 'q' }, @{ label = '0'; text = '0' }
    ) {
        (Resolve-LokiGuideChoice -Options $script:opts -Choice $text).Kind | Should -Be 'quit'
    }

    It '<label> is invalid with a reason' -ForEach @(
        @{ label = 'text';         text = 'abc'; reason = 'guide.error.notANumber' }
        @{ label = 'out of range'; text = '99';  reason = 'guide.error.outOfRange' }
    ) {
        $r = Resolve-LokiGuideChoice -Options $script:opts -Choice $text
        $r.Kind | Should -Be 'invalid'
        $r.ReasonKey | Should -Be $reason
    }

    It 'choosing an UNAVAILABLE number answers "why not" instead of pretending it does not exist' {
        $blocked = @($script:opts | Where-Object { -not $_.Available } | Select-Object -First 1)[0]
        $r = Resolve-LokiGuideChoice -Options $script:opts -Choice ([string]$blocked.Number)
        $r.Kind | Should -Be 'unavailable'
        $r.ReasonKey | Should -Be $blocked.ReasonKey
    }

    It 'choosing an available number runs it' {
        $ok = @($script:opts | Where-Object { $_.Available } | Select-Object -First 1)[0]
        $r = Resolve-LokiGuideChoice -Options $script:opts -Choice ([string]$ok.Number)
        $r.Kind | Should -Be 'run'
        $r.Option.Id | Should -Be $ok.Id
    }
}

Describe 'the guided mode can always be rendered' {
    It 'every key the guide can emit exists in EVERY locale' {
        # The worst moment for a missing translation is the one where the tool is explaining itself. This covers
        # both sources: the keys the options table produces, and the literal keys the handler passes to Get-LokiText.
        $needed = New-Object System.Collections.Generic.List[string]
        foreach ($f in @(
                (New-LokiTestState),
                (New-LokiTestState -EngineOk $false -Fitting 0 -AgentFitting 0 -AgentInstalled 0 -Dumps 0 -Auth $false -Online $false),
                (New-LokiTestState -AgentFitting 0 -AgentInstalled 1))) {
            $produced = Get-LokiGuideMenu -State $f
            foreach ($o in @($produced)) {
                $needed.Add([string]$o.LabelKey)
                if (-not [string]::IsNullOrEmpty([string]$o.ReasonKey)) { $needed.Add([string]$o.ReasonKey) }
                if (-not [string]::IsNullOrEmpty([string]$o.RemedyKey)) { $needed.Add([string]$o.RemedyKey) }
            }
        }
        $handlerText = Get-Content -LiteralPath "$PSScriptRoot\..\src\commands\guide.ps1" -Raw -Encoding utf8
        foreach ($m in [regex]::Matches($handlerText, "Get-LokiText\s+'([^']+)'")) { $needed.Add($m.Groups[1].Value) }
        $needed.Add('guide.reason.unknown'); $needed.Add('guide.remedy.none')

        $keys = @($needed.ToArray() | Sort-Object -Unique)
        # A floor, not a headcount: it must catch a collector that silently found nothing, without becoming a
        # number that has to be edited every time a key is added. The three spot-checks below are the real
        # assertion -- one from each source, so a regression in ANY of the three shows up as a named miss rather
        # than as a count that happens to still clear the bar.
        $keys.Count | Should -BeGreaterThan 15 -Because 'a matcher that found nothing would pass vacuously'
        $keys | Should -Contain 'guide.title'                    # literal, from the handler
        $keys | Should -Contain 'guide.opt.collect'              # label, from the options table
        $keys | Should -Contain 'guide.reason.agentTierTooBig'   # conditional reason, only in one facts shape

        foreach ($locale in @('en', 'de')) {
            $cat = Import-PowerShellDataFile -LiteralPath "$PSScriptRoot\..\src\i18n\$locale.psd1"
            foreach ($k in $keys) {
                $cat.ContainsKey($k) | Should -BeTrue -Because "$locale is missing '$k'"
            }
        }
    }
}

Describe 'Get-LokiGuideState never throws' {
    It 'a missing stick yields an all-unavailable picture instead of an exception' {
        # A guide that crashes while explaining a broken machine is worse than no guide at all.
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ('loki-guide-nope-' + [guid]::NewGuid().ToString('N'))
        # Called directly, NOT inside a { } passed to Should -Not -Throw: that scriptblock runs in a child scope,
        # so the assignment would be invisible out here (and the follow-up assertions would test $null). A throw
        # fails this test just as loudly either way.
        $state = Get-LokiGuideState -AppRoot $missing -Config @{} -SkipNetwork
        $state.EngineOk | Should -BeFalse
        @($state.Dumps).Count | Should -Be 0
        $opts = Get-LokiGuideMenu -State $state
        @($opts).Count | Should -Be 6
    }
}

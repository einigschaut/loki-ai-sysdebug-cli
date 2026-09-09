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

        # A THIRD source, and the regex above cannot see it: the session's status row resolves whatever
        # Get-LokiGuideEngineLabel returns, so the key is never a literal in the handler. Collected by calling it.
        foreach ($f in @(
                (New-LokiTestState -Auth $true -Online $true),
                (New-LokiTestState -Auth $false -Online $true),
                (New-LokiTestState -Auth $false -Online $false -EngineOk $false -Fitting 0))) {
            $needed.Add((Get-LokiGuideEngineLabel -State $f))
        }

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

Describe 'Get-LokiGuideMenuLine -- one source of truth for the menu text' {

    It 'renders an available entry as exactly one numbered line' {
        $opts = Get-LokiGuideMenu -State (New-LokiTestState)
        $opts = @($opts)
        $lines = @(Get-LokiGuideMenuLine -Options $opts)
        $first = @($lines | Where-Object { $_.Role -eq 'available' })[0]
        $first.Text | Should -Match '^\s+1\)\s+\S'
    }

    It 'renders an unavailable entry as THREE lines: the entry, the reason, the remedy' {
        # Shown, numbered and muted -- never hidden. The reason and the remedy are the most useful thing on the
        # screen for someone new to the tool, so losing either of them is a regression worth a test.
        $blind = New-LokiTestState -EngineOk $false -Fitting 0 -AgentFitting 0 -AgentInstalled 0 -Dumps 0 -Auth $false -Online $false
        $opts = Get-LokiGuideMenu -State $blind
        $opts = @($opts)
        $unavailable = @($opts | Where-Object { -not $_.Available })
        $unavailable.Count | Should -BeGreaterThan 0
        $lines = @(Get-LokiGuideMenuLine -Options $opts)
        $available = @($opts | Where-Object { $_.Available })
        $lines.Count | Should -Be ($available.Count + ($unavailable.Count * 3))
    }

    It 'keeps the numbers where Get-LokiGuideMenu put them, available or not' {
        # Rule 1 of lib/guide.ps1: the numbers never move, so muscle memory survives a machine that can do less
        # today than it could yesterday.
        $blind = New-LokiTestState -EngineOk $false -Fitting 0 -AgentFitting 0 -AgentInstalled 0 -Dumps 0 -Auth $false -Online $false
        foreach ($state in @((New-LokiTestState), $blind)) {
            $menu = Get-LokiGuideMenu -State $state
            $lines = @(Get-LokiGuideMenuLine -Options @($menu))
            $numbered = @($lines | Where-Object { $_.Text -match '^\s+(\d+)\)' } | ForEach-Object { [int]([regex]::Match($_.Text, '^\s+(\d+)\)').Groups[1].Value) })
            ($numbered -join ',') | Should -Be '1,2,3,4,5,6'
        }
    }

    It 'emits no escape sequence, because the session paints it into a diffed model' {
        $menu = Get-LokiGuideMenu -State (New-LokiTestState)
        $lines = @(Get-LokiGuideMenuLine -Options @($menu))
        foreach ($l in $lines) { ([string]$l.Text) | Should -Not -Match ([char]27) }
    }

    It 'survives an empty menu instead of throwing' {
        @(Get-LokiGuideMenuLine -Options @()).Count | Should -Be 0
    }
}

Describe 'Get-LokiGuideEngineLabel' {

    It 'names the online engine when a credential is present and the machine is reachable' {
        Get-LokiGuideEngineLabel -State (New-LokiTestState -Auth $true -Online $true) | Should -Be 'guide.engine.online'
    }

    It 'falls back to offline when there is no credential or no network' {
        Get-LokiGuideEngineLabel -State (New-LokiTestState -Auth $false -Online $true) | Should -Be 'guide.engine.offline'
        Get-LokiGuideEngineLabel -State (New-LokiTestState -Auth $true -Online $false) | Should -Be 'guide.engine.offline'
    }

    It 'says so plainly when neither is available -- which is not an error state' {
        # A stick with no model and no credential still runs collect and doctor, which is most of what it is for.
        $bare = New-LokiTestState -Auth $false -Online $false -EngineOk $false -Fitting 0
        Get-LokiGuideEngineLabel -State $bare | Should -Be 'guide.engine.none'
    }

    It 'prefers online when BOTH are available, matching the order the menu lists them in' {
        $both = New-LokiTestState -Auth $true -Online $true -EngineOk $true -Fitting 1
        Get-LokiGuideEngineLabel -State $both | Should -Be 'guide.engine.online'
    }
}

Describe 'Invoke-LokiGuideSession -- the loop' {

    BeforeAll {
        Initialize-LokiI18n -AppRoot (Resolve-Path "$PSScriptRoot\..\src").Path -Locale 'en' | Out-Null

        # Hands back a scripted sequence of rounds, one per call, and remembers the state it was given so the
        # test can look at the transcript the loop built.
        function global:Set-LokiTestRound {
            param([object[]]$Rounds)
            $script:rounds = @($Rounds)
            $script:roundIndex = 0
            $script:seenState = $null
        }

        function global:New-LokiTestGuideContext {
            param([scriptblock]$Handler = { return 0 })
            return @{
                AppRoot  = 'C:\stick'
                Version  = '9.9.9'
                Args     = @()
                Flags    = @{ Plain = $false; Quiet = $false }
                Registry = @(
                    @{ Name = 'collect'; Handler = $Handler },
                    @{ Name = 'doctor';  Handler = $Handler },
                    @{ Name = 'offline'; Handler = $Handler },
                    @{ Name = 'ask';     Handler = $Handler },
                    @{ Name = 'chat';    Handler = $Handler }
                )
            }
        }
    }

    BeforeEach {
        Mock -CommandName Get-LokiGuideState -MockWith { return (New-LokiTestState) }
        Mock -CommandName Open-LokiSession -MockWith { return $true }
        Mock -CommandName Close-LokiSession -MockWith { }
        Mock -CommandName Invoke-LokiSessionRound -MockWith {
            $script:seenState = $State
            if ($script:roundIndex -ge $script:rounds.Count) {
                return [pscustomobject]@{ Action = 'exit'; Text = '' }
            }
            $r = $script:rounds[$script:roundIndex]
            $script:roundIndex++
            return $r
        }
    }

    It 'draws the identity ONCE, at the top, then the menu -- before it reads anything' {
        # The art itself is brand.ps1's business and is tested there; what matters here is that it is asked for,
        # placed first, and asked for only once however many rounds the session runs.
        Mock -CommandName Get-LokiBrandArt -MockWith { return @('<identity>') }
        Set-LokiTestRound -Rounds @(
            ([pscustomobject]@{ Action = ''; Text = '' }),
            ([pscustomobject]@{ Action = 'exit'; Text = '' })
        )
        [void](Invoke-LokiGuideSession -Context (New-LokiTestGuideContext) -Config @{})
        $lines = @($script:seenState.Lines)
        $lines[0] | Should -Be '<identity>'
        Should -Invoke Get-LokiBrandArt -Times 1 -Exactly
        $text = ($lines -join "`n")
        $text | Should -Match '9\.9\.9'
        $text | Should -Match '1\)'
    }

    It 'asks the screen how wide it is, rather than guessing the banner width' {
        # Below 34 columns the art collapses to one line instead of wrapping into rubble (issue #121), so the
        # width has to be the real one.
        Mock -CommandName Get-LokiScreenSize -MockWith { return [pscustomobject]@{ Width = 120; Height = 30 } }
        Mock -CommandName Get-LokiBrandArt -MockWith { return @("w=$Width t=$Tier") }
        Set-LokiTestRound -Rounds @(([pscustomobject]@{ Action = 'exit'; Text = '' }))
        [void](Invoke-LokiGuideSession -Context (New-LokiTestGuideContext) -Config @{})
        @($script:seenState.Lines)[0] | Should -Match '^w=120 t='
    }

    It 'leaves with Ok on the second Ctrl+C, whatever the commands inside it returned' {
        # ADR-0038: a session's exit code describes the SESSION. "collect, then offline, then quit" did exactly
        # what was asked, and reporting offline's 5 would make the code depend on which command happened to be last.
        Set-LokiTestRound -Rounds @(
            ([pscustomobject]@{ Action = 'submit'; Text = '1' }),
            ([pscustomobject]@{ Action = 'exit'; Text = '' })
        )
        $ctx = New-LokiTestGuideContext -Handler { return 5 }
        Invoke-LokiGuideSession -Context $ctx -Config @{} | Should -Be 0
    }

    It 'leaves on q without running anything' {
        Set-LokiTestRound -Rounds @(([pscustomobject]@{ Action = 'submit'; Text = 'q' }))
        # A captured LIST, not a $script: counter. Inside .GetNewClosure() a $script: reference resolves to the
        # closure own scope, not to this file -- so the counter stayed 0 whatever happened, and THREE of the four
        # tests using it were green for that reason rather than because nothing ran. Caught 2026-08-31 by the one
        # assertion that expected a NON-zero count. A captured reference type is mutated in place and IS visible.
        $calls = New-Object System.Collections.Generic.List[string]
        $ctx = New-LokiTestGuideContext -Handler { $calls.Add('ran'); return 0 }.GetNewClosure()
        Invoke-LokiGuideSession -Context $ctx -Config @{} | Should -Be 0
        $calls.Count | Should -Be 0
    }

    It 'runs an ordinary command INSIDE the session and never hands the screen over' {
        # ADR-0040, and the point of the whole slice: the reference captures what it runs, it does not become a
        # launcher. Closing the screen for a command the session can capture would be the launcher behaviour.
        Set-LokiTestRound -Rounds @(
            ([pscustomobject]@{ Action = 'submit'; Text = '1' }),
            ([pscustomobject]@{ Action = 'exit'; Text = '' })
        )
        # A captured LIST, not a $script: counter. Inside .GetNewClosure() a $script: reference resolves to the
        # closure own scope, not to this file -- so the counter stayed 0 whatever happened, and THREE of the four
        # tests using it were green for that reason rather than because nothing ran. Caught 2026-08-31 by the one
        # assertion that expected a NON-zero count. A captured reference type is mutated in place and IS visible.
        $calls = New-Object System.Collections.Generic.List[string]
        $ctx = New-LokiTestGuideContext -Handler { $calls.Add('ran'); return 0 }.GetNewClosure()
        [void](Invoke-LokiGuideSession -Context $ctx -Config @{})
        $calls.Count | Should -Be 1
        Should -Invoke Close-LokiSession -Times 0 -Exactly
        Should -Invoke Open-LokiSession -Times 0 -Exactly
    }

    It 'captures an ordinary command output into the transcript, line by line' {
        # End to end: the handler prints through the real ui.ps1 seam, the sink catches it, and it lands in the
        # session transcript instead of on the console.
        Set-LokiTestRound -Rounds @(
            ([pscustomobject]@{ Action = 'submit'; Text = '1' }),
            ([pscustomobject]@{ Action = 'exit'; Text = '' })
        )
        Mock -CommandName Write-LokiSessionFrame -MockWith { }
        $ctx = New-LokiTestGuideContext -Handler {
            Write-LokiLine 'collected 3 event logs'
            Write-LokiErr 'one source was unreadable'
            return 0
        }
        [void](Invoke-LokiGuideSession -Context $ctx -Config @{})
        $text = ($script:seenState.Lines -join "`n")
        $text | Should -Match 'collected 3 event logs'
        $text | Should -Match 'one source was unreadable'
    }

    It 'leaves the sink cleared even when the command throws' {
        # A sink left registered after the session that owns it would swallow every later line of output --
        # including the dispatcher own error path -- into an object nobody reads.
        Set-LokiTestRound -Rounds @(
            ([pscustomobject]@{ Action = 'submit'; Text = '1' }),
            ([pscustomobject]@{ Action = 'exit'; Text = '' })
        )
        Mock -CommandName Write-LokiSessionFrame -MockWith { }
        $ctx = New-LokiTestGuideContext -Handler { throw 'boom' }
        { Invoke-LokiGuideSession -Context $ctx -Config @{} } | Should -Throw
        Test-LokiWriteSinkActive | Should -BeFalse
    }

    It 'hands the console over ONLY for a command that declares itself interactive' {
        # Mocked HERE and not in BeforeEach: a blanket Write-LokiLine mock hides the very thing the capture
        # test asserts -- the handler output never reaches ui.ps1 at all. Only the hand-over path prints.
        Mock -CommandName Write-LokiLine -MockWith { }
        Mock -CommandName Write-LokiInfo -MockWith { }
        # chat inherits the console on purpose (a live Claude TUI) and agent asks Read-Host before every mutating
        # command. A captured confirm prompt is a prompt nobody can answer.
        $menu = Get-LokiGuideMenu -State (New-LokiTestState)
        $chat = @(@($menu) | Where-Object { $_.Id -eq 'chat' })[0]
        Set-LokiTestRound -Rounds @(
            ([pscustomobject]@{ Action = 'submit'; Text = [string]$chat.Number }),
            ([pscustomobject]@{ Action = 'exit'; Text = '' })
        )
        $calls = New-Object System.Collections.Generic.List[string]
        $ctx = New-LokiTestGuideContext -Handler { $calls.Add('ran'); return 0 }.GetNewClosure()
        [void](Invoke-LokiGuideSession -Context $ctx -Config @{})
        $calls.Count | Should -Be 1
        Should -Invoke Close-LokiSession -Times 1 -Exactly
        Should -Invoke Open-LokiSession -Times 1 -Exactly
    }

    It 'recomputes what the machine can do AFTER a command, not before it' {
        # The complaint that opened #133: the operator ran collect and then chose "analyse a dump" against a menu
        # computed before the dump existed.
        Set-LokiTestRound -Rounds @(
            ([pscustomobject]@{ Action = 'submit'; Text = '1' }),
            ([pscustomobject]@{ Action = 'exit'; Text = '' })
        )
        [void](Invoke-LokiGuideSession -Context (New-LokiTestGuideContext) -Config @{})
        Should -Invoke Get-LokiGuideState -Times 2 -Exactly
    }

    It 'does NOT recompute per keystroke -- the probe opens a socket' {
        Set-LokiTestRound -Rounds @(
            ([pscustomobject]@{ Action = ''; Text = '' }),
            ([pscustomobject]@{ Action = ''; Text = '' }),
            ([pscustomobject]@{ Action = 'exit'; Text = '' })
        )
        [void](Invoke-LokiGuideSession -Context (New-LokiTestGuideContext) -Config @{})
        Should -Invoke Get-LokiGuideState -Times 1 -Exactly
    }

    It 'answers a typo with a notice and runs nothing' {
        Set-LokiTestRound -Rounds @(
            ([pscustomobject]@{ Action = 'submit'; Text = 'zzz' }),
            ([pscustomobject]@{ Action = 'exit'; Text = '' })
        )
        # A captured LIST, not a $script: counter. Inside .GetNewClosure() a $script: reference resolves to the
        # closure own scope, not to this file -- so the counter stayed 0 whatever happened, and THREE of the four
        # tests using it were green for that reason rather than because nothing ran. Caught 2026-08-31 by the one
        # assertion that expected a NON-zero count. A captured reference type is mutated in place and IS visible.
        $calls = New-Object System.Collections.Generic.List[string]
        $ctx = New-LokiTestGuideContext -Handler { $calls.Add('ran'); return 0 }.GetNewClosure()
        [void](Invoke-LokiGuideSession -Context $ctx -Config @{})
        $calls.Count | Should -Be 0
        $script:seenState.Notice | Should -Not -Be ''
    }

    It 'writes the reason AND the remedy into the transcript for an unavailable entry' {
        # Choosing an unavailable option is itself a way of asking "why not?", so the answer must survive the next
        # keystroke -- which a one-line notice would not.
        Mock -CommandName Get-LokiGuideState -MockWith {
            return (New-LokiTestState -EngineOk $false -Fitting 0 -AgentFitting 0 -AgentInstalled 0 -Dumps 0 -Auth $false -Online $false)
        }
        $opts = Get-LokiGuideMenu -State (New-LokiTestState -EngineOk $false -Fitting 0 -AgentFitting 0 -AgentInstalled 0 -Dumps 0 -Auth $false -Online $false)
        $opts = @($opts)
        $blocked = @($opts | Where-Object { -not $_.Available })[0]
        Set-LokiTestRound -Rounds @(
            ([pscustomobject]@{ Action = 'submit'; Text = [string]$blocked.Number }),
            ([pscustomobject]@{ Action = 'exit'; Text = '' })
        )
        # A captured LIST, not a $script: counter. Inside .GetNewClosure() a $script: reference resolves to the
        # closure own scope, not to this file -- so the counter stayed 0 whatever happened, and THREE of the four
        # tests using it were green for that reason rather than because nothing ran. Caught 2026-08-31 by the one
        # assertion that expected a NON-zero count. A captured reference type is mutated in place and IS visible.
        $calls = New-Object System.Collections.Generic.List[string]
        $ctx = New-LokiTestGuideContext -Handler { $calls.Add('ran'); return 0 }.GetNewClosure()
        [void](Invoke-LokiGuideSession -Context $ctx -Config @{})
        $calls.Count | Should -Be 0
        $text = ($script:seenState.Lines -join "`n")
        $text | Should -Match ([regex]::Escape((Get-LokiText ([string]$blocked.ReasonKey))))
        $text | Should -Match ([regex]::Escape((Get-LokiText ([string]$blocked.RemedyKey))))
    }

    It 'keeps the session on Escape' {
        Set-LokiTestRound -Rounds @(
            ([pscustomobject]@{ Action = 'interrupt'; Text = '' }),
            ([pscustomobject]@{ Action = 'exit'; Text = '' })
        )
        Invoke-LokiGuideSession -Context (New-LokiTestGuideContext) -Config @{} | Should -Be 0
        $script:roundIndex | Should -Be 2
    }

    It 'stops when the console goes away underneath it' {
        Set-LokiTestRound -Rounds @(([pscustomobject]@{ Action = 'closed'; Text = '' }))
        Invoke-LokiGuideSession -Context (New-LokiTestGuideContext) -Config @{} | Should -Be 0
    }

    It 'returns the command exit code when the screen cannot be taken back after an interactive one' {
        Mock -CommandName Write-LokiLine -MockWith { }
        Mock -CommandName Write-LokiInfo -MockWith { }
        # Only reachable on the interactive path, because that is the only path that gives the console away. The
        # console changed its mind while the command had it -- resized below the floor, redirected, or the screen
        # disabled itself. Leaving with what the command returned beats looping on a session that cannot draw.
        Mock -CommandName Open-LokiSession -MockWith { return $false }
        $menu = Get-LokiGuideMenu -State (New-LokiTestState)
        $chat = @(@($menu) | Where-Object { $_.Id -eq 'chat' })[0]
        Set-LokiTestRound -Rounds @(
            ([pscustomobject]@{ Action = 'submit'; Text = [string]$chat.Number }),
            ([pscustomobject]@{ Action = 'exit'; Text = '' })
        )
        $ctx = New-LokiTestGuideContext -Handler { return 6 }
        Invoke-LokiGuideSession -Context $ctx -Config @{} | Should -Be 6
    }

    It 'records what ran, with its exit code, in the transcript' {
        Set-LokiTestRound -Rounds @(
            ([pscustomobject]@{ Action = 'submit'; Text = '1' }),
            ([pscustomobject]@{ Action = 'exit'; Text = '' })
        )
        $ctx = New-LokiTestGuideContext -Handler { return 3 }
        [void](Invoke-LokiGuideSession -Context $ctx -Config @{})
        ($script:seenState.Lines -join "`n") | Should -Match 'loki collect'
        ($script:seenState.Lines -join "`n") | Should -Match '3'
    }

    It 'puts the engine on the session status, and nothing else about the machine' {
        Set-LokiTestRound -Rounds @(([pscustomobject]@{ Action = 'exit'; Text = '' }))
        [void](Invoke-LokiGuideSession -Context (New-LokiTestGuideContext) -Config @{})
        $script:seenState.Engine | Should -Be (Get-LokiText 'guide.engine.online')
        # Not the stick path: it never changes and would eat the width the steering keys need (ADR-0038).
        $script:seenState.Engine | Should -Not -Match 'C:\\stick'
    }
}

Describe 'the capture sink -- Open/Write/Close-LokiSessionCapture' {

    AfterEach { Close-LokiSessionCapture }

    BeforeEach {
        Mock -CommandName Write-LokiSessionFrame -MockWith { }
        $script:sinkState = New-LokiSessionState -Tier 'ascii'
        Open-LokiSessionCapture -State $script:sinkState
    }

    It 'turns a line into a transcript entry' {
        Write-LokiSessionCapture -Write @{ Text = 'collected 3 event logs'; NoNewline = $false; Stream = 'out'; Color = $null }
        @($script:sinkState.Lines)[-1] | Should -Be 'collected 3 event logs'
    }

    It 'turns a no-newline write into the NOTICE, not into a transcript row' {
        # The spinner rewinds its own line several times a second. One transcript row per frame would bury
        # everything else -- which is exactly why the reference gives its spinner a row of its own.
        Write-LokiSessionCapture -Write @{ Text = "`r  ~---  checking"; NoNewline = $true; Stream = 'out'; Color = 'DarkGreen' }
        $script:sinkState.Lines.Count | Should -Be 0
        $script:sinkState.Notice | Should -Be '~---  checking'
        $script:sinkState.Notice | Should -Not -Match "`r"
    }

    It 'clears the notice when the spinner clears its own line' {
        Write-LokiSessionCapture -Write @{ Text = "`r  ~---  checking"; NoNewline = $true; Stream = 'out'; Color = $null }
        # Asserted BEFORE the clear, and that is the point: written as "clear it, then check it is empty" this
        # test passed with the no-newline branch deliberately removed, because the notice was empty the whole time.
        # A test whose expected value is also the default value proves nothing (CLAUDE.md section 9).
        $script:sinkState.Notice | Should -Not -Be ''
        Write-LokiSessionCapture -Write @{ Text = "`r            `r"; NoNewline = $true; Stream = 'out'; Color = $null }
        $script:sinkState.Notice | Should -Be ''
    }

    It 'does not add a second marker to a warning that already carries one' {
        # Write-LokiWarn prefixes "! " and Write-LokiErr "x " BEFORE calling Write-LokiToStdErr, so the text
        # arriving here already has it. A marker added here would print "x x failed".
        Write-LokiSessionCapture -Write @{ Text = 'x it failed'; NoNewline = $false; Stream = 'err'; Color = 'Red' }
        @($script:sinkState.Lines)[-1] | Should -Be 'x it failed'
    }

    It 'never drops a line, however fast they arrive' {
        # The repaint is rate-limited; the APPEND must not be. Dropping a frame costs nothing, dropping a line
        # loses output.
        for ($i = 0; $i -lt 200; $i++) {
            Write-LokiSessionCapture -Write @{ Text = "line $i"; NoNewline = $false; Stream = 'out'; Color = $null }
        }
        $script:sinkState.Lines.Count | Should -Be 200
        @($script:sinkState.Lines)[-1] | Should -Be 'line 199'
    }

    It 'rate-limits the repaint rather than painting once per line' {
        # A frame per line would be hundreds of console writes for one `collect`. The reference paints 8 times a
        # second, and Test-LokiSpinnerDue is the rate limiter this codebase already uses for that question.
        $script:paints = New-Object System.Collections.Generic.List[string]
        Mock -CommandName Write-LokiSessionFrame -MockWith { [void]$script:paints.Add('x') }
        for ($i = 0; $i -lt 200; $i++) {
            Write-LokiSessionCapture -Write @{ Text = "line $i"; NoNewline = $false; Stream = 'out'; Color = $null }
        }
        $script:sinkState.Lines.Count | Should -Be 200
        $script:paints.Count | Should -BeLessThan 200 -Because 'the paint is capped, the append is not'
        $script:paints.Count | Should -BeGreaterThan 0 -Because 'output must still appear while a command runs'
    }

    It 'splits a multi-line write into separate transcript rows' {
        Write-LokiSessionCapture -Write @{ Text = "first`nsecond"; NoNewline = $false; Stream = 'out'; Color = $null }
        $script:sinkState.Lines.Count | Should -Be 2
    }
}

Describe 'the Interactive flag on the option table' {

    It 'is true for exactly the two entries that need the console themselves' {
        # Measured, not guessed (ADR-0040): lib/claude.ps1 launches the Claude CLI with no stream redirected so it
        # inherits the console, and lib/offline-agent.ps1 asks Read-Host before every mutating command. Everything
        # else writes through the ui.ps1 seam or through an already-redirected child.
        $menu = Get-LokiGuideMenu -State (New-LokiTestState)
        $interactive = @(@($menu) | Where-Object { $_.Interactive } | ForEach-Object { $_.Id } | Sort-Object)
        ($interactive -join ',') | Should -Be 'agent,chat'
    }

    It 'gives every entry the flag, so a caller never reads a missing key under StrictMode' {
        foreach ($o in @(Get-LokiGuideMenu -State (New-LokiTestState))) {
            $o.ContainsKey('Interactive') | Should -BeTrue -Because "$($o.Id) must declare it"
        }
    }
}

Describe 'Get-LokiGuideCommandTarget / New-LokiGuideChildContext' {

    It 'finds a registered command and reports a missing one as null' {
        $registry = @(@{ Name = 'collect'; Handler = { 0 } }, @{ Name = 'doctor'; Handler = { 0 } })
        (Get-LokiGuideCommandTarget -Registry $registry -Name 'doctor').Name | Should -Be 'doctor'
        Get-LokiGuideCommandTarget -Registry $registry -Name 'nope' | Should -BeNullOrEmpty
    }

    It 'builds exactly the context shape the dispatcher builds' {
        # If these two ever diverge, the guide becomes a second definition of what a command receives -- and the
        # one nobody types is the one that rots.
        $ctx = @{ AppRoot = 'C:\stick'; Version = '1.2.3'; Args = @('ignored'); Flags = @{ Plain = $true }; Registry = @() }
        $child = New-LokiGuideChildContext -Context $ctx -CommandArgs @('--analyze', 'x.json')
        @($child.Keys | Sort-Object) -join ',' | Should -Be 'AppRoot,Args,Flags,Registry,Version'
        $child.AppRoot | Should -Be 'C:\stick'
        $child.Version | Should -Be '1.2.3'
        @($child.Args) -join ',' | Should -Be '--analyze,x.json'
        $child.Flags.Plain | Should -BeTrue
    }
}

Describe 'Get-LokiGuideFlag' {
    It 'reads a flag, and treats a missing key or a missing hashtable as false' {
        # StrictMode makes a missing key a throw, and the dispatcher is not the only thing that builds a context.
        Get-LokiGuideFlag -Flags @{ Plain = $true } -Name 'Plain' | Should -BeTrue
        Get-LokiGuideFlag -Flags @{ Plain = $false } -Name 'Plain' | Should -BeFalse
        Get-LokiGuideFlag -Flags @{} -Name 'Plain' | Should -BeFalse
        Get-LokiGuideFlag -Flags $null -Name 'Plain' | Should -BeFalse
        Get-LokiGuideFlag -Flags 'not a hashtable' -Name 'Plain' | Should -BeFalse
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

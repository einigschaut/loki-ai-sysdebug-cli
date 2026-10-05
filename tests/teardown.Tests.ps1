# tests/teardown.Tests.ps1 -- giving the operator's console back (issue #133 review, invariant I1).
#
# I1, in one sentence: after Loki ends by any path short of a hard kill -- including an exception or a stop at ANY
# instruction -- the operator's console is as Loki found it: main screen visible and untouched, cursor visible, Ctrl+C
# handled the way it was before Loki started.
#
# The test that matters most is the property test below. It does not pick the failure points a human would think of;
# it runs one full open -> frame -> close cycle against a fake console that interprets what Loki writes
# (tests/helpers/LokiTestConsole.ps1), counts every console call in it, and then fails the cycle at EACH of those calls
# in turn -- once by throwing, once by reporting failure -- and asks whether the console came back. An independent
# review found that an exception between entering the alternate screen and recording it left the operator in the
# alternate screen with the cursor hidden; that is one of the points this walks over, and so is every other.
Set-StrictMode -Version Latest

BeforeAll {
    Get-ChildItem "$PSScriptRoot\..\src\lib" -Filter *.ps1 | ForEach-Object { . $_.FullName }
    . "$PSScriptRoot\helpers\LokiTestConsole.ps1"
    Initialize-LokiUi -NoColor
    Initialize-LokiI18n -AppRoot (Resolve-Path "$PSScriptRoot\..\src").Path -Locale 'en' | Out-Null
}

Describe 'the fake console itself -- a wrong double makes every test below meaningless' {
    # This block exists because the double's first version read ESC[?1049h as a cursor move: PowerShell's -eq compares
    # [char]'h' and [char]'H' as EQUAL. Every session open then failed inside the double, no session ever opened, and
    # the fault walk below passed all 80 points against code that really does leave the operator stranded -- it was
    # walking over nothing. The same case trap is finding B6 in the renderer.

    It 'tells ?1049h (enter, lowercase h) apart from a cursor move (uppercase H)' {
        $tc = New-LokiTestConsole -Width 20 -Height 4
        $esc = [string][char]27
        [void]$tc.Write($esc + '[?1049h')
        $tc.AltOn | Should -BeTrue
        $tc.Unknown.Count | Should -Be 0
        [void]$tc.Write($esc + '[2;3H' + 'xy')
        $tc.Alt[1].Substring(2, 2) | Should -BeExactly 'xy'
        [void]$tc.Write($esc + '[?1049l')
        $tc.AltOn | Should -BeFalse
    }

    It 'leaves the main buffer untouched while the alternate screen is active, and reports it restored' {
        $tc = New-LokiTestConsole -Width 20 -Height 4
        $esc = [string][char]27
        [void]$tc.Write($esc + '[?1049h' + $esc + '[?25l' + $esc + '[1;1H' + 'drawn in alt')
        $tc.IsRestored() | Should -BeFalse
        [void]$tc.Write($esc + '[?25h' + $esc + '[?1049l' + $esc + '[m')
        $tc.IsRestored() | Should -BeTrue
    }

    It 'notices text written into the MAIN buffer' {
        $tc = New-LokiTestConsole -Width 20 -Height 4
        [void]$tc.Write('stray')
        $tc.IsRestored() | Should -BeFalse
    }

    It 'fails the N-th console call, by throwing or by reporting failure' {
        $tc = New-LokiTestConsole -Width 20 -Height 4
        $tc.FailAt = 2
        $tc.Write('a') | Should -BeTrue
        { $tc.Write('b') } | Should -Throw '*injected fault at console call 2*'
        $tc = New-LokiTestConsole -Width 20 -Height 4
        $tc.FailAt = 1
        $tc.FailMode = 'false'
        $tc.Write('a') | Should -BeFalse
    }
}

Describe 'I1 -- the console comes back after a failure at any console call' {

    BeforeEach {
        $script:tc = New-LokiTestConsole -Width 60 -Height 12
        Mock -CommandName Get-LokiConsoleFact -MockWith { return $script:tc.Fact() }
        Mock -CommandName Test-LokiVtProcessing -MockWith { [void]$script:tc.Tick('vt-probe'); return $true }
        Mock -CommandName Write-LokiScreenRaw -MockWith { return $script:tc.Write($Text) }
        Mock -CommandName Get-LokiScreenRow -MockWith { return $script:tc.ReadRow($Row, $Width) }
        Mock -CommandName Request-LokiCtrlCInput -MockWith { return $script:tc.SetCtrlC($Enabled) }
        Mock -CommandName Get-LokiCtrlCInput -MockWith { return $script:tc.GetCtrlC() }
        Mock -CommandName Get-LokiKeyreadFact -MockWith { [void]$script:tc.Tick('keyread-fact'); return @{ HostName = 'ConsoleHost'; InputRedirected = $false } }
        Initialize-LokiScreen
        Initialize-LokiKeyread
        Initialize-LokiSession
    }

    AfterEach {
        Initialize-LokiScreen
        Initialize-LokiKeyread
        Initialize-LokiSession
    }

    It 'a fault-free cycle leaves the console restored, and is long enough to be worth walking' {
        $script:tc.Calls = 0
        [void](Open-LokiSession)
        Test-LokiSessionOpen | Should -BeTrue -Because 'the cycle must actually reach the screen, or the walk tests nothing'
        Write-LokiSessionFrame -State (New-LokiSessionState -Tier 'ascii')
        Close-LokiSession
        Restore-LokiConsole
        $script:tc.IsRestored() | Should -BeTrue -Because $script:tc.Describe()
        $script:tc.Calls | Should -BeGreaterThan 15
        $script:tc.Unknown.Count | Should -Be 0 -Because "every sequence Loki sends must be one the double understands: $($script:tc.Unknown -join ', ')"
    }

    It 'restores the console when the cycle fails at console call <n> by <mode>' -ForEach @(
        # The walk is generated, not hand-picked. 40 covers the whole cycle with room to spare; a call number past the
        # end of the cycle simply never fires, which is the fault-free case again and must also pass.
        foreach ($m in @('throw', 'false')) { foreach ($n in 1..40) { @{ n = $n; mode = $m } } }
    ) {
        $script:tc.FailAt = $n
        $script:tc.FailMode = $mode
        try {
            if (Open-LokiSession) {
                Write-LokiSessionFrame -State (New-LokiSessionState -Tier 'ascii')
                Close-LokiSession
            }
        }
        catch {
            # The injected fault. What follows is what the dispatcher's catch and finally do with it.
            $null = $_
        }
        Restore-LokiConsole
        $script:tc.IsRestored() | Should -BeTrue -Because "fault at call $n ($mode): $($script:tc.Describe())"
    }

    It 'claims Ctrl+C BEFORE it enters the alternate screen' {
        # So a Ctrl+C while the screen is opening arrives as a key, not as a stop that could interrupt the opening
        # halfway. The review found the opposite order: screen first, keyboard second.
        [void](Open-LokiSession)
        $log = @($script:tc.Log)
        $claim = [array]::IndexOf($log, 'ctrl-c=True')
        $enter = -1
        for ($i = 0; $i -lt $log.Count; $i++) { if ($log[$i].Contains('[?1049h')) { $enter = $i; break } }
        $claim | Should -BeGreaterOrEqual 0
        $enter | Should -BeGreaterOrEqual 0
        $claim | Should -BeLessThan $enter
    }

    It 'leaves the alternate screen BEFORE it gives Ctrl+C back' {
        [void](Open-LokiSession)
        $script:tc.Log.Clear()
        Close-LokiSession
        $log = @($script:tc.Log)
        $leave = -1
        for ($i = 0; $i -lt $log.Count; $i++) { if ($log[$i].Contains('[?1049l')) { $leave = $i; break } }
        $release = [array]::IndexOf($log, 'ctrl-c=False')
        $leave | Should -BeGreaterOrEqual 0
        $release | Should -BeGreaterOrEqual 0
        $leave | Should -BeLessThan $release
    }

    It 'gives Ctrl+C back the way it FOUND it, even when it was already claimed' {
        # Close used to put back whatever Open read -- but nothing tested that Open read it at all. "Assume it was off"
        # survived a mutation with every test green.
        $script:tc = New-LokiTestConsole -Width 60 -Height 12 -CtrlC $true
        [void](Open-LokiSession)
        Close-LokiSession
        Restore-LokiConsole
        $script:tc.CtrlC | Should -BeTrue
    }

    It 'retries leaving the screen when the first attempt could not be written' {
        [void](Open-LokiSession)
        # Fail exactly the next console call, which is the leave sequence inside Close-LokiSession.
        $script:tc.FailAt = $script:tc.Calls + 1
        $script:tc.FailMode = 'false'
        Close-LokiSession
        $script:tc.AltOn | Should -BeTrue -Because 'the injected failure really did stop the first leave'
        Restore-LokiConsole
        $script:tc.AltOn | Should -BeFalse
        $script:tc.CursorVisible | Should -BeTrue
    }
}

Describe 'a session whose screen is lost ends, instead of carrying on unseen' {

    BeforeEach {
        $script:tc = New-LokiTestConsole -Width 60 -Height 12
        Mock -CommandName Get-LokiConsoleFact -MockWith { return $script:tc.Fact() }
        Mock -CommandName Test-LokiVtProcessing -MockWith { return $true }
        Mock -CommandName Write-LokiScreenRaw -MockWith { return $script:tc.Write($Text) }
        Mock -CommandName Get-LokiScreenRow -MockWith { return $script:tc.ReadRow($Row, $Width) }
        Mock -CommandName Request-LokiCtrlCInput -MockWith { return $script:tc.SetCtrlC($Enabled) }
        Mock -CommandName Get-LokiCtrlCInput -MockWith { return $script:tc.GetCtrlC() }
        Mock -CommandName Get-LokiKeyreadFact -MockWith { return @{ HostName = 'ConsoleHost'; InputRedirected = $false } }
        Initialize-LokiScreen; Initialize-LokiKeyread; Initialize-LokiSession
    }
    AfterEach { Initialize-LokiScreen; Initialize-LokiKeyread; Initialize-LokiSession }

    It 'returns closed, closes the session and gives Ctrl+C back when a frame cannot be written' {
        # The review: a failed frame write closed the SCREEN, but the session stayed open with the keyboard claimed,
        # so the next key ran a command with nothing drawn.
        [void](Open-LokiSession)
        Mock -CommandName Read-LokiKey -MockWith { throw 'must not be reached: the session should have ended' }
        $state = New-LokiSessionState -Tier 'ascii'
        Add-LokiSessionEntry -State $state -Text 'something to paint'
        $script:tc.FailAt = $script:tc.Calls + 2      # the frame write itself: hide-caret first, then the frame
        $script:tc.FailMode = 'false'
        $round = Invoke-LokiSessionRound -State $state
        $round.Action | Should -Be 'closed'
        Test-LokiSessionOpen | Should -BeFalse
        $script:tc.CtrlC | Should -BeFalse
        $script:tc.AltOn | Should -BeFalse
    }
}

Describe 'a session whose keyboard can no longer be read ends, and says why' {

    It 'returns closed with the keyboard''s reason and closes the session' {
        Mock -CommandName Test-LokiScreenOpen -MockWith { return $true }
        Mock -CommandName Write-LokiSessionFrame -MockWith { }
        Mock -CommandName Read-LokiKey -MockWith { return $null }
        Mock -CommandName Get-LokiKeyreadRefusal -MockWith { return 'read-failed' }
        Mock -CommandName Open-LokiScreen -MockWith { return $true }
        Mock -CommandName Open-LokiKeyread -MockWith { return $true }
        Mock -CommandName Close-LokiScreen -MockWith { }
        Mock -CommandName Close-LokiKeyread -MockWith { }
        Initialize-LokiSession
        [void](Open-LokiSession)
        Test-LokiSessionOpen | Should -BeTrue
        $round = Invoke-LokiSessionRound -State (New-LokiSessionState -Tier 'ascii')
        $round.Action | Should -Be 'closed'
        $round.Text | Should -Be 'keyread:read-failed'
        # The state that matters, not a count of calls: Open-LokiSession also calls Close-LokiSession at its start, so
        # counting would have to know that, and the first version of this test did not.
        Test-LokiSessionOpen | Should -BeFalse
    }
}

Describe 'the VT probe gives the operator''s row back from a snapshot' {
    # It used to put the row back by printing its TEXT again, which lost the colours and, on a CP850 console, replaced
    # every character the code page cannot encode -- measured by an independent review on a real console.

    BeforeEach {
        $script:restored = New-Object System.Collections.Generic.List[object]
        $script:snap = @{ Row = 3; Col = 7; Width = 40; Cells = 'the cells as they were' }
        Mock -CommandName Get-LokiBufferSnapshot -MockWith { return $script:snap }
        Mock -CommandName Restore-LokiBufferSnapshot -MockWith { [void]$script:restored.Add($Snapshot); return $true }
        Mock -CommandName Move-LokiCursor -MockWith { return $true }
        Mock -CommandName Write-LokiScreenRaw -MockWith { return $true }
    }

    It 'restores exactly the snapshot it took' {
        Mock -CommandName Get-LokiScreenRow -MockWith { return ('A' + (' ' * 39)) }
        Test-LokiVtProcessing | Should -BeTrue
        $script:restored.Count | Should -Be 1
        $script:restored[0].Cells | Should -Be 'the cells as they were'
        $script:restored[0].Col | Should -Be 7
    }

    It 'restores it even when the probe write throws halfway, and reports VT as off' {
        Mock -CommandName Write-LokiScreenRaw -MockWith { throw 'console went away mid-probe' }
        Test-LokiVtProcessing | Should -BeFalse
        $script:restored.Count | Should -Be 1
    }

    It 'does not touch the row at all when it cannot take a snapshot' {
        Mock -CommandName Get-LokiBufferSnapshot -MockWith { return $null }
        Test-LokiVtProcessing | Should -BeFalse
        Should -Invoke Write-LokiScreenRaw -Times 0 -Exactly
        Should -Invoke Restore-LokiBufferSnapshot -Times 0 -Exactly
    }

    It 'reads a plain A as VT on, and the raw sequence or a lowercase a as VT off' {
        Mock -CommandName Get-LokiScreenRow -MockWith { return ('A' + (' ' * 39)) }
        Test-LokiVtProcessing | Should -BeTrue
        Mock -CommandName Get-LokiScreenRow -MockWith { return ([string][char]27 + '[1mA' + (' ' * 35)) }
        Test-LokiVtProcessing | Should -BeFalse
        # PowerShell's -eq calls [char]'a' and [char]'A' equal; the probe compares code points, so this must be off.
        Mock -CommandName Get-LokiScreenRow -MockWith { return ('a' + (' ' * 39)) }
        Test-LokiVtProcessing | Should -BeFalse
    }
}

Describe 'Restore-LokiConsole' {

    BeforeEach {
        Mock -CommandName Close-LokiSessionCapture -MockWith { }
        Mock -CommandName Close-LokiScreen -MockWith { }
        Mock -CommandName Close-LokiRegion -MockWith { }
        Mock -CommandName Close-LokiSession -MockWith { }
        Mock -CommandName Close-LokiKeyread -MockWith { }
        Initialize-LokiRestore
    }

    It 'clears the capture sink, so anything printed afterwards reaches the real console' {
        Register-LokiWriteSink -Sink { param($w) $null = $w }
        Restore-LokiConsole
        Test-LokiWriteSinkActive | Should -BeFalse
    }

    It 'runs every step even when one of them throws, and says which one failed' {
        Mock -CommandName Close-LokiScreen -MockWith { throw 'console handle is gone' }
        Restore-LokiConsole
        Should -Invoke Close-LokiRegion -Times 1 -Exactly
        Should -Invoke Close-LokiSession -Times 1 -Exactly
        Should -Invoke Close-LokiKeyread -Times 1 -Exactly
        $failures = @(Get-LokiRestoreFailure)
        $failures.Count | Should -Be 1
        $failures[0] | Should -Match 'screen'
    }

    It 'gives the keyboard back LAST, after everything that still writes to the console' {
        $script:order = New-Object System.Collections.Generic.List[string]
        Mock -CommandName Close-LokiScreen -MockWith { [void]$script:order.Add('screen') }
        Mock -CommandName Close-LokiRegion -MockWith { [void]$script:order.Add('region') }
        Mock -CommandName Close-LokiSession -MockWith { [void]$script:order.Add('session') }
        Mock -CommandName Close-LokiKeyread -MockWith { [void]$script:order.Add('keyboard') }
        Restore-LokiConsole
        $script:order[$script:order.Count - 1] | Should -Be 'keyboard'
        $script:order.IndexOf('screen') | Should -BeLessThan $script:order.IndexOf('keyboard')
    }

    It 'is safe to run twice, which is what the dispatcher does on the error path' {
        Restore-LokiConsole
        Restore-LokiConsole
        @(Get-LokiRestoreFailure).Count | Should -Be 0
    }
}

Describe 'the dispatcher gives the console back on every path' {
    # Static, because the dispatcher is a script that ends in `exit` and runs as a child process in which no screen can
    # open. What it pins is exactly what an independent review removed with every test still green: the teardown.

    BeforeAll {
        $tokens = $null; $errors = $null
        $script:dispatcherAst = [System.Management.Automation.Language.Parser]::ParseFile(
            (Resolve-Path "$PSScriptRoot\..\src\loki.ps1").Path, [ref]$tokens, [ref]$errors)
        $script:mainTry = @($script:dispatcherAst.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $false)) |
            Where-Object { $_.Finally -and $_.CatchClauses.Count -gt 0 } | Select-Object -First 1

        function global:Get-LokiTestCommandOffset {
            param($Block, [string]$Name)
            $hit = @($Block.FindAll({
                        param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Name
                    }, $true)) | Select-Object -First 1
            if ($null -eq $hit) { return -1 }
            return $hit.Extent.StartOffset
        }
    }

    It 'restores the console in the finally block' {
        $script:mainTry | Should -Not -BeNullOrEmpty
        Get-LokiTestCommandOffset -Block $script:mainTry.Finally -Name 'Restore-LokiConsole' | Should -BeGreaterOrEqual 0
    }

    It 'restores the console in the catch block BEFORE it prints the error' {
        # catch runs before finally. Printing first put the error into the alternate screen, which the finally then
        # discarded: exit code 1 and no message at all.
        $catchBody = $script:mainTry.CatchClauses[0].Body
        $restore = Get-LokiTestCommandOffset -Block $catchBody -Name 'Restore-LokiConsole'
        $err = Get-LokiTestCommandOffset -Block $catchBody -Name 'Write-LokiErr'
        $restore | Should -BeGreaterOrEqual 0
        $err | Should -BeGreaterOrEqual 0
        $restore | Should -BeLessThan $err
    }
}

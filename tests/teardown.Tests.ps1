# tests/teardown.Tests.ps1 -- giving the operator's console back (issue #133 review, invariant I1).
#
# I1, in one sentence: after Loki ends by any path short of a hard kill -- including an exception or a stop at ANY
# instruction -- the operator's console is as Loki found it: main screen visible and untouched, cursor visible and where
# it was, Ctrl+C handled the way it was before Loki started. And one rule beneath it, measured on a real conhost: a bare
# ESC[?1049l moves the cursor to the corner of the window, and a second one jumps it back to where it was at enter -- so
# a leave goes out only
# while one is owed, and the one leave that may not have been owed (after an enter that was attempted but never
# confirmed) is followed by putting the cursor back.
#
# The test that matters most is the fault walk below. It does not pick the failure points a human would think of. It
# runs one full lifecycle against a fake console that interprets what Loki writes (tests/helpers/LokiTestConsole.ps1),
# COUNTS the console calls in it, and then fails the lifecycle at each of those calls in turn, in three ways: before the
# call took effect, instead of it, and right after it. The lifecycle is the real one: open, a frame, a key read during
# which the window changes size, a captured command, the hand-over to an interactive command and back, close.
#
# What the walk cannot see is listed in the fake's header. Nothing green here covers those.
Set-StrictMode -Version Latest

BeforeAll {
    Get-ChildItem "$PSScriptRoot\..\src\lib" -Filter *.ps1 | ForEach-Object { . $_.FullName }
    . "$PSScriptRoot\helpers\LokiTestConsole.ps1"
    Initialize-LokiUi -NoColor
    Initialize-LokiI18n -AppRoot (Resolve-Path "$PSScriptRoot\..\src").Path -Locale 'en' | Out-Null

    # One whole lifecycle. Returns where it stopped, so the walker can check the console right after an open that
    # refused: the caller carries on in the one-shot menu at that point, on whatever the console now looks like.
    function global:Invoke-LokiTestLifecycle {
        param($Console)
        $state = New-LokiSessionState -Tier 'ascii'
        if (-not (Open-LokiSession)) { return 'refused' }
        Write-LokiSessionFrame -State $state

        # A key arrives -- and the window has been made smaller in the meantime, which the round only learns after it.
        $Console.ReportHeight = $Console.Height - 2
        $round = Invoke-LokiSessionRound -State $state
        if ([string]$round.Action -eq 'closed') { return 'closed' }

        # A command that runs inside the session, its output captured.
        Open-LokiSessionCapture -State $state
        try { Write-LokiLine 'a captured line' }
        finally { Close-LokiSessionCapture }

        # An interactive command: the console is handed over, then taken back.
        Close-LokiSession
        if (-not (Open-LokiSession)) { return 'refused' }
        Write-LokiSessionFrame -State $state
        Close-LokiSession
        return 'done'
    }

    # Mocks cannot be installed from a helper, so each Describe that drives the fake console calls these in BeforeEach.
    function global:Get-LokiTestConsoleMock {
        return @{
            Fact     = { return $script:tc.Fact() }
            # Every call honours 'false' with what its real primitive returns on failure, or the walk's 'false' mode
            # changes nothing at that call -- an independent review found 11 of 60 such calls in an earlier version.
            Vt       = { if (-not $script:tc.Tick('vt-probe')) { return $false }; $script:tc.AfterEffect(); return $true }
            Raw      = { return $script:tc.Write($Text) }
            Row      = { return $script:tc.ReadRow($Row, $Width) }
            SetCtrlC = { return $script:tc.SetCtrlC($Enabled) }
            GetCtrlC = { return $script:tc.GetCtrlC() }
            KeyFact  = { if (-not $script:tc.Tick('keyread-fact')) { return $null }; $script:tc.AfterEffect(); return @{ HostName = 'ConsoleHost'; InputRedirected = $false } }
            Cursor   = { return $script:tc.MoveCursor($Row, $Col) }
            Key      = { if (-not $script:tc.Tick('read-key')) { return $null }; $script:tc.AfterEffect(); return @{ Key = 'Q'; KeyChar = 113; Modifiers = '0' } }
        }
    }
}

Describe 'the fake console itself -- a wrong double makes every test below meaningless' {
    # The double's first version read ESC[?1049h as a cursor move: PowerShell's -eq compares [char]'h' and [char]'H' as
    # EQUAL. No session ever opened inside it, and the fault walk passed every point against code that really did leave
    # the operator stranded -- it was walking over nothing.

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

    It 'puts the cursor back where it was on leave, and at 0,0 when nothing was saved -- as a real conhost does' {
        $esc = [string][char]27
        $tc = New-LokiTestConsole -Width 20 -Height 12
        [void]$tc.Write($esc + '[?1049h' + $esc + '[2;2H' + $esc + '[?1049l')
        "$($tc.Row),$($tc.Col)" | Should -Be '7,8'
        $tc = New-LokiTestConsole -Width 20 -Height 12
        [void]$tc.Write($esc + '[?1049l')
        "$($tc.Row),$($tc.Col)" | Should -Be '0,0'
        $tc.IsRestored() | Should -BeFalse -Because 'a moved cursor is damage, even with everything else in place'
    }

    It 'notices text written into the MAIN buffer' {
        $tc = New-LokiTestConsole -Width 20 -Height 12
        [void]$tc.Write('stray')
        $tc.IsRestored() | Should -BeFalse
    }

    It 'fails the N-th console call before its effect, instead of it, or right after it' {
        $tc = New-LokiTestConsole -Width 20 -Height 12
        $tc.FailAt = 2
        $tc.Write('a') | Should -BeTrue
        { $tc.Write('b') } | Should -Throw '*injected fault at console call 2*'
        $tc.Main[7].Substring(8, 2) | Should -BeExactly 'am' -Because "'throw' fails BEFORE the effect"

        $tc = New-LokiTestConsole -Width 20 -Height 12
        $tc.FailAt = 1; $tc.FailMode = 'false'
        $tc.Write('a') | Should -BeFalse
        $tc.Main[7].Substring(8, 1) | Should -BeExactly 'm'

        $tc = New-LokiTestConsole -Width 20 -Height 12
        $tc.FailAt = 1; $tc.FailMode = 'after'
        { $tc.Write('a') } | Should -Throw '*AFTER the effect*'
        $tc.Main[7].Substring(8, 1) | Should -BeExactly 'a' -Because "'after' lets the effect happen first"
    }
}

Describe 'I1 -- the console comes back after a failure at any console call of the whole lifecycle' {

    BeforeEach {
        $m = Get-LokiTestConsoleMock
        Mock -CommandName Get-LokiConsoleFact -MockWith $m.Fact
        Mock -CommandName Test-LokiVtProcessing -MockWith $m.Vt
        Mock -CommandName Write-LokiScreenRaw -MockWith $m.Raw
        Mock -CommandName Get-LokiScreenRow -MockWith $m.Row
        Mock -CommandName Move-LokiCursor -MockWith $m.Cursor
        Mock -CommandName Request-LokiCtrlCInput -MockWith $m.SetCtrlC
        Mock -CommandName Get-LokiCtrlCInput -MockWith $m.GetCtrlC
        Mock -CommandName Get-LokiKeyreadFact -MockWith $m.KeyFact
        Mock -CommandName Read-LokiRawKey -MockWith $m.Key
        Mock -CommandName Test-LokiKeyWaiting -MockWith { return $false }
    }

    AfterEach {
        Initialize-LokiScreen; Initialize-LokiKeyread; Initialize-LokiSession; Initialize-LokiRestore
    }

    It 'a fault-free lifecycle completes, restores the console, and is long enough to be worth walking' {
        $script:tc = New-LokiTestConsole -Width 60 -Height 14
        Initialize-LokiScreen; Initialize-LokiKeyread; Initialize-LokiSession; Initialize-LokiRestore
        Invoke-LokiTestLifecycle -Console $script:tc | Should -Be 'done' -Because 'the walk must actually reach every stage'
        Restore-LokiConsole
        $script:tc.IsRestored() | Should -BeTrue -Because $script:tc.Describe()
        $script:tc.Calls | Should -BeGreaterThan 30
        $script:tc.Unknown.Count | Should -Be 0 -Because "every sequence Loki sends must be one the double understands: $($script:tc.Unknown -join ', ')"
        @($script:tc.Log | Where-Object { $_.Contains('[?1049l') }).Count | Should -Be 2 -Because 'one leave per enter, and the lifecycle enters twice'
        $script:tc.SpuriousLeaves | Should -Be 0
        @($script:tc.Log | Where-Object { $_ -like 'cursor=*' }).Count | Should -Be 0 -Because 'after a confirmed enter the terminal puts the cursor back itself'
    }

    It 'restores the console when the lifecycle fails at EVERY console call, by <mode>' -ForEach @(
        @{ mode = 'throw' }, @{ mode = 'false' }, @{ mode = 'after' }
    ) {
        # Count the calls of a fault-free run first, then walk exactly those -- no point past the end, none skipped.
        $script:tc = New-LokiTestConsole -Width 60 -Height 14
        Initialize-LokiScreen; Initialize-LokiKeyread; Initialize-LokiSession; Initialize-LokiRestore
        [void](Invoke-LokiTestLifecycle -Console $script:tc)
        Restore-LokiConsole
        $total = $script:tc.Calls
        $total | Should -BeGreaterThan 30

        $broken = New-Object System.Collections.Generic.List[string]
        for ($n = 1; $n -le $total; $n++) {
            $script:tc = New-LokiTestConsole -Width 60 -Height 14
            Initialize-LokiScreen; Initialize-LokiKeyread; Initialize-LokiSession; Initialize-LokiRestore
            $script:tc.FailAt = $n
            $script:tc.FailMode = $mode
            $where = 'fault'
            try { $where = Invoke-LokiTestLifecycle -Console $script:tc }
            catch { $where = 'fault' }

            # An open that refused leaves the caller in the one-shot menu, printing onto this console NOW -- not after
            # some later restore. It must already be the operator's console here.
            if ($where -eq 'refused' -and -not $script:tc.IsRestored()) {
                $broken.Add("call $n ($mode) right after a refused open: $($script:tc.Describe())")
            }
            Restore-LokiConsole
            # IsRestored includes the cursor, so a leave that was not owed and left it moved is caught here -- that is the
            # damage. Counting leaves instead reported attempts that never took effect.
            if (-not $script:tc.IsRestored()) { $broken.Add("call $n ($mode) after restore: $($script:tc.Describe())") }
            if (@(Get-LokiRestoreFailure).Count -gt 0) {
                $broken.Add("call $n ($mode): restored, yet reported as failed: $(@(Get-LokiRestoreFailure) -join ', ')")
            }
        }
        $broken.Count | Should -Be 0 -Because ($broken -join ' | ')
    }
}

Describe 'the rules the walk depends on, pinned one by one' {

    BeforeEach {
        $script:tc = New-LokiTestConsole -Width 60 -Height 14
        $m = Get-LokiTestConsoleMock
        Mock -CommandName Get-LokiConsoleFact -MockWith $m.Fact
        Mock -CommandName Test-LokiVtProcessing -MockWith { return $true }
        Mock -CommandName Write-LokiScreenRaw -MockWith $m.Raw
        Mock -CommandName Get-LokiScreenRow -MockWith $m.Row
        Mock -CommandName Move-LokiCursor -MockWith $m.Cursor
        Mock -CommandName Request-LokiCtrlCInput -MockWith $m.SetCtrlC
        Mock -CommandName Get-LokiCtrlCInput -MockWith $m.GetCtrlC
        Mock -CommandName Get-LokiKeyreadFact -MockWith { return @{ HostName = 'ConsoleHost'; InputRedirected = $false } }
        Initialize-LokiScreen; Initialize-LokiKeyread; Initialize-LokiSession; Initialize-LokiRestore
    }
    AfterEach { Initialize-LokiScreen; Initialize-LokiKeyread; Initialize-LokiSession; Initialize-LokiRestore }

    It 'claims Ctrl+C BEFORE it enters the alternate screen' {
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

    It 'never touches Ctrl+C when the screen would refuse anyway' {
        # --plain, redirected output, no ConsoleHost, a tiny window: the screen's cheap checks say no before anything is
        # written. The keyboard must not be claimed and released for nothing -- a release that fails would leave the
        # operator's Ctrl+C claimed on a run that never showed a session at all.
        [void](Open-LokiSession -Plain)
        @($script:tc.Log | Where-Object { $_ -like 'ctrl-c=*' }).Count | Should -Be 0
        Get-LokiSessionRefusal | Should -Be 'screen:plain'
    }

    It 'gives Ctrl+C back the way it FOUND it, even when it was already claimed' {
        $script:tc = New-LokiTestConsole -Width 60 -Height 14 -CtrlC $true
        Initialize-LokiKeyread
        [void](Open-LokiSession)
        Close-LokiSession
        Restore-LokiConsole
        $script:tc.CtrlC | Should -BeTrue
    }

    It 'leaves the keyboard closed when claiming Ctrl+C reports failure' {
        # The state goes in before the claim (so a stop after the claim still gives it back) and must come out again
        # when the claim says it did not happen -- otherwise the keyboard counts as open with nothing claimed.
        Mock -CommandName Request-LokiCtrlCInput -MockWith { if ($Enabled) { [void]$script:tc.Tick('ctrl-c=True'); return $false }; return $script:tc.SetCtrlC($Enabled) }
        Open-LokiSession | Should -BeFalse
        Get-LokiSessionRefusal | Should -Be 'keyread:no-ctrl-c'
        Test-LokiKeyreadOpen | Should -BeFalse
        Restore-LokiConsole
        @(Get-LokiRestoreFailure).Count | Should -Be 0
        $script:tc.IsRestored() | Should -BeTrue -Because $script:tc.Describe()
    }

    It 'gives back what it found at the FIRST open, even if a child changed it in between' {
        # An interactive command (chat, agent) gets the console handed over. If it leaves Ctrl+C claimed, a re-open that
        # read "what it found" again would make Loki hand THAT back at the end -- not what the operator had.
        [void](Open-LokiSession)
        Close-LokiSession
        $script:tc.CtrlC = $true          # the child left it claimed
        [void](Open-LokiSession)
        Close-LokiSession
        $script:tc.CtrlC | Should -BeFalse
    }

    It 'sends no leave at all when the enter could not be written' {
        # Measured on a real conhost: a leave without an enter moves the operator's cursor to the corner of the window. The enter write
        # reporting failure means it never reached the terminal, so there is nothing to leave.
        Mock -CommandName Write-LokiScreenRaw -MockWith { if ($Text.Contains('[?1049h')) { [void]$script:tc.Tick('write:' + $Text); return $false }; return $script:tc.Write($Text) }
        Open-LokiSession | Should -BeFalse
        Restore-LokiConsole
        @($script:tc.Log | Where-Object { $_.Contains('[?1049l') }).Count | Should -Be 0
        $script:tc.IsRestored() | Should -BeTrue -Because $script:tc.Describe()
    }

    It 'puts the cursor back after a leave that followed an enter which was attempted but never confirmed' {
        # A stop between "a leave is owed" and the enter reaching the console: nothing can tell whether the enter took
        # effect, so the leave goes out -- and if it was a bare one, a real conhost has just moved the cursor to the
        # corner of the window. Measured there too: putting it back by position restores it, scroll position unchanged.
        Mock -CommandName Write-LokiScreenRaw -MockWith {
            if ($Text.Contains('[?1049h')) { [void]$script:tc.Tick('write:' + $Text); throw 'stopped before the enter reached the console' }
            return $script:tc.Write($Text)
        }
        { Open-LokiSession } | Should -Throw '*stopped before*'
        Restore-LokiConsole
        $script:tc.SpuriousLeaves | Should -Be 1 -Because 'the case under test: a leave that turned out not to be owed'
        $script:tc.IsRestored() | Should -BeTrue -Because $script:tc.Describe()
    }

    It 'leaves the cursor to the terminal after a CONFIRMED enter' {
        # A window resized during the session reflows the main buffer; the terminal restores the cursor into the
        # reflowed buffer, and a position recorded before the enter would put it in the wrong place.
        [void](Open-LokiSession)
        Close-LokiSession
        @($script:tc.Log | Where-Object { $_ -like 'cursor=*' }).Count | Should -Be 0
        $script:tc.IsRestored() | Should -BeTrue -Because $script:tc.Describe()
    }

    It 'leaves the screen at once when the first paint fails, without waiting for a later restore' {
        Mock -CommandName Write-LokiScreenRaw -MockWith {
            if ($Text.Contains('[1;1H') -and -not $Text.Contains('[?1049h')) { return $false }
            return $script:tc.Write($Text)
        }
        Open-LokiSession | Should -BeFalse
        $script:tc.AltOn | Should -BeFalse
        $script:tc.IsRestored() | Should -BeTrue -Because $script:tc.Describe()
    }

    It 'sends exactly one leave when the console is restored twice' {
        # The dispatcher restores from its catch and again from its finally. A second leave jumps the cursor back to where
        # it was at enter, on top of whatever was printed in between -- measured on a real conhost.
        [void](Open-LokiSession)
        Restore-LokiConsole
        Restore-LokiConsole
        @($script:tc.Log | Where-Object { $_.Contains('[?1049l') }).Count | Should -Be 1
        $script:tc.IsRestored() | Should -BeTrue
    }

    It 'retries a leave that could not be written, and still sends only one that went through' {
        [void](Open-LokiSession)
        $script:tc.FailAt = $script:tc.Calls + 1
        $script:tc.FailMode = 'false'
        Close-LokiSession
        $script:tc.AltOn | Should -BeTrue -Because 'the injected failure really did stop the first leave'
        Restore-LokiConsole
        $script:tc.AltOn | Should -BeFalse
        $script:tc.IsRestored() | Should -BeTrue -Because $script:tc.Describe()
    }

    It 'resets the attributes in the leave sequence' {
        # The fake ignores SGR, so the walk cannot see a missing reset. This pins it directly.
        [void](Open-LokiSession)
        $script:tc.Log.Clear()
        Close-LokiScreen
        $leave = @($script:tc.Log | Where-Object { $_.Contains('[?1049l') })[0]
        $leave.Contains([string][char]27 + '[m') | Should -BeTrue
    }

    It 'closes the screen when hiding the caret fails, and when showing it fails' {
        [void](Open-LokiSession)
        Mock -CommandName Write-LokiScreenRaw -MockWith { if ($Text.Contains('[?25l')) { return $false }; return $script:tc.Write($Text) }
        Hide-LokiScreenCaret | Should -BeFalse
        Test-LokiScreenOpen | Should -BeFalse

        Initialize-LokiScreen; Initialize-LokiKeyread; Initialize-LokiSession
        $script:tc = New-LokiTestConsole -Width 60 -Height 14
        Mock -CommandName Write-LokiScreenRaw -MockWith { return $script:tc.Write($Text) }
        [void](Open-LokiSession)
        Mock -CommandName Write-LokiScreenRaw -MockWith { if ($Text.Contains('[?25h')) { return $false }; return $script:tc.Write($Text) }
        Show-LokiScreenCaret -Row 1 -Col 1 | Should -BeFalse
        Test-LokiScreenOpen | Should -BeFalse
    }
}

Describe 'a session whose screen or keyboard is lost ends, instead of carrying on unseen' {

    BeforeEach {
        $script:tc = New-LokiTestConsole -Width 60 -Height 14
        $m = Get-LokiTestConsoleMock
        Mock -CommandName Get-LokiConsoleFact -MockWith $m.Fact
        Mock -CommandName Test-LokiVtProcessing -MockWith { return $true }
        Mock -CommandName Write-LokiScreenRaw -MockWith $m.Raw
        Mock -CommandName Get-LokiScreenRow -MockWith $m.Row
        Mock -CommandName Move-LokiCursor -MockWith $m.Cursor
        Mock -CommandName Request-LokiCtrlCInput -MockWith $m.SetCtrlC
        Mock -CommandName Get-LokiCtrlCInput -MockWith $m.GetCtrlC
        Mock -CommandName Get-LokiKeyreadFact -MockWith { return @{ HostName = 'ConsoleHost'; InputRedirected = $false } }
        Mock -CommandName Test-LokiKeyWaiting -MockWith { return $false }
        Initialize-LokiScreen; Initialize-LokiKeyread; Initialize-LokiSession; Initialize-LokiRestore
    }
    AfterEach { Initialize-LokiScreen; Initialize-LokiKeyread; Initialize-LokiSession; Initialize-LokiRestore }

    It 'returns closed, closes the session and gives Ctrl+C back when a frame cannot be written' {
        [void](Open-LokiSession)
        Mock -CommandName Read-LokiKey -MockWith { throw 'must not be reached: the session should have ended' }
        $state = New-LokiSessionState -Tier 'ascii'
        Add-LokiSessionEntry -State $state -Text 'something to paint'
        Mock -CommandName Write-LokiScreenRaw -MockWith { if ($Text.Contains('something to paint')) { return $false }; return $script:tc.Write($Text) }
        $round = Invoke-LokiSessionRound -State $state
        $round.Action | Should -Be 'closed'
        Test-LokiSessionOpen | Should -BeFalse
        $script:tc.CtrlC | Should -BeFalse
        $script:tc.AltOn | Should -BeFalse
    }

    It 'returns closed BEFORE acting on the key when the resize repaint after it fails' {
        # The review: the key was read, the window had changed, the repaint failed and closed the screen -- and the round
        # still returned the key's action, so the caller ran a command with nothing drawn and Ctrl+C claimed.
        [void](Open-LokiSession)
        $state = New-LokiSessionState -Tier 'ascii'
        Mock -CommandName Read-LokiKey -MockWith {
            return [pscustomobject]@{ Kind = 'enter'; Char = 13; Text = ''; Key = 'Enter'; Modifiers = '0'; ControlLetter = ''; Source = 'typing'; MoreWaiting = $false; GapMs = 200.0 }
        }
        $state.Buffer = 'collect'
        $state.Cursor = 7
        $script:tc.ReportHeight = 10
        Mock -CommandName Write-LokiScreenRaw -MockWith { if ($Text.Contains('[2J') -and -not $Text.Contains('[?1049h')) { return $false }; return $script:tc.Write($Text) }
        $round = Invoke-LokiSessionRound -State $state
        $round.Action | Should -Be 'closed'
        $state.Buffer | Should -Be 'collect' -Because 'the Enter must not have been applied'
        Test-LokiSessionOpen | Should -BeFalse
        $script:tc.CtrlC | Should -BeFalse
    }

    It 'returns closed with the keyboard''s OWN reason when a key cannot be read' {
        # Through the real reason path: the raw console read throws, Read-LokiRawKey records why. The previous version of
        # this test mocked the reason it then asserted, and a mutation that stopped recording it stayed green.
        [void](Open-LokiSession)
        Mock -CommandName Read-LokiConsoleKey -MockWith { throw 'The handle is invalid.' }
        $round = Invoke-LokiSessionRound -State (New-LokiSessionState -Tier 'ascii')
        $round.Action | Should -Be 'closed'
        $round.Text | Should -Be 'keyread:read-failed'
        Test-LokiSessionOpen | Should -BeFalse
    }
}

Describe 'the VT probe gives the operator''s row back from a snapshot' {
    # It used to put the row back by printing its TEXT again, which lost the colours and, on a CP850 console, replaced
    # every character the code page cannot encode -- measured on a real conhost: 11 of 120 cells changed, a check mark
    # came back as 'V'. With the snapshot, 0 of 120.

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
        Mock -CommandName Get-LokiScreenRow -MockWith { return ('a' + (' ' * 39)) }
        Test-LokiVtProcessing | Should -BeFalse -Because "PowerShell's -eq calls [char]'a' and [char]'A' equal; the probe compares code points"
    }
}

Describe 'Restore-LokiConsole reports what it could not give back' {

    BeforeEach {
        $script:tc = New-LokiTestConsole -Width 60 -Height 14
        $m = Get-LokiTestConsoleMock
        Mock -CommandName Get-LokiConsoleFact -MockWith $m.Fact
        Mock -CommandName Test-LokiVtProcessing -MockWith { return $true }
        Mock -CommandName Write-LokiScreenRaw -MockWith $m.Raw
        Mock -CommandName Get-LokiScreenRow -MockWith $m.Row
        Mock -CommandName Move-LokiCursor -MockWith $m.Cursor
        Mock -CommandName Request-LokiCtrlCInput -MockWith $m.SetCtrlC
        Mock -CommandName Get-LokiCtrlCInput -MockWith $m.GetCtrlC
        Mock -CommandName Get-LokiKeyreadFact -MockWith { return @{ HostName = 'ConsoleHost'; InputRedirected = $false } }
        Initialize-LokiScreen; Initialize-LokiKeyread; Initialize-LokiSession; Initialize-LokiRestore
    }
    AfterEach {
        Mock -CommandName Write-LokiScreenRaw -MockWith { return $true }
        Mock -CommandName Request-LokiCtrlCInput -MockWith { return $true }
        Initialize-LokiScreen; Initialize-LokiKeyread; Initialize-LokiSession; Initialize-LokiRestore
    }

    It 'reports a leave that could not be written -- which does not throw, and so used to go unreported' {
        # The review measured this on a real console: alternate screen still active, exit code 0, no warning. The Close
        # functions report failure by keeping their state, not by throwing, so Restore has to ASK the state.
        [void](Open-LokiSession)
        Mock -CommandName Write-LokiScreenRaw -MockWith { if ($Text.Contains('[?1049l')) { return $false }; return $script:tc.Write($Text) }
        Restore-LokiConsole
        $failures = @(Get-LokiRestoreFailure)
        ($failures -join ' ') | Should -Match 'screen'
    }

    It 'reports a step that threw once, not again as a part still not given back' {
        [void](Open-LokiSession)
        Mock -CommandName Write-LokiScreenRaw -MockWith { if ($Text.Contains('[?1049l')) { throw 'console handle is gone' }; return $script:tc.Write($Text) }
        Restore-LokiConsole
        @(Get-LokiRestoreFailure | Where-Object { $_ -like 'screen*' }).Count | Should -Be 1
    }

    It 'reports Ctrl+C that could not be handed back' {
        [void](Open-LokiSession)
        Mock -CommandName Request-LokiCtrlCInput -MockWith { if (-not $Enabled) { return $false }; return $script:tc.SetCtrlC($Enabled) }
        Restore-LokiConsole
        (@(Get-LokiRestoreFailure) -join ' ') | Should -Match 'keyboard'
    }

    It 'reports only its OWN outcome, so a failure the next restore repaired is not reported' {
        # The dispatcher restores from its catch and again from its finally; what it reports is the second, final one.
        [void](Open-LokiSession)
        Mock -CommandName Write-LokiScreenRaw -MockWith { if ($Text.Contains('[?1049l')) { return $false }; return $script:tc.Write($Text) }
        Restore-LokiConsole
        @(Get-LokiRestoreFailure).Count | Should -BeGreaterThan 0
        Mock -CommandName Write-LokiScreenRaw -MockWith { return $script:tc.Write($Text) }
        Restore-LokiConsole
        @(Get-LokiRestoreFailure).Count | Should -Be 0
        $script:tc.IsRestored() | Should -BeTrue
    }

    It 'runs every step even when one of them throws, and says which one failed' {
        Mock -CommandName Close-LokiRegion -MockWith { throw 'console handle is gone' }
        # The session step closes the keyboard too; stubbed, so the one call counted is the keyboard step's own.
        Mock -CommandName Close-LokiSession -MockWith { }
        Mock -CommandName Close-LokiKeyread -MockWith { }
        Restore-LokiConsole
        Should -Invoke Close-LokiKeyread -Times 1 -Exactly
        (@(Get-LokiRestoreFailure) -join ' ') | Should -Match 'region'
    }

    It 'clears the capture sink, so anything printed afterwards reaches the real console' {
        Register-LokiWriteSink -Sink { param($w) $null = $w }
        Restore-LokiConsole
        Test-LokiWriteSinkActive | Should -BeFalse
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

    It 'closes a live region BEFORE it leaves the screen' {
        # A region opened inside the session blanks its rows at an anchor read from the console. Closed after the leave,
        # those are the operator's rows in the main buffer -- measured on a real conhost: four rows blanked, cursor moved.
        $script:order = New-Object System.Collections.Generic.List[string]
        Mock -CommandName Close-LokiScreen -MockWith { [void]$script:order.Add('screen') }
        Mock -CommandName Close-LokiRegion -MockWith { [void]$script:order.Add('region') }
        Mock -CommandName Close-LokiKeyread -MockWith { }
        Restore-LokiConsole
        $script:order[0] | Should -Be 'region'
        $script:order.IndexOf('region') | Should -BeLessThan $script:order.IndexOf('screen')

        # And the session's own close, which the guided mode's finally and the session step run, does the same.
        $script:order.Clear()
        Close-LokiSession
        $script:order -join ',' | Should -Be 'region,screen'
    }
}

Describe 'Get-LokiRestoreExitCode -- a run that could not give the console back does not end in success' {

    BeforeEach { Initialize-LokiRestore }

    It 'turns Ok into GeneralError when a step could not be restored' {
        Mock -CommandName Get-LokiRestoreFailure -MockWith { return @('screen: the alternate screen could not be left') }
        Get-LokiRestoreExitCode -ExitCode (Get-LokiExitCode 'Ok') | Should -Be (Get-LokiExitCode 'GeneralError')
    }

    It 'keeps a failing exit code as it is -- the command''s own reason comes first' {
        Mock -CommandName Get-LokiRestoreFailure -MockWith { return @('keyboard: Ctrl+C could not be handed back') }
        Get-LokiRestoreExitCode -ExitCode (Get-LokiExitCode 'OfflineEngineMissing') | Should -Be (Get-LokiExitCode 'OfflineEngineMissing')
    }

    It 'changes nothing when everything came back' {
        Mock -CommandName Get-LokiRestoreFailure -MockWith { return @() }
        Get-LokiRestoreExitCode -ExitCode (Get-LokiExitCode 'Ok') | Should -Be (Get-LokiExitCode 'Ok')
    }
}

Describe 'Write-LokiRestoreWarning -- what could not be given back is said, and saying it cannot break the exit' {

    BeforeEach {
        $script:warned = New-Object System.Collections.Generic.List[string]
        Mock -CommandName Write-LokiWarn -MockWith { [void]$script:warned.Add([string]$Text) }
    }

    It 'warns once per part, in the localized sentence' {
        Mock -CommandName Get-LokiRestoreFailure -MockWith { return @('screen', 'keyboard') }
        Write-LokiRestoreWarning
        $script:warned.Count | Should -Be 2
        $script:warned[0] | Should -Be (Get-LokiText 'restore.failed' -ArgumentList @('screen'))
        $script:warned[1] | Should -Be (Get-LokiText 'restore.failed' -ArgumentList @('keyboard'))
    }

    It 'says nothing when everything came back' {
        Mock -CommandName Get-LokiRestoreFailure -MockWith { return @() }
        Write-LokiRestoreWarning
        $script:warned.Count | Should -Be 0
    }

    It 'stops at the first warning that cannot be written, and does not throw' {
        Mock -CommandName Get-LokiRestoreFailure -MockWith { return @('screen', 'keyboard') }
        Mock -CommandName Write-LokiWarn -MockWith { throw 'the console is gone' }
        { Write-LokiRestoreWarning } | Should -Not -Throw
        Should -Invoke Write-LokiWarn -Times 1 -Exactly
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

    It 'restores the console in the finally block, then derives the exit code and warns from what came back' {
        $script:mainTry | Should -Not -BeNullOrEmpty
        $restore = Get-LokiTestCommandOffset -Block $script:mainTry.Finally -Name 'Restore-LokiConsole'
        $exitFrom = Get-LokiTestCommandOffset -Block $script:mainTry.Finally -Name 'Get-LokiRestoreExitCode'
        $warn = Get-LokiTestCommandOffset -Block $script:mainTry.Finally -Name 'Write-LokiRestoreWarning'
        $restore | Should -BeGreaterOrEqual 0
        $exitFrom | Should -BeGreaterThan $restore
        $warn | Should -BeGreaterThan $restore
    }

    It 'exits from INSIDE the finally, as its last statement' {
        # After a stop nothing after the finally runs, so an `exit` there was never reached and the process ended with 0
        # whatever the restore had found (measured on a real conhost).
        $last = $script:mainTry.Finally.Statements[$script:mainTry.Finally.Statements.Count - 1]
        $last | Should -BeOfType ([System.Management.Automation.Language.ExitStatementAst])
        $last.Pipeline.Extent.Text | Should -Be '$exit'
    }

    It 'restores the console in the catch block BEFORE it prints the error' {
        $catchBody = $script:mainTry.CatchClauses[0].Body
        $restore = Get-LokiTestCommandOffset -Block $catchBody -Name 'Restore-LokiConsole'
        $err = Get-LokiTestCommandOffset -Block $catchBody -Name 'Write-LokiErr'
        $restore | Should -BeGreaterOrEqual 0
        $err | Should -BeGreaterOrEqual 0
        $restore | Should -BeLessThan $err
    }
}

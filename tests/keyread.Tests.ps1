# tests/keyread.Tests.ps1 -- reading the keyboard one key at a time (issue #133, slice 2).
#
# CI runs Pester in a process whose stdin is not a console, which is exactly the condition under
# which this refuses to engage. So every decision lives in a pure function and is tested here; the
# four console primitives are mocked.
#
# The numbers below are not invented. They come from two probe runs on the maintainer's machine
# (Windows 11 26200, WinPS 5.1, ConsoleHost, CP850, German layout 1031) and every one of them is
# cited where it is used, so a later reader can tell a measurement from a guess.
#
# Three tests exist to fail on purpose:
#   'a classifier that reads Modifiers would swallow the @ key'
#   'the Ctrl+C claim is re-asserted on EVERY read, not once at open'
#   'the armed exit is disarmed by any other key'
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\keyread.ps1"

    # Measured key events, so the happy paths are not fantasies. Codes and modifier strings are
    # copied verbatim out of the probe reports.
    function global:Get-LokiTestMeasuredKey {
        return @{
            # AltGr on a German layout: a printable character that ALSO reports Control.
            At        = @{ Key = 'Q';        KeyChar = 64;  Modifiers = 'Alt, Control' }
            Bracket   = @{ Key = 'D8';       KeyChar = 91;  Modifiers = 'Alt, Control' }
            Backslash = @{ Key = 'Oem4';     KeyChar = 92;  Modifiers = 'Alt, Control' }
            Pipe      = @{ Key = 'Oem102';   KeyChar = 124; Modifiers = 'Alt, Control' }
            Umlaut    = @{ Key = 'Oem1';     KeyChar = 252; Modifiers = '0' }
            Sharp     = @{ Key = 'Oem4';     KeyChar = 223; Modifiers = '0' }
            Letter    = @{ Key = 'A';        KeyChar = 97;  Modifiers = '0' }
            UpArrow   = @{ Key = 'UpArrow';  KeyChar = 0;   Modifiers = '0' }
            Delete    = @{ Key = 'Delete';   KeyChar = 0;   Modifiers = '0' }
            Backspace = @{ Key = 'Backspace';KeyChar = 8;   Modifiers = '0' }
            Tab       = @{ Key = 'Tab';      KeyChar = 9;   Modifiers = '0' }
            Enter     = @{ Key = 'Enter';    KeyChar = 13;  Modifiers = '0' }
            Escape    = @{ Key = 'Escape';   KeyChar = 27;  Modifiers = '0' }
            CtrlA     = @{ Key = 'A';        KeyChar = 1;   Modifiers = 'Control' }
            CtrlC     = @{ Key = 'C';        KeyChar = 3;   Modifiers = 'Control' }
            CtrlU     = @{ Key = 'U';        KeyChar = 21;  Modifiers = 'Control' }
            CtrlW     = @{ Key = 'W';        KeyChar = 23;  Modifiers = 'Control' }
        }
    }
}

Describe 'Get-LokiKeyreadCapability' {
    It 'engages on a real console' {
        $c = Get-LokiKeyreadCapability -HostName 'ConsoleHost' -InputRedirected $false
        $c.Engage | Should -BeTrue
        $c.Reason | Should -Be 'ok'
    }
    It 'refuses a redirected stdin, which is how CI runs' {
        (Get-LokiKeyreadCapability -HostName 'ConsoleHost' -InputRedirected $true).Reason | Should -Be 'redirected'
    }
    It 'refuses a host that is not ConsoleHost' {
        (Get-LokiKeyreadCapability -HostName 'ServerRemoteHost' -InputRedirected $false).Reason | Should -Be 'host'
    }
    It 'asks nothing about stdout' {
        # The screen refuses a redirected stdout; this must not. A pipe on the way out does not stop
        # a key coming in, and refusing it would refuse a case nobody measured to be broken.
        (Get-Command Get-LokiKeyreadCapability).Parameters.Keys | Should -Not -Contain 'OutputRedirected'
    }
}

Describe 'Get-LokiKeyKind -- what a key means' {
    It 'calls every measured printable character text' {
        $m = Get-LokiTestMeasuredKey
        foreach ($name in @('At', 'Bracket', 'Backslash', 'Pipe', 'Umlaut', 'Sharp', 'Letter')) {
            Get-LokiKeyKind -KeyChar $m[$name].KeyChar | Should -Be 'text' -Because "$name is a character the operator typed"
        }
    }

    It 'a classifier that reads Modifiers would swallow the @ key' {
        # THE MUTATION. On a German layout AltGr sets Alt AND Control while producing an ordinary
        # printable character, so "Control is set means shortcut" eats @ [ \ and | -- every one of
        # which occurs in paths and commands. Measured 2026-08-27, layout 1031.
        function Test-LokiMutatedKind {
            param([int]$KeyChar, [string]$Modifiers)
            if ($Modifiers -match 'Control') { return 'control' }
            return 'text'
        }
        $m = Get-LokiTestMeasuredKey
        foreach ($name in @('At', 'Bracket', 'Backslash', 'Pipe')) {
            $k = $m[$name]
            Test-LokiMutatedKind -KeyChar $k.KeyChar -Modifiers $k.Modifiers |
                Should -Be 'control' -Because 'this is the wrong answer, and it is why Modifiers is never consulted'
            Get-LokiKeyKind -KeyChar $k.KeyChar | Should -Be 'text'
        }
    }

    It 'names the editing keys rather than calling them chords' {
        Get-LokiKeyKind -KeyChar 13 | Should -Be 'enter'
        Get-LokiKeyKind -KeyChar 8  | Should -Be 'backspace'
        Get-LokiKeyKind -KeyChar 27 | Should -Be 'escape'
        Get-LokiKeyKind -KeyChar 9  | Should -Be 'tab'
    }

    It 'calls a key with no character at all a key' {
        # Measured: UpArrow, DownArrow, Home, End and Delete all arrive with KeyChar 0. The caller
        # has nothing but the name to dispatch on.
        $m = Get-LokiTestMeasuredKey
        Get-LokiKeyKind -KeyChar $m.UpArrow.KeyChar | Should -Be 'key'
        Get-LokiKeyKind -KeyChar $m.Delete.KeyChar  | Should -Be 'key'
    }

    It 'calls the remaining control codes chords' {
        $m = Get-LokiTestMeasuredKey
        foreach ($name in @('CtrlA', 'CtrlC', 'CtrlU', 'CtrlW')) {
            Get-LokiKeyKind -KeyChar $m[$name].KeyChar | Should -Be 'control'
        }
        Get-LokiKeyKind -KeyChar 127 | Should -Be 'control' -Because 'DEL comes from Ctrl+Backspace'
    }
}

Describe 'Get-LokiControlLetter' {
    It 'turns the measured control codes into their letters' {
        Get-LokiControlLetter -KeyChar 1  | Should -Be 'a'
        Get-LokiControlLetter -KeyChar 3  | Should -Be 'c'
        Get-LokiControlLetter -KeyChar 21 | Should -Be 'u'
        Get-LokiControlLetter -KeyChar 23 | Should -Be 'w'
    }
    It 'refuses to call an editing key a chord' {
        # Backspace is not Ctrl+H to an operator, whatever the code says.
        Get-LokiControlLetter -KeyChar 8  | Should -Be ''
        Get-LokiControlLetter -KeyChar 9  | Should -Be ''
        Get-LokiControlLetter -KeyChar 13 | Should -Be ''
    }
    It 'has no letter for a printable character or for DEL' {
        Get-LokiControlLetter -KeyChar 64  | Should -Be ''
        Get-LokiControlLetter -KeyChar 127 | Should -Be ''
        Get-LokiControlLetter -KeyChar 0   | Should -Be ''
    }
}

Describe 'Get-LokiInputSource -- paste or typing' {
    It 'calls it paste whenever the next key was already waiting' {
        # Measured: true for 59 of the 61 keys in a pasted block. Even a slow gap cannot override
        # it -- the buffer already holding more is not something typing produces.
        Get-LokiInputSource -MoreWaiting $true -GapMs 500.0 | Should -Be 'paste'
    }

    It 'calls it typing when nothing was waiting, across every measured keystroke gap' {
        # min 74.33, median 171.91, max 470.66 -- the whole measured range of one human typing.
        foreach ($gap in @(74.33, 171.91, 470.66)) {
            Get-LokiInputSource -MoreWaiting $false -GapMs $gap | Should -Be 'typing'
        }
    }

    It 'still calls the last key of a burst paste, by the gap' {
        # The final key of a paste has nothing waiting behind it but arrived microseconds after its
        # predecessor. Measured paste gaps: min 0.08, median 0.12, max 3.05.
        foreach ($gap in @(0.08, 0.12, 3.05)) {
            Get-LokiInputSource -MoreWaiting $false -GapMs $gap | Should -Be 'paste'
        }
    }

    It 'leaves a margin on both sides of the measured evidence' {
        # 20 ms sits 6.5x above the slowest measured paste gap and 3.7x below the fastest measured
        # keystroke. If someone narrows this, these two are what go red.
        Get-LokiInputSource -MoreWaiting $false -GapMs 19.9 | Should -Be 'paste'
        Get-LokiInputSource -MoreWaiting $false -GapMs 20.0 | Should -Be 'typing'
    }

    It 'treats the very first key as typing, not as instant' {
        # Get-LokiKeyElapsed returns -1 for the first key of a session: no evidence, not zero.
        Get-LokiInputSource -MoreWaiting $false -GapMs -1.0 | Should -Be 'typing'
    }
}

Describe 'Get-LokiExitIntent -- the two-press exit' {
    It 'arms on the first Ctrl+C and does not exit' {
        $r = Get-LokiExitIntent -Kind 'control' -ControlLetter 'c' -Armed $false
        $r.Armed | Should -BeTrue
        $r.Exit  | Should -BeFalse
    }
    It 'exits on the second' {
        (Get-LokiExitIntent -Kind 'control' -ControlLetter 'c' -Armed $true).Exit | Should -BeTrue
    }
    It 'the armed exit is disarmed by any other key' {
        # The reference's stream cannot say whether it disarms on a keystroke or on a timer -- only
        # its output was recorded. This takes the safer reading, and this test is what holds it:
        # a Ctrl+C from ten minutes ago must not end the session on the next one.
        foreach ($kind in @('text', 'enter', 'escape', 'backspace', 'tab', 'key')) {
            (Get-LokiExitIntent -Kind $kind -ControlLetter '' -Armed $true).Armed |
                Should -BeFalse -Because "$kind must disarm"
        }
        (Get-LokiExitIntent -Kind 'control' -ControlLetter 'u' -Armed $true).Armed | Should -BeFalse
        (Get-LokiExitIntent -Kind 'control' -ControlLetter 'u' -Armed $true).Exit  | Should -BeFalse
    }
    It 'never exits on a key that is not Ctrl+C' {
        foreach ($letter in @('a', 'u', 'w', '')) {
            (Get-LokiExitIntent -Kind 'control' -ControlLetter $letter -Armed $true).Exit |
                Should -BeFalse -Because 'only c exits'
        }
    }
}

Describe 'the reader, against mocked console primitives' {
    BeforeEach {
        $script:queue = New-Object System.Collections.Generic.Queue[object]
        $script:waiting = New-Object System.Collections.Generic.Queue[object]
        $script:gaps = New-Object System.Collections.Generic.Queue[object]
        $script:ctrlC = New-Object System.Collections.Generic.List[object]

        Mock -CommandName Request-LokiCtrlCInput -MockWith { [void]$script:ctrlC.Add($Enabled); return $true }
        Mock -CommandName Read-LokiRawKey -MockWith {
            if ($script:queue.Count -eq 0) { return $null }
            return $script:queue.Dequeue()
        }
        Mock -CommandName Test-LokiKeyWaiting -MockWith {
            if ($script:waiting.Count -eq 0) { return $false }
            return [bool]$script:waiting.Dequeue()
        }
        Mock -CommandName Get-LokiKeyElapsed -MockWith {
            if ($script:gaps.Count -eq 0) { return 999.0 }
            return [double]$script:gaps.Dequeue()
        }
        Initialize-LokiKeyread
        $script:LokiKeyState = @{ CtrlCWasOwned = $false }   # open, without touching a console
    }

    AfterEach { $script:LokiKeyState = $null }

    It 'classifies a measured AltGr @ as text and hands the character over' {
        $m = Get-LokiTestMeasuredKey
        $script:queue.Enqueue($m.At)
        $k = Read-LokiKey
        $k.Kind | Should -Be 'text'
        $k.Text | Should -Be '@'
        $k.Modifiers | Should -Be 'Alt, Control' -Because 'the modifiers are reported, just never used to decide'
    }

    It 'hands over the control letter, not the code' {
        $m = Get-LokiTestMeasuredKey
        $script:queue.Enqueue($m.CtrlC)
        $k = Read-LokiKey
        $k.Kind | Should -Be 'control'
        $k.ControlLetter | Should -Be 'c'
        $k.Text | Should -Be '' -Because 'a chord is not text'
    }

    It 'the Ctrl+C claim is re-asserted on EVERY read, not once at open' {
        # THE OTHER MUTATION. Measured 2026-08-27: one Read-Host anywhere sets
        # TreatControlCAsInput back to False, and the next Ctrl+C then kills the process instead of
        # arriving here. Loki calls no Read-Host itself, but this file cannot police what a command
        # it dispatches does. If someone "optimises" this into Open-LokiKeyread, this goes red.
        $m = Get-LokiTestMeasuredKey
        $script:queue.Enqueue($m.Letter)
        $script:queue.Enqueue($m.Letter)
        $script:queue.Enqueue($m.Letter)
        [void](Read-LokiKey)
        [void](Read-LokiKey)
        [void](Read-LokiKey)
        Should -Invoke Request-LokiCtrlCInput -Times 3 -Exactly
        $script:ctrlC | Should -Not -Contain $false -Because 'every one of them claims, none releases'
    }

    It 'marks a pasted burst as paste and the typing around it as typing' {
        $m = Get-LokiTestMeasuredKey
        # three keys of a burst, then one typed a comfortable while later
        $script:queue.Enqueue($m.Letter); $script:waiting.Enqueue($true);  $script:gaps.Enqueue(0.12)
        $script:queue.Enqueue($m.Enter);  $script:waiting.Enqueue($true);  $script:gaps.Enqueue(0.09)
        $script:queue.Enqueue($m.Letter); $script:waiting.Enqueue($false); $script:gaps.Enqueue(3.05)
        $script:queue.Enqueue($m.Letter); $script:waiting.Enqueue($false); $script:gaps.Enqueue(171.91)

        (Read-LokiKey).Source | Should -Be 'paste'
        $enter = Read-LokiKey
        $enter.Kind   | Should -Be 'enter'
        $enter.Source | Should -Be 'paste' -Because 'an Enter inside a paste must not submit the line'
        (Read-LokiKey).Source | Should -Be 'paste' -Because 'the last key of a burst is caught by the gap'
        (Read-LokiKey).Source | Should -Be 'typing'
    }

    It 'asks whether more is waiting BEFORE it measures the gap' {
        # Order matters: anything slow between the read and the question makes a fast typist look
        # like a paste. Enforced by observing which mock ran first.
        $order = New-Object System.Collections.Generic.List[string]
        Mock -CommandName Test-LokiKeyWaiting -MockWith { [void]$order.Add('waiting'); return $false }
        Mock -CommandName Get-LokiKeyElapsed -MockWith { [void]$order.Add('gap'); return 100.0 }
        $script:queue.Enqueue((Get-LokiTestMeasuredKey).Letter)
        [void](Read-LokiKey)
        $order[0] | Should -Be 'waiting'
        $order[1] | Should -Be 'gap'
    }

    It 'returns nothing when the console gives nothing' {
        Mock -CommandName Read-LokiRawKey -MockWith { return $null }
        Read-LokiKey | Should -BeNullOrEmpty
    }

    It 'returns nothing, and claims nothing, when it is not open' {
        $script:LokiKeyState = $null
        Read-LokiKey | Should -BeNullOrEmpty
        Should -Invoke Request-LokiCtrlCInput -Times 0 -Exactly
    }
}

Describe 'the lifecycle' {
    BeforeEach {
        $script:claims = New-Object System.Collections.Generic.List[object]
        Mock -CommandName Request-LokiCtrlCInput -MockWith { [void]$script:claims.Add($Enabled); return $true }
        Initialize-LokiKeyread
    }
    AfterEach { $script:LokiKeyState = $null }

    It 'puts the flag back the way it found it, rather than assuming it was off' {
        # It was False on every console measured. Assuming that is how a tool leaves a machine
        # changed, so Close restores what Open saw.
        $script:LokiKeyState = @{ CtrlCWasOwned = $true }
        Close-LokiKeyread
        $script:claims[-1] | Should -BeTrue
        Test-LokiKeyreadOpen | Should -BeFalse

        $script:claims.Clear()
        $script:LokiKeyState = @{ CtrlCWasOwned = $false }
        Close-LokiKeyread
        $script:claims[-1] | Should -BeFalse
    }

    It 'closing twice claims nothing the second time' {
        $script:LokiKeyState = @{ CtrlCWasOwned = $false }
        Close-LokiKeyread
        $script:claims.Clear()
        Close-LokiKeyread
        $script:claims.Count | Should -Be 0
    }

    It 'refuses under redirection, which is how this very test process runs' {
        Open-LokiKeyread | Should -BeFalse
        Get-LokiKeyreadRefusal | Should -Be 'redirected'
        Test-LokiKeyreadOpen | Should -BeFalse
    }

    It 'reports closed after Initialize' {
        Get-LokiKeyreadRefusal | Should -Be 'closed'
    }
}

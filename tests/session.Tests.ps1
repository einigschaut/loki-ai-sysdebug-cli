# tests/session.Tests.ps1 -- the session loop (issue #133, slice 3b).
#
# CI runs Pester in a process with neither a console nor a keyboard, which is exactly the condition
# under which a session refuses to open. So everything that decides anything lives in a pure
# function and is tested here; the four console calls are mocked, and what is left over is drawing,
# which needs a human.
#
# Three tests in this file are worth reading before the rest:
#
#   'every geometry produces a paintable frame'  -- property test over a grid of window sizes,
#       asserting Test-LokiScreenModelShape. A frame one character short on one row does not throw:
#       it silently shifts that row's diff arithmetic and puts text in the wrong column. This is the
#       cheap guard against the whole class.
#
#   'the layout puts the caret and the hint where the reference puts them' -- at Height 51 the
#       arithmetic must land on rows 49 and 51, 1-based, because that is where a 249 KB capture of a
#       real reference session put them 1843 and 1 times respectively.
#
#   'a pasted block refuses to run and is handed back' -- the decision ADR-0038 deferred to this
#       slice. Both halves matter: it must not run, AND the operator must get their text back.
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\ui.ps1"
    . "$PSScriptRoot\..\src\lib\i18n.ps1"
    . "$PSScriptRoot\..\src\lib\brand.ps1"
    . "$PSScriptRoot\..\src\lib\liveregion.ps1"   # Get-LokiConsoleFact lives there
    . "$PSScriptRoot\..\src\lib\screen.ps1"
    . "$PSScriptRoot\..\src\lib\keyread.ps1"
    . "$PSScriptRoot\..\src\lib\lineedit.ps1"
    . "$PSScriptRoot\..\src\lib\session.ps1"

    Initialize-LokiUi
    Initialize-LokiI18n -AppRoot (Resolve-Path "$PSScriptRoot\..\src").Path -Locale 'en' | Out-Null

    # Functions, not variables: PSAvoidGlobalVars is on, and Pester's BeforeAll scope does not reach
    # into It blocks for variables the way it does for functions.

    # A key shaped exactly like Read-LokiKey's output. EVERY field is set, because StrictMode makes a
    # missing property a throw rather than a $null -- which is the point of pinning the shape here.
    function global:New-LokiTestKey {
        param([hashtable]$Override = @{})
        $k = @{
            Kind          = 'text'
            Char          = 97
            Text          = 'a'
            Key           = 'A'
            Modifiers     = '0'
            ControlLetter = ''
            Source        = 'typing'
            MoreWaiting   = $false
            GapMs         = 120.0
        }
        foreach ($n in $Override.Keys) { $k[$n] = $Override[$n] }
        return [pscustomobject]$k
    }

    function global:New-LokiTestTextKey {
        param([string]$Char)
        return New-LokiTestKey @{ Kind = 'text'; Text = $Char; Char = [int][char]$Char; Key = $Char.ToUpperInvariant() }
    }

    function global:New-LokiTestEnterKey {
        param([string]$Source = 'typing', [bool]$MoreWaiting = $false)
        return New-LokiTestKey @{ Kind = 'enter'; Text = ''; Char = 13; Key = 'Enter'; Source = $Source; MoreWaiting = $MoreWaiting }
    }

    function global:New-LokiTestCtrlCKey {
        return New-LokiTestKey @{ Kind = 'control'; Text = ''; Char = 3; Key = 'C'; ControlLetter = 'c'; Modifiers = 'Control' }
    }

    # Type a whole string into a state, one key at a time, and hand back the last result.
    function global:Invoke-LokiTestTyping {
        param($State, [string]$Text)
        $last = $null
        foreach ($ch in $Text.ToCharArray()) {
            $last = Step-LokiSession -State $State -Key (New-LokiTestTextKey -Char ([string]$ch))
        }
        return $last
    }
}

Describe 'Get-LokiSessionChrome' {

    It 'draws every non-ascii character in BOTH code pages a German console actually runs' {
        # Not a claim, a round trip. CP850 is the default on a German Windows console and CP437 is
        # what an older one falls back to; a character that survives neither is a question mark on
        # the machine this tool exists for. Same probe Resolve-LokiGlyphTier uses.
        $chrome = Get-LokiSessionChrome -Tier 'rich'
        foreach ($cp in @(850, 437)) {
            $enc = [System.Text.Encoding]::GetEncoding($cp)
            foreach ($name in @('BreakMark', 'Separator', 'ScrollLeft', 'ScrollRight', 'Echo')) {
                Test-LokiEncodingSupport -Encoding $enc -Text $chrome[$name] |
                    Should -BeTrue -Because "$name must survive CP$cp"
            }
        }
    }

    It 'keeps the ascii tier inside ascii' {
        $chrome = Get-LokiSessionChrome -Tier 'ascii'
        foreach ($name in @('BreakMark', 'Separator', 'ScrollLeft', 'ScrollRight', 'Echo')) {
            foreach ($ch in ([string]$chrome[$name]).ToCharArray()) {
                ([int][char]$ch) | Should -BeLessThan 128 -Because "$name must be ascii in the ascii tier"
            }
        }
    }

    It 'gives rich and oem the same characters, because the tiers differ above U+00FF' {
        $rich = Get-LokiSessionChrome -Tier 'rich'
        $oem = Get-LokiSessionChrome -Tier 'oem'
        foreach ($name in @('BreakMark', 'Separator', 'ScrollLeft', 'ScrollRight', 'Echo')) {
            $rich[$name] | Should -Be $oem[$name]
        }
    }

    It 'gives the break mark as exactly one character, or Format-LokiLineView would drift' {
        # Format-LokiLineView takes only $mark[0]. A two-character mark would render as one column
        # while the cursor arithmetic counted two.
        (Get-LokiSessionChrome -Tier 'rich').BreakMark.Length | Should -Be 1
        (Get-LokiSessionChrome -Tier 'ascii').BreakMark.Length | Should -Be 1
    }
}

Describe 'Get-LokiSessionLayout' {

    It 'puts the caret and the hint where the reference puts them' {
        # Measured, from a 249 KB capture of a real 5.3-minute session in a 51-row window: the input
        # caret was drawn at row 49 1843 times, and "Press Ctrl-C again to exit" at row 51 column 3.
        # The layout is 0-based, the capture 1-based.
        $l = Get-LokiSessionLayout -Height 51
        ($l.InputRow + 1) | Should -Be 49
        ($l.StatusRow + 1) | Should -Be 51
    }

    It 'never lets the chrome outgrow the transcript' {
        # The rule that decides when the notice row is dropped. Asserted as a property across every
        # height the screen will ever hand over, rather than at the two heights I happened to try.
        foreach ($h in 8..80) {
            $l = Get-LokiSessionLayout -Height $h
            $l.Ok | Should -BeTrue
            $chrome = $h - $l.TranscriptRows
            $l.TranscriptRows | Should -BeGreaterOrEqual $chrome -Because "at height $h"
        }
    }

    It 'stacks the rows in order and inside the window' {
        foreach ($h in 8..80) {
            $l = Get-LokiSessionLayout -Height $h
            $l.StatusRow | Should -Be ($h - 1)
            $l.BoxBottom | Should -Be ($l.StatusRow - 1)
            $l.InputRow | Should -Be ($l.BoxBottom - 1)
            $l.BoxTop | Should -Be ($l.InputRow - 1)
            # The transcript must end exactly where the chrome begins -- no gap, no overlap.
            $firstChrome = $l.BoxTop
            if ($l.NoticeRow -ge 0) { $firstChrome = $l.NoticeRow }
            ($l.TranscriptTop + $l.TranscriptRows) | Should -Be $firstChrome -Because "at height $h"
        }
    }

    It 'drops the notice row below height 10 and keeps it at and above' {
        (Get-LokiSessionLayout -Height 9).NoticeRow | Should -Be -1
        (Get-LokiSessionLayout -Height 8).NoticeRow | Should -Be -1
        (Get-LokiSessionLayout -Height 10).NoticeRow | Should -BeGreaterOrEqual 0
        (Get-LokiSessionLayout -Height 51).NoticeRow | Should -BeGreaterOrEqual 0
    }

    It 'refuses below the smallest window the screen was measured in' {
        foreach ($h in 0..7) { (Get-LokiSessionLayout -Height $h).Ok | Should -BeFalse }
        (Get-LokiSessionLayout -Height 8).Ok | Should -BeTrue
    }
}

Describe 'Format-LokiSessionTranscript' {

    It 'returns exactly the number of rows asked for, however many lines there were' {
        foreach ($count in @(0, 1, 5, 40)) {
            $lines = @()
            for ($i = 0; $i -lt $count; $i++) { $lines += "line $i" }
            (Format-LokiSessionTranscript -Lines $lines -Width 20 -Rows 6).Count | Should -Be 6
        }
    }

    It 'grows downward: a short transcript sits at the top and pads at the bottom' {
        $r = Format-LokiSessionTranscript -Lines @('first', 'second') -Width 20 -Rows 5
        $r[0] | Should -Be 'first'
        $r[1] | Should -Be 'second'
        $r[4] | Should -Be ''
    }

    It 'keeps the TAIL when it overflows, because the newest line is the one being read' {
        $lines = @('a', 'b', 'c', 'd', 'e')
        $r = Format-LokiSessionTranscript -Lines $lines -Width 20 -Rows 2
        $r[0] | Should -Be 'd'
        $r[1] | Should -Be 'e'
    }

    It 'wraps a long line instead of truncating it' {
        # The right-hand end of a path or an error code is exactly the part the operator needed.
        $r = Format-LokiSessionTranscript -Lines @('abcdefghij') -Width 4 -Rows 5
        $r[0] | Should -Be 'abcd'
        $r[1] | Should -Be 'efgh'
        $r[2] | Should -Be 'ij'
        ($r[0] + $r[1] + $r[2]) | Should -Be 'abcdefghij'
    }

    It 'keeps an empty line as one empty row rather than closing the gap' {
        $r = Format-LokiSessionTranscript -Lines @('a', '', 'b') -Width 10 -Rows 3
        $r[0] | Should -Be 'a'
        $r[1] | Should -Be ''
        $r[2] | Should -Be 'b'
    }

    It 'never returns a row wider than the width' {
        $long = 'x' * 200
        foreach ($row in (Format-LokiSessionTranscript -Lines @($long) -Width 13 -Rows 20)) {
            $row.Length | Should -BeLessOrEqual 13
        }
    }
}

Describe 'Format-LokiSessionStatus' {

    It 'joins the engine and the hint with the separator' {
        Format-LokiSessionStatus -Engine 'claude' -Hint 'esc quits' -Separator ' - ' -Width 40 |
            Should -Be 'claude - esc quits'
    }

    It 'drops the engine before the hint when the row is too narrow for both' {
        # The hint says how to get OUT. A row with space for one of the two carries that one.
        Format-LokiSessionStatus -Engine 'qwen3-8b' -Hint 'esc quits' -Separator ' - ' -Width 12 |
            Should -Be 'esc quits'
    }

    It 'truncates the hint only when even the hint does not fit' {
        Format-LokiSessionStatus -Engine 'e' -Hint 'abcdefgh' -Separator ' - ' -Width 4 | Should -Be 'abcd'
    }

    It 'omits the separator when there is no engine' {
        Format-LokiSessionStatus -Engine '' -Hint 'hint' -Separator ' - ' -Width 40 | Should -Be 'hint'
    }
}

Describe 'Format-LokiSessionFrame' {

    It 'every geometry produces a paintable frame' {
        # A row one character short does not throw. It shifts that row's diff arithmetic and puts
        # text in the wrong column, silently -- the same class of failure the read-back check in
        # lib/screen.ps1 exists to catch, and this is the cheap version that covers every size.
        $state = New-LokiSessionState -Engine 'claude' -Tier 'rich'
        Add-LokiSessionEntry -State $state -Text 'a line long enough to need wrapping on a narrow window'
        $state.Buffer = 'loki hwscan --tier mid'
        $state.Cursor = 22
        foreach ($w in @(1, 12, 19, 20, 21, 40, 63, 120, 208)) {
            foreach ($h in @(1, 5, 7, 8, 9, 10, 30, 51)) {
                $f = Format-LokiSessionFrame -State $state -Width $w -Height $h
                Test-LokiScreenModelShape -Model $f.Model -Width $w -Height $h |
                    Should -BeTrue -Because "geometry ${w}x${h}"
            }
        }
    }

    It 'keeps the caret inside the window at every geometry' {
        $state = New-LokiSessionState -Tier 'rich'
        $state.Buffer = 'x' * 300
        $state.Cursor = 300
        foreach ($w in @(20, 21, 40, 120)) {
            foreach ($h in @(8, 10, 30, 51)) {
                $f = Format-LokiSessionFrame -State $state -Width $w -Height $h
                $f.CaretRow | Should -BeGreaterOrEqual 0
                $f.CaretRow | Should -BeLessThan $h
                $f.CaretCol | Should -BeGreaterOrEqual 0
                $f.CaretCol | Should -BeLessThan $w -Because "geometry ${w}x${h}"
            }
        }
    }

    It 'parks the caret at column 3, one-based, on an empty line' {
        # Which is where the reference parks it: ESC[49;3H in the capture. It is not a coincidence --
        # column 3 is the first content column inside a border of one character plus one space.
        $state = New-LokiSessionState -Tier 'rich'
        $f = Format-LokiSessionFrame -State $state -Width 120 -Height 51
        ($f.CaretCol + 1) | Should -Be 3
        ($f.CaretRow + 1) | Should -Be 49
    }

    It 'moves the caret one column per character typed' {
        $state = New-LokiSessionState -Tier 'rich'
        [void](Invoke-LokiTestTyping -State $state -Text 'loki')
        $f = Format-LokiSessionFrame -State $state -Width 120 -Height 51
        ($f.CaretCol + 1) | Should -Be 7
    }

    It 'draws the input box on the three rows the layout names' {
        $state = New-LokiSessionState -Tier 'ascii'
        $layout = Get-LokiSessionLayout -Height 30
        $f = Format-LokiSessionFrame -State $state -Width 60 -Height 30
        ([string]$f.Model[$layout.BoxTop])[0] | Should -Be '+'
        ([string]$f.Model[$layout.InputRow])[0] | Should -Be '|'
        ([string]$f.Model[$layout.BoxBottom])[0] | Should -Be '+'
    }

    It 'shows the operator text inside the box' {
        $state = New-LokiSessionState -Tier 'ascii'
        [void](Invoke-LokiTestTyping -State $state -Text 'hwscan')
        $layout = Get-LokiSessionLayout -Height 30
        $f = Format-LokiSessionFrame -State $state -Width 60 -Height 30
        ([string]$f.Model[$layout.InputRow]) | Should -Match 'hwscan'
    }

    It 'marks a line that has scrolled out of the box, without narrowing the box' {
        $state = New-LokiSessionState -Tier 'ascii'
        $state.Buffer = 'y' * 200
        $state.Cursor = 200
        $layout = Get-LokiSessionLayout -Height 30
        $f = Format-LokiSessionFrame -State $state -Width 40 -Height 30
        $row = [string]$f.Model[$layout.InputRow]
        $row.Length | Should -Be 40
        $row[1] | Should -Be '<'
    }

    It 'puts the engine on the status row and replaces it entirely once Ctrl+C is armed' {
        $state = New-LokiSessionState -Engine 'qwen3-8b' -Tier 'ascii'
        $layout = Get-LokiSessionLayout -Height 30
        ([string](Format-LokiSessionFrame -State $state -Width 80 -Height 30).Model[$layout.StatusRow]) |
            Should -Match 'qwen3-8b'

        $state.Armed = $true
        $armedRow = [string](Format-LokiSessionFrame -State $state -Width 80 -Height 30).Model[$layout.StatusRow]
        $armedRow | Should -Match 'again'
        # REPLACES, not joins -- the reference follows its warning with ESC[K for exactly this reason.
        $armedRow | Should -Not -Match 'qwen3-8b'
    }

    It 'shows the notice on the notice row and clears it again' {
        $state = New-LokiSessionState -Tier 'ascii'
        $state.Notice = 'something happened'
        $layout = Get-LokiSessionLayout -Height 30
        ([string](Format-LokiSessionFrame -State $state -Width 60 -Height 30).Model[$layout.NoticeRow]) |
            Should -Match 'something happened'
        $state.Notice = ''
        ([string](Format-LokiSessionFrame -State $state -Width 60 -Height 30).Model[$layout.NoticeRow]).Trim() |
            Should -Be ''
    }

    It 'says so rather than painting rubble when the window is too small' {
        $state = New-LokiSessionState -Tier 'ascii'
        foreach ($g in @(@(19, 30), @(60, 7), @(10, 4))) {
            $f = Format-LokiSessionFrame -State $state -Width $g[0] -Height $g[1]
            Test-LokiScreenModelShape -Model $f.Model -Width $g[0] -Height $g[1] | Should -BeTrue
            ([string]$f.Model[0]).Trim() | Should -Not -Be ''
        }
    }

    It 'draws a frame with no state at all' {
        # A refusal or a first frame may have to be drawn before there is a session.
        $f = Format-LokiSessionFrame -State $null -Width 80 -Height 24
        Test-LokiScreenModelShape -Model $f.Model -Width 80 -Height 24 | Should -BeTrue
    }

    It 'puts no escape sequence into the model, or the diff would count it as content' {
        $state = New-LokiSessionState -Engine 'claude' -Tier 'rich'
        Add-LokiSessionEntry -State $state -Text 'ordinary output'
        $f = Format-LokiSessionFrame -State $state -Width 80 -Height 24
        foreach ($row in $f.Model) { ([string]$row) | Should -Not -Match ([char]27) }
    }
}

Describe 'Add-LokiSessionEntry' {

    It 'splits a multi-line block into transcript lines' {
        $state = New-LokiSessionState -Tier 'ascii'
        Add-LokiSessionEntry -State $state -Text "one`r`ntwo`nthree`rfour"
        $state.Lines.Count | Should -Be 4
        $state.Lines[0] | Should -Be 'one'
        $state.Lines[3] | Should -Be 'four'
    }

    It 'keeps an empty entry as an empty line' {
        $state = New-LokiSessionState -Tier 'ascii'
        Add-LokiSessionEntry -State $state -Text ''
        $state.Lines.Count | Should -Be 1
    }
}

Describe 'Step-LokiSession' {

    It 'types text into the buffer and asks the caller for nothing' {
        $state = New-LokiSessionState -Tier 'ascii'
        $r = Invoke-LokiTestTyping -State $state -Text 'hwscan'
        $state.Buffer | Should -Be 'hwscan'
        $state.Cursor | Should -Be 6
        $r.Action | Should -Be ''
    }

    It 'submits a typed line, echoes it and hands the text to the caller' {
        $state = New-LokiSessionState -Tier 'ascii'
        [void](Invoke-LokiTestTyping -State $state -Text 'hwscan')
        $r = Step-LokiSession -State $state -Key (New-LokiTestEnterKey)
        $r.Action | Should -Be 'submit'
        $r.Text | Should -Be 'hwscan'
        $state.Buffer | Should -Be ''
        $state.Cursor | Should -Be 0
        $state.Lines[0] | Should -Be '> hwscan'
    }

    It 'treats an empty Enter as a blank prompt, not a command' {
        $state = New-LokiSessionState -Tier 'ascii'
        (Step-LokiSession -State $state -Key (New-LokiTestEnterKey)).Action | Should -Be ''
        [void](Invoke-LokiTestTyping -State $state -Text '   ')
        (Step-LokiSession -State $state -Key (New-LokiTestEnterKey)).Action | Should -Be ''
        $state.Lines.Count | Should -Be 0
    }

    It 'runs a pasted command whose Enter is the last key of the burst' {
        # The single most common paste there is: one command copied out of a ticket, with the
        # trailing newline that copying a line always brings.
        $state = New-LokiSessionState -Tier 'ascii'
        foreach ($ch in 'loki hwscan'.ToCharArray()) {
            [void](Step-LokiSession -State $state -Key (New-LokiTestKey @{
                Kind = 'text'; Text = [string]$ch; Char = [int][char]$ch; Key = 'A'
                Source = 'paste'; MoreWaiting = $true
            }))
        }
        $r = Step-LokiSession -State $state -Key (New-LokiTestEnterKey -Source 'paste' -MoreWaiting $false)
        $r.Action | Should -Be 'submit'
        $r.Text | Should -Be 'loki hwscan'
    }

    It 'a pasted block refuses to run and is handed back' {
        # ADR-0038 deferred this to the session. BOTH halves matter: running only the first line
        # would be silently wrong, and refusing while ALSO discarding the paste would punish the
        # operator twice for one mistake.
        $state = New-LokiSessionState -Tier 'ascii'
        [void](Invoke-LokiTestTyping -State $state -Text 'a')
        [void](Step-LokiSession -State $state -Key (New-LokiTestEnterKey -Source 'paste' -MoreWaiting $true))
        [void](Invoke-LokiTestTyping -State $state -Text 'b')
        $state.Buffer | Should -Match "`n"

        $r = Step-LokiSession -State $state -Key (New-LokiTestEnterKey)
        $r.Action | Should -Be ''
        $state.Buffer | Should -Be "a`nb"
        $state.Cursor | Should -Be 3
        $state.Notice | Should -Not -Be ''
        $state.Lines.Count | Should -Be 0
    }

    It 'takes two presses of Ctrl+C to leave, and says so after the first' {
        $state = New-LokiSessionState -Tier 'ascii'
        $first = Step-LokiSession -State $state -Key (New-LokiTestCtrlCKey)
        $first.Action | Should -Be ''
        $state.Armed | Should -BeTrue

        $second = Step-LokiSession -State $state -Key (New-LokiTestCtrlCKey)
        $second.Action | Should -Be 'exit'
    }

    It 'disarms on any other key, so a Ctrl+C from ten minutes ago cannot end the session' {
        $state = New-LokiSessionState -Tier 'ascii'
        [void](Step-LokiSession -State $state -Key (New-LokiTestCtrlCKey))
        $state.Armed | Should -BeTrue
        [void](Invoke-LokiTestTyping -State $state -Text 'x')
        $state.Armed | Should -BeFalse
        (Step-LokiSession -State $state -Key (New-LokiTestCtrlCKey)).Action | Should -Be ''
    }

    It 'never lets Ctrl+C reach the line editor' {
        # lib/lineedit.ps1 has no Ctrl+C handler precisely so the session stays its only owner. If
        # the key were passed through anyway, a later chord added there would silently start firing
        # on the exit key.
        #
        # Asserted on the CALL, not on the buffer. Written the obvious way -- type 'abc', send
        # Ctrl+C, check the buffer still says 'abc' -- this test passed with the guard deliberately
        # removed, because Edit-LokiLine ignores Ctrl+C today and hands the same buffer straight
        # back. It was a test that could not fail (CLAUDE.md section 9), and it was the mutation run
        # on 2026-08-31 that said so rather than a review of it.
        Mock -CommandName Edit-LokiLine -MockWith {
            return [pscustomobject]@{ Buffer = $Buffer; Cursor = $Cursor; Action = '' }
        }
        $state = New-LokiSessionState -Tier 'ascii'
        $state.Buffer = 'abc'
        $state.Cursor = 3
        [void](Step-LokiSession -State $state -Key (New-LokiTestCtrlCKey))
        Should -Invoke Edit-LokiLine -Times 0 -Exactly
        $state.Buffer | Should -Be 'abc'

        # And the same key with the chord letter cleared DOES reach it, so the assertion above is
        # about Ctrl+C rather than about control keys never getting through at all.
        [void](Step-LokiSession -State $state -Key (New-LokiTestKey @{ Kind = 'control'; Text = ''; Char = 21; Key = 'U'; ControlLetter = 'u' }))
        Should -Invoke Edit-LokiLine -Times 1 -Exactly
    }

    It 'reports Escape as an interrupt and keeps the session' {
        $state = New-LokiSessionState -Tier 'ascii'
        $r = Step-LokiSession -State $state -Key (New-LokiTestKey @{ Kind = 'escape'; Text = ''; Char = 27; Key = 'Escape' })
        $r.Action | Should -Be 'interrupt'
    }

    It 'clears the notice on the next keystroke' {
        # A notice left standing would look like a fresh answer to whatever the operator just did.
        $state = New-LokiSessionState -Tier 'ascii'
        [void](Step-LokiSession -State $state -Key (New-LokiTestKey @{ Kind = 'tab'; Text = ''; Char = 9; Key = 'Tab' }))
        $state.Notice | Should -Not -Be ''
        [void](Invoke-LokiTestTyping -State $state -Text 'z')
        $state.Notice | Should -Be ''
    }

    It 'passes the readline chords through to the editor' {
        $state = New-LokiSessionState -Tier 'ascii'
        [void](Invoke-LokiTestTyping -State $state -Text 'one two')
        [void](Step-LokiSession -State $state -Key (New-LokiTestKey @{ Kind = 'control'; Text = ''; Char = 23; Key = 'W'; ControlLetter = 'w' }))
        $state.Buffer | Should -Be 'one '
    }

    It 'does nothing at all when handed no key' {
        $state = New-LokiSessionState -Tier 'ascii'
        (Step-LokiSession -State $state -Key $null).Action | Should -Be ''
    }
}

Describe 'session history' {

    It 'walks back through submitted commands and forward again' {
        $state = New-LokiSessionState -Tier 'ascii'
        foreach ($cmd in @('hwscan', 'collect')) {
            [void](Invoke-LokiTestTyping -State $state -Text $cmd)
            [void](Step-LokiSession -State $state -Key (New-LokiTestEnterKey))
        }
        $up = New-LokiTestKey @{ Kind = 'key'; Text = ''; Char = 0; Key = 'UpArrow' }
        $down = New-LokiTestKey @{ Kind = 'key'; Text = ''; Char = 0; Key = 'DownArrow' }

        [void](Step-LokiSession -State $state -Key $up)
        $state.Buffer | Should -Be 'collect'
        $state.Cursor | Should -Be 7
        [void](Step-LokiSession -State $state -Key $up)
        $state.Buffer | Should -Be 'hwscan'
        [void](Step-LokiSession -State $state -Key $down)
        $state.Buffer | Should -Be 'collect'
    }

    It 'gives back what was half-typed when it walks forward off the end' {
        # Losing the half-typed line is the thing that makes people stop using history at all.
        $state = New-LokiSessionState -Tier 'ascii'
        [void](Invoke-LokiTestTyping -State $state -Text 'hwscan')
        [void](Step-LokiSession -State $state -Key (New-LokiTestEnterKey))
        [void](Invoke-LokiTestTyping -State $state -Text 'half')

        $up = New-LokiTestKey @{ Kind = 'key'; Text = ''; Char = 0; Key = 'UpArrow' }
        $down = New-LokiTestKey @{ Kind = 'key'; Text = ''; Char = 0; Key = 'DownArrow' }
        [void](Step-LokiSession -State $state -Key $up)
        $state.Buffer | Should -Be 'hwscan'
        [void](Step-LokiSession -State $state -Key $down)
        $state.Buffer | Should -Be 'half'
    }

    It 'does not wrap round at either end' {
        # Wrapping puts the oldest command under the operator's fingers at the exact moment they
        # expected the newest.
        $state = New-LokiSessionState -Tier 'ascii'
        [void](Invoke-LokiTestTyping -State $state -Text 'only')
        [void](Step-LokiSession -State $state -Key (New-LokiTestEnterKey))
        $up = New-LokiTestKey @{ Kind = 'key'; Text = ''; Char = 0; Key = 'UpArrow' }
        foreach ($i in 1..5) { [void](Step-LokiSession -State $state -Key $up) }
        $state.Buffer | Should -Be 'only'
    }

    It 'does not store a command twice in a row' {
        $state = New-LokiSessionState -Tier 'ascii'
        foreach ($i in 1..3) {
            [void](Invoke-LokiTestTyping -State $state -Text 'same')
            [void](Step-LokiSession -State $state -Key (New-LokiTestEnterKey))
        }
        $state.History.Count | Should -Be 1
    }

    It 'walks nowhere when nothing has been submitted yet' {
        $state = New-LokiSessionState -Tier 'ascii'
        [void](Invoke-LokiTestTyping -State $state -Text 'draft')
        $up = New-LokiTestKey @{ Kind = 'key'; Text = ''; Char = 0; Key = 'UpArrow' }
        [void](Step-LokiSession -State $state -Key $up)
        $state.Buffer | Should -Be 'draft'
    }
}

Describe 'New-LokiSessionState' {

    It 'resolves the glyph tier from the live console when none is given' {
        (New-LokiSessionState).Tier | Should -BeIn @('rich', 'oem', 'ascii')
    }

    It 'starts empty, unarmed and not browsing history' {
        $s = New-LokiSessionState -Tier 'ascii'
        $s.Buffer | Should -Be ''
        $s.Cursor | Should -Be 0
        $s.Armed | Should -BeFalse
        $s.Notice | Should -Be ''
        $s.Lines.Count | Should -Be 0
        $s.HistoryIndex | Should -Be $s.History.Count
    }
}

Describe 'Open-LokiSession / Close-LokiSession' {

    BeforeEach { Initialize-LokiSession }
    AfterEach { Initialize-LokiSession }

    It 'opens only when BOTH the screen and the keyboard are available' {
        Mock -CommandName Open-LokiScreen -MockWith { return $true }
        Mock -CommandName Open-LokiKeyread -MockWith { return $true }
        Open-LokiSession | Should -BeTrue
        Test-LokiSessionOpen | Should -BeTrue
        Get-LokiSessionRefusal | Should -Be 'ok'
    }

    It 'refuses when the screen refuses, and says which half said no' {
        Mock -CommandName Open-LokiScreen -MockWith { return $false }
        Mock -CommandName Get-LokiScreenRefusal -MockWith { return 'no-vt' }
        Mock -CommandName Open-LokiKeyread -MockWith { throw 'must not be reached' }
        Open-LokiSession | Should -BeFalse
        Test-LokiSessionOpen | Should -BeFalse
        Get-LokiSessionRefusal | Should -Be 'screen:no-vt'
    }

    It 'gives the screen back when the keyboard refuses, rather than leaving half a session' {
        Mock -CommandName Open-LokiScreen -MockWith { return $true }
        Mock -CommandName Open-LokiKeyread -MockWith { return $false }
        Mock -CommandName Get-LokiKeyreadRefusal -MockWith { return 'redirected' }
        Mock -CommandName Close-LokiScreen -MockWith { }
        Open-LokiSession | Should -BeFalse
        Get-LokiSessionRefusal | Should -Be 'keyread:redirected'
        # Twice: once from the Close-LokiSession that begins EVERY open attempt, so a reopen cannot
        # inherit half a previous session, and once from the keyboard's refusal path. The first is a
        # no-op here; the second is the one under test.
        Should -Invoke Close-LokiScreen -Times 2 -Exactly
    }

    It 'closes both halves, and closing twice is harmless' {
        Mock -CommandName Open-LokiScreen -MockWith { return $true }
        Mock -CommandName Open-LokiKeyread -MockWith { return $true }
        Mock -CommandName Close-LokiScreen -MockWith { }
        Mock -CommandName Close-LokiKeyread -MockWith { }
        [void](Open-LokiSession)
        Close-LokiSession
        Close-LokiSession
        Test-LokiSessionOpen | Should -BeFalse
        # Three: the one inside Open-LokiSession, then the two explicit closes. The point of the test
        # is the SECOND explicit close -- closing an already-closed session must not throw.
        Should -Invoke Close-LokiScreen -Times 3 -Exactly
        Should -Invoke Close-LokiKeyread -Times 3 -Exactly
    }
}

Describe 'Write-LokiSessionFrame' {

    It 'fences the frame the way the reference does: hide, paint, then move and show' {
        # Without the fence the cursor is visibly parked wherever the diff happened to end -- in the
        # middle of the transcript -- for the moment between the paint and the caret move.
        $script:order = New-Object System.Collections.Generic.List[string]
        Mock -CommandName Test-LokiScreenOpen -MockWith { return $true }
        Mock -CommandName Get-LokiScreenSize -MockWith { return [pscustomobject]@{ Width = 80; Height = 24 } }
        Mock -CommandName Hide-LokiScreenCaret -MockWith { [void]$script:order.Add('hide'); return $true }
        Mock -CommandName Write-LokiScreenFrame -MockWith { [void]$script:order.Add('paint') }
        Mock -CommandName Show-LokiScreenCaret -MockWith { [void]$script:order.Add('show'); return $true }

        Write-LokiSessionFrame -State (New-LokiSessionState -Tier 'ascii')
        ($script:order -join ',') | Should -Be 'hide,paint,show'
    }

    It 'paints nothing when no screen is open' {
        Mock -CommandName Test-LokiScreenOpen -MockWith { return $false }
        Mock -CommandName Write-LokiScreenFrame -MockWith { }
        Write-LokiSessionFrame -State (New-LokiSessionState -Tier 'ascii')
        Should -Invoke Write-LokiScreenFrame -Times 0 -Exactly
    }
}

Describe 'Invoke-LokiSessionRound' {

    BeforeEach { Initialize-LokiSession }
    AfterEach { Initialize-LokiSession }

    It 'paints, reads a key, then checks the geometry -- in that order' {
        # The resize check can only be AFTER the read: measured for ADR-0037, dragging the window
        # while a read was pending returned normally and the new size appeared only once ReadKey
        # came back. Nothing announces it, so the arrival of a key is the only moment to look.
        $script:order = New-Object System.Collections.Generic.List[string]
        Mock -CommandName Open-LokiScreen -MockWith { return $true }
        Mock -CommandName Open-LokiKeyread -MockWith { return $true }
        Mock -CommandName Write-LokiSessionFrame -MockWith { [void]$script:order.Add('paint') }
        Mock -CommandName Read-LokiKey -MockWith { [void]$script:order.Add('read'); return (New-LokiTestTextKey -Char 'q') }
        Mock -CommandName Resize-LokiScreen -MockWith { [void]$script:order.Add('resize'); return $true }

        [void](Open-LokiSession)
        $state = New-LokiSessionState -Tier 'ascii'
        $r = Invoke-LokiSessionRound -State $state
        ($script:order -join ',') | Should -Be 'paint,read,resize'
        $r.Action | Should -Be ''
        $state.Buffer | Should -Be 'q'
    }

    It 'reports a closed console instead of spinning' {
        Mock -CommandName Open-LokiScreen -MockWith { return $true }
        Mock -CommandName Open-LokiKeyread -MockWith { return $true }
        Mock -CommandName Write-LokiSessionFrame -MockWith { }
        Mock -CommandName Read-LokiKey -MockWith { return $null }
        Mock -CommandName Resize-LokiScreen -MockWith { return $true }

        [void](Open-LokiSession)
        (Invoke-LokiSessionRound -State (New-LokiSessionState -Tier 'ascii')).Action | Should -Be 'closed'
    }

    It 'refuses to run a round when nothing is open' {
        (Invoke-LokiSessionRound -State (New-LokiSessionState -Tier 'ascii')).Action | Should -Be 'closed'
    }

    It 'carries a submitted line out to the caller' {
        Mock -CommandName Open-LokiScreen -MockWith { return $true }
        Mock -CommandName Open-LokiKeyread -MockWith { return $true }
        Mock -CommandName Write-LokiSessionFrame -MockWith { }
        Mock -CommandName Resize-LokiScreen -MockWith { return $true }
        Mock -CommandName Read-LokiKey -MockWith { return (New-LokiTestEnterKey) }

        [void](Open-LokiSession)
        $state = New-LokiSessionState -Tier 'ascii'
        [void](Invoke-LokiTestTyping -State $state -Text 'doctor')
        $r = Invoke-LokiSessionRound -State $state
        $r.Action | Should -Be 'submit'
        $r.Text | Should -Be 'doctor'
    }
}

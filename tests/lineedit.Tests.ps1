# tests/lineedit.Tests.ps1 -- the input line (issue #133, slice 3a).
#
# lib/lineedit.ps1 is entirely pure, so unlike the screen and the reader there is nothing here that
# CI cannot exercise. Every edge case is reachable, so every edge case is pinned.
#
# Two tests exist to fail on purpose:
#   'a pasted Enter with more keys behind it does NOT submit'  -- the whole reason slice 2 measured
#       arrival timing at all. An editor that gets this wrong fires one command per pasted line.
#   'a trailing pasted Enter DOES submit'                      -- the other half. Refusing every
#       pasted Enter would break the single most common paste there is.
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\lineedit.ps1"

    # Feeds a whole key sequence through the editor, the way the session loop will.
    function global:Invoke-LokiTestKeySequence {
        # NOT $args: that is an automatic variable, and assigning to it inside a function is a trap
        # PSAvoidAssignmentToAutomaticVariable exists to catch.
        param([string]$Buffer = '', [int]$Cursor = 0, [object[]]$Keys)
        $state = [pscustomobject]@{ Buffer = $Buffer; Cursor = $Cursor; Action = '' }
        foreach ($k in $Keys) {
            $call = @{
                Buffer = $state.Buffer
                Cursor = $state.Cursor
                Kind   = $k.Kind
            }
            foreach ($opt in @('Text', 'KeyName', 'ControlLetter', 'Source')) {
                if ($k.ContainsKey($opt)) { $call[$opt] = $k[$opt] }
            }
            if ($k.ContainsKey('MoreWaiting')) { $call['MoreWaiting'] = [bool]$k['MoreWaiting'] }
            $state = Edit-LokiLine @call
        }
        return $state
    }
    function global:New-LokiTestTextKey {
        param([string]$Text)
        return @{ Kind = 'text'; Text = $Text }
    }
}

Describe 'Test-LokiLineInsertable' {
    It 'accepts the characters a German keyboard actually produces' {
        # Measured: @ 64, [ 91, \ 92, | 124, ue 252, ss 223. All ordinary characters, all insertable,
        # regardless of the fact that AltGr reported Control for the first four.
        foreach ($code in @(64, 91, 92, 124, 252, 223, 97, 32)) {
            Test-LokiLineInsertable -Text ([string][char]$code) | Should -BeTrue -Because "code $code is a character"
        }
    }
    It 'refuses control codes, which are cursor motion in disguise' {
        foreach ($code in @(0, 3, 8, 9, 13, 27, 31, 127)) {
            Test-LokiLineInsertable -Text ([string][char]$code) | Should -BeFalse -Because "code $code would desync the buffer from the drawing"
        }
    }
    It 'refuses a surrogate half, which cannot survive an index' {
        Test-LokiLineInsertable -Text ([string][char]0xD83D) | Should -BeFalse
    }
    It 'refuses nothing at all' {
        Test-LokiLineInsertable -Text '' | Should -BeFalse
        Test-LokiLineInsertable -Text $null | Should -BeFalse
    }
    It 'refuses a run containing one bad character, not just a bad first character' {
        Test-LokiLineInsertable -Text ("ab" + [string][char]9 + "cd") | Should -BeFalse
    }
}

Describe 'Edit-LokiLine -- typing' {
    It 'inserts at the cursor and moves it along' {
        $s = Invoke-LokiTestKeySequence -Keys @(
            (New-LokiTestTextKey 'l'), (New-LokiTestTextKey 'o'), (New-LokiTestTextKey 'k'), (New-LokiTestTextKey 'i'))
        $s.Buffer | Should -Be 'loki'
        $s.Cursor | Should -Be 4
        $s.Action | Should -Be ''
    }

    It 'inserts in the middle without disturbing what is around it' {
        $s = Edit-LokiLine -Buffer 'loki can' -Cursor 4 -Kind 'text' -Text 'X'
        $s.Buffer | Should -Be 'lokiX can'
        $s.Cursor | Should -Be 5
    }

    It 'takes the AltGr characters verbatim' {
        # The end-to-end version of the trap: @ arrives as a text key whose Modifiers said Control.
        # By the time it reaches here the classifier has already decided, and this must not undo it.
        $s = Invoke-LokiTestKeySequence -Keys @(
            (New-LokiTestTextKey 'C'), (New-LokiTestTextKey ':'), (New-LokiTestTextKey '\'),
            (New-LokiTestTextKey 'a'), (New-LokiTestTextKey '|'), (New-LokiTestTextKey '@'))
        $s.Buffer | Should -Be 'C:\a|@'
    }

    It 'silently drops a character it must not store, rather than corrupting the buffer' {
        $s = Edit-LokiLine -Buffer 'ab' -Cursor 2 -Kind 'text' -Text ([string][char]9)
        $s.Buffer | Should -Be 'ab'
        $s.Cursor | Should -Be 2
    }
}

Describe 'Edit-LokiLine -- THE ENTER RULE' {
    It 'a typed Enter submits' {
        (Edit-LokiLine -Buffer 'loki hwscan' -Cursor 11 -Kind 'enter' -Source 'typing').Action | Should -Be 'submit'
    }

    It 'a pasted Enter with more keys behind it does NOT submit' {
        # THE MUTATION. This is the whole reason slice 2 measured arrival timing. Get this wrong and
        # a three-line paste fires three commands the operator never typed.
        $s = Edit-LokiLine -Buffer 'a' -Cursor 1 -Kind 'enter' -Source 'paste' -MoreWaiting $true
        $s.Action | Should -Be '' -Because 'more of the paste is still arriving'
        $s.Buffer | Should -Be "a`n" -Because 'the line break is KEPT, so nothing the operator pasted is silently altered'
        $s.Cursor | Should -Be 2
    }

    It 'a trailing pasted Enter DOES submit' {
        # THE OTHER HALF. Pasting one command with a trailing newline is the most common paste there
        # is, and refusing it would make Loki feel broken in the ordinary case.
        $s = Edit-LokiLine -Buffer 'loki hwscan' -Cursor 11 -Kind 'enter' -Source 'paste' -MoreWaiting $false
        $s.Action | Should -Be 'submit'
    }

    It 'a three-line paste becomes one buffer and runs nothing' {
        # The real shape, key for key: "a<CR>b<CR>c" as slice 2 measured it -- every key but the last
        # had its successor already waiting.
        $s = Invoke-LokiTestKeySequence -Keys @(
            @{ Kind = 'text';  Text = 'a'; Source = 'paste'; MoreWaiting = $true }
            @{ Kind = 'enter';             Source = 'paste'; MoreWaiting = $true }
            @{ Kind = 'text';  Text = 'b'; Source = 'paste'; MoreWaiting = $true }
            @{ Kind = 'enter';             Source = 'paste'; MoreWaiting = $true }
            @{ Kind = 'text';  Text = 'c'; Source = 'paste'; MoreWaiting = $false }
        )
        $s.Buffer | Should -Be "a`nb`nc"
        $s.Action | Should -Be '' -Because 'nothing may run until the operator says so'
    }
}

Describe 'Edit-LokiLine -- deleting' {
    It 'backspace removes the character before the cursor' {
        $s = Edit-LokiLine -Buffer 'loki' -Cursor 4 -Kind 'backspace'
        $s.Buffer | Should -Be 'lok'
        $s.Cursor | Should -Be 3
    }
    It 'backspace at the start of the line does nothing at all' {
        $s = Edit-LokiLine -Buffer 'loki' -Cursor 0 -Kind 'backspace'
        $s.Buffer | Should -Be 'loki'
        $s.Cursor | Should -Be 0
    }
    It 'Delete removes the character AT the cursor' {
        $s = Edit-LokiLine -Buffer 'loki' -Cursor 1 -Kind 'key' -KeyName 'Delete'
        $s.Buffer | Should -Be 'lki'
        $s.Cursor | Should -Be 1
    }
    It 'Delete at the end of the line does nothing at all' {
        (Edit-LokiLine -Buffer 'loki' -Cursor 4 -Kind 'key' -KeyName 'Delete').Buffer | Should -Be 'loki'
    }
}

Describe 'Edit-LokiLine -- moving' {
    It 'the arrows step, and stop at the ends' {
        (Edit-LokiLine -Buffer 'ab' -Cursor 1 -Kind 'key' -KeyName 'LeftArrow').Cursor  | Should -Be 0
        (Edit-LokiLine -Buffer 'ab' -Cursor 0 -Kind 'key' -KeyName 'LeftArrow').Cursor  | Should -Be 0
        (Edit-LokiLine -Buffer 'ab' -Cursor 1 -Kind 'key' -KeyName 'RightArrow').Cursor | Should -Be 2
        (Edit-LokiLine -Buffer 'ab' -Cursor 2 -Kind 'key' -KeyName 'RightArrow').Cursor | Should -Be 2
    }
    It 'Home and End, and their readline twins' {
        (Edit-LokiLine -Buffer 'loki' -Cursor 3 -Kind 'key' -KeyName 'Home').Cursor | Should -Be 0
        (Edit-LokiLine -Buffer 'loki' -Cursor 1 -Kind 'key' -KeyName 'End').Cursor  | Should -Be 4
        (Edit-LokiLine -Buffer 'loki' -Cursor 3 -Kind 'control' -ControlLetter 'a').Cursor | Should -Be 0
        (Edit-LokiLine -Buffer 'loki' -Cursor 1 -Kind 'control' -ControlLetter 'e').Cursor | Should -Be 4
    }
    It 'the vertical arrows ask for history rather than moving' {
        (Edit-LokiLine -Buffer '' -Cursor 0 -Kind 'key' -KeyName 'UpArrow').Action   | Should -Be 'history-prev'
        (Edit-LokiLine -Buffer '' -Cursor 0 -Kind 'key' -KeyName 'DownArrow').Action | Should -Be 'history-next'
    }
    It 'an unknown named key changes nothing' {
        $s = Edit-LokiLine -Buffer 'loki' -Cursor 2 -Kind 'key' -KeyName 'F7'
        $s.Buffer | Should -Be 'loki'
        $s.Cursor | Should -Be 2
        $s.Action | Should -Be ''
    }
}

Describe 'Edit-LokiLine -- the readline chords' {
    It 'Ctrl+U kills to the start of the line' {
        $s = Edit-LokiLine -Buffer 'loki collect' -Cursor 5 -Kind 'control' -ControlLetter 'u'
        $s.Buffer | Should -Be 'collect'
        $s.Cursor | Should -Be 0
    }
    It 'Ctrl+K kills to the end of the line' {
        (Edit-LokiLine -Buffer 'loki collect' -Cursor 5 -Kind 'control' -ControlLetter 'k').Buffer | Should -Be 'loki '
    }
    It 'Ctrl+W deletes the word behind the cursor' {
        $s = Edit-LokiLine -Buffer 'loki collect' -Cursor 12 -Kind 'control' -ControlLetter 'w'
        $s.Buffer | Should -Be 'loki '
        $s.Cursor | Should -Be 5
    }
    It 'Ctrl+W skips a trailing space first, which is the point of it' {
        # Without the skip, Ctrl+W after a space deletes nothing and feels dead.
        $s = Edit-LokiLine -Buffer 'loki collect ' -Cursor 13 -Kind 'control' -ControlLetter 'w'
        $s.Buffer | Should -Be 'loki '
    }
    It 'Ctrl+W on an empty line does nothing' {
        (Edit-LokiLine -Buffer '' -Cursor 0 -Kind 'control' -ControlLetter 'w').Buffer | Should -Be ''
    }
    It 'Ctrl+C never reaches the editor as an edit' {
        # The two-press exit belongs to the session, which asks Get-LokiExitIntent first. An editor
        # that could end the session would be an editor with a side effect.
        $s = Edit-LokiLine -Buffer 'loki' -Cursor 4 -Kind 'control' -ControlLetter 'c'
        $s.Buffer | Should -Be 'loki'
        $s.Action | Should -Be ''
    }
}

Describe 'Edit-LokiLine -- intents it only names' {
    It 'Escape asks to interrupt, and leaves the line alone' {
        $s = Edit-LokiLine -Buffer 'half typed' -Cursor 4 -Kind 'escape'
        $s.Action | Should -Be 'interrupt'
        $s.Buffer | Should -Be 'half typed' -Because 'interrupting the work is not the same as throwing the line away'
    }
    It 'Tab asks for completion rather than inserting one' {
        (Edit-LokiLine -Buffer 'loki col' -Cursor 8 -Kind 'tab').Action | Should -Be 'complete'
    }
}

Describe 'Edit-LokiLine -- nonsense in, sane out' {
    It 'clamps a cursor that is out of the buffer' {
        (Edit-LokiLine -Buffer 'ab' -Cursor 99 -Kind 'backspace').Buffer | Should -Be 'a'
        (Edit-LokiLine -Buffer 'ab' -Cursor -5 -Kind 'text' -Text 'X').Buffer | Should -Be 'Xab'
    }
    It 'survives a null buffer' {
        $s = Edit-LokiLine -Buffer $null -Cursor 0 -Kind 'text' -Text 'a'
        $s.Buffer | Should -Be 'a'
    }
    It 'ignores a kind it has never heard of' {
        $s = Edit-LokiLine -Buffer 'ab' -Cursor 1 -Kind 'wingding'
        $s.Buffer | Should -Be 'ab'
        $s.Action | Should -Be ''
    }
}

Describe 'Format-LokiLineView' {
    It 'shows a short line whole, with the caret where the cursor is' {
        $v = Format-LokiLineView -Buffer 'loki' -Cursor 2 -Width 20
        $v.Text | Should -Be 'loki'
        $v.CursorColumn | Should -Be 2
        $v.ScrolledLeft  | Should -BeFalse
        $v.ScrolledRight | Should -BeFalse
    }

    It 'scrolls to keep the caret inside a box narrower than the line' {
        # Without this, typing past the right edge either wraps -- destroying the screen's row
        # arithmetic -- or simply vanishes.
        $long = '0123456789abcdefghij'
        $v = Format-LokiLineView -Buffer $long -Cursor 20 -Width 10
        $v.Text.Length | Should -BeLessOrEqual 10
        $v.CursorColumn | Should -BeGreaterOrEqual 0
        $v.CursorColumn | Should -BeLessOrEqual 10
        $v.ScrolledLeft | Should -BeTrue -Because 'the start of the line is off the left edge'
    }

    It 'keeps the caret in view no matter where in a long line it sits' {
        $long = '0123456789abcdefghijKLMNOPQRST'
        for ($c = 0; $c -le $long.Length; $c++) {
            $v = Format-LokiLineView -Buffer $long -Cursor $c -Width 12
            $v.CursorColumn | Should -BeGreaterOrEqual 0 -Because "cursor $c must be visible"
            $v.CursorColumn | Should -BeLessOrEqual 12 -Because "cursor $c must be visible"
        }
    }

    It 'reports that there is more to the right' {
        $v = Format-LokiLineView -Buffer '0123456789abcdef' -Cursor 0 -Width 8
        $v.ScrolledRight | Should -BeTrue
        $v.ScrolledLeft  | Should -BeFalse
    }

    It 'turns a line break into exactly one mark, in all three spellings' {
        # Measured: pasted line breaks arrive as CR. History or a config file may hold LF or CRLF.
        # All three must cost ONE column, or the caret drifts by one per break.
        foreach ($nl in @("`n", "`r", "`r`n")) {
            $v = Format-LokiLineView -Buffer ('a' + $nl + 'b') -Cursor 0 -Width 20 -BreakMark '#'
            $v.Text | Should -Be 'a#b'
        }
    }

    It 'takes the mark from the caller, because it draws nothing itself' {
        # The codebase has three glyph tiers and this file must not pick one. Default is U+00B6,
        # which exists in both code pages measured on the target.
        (Format-LokiLineView -Buffer "a`nb" -Cursor 0 -Width 10).Text | Should -Be ('a' + [string][char]0x00B6 + 'b')
        (Format-LokiLineView -Buffer "a`nb" -Cursor 0 -Width 10 -BreakMark '/').Text | Should -Be 'a/b'
    }

    It 'survives a width of nothing' {
        $v = Format-LokiLineView -Buffer 'loki' -Cursor 2 -Width 0
        $v.Text | Should -Be ''
        $v.CursorColumn | Should -Be 0
    }

    It 'survives an empty buffer' {
        $v = Format-LokiLineView -Buffer '' -Cursor 0 -Width 10
        $v.Text | Should -Be ''
        $v.CursorColumn | Should -Be 0
    }
}

Describe 'Get-LokiLineWordStart' {
    It 'finds the start of the word behind the cursor' {
        Get-LokiLineWordStart -Buffer 'loki collect' -Cursor 12 | Should -Be 5
    }
    It 'skips trailing whitespace before it looks for a word' {
        Get-LokiLineWordStart -Buffer 'loki collect   ' -Cursor 15 | Should -Be 5
    }
    It 'returns 0 at the start, on an empty buffer, and for a line of only spaces' {
        Get-LokiLineWordStart -Buffer 'loki' -Cursor 0 | Should -Be 0
        Get-LokiLineWordStart -Buffer '' -Cursor 0     | Should -Be 0
        Get-LokiLineWordStart -Buffer '     ' -Cursor 5 | Should -Be 0
    }
}

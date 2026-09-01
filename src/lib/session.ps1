# lib/session.ps1 -- the session: a screen, a keyboard and a line editor joined into one loop
# (issue #133, slice 3b).
#
# This file is ASSEMBLY, not invention. Slices 1-3a built and measured the parts:
#   lib/screen.ps1    owns the window and paints it by cell-level difference   (ADR-0036)
#   lib/keyread.ps1   reads one key and says what it means                     (ADR-0037)
#   lib/lineedit.ps1  turns a key into a buffer and a cursor                   (ADR-0038)
# What is left is layout, a transition table, and the order the three are called in -- which is
# exactly why the parts were built first: none of the below is where a bug is expensive.
#
# THE LAYOUT, and two of its three landmark rows are a measurement rather than a taste. A 249 KB
# capture of a real 5.3-minute reference session in a 51-row window shows the input caret at row 49
# (1843 times) and the "Press Ctrl-C again to exit" hint at row 51, column 3. The arithmetic below,
# at Height 51, puts the input row at 49 and the status row at 51 -- and column 3 falls out of it
# too, because it is the first content column inside a border with one space of padding. The notice
# row is the one placement NOT corroborated: the reference's spinner sat at row 45, and nothing in
# the capture says what occupied 46 and 47.
#
#     rows 1 .. H-5   transcript      grows downward, oldest at the top, tail kept when it overflows
#     row H-4         notice          one transient line; blank when there is nothing to say
#     row H-3         input box top
#     row H-2         input row       <- the caret lives here, at column 3
#     row H-1         input box bottom
#     row H           status          which engine is answering, and the keys that change things
#
# Below Height 10 the notice row is dropped, so the transcript is never smaller than the chrome that
# frames it. Below Height 8 or Width 20 nothing is drawn but a message saying so: the screen refuses
# to open under those, but a window can be dragged smaller AFTER it opened, and the honest response
# to that is to say so rather than to paint rubble or to tear the session down.
#
# WHAT THIS FILE DOES NOT DO, and it is the important sentence: it dispatches nothing. A submitted
# line comes back to the caller as an intent with its text, and the caller decides what running it
# means. Dispatch means the allow-list, and the allow-list is a security core that CI holds to
# exactly one entrance (CLAUDE.md sections 5 and 7, single-gate). A session that ran commands itself
# would be that second entrance, whatever its author intended on the day.
#
# Contract. Same split as its three parts: the loop is four console calls thick, and everything else
# is a function a test can drive with no console at all.
#
#   PURE:
#   New-LokiSessionState [-Engine] [-Tier] -> [hashtable]     the whole session, one record
#   Get-LokiSessionChrome -Tier -> [hashtable]                the characters the tier can draw
#   Get-LokiSessionLayout -Height -> [pscustomobject]         which row is what; Ok=$false if none
#   Add-LokiSessionEntry -State -Text                         append to the transcript
#   Format-LokiSessionTranscript -Lines -Width -Rows -> [string[]]   wrapped, tail-kept, exactly Rows
#   Format-LokiSessionStatus -Engine -Hint -Separator -Width -> [string]
#   Format-LokiSessionFrame -State -Width -Height -> @{ Model; CaretRow; CaretCol }
#   Step-LokiSession -State -Key -> @{ Action; Text }         one key applied; MUTATES State
#   Set-LokiSessionHistoryPosition -State -Direction          walks the history; MUTATES State
#
#   IMPURE:
#   Open-LokiSession [-Plain] -> [bool]    screen and keyboard together, or neither
#   Write-LokiSessionFrame -State          hide caret, paint one frame, place and show the caret
#   Invoke-LokiSessionRound -State -> @{ Action; Text }   paint, block for a key, apply it
#   Open-LokiSessionCapture -State / Write-LokiSessionCapture -Write / Close-LokiSessionCapture
#                                          a command's output becomes transcript instead of console (ADR-0040)
#   Close-LokiSession / Test-LokiSessionOpen / Get-LokiSessionRefusal / Initialize-LokiSession
#
# THE STATE IS MUTATED IN PLACE, deliberately, and it is the one place this file departs from
# lib/lineedit.ps1's style. Edit-LokiLine returns a new buffer because a caller may want to fall
# back; a session has nothing to fall back to, and its transcript is an accumulating list that would
# be copied on every keystroke of a machine that is by definition already struggling. Testability is
# untouched -- build a state, feed it keys, assert on it -- and that is the property that mattered.
#
# A [hashtable] parameter is safe to type-constrain here, where the [string[]] in lib/screen.ps1 was
# not. That trap is specific to ARRAYS: binding an Object[] to [string[]] CONVERTS, and converting
# copies, so writes land in a copy and the caller sees nothing. A Hashtable bound to [hashtable] is
# already that type -- the cast is a no-op and the reference survives. Do not "fix" this file to
# match the other one.
Set-StrictMode -Version Latest

# The floors. Below these nothing can be laid out, so nothing is drawn but a message.
#   Height 8   is the smallest window lib/screen.ps1 was measured to work in (63x8, ConPTY regime).
#   Width 20   is a judgement: lib/brand.ps1 refuses to frame anything under 12 columns, and four of
#              those go to the border and its padding, so a box narrower than this is all frame.
$script:LokiSessionMinHeight = 8
$script:LokiSessionMinWidth = 20

# Rows the chrome takes at the bottom, with and without the notice row.
$script:LokiSessionChromeFull = 5
$script:LokiSessionChromeLean = 4

$script:LokiSessionOpen = $false
$script:LokiSessionReason = 'closed'

# The session a running command's output is being captured into, or $null when nothing is being captured.
$script:LokiSessionCaptureState = $null
$script:LokiSessionCapturePaintTicks = 0

# ==============================================================================================
# PURE
# ==============================================================================================

function Get-LokiSessionChrome {
    param([Parameter(Mandatory = $true)][ValidateSet('rich', 'oem', 'ascii')][string]$Tier)
    # PURE. Every character the session draws that is not the operator's own text, resolved ONCE so
    # that no pure function below ever has to ask what the console can render.
    #
    # The non-ascii choices are all characters ROUND-TRIPPED through both DOS code pages a German
    # Windows console actually runs -- CP850 and CP437 -- which is the same constraint that gave
    # lib/brand.ps1 square corners instead of rounded ones (issue #121). Measured 2026-08-31 with
    # Test-LokiEncodingSupport, and the measurement overturned the obvious choice:
    #
    #                       CP850   CP437   CP1252   UTF-8
    #   U+00B6 pilcrow      ok      FAILS   ok       ok       <- rejected
    #   U+00AC not sign     ok      ok      ok       ok       <- BreakMark
    #   U+00B7 middle dot   ok      ok      ok       ok       <- Separator
    #   U+00AB / U+00BB     ok      ok      ok       ok       <- scroll markers
    #
    # The pilcrow is the natural mark for a line break and it is the one that does not survive.
    # CP437 has a pilcrow GLYPH at 0x14, which is what ADR-0038 and lib/lineedit.ps1 originally
    # cited -- but .NET maps 0x14 to U+0014, the control character, so the round trip comes back
    # changed and the console shows something else. A glyph in a code-page chart is not the same
    # claim as a character an encoder will produce, and only the round trip can tell them apart.
    #
    # BreakMark stands in for a line break inside the one-line input box. It is ambiguous with a
    # pasted copy of the same character -- unavoidably, in any tier. The display is lossy; the
    # BUFFER keeps exactly what was pasted, which is what makes the ambiguity survivable rather than
    # a lie, and the notice that refuses a multi-line submission names the mark so the operator
    # knows which character to look for.
    if ($Tier -eq 'ascii') {
        return @{
            BreakMark   = '\'
            Separator   = ' - '
            ScrollLeft  = '<'
            ScrollRight = '>'
            Echo        = '> '
        }
    }
    return @{
        BreakMark   = [string][char]0x00AC
        Separator   = ' ' + [string][char]0x00B7 + ' '
        ScrollLeft  = [string][char]0x00AB
        ScrollRight = [string][char]0x00BB
        Echo        = '> '
    }
}

function New-LokiSessionState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure construction of an in-memory record; nothing outside the return value changes. -WhatIf would hand back a session that does not exist.')]
    param(
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Engine = '',
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Tier = ''
    )
    # PURE. The whole session in one record. Tier defaults through Get-LokiGlyphTier the same way
    # Write-LokiBrand does -- resolved in the BODY, never in a param() default, because module state
    # and $PSScriptRoot are both empty in a 5.1 param default (CLAUDE.md section 1).
    $t = $Tier
    if ([string]::IsNullOrEmpty($t)) { $t = Get-LokiGlyphTier }

    return @{
        Buffer       = ''
        Cursor       = 0
        # Armed is the FIRST press of Ctrl+C. It lives in the session and not in the editor on
        # purpose: an editor that could end a session would be an editor with a side effect
        # (ADR-0038), so the session asks Get-LokiExitIntent before the key reaches the editor.
        Armed        = $false
        Lines        = (New-Object System.Collections.Generic.List[string])
        History      = (New-Object System.Collections.Generic.List[string])
        # Count means "not browsing". Anything less is an index into History.
        HistoryIndex = 0
        # What was half-typed when the operator started walking back through history, so that
        # walking forward again returns it instead of an empty line.
        HistoryDraft = ''
        Notice       = ''
        Engine       = $Engine
        Tier         = $t
        Chrome       = (Get-LokiSessionChrome -Tier $t)
    }
}

function Get-LokiSessionLayout {
    param([Parameter(Mandatory = $true)][int]$Height)
    # PURE. Which row is what, 0-based, -1 for a row this height cannot afford. See the diagram at
    # the top of the file.
    #
    # The notice row is the first thing dropped, and the rule for dropping it is that the transcript
    # must never be smaller than the chrome framing it. At Height 10 the full layout leaves 5
    # transcript rows against 5 chrome rows; below that the notice goes, and the lean layout leaves 4
    # against 4 at the floor. A session whose chrome outgrows its content has stopped being a session
    # and become a form.
    if ($Height -lt $script:LokiSessionMinHeight) {
        return [pscustomobject]@{
            Ok             = $false
            TranscriptTop  = 0
            TranscriptRows = 0
            NoticeRow      = -1
            BoxTop         = -1
            InputRow       = -1
            BoxBottom      = -1
            StatusRow      = -1
        }
    }

    $chrome = $script:LokiSessionChromeFull
    if ($Height -lt 10) { $chrome = $script:LokiSessionChromeLean }

    $notice = -1
    if ($chrome -eq $script:LokiSessionChromeFull) { $notice = $Height - 5 }

    return [pscustomobject]@{
        Ok             = $true
        TranscriptTop  = 0
        TranscriptRows = $Height - $chrome
        NoticeRow      = $notice
        BoxTop         = $Height - 4
        InputRow       = $Height - 3
        BoxBottom      = $Height - 2
        StatusRow      = $Height - 1
    }
}

function Add-LokiSessionEntry {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][hashtable]$State,
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$Text
    )
    # PURE in effect: appends to the caller's own list, nothing else. Newlines are split HERE rather
    # than at render time, so the transcript holds LINES -- a caller handing over a multi-line block
    # of command output should not have to know how this file wraps.
    if ($null -eq $State) { return }
    $t = $Text
    if ($null -eq $t) { $t = '' }
    foreach ($line in ($t -split "`r`n|`n|`r")) { $State.Lines.Add([string]$line) }
}

function Format-LokiSessionTranscript {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][AllowNull()][string[]]$Lines,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Rows
    )
    # PURE. Exactly $Rows strings, oldest at the top, newest at the bottom, blank-padded at the END
    # so a fresh session starts at the top of the window like a terminal rather than floating in the
    # middle of it.
    #
    # Long lines WRAP, they are not truncated. A transcript that silently drops the right-hand end of
    # a path or an error code is worse than one that takes two rows: the operator is here because
    # something is already wrong, and the part that got cut is the part they needed.
    #
    # $Lines is only READ, so a [string[]] constraint is safe here -- see the note at the top of the
    # file about where that is and is not true.
    if ($Rows -lt 1 -or $Width -lt 1) { return @() }

    $visual = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Lines) {
        foreach ($line in $Lines) {
            $t = [string]$line
            if ($null -eq $t) { $t = '' }
            if ($t.Length -eq 0) {
                # An empty line is one empty ROW, not zero rows. Dropping it would silently close the
                # gaps a caller put in on purpose.
                $visual.Add('')
                continue
            }
            $i = 0
            while ($i -lt $t.Length) {
                $take = [math]::Min($Width, $t.Length - $i)
                $visual.Add($t.Substring($i, $take))
                $i += $take
            }
        }
    }

    $out = New-Object System.Collections.Generic.List[string]
    if ($visual.Count -gt $Rows) {
        for ($i = $visual.Count - $Rows; $i -lt $visual.Count; $i++) { $out.Add($visual[$i]) }
    }
    else {
        foreach ($v in $visual) { $out.Add($v) }
        while ($out.Count -lt $Rows) { $out.Add('') }
    }
    return $out.ToArray()
}

function Format-LokiSessionStatus {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$Engine,
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$Hint,
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$Separator,
        [Parameter(Mandatory = $true)][int]$Width
    )
    # PURE. The always-visible row, and ADR-0038 settled what goes on it: capability and steering,
    # never the environment. Which engine is answering RIGHT NOW genuinely changes mid-session --
    # free some memory and the offline agent becomes available -- which is why #133 recomputes state
    # every round. The stick path does not change, and would eat the width this needs.
    #
    # The engine is dropped before the hint when the row is too narrow for both: the hint tells the
    # operator how to get OUT, and a row with room for only one of the two should carry that one.
    if ($Width -lt 1) { return '' }
    $e = $Engine
    if ($null -eq $e) { $e = '' }
    $h = $Hint
    if ($null -eq $h) { $h = '' }
    $s = $Separator
    if ($null -eq $s) { $s = ' ' }

    $full = $h
    if ($e.Length -gt 0) { $full = $e + $s + $h }
    if ($full.Length -le $Width) { return $full }
    if ($h.Length -le $Width) { return $h }
    return $h.Substring(0, $Width)
}

function Format-LokiSessionFrame {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][hashtable]$State,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height
    )
    # PURE. State plus a geometry in; one paintable frame plus the caret's home out. The model comes
    # back as Object[] -- Initialize-LokiScreenModel's own shape -- because Write-LokiScreenFrame
    # takes it untyped, for exactly the reason lib/screen.ps1's header gives at length.
    #
    # NO COLOUR ANYWHERE IN THE MODEL, and that is a constraint rather than a preference:
    # Get-LokiScreenDiff finds the changed span of a row by comparing it CHARACTER BY CHARACTER, so
    # an escape sequence embedded in a row would be counted as content and every column after it
    # placed wrong. Emphasis in the transcript has to come from characters -- the echo marker, the
    # box -- or from a later change to the diff that understands attributes.
    # @(...) and not a bare assignment. A `return` in Initialize-LokiScreenModel unrolls, so a
    # ONE-ROW model comes back as a bare string -- and then Write-LokiScreenCell refuses it (its
    # -is [array] guard) and Test-LokiScreenModelShape calls the frame misshapen, both silently and
    # both correct about what they were handed. Fixing it there instead was tried on 2026-08-31 and
    # reverted: the unrolling is load-bearing in that file, and the note at that function says why.
    # A one-row window never reaches a real session -- the screen refuses below 8 -- but a frame
    # builder that only works above a threshold is a frame builder waiting for the resize that
    # crosses it.
    $model = @(Initialize-LokiScreenModel -Width $Width -Height $Height)
    $layout = Get-LokiSessionLayout -Height $Height

    if (-not $layout.Ok -or $Width -lt $script:LokiSessionMinWidth) {
        # Too small to lay out. Say so, on whatever row exists, rather than paint rubble or tear the
        # session down -- the window can be dragged back, and a session that quit because somebody
        # resized it would have thrown away work over a reversible mistake.
        $msg = Get-LokiText 'session.window.tooSmall' -ArgumentList @($script:LokiSessionMinWidth, $script:LokiSessionMinHeight)
        Write-LokiScreenCell -Model $model -Row 0 -Col 0 -Text $msg
        return [pscustomobject]@{ Model = $model; CaretRow = 0; CaretCol = 0 }
    }

    # A state is optional so that a refusal or an early frame can still be drawn. Everything the
    # frame needs is read once, here, with a drawable default.
    $buffer = ''
    $cursor = 0
    $notice = ''
    $engine = ''
    $armed = $false
    $tier = 'ascii'
    $chrome = Get-LokiSessionChrome -Tier 'ascii'
    $lines = @()
    if ($null -ne $State) {
        $buffer = [string]$State.Buffer
        $cursor = [int]$State.Cursor
        $notice = [string]$State.Notice
        $engine = [string]$State.Engine
        $armed = [bool]$State.Armed
        $tier = [string]$State.Tier
        $chrome = $State.Chrome
        $lines = @($State.Lines.ToArray())
    }

    # --- transcript ---
    $rows = @(Format-LokiSessionTranscript -Lines $lines -Width $Width -Rows $layout.TranscriptRows)
    for ($i = 0; $i -lt $rows.Count; $i++) {
        Write-LokiScreenCell -Model $model -Row ($layout.TranscriptTop + $i) -Col 0 -Text $rows[$i]
    }

    # --- notice ---
    if ($layout.NoticeRow -ge 0 -and $notice.Length -gt 0) {
        Write-LokiScreenCell -Model $model -Row $layout.NoticeRow -Col 0 -Text $notice
    }

    # --- input box ---
    # Reuses lib/brand.ps1's frame rather than drawing a second one. That is not thrift: the footer
    # from #131 and the mascot's own head are already those six characters, and a third style bolted
    # on here would read as two tools sharing a window (CLAUDE.md section 2, one source of truth).
    $view = Format-LokiLineView -Buffer $buffer -Cursor $cursor -Width ($Width - 4) -BreakMark $chrome.BreakMark
    $box = @(Get-LokiBoxArt -Tier $tier -Lines @($view.Text) -Width $Width)
    if ($box.Count -eq 3) {
        Write-LokiScreenCell -Model $model -Row $layout.BoxTop -Col 0 -Text $box[0]
        Write-LokiScreenCell -Model $model -Row $layout.InputRow -Col 0 -Text $box[1]
        Write-LokiScreenCell -Model $model -Row $layout.BoxBottom -Col 0 -Text $box[2]
    }

    # The scroll markers sit in the border's PADDING columns, not in the content, so a line long
    # enough to scroll does not also become one character narrower for saying so.
    if ($view.ScrolledLeft) {
        Write-LokiScreenCell -Model $model -Row $layout.InputRow -Col 1 -Text $chrome.ScrollLeft
    }
    if ($view.ScrolledRight) {
        Write-LokiScreenCell -Model $model -Row $layout.InputRow -Col ($Width - 2) -Text $chrome.ScrollRight
    }

    # --- status ---
    # When Ctrl+C is armed the warning REPLACES the standing hint rather than joining it. Measured in
    # the reference: it draws the warning at column 3 of the hint row and follows it with ESC[K,
    # which erases to end of line -- so the row carries one message, never two.
    if ($armed) {
        $status = Format-LokiSessionStatus -Engine '' -Hint (Get-LokiText 'session.status.armed') -Separator $chrome.Separator -Width $Width
    }
    else {
        $status = Format-LokiSessionStatus -Engine $engine -Hint (Get-LokiText 'session.status.hint') -Separator $chrome.Separator -Width $Width
    }
    Write-LokiScreenCell -Model $model -Row $layout.StatusRow -Col 0 -Text $status

    # Column 2, 0-based, is the first content column inside a border of one character plus one space
    # of padding -- and it is where the reference parks its caret: ESC[49;3H, 1-based, in the capture.
    return [pscustomobject]@{
        Model    = $model
        CaretRow = $layout.InputRow
        CaretCol = 2 + [int]$view.CursorColumn
    }
}

function Set-LokiSessionHistoryPosition {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Moves a cursor inside the caller''s own in-memory record; there is no external state to gate, and -WhatIf would report a move that did not happen while the next keystroke edited the wrong line.')]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][hashtable]$State,
        [Parameter(Mandatory = $true)][ValidateSet('history-prev', 'history-next')][string]$Direction
    )
    # PURE in effect. History belongs to the SESSION, not to the editor: lib/lineedit.ps1 names the
    # intent and stops there, because a list of past commands is not something a line editor has any
    # business owning (ADR-0038).
    #
    # HistoryIndex == History.Count means "not browsing". Stepping back off the end of the list does
    # nothing rather than wrapping round -- wrapping puts the oldest command under the operator's
    # fingers at the exact moment they expected the newest.
    if ($null -eq $State) { return }
    $count = $State.History.Count
    if ($count -eq 0) { return }

    if ($Direction -eq 'history-prev') {
        if ($State.HistoryIndex -le 0) { return }
        if ($State.HistoryIndex -ge $count) {
            # First step back. Keep whatever was half-typed, so stepping forward again returns it
            # instead of an empty line -- losing it is the thing that makes people stop using history
            # at all.
            $State.HistoryDraft = [string]$State.Buffer
        }
        $State.HistoryIndex = $State.HistoryIndex - 1
    }
    else {
        if ($State.HistoryIndex -ge $count) { return }
        $State.HistoryIndex = $State.HistoryIndex + 1
    }

    if ($State.HistoryIndex -ge $count) { $State.Buffer = [string]$State.HistoryDraft }
    else { $State.Buffer = [string]$State.History[$State.HistoryIndex] }
    $State.Cursor = $State.Buffer.Length
}

function Step-LokiSession {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][hashtable]$State,
        [Parameter(Mandatory = $true)][AllowNull()]$Key
    )
    # One key applied to the session. MUTATES $State (see the note at the top of the file) and
    # returns only what the CALLER has to act on:
    #
    #   ''          nothing to do; repaint and read the next key
    #   'submit'    the operator pressed Enter on a line; Text is that line
    #   'interrupt' Escape -- stop whatever is running, keep the session
    #   'exit'      the second Ctrl+C
    #
    # Escape and Ctrl+C are different keys with different jobs, copied from the reference on purpose
    # (ADR-0037). One press of Ctrl+C exiting is the terminal norm and this breaks it deliberately: a
    # session holds a diagnosis in progress, and a reflex keystroke must not throw it away.
    if ($null -eq $State -or $null -eq $Key) { return [pscustomobject]@{ Action = ''; Text = '' } }

    # A notice lives for exactly one keystroke. Left standing it would look like a fresh answer to
    # whatever the operator just did, which is how a stale message becomes a wrong one.
    $State.Notice = ''

    # BEFORE the editor, always. Get-LokiExitIntent also disarms on every other key, which is the
    # safer of the two readings the capture allows -- it recorded only the reference's output, so it
    # cannot say whether that disarm is on a keystroke or on a timer, and a Ctrl+C from ten minutes
    # ago must not end the session on the next one.
    $intent = Get-LokiExitIntent -Kind $Key.Kind -ControlLetter $Key.ControlLetter -Armed ([bool]$State.Armed)
    $State.Armed = [bool]$intent.Armed
    if ($intent.Exit) { return [pscustomobject]@{ Action = 'exit'; Text = '' } }
    if ($Key.Kind -eq 'control' -and $Key.ControlLetter -eq 'c') {
        # Now armed. The status row says so; nothing else happens, and the key does NOT reach the
        # editor -- lib/lineedit.ps1 has no Ctrl+C handler precisely so this stays its only owner.
        return [pscustomobject]@{ Action = ''; Text = '' }
    }

    $edit = Edit-LokiLine -Buffer $State.Buffer -Cursor $State.Cursor `
        -Kind $Key.Kind -Text $Key.Text -KeyName $Key.Key -ControlLetter $Key.ControlLetter `
        -Source $Key.Source -MoreWaiting ([bool]$Key.MoreWaiting)
    $State.Buffer = [string]$edit.Buffer
    $State.Cursor = [int]$edit.Cursor

    if ($edit.Action -eq 'interrupt') { return [pscustomobject]@{ Action = 'interrupt'; Text = '' } }

    if ($edit.Action -eq 'complete') {
        $State.Notice = Get-LokiText 'session.notice.completeUnavailable'
        return [pscustomobject]@{ Action = ''; Text = '' }
    }

    if ($edit.Action -eq 'history-prev' -or $edit.Action -eq 'history-next') {
        Set-LokiSessionHistoryPosition -State $State -Direction $edit.Action
        return [pscustomobject]@{ Action = ''; Text = '' }
    }

    if ($edit.Action -eq 'submit') {
        $text = [string]$State.Buffer
        $State.Buffer = ''
        $State.Cursor = 0

        # An empty Enter is a blank prompt, not a command. Every shell does this, and an operator
        # pressing Enter to get some breathing room would otherwise be told off for it.
        if ($text.Trim().Length -eq 0) { return [pscustomobject]@{ Action = ''; Text = '' } }

        if ($text.Contains("`n") -or $text.Contains("`r")) {
            # ADR-0038 left this decision to the session, and refusing is the honest answer. Running
            # only the first line would be silently wrong; running each line in turn is exactly the
            # accident the paste-aware Enter rule exists to prevent, and a machine somebody brought
            # in broken is the worst place to guess.
            #
            # The buffer is handed BACK, not discarded: refusing the submission and also throwing
            # away what they pasted would be two punishments for one mistake.
            $State.Notice = Get-LokiText 'session.notice.multiline' -ArgumentList @($State.Chrome.BreakMark)
            $State.Buffer = $text
            $State.Cursor = $text.Length
            return [pscustomobject]@{ Action = ''; Text = '' }
        }

        Add-LokiSessionEntry -State $State -Text ([string]$State.Chrome.Echo + $text)
        # Consecutive duplicates are not stored, which is what makes walking back through history
        # useful after running the same command twice while chasing something.
        if ($State.History.Count -eq 0 -or $State.History[$State.History.Count - 1] -ne $text) {
            $State.History.Add($text)
        }
        $State.HistoryIndex = $State.History.Count
        $State.HistoryDraft = ''
        return [pscustomobject]@{ Action = 'submit'; Text = $text }
    }

    return [pscustomobject]@{ Action = ''; Text = '' }
}

# ==============================================================================================
# IMPURE. Four console calls, every one of them borrowed from lib/screen.ps1 and lib/keyread.ps1.
# ==============================================================================================

function Test-LokiSessionOpen { return $script:LokiSessionOpen }

function Get-LokiSessionRefusal { return [string]$script:LokiSessionReason }

function Initialize-LokiSession {
    # Back to the state a fresh process starts in, matching Initialize-LokiUi / Initialize-LokiRegion
    # / Initialize-LokiScreen / Initialize-LokiKeyread.
    Close-LokiSession
    $script:LokiSessionReason = 'closed'
}

function Open-LokiSession {
    param([switch]$Plain)
    # Both halves or neither, and the reason is not tidiness. A session that can paint but cannot
    # read keys is a picture; one that can read keys but cannot paint is a prompt with no output.
    # Opening them separately would let the CLI reach either half-state and then have to describe it
    # to somebody, and there is nothing useful to say.
    #
    # $false is a NORMAL answer -- under redirection, in CI, without VT, on a tiny window, and
    # whenever the operator passed --plain. The refusal carries WHICH half said no and why, because
    # "the session did not start" is not something an operator can act on.
    Close-LokiSession

    if (-not (Open-LokiScreen -Plain:$Plain)) {
        $script:LokiSessionReason = 'screen:' + (Get-LokiScreenRefusal)
        return $false
    }
    if (-not (Open-LokiKeyread)) {
        Close-LokiScreen
        $script:LokiSessionReason = 'keyread:' + (Get-LokiKeyreadRefusal)
        return $false
    }

    $script:LokiSessionOpen = $true
    $script:LokiSessionReason = 'ok'
    return $true
}

function Write-LokiSessionFrame {
    param([Parameter(Mandatory = $true)][AllowNull()][hashtable]$State)
    # One frame, fenced exactly the way the reference fences each of its 1836: hide the caret, paint,
    # then move and show it in a single write. Three console writes, and that is the reference's own
    # shape -- the flicker measurement said what tears a frame is the number of writes for the SAME
    # content, not three small ones that each do a different job.
    if (-not (Test-LokiScreenOpen)) { return }
    $size = Get-LokiScreenSize
    if ($size.Width -lt 1 -or $size.Height -lt 1) { return }

    $frame = Format-LokiSessionFrame -State $State -Width $size.Width -Height $size.Height
    [void](Hide-LokiScreenCaret)
    Write-LokiScreenFrame -Model $frame.Model
    [void](Show-LokiScreenCaret -Row $frame.CaretRow -Col $frame.CaretCol)
}

function Invoke-LokiSessionRound {
    param([Parameter(Mandatory = $true)][AllowNull()][hashtable]$State)
    # ONE round: paint what the state says, block for a key, apply it. The caller loops on the
    # Action, and 'closed' means the console went away underneath -- a caller that ignored it would
    # spin.
    if ($null -eq $State -or -not $script:LokiSessionOpen) {
        return [pscustomobject]@{ Action = 'closed'; Text = '' }
    }

    Write-LokiSessionFrame -State $State
    $key = Read-LokiKey
    if ($null -eq $key) { return [pscustomobject]@{ Action = 'closed'; Text = '' } }

    # AFTER the read, and it can only be here. Nothing announces a resize -- measured for ADR-0037:
    # dragging 209x51 down to 75x30 while a read was pending returned normally, and the new size
    # appeared only once ReadKey came back. So the moment a key arrives is the only moment the
    # session learns its window changed, and it must learn it before the next frame is laid out
    # against a geometry that no longer exists.
    [void](Resize-LokiScreen)

    return Step-LokiSession -State $State -Key $key
}

function Write-LokiSessionCapture {
    param([Parameter(Mandatory = $true)][AllowNull()][hashtable]$Write)
    # What lib/ui.ps1's sink hands over while a command runs inside the session (ADR-0040). A command's ordinary
    # output cannot reach the console -- it would land wherever the cursor happens to be and corrupt every
    # subsequent frame -- so it is turned into transcript instead.
    #
    # Two kinds of write, and telling them apart is the whole job:
    #   a LINE     -> a transcript entry. Permanent, scrolls up, stays readable.
    #   NO NEWLINE -> progress. The spinner rewinds its own line with a carriage return and rewrites it several
    #                 times a second; one transcript row per frame would bury everything else. It goes to the
    #                 notice row, which is exactly what the reference does with its own spinner row.
    #
    # The repaint is RATE-LIMITED, the append never is. Dropping a frame costs nothing -- the next write, or the
    # frame drawn when the command finishes, shows everything -- while dropping a line would lose output. The limit
    # is Test-LokiSpinnerDue from lib/brand.ps1 rather than a second threshold of this file's own: "is a redraw
    # due" already has one answer in this codebase and should not grow a second (CLAUDE.md section 2).
    if ($null -eq $script:LokiSessionCaptureState -or $null -eq $Write) { return }
    $state = $script:LokiSessionCaptureState

    $text = [string]$Write.Text
    if ($null -eq $text) { $text = '' }

    if ([bool]$Write.NoNewline) {
        # Strip the carriage returns the spinner rewinds with; a one-row notice does not need them. An all-blank
        # progress write is the spinner clearing its own line, and it clears the notice with it.
        $state.Notice = $text.Replace("`r", '').Replace("`n", ' ').Trim()
    }
    else {
        # No marker is added for the 'err' stream, and that is checked rather than assumed: Write-LokiWarn and
        # Write-LokiErr prefix "! " and "x " THEMSELVES before calling Write-LokiToStdErr, so the text arriving here
        # already carries it. A second one would print "x x failed". Colour could not survive into a screen model
        # in any case (see the note in Format-LokiSessionFrame), so a character is the only distinction available --
        # and it is already there.
        Add-LokiSessionEntry -State $state -Text $text
    }

    $now = [datetime]::UtcNow.Ticks
    if (Test-LokiSpinnerDue -LastTicks $script:LokiSessionCapturePaintTicks -NowTicks $now) {
        $script:LokiSessionCapturePaintTicks = $now
        Write-LokiSessionFrame -State $state
    }
}

function Open-LokiSessionCapture {
    param([Parameter(Mandatory = $true)][AllowNull()][hashtable]$State)
    # Everything a command prints from here until Close-LokiSessionCapture becomes transcript instead of console.
    #
    # A PLAIN scriptblock, deliberately NOT one built with .GetNewClosure(). A closure gets its own module scope,
    # and dot-sourced functions are invisible from inside it -- so a closure that captured the state could not call
    # Add-LokiSessionEntry at all. Measured 2026-08-31, and it fails the same way in the dispatcher as in a test,
    # because Loki dot-sources every lib into one script scope rather than importing modules. A plain scriptblock
    # keeps THIS file's session state, so the call below resolves; the state it needs travels in a script variable
    # rather than in a capture.
    $script:LokiSessionCaptureState = $State
    $script:LokiSessionCapturePaintTicks = 0
    Register-LokiWriteSink -Sink { param([hashtable]$LokiWrite) Write-LokiSessionCapture -Write $LokiWrite }
}

function Close-LokiSessionCapture {
    # Callers MUST reach this from a finally. A sink left registered after the command that owns it has finished
    # would swallow every later line of output -- including the dispatcher's own error path -- into a transcript
    # nobody is drawing any more.
    $script:LokiSessionCaptureState = $null
    Register-LokiWriteSink -Sink $null
}

function Close-LokiSession {
    # Idempotent, and it closes both halves even if only one was open -- it is called from the
    # dispatcher's finally block, which exists precisely for the paths nobody planned.
    $script:LokiSessionOpen = $false
    $script:LokiSessionReason = 'closed'
    Close-LokiKeyread
    Close-LokiScreen
}

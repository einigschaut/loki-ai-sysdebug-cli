# lib/lineedit.ps1 -- the input line: what a key does to a buffer and a cursor (issue #133, slice 3a).
#
# ENTIRELY PURE. Not a console call in the file, not one. That is the point of splitting it out of
# the session loop: a line editor is nothing but edge cases -- word deletion at a boundary, Home on
# an empty line, a paste that contains newlines, a cursor that must stay inside a box narrower than
# the text -- and every one of them is cheap to test here and nearly impossible to test through a
# loop that owns a screen.
#
#   Edit-LokiLine -Buffer -Cursor -Kind -Text -KeyName -ControlLetter -Source -MoreWaiting
#       -> @{ Buffer; Cursor; Action }
#   Format-LokiLineView -Buffer -Cursor -Width [-BreakMark]
#       -> @{ Text; CursorColumn; ScrolledLeft; ScrolledRight }
#   Get-LokiLineWordStart -Buffer -Cursor -> [int]
#   Test-LokiLineInsertable -Text -> [bool]
#
# Action is an INTENT, never an act: 'submit', 'interrupt', 'history-prev', 'history-next',
# 'complete' or ''. History and completion need lists this file has no business owning, so it names
# what the operator asked for and the session decides what that means.
#
# THE ENTER RULE, and it is the whole reason slice 2 measured what it measured.
#
# A pasted block arrives as ordinary keystrokes -- there is no bracketed paste at this layer -- so a
# three-line paste contains two Enter keys, and a naive editor fires two commands the operator never
# typed. But refusing every pasted Enter is wrong too: pasting one command with a trailing newline
# is the single most common paste there is, and it should just run.
#
# Both are decided by one measured signal:
#
#     Enter submits        when it was typed, OR when it is the LAST key of a burst
#     Enter inserts a line when it is a pasted Enter with more keys already waiting behind it
#
#   "loki hwscan<CR>"   -> the CR is last, nothing waiting  -> submits. What the operator meant.
#   "a<CR>b<CR>c"       -> both CRs have keys waiting        -> two line breaks, nothing runs.
#
# Measured: the next key was already waiting for 59 of 61 pasted characters and 0 of 23 keystrokes,
# and the two exceptions are exactly the first (no predecessor) and the last (nothing follows).
Set-StrictMode -Version Latest

# What a line break looks like INSIDE the buffer. Stored as a real newline so nothing is silently
# altered -- the operator gets back exactly what they pasted -- and rendered as a visible mark by
# Format-LokiLineView, because a single-line box cannot show a line break any other way. Showing it
# is what lets them see what happened and delete it.
$script:LokiLineBreak = "`n"

function Test-LokiLineInsertable {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$Text)
    # PURE. A character may go into the buffer if it is a character. Control codes are cursor motion
    # in disguise and would make the buffer's length disagree with what is drawn; surrogate halves
    # are half a character and cannot survive an index.
    #
    # NOT rejected: characters that occupy two console cells. The measured input set is CP850 text on
    # a German layout, where every character is one cell, and refusing more than that would refuse
    # scripts nobody here has tried. The stated consequence: type a full-width character and the
    # cursor sits one cell off. Known and bounded, rather than silently wrong.
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int][char]$ch
        if ($code -lt 32 -or $code -eq 127) { return $false }
        if ([char]::IsSurrogate($ch)) { return $false }
    }
    return $true
}

function Get-LokiLineWordStart {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$Buffer,
        [Parameter(Mandatory = $true)][int]$Cursor
    )
    # PURE. Where Ctrl+W deletes back to: skip the whitespace immediately behind the cursor, then
    # skip the word behind that. Standard readline behaviour, and it is what makes Ctrl+W useful
    # after a trailing space instead of deleting nothing.
    if ([string]::IsNullOrEmpty($Buffer)) { return 0 }
    $i = [math]::Min($Cursor, $Buffer.Length)
    if ($i -le 0) { return 0 }
    while ($i -gt 0 -and [char]::IsWhiteSpace($Buffer[$i - 1])) { $i-- }
    while ($i -gt 0 -and -not [char]::IsWhiteSpace($Buffer[$i - 1])) { $i-- }
    return $i
}

function Edit-LokiLine {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$Buffer,
        [Parameter(Mandatory = $true)][int]$Cursor,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Kind,
        [Parameter(Mandatory = $false)][AllowEmptyString()][AllowNull()][string]$Text = '',
        [Parameter(Mandatory = $false)][AllowEmptyString()][AllowNull()][string]$KeyName = '',
        [Parameter(Mandatory = $false)][AllowEmptyString()][AllowNull()][string]$ControlLetter = '',
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Source = 'typing',
        [Parameter(Mandatory = $false)][bool]$MoreWaiting = $false
    )
    # PURE. One key in, a whole new state out -- nothing is mutated, so a caller can always fall back
    # to what it had. Kind / Text / KeyName / ControlLetter / Source / MoreWaiting are exactly the
    # fields Read-LokiKey produces, taken apart rather than passed as an object so that a test can
    # write one line per case.
    $buf = $Buffer
    if ($null -eq $buf) { $buf = '' }
    $cur = $Cursor
    if ($cur -lt 0) { $cur = 0 }
    if ($cur -gt $buf.Length) { $cur = $buf.Length }
    $action = ''

    if ($Kind -eq 'text') {
        if (Test-LokiLineInsertable -Text $Text) {
            $buf = $buf.Substring(0, $cur) + $Text + $buf.Substring($cur)
            $cur = $cur + $Text.Length
        }
    }
    elseif ($Kind -eq 'enter') {
        # See THE ENTER RULE at the top of this file.
        if ($Source -eq 'paste' -and $MoreWaiting) {
            $buf = $buf.Substring(0, $cur) + $script:LokiLineBreak + $buf.Substring($cur)
            $cur = $cur + 1
        }
        else {
            $action = 'submit'
        }
    }
    elseif ($Kind -eq 'backspace') {
        if ($cur -gt 0) {
            $buf = $buf.Substring(0, $cur - 1) + $buf.Substring($cur)
            $cur--
        }
    }
    elseif ($Kind -eq 'escape') {
        $action = 'interrupt'
    }
    elseif ($Kind -eq 'tab') {
        $action = 'complete'
    }
    elseif ($Kind -eq 'key') {
        # Keys that carry no character at all -- measured: UpArrow, DownArrow, Home, End, Delete all
        # arrive with KeyChar 0, so the name is the only thing to dispatch on.
        if     ($KeyName -eq 'LeftArrow')  { if ($cur -gt 0) { $cur-- } }
        elseif ($KeyName -eq 'RightArrow') { if ($cur -lt $buf.Length) { $cur++ } }
        elseif ($KeyName -eq 'Home')       { $cur = 0 }
        elseif ($KeyName -eq 'End')        { $cur = $buf.Length }
        elseif ($KeyName -eq 'UpArrow')    { $action = 'history-prev' }
        elseif ($KeyName -eq 'DownArrow')  { $action = 'history-next' }
        elseif ($KeyName -eq 'Delete')     { if ($cur -lt $buf.Length) { $buf = $buf.Substring(0, $cur) + $buf.Substring($cur + 1) } }
    }
    elseif ($Kind -eq 'control') {
        # Readline's chords, because a technician's fingers already know them. Ctrl+A, Ctrl+U and
        # Ctrl+W were measured arriving as 1, 21 and 23; Ctrl+E and Ctrl+K are the same mechanism at
        # 5 and 11 and are handled by the same rule, which is inference, not measurement.
        #
        # Ctrl+C is deliberately absent. The two-press exit belongs to the session, which asks
        # Get-LokiExitIntent before it ever reaches the editor -- an editor that could end the
        # session would be an editor with a side effect.
        if     ($ControlLetter -eq 'a') { $cur = 0 }
        elseif ($ControlLetter -eq 'e') { $cur = $buf.Length }
        elseif ($ControlLetter -eq 'u') { $buf = $buf.Substring($cur); $cur = 0 }
        elseif ($ControlLetter -eq 'k') { $buf = $buf.Substring(0, $cur) }
        elseif ($ControlLetter -eq 'w') {
            $start = Get-LokiLineWordStart -Buffer $buf -Cursor $cur
            $buf = $buf.Substring(0, $start) + $buf.Substring($cur)
            $cur = $start
        }
    }

    return [pscustomobject]@{
        Buffer = $buf
        Cursor = $cur
        Action = $action
    }
}

function Format-LokiLineView {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$Buffer,
        [Parameter(Mandatory = $true)][int]$Cursor,
        [Parameter(Mandatory = $true)][int]$Width,
        # The mark that stands in for a line break. A PARAMETER, because this file draws nothing and
        # must not pick a glyph: the codebase has three glyph tiers and the caller knows which one is
        # live. The default is U+00B6, which exists in BOTH code pages measured on the target (CP850
        # at 0xF4, CP437 at 0x14); an ascii-tier caller passes something else.
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$BreakMark = ([string][char]0x00B6)
    )
    # PURE. What the box actually shows, and where the caret goes inside it.
    #
    # A command line outgrows its box, and the box cannot grow. So the view scrolls horizontally and
    # keeps the cursor inside it, exactly like every shell prompt -- without this, typing past the
    # right edge either wraps (destroying the screen's row arithmetic) or vanishes.
    #
    # ScrolledLeft / ScrolledRight say whether text is hidden on either side. The caller can draw a
    # marker; nothing here decides what that marker looks like, because that is a glyph tier
    # question and this file draws nothing.
    if ($Width -lt 1) {
        return [pscustomobject]@{ Text = ''; CursorColumn = 0; ScrolledLeft = $false; ScrolledRight = $false }
    }
    $buf = $Buffer
    if ($null -eq $buf) { $buf = '' }

    # Line breaks become one visible character. The buffer keeps the real newline -- nothing the
    # operator pasted is altered -- but a single-line box has no other way to show it, and showing
    # it is what lets them see it and delete it.
    # All three forms become ONE mark. CRLF first, or it would be counted twice and the cursor
    # arithmetic below would drift by a column for every pasted line break.
    $mark = $BreakMark
    if ([string]::IsNullOrEmpty($mark)) { $mark = ' ' }
    $mark = [string]$mark[0]
    $shown = $buf.Replace("`r`n", $mark).Replace("`n", $mark).Replace("`r", $mark)

    $cur = $Cursor
    if ($cur -lt 0) { $cur = 0 }
    if ($cur -gt $shown.Length) { $cur = $shown.Length }

    # The window that contains the cursor, preferring to keep it visible over keeping the start
    # anchored. One column of slack on the right so the caret has somewhere to sit at end of line.
    $start = 0
    if ($shown.Length -ge $Width) {
        if ($cur -ge $Width) { $start = $cur - $Width + 1 }
        $maxStart = [math]::Max(0, $shown.Length - $Width + 1)
        if ($start -gt $maxStart) { $start = $maxStart }
    }
    $take = [math]::Min($Width, [math]::Max(0, $shown.Length - $start))
    $text = ''
    if ($take -gt 0) { $text = $shown.Substring($start, $take) }

    return [pscustomobject]@{
        Text          = $text
        CursorColumn  = $cur - $start
        ScrolledLeft  = ($start -gt 0)
        ScrolledRight = (($start + $take) -lt $shown.Length)
    }
}

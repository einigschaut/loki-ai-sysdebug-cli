# lib/screen.ps1 -- the owned screen: Loki takes the whole window, paints it by cell-level difference,
# and gives it back untouched (issue #133).
#
# WHY THIS EXISTS, AND WHY IT REVERSES AN EARLIER DECISION. The plan in #133 originally ruled out the
# alternate screen and every escape sequence, on the grounds that Loki must leave no app-level trace.
# Measurement says the opposite. Writing into the technician's normal buffer IS mutating it; the
# alternate screen is the only option measured here that leaves nothing behind at all:
#
#   Windows 11 26200, WinPS 5.1.26100.8875, ConsoleHost, CP850. Five runs.
#     ConPTY regime (buffer = window), 120x30 and 63x8 : 0 of 30 and 0 of 8 rows changed by the
#                                                        enter/leave round trip
#     conhost regime, 120x9001 behind a 120x30 window  : 0 of 30 rows changed, buffer height 9001
#                                                        before AND after, and a marker parked in
#                                                        the scrollback above the window was found
#                                                        at the SAME absolute row afterwards
#
# The buffer reporting 120x30 while inside the alternate screen is a view change, not a truncation.
# The scrollback survives, and the scrollback is what a technician needs -- the error that brought
# them to the machine may be sitting in it.
#
# WHAT THE REFERENCE ACTUALLY DOES, from a 249 KB pseudo-terminal capture of a real 5.3-minute
# session (the numbers this file is built to): alternate screen for 99.1% of the run; exactly ONE
# ESC[2J, at entry, never cleared again; 1836 frames with a median payload of 61 bytes; absolute
# addressing only -- zero relative cursor-up, zero scroll region; 8 frames/s median, 13 peak.
# Its ESC[?2026 synchronised-update fences are emitted 1966 times as an EMPTY pair, so they are not
# what makes its frames calm and this file does not send them.
#
# Contract. Same split as lib/liveregion.ps1: every decision pure and injected, because CI runs
# Pester in a process whose stdout is a pipe -- the exact condition under which this refuses to
# engage. A decision taken inside a console call is a decision no test can ever see.
#
#   PURE:
#   Get-LokiScreenCapability -HostName -OutputRedirected -InputRedirected -Plain -VtActive
#                            -WindowWidth -WindowHeight -> @{ Engage; Reason }
#   Get-LokiScreenCellWidth -WindowWidth -> [int]           how wide one row may be
#   Initialize-LokiScreenModel -Width -Height -> [string[]] a blank virtual screen
#   Write-LokiScreenCell -Model -Row -Col -Text             writes THROUGH to the caller's array
#   Format-LokiScreenRow -Text -Width -> [string]           exactly Width characters
#   Get-LokiScreenDiff -Old -New -> [string]                ONE string, only what changed
#   Get-LokiScreenFullPaint -Model -> [string]              ONE string, every row, absolutely placed
#   Test-LokiScreenModelShape -Model -Width -Height -> [bool]
#
#   IMPURE:
#   Test-LokiVtProcessing -> [bool]      does this console interpret escapes? measured, not assumed
#   Get-LokiScreenRow -Row -Width -> [string] or $null
#   Open-LokiScreen [-Plain] -> [bool]   $false is a NORMAL answer
#   Write-LokiScreenFrame -Model         one frame, one console write
#   Resize-LokiScreen -> [bool]          re-measure and full-repaint after the window changed
#   Hide-LokiScreenCaret / Show-LokiScreenCaret -Row -Col   the fence the reference puts round a frame
#   Close-LokiScreen                     leaves the alternate screen, always
#   Test-LokiScreenPaint -Model -> [int] rows where the console disagrees with the model
#   Test-LokiScreenOpen / Get-LokiScreenRefusal / Get-LokiScreenSize / Initialize-LokiScreen
#
# THE TYPE-CONSTRAINT RULE IN THIS FILE, and it is not style. A [string[]] parameter handed an
# Object[] is CONVERTED, and converting copies -- so a function that writes into the array writes
# into a copy and the caller sees nothing, with no error. Worse, the read-back self-check would then
# compare two unchanged things and report zero mismatches. That is the same wrong-against-wrong
# failure that let 28 deliberately bad anchors through the first live-region probe. Measured here on
# 2026-08-26: Initialize-LokiScreenModel returns Object[] (a `return` unrolls the array), and binding
# that to [string[]] loses every cell write.
#   => Parameters this file WRITES THROUGH carry NO type constraint, only an -is [array] guard.
#   => Parameters it only READS may be [string[]]; the copy is harmless there.
# Debugging note for whoever meets this next: [object[]]$x = $stringArray does NOT copy (array
# covariance keeps the same String[] instance). Reproducing the trap that way yields a green result
# and the wrong conclusion.
Set-StrictMode -Version Latest

# Not a magic number worth naming twice.
$script:LokiEsc = [string][char]27

$script:LokiScreenState    = $null      # $null = closed. Otherwise Width / Height / Model / Encoding
$script:LokiScreenReason   = 'closed'   # why there is no screen right now, as a machine token
$script:LokiScreenDisabled = $false     # a refusal that lasts for the rest of the process

# ==============================================================================================
# PURE
# ==============================================================================================

function Get-LokiScreenCapability {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$HostName,
        [Parameter(Mandatory = $true)][bool]$OutputRedirected,
        [Parameter(Mandatory = $true)][bool]$InputRedirected,
        [Parameter(Mandatory = $true)][bool]$Plain,
        [Parameter(Mandatory = $true)][bool]$VtActive,
        [Parameter(Mandatory = $true)][int]$WindowWidth,
        [Parameter(Mandatory = $true)][int]$WindowHeight
    )
    # PURE. One chain, one exit, ordered by decisiveness -- Reason is what the operator gets told and
    # the first true answer should be the most useful one. Reason is a stable machine token; the
    # human wording lives in the i18n catalogs.
    #
    #   plain          the operator said no, by flag, env or config -- beats every capability question
    #   redirected     a file or a pipe, not a degraded console. Escape sequences there are garbage in
    #                  someone's log, and it is the exact condition under which CI runs.
    #   host           ConsoleHost only. The ISE stubs RawUI; remoting hosts have no console at all.
    #   no-vt          this console does not interpret escapes, so there is no alternate screen to
    #                  enter. Measured at runtime by Test-LokiVtProcessing rather than assumed from
    #                  the Windows build -- Windows 10 was not available to measure, and the honest
    #                  answer to an unmeasured regime is to detect and refuse, not to hope.
    #   window-short   below the smallest window measured to work.
    #   window-narrow  a judgement, not a measurement.
    #
    # NOT in the list, unlike the live region's gate: nothing about the buffer. The region cared,
    # because it anchored itself inside someone else's buffer. This owns the screen, and both buffer
    # regimes were measured to work -- ConPTY, where buffer equals window, and conhost, where a
    # 9001-row buffer sits behind a 30-row window. Adding a check either would pass is noise.
    $reason = 'ok'
    if     ($Plain)                                 { $reason = 'plain' }
    elseif ($OutputRedirected -or $InputRedirected) { $reason = 'redirected' }
    elseif ($HostName -ne 'ConsoleHost')            { $reason = 'host' }
    elseif (-not $VtActive)                         { $reason = 'no-vt' }
    elseif ($WindowHeight -lt 8)                    { $reason = 'window-short' }
    elseif ($WindowWidth -lt 40)                    { $reason = 'window-narrow' }

    return [pscustomobject]@{ Engage = ($reason -eq 'ok'); Reason = $reason }
}

function Get-LokiScreenCellWidth {
    param([Parameter(Mandatory = $true)][int]$WindowWidth)
    # PURE. One column short of the window, on purpose, exactly as Get-LokiRegionCellWidth argues.
    # Writing the last cell of a row leaves the console in a pending-wrap state that the next
    # absolute move cancels -- on every host measured. But "on every host measured" is three hosts,
    # and the two failure modes are wildly asymmetric: a host that wraps eagerly would shift every
    # subsequent row by one, while one unused column costs a column that holds no content anyway.
    $w = $WindowWidth - 1
    if ($w -lt 1) { return 1 }
    return $w
}

function Initialize-LokiScreenModel {
    param(
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height
    )
    # PURE. Height rows of exactly Width spaces. Note for callers: this returns Object[], because a
    # `return` unrolls the array. That is fine everywhere in this file -- see the type-constraint
    # rule at the top -- but it is why Write-LokiScreenCell must not constrain its parameter.
    #
    # DO NOT "FIX" THE RETURN TO `, $rows.ToArray()`. It was tried on 2026-08-31 and reverted, because
    # the unrolling is load-bearing in two ways at once:
    #
    #   1. The unroll-and-recollect is what makes this Object[] rather than the String[] that
    #      List[string].ToArray() actually produces. Handing back String[] makes binding to a
    #      [string[]] parameter a no-op cast instead of a copy -- array covariance -- so the test
    #      that reproduces this file's central trap stops reproducing anything and goes green while
    #      guarding nothing. Exactly the wrong-against-wrong failure the trap is about.
    #   2. `return , @()` on the degenerate path emits the empty array as ONE object instead of
    #      emitting nothing, so a caller's @(...) gets Count 1 for a screen with no rows.
    #
    # The real consequence -- a one-row model comes back as a bare string, which Write-LokiScreenCell
    # and Test-LokiScreenModelShape both correctly refuse -- belongs to the CALLER, and the caller
    # fixes it with @(...) at the point of use. Format-LokiSessionFrame does exactly that.
    if ($Width -lt 1 -or $Height -lt 1) { return @() }
    $rows = New-Object System.Collections.Generic.List[string]
    $blank = ' ' * $Width
    for ($r = 0; $r -lt $Height; $r++) { $rows.Add($blank) }
    return $rows.ToArray()
}

function Write-LokiScreenCell {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Model,
        [Parameter(Mandatory = $true)][int]$Row,
        [Parameter(Mandatory = $true)][int]$Col,
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$Text
    )
    # PURE in effect: it mutates only the array it was handed. NO type constraint on $Model -- see the
    # rule at the top of this file. Out-of-range writes are clipped rather than thrown, because the
    # callers are layout code and a widget one row taller than its box is a cosmetic bug, not a
    # reason to take the CLI down.
    if ($null -eq $Model -or -not ($Model -is [array])) { return }
    if ($Row -lt 0 -or $Row -ge $Model.Count) { return }
    if ($Col -lt 0) { return }
    $line = [string]$Model[$Row]
    $width = $line.Length
    if ($Col -ge $width) { return }
    $t = $Text
    if ($null -eq $t) { $t = '' }
    if ($t.Length -eq 0) { return }
    $take = [math]::Min($t.Length, $width - $Col)
    $Model[$Row] = $line.Substring(0, $Col) + $t.Substring(0, $take) + $line.Substring($Col + $take)
}

function Format-LokiScreenRow {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$Text,
        [Parameter(Mandatory = $true)][int]$Width
    )
    # PURE. Exactly Width characters, always. Short rows are padded because the screen overwrites in
    # place: without the padding, the tail of the previous frame survives to the right of the new text.
    if ($Width -lt 1) { return '' }
    $t = $Text
    if ($null -eq $t) { $t = '' }
    if ($t.Length -gt $Width) { return $t.Substring(0, $Width) }
    return $t.PadRight($Width)
}

function Test-LokiScreenModelShape {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Model,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height
    )
    # PURE. A frame is only paintable if every row is exactly the declared size. Called before every
    # paint, because a single short row would shift the diff's column arithmetic for that row and put
    # text in the wrong place silently -- which is precisely the class of bug the read-back check at
    # open exists to catch, and this is the cheap version that runs every time.
    if ($null -eq $Model -or -not ($Model -is [array])) { return $false }
    if ($Model.Count -ne $Height) { return $false }
    foreach ($row in $Model) {
        if ($null -eq $row) { return $false }
        if (([string]$row).Length -ne $Width) { return $false }
    }
    return $true
}

function Get-LokiScreenDiff {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][AllowNull()][string[]]$Old,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][AllowNull()][string[]]$New
    )
    # PURE. ONE string for ONE console write -- the rule that came out of the flicker measurement:
    # what makes a frame tear is the NUMBER of console writes, not the cursor motion.
    #
    # Per changed row, the smallest span that covers the change, placed absolutely. The reference
    # goes finer, skipping unchanged gaps inside a row with ESC[nC; that would save bytes on rows
    # that change in two places at once and is not worth the arithmetic until something needs it.
    # Measured cost of this version: 26 bytes per frame on a 120x28 screen against 3417 for a full
    # repaint.
    #
    # Absolute addressing only, no newlines: relative motion would make a frame depend on where the
    # cursor happened to be, and a newline on the last row scrolls the screen the caller believes it
    # owns. The reference emits zero relative cursor-ups and zero scroll regions across 1836 frames.
    if ($null -eq $Old -or $null -eq $New) { return '' }
    $sb = New-Object System.Text.StringBuilder
    $count = [math]::Min($Old.Count, $New.Count)
    for ($r = 0; $r -lt $count; $r++) {
        $o = [string]$Old[$r]
        $n = [string]$New[$r]
        if ($o -eq $n) { continue }
        $width = [math]::Min($o.Length, $n.Length)
        if ($width -lt 1) { continue }
        $start = 0
        while ($start -lt $width -and $o[$start] -eq $n[$start]) { $start++ }
        if ($start -ge $width) {
            # Same prefix all the way, so the rows differ only in length. Repaint from the shorter
            # length onward rather than pretending nothing changed.
            $start = $width - 1
        }
        $end = $width - 1
        while ($end -gt $start -and $o[$end] -eq $n[$end]) { $end-- }
        [void]$sb.Append($script:LokiEsc + '[' + ($r + 1) + ';' + ($start + 1) + 'H')
        [void]$sb.Append($n.Substring($start, $end - $start + 1))
    }
    return $sb.ToString()
}

function Get-LokiScreenFullPaint {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][AllowNull()][string[]]$Model)
    # PURE. Every row, each placed absolutely, in ONE string and with NO newline anywhere.
    #
    # The obvious implementation joins the rows with CRLF, and it is wrong: the newline after the
    # last row scrolls the screen by one, so the whole frame slides up and every subsequent absolute
    # position is off by a row. It looks fine in a probe that paints WindowHeight-2 rows and breaks
    # the moment the screen is the full window.
    if ($null -eq $Model -or $Model.Count -eq 0) { return '' }
    $sb = New-Object System.Text.StringBuilder
    for ($r = 0; $r -lt $Model.Count; $r++) {
        [void]$sb.Append($script:LokiEsc + '[' + ($r + 1) + ';1H')
        [void]$sb.Append([string]$Model[$r])
    }
    return $sb.ToString()
}

# ==============================================================================================
# IMPURE. Everything below touches the console, through two primitives -- Write-LokiScreenRaw and
# Get-LokiScreenRow -- so a test can replace both and still exercise every path.
#
# WHAT IT NEVER DOES: it changes no code page, no console mode, no buffer size, no colour default.
# It sets two DEC private modes that are view state and measured to restore exactly (?1049 alternate
# screen, ?25 cursor visibility), and it writes text. There is no path on which Loki exits with the
# alternate screen still active that does not also mean the process was killed outright.
# ==============================================================================================

function Write-LokiScreenRaw {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    # The only console write in this file, and it reports failure instead of raising it -- the
    # console APIs throw when output is redirected, and a diagnostic tool that dies while drawing is
    # worse than one that stops drawing. [Console]::Write and not Write-Host: this is exactly the
    # call the feasibility probe measured, and it must stay the same call for those numbers to mean
    # anything. It deliberately does NOT fire the ordinary write hook -- the screen's own painting
    # must not be mistaken for output that should tear the screen down.
    if ($Text.Length -eq 0) { return $true }
    try {
        [Console]::Write($Text)
        return $true
    }
    catch { return $false }
}

function Get-LokiScreenRow {
    param(
        [Parameter(Mandatory = $true)][int]$Row,
        [Parameter(Mandatory = $true)][int]$Width
    )
    # Reads back what the console actually shows. Measured to work INSIDE the alternate screen in
    # both buffer regimes, which is what makes the renderer verifiable at all. Returns $null rather
    # than throwing, because the first thing that reads may be reading a redirected handle.
    if ($Row -lt 0 -or $Width -lt 1) { return $null }
    try {
        $rect = New-Object System.Management.Automation.Host.Rectangle 0, $Row, ($Width - 1), $Row
        $cells = $Host.UI.RawUI.GetBufferContents($rect)
        $sb = New-Object System.Text.StringBuilder
        # GetValue, not $cells[0, $x]: Windows PowerShell 5.1 reads that as a slice and refuses to
        # parse the file at all. PowerShell 7 accepts it, which is why this must be checked in 5.1.
        for ($x = 0; $x -lt $Width; $x++) { [void]$sb.Append($cells.GetValue(0, $x).Character) }
        return $sb.ToString()
    }
    catch { return $null }
}

function Test-LokiVtProcessing {
    # Does this console interpret escape sequences? Measured, never assumed.
    #
    # The trick: write a colour sequence and read the cell back. With VT on the buffer holds just the
    # 'A'; with VT off it holds the raw ESC [ 1 m A. No P/Invoke and no Add-Type -- Add-Type compiles
    # to a temporary DLL under %TEMP%, which is a trace, and traces are the one thing this project
    # does not get to leave.
    #
    # It borrows one row of the operator's screen for a few milliseconds and puts it back. The row is
    # restored from its own contents, so the text survives; colour attributes on that row do not.
    # That is the price of not being allowed to ask the console directly.
    $probe = 'A'
    try {
        $rawUi = $Host.UI.RawUI
        $width = [int]$rawUi.BufferSize.Width
        $row = [int]$rawUi.CursorPosition.Y
        $col = [int]$rawUi.CursorPosition.X
        if ($width -lt 8) { return $false }

        $before = Get-LokiScreenRow -Row $row -Width $width
        if ($null -eq $before) { return $false }

        [Console]::SetCursorPosition(0, $row)
        [Console]::Write($script:LokiEsc + '[1m' + $probe + $script:LokiEsc + '[m')
        $seen = Get-LokiScreenRow -Row $row -Width $width

        # Put the row back exactly as it was, then the cursor.
        [Console]::SetCursorPosition(0, $row)
        [Console]::Write($before.Substring(0, $width - 1))
        [Console]::SetCursorPosition($col, $row)

        if ($null -eq $seen -or $seen.Length -lt 1) { return $false }
        return ($seen[0] -eq $probe[0])
    }
    catch { return $false }
}

function Test-LokiScreenOpen { return ($null -ne $script:LokiScreenState) }

function Get-LokiScreenRefusal { return [string]$script:LokiScreenReason }

function Get-LokiScreenSize {
    # The screen's own dimensions, or zeroes when nothing is open. A caller laying out a frame has to
    # know these: the width is decided here, from the console, and guessing it would put every
    # right-hand border in the wrong column on every console but the author's.
    if ($null -eq $script:LokiScreenState) { return [pscustomobject]@{ Width = 0; Height = 0 } }
    return [pscustomobject]@{
        Width  = [int]$script:LokiScreenState.Width
        Height = [int]$script:LokiScreenState.Height
    }
}

function Initialize-LokiScreen {
    # Back to the state a fresh process starts in, matching Initialize-LokiUi / Initialize-LokiRegion.
    # It exists because 'disabled' deliberately LASTS: once the console has disagreed with the model,
    # reopening would walk straight back into the same trap, so nothing else in this file ever clears
    # that flag. Something has to, once, at the start.
    Close-LokiScreen
    $script:LokiScreenDisabled = $false
    $script:LokiScreenReason = 'closed'
}

function Test-LokiScreenPaint {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][AllowNull()][string[]]$Model)
    # How many rows does the console disagree with the model about? -1 means it could not be read.
    #
    # This is the check that makes the renderer honest, and it is only possible because
    # GetBufferContents was measured to work inside the alternate screen. It is NOT run per frame --
    # reading thirty rows costs more than painting them -- it runs once, right after the first paint,
    # so a console that does not do what this file believes is caught before a whole session is drawn
    # wrong.
    if ($null -eq $Model -or $Model.Count -eq 0) { return -1 }
    $bad = 0
    for ($r = 0; $r -lt $Model.Count; $r++) {
        $expected = [string]$Model[$r]
        $actual = Get-LokiScreenRow -Row $r -Width $expected.Length
        if ($null -eq $actual) { return -1 }
        if ($actual -ne $expected) { $bad++ }
    }
    return $bad
}

function Open-LokiScreen {
    param([switch]$Plain)
    # Returns $true only if the screen is now ours. EVERY caller must cope with $false -- that is the
    # normal answer under redirection, in CI, on a console without VT and whenever the operator said
    # no. The fallback is the bottom-anchored live region from #131, which needs none of this.
    Close-LokiScreen

    if ($script:LokiScreenDisabled) {
        $script:LokiScreenReason = 'disabled'
        return $false
    }

    $facts = Get-LokiConsoleFact
    if ($null -eq $facts) {
        $script:LokiScreenReason = 'no-console'
        return $false
    }

    # Cheap refusals first: the VT probe writes to the operator's screen, so it must not run for a
    # console that was going to be refused anyway.
    $pre = Get-LokiScreenCapability -HostName $facts.HostName `
        -OutputRedirected $facts.OutputRedirected -InputRedirected $facts.InputRedirected `
        -Plain ([bool]$Plain) -VtActive $true `
        -WindowWidth $facts.WindowWidth -WindowHeight $facts.WindowHeight
    if (-not $pre.Engage) {
        $script:LokiScreenReason = [string]$pre.Reason
        return $false
    }

    $capability = Get-LokiScreenCapability -HostName $facts.HostName `
        -OutputRedirected $facts.OutputRedirected -InputRedirected $facts.InputRedirected `
        -Plain ([bool]$Plain) -VtActive (Test-LokiVtProcessing) `
        -WindowWidth $facts.WindowWidth -WindowHeight $facts.WindowHeight
    $script:LokiScreenReason = [string]$capability.Reason
    if (-not $capability.Engage) { return $false }

    $width = Get-LokiScreenCellWidth -WindowWidth $facts.WindowWidth
    $height = [int]$facts.WindowHeight
    $model = Initialize-LokiScreenModel -Width $width -Height $height

    # Enter. ESC[2J exactly once, at entry, and never again -- the reference clears exactly once
    # across 1836 frames and repaints everything else by difference.
    $enter = $script:LokiEsc + '[?1049h' + $script:LokiEsc + '[2J' + $script:LokiEsc + '[?25l'
    if (-not (Write-LokiScreenRaw -Text $enter)) {
        $script:LokiScreenReason = 'write-failed'
        return $false
    }

    if (-not (Write-LokiScreenRaw -Text (Get-LokiScreenFullPaint -Model $model))) {
        [void](Write-LokiScreenRaw -Text ($script:LokiEsc + '[?25h' + $script:LokiEsc + '[?1049l'))
        $script:LokiScreenReason = 'write-failed'
        return $false
    }

    # The one self-check. If the console does not show what was just painted, this file's model of
    # the world is wrong, and drawing an entire session on top of a wrong model is worse than not
    # drawing it. Refuse for good and hand the caller back to the fallback path.
    $mismatch = Test-LokiScreenPaint -Model $model
    if ($mismatch -gt 0) {
        [void](Write-LokiScreenRaw -Text ($script:LokiEsc + '[?25h' + $script:LokiEsc + '[?1049l'))
        $script:LokiScreenDisabled = $true
        $script:LokiScreenReason = 'self-check'
        return $false
    }
    # -1 means the read failed rather than disagreed -- that is a console which cannot be verified,
    # not one which is wrong. Accepting it keeps hosts where GetBufferContents is stubbed, and the
    # per-frame shape check still guards the arithmetic.

    $encoding = $null
    try { $encoding = [Console]::OutputEncoding } catch { $encoding = $null }

    $script:LokiScreenState = @{
        Width    = $width
        Height   = $height
        Model    = $model
        Encoding = $encoding
    }
    return $true
}

function Write-LokiScreenFrame {
    param([Parameter(Mandatory = $true)][AllowNull()]$Model)
    # One frame, one console write. No type constraint on $Model because callers hand over whatever
    # Initialize-LokiScreenModel gave them, which is Object[].
    if ($null -eq $script:LokiScreenState) { return }
    $state = $script:LokiScreenState

    if (-not (Test-LokiScreenModelShape -Model $Model -Width $state.Width -Height $state.Height)) {
        # A misshapen frame would shift the diff's column arithmetic and put text in the wrong place
        # without any error at all. Drop the frame; the screen keeps showing the last good one.
        $script:LokiScreenReason = 'bad-shape'
        return
    }

    $rows = New-Object string[] $state.Height
    for ($r = 0; $r -lt $state.Height; $r++) { $rows[$r] = [string]$Model[$r] }

    $paint = Get-LokiScreenDiff -Old ([string[]]$state.Model) -New $rows
    if ($paint.Length -eq 0) { return }
    if (-not (Write-LokiScreenRaw -Text $paint)) {
        Close-LokiScreen
        $script:LokiScreenReason = 'write-failed'
        return
    }
    $state.Model = $rows
}

function Close-LokiScreen {
    if ($null -eq $script:LokiScreenState) { return }
    # State is cleared FIRST: everything below writes, and a write that re-entered here would loop.
    $script:LokiScreenState = $null
    $script:LokiScreenReason = 'closed'

    # Cursor back, alternate screen off, attributes reset. In that order: showing the cursor after
    # leaving would show it in the restored screen at a position this file never chose.
    [void](Write-LokiScreenRaw -Text ($script:LokiEsc + '[?25h' + $script:LokiEsc + '[?1049l' + $script:LokiEsc + '[m'))
}

function Resize-LokiScreen {
    # The window changed size. NOTHING ANNOUNCES THAT -- measured for ADR-0037: dragging the window
    # from 209x51 to 75x30 while a key read was pending, ReadKey returned normally and the new size
    # was visible only AFTER it returned. So the session asks after every key, and this is what it
    # calls. $true means the screen now matches the console; $false means nothing was open, or the
    # console could not be read, in which case the caller keeps the frame it has rather than painting
    # into a geometry nobody measured.
    #
    # It does NOT leave and re-enter the alternate screen. Close-LokiScreen followed by
    # Open-LokiScreen would work and is shorter, but ESC[?1049l restores the operator's shell for a
    # frame and then hides it again -- which reads as a flash of somebody else's window in the middle
    # of a session, and would re-run the capability gate and the read-back self-check on every drag.
    #
    # It DOES send a second ESC[2J, and the header of this file says the reference sends exactly one.
    # That is not a contradiction: the reference's window was never resized during the 5.3 minutes
    # captured, so the capture says nothing about this case. A resize invalidates every row -- a
    # narrower window reflows what the terminal already holds -- so the honest paint is a clear plus
    # a full paint, not a diff against rows whose geometry no longer exists.
    if ($null -eq $script:LokiScreenState) { return $false }

    $facts = Get-LokiConsoleFact
    if ($null -eq $facts) { return $false }

    $width = Get-LokiScreenCellWidth -WindowWidth $facts.WindowWidth
    $height = [int]$facts.WindowHeight
    if ($width -lt 1 -or $height -lt 1) { return $false }

    $state = $script:LokiScreenState
    if ($state.Width -eq $width -and $state.Height -eq $height) { return $true }

    $model = Initialize-LokiScreenModel -Width $width -Height $height
    if (-not (Write-LokiScreenRaw -Text ($script:LokiEsc + '[2J' + (Get-LokiScreenFullPaint -Model $model)))) {
        Close-LokiScreen
        $script:LokiScreenReason = 'write-failed'
        return $false
    }

    $state.Width = $width
    $state.Height = $height
    $state.Model = [string[]]$model
    return $true
}

function Hide-LokiScreenCaret {
    # Half of the fence the reference puts around every frame: its 1836 frames are all bracketed
    # ESC[?25l ... ESC[?25h. Without it the cursor is visibly parked wherever the diff happened to
    # end -- in the middle of the transcript -- for the moment between the frame write and the caret
    # move. At 8 frames a second that is not a theoretical flicker.
    if ($null -eq $script:LokiScreenState) { return $false }
    return Write-LokiScreenRaw -Text ($script:LokiEsc + '[?25l')
}

function Show-LokiScreenCaret {
    param(
        [Parameter(Mandatory = $true)][int]$Row,
        [Parameter(Mandatory = $true)][int]$Col
    )
    # The other half, and the reason the caret is the console's OWN cursor rather than a character
    # painted into the model: a real cursor blinks, sits at the right place for the terminal's own
    # copy/paste, and is what a screen reader or a terminal-side IME asks for. Painting a block into
    # the model would look similar and be none of those things.
    #
    # Measured in the reference: the last absolute move before each ESC[?25h is the input row --
    # ESC[49;3H in the captured session, which is column 3, the first content column inside a
    # one-space-padded box border. Row and column are 0-based here and 1-based on the wire.
    #
    # Move and show in ONE write. Two writes would show the cursor at the position the previous
    # frame left it before moving it, which is the flicker this pair exists to remove.
    if ($null -eq $script:LokiScreenState) { return $false }
    if ($Row -lt 0 -or $Col -lt 0) { return $false }
    if ($Row -ge [int]$script:LokiScreenState.Height) { return $false }
    if ($Col -ge [int]$script:LokiScreenState.Width) { return $false }
    return Write-LokiScreenRaw -Text ($script:LokiEsc + '[' + ($Row + 1) + ';' + ($Col + 1) + 'H' + $script:LokiEsc + '[?25h')
}

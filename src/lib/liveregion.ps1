# lib/liveregion.ps1 -- the pure half of the bottom-anchored live region: a footer pinned above the
# cursor that repaints in place while finished output scrolls away above it (issue #130).
#
# Contract. EVERY DECISION IS PURE and every fact it needs is injected -- CI runs Pester in a process
# whose stdout is a pipe, which is exactly the condition under which the region refuses to engage, so
# a decision taken inside a Write-Host is a decision no test can ever see.
#
#   PURE -- decides, formats, refuses. No console access at all:
#   Get-LokiRegionCapability -HostName <string> -OutputRedirected <bool> -InputRedirected <bool>
#                            -Plain <bool> -WindowWidth <int> -WindowHeight <int>
#                            -BufferWidth <int> -BufferHeight <int> -RegionHeight <int>
#       -> [pscustomobject]@{ Engage = [bool]; Reason = [string] }   the whole fail-closed gate
#   Get-LokiRegionCellWidth -WindowWidth <int> -> [int]              how wide one region line may be
#   Get-LokiRegionAnchor -CursorTop <int> -RegionHeight <int> -> [int]   region start row, -1 = refuse
#   Get-LokiRegionBlank -Height <int> -> [string[]]                  the lines that erase a region
#   Format-LokiRegionLine -Text <string> -CellWidth <int> -> [string]    exactly CellWidth characters
#   Format-LokiRegionFrame -Lines <string[]> -CellWidth <int> -> [string]   ONE string for ONE write
#   Test-LokiRegionTextSafe -Text <string> -Encoding <Encoding> -> [bool]   may this text be padded?
#   Test-LokiRegionGeometryChanged -Width <int> -Height <int> -KnownWidth <int> -KnownHeight <int>
#       -> [bool]                                                    the resize tripwire, both axes
#
#   IMPURE -- the three primitives plus the state machine built on them:
#   Get-LokiConsoleFact -> [hashtable] or $null                      one guarded read, never throws
#   Open-LokiRegion -Height <int> [-Plain] [-Color] -> [bool]        $false is a NORMAL answer
#   Write-LokiRegion -Lines <string[]>                               one repaint, one console write
#   Close-LokiRegion                                                 erases and parks the cursor
#   Test-LokiRegionOpen -> [bool] / Get-LokiRegionRefusal -> [string]
#
# THE ANCHOR, AND WHAT IT RESTS ON. The region never stores an absolute row. Every repaint recomputes
# its own start as CursorTop - RegionHeight, which is self-correcting: when the buffer scrolls, the
# region and the cursor move up together and the difference is unchanged. That is measured, not
# assumed -- 1000 repaints and 100 scroll events across Windows Terminal (209x51), the VS Code
# terminal (175x26) and a conhost window with a 3000-row buffer behind a 50-row window. In every run
# the anchor row was constant TO THE ROW (48..48, 23..23, 2997..2997) and every line that scrolled
# away survived intact above the region.
#
# THE MEASUREMENT THAT MATTERS MOST IS THE ONE THAT FAILED. A first version of that probe verified
# only the cells at CursorTop - height after each write. Fed 28 deliberately wrong anchors it
# reported zero errors -- and so did the obvious repair of reading those rows before overwriting
# them. A region that walks up the screen carries its cells AND the cursor with it, so both checks
# compare wrong against wrong. What caught it, 189 times, was a structural invariant: once the
# buffer is full the cursor must return to the last buffer row after every repaint. Anyone changing
# the anchor rule here should re-run that mutation control before believing a green result.
Set-StrictMode -Version Latest

# Characters whose console cell count is not their UTF-16 length. Format-LokiRegionLine pads with
# PadRight, which counts UTF-16 units, so one of these silently makes a line one cell too wide --
# and a line one cell too wide is not cosmetic here, it can wrap and add a row the anchor does not
# know about. Everything ever measured was ASCII under CP850, so this is a guard against a future
# caller, not against a known bug.
$script:LokiRegionWideRanges = @(
    @(0x1100, 0x115F),   # Hangul Jamo
    @(0x2E80, 0x303E),   # CJK radicals, Kangxi, CJK symbols
    @(0x3041, 0x33FF),   # kana, Hangul compatibility jamo, CJK compatibility
    @(0x3400, 0x4DBF),   # CJK extension A
    @(0x4E00, 0x9FFF),   # CJK unified ideographs
    @(0xA000, 0xA4CF),   # Yi
    @(0xAC00, 0xD7A3),   # Hangul syllables
    @(0xF900, 0xFAFF),   # CJK compatibility ideographs
    @(0xFE30, 0xFE6F),   # CJK compatibility forms
    @(0xFF00, 0xFF60),   # fullwidth forms
    @(0xFFE0, 0xFFE6)    # fullwidth signs
)

function Get-LokiRegionCapability {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$HostName,
        [Parameter(Mandatory = $true)][bool]$OutputRedirected,
        [Parameter(Mandatory = $true)][bool]$InputRedirected,
        [Parameter(Mandatory = $true)][bool]$Plain,
        [Parameter(Mandatory = $true)][int]$WindowWidth,
        [Parameter(Mandatory = $true)][int]$WindowHeight,
        [Parameter(Mandatory = $true)][int]$BufferWidth,
        [Parameter(Mandatory = $true)][int]$BufferHeight,
        [Parameter(Mandatory = $true)][int]$RegionHeight
    )
    # PURE. The gate IS the design: the region engages only inside the regime that was measured, and
    # everywhere else Loki keeps the shipped single-line carriage-return spinner. That is why this
    # change can merge at all -- it is a no-op wherever the evidence stops.
    #
    # ONE chain, ONE exit. The order is the order of decisiveness, because Reason is what the
    # operator gets told and the first true answer should be the most useful one. Reason is a stable
    # machine token; the human wording lives in the i18n catalogs.
    #
    #   plain          the operator said no, by flag, env or config -- beats every capability question
    #   redirected     not a degraded console but a file or a pipe. Cursor motion there is garbage in
    #                  someone's log, and it is the exact condition under which CI runs.
    #   host           ConsoleHost only. The ISE stubs RawUI and throws on cursor moves; remoting
    #                  hosts have no console at all. Neither was ever measured.
    #   buffer-short   a buffer shorter than its own window is malformed; nothing sane reports it.
    #   buffer-wide    a buffer WIDER than the window: the region pads to the visible width, so the
    #                  columns beyond would keep whatever was there before, off-screen and
    #                  unverifiable. Never measured, so refused rather than adapted to.
    #   window-short   no room for the footer plus something above it.
    #   window-narrow  a judgement, not a measurement. The narrowest console measured here was 120
    #                  columns; below roughly 40 a two-line footer is rubble rather than information.
    #                  Set this from a real 80x25 run when there is one.
    #
    # NOT in the list, because an earlier draft of this design had it and was wrong: a buffer TALLER
    # than its window is explicitly ALLOWED. That is the classic conhost scrollback regime, and it is
    # the single best-evidenced configuration there is -- measured with the hardened probe at a
    # 3000-row buffer behind a 50-row window, anchor row constant across 200 repaints and 20 scrolls.
    # Refusing it would refuse the console a portable diagnostic stick is most likely to land in.
    $reason = 'ok'
    if     ($Plain)                                     { $reason = 'plain' }
    elseif ($OutputRedirected -or $InputRedirected)     { $reason = 'redirected' }
    elseif ($HostName -ne 'ConsoleHost')                { $reason = 'host' }
    elseif ($RegionHeight -lt 1)                        { $reason = 'region-height' }
    elseif ($BufferHeight -lt $WindowHeight)            { $reason = 'buffer-short' }
    elseif ($BufferWidth -ne $WindowWidth)              { $reason = 'buffer-wide' }
    elseif ($WindowHeight -lt ($RegionHeight + 2))      { $reason = 'window-short' }
    elseif ($WindowWidth -lt 40)                        { $reason = 'window-narrow' }

    return [pscustomobject]@{ Engage = ($reason -eq 'ok'); Reason = $reason }
}

function Get-LokiRegionCellWidth {
    param([Parameter(Mandatory = $true)][int]$WindowWidth)
    # PURE. One column short of the window, on purpose.
    #
    # Every host measured defers the end-of-line wrap: a line of exactly WindowWidth characters stays
    # on its own row. But that was established by reading CursorLeft, never by reading a cell, and
    # that probe cannot tell a deferred wrap from a swallowed last character. The two failure modes
    # are wildly asymmetric -- a host that wraps immediately would add a row per line and destroy the
    # anchor, while one unused column costs a column that never holds region content anyway. So the
    # cheap safety wins over the measurement that cannot quite carry the weight.
    $w = $WindowWidth - 1
    if ($w -lt 1) { return 1 }
    return $w
}

function Get-LokiRegionAnchor {
    param(
        [Parameter(Mandatory = $true)][int]$CursorTop,
        [Parameter(Mandatory = $true)][int]$RegionHeight
    )
    # PURE. Returns -1 to mean "do not draw", and that is not a clamp waiting to be improved.
    # The probe clamped a negative anchor to row 0 and would then have drawn the footer over the top
    # of the screen while reporting a clean run. A region that does not fit must refuse, not relocate.
    if ($RegionHeight -lt 1) { return -1 }
    $anchor = $CursorTop - $RegionHeight
    if ($anchor -lt 0) { return -1 }
    return $anchor
}

function Format-LokiRegionLine {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$Text,
        [Parameter(Mandatory = $true)][int]$CellWidth
    )
    # PURE. Exactly CellWidth characters, always. Short lines are padded because the region overwrites
    # rows in place: without the padding, the tail of whatever was there before survives to the right
    # of the new text.
    if ($CellWidth -lt 1) { return '' }
    $t = $Text
    if ($null -eq $t) { $t = '' }
    if ($t.Length -gt $CellWidth) { return $t.Substring(0, $CellWidth) }
    return $t.PadRight($CellWidth)
}

function Format-LokiRegionFrame {
    param(
        # AllowEmptyString as well as AllowEmptyCollection: a [string[]] parameter rejects an EMPTY
        # ELEMENT unless told otherwise, and the blank lines that erase a region are exactly that.
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][AllowNull()][string[]]$Lines,
        [Parameter(Mandatory = $true)][int]$CellWidth
    )
    # PURE. Returns ONE string for ONE console write, including its own trailing newline.
    #
    # The trailing CRLF is inside the string on purpose. Write-Host emits the text and then
    # Environment.NewLine as a SEPARATE console write, so at the bottom of a full buffer the content
    # arrives in one operation and the scroll it causes in the next -- and the terminal is free to
    # draw the state in between. That is the flicker reported on exactly the frames where the footer
    # slides down a row. Handing a single string to a single -NoNewline write makes the frame and the
    # scroll one operation.
    #
    # CRLF and not LF: a bare LF moves down without resetting the column, so the next line of a
    # padded full-width frame would start at the right-hand edge.
    if ($null -eq $Lines -or $Lines.Count -eq 0) { return '' }
    $padded = New-Object System.Collections.ArrayList
    foreach ($l in $Lines) { [void]$padded.Add((Format-LokiRegionLine -Text $l -CellWidth $CellWidth)) }
    return ((($padded.ToArray()) -join "`r`n") + "`r`n")
}

function Test-LokiRegionTextSafe {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$Text,
        [Parameter(Mandatory = $true)][AllowNull()]$Encoding
    )
    # PURE. Two questions, both of which break the padding rather than merely look wrong:
    #   - is every character exactly one console cell wide? PadRight counts UTF-16 units, so a wide
    #     or a combining character makes the line the wrong size and can wrap.
    #   - does the text survive this console's encoding unchanged? Re-uses the round-trip probe from
    #     lib/ui.ps1, because CP850 substitutes rather than refuses (U+2713 comes back as 'V').
    if ([string]::IsNullOrEmpty($Text)) { return $true }
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int][char]$ch
        # Control characters are cursor motion in disguise -- a tab or a carriage return inside a
        # region line moves the cursor the region is trying to control.
        if ($code -lt 32 -or $code -eq 127) { return $false }
        if ([char]::IsSurrogate($ch)) { return $false }
        $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
        if ($cat -eq [System.Globalization.UnicodeCategory]::NonSpacingMark) { return $false }
        if ($cat -eq [System.Globalization.UnicodeCategory]::SpacingCombiningMark) { return $false }
        if ($cat -eq [System.Globalization.UnicodeCategory]::EnclosingMark) { return $false }
        foreach ($range in $script:LokiRegionWideRanges) {
            if ($code -ge $range[0] -and $code -le $range[1]) { return $false }
        }
    }
    return (Test-LokiEncodingSupport -Encoding $Encoding -Text $Text)
}

function Test-LokiRegionGeometryChanged {
    param(
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [Parameter(Mandatory = $true)][int]$KnownWidth,
        [Parameter(Mandatory = $true)][int]$KnownHeight
    )
    # PURE. BOTH axes. The probe polled only the width, which means a purely vertical resize would
    # have passed straight through it -- and a vertical resize is precisely what moves a region
    # anchored to the bottom. On a change the caller closes the region for good rather than adapting:
    # a narrowed window reflows every padded line into two rows, so the anchor points into the middle
    # of the old footer and the next repaint smears. Adapting to that would be code written against
    # no evidence at all.
    return (($Width -ne $KnownWidth) -or ($Height -ne $KnownHeight))
}

# ==============================================================================================
# The impure half. Everything below touches the console, and it touches it through exactly three
# primitives -- Get-LokiConsoleFact, Move-LokiCursor and Write-LokiConsole -- so a test can replace
# all three and still exercise every path. Nothing here decides anything: every decision is a call
# into the pure functions above.
#
# WHAT IT NEVER DOES: it changes no console mode, no code page, no buffer size, no colour default.
# It moves the cursor and it writes text. A region left behind by a hard kill is a stale footer on
# screen, never a mutated console -- which is why the cursor is not hidden either (lib/ui.ps1 makes
# the same argument for encoding).
# ==============================================================================================

$script:LokiRegionState    = $null    # $null = closed. Otherwise Height / CellWidth / KnownWidth / KnownHeight / Color
$script:LokiRegionReason   = 'closed' # why there is no region right now, as a machine token
$script:LokiRegionDisabled = $false   # a refusal that lasts for the rest of the process

function Get-LokiConsoleFact {
    # IMPURE, and it NEVER throws. The console APIs raise rather than degrade when output is
    # redirected, and this is the first thing that runs -- a probe that dies on its own first
    # reading takes the CLI with it.
    #
    # Read through $Host.UI.RawUI, not [Console]. Both agreed in every interactive host measured,
    # but they part company when output is redirected: .NET falls back to the standard ERROR handle
    # and then reports a window width while the cursor calls throw. RawUI opens CONOUT$ and survives.
    try {
        $rawUi = $Host.UI.RawUI
        return @{
            HostName         = [string]$Host.Name
            OutputRedirected = [bool][Console]::IsOutputRedirected
            InputRedirected  = [bool][Console]::IsInputRedirected
            WindowWidth      = [int]$rawUi.WindowSize.Width
            WindowHeight     = [int]$rawUi.WindowSize.Height
            BufferWidth      = [int]$rawUi.BufferSize.Width
            BufferHeight     = [int]$rawUi.BufferSize.Height
            CursorTop        = [int]$rawUi.CursorPosition.Y
        }
    }
    catch { return $null }
}

function Test-LokiRegionOpen { return ($null -ne $script:LokiRegionState) }

function Get-LokiRegionRefusal { return [string]$script:LokiRegionReason }

function Get-LokiRegionWidth {
    # How wide a region line may be right now, or 0 when nothing is open. A caller that draws a frame
    # has to know this: the width is decided here, from the console, and guessing it would put the
    # right-hand border in the wrong column on every console but the author's.
    if ($null -eq $script:LokiRegionState) { return 0 }
    return [int]$script:LokiRegionState.CellWidth
}

function Initialize-LokiRegion {
    # Back to the state a fresh process starts in, matching Initialize-LokiUi / Initialize-LokiI18n /
    # Initialize-LokiSpinner. It exists because 'disabled' deliberately LASTS: once a resize or a
    # refused cursor move has been seen, reopening would walk straight back into the same trap, so
    # nothing inside this file ever clears that flag. Something has to, once, at the start.
    Close-LokiRegion
    $script:LokiRegionDisabled = $false
    $script:LokiRegionReason = 'closed'
}

function Open-LokiRegion {
    param(
        [Parameter(Mandatory = $true)][int]$Height,
        [switch]$Plain,
        [AllowNull()]$Color = $null
    )
    # Returns $true only if a region is now open. EVERY caller must cope with $false -- that is the
    # normal answer under redirection, in CI, on a narrow console and whenever the operator said no.
    Close-LokiRegion

    if ($script:LokiRegionDisabled) {
        $script:LokiRegionReason = 'disabled'
        return $false
    }

    $facts = Get-LokiConsoleFact
    if ($null -eq $facts) {
        $script:LokiRegionReason = 'no-console'
        return $false
    }

    $capability = Get-LokiRegionCapability -HostName $facts.HostName `
        -OutputRedirected $facts.OutputRedirected -InputRedirected $facts.InputRedirected `
        -Plain ([bool]$Plain) -WindowWidth $facts.WindowWidth -WindowHeight $facts.WindowHeight `
        -BufferWidth $facts.BufferWidth -BufferHeight $facts.BufferHeight -RegionHeight $Height
    $script:LokiRegionReason = [string]$capability.Reason
    if (-not $capability.Engage) { return $false }

    $encoding = $null
    try { $encoding = [Console]::OutputEncoding } catch { $encoding = $null }

    $cellWidth = Get-LokiRegionCellWidth -WindowWidth $facts.WindowWidth

    # Reserve the rows. Without this the first repaint's anchor would point at whatever happened to
    # be above the cursor, and the region would eat it.
    Write-LokiConsole -Text (Format-LokiRegionFrame -Lines (Get-LokiRegionBlank -Height $Height) -CellWidth $cellWidth) -NoNewline

    $script:LokiRegionState = @{
        Height      = $Height
        CellWidth   = $cellWidth
        KnownWidth  = $facts.WindowWidth
        KnownHeight = $facts.WindowHeight
        Color       = $Color
        Encoding    = $encoding
    }

    # From here on, ANY ordinary output closes the region first -- stdout and stderr alike.
    Register-LokiWriteHook -Hook { Close-LokiRegion }
    return $true
}

function Write-LokiRegion {
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)
    if ($null -eq $script:LokiRegionState) { return }
    $state = $script:LokiRegionState

    $facts = Get-LokiConsoleFact
    if ($null -eq $facts) { Close-LokiRegion; return }

    # Resize: close for good rather than adapt. A narrowed window reflows every padded line into two
    # rows, so the anchor lands in the middle of the old footer -- and adapting to that would be code
    # written against zero evidence, because every measurement voided itself on resize.
    if (Test-LokiRegionGeometryChanged -Width $facts.WindowWidth -Height $facts.WindowHeight `
            -KnownWidth $state.KnownWidth -KnownHeight $state.KnownHeight) {
        $script:LokiRegionDisabled = $true
        Close-LokiRegion
        $script:LokiRegionReason = 'resized'
        return
    }

    foreach ($line in @($Lines)) {
        if (-not (Test-LokiRegionTextSafe -Text ([string]$line) -Encoding $state.Encoding)) {
            # A line whose console width is not its string length breaks the padding, and broken
            # padding can wrap and add a row the anchor knows nothing about. Stop drawing rather than
            # draw something whose geometry is unknown.
            $script:LokiRegionDisabled = $true
            Close-LokiRegion
            $script:LokiRegionReason = 'unsafe-text'
            return
        }
    }

    $anchor = Get-LokiRegionAnchor -CursorTop $facts.CursorTop -RegionHeight $state.Height
    if ($anchor -lt 0) { Close-LokiRegion; return }
    if (-not (Move-LokiCursor -Row $anchor)) {
        $script:LokiRegionDisabled = $true
        Close-LokiRegion
        $script:LokiRegionReason = 'cursor'
        return
    }

    # ONE write. The frame carries its own trailing newline so the content and the scroll it causes
    # at the bottom of a full buffer reach the console together -- see Format-LokiRegionFrame.
    Write-LokiConsole -Text (Format-LokiRegionFrame -Lines $Lines -CellWidth $state.CellWidth) -Color $state.Color -NoNewline
}

function Close-LokiRegion {
    if ($null -eq $script:LokiRegionState) {
        Register-LokiWriteHook -Hook $null
        return
    }
    # State is cleared FIRST: everything below writes, and a write that re-entered here would loop.
    $state = $script:LokiRegionState
    $script:LokiRegionState = $null
    $script:LokiRegionReason = 'closed'
    Register-LokiWriteHook -Hook $null

    $facts = Get-LokiConsoleFact
    if ($null -eq $facts) { return }
    $anchor = Get-LokiRegionAnchor -CursorTop $facts.CursorTop -RegionHeight $state.Height
    if ($anchor -lt 0) { return }
    if (-not (Move-LokiCursor -Row $anchor)) { return }

    # Blank the footer and park the cursor back at its first row, so whatever prints next simply
    # flows over the cleared space. Same contract as the spinner's own Write-LokiSpinnerDone.
    Write-LokiConsole -Text (Format-LokiRegionFrame -Lines (Get-LokiRegionBlank -Height $state.Height) -CellWidth $state.CellWidth) -NoNewline
    $after = Get-LokiConsoleFact
    if ($null -eq $after) { return }
    $back = Get-LokiRegionAnchor -CursorTop $after.CursorTop -RegionHeight $state.Height
    if ($back -ge 0) { [void](Move-LokiCursor -Row $back) }
}

function Get-LokiRegionBlank {
    param([Parameter(Mandatory = $true)][int]$Height)
    # PURE. Height empty lines; Format-LokiRegionFrame pads them to full width, which is what erases.
    if ($Height -lt 1) { return @() }
    $blank = New-Object string[] $Height
    for ($i = 0; $i -lt $Height; $i++) { $blank[$i] = '' }
    return $blank
}

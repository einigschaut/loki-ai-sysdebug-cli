# lib/brand.ps1 -- Loki's visual identity: the mascot, the wordmark and the crawling serpent that marks work in
# progress. PURE data and pure selection here; the writing happens through lib/ui.ps1 (ADR-0034).
#
# Contract:
#   Get-LokiBrandArt -Tier <'rich'|'oem'|'ascii'> -Width <int> -> [string[]]   PURE. Banner lines for that console.
#   Get-LokiBoxArt -Tier <string> -Lines <string[]> -Width <int> -> [string[]]    PURE. Frames a live region.
#   Get-LokiSpinnerFrameSet -Tier <string> -> [string[]]                          PURE. The animation, one entry per frame.
#   Get-LokiSpinnerFrame -Tier <string> -Index <int> -> [string]                PURE. Wraps; any index is legal.
#   Write-LokiBrand [-Width <int>] [-Tier <string>]                             renders the banner
#   Test-LokiSpinnerDue -LastTicks <long> -NowTicks <long> [-MinIntervalMs] -> [bool]  PURE throttle rule
#   Initialize-LokiSpinner                                                          back to frame 0
#   Write-LokiSpinnerTick -Label <string>                                       one frame on ITS OWN line
#   Write-LokiSpinnerDone                                                       clears the spinner line
#   Write-LokiSpinnerDone -Label <string>                                       clears the spinner line
#
# WHY THE MASCOT IS A FACE AND NOT A CHARACTER. The figure is drawn from the Snaptun stone -- a real 10th-century
# hearth stone whose sewn lips are the iconic image of the Loki of the actual Norse sources, from the wager with
# Brokkr. That is deliberate: it is unmistakably the mythological figure and unmistakably not the modern comic-book
# one, so the resemblance question never arises. The double line is the sewn mouth.
#
# WHY THE SERPENT MOVES INSTEAD OF THE FACE. The world serpent is Loki's child, and a coil that crawls is the
# cheapest honest way to say "still working" in a console. Anthropic's CLI ties its brand accent to its spinner for
# the same reason -- identity carried by colour and motion rather than by a drawing.
#
# WHY THE ART IS TIER-AWARE AND NOT JUST UNICODE. Measured (issue #121): a German Windows console runs CP850, where
# the rounded corners, triangles and dashes of the first drafts all collapse to '?'. The oem art therefore uses only
# characters proven present in BOTH CP850 and CP437, and the ascii art is pure ASCII for everything else. 'rich' and
# 'oem' deliberately share one design: if the conservative set is enough to draw it well, having two designs would
# only mean two things to keep in step.
Set-StrictMode -Version Latest

function Get-LokiBrandArt {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('rich', 'oem', 'ascii')][string]$Tier,
        [Parameter(Mandatory = $true)][int]$Width
    )

    # 'rich' draws the same picture as 'oem' on purpose (see the header). Only the ascii tier needs its own.
    $useOem = ($Tier -eq 'rich' -or $Tier -eq 'oem')

    # Narrow console: the banner becomes one line rather than wrapping into rubble. 34 is the wide form's 29
    # columns plus room for the frame not to touch the right edge.
    if ($Width -lt 34) {
        if ($useOem) { return @(('  [{0} {0}] LOKI' -f ([char]0x25A0))) }
        return @('  [o o] LOKI')
    }

    if ($useOem) {
        $tl = [char]0x250C; $tr = [char]0x2510; $bl = [char]0x2514; $br = [char]0x2518
        $h = [char]0x2500; $v = [char]0x2502; $td = [char]0x252C; $d = [char]0x2550
        $eye = [char]0x25A0; $b = [char]0x2588
        return @(
            ('  {0}{1}{1}{1}{1}{1}{2}' -f $tl, $h, $tr),
            ('  {0} {1} {1} {0}   {2}   {2}{2}{2} {2} {2} {2}{2}{2}' -f $v, $eye, $b),
            ('  {0} {1}{1}{1} {0}   {2}   {2} {2} {2}{2}   {2} ' -f $v, $d, $b),
            ('  {0}{1}{1}{2}{1}{1}{3}   {4}{4}{4} {4}{4}{4} {4} {4} {4}{4}{4}' -f $bl, $h, $td, $br, $b)
        )
    }

    return @(
        '  +-----+',
        '  | o o |   L O K I',
        '  |=====|',
        '  +--+--+'
    )
}

function Get-LokiBoxArt {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('rich', 'oem', 'ascii')][string]$Tier,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][AllowNull()][string[]]$Lines,
        [Parameter(Mandatory = $true)][int]$Width
    )
    # PURE. Frames a live region (lib/liveregion.ps1) the way the mascot's own head is framed -- deliberately the
    # same six characters, so the footer reads as part of Loki rather than as a second style bolted on.
    #
    # The corners are SQUARE, and that is a measurement rather than taste: the rounded corners this would otherwise
    # use (U+256D..U+2570) do not exist in CP850, which is what a German Windows console runs by default. They are
    # what issue #121 was found through. U+250C/2510/2514/2518 and U+2500/2502 are present in both CP850 and CP437.
    $content = @()
    if ($null -ne $Lines) { $content = @($Lines) }

    # Too narrow to frame: hand the lines back unboxed rather than draw rubble, on the same principle that collapses
    # the banner below 34 columns. Four characters go to the frame and two more to the padding, so anything under
    # about a dozen columns would be all border and no content.
    if ($Width -lt 12) { return $content }

    $tl = '+'; $tr = '+'; $bl = '+'; $br = '+'; $h = '-'; $v = '|'
    if ($Tier -ne 'ascii') {
        $tl = [string][char]0x250C; $tr = [string][char]0x2510
        $bl = [string][char]0x2514; $br = [string][char]0x2518
        $h = [string][char]0x2500; $v = [string][char]0x2502
    }

    $inner = $Width - 4    # the two frame characters plus one space of padding on each side
    $rule = $h * ($Width - 2)
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add($tl + $rule + $tr)
    foreach ($line in $content) {
        $text = [string]$line
        if ($null -eq $text) { $text = '' }
        if ($text.Length -gt $inner) { $text = $text.Substring(0, $inner) }
        $out.Add($v + ' ' + $text.PadRight($inner) + ' ' + $v)
    }
    $out.Add($bl + $rule + $br)
    return $out.ToArray()
}

# The serpent. Frames are equal width so the line never jitters, and the coil advances one column per frame so it
# reads as crawling rather than blinking.
function Get-LokiSpinnerFrameSet {
    param([Parameter(Mandatory = $true)][ValidateSet('rich', 'oem', 'ascii')][string]$Tier)
    if ($Tier -eq 'ascii') {
        return , @('~-------', '-~------', '--~-----', '---~----', '----~---', '-----~--', '------~-', '-------~')
    }
    # The head is the same filled square as the mascot's eyes, travelling along a rule.
    #
    # It used to be a coil built from the box-drawing corners, and on an open line that read well. It stopped
    # reading well the moment the footer gained a frame (issue #130, slice 2a): a coil made of the SAME six
    # characters as the border, printed immediately after a border, looks like a broken piece of border rather
    # than like a serpent. The square shares nothing with the frame, so the head stays a head -- and it is a
    # character the mascot already owns, so this is one identity rather than two.
    $h = [string][char]0x2500
    $head = [string][char]0x25A0
    $track = 8
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $track; $i++) {
        $out.Add(($h * $i) + $head + ($h * ($track - 1 - $i)))
    }
    return , @($out.ToArray())
}

function Get-LokiSpinnerFrame {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('rich', 'oem', 'ascii')][string]$Tier,
        [Parameter(Mandatory = $true)][int]$Index
    )
    # ASSIGN FIRST, then wrap -- Get-LokiSpinnerFrameSet ends in `return , @(...)`.
    $frames = Get-LokiSpinnerFrameSet -Tier $Tier
    $all = @($frames)
    # Modulo that also survives a negative index: a caller counting down must not crash the display.
    $i = $Index % $all.Count
    if ($i -lt 0) { $i += $all.Count }
    return [string]$all[$i]
}

function Write-LokiBrand {
    param([int]$Width = 0, [string]$Tier = '')

    if ([string]::IsNullOrEmpty($Tier)) { $Tier = Get-LokiGlyphTier }
    if ($Width -le 0) {
        # Guarded: WindowWidth throws when the output is redirected (measured). 80 is the honest assumption for a
        # console we cannot ask.
        try { $Width = [Console]::WindowWidth } catch { $Width = 80 }
    }

    foreach ($line in @(Get-LokiBrandArt -Tier $Tier -Width $Width)) {
        Write-LokiColor -Text $line -Color Green
    }
}

# The spinner counts its OWN frames and rate-limits itself, and both halves of that matter.
#
# Rate limit: the best tick point in this tool is the 128 KB copy loop of a download, so a 5 GB model would
# call this roughly 40,000 times. Unthrottled, drawing the spinner would cost more than the download it is
# reporting on. Callers must be free to tick as often as they like; protecting the console is this function's
# job, not theirs.
#
# Own frame counter: with a rate limit, an index supplied by the caller would jump by hundreds between two
# draws, and index modulo six is then effectively random -- the coil would flicker instead of crawling. The
# frame advances once per DRAW, which is the only thing that makes it look like movement.
$script:LokiSpinnerFrame = 0
$script:LokiSpinnerLastTicks = [long]0
$script:LokiSpinnerMaxLen = 0

function Test-LokiSpinnerDue {
    param(
        [Parameter(Mandatory = $true)][long]$LastTicks,
        [Parameter(Mandatory = $true)][long]$NowTicks,
        [int]$MinIntervalMs = 80
    )
    # PURE. The first tick always draws. A clock that appears to run backwards (DST, a corrected system
    # time) must not freeze the spinner until the difference has been made up -- so a negative interval
    # draws too, rather than waiting.
    if ($LastTicks -le 0) { return $true }
    $elapsedMs = [long](($NowTicks - $LastTicks) / 10000)
    if ($elapsedMs -lt 0) { return $true }
    return ($elapsedMs -ge $MinIntervalMs)
}

function Initialize-LokiSpinner {
    $script:LokiSpinnerFrame = 0
    $script:LokiSpinnerLastTicks = [long]0
    $script:LokiSpinnerMaxLen = 0
}

function Write-LokiSpinnerTick {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Label)
    # The spinner OWNS ITS LINE. A carriage return rewinds to column 0 of the physical line, so anything
    # already printed there gets eaten -- observed the first time this was tried. Nothing else may write
    # while it ticks.
    if ([Console]::IsOutputRedirected) { return }
    $now = [datetime]::UtcNow.Ticks
    if (-not (Test-LokiSpinnerDue -LastTicks $script:LokiSpinnerLastTicks -NowTicks $now)) { return }
    $script:LokiSpinnerLastTicks = $now
    $frame = Get-LokiSpinnerFrame -Tier (Get-LokiGlyphTier) -Index $script:LokiSpinnerFrame
    $script:LokiSpinnerFrame++
    $line = "  {0}  {1}" -f $frame, $Label
    if ($line.Length -gt $script:LokiSpinnerMaxLen) { $script:LokiSpinnerMaxLen = $line.Length }
    Write-Host ("`r" + $line) -NoNewline -ForegroundColor DarkGreen
}

function Write-LokiSpinnerDone {
    if ([Console]::IsOutputRedirected) { return }
    # Cleared to the WIDEST line actually written, not to a guess. A label that grows while it ticks --
    # "5 %" becoming "100 %" -- would otherwise leave its own tail behind on the console.
    if ($script:LokiSpinnerMaxLen -le 0) { return }
    Write-Host ("`r{0}`r" -f (' ' * $script:LokiSpinnerMaxLen)) -NoNewline
    Initialize-LokiSpinner
}

# lib/keyread.ps1 -- reading the keyboard one key at a time, and knowing what each key MEANS
# (issue #133, slice 2).
#
# Every rule in this file was measured on a real console before it was written. None of it is
# inferred from documentation, and the three that matter most are counter-intuitive:
#
#   1. A single Read-Host hands Ctrl+C back to PowerShell.
#        set TreatControlCAsInput = $true, read back  ->  True
#        after ONE Read-Host, read back               ->  False
#        set again, then read Ctrl+C   ->  Key=C Char=^C Code=3 Mod=Control, delivered
#        Read-Host, then Ctrl+C without setting again ->  the process died
#      So the flag is asserted immediately before EVERY read, not once at startup. That is the only
#      form that survives a stray Read-Host anywhere else in the codebase, now or later.
#
#   2. AltGr reports itself as Alt AND Control, on a German layout:
#        @  Key=Q       Char=64   Mod=Alt, Control
#        [  Key=D8      Char=91   Mod=Alt, Control
#        \  Key=Oem4    Char=92   Mod=Alt, Control
#        |  Key=Oem102  Char=124  Mod=Alt, Control
#      A reader that treats "Control is set" as a shortcut swallows @ [ \ and | -- every one of
#      which occurs in paths and commands. KeyChar decides, not Modifiers. KeyChar is primary
#      because it also holds for layouts nobody here has measured.
#
#   3. Pasting is separable from typing, and NOT primarily by time:
#                          typing        pasting a 3-line block
#        keys                  23        61
#        gap min           74.33 ms      0.08 ms
#        gap max          470.66 ms      3.05 ms
#        next key already waiting?   0 of 23        59 of 61
#      The two paste exceptions are the first key (no predecessor) and the last (nothing follows).
#      So the discriminator is "was the next key already there when this one was read", which needs
#      no threshold at all and does not wobble on a slow patient machine. The gap is a backstop.
#      Line breaks inside a pasted block arrive as CR only, never LF -- 2 Enter keys for 3 lines.
#
# Contract. Same split as lib/screen.ps1: every decision pure and injected, because CI runs Pester
# in a process whose stdin is not a console -- exactly the condition under which this refuses.
#
#   PURE:
#   Get-LokiKeyreadCapability -HostName -InputRedirected -> @{ Engage; Reason }
#   Get-LokiKeyKind -KeyChar -> [string]        text | enter | backspace | escape | tab | control | key
#   Get-LokiControlLetter -KeyChar -> [string]  3 -> 'c', 21 -> 'u', 23 -> 'w'; '' when not a chord
#   Get-LokiInputSource -MoreWaiting -GapMs -> [string]   paste | typing
#   Get-LokiExitIntent -Kind -ControlLetter -Armed -> @{ Armed; Exit }
#
#   IMPURE -- four primitives, so a test can replace all four and still reach every path:
#   Request-LokiCtrlCInput -Enabled -> [bool]   named Request- not Set-, for the analyzer
#   Read-LokiRawKey -> [hashtable] or $null
#   Test-LokiKeyWaiting -> [bool]
#   Get-LokiKeyElapsed -> [double]            MILLISECONDS since the previous key; restarts the clock
#
#   Open-LokiKeyread -> [bool] / Read-LokiKey -> [pscustomobject] / Close-LokiKeyread
#   Test-LokiKeyreadOpen / Get-LokiKeyreadRefusal / Initialize-LokiKeyread
#
# WHAT IT NEVER DOES: it calls Read-Host nowhere, ever. Not as a convenience, not in an error path.
# That is rule 1 above, and it is a property of the whole file rather than of one function.
Set-StrictMode -Version Latest

# The backstop threshold, deliberately NOT the midpoint of the measured gap.
#
# Measured: the slowest interval inside a paste was 3.05 ms, the fastest between two keystrokes was
# 74.33 ms. The midpoint would be ~38.7 ms. This sits at 20 -- 6.5x above the slowest paste and 3.7x
# below the fastest keystroke -- because the two mistakes are not equally bad. Calling typing
# "paste" swallows the operator's Enter and the CLI feels broken; calling a paste "typing" submits
# one line early, which is annoying and recoverable. So the threshold leans toward typing.
$script:LokiKeyPasteGapMs = 20.0

$script:LokiKeyState   = $null      # $null = closed. Otherwise CtrlCWasOwned
$script:LokiKeyReason  = 'closed'
$script:LokiKeyClock   = $null

# ==============================================================================================
# PURE
# ==============================================================================================

function Get-LokiKeyreadCapability {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$HostName,
        [Parameter(Mandatory = $true)][bool]$InputRedirected
    )
    # PURE. Reading a key needs a real console on stdin; there is nothing to degrade to.
    #
    # Only stdin is asked about, unlike the screen's gate, which also refuses a redirected stdout.
    # A pipe on the way OUT does not stop a key coming IN, and refusing that would refuse a case
    # nobody has measured to be broken.
    $reason = 'ok'
    if     ($InputRedirected)            { $reason = 'redirected' }
    elseif ($HostName -ne 'ConsoleHost') { $reason = 'host' }

    return [pscustomobject]@{ Engage = ($reason -eq 'ok'); Reason = $reason }
}

function Get-LokiKeyKind {
    param([Parameter(Mandatory = $true)][int]$KeyChar)
    # PURE, and this is where the AltGr trap is disarmed: the decision reads ONLY the character.
    # Modifiers are not consulted at all, because on a German layout AltGr sets Alt AND Control
    # while producing a perfectly ordinary printable character.
    #
    # Order matters: the named editing keys are control codes too, and they are not chords.
    #   13 CR    every measured Enter, including the two inside a pasted 3-line block
    #    8 ^H    Backspace
    #   27 ESC   Escape
    #    9 TAB   Tab
    if ($KeyChar -eq 13) { return 'enter' }
    if ($KeyChar -eq 8)  { return 'backspace' }
    if ($KeyChar -eq 27) { return 'escape' }
    if ($KeyChar -eq 9)  { return 'tab' }
    if ($KeyChar -ge 32 -and $KeyChar -ne 127) { return 'text' }
    if ($KeyChar -gt 0) { return 'control' }
    # KeyChar 0 is a key with no character at all: measured for UpArrow, DownArrow, Home, End and
    # Delete. The caller dispatches those on the key NAME, which is the only thing they carry.
    return 'key'
}

function Get-LokiControlLetter {
    param([Parameter(Mandatory = $true)][int]$KeyChar)
    # PURE. Turns a control code into the letter it stands for, so the session loop can bind 'c'
    # rather than do arithmetic on 3. Measured: Ctrl+A 1, Ctrl+C 3, Ctrl+U 21, Ctrl+W 23.
    #
    # The four codes Get-LokiKeyKind claims first (8, 9, 13, 27) are deliberately NOT letters here:
    # Backspace is not Ctrl+H to an operator, whatever the code says. 127 (DEL, from Ctrl+Backspace)
    # has no letter either.
    if ($KeyChar -lt 1 -or $KeyChar -gt 26) { return '' }
    if ($KeyChar -eq 8 -or $KeyChar -eq 9 -or $KeyChar -eq 13) { return '' }
    return [string][char]([int][char]'a' + $KeyChar - 1)
}

function Get-LokiInputSource {
    param(
        [Parameter(Mandatory = $true)][bool]$MoreWaiting,
        [Parameter(Mandatory = $true)][double]$GapMs
    )
    # PURE. "Was the next key already waiting when this one was read" is the primary answer, and it
    # was perfect over 84 measured keys: 0 of 23 while typing, 59 of 61 while pasting. It needs no
    # threshold, so it cannot drift on a slower machine -- which matters, because the machine this
    # runs on is by definition a broken one.
    #
    # The gap is the backstop for the last key of a burst, where nothing is waiting any more but the
    # key still arrived microseconds after its predecessor.
    if ($MoreWaiting) { return 'paste' }
    if ($GapMs -ge 0 -and $GapMs -lt $script:LokiKeyPasteGapMs) { return 'paste' }
    return 'typing'
}

function Get-LokiExitIntent {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Kind,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ControlLetter,
        [Parameter(Mandatory = $true)][bool]$Armed
    )
    # PURE. The two-press exit, copied from the reference deliberately.
    #
    # One press exiting is the terminal norm and this breaks it on purpose: a session holds work in
    # progress, and a reflex keystroke should not throw a half-finished diagnosis away. Measured in
    # the reference's own output -- a grey "Press Ctrl-C again to exit" drawn on the hint row, then
    # teardown on the next press.
    #
    # ANY other key disarms. The reference's stream cannot say whether it disarms on a keystroke or
    # on a timer -- only its output was recorded, not its input -- so this takes the safer reading.
    # A Ctrl+C from ten minutes ago must not end the session on the next one.
    if ($Kind -eq 'control' -and $ControlLetter -eq 'c') {
        if ($Armed) { return [pscustomobject]@{ Armed = $false; Exit = $true } }
        return [pscustomobject]@{ Armed = $true; Exit = $false }
    }
    return [pscustomobject]@{ Armed = $false; Exit = $false }
}

# ==============================================================================================
# IMPURE. Four primitives, nothing else touches the console.
# ==============================================================================================

function Request-LokiCtrlCInput {
    param([Parameter(Mandatory = $true)][bool]$Enabled)
    # Named Request- rather than Set-: PSUseShouldProcessForStateChangingFunctions fires on Set-,
    # and lib/ui.ps1 already made the same trade for Move-LokiCursor.
    #
    # Reports failure instead of raising it. Without a console this throws "The handle is invalid",
    # and a diagnostic tool must not die because it could not claim a key.
    try {
        [Console]::TreatControlCAsInput = $Enabled
        return $true
    }
    catch { return $false }
}

function Read-LokiRawKey {
    # BLOCKS. Returns the three facts a key carries, as a plain hashtable, so a test can hand over a
    # scripted sequence without constructing ConsoleKeyInfo values.
    try {
        $k = [Console]::ReadKey($true)
        return @{
            Key       = [string]$k.Key
            KeyChar   = [int]$k.KeyChar
            Modifiers = [string]$k.Modifiers
        }
    }
    catch { return $null }
}

function Test-LokiKeyWaiting {
    # Is the next key already in the buffer? Sampled immediately after a read, this is the whole
    # paste detector. Never throws: a redirected stdin raises here.
    try { return [bool][Console]::KeyAvailable }
    catch { return $false }
}

function Get-LokiKeyElapsed {
    # Milliseconds since the previous key, then restarts the clock. Returns -1 for the first key of
    # a session, which Get-LokiInputSource reads as "no evidence" rather than as "instant".
    if ($null -eq $script:LokiKeyClock) {
        $script:LokiKeyClock = New-Object System.Diagnostics.Stopwatch
        $script:LokiKeyClock.Start()
        return -1.0
    }
    $ms = $script:LokiKeyClock.Elapsed.TotalMilliseconds
    $script:LokiKeyClock.Restart()
    return [double]$ms
}

function Test-LokiKeyreadOpen { return ($null -ne $script:LokiKeyState) }

function Get-LokiKeyreadRefusal { return [string]$script:LokiKeyReason }

function Initialize-LokiKeyread {
    # Back to the state a fresh process starts in, matching Initialize-LokiUi / Initialize-LokiRegion
    # / Initialize-LokiScreen.
    Close-LokiKeyread
    $script:LokiKeyReason = 'closed'
    $script:LokiKeyClock = $null
}

function Open-LokiKeyread {
    # Returns $true only if keys can be read. EVERY caller must cope with $false -- that is the
    # normal answer under redirection and in CI.
    Close-LokiKeyread

    $hostName = ''
    $redirected = $true
    try {
        $hostName = [string]$Host.Name
        $redirected = [bool][Console]::IsInputRedirected
    }
    catch {
        $script:LokiKeyReason = 'no-console'
        return $false
    }

    $capability = Get-LokiKeyreadCapability -HostName $hostName -InputRedirected $redirected
    $script:LokiKeyReason = [string]$capability.Reason
    if (-not $capability.Engage) { return $false }

    # Remember what it was, so Close puts it back rather than assuming it was off. It was False on
    # every console measured, but assuming that is how a tool leaves a machine changed.
    $was = $false
    try { $was = [bool][Console]::TreatControlCAsInput } catch { $was = $false }

    if (-not (Request-LokiCtrlCInput -Enabled $true)) {
        $script:LokiKeyReason = 'no-ctrl-c'
        return $false
    }

    $script:LokiKeyState = @{ CtrlCWasOwned = $was }
    $script:LokiKeyClock = $null
    return $true
}

function Read-LokiKey {
    # One key, classified. Returns $null when nothing can be read.
    if ($null -eq $script:LokiKeyState) { return $null }

    # EVERY time, not once at open. Measured: one Read-Host anywhere gives Ctrl+C back to
    # PowerShell, and the next Ctrl+C then kills the process instead of arriving here. Loki calls
    # no Read-Host itself, but this file cannot police what a command it dispatches does.
    [void](Request-LokiCtrlCInput -Enabled $true)

    $raw = Read-LokiRawKey
    if ($null -eq $raw) { return $null }

    # Order matters: ask whether more is waiting BEFORE anything slow happens, or a fast typist
    # starts looking like a paste.
    $more = Test-LokiKeyWaiting
    $gap = Get-LokiKeyElapsed

    $char = [int]$raw.KeyChar
    $kind = Get-LokiKeyKind -KeyChar $char

    return [pscustomobject]@{
        Kind          = $kind
        Char          = $char
        Text          = $(if ($kind -eq 'text') { [string][char]$char } else { '' })
        Key           = [string]$raw.Key
        Modifiers     = [string]$raw.Modifiers
        ControlLetter = Get-LokiControlLetter -KeyChar $char
        Source        = Get-LokiInputSource -MoreWaiting $more -GapMs $gap
        MoreWaiting   = $more
        GapMs         = $gap
    }
}

function Close-LokiKeyread {
    if ($null -eq $script:LokiKeyState) { return }
    # State cleared FIRST, so nothing below can re-enter.
    $state = $script:LokiKeyState
    $script:LokiKeyState = $null
    $script:LokiKeyReason = 'closed'
    [void](Request-LokiCtrlCInput -Enabled ([bool]$state.CtrlCWasOwned))
}

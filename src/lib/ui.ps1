# lib/ui.ps1 — Ausgabe & Farbe (5.1-robust)
# Contract:
#   Initialize-LokiUi [-NoColor]       Farbmodus bestimmen (NO_COLOR-Env + --no-color respektiert)
#   Write-LokiLine  [-Text]            neutrale Zeile
#   Write-LokiInfo/Ok/Warn/Err -Text   farbige Semantik (Warn/Err -> stderr)
#   Write-LokiHeading -Text            Abschnittsüberschrift
#   Test-LokiEncodingSupport -Encoding <Encoding> -Text <string> -> [bool]   PURE round-trip probe
#   Resolve-LokiGlyphTier -Encoding <Encoding> -> 'rich' | 'oem' | 'ascii'    PURE
#   Get-LokiGlyphTier / Get-LokiGlyph -Name <string>                          current tier and its glyph
#   Write-LokiConsole -Text <string> [-Color] [-NoNewline]                    the ONLY Write-Host; fires NO hook
#   Write-LokiRaw -Text <string> [-Color] [-NoNewline]                        hook first, then Write-LokiConsole
#   Register-LokiWriteHook -Hook <scriptblock>                                what must run before ordinary output
#   Invoke-LokiWriteHook / Get-LokiWriteHookError                             fires it once; records a throw
#   Move-LokiCursor -Row <int> -> [bool]                                      absolute cursor move, $false on refusal
# Nutzt Write-Host -ForegroundColor (kein VT nötig -> funktioniert auf Alt-Konsolen); Fehler/Warnungen zusätzlich nach stderr.
Set-StrictMode -Version Latest

$script:LokiUseColor = $true

function Initialize-LokiUi {
    param([switch]$NoColor, [AllowNull()]$Encoding = $null)
    $disabled = $NoColor.IsPresent -or (-not [string]::IsNullOrEmpty($env:NO_COLOR))
    $script:LokiUseColor = -not $disabled

    $enc = $Encoding
    if ($null -eq $enc) {
        # Guarded: a UI layer that throws while initialising takes the whole CLI down with it, and this
        # runs before anything can report the failure.
        try { $enc = [Console]::OutputEncoding } catch { $enc = $null }
    }
    $script:LokiGlyphTier = Resolve-LokiGlyphTier -Encoding $enc
}

# Getter fuer den Farbmodus (Testbarkeit; keine Business-Logik im Zustand).
function Get-LokiUseColor { return $script:LokiUseColor }

function Write-LokiLine {
    param([string]$Text = '')
    Write-LokiRaw -Text $Text
}

function Write-LokiColor {
    param([string]$Text, [System.ConsoleColor]$Color)
    Write-LokiRaw -Text $Text -Color $Color
}

# --- the write seam (issue #130) ------------------------------------------------------------------------------
# Every console write in Loki funnels through these two functions, because a live region and ordinary output cannot
# both own the cursor. The hook is $null by default, so with no region open the bytes leaving this file are exactly
# what they were before the seam existed -- which is what the dispatcher's bare-loki-equals-loki-guide byte-identity
# test measures.
#
# Write-LokiConsole is the ONLY Write-Host in the codebase and it does NOT fire the hook: it is what the region
# itself draws with, and a region redrawing through a hook that closes the region is a loop, not a feature.
$script:LokiWriteHook = $null
$script:LokiWriteHookError = ''

function Register-LokiWriteHook {
    param([Parameter(Mandatory = $true)][AllowNull()][scriptblock]$Hook)
    $script:LokiWriteHook = $Hook
}

function Invoke-LokiWriteHook {
    # Cleared BEFORE the hook runs: whatever it does, it cannot re-enter through its own writes.
    if ($null -eq $script:LokiWriteHook) { return }
    $hook = $script:LokiWriteHook
    $script:LokiWriteHook = $null
    # A hook that throws must not take the ordinary output with it -- but it must not vanish either. A live region
    # broken for months that leaves no trace is a bug nobody goes looking for.
    try { & $hook } catch { $script:LokiWriteHookError = [string]$_.Exception.Message }
}

function Get-LokiWriteHookError { return $script:LokiWriteHookError }

function Write-LokiConsole {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [AllowNull()]$Color = $null,
        [switch]$NoNewline
    )
    $withColor = ($script:LokiUseColor -and $null -ne $Color)
    if ($withColor) {
        if ($NoNewline) { Write-Host $Text -ForegroundColor $Color -NoNewline } else { Write-Host $Text -ForegroundColor $Color }
    }
    else {
        if ($NoNewline) { Write-Host $Text -NoNewline } else { Write-Host $Text }
    }
}

function Write-LokiRaw {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [AllowNull()]$Color = $null,
        [switch]$NoNewline
    )
    Invoke-LokiWriteHook
    Write-LokiConsole -Text $Text -Color $Color -NoNewline:$NoNewline
}

function Move-LokiCursor {
    param([Parameter(Mandatory = $true)][int]$Row)
    # The only absolute cursor move in Loki, and it reports failure instead of raising it: the console APIs throw
    # when output is redirected, and a diagnostic tool that dies while drawing a decoration is worse than one that
    # simply stops decorating. Named Move- rather than Set- on purpose (PSUseShouldProcessForStateChangingFunctions).
    if ($Row -lt 0) { return $false }
    try {
        [Console]::SetCursorPosition(0, $Row)
        return $true
    }
    catch { return $false }
}

function Write-LokiInfo { param([string]$Text) Write-LokiColor -Text $Text -Color Cyan }
function Write-LokiOk   { param([string]$Text) Write-LokiColor -Text "$(Get-LokiGlyph 'ok') $Text" -Color Green }

# Diagnostik (Warn/Err) geht auf stderr (fd 2) — EINMAL, farbig wenn ein Terminal dranhaengt.
# Kein Write-Host-Duplikat: sonst erscheint die Meldung interaktiv doppelt und landet nicht sauber auf stderr.
function Write-LokiToStdErr {
    param([string]$Text, [System.ConsoleColor]$Color)
    # stderr bypasses Write-Host entirely, so it would otherwise print straight through an open live region -- and
    # Write-LokiErr alone appears on dozens of source lines. The region closes first, exactly as for stdout.
    Invoke-LokiWriteHook
    if (-not $script:LokiUseColor -or [Console]::IsErrorRedirected) {
        [Console]::Error.WriteLine($Text)
        return
    }
    $prev = [Console]::ForegroundColor
    try {
        [Console]::ForegroundColor = $Color
        [Console]::Error.WriteLine($Text)
    }
    finally {
        [Console]::ForegroundColor = $prev
    }
}

function Write-LokiWarn { param([string]$Text) Write-LokiToStdErr -Text "! $Text" -Color Yellow }
function Write-LokiErr  { param([string]$Text) Write-LokiToStdErr -Text "x $Text" -Color Red }

function Write-LokiHeading {
    param([string]$Text)
    Write-LokiColor -Text $Text -Color White
}

# --- glyph capability (issue #121) ---------------------------------------------------------------------------
# Colour and glyphs are TWO capabilities and they fail differently. Colour degrades quietly to plain text; a glyph
# the console's code page cannot represent is silently SUBSTITUTED -- U+2713 comes back as the letter "V" on CP850,
# which is what a German Windows console runs by default. Measured with a round trip, not assumed.
#
# DETECT, NEVER MUTATE. Setting [Console]::OutputEncoding calls SetConsoleOutputCP, which changes the CONSOLE --
# shared with the parent shell, and still changed after Loki exits. Repainting the operator's console to draw a
# nicer tick is exactly the app-level trace this tool promises not to leave, and a hard kill would skip any
# restore. It would not even be sufficient: font coverage is a separate question from encoding. So Loki asks what
# the console can show and adapts to the answer.
$script:LokiGlyphTier = 'ascii'   # fail-closed until Initialize-LokiUi says otherwise: ascii renders everywhere

$script:LokiGlyphs = @{
    ok = @{ rich = ([char]0x2713); oem = ([char]0x00BB); ascii = '>' }
}

function Test-LokiEncodingSupport {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Encoding,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    # PURE. "Did it come back unchanged" is the only reliable question: an unrepresentable character does not
    # always become '?'. CP850 best-fits U+2713 to 'V' and U+2248 to '~', so checking for a question mark would
    # report those as supported.
    if ($null -eq $Encoding) { return $false }
    try { return ($Encoding.GetString($Encoding.GetBytes($Text)) -eq $Text) } catch { return $false }
}

function Resolve-LokiGlyphTier {
    param([Parameter(Mandatory = $true)][AllowNull()]$Encoding)
    # PURE, richest first, first survivor wins. The probes are the cheapest characters that distinguish the tiers:
    # a tick and an arrow exist only in Unicode-capable encodings; a full block and a box-drawing line exist in the
    # DOS OEM pages (850, 437) but not in CP1252.
    if (Test-LokiEncodingSupport -Encoding $Encoding -Text ([string][char]0x2713 + [char]0x2192)) { return 'rich' }
    if (Test-LokiEncodingSupport -Encoding $Encoding -Text ([string][char]0x2588 + [char]0x2500)) { return 'oem' }
    return 'ascii'
}

# Getter for the glyph tier (testability; no business logic in the state).
function Get-LokiGlyphTier { return $script:LokiGlyphTier }

function Get-LokiGlyph {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not $script:LokiGlyphs.ContainsKey($Name)) { throw "Unknown glyph '$Name'." }
    return [string]$script:LokiGlyphs[$Name][$script:LokiGlyphTier]
}

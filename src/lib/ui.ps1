# lib/ui.ps1 — Ausgabe & Farbe (5.1-robust)
# Contract:
#   Initialize-LokiUi [-NoColor]       Farbmodus bestimmen (NO_COLOR-Env + --no-color respektiert)
#   Write-LokiLine  [-Text]            neutrale Zeile
#   Write-LokiInfo/Ok/Warn/Err -Text   farbige Semantik (Warn/Err -> stderr)
#   Write-LokiHeading -Text            Abschnittsüberschrift
# Nutzt Write-Host -ForegroundColor (kein VT nötig -> funktioniert auf Alt-Konsolen); Fehler/Warnungen zusätzlich nach stderr.
Set-StrictMode -Version Latest

$script:LokiUseColor = $true

function Initialize-LokiUi {
    param([switch]$NoColor)
    $disabled = $NoColor.IsPresent -or (-not [string]::IsNullOrEmpty($env:NO_COLOR))
    $script:LokiUseColor = -not $disabled
}

# Getter fuer den Farbmodus (Testbarkeit; keine Business-Logik im Zustand).
function Get-LokiUseColor { return $script:LokiUseColor }

function Write-LokiLine {
    param([string]$Text = '')
    Write-Host $Text
}

function Write-LokiColor {
    param([string]$Text, [System.ConsoleColor]$Color)
    if ($script:LokiUseColor) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
}

function Write-LokiInfo { param([string]$Text) Write-LokiColor -Text $Text -Color Cyan }
function Write-LokiOk   { param([string]$Text) Write-LokiColor -Text "$([char]0x2713) $Text" -Color Green }

# Diagnostik (Warn/Err) geht auf stderr (fd 2) — EINMAL, farbig wenn ein Terminal dranhaengt.
# Kein Write-Host-Duplikat: sonst erscheint die Meldung interaktiv doppelt und landet nicht sauber auf stderr.
function Write-LokiToStdErr {
    param([string]$Text, [System.ConsoleColor]$Color)
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

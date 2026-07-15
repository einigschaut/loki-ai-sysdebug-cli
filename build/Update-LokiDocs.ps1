# build/Update-LokiDocs.ps1 — regenerate the generated doc blocks from the command registry (CLAUDE.md §3/§7).
# Writes the README command table between the GENERATED COMMANDS markers so the docs can never drift from the
# registry (the missing half of the §7 docs gate). tests\docs.Tests.ps1 runs this with -Check and fails the
# build if README is stale. Bootstrap mirrors the dispatcher: auto-load lib -> commands -> i18n (en) -> registry.
# Usage:
#   powershell -File build\Update-LokiDocs.ps1            # rewrite README.md in place
#   powershell -File build\Update-LokiDocs.ps1 -Check     # exit 1 (no write) if README.md is stale (CI/gate use)
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [switch]$Check
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# $PSScriptRoot is unreliable (empty) in a param default under 5.1 -> resolve it in the body.
if ([string]::IsNullOrEmpty($RepoRoot)) { $RepoRoot = Split-Path $PSScriptRoot -Parent }
$src        = Join-Path $RepoRoot 'src'
$readmePath = Join-Path $RepoRoot 'README.md'
$beginMarker = '<!-- BEGIN GENERATED COMMANDS (build/Update-LokiDocs.ps1 -- do not edit by hand) -->'
$endMarker   = '<!-- END GENERATED COMMANDS -->'

# Bootstrap the registry exactly like src\loki.ps1 (lib modules have no load-time deps; commands define the
# Get-LokiCmdMeta_* functions the registry enumerates). Locale pinned to en -> README is English.
Get-ChildItem -LiteralPath (Join-Path $src 'lib') -Filter '*.ps1' -File | Sort-Object Name | ForEach-Object { . $_.FullName }
Get-ChildItem -LiteralPath (Join-Path $src 'commands') -Filter '*.ps1' -File | Sort-Object Name | ForEach-Object { . $_.FullName }
Initialize-LokiI18n -AppRoot $src -Locale 'en' | Out-Null
$registry = Get-LokiCommandRegistry
$table = Format-LokiCommandTable -Registry $registry

# -Encoding UTF8 is mandatory (CLAUDE.md §1): 5.1's default Get-Content reads a BOM-less UTF-8 file as ANSI,
# which mangles non-ASCII (em dashes etc.) and would then be written back double-encoded.
$readme = Get-Content -LiteralPath $readmePath -Raw -Encoding UTF8
# Match the README's dominant newline so the spliced block never mixes CRLF/LF (Windows checkout is CRLF).
$nl = "`n"
if ($readme -like "*`r`n*") { $nl = "`r`n" }
$tableNorm = ($table -replace "`r`n", "`n") -replace "`n", $nl
$block = $beginMarker + $nl + $nl + $tableNorm + $nl + $nl + $endMarker

$bi = $readme.IndexOf($beginMarker)
$ei = $readme.IndexOf($endMarker)
if ($bi -lt 0 -or $ei -lt 0 -or $ei -lt $bi) {
    Write-Host 'Update-LokiDocs: GENERATED COMMANDS markers not found (or out of order) in README.md.'
    exit 2
}
$before  = $readme.Substring(0, $bi)
$after   = $readme.Substring($ei + $endMarker.Length)
$updated = $before + $block + $after

if ($Check) {
    if ($updated -ceq $readme) {
        Write-Host 'Docs gate: README command table is up to date.'
        exit 0
    }
    Write-Host 'Docs gate: README command table is STALE -- run build\Update-LokiDocs.ps1 to regenerate.'
    exit 1
}

# Write mode: BOM-less UTF-8 (README is Markdown and must not carry a BOM).
[System.IO.File]::WriteAllText($readmePath, $updated, (New-Object System.Text.UTF8Encoding($false)))
Write-Host 'Update-LokiDocs: README.md command table regenerated.'

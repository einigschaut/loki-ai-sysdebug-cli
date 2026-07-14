# lib/meta.ps1 — app metadata (version, root resolution)
# Contract:
#   Get-LokiVersion -AppRoot <dir>   returns the product version (trimmed); '0.0.0-unknown' if no version.txt
# The version lives in a plain-text SemVer file `version.txt` (the single source of truth, bumped only by
# release-please; see ADR-0005). It sits next to loki.ps1 (AppRoot) on the stick, and one level up in the
# repo (repo root). Both locations are tried.
Set-StrictMode -Version Latest

function Get-LokiVersion {
    param([Parameter(Mandatory = $true)][string]$AppRoot)
    $candidates = @(
        (Join-Path $AppRoot 'version.txt'),
        (Join-Path (Split-Path $AppRoot -Parent) 'version.txt')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) {
            return (Get-Content -LiteralPath $c -Raw -Encoding utf8).Trim()
        }
    }
    return '0.0.0-unknown'
}

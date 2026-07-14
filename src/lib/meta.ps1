# lib/meta.ps1 — app metadata (version, root resolution)
# Contract:
#   Get-LokiVersion -AppRoot <dir>   returns the product version (trimmed); '0.0.0-unknown' if no VERSION file
# VERSION lives on the stick next to loki.ps1 (AppRoot), one level up in the repo (repo root). Both locations are tried.
Set-StrictMode -Version Latest

function Get-LokiVersion {
    param([Parameter(Mandatory = $true)][string]$AppRoot)
    $candidates = @(
        (Join-Path $AppRoot 'VERSION'),
        (Join-Path (Split-Path $AppRoot -Parent) 'VERSION')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) {
            return (Get-Content -LiteralPath $c -Raw -Encoding utf8).Trim()
        }
    }
    return '0.0.0-unknown'
}

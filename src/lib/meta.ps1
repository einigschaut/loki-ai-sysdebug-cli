# lib/meta.ps1 — app metadata (version, root resolution)
# Contract:
#   Get-LokiVersion -AppRoot <dir>   returns the product version (trimmed); '0.0.0-unknown' if no version.txt
#   Get-LokiStickBuildInfo -AppRoot <dir>  -> @{ BuiltUtc; SourceVersion } from stick-build.json, or $null (#91)
#   Get-LokiStickAgeDays -BuiltUtc <iso> -Now <datetime>  -> whole days old (>=0), or $null if unparseable (PURE)
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

function Get-LokiStickBuildInfo {
    <#
        Read the build stamp New-LokiStick.ps1 writes to stick-build.json at the stick root (#91), so an
        operator can tell how old the stick in their pocket is. Returns @{ BuiltUtc; SourceVersion } or $null.

        $null is the ORDINARY case in a repo checkout -- the file is written only when a stick is BUILT, not
        for src\ itself -- so a missing or unreadable file is silence, never an error: `status` simply omits
        the line. The timestamp is read as a STRING and left unparsed here; the age math is the pure function
        below. (Reading it as [datetime] via ConvertFrom-Json would be fine, but keeping it a string keeps the
        ConvertTo/From-Json DateTime quirks out of this seam entirely.)
    #>
    param([Parameter(Mandatory = $true)][string]$AppRoot)
    $path = Join-Path $AppRoot 'stick-build.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding utf8
        $obj = $raw | ConvertFrom-Json
    }
    catch { return $null }   # a corrupt stamp is not worth failing a write-free status over
    $built = [string](Get-LokiMetaProp -Object $obj -Name 'builtUtc')
    if ([string]::IsNullOrWhiteSpace($built)) { return $null }
    return @{
        BuiltUtc      = $built
        SourceVersion = [string](Get-LokiMetaProp -Object $obj -Name 'sourceVersion')
    }
}

function Get-LokiStickAgeDays {
    <#
        PURE. Whole days between an ISO-8601 build timestamp and a caller-supplied "now" -- $Now is a parameter,
        NOT Get-Date, so the age is deterministic and table-testable. Parses invariantly (AssumeUniversal so a
        bare 'Z' or offset is honoured); an unparseable stamp returns $null rather than throwing (a bad stamp
        must not break a write-free status). Clamped at 0: a stick cannot be built in the future, so a skewed
        clock reads as "today", never as a negative age.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = '"Days" is the UNIT of the returned count (an age in days), not a collection; the plural is the accurate name.')]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$BuiltUtc,
        [Parameter(Mandatory = $true)][datetime]$Now
    )
    $dto = [System.DateTimeOffset]::MinValue
    $ok = [System.DateTimeOffset]::TryParse(
        $BuiltUtc, [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$dto)
    if (-not $ok) { return $null }
    $days = [math]::Floor((($Now.ToUniversalTime()) - $dto.UtcDateTime).TotalDays)
    if ($days -lt 0) { $days = 0 }
    return [int]$days
}

function Get-LokiMetaProp {
    # StrictMode-safe property read off a ConvertFrom-Json PSCustomObject (a missing property throws under
    # StrictMode). Same shape as Get-LokiJsonProp in lib/claude.ps1, kept local so lib/meta.ps1 stays
    # dependency-free (it is dot-sourced very early).
    param([Parameter(Mandatory = $true)][AllowNull()]$Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

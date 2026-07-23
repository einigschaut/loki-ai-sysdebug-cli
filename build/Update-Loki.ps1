<#
.SYNOPSIS
    Update a git-less Loki checkout to a newer release, verifying it before trusting it.

.DESCRIPTION
    The companion to `git pull` for a technician who took the ZIP path (README "Without git"). It
    fetches a release archive, VERIFIES it, and expands it BESIDE the current tree -- never over it.

    Beside, not over, is the whole point: this script lives inside the tree it is updating, so
    unpacking on top of itself could replace the very file mid-run. Instead it writes a sibling
    directory `loki-<tag>\` and tells you to switch into it. The old tree stays intact as a rollback.

    VERIFICATION, in order, fail-closed:
      1. SHA256 of the download vs the published `.sha256` sidecar. A mismatch deletes the download
         and stops -- an unverified archive is never left on disk (the fail-closed rule that
         Invoke-LokiVerifiedDownload learned the hard way; see lib/download.ps1 and ADR-0026).
      2. Build-provenance attestation via `gh attestation verify` -- the REAL trust anchor (ADR-0028).
         The sidecar sits on the same host as the archive, so a checksum alone proves only that the
         bytes arrived intact, not that GitHub built them. If the GitHub CLI is present this is
         mandatory and a failure stops the update; if `gh` is absent the script says plainly that
         only transport integrity was checked and prints the manual command, rather than pretending.

    This is a PREPARATION-MACHINE tool, like New-LokiStick.ps1 and setup -- it reaches the network
    and writes files, which is exactly why it is a build script and NOT a `loki` command behind the
    footprint gate. It never runs on a machine being diagnosed.

    Standalone by design: it dot-sources nothing from lib\, because it may run against an OLD tree
    whose lib\ contracts differ from the release being fetched. The pure judgements below
    (hash match, target resolution) are split out so they are table-testable without the network
    (tests\update-loki.Tests.ps1); the impure orchestration stays thin.

.PARAMETER Tag
    The release tag to fetch, e.g. v0.14.0. Default: the repository's latest release.

.PARAMETER Destination
    Where to expand the new tree. The archive carries a `loki-<tag>\` prefix, so the result is
    <Destination>\loki-<tag>\. Default: the parent of the current checkout, i.e. right next to it.

.PARAMETER Repo
    owner/name of the GitHub repository. Default: einigschaut/loki-ai-sysdebug-cli.

.PARAMETER Force
    Overwrite an already-existing <Destination>\loki-<tag>\ target. Off by default.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File build\Update-Loki.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File build\Update-Loki.ps1 -Tag v0.14.0 -Destination D:\tools
#>
[CmdletBinding()]
param(
    [string]$Tag,
    [string]$Destination,
    [string]$Repo = 'einigschaut/loki-ai-sysdebug-cli',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- pure judgements (no network, no filesystem) -- table-tested in tests\update-loki.Tests.ps1 ----

function Get-LokiUpdateExpectedHash {
    <#
        PURE. Pull the SHA256 out of the `.sha256` sidecar. Deliberately format-TOLERANT: it takes
        the first 64-hex-character run anywhere in the text, so it reads both the human-readable
        sidecar the release workflow writes today (`sha256:  <hash>` ...) and the plain
        `sha256sum`-style `<hash>  <file>` form, and does not break if that format is ever changed.
        Fail-closed: no 64-hex run -> throw, because "could not find the hash" must never be
        indistinguishable from "the hash matched".
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$SidecarText)
    $m = [regex]::Match($SidecarText, '[0-9a-fA-F]{64}')
    if (-not $m.Success) {
        throw "Checksum sidecar does not contain a SHA256 (no 64-hex value found). Refusing to proceed unverified."
    }
    return $m.Value.ToLowerInvariant()
}

function Test-LokiHashMatch {
    <#
        PURE. Ordinal, case-insensitive equality of two hex digests. Ordinal on purpose: a hash is
        ASCII hex, and culture-aware comparison is both meaningless here and a known 5.1 trap
        (tr-TR folds 'I' oddly -- see the culture notes in lib/allowlist and tests\culture).
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Expected,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Actual
    )
    if ([string]::IsNullOrWhiteSpace($Expected) -or [string]::IsNullOrWhiteSpace($Actual)) { return $false }
    return [string]::Equals($Expected.Trim(), $Actual.Trim(), [System.StringComparison]::OrdinalIgnoreCase)
}

function Resolve-LokiUpdateTarget {
    <#
        PURE. Decide where the new tree lands and REFUSE the cases that would clobber the running
        one. Returns @{ TargetDir; ArchiveName }. The refusal is the safety property: expanding onto
        the current checkout could overwrite this very script mid-run, so a target equal to -- or
        containing, or contained by -- the running tree is rejected. Comparison is ordinal with a
        trailing separator on both sides, so 'C:\loki' is not seen as a prefix of 'C:\loki-v2'.

        PRECONDITION: -Destination and -RepoRoot are already-resolved absolute paths (the caller runs
        Resolve-Path first). This matters because [IO.Path]::Combine('C:', 'x') yields the
        drive-relative 'C:x', not 'C:\x' -- a normalised path like 'C:\' avoids that trap.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )
    $targetDir = [System.IO.Path]::Combine($Destination, "loki-$Tag")

    # Normalise to compare paths as strings without needing them to exist (Combine is pure; Test-Path/Resolve are not).
    $t = $targetDir.TrimEnd('\', '/') + '\'
    $r = $RepoRoot.TrimEnd('\', '/') + '\'
    $cmp = [System.StringComparison]::OrdinalIgnoreCase
    if ($t.Equals($r, $cmp) -or $t.StartsWith($r, $cmp) -or $r.StartsWith($t, $cmp)) {
        throw "Refusing to expand into the running checkout ($RepoRoot). The new tree must be a SEPARATE directory; " +
              "pick a -Destination outside it (default is the checkout's parent)."
    }
    return @{ TargetDir = $targetDir; ArchiveName = "loki-$Tag.zip" }
}

# ---- impure orchestration (network + filesystem) ---------------------------------------------------

function Get-LokiLatestReleaseTag {
    # IMPURE. Ask the GitHub API for the latest release tag. api.github.com REQUIRES a User-Agent or
    # answers 403; the endpoint is public, so no token is needed (60 req/h unauthenticated is ample).
    param([Parameter(Mandatory = $true)][string]$Repo)
    $uri = "https://api.github.com/repos/$Repo/releases/latest"
    $resp = Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = 'loki-update' } -TimeoutSec 30
    if ([string]::IsNullOrWhiteSpace([string]$resp.tag_name)) {
        throw "GitHub returned no tag_name for the latest release of $Repo."
    }
    return [string]$resp.tag_name
}

function Invoke-LokiUpdate {
    param(
        [string]$Tag,
        [string]$Destination,
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [switch]$Force
    )
    # TLS 1.2: 5.1's Invoke-WebRequest can default to TLS 1.0/1.1, which github.com refuses -- a
    # classic 5.1 trap that surfaces as an opaque "could not create SSL/TLS secure channel".
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

    $currentVersion = ''
    $versionFile = Join-Path $RepoRoot 'version.txt'
    if (Test-Path -LiteralPath $versionFile) { $currentVersion = (Get-Content -LiteralPath $versionFile -Raw).Trim() }

    if ([string]::IsNullOrWhiteSpace($Tag)) {
        Write-Host "Resolving the latest release of $Repo ..."
        $Tag = Get-LokiLatestReleaseTag -Repo $Repo
    }
    Write-Host ("  current : {0}" -f $(if ($currentVersion) { $currentVersion } else { '(unknown)' }))
    Write-Host ("  target  : {0}" -f $Tag)

    # "Already there" is worth saying, not silently redoing. version.txt has no leading 'v'; the tag does.
    if ($currentVersion -and ($Tag.TrimStart('v') -eq $currentVersion) -and -not $Force) {
        Write-Host "This checkout is already $Tag. Nothing to do (pass -Force to fetch it anyway)."
        return
    }

    if ([string]::IsNullOrWhiteSpace($Destination)) { $Destination = Split-Path -Parent $RepoRoot }
    if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Force -Path $Destination | Out-Null }
    $Destination = (Resolve-Path -LiteralPath $Destination).Path

    $plan = Resolve-LokiUpdateTarget -Destination $Destination -Tag $Tag -RepoRoot $RepoRoot
    $targetDir = $plan.TargetDir
    $archiveName = $plan.ArchiveName
    if ((Test-Path -LiteralPath $targetDir) -and -not $Force) {
        throw "Target already exists: $targetDir. Delete it or pass -Force. (Loki does not overwrite an existing tree.)"
    }

    $base = "https://github.com/$Repo/releases/download/$Tag"
    $zipPath = Join-Path $Destination $archiveName
    $sidecarPath = "$zipPath.sha256"

    Write-Host "Downloading $archiveName + checksum ..."
    Invoke-WebRequest -Uri "$base/$archiveName" -OutFile $zipPath -Headers @{ 'User-Agent' = 'loki-update' } -TimeoutSec 120
    Invoke-WebRequest -Uri "$base/$archiveName.sha256" -OutFile $sidecarPath -Headers @{ 'User-Agent' = 'loki-update' } -TimeoutSec 30

    # --- 1) checksum (transport integrity), fail-closed ---
    $expected = Get-LokiUpdateExpectedHash -SidecarText (Get-Content -LiteralPath $sidecarPath -Raw)
    $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    if (-not (Test-LokiHashMatch -Expected $expected -Actual $actual)) {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        throw "SHA256 mismatch: the download does not match the published checksum. Deleted the archive; nothing was changed."
    }
    Write-Host ("  checksum OK ({0})" -f $actual.ToLowerInvariant())

    # --- 2) provenance attestation (the real anchor) ---
    $gh = Get-Command -Name 'gh' -CommandType Application -ErrorAction SilentlyContinue
    if ($gh) {
        Write-Host "Verifying build provenance (gh attestation verify) ..."
        # Native command: let a non-zero exit be the signal; do NOT merge stderr into the success
        # stream under Stop (a 5.1 trap that turns tool chatter into a terminating error).
        & $gh.Source attestation verify $zipPath -R $Repo
        if ($LASTEXITCODE -ne 0) {
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
            throw "Provenance attestation FAILED for $archiveName. This is not a download glitch -- the archive is not a build of $Repo. Deleted it; nothing was changed."
        }
        Write-Host "  provenance OK -- GitHub built this archive from $Repo."
    }
    else {
        Write-Host ""
        Write-Host "  WARNING: the GitHub CLI (gh) is not installed, so ONLY transport integrity (the" -ForegroundColor Yellow
        Write-Host "           checksum) was verified -- NOT that GitHub actually built this archive." -ForegroundColor Yellow
        Write-Host "           To verify provenance, install gh and run:" -ForegroundColor Yellow
        Write-Host ("             gh attestation verify `"{0}`" -R {1}" -f $zipPath, $Repo) -ForegroundColor Yellow
        Write-Host ""
    }

    # --- expand BESIDE, never over ---
    Write-Host "Expanding to $targetDir ..."
    if ((Test-Path -LiteralPath $targetDir) -and $Force) { Remove-Item -LiteralPath $targetDir -Recurse -Force }
    Expand-Archive -LiteralPath $zipPath -DestinationPath $Destination -Force

    Write-Host ""
    Write-Host ("Loki {0} is unpacked next to your current checkout:" -f $Tag)
    Write-Host ("    {0}" -f $targetDir)
    Write-Host "Your old checkout is untouched. To switch to the new one:"
    Write-Host ("    cd `"{0}`"" -f $targetDir)
    Write-Host "Then rebuild any sticks from it:"
    Write-Host "    powershell -ExecutionPolicy Bypass -File build\New-LokiStick.ps1 -Destination E:\"
}

# Run ONLY when invoked directly (powershell -File / &), NOT when a test dot-sources this file to
# reach the pure functions above. Verified under 5.1: dot-source sets InvocationName to '.', while
# -File and & set it to the path / '&'. (Same guard other build scripts could adopt.)
if ($MyInvocation.InvocationName -ne '.') {
    $repoRoot = Split-Path -Parent $PSScriptRoot   # $PSScriptRoot is empty in a param() default under 5.1
    Invoke-LokiUpdate -Tag $Tag -Destination $Destination -Repo $Repo -RepoRoot $repoRoot -Force:$Force
    exit 0
}

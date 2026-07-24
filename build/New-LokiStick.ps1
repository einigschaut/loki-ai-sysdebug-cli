<#
.SYNOPSIS
    Produce the deployed Loki artifact (the stick) from this repository.

.DESCRIPTION
    DESIGN.md section 2 describes the stick layout and then says, plainly: "The layout above is the deployed
    artifact, produced from the repository by a build script -- it is not assembled by hand." This is that script.
    Until it existed the sentence was aspirational, sticks were assembled by hand, and the first hand-assembly
    promptly stripped a UTF-8 BOM off an i18n catalog -- exactly the mojibake failure CLAUDE.md section 1 warns
    about. Copy-Item moves bytes; a human with Set-Content does not.

    WHAT IT WRITES: everything under src\ (the dispatcher, its entry point, lib\, commands\, hooks\, i18n\ and the
    model manifest), plus version.txt so the deployed CLI reports the version it was built from.

    WHAT IT NEVER TOUCHES: engine-offline\, engine-staging\, models\*.gguf, home\ (the operator's .env lives there),
    temp\, reports\, logs\, loki.config.json. Those are `loki setup`'s and the operator's, they cost gigabytes and a
    credential to recreate, and a build script that can delete them is a build script that eventually will.

    IT NEVER DELETES ANYTHING. A file that disappeared from src\ but still sits on the stick is REPORTED, not
    removed -- because the dispatcher dot-sources every lib\*.ps1 and commands\*.ps1 it finds, so a stale module is
    not inert, it is loaded. Pass -Prune to remove reported orphans; that is the only mode in which this script
    deletes, and it only ever considers the four auto-loaded directories.

.PARAMETER Destination
    The stick root. Created if missing. This is <StickRoot> in DESIGN.md section 2 -- normally the drive root of the
    encrypted stick, but any directory works (that is how the live-test rig is built).

.PARAMETER Prune
    Also delete files in the auto-loaded directories that src\ no longer contains. Off by default: deleting is the
    dangerous half, and the operator should see the list before agreeing to it.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File build\New-LokiStick.ps1 -Destination E:\

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File build\New-LokiStick.ps1 -Destination D:\loki -Prune
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Destination,
    [switch]$Prune
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# $PSScriptRoot is empty in a param() default under 5.1 (CLAUDE.md section 1) -- resolve it in the body.
$repoRoot = Split-Path -Parent $PSScriptRoot
$srcDir = Join-Path $repoRoot 'src'
if (-not (Test-Path -LiteralPath $srcDir -PathType Container)) {
    throw "Not a Loki repository: $srcDir does not exist."
}

# The directories the dispatcher AUTO-LOADS (loki.ps1 dot-sources every *.ps1 it finds in lib\ and commands\; i18n
# and hooks are enumerated by name). A leftover file in one of these is executed, which is why orphans are reported
# here rather than shrugged off -- and why nothing OUTSIDE this set is ever considered for deletion.
$autoLoadedDirs = @('lib', 'commands', 'hooks', 'i18n')

$destFull = $Destination
if (-not (Test-Path -LiteralPath $destFull)) {
    New-Item -ItemType Directory -Force -Path $destFull | Out-Null
}
$destFull = (Resolve-Path -LiteralPath $destFull).Path
$srcFull = (Resolve-Path -LiteralPath $srcDir).Path

# Refuse to build the repository into itself. Ordinal, trailing separator on both sides so 'C:\loki' does not look
# like a prefix of 'C:\loki-other'. Building into src\ would have the script copy files onto themselves; building
# into the repo root would scatter a deployed layout through the working tree.
$destProbe = $destFull.TrimEnd('\') + '\'
foreach ($forbidden in @($srcFull, (Resolve-Path -LiteralPath $repoRoot).Path)) {
    $probe = $forbidden.TrimEnd('\') + '\'
    if ([string]::Equals($destProbe, $probe, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to build into the repository itself ($destFull). Pick a stick root outside the checkout."
    }
}

Write-Host "loki stick build"
Write-Host ("  from : {0}" -f $srcFull)
Write-Host ("  to   : {0}" -f $destFull)

# --- copy -------------------------------------------------------------------------------------------------------
# Copy-Item, deliberately: it moves BYTES. Every read-modify-write round trip through Get-Content/Set-Content is a
# chance to lose a UTF-8 BOM or rewrite line endings, and a BOM-less catalog with umlauts is read as ANSI by 5.1 ->
# mojibake in the operator's output (CLAUDE.md section 1). The build must not be able to introduce that.
$copied = 0
foreach ($item in (Get-ChildItem -LiteralPath $srcFull -Recurse -File)) {
    $relative = $item.FullName.Substring($srcFull.Length).TrimStart('\')
    $target = Join-Path $destFull $relative
    $targetDir = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Force -Path $targetDir | Out-Null }
    Copy-Item -LiteralPath $item.FullName -Destination $target -Force
    $copied++
}

# version.txt is the single SemVer source of truth (ADR-0005) and lives at the REPO root, not under src\ -- without
# this the deployed CLI reports whatever version the stick was last built with, which is the sort of quiet lie that
# makes a support call impossible.
$versionFile = Join-Path $repoRoot 'version.txt'
$srcVersion = ''
if (Test-Path -LiteralPath $versionFile) {
    $srcVersion = (Get-Content -LiteralPath $versionFile -Raw -Encoding utf8).Trim()
    Copy-Item -LiteralPath $versionFile -Destination (Join-Path $destFull 'version.txt') -Force
    $copied++
}

# The build stamp (#91): nothing on a stick tells an operator how OLD it is -- standing in a server room you
# cannot tell last week's build from last quarter's. This records WHEN it was built (and from which version),
# and `loki status` reads it back as "built N days ago". It is written, never copied, so it always reflects
# THIS build; a rebuild overwrites it. NOT under src\, so New-LokiStick's own orphan scan ignores it.
# The timestamp is a PRE-FORMATTED invariant ISO-8601 UTC string, and the JSON is written from strings only --
# no [datetime] ever reaches ConvertTo-Json, so its 5.1 "\/Date(...)\/" quirk cannot appear. BOM-free because
# it is pure ASCII and a BOM in JSON is just grit some parsers choke on.
$stamp = [ordered]@{
    builtUtc      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    sourceVersion = $srcVersion
}
$stampJson = ($stamp | ConvertTo-Json)
[System.IO.File]::WriteAllText((Join-Path $destFull 'stick-build.json'), $stampJson, (New-Object System.Text.UTF8Encoding($false)))
$copied++

# --- orphans ----------------------------------------------------------------------------------------------------
$orphans = New-Object System.Collections.Generic.List[string]
foreach ($dir in $autoLoadedDirs) {
    $destDir = Join-Path $destFull $dir
    if (-not (Test-Path -LiteralPath $destDir -PathType Container)) { continue }
    $srcSub = Join-Path $srcFull $dir
    foreach ($item in (Get-ChildItem -LiteralPath $destDir -Recurse -File)) {
        $relative = $item.FullName.Substring($destDir.Length).TrimStart('\')
        $counterpart = Join-Path $srcSub $relative
        if (-not (Test-Path -LiteralPath $counterpart)) {
            [void]$orphans.Add((Join-Path $dir $relative))
        }
    }
}

Write-Host ("  copied {0} file(s)" -f $copied)
if ($orphans.Count -gt 0) {
    Write-Host ""
    Write-Host ("  {0} file(s) on the stick that src\ no longer has:" -f $orphans.Count)
    foreach ($o in $orphans) { Write-Host ("    {0}" -f $o) }
    if ($Prune) {
        foreach ($o in $orphans) { Remove-Item -LiteralPath (Join-Path $destFull $o) -Force }
        Write-Host ("  pruned {0} file(s)." -f $orphans.Count)
    }
    else {
        # Not a warning to be scrolled past: the dispatcher LOADS these. Say what they are and what to do.
        Write-Host "  These are still loaded by the dispatcher. Re-run with -Prune to remove them."
    }
}

Write-Host ""
Write-Host "Stick code is current. Next, ON THE STICK:"
Write-Host ("    {0}\loki.cmd setup        # download the offline engine + model tier(s)" -f $destFull.TrimEnd('\'))
Write-Host ("    {0}\loki.cmd auth login   # only if you want the ONLINE engine" -f $destFull.TrimEnd('\'))
exit 0

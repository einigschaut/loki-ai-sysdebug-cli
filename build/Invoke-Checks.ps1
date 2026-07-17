# build/Invoke-Checks.ps1 — single entry point for all gates (CI and local identical, CLAUDE.md §7).
# Order: PSScriptAnalyzer -> structure/dead-code gate -> Pester. Exit != 0 as soon as one gate goes red.
[CmdletBinding()]
param(
    [string]$RepoRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# $PSScriptRoot is unreliable (empty) in a param default under 5.1 -> resolve it in the body.
if ([string]::IsNullOrEmpty($RepoRoot)) { $RepoRoot = Split-Path $PSScriptRoot -Parent }

$src      = Join-Path $RepoRoot 'src'
$tests    = Join-Path $RepoRoot 'tests'
$build    = Join-Path $RepoRoot 'build'
$settings = Join-Path $build 'PSScriptAnalyzerSettings.psd1'
$failures = New-Object System.Collections.Generic.List[string]

# The tool versions live in exactly ONE place, which CI installs from and this script imports — that is what makes
# the "CI and local identical" claim on line 1 true rather than aspirational. See build/module-versions.psd1 for why
# a floor was not enough. Never write a version number here.
$pins = Import-PowerShellDataFile -LiteralPath (Join-Path $build 'module-versions.psd1')

function Write-Section { param([string]$Title) Write-Host ''; Write-Host "=== $Title ===" }

function Import-RequiredModule {
    param([string]$Name, [hashtable]$Pins)
    # ContainsKey, not a bare read: under StrictMode Latest a missing hashtable key throws, which would surface the
    # one file the whole gate depends on as an unrelated stack trace.
    if (-not $Pins.ContainsKey($Name)) {
        Write-Host "MISSING: build/module-versions.psd1 pins no version for '$Name'."
        exit 3
    }
    $required = [version]$Pins[$Name]
    $mod = Get-Module -ListAvailable -Name $Name | Where-Object { $_.Version -eq $required } | Select-Object -First 1
    if ($null -eq $mod) {
        $have = @(Get-Module -ListAvailable -Name $Name | Sort-Object Version -Descending | ForEach-Object { $_.Version.ToString() })
        Write-Host "MISSING: module '$Name' $required — the gate is pinned to this exact version (build/module-versions.psd1)."
        if ($have.Count -gt 0) { Write-Host "  installed here: $($have -join ', ')" }
        Write-Host "  Install-Module $Name -RequiredVersion $required -Scope CurrentUser -Force -SkipPublisherCheck"
        Write-Host "  If that hangs or fails, a TLS-inspection proxy (Sophos, Zscaler) is blocking the NuGet provider"
        Write-Host "  bootstrap from cdn.oneget.org — measured on the maintainer's network, and it hangs because"
        Write-Host "  Install-Module PROMPTS for the bootstrap. Then take the package directly (a .nupkg is a zip):"
        Write-Host "    https://www.powershellgallery.com/api/v2/package/$Name/$required"
        Write-Host "  expand it into <Documents>\WindowsPowerShell\Modules\$Name\$required and delete _rels\,"
        Write-Host "  package\, *.nuspec and [Content_Types].xml from it."
        exit 3
    }
    # -RequiredVersion so that a session already holding a different Pester fails HERE, with Pester's own "restart
    # your session" message, instead of the gate quietly running on whichever version got loaded first (measured:
    # -MinimumVersion is satisfied by the loaded one and silently keeps it).
    try { Import-Module $Name -RequiredVersion $required -ErrorAction Stop }
    catch {
        Write-Host "CANNOT LOAD: '$Name' $required into this session."
        Write-Host "  $($_.Exception.Message -replace '\s+', ' ')"
        exit 3
    }
}

# --- 1) PSScriptAnalyzer ---
Write-Section 'PSScriptAnalyzer'
Import-RequiredModule -Name 'PSScriptAnalyzer' -Pins $pins
$paFindings = @()
foreach ($p in @($src, $tests, $build)) {
    if (Test-Path -LiteralPath $p) {
        $paFindings += Invoke-ScriptAnalyzer -Path $p -Recurse -Settings $settings
    }
}
if ($paFindings.Count -gt 0) {
    $paFindings | ForEach-Object { Write-Host ("  [{0}] {1}:{2} {3}" -f $_.Severity, (Split-Path $_.ScriptName -Leaf), $_.Line, $_.RuleName) }
    $failures.Add("PSScriptAnalyzer: $($paFindings.Count) finding(s)")
}
else { Write-Host '  OK (no findings)' }

# --- 2) structure/dead-code gate ---
Write-Section 'Structure / dead-code gate'
. (Join-Path $build 'Test-LokiStructure.ps1')
$struct = Test-LokiStructure -SrcPath $src -TestPath $tests
if (-not $struct.Ok) {
    $struct.Issues | ForEach-Object { Write-Host "  ! $_" }
    $failures.Add("Structure gate: $($struct.Issues.Count) issue(s)")
}
else { Write-Host '  OK' }

# --- 3) Pester ---
Write-Section 'Pester'
Import-RequiredModule -Name 'Pester' -Pins $pins
$cfg = New-PesterConfiguration
$cfg.Run.Path = $tests
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'Detailed'
$pester = Invoke-Pester -Configuration $cfg
if ($pester.FailedCount -gt 0) {
    $failures.Add("Pester: $($pester.FailedCount) test(s) failed")
}

# --- result ---
Write-Section 'Result'
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "  FAIL: $_" }
    Write-Host ''
    Write-Host 'CHECKS FAILED'
    exit 1
}
Write-Host 'ALL CHECKS GREEN (analyzer + structure gate + Pester)'
exit 0

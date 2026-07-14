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

function Write-Section { param([string]$Title) Write-Host ''; Write-Host "=== $Title ===" }

function Import-RequiredModule {
    param([string]$Name, [version]$MinimumVersion)
    $mod = Get-Module -ListAvailable -Name $Name | Where-Object { $_.Version -ge $MinimumVersion } | Select-Object -First 1
    if ($null -eq $mod) {
        Write-Host "MISSING: module '$Name' (>= $MinimumVersion)."
        Write-Host "Install locally: Install-Module $Name -Scope CurrentUser"
        Write-Host "(Corporate TLS-inspection proxies (e.g. Sophos, Zscaler) may block the NuGet provider bootstrap; see BUILD-STATUS for a direct nupkg download.)"
        exit 3
    }
    Import-Module $Name -MinimumVersion $MinimumVersion -ErrorAction Stop
}

# --- 1) PSScriptAnalyzer ---
Write-Section 'PSScriptAnalyzer'
Import-RequiredModule -Name 'PSScriptAnalyzer' -MinimumVersion '1.21.0'
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
Import-RequiredModule -Name 'Pester' -MinimumVersion '5.0.0'
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

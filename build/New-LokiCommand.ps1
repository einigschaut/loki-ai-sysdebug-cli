# build/New-LokiCommand.ps1 — scaffolding: the ONLY way to add a new command (CLAUDE.md §3).
# Generates src\commands\<name>.ps1 (meta+handler, ADR-0002 shape) and tests\<name>.Tests.ps1 (contract stub),
# both as UTF-8 with BOM. Refuses to overwrite without -Force.
# Usage:  powershell -File build\New-LokiCommand.ps1 -Name scan -Group Diagnostics -Summary "scan.summary"
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z][a-z0-9-]*$')][string]$Name,
    [Parameter(Mandatory = $true)][string]$Summary,
    [Parameter(Mandatory = $true)][string]$Group,
    [string]$Usage,
    [string]$RepoRoot,
    [switch]$Force
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($RepoRoot)) { $RepoRoot = Split-Path $PSScriptRoot -Parent }
if ([string]::IsNullOrEmpty($Usage))    { $Usage = "loki $Name" }

$cmdFile  = Join-Path $RepoRoot ("src\commands\{0}.ps1" -f $Name)
$testFile = Join-Path $RepoRoot ("tests\{0}.Tests.ps1" -f $Name)

foreach ($f in @($cmdFile, $testFile)) {
    if ((Test-Path -LiteralPath $f) -and (-not $Force)) {
        Write-Host "ABORT: '$f' already exists. Use -Force to overwrite."
        exit 2
    }
}

# Guard values for PS single-quoted literals (double any embedded '); $Name is quote-free by regex.
$sumEsc   = $Summary.Replace("'", "''")
$grpEsc   = $Group.Replace("'", "''")
$usageEsc = $Usage.Replace("'", "''")

$cmdTemplate = @'
# commands/__NAME__.ps1 — `loki __NAME__` (scaffolded by build/New-LokiCommand.ps1)
# Metadata (Get-LokiCmdMeta___NAME__) is the single source of truth; handler (Invoke-LokiCmd___NAME__) executes it. ADR-0002.
# Note: Summary should be an i18n catalog key (add it to src/i18n/*.psd1); user-facing output goes through Get-LokiText (CLAUDE.md §10).
Set-StrictMode -Version Latest

function Get-LokiCmdMeta___NAME__ {
    @{
        Name     = '__NAME__'
        Group    = '__GROUP__'
        Summary  = '__SUMMARY__'
        Usage    = '__USAGE__'
        Examples = @('__USAGE__')
        Flags    = @()
    }
}

function Invoke-LokiCmd___NAME__ {
    param($Context)
    Write-LokiWarn 'Command "__NAME__" is not implemented yet.'
    # TODO: implement. Return a suitable exit code via Get-LokiExitCode (e.g. 'Ok').
    #       Route user-facing text through Get-LokiText (CLAUDE.md §10), not hardcoded strings.
    return (Get-LokiExitCode 'GeneralError')
}
'@

$testTemplate = @'
# tests/__NAME__.Tests.ps1 — contract stub (scaffolding). Add behaviour tests (break every guard once)!
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\exitcodes.ps1"
    . "$PSScriptRoot\..\src\lib\ui.ps1"
    . "$PSScriptRoot\..\src\commands\__NAME__.ps1"
    Initialize-LokiUi -NoColor
}

Describe 'Command __NAME__' {
    It 'metadata is complete (Name == file name)' {
        $m = Get-LokiCmdMeta___NAME__
        $m.Name    | Should -Be '__NAME__'
        $m.Summary | Should -Not -BeNullOrEmpty
        $m.Usage   | Should -Not -BeNullOrEmpty
        $m.Group   | Should -Not -BeNullOrEmpty
    }
    It 'handler is defined and returns an exit code' {
        (Get-Command Invoke-LokiCmd___NAME__ -CommandType Function) | Should -Not -BeNullOrEmpty
        $ctx  = @{ AppRoot = 'x'; Version = '0'; Args = @(); Flags = @{}; Registry = @() }
        $code = Invoke-LokiCmd___NAME__ $ctx
        ([int]$code) | Should -BeOfType [int]
    }
    # TODO: add behaviour tests for __NAME__.
}
'@

function Expand-Template {
    param([string]$Text)
    return $Text.Replace('__NAME__', $Name).Replace('__GROUP__', $grpEsc).Replace('__SUMMARY__', $sumEsc).Replace('__USAGE__', $usageEsc)
}

$enc = New-Object System.Text.UTF8Encoding($true)   # UTF-8 with BOM (5.1 correctness)
[System.IO.File]::WriteAllText($cmdFile,  (Expand-Template $cmdTemplate),  $enc)
[System.IO.File]::WriteAllText($testFile, (Expand-Template $testTemplate), $enc)

Write-Host "Created: $cmdFile"
Write-Host "Created: $testFile"
Write-Host ''
Write-Host 'Next steps (Definition of Done):'
Write-Host "  1. Implement the handler in src\commands\$Name.ps1 (the placeholder returns a non-zero exit for now)."
Write-Host "  2. Add behaviour tests in tests\$Name.Tests.ps1 — break every new guard once on purpose."
Write-Host "  3. Add the Summary key + any user-facing strings to src\i18n\*.psd1 (all locales; CLAUDE.md §10)."
Write-Host '  4. Add a CHANGELOG.md line.'
Write-Host '  5. build\Invoke-Checks.ps1 -> must be green.'
exit 0

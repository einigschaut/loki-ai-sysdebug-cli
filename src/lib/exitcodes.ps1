# lib/exitcodes.ps1 — central, stable exit-code definition (single source of truth)
# Contract:
#   $script:LokiExit        hashtable Name -> Code (read-only)
#   Get-LokiExitCode -Name  returns the code; throws on an unknown name (prevents hardcoded numbers)
# CLAUDE.md section 4: reference ONLY through this, never scatter exit-code numbers through the code.
Set-StrictMode -Version Latest

$script:LokiExit = [ordered]@{
    Ok                   = 0
    GeneralError         = 1
    Usage                = 2
    AuthMissing          = 3
    NetworkRequired      = 4
    OfflineEngineMissing = 5
    FootprintGuard       = 6
    VolumeLocked         = 7
    UserAborted          = 8
    Interrupted          = 130
}

function Get-LokiExitCode {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not $script:LokiExit.Contains($Name)) {
        throw "Unknown exit-code name '$Name' (allowed: $($script:LokiExit.Keys -join ', '))"
    }
    return [int]$script:LokiExit[$Name]
}

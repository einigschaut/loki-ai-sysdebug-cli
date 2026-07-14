# commands/status.ps1 — `loki status`
# Stage-0 build-out: fast, WRITE-FREE environment check (app root, PowerShell, network reachability).
# Honestly scoped: auth, host-posture, and volume checks follow in stage 1 (F5/F7) — do NOT fake them here.
Set-StrictMode -Version Latest

function Get-LokiCmdMeta_status {
    @{
        Name     = 'status'
        Group    = 'Health'
        Summary  = 'status.summary'
        Usage    = 'loki status'
        Examples = @('loki status')
        Flags    = @()
    }
}

function Invoke-LokiCmd_status {
    param($Context)
    Write-LokiHeading "loki status  (v$($Context.Version))"
    Write-LokiLine ("{0,-14} {1}" -f 'App-Root:', $Context.AppRoot)
    Write-LokiLine ("{0,-14} {1}" -f 'PowerShell:', $PSVersionTable.PSVersion.ToString())

    $online = Test-LokiConnectivity
    if ($online) {
        Write-LokiOk (Get-LokiText 'status.net.online')
    }
    else {
        Write-LokiWarn (Get-LokiText 'status.net.offline')
    }

    Write-LokiLine ''
    Write-LokiInfo (Get-LokiText 'status.pending')
    return (Get-LokiExitCode 'Ok')
}

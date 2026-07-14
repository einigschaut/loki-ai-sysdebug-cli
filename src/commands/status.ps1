# commands/status.ps1 — `loki status`
# Fast, WRITE-FREE glance: app root, PowerShell, network reachability, auth, and a host-posture rollup.
# Reuses the pure ConvertTo-LokiDoctorChecks interpreter (src/lib/posture.ps1) with a placeholder "unknown"
# volume so there is no duplicated check logic against `loki doctor` — but status ONLY calls the FAST
# Get-LokiHostPosture and MUST NOT call Get-LokiVolumePosture (that ~5s BitLocker probe belongs to doctor;
# it is dropped from the rollup here). The full volume/BitLocker diagnosis stays exclusive to `loki doctor`.
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

    $cfg = Read-LokiConfig -Path (Join-Path $Context.AppRoot 'loki.config.json')
    $auth = Get-LokiAuthStatus -EnvFilePath (Join-Path $Context.AppRoot 'home\.env') -Config $cfg
    $hostPosture = Get-LokiHostPosture
    # Placeholder volume ("unknown" sentinel) -- status must NEVER call Get-LokiVolumePosture (slow BitLocker
    # probe, ~5s); the volume check is dropped from the rollup below. Full volume diagnosis: `loki doctor`.
    $volumePlaceholder = [pscustomobject]@{ Drive = $null; Removable = $null; BitLockerOn = $null }
    $allChecks = ConvertTo-LokiDoctorChecks -HostPosture $hostPosture -VolumePosture $volumePlaceholder -AuthStatus $auth

    $authCheck = $allChecks | Where-Object { $_.Id -eq 'auth' } | Select-Object -First 1
    $hostChecks = @($allChecks | Where-Object { ($_.Id -ne 'auth') -and ($_.Id -ne 'volume') })

    $authStatusWord = Get-LokiText ('doctor.status.' + $authCheck.Severity)
    $authDetail = $authCheck.DetailRaw
    if ($null -ne $authCheck.DetailKey) {
        $authDetail = Get-LokiText $authCheck.DetailKey -ArgumentList $authCheck.DetailArgs
    }
    $authLine = "{0,-14} [{1}] {2}" -f 'Auth:', $authStatusWord, $authDetail
    if ($authCheck.Severity -eq 'ok') {
        Write-LokiOk $authLine
    }
    else {
        Write-LokiWarn $authLine
    }

    $ok = @($hostChecks | Where-Object { $_.Severity -eq 'ok' }).Count
    $warn = @($hostChecks | Where-Object { ($_.Severity -eq 'warn') -or ($_.Severity -eq 'unknown') }).Count
    $fail = @($hostChecks | Where-Object { $_.Severity -eq 'fail' }).Count

    $rollupText = Get-LokiText 'status.postureRollup' -ArgumentList @($ok, $warn, $fail)
    $postureLine = "{0,-14} {1}" -f 'Posture:', $rollupText
    if ($fail -gt 0) {
        Write-LokiErr $postureLine
    }
    elseif ($warn -gt 0) {
        Write-LokiWarn $postureLine
    }
    else {
        Write-LokiOk $postureLine
    }

    Write-LokiLine ''
    Write-LokiInfo (Get-LokiText 'status.doctorHint')
    return (Get-LokiExitCode 'Ok')
}

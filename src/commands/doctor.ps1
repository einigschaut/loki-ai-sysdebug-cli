# commands/doctor.ps1 — `loki doctor` (scaffolded by build/New-LokiCommand.ps1, then implemented)
# Metadata (Get-LokiCmdMeta_doctor) is the single source of truth; handler (Invoke-LokiCmd_doctor) executes it. ADR-0002.
# Read-only environment/host-posture diagnosis: wires lib/auth.ps1 + lib/posture.ps1 together and renders
# the pure ConvertTo-LokiDoctorChecks result (src/lib/posture.ps1) through Get-LokiText (CLAUDE.md §10).
Set-StrictMode -Version Latest

function Get-LokiCmdMeta_doctor {
    @{
        Name     = 'doctor'
        Group    = 'Health'
        Summary  = 'doctor.summary'
        Usage    = 'loki doctor'
        Examples = @('loki doctor')
        Flags    = @()
    }
}

function Invoke-LokiCmd_doctor {
    param($Context)

    $envPath = Join-Path $Context.AppRoot 'home\.env'
    $configPath = Join-Path $Context.AppRoot 'loki.config.json'
    $cfg = Read-LokiConfig -Path $configPath

    $auth = Get-LokiAuthStatus -EnvFilePath $envPath -Config $cfg
    $host_ = Get-LokiHostPosture
    $vol = Get-LokiVolumePosture -Path $Context.AppRoot

    $checks = ConvertTo-LokiDoctorChecks -HostPosture $host_ -VolumePosture $vol -AuthStatus $auth

    Write-LokiHeading 'loki doctor'
    Write-LokiLine ''

    $okCount = 0
    $warnCount = 0
    $failCount = 0

    foreach ($c in $checks) {
        $status = Get-LokiText ('doctor.status.' + $c.Severity)
        $label = Get-LokiText $c.LabelKey
        $detail = $c.DetailRaw
        if ($null -ne $c.DetailKey) {
            $detail = Get-LokiText $c.DetailKey -ArgumentList $c.DetailArgs
        }
        $line = "[{0}] {1,-26} {2}" -f $status, $label, $detail

        if ($c.Severity -eq 'ok') {
            $okCount++
            Write-LokiOk $line
        }
        elseif ($c.Severity -eq 'fail') {
            $failCount++
            Write-LokiErr $line
        }
        else {
            # 'warn' AND 'unknown' both render as a warning and both count toward the footer's
            # warning bucket -- there is no separate "unknown" exit code/footer slot (CLAUDE.md §4
            # keeps the exit-code set stable), and an undetermined check is not a clean "OK" either.
            $warnCount++
            Write-LokiWarn $line
        }
    }

    Write-LokiLine ''
    Write-LokiLine (Get-LokiText 'doctor.footer' -ArgumentList @($okCount, $warnCount, $failCount))

    return (Get-LokiDoctorExitCode -Checks $checks)
}
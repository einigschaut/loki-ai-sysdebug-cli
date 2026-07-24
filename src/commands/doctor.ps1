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
        Usage    = 'loki doctor [--footprint] [--engine]'
        Examples = @('loki doctor', 'loki doctor --footprint', 'loki doctor --engine')
        Flags    = @(
            @{ Flag = '--footprint'; Desc = 'Prove zero host-profile footprint (isolated write-probe + before/after diff)' },
            @{ Flag = '--engine'; Desc = 'Verify the offline engine and models against their pinned hashes (hashes every installed model)' }
        )
    }
}

function Write-LokiDoctorReport {
    # Renders an ordered list of check objects (the shape lib/posture.ps1 and lib/integrity.ps1 both produce) plus the
    # footer. Shared by `loki doctor` and `loki doctor --engine`: the two reports differ in what they CHECK, not in
    # what a check looks like.
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()]$Checks)

    $okCount = 0
    $warnCount = 0
    $failCount = 0

    foreach ($c in $Checks) {
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
}

function Invoke-LokiCmd_doctor {
    param($Context)

    # --footprint mode (DESIGN.md section 5.4): the falsifiable zero-app-level-footprint gate. Thin wiring over
    # lib/footprint.ps1 -- run the isolated write-probe, render the verdict, map to an exit code. A hard probe-target
    # leak -> FootprintGuard (6); an inconclusive probe (isolation could not be exercised) -> GeneralError; a change in
    # a soft standing location is reported but does not fail the gate (see ADR-0010).
    if (@($Context.Args) -contains '--footprint') {
        Write-LokiHeading (Get-LokiText 'footprint.heading')
        Write-LokiLine ''
        $res = Invoke-LokiFootprintProbe -AppRoot $Context.AppRoot
        # A detected leak MUST win. When the redirect breaks, the isolated child writes to the host (leak detected,
        # Clean=$false) AND the stick marker is absent (ProbeVerified=$false) -- these co-occur in the gate's primary
        # failure mode. Check the leak FIRST so it always maps to FootprintGuard (6) and names the target; only a
        # clean-but-unverified run (isolation could not be exercised at all) is the inconclusive GeneralError case.
        if (-not $res.Clean) {
            Write-LokiErr (Get-LokiText 'footprint.leaked' -ArgumentList @(($res.Leaked -join ', ')))
            return (Get-LokiExitCode 'FootprintGuard')
        }
        if (-not $res.ProbeVerified) {
            Write-LokiErr (Get-LokiText 'footprint.probeFailed')
            return (Get-LokiExitCode 'GeneralError')
        }
        Write-LokiOk (Get-LokiText 'footprint.probeVerified')
        if ($res.Observed.Count -gt 0) {
            Write-LokiWarn (Get-LokiText 'footprint.observed' -ArgumentList @(($res.Observed -join ', ')))
        }
        Write-LokiOk (Get-LokiText 'footprint.clean')
        return (Get-LokiExitCode 'Ok')
    }

    # --engine mode (ADR-0014): the load-time integrity chain, as a read-only report. It is opt-in rather than part of
    # the default `loki doctor` because it hashes every installed model -- seconds for nano, about a minute for a
    # 19 GB tier on USB. The default doctor must stay instant; an operator asking THIS question is asking for the cost.
    if (@($Context.Args) -contains '--engine') {
        $engineData = Get-LokiEngineManifest -Path (Join-Path $Context.AppRoot 'engine\manifest.psd1')
        # #87: an outdated stick's model manifest fails fail-closed validation -> rebuild hint, not a raw throw.
        $modelMf = Read-LokiModelManifestSafe -Path (Get-LokiModelLayout -AppRoot $Context.AppRoot).ManifestPath
        if (-not $modelMf.Ok) {
            Write-LokiErr (Get-LokiText 'offline.stickOutdated' -ArgumentList @([string]$modelMf.Detail))
            return (Get-LokiExitCode 'OfflineEngineMissing')
        }
        $models = @($modelMf.Models)

        Write-LokiHeading (Get-LokiText 'integrity.heading')
        Write-LokiLine ''
        Write-LokiLine (Get-LokiText 'integrity.hashingNote')
        Write-LokiLine ''

        $report = Get-LokiEngineReport -AppRoot $Context.AppRoot -Engine $engineData.Engine `
            -Runtime $engineData.Runtime -Models $models
        $checks = ConvertTo-LokiIntegrityChecks -Report $report
        Write-LokiDoctorReport -Checks $checks

        # NOT Get-LokiDoctorExitCode: this report distinguishes "the stick is wrong" (1) from "the stick is
        # incomplete" (5), which a single fail/not-fail verdict cannot express. See Get-LokiIntegrityExitCode.
        return (Get-LokiIntegrityExitCode -Report $report)
    }

    $envPath = Join-Path $Context.AppRoot 'home\.env'
    $configPath = Join-Path $Context.AppRoot 'loki.config.json'
    $cfg = Read-LokiConfig -Path $configPath

    $auth = Get-LokiAuthStatus -EnvFilePath $envPath -Config $cfg
    $host_ = Get-LokiHostPosture
    $vol = Get-LokiVolumePosture -Path $Context.AppRoot

    $checks = ConvertTo-LokiDoctorChecks -HostPosture $host_ -VolumePosture $vol -AuthStatus $auth

    Write-LokiHeading (Get-LokiText 'doctor.heading')
    Write-LokiLine ''

    Write-LokiDoctorReport -Checks $checks

    return (Get-LokiDoctorExitCode -Checks $checks)
}
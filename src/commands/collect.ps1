# commands/collect.ps1 -- `loki collect` (scaffolded by build/New-LokiCommand.ps1, then implemented). ADR-0002/0018.
# The raw diagnostic dump: what Loki can still tell an operator with no network, no auth, no model and no admin.
# Read-only apart from the two artifacts it writes to reports\ ON THE STICK -- never the host profile.
# Thin wiring: lib/collect.ps1 owns the batteries, the shaping and the rendering. This file parses arguments,
# writes the files, and translates machine tokens into the operator's language (CLAUDE.md section 10).
Set-StrictMode -Version Latest

function Get-LokiCmdMeta_collect {
    @{
        Name     = 'collect'
        Group    = 'Diagnostics'
        Summary  = 'collect.summary'
        Usage    = 'loki collect [--only <battery,...>]'
        Examples = @('loki collect', 'loki collect --only os,storage')
        Flags    = @(
            @{ Flag = '--only'; Desc = 'Run only these batteries (comma-separated) instead of all of them' }
        )
    }
}

function Invoke-LokiCmd_collect {
    param($Context)

    $only = $null
    $expectOnly = $false
    foreach ($a in $Context.Args) {
        $s = [string]$a
        if ($expectOnly) { $only = $s; $expectOnly = $false; continue }
        if ($s -eq '--only') { $expectOnly = $true; continue }
        if ($s -like '--only=*') { $only = $s -replace '^--only=', ''; continue }
        Write-LokiErr (Get-LokiText 'collect.badArg' -ArgumentList @($s))
        return (Get-LokiExitCode 'Usage')
    }
    if ($expectOnly) {
        Write-LokiErr (Get-LokiText 'collect.onlyNeedsValue')
        return (Get-LokiExitCode 'Usage')
    }

    $known = Get-LokiCollectBatteryId
    $selected = $null
    if (-not [string]::IsNullOrWhiteSpace($only)) {
        $selected = @($only -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($selected.Count -eq 0) {
            Write-LokiErr (Get-LokiText 'collect.onlyNeedsValue')
            return (Get-LokiExitCode 'Usage')
        }
        # A misspelled battery REFUSES rather than silently collecting less. lib/collect.ps1 filters unknown ids out
        # without complaint (a library does not get to reject an operator's argument), so if this does not check,
        # `loki collect --only stroage` writes a dump with nothing in it and reports success.
        foreach ($name in $selected) {
            if ($known -notcontains $name) {
                Write-LokiErr (Get-LokiText 'collect.unknownBattery' -ArgumentList @($name, ($known -join ', ')))
                return (Get-LokiExitCode 'Usage')
            }
        }
    }

    Write-LokiHeading (Get-LokiText 'collect.heading')
    Write-LokiLine ''
    Write-LokiInfo (Get-LokiText 'collect.working')

    $dump = Invoke-LokiCollect -Only $selected
    $document = ConvertTo-LokiCollectDocument -Dump $dump -LokiVersion ([string]$Context.Version)

    $okCount = 0
    $failCount = 0
    foreach ($battery in @($dump.Batteries)) {
        if (([string]$battery.Status) -eq 'ok') {
            $okCount++
            Write-LokiOk (Get-LokiText 'collect.batteryOk' -ArgumentList @([string]$battery.Id, $battery.DurationMs))
        }
        else {
            $failCount++
            $reason = [string]$battery.Error
            if ([string]::IsNullOrWhiteSpace($reason)) { $reason = Get-LokiText 'collect.noReason' }
            Write-LokiWarn (Get-LokiText 'collect.batteryFailed' -ArgumentList @(
                    [string]$battery.Id, $battery.DurationMs, (Get-LokiText ('collect.status.' + [string]$battery.Status)), $reason))
        }
    }

    $paths = Get-LokiCollectPath -AppRoot $Context.AppRoot -Stamp (Get-LokiCollectStamp)
    try {
        # Test-Path WITHOUT -PathType Container, deliberately. It looks like the sloppier choice and is the safe one:
        # measured, `New-Item -ItemType Directory -Force` against a path where a FILE already exists reports success
        # and creates NO directory (Test-Path -PathType Container stays $false afterwards). So "improving" this to
        # -PathType Container would send New-Item at the file, get a silent no-op, and turn a clear Set-Content
        # refusal into a mystery. As written, a file in the way skips New-Item and Set-Content refuses out loud.
        #
        # New-Item's -ErrorAction Stop is REDUNDANT for the exit code, and that is measured rather than assumed: a
        # mutation dropping it survives the whole suite, because a New-Item that fails silently leaves reports\
        # absent and the Set-Content below then fails anyway, through its own -ErrorAction Stop. There is no case
        # where New-Item fails and Set-Content succeeds. It is kept because it makes the reported reason name the
        # FIRST failure ("cannot find drive") instead of a downstream one -- better diagnostics, not a second guard.
        if (-not (Test-Path -LiteralPath $paths.Dir)) {
            New-Item -ItemType Directory -Path $paths.Dir -Force -ErrorAction Stop | Out-Null
        }
        # -ErrorAction Stop is load-bearing, not decoration: Set-Content failures are NON-terminating by default, so
        # without it the catch below never fires and this reports a written dump over a file that does not exist.
        # lib/download.ps1 and lib/engine.ps1 both carry the same note after adversarial review reproduced exactly that.
        # -Encoding utf8 is explicit per CLAUDE.md section 1 (never rely on an encoding default).
        Set-Content -LiteralPath $paths.JsonPath -Value (ConvertTo-LokiCollectJson -Document $document) `
            -Encoding utf8 -ErrorAction Stop
        Set-Content -LiteralPath $paths.TextPath -Value (ConvertTo-LokiCollectText -Document $document) `
            -Encoding utf8 -ErrorAction Stop
    }
    catch {
        Write-LokiErr (Get-LokiText 'collect.writeFailed' -ArgumentList @($paths.Dir, ($_.Exception.Message -split "`n")[0].Trim()))
        return (Get-LokiExitCode 'GeneralError')
    }

    Write-LokiLine ''
    Write-LokiOk (Get-LokiText 'collect.wroteData' -ArgumentList @($paths.JsonPath))
    Write-LokiOk (Get-LokiText 'collect.wroteReport' -ArgumentList @($paths.TextPath))
    Write-LokiLine (Get-LokiText 'collect.footer' -ArgumentList @($okCount, $failCount))

    # Ok whenever a dump was WRITTEN -- a failed battery is content, not a failed run (ADR-0018). `loki collect` is the
    # command for machines that are already broken; exiting non-zero because one probe was denied would make the tool
    # report failure on exactly the hosts it exists to serve, and a wrapping script would throw the dump away. Even an
    # all-failed dump is an answer ("WMI answers nothing here" is a diagnosis). Only an unwritable dump is an error.
    return (Get-LokiExitCode 'Ok')
}

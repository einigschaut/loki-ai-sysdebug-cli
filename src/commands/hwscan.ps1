# commands/hwscan.ps1 -- `loki hwscan` (scaffolded by build/New-LokiCommand.ps1, then implemented). ADR-0002/0013/0017.
# Read-only: answers "can the offline engine run on THIS machine, and with which model?" before anything is started.
# Writes nothing. Thin wiring -- lib/hwscan.ps1 owns the probe and the whole selection rule, lib/models.ps1 the catalog.
Set-StrictMode -Version Latest

function Get-LokiCmdMeta_hwscan {
    @{
        Name     = 'hwscan'
        Group    = 'Health'
        Summary  = 'hwscan.summary'
        Usage    = 'loki hwscan [--model <tier>] [--force]'
        Examples = @('loki hwscan', 'loki hwscan --model mid', 'loki hwscan --model max --force')
        Flags    = @(
            @{ Flag = '--model'; Desc = 'Ask what a specific tier would do here instead of the automatic pick' },
            @{ Flag = '--force'; Desc = 'With --model: report the tier as usable even if it exceeds the RAM limits' }
        )
    }
}

function Invoke-LokiCmd_hwscan {
    param($Context)

    $override = $null
    $force = $false
    $expectModel = $false
    foreach ($a in $Context.Args) {
        $s = [string]$a
        if ($expectModel) { $override = $s; $expectModel = $false; continue }
        if ($s -eq '--model') { $expectModel = $true; continue }
        if ($s -like '--model=*') { $override = $s -replace '^--model=', ''; continue }
        if ($s -eq '--force') { $force = $true; continue }
        Write-LokiErr (Get-LokiText 'hwscan.badArg' -ArgumentList @($s))
        return (Get-LokiExitCode 'Usage')
    }
    if ($expectModel) {
        Write-LokiErr (Get-LokiText 'hwscan.modelNeedsValue')
        return (Get-LokiExitCode 'Usage')
    }
    # --force only means anything together with --model. Accepting it silently would let someone type
    # `loki hwscan --force` expecting the limits to be lifted and get a normal, limit-respecting answer with no hint
    # that their flag did nothing.
    if ($force -and [string]::IsNullOrWhiteSpace($override)) {
        Write-LokiErr (Get-LokiText 'hwscan.forceNeedsModel')
        return (Get-LokiExitCode 'Usage')
    }

    Write-LokiHeading (Get-LokiText 'hwscan.heading')

    $hw = Get-LokiHardwareProfile
    $cpuText = Get-LokiText 'hwscan.unknown'
    if (-not [string]::IsNullOrWhiteSpace([string]$hw.CpuName)) { $cpuText = [string]$hw.CpuName }
    if ($null -ne $hw.CpuCores) { $cpuText = Get-LokiText 'hwscan.cpuThreads' -ArgumentList @($cpuText, $hw.CpuCores) }
    Write-LokiLine (Get-LokiText 'hwscan.cpu' -ArgumentList @($cpuText))

    if ($null -eq $hw.TotalRamGB) {
        Write-LokiWarn (Get-LokiText 'hwscan.ramUnknown')
    }
    else {
        Write-LokiLine (Get-LokiText 'hwscan.ram' -ArgumentList @($hw.TotalRamGB, $hw.AvailableRamGB))
    }

    # Both ceilings are printed, because a verdict the operator cannot recompute is magic (ADR-0013 decision 7).
    $limit = Get-LokiModelRamLimit -TotalRamGB $hw.TotalRamGB -AvailableRamGB $hw.AvailableRamGB
    if ($limit.Ok) {
        Write-LokiLine (Get-LokiText 'hwscan.limits' -ArgumentList @($limit.CapGB, $limit.UsableNowGB))
    }

    $modelLayout = Get-LokiModelLayout -AppRoot $Context.AppRoot
    $models = Get-LokiModelManifest -Path $modelLayout.ManifestPath
    $installed = Get-LokiInstalledTiers -Models $models -ModelsDir $modelLayout.Dir
    Write-LokiLine (Get-LokiText 'hwscan.installed' -ArgumentList @(@($installed).Count, @($models).Count))

    $report = Get-LokiTierFitReport -Tiers $installed -TotalRamGB $hw.TotalRamGB -AvailableRamGB $hw.AvailableRamGB
    foreach ($row in @($report)) {
        Write-LokiLine (Get-LokiText 'hwscan.tierRow' -ArgumentList @(
                [string]$row.Tier.Id, [string]$row.Tier.Model, $row.Tier.ResidentGB, (Get-LokiHwscanVerdictText -Row $row)))
    }

    $sel = Select-LokiTier -Tiers $installed -TotalRamGB $hw.TotalRamGB -AvailableRamGB $hw.AvailableRamGB `
        -Override $override -Force:$force

    if ($sel.Ok) {
        Write-LokiOk (Get-LokiText 'hwscan.selected' -ArgumentList @([string]$sel.Tier.Id, [string]$sel.Tier.Model, $sel.Tier.ResidentGB))
        if ([string]$sel.Reason -eq 'forced') {
            # Two different truths: with a reading we can say what the tier overshoots; without one we must NOT print
            # a blank where a number belongs and call it a limit.
            if (-not $limit.Ok) { Write-LokiWarn (Get-LokiText 'hwscan.forcedRamUnknown' -ArgumentList @($sel.Tier.ResidentGB)) }
            else { Write-LokiWarn (Get-LokiText 'hwscan.forced' -ArgumentList @($sel.Tier.ResidentGB, $limit.UsableNowGB)) }
        }
        Write-LokiHwscanGuidance -Report $report -Override $override
        return (Get-LokiExitCode 'Ok')
    }

    # Every "no" says WHY in the operator's terms, and maps to a stable exit code. A machine that cannot run any model
    # is not an error in the tool -- it is an answer -- but the offline engine genuinely is unavailable, so it exits
    # OfflineEngineMissing rather than pretending success.
    switch ([string]$sel.Reason) {
        'no-tiers-installed' { Write-LokiErr (Get-LokiText 'hwscan.noneInstalled') }
        'override-not-installed' { Write-LokiErr (Get-LokiText 'hwscan.overrideMissing' -ArgumentList @([string]$override)) }
        'override-needs-free' { Write-LokiErr (Get-LokiText 'hwscan.overrideNeedsFree' -ArgumentList @([string]$override, $sel.NeedFreeGB)) }
        'override-too-big' { Write-LokiErr (Get-LokiText 'hwscan.overrideTooBig' -ArgumentList @([string]$override, $sel.Tier.ResidentGB, $limit.CapGB)) }
        'ram-unknown' { Write-LokiErr (Get-LokiText 'hwscan.ramUnknownFatal') }
        default { Write-LokiHwscanRefusal -Report $report -Models $models -Hw $hw }
    }
    Write-LokiHwscanGuidance -Report $report -Override $override
    return (Get-LokiExitCode 'OfflineEngineMissing')
}

function Get-LokiHwscanVerdictText {
    # The verdict column. Machine tokens in, localized prose out -- lib/hwscan.ps1 never speaks to a human.
    param($Row)
    switch ([string]$Row.Verdict) {
        'fits' { return (Get-LokiText 'hwscan.verdictFits') }
        'fits-if-freed' { return (Get-LokiText 'hwscan.verdictNeedsFree' -ArgumentList @($Row.NeedFreeGB)) }
        'too-big' { return (Get-LokiText 'hwscan.verdictTooBig') }
        default { return (Get-LokiText 'hwscan.verdictUnjudged') }
    }
}

function Write-LokiHwscanRefusal {
    <#
        Nothing fits. The useful question is not "why" but "what now", and there are three different answers.
        The old rule asserted that below a fixed floor nothing to download could help; this CHECKS it against the
        catalogue instead, because "fetch a smaller tier" is either the right advice or advice that cannot work, and
        which one it is depends on the machine.
    #>
    param($Report, $Models, $Hw)

    if (@($Report | Where-Object { [string]$_.Verdict -eq 'fits-if-freed' }).Count -gt 0) {
        Write-LokiErr (Get-LokiText 'hwscan.nothingFitsNow')
        return
    }
    # Every installed tier is too big for this machine, permanently. Would anything in the catalogue run here?
    $catalog = Get-LokiTierFitReport -Tiers $Models -TotalRamGB $Hw.TotalRamGB -AvailableRamGB $Hw.AvailableRamGB
    $usable = @($catalog | Where-Object { @('fits', 'fits-if-freed') -contains [string]$_.Verdict })
    if ($usable.Count -gt 0) {
        Write-LokiErr (Get-LokiText 'hwscan.addSmallerTier' -ArgumentList @([string]$usable[0].Tier.Id))
        return
    }
    Write-LokiErr (Get-LokiText 'hwscan.machineTooSmall')
}

function Write-LokiHwscanGuidance {
    <#
        The "close something" hint, shown exactly when freeing memory would change the answer -- on a machine where
        everything already fits it would be noise.

        NOT shown for --model: the operator who names a tier has already made the choice, and answering a question
        they did not ask reads as a non-sequitur at best. On `--model max-ceiling` (refused as permanently too big)
        it read as a contradiction -- "freeing memory will not help" followed by "free 3.55 GB" -- even though both
        sentences were true about different tiers. Found by running the real report, not by a unit test.

        The numbers are DESCRIPTIVE ("holding ~X GB"), never a promise ("closing this frees X GB"): WorkingSet64
        double-counts pages shared between an app's own processes, so it is an upper bound (see Get-LokiMemoryConsumer
        for the measurements behind that choice). Naming the holders is what the operator asked for; guaranteeing the
        yield is something no counter on Windows can honestly do.
    #>
    param($Report, [string]$Override)

    if (-not [string]::IsNullOrWhiteSpace($Override)) { return }

    $blocked = @($Report | Where-Object { [string]$_.Verdict -eq 'fits-if-freed' })
    if ($blocked.Count -eq 0) { return }
    # The cheapest tier to unlock, chosen by the number itself rather than by position in a sorted list -- the two
    # coincide today (NeedFreeGB grows with resident size), but tying the message to the sort order would make a
    # semantic promise depend on a presentation decision.
    $best = $blocked[0]
    foreach ($row in $blocked) { if ([double]$row.NeedFreeGB -lt [double]$best.NeedFreeGB) { $best = $row } }

    $consumers = Get-LokiMemoryConsumer -Top 5
    if (@($consumers).Count -eq 0) { return }

    Write-LokiLine ''
    Write-LokiLine (Get-LokiText 'hwscan.freeHint' -ArgumentList @($best.NeedFreeGB, [string]$best.Tier.Id))
    foreach ($c in @($consumers)) {
        Write-LokiLine (Get-LokiText 'hwscan.consumerRow' -ArgumentList @([string]$c.Name, $c.ProcessCount, $c.ResidentGB))
    }
}

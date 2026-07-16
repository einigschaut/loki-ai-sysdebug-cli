# commands/hwscan.ps1 -- `loki hwscan` (scaffolded by build/New-LokiCommand.ps1, then implemented). ADR-0002/0013.
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
            @{ Flag = '--force'; Desc = 'With --model: report the tier as usable even if it exceeds the RAM budget' }
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
    # `loki hwscan --force` expecting the budget to be lifted and get a normal, budget-respecting answer with no hint
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

    $budget = Get-LokiTierBudget -TotalRamGB $hw.TotalRamGB -AvailableRamGB $hw.AvailableRamGB
    if ($null -ne $budget.BudgetGB) {
        Write-LokiLine (Get-LokiText 'hwscan.budget' -ArgumentList @($budget.BudgetGB, $budget.ReserveGB))
    }

    $models = Get-LokiModelManifest -Path (Join-Path $Context.AppRoot 'models\manifest.psd1')
    $installed = Get-LokiInstalledTiers -Models $models -ModelsDir (Join-Path $Context.AppRoot 'models')
    Write-LokiLine (Get-LokiText 'hwscan.installed' -ArgumentList @(@($installed).Count, @($models).Count))
    foreach ($t in @($installed)) {
        Write-LokiLine (Get-LokiText 'hwscan.tierRow' -ArgumentList @([string]$t.Id, [string]$t.Model, $t.ResidentGB))
    }

    # The 2 GB floor from DESIGN.md 3.2 is a distinct answer, not just "nothing fits": below it NO tier can ever help,
    # so telling the operator to fetch a smaller one would be advice that cannot work. It has to name the raw-collection
    # path instead. An override + --force still gets through -- that is the operator overruling us knowingly.
    if ((-not $budget.Ok) -and ([string]$budget.Reason -eq 'budget-too-small') -and (-not $force)) {
        Write-LokiErr (Get-LokiText 'hwscan.budgetTooSmall' -ArgumentList @($budget.BudgetGB))
        return (Get-LokiExitCode 'OfflineEngineMissing')
    }

    $sel = Select-LokiTier -Tiers $installed -BudgetGB $budget.BudgetGB -Override $override -Force:$force

    if ($sel.Ok) {
        Write-LokiOk (Get-LokiText 'hwscan.selected' -ArgumentList @([string]$sel.Tier.Id, [string]$sel.Tier.Model, $sel.Tier.ResidentGB))
        if ([string]$sel.Reason -eq 'forced') {
            # Two different truths: with a budget we can say by how much it overshoots; without a RAM reading we
            # must NOT print a blank where a number belongs and call it "free".
            if ($null -eq $budget.BudgetGB) { Write-LokiWarn (Get-LokiText 'hwscan.forcedRamUnknown' -ArgumentList @($sel.Tier.ResidentGB)) }
            else { Write-LokiWarn (Get-LokiText 'hwscan.forced' -ArgumentList @($sel.Tier.ResidentGB, $budget.BudgetGB)) }
        }
        return (Get-LokiExitCode 'Ok')
    }

    # Every "no" says WHY in the operator's terms, and maps to a stable exit code. A machine that cannot run any model
    # is not an error in the tool -- it is an answer -- but the offline engine genuinely is unavailable, so it exits
    # OfflineEngineMissing rather than pretending success.
    switch ([string]$sel.Reason) {
        'no-tiers-installed' { Write-LokiErr (Get-LokiText 'hwscan.noneInstalled') }
        'override-not-installed' { Write-LokiErr (Get-LokiText 'hwscan.overrideMissing' -ArgumentList @([string]$override)) }
        'override-too-large' { Write-LokiErr (Get-LokiText 'hwscan.overrideTooLarge' -ArgumentList @([string]$override, $sel.Tier.ResidentGB, $budget.BudgetGB)) }
        'ram-unknown' { Write-LokiErr (Get-LokiText 'hwscan.ramUnknownFatal') }
        default { Write-LokiErr (Get-LokiText 'hwscan.nothingFits' -ArgumentList @($budget.BudgetGB)) }
    }
    return (Get-LokiExitCode 'OfflineEngineMissing')
}

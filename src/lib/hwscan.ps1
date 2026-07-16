# lib/hwscan.ps1 -- hardware scan + offline model tier selection (DESIGN.md section 3.2, ADR-0013).
# The question this answers on a machine we have never seen: which offline model can we run here WITHOUT making an
# already-struggling box worse? Starting a model that does not fit is not a graceful degradation -- it swaps the host
# to a standstill, which is the opposite of diagnosing it. So we decide ourselves rather than trusting the engine's
# memory mapping to fail politely.
#
# The rule is DESIGN.md section 3.2, verbatim:
#     reserve = max(4 GB, 25% of total RAM)     the host keeps >= 4 GB AND >= 25%
#     budget  = available RAM - reserve
#     choose the largest tier whose resident size <= budget
#     budget < 2 GB -> no LLM; raw collection only, with a stated reason
# AVAILABLE, not total, is deliberate: on a box that is already thrashing, total RAM is a fiction.
#
# Split of responsibilities (so the interesting half is testable without a machine):
#   * Get-LokiHardwareProfile is the ONLY impure function -- it probes, never throws, and returns $null fields when a
#     probe fails (same discipline as lib/posture.ps1).
#   * Get-LokiTierBudget and Select-LokiTier are PURE and table-tested. All the judgement lives there.
# Contract:
#   Get-LokiHardwareProfile -> [hashtable]{ TotalRamGB; AvailableRamGB; CpuName; CpuCores; Is64BitOs }  (never throws;
#       any field may be $null when the probe failed).
#   Get-LokiTierBudget -TotalRamGB <double> -AvailableRamGB <double> -> [hashtable]{ ReserveGB; BudgetGB; Ok; Reason }
#       (pure; Ok=$false + Reason when there is not enough room for any model, or the inputs are unusable).
#   Get-LokiInstalledTiers -Models <manifest entries> -ModelsDir <dir> -> [object[]] the entries whose file is actually
#       on the stick at the pinned size (presence, NOT integrity -- the hash check belongs at load time, ADR-0012).
#   Select-LokiTier -Tiers <entries> -BudgetGB <double> [-Override <id>] [-Force] -> [hashtable]{ Ok; Reason; [Tier] }
#       (pure; Reason is a stable machine token, never localized -- same convention as lib/allowlist.ps1).
# ASCII-only file -> no BOM (CLAUDE.md section 1).
Set-StrictMode -Version Latest

# Below this there is no point starting any LLM -- even the nano tier needs ~2.5 GB resident (DESIGN.md section 3.2).
$script:LokiMinUsefulBudgetGB = 2.0

function Get-LokiHardwareProfile {
    <#
        The one impure function here. Every probe is individually guarded: a machine that refuses to answer must
        produce a $null field and an honest "unknown" downstream, never a crash and never a guessed number -- guessing
        RAM is how you end up swapping the host you were asked to fix.
    #>
    # NOT $profile: that is a PowerShell automatic variable (the profile script path).
    $hw = @{ TotalRamGB = $null; AvailableRamGB = $null; CpuName = $null; CpuCores = $null; Is64BitOs = $null }

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        # CIM reports these in KILOBYTES (TotalVisibleMemorySize / FreePhysicalMemory) -- a units mistake here would
        # silently be a factor of a million, so the conversion is explicit.
        $hw.TotalRamGB = [math]::Round(([double]$os.TotalVisibleMemorySize * 1KB / 1GB), 2)
        $hw.AvailableRamGB = [math]::Round(([double]$os.FreePhysicalMemory * 1KB / 1GB), 2)
    }
    catch {
        # Sentinel, never a guess: an unreadable host must degrade to "unknown" and a refusal downstream.
        $hw.TotalRamGB = $null
        $hw.AvailableRamGB = $null
    }

    try {
        $cpu = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop) | Select-Object -First 1
        if ($null -ne $cpu) {
            $hw.CpuName = ([string]$cpu.Name).Trim()
            $hw.CpuCores = [int]$cpu.NumberOfLogicalProcessors
        }
    }
    catch {
        $hw.CpuName = $null
        $hw.CpuCores = $null
    }

    try { $hw.Is64BitOs = [Environment]::Is64BitOperatingSystem }
    catch { $hw.Is64BitOs = $null }

    return $hw
}

function Get-LokiTierBudget {
    # Pure. DESIGN.md section 3.2: reserve = max(4 GB, 25% of total); budget = available - reserve.
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$TotalRamGB,
        [Parameter(Mandatory = $true)][AllowNull()]$AvailableRamGB
    )
    if (($null -eq $TotalRamGB) -or ($null -eq $AvailableRamGB)) {
        return @{ ReserveGB = $null; BudgetGB = $null; Ok = $false; Reason = 'ram-unknown' }
    }
    $total = [double]$TotalRamGB
    $avail = [double]$AvailableRamGB
    # available > total is not merely odd, it is the one inconsistency that breaks the safety property: a probe
    # reporting 4 GB total / 64 GB available would budget 60 GB and cheerfully pick a 24 GB model for a 4 GB box.
    # Get-LokiHardwareProfile is exactly the function whose contract is "a probe may lie", so the pure rule refuses
    # rather than trusting it.
    if (($total -le 0) -or ($avail -lt 0) -or ($avail -gt $total)) {
        return @{ ReserveGB = $null; BudgetGB = $null; Ok = $false; Reason = 'ram-implausible' }
    }

    $reserve = [math]::Max(4.0, ($total * 0.25))
    $budget = $avail - $reserve
    if ($budget -lt 0) { $budget = 0.0 }
    $reserve = [math]::Round($reserve, 2)
    $budget = [math]::Round($budget, 2)

    if ($budget -lt $script:LokiMinUsefulBudgetGB) {
        return @{ ReserveGB = $reserve; BudgetGB = $budget; Ok = $false; Reason = 'budget-too-small' }
    }
    return @{ ReserveGB = $reserve; BudgetGB = $budget; Ok = $true; Reason = 'ok' }
}

function Get-LokiInstalledTiers {
    <#
        Which tiers are actually ON this stick. `loki setup` deliberately lets the operator download a subset, so
        selecting from the full catalogue would happily recommend a model that is not there. Presence + pinned size
        only: verifying a 19 GB hash here would cost a minute on a machine we are trying to help quickly, and the
        authoritative integrity check belongs at load time (ADR-0012), not to a report.
    #>
    # 'Tiers' is the exact contract name (the result is the set of installed tiers, not one tier) -- CLAUDE.md
    # section 3 forbids renaming a specified interface; suppress rather than rename.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Exact contract name (result is the set of installed tiers, not one tier); renaming after the contract is specified is forbidden by CLAUDE.md section 3.')]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Models,
        [Parameter(Mandatory = $true)][string]$ModelsDir
    )
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($m in @($Models)) {
        $p = Join-Path $ModelsDir ([string]$m.FileName)
        if (Test-Path -LiteralPath $p) {
            $len = -1
            try { $len = (Get-Item -LiteralPath $p).Length } catch { $len = -1 }
            if ($len -eq [long]$m.SizeBytes) { $found.Add($m) }
        }
    }
    return , $found.ToArray()   # leading comma: a single installed tier must stay an array (no pipeline unwrap)
}

function Select-LokiTier {
    <#
        Pure + table-tested. Picks the strongest tier that fits the budget, out of the tiers actually installed.
        -Override names a tier explicitly (`offline --model <tier>`); it still has to fit unless -Force is given, and
        -Force is the operator knowingly accepting the swap risk -- it is reported, never silent.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Tiers,
        [Parameter(Mandatory = $true)][AllowNull()]$BudgetGB,
        [string]$Override,
        [switch]$Force
    )
    $list = @($Tiers)
    if ($list.Count -eq 0) { return @{ Ok = $false; Reason = 'no-tiers-installed' } }

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $want = $Override.Trim().ToLowerInvariant()
        $t = $list | Where-Object { ([string]$_.Id).ToLowerInvariant() -eq $want } | Select-Object -First 1
        if ($null -eq $t) { return @{ Ok = $false; Reason = 'override-not-installed' } }
        if ($null -eq $BudgetGB) {
            if ($Force) { return @{ Ok = $true; Reason = 'forced'; Tier = $t } }
            return @{ Ok = $false; Reason = 'ram-unknown' }
        }
        if ([double]$t.ResidentGB -le [double]$BudgetGB) { return @{ Ok = $true; Reason = 'override'; Tier = $t } }
        if ($Force) { return @{ Ok = $true; Reason = 'forced'; Tier = $t } }
        return @{ Ok = $false; Reason = 'override-too-large'; Tier = $t }
    }

    if ($null -eq $BudgetGB) { return @{ Ok = $false; Reason = 'ram-unknown' } }
    $budget = [double]$BudgetGB

    # Strongest that fits = largest resident footprint within budget. Ties broken by id for determinism, so the same
    # stick on the same machine never recommends a different model twice.
    $fits = @($list | Where-Object { [double]$_.ResidentGB -le $budget } |
            Sort-Object -Property @{ Expression = { [double]$_.ResidentGB } ; Descending = $true }, @{ Expression = { [string]$_.Id } })
    if ($fits.Count -eq 0) { return @{ Ok = $false; Reason = 'nothing-fits' } }
    return @{ Ok = $true; Reason = 'selected'; Tier = $fits[0] }
}

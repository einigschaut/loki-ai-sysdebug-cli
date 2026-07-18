# lib/hwscan.ps1 -- hardware scan + offline model tier selection (DESIGN.md section 3.2, ADR-0013, ADR-0017).
# The question this answers on a machine we have never seen: which offline model can we run here WITHOUT making an
# already-struggling box worse? Starting a model that does not fit is not a graceful degradation -- it swaps the host
# to a standstill, which is the opposite of diagnosing it. So we decide ourselves rather than trusting the engine's
# memory mapping to fail politely.
#
# THE RULE IS TWO INDEPENDENT GUARDS (ADR-0017). They answer two different questions, and the single "reserve" figure
# they replace conflated them -- deriving how much room the host needs from how much RAM it happens to have installed:
#
#   thrash guard   resident + 1.5 GB <= available     don't take what isn't there.
#                  The headroom is ABSOLUTE, not a percentage: what an OS needs to avoid paging does not grow with the
#                  bank size. 1.5 GB is "the operator can still keep a window and Task Manager open while it runs".
#   ballast guard  resident <= 60% of TOTAL           don't dominate the machine you came to help.
#                  This one is about installed RAM, because "am I too big a burden here" genuinely is proportional.
#
# Their ORDER is a correctness property, not a preference: ballast is checked first, because failing it is permanent
# (no amount of closing programs helps) while failing thrash is a "close something and retry". Reporting the wrong one
# sends the operator off to free memory that will never be enough.
#
# AVAILABLE, not total, is deliberate for the thrash guard: on a box that is already thrashing, total RAM is a fiction.
# And available already INCLUDES the standby cache (measured: FreePhysicalMemory 6.45 GB vs Memory\Available MBytes
# 6.43 GB) -- so the "modern OS frees memory on demand" effect is counted, not ignored. What is deliberately NOT
# counted is Windows paging out somebody else's working set to make room: that IS the ballast, and the operator gets
# told what is holding memory instead of having their browser silently made slow.
#
# Split of responsibilities (so the interesting half is testable without a machine):
#   * Get-LokiHardwareProfile and Get-LokiMemoryConsumer are the ONLY impure functions -- they probe, never throw, and
#     return $null fields / an empty list when a probe fails (same discipline as lib/posture.ps1).
#   * Get-LokiModelRamLimit, Get-LokiTierFit, Get-LokiTierFitReport and Select-LokiTier are PURE and table-tested.
#     All the judgement lives there.
# Contract:
#   Get-LokiHardwareProfile -> [hashtable]{ TotalRamGB; AvailableRamGB; CpuName; CpuCores; Is64BitOs }  (never throws;
#       any field may be $null when the probe failed).
#   Get-LokiModelRamLimit -TotalRamGB <double> -AvailableRamGB <double> -> [hashtable]{ CapGB; UsableNowGB; Ok; Reason }
#       (pure; the machine's two ceilings, independent of any tier. Ok=$false + Reason when the reading is unusable.)
#   Get-LokiTierFit -TotalRamGB -AvailableRamGB -ResidentGB -> [hashtable]{ Verdict; NeedFreeGB; CapGB; UsableNowGB }
#       (pure; Verdict is a stable machine token, never localized -- same convention as lib/allowlist.ps1:
#        fits | fits-if-freed | too-big | ram-unknown | ram-implausible.)
#   Get-LokiTierFitReport -Tiers <entries> -TotalRamGB -AvailableRamGB -> [object[]] one row per tier, largest first:
#       { Tier; Verdict; NeedFreeGB }. ASSIGN the result -- see the `return ,` note on Get-LokiInstalledTiers.
#   Get-LokiInstalledTiers -Models <manifest entries> -ModelsDir <dir> -> [object[]] the entries whose file is actually
#       on the stick at the pinned size (presence, NOT integrity -- the hash check belongs at load time, ADR-0012).
#   Select-LokiTier -Tiers <entries> -TotalRamGB -AvailableRamGB [-Override <id>] [-Force] -> [hashtable]{ Ok; Reason; [Tier] }
#       (pure; Reason: selected | override | forced | override-not-installed | override-needs-free | override-too-big |
#        no-tiers-installed | nothing-fits | ram-unknown.)
#   Get-LokiMemoryConsumer [-Top <int>] -> [object[]] { Name; ProcessCount; ResidentGB } biggest first (never throws).
# ASCII-only file -> no BOM (CLAUDE.md section 1).
Set-StrictMode -Version Latest

# The two guards, as named constants so the numbers are explainable rather than magic (ADR-0013 decision 7).
$script:LokiHeadroomGB = 1.5           # thrash guard: what stays free for the host BESIDES the model
$script:LokiBallastMaxFraction = 0.6   # ballast guard: the largest share of installed RAM a model may ever occupy

# Kernel bookkeeping that Windows surfaces as processes. Excluded from the consumer list because they are not apps
# holding memory in the sense that list means -- "Memory Compression" in particular holds OTHER processes' pages in
# compressed form, so listing it would double-count what is already attributed to firefox and friends. This is a
# bounded, stable set (not an app deny-list that rots): a name missed here costs one odd row in a report, nothing more.
$script:LokiKernelPseudoProcesses = @('Idle', 'System', 'Registry', 'Memory Compression', 'Secure System')

function Get-LokiHardwareProfile {
    <#
        The impure probe. Every reading is individually guarded: a machine that refuses to answer must produce a $null
        field and an honest "unknown" downstream, never a crash and never a guessed number -- guessing RAM is how you
        end up swapping the host you were asked to fix.
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

function Get-LokiTierField {
    <#
        Read one field off a tier entry without exploding on an entry that predates it.
        Measured under Windows PowerShell 5.1 + StrictMode -Latest: reading an ABSENT key off a hashtable throws
        PropertyNotFoundException -- it does NOT quietly yield $null. Tier entries come from the manifest (hashtables),
        but Select-LokiTier must not become a landmine for any caller holding an older-shaped entry.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Tier,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Tier) { return $null }
    if ($Tier -is [System.Collections.IDictionary]) {
        if (-not $Tier.Contains($Name)) { return $null }
        return $Tier[$Name]
    }
    $p = $Tier.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Get-LokiModelRamLimit {
    <#
        Pure. The machine's two ceilings for ANY model -- see the two guards at the top of this file.
        Deliberately tier-free: `loki hwscan` prints both numbers so the verdict below is explainable rather than
        magic, and both are properties of the machine alone.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$TotalRamGB,
        [Parameter(Mandatory = $true)][AllowNull()]$AvailableRamGB
    )
    if (($null -eq $TotalRamGB) -or ($null -eq $AvailableRamGB)) {
        return @{ CapGB = $null; UsableNowGB = $null; Ok = $false; Reason = 'ram-unknown' }
    }
    $total = [double]$TotalRamGB
    $avail = [double]$AvailableRamGB
    # available > total is not merely odd, it is the one inconsistency that breaks the safety property: a probe
    # reporting 4 GB total / 64 GB available would happily clear a 24 GB model for a 4 GB box. Get-LokiHardwareProfile
    # is exactly the function whose contract is "a probe may lie", so the pure rule refuses rather than trusting it.
    if (($total -le 0) -or ($avail -lt 0) -or ($avail -gt $total)) {
        return @{ CapGB = $null; UsableNowGB = $null; Ok = $false; Reason = 'ram-implausible' }
    }

    $cap = [math]::Round(($total * $script:LokiBallastMaxFraction), 2)
    $usable = [math]::Round(($avail - $script:LokiHeadroomGB), 2)
    if ($usable -lt 0) { $usable = 0.0 }
    return @{ CapGB = $cap; UsableNowGB = $usable; Ok = $true; Reason = 'ok' }
}

function Get-LokiTierFit {
    <#
        Pure. One tier against one machine reading. The whole rule is here; everything else in this file arranges the
        answers. See the top of the file for why ballast is tested BEFORE thrash.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$TotalRamGB,
        [Parameter(Mandatory = $true)][AllowNull()]$AvailableRamGB,
        [Parameter(Mandatory = $true)][AllowNull()]$ResidentGB
    )
    $limit = Get-LokiModelRamLimit -TotalRamGB $TotalRamGB -AvailableRamGB $AvailableRamGB
    if (-not $limit.Ok) {
        return @{ Verdict = [string]$limit.Reason; NeedFreeGB = $null; CapGB = $null; UsableNowGB = $null }
    }
    if ($null -eq $ResidentGB) {
        return @{ Verdict = 'ram-implausible'; NeedFreeGB = $null; CapGB = $limit.CapGB; UsableNowGB = $limit.UsableNowGB }
    }
    $resident = [double]$ResidentGB
    # NeedFreeGB is deliberately NOT seeded here: PowerShell's hashtable + THROWS on a duplicate key rather than
    # merging, so every branch below owns the key exactly once.
    $base = @{ CapGB = $limit.CapGB; UsableNowGB = $limit.UsableNowGB }

    # Ballast FIRST: this is the permanent no. Freeing memory cannot move it, so reporting it as "close something"
    # would send the operator after memory that will never be enough.
    if ($resident -gt [double]$limit.CapGB) { return ($base + @{ Verdict = 'too-big'; NeedFreeGB = $null }) }

    if ($resident -gt [double]$limit.UsableNowGB) {
        # How much more AVAILABLE memory this tier needs -- the number the operator can act on.
        $need = [math]::Round(($resident + $script:LokiHeadroomGB - [double]$AvailableRamGB), 2)
        if ($need -lt 0) { $need = 0.0 }
        return ($base + @{ Verdict = 'fits-if-freed'; NeedFreeGB = $need })
    }
    return ($base + @{ Verdict = 'fits'; NeedFreeGB = 0.0 })
}

function Get-LokiTierFitReport {
    <#
        Pure. Every tier with its verdict, biggest first -- the material both the picker and the report render, so the
        rule is applied in exactly one place (CLAUDE.md section 2: one truth per concept).
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Tiers,
        [Parameter(Mandatory = $true)][AllowNull()]$TotalRamGB,
        [Parameter(Mandatory = $true)][AllowNull()]$AvailableRamGB
    )
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($t in @($Tiers)) {
        $fit = Get-LokiTierFit -TotalRamGB $TotalRamGB -AvailableRamGB $AvailableRamGB -ResidentGB (Get-LokiTierField -Tier $t -Name 'ResidentGB')
        $rows.Add(@{ Tier = $t; Verdict = [string]$fit.Verdict; NeedFreeGB = $fit.NeedFreeGB })
    }
    # Ties broken by id so the same stick on the same machine never reports a different order twice.
    $sorted = @($rows | Sort-Object -Property @{ Expression = { [double](Get-LokiTierField -Tier $_.Tier -Name 'ResidentGB') } ; Descending = $true },
        @{ Expression = { [string](Get-LokiTierField -Tier $_.Tier -Name 'Id') } })
    return , $sorted   # leading comma: the caller must ASSIGN (measured: @(Get-LokiTierFitReport ...) collapses to 1)
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
        Pure + table-tested. Picks the RECOMMENDED tier when it fits, out of the tiers actually installed -- not the
        largest that fits. RAM is not the only capacity: the manifest's own note puts the 32B tier at ~1-2 tok/s on
        CPU, so "biggest that fits" would hand a 128 GB server a model that technically runs and practically does not.
        The manifest's Default flag already encodes somebody balancing quality against speed; a RAM figure does not
        get to overrule it. Anything larger is offered by the report, never auto-selected (ADR-0017).

        -Override names a tier explicitly (a `--model <tier>` override where a command wires it); it still has to fit unless -Force is given, and
        -Force is the operator knowingly accepting the swap risk -- it is reported, never silent.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Tiers,
        [Parameter(Mandatory = $true)][AllowNull()]$TotalRamGB,
        [Parameter(Mandatory = $true)][AllowNull()]$AvailableRamGB,
        [string]$Override,
        [switch]$Force
    )
    $list = @($Tiers)
    if ($list.Count -eq 0) { return @{ Ok = $false; Reason = 'no-tiers-installed' } }

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $want = $Override.Trim().ToLowerInvariant()
        $t = $list | Where-Object { ([string](Get-LokiTierField -Tier $_ -Name 'Id')).ToLowerInvariant() -eq $want } | Select-Object -First 1
        if ($null -eq $t) { return @{ Ok = $false; Reason = 'override-not-installed' } }
        $fit = Get-LokiTierFit -TotalRamGB $TotalRamGB -AvailableRamGB $AvailableRamGB -ResidentGB (Get-LokiTierField -Tier $t -Name 'ResidentGB')
        if ([string]$fit.Verdict -eq 'fits') { return @{ Ok = $true; Reason = 'override'; Tier = $t } }
        if ($Force) { return @{ Ok = $true; Reason = 'forced'; Tier = $t } }
        # The two refusals are different advice, so they are different tokens: one says "close something", the other
        # says "not on this machine, ever".
        if ([string]$fit.Verdict -eq 'fits-if-freed') {
            return @{ Ok = $false; Reason = 'override-needs-free'; Tier = $t; NeedFreeGB = $fit.NeedFreeGB }
        }
        if ([string]$fit.Verdict -eq 'too-big') { return @{ Ok = $false; Reason = 'override-too-big'; Tier = $t } }
        return @{ Ok = $false; Reason = 'ram-unknown'; Tier = $t }
    }

    $report = Get-LokiTierFitReport -Tiers $list -TotalRamGB $TotalRamGB -AvailableRamGB $AvailableRamGB
    if (@($report | Where-Object { @('ram-unknown', 'ram-implausible') -contains [string]$_.Verdict }).Count -gt 0) {
        return @{ Ok = $false; Reason = 'ram-unknown' }
    }
    $fits = @($report | Where-Object { [string]$_.Verdict -eq 'fits' })   # already sorted largest-first
    if ($fits.Count -eq 0) { return @{ Ok = $false; Reason = 'nothing-fits' } }

    # The ceiling is the recommended tier's resident size. It is read from the INSTALLED set on purpose: a stick
    # without the recommended tier was curated that way deliberately, and inventing a ceiling from a model the
    # operator chose not to carry would be a constraint derived from absent data.
    $ceiling = $null
    foreach ($r in $report) {
        if ([bool](Get-LokiTierField -Tier $r.Tier -Name 'Default')) { $ceiling = [double](Get-LokiTierField -Tier $r.Tier -Name 'ResidentGB') }
    }
    if ($null -eq $ceiling) { return @{ Ok = $true; Reason = 'selected'; Tier = $fits[0].Tier } }

    $atOrBelow = @($fits | Where-Object { [double](Get-LokiTierField -Tier $_.Tier -Name 'ResidentGB') -le $ceiling })
    # Cannot be empty for a sane catalogue -- both guards are monotonic in resident size, so if anything fits, the
    # recommended tier or something smaller does. Falling back to the smallest that fits keeps a mis-flagged manifest
    # from returning nothing at all.
    if ($atOrBelow.Count -eq 0) { return @{ Ok = $true; Reason = 'selected'; Tier = $fits[$fits.Count - 1].Tier } }
    return @{ Ok = $true; Reason = 'selected'; Tier = $atOrBelow[0].Tier }
}

function Get-LokiMemoryConsumer {
    <#
        Impure, read-only, and never throws: which apps are holding this machine's memory right now, grouped by app.
        Grouping is the point -- the operator's browser is 21 processes, and a per-process list would bury the answer.

        WHY WorkingSet64 (measured on a real 31.46 GB box, 24.5 GB in use):
          PrivateMemorySize64  summed to 36.23 GB -- more than the machine HAS. It is commit charge and counts pages
                               already paged out, so it does not answer "what is in RAM".
          Working Set-Private  summed to 10.01 GB against 24.5 GB in use -- it excludes shared pages and understates
                               an app's footprint by roughly half.
          WorkingSet64         summed to 23.15 GB against 24.5 GB in use, and it is the number the operator can check
                               against Task Manager. It DOES double-count pages shared between an app's processes,
                               which makes it an upper bound -- which is why the caller must report it as "holding
                               ~X GB" and never promise "closing this frees X GB".
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'A process that exits between Get-Process and the WorkingSet64 read throws, and that race IS the normal path on a busy box. The right contribution from a process that no longer exists is nothing; an error per vanished process would bury the report on a tool people run when something is already wrong, and this whole function is best-effort guidance -- the tier verdict does not depend on it.')]
    param([int]$Top = 5)
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        $groups = Get-Process -ErrorAction Stop | Group-Object -Property ProcessName
        foreach ($g in $groups) {
            if ($script:LokiKernelPseudoProcesses -contains [string]$g.Name) { continue }
            $sum = 0.0
            foreach ($p in $g.Group) {
                try { $sum += [double]$p.WorkingSet64 } catch { }
            }
            $rows.Add(@{ Name = [string]$g.Name; ProcessCount = [int]$g.Count; ResidentGB = [math]::Round(($sum / 1GB), 2) })
        }
    }
    catch {
        # A host that will not enumerate its processes gets no guidance, not a crash -- the tier verdict above is the
        # answer that matters and it does not depend on this.
        return , ([object[]]@())
    }
    $sorted = @($rows | Sort-Object -Property @{ Expression = { [double]$_.ResidentGB } ; Descending = $true },
        @{ Expression = { [string]$_.Name } } | Select-Object -First $Top)
    return , $sorted   # leading comma: the caller must ASSIGN (see Get-LokiTierFitReport)
}

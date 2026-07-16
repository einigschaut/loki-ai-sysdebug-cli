# tests/hwscan.Tests.ps1 -- hardware scan + tier selection (src/lib/hwscan.ps1, DESIGN.md section 3.2, ADR-0013/0017).
# CLAUDE.md section 6 requires tier selection to be table-tested, so the pure functions are tested as a truth table
# straight off the design rule: resident + 1.5 GB <= available (thrash) AND resident <= 60% of total (ballast);
# ballast is decided FIRST; the auto-pick is the RECOMMENDED tier that fits, never the largest.
# Get-LokiHardwareProfile and Get-LokiMemoryConsumer are the impure ones; they are tested for the properties that
# matter (never throw, never invent a number, report GB not the raw KB CIM hands back) rather than for this machine's
# values. The command wiring lives in tests/hwscan-command.Tests.ps1 (same split as auth / auth-command).
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\hwscan.ps1"

    # A miniature catalogue in the shape lib/models.ps1 produces -- residents chosen to make the boundaries explicit
    # rather than to mirror the real manifest (that one is covered by tests/models.Tests.ps1). 'small' carries the
    # Default flag exactly as the real manifest does, because the picker's whole rule turns on it.
    $script:Tiers = @(
        @{ Id = 'nano'; Model = 'N'; ResidentGB = 2.5; FileName = 'n.gguf'; SizeBytes = 1000; Default = $false }
        @{ Id = 'small'; Model = 'S'; ResidentGB = 4.5; FileName = 's.gguf'; SizeBytes = 2000; Default = $true }
        @{ Id = 'mid'; Model = 'M'; ResidentGB = 7.0; FileName = 'm.gguf'; SizeBytes = 3000; Default = $false }
        @{ Id = 'max'; Model = 'X'; ResidentGB = 24.0; FileName = 'x.gguf'; SizeBytes = 4000; Default = $false }
    )

    $script:RootTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("loki-hwscan-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:RootTmp | Out-Null

    function global:New-HwCaseDir {
        $d = Join-Path $script:RootTmp ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        return $d
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:RootTmp) { Remove-Item -LiteralPath $script:RootTmp -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item Function:\New-HwCaseDir -ErrorAction SilentlyContinue
}

Describe 'Get-LokiModelRamLimit (pure; the two ceilings)' {

    It 'total=<total> avail=<avail> -> cap=<cap> usableNow=<usable>' -ForEach @(
        # The ballast cap follows INSTALLED RAM; the headroom is absolute and does not.
        @{ total = 8; avail = 7; cap = 4.8; usable = 5.5 }
        @{ total = 16; avail = 12; cap = 9.6; usable = 10.5 }
        @{ total = 32; avail = 30; cap = 19.2; usable = 28.5 }
        # THE regression this rule exists for: a big host is no longer punished for RAM it merely owns. The old rule
        # reserved 25% (32 GB) here and left an 8 GB budget on a 128 GB machine.
        @{ total = 128; avail = 40; cap = 76.8; usable = 38.5 }
        # Headroom never drives usable-now below zero.
        @{ total = 8; avail = 1; cap = 4.8; usable = 0.0 }
        @{ total = 8; avail = 1.5; cap = 4.8; usable = 0.0 }
    ) {
        $r = Get-LokiModelRamLimit -TotalRamGB $total -AvailableRamGB $avail
        $r.Ok | Should -BeTrue
        $r.CapGB | Should -Be $cap
        $r.UsableNowGB | Should -Be $usable
    }

    It 'refuses to invent a limit when RAM is unknown or implausible: <case> -> <reason>' -ForEach @(
        @{ case = 'total null'; total = $null; avail = 8; reason = 'ram-unknown' }
        @{ case = 'avail null'; total = 16; avail = $null; reason = 'ram-unknown' }
        @{ case = 'both null'; total = $null; avail = $null; reason = 'ram-unknown' }
        @{ case = 'total zero'; total = 0; avail = 8; reason = 'ram-implausible' }
        @{ case = 'negative avail'; total = 16; avail = -1; reason = 'ram-implausible' }
        # A probe reporting more free than exists is the one inconsistency that breaks the safety property:
        # 4 GB total / 64 GB available would clear a 24 GB model for a 4 GB box.
        @{ case = 'available exceeds total'; total = 4; avail = 64; reason = 'ram-implausible' }
    ) {
        $r = Get-LokiModelRamLimit -TotalRamGB $total -AvailableRamGB $avail
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be $reason
        $r.CapGB | Should -BeNullOrEmpty
        $r.UsableNowGB | Should -BeNullOrEmpty
    }
}

Describe 'Get-LokiTierFit (pure; the whole rule as a truth table)' {

    It '<case>: total=<total> avail=<avail> resident=<resident> -> <verdict>' -ForEach @(
        # --- the maintainer's real dev box, which the OLD rule refused outright (reserve 7.87 -> budget 0) ---
        @{ case = 'dev box runs the recommended tier'; total = 31.46; avail = 7.06; resident = 4.5; verdict = 'fits'; need = 0.0 }
        @{ case = 'dev box, one tier up needs a little freed'; total = 31.46; avail = 7.06; resident = 7.0; verdict = 'fits-if-freed'; need = 1.44 }
        @{ case = 'dev box, the 32B ceiling is simply too much'; total = 31.46; avail = 7.06; resident = 24.0; verdict = 'too-big'; need = $null }
        # --- boundaries: exactly at a guard still passes, a hair over does not ---
        @{ case = 'resident exactly == usable-now'; total = 16; avail = 8.5; resident = 7.0; verdict = 'fits'; need = 0.0 }
        @{ case = 'a hair over usable-now'; total = 16; avail = 8.4; resident = 7.0; verdict = 'fits-if-freed'; need = 0.1 }
        @{ case = 'resident exactly == the ballast cap'; total = 16; avail = 14; resident = 9.6; verdict = 'fits'; need = 0.0 }
        @{ case = 'a hair over the ballast cap'; total = 16; avail = 14; resident = 9.7; verdict = 'too-big'; need = $null }
        # --- PRECEDENCE: failing BOTH guards must report too-big, never fits-if-freed. Reporting the thrash guard
        #     here would send the operator off to free memory that could never be enough (ADR-0017).
        @{ case = 'fails both guards -> the permanent answer wins'; total = 8; avail = 7; resident = 7.0; verdict = 'too-big'; need = $null }
        # --- small hosts ---
        @{ case = 'busy 8 GB office box, nano within reach'; total = 8; avail = 3; resident = 2.5; verdict = 'fits-if-freed'; need = 1.0 }
        @{ case = 'fresh 8 GB box runs the recommended tier'; total = 8; avail = 7; resident = 4.5; verdict = 'fits'; need = 0.0 }
        @{ case = 'a 4 GB box cannot carry even nano'; total = 4; avail = 3.5; resident = 2.5; verdict = 'too-big'; need = $null }
        # --- big hosts: the ballast cap stops dominating a server, it does not stop USING it ---
        @{ case = '128 GB server clears the 32B tier'; total = 128; avail = 40; resident = 24.0; verdict = 'fits'; need = 0.0 }
    ) {
        $r = Get-LokiTierFit -TotalRamGB $total -AvailableRamGB $avail -ResidentGB $resident
        $r.Verdict | Should -Be $verdict
        if ($null -eq $need) { $r.NeedFreeGB | Should -BeNullOrEmpty }
        else { $r.NeedFreeGB | Should -Be $need }
    }

    It 'an unreadable machine yields the unknown verdict, never a fit: <case>' -ForEach @(
        @{ case = 'total null'; total = $null; avail = 8; verdict = 'ram-unknown' }
        @{ case = 'avail null'; total = 16; avail = $null; verdict = 'ram-unknown' }
        @{ case = 'available exceeds total'; total = 4; avail = 64; verdict = 'ram-implausible' }
    ) {
        $r = Get-LokiTierFit -TotalRamGB $total -AvailableRamGB $avail -ResidentGB 2.5
        $r.Verdict | Should -Be $verdict
    }

    It 'a tier with no resident figure is never declared to fit' {
        # A manifest entry that lost its ResidentGB must not silently become "fits" -- that is the direction that
        # thrashes the host.
        $r = Get-LokiTierFit -TotalRamGB 32 -AvailableRamGB 24 -ResidentGB $null
        $r.Verdict | Should -Not -Be 'fits'
    }
}

Describe 'Get-LokiTierFitReport (pure)' {

    It 'reports every tier, largest first' {
        $r = Get-LokiTierFitReport -Tiers $script:Tiers -TotalRamGB 31.46 -AvailableRamGB 7.06
        @($r).Count | Should -Be 4
        @($r | ForEach-Object { [string]$_.Tier.Id }) -join ',' | Should -Be 'max,mid,small,nano'
    }

    It 'carries the verdict for each tier on the maintainer dev box' {
        $r = Get-LokiTierFitReport -Tiers $script:Tiers -TotalRamGB 31.46 -AvailableRamGB 7.06
        $byId = @{}
        foreach ($row in @($r)) { $byId[[string]$row.Tier.Id] = [string]$row.Verdict }
        $byId['nano'] | Should -Be 'fits'
        $byId['small'] | Should -Be 'fits'
        $byId['mid'] | Should -Be 'fits-if-freed'
        $byId['max'] | Should -Be 'too-big'
    }

    It 'an empty tier list yields an empty report rather than throwing' {
        $r = Get-LokiTierFitReport -Tiers @() -TotalRamGB 32 -AvailableRamGB 24
        @($r).Count | Should -Be 0
    }

    It 'a single-tier report is still an array (regression: .Count must not throw under StrictMode)' {
        $r = Get-LokiTierFitReport -Tiers @($script:Tiers[0]) -TotalRamGB 32 -AvailableRamGB 24
        { $r.Count } | Should -Not -Throw
        $r.Count | Should -Be 1
    }
}

Describe 'Select-LokiTier (pure; table-tested)' {

    It '<case>: total=<total> avail=<avail> -> picks <expect>' -ForEach @(
        # THE headline rule (ADR-0017): the recommended tier, NOT the largest that fits. RAM is not the only
        # capacity -- the 24 GB tier runs at ~1-2 tok/s on CPU, so "biggest that fits" is a trap on a big host.
        @{ case = 'a 128 GB server still gets the recommended tier'; total = 128; avail = 60; expect = 'small' }
        @{ case = 'everything fits -> still the recommended tier'; total = 64; avail = 40; expect = 'small' }
        @{ case = 'the maintainer dev box, mid-morning'; total = 31.46; avail = 7.06; expect = 'small' }
        # Below the recommendation, it degrades to the largest that DOES fit.
        @{ case = 'recommended needs freeing -> next one down'; total = 8; avail = 5; expect = 'nano' }
        @{ case = 'a fresh 8 GB box reaches the recommendation'; total = 8; avail = 7; expect = 'small' }
    ) {
        $r = Select-LokiTier -Tiers $script:Tiers -TotalRamGB $total -AvailableRamGB $avail
        $r.Ok | Should -BeTrue
        $r.Reason | Should -Be 'selected'
        $r.Tier.Id | Should -Be $expect
    }

    It 'BREAK-THE-GUARD: a bigger tier that fits is NOT auto-selected over the recommended one' {
        # Without this the whole ADR-0017 decision is decoration: on this box mid and max both clear both guards.
        $r = Select-LokiTier -Tiers $script:Tiers -TotalRamGB 128 -AvailableRamGB 100
        $r.Tier.Id | Should -Be 'small'
        $r.Tier.ResidentGB | Should -BeLessThan 7.0
    }

    It 'a stick curated WITHOUT the recommended tier falls back to the largest that fits' {
        # No Default flag in this set: inventing a ceiling from a model the operator chose not to carry would be a
        # constraint derived from absent data.
        $r = Select-LokiTier -Tiers @($script:Tiers | Where-Object { $_.Id -in @('nano', 'mid') }) -TotalRamGB 64 -AvailableRamGB 40
        $r.Ok | Should -BeTrue
        $r.Tier.Id | Should -Be 'mid'
    }

    It 'nothing fits right now -> nothing-fits' {
        $r = Select-LokiTier -Tiers $script:Tiers -TotalRamGB 8 -AvailableRamGB 3
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'nothing-fits'
    }

    It 'nothing installed -> no-tiers-installed (never recommends a model that is not on the stick)' {
        $r = Select-LokiTier -Tiers @() -TotalRamGB 64 -AvailableRamGB 40
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'no-tiers-installed'
    }

    It 'picks only from what is INSTALLED, not from the catalogue' {
        # The box could run 'max', but only 'nano' is on the stick.
        $r = Select-LokiTier -Tiers @($script:Tiers | Where-Object { $_.Id -eq 'nano' }) -TotalRamGB 64 -AvailableRamGB 40
        $r.Ok | Should -BeTrue
        $r.Tier.Id | Should -Be 'nano'
    }

    It 'unknown RAM -> refuses to pick rather than guessing' {
        $r = Select-LokiTier -Tiers $script:Tiers -TotalRamGB $null -AvailableRamGB $null
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'ram-unknown'
    }

    It 'a tier entry missing the Default flag does not explode the picker' {
        # Measured: under StrictMode -Latest an ABSENT hashtable key throws PropertyNotFoundException rather than
        # yielding $null, so any entry shaped before a field existed would take the picker down with it.
        $bare = @(@{ Id = 'nano'; Model = 'N'; ResidentGB = 2.5 }, @{ Id = 'mid'; Model = 'M'; ResidentGB = 7.0 })
        { Select-LokiTier -Tiers $bare -TotalRamGB 64 -AvailableRamGB 40 } | Should -Not -Throw
        (Select-LokiTier -Tiers $bare -TotalRamGB 64 -AvailableRamGB 40).Tier.Id | Should -Be 'mid'
    }

    Context '--model override' {
        It 'an override that fits is honoured' {
            $r = Select-LokiTier -Tiers $script:Tiers -TotalRamGB 32 -AvailableRamGB 24 -Override 'mid'
            $r.Ok | Should -BeTrue
            $r.Reason | Should -Be 'override'
            $r.Tier.Id | Should -Be 'mid'
        }

        It 'an override ABOVE the recommendation is honoured -- the ceiling only binds the automatic pick' {
            # The operator asking for more is exactly the "switch, with guidance" the ceiling is meant to allow.
            $r = Select-LokiTier -Tiers $script:Tiers -TotalRamGB 64 -AvailableRamGB 40 -Override 'max'
            $r.Ok | Should -BeTrue
            $r.Reason | Should -Be 'override'
            $r.Tier.Id | Should -Be 'max'
        }

        It 'is case-insensitive on the id' {
            (Select-LokiTier -Tiers $script:Tiers -TotalRamGB 32 -AvailableRamGB 24 -Override 'MID').Tier.Id | Should -Be 'mid'
        }

        It 'an override that is not installed -> refused, not silently downgraded' {
            $r = Select-LokiTier -Tiers @($script:Tiers | Where-Object { $_.Id -eq 'nano' }) -TotalRamGB 64 -AvailableRamGB 40 -Override 'max'
            $r.Ok | Should -BeFalse
            $r.Reason | Should -Be 'override-not-installed'
        }

        It 'BREAK-THE-GUARD: an override needing memory that is merely BUSY is refused, and says how much' {
            $r = Select-LokiTier -Tiers $script:Tiers -TotalRamGB 32 -AvailableRamGB 6 -Override 'mid'
            $r.Ok | Should -BeFalse
            $r.Reason | Should -Be 'override-needs-free'
            $r.NeedFreeGB | Should -Be 2.5      # 7.0 + 1.5 - 6
            $r.Tier.Id | Should -Be 'mid'       # still reported, so the message can name it
        }

        It 'BREAK-THE-GUARD: an override too big for the MACHINE is a different refusal from a busy one' {
            # The distinction is the point: one says "close something", the other says "never here". Collapsing them
            # sends the operator to free memory that can never be enough.
            $r = Select-LokiTier -Tiers $script:Tiers -TotalRamGB 32 -AvailableRamGB 30 -Override 'max'
            $r.Ok | Should -BeFalse
            $r.Reason | Should -Be 'override-too-big'
            $r.Tier.Id | Should -Be 'max'
        }

        It '-Force runs a busy-blocked tier anyway and labels it forced (never silently)' {
            $r = Select-LokiTier -Tiers $script:Tiers -TotalRamGB 32 -AvailableRamGB 6 -Override 'mid' -Force
            $r.Ok | Should -BeTrue
            $r.Reason | Should -Be 'forced'
            $r.Tier.Id | Should -Be 'mid'
        }

        It '-Force also runs a tier that is too big for the machine (the operator takes the risk knowingly)' {
            $r = Select-LokiTier -Tiers $script:Tiers -TotalRamGB 32 -AvailableRamGB 30 -Override 'max' -Force
            $r.Ok | Should -BeTrue
            $r.Reason | Should -Be 'forced'
        }

        It '-Force also overrides an unknown-RAM host' {
            $r = Select-LokiTier -Tiers $script:Tiers -TotalRamGB $null -AvailableRamGB $null -Override 'nano' -Force
            $r.Ok | Should -BeTrue
            $r.Reason | Should -Be 'forced'
        }

        It '-Force WITHOUT an override does not bypass the rule (force is per-tier, not a global off-switch)' {
            $r = Select-LokiTier -Tiers $script:Tiers -TotalRamGB 8 -AvailableRamGB 3 -Force
            $r.Ok | Should -BeFalse
            $r.Reason | Should -Be 'nothing-fits'
        }
    }
}

Describe 'Get-LokiInstalledTiers' {

    It 'reports only tiers whose file is present at the pinned size' {
        $d = New-HwCaseDir
        [System.IO.File]::WriteAllBytes((Join-Path $d 'n.gguf'), (New-Object byte[] 1000))   # right size
        [System.IO.File]::WriteAllBytes((Join-Path $d 's.gguf'), (New-Object byte[] 5))      # truncated download
        $r = Get-LokiInstalledTiers -Models $script:Tiers -ModelsDir $d
        @($r).Count | Should -Be 1
        @($r)[0].Id | Should -Be 'nano'
    }

    It 'an empty models dir -> nothing installed' {
        $r = Get-LokiInstalledTiers -Models $script:Tiers -ModelsDir (New-HwCaseDir)
        @($r).Count | Should -Be 0
    }

    It 'a single installed tier is still an array (regression: .Count must not throw under StrictMode)' {
        $d = New-HwCaseDir
        [System.IO.File]::WriteAllBytes((Join-Path $d 'n.gguf'), (New-Object byte[] 1000))
        $r = Get-LokiInstalledTiers -Models $script:Tiers -ModelsDir $d
        { $r.Count } | Should -Not -Throw
        $r.Count | Should -Be 1
    }
}

Describe 'Get-LokiHardwareProfile (impure; probes this machine)' {

    It 'never throws and returns every documented field' {
        { Get-LokiHardwareProfile } | Should -Not -Throw
        $p = Get-LokiHardwareProfile
        foreach ($k in @('TotalRamGB', 'AvailableRamGB', 'CpuName', 'CpuCores', 'Is64BitOs')) {
            $p.ContainsKey($k) | Should -BeTrue
        }
    }

    It 'reports plausible RAM in GB, not the raw KB CIM hands back' {
        # The bug this guards against is a factor of a million: TotalVisibleMemorySize is in KILOBYTES.
        # Any real Windows host running this suite is between 1 GB and 4 TB.
        $p = Get-LokiHardwareProfile
        $p.TotalRamGB | Should -BeGreaterThan 1
        $p.TotalRamGB | Should -BeLessThan 4096
        $p.AvailableRamGB | Should -BeLessOrEqual $p.TotalRamGB
    }

    It 'a real reading feeds a real verdict (probe and rule actually fit together)' {
        $p = Get-LokiHardwareProfile
        $limit = Get-LokiModelRamLimit -TotalRamGB $p.TotalRamGB -AvailableRamGB $p.AvailableRamGB
        $limit.Ok | Should -BeTrue
        $limit.CapGB | Should -BeGreaterThan 0
        $fit = Get-LokiTierFit -TotalRamGB $p.TotalRamGB -AvailableRamGB $p.AvailableRamGB -ResidentGB 2.5
        @('fits', 'fits-if-freed', 'too-big') | Should -Contain $fit.Verdict
    }
}

Describe 'Get-LokiMemoryConsumer (impure; probes this machine)' {

    It 'never throws and reports the documented fields' {
        { Get-LokiMemoryConsumer } | Should -Not -Throw
        $c = Get-LokiMemoryConsumer -Top 3
        @($c).Count | Should -BeGreaterThan 0
        foreach ($row in @($c)) {
            foreach ($k in @('Name', 'ProcessCount', 'ResidentGB')) { $row.ContainsKey($k) | Should -BeTrue }
        }
    }

    It 'honours -Top and reports biggest first' {
        $c = Get-LokiMemoryConsumer -Top 3
        @($c).Count | Should -BeLessOrEqual 3
        $gb = @(@($c) | ForEach-Object { [double]$_.ResidentGB })
        for ($i = 1; $i -lt $gb.Count; $i++) { $gb[$i] | Should -BeLessOrEqual $gb[$i - 1] }
    }

    It 'groups an app by name rather than listing every process' {
        # The operator's browser is ~21 processes; a per-process list would bury the answer it exists to give.
        # Summed by hand on purpose: Measure-Object -Property cannot see hashtable KEYS, only object properties.
        $c = Get-LokiMemoryConsumer -Top 10
        @(@($c) | ForEach-Object { [string]$_.Name } | Sort-Object -Unique).Count | Should -Be @($c).Count
        $procs = 0
        foreach ($row in @($c)) { $procs += [int]$row.ProcessCount }
        $procs | Should -BeGreaterOrEqual @($c).Count
    }

    It 'never names kernel bookkeeping as an app holding memory' {
        # "Memory Compression" holds OTHER processes' pages in compressed form -- listing it double-counts what is
        # already attributed to the apps, and "close Memory Compression" is not advice anyone can take.
        $c = Get-LokiMemoryConsumer -Top 20
        foreach ($row in @($c)) {
            @('Idle', 'System', 'Registry', 'Memory Compression', 'Secure System') | Should -Not -Contain $row.Name
        }
    }

    It 'reports plausible resident sizes in GB, not raw bytes' {
        $c = Get-LokiMemoryConsumer -Top 1
        @($c)[0].ResidentGB | Should -BeGreaterThan 0
        @($c)[0].ResidentGB | Should -BeLessThan 4096
    }
}

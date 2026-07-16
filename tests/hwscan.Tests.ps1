# tests/hwscan.Tests.ps1 -- hardware scan + tier selection (src/lib/hwscan.ps1, DESIGN.md section 3.2, ADR-0013).
# CLAUDE.md section 6 requires tier selection to be table-tested, so the two pure functions are tested as a truth
# table straight off the design rule: reserve = max(4 GB, 25% of total); budget = available - reserve; largest tier
# whose resident <= budget; budget < 2 GB -> no LLM.
# Get-LokiHardwareProfile is the only impure one; it is tested for the properties that matter (never throws, never
# invents a number, reports GB not the raw KB CIM hands back) rather than for this machine's values.
# The command wiring lives in tests/hwscan-command.Tests.ps1 (same split as auth / auth-command).
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\hwscan.ps1"

    # A miniature catalogue in the shape lib/models.ps1 produces -- residents chosen to make the boundaries explicit
    # rather than to mirror the real manifest (that one is covered by tests/models.Tests.ps1).
    $script:Tiers = @(
        @{ Id = 'nano'; Model = 'N'; ResidentGB = 2.5; FileName = 'n.gguf'; SizeBytes = 1000 }
        @{ Id = 'small'; Model = 'S'; ResidentGB = 4.5; FileName = 's.gguf'; SizeBytes = 2000 }
        @{ Id = 'mid'; Model = 'M'; ResidentGB = 7.0; FileName = 'm.gguf'; SizeBytes = 3000 }
        @{ Id = 'max'; Model = 'X'; ResidentGB = 24.0; FileName = 'x.gguf'; SizeBytes = 4000 }
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

Describe 'Get-LokiTierBudget (pure; the DESIGN.md 3.2 formula as a truth table)' {

    It 'total=<total> avail=<avail> -> reserve=<reserve> budget=<budget> ok=<ok>' -ForEach @(
        # Small hosts: the 4 GB floor dominates the 25% rule.
        @{ total = 8; avail = 7; reserve = 4.0; budget = 3.0; ok = $true }
        @{ total = 16; avail = 12; reserve = 4.0; budget = 8.0; ok = $true }
        # Big hosts: 25% dominates the floor -- a 64 GB box keeps 16 GB, not 4.
        @{ total = 64; avail = 60; reserve = 16.0; budget = 44.0; ok = $true }
        @{ total = 32; avail = 30; reserve = 8.0; budget = 22.0; ok = $true }
        # AVAILABLE is what counts: the same 32 GB box, but already thrashing -> no model.
        @{ total = 32; avail = 9; reserve = 8.0; budget = 1.0; ok = $false }
        # Budget never goes negative.
        @{ total = 8; avail = 1; reserve = 4.0; budget = 0.0; ok = $false }
        # Exactly at the 2 GB floor is still usable; just under it is not.
        @{ total = 8; avail = 6; reserve = 4.0; budget = 2.0; ok = $true }
        @{ total = 8; avail = 5.9; reserve = 4.0; budget = 1.9; ok = $false }
    ) {
        $r = Get-LokiTierBudget -TotalRamGB $total -AvailableRamGB $avail
        $r.ReserveGB | Should -Be $reserve
        $r.BudgetGB | Should -Be $budget
        $r.Ok | Should -Be $ok
    }

    It 'refuses to invent a budget when RAM is unknown or implausible: <case>' -ForEach @(
        @{ case = 'total null'; total = $null; avail = 8 }
        @{ case = 'avail null'; total = 16; avail = $null }
        @{ case = 'both null'; total = $null; avail = $null }
        @{ case = 'total zero'; total = 0; avail = 8 }
        @{ case = 'negative avail'; total = 16; avail = -1 }
        # A probe reporting more free than exists is the one inconsistency that breaks the safety property:
        # 4 GB total / 64 GB available would budget 60 GB and pick a 24 GB model for a 4 GB box.
        @{ case = 'available exceeds total'; total = 4; avail = 64 }
    ) {
        $r = Get-LokiTierBudget -TotalRamGB $total -AvailableRamGB $avail
        $r.Ok | Should -BeFalse
        $r.BudgetGB | Should -BeNullOrEmpty
    }
}

Describe 'Select-LokiTier (pure; table-tested)' {

    It 'budget=<budget> -> picks <expect>' -ForEach @(
        @{ budget = 30.0; expect = 'max' }      # everything fits -> strongest
        @{ budget = 24.0; expect = 'max' }      # resident == budget still fits
        @{ budget = 23.9; expect = 'mid' }      # one notch under -> next one down
        @{ budget = 7.0; expect = 'mid' }
        @{ budget = 6.9; expect = 'small' }
        @{ budget = 2.5; expect = 'nano' }
    ) {
        $r = Select-LokiTier -Tiers $script:Tiers -BudgetGB $budget
        $r.Ok | Should -BeTrue
        $r.Reason | Should -Be 'selected'
        $r.Tier.Id | Should -Be $expect
    }

    It 'a budget below every tier -> nothing-fits' {
        $r = Select-LokiTier -Tiers $script:Tiers -BudgetGB 2.4
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'nothing-fits'
    }

    It 'nothing installed -> no-tiers-installed (never recommends a model that is not on the stick)' {
        $r = Select-LokiTier -Tiers @() -BudgetGB 64
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'no-tiers-installed'
    }

    It 'picks only from what is INSTALLED, not from the catalogue' {
        # The box could run 'max', but only 'small' is on the stick.
        $r = Select-LokiTier -Tiers @($script:Tiers | Where-Object { $_.Id -eq 'small' }) -BudgetGB 64
        $r.Ok | Should -BeTrue
        $r.Tier.Id | Should -Be 'small'
    }

    It 'unknown RAM -> refuses to pick rather than guessing' {
        $r = Select-LokiTier -Tiers $script:Tiers -BudgetGB $null
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'ram-unknown'
    }

    Context '--model override' {
        It 'an override that fits is honoured' {
            $r = Select-LokiTier -Tiers $script:Tiers -BudgetGB 10 -Override 'small'
            $r.Ok | Should -BeTrue
            $r.Reason | Should -Be 'override'
            $r.Tier.Id | Should -Be 'small'
        }

        It 'is case-insensitive on the id' {
            (Select-LokiTier -Tiers $script:Tiers -BudgetGB 10 -Override 'SMALL').Tier.Id | Should -Be 'small'
        }

        It 'an override that is not installed -> refused, not silently downgraded' {
            $r = Select-LokiTier -Tiers @($script:Tiers | Where-Object { $_.Id -eq 'nano' }) -BudgetGB 64 -Override 'max'
            $r.Ok | Should -BeFalse
            $r.Reason | Should -Be 'override-not-installed'
        }

        It 'BREAK-THE-GUARD: an override that does NOT fit is refused without -Force' {
            $r = Select-LokiTier -Tiers $script:Tiers -BudgetGB 5 -Override 'max'
            $r.Ok | Should -BeFalse
            $r.Reason | Should -Be 'override-too-large'
            $r.Tier.Id | Should -Be 'max'   # still reported, so the message can say by how much
        }

        It '-Force runs it anyway and labels it forced (never silently)' {
            $r = Select-LokiTier -Tiers $script:Tiers -BudgetGB 5 -Override 'max' -Force
            $r.Ok | Should -BeTrue
            $r.Reason | Should -Be 'forced'
            $r.Tier.Id | Should -Be 'max'
        }

        It '-Force also overrides an unknown-RAM host (the operator takes the risk knowingly)' {
            $r = Select-LokiTier -Tiers $script:Tiers -BudgetGB $null -Override 'nano' -Force
            $r.Ok | Should -BeTrue
            $r.Reason | Should -Be 'forced'
        }

        It '-Force WITHOUT an override does not bypass the budget (force is per-tier, not a global off-switch)' {
            $r = Select-LokiTier -Tiers $script:Tiers -BudgetGB 2.4 -Force
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

    It 'a real reading feeds a real budget (probe and rule actually fit together)' {
        $p = Get-LokiHardwareProfile
        $b = Get-LokiTierBudget -TotalRamGB $p.TotalRamGB -AvailableRamGB $p.AvailableRamGB
        $b.ReserveGB | Should -BeGreaterOrEqual 4.0
        $b.BudgetGB | Should -BeGreaterOrEqual 0
    }
}

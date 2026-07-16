# tests/hwscan-command.Tests.ps1 -- Command `loki hwscan`: metadata, registry, arg parsing, exit codes (CLAUDE.md 5/6).
# A lib and a command share the name, so the command tests live here and the lib tests in tests/hwscan.Tests.ps1 --
# same split as auth / auth-command.
# The hardware probe is Mocked: these tests pin the WIRING (profile -> budget -> installed -> selection -> exit code)
# deterministically, on any machine, including a CI runner whose real RAM would otherwise decide the outcome.
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\i18n.ps1"
    . "$PSScriptRoot\..\src\lib\ui.ps1"
    . "$PSScriptRoot\..\src\lib\exitcodes.ps1"
    . "$PSScriptRoot\..\src\lib\models.ps1"
    . "$PSScriptRoot\..\src\lib\hwscan.ps1"
    . "$PSScriptRoot\..\src\lib\registry.ps1"
    . "$PSScriptRoot\..\src\commands\hwscan.ps1"
    Initialize-LokiUi -NoColor
    $script:SrcRoot = (Resolve-Path "$PSScriptRoot\..\src").Path
    Initialize-LokiI18n -AppRoot $script:SrcRoot -Locale 'en' | Out-Null

    function global:New-TestHwContext {
        param([string[]]$CmdArgs = @())
        return @{ AppRoot = $script:SrcRoot; Version = 'test'; Args = $CmdArgs; Flags = @{}; Registry = @() }
    }

    function global:Invoke-HwscanCommand {
        param([Parameter(Mandatory = $true)][hashtable]$Context)
        $swErr = New-Object System.IO.StringWriter
        $origErr = [Console]::Error
        [Console]::SetError($swErr)
        try { $raw = @(Invoke-LokiCmd_hwscan $Context 6>&1) }
        finally { [Console]::SetError($origErr) }
        $code = [int]($raw | Select-Object -Last 1)
        $lineCount = [Math]::Max(0, $raw.Count - 1)
        $stdText = (@($raw | Select-Object -First $lineCount) | Out-String)
        $errText = $swErr.ToString()
        [pscustomobject]@{ Code = $code; Text = $stdText; ErrText = $errText; AllText = ($stdText + $errText) }
    }
}

AfterAll {
    Remove-Item Function:\New-TestHwContext -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-HwscanCommand -ErrorAction SilentlyContinue
}

Describe 'Command hwscan' {

    BeforeAll {
        # A big, healthy host by default. Every test that cares overrides this.
        # CpuCores is deliberately 12, NOT 16: with 16 the CPU line rendered "(16 threads)" and a '*16*' assertion on
        # the RESERVE (also 16 on this host) passed against the CPU line instead -- the reserve could be deleted from
        # the report entirely and the suite stayed green. Found by adversarial review; keep these values distinct.
        Mock Get-LokiHardwareProfile { @{ TotalRamGB = 64.0; AvailableRamGB = 60.0; CpuName = 'Test CPU'; CpuCores = 12; Is64BitOs = $true } }
        Mock Get-LokiInstalledTiers { , @(
                @{ Id = 'nano'; Model = 'Qwen3-1.7B'; ResidentGB = 2.5; FileName = 'n.gguf'; SizeBytes = 1 }
                @{ Id = 'mid'; Model = 'Qwen3-8B'; ResidentGB = 7.0; FileName = 'm.gguf'; SizeBytes = 1 }
            ) }
    }

    Context 'metadata & registry' {
        It 'metadata is complete (Name == file name, Group Health)' {
            $m = Get-LokiCmdMeta_hwscan
            $m.Name | Should -Be 'hwscan'
            $m.Group | Should -Be 'Health'
            $m.Summary | Should -Not -BeNullOrEmpty
            $m.Usage | Should -Not -BeNullOrEmpty
        }
        It 'is consistently registered (meta + handler, ADR-0002)' {
            $entry = Get-LokiCommandRegistry | Where-Object { $_.Name -eq 'hwscan' } | Select-Object -First 1
            $entry | Should -Not -BeNullOrEmpty
            $entry.Handler | Should -Be 'Invoke-LokiCmd_hwscan'
        }
    }

    Context 'reporting' {
        It 'a healthy host -> Ok, and it names the tier it would run' {
            $r = Invoke-HwscanCommand -Context (New-TestHwContext)
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            $r.AllText | Should -BeLike '*Qwen3-8B*'      # strongest that fits, not just any
        }

        It 'shows the budget AND the reserve, so the number is explainable rather than magic' {
            # Asserts the RENDERED line, not two loose numbers: '*16*' alone used to be satisfied by the CPU mock's
            # "(16 threads)" and proved nothing about the reserve (adversarial review, proven by mutation).
            $r = Invoke-HwscanCommand -Context (New-TestHwContext)
            $r.AllText | Should -BeLike '*44 GB for a model (16 GB stays reserved*'   # 60 available - 25% of 64
        }

        It 'writes NOTHING -- measured, not asserted: it is a read-only report' {
            # The command's whole contract is "check before you start anything", so prove nothing under AppRoot
            # changed rather than mocking a writer and calling that proof.
            $before = @(Get-ChildItem -LiteralPath $script:SrcRoot -Recurse -File -Force | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }) | Sort-Object
            $r = Invoke-HwscanCommand -Context (New-TestHwContext)
            $after = @(Get-ChildItem -LiteralPath $script:SrcRoot -Recurse -File -Force | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }) | Sort-Object
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            (Compare-Object -ReferenceObject $before -DifferenceObject $after) | Should -BeNullOrEmpty
        }
    }

    Context 'exit codes' {
        It 'a thrashing host -> OfflineEngineMissing with a reason, not a crash' {
            Mock Get-LokiHardwareProfile { @{ TotalRamGB = 8.0; AvailableRamGB = 4.5; CpuName = 'Small'; CpuCores = 2; Is64BitOs = $true } }
            $r = Invoke-HwscanCommand -Context (New-TestHwContext)
            $r.Code | Should -Be (Get-LokiExitCode 'OfflineEngineMissing')
        }

        It 'REGRESSION: below the 2 GB floor it names raw collection, not the impossible "download a smaller tier"' {
            # DESIGN.md 3.2 requires the floor to give a STATED REASON. The budget was computed and then discarded --
            # Ok/Reason were never read -- so the operator was told to fetch a smaller tier, which cannot help: below
            # the floor no tier applies at all. Found by adversarial review; the floor was effectively dead code.
            Mock Get-LokiHardwareProfile { @{ TotalRamGB = 32.0; AvailableRamGB = 9.0; CpuName = 'Busy'; CpuCores = 8; Is64BitOs = $true } }
            $r = Invoke-HwscanCommand -Context (New-TestHwContext)
            $r.Code | Should -Be (Get-LokiExitCode 'OfflineEngineMissing')
            $r.AllText | Should -BeLike '*raw diagnostic dump*'
            $r.AllText | Should -Not -BeLike '*add a smaller tier*'
        }

        It 'BREAK-THE-GUARD: available > total (a lying probe) is refused, not budgeted' {
            # 4 GB total / 64 GB available would otherwise budget 60 GB and pick a 24 GB model for a 4 GB box.
            Mock Get-LokiHardwareProfile { @{ TotalRamGB = 4.0; AvailableRamGB = 64.0; CpuName = 'Liar'; CpuCores = 2; Is64BitOs = $true } }
            $r = Invoke-HwscanCommand -Context (New-TestHwContext)
            $r.Code | Should -Be (Get-LokiExitCode 'OfflineEngineMissing')
            $r.AllText | Should -Not -BeLike '*Would run*'
        }

        It 'nothing on the stick -> OfflineEngineMissing pointing at loki setup' {
            Mock Get-LokiInstalledTiers { , @() }
            $r = Invoke-HwscanCommand -Context (New-TestHwContext)
            $r.Code | Should -Be (Get-LokiExitCode 'OfflineEngineMissing')
            $r.AllText | Should -BeLike '*loki setup*'
        }

        It 'BREAK-THE-GUARD: unreadable RAM -> refuses to pick, never guesses' {
            Mock Get-LokiHardwareProfile { @{ TotalRamGB = $null; AvailableRamGB = $null; CpuName = $null; CpuCores = $null; Is64BitOs = $true } }
            $r = Invoke-HwscanCommand -Context (New-TestHwContext)
            $r.Code | Should -Be (Get-LokiExitCode 'OfflineEngineMissing')
            $r.AllText | Should -Not -BeLike '*Would run*'
        }
    }

    Context '--model / --force' {
        It '--model picks that tier when it fits' {
            $r = Invoke-HwscanCommand -Context (New-TestHwContext -CmdArgs @('--model', 'nano'))
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            $r.AllText | Should -BeLike '*Qwen3-1.7B*'
        }

        It 'the --model=nano form works too (not just the space-separated one)' {
            $r = Invoke-HwscanCommand -Context (New-TestHwContext -CmdArgs @('--model=nano'))
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
        }

        It 'BREAK-THE-GUARD: a tier that does not fit is refused -> OfflineEngineMissing' {
            Mock Get-LokiHardwareProfile { @{ TotalRamGB = 8.0; AvailableRamGB = 7.0; CpuName = 'Small'; CpuCores = 2; Is64BitOs = $true } }
            $r = Invoke-HwscanCommand -Context (New-TestHwContext -CmdArgs @('--model', 'mid'))
            $r.Code | Should -Be (Get-LokiExitCode 'OfflineEngineMissing')
        }

        It '--force runs it anyway and WARNS -- the swap risk is never silent' {
            Mock Get-LokiHardwareProfile { @{ TotalRamGB = 8.0; AvailableRamGB = 7.0; CpuName = 'Small'; CpuCores = 2; Is64BitOs = $true } }
            $r = Invoke-HwscanCommand -Context (New-TestHwContext -CmdArgs @('--model', 'mid', '--force'))
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            $r.AllText | Should -BeLike '*swapping*'
        }

        It 'an unknown tier id -> OfflineEngineMissing naming the id' {
            $r = Invoke-HwscanCommand -Context (New-TestHwContext -CmdArgs @('--model', 'banana'))
            $r.Code | Should -Be (Get-LokiExitCode 'OfflineEngineMissing')
            $r.AllText | Should -BeLike '*banana*'
        }

        It 'REGRESSION: --force on an unreadable-RAM host does NOT print a blank where a number belongs' {
            # It used to say "needs ~24 GB but only  GB is free" -- a definite claim about memory, rendered blank, on
            # the exact host where we refused to determine it. Found by adversarial review; this path had no test.
            Mock Get-LokiHardwareProfile { @{ TotalRamGB = $null; AvailableRamGB = $null; CpuName = $null; CpuCores = $null; Is64BitOs = $true } }
            $r = Invoke-HwscanCommand -Context (New-TestHwContext -CmdArgs @('--model', 'mid', '--force'))
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            $r.AllText | Should -BeLike '*risk cannot be judged*'
            $r.AllText | Should -Not -BeLike '*is free*'
        }

        It 'REGRESSION: --force without --model -> Usage, never a silently ignored flag' {
            $r = Invoke-HwscanCommand -Context (New-TestHwContext -CmdArgs @('--force'))
            $r.Code | Should -Be (Get-LokiExitCode 'Usage')
        }

        It 'an unknown argument -> Usage (a typo must not read as a silent default)' {
            $r = Invoke-HwscanCommand -Context (New-TestHwContext -CmdArgs @('--nope'))
            $r.Code | Should -Be (Get-LokiExitCode 'Usage')
        }

        It '--model without a value -> Usage, not a null tier' {
            $r = Invoke-HwscanCommand -Context (New-TestHwContext -CmdArgs @('--model'))
            $r.Code | Should -Be (Get-LokiExitCode 'Usage')
        }
    }
}

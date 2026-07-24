# tests/hwscan-command.Tests.ps1 -- Command `loki hwscan`: metadata, registry, arg parsing, exit codes (CLAUDE.md 5/6).
# A lib and a command share the name, so the command tests live here and the lib tests in tests/hwscan.Tests.ps1 --
# same split as auth / auth-command.
# The hardware probe is Mocked: these tests pin the WIRING (profile -> limits -> installed -> selection -> exit code)
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
        # a memory figure passed against the CPU line instead -- the figure could be deleted from the report entirely
        # and the suite stayed green. Found by adversarial review; keep these values distinct.
        Mock Get-LokiHardwareProfile { @{ TotalRamGB = 64.0; AvailableRamGB = 60.0; CpuName = 'Test CPU'; CpuCores = 12; Is64BitOs = $true } }
        # Mirrors the real manifest's shape, Default flag included -- the picker's whole rule turns on it (ADR-0017).
        Mock Get-LokiInstalledTiers { , @(
                @{ Id = 'nano'; Model = 'Qwen3-1.7B'; ResidentGB = 2.5; FileName = 'n.gguf'; SizeBytes = 1; Default = $false }
                @{ Id = 'small'; Model = 'Qwen3-4B'; ResidentGB = 4.5; FileName = 's.gguf'; SizeBytes = 1; Default = $true }
                @{ Id = 'mid'; Model = 'Qwen3-8B'; ResidentGB = 7.0; FileName = 'm.gguf'; SizeBytes = 1; Default = $false }
            ) }
    }

    It 'an OUTDATED/invalid model manifest -> the rebuild hint + OfflineEngineMissing, and tier selection NEVER runs (fail-closed, #87)' {
        # A stick older than the code -> the model manifest is rejected fail-closed. hwscan must show the operator the
        # "rebuild the stick" hint and stop, not surface a raw validation throw and not proceed to tier selection.
        Mock Get-LokiModelManifest { throw "Model 'x': a huggingface.co Url must pin an immutable 40-hex revision, not a moving ref like /resolve/main/." }
        Mock Get-LokiInstalledTiers { throw 'tier selection must NOT run on an unusable manifest' }
        $r = Invoke-HwscanCommand -Context (New-TestHwContext)
        $r.Code    | Should -Be (Get-LokiExitCode 'OfflineEngineMissing')
        $r.AllText | Should -Match '(?i)rebuild'
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
            $r.AllText | Should -BeLike '*Qwen3-4B*'
        }

        It 'BREAK-THE-GUARD: a bigger tier that fits is offered but NOT auto-selected (ADR-0017)' {
            # On a 64 GB host with 60 free, mid clears both guards. Picking it would be the old "biggest that fits"
            # rule, which hands a big machine a model that runs at a crawl on CPU. It must be listed as fitting and
            # still not be the answer.
            $r = Invoke-HwscanCommand -Context (New-TestHwContext)
            $r.AllText | Should -BeLike '*Would run: small*'
            $r.AllText | Should -Not -BeLike '*Would run: mid*'
            $r.AllText | Should -BeLike '*mid*fits now*'      # offered, so the operator can choose it
        }

        It 'shows BOTH ceilings, so the verdict is explainable rather than magic' {
            # Asserts the RENDERED line, not two loose numbers: a bare '*38*' would be satisfied by any other figure
            # in the report and prove nothing (adversarial review, proven by mutation).
            $r = Invoke-HwscanCommand -Context (New-TestHwContext)
            $r.AllText | Should -BeLike '*up to 38.4 GB on this machine; 58.5 GB is free enough right now*'
        }

        It 'each tier carries its own verdict, not just the winner' {
            $r = Invoke-HwscanCommand -Context (New-TestHwContext)
            $r.AllText | Should -BeLike '*nano*fits now*'
            $r.AllText | Should -BeLike '*small*fits now*'
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

    Context 'guidance (ADR-0017: a refusal that names what to do about it)' {
        It 'a tier blocked only by BUSY memory says how much to free AND who is holding it' {
            # This is the whole point of the loosened rule: "no" was never the useful answer. 16 GB total -> cap 9.6,
            # so mid (7.0) is permitted here; 5 GB available -> usable 3.5, so it needs 3.5 GB more free.
            Mock Get-LokiHardwareProfile { @{ TotalRamGB = 16.0; AvailableRamGB = 5.0; CpuName = 'Busy'; CpuCores = 8; Is64BitOs = $true } }
            $r = Invoke-HwscanCommand -Context (New-TestHwContext)
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')          # nano still fits, so this is an answer, not a failure
            $r.AllText | Should -BeLike '*Would run: nano*'
            $r.AllText | Should -BeLike '*mid*needs 3.5 GB more free*'
            $r.AllText | Should -BeLike '*Biggest memory holders right now*'
        }

        It 'BREAK-THE-GUARD: no guidance block on a host where everything already fits (it would be noise)' {
            $r = Invoke-HwscanCommand -Context (New-TestHwContext)
            $r.AllText | Should -Not -BeLike '*Biggest memory holders*'
        }

        It 'REGRESSION: --model gets no unasked-for guidance about a DIFFERENT tier' {
            # Found by running the real report, not by a unit test: `--model max-ceiling` answered "freeing memory
            # will not help" and then appended "Free 3.55 GB to unlock large-longctx". Both sentences were true, about
            # different tiers, and together they read as a contradiction. The operator who names a tier has chosen.
            Mock Get-LokiHardwareProfile { @{ TotalRamGB = 16.0; AvailableRamGB = 5.0; CpuName = 'Busy'; CpuCores = 8; Is64BitOs = $true } }
            $r = Invoke-HwscanCommand -Context (New-TestHwContext -CmdArgs @('--model', 'nano'))
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            $r.AllText | Should -Not -BeLike '*Biggest memory holders*'
            $r.AllText | Should -Not -BeLike '*to unlock*'
        }

        It 'names the CHEAPEST tier to unlock when several are within reach' {
            # 16 GB total -> cap 9.6; 5 GB available -> usable 3.5. Both small (4.5) and mid (7.0) are blocked only by
            # busy memory; the hint must name the one that is 1 GB away, not the one that is 3.5 GB away.
            Mock Get-LokiHardwareProfile { @{ TotalRamGB = 16.0; AvailableRamGB = 5.0; CpuName = 'Busy'; CpuCores = 8; Is64BitOs = $true } }
            $r = Invoke-HwscanCommand -Context (New-TestHwContext)
            $r.AllText | Should -BeLike '*Free 1 GB to unlock "small"*'
            $r.AllText | Should -Not -BeLike '*to unlock "mid"*'
        }

        It 'a tier too big for the MACHINE is never presented as "free some memory"' {
            # 8 GB total -> cap 4.8, so mid (7.0) can never run here. Telling the operator to close programs would
            # send them after memory that could never be enough.
            Mock Get-LokiHardwareProfile { @{ TotalRamGB = 8.0; AvailableRamGB = 7.0; CpuName = 'Small'; CpuCores = 2; Is64BitOs = $true } }
            $r = Invoke-HwscanCommand -Context (New-TestHwContext)
            $r.AllText | Should -BeLike '*mid*too big for this machine*'
            $r.AllText | Should -Not -BeLike '*mid*needs*more free*'
        }
    }

    Context 'exit codes' {
        It 'a genuinely thrashing host -> OfflineEngineMissing with a reason, not a crash' {
            # 8 GB total, 2.5 free -> usable 1.0; even nano needs freeing, and mid is over the cap. Nothing fits NOW.
            Mock Get-LokiHardwareProfile { @{ TotalRamGB = 8.0; AvailableRamGB = 2.5; CpuName = 'Small'; CpuCores = 2; Is64BitOs = $true } }
            $r = Invoke-HwscanCommand -Context (New-TestHwContext)
            $r.Code | Should -Be (Get-LokiExitCode 'OfflineEngineMissing')
            $r.AllText | Should -BeLike '*freeing memory would change that*'
        }

        It 'REGRESSION: a host too small for ANY model names raw collection, not the impossible "download a smaller tier"' {
            # DESIGN.md 3.2 requires this to give a STATED REASON. The old rule ASSERTED that below a fixed budget
            # floor nothing could help; this CHECKS it against the catalogue, because "fetch a smaller tier" is
            # either the right advice or advice that cannot possibly work.
            # 4 GB total -> cap 2.4 GB: even the catalogue's smallest tier (2.5 GB) is over it, permanently.
            Mock Get-LokiHardwareProfile { @{ TotalRamGB = 4.0; AvailableRamGB = 3.5; CpuName = 'Tiny'; CpuCores = 2; Is64BitOs = $true } }
            $r = Invoke-HwscanCommand -Context (New-TestHwContext)
            $r.Code | Should -Be (Get-LokiExitCode 'OfflineEngineMissing')
            $r.AllText | Should -BeLike '*raw diagnostic dump*'
            $r.AllText | Should -Not -BeLike '*loki setup*'
        }

        It 'a stick missing the tier this host COULD run is told to fetch it, not to give up' {
            # The other side of the same coin, and the reason the check above must be a check and not an assertion:
            # only 'mid' is on the stick and it is over this box's cap -- but the catalogue's nano would run here.
            Mock Get-LokiInstalledTiers { , @(@{ Id = 'mid'; Model = 'Qwen3-8B'; ResidentGB = 7.0; FileName = 'm.gguf'; SizeBytes = 1; Default = $false }) }
            Mock Get-LokiHardwareProfile { @{ TotalRamGB = 8.0; AvailableRamGB = 7.0; CpuName = 'Small'; CpuCores = 2; Is64BitOs = $true } }
            $r = Invoke-HwscanCommand -Context (New-TestHwContext)
            $r.Code | Should -Be (Get-LokiExitCode 'OfflineEngineMissing')
            $r.AllText | Should -BeLike '*loki setup*'
            $r.AllText | Should -Not -BeLike '*raw diagnostic dump*'
        }

        It 'BREAK-THE-GUARD: available > total (a lying probe) is refused, not budgeted' {
            # 4 GB total / 64 GB available would otherwise clear a 24 GB model for a 4 GB box.
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

        It '--model reaches ABOVE the recommendation -- the ceiling only binds the automatic pick' {
            # The "switch, with guidance" half of ADR-0017: a ceiling the operator cannot cross is not a default.
            $r = Invoke-HwscanCommand -Context (New-TestHwContext -CmdArgs @('--model', 'mid'))
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            $r.AllText | Should -BeLike '*Would run: mid*'
        }

        It 'the --model=nano form works too (not just the space-separated one)' {
            $r = Invoke-HwscanCommand -Context (New-TestHwContext -CmdArgs @('--model=nano'))
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
        }

        It 'BREAK-THE-GUARD: a tier too big for the machine is refused -> OfflineEngineMissing' {
            Mock Get-LokiHardwareProfile { @{ TotalRamGB = 8.0; AvailableRamGB = 7.0; CpuName = 'Small'; CpuCores = 2; Is64BitOs = $true } }
            $r = Invoke-HwscanCommand -Context (New-TestHwContext -CmdArgs @('--model', 'mid'))
            $r.Code | Should -Be (Get-LokiExitCode 'OfflineEngineMissing')
            $r.AllText | Should -BeLike '*Freeing memory will not help*'
        }

        It 'BREAK-THE-GUARD: a tier blocked only by busy memory gets the OTHER refusal, with the number' {
            Mock Get-LokiHardwareProfile { @{ TotalRamGB = 16.0; AvailableRamGB = 5.0; CpuName = 'Busy'; CpuCores = 8; Is64BitOs = $true } }
            $r = Invoke-HwscanCommand -Context (New-TestHwContext -CmdArgs @('--model', 'mid'))
            $r.Code | Should -Be (Get-LokiExitCode 'OfflineEngineMissing')
            $r.AllText | Should -BeLike '*3.5 GB more free memory*'
            $r.AllText | Should -Not -BeLike '*Freeing memory will not help*'
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
            $r.AllText | Should -Not -BeLike '*is free enough*'
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

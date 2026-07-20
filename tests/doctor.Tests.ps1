# tests/doctor.Tests.ps1 -- Command `loki doctor`: metadata, registry, rendering, exit code (CLAUDE.md section 5/6).
#
# The two IMPURE detection functions (Get-LokiHostPosture / Get-LokiVolumePosture) are MOCKED here so the
# command tests are deterministic (live host posture varies per machine) and fast (the real Get-BitLockerVolume
# probe costs ~5s per call). The real detection functions are smoke-tested against the live host in
# tests/posture.Tests.ps1; here we test the command's wiring: config -> auth -> posture -> checks -> render -> exit.
#
# Encapsulation note (see tests\auth-command.Tests.ps1): Write-LokiWarn/Write-LokiErr write DIRECTLY via
# [Console]::Error.WriteLine (lib/ui.ps1), NOT a PowerShell stream -- so [Console]::SetError() is redirected
# to a StringWriter for real in-process interception; Write-Host/Write-LokiOk/-Line go through stream 6
# (last pipeline element = the handler's return exit code).
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\i18n.ps1"
    . "$PSScriptRoot\..\src\lib\ui.ps1"
    . "$PSScriptRoot\..\src\lib\exitcodes.ps1"
    . "$PSScriptRoot\..\src\lib\config.ps1"
    . "$PSScriptRoot\..\src\lib\auth.ps1"
    . "$PSScriptRoot\..\src\lib\posture.ps1"
    . "$PSScriptRoot\..\src\lib\env-isolate.ps1"
    . "$PSScriptRoot\..\src\lib\footprint.ps1"
    . "$PSScriptRoot\..\src\lib\registry.ps1"
    . "$PSScriptRoot\..\src\lib\download.ps1"     # --engine mode: Test-LokiFileHash, the primitive the chain rests on
    . "$PSScriptRoot\..\src\lib\engine.ps1"
    . "$PSScriptRoot\..\src\lib\models.ps1"
    . "$PSScriptRoot\..\src\lib\integrity.ps1"
    . "$PSScriptRoot\..\src\commands\doctor.ps1"
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Initialize-LokiUi -NoColor
    Initialize-LokiI18n -AppRoot (Resolve-Path "$PSScriptRoot\..\src").Path -Locale 'en' | Out-Null

    $script:RootTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("loki-doctorcmd-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:RootTmp | Out-Null

    # New, isolated temp AppRoot (with home\ subfolder, like the real stick layout) per test case.
    function global:New-TestDoctorAppRoot {
        $root = Join-Path $script:RootTmp ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'home') | Out-Null
        return $root
    }

    function global:New-TestDoctorContext {
        param([Parameter(Mandatory = $true)][string]$AppRoot, [string[]]$CmdArgs = @())
        return @{ AppRoot = $AppRoot; Version = 'test'; Args = $CmdArgs; Flags = @{}; Registry = @() }
    }

    # Builds an AppRoot laid out like a prepared stick for `doctor --engine`: real manifests, a real archive in
    # engine-offline\ with its contents expanded next to it, and a real model file at its pinned hash. Real files
    # throughout -- the thing under test IS the filesystem interaction.
    function global:New-TestEngineStick {
        param([switch]$NoEngine, [switch]$NoModel, [switch]$NoRuntime)
        $root = New-TestDoctorAppRoot
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'engine') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'models') | Out-Null

        # --- the engine archive + its expanded contents
        $engineDir = Join-Path $root 'engine-offline'
        $zipPath = Join-Path $script:RootTmp ([System.Guid]::NewGuid().ToString('N') + '.zip')
        $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
        foreach ($n in @('llama-server.exe', 'ggml-base.dll')) {
            $e = $zip.CreateEntry($n)
            $sw = New-Object System.IO.StreamWriter($e.Open())
            $sw.Write("bytes-of-$n")
            $sw.Dispose()
        }
        $zip.Dispose()
        $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not $NoEngine) {
            New-Item -ItemType Directory -Force -Path $engineDir | Out-Null
            Copy-Item -LiteralPath $zipPath -Destination (Join-Path $engineDir 'engine.zip') -Force
            foreach ($n in @('llama-server.exe', 'ggml-base.dll')) {
                [System.IO.File]::WriteAllText((Join-Path $engineDir $n), "bytes-of-$n")
            }
            # A staged MSVC runtime, so a "clean stick" is genuinely clean: without one the engine could not start
            # here and the report would (correctly) not be green. kernel32.dll is a real versioned binary present on
            # every Windows host, paired with a MinVersion of 1.0 below -- so this does not depend on whatever VC++
            # runtime the CI machine happens to have.
            if (-not $NoRuntime) {
                Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\kernel32.dll') `
                    -Destination (Join-Path $engineDir 'VCRUNTIME140.dll') -Force
            }
        }
        [System.IO.File]::WriteAllText((Join-Path $root 'engine\manifest.psd1'), @"
@{
    Engine  = @{
        Id = 'llama.cpp'; Version = 'b10038'; Platform = 'win-cpu-x64'; License = 'MIT'
        Url = 'https://example.invalid/engine.zip'; FileName = 'engine.zip'
        Sha256 = '$zipHash'; SizeBytes = $((Get-Item -LiteralPath $zipPath).Length); ServerExe = 'llama-server.exe'
    }
    Runtime = @{
        Files = @('VCRUNTIME140.dll'); MinVersion = '1.0'
        RegistryKey = 'HKLM:\SOFTWARE\Loki\DoesNotExist\Ever'
    }
}
"@, (New-Object System.Text.UTF8Encoding($false)))

        # --- one model tier, present at its pinned hash
        $modelPath = Join-Path $root 'models\nano.gguf'
        [System.IO.File]::WriteAllText($modelPath, 'model-weights')
        $modelHash = (Get-FileHash -LiteralPath $modelPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $modelSize = (Get-Item -LiteralPath $modelPath).Length
        if ($NoModel) { [System.IO.File]::Delete($modelPath) }
        [System.IO.File]::WriteAllText((Join-Path $root 'models\manifest.psd1'), @"
@{
    Models = @(
        @{
            Id = 'nano'; Model = 'Test-1.7B'; Tier = 'Nano'; License = 'Apache-2.0'
            Url = 'https://example.invalid/nano.gguf'; FileName = 'nano.gguf'
            Sha256 = '$modelHash'; SizeBytes = $modelSize; ResidentGB = 2.5; ContextTokens = 32768
            KVCache = @{ Layers = 28; KVHeads = 8; HeadDim = 128 }
            Default = `$true
        }
    )
}
"@, (New-Object System.Text.UTF8Encoding($false)))
        return $root
    }

    # Calls Invoke-LokiCmd_doctor and returns exit code, stdout text (stream 6), stderr text, and the
    # combined text (both streams -- ok lines go to stdout, warn/fail lines to stderr).
    function global:Invoke-DoctorCommand {
        param([Parameter(Mandatory = $true)][hashtable]$Context)

        $swErr = New-Object System.IO.StringWriter
        $origErr = [Console]::Error
        [Console]::SetError($swErr)
        try {
            $raw = @(Invoke-LokiCmd_doctor $Context 6>&1)
        }
        finally {
            [Console]::SetError($origErr)
        }

        $code = [int]($raw | Select-Object -Last 1)
        $lineCount = [Math]::Max(0, $raw.Count - 1)
        $lines = @($raw | Select-Object -First $lineCount)
        $stdText = ($lines | Out-String)
        $errText = $swErr.ToString()

        [pscustomobject]@{ Code = $code; Text = $stdText; ErrText = $errText; AllText = ($stdText + $errText) }
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:RootTmp) { Remove-Item -LiteralPath $script:RootTmp -Recurse -Force }
    Remove-Item Function:\New-TestDoctorAppRoot -ErrorAction SilentlyContinue
    Remove-Item Function:\New-TestDoctorContext -ErrorAction SilentlyContinue
    Remove-Item Function:\New-TestEngineStick -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-DoctorCommand -ErrorAction SilentlyContinue
}

Describe 'loki doctor --engine (ADR-0014)' {

    It 'a stick setup produced verifies clean' {
        $r = Invoke-DoctorCommand -Context (New-TestDoctorContext -AppRoot (New-TestEngineStick) -CmdArgs @('--engine'))
        $r.Code | Should -Be 0
        $r.AllText | Should -Match 'verified against the pin'
    }

    It 'no engine on the stick -> OfflineEngineMissing(5), not a generic error' {
        # ADR-0014 section 8: a fresh stick is not a broken stick. 5 says "run loki setup", which is actionable.
        $r = Invoke-DoctorCommand -Context (New-TestDoctorContext -AppRoot (New-TestEngineStick -NoEngine) -CmdArgs @('--engine'))
        $r.Code | Should -Be 5
    }

    It 'BREAK-THE-GUARD: a tampered engine file -> GeneralError(1), and it must NOT look like "not installed"' {
        # The distinction is the point: a script must be able to tell "expected on a fresh stick" (5) from
        # "the engine on this stick does not match the pin" (1). If this ever returns 5, tampering looks routine.
        $root = New-TestEngineStick
        [System.IO.File]::WriteAllText((Join-Path $root 'engine-offline\llama-server.exe'), 'EVIL')
        $r = Invoke-DoctorCommand -Context (New-TestDoctorContext -AppRoot $root -CmdArgs @('--engine'))
        $r.Code | Should -Be 1
        $r.AllText | Should -Match 'llama-server\.exe'
    }

    It 'BREAK-THE-GUARD: a planted dll the pinned build does not contain -> GeneralError(1)' {
        $root = New-TestEngineStick
        [System.IO.File]::WriteAllText((Join-Path $root 'engine-offline\ggml-cpu-haswell.dll'), 'PLANTED')
        $r = Invoke-DoctorCommand -Context (New-TestDoctorContext -AppRoot $root -CmdArgs @('--engine'))
        $r.Code | Should -Be 1
        $r.AllText | Should -Match 'ggml-cpu-haswell\.dll'
    }

    It 'BREAK-THE-GUARD: a swapped model -> GeneralError(1) and the tier is named' {
        $root = New-TestEngineStick
        [System.IO.File]::WriteAllText((Join-Path $root 'models\nano.gguf'), 'EVIL-weights')
        $r = Invoke-DoctorCommand -Context (New-TestDoctorContext -AppRoot $root -CmdArgs @('--engine'))
        $r.Code | Should -Be 1
        $r.AllText | Should -Match 'nano'
    }

    It 'a stick with no model tiers is a warning, not a failure (setup lets you pick a subset)' {
        $r = Invoke-DoctorCommand -Context (New-TestDoctorContext -AppRoot (New-TestEngineStick -NoModel) -CmdArgs @('--engine'))
        $r.Code | Should -Be 0
        $r.AllText | Should -Match 'no model tiers'
    }

    It 'a good engine with no MSVC runtime -> OfflineEngineMissing(5): incomplete, NOT untrustworthy' {
        # The engine here matches its pin perfectly. It simply cannot start without the runtime, and that is a
        # `--stage-runtime` problem, not a tampering signal. Returning 1 here would cry wolf.
        $r = Invoke-DoctorCommand -Context (New-TestDoctorContext -AppRoot (New-TestEngineStick -NoRuntime) -CmdArgs @('--engine'))
        $r.Code | Should -Be 5
        $r.AllText | Should -Match 'verified against the pin'
    }

    It 'says up front that it hashes every model (the cost is stated, not sprung)' {
        $r = Invoke-DoctorCommand -Context (New-TestDoctorContext -AppRoot (New-TestEngineStick) -CmdArgs @('--engine'))
        $r.AllText | Should -Match 'hashed'
    }

    It 'writes nothing to the stick it is inspecting' {
        $root = New-TestEngineStick
        # A directory's LastWriteTime is deliberately NOT snapshotted: NTFS updates directory timestamps LAZILY, so
        # the `before` reading can catch a value that has not been flushed yet and then "change" on its own with
        # nothing having written anything. That made this test flaky -- green locally, red on CI, where the engine
        # directory's mtime moved by 8ms mid-run. Directories are still snapshotted by PATH, so a created or removed
        # directory is caught; for files, size and mtime are both compared, which is what "writes nothing" means.
        $snapshot = {
            @(Get-ChildItem -LiteralPath $root -Recurse -Force | ForEach-Object {
                    if ($_.PSIsContainer) { '{0}|dir' -f $_.FullName }
                    else { '{0}|{1}|{2}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks }
                }) -join "`n"
        }
        $before = & $snapshot
        Invoke-DoctorCommand -Context (New-TestDoctorContext -AppRoot $root -CmdArgs @('--engine')) | Out-Null
        (& $snapshot) | Should -Be $before
    }
}

Describe 'Command doctor' {

    BeforeAll {
        # Default deterministic host posture: a "healthy" machine (full language, remote-signed, no Device
        # Guard, no AppLocker) on a removable, BitLocker-encrypted volume. Mocking these two impure detection
        # functions isolates the command's wiring from the live host and avoids the ~5s BitLocker probe.
        # Individual tests override Get-LokiHostPosture where a specific posture matters.
        Mock Get-LokiHostPosture {
            [pscustomobject]@{ LanguageMode = 'FullLanguage'; ExecutionPolicy = 'RemoteSigned'; DeviceGuardEnforced = $false; AppLocker = 'none' }
        }
        Mock Get-LokiVolumePosture {
            [pscustomobject]@{ Drive = 'X:'; Removable = $true; BitLockerOn = $true }
        }
    }

    Context 'metadata & registry' {

        It 'metadata is complete (Name == file name, Group Health)' {
            $m = Get-LokiCmdMeta_doctor
            $m.Name | Should -Be 'doctor'
            $m.Summary | Should -Not -BeNullOrEmpty
            $m.Usage | Should -Not -BeNullOrEmpty
            $m.Group | Should -Be 'Health'
        }

        It 'handler is defined' {
            (Get-Command Invoke-LokiCmd_doctor -CommandType Function) | Should -Not -BeNullOrEmpty
        }

        It 'is consistently registered via Get-LokiCommandRegistry (meta + handler, ADR-0002 consistency gate)' {
            $reg = Get-LokiCommandRegistry
            $entry = $reg | Where-Object { $_.Name -eq 'doctor' } | Select-Object -First 1
            $entry | Should -Not -BeNullOrEmpty
            $entry.Handler | Should -Be 'Invoke-LokiCmd_doctor'
            (Get-Command -CommandType Function -Name $entry.Handler -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }

    Context 'rendering & exit code (deterministic mocked posture)' {

        It 'healthy host + no secret -> exit Ok, prints heading + all check labels + footer' {
            $ctx = New-TestDoctorContext -AppRoot (New-TestDoctorAppRoot)
            $r = Invoke-DoctorCommand -Context $ctx
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            $r.AllText | Should -BeLike '*loki doctor*'
            $r.AllText | Should -BeLike '*Authentication*'
            $r.AllText | Should -BeLike '*PowerShell language mode*'
            $r.AllText | Should -BeLike '*Execution policy*'
            $r.AllText | Should -BeLike '*Volume*'
            $r.AllText | Should -Match 'OK,\s*\d+\s*warning\(s\),\s*\d+\s*failure\(s\)'
        }

        It 'no secret set -> the auth check reports "No secret set"' {
            $ctx = New-TestDoctorContext -AppRoot (New-TestDoctorAppRoot)
            $r = Invoke-DoctorCommand -Context $ctx
            $r.AllText | Should -BeLike '*No secret set*'
        }

        It 'ConstrainedLanguage host -> the lang check FAILs and the exit code is GeneralError' {
            Mock Get-LokiHostPosture {
                [pscustomobject]@{ LanguageMode = 'ConstrainedLanguage'; ExecutionPolicy = 'RemoteSigned'; DeviceGuardEnforced = $false; AppLocker = 'none' }
            }
            $ctx = New-TestDoctorContext -AppRoot (New-TestDoctorAppRoot)
            $r = Invoke-DoctorCommand -Context $ctx
            $r.Code | Should -Be (Get-LokiExitCode 'GeneralError')
            $r.AllText | Should -BeLike '*FAIL*'
            $r.AllText | Should -BeLike '*ConstrainedLanguage*'
        }

        It 'exit code is always one of the stable known exit codes' {
            $ctx = New-TestDoctorContext -AppRoot (New-TestDoctorAppRoot)
            $r = Invoke-DoctorCommand -Context $ctx
            @((Get-LokiExitCode 'Ok'), (Get-LokiExitCode 'GeneralError')) | Should -Contain $r.Code
        }

        It 'with a secret set, the auth check reports the masked secret (never the raw value)' {
            $approot = New-TestDoctorAppRoot
            $envPath = Join-Path $approot 'home\.env'
            $plain = 'sk-test-1234567890abcd'
            $ss = New-Object System.Security.SecureString
            foreach ($ch in $plain.ToCharArray()) { $ss.AppendChar($ch) }
            $ss.MakeReadOnly()
            Set-LokiSecret -EnvFilePath $envPath -SecureValue $ss

            $ctx = New-TestDoctorContext -AppRoot $approot
            $r = Invoke-DoctorCommand -Context $ctx
            $r.AllText | Should -BeLike '*sk-...abcd*'
            $r.AllText.Contains($plain) | Should -BeFalse
        }
    }

    Context 'footprint mode (--footprint, ADR-0010)' {

        It 'clean probe -> exit Ok, reports clean' {
            Mock Invoke-LokiFootprintProbe { @{ Clean = $true; Leaked = @(); Observed = @(); Added = @(); Changed = @(); ProbeVerified = $true } }
            $ctx = New-TestDoctorContext -AppRoot (New-TestDoctorAppRoot) -CmdArgs @('--footprint')
            $r = Invoke-DoctorCommand -Context $ctx
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            $r.AllText | Should -BeLike '*Clean*'
        }

        It 'a probe-target leak -> exit FootprintGuard (6), names the leaked target' {
            Mock Invoke-LokiFootprintProbe { @{ Clean = $false; Leaked = @('probe-appdata'); Observed = @(); Added = @('probe-appdata'); Changed = @(); ProbeVerified = $true } }
            $ctx = New-TestDoctorContext -AppRoot (New-TestDoctorAppRoot) -CmdArgs @('--footprint')
            $r = Invoke-DoctorCommand -Context $ctx
            $r.Code | Should -Be (Get-LokiExitCode 'FootprintGuard')
            $r.AllText | Should -BeLike '*FOOTPRINT*'
            $r.AllText | Should -BeLike '*probe-appdata*'
        }

        It 'a clean-but-unverified probe (isolation could not be exercised) -> exit GeneralError' {
            Mock Invoke-LokiFootprintProbe { @{ Clean = $true; Leaked = @(); Observed = @(); Added = @(); Changed = @(); ProbeVerified = $false } }
            $ctx = New-TestDoctorContext -AppRoot (New-TestDoctorAppRoot) -CmdArgs @('--footprint')
            $r = Invoke-DoctorCommand -Context $ctx
            $r.Code | Should -Be (Get-LokiExitCode 'GeneralError')
        }

        It 'a DETECTED leak with an unverified probe -> FootprintGuard (6), not inconclusive (leak wins; the gate primary failure mode)' {
            # When the redirect breaks, the child writes to the host (Clean=$false) AND the stick marker is absent
            # (ProbeVerified=$false) -- they co-occur. The leak must dominate: exit 6 + name the target, never a
            # benign-sounding GeneralError. (Regression the 3-vote review reproduced live.)
            Mock Invoke-LokiFootprintProbe { @{ Clean = $false; Leaked = @('probe-temp'); Observed = @(); Added = @('probe-temp'); Changed = @(); ProbeVerified = $false } }
            $ctx = New-TestDoctorContext -AppRoot (New-TestDoctorAppRoot) -CmdArgs @('--footprint')
            $r = Invoke-DoctorCommand -Context $ctx
            $r.Code | Should -Be (Get-LokiExitCode 'FootprintGuard')
            $r.AllText | Should -BeLike '*FOOTPRINT*'
            $r.AllText | Should -BeLike '*probe-temp*'
        }

        It 'a soft standing change is reported (Observed) but the gate still exits Ok' {
            Mock Invoke-LokiFootprintProbe { @{ Clean = $true; Leaked = @(); Observed = @('host-userprofile-claude'); Added = @(); Changed = @('host-userprofile-claude'); ProbeVerified = $true } }
            $ctx = New-TestDoctorContext -AppRoot (New-TestDoctorAppRoot) -CmdArgs @('--footprint')
            $r = Invoke-DoctorCommand -Context $ctx
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            $r.AllText | Should -BeLike '*host-userprofile-claude*'
        }

        It 'footprint mode does NOT run the posture checks (no Authentication line)' {
            Mock Invoke-LokiFootprintProbe { @{ Clean = $true; Leaked = @(); Observed = @(); Added = @(); Changed = @(); ProbeVerified = $true } }
            $ctx = New-TestDoctorContext -AppRoot (New-TestDoctorAppRoot) -CmdArgs @('--footprint')
            $r = Invoke-DoctorCommand -Context $ctx
            $r.AllText | Should -Not -BeLike '*Authentication*'
        }
    }
}

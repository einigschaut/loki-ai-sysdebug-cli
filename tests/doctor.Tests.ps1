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
    . "$PSScriptRoot\..\src\lib\registry.ps1"
    . "$PSScriptRoot\..\src\commands\doctor.ps1"
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
        param([Parameter(Mandatory = $true)][string]$AppRoot)
        return @{ AppRoot = $AppRoot; Version = 'test'; Args = @(); Flags = @{}; Registry = @() }
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
    Remove-Item Function:\Invoke-DoctorCommand -ErrorAction SilentlyContinue
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
}

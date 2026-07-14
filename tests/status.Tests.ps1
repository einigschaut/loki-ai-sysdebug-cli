# tests/status.Tests.ps1 -- Command `loki status`: metadata, registry, rendering, exit code (CLAUDE.md section 5/6).
#
# `loki status` is the FAST, write-free glance (unlike `loki doctor`, the full diagnosis) -- it reuses the pure
# ConvertTo-LokiDoctorChecks interpreter (src/lib/posture.ps1) with a placeholder "unknown" volume so there is
# no duplicated check logic, but it MUST NOT call the slow Get-LokiVolumePosture (~5s BitLocker probe -- that
# stays exclusive to `loki doctor`). Get-LokiHostPosture / Test-LokiConnectivity are mocked here for determinism
# (live host posture and network reachability vary per machine/run); Get-LokiVolumePosture is ALSO mocked, but
# only to TRACK it -- the "status stays fast" contract is proven via Should -Invoke ... -Times 0 below.
#
# Encapsulation note (see tests\doctor.Tests.ps1): Write-LokiWarn/Write-LokiErr write DIRECTLY via
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
    . "$PSScriptRoot\..\src\lib\net.ps1"
    . "$PSScriptRoot\..\src\lib\posture.ps1"
    . "$PSScriptRoot\..\src\lib\registry.ps1"
    . "$PSScriptRoot\..\src\commands\status.ps1"
    Initialize-LokiUi -NoColor
    Initialize-LokiI18n -AppRoot (Resolve-Path "$PSScriptRoot\..\src").Path -Locale 'en' | Out-Null

    $script:RootTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("loki-statuscmd-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:RootTmp | Out-Null

    # New, isolated temp AppRoot (with home\ subfolder, like the real stick layout) per test case.
    function global:New-TestStatusAppRoot {
        $root = Join-Path $script:RootTmp ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'home') | Out-Null
        return $root
    }

    function global:New-TestStatusContext {
        param([Parameter(Mandatory = $true)][string]$AppRoot)
        return @{ AppRoot = $AppRoot; Version = 'test'; Args = @(); Flags = @{}; Registry = @() }
    }

    # Calls Invoke-LokiCmd_status and returns exit code, stdout text (stream 6), stderr text, and the
    # combined text (ok lines go to stdout, warn/fail lines to stderr).
    function global:Invoke-StatusCommand {
        param([Parameter(Mandatory = $true)][hashtable]$Context)

        $swErr = New-Object System.IO.StringWriter
        $origErr = [Console]::Error
        [Console]::SetError($swErr)
        try {
            $raw = @(Invoke-LokiCmd_status $Context 6>&1)
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
    Remove-Item Function:\New-TestStatusAppRoot -ErrorAction SilentlyContinue
    Remove-Item Function:\New-TestStatusContext -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-StatusCommand -ErrorAction SilentlyContinue
}

Describe 'Command status' {

    BeforeAll {
        # Default deterministic host posture: a "healthy" machine (full language, remote-signed, no Device
        # Guard, no AppLocker), reachable network. Get-LokiVolumePosture is mocked ONLY to track invocations --
        # status must never call it (see the "stays fast" test below).
        Mock Get-LokiHostPosture {
            [pscustomobject]@{ LanguageMode = 'FullLanguage'; ExecutionPolicy = 'RemoteSigned'; DeviceGuardEnforced = $false; AppLocker = 'none' }
        }
        Mock Test-LokiConnectivity { $true }
        Mock Get-LokiVolumePosture {
            [pscustomobject]@{ Drive = $null; Removable = $null; BitLockerOn = $null }
        }
    }

    Context 'metadata & registry' {

        It 'metadata is complete (Name status, Group Health)' {
            $m = Get-LokiCmdMeta_status
            $m.Name | Should -Be 'status'
            $m.Summary | Should -Not -BeNullOrEmpty
            $m.Usage | Should -Not -BeNullOrEmpty
            $m.Group | Should -Be 'Health'
        }

        It 'handler is defined' {
            (Get-Command Invoke-LokiCmd_status -CommandType Function) | Should -Not -BeNullOrEmpty
        }

        It 'is consistently registered via Get-LokiCommandRegistry (meta + handler, ADR-0002 consistency gate)' {
            $reg = Get-LokiCommandRegistry
            $entry = $reg | Where-Object { $_.Name -eq 'status' } | Select-Object -First 1
            $entry | Should -Not -BeNullOrEmpty
            $entry.Handler | Should -Be 'Invoke-LokiCmd_status'
            (Get-Command -CommandType Function -Name $entry.Handler -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }

    Context 'rendering & exit code (deterministic mocked posture)' {

        It 'healthy host + no secret -> exit Ok, prints app-root/PowerShell/Auth/Posture + doctor hint, no stale pending text' {
            $ctx = New-TestStatusContext -AppRoot (New-TestStatusAppRoot)
            $r = Invoke-StatusCommand -Context $ctx
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            $r.AllText | Should -BeLike '*App-Root*'
            $r.AllText | Should -BeLike '*PowerShell*'
            $r.AllText | Should -BeLike '*Auth:*'
            $r.AllText | Should -BeLike '*Posture:*'
            $r.AllText | Should -BeLike '*loki doctor*'
            $r.AllText | Should -Not -BeLike '*coming in stage 1*'
        }

        It 'never calls the slow Get-LokiVolumePosture probe (status stays fast -- break-the-guard proof)' {
            $ctx = New-TestStatusContext -AppRoot (New-TestStatusAppRoot)
            Invoke-StatusCommand -Context $ctx | Out-Null
            Should -Invoke -CommandName Get-LokiVolumePosture -Times 0
        }

        It 'ConstrainedLanguage host -> Posture rollup renders a failure count, but status still exits Ok (a glance never fails)' {
            Mock Get-LokiHostPosture {
                [pscustomobject]@{ LanguageMode = 'ConstrainedLanguage'; ExecutionPolicy = 'RemoteSigned'; DeviceGuardEnforced = $false; AppLocker = 'none' }
            }
            $ctx = New-TestStatusContext -AppRoot (New-TestStatusAppRoot)
            $r = Invoke-StatusCommand -Context $ctx
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            $r.AllText | Should -Match 'ok,\s*\d+\s*warning\(s\),\s*[1-9]\d*\s*issue\(s\)'
        }

        It 'with a secret set, the Auth line shows the masked value, never the raw secret' {
            $approot = New-TestStatusAppRoot
            $envPath = Join-Path $approot 'home\.env'
            $plain = 'sk-test-1234567890abcd'
            $ss = New-Object System.Security.SecureString
            foreach ($ch in $plain.ToCharArray()) { $ss.AppendChar($ch) }
            $ss.MakeReadOnly()
            Set-LokiSecret -EnvFilePath $envPath -SecureValue $ss

            $ctx = New-TestStatusContext -AppRoot $approot
            $r = Invoke-StatusCommand -Context $ctx
            $r.AllText | Should -BeLike '*sk-...abcd*'
            $r.AllText.Contains($plain) | Should -BeFalse
        }
    }
}

# tests/posture.Tests.ps1 -- host/volume posture detection + the pure doctor-check interpreter
# (src/lib/posture.ps1). Detection functions must never throw (CLAUDE.md section 5); ConvertTo-LokiDoctorChecks
# is table-tested for every documented mapping, including the "break the guard once" proofs.
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\exitcodes.ps1"
    . "$PSScriptRoot\..\src\lib\posture.ps1"

    $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ("loki-posture-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:Work | Out-Null

    function global:New-FakeAuthStatus {
        param([bool]$Present, [string]$Masked = 'sk-...abcd')
        [pscustomobject]@{ Present = $Present; Masked = $Masked }
    }

    function global:New-FakeHostPosture {
        param(
            $LanguageMode = 'FullLanguage',
            $ExecutionPolicy = 'RemoteSigned',
            $DeviceGuardEnforced = $false,
            $AppLocker = 'none'
        )
        [pscustomobject]@{
            LanguageMode        = $LanguageMode
            ExecutionPolicy     = $ExecutionPolicy
            DeviceGuardEnforced = $DeviceGuardEnforced
            AppLocker           = $AppLocker
        }
    }

    function global:New-FakeVolumePosture {
        param($Drive = 'C:', $Removable = $false, $BitLockerOn = $false)
        [pscustomobject]@{ Drive = $Drive; Removable = $Removable; BitLockerOn = $BitLockerOn }
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force }
    Remove-Item Function:\New-FakeAuthStatus -ErrorAction SilentlyContinue
    Remove-Item Function:\New-FakeHostPosture -ErrorAction SilentlyContinue
    Remove-Item Function:\New-FakeVolumePosture -ErrorAction SilentlyContinue
}

Describe 'Get-LokiHostPosture' {

    It 'does not throw and returns an object with the four documented properties' {
        # Calling directly (not via a wrapping scriptblock): a wrapping `{ $r = ... } | Should -Not -Throw`
        # would run in a CHILD scope, so an assignment inside it would never reach the outer $r. Pester
        # already fails the It block if an exception escapes, so a direct call covers "does not throw" too.
        $r = Get-LokiHostPosture
        $r.PSObject.Properties.Name | Should -Contain 'LanguageMode'
        $r.PSObject.Properties.Name | Should -Contain 'ExecutionPolicy'
        $r.PSObject.Properties.Name | Should -Contain 'DeviceGuardEnforced'
        $r.PSObject.Properties.Name | Should -Contain 'AppLocker'
    }

    It 'LanguageMode reflects the current session (never null/empty)' {
        $r = Get-LokiHostPosture
        $r.LanguageMode | Should -Not -BeNullOrEmpty
        $r.LanguageMode | Should -Be $ExecutionContext.SessionState.LanguageMode.ToString()
    }

    It 'AppLocker is one of the three documented sentinels' {
        $r = Get-LokiHostPosture
        @('rules', 'none', 'unknown') | Should -Contain $r.AppLocker
    }

    It 'DeviceGuardEnforced is $true, $false or $null (never throws, never anything else)' {
        $r = Get-LokiHostPosture
        ($null -eq $r.DeviceGuardEnforced) -or ($r.DeviceGuardEnforced -is [bool]) | Should -BeTrue
    }
}

Describe 'Get-LokiVolumePosture' {

    It 'returns Drive/Removable/BitLockerOn for a real temp directory, does not throw' {
        $dir = Join-Path $script:Work 'realdir'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $r = Get-LokiVolumePosture -Path $dir
        $r.PSObject.Properties.Name | Should -Contain 'Drive'
        $r.PSObject.Properties.Name | Should -Contain 'Removable'
        $r.PSObject.Properties.Name | Should -Contain 'BitLockerOn'
        $r.Drive | Should -Not -BeNullOrEmpty
    }

    It 'a non-existent path does not throw' {
        $missing = Join-Path $script:Work 'this-does-not-exist-at-all'
        $r = Get-LokiVolumePosture -Path $missing
        $r | Should -Not -BeNullOrEmpty
    }

    It 'an unresolvable/relative path does not throw and Drive may be $null' {
        $r = Get-LokiVolumePosture -Path 'not-a-rooted-path'
        $r | Should -Not -BeNullOrEmpty
    }
}

Describe 'ConvertTo-LokiDoctorChecks - auth' {

    It 'auth present -> ok, secretSet detail key + masked arg' {
        $checks = ConvertTo-LokiDoctorChecks -HostPosture (New-FakeHostPosture) -VolumePosture (New-FakeVolumePosture) -AuthStatus (New-FakeAuthStatus -Present $true -Masked 'sk-...wxyz')
        $c = $checks | Where-Object { $_.Id -eq 'auth' }
        $c.Severity | Should -Be 'ok'
        $c.LabelKey | Should -Be 'doctor.check.auth'
        $c.DetailKey | Should -Be 'auth.status.secretSet'
        $c.DetailArgs | Should -Be @('sk-...wxyz')
    }

    It 'auth absent -> warn, secretUnset detail key' {
        $checks = ConvertTo-LokiDoctorChecks -HostPosture (New-FakeHostPosture) -VolumePosture (New-FakeVolumePosture) -AuthStatus (New-FakeAuthStatus -Present $false)
        $c = $checks | Where-Object { $_.Id -eq 'auth' }
        $c.Severity | Should -Be 'warn'
        $c.LabelKey | Should -Be 'doctor.check.auth'
        $c.DetailKey | Should -Be 'auth.status.secretUnset'
    }
}

Describe 'ConvertTo-LokiDoctorChecks - language mode (break-the-guard proof)' {

    It 'FullLanguage -> ok' {
        $checks = ConvertTo-LokiDoctorChecks -HostPosture (New-FakeHostPosture -LanguageMode 'FullLanguage') -VolumePosture (New-FakeVolumePosture) -AuthStatus (New-FakeAuthStatus -Present $true)
        $c = $checks | Where-Object { $_.Id -eq 'lang' }
        $c.Severity | Should -Be 'ok'
        $c.LabelKey | Should -Be 'doctor.check.lang'
        $c.Severity | Should -Not -Be 'fail'
    }

    It 'ConstrainedLanguage -> fail (the guard the doctor exists to catch)' {
        $checks = ConvertTo-LokiDoctorChecks -HostPosture (New-FakeHostPosture -LanguageMode 'ConstrainedLanguage') -VolumePosture (New-FakeVolumePosture) -AuthStatus (New-FakeAuthStatus -Present $true)
        $c = $checks | Where-Object { $_.Id -eq 'lang' }
        $c.Severity | Should -Be 'fail'
        $c.LabelKey | Should -Be 'doctor.check.lang'
    }

    It '$null LanguageMode -> unknown' {
        $checks = ConvertTo-LokiDoctorChecks -HostPosture (New-FakeHostPosture -LanguageMode $null) -VolumePosture (New-FakeVolumePosture) -AuthStatus (New-FakeAuthStatus -Present $true)
        $c = $checks | Where-Object { $_.Id -eq 'lang' }
        $c.Severity | Should -Be 'unknown'
        $c.DetailKey | Should -Be 'doctor.detail.unknown'
    }

    It 'any other value (e.g. RestrictedLanguage) -> warn' {
        $checks = ConvertTo-LokiDoctorChecks -HostPosture (New-FakeHostPosture -LanguageMode 'RestrictedLanguage') -VolumePosture (New-FakeVolumePosture) -AuthStatus (New-FakeAuthStatus -Present $true)
        $c = $checks | Where-Object { $_.Id -eq 'lang' }
        $c.Severity | Should -Be 'warn'
    }
}

Describe 'ConvertTo-LokiDoctorChecks - execution policy' {

    It '$null -> unknown' {
        $checks = ConvertTo-LokiDoctorChecks -HostPosture (New-FakeHostPosture -ExecutionPolicy $null) -VolumePosture (New-FakeVolumePosture) -AuthStatus (New-FakeAuthStatus -Present $true)
        $c = $checks | Where-Object { $_.Id -eq 'execpolicy' }
        $c.Severity | Should -Be 'unknown'
        $c.DetailKey | Should -Be 'doctor.detail.unknown'
    }

    It 'Restricted -> warn' {
        $checks = ConvertTo-LokiDoctorChecks -HostPosture (New-FakeHostPosture -ExecutionPolicy 'Restricted') -VolumePosture (New-FakeVolumePosture) -AuthStatus (New-FakeAuthStatus -Present $true)
        ($checks | Where-Object { $_.Id -eq 'execpolicy' }).Severity | Should -Be 'warn'
    }

    It 'AllSigned -> warn' {
        $checks = ConvertTo-LokiDoctorChecks -HostPosture (New-FakeHostPosture -ExecutionPolicy 'AllSigned') -VolumePosture (New-FakeVolumePosture) -AuthStatus (New-FakeAuthStatus -Present $true)
        ($checks | Where-Object { $_.Id -eq 'execpolicy' }).Severity | Should -Be 'warn'
    }

    It 'RemoteSigned -> ok' {
        $checks = ConvertTo-LokiDoctorChecks -HostPosture (New-FakeHostPosture -ExecutionPolicy 'RemoteSigned') -VolumePosture (New-FakeVolumePosture) -AuthStatus (New-FakeAuthStatus -Present $true)
        ($checks | Where-Object { $_.Id -eq 'execpolicy' }).Severity | Should -Be 'ok'
    }

    It 'Unrestricted -> ok' {
        $checks = ConvertTo-LokiDoctorChecks -HostPosture (New-FakeHostPosture -ExecutionPolicy 'Unrestricted') -VolumePosture (New-FakeVolumePosture) -AuthStatus (New-FakeAuthStatus -Present $true)
        ($checks | Where-Object { $_.Id -eq 'execpolicy' }).Severity | Should -Be 'ok'
    }
}

Describe 'ConvertTo-LokiDoctorChecks - Device Guard' {

    It '$true -> warn (enforced)' {
        $checks = ConvertTo-LokiDoctorChecks -HostPosture (New-FakeHostPosture -DeviceGuardEnforced $true) -VolumePosture (New-FakeVolumePosture) -AuthStatus (New-FakeAuthStatus -Present $true)
        $c = $checks | Where-Object { $_.Id -eq 'deviceguard' }
        $c.Severity | Should -Be 'warn'
        $c.DetailKey | Should -Be 'doctor.deviceguard.enforced'
    }

    It '$false -> ok (off)' {
        $checks = ConvertTo-LokiDoctorChecks -HostPosture (New-FakeHostPosture -DeviceGuardEnforced $false) -VolumePosture (New-FakeVolumePosture) -AuthStatus (New-FakeAuthStatus -Present $true)
        $c = $checks | Where-Object { $_.Id -eq 'deviceguard' }
        $c.Severity | Should -Be 'ok'
        $c.DetailKey | Should -Be 'doctor.deviceguard.off'
    }

    It '$null -> unknown' {
        $checks = ConvertTo-LokiDoctorChecks -HostPosture (New-FakeHostPosture -DeviceGuardEnforced $null) -VolumePosture (New-FakeVolumePosture) -AuthStatus (New-FakeAuthStatus -Present $true)
        $c = $checks | Where-Object { $_.Id -eq 'deviceguard' }
        $c.Severity | Should -Be 'unknown'
        $c.DetailKey | Should -Be 'doctor.detail.unknown'
    }
}

Describe 'ConvertTo-LokiDoctorChecks - AppLocker' {

    It "'rules' -> warn" {
        $checks = ConvertTo-LokiDoctorChecks -HostPosture (New-FakeHostPosture -AppLocker 'rules') -VolumePosture (New-FakeVolumePosture) -AuthStatus (New-FakeAuthStatus -Present $true)
        $c = $checks | Where-Object { $_.Id -eq 'applocker' }
        $c.Severity | Should -Be 'warn'
        $c.DetailKey | Should -Be 'doctor.applocker.rules'
    }

    It "'none' -> ok" {
        $checks = ConvertTo-LokiDoctorChecks -HostPosture (New-FakeHostPosture -AppLocker 'none') -VolumePosture (New-FakeVolumePosture) -AuthStatus (New-FakeAuthStatus -Present $true)
        $c = $checks | Where-Object { $_.Id -eq 'applocker' }
        $c.Severity | Should -Be 'ok'
        $c.DetailKey | Should -Be 'doctor.applocker.none'
    }

    It "'unknown' -> unknown" {
        $checks = ConvertTo-LokiDoctorChecks -HostPosture (New-FakeHostPosture -AppLocker 'unknown') -VolumePosture (New-FakeVolumePosture) -AuthStatus (New-FakeAuthStatus -Present $true)
        $c = $checks | Where-Object { $_.Id -eq 'applocker' }
        $c.Severity | Should -Be 'unknown'
        $c.DetailKey | Should -Be 'doctor.detail.unknown'
    }
}

Describe 'ConvertTo-LokiDoctorChecks - Volume' {

    It 'removable + BitLocker on -> ok, encrypted' {
        $checks = ConvertTo-LokiDoctorChecks -HostPosture (New-FakeHostPosture) -VolumePosture (New-FakeVolumePosture -Removable $true -BitLockerOn $true) -AuthStatus (New-FakeAuthStatus -Present $true)
        $c = $checks | Where-Object { $_.Id -eq 'volume' }
        $c.Severity | Should -Be 'ok'
        $c.DetailKey | Should -Be 'doctor.volume.encrypted'
    }

    It 'removable but BitLocker off -> warn, plain' {
        $checks = ConvertTo-LokiDoctorChecks -HostPosture (New-FakeHostPosture) -VolumePosture (New-FakeVolumePosture -Removable $true -BitLockerOn $false) -AuthStatus (New-FakeAuthStatus -Present $true)
        $c = $checks | Where-Object { $_.Id -eq 'volume' }
        $c.Severity | Should -Be 'warn'
        $c.DetailKey | Should -Be 'doctor.volume.plain'
    }

    It 'fixed drive (not removable), BitLocker on -> warn, plain' {
        $checks = ConvertTo-LokiDoctorChecks -HostPosture (New-FakeHostPosture) -VolumePosture (New-FakeVolumePosture -Removable $false -BitLockerOn $true) -AuthStatus (New-FakeAuthStatus -Present $true)
        $c = $checks | Where-Object { $_.Id -eq 'volume' }
        $c.Severity | Should -Be 'warn'
        $c.DetailKey | Should -Be 'doctor.volume.plain'
    }

    It 'Removable unknown ($null) -> unknown' {
        $checks = ConvertTo-LokiDoctorChecks -HostPosture (New-FakeHostPosture) -VolumePosture (New-FakeVolumePosture -Removable $null -BitLockerOn $true) -AuthStatus (New-FakeAuthStatus -Present $true)
        $c = $checks | Where-Object { $_.Id -eq 'volume' }
        $c.Severity | Should -Be 'unknown'
        $c.DetailKey | Should -Be 'doctor.detail.unknown'
    }

    It 'BitLockerOn unknown ($null) -> unknown' {
        $checks = ConvertTo-LokiDoctorChecks -HostPosture (New-FakeHostPosture) -VolumePosture (New-FakeVolumePosture -Removable $true -BitLockerOn $null) -AuthStatus (New-FakeAuthStatus -Present $true)
        $c = $checks | Where-Object { $_.Id -eq 'volume' }
        $c.Severity | Should -Be 'unknown'
        $c.DetailKey | Should -Be 'doctor.detail.unknown'
    }
}

Describe 'ConvertTo-LokiDoctorChecks - shape' {

    It 'returns exactly the 6 documented checks, in order' {
        $checks = ConvertTo-LokiDoctorChecks -HostPosture (New-FakeHostPosture) -VolumePosture (New-FakeVolumePosture) -AuthStatus (New-FakeAuthStatus -Present $true)
        $checks.Count | Should -Be 6
        @($checks | ForEach-Object { $_.Id }) | Should -Be @('auth', 'lang', 'execpolicy', 'deviceguard', 'applocker', 'volume')
    }
}

Describe 'Get-LokiDoctorExitCode' {

    It 'any fail -> GeneralError' {
        $checks = @(
            [pscustomobject]@{ Severity = 'ok' }
            [pscustomobject]@{ Severity = 'fail' }
            [pscustomobject]@{ Severity = 'warn' }
        )
        Get-LokiDoctorExitCode -Checks $checks | Should -Be (Get-LokiExitCode 'GeneralError')
    }

    It 'all ok -> Ok' {
        $checks = @(
            [pscustomobject]@{ Severity = 'ok' }
            [pscustomobject]@{ Severity = 'ok' }
        )
        Get-LokiDoctorExitCode -Checks $checks | Should -Be (Get-LokiExitCode 'Ok')
    }

    It 'only warn/unknown (no fail) -> Ok' {
        $checks = @(
            [pscustomobject]@{ Severity = 'warn' }
            [pscustomobject]@{ Severity = 'unknown' }
            [pscustomobject]@{ Severity = 'ok' }
        )
        Get-LokiDoctorExitCode -Checks $checks | Should -Be (Get-LokiExitCode 'Ok')
    }
}

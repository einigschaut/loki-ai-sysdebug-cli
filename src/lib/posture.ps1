# lib/posture.ps1 - host/volume posture detection (read-only diagnostics, CLAUDE.md section 5/6)
# Contract:
#   Get-LokiHostPosture ()                              -> [pscustomobject]{ LanguageMode; ExecutionPolicy; DeviceGuardEnforced; AppLocker }
#     Read-only, no admin required, NEVER throws (every environment call wrapped in try/catch -> sentinel).
#       LanguageMode        : $ExecutionContext.SessionState.LanguageMode.ToString() (never fails).
#       ExecutionPolicy     : (Get-ExecutionPolicy).ToString(), or $null on failure.
#       DeviceGuardEnforced : $true/$false from Win32_DeviceGuard (CodeIntegrityPolicyEnforcementStatus
#                             or UsermodeCodeIntegrityPolicyEnforcementStatus == 2), or $null if the class/
#                             namespace is unavailable (most consumer machines).
#       AppLocker           : 'rules' (effective rule collections present) | 'none' | 'unknown' (AppLocker
#                             cmdlet/service unavailable, e.g. non-Enterprise SKU).
#   Get-LokiVolumePosture -Path <string>                 -> [pscustomobject]{ Drive; Removable; BitLockerOn }
#     Read-only, no admin required, NEVER throws (also for a non-existent path).
#       Drive       : drive letter (e.g. 'C:') derived purely from the path string (no filesystem access
#                     needed to resolve it -> also works for a not-yet-existing path). $null if unresolvable.
#       Removable   : Win32_LogicalDisk.DriveType -eq 2 -> $true, else $false; $null if the drive can't be queried.
#       BitLockerOn : Get-BitLockerVolume.ProtectionStatus -eq 'On'/'Off'; $null if the BitLocker cmdlet/volume
#                     is unavailable (module not installed, non-NTFS volume, etc.).
#   ConvertTo-LokiDoctorChecks -HostPosture <o> -VolumePosture <o> -AuthStatus <o> -> [pscustomobject[]]
#     PURE interpreter (no i18n calls, no environment calls -> fully unit-testable). Maps the three input
#     objects to an ORDERED list of checks: @{ Id; Severity ('ok'|'warn'|'fail'|'unknown'); LabelKey;
#     DetailKey; DetailArgs; DetailRaw }. See src/commands/doctor.ps1 for how it's rendered.
#   Get-LokiDoctorExitCode -Checks <array>               -> [int]
#     Any check with Severity 'fail' -> Get-LokiExitCode 'GeneralError'; else Get-LokiExitCode 'Ok'.
#     (Depends on lib/exitcodes.ps1 being loaded -- true at runtime via the dispatcher's lib auto-load.)
# CLAUDE.md section 5: detection functions here are strictly READ-ONLY and MUST NOT throw outward --
# every environment call (Get-CimInstance/Get-AppLockerPolicy/Get-BitLockerVolume/Get-ExecutionPolicy) is
# wrapped in its own try/catch with a sentinel ($null / 'unknown') on failure, so a locked-down host
# (missing module, no namespace, non-admin) degrades to "unknown", never to a crash.
Set-StrictMode -Version Latest

function Get-LokiHostPosture {
    $languageMode = $ExecutionContext.SessionState.LanguageMode.ToString()

    $executionPolicy = $null
    try {
        $executionPolicy = (Get-ExecutionPolicy).ToString()
    }
    catch {
        $executionPolicy = $null
    }

    $deviceGuardEnforced = $null
    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        $codeIntegrity = $null
        $userModeCodeIntegrity = $null
        if ($null -ne $dg) {
            $codeIntegrity = $dg.CodeIntegrityPolicyEnforcementStatus
            $userModeCodeIntegrity = $dg.UsermodeCodeIntegrityPolicyEnforcementStatus
        }
        if (($codeIntegrity -eq 2) -or ($userModeCodeIntegrity -eq 2)) {
            $deviceGuardEnforced = $true
        }
        else {
            $deviceGuardEnforced = $false
        }
    }
    catch {
        $deviceGuardEnforced = $null
    }

    $appLocker = 'unknown'
    try {
        $policy = Get-AppLockerPolicy -Effective -ErrorAction Stop
        $hasRules = $false
        if ($null -ne $policy) {
            foreach ($rc in $policy.RuleCollections) {
                if ($rc.Count -gt 0) { $hasRules = $true }
            }
        }
        if ($hasRules) { $appLocker = 'rules' } else { $appLocker = 'none' }
    }
    catch {
        $appLocker = 'unknown'
    }

    return [pscustomobject]@{
        LanguageMode        = $languageMode
        ExecutionPolicy     = $executionPolicy
        DeviceGuardEnforced = $deviceGuardEnforced
        AppLocker           = $appLocker
    }
}

function Get-LokiVolumePosture {
    param([Parameter(Mandatory = $true)][string]$Path)

    # Drive is derived purely from the path STRING (no filesystem access) -> also resolves for a
    # not-yet-existing path (contract: "must not throw even for a non-existent path").
    $drive = $null
    try {
        $root = [System.IO.Path]::GetPathRoot($Path)
        if (-not [string]::IsNullOrEmpty($root)) {
            $trimmed = $root.TrimEnd('\', '/')
            if (-not [string]::IsNullOrEmpty($trimmed)) { $drive = $trimmed }
        }
    }
    catch {
        $drive = $null
    }

    $removable = $null
    if ($null -ne $drive) {
        try {
            $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$drive'" -ErrorAction Stop
            if (($null -ne $disk) -and ($disk.DriveType -eq 2)) { $removable = $true } else { $removable = $false }
        }
        catch {
            $removable = $null
        }
    }

    $bitLockerOn = $null
    if ($null -ne $drive) {
        try {
            $vol = Get-BitLockerVolume -MountPoint $drive -ErrorAction Stop
            if ($null -eq $vol) {
                $bitLockerOn = $null
            }
            elseif (([string]$vol.ProtectionStatus) -eq 'On') {
                $bitLockerOn = $true
            }
            elseif (([string]$vol.ProtectionStatus) -eq 'Off') {
                $bitLockerOn = $false
            }
            else {
                $bitLockerOn = $null
            }
        }
        catch {
            $bitLockerOn = $null
        }
    }

    return [pscustomobject]@{
        Drive       = $drive
        Removable   = $removable
        BitLockerOn = $bitLockerOn
    }
}

function ConvertTo-LokiDoctorChecks {
    # 'Checks' is the exact contract name specified for this function (a set of check results, not a
    # single check) -- CLAUDE.md section 3 forbids renaming a specified interface; suppress rather than rename.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Exact contract name (result is a list of checks, not one check); renaming after the contract is specified is forbidden by CLAUDE.md section 3.')]
    param(
        [Parameter(Mandatory = $true)]$HostPosture,
        [Parameter(Mandatory = $true)]$VolumePosture,
        [Parameter(Mandatory = $true)]$AuthStatus
    )

    $checks = @()

    if ($AuthStatus.Present) {
        $checks += [pscustomobject]@{
            Id         = 'auth'
            Severity   = 'ok'
            LabelKey   = 'doctor.check.auth'
            DetailKey  = 'auth.status.secretSet'
            DetailArgs = @($AuthStatus.Masked)
            DetailRaw  = $null
        }
    }
    else {
        $checks += [pscustomobject]@{
            Id         = 'auth'
            Severity   = 'warn'
            LabelKey   = 'doctor.check.auth'
            DetailKey  = 'auth.status.secretUnset'
            DetailArgs = @()
            DetailRaw  = $null
        }
    }

    $langMode = $HostPosture.LanguageMode
    if ($null -eq $langMode) {
        $checks += [pscustomobject]@{
            Id         = 'lang'
            Severity   = 'unknown'
            LabelKey   = 'doctor.check.lang'
            DetailKey  = 'doctor.detail.unknown'
            DetailArgs = @()
            DetailRaw  = $null
        }
    }
    elseif ($langMode -eq 'FullLanguage') {
        $checks += [pscustomobject]@{
            Id         = 'lang'
            Severity   = 'ok'
            LabelKey   = 'doctor.check.lang'
            DetailKey  = $null
            DetailArgs = @()
            DetailRaw  = $langMode
        }
    }
    elseif ($langMode -eq 'ConstrainedLanguage') {
        $checks += [pscustomobject]@{
            Id         = 'lang'
            Severity   = 'fail'
            LabelKey   = 'doctor.check.lang'
            DetailKey  = $null
            DetailArgs = @()
            DetailRaw  = $langMode
        }
    }
    else {
        $checks += [pscustomobject]@{
            Id         = 'lang'
            Severity   = 'warn'
            LabelKey   = 'doctor.check.lang'
            DetailKey  = $null
            DetailArgs = @()
            DetailRaw  = $langMode
        }
    }

    $execPolicy = $HostPosture.ExecutionPolicy
    if ($null -eq $execPolicy) {
        $checks += [pscustomobject]@{
            Id         = 'execpolicy'
            Severity   = 'unknown'
            LabelKey   = 'doctor.check.execpolicy'
            DetailKey  = 'doctor.detail.unknown'
            DetailArgs = @()
            DetailRaw  = $null
        }
    }
    elseif (($execPolicy -eq 'Restricted') -or ($execPolicy -eq 'AllSigned')) {
        $checks += [pscustomobject]@{
            Id         = 'execpolicy'
            Severity   = 'warn'
            LabelKey   = 'doctor.check.execpolicy'
            DetailKey  = $null
            DetailArgs = @()
            DetailRaw  = $execPolicy
        }
    }
    else {
        $checks += [pscustomobject]@{
            Id         = 'execpolicy'
            Severity   = 'ok'
            LabelKey   = 'doctor.check.execpolicy'
            DetailKey  = $null
            DetailArgs = @()
            DetailRaw  = $execPolicy
        }
    }

    $dgEnforced = $HostPosture.DeviceGuardEnforced
    if ($null -eq $dgEnforced) {
        $checks += [pscustomobject]@{
            Id         = 'deviceguard'
            Severity   = 'unknown'
            LabelKey   = 'doctor.check.deviceguard'
            DetailKey  = 'doctor.detail.unknown'
            DetailArgs = @()
            DetailRaw  = $null
        }
    }
    elseif ($dgEnforced) {
        $checks += [pscustomobject]@{
            Id         = 'deviceguard'
            Severity   = 'warn'
            LabelKey   = 'doctor.check.deviceguard'
            DetailKey  = 'doctor.deviceguard.enforced'
            DetailArgs = @()
            DetailRaw  = $null
        }
    }
    else {
        $checks += [pscustomobject]@{
            Id         = 'deviceguard'
            Severity   = 'ok'
            LabelKey   = 'doctor.check.deviceguard'
            DetailKey  = 'doctor.deviceguard.off'
            DetailArgs = @()
            DetailRaw  = $null
        }
    }

    $appLocker = $HostPosture.AppLocker
    if ($appLocker -eq 'rules') {
        $checks += [pscustomobject]@{
            Id         = 'applocker'
            Severity   = 'warn'
            LabelKey   = 'doctor.check.applocker'
            DetailKey  = 'doctor.applocker.rules'
            DetailArgs = @()
            DetailRaw  = $null
        }
    }
    elseif ($appLocker -eq 'none') {
        $checks += [pscustomobject]@{
            Id         = 'applocker'
            Severity   = 'ok'
            LabelKey   = 'doctor.check.applocker'
            DetailKey  = 'doctor.applocker.none'
            DetailArgs = @()
            DetailRaw  = $null
        }
    }
    else {
        $checks += [pscustomobject]@{
            Id         = 'applocker'
            Severity   = 'unknown'
            LabelKey   = 'doctor.check.applocker'
            DetailKey  = 'doctor.detail.unknown'
            DetailArgs = @()
            DetailRaw  = $null
        }
    }

    $removable = $VolumePosture.Removable
    $bitLockerOn = $VolumePosture.BitLockerOn
    if ($removable -and $bitLockerOn) {
        $checks += [pscustomobject]@{
            Id         = 'volume'
            Severity   = 'ok'
            LabelKey   = 'doctor.check.volume'
            DetailKey  = 'doctor.volume.encrypted'
            DetailArgs = @()
            DetailRaw  = $null
        }
    }
    elseif (($null -eq $removable) -or ($null -eq $bitLockerOn)) {
        $checks += [pscustomobject]@{
            Id         = 'volume'
            Severity   = 'unknown'
            LabelKey   = 'doctor.check.volume'
            DetailKey  = 'doctor.detail.unknown'
            DetailArgs = @()
            DetailRaw  = $null
        }
    }
    else {
        $checks += [pscustomobject]@{
            Id         = 'volume'
            Severity   = 'warn'
            LabelKey   = 'doctor.check.volume'
            DetailKey  = 'doctor.volume.plain'
            DetailArgs = @()
            DetailRaw  = $null
        }
    }

    return , $checks
}

function Get-LokiDoctorExitCode {
    param([Parameter(Mandatory = $true)]$Checks)

    foreach ($c in $Checks) {
        if ($c.Severity -eq 'fail') {
            return (Get-LokiExitCode 'GeneralError')
        }
    }
    return (Get-LokiExitCode 'Ok')
}

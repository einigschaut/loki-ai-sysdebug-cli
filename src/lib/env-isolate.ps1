# lib/env-isolate.ps1 -- process environment isolation for child processes (security core, CLAUDE.md paragraph 5)
# Principle (confirmed by prior-art review, "redirect instead of clean up"):
#   Isolation sets env vars ONLY in the CHILD PROCESS's env block. The parent session
#   (current PowerShell process) is NEVER mutated on the normal path -> there is nothing to
#   clean up for env (no leak by construction). Teardown exists ONLY for the few things that
#   outlive the process itself (wrapper/registry) -> paired LIFO undo.
# Contract:
#   Get-LokiIsolatedEnv -StickRoot <string> [-BasePath <string>] -> [hashtable]
#     All env var->value pairs to set, every path anchored under $StickRoot. Pure:
#     reads no global state besides the BasePath default, does not mutate Env: itself.
#   New-LokiChildEnvBlock -Isolated <hashtable> [-BaseEnv <IDictionary>] -> [hashtable]
#     Copy of BaseEnv (default: current process env as a new hashtable) with Isolated overlaid.
#     Does NOT mutate the passed-in BaseEnv. Result is meant for handoff to a child process.
#   New-LokiTeardownStack -> [object]
#     Empty LIFO undo collection.
#   Set-LokiProcessEnvTracked -Stack <object> -Name <string> -Value <string>
#     Sets $env:<Name> in the CURRENT process, captures the prior state BEFOREHAND (value or "was not
#     set") and registers the exact undo in $Stack. Only for the rare case where a
#     process env really must outlive it (wrapper/registry) -- not child-process isolation.
#   Invoke-LokiTeardown -Stack <object>
#     Replays the undos in LIFO order; vars that were previously unset are removed (Remove-Item),
#     not set to an empty string. Clears the stack afterward.
Set-StrictMode -Version Latest

function Get-LokiIsolatedEnv {
    param(
        [Parameter(Mandatory = $true)][string]$StickRoot,
        [string]$BasePath = $env:PATH
    )

    $homeDir         = Join-Path $StickRoot 'home'
    $claudeConfigDir = Join-Path $homeDir '.claude'
    $appDataDir      = Join-Path $homeDir 'appdata'
    $localAppDataDir = Join-Path $appDataDir 'local'
    $tempDir         = Join-Path $StickRoot 'temp'

    # Neutralize host sibling vars (Opus review / ADR-0003) -- otherwise home leaks via
    # %HOMEDRIVE%%HOMEPATH% (and via PSModulePath/OneDrive/USERNAME/USERDOMAIN) into the child block.
    $homeDriveQualifier = Split-Path -Path $homeDir -Qualifier
    $homePathRest       = $homeDir.Substring($homeDriveQualifier.Length)
    $psModulePathDir    = Join-Path $homeDir 'Documents\WindowsPowerShell\Modules'
    $oneDriveDir        = Join-Path $homeDir 'OneDrive'

    $toolsRoot            = Join-Path $StickRoot 'tools'
    $toolsBinDir          = Join-Path $toolsRoot 'bin'
    $toolsDnsDir          = Join-Path $toolsRoot 'dns'
    $toolsWiresharkDir    = Join-Path $toolsRoot 'wireshark'
    $toolsSysinternalsDir = Join-Path $toolsRoot 'sysinternals'
    $pathValue = '{0};{1};{2};{3};{4}' -f $toolsBinDir, $toolsDnsDir, $toolsWiresharkDir, $toolsSysinternalsDir, $BasePath

    return @{
        USERPROFILE                            = $homeDir
        HOME                                    = $homeDir
        CLAUDE_CONFIG_DIR                       = $claudeConfigDir
        APPDATA                                 = $appDataDir
        LOCALAPPDATA                             = $localAppDataDir
        TEMP                                     = $tempDir
        TMP                                      = $tempDir
        TMPDIR                                   = $tempDir
        HOMEDRIVE                                = $homeDriveQualifier
        HOMEPATH                                  = $homePathRest
        USERNAME                                  = 'loki'
        USERDOMAIN                                = 'LOKI'
        PSModulePath                              = $psModulePathDir
        OneDrive                                  = $oneDriveDir
        CLAUDE_CODE_SKIP_PROMPT_HISTORY          = '1'
        DISABLE_TELEMETRY                        = '1'
        DO_NOT_TRACK                             = '1'
        DISABLE_UPDATES                          = '1'
        DISABLE_AUTOUPDATER                       = '1'
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
        CLAUDE_CODE_DISABLE_AUTO_MEMORY          = '1'
        CLAUDE_CODE_CERT_STORE                   = 'system'
        PATH                                      = $pathValue
    }
}

function New-LokiChildEnvBlock {
    # PSScriptAnalyzer PSUseShouldProcessForStateChangingFunctions: false positive -- the verb "New"
    # doesn't mutate anything outside the return value here (pure copy+overlay), no ShouldProcess needed.
    [System.Diagnostics.CodeAnalysis.SuppressMessage('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure construction/copy; no side effect beyond the return value.')]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Isolated,
        [System.Collections.IDictionary]$BaseEnv
    )

    if ($null -eq $BaseEnv) {
        $BaseEnv = @{}
        foreach ($item in (Get-ChildItem -Path 'Env:')) {
            $BaseEnv[$item.Name] = $item.Value
        }
    }

    $result = @{}
    foreach ($key in $BaseEnv.Keys) {
        $result[$key] = $BaseEnv[$key]
    }
    foreach ($key in $Isolated.Keys) {
        $result[$key] = $Isolated[$key]
    }
    return $result
}

function New-LokiTeardownStack {
    # PSScriptAnalyzer PSUseShouldProcessForStateChangingFunctions: false positive -- the verb "New"
    # doesn't mutate anything outside the return value here (just returns a new, empty collection).
    [System.Diagnostics.CodeAnalysis.SuppressMessage('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure construction of a new empty collection; no side effect.')]
    param()
    return New-Object 'System.Collections.Generic.List[hashtable]'
}

function Set-LokiProcessEnvTracked {
    # Note (Windows quirk, not a bug here): Set-Item Env:\X -Value '' effectively removes the
    # variable -- Windows doesn't distinguish between "empty string" and "unset". The undo
    # stays correct regardless, because HadValue/PreviousValue are captured before the Set.
    # Mutates real process state ($env:) -> SupportsShouldProcess isn't ceremony here,
    # it prevents a -WhatIf run from recording an undo entry without an actual change.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]$Stack,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    $envPath = "Env:\$Name"
    $hadValue = Test-Path -LiteralPath $envPath
    $previousValue = $null
    if ($hadValue) {
        $previousValue = (Get-Item -LiteralPath $envPath).Value
    }

    if ($PSCmdlet.ShouldProcess($envPath, 'Set-Item')) {
        $undo = @{
            Name          = $Name
            HadValue      = $hadValue
            PreviousValue = $previousValue
        }
        $Stack.Add($undo)

        Set-Item -LiteralPath $envPath -Value $Value
    }
}

function Invoke-LokiTeardown {
    param([Parameter(Mandatory = $true)]$Stack)

    for ($i = $Stack.Count - 1; $i -ge 0; $i--) {
        $undo = $Stack[$i]
        $envPath = "Env:\$($undo.Name)"
        if ($undo.HadValue) {
            Set-Item -LiteralPath $envPath -Value $undo.PreviousValue
        }
        else {
            Remove-Item -LiteralPath $envPath -ErrorAction SilentlyContinue
        }
    }
    $Stack.Clear()
}

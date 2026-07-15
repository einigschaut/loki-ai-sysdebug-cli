# tests/ask.Tests.ps1 -- Command `loki ask`: metadata, registry, guards, and engine-result -> exit-code mapping
# (CLAUDE.md section 5/6). The online engine (Invoke-LokiClaude) and the connectivity probe (Test-LokiConnectivity)
# are MOCKED so the command's WIRING is tested deterministically without a real `claude` install or network.
#
# Encapsulation note (see tests\doctor.Tests.ps1): Write-LokiWarn/Write-LokiErr write DIRECTLY via
# [Console]::Error.WriteLine (lib/ui.ps1), so [Console]::SetError() is redirected to a StringWriter to intercept
# them; Write-Host/Write-LokiOk/-Line/-Info/-Heading go through stream 6 (last pipeline element = the exit code).
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\i18n.ps1"
    . "$PSScriptRoot\..\src\lib\ui.ps1"
    . "$PSScriptRoot\..\src\lib\exitcodes.ps1"
    . "$PSScriptRoot\..\src\lib\config.ps1"
    . "$PSScriptRoot\..\src\lib\net.ps1"
    . "$PSScriptRoot\..\src\lib\allowlist.ps1"
    . "$PSScriptRoot\..\src\lib\auth.ps1"
    . "$PSScriptRoot\..\src\lib\env-isolate.ps1"
    . "$PSScriptRoot\..\src\lib\claude.ps1"
    . "$PSScriptRoot\..\src\lib\registry.ps1"
    . "$PSScriptRoot\..\src\commands\ask.ps1"
    Initialize-LokiUi -NoColor
    Initialize-LokiI18n -AppRoot (Resolve-Path "$PSScriptRoot\..\src").Path -Locale 'en' | Out-Null

    function global:New-TestAskContext {
        param([string[]]$AskArgs = @('why', 'is', 'dns', 'slow'), [hashtable]$Flags = @{})
        return @{ AppRoot = 'TestDrive:\nope'; Version = 'test'; Args = $AskArgs; Flags = $Flags; Registry = @() }
    }

    function global:Invoke-AskCommand {
        param([Parameter(Mandatory = $true)][hashtable]$Context)
        $swErr = New-Object System.IO.StringWriter
        $origErr = [Console]::Error
        [Console]::SetError($swErr)
        try {
            $raw = @(Invoke-LokiCmd_ask $Context 6>&1)
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
    Remove-Item Function:\New-TestAskContext -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-AskCommand -ErrorAction SilentlyContinue
}

Describe 'Command ask' {

    Context 'metadata & registry' {
        It 'metadata is complete (Name == file name, Group Online)' {
            $m = Get-LokiCmdMeta_ask
            $m.Name | Should -Be 'ask'
            $m.Summary | Should -Be 'ask.summary'
            $m.Usage | Should -Not -BeNullOrEmpty
            $m.Group | Should -Be 'Online'
        }

        It 'is consistently registered (meta + handler, ADR-0002 consistency gate)' {
            $reg = Get-LokiCommandRegistry
            $entry = $reg | Where-Object { $_.Name -eq 'ask' } | Select-Object -First 1
            $entry | Should -Not -BeNullOrEmpty
            $entry.Handler | Should -Be 'Invoke-LokiCmd_ask'
            (Get-Command -CommandType Function -Name $entry.Handler -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }

    Context 'guards (no engine call)' {

        BeforeEach {
            Mock Test-LokiConnectivity { $true }
            Mock Invoke-LokiClaude { @{ Ok = $true; Reason = 'ok'; Result = 'unused'; CostUsd = $null } }
        }

        It 'empty question -> Usage exit and never calls the engine' {
            $r = Invoke-AskCommand -Context (New-TestAskContext -AskArgs @())
            $r.Code | Should -Be (Get-LokiExitCode 'Usage')
            Should -Invoke Invoke-LokiClaude -Times 0
        }

        It 'offline -> NetworkRequired exit and never calls the engine' {
            Mock Test-LokiConnectivity { $false }
            $r = Invoke-AskCommand -Context (New-TestAskContext)
            $r.Code | Should -Be (Get-LokiExitCode 'NetworkRequired')
            Should -Invoke Invoke-LokiClaude -Times 0
        }
    }

    Context 'engine result -> exit code mapping (online, mocked engine)' {

        BeforeEach {
            Mock Test-LokiConnectivity { $true }
        }

        It 'success -> prints result + cost, exit Ok' {
            Mock Invoke-LokiClaude { @{ Ok = $true; Reason = 'ok'; Result = 'Your DNS server is unreachable.'; CostUsd = 0.0123; IsError = $false } }
            $r = Invoke-AskCommand -Context (New-TestAskContext)
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            $r.AllText | Should -BeLike '*Your DNS server is unreachable.*'
            $r.AllText | Should -BeLike '*0.0123*'
        }

        It 'auth-missing -> AuthMissing exit with a helpful message' {
            Mock Invoke-LokiClaude { @{ Ok = $false; Reason = 'auth-missing' } }
            $r = Invoke-AskCommand -Context (New-TestAskContext)
            $r.Code | Should -Be (Get-LokiExitCode 'AuthMissing')
            $r.AllText | Should -BeLike '*auth login*'
        }

        It 'claude-not-found -> GeneralError exit' {
            Mock Invoke-LokiClaude { @{ Ok = $false; Reason = 'claude-not-found' } }
            $r = Invoke-AskCommand -Context (New-TestAskContext)
            $r.Code | Should -Be (Get-LokiExitCode 'GeneralError')
            $r.AllText | Should -BeLike '*claude*'
        }

        It 'timeout -> GeneralError exit' {
            Mock Invoke-LokiClaude { @{ Ok = $false; Reason = 'timeout' } }
            $r = Invoke-AskCommand -Context (New-TestAskContext)
            $r.Code | Should -Be (Get-LokiExitCode 'GeneralError')
        }

        It 'engine-error -> GeneralError, raw stderr only with --verbose' {
            Mock Invoke-LokiClaude { @{ Ok = $false; Reason = 'engine-error'; ExitCode = 1; ErrorText = 'RAW-ENGINE-STDERR-XYZ' } }

            $quiet = Invoke-AskCommand -Context (New-TestAskContext)
            $quiet.Code | Should -Be (Get-LokiExitCode 'GeneralError')
            $quiet.AllText | Should -Not -BeLike '*RAW-ENGINE-STDERR-XYZ*'

            $verbose = Invoke-AskCommand -Context (New-TestAskContext -Flags @{ Verbose = $true })
            $verbose.AllText | Should -BeLike '*RAW-ENGINE-STDERR-XYZ*'
        }

        It 'always returns a stable known exit code' {
            Mock Invoke-LokiClaude { @{ Ok = $true; Reason = 'ok'; Result = 'ok'; CostUsd = $null } }
            $r = Invoke-AskCommand -Context (New-TestAskContext)
            @(
                (Get-LokiExitCode 'Ok'), (Get-LokiExitCode 'Usage'), (Get-LokiExitCode 'AuthMissing'),
                (Get-LokiExitCode 'NetworkRequired'), (Get-LokiExitCode 'GeneralError')
            ) | Should -Contain $r.Code
        }
    }
}

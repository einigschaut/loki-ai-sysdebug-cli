# tests/chat.Tests.ps1 -- Command `loki chat`: metadata, registry, guards, and interactive-result -> exit-code
# mapping (CLAUDE.md section 5/6). The interactive engine (Invoke-LokiClaudeInteractive) and the connectivity probe
# (Test-LokiConnectivity) are MOCKED so the command's WIRING is tested deterministically without a real terminal,
# `claude` install, or network. The interactive spawn itself is live-gated (ADR-0008).
#
# Encapsulation note (see tests\ask.Tests.ps1): Write-LokiWarn/Write-LokiErr write DIRECTLY via
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
    . "$PSScriptRoot\..\src\commands\chat.ps1"
    Initialize-LokiUi -NoColor
    Initialize-LokiI18n -AppRoot (Resolve-Path "$PSScriptRoot\..\src").Path -Locale 'en' | Out-Null

    function global:New-TestChatContext {
        param([hashtable]$Flags = @{})
        return @{ AppRoot = 'TestDrive:\nope'; Version = 'test'; Args = @(); Flags = $Flags; Registry = @() }
    }

    function global:Invoke-ChatCommand {
        param([Parameter(Mandatory = $true)][hashtable]$Context)
        $swErr = New-Object System.IO.StringWriter
        $origErr = [Console]::Error
        [Console]::SetError($swErr)
        try {
            $raw = @(Invoke-LokiCmd_chat $Context 6>&1)
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
    Remove-Item Function:\New-TestChatContext -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-ChatCommand -ErrorAction SilentlyContinue
}

Describe 'Command chat' {

    Context 'metadata & registry' {
        It 'metadata is complete (Name == file name, Group Online)' {
            $m = Get-LokiCmdMeta_chat
            $m.Name | Should -Be 'chat'
            $m.Summary | Should -Be 'chat.summary'
            $m.Usage | Should -Not -BeNullOrEmpty
            $m.Group | Should -Be 'Online'
        }

        It 'is consistently registered (meta + handler, ADR-0002 consistency gate)' {
            $reg = Get-LokiCommandRegistry
            $entry = $reg | Where-Object { $_.Name -eq 'chat' } | Select-Object -First 1
            $entry | Should -Not -BeNullOrEmpty
            $entry.Handler | Should -Be 'Invoke-LokiCmd_chat'
            (Get-Command -CommandType Function -Name $entry.Handler -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }

    Context 'guards (no engine spawn)' {

        BeforeEach {
            Mock Invoke-LokiClaudeInteractive { @{ Ok = $true; Reason = 'ok'; ExitCode = 0 } }
        }

        It 'offline -> NetworkRequired exit and never spawns the interactive engine' {
            Mock Test-LokiConnectivity { $false }
            $r = Invoke-ChatCommand -Context (New-TestChatContext)
            $r.Code | Should -Be (Get-LokiExitCode 'NetworkRequired')
            Should -Invoke Invoke-LokiClaudeInteractive -Times 0
        }
    }

    Context 'interactive result -> exit code mapping (mocked spawn)' {

        BeforeEach {
            Mock Test-LokiConnectivity { $true }
        }

        It 'session ran and exited cleanly (0) -> exit Ok' {
            Mock Invoke-LokiClaudeInteractive { @{ Ok = $true; Reason = 'ok'; ExitCode = 0 } }
            $r = Invoke-ChatCommand -Context (New-TestChatContext)
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            Should -Invoke Invoke-LokiClaudeInteractive -Times 1
        }

        It 'a non-zero session exit -> GeneralError, not silent success (adversarial regression)' {
            Mock Invoke-LokiClaudeInteractive { @{ Ok = $true; Reason = 'ok'; ExitCode = 1 } }
            $r = Invoke-ChatCommand -Context (New-TestChatContext)
            $r.Code | Should -Be (Get-LokiExitCode 'GeneralError')
        }

        It 'auth-missing -> AuthMissing exit with a helpful message' {
            Mock Invoke-LokiClaudeInteractive { @{ Ok = $false; Reason = 'auth-missing' } }
            $r = Invoke-ChatCommand -Context (New-TestChatContext)
            $r.Code | Should -Be (Get-LokiExitCode 'AuthMissing')
            $r.AllText | Should -BeLike '*auth login*'
        }

        It 'claude-not-found -> GeneralError exit' {
            Mock Invoke-LokiClaudeInteractive { @{ Ok = $false; Reason = 'claude-not-found' } }
            $r = Invoke-ChatCommand -Context (New-TestChatContext)
            $r.Code | Should -Be (Get-LokiExitCode 'GeneralError')
            $r.AllText | Should -BeLike '*claude*'
        }

        It 'cmd-shim-unsafe -> GeneralError exit with the actionable native-exe message (issue #58)' {
            Mock Invoke-LokiClaudeInteractive { @{ Ok = $false; Reason = 'cmd-shim-unsafe' } }
            $r = Invoke-ChatCommand -Context (New-TestChatContext)
            $r.Code | Should -Be (Get-LokiExitCode 'GeneralError')
            $r.AllText | Should -BeLike '*claude.exe*'
        }

        It 'a generic build failure -> GeneralError exit' {
            Mock Invoke-LokiClaudeInteractive { @{ Ok = $false; Reason = 'some-other-failure' } }
            $r = Invoke-ChatCommand -Context (New-TestChatContext)
            $r.Code | Should -Be (Get-LokiExitCode 'GeneralError')
        }

        It 'always returns a stable known exit code' {
            Mock Invoke-LokiClaudeInteractive { @{ Ok = $true; Reason = 'ok'; ExitCode = 0 } }
            $r = Invoke-ChatCommand -Context (New-TestChatContext)
            @(
                (Get-LokiExitCode 'Ok'), (Get-LokiExitCode 'AuthMissing'),
                (Get-LokiExitCode 'NetworkRequired'), (Get-LokiExitCode 'GeneralError')
            ) | Should -Contain $r.Code
        }
    }
}

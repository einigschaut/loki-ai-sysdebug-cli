# tests/setup.Tests.ps1 -- Command `loki setup`: metadata, routing, selection, exit codes (CLAUDE.md section 5/6).
# The real network fetch is never touched: Test-LokiConnectivity and Invoke-LokiVerifiedDownload are Mocked, so the
# tests exercise the command's wiring (manifest -> selection -> plan -> per-file verify -> exit) against the REAL
# src/models/manifest.psd1, without downloading anything.
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\i18n.ps1"
    . "$PSScriptRoot\..\src\lib\ui.ps1"
    . "$PSScriptRoot\..\src\lib\exitcodes.ps1"
    . "$PSScriptRoot\..\src\lib\net.ps1"
    . "$PSScriptRoot\..\src\lib\models.ps1"
    . "$PSScriptRoot\..\src\lib\registry.ps1"
    . "$PSScriptRoot\..\src\commands\setup.ps1"
    Initialize-LokiUi -NoColor
    $script:SrcRoot = (Resolve-Path "$PSScriptRoot\..\src").Path
    Initialize-LokiI18n -AppRoot $script:SrcRoot -Locale 'en' | Out-Null

    function global:New-TestSetupContext {
        param([string[]]$CmdArgs = @())
        return @{ AppRoot = $script:SrcRoot; Version = 'test'; Args = $CmdArgs; Flags = @{}; Registry = @() }
    }

    function global:Invoke-SetupCommand {
        param([Parameter(Mandatory = $true)][hashtable]$Context)
        $swErr = New-Object System.IO.StringWriter
        $origErr = [Console]::Error
        [Console]::SetError($swErr)
        try { $raw = @(Invoke-LokiCmd_setup $Context 6>&1) }
        finally { [Console]::SetError($origErr) }
        $code = [int]($raw | Select-Object -Last 1)
        $lineCount = [Math]::Max(0, $raw.Count - 1)
        $stdText = (@($raw | Select-Object -First $lineCount) | Out-String)
        $errText = $swErr.ToString()
        [pscustomobject]@{ Code = $code; Text = $stdText; ErrText = $errText; AllText = ($stdText + $errText) }
    }
}

AfterAll {
    Remove-Item Function:\New-TestSetupContext -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-SetupCommand -ErrorAction SilentlyContinue
}

Describe 'Command setup' {

    BeforeAll {
        # Online by default; no real download ever happens.
        Mock Test-LokiConnectivity { $true }
        Mock Invoke-LokiVerifiedDownload { @{ Ok = $true; Reason = 'verified' } }
    }

    Context 'metadata & registry' {
        It 'metadata is complete (Name == file name, Group Setup)' {
            $m = Get-LokiCmdMeta_setup
            $m.Name | Should -Be 'setup'
            $m.Group | Should -Be 'Setup'
            $m.Summary | Should -Not -BeNullOrEmpty
            $m.Usage | Should -Not -BeNullOrEmpty
        }
        It 'is consistently registered (meta + handler, ADR-0002)' {
            $entry = Get-LokiCommandRegistry | Where-Object { $_.Name -eq 'setup' } | Select-Object -First 1
            $entry | Should -Not -BeNullOrEmpty
            $entry.Handler | Should -Be 'Invoke-LokiCmd_setup'
        }
    }

    Context 'routing, selection & exit codes' {
        It 'offline -> NetworkRequired' {
            Mock Test-LokiConnectivity { $false }
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @('--tier', 'default'))
            $r.Code | Should -Be (Get-LokiExitCode 'NetworkRequired')
        }

        It '--tier default -> Ok, downloads exactly the default model' {
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @('--tier', 'default'))
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            Should -Invoke Invoke-LokiVerifiedDownload -Times 1 -Exactly
            Should -Invoke Invoke-LokiVerifiedDownload -Times 1 -Exactly -ParameterFilter { $DestPath -like '*Qwen3-4B-Instruct-2507-Q4_K_M.gguf' }
        }

        It '--tier small,mid -> downloads two models' {
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @('--tier', 'small,mid'))
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            Should -Invoke Invoke-LokiVerifiedDownload -Times 2 -Exactly
        }

        It '--tier all -> downloads every catalog model' {
            $count = (Get-LokiModelManifest -Path (Join-Path $script:SrcRoot 'models\manifest.psd1')).Count
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @('--tier', 'all'))
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            Should -Invoke Invoke-LokiVerifiedDownload -Times $count -Exactly
        }

        It 'an unknown tier id -> Usage, downloads nothing' {
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @('--tier', 'banana'))
            $r.Code | Should -Be (Get-LokiExitCode 'Usage')
            Should -Invoke Invoke-LokiVerifiedDownload -Times 0 -Exactly
        }

        It 'a verification failure -> GeneralError' {
            Mock Invoke-LokiVerifiedDownload { @{ Ok = $false; Reason = 'hash-mismatch' } }
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @('--tier', 'default'))
            $r.Code | Should -Be (Get-LokiExitCode 'GeneralError')
        }

        It 'interactive picker: choosing "default" downloads the default model' {
            Mock Read-Host { 'default' }
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @())
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            Should -Invoke Invoke-LokiVerifiedDownload -Times 1 -Exactly
        }

        It 'interactive picker: empty selection -> Ok, downloads nothing' {
            Mock Read-Host { '' }
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @())
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            Should -Invoke Invoke-LokiVerifiedDownload -Times 0 -Exactly
        }

        It 'the catalog is shown with sizes so the user can pick to fit the stick' {
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @('--tier', 'default'))
            $r.AllText | Should -BeLike '*GB*'
            $r.AllText | Should -BeLike '*Qwen3-4B-Instruct-2507*'
        }
    }
}

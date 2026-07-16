# tests/setup.Tests.ps1 -- Command `loki setup`: metadata, routing, selection, engine step, exit codes
# (CLAUDE.md section 5/6, ADR-0011/0012). The real network and the real disk are never touched:
# Test-LokiConnectivity, Invoke-LokiVerifiedDownload, Expand-LokiVerifiedArchive and the runtime staging are Mocked,
# so the tests exercise the command's wiring (selection -> engine -> runtime -> models -> exit) against the REAL
# src/models/manifest.psd1 + src/engine/manifest.psd1, without downloading or writing anything.
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\i18n.ps1"
    . "$PSScriptRoot\..\src\lib\ui.ps1"
    . "$PSScriptRoot\..\src\lib\exitcodes.ps1"
    . "$PSScriptRoot\..\src\lib\net.ps1"
    . "$PSScriptRoot\..\src\lib\download.ps1"
    . "$PSScriptRoot\..\src\lib\models.ps1"
    . "$PSScriptRoot\..\src\lib\engine.ps1"
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
        # Online by default; no real download, no real unpack, no real staging ever happens.
        Mock Test-LokiConnectivity { $true }
        Mock Invoke-LokiVerifiedDownload { @{ Ok = $true; Reason = 'verified' } }
        Mock Expand-LokiVerifiedArchive { @{ Ok = $true; Reason = 'expanded'; Count = 51; Pruned = 0 } }
        Mock Get-LokiVcRuntimeStatus { @{ Present = $false; Found = @(); Missing = @('VCRUNTIME140.dll') } }
        Mock Copy-LokiVcRuntimeAppLocal { @{ Ok = $true; Reason = 'staged'; Staged = @('VCRUNTIME140.dll'); Version = '14.51.36247.0' } }
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
            Should -Invoke Invoke-LokiVerifiedDownload -Times 1 -Exactly -ParameterFilter { $DestPath -like '*.gguf' }
            Should -Invoke Invoke-LokiVerifiedDownload -Times 1 -Exactly -ParameterFilter { $DestPath -like '*Qwen3-4B-Instruct-2507-Q4_K_M.gguf' }
        }

        It '--tier small,mid -> downloads two models' {
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @('--tier', 'small,mid'))
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            Should -Invoke Invoke-LokiVerifiedDownload -Times 2 -Exactly -ParameterFilter { $DestPath -like '*.gguf' }
        }

        It '--tier all -> downloads every catalog model' {
            $count = (Get-LokiModelManifest -Path (Join-Path $script:SrcRoot 'models\manifest.psd1')).Count
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @('--tier', 'all'))
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            Should -Invoke Invoke-LokiVerifiedDownload -Times $count -Exactly -ParameterFilter { $DestPath -like '*.gguf' }
        }

        It 'an unknown tier id -> Usage, and NOTHING is downloaded (selection is validated before any work)' {
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @('--tier', 'banana'))
            $r.Code | Should -Be (Get-LokiExitCode 'Usage')
            Should -Invoke Invoke-LokiVerifiedDownload -Times 0 -Exactly
        }

        It 'a model verification failure -> GeneralError' {
            Mock Invoke-LokiVerifiedDownload { @{ Ok = $false; Reason = 'hash-mismatch' } } -ParameterFilter { $DestPath -like '*.gguf' }
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @('--tier', 'default'))
            $r.Code | Should -Be (Get-LokiExitCode 'GeneralError')
        }

        It 'interactive picker: choosing "default" downloads the default model' {
            Mock Read-Host { 'default' }
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @())
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            Should -Invoke Invoke-LokiVerifiedDownload -Times 1 -Exactly -ParameterFilter { $DestPath -like '*.gguf' }
        }

        It 'interactive picker: empty selection -> Ok, engine only, no model downloaded' {
            Mock Read-Host { '' }
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @())
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            Should -Invoke Invoke-LokiVerifiedDownload -Times 0 -Exactly -ParameterFilter { $DestPath -like '*.gguf' }
            Should -Invoke Invoke-LokiVerifiedDownload -Times 1 -Exactly -ParameterFilter { $DestPath -like '*.zip' }
        }

        It 'the catalog is shown with sizes so the user can pick to fit the stick' {
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @('--tier', 'default'))
            $r.AllText | Should -BeLike '*GB*'
            $r.AllText | Should -BeLike '*Qwen3-4B-Instruct-2507*'
        }
    }

    Context 'engine step (ADR-0012)' {
        It 'always fetches + verifies + unpacks the engine, even when only a model was asked for' {
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @('--tier', 'default'))
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            Should -Invoke Invoke-LokiVerifiedDownload -Times 1 -Exactly -ParameterFilter { $DestPath -like '*engine-offline\llama-*-bin-win-cpu-x64.zip' }
            Should -Invoke Expand-LokiVerifiedArchive -Times 1 -Exactly
        }

        It 'probes github (engine host) not just huggingface, so a network that blocks one says which' {
            Should -Invoke Test-LokiConnectivity -Times 0   # reset guard: assertions below are what matters
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @('--tier', 'default'))
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            Should -Invoke Test-LokiConnectivity -Times 1 -Exactly -ParameterFilter { $TargetHost -eq 'github.com' }
            Should -Invoke Test-LokiConnectivity -Times 1 -Exactly -ParameterFilter { $TargetHost -eq 'huggingface.co' }
        }

        It 'an engine download failure -> GeneralError and no model is fetched afterwards' {
            Mock Invoke-LokiVerifiedDownload { @{ Ok = $false; Reason = 'hash-mismatch' } } -ParameterFilter { $DestPath -like '*.zip' }
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @('--tier', 'default'))
            $r.Code | Should -Be (Get-LokiExitCode 'GeneralError')
            Should -Invoke Invoke-LokiVerifiedDownload -Times 0 -Exactly -ParameterFilter { $DestPath -like '*.gguf' }
        }

        It 'BREAK-THE-GUARD: an engine that cannot be unpacked -> GeneralError, no models fetched' {
            Mock Expand-LokiVerifiedArchive { @{ Ok = $false; Reason = 'unsafe-entry'; Entry = '../evil' } }
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @('--tier', 'default'))
            $r.Code | Should -Be (Get-LokiExitCode 'GeneralError')
            Should -Invoke Invoke-LokiVerifiedDownload -Times 0 -Exactly -ParameterFilter { $DestPath -like '*.gguf' }
        }
    }

    Context 'runtime staging (--stage-runtime, ADR-0012)' {
        It 'REGRESSION: a staged runtime BELOW the floor is warned about, not blessed with a green check' {
            # Both adversarial reviewers found this independently: the staging path refuses <14.30, but the reporting
            # path used presence alone, so the same too-old runtime was reported fine -> cryptic loader failure later.
            Mock Get-LokiVcRuntimeStatus { @{ Present = $true; Found = @([pscustomobject]@{ File = 'VCRUNTIME140.dll'; Path = 'x'; Version = '14.0.24215.1' }); Missing = @() } }
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @('--tier', 'default'))
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            $r.AllText | Should -BeLike '*14.30*'
            $r.AllText | Should -Not -BeLike '*already staged*'
        }

        It 'a staged runtime at or above the floor is reported present, with its version' {
            Mock Get-LokiVcRuntimeStatus { @{ Present = $true; Found = @([pscustomobject]@{ File = 'VCRUNTIME140.dll'; Path = 'x'; Version = '14.51.36247.0' }); Missing = @() } }
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @('--tier', 'default'))
            $r.AllText | Should -BeLike '*already staged*'
            $r.AllText | Should -BeLike '*14.51.36247.0*'
        }

        It 'the reconcile is told to preserve the staged runtime (it is not in the archive)' {
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @('--tier', 'default'))
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            Should -Invoke Expand-LokiVerifiedArchive -Times 1 -Exactly -ParameterFilter { @($PreserveNames) -contains 'MSVCP140.dll' }
        }

        It 'does NOT touch Microsoft files unless asked' {
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @('--tier', 'default'))
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            Should -Invoke Copy-LokiVcRuntimeAppLocal -Times 0 -Exactly
            $r.AllText | Should -BeLike '*--stage-runtime*'   # but it does tell the operator the option exists
        }

        It '--stage-runtime is a flag, not a tier id (regression: it must not reach the selection parser)' {
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @('--tier', 'default', '--stage-runtime'))
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            Should -Invoke Copy-LokiVcRuntimeAppLocal -Times 1 -Exactly
        }

        It 'stages from this machine System32 -- never from a caller-supplied path' {
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @('--tier', 'default', '--stage-runtime'))
            $r.Code | Should -Be (Get-LokiExitCode 'Ok')
            Should -Invoke Copy-LokiVcRuntimeAppLocal -Times 1 -Exactly -ParameterFilter { $SourceDir -eq (Join-Path $env:SystemRoot 'System32') }
        }

        It 'prints the Microsoft license notice when staging (we copy their files, we do not ship them)' {
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @('--tier', 'default', '--stage-runtime'))
            $r.AllText | Should -BeLike '*Microsoft*'
        }

        It 'BREAK-THE-GUARD: a refused staging (<reason>) -> GeneralError, no models fetched' -ForEach @(
            @{ reason = 'source-missing'; res = @{ Ok = $false; Reason = 'source-missing'; Missing = @('MSVCP140.dll') } }
            @{ reason = 'too-old'; res = @{ Ok = $false; Reason = 'too-old'; Version = '14.0'; MinVersion = '14.30' } }
            @{ reason = 'version-unreadable'; res = @{ Ok = $false; Reason = 'version-unreadable'; File = 'MSVCP140.dll' } }
            @{ reason = 'copy-failed'; res = @{ Ok = $false; Reason = 'copy-failed'; File = 'MSVCP140.dll'; Error = 'denied' } }
        ) {
            Mock Copy-LokiVcRuntimeAppLocal { $res }
            $r = Invoke-SetupCommand -Context (New-TestSetupContext -CmdArgs @('--tier', 'default', '--stage-runtime'))
            $r.Code | Should -Be (Get-LokiExitCode 'GeneralError')
            Should -Invoke Invoke-LokiVerifiedDownload -Times 0 -Exactly -ParameterFilter { $DestPath -like '*.gguf' }
        }
    }
}

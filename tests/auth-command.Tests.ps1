# tests/auth-command.Tests.ps1 — Command `loki auth`: routing, exit codes, secret handling (CLAUDE.md §5/§6).
#
# Scaffold deviation (documented in src\commands\auth.ps1): `build\New-LokiCommand.ps1 auth` would
# want to generate tests\auth.Tests.ps1 -- that already exists as the lib test for src\lib\auth.ps1
# (name collision: command name == lib module name). The command tests therefore live here, under
# tests\auth-command.Tests.ps1, otherwise identical to the usual scaffold test pattern.
#
# Encapsulation note: Write-LokiWarn/Write-LokiErr write DIRECTLY via [Console]::Error.WriteLine
# (see lib/ui.ps1) and NOT via the PowerShell error/warning stream -- a plain stream redirect
# (2>&1 / 6>&1) therefore doesn't catch them (see also tests\ui.Tests.ps1: only "doesn't throw" is checked there).
# For text assertions on warn/err, [Console]::SetError() is therefore redirected to a
# StringWriter during the call (real in-process interception); Write-Host/Write-LokiOk/-Line go through stream 6
# and are merged into the success pipeline via 6>&1 (last element = the handler's return exit code).
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\i18n.ps1"
    . "$PSScriptRoot\..\src\lib\ui.ps1"
    . "$PSScriptRoot\..\src\lib\exitcodes.ps1"
    . "$PSScriptRoot\..\src\lib\config.ps1"
    . "$PSScriptRoot\..\src\lib\auth.ps1"
    . "$PSScriptRoot\..\src\lib\registry.ps1"
    . "$PSScriptRoot\..\src\commands\auth.ps1"
    Initialize-LokiUi -NoColor
    Initialize-LokiI18n -AppRoot (Resolve-Path "$PSScriptRoot\..\src").Path -Locale 'en' | Out-Null

    $script:RootTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("loki-authcmd-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:RootTmp | Out-Null

    $script:FakeSecret = 'sk-test-1234567890abcd'

    # Builds a [securestring] from plaintext WITHOUT ConvertTo-SecureString -AsPlainText (PSAvoidUsingConvertToSecureStringWithPlainText).
    # Only for fake test values -- pattern taken from tests\auth.Tests.ps1.
    $script:NewSecure = {
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Plain)
        $ss = New-Object System.Security.SecureString
        foreach ($ch in $Plain.ToCharArray()) { $ss.AppendChar($ch) }
        $ss.MakeReadOnly()
        $ss
    }

    # New, isolated temp AppRoot (with home\ subfolder) per test case -- all live under $script:RootTmp
    # and are removed together in AfterAll.
    function global:New-TestAppRoot {
        $root = Join-Path $script:RootTmp ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'home') | Out-Null
        return $root
    }

    function global:New-TestAuthContext {
        param([Parameter(Mandatory = $true)][string]$AppRoot, [string[]]$CmdArgs = @())
        return @{ AppRoot = $AppRoot; Version = 'test'; Args = $CmdArgs; Flags = @{}; Registry = @() }
    }

    # Calls Invoke-LokiCmd_auth and returns exit code, Write-Host text (stream 6), and stderr text separately.
    function global:Invoke-AuthCommand {
        param([Parameter(Mandatory = $true)][hashtable]$Context)

        $swErr = New-Object System.IO.StringWriter
        $origErr = [Console]::Error
        [Console]::SetError($swErr)
        try {
            $raw = @(Invoke-LokiCmd_auth $Context 6>&1)
        }
        finally {
            [Console]::SetError($origErr)
        }

        $code = [int]($raw | Select-Object -Last 1)
        $lineCount = [Math]::Max(0, $raw.Count - 1)
        $lines = @($raw | Select-Object -First $lineCount)
        $stdText = ($lines | Out-String)
        $errText = $swErr.ToString()

        [pscustomobject]@{ Code = $code; Text = $stdText; ErrText = $errText }
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:RootTmp) { Remove-Item -LiteralPath $script:RootTmp -Recurse -Force }
    Remove-Item Function:\New-TestAppRoot -ErrorAction SilentlyContinue
    Remove-Item Function:\New-TestAuthContext -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-AuthCommand -ErrorAction SilentlyContinue
}

Describe 'Command auth - metadata & registry' {

    It 'metadata is complete (Name == file name)' {
        $m = Get-LokiCmdMeta_auth
        $m.Name | Should -Be 'auth'
        $m.Summary | Should -Not -BeNullOrEmpty
        $m.Usage | Should -Not -BeNullOrEmpty
        $m.Group | Should -Not -BeNullOrEmpty
    }

    It 'handler is defined and returns an exit code' {
        (Get-Command Invoke-LokiCmd_auth -CommandType Function) | Should -Not -BeNullOrEmpty
        $ctx = New-TestAuthContext -AppRoot (New-TestAppRoot) -CmdArgs @('status')
        $code = Invoke-LokiCmd_auth $ctx *>$null
        ([int]$code) | Should -BeOfType [int]
    }

    It 'is consistently registered via Get-LokiCommandRegistry (meta + handler, ADR-0002 consistency gate)' {
        $reg = Get-LokiCommandRegistry
        $entry = $reg | Where-Object { $_.Name -eq 'auth' } | Select-Object -First 1
        $entry | Should -Not -BeNullOrEmpty
        $entry.Handler | Should -Be 'Invoke-LokiCmd_auth'
        (Get-Command -CommandType Function -Name $entry.Handler -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
}

Describe 'Command auth - routing & exit codes' {

    It 'without sub-command -> exit Usage' {
        $ctx = New-TestAuthContext -AppRoot (New-TestAppRoot) -CmdArgs @()
        $r = Invoke-AuthCommand -Context $ctx
        $r.Code | Should -Be (Get-LokiExitCode 'Usage')
    }

    It 'unknown sub-command -> exit Usage' {
        $ctx = New-TestAuthContext -AppRoot (New-TestAppRoot) -CmdArgs @('bogus')
        $r = Invoke-AuthCommand -Context $ctx
        $r.Code | Should -Be (Get-LokiExitCode 'Usage')
    }

    It 'status without secret -> exit Ok, warning "No secret set"' {
        $approot = New-TestAppRoot
        $ctx = New-TestAuthContext -AppRoot $approot -CmdArgs @('status')
        $r = Invoke-AuthCommand -Context $ctx
        $r.Code | Should -Be (Get-LokiExitCode 'Ok')
        $r.ErrText | Should -BeLike '*No secret set*'

        # Direct lib check (independent of the text output): Present must be false.
        $st = Get-LokiAuthStatus -EnvFilePath (Join-Path $approot 'home\.env') -Config @{}
        $st.Present | Should -BeFalse
    }

    It 'use api -> exit Ok, writes AuthMethod to loki.config.json' {
        $approot = New-TestAppRoot
        $ctx = New-TestAuthContext -AppRoot $approot -CmdArgs @('use', 'api')
        $r = Invoke-AuthCommand -Context $ctx
        $r.Code | Should -Be (Get-LokiExitCode 'Ok')

        $configPath = Join-Path $approot 'loki.config.json'
        Test-Path -LiteralPath $configPath | Should -BeTrue
        $cfg = Read-LokiConfig -Path $configPath
        $cfg['AuthMethod'] | Should -Be 'api'
    }

    It 'use sub -> exit Ok, writes AuthMethod=sub to loki.config.json' {
        $approot = New-TestAppRoot
        $ctx = New-TestAuthContext -AppRoot $approot -CmdArgs @('use', 'sub')
        $r = Invoke-AuthCommand -Context $ctx
        $r.Code | Should -Be (Get-LokiExitCode 'Ok')

        $cfg = Read-LokiConfig -Path (Join-Path $approot 'loki.config.json')
        $cfg['AuthMethod'] | Should -Be 'sub'
    }

    It 'use preserves other existing config keys when writing' {
        $approot = New-TestAppRoot
        $configPath = Join-Path $approot 'loki.config.json'
        Write-LokiConfig -Path $configPath -Config @{ engine = 'cloud' }

        $ctx = New-TestAuthContext -AppRoot $approot -CmdArgs @('use', 'api')
        (Invoke-AuthCommand -Context $ctx).Code | Should -Be (Get-LokiExitCode 'Ok')

        $cfg = Read-LokiConfig -Path $configPath
        $cfg['engine'] | Should -Be 'cloud'
        $cfg['AuthMethod'] | Should -Be 'api'
    }

    It 'use without sub-arg -> exit Usage' {
        $ctx = New-TestAuthContext -AppRoot (New-TestAppRoot) -CmdArgs @('use')
        $r = Invoke-AuthCommand -Context $ctx
        $r.Code | Should -Be (Get-LokiExitCode 'Usage')
    }

    It 'use with invalid sub-arg -> exit Usage' {
        $ctx = New-TestAuthContext -AppRoot (New-TestAppRoot) -CmdArgs @('use', 'foo')
        $r = Invoke-AuthCommand -Context $ctx
        $r.Code | Should -Be (Get-LokiExitCode 'Usage')
    }

    It 'set (Read-Host mocked, no real secret) -> exit Ok, secret afterwards Present=true' {
        Mock Read-Host {
            $ss = New-Object System.Security.SecureString
            foreach ($ch in $script:FakeSecret.ToCharArray()) { $ss.AppendChar($ch) }
            $ss.MakeReadOnly()
            return $ss
        }

        $approot = New-TestAppRoot
        $envPath = Join-Path $approot 'home\.env'
        $ctx = New-TestAuthContext -AppRoot $approot -CmdArgs @('set')
        $r = Invoke-AuthCommand -Context $ctx
        $r.Code | Should -Be (Get-LokiExitCode 'Ok')

        $status = Get-LokiAuthStatus -EnvFilePath $envPath -Config @{}
        $status.Present | Should -BeTrue
        Read-LokiSecret -EnvFilePath $envPath | Should -Be $script:FakeSecret
    }

    It 'clear -> removes LOKI_SECRET, Read-LokiSecret afterwards $null' {
        $approot = New-TestAppRoot
        $envPath = Join-Path $approot 'home\.env'
        $secure = & $script:NewSecure $script:FakeSecret
        Set-LokiSecret -EnvFilePath $envPath -SecureValue $secure
        Read-LokiSecret -EnvFilePath $envPath | Should -Be $script:FakeSecret

        $ctx = New-TestAuthContext -AppRoot $approot -CmdArgs @('clear')
        $r = Invoke-AuthCommand -Context $ctx
        $r.Code | Should -Be (Get-LokiExitCode 'Ok')
        Read-LokiSecret -EnvFilePath $envPath | Should -Be $null
    }

    It 'login -> non-null exit + warning (online engine only lands in F2, no fake login)' {
        $ctx = New-TestAuthContext -AppRoot (New-TestAppRoot) -CmdArgs @('login')
        $r = Invoke-AuthCommand -Context $ctx
        $r.Code | Should -Not -Be (Get-LokiExitCode 'Ok')
        $r.Code | Should -Be (Get-LokiExitCode 'GeneralError')
        $r.ErrText | Should -BeLike '*online engine*'
    }
}

Describe 'Command auth - security: no raw secret in status output' {

    It 'status reports Present + masks the value but NEVER contains the raw secret' {
        $approot = New-TestAppRoot
        $envPath = Join-Path $approot 'home\.env'
        $secure = & $script:NewSecure $script:FakeSecret
        Set-LokiSecret -EnvFilePath $envPath -SecureValue $secure

        $ctx = New-TestAuthContext -AppRoot $approot -CmdArgs @('status')
        $r = Invoke-AuthCommand -Context $ctx

        $r.Code | Should -Be (Get-LokiExitCode 'Ok')
        $r.Text | Should -BeLike '*sk-...abcd*'
        $r.Text.Contains($script:FakeSecret) | Should -BeFalse
        $r.ErrText.Contains($script:FakeSecret) | Should -BeFalse
    }
}

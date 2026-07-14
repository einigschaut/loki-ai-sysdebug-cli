# commands/auth.ps1 — `loki auth <status|use|set|clear|login>`
# Metadata (Get-LokiCmdMeta_auth) is the single source of truth; handler (Invoke-LokiCmd_auth) executes it. ADR-0002.
#
# Scaffold deviation (deliberate, documented -- CLAUDE.md §9 "scope creep -> ADR or ask, never silently"):
# `build\New-LokiCommand.ps1 -Name auth ...` would try to generate tests\auth.Tests.ps1. That file already exists
# as the LIB test for src\lib\auth.ps1 (auth variable & secret handling) -> name collision, because the
# command name happens to match the lib module name. The scaffold would either have overwritten the existing
# lib test (data loss, only possible with -Force) or refused outright -- both wrong.
# So: this file was created by hand, STRUCTURALLY IDENTICAL to the scaffold output (meta+handler function pair,
# same comment/form conventions as commands\status.ps1 / commands\version.ps1). The command tests
# live under tests\auth-command.Tests.ps1 to avoid the collision with the existing lib test.
Set-StrictMode -Version Latest

function Get-LokiCmdMeta_auth {
    @{
        Name     = 'auth'
        Group    = 'Setup'
        Summary  = 'auth.summary'
        Usage    = 'loki auth <status|use|set|clear|login>'
        Examples = @('loki auth status', 'loki auth use api', 'loki auth set')
        Flags    = @()
    }
}

function Invoke-LokiCmd_auth {
    param($Context)

    # Paths from the dispatcher context (CLAUDE.md contract): AppRoot = directory of loki.ps1 (= StickRoot).
    $configPath = Join-Path $Context.AppRoot 'loki.config.json'
    $envPath = Join-Path $Context.AppRoot 'home\.env'

    $verb = $null
    if ($Context.Args.Count -gt 0) { $verb = [string]$Context.Args[0] }

    if ($verb -eq 'status') {
        $cfg = Read-LokiConfig -Path $configPath
        $st = Get-LokiAuthStatus -EnvFilePath $envPath -Config $cfg

        Write-LokiHeading 'loki auth status'
        Write-LokiLine ("{0,-14} {1}" -f (Get-LokiText 'auth.status.method'), $st.Method)
        Write-LokiLine ("{0,-14} {1}" -f (Get-LokiText 'auth.status.variable'), $st.VarName)
        if ($st.Present) {
            # NEVER print the raw secret -- $st.Masked already comes masked from Get-LokiAuthStatus (CLAUDE.md §5).
            Write-LokiOk (Get-LokiText 'auth.status.secretSet' -ArgumentList @($st.Masked))
        }
        else {
            Write-LokiWarn (Get-LokiText 'auth.status.secretUnset')
        }
        return (Get-LokiExitCode 'Ok')
    }

    if ($verb -eq 'use') {
        $sub = $null
        if ($Context.Args.Count -gt 1) { $sub = ([string]$Context.Args[1]).Trim().ToLowerInvariant() }

        if (($sub -ne 'api') -and ($sub -ne 'sub')) {
            Write-LokiErr (Get-LokiText 'auth.use.invalid')
            Write-LokiLine (Get-LokiText 'auth.use.usage')
            return (Get-LokiExitCode 'Usage')
        }

        $cfg = Read-LokiConfig -Path $configPath
        $cfg['AuthMethod'] = $sub
        Write-LokiConfig -Path $configPath -Config $cfg
        Write-LokiOk (Get-LokiText 'auth.use.set' -ArgumentList @($sub))
        return (Get-LokiExitCode 'Ok')
    }

    if ($verb -eq 'set') {
        # Secret NEVER via argv -- interactive, hidden input directly as SecureString (CLAUDE.md §5).
        $sec = Read-Host -AsSecureString -Prompt (Get-LokiText 'auth.set.prompt')
        Set-LokiSecret -EnvFilePath $envPath -SecureValue $sec
        Write-LokiOk (Get-LokiText 'auth.set.saved')
        return (Get-LokiExitCode 'Ok')
    }

    if ($verb -eq 'clear') {
        Clear-LokiSecret -EnvFilePath $envPath
        Write-LokiOk (Get-LokiText 'auth.clear.removed')
        return (Get-LokiExitCode 'Ok')
    }

    if ($verb -eq 'login') {
        # The online login flow (Claude engine, setup token) only lands in F2 (docs/DESIGN.md) -- do NOT
        # fake it here (CLAUDE.md §9: marking a stub/TODO as "done" is forbidden). Exit code choice: none of the
        # existing names fit exactly -- 'AuthMissing' would be wrong (it's not a missing secret, but the
        # missing engine wiring), 'NetworkRequired' would be misleading (not a connectivity issue), and
        # 'OfflineEngineMissing' is semantically the opposite (here the ONLINE engine wiring is missing, not the
        # offline engine). Hence the deliberate, generic 'GeneralError' -- don't fake a special case that doesn't
        # exist (yet) instead of abusing a wrongly-fitting name.
        Write-LokiWarn (Get-LokiText 'auth.login.deferred')
        return (Get-LokiExitCode 'GeneralError')
    }

    if ([string]::IsNullOrEmpty($verb)) {
        Write-LokiErr (Get-LokiText 'auth.missingSub')
    }
    else {
        Write-LokiErr (Get-LokiText 'auth.unknownSub' -ArgumentList @($verb))
    }
    Write-LokiLine (Get-LokiText 'auth.usage')
    return (Get-LokiExitCode 'Usage')
}

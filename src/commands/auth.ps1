# commands/auth.ps1 — `loki auth <login|status|use|set|clear>`
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
        Usage    = 'loki auth <login|status|use|set|clear>'
        Examples = @('loki auth login', 'loki auth login sub', 'loki auth login api', 'loki auth status')
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
        # THE single onboarding door (ADR-0009, gh-`auth login` style). Pick the method, then land exactly ONE
        # credential on the stick. `use`/`set`/`clear` remain as scriptable advanced primitives (kept out of the main
        # help). Method precedence: an explicit 2nd arg (`sub`/`api`, also `--sub`/`--api`) skips the chooser; else ask.
        $methodArg = $null
        if ($Context.Args.Count -gt 1) {
            $methodArg = ([string]$Context.Args[1]).Trim().TrimStart('-').ToLowerInvariant()
        }

        $method = $null
        if ($methodArg -eq 'api' -or $methodArg -eq 'console') { $method = 'api' }
        elseif ($methodArg -eq 'sub' -or $methodArg -eq 'claudeai' -or $methodArg -eq 'subscription') { $method = 'sub' }
        elseif (-not [string]::IsNullOrEmpty($methodArg)) {
            Write-LokiErr (Get-LokiText 'auth.login.badMethod')
            Write-LokiLine (Get-LokiText 'auth.login.usage')
            return (Get-LokiExitCode 'Usage')
        }
        else {
            # Interactive chooser (rudimentary MVP UI on purpose -- a richer prompt is a later-version item).
            Write-LokiLine (Get-LokiText 'auth.login.chooseHeading')
            Write-LokiLine (Get-LokiText 'auth.login.optSub')
            Write-LokiLine (Get-LokiText 'auth.login.optApi')
            $choice = ([string](Read-Host -Prompt (Get-LokiText 'auth.login.choosePrompt'))).Trim().ToLowerInvariant()
            if ($choice -eq '1' -or $choice -eq 'sub' -or $choice -eq 's') { $method = 'sub' }
            elseif ($choice -eq '2' -or $choice -eq 'api' -or $choice -eq 'a') { $method = 'api' }
            else {
                Write-LokiErr (Get-LokiText 'auth.login.badMethod')
                return (Get-LokiExitCode 'Usage')
            }
        }

        if ($method -eq 'sub') {
            # Subscription: launch the real browser sign-in INLINE (`claude setup-token`) under Loki's env isolation,
            # then collect the token it prints through the SAME hidden SecureString path as the API key. Loki launches
            # the flow but NEVER captures/parses the token itself (secret only via SecureString, CLAUDE.md §5).
            Write-LokiInfo (Get-LokiText 'auth.login.subLaunch')
            $res = Invoke-LokiClaudeSetupToken -AppRoot $Context.AppRoot
            if (-not $res.Ok) {
                if ($res.Reason -eq 'claude-not-found') {
                    Write-LokiErr (Get-LokiText 'auth.login.engineMissing')
                    return (Get-LokiExitCode 'GeneralError')
                }
                Write-LokiErr (Get-LokiText 'auth.login.subFailed')
                return (Get-LokiExitCode 'GeneralError')
            }
            if (($null -ne $res.ExitCode) -and ([int]$res.ExitCode -ne 0)) {
                # setup-token aborted or errored -> no token was generated. Do not prompt for a paste; change nothing.
                Write-LokiErr (Get-LokiText 'auth.login.subFailed')
                return (Get-LokiExitCode 'GeneralError')
            }
            Write-LokiInfo (Get-LokiText 'auth.login.pasteHint')
            $prompt = Get-LokiText 'auth.login.prompt'
            $done = Get-LokiText 'auth.login.done'
        }
        else {
            $prompt = Get-LokiText 'auth.login.apiPrompt'
            $done = Get-LokiText 'auth.login.apiDone'
        }

        # Secret NEVER via argv -- hidden input directly as a SecureString (CLAUDE.md §5).
        $sec = Read-Host -AsSecureString -Prompt $prompt
        if ($sec.Length -eq 0) {
            Write-LokiErr (Get-LokiText 'auth.login.empty')
            return (Get-LokiExitCode 'Usage')
        }
        # Order: method first, then secret, so a later failure never leaves a stored credential under the wrong method.
        $cfg = Read-LokiConfig -Path $configPath
        $cfg['AuthMethod'] = $method
        Write-LokiConfig -Path $configPath -Config $cfg
        Set-LokiSecret -EnvFilePath $envPath -SecureValue $sec
        Write-LokiOk $done
        return (Get-LokiExitCode 'Ok')
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

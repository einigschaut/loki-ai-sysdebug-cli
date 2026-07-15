# commands/chat.ps1 -- `loki chat` (scaffolded by build/New-LokiCommand.ps1, then implemented)
# The interactive ONLINE-engine command: an interactive Claude Code diagnostic session against the local machine.
# Unlike ask/scan (read-only, headless), chat opens the ADR-0006 ask-by-default path: read-only commands run
# automatically, a mutation pauses for interactive USER CONFIRMATION, and hard-denied commands stay blocked. Thin
# wiring only -- lib/claude.ps1 (Invoke-LokiClaudeInteractive) owns the interactive spawn and the LOKI_HOOK_MODE
# gate; the allow-list (lib/allowlist.ps1) via the PreToolUse hook still decides read/ask/deny for every command.
# User-facing text via Get-LokiText (CLAUDE.md section 10). ADR-0002/0007/0008.
Set-StrictMode -Version Latest

function Get-LokiCmdMeta_chat {
    @{
        Name     = 'chat'
        Group    = 'Online'
        Summary  = 'chat.summary'
        Usage    = 'loki chat'
        Examples = @('loki chat')
        Flags    = @()
    }
}

function Invoke-LokiCmd_chat {
    param($Context)

    # Online engine -> requires reachability. Fail fast and clearly when offline (exit 4).
    if (-not (Test-LokiConnectivity)) {
        Write-LokiErr (Get-LokiText 'chat.offline')
        return (Get-LokiExitCode 'NetworkRequired')
    }

    $cfg = Read-LokiConfig -Path (Join-Path $Context.AppRoot 'loki.config.json')

    Write-LokiInfo (Get-LokiText 'chat.starting')
    $res = Invoke-LokiClaudeInteractive -AppRoot $Context.AppRoot -Config $cfg

    if (-not $res.Ok) {
        if ($res.Reason -eq 'auth-missing') {
            Write-LokiErr (Get-LokiText 'chat.authMissing')
            return (Get-LokiExitCode 'AuthMissing')
        }
        if ($res.Reason -eq 'claude-not-found') {
            Write-LokiErr (Get-LokiText 'chat.engineMissing')
            return (Get-LokiExitCode 'GeneralError')
        }
        Write-LokiErr (Get-LokiText 'chat.failed')
        return (Get-LokiExitCode 'GeneralError')
    }

    # The session ran live on the console (its output was the session itself). Surface a non-zero engine exit
    # (an interrupted or errored session) as a general error instead of silently reporting success; a clean
    # exit (0) closes as Ok.
    if (($null -ne $res.ExitCode) -and ([int]$res.ExitCode -ne 0)) {
        Write-LokiErr (Get-LokiText 'chat.failed')
        return (Get-LokiExitCode 'GeneralError')
    }
    Write-LokiInfo (Get-LokiText 'chat.ended')
    return (Get-LokiExitCode 'Ok')
}

# commands/ask.ps1 -- `loki ask <question>` (scaffolded by build/New-LokiCommand.ps1, then implemented)
# The first ONLINE-engine command: a read-only diagnostic question answered by Claude Code running against the
# local machine. Thin wiring only -- lib/claude.ps1 (Invoke-LokiClaude) owns enforcement + orchestration, the
# allow-list gate (lib/allowlist.ps1) via the PreToolUse hook decides which commands may run, and every mutation
# is blocked (read-only scope). User-facing text goes through Get-LokiText (CLAUDE.md section 10). ADR-0002/0007.
Set-StrictMode -Version Latest

function Get-LokiCmdMeta_ask {
    @{
        Name     = 'ask'
        Group    = 'Online'
        Summary  = 'ask.summary'
        Usage    = 'loki ask <question>'
        Examples = @('loki ask "why is my DNS resolution slow?"')
        Flags    = @()
    }
}

function Invoke-LokiCmd_ask {
    param($Context)

    $question = (@($Context.Args) -join ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($question)) {
        Write-LokiErr (Get-LokiText 'ask.usage')
        return (Get-LokiExitCode 'Usage')
    }

    # Online engine -> requires reachability. Fail fast and clearly when offline (exit 4), pointing at the offline path.
    if (-not (Test-LokiConnectivity)) {
        Write-LokiErr (Get-LokiText 'ask.offline')
        return (Get-LokiExitCode 'NetworkRequired')
    }

    $cfg = Read-LokiConfig -Path (Join-Path $Context.AppRoot 'loki.config.json')

    Write-LokiInfo (Get-LokiText 'ask.working')
    $res = Invoke-LokiClaude -Prompt $question -AppRoot $Context.AppRoot -Config $cfg

    if (-not $res.Ok) {
        if ($res.Reason -eq 'auth-missing') {
            Write-LokiErr (Get-LokiText 'ask.authMissing')
            return (Get-LokiExitCode 'AuthMissing')
        }
        if ($res.Reason -eq 'claude-not-found') {
            Write-LokiErr (Get-LokiText 'ask.engineMissing')
            return (Get-LokiExitCode 'GeneralError')
        }
        if ($res.Reason -eq 'cmd-shim-unsafe') {
            Write-LokiErr (Get-LokiText 'ask.engineShimUnsafe')
            return (Get-LokiExitCode 'GeneralError')
        }
        if ($res.Reason -eq 'timeout') {
            Write-LokiErr (Get-LokiText 'ask.timeout')
            return (Get-LokiExitCode 'GeneralError')
        }
        # engine-error / bad-output / an is_error result: generic failure; raw engine stderr only with --verbose.
        Write-LokiErr (Get-LokiText 'ask.failed')
        # StrictMode-safe: Flags may not carry every key in every caller (real dispatcher sets them all; tests may not).
        $verbose = ($Context.Flags -is [hashtable]) -and $Context.Flags.ContainsKey('Verbose') -and $Context.Flags['Verbose']
        if ($verbose -and (-not [string]::IsNullOrEmpty([string]$res.ErrorText))) {
            Write-LokiLine ([string]$res.ErrorText)
        }
        return (Get-LokiExitCode 'GeneralError')
    }

    Write-LokiLine ''
    Write-LokiLine ([string]$res.Result)
    if ($null -ne $res.CostUsd) {
        Write-LokiLine ''
        # NOT [string]$res.CostUsd: PowerShell's [string] cast is culture-INVARIANT (measured -- it stays '0.42' even
        # under a forced en-US thread), so pre-casting hands Get-LokiText a finished string and takes the number out
        # of localization entirely. A German user would read "Kosten: 0.42 USD". The double goes through as a double.
        Write-LokiInfo (Get-LokiText 'ask.cost' -ArgumentList @($res.CostUsd))
    }
    return (Get-LokiExitCode 'Ok')
}

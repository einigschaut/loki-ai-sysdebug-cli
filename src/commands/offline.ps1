# commands/offline.ps1 — `loki offline` (scaffolded by build/New-LokiCommand.ps1)
# Metadata (Get-LokiCmdMeta_offline) is the single source of truth; handler (Invoke-LokiCmd_offline) executes it. ADR-0002.
# Note: Summary should be an i18n catalog key (add it to src/i18n/*.psd1); user-facing output goes through Get-LokiText (CLAUDE.md §10).
Set-StrictMode -Version Latest

function Get-LokiCmdMeta_offline {
    @{
        Name     = 'offline'
        Group    = 'Offline'
        Summary  = 'offline.summary'
        Usage    = 'loki offline --analyze <dump>'
        Examples = @('loki offline --analyze <dump>')
        Flags    = @()
    }
}

function Invoke-LokiCmd_offline {
    param($Context)
    # Slice 1 scaffold: the command is registered and its usage is real. The --analyze orchestration
    # (integrity preflight + engine chat, lib/offline.ps1 / Invoke-LokiOfflineAnalyze) lands in the next commit
    # (task #17). Until then the handler shows how it will be invoked rather than pretending to analyze.
    Write-LokiErr (Get-LokiText 'offline.usage')
    return (Get-LokiExitCode 'Usage')
}
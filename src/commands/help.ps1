# commands/help.ps1 — `loki help [command]`
# Generates output EXCLUSIVELY from the registry (Format-LokiHelp) -> no hand-maintained help text (anti-drift, CLAUDE.md §3).
Set-StrictMode -Version Latest

function Get-LokiCmdMeta_help {
    @{
        Name     = 'help'
        Group    = 'Health'
        Summary  = 'help.summary'
        Usage    = 'loki help [command]'
        Examples = @('loki help', 'loki help status')
        Flags    = @()
    }
}

function Invoke-LokiCmd_help {
    param($Context)
    if ($Context.Args.Count -gt 0) {
        $target = [string]$Context.Args[0]
        $known = $Context.Registry | Where-Object { $_.Name -eq $target } | Select-Object -First 1
        if ($null -eq $known) {
            Write-LokiErr (Get-LokiText 'error.unknownCommandQuoted' -ArgumentList @($target))
            $suggestion = Get-LokiSuggestion -Name $target -Registry $Context.Registry
            if ($null -ne $suggestion) { Write-LokiLine (Get-LokiText 'error.didYouMean' -ArgumentList @($suggestion)) }
            Write-LokiLine (Get-LokiText 'hint.overview')
            return (Get-LokiExitCode 'Usage')
        }
        Write-LokiLine (Format-LokiHelp -Registry $Context.Registry -CommandName $target -AppVersion $Context.Version)
        return (Get-LokiExitCode 'Ok')
    }
    Write-LokiLine (Format-LokiHelp -Registry $Context.Registry -AppVersion $Context.Version)
    return (Get-LokiExitCode 'Ok')
}

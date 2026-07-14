# loki.ps1 — dispatcher (NO business logic, CLAUDE.md §2)
# Responsibility: load lib+commands, parse args, preflight, routing, exit code, teardown.
# 5.1-clean: no &&/||/ternary/??; explicit -Encoding; StrictMode.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AppRoot = $PSScriptRoot

# --- load lib (auto: every lib/*.ps1, alphabetically; lib modules have no load-time dependencies) ---
# Auto-load = anti-drift (CLAUDE.md §3): a new lib module is picked up without a dispatcher edit.
$libDir = Join-Path $AppRoot 'lib'
Get-ChildItem -LiteralPath $libDir -Filter '*.ps1' -File | Sort-Object Name | ForEach-Object { . $_.FullName }

# --- load commands (defines Get-LokiCmdMeta_* + Invoke-LokiCmd_* in script scope) ---
$commandsDir = Join-Path $AppRoot 'commands'
Get-ChildItem -LiteralPath $commandsDir -Filter '*.ps1' -File | Sort-Object Name | ForEach-Object { . $_.FullName }

# --- parse args: first non-flag token = command; capture global flags; rest = CommandArgs ---
$commandName = $null
$commandArgs = @()
$flags = @{ NoColor = $false; Help = $false; Verbose = $false; Quiet = $false; Lang = $null }
$expectLang = $false
foreach ($a in $args) {
    if ($expectLang) { $flags.Lang = $a; $expectLang = $false; continue }
    if ($null -eq $commandName -and ($a -notlike '-*')) { $commandName = $a; continue }
    switch -Regex ($a) {
        '^--lang=(.+)$'     { $flags.Lang = $Matches[1]; continue }
        '^--lang$'          { $expectLang = $true; continue }
        '^--no-color$'      { $flags.NoColor = $true; continue }
        '^(--help|-h)$'     { $flags.Help = $true; continue }
        '^(--verbose|-v)$'  { $flags.Verbose = $true; continue }
        '^(--quiet|-q)$'    { $flags.Quiet = $true; continue }
        default             { $commandArgs += $a }
    }
}

Initialize-LokiUi -NoColor:$flags.NoColor
$version = Get-LokiVersion -AppRoot $AppRoot
$exit = Get-LokiExitCode 'Ok'

# Routing as if/elseif/else (NO early `return`): a top-level `return` in the try would leave
# the script after `finally` and skip `exit $exit` -> the exit code would be lost.
try {
    # Determine locale + load catalog BEFORE any output (auto-detect OS culture, fallback en; ADR-0004).
    $configPath = Join-Path $AppRoot 'loki.config.json'
    $config = @{}
    if (Test-Path -LiteralPath $configPath) { $config = Read-LokiConfig -Path $configPath }
    Initialize-LokiI18n -AppRoot $AppRoot -Flags $flags -Config $config | Out-Null

    $registry = Get-LokiCommandRegistry

    if ($null -eq $commandName -and -not $flags.Help) {
        # Bare `loki` -> stage-0 banner (later: status menu)
        Write-LokiHeading ("loki v{0} - {1}" -f $version, (Get-LokiText 'app.tagline'))
        Write-LokiLine ''
        Write-LokiInfo  (Get-LokiText 'dispatch.overviewHint')
        Write-LokiLine  (Get-LokiText 'dispatch.statusHint')
        $exit = Get-LokiExitCode 'Ok'
    }
    elseif ($flags.Help) {
        # `--help` -> command help (with command) or overall help (without command), no handler
        Write-LokiLine (Format-LokiHelp -Registry $registry -CommandName $commandName -AppVersion $version)
        $exit = Get-LokiExitCode 'Ok'
    }
    else {
        # Resolve command
        $cmd = $registry | Where-Object { $_.Name -eq $commandName } | Select-Object -First 1
        if ($null -eq $cmd) {
            Write-LokiErr (Get-LokiText 'error.unknownCommandQuoted' -ArgumentList @($commandName))
            $suggestion = Get-LokiSuggestion -Name $commandName -Registry $registry
            if ($null -ne $suggestion) { Write-LokiLine (Get-LokiText 'error.didYouMean' -ArgumentList @($suggestion)) }
            Write-LokiLine (Get-LokiText 'hint.overview')
            $exit = Get-LokiExitCode 'Usage'
        }
        else {
            # Context for the handler (narrow, documented interface)
            $context = @{
                AppRoot  = $AppRoot
                Version  = $version
                Args     = $commandArgs
                Flags    = $flags
                Registry = $registry
            }
            $result = & $cmd.Handler $context
            $exit = [int](@($result) | Select-Object -Last 1)
        }
    }
}
catch {
    Write-LokiErr $_.Exception.Message
    if ($flags.Verbose) { Write-LokiLine ($_.ScriptStackTrace) }
    $exit = Get-LokiExitCode 'GeneralError'
}
finally {
    # Teardown anchor (stage 0 minimal; later: env-isolate cleanup, llama-server kill, footprint guard).
    # Deliberately empty, but present -> every later command cleans up here centrally.
}

exit $exit

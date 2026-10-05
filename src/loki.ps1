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
$flags = @{ NoColor = $false; Help = $false; Verbose = $false; Quiet = $false; Lang = $null; Plain = $false }
$expectLang = $false
foreach ($a in $args) {
    if ($expectLang) { $flags.Lang = $a; $expectLang = $false; continue }
    if ($null -eq $commandName -and ($a -notlike '-*')) { $commandName = $a; continue }
    switch -Regex ($a) {
        '^--lang=(.+)$'     { $flags.Lang = $Matches[1]; continue }
        '^--lang$'          { $expectLang = $true; continue }
        '^--no-color$'      { $flags.NoColor = $true; continue }
        '^--plain$'         { $flags.Plain = $true; continue }
        '^(--help|-h)$'     { $flags.Help = $true; continue }
        '^(--verbose|-v)$'  { $flags.Verbose = $true; continue }
        '^(--quiet|-q)$'    { $flags.Quiet = $true; continue }
        default             { $commandArgs += $a }
    }
}

# LOKI_PLAIN alongside --plain, mirroring how NO_COLOR sits alongside --no-color: an operator who
# pipes Loki through a wrapper cannot always add a flag, but can always set an environment variable.
if (-not [string]::IsNullOrEmpty($env:LOKI_PLAIN)) { $flags.Plain = $true }

Initialize-LokiUi -NoColor:$flags.NoColor
Initialize-LokiRegion
Initialize-LokiScreen
Initialize-LokiKeyread
Initialize-LokiSession
Initialize-LokiRestore
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

    # Bare `loki` -> the guided mode (ADR-0034). This REWRITES the command name rather than special-casing a
    # banner here, so `loki` and `loki guide` travel the identical path: one registered handler, one context
    # shape, and the registry, docs and dead-code gates keep covering the entry point like every other command.
    # A guided mode wired in beside the registry would be the first thing in this tool that `help` cannot
    # describe -- exactly the drift CLAUDE.md section 3 exists to prevent.
    if ($null -eq $commandName -and -not $flags.Help) { $commandName = 'guide' }

    if ($flags.Help) {
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
    # Give the console back BEFORE saying what went wrong. catch runs before finally, and an error printed while the
    # alternate screen is still active lands in the alternate buffer -- which the finally then discards, leaving exit
    # code 1 and no message at all. Restore-LokiConsole is idempotent; the finally runs it again regardless.
    Restore-LokiConsole
    Write-LokiErr $_.Exception.Message
    if ($flags.Verbose) { Write-LokiLine ($_.ScriptStackTrace) }
    $exit = Get-LokiExitCode 'GeneralError'
}
finally {
    # Teardown anchor (later also: env-isolate cleanup, llama-server kill, footprint guard). EVERY exit path ends here,
    # and lib/teardown.ps1 says in what order and why: capture sink, owned screen, live region, session, and the
    # keyboard last. Each step is guarded on its own and each is a no-op when its part was never opened -- which is the
    # overwhelmingly common case.
    Restore-LokiConsole

    # A part that could not be given back is not silently forgotten, and a run that could not give the console back
    # does not end with exit code 0 -- that would be a failure that looks like success. Both live in lib/teardown.ps1,
    # where they are tested; the warning is best effort and never throws.
    $exit = Get-LokiRestoreExitCode -ExitCode $exit
    Write-LokiRestoreWarning
}

exit $exit

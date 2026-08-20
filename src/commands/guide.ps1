# commands/guide.ps1 -- `loki guide`, the guided mode. Bare `loki` routes here (see src/loki.ps1).
# Metadata (Get-LokiCmdMeta_guide) is the single source of truth; the handler (Invoke-LokiCmd_guide) executes it.
# ADR-0002 / ADR-0034.
#
# THIS FILE ONLY DRAWS AND ASKS. Every decision -- what is possible on this machine, why not, what would fix it,
# what a choice maps to -- lives in lib/guide.ps1 as pure functions, because a menu whose logic is tangled up with
# Write-Host is a menu nobody can test (CLAUDE.md section 2 and 6).
#
# SECURITY NOTE, because "a mode that runs other commands" deserves one: this command grants nothing. It builds the
# same context hashtable the dispatcher builds and calls the same registered handler, so env-isolate, the allow-list
# gate and the footprint guard apply exactly as they do when the operator types the command themselves. The guide is
# a signpost, never a side door.
Set-StrictMode -Version Latest

function Get-LokiCmdMeta_guide {
    @{
        Name     = 'guide'
        Group    = 'Diagnostics'
        Summary  = 'guide.summary'
        Usage    = 'loki guide'
        Examples = @('loki guide', 'loki')
        Flags    = @()
    }
}

function Invoke-LokiCmd_guide {
    param($Context)

    $config = @{}
    $configPath = Join-Path $Context.AppRoot 'loki.config.json'
    if (Test-Path -LiteralPath $configPath) { $config = Read-LokiConfig -Path $configPath }

    $quiet = ($Context.Flags -is [hashtable]) -and $Context.Flags.ContainsKey('Quiet') -and [bool]$Context.Flags.Quiet
    if (-not $quiet) {
        Write-LokiBrand
        Write-LokiLine ''
    }

    # The serpent advances its own frame per draw and rate-limits itself, so the caller just says "still busy".
    $label = Get-LokiText 'guide.checking'
    Initialize-LokiSpinner
    $onStep = { Write-LokiSpinnerTick -Label $label }.GetNewClosure()
    $state = Get-LokiGuideState -AppRoot $Context.AppRoot -Config $config -OnStep $onStep
    Write-LokiSpinnerDone
    # ASSIGN FIRST, then wrap: Get-LokiGuideMenu ends in `return , @(...)`, so @(FUNC) would be 1 element.
    $options = Get-LokiGuideMenu -State $state
    $options = @($options)

    Write-LokiHeading (Get-LokiText 'guide.title' -ArgumentList @($Context.Version))
    Write-LokiLine ''
    Write-LokiLine (Get-LokiText 'guide.intro')
    Write-LokiLine ''

    foreach ($o in $options) {
        $label = Get-LokiText $o.LabelKey
        if ($o.Available) {
            Write-LokiColor -Text ("  {0}) {1}" -f $o.Number, $label) -Color Green
        }
        else {
            # Shown, numbered and greyed -- never hidden. Hiding it would answer "can I do this here?" with silence,
            # and the reason below is the single most useful line on the screen for someone new to the tool.
            Write-LokiColor -Text ("  {0}) {1}" -f $o.Number, $label) -Color DarkGray
            Write-LokiColor -Text ("       {0}" -f (Get-LokiText $o.ReasonKey)) -Color DarkGray
            Write-LokiColor -Text ("       {0}" -f (Get-LokiText $o.RemedyKey)) -Color DarkGray
        }
    }
    Write-LokiLine ''

    # Piped or redirected input: the menu above is still a perfectly good report of what this machine can do, so
    # print it, say why nothing is being asked, and leave with Ok. Prompting into a closed stdin would either hang
    # or read EOF forever.
    if ([Console]::IsInputRedirected) {
        Write-LokiInfo (Get-LokiText 'guide.nonInteractive')
        return (Get-LokiExitCode 'Ok')
    }

    # Bounded re-prompt: a typo must not end the session (this command exists to be pleasant to use), but an
    # unbounded loop against a misbehaving host would hang. Empty input is always a way out.
    $attempts = 0
    $choice = $null
    while ($attempts -lt 3) {
        $attempts++
        $raw = Read-Host (Get-LokiText 'guide.prompt')
        $choice = Resolve-LokiGuideChoice -Options $options -Choice $raw
        if ([string]$choice.Kind -ne 'invalid') { break }
        Write-LokiWarn (Get-LokiText $choice.ReasonKey)
    }

    if ($null -eq $choice -or [string]$choice.Kind -eq 'invalid') {
        return (Get-LokiExitCode 'Usage')
    }
    if ([string]$choice.Kind -eq 'quit') {
        return (Get-LokiExitCode 'Ok')
    }
    if ([string]$choice.Kind -eq 'unavailable') {
        Write-LokiWarn (Get-LokiText $choice.ReasonKey)
        Write-LokiLine (Get-LokiText $choice.Option.RemedyKey)
        return (Get-LokiExitCode 'Ok')
    }

    $option = $choice.Option
    $target = @($Context.Registry) | Where-Object { $_.Name -eq [string]$option.Target } | Select-Object -First 1
    if ($null -eq $target) {
        # Only reachable if the registry and the guide's option table disagree -- i.e. a command was renamed and
        # this file was not updated. Fail loudly rather than silently offering a dead entry.
        Write-LokiErr (Get-LokiText 'guide.error.noSuchCommand' -ArgumentList @([string]$option.Target))
        return (Get-LokiExitCode 'GeneralError')
    }

    Write-LokiLine ''
    # The same shape src/loki.ps1 builds. Deliberately identical: the guide must not become a second, divergent
    # definition of what a command receives.
    $childContext = @{
        AppRoot  = $Context.AppRoot
        Version  = $Context.Version
        Args     = @($option.Args)
        Flags    = $Context.Flags
        Registry = $Context.Registry
    }
    $result = & $target.Handler $childContext
    $exit = [int](@($result) | Select-Object -Last 1)

    # The learning curve, in one line. A guided mode that never names what it did produces dependants; one that
    # always does produces operators who eventually stop needing it. That is the goal, not a regrettable side effect.
    Write-LokiLine ''
    Write-LokiInfo (Get-LokiText 'guide.equivalent' -ArgumentList @([string]$option.Teach))
    return $exit
}

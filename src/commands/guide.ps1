# commands/guide.ps1 -- `loki guide`, the guided mode. Bare `loki` routes here (see src/loki.ps1).
# Metadata (Get-LokiCmdMeta_guide) is the single source of truth; the handler (Invoke-LokiCmd_guide) executes it.
# ADR-0002 / ADR-0034 / ADR-0039 / ADR-0040.
#
# THIS FILE ONLY DRAWS AND ASKS. Every decision -- what is possible on this machine, why not, what would fix it,
# what a choice maps to, what the menu says -- lives in lib/guide.ps1 as pure functions, because a menu whose logic
# is tangled up with Write-Host is a menu nobody can test (CLAUDE.md section 2 and 6).
#
# TWO PATHS, ONE MENU. The session (ADR-0039/0040) is the real guided mode: a full-screen loop that stays open,
# recomputes what this machine can do after every command, and does not make the operator type `loki` again for
# every action -- which was the complaint that opened #133. The one-shot menu below it is the FALLBACK, and it is
# not a lesser copy: it is the exact code that shipped before, unchanged, and it runs whenever the session refuses
# -- under redirection, in CI, on a console without VT, on a tiny window, and whenever the operator passed --plain.
# Both render the same lines from Get-LokiGuideMenuLine, so they cannot drift apart.
#
# A COMMAND RUNS INSIDE THE SESSION AND ITS OUTPUT IS CAPTURED. The screen is not handed over for it. That is what
# the reference does and what makes this a session rather than a launcher, and it is possible because Loki's own
# output has exactly two exits -- Write-LokiConsole and Write-LokiToStdErr, both intercepted by lib/ui.ps1's sink --
# and because every child process these entries spawn already redirects its streams.
#
# The exception is DECLARED and it is two of six: `chat` inherits the console on purpose (a live Claude TUI) and
# `agent` asks Read-Host before every mutating command. lib/guide.ps1 marks them Interactive, and only they get the
# console for their duration.
#
# SECURITY NOTE, because "a mode that runs other commands" deserves one: this command grants nothing, on either
# path. It builds the same context hashtable the dispatcher builds and calls the same registered handler, so
# env-isolate, the allow-list gate and the footprint guard apply exactly as they do when the operator types the
# command themselves. The guide is a signpost, never a side door. Capturing output does not change that: the sink
# reads what a command PRINTS, it does not sit between the command and the gate.
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

function Get-LokiGuideCommandTarget {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Registry,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name
    )
    # PURE. Only reachable as $null if the registry and the guide's option table disagree -- i.e. a command was
    # renamed and lib/guide.ps1 was not updated. Split out so both paths fail the same way instead of one of them
    # quietly offering a dead entry.
    return @($Registry) | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

function New-LokiGuideChildContext {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure construction of the context hashtable; no side effect beyond the return value.')]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$CommandArgs
    )
    # The same shape src/loki.ps1 builds. Deliberately identical, and deliberately in ONE place now that two paths
    # need it: the guide must not become a second, divergent definition of what a command receives.
    return @{
        AppRoot  = $Context.AppRoot
        Version  = $Context.Version
        Args     = @($CommandArgs)
        Flags    = $Context.Flags
        Registry = $Context.Registry
    }
}

function Invoke-LokiGuideSession {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][hashtable]$Config
    )
    # The loop #133 asked for. Assumes an OPEN session; the caller owns opening and closing it.
    #
    # THE STATE IS RECOMPUTED AFTER EVERY COMMAND, and that is the feature rather than an optimisation. In the
    # session log that opened #133 the operator ran `collect` and then chose "analyse a dump" -- against a menu
    # computed before the dump existed. Here the menu already knows, and freeing memory makes the offline agent
    # appear without a restart.
    #
    # It is NOT recomputed per keystroke: Get-LokiGuideState reads the disk and opens a TCP probe, which is
    # seconds. "Every round" in the issue means every round of the operator's attention, not of the keyboard's.
    $state = New-LokiSessionState

    # The identity, drawn once. In a diff-painted screen "once" is automatic -- these rows never change, so they
    # are never repainted -- and they scroll away like the reference's own header as the transcript grows.
    #
    # The art needs the tier AND the width: it collapses to a single line below 34 columns rather than wrapping
    # into rubble, and it uses only characters proven present in CP850 and CP437 (issue #121). The width comes from
    # the screen, which is the only thing that knows it -- guessing would put the wide form on a narrow console.
    $screen = Get-LokiScreenSize
    foreach ($line in @(Get-LokiBrandArt -Tier $state.Tier -Width $screen.Width)) {
        Add-LokiSessionEntry -State $state -Text $line
    }
    Add-LokiSessionEntry -State $state -Text ''
    Add-LokiSessionEntry -State $state -Text (Get-LokiText 'guide.title' -ArgumentList @($Context.Version))
    Add-LokiSessionEntry -State $state -Text ''
    Add-LokiSessionEntry -State $state -Text (Get-LokiText 'guide.intro')

    $options = @()
    $refresh = $true
    $exit = Get-LokiExitCode 'Ok'

    while ($true) {
        if ($refresh) {
            # Say so before the wait, not after it. Get-LokiGuideState reads the disk and opens a TCP probe, which
            # is seconds -- long enough that a screen showing the previous frame with no explanation reads as a
            # hang. No spinner: the session cannot animate from a single thread while a probe blocks, and a
            # standing line that is true beats an animation that would have to lie about progress.
            $state.Notice = Get-LokiText 'guide.checking'
            Write-LokiSessionFrame -State $state

            $guideState = Get-LokiGuideState -AppRoot $Context.AppRoot -Config $Config
            $state.Notice = ''
            # ASSIGN FIRST, then wrap: Get-LokiGuideMenu ends in `return , @(...)`, so @(FUNC) would be 1 element.
            $options = Get-LokiGuideMenu -State $guideState
            $options = @($options)
            $state.Engine = Get-LokiText (Get-LokiGuideEngineLabel -State $guideState)

            Add-LokiSessionEntry -State $state -Text ''
            foreach ($line in @(Get-LokiGuideMenuLine -Options $options)) {
                Add-LokiSessionEntry -State $state -Text ([string]$line.Text)
            }
            Add-LokiSessionEntry -State $state -Text ''
            Add-LokiSessionEntry -State $state -Text (Get-LokiText 'guide.session.prompt')
            $refresh = $false
        }

        $round = Invoke-LokiSessionRound -State $state
        if ([string]$round.Action -eq 'closed') {
            # The console went away underneath. Not an error and not a clean departure either -- say nothing and
            # leave, because there is nowhere left to say it.
            break
        }
        if ([string]$round.Action -eq 'exit') { break }
        if ([string]$round.Action -eq 'interrupt') {
            # Escape with nothing running. The reference keeps the session and so does this.
            continue
        }
        if ([string]$round.Action -ne 'submit') { continue }

        $choice = Resolve-LokiGuideChoice -Options $options -Choice ([string]$round.Text)
        if ([string]$choice.Kind -eq 'quit') { break }
        if ([string]$choice.Kind -eq 'invalid') {
            $state.Notice = Get-LokiText ([string]$choice.ReasonKey)
            continue
        }
        if ([string]$choice.Kind -eq 'unavailable') {
            # Refused, and the refusal repeats the reason AND the remedy into the transcript rather than the
            # one-line notice -- choosing an unavailable option is itself a way of asking "why not?", and the
            # answer should still be on screen after the next keystroke.
            Add-LokiSessionEntry -State $state -Text (Get-LokiText ([string]$choice.ReasonKey))
            Add-LokiSessionEntry -State $state -Text (Get-LokiText ([string]$choice.Option.RemedyKey))
            continue
        }

        $option = $choice.Option
        $target = Get-LokiGuideCommandTarget -Registry @($Context.Registry) -Name ([string]$option.Target)
        if ($null -eq $target) {
            Add-LokiSessionEntry -State $state -Text (Get-LokiText 'guide.error.noSuchCommand' -ArgumentList @([string]$option.Target))
            $exit = Get-LokiExitCode 'GeneralError'
            continue
        }

        # THE COMMAND RUNS INSIDE THE SESSION AND ITS OUTPUT IS CAPTURED, which is what the reference does and what
        # #133 asked for. The screen is never handed over for it.
        #
        # This is possible because Loki's own output has exactly two exits -- Write-LokiConsole and
        # Write-LokiToStdErr -- and lib/ui.ps1's sink intercepts both; and because every child process Loki spawns
        # for these entries already redirects its streams (lib/claude.ps1 for `ask`, lib/agent.ps1 for the engine,
        # lib/offline-agent.ps1 for gated commands). Nothing writes to the console behind the session's back.
        #
        # The exception is DECLARED, not universal: `chat` inherits the console on purpose (a live Claude TUI) and
        # `agent` asks Read-Host before every mutating command. Those two, and only those two, get the console.
        $childExit = 0
        $childContext = New-LokiGuideChildContext -Context $Context -CommandArgs @($option.Args)

        if ([bool]$option.Interactive) {
            # Hand over. A captured confirm prompt is a prompt nobody can answer, and a captured TUI is a frozen
            # screen -- so for these the honest thing is to give the console back for the duration and take it
            # again afterwards. Close-LokiKeyread also returns Ctrl+C to the child, which an interactive command
            # needs.
            Close-LokiSession
            Write-LokiLine ''
            $result = & $target.Handler $childContext
            $childExit = [int](@($result) | Select-Object -Last 1)
            Write-LokiLine ''
            Write-LokiInfo (Get-LokiText 'guide.equivalent' -ArgumentList @([string]$option.Teach))

            Add-LokiSessionEntry -State $state -Text (Get-LokiText 'guide.session.ran' -ArgumentList @([string]$option.Teach, $childExit))
            if (-not (Open-LokiSession -Plain:(Get-LokiGuideFlag -Flags $Context.Flags -Name 'Plain'))) {
                # The console changed its mind while the command had it -- resized below the floor, redirected, or
                # the screen disabled itself. Leave with what the command returned rather than looping on a session
                # that cannot draw.
                return $childExit
            }
            $refresh = $true
            continue
        }

        # Captured. The sink appends each line to the transcript and repaints, so output appears line by line as it
        # is produced rather than arriving in a lump when the command finishes -- which matters most for `collect`,
        # the slowest entry and the one where a frozen screen would look like a hang.
        #
        # A no-newline write is PROGRESS, not transcript: the spinner rewinds its own line with a carriage return,
        # and a transcript that grew a row per spinner frame would be unreadable. It goes to the notice row, which
        # is what that row is for and what the reference does with its own spinner.
        Open-LokiSessionCapture -State $state
        try {
            $result = & $target.Handler $childContext
            $childExit = [int](@($result) | Select-Object -Last 1)
        }
        finally {
            # ALWAYS. A sink left registered after the command that owns it has finished would swallow every
            # subsequent line of output -- including the dispatcher's own error path -- into a transcript nobody
            # is drawing any more.
            Close-LokiSessionCapture
        }

        $state.Notice = ''
        Add-LokiSessionEntry -State $state -Text (Get-LokiText 'guide.session.ran' -ArgumentList @([string]$option.Teach, $childExit))
        Add-LokiSessionEntry -State $state -Text (Get-LokiText 'guide.equivalent' -ArgumentList @([string]$option.Teach))
        $refresh = $true
    }

    # A session's exit code describes the SESSION, not the commands inside it (ADR-0038). "collect, then offline,
    # then quit" did exactly what was asked; reporting offline's 5 would make the code depend on which command the
    # operator happened to run last. The individual codes are in the transcript, where a human reads them.
    return $exit
}

function Get-LokiGuideFlag {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Flags,
        [Parameter(Mandatory = $true)][string]$Name
    )
    # PURE. StrictMode makes a missing hashtable key a throw, and the dispatcher is not the only thing that ever
    # builds a context -- the guide builds one too, and so does every test. Same shape the Quiet check below used
    # inline before there were two flags to read.
    if (-not ($Flags -is [hashtable])) { return $false }
    if (-not $Flags.ContainsKey($Name)) { return $false }
    return [bool]$Flags[$Name]
}

function Invoke-LokiCmd_guide {
    param($Context)

    $config = @{}
    $configPath = Join-Path $Context.AppRoot 'loki.config.json'
    if (Test-Path -LiteralPath $configPath) { $config = Read-LokiConfig -Path $configPath }

    # The session first. Open-LokiSession returning $false is a NORMAL answer and the one CI always gets, so the
    # fallback below is not a rarely-exercised branch -- it is what the whole test suite runs against.
    if (Open-LokiSession -Plain:(Get-LokiGuideFlag -Flags $Context.Flags -Name 'Plain')) {
        try { return (Invoke-LokiGuideSession -Context $Context -Config $config) }
        finally { Close-LokiSession }
    }

    # ---------------------------------------------------------------------------------------------------------
    # FALLBACK: the one-shot menu, unchanged from before the session existed.
    # ---------------------------------------------------------------------------------------------------------
    if (-not (Get-LokiGuideFlag -Flags $Context.Flags -Name 'Quiet')) {
        Write-LokiBrand
        Write-LokiLine ''
    }

    # The serpent advances its own frame per draw and rate-limits itself, so the caller just says "still busy".
    $label = Get-LokiText 'guide.checking'
    Initialize-LokiSpinner
    $onStep = { Write-LokiSpinnerTick -Label $label }.GetNewClosure()
    # try/finally, exactly as collect.ps1:65-68 and setup.ps1 do it. Write-LokiSpinnerTick leaves the cursor
    # parked mid-line (carriage return, no newline), and only Write-LokiSpinnerDone puts it back -- on a
    # console SHARED with the parent shell, which keeps that position after Loki exits. Get-LokiGuideState is
    # built never to throw, so this is defence in depth rather than a live crash; it is here because two of
    # three spinner call sites had the guard and this one did not, and an inconsistency like that reads as a
    # deliberate exception to whoever finds it next.
    try {
        $state = Get-LokiGuideState -AppRoot $Context.AppRoot -Config $config -OnStep $onStep
    }
    finally { Write-LokiSpinnerDone }
    # ASSIGN FIRST, then wrap: Get-LokiGuideMenu ends in `return , @(...)`, so @(FUNC) would be 1 element.
    $options = Get-LokiGuideMenu -State $state
    $options = @($options)

    Write-LokiHeading (Get-LokiText 'guide.title' -ArgumentList @($Context.Version))
    Write-LokiLine ''
    Write-LokiLine (Get-LokiText 'guide.intro')
    Write-LokiLine ''

    # Same lines as the session draws, coloured by role. One source of truth for the text (CLAUDE.md section 2).
    foreach ($line in @(Get-LokiGuideMenuLine -Options $options)) {
        if ([string]$line.Role -eq 'available') {
            Write-LokiColor -Text ([string]$line.Text) -Color Green
        }
        else {
            Write-LokiColor -Text ([string]$line.Text) -Color DarkGray
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
    $target = Get-LokiGuideCommandTarget -Registry @($Context.Registry) -Name ([string]$option.Target)
    if ($null -eq $target) {
        # Only reachable if the registry and the guide's option table disagree -- i.e. a command was renamed and
        # this file was not updated. Fail loudly rather than silently offering a dead entry.
        Write-LokiErr (Get-LokiText 'guide.error.noSuchCommand' -ArgumentList @([string]$option.Target))
        return (Get-LokiExitCode 'GeneralError')
    }

    Write-LokiLine ''
    $result = & $target.Handler (New-LokiGuideChildContext -Context $Context -CommandArgs @($option.Args))
    $exit = [int](@($result) | Select-Object -Last 1)

    # The learning curve, in one line. A guided mode that never names what it did produces dependants; one that
    # always does produces operators who eventually stop needing it. That is the goal, not a regrettable side effect.
    Write-LokiLine ''
    Write-LokiInfo (Get-LokiText 'guide.equivalent' -ArgumentList @([string]$option.Teach))
    return $exit
}

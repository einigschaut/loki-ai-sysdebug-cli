# lib/guide.ps1 -- the MODEL behind `loki guide`. The rendering and the prompting live in commands/guide.ps1;
# everything that decides anything lives here, because an interactive screen is only testable if the decisions are
# not tangled up with the drawing (CLAUDE.md section 2).
#
# Contract:
# Names are singular by choice, not by lint appeasement: PSUseSingularNouns fired on the first draft
# (GuideFacts / GuideOptions) and renaming was free because nothing depended on them yet. Suppression belongs
# where a specified contract forbids renaming -- see Get-LokiInstalledTiers -- not where a better name exists.
#   Get-LokiGuideState -AppRoot <dir> -Config <hashtable> [-SkipNetwork] -> [hashtable]
#       IMPURE (disk + one short TCP probe). NEVER throws: a guide that crashes while explaining the machine is
#       worse than no guide at all, so every probe degrades to "unknown", and unknown is treated as unavailable
#       WITH a reason rather than silently hidden.
#   Get-LokiGuideMenu -State <hashtable> -> [object[]]
#       PURE, table-tested. The heart: turns facts into the menu, including WHY an entry is unavailable and WHAT
#       to do about it.
#   Resolve-LokiGuideChoice -Options <entries> -Choice <string> -> [hashtable]{ Kind; Option; ReasonKey }
#       PURE. Kind is 'run' | 'quit' | 'invalid' | 'unavailable'.
#   Get-LokiGuideMenuLine -Options <entries> -> [object[]]{ Text; Role }
#       PURE. The menu as text, once, for BOTH renderers -- the coloured one-shot fallback and the session
#       transcript. Role ('available' | 'muted') is what the fallback colours by; the session cannot colour at
#       all, because an escape sequence inside a screen model breaks the diff's column arithmetic (ADR-0039).
#   Get-LokiGuideEngineLabel -State <hashtable> -> [string]  a catalog key
#       PURE. Which engine would answer right now. The session's status row carries this and nothing else about
#       the machine (ADR-0038): it is the one fact that genuinely changes mid-session.
#
# Two design rules worth stating, because both are easy to "improve" into something worse:
#
#   1. THE NUMBERS NEVER MOVE. Every option is listed and numbered in a fixed order whether or not it is available
#      today. Renumbering to hide unavailable entries would mean "3" is the agent on one machine and the online
#      session on the next -- and the technician who uses this daily would have to read the menu every time instead
#      of building muscle memory. An unavailable entry is shown, numbered, and refused with its reason.
#
#   2. AN UNAVAILABLE ENTRY ALWAYS CARRIES A REMEDY. "Online diagnosis: not available" teaches nothing. The point of
#      this whole command is that the tool already knows why -- status, hwscan and doctor compute exactly these
#      facts today -- and the operator should not have to go find out.
Set-StrictMode -Version Latest

# The menu order. Fixed on purpose (rule 1 above) and roughly "cheapest and most universal first": collect needs
# neither model nor network nor admin, doctor never fails, and the two engine paths sit between them.
$script:LokiGuideOrder = @('collect', 'analyze', 'agent', 'ask', 'chat', 'doctor')

function Get-LokiGuideState {
    param(
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [switch]$SkipNetwork,
        # Called once after each probe. Exists so the caller can animate WITHOUT a second thread: the serpent
        # advances when Loki actually finishes a step, which is more honest than a timer pretending to be
        # busy -- and it keeps console writes on one thread, where they belong.
        [AllowNull()][scriptblock]$OnStep = $null
    )


    $state = @{
        EngineOk     = $false
        EngineDetail = ''
        StepError    = ''
        Tiers        = @()
        FittingTiers = @()
        AgentTiers   = @()
        AgentInstalled = @()
        Dumps        = @()
        AuthPresent  = $false
        AuthMethod   = ''
        Online       = $false
        TotalRamGB   = 0.0
    }

    $step = {
        if ($null -ne $OnStep) {
            # Decoration must never be able to fail the diagnosis it decorates -- so the failure is
            # swallowed ON PURPOSE. Recorded rather than discarded, though: a permanently broken
            # spinner that leaves no trace anywhere is a bug nobody will ever find.
            try { & $OnStep } catch { $state.StepError = [string]$_.Exception.Message }
        }
    }

    # --- offline engine -------------------------------------------------------------------------------------
    # Presence of the manifest AND the server binary. Deliberately NOT a hash verification: that is ADR-0012's job
    # at load time, and hashing gigabytes to draw a menu would make the fast path the slow one.
    try {
        $engineManifestPath = Join-Path (Join-Path $AppRoot 'engine') 'manifest.psd1'
        if (Test-Path -LiteralPath $engineManifestPath) {
            $engineData = Get-LokiEngineManifest -Path $engineManifestPath
            $layout = Get-LokiEngineLayout -AppRoot $AppRoot -Engine $engineData.Engine
            if (Test-Path -LiteralPath $layout.ServerExePath) { $state.EngineOk = $true }
        }
    }
    catch { $state.EngineDetail = [string]$_.Exception.Message }
    & $step

    # --- models ---------------------------------------------------------------------------------------------
    # Read-LokiModelManifestSafe rather than the raw parser: a stale or broken manifest must leave the guide
    # standing (it is exactly the machine that needs help), not take it down with a validator exception.
    try {
        $layout = Get-LokiModelLayout -AppRoot $AppRoot
        $read = Read-LokiModelManifestSafe -Path $layout.ManifestPath -LocalPath $layout.LocalManifestPath
        if ($read.Ok) {
            # ASSIGN FIRST, then wrap: Get-LokiInstalledTiers ends in `return , $array`, so @(FUNC) would count 1
            # regardless of how many tiers are installed. Measured in this repo more than once.
            $installed = Get-LokiInstalledTiers -Models $read.Models -ModelsDir $layout.Dir
            $state.Tiers = @($installed)

            $hw = Get-LokiHardwareProfile
            $state.TotalRamGB = [double]$hw.TotalRamGB
            $fitting = New-Object System.Collections.Generic.List[object]
            $agentic = New-Object System.Collections.Generic.List[object]
            $agentAll = New-Object System.Collections.Generic.List[object]
            foreach ($t in $state.Tiers) {
                $capable = Test-LokiOfflineAgentCapable -Model $t
                # Tracked SEPARATELY from fit on purpose. "No agent model on the stick" and "the agent model is
                # here but will not fit right now" have completely different remedies, and telling someone to
                # download a model they already have is exactly the kind of confident-but-wrong advice this
                # command exists to replace. (Found on the first real run against a provisioned stick.)
                if ($capable) { $agentAll.Add($t) }
                $fit = Get-LokiTierFit -TotalRamGB $hw.TotalRamGB -AvailableRamGB $hw.AvailableRamGB -ResidentGB $t.ResidentGB
                if ([string]$fit.Verdict -ne 'fits') { continue }
                $fitting.Add($t)
                if ($capable) { $agentic.Add($t) }
            }
            $state.FittingTiers = @($fitting.ToArray())
            $state.AgentTiers = @($agentic.ToArray())
            $state.AgentInstalled = @($agentAll.ToArray())
        }
    }
    catch { $state.EngineDetail = [string]$_.Exception.Message }
    & $step

    # --- existing dumps -------------------------------------------------------------------------------------
    # Newest first, because the answer to "which dump did you mean" is almost always "the one I just made".
    try {
        $reportsDir = Join-Path $AppRoot 'reports'
        if (Test-Path -LiteralPath $reportsDir) {
            $found = Get-ChildItem -LiteralPath $reportsDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -eq '.json' -or $_.Extension -eq '.txt' } |
                Sort-Object LastWriteTime -Descending
            $state.Dumps = @($found)
        }
    }
    catch { $state.Dumps = @() }
    & $step

    # --- auth + reachability --------------------------------------------------------------------------------
    try {
        $envFilePath = Join-Path (Join-Path $AppRoot 'home') '.env'
        $auth = Get-LokiAuthStatus -EnvFilePath $envFilePath -Config $Config
        $state.AuthPresent = [bool]$auth.Present
        $state.AuthMethod = [string]$auth.Method
    }
    catch { $state.AuthPresent = $false }
    & $step

    if (-not $SkipNetwork) {
        try { $state.Online = [bool](Test-LokiConnectivity) } catch { $state.Online = $false }
        & $step
    }

    return $state
}

function Get-LokiGuideMenu {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        # Injectable ONLY so the fail-safe branch below can be exercised: an id with no availability rule must come
        # back unavailable rather than silently available (CLAUDE.md section 6 -- no guard that cannot be fired).
        [AllowEmptyCollection()][string[]]$Order = @()
    )

    $engineOk = [bool]$State.EngineOk
    $fitting = @($State.FittingTiers)
    $agentic = @($State.AgentTiers)
    $agentInstalled = @($(if ($State.ContainsKey('AgentInstalled')) { $State.AgentInstalled } else { @() }))
    $dumps = @($State.Dumps)
    $authOk = [bool]$State.AuthPresent
    $online = [bool]$State.Online

    # One decision per option, in one place. The reason/remedy pair is chosen by the FIRST unmet condition, so the
    # operator is told the thing to fix first rather than the last thing that happened to be checked.
    $decide = {
        param([string]$Id)
        switch ($Id) {
            'collect' { return @{ Ok = $true } }
            'doctor' { return @{ Ok = $true } }
            'analyze' {
                if (-not $engineOk) { return @{ Ok = $false; ReasonKey = 'guide.reason.noEngine'; RemedyKey = 'guide.remedy.setup' } }
                if ($fitting.Count -eq 0) { return @{ Ok = $false; ReasonKey = 'guide.reason.noFittingTier'; RemedyKey = 'guide.remedy.hwscan' } }
                if ($dumps.Count -eq 0) { return @{ Ok = $false; ReasonKey = 'guide.reason.noDump'; RemedyKey = 'guide.remedy.collectFirst' } }
                return @{ Ok = $true }
            }
            'agent' {
                if (-not $engineOk) { return @{ Ok = $false; ReasonKey = 'guide.reason.noEngine'; RemedyKey = 'guide.remedy.setup' } }
                if ($agentInstalled.Count -eq 0) { return @{ Ok = $false; ReasonKey = 'guide.reason.noAgentTier'; RemedyKey = 'guide.remedy.setupMid' } }
                if ($agentic.Count -eq 0) { return @{ Ok = $false; ReasonKey = 'guide.reason.agentTierTooBig'; RemedyKey = 'guide.remedy.freeMemory' } }
                return @{ Ok = $true }
            }
            'ask' {
                if (-not $authOk) { return @{ Ok = $false; ReasonKey = 'guide.reason.noAuth'; RemedyKey = 'guide.remedy.authLogin' } }
                if (-not $online) { return @{ Ok = $false; ReasonKey = 'guide.reason.offline'; RemedyKey = 'guide.remedy.useOffline' } }
                return @{ Ok = $true }
            }
            'chat' {
                if (-not $authOk) { return @{ Ok = $false; ReasonKey = 'guide.reason.noAuth'; RemedyKey = 'guide.remedy.authLogin' } }
                if (-not $online) { return @{ Ok = $false; ReasonKey = 'guide.reason.offline'; RemedyKey = 'guide.remedy.useOffline' } }
                return @{ Ok = $true }
            }
            default { return @{ Ok = $false; ReasonKey = 'guide.reason.unknown'; RemedyKey = 'guide.remedy.none' } }
        }
    }

    $result = New-Object System.Collections.Generic.List[object]
    $n = 0
    $ids = @($Order)
    if ($ids.Count -eq 0) { $ids = @($script:LokiGuideOrder) }
    foreach ($id in $ids) {
        $n++
        $verdict = & $decide $id

        # The teaching line: the command line this entry stands for. It is shown AFTER the step runs, which is the
        # whole learning-curve mechanism -- a guided mode that never names what it did produces dependants, not
        # operators. For `analyze` the newest dump is named explicitly, because "the path" is precisely the part a
        # newcomer cannot guess.
        # INTERACTIVE means "this one needs the console itself, and cannot be captured into a transcript".
        # Measured, not guessed (ADR-0040), and it is exactly two of the six:
        #   chat   -> lib/claude.ps1 launches the Claude CLI with NO stream redirected on purpose, so the child
        #             inherits stdin/stdout/stderr and is a live TUI the operator drives.
        #   agent  -> lib/offline-agent.ps1 asks Read-Host before every mutating command. A confirm prompt captured
        #             into a transcript is a prompt nobody can answer.
        # Everything else writes only through the ui.ps1 seam or through an already-redirected child, so a session
        # captures it whole. Getting this list wrong in the SAFE direction costs a screen flash; getting it wrong
        # the other way hangs the session on a prompt the operator cannot see.
        $target = $id
        $cmdArgs = @()
        $teach = "loki $id"
        $interactive = ($id -eq 'chat' -or $id -eq 'agent')
        if ($id -eq 'analyze') {
            $target = 'offline'
            $teach = 'loki offline --analyze <dump>'
            if ($dumps.Count -gt 0) {
                $newest = @($dumps)[0]
                $cmdArgs = @('--analyze', [string]$newest.FullName)
                $teach = "loki offline --analyze reports\{0}" -f [string]$newest.Name
            }
        }
        elseif ($id -eq 'agent') {
            $target = 'offline'
            $cmdArgs = @('--agent')
            $teach = 'loki offline --agent'
        }

        $result.Add(@{
                Number    = $n
                Id        = $id
                LabelKey  = "guide.opt.$id"
                Available = [bool]$verdict.Ok
                ReasonKey = $(if ($verdict.ContainsKey('ReasonKey')) { [string]$verdict.ReasonKey } else { '' })
                RemedyKey = $(if ($verdict.ContainsKey('RemedyKey')) { [string]$verdict.RemedyKey } else { '' })
                Target      = $target
                Args        = $cmdArgs
                Teach       = $teach
                Interactive = $interactive
            })
    }
    return , @($result.ToArray())
}

function Resolve-LokiGuideChoice {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Options,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Choice
    )

    $text = ([string]$Choice).Trim()
    # Empty input is a quit, not an error: pressing Enter to get out is what everyone tries first.
    if ($text -eq '') { return @{ Kind = 'quit'; Option = $null; ReasonKey = '' } }
    if ($text -eq 'q' -or $text -eq 'Q' -or $text -eq '0') { return @{ Kind = 'quit'; Option = $null; ReasonKey = '' } }

    $n = 0
    if (-not [int]::TryParse($text, [ref]$n)) {
        return @{ Kind = 'invalid'; Option = $null; ReasonKey = 'guide.error.notANumber' }
    }

    $match = $null
    foreach ($o in @($Options)) {
        if ([int]$o.Number -eq $n) { $match = $o; break }
    }
    if ($null -eq $match) { return @{ Kind = 'invalid'; Option = $null; ReasonKey = 'guide.error.outOfRange' } }

    # Refused, not hidden: the entry keeps its number (rule 1) and the refusal repeats the reason, so choosing an
    # unavailable option is itself a way of asking "why not?".
    if (-not [bool]$match.Available) {
        return @{ Kind = 'unavailable'; Option = $match; ReasonKey = [string]$match.ReasonKey }
    }
    return @{ Kind = 'run'; Option = $match; ReasonKey = '' }
}

function Get-LokiGuideMenuLine {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Options)
    # PURE. The menu as lines, resolved through the catalog, with no colour and no console call.
    #
    # It exists because there are now TWO renderers -- the coloured one-shot fallback and the session transcript --
    # and the format string must not exist twice. When it did, for about ten minutes while this was being written,
    # the two indentations had already drifted by a space (CLAUDE.md section 2: one source of truth per concept).
    #
    # Role, not colour: the session cannot colour anything, because an escape sequence inside a screen model is
    # counted as content by the diff and shifts every column after it (ADR-0039). The fallback maps 'muted' to
    # DarkGray; the session simply writes the same text.
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($o in @($Options)) {
        $label = Get-LokiText ([string]$o.LabelKey)
        if ([bool]$o.Available) {
            $out.Add(@{ Text = ("  {0}) {1}" -f $o.Number, $label); Role = 'available' })
            continue
        }
        # Shown, numbered and muted -- never hidden. Hiding it would answer "can I do this here?" with silence,
        # and the two lines below are the most useful thing on the screen for someone new to the tool.
        $out.Add(@{ Text = ("  {0}) {1}" -f $o.Number, $label); Role = 'muted' })
        $out.Add(@{ Text = ("       {0}" -f (Get-LokiText ([string]$o.ReasonKey))); Role = 'muted' })
        $out.Add(@{ Text = ("       {0}" -f (Get-LokiText ([string]$o.RemedyKey))); Role = 'muted' })
    }
    # A PLAIN return, deliberately NOT the `return , @(...)` that Get-LokiGuideMenu uses two functions up.
    # That idiom keeps a set from unrolling, and it costs every caller a two-step assignment -- `@(FUNC)` around it
    # yields ONE element holding the whole array, which is why Get-LokiGuideMenu carries a warning comment at each
    # of its call sites. Here every caller wants to iterate, so unrolling is exactly right: N lines come back as N,
    # one line as one, and none as nothing. Written the other way first, and the tests caught it.
    return $out.ToArray()
}

function Get-LokiGuideEngineLabel {
    param([Parameter(Mandatory = $true)][hashtable]$State)
    # PURE. Returns a CATALOG KEY, not prose -- this file resolves nothing the caller might want in another locale.
    #
    # Online wins when both are available, because that is the order Loki's own commands prefer: `ask` and `chat`
    # are the online path and sit above the offline entries in the menu. "none" is not an error state -- a stick
    # with no model and no credential still runs `collect` and `doctor`, which is most of what it is for.
    $authOk = [bool]$State.AuthPresent
    $online = [bool]$State.Online
    if ($authOk -and $online) { return 'guide.engine.online' }
    if ([bool]$State.EngineOk -and @($State.FittingTiers).Count -gt 0) { return 'guide.engine.offline' }
    return 'guide.engine.none'
}

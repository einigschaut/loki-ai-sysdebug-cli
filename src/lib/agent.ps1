# lib/agent.ps1 -- the offline engine harness: start llama-server, know when it is ready, and never leak it
# (security core, CLAUDE.md section 5; DESIGN.md section 2.2 names `agent` as its own lib; ADR-0015).
#
# WHY THIS EXISTS. lib/engine.ps1 puts the engine on the stick and lib/integrity.ps1 proves it is the pinned build.
# Nothing yet RUNS it. This module owns the process: it refuses to start an engine it cannot vouch for, starts it in a
# shape the target machine cannot weaken, waits for it to actually answer, and guarantees it is gone afterwards.
#
# THE TARGET'S ENVIRONMENT IS HOSTILE-BY-DEFAULT, and that is not a pose: Loki is plugged into a machine precisely
# BECAUSE something is wrong with it. Two measured facts (2026-07-16, against the pinned b10038 binary -- see ADR-0015;
# none of this is recalled) shape everything below:
#   * llama-server reads ~132 LLAMA_ARG_* environment variables, one per flag, plus four UNDOCUMENTED AIP_* variables
#     that appear in llama-server-impl.dll and in no --help output. lib/env-isolate.ps1 hands the child a COPY of the
#     full parent environment, so every one of them reaches the engine from the target machine.
#   * an explicit command-line flag BEATS its environment twin, always. Measured: LLAMA_ARG_HOST=0.0.0.0 could not
#     move a server started with --host 127.0.0.1. The variables are DEFAULTS, not overrides.
# So the defence is two-layered, and it has to be, because each layer covers the other's gap:
#   1. Pass every security-relevant flag EXPLICITLY (Get-LokiLlamaServerArgs). This survives a strip list going stale
#      when a future build adds a variable nobody here has heard of.
#   2. STRIP the engine's whole environment namespace (Get-LokiEngineChildEnv). This covers the flags that have no
#      negated form -- `--metrics` and `--props` can be turned ON by an env var and there is no --no-metrics to say
#      otherwise, so for those the flag layer has nothing to say.
#
# Contract:
#   Get-LokiLlamaServerArgs -ModelPath -Port -CtxSize -Threads -> [string[]]  PURE. The argv, security flags included.
#   Get-LokiEngineChildEnv -AppRoot [-BaseEnv <IDictionary>] -> [hashtable]  isolated block, engine namespace stripped.
#   Get-LokiFreeLoopbackPort [-Attempts <int>] -> [int] or 0  a port that was free a moment ago (see the note there).
#   Get-LokiEngineOrphan -ServerExePath <path> -> [object[]]  processes running THIS stick's engine exe. Never kills.
#   Resolve-LokiEnginePreflight -AppRoot -Engine -Runtime -Model -> [hashtable]{ Ok; Reason; ... }
#       may-we-start, answered before anything is launched. Reasons are stable machine tokens:
#       engine-unverified | model-unverified | runtime-unavailable | insufficient-ram | engine-already-running | ok.
#       insufficient-ram also carries Verdict (fits-if-freed | too-big | ram-unknown | ram-implausible) + NeedFreeGB,
#       so the caller can tell "close something and retry" from "never on this machine" (ADR-0017).
#   Wait-LokiEngineReady -Port -Process -TimeoutSec -> [hashtable]{ Ok; Reason; ElapsedMs }  ready | exited | timeout.
#   Start-LokiEngineServer -ServerExePath -ArgList -ChildEnv -> [hashtable]{ Ok; Reason; [Process]; [StdOut]; [StdErr] }
#       StdOut/StdErr are Task[string] -- the drained pipes; they complete when the process exits.
#   Get-LokiProcessOutputTail -Task [-MaxLines] [-TimeoutMs] -> [string]  the last lines, or '' -- never throws, never blocks.
#   Stop-LokiEngineServer -Process [-TimeoutMs] -> [bool]  idempotent; $true once the process is gone.
#   Invoke-LokiWithEngine -... -Body <scriptblock> -> [hashtable]{ Ok; Reason; [Result]; [EngineLog] }
#       the ONLY intended entry point: preflight -> start -> ready -> run Body -> ALWAYS stop.
# ASCII-only file -> no BOM (CLAUDE.md section 1).
Set-StrictMode -Version Latest

# The engine's own environment namespace. Everything llama-server reads about itself starts with one of these, so
# stripping the prefixes -- rather than listing 132 variable names -- is the part that does not rot when the engine is
# bumped. LLAMA_API_KEY and HF_TOKEN are spelled out because they are the two that do NOT carry the LLAMA_ARG_ prefix.
$script:LokiEngineEnvPrefixes = @('LLAMA_ARG_', 'AIP_')
$script:LokiEngineEnvNames = @('LLAMA_API_KEY', 'HF_TOKEN')

function Get-LokiLlamaServerArgs {
    <#
        PURE: the exact argv llama-server is started with. Pure so the security decisions below are table-testable
        WITHOUT starting a server -- a guard you can only check by launching a process is a guard nobody checks.

        Every flag here is present for a reason a review should be able to challenge:
          --host 127.0.0.1  loopback ONLY. This is a diagnostic LLM holding the contents of someone's event log; it
                            must not be reachable from the target's network. Measured: the flag beats LLAMA_ARG_HOST.
          --no-webui        the Web UI is default ENABLED (verified against --help on b10038: "--ui, --webui, --no-ui,
                            --no-webui ... (default: enabled)"). A CLI has no use for it, and it is attack surface.
          --no-slots        /slots is default ENABLED and serves the prompt CONTENTS of every slot -- i.e. exactly the
                            diagnostic data we just read off the machine, to anything that can reach the port.
          --jinja           default enabled TODAY, passed anyway: not passing it is what lets LLAMA_ARG_JINJA=0 on the
                            target turn the chat template off, and a Qwen3 without its template does not answer, it
                            rambles. Explicit is what makes the environment irrelevant.
          --ctx-size        MANDATORY, never defaulted. The default is 0 = "take it from the model", which hands the
                            RAM decision to a file: the `small` tier declares 262144 tokens of context, and Loki runs
                            on whatever machine it is plugged into. The POLICY (how much context fits here) belongs to
                            the caller; this function only refuses to leave the question open.
          --threads         explicit for the same reason -- default is -1 (auto), which LLAMA_ARG_THREADS can move.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns the argument VECTOR (argv), not one argument; the plural is the accurate name and the singular would be a lie about the return type.')]
    param(
        [Parameter(Mandatory = $true)][string]$ModelPath,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][int]$CtxSize,
        [Parameter(Mandatory = $true)][int]$Threads
    )
    if ($Port -le 0 -or $Port -gt 65535) { throw "Agent: port $Port is not a usable TCP port." }
    if ($CtxSize -le 0) { throw 'Agent: CtxSize must be positive -- 0 would mean "let the model decide the RAM".' }
    if ($Threads -le 0) { throw 'Agent: Threads must be positive -- -1 would mean "auto", which the environment can move.' }

    # Leading comma: an array returned bare is unrolled by the pipeline and the caller gets loose strings.
    return , @(
        '--model', $ModelPath,
        '--host', '127.0.0.1',
        '--port', [string]$Port,
        '--ctx-size', [string]$CtxSize,
        '--threads', [string]$Threads,
        '--jinja',
        '--no-webui',
        '--no-slots'
    )
}

function Get-LokiEngineChildEnv {
    <#
        The isolated environment block for llama-server, with the engine's own namespace removed.

        lib/env-isolate.ps1 deliberately hands a child a COPY of the FULL parent environment with Loki's redirects
        overlaid ("redirect instead of clean up", ADR-0003). That is right for PATH and SystemRoot and wrong for
        LLAMA_ARG_*: those come from the machine under investigation and configure the engine we are about to trust.
        Same reasoning, and the same shape, as lib/claude.ps1 stripping inherited auth vars from Claude Code's block.

        This is layer 2 of the defence. It is not redundant with the explicit flags: `--metrics` and `--props` have no
        negated form, so LLAMA_ARG_ENDPOINT_METRICS / LLAMA_ARG_ENDPOINT_PROPS can switch endpoints ON and no flag can
        answer back. Stripping is the only thing that speaks for those.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [System.Collections.IDictionary]$BaseEnv
    )
    $isolated = Get-LokiIsolatedEnv -StickRoot $AppRoot
    if ($null -eq $BaseEnv) { $childEnv = New-LokiChildEnvBlock -Isolated $isolated }
    else { $childEnv = New-LokiChildEnvBlock -Isolated $isolated -BaseEnv $BaseEnv }

    # ToArray first: removing from a hashtable while enumerating its keys throws under 5.1.
    foreach ($k in @($childEnv.Keys)) {
        $name = [string]$k
        $drop = $false
        foreach ($p in $script:LokiEngineEnvPrefixes) {
            # -like with a CultureInvariant-safe comparison is not available; StartsWith with an explicit ORDINAL
            # comparison is. Culture-sensitive folding here would be the tr-TR bug again: 'LLAMA_ARG_' contains an A
            # and an I, and OrdinalIgnoreCase never folds anything.
            if ($name.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)) { $drop = $true; break }
        }
        if (-not $drop) {
            foreach ($n in $script:LokiEngineEnvNames) {
                if ([string]::Equals($name, $n, [System.StringComparison]::OrdinalIgnoreCase)) { $drop = $true; break }
            }
        }
        if ($drop) { [void]$childEnv.Remove($k) }
    }
    return $childEnv
}

function Get-LokiFreeLoopbackPort {
    <#
        A loopback port that was free a moment ago. Asking the OS for port 0 and reading back what it assigned is the
        only way to learn a free port; the gap between releasing it and llama-server binding it is an unavoidable race,
        so this is a HINT and the caller must treat a bind failure as normal. It is not a lie as long as nobody reads
        it as a reservation -- hence the name, and hence -Attempts.

        Loopback specifically: binding the probe to 0.0.0.0 could hand back a port that is free on all interfaces but
        taken on 127.0.0.1, which is the only interface the engine will ever use.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'A failed probe IS this loop''s normal path -- it retries, and exhausting -Attempts is reported as 0 to the caller. Writing an error per attempt would turn a transient socket race into console noise on a tool people run when something is already wrong.')]
    param([int]$Attempts = 5)
    for ($i = 0; $i -lt $Attempts; $i++) {
        $listener = $null
        try {
            $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
            $listener.Start()
            $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
            if ($port -gt 0) { return $port }
        }
        catch { }
        finally { if ($null -ne $listener) { $listener.Stop() } }
    }
    return 0
}

function Get-LokiEngineOrphan {
    <#
        Processes running THIS stick's engine executable. Identity comes from the image PATH, deliberately, and there
        is no PID marker file anywhere in this module: a marker records a PID, Windows recycles PIDs, and a tool whose
        job is to be safe on someone else's machine must never kill a number it read out of a stale file. A process
        whose image is our exe, on our stick, is self-identifying and needs no bookkeeping to corroborate.

        Reports; never kills. An orphan means an earlier Loki was killed hard -- that is the operator's situation to
        understand, and terminating processes we did not start is not a decision a library gets to make silently.

        .Path is not readable for processes owned by other users; those are not ours by definition, so a failure to
        read is a skip, not an error.
    #>
    param([Parameter(Mandatory = $true)][string]$ServerExePath)
    $found = New-Object System.Collections.Generic.List[object]
    $name = [System.IO.Path]::GetFileNameWithoutExtension($ServerExePath)
    foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = [string]$p.Path } catch { continue }
        if ([string]::IsNullOrEmpty($path)) { continue }
        if ([string]::Equals($path, $ServerExePath, [System.StringComparison]::OrdinalIgnoreCase)) { $found.Add($p) }
    }
    # NO leading comma here, unlike Get-LokiEngineExpectedSet -- and the difference is not style, it is the sign of
    # the answer. `return , $array` emits the array as ONE object, so a caller writing the defensive @(...) gets
    # Count=1 whether the array holds 0 items or 20. Measured, after this function told every clean stick it already
    # had an engine running and then died reading .Id off the empty array it had wrapped. The comma is right for a
    # HashSet (which PowerShell would otherwise unroll into loose strings, losing .Contains); it is a landmine for a
    # possibly-empty array whose whole purpose is to be counted. Callers wrap this in @() and get a real count.
    return $found.ToArray()
}

function Resolve-LokiEnginePreflight {
    <#
        May we start? Answered BEFORE a process exists, because every reason below is cheaper to report than to debug
        as a crash.

        ADR-0014 section "Consequences" left this as a written obligation: the harness must verify the engine AND the
        model before llama-server, and treat any non-`verified` result -- INCLUDING a model that is merely
        `not-installed` -- as fatal. `not-installed` is not fatal to lib/integrity.ps1 (a stick may legitimately carry
        a subset of tiers, ADR-0013) and it is absolutely fatal here: we are about to load THIS model.

        RAM is re-measured, never taken from a stored hwscan: the tier was chosen on the SETUP machine, and the whole
        point of the stick is that it gets carried to a different one.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [Parameter(Mandatory = $true)]$Engine,
        [Parameter(Mandatory = $true)]$Runtime,
        [Parameter(Mandatory = $true)]$Model
    )
    $ErrorActionPreference = 'Stop'

    $layout = Get-LokiEngineLayout -AppRoot $AppRoot -Engine $Engine
    $runtimeFiles = [string[]]@($Runtime.Files)

    # An engine already serving from this stick means an earlier run was killed hard. Reported first: it explains the
    # port collision and the missing RAM that every later reason would otherwise blame on the machine.
    $orphans = @(Get-LokiEngineOrphan -ServerExePath $layout.ServerExePath)
    if ($orphans.Count -gt 0) {
        return @{ Ok = $false; Reason = 'engine-already-running'; Pids = @($orphans | ForEach-Object { $_.Id }) }
    }

    $engineState = Test-LokiEngineIntegrity -Layout $layout -Engine $Engine -PreserveNames $runtimeFiles
    if (-not $engineState.Ok) {
        return @{ Ok = $false; Reason = 'engine-unverified'; Detail = [string]$engineState.Reason }
    }

    $modelsDir = (Get-LokiModelLayout -AppRoot $AppRoot).Dir
    $modelState = Test-LokiModelIntegrity -Entry $Model -ModelsDir $modelsDir
    if (-not $modelState.Ok) {
        return @{ Ok = $false; Reason = 'model-unverified'; Detail = [string]$modelState.Reason; Id = [string]$Model.Id }
    }

    # The runtime is not integrity, it is loadability: without it llama-server dies in the Windows loader with a
    # message no operator can act on.
    $rt = Resolve-LokiVcRuntimeAvailability -Directory $layout.Dir -Files $runtimeFiles `
        -MinVersion ([string]$Runtime.MinVersion) -RegistryKey ([string]$Runtime.RegistryKey)
    if (-not $rt.Ok) {
        return @{ Ok = $false; Reason = 'runtime-unavailable'; Detail = [string]$rt.Reason }
    }

    $hw = Get-LokiHardwareProfile
    # NOT [double]-cast: $null casts to 0.0, which would turn "the probe could not read this machine" into "this
    # machine has no RAM" -- both refuse, but only the uncast form can say WHICH, and Get-LokiHardwareProfile's whole
    # contract is that a field may be $null.
    $fit = Get-LokiTierFit -TotalRamGB $hw.TotalRamGB -AvailableRamGB $hw.AvailableRamGB -ResidentGB $Model.ResidentGB
    if ([string]$fit.Verdict -ne 'fits') {
        # Verdict travels so the caller can tell "close something and retry" from "never on this machine" (ADR-0017).
        return @{ Ok = $false; Reason = 'insufficient-ram'; Verdict = [string]$fit.Verdict
            NeedGB = [double]$Model.ResidentGB; NeedFreeGB = $fit.NeedFreeGB; Id = [string]$Model.Id
        }
    }

    return @{ Ok = $true; Reason = 'ok'; ModelPath = [string]$modelState.Path
        ServerExePath = [string]$layout.ServerExePath
    }
}

function Wait-LokiEngineReady {
    <#
        Poll /health until the engine answers. Measured on the real b10038 + Qwen3-1.7B: 503 while the model loads,
        then 200 {"status":"ok"} after ~2.2s. (/health could not be confirmed by scanning the binary for the string --
        C++ inlines short literals -- so it was confirmed by starting the thing. It exists.)

        The process is watched as well as the port, because the failure that matters most is the engine dying during
        load: without this, a model too large for the machine turns a 4-second crash into a full TimeoutSec of silence
        and then the wrong diagnosis.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'A failed probe IS the normal path while an engine loads: connection-refused before the socket is up, then 503 until the model is in. The loop''s three exits (ready / exited / timeout) ARE the report; an error per 250ms poll would bury it.')]
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)]$Process,
        [int]$TimeoutSec = 300
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if ($Process.HasExited) {
            return @{ Ok = $false; Reason = 'exited'; ExitCode = [int]$Process.ExitCode; ElapsedMs = [int]$sw.ElapsedMilliseconds }
        }
        try {
            $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/health" -f $Port) -UseBasicParsing -TimeoutSec 3
            if ([int]$r.StatusCode -eq 200) { return @{ Ok = $true; Reason = 'ready'; ElapsedMs = [int]$sw.ElapsedMilliseconds } }
        }
        catch {
            # 503 = still loading, connection refused = not listening yet. Both are the normal path, not an error.
        }
        Start-Sleep -Milliseconds 250
    }
    return @{ Ok = $false; Reason = 'timeout'; ElapsedMs = [int]$sw.ElapsedMilliseconds }
}

function ConvertTo-LokiArgumentString {
    <#
        PURE: an argv array -> the single command-line string Windows actually takes, quoted so the child's parser
        hands back exactly the array we started with.

        Two rules, both of them Windows' (CommandLineToArgvW), neither of them obvious:
          * Quote everything. 'C:\Users\Chris Veit\models\nano.gguf' is an ordinary profile path, and unquoted it is
            two arguments -- the engine would then report a model it was never given.
          * DOUBLE a run of backslashes that ends an argument. A backslash immediately before the closing quote
            escapes it, so a naive "C:\dir\" passes a quote as DATA and swallows the next argument whole.
        Unreachable with today's inputs (every value is a flag, a number, or a path ending in .gguf), and written
        anyway: this is the one place a path off the operator's disk becomes a command line, and "it cannot happen
        with the inputs we have today" is the sentence that precedes the bug report.

        Pure so the rules can be checked against a table instead of against a process -- and checked against a real
        process ONCE, in the tests, because a quoting rule nobody confronted with the actual parser is a guess.
    #>
    # AllowEmptyString as well as AllowEmptyCollection: '' is a legitimate argv element (it must reach the child as
    # ""), and without this the binder rejects it before the function can say so. Not reachable from this module's own
    # callers -- the point of a pure primitive is that it is correct for its inputs, not only for today's.
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$ArgList)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($a in $ArgList) {
        $v = [string]$a
        $v = $v -replace '(\\*)"', '$1$1\"'   # backslashes before an embedded quote double; the quote is escaped
        $v = $v -replace '(\\+)$', '$1$1'     # backslashes at the end double, or they escape our closing quote
        $parts.Add('"' + $v + '"')
    }
    return ($parts -join ' ')
}

function Start-LokiEngineServer {
    <#
        Start llama-server with an explicit environment block and no shell.

        ProcessStartInfo rather than Start-Process, for one reason that matters: it takes an explicit
        EnvironmentVariables dictionary, so the child gets EXACTLY the block Get-LokiEngineChildEnv built. Start-Process
        has no equivalent, and the alternative -- mutating $env: in this process and restoring it afterwards -- is the
        "clean up after yourself" pattern ADR-0003 rejects, because an interrupt between the two leaves the operator's
        own shell modified.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Library primitive, not a user-facing cmdlet: -WhatIf would return a "started" result over a process that does not exist, and -Confirm would prompt in the -NonInteractive child context this exists to serve. The decision to start is Resolve-LokiEnginePreflight''s.')]
    param(
        [Parameter(Mandatory = $true)][string]$ServerExePath,
        [Parameter(Mandatory = $true)][string[]]$ArgList,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$ChildEnv
    )
    $ErrorActionPreference = 'Stop'
    if (-not (Test-Path -LiteralPath $ServerExePath -PathType Leaf)) {
        return @{ Ok = $false; Reason = 'server-exe-missing' }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ServerExePath
    $psi.Arguments = ConvertTo-LokiArgumentString -ArgList $ArgList
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = (Split-Path -Parent $ServerExePath)
    $psi.EnvironmentVariables.Clear()
    foreach ($k in $ChildEnv.Keys) { $psi.EnvironmentVariables[[string]$k] = [string]$ChildEnv[$k] }

    $p = $null
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    catch { return @{ Ok = $false; Reason = 'start-failed'; Error = $_.Exception.Message } }

    # Both pipes MUST be drained or the child blocks forever once a buffer fills, and llama-server is chatty while a
    # model loads -- "the engine hangs at 60%" would be our own unread pipe.
    # ReadToEndAsync, deliberately, NOT BeginOutputReadLine + a ScriptBlock event handler: the handler would be invoked
    # by .NET on a threadpool thread that has no PowerShell runspace to run it, which is unreliable under 5.1 in
    # exactly the way that produces an intermittent hang nobody can reproduce. This is pure .NET; no callback into
    # PowerShell exists, so there is nothing to schedule. The tasks complete when the pipes close (i.e. on exit), and
    # Get-LokiProcessOutputTail turns them into the diagnosis for a start that failed.
    return @{ Ok = $true; Reason = 'started'; Process = $p
        StdOut = $p.StandardOutput.ReadToEndAsync(); StdErr = $p.StandardError.ReadToEndAsync()
    }
}

function Get-LokiProcessOutputTail {
    <#
        The last few lines of a drained pipe, once the process behind it is gone.

        Exists because 'engine-not-ready:exited' on its own is a dead end for whoever has to act on it: llama-server
        says WHY it died (a model too large, an unsupported quant, a missing dll) on stderr and then is never asked.
        Waits with a bound rather than on .Result, which blocks forever if the pipe is somehow still open.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Task,
        [int]$MaxLines = 12,
        [int]$TimeoutMs = 2000
    )
    if ($null -eq $Task) { return '' }
    try {
        if (-not $Task.Wait($TimeoutMs)) { return '' }
        $text = [string]$Task.Result
        if ([string]::IsNullOrWhiteSpace($text)) { return '' }
        $lines = @($text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($lines.Count -le $MaxLines) { return ($lines -join "`n") }
        return (($lines[($lines.Count - $MaxLines)..($lines.Count - 1)]) -join "`n")
    }
    catch { return '' }
}

function Stop-LokiEngineServer {
    <#
        Idempotent: returns $true once the process is gone, whether we killed it or it was already dead.

        Kill(), not CloseMainWindow(): llama-server is started with CreateNoWindow and has no message loop to close,
        so a graceful request has nothing to arrive at. There is no persistent state to corrupt -- the engine holds a
        read-only mmap of the model and an HTTP socket.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Called from the finally block whose entire purpose is that it cannot be skipped. -Confirm would prompt where nobody can answer (-NonInteractive), and -WhatIf would report success while leaving a multi-GB engine running on someone else''s machine -- i.e. both switches would break the one guarantee this function exists to make.')]
    param(
        # AllowNull: "there is nothing to stop" is a legitimate answer to "is it stopped?", and the caller in the
        # `finally` below must be able to ask it without first proving a process exists. A mandatory parameter rejects
        # $null at the BINDER, before the function's own null check ever runs.
        [Parameter(Mandatory = $true)][AllowNull()]$Process,
        [int]$TimeoutMs = 10000
    )
    if ($null -eq $Process) { return $true }
    try {
        if ($Process.HasExited) { return $true }
        $Process.Kill()
        return [bool]$Process.WaitForExit($TimeoutMs)
    }
    catch {
        # Already gone between the check and the Kill -- the outcome we wanted either way.
        try { return [bool]$Process.HasExited } catch { return $true }
    }
}

function Invoke-LokiWithEngine {
    <#
        The intended entry point, and the reason this module is one function and not five loose ones: the engine is
        started and stopped around Body, and the stop is in a `finally`.

        A leaked llama-server is not an untidy detail on a machine Loki was carried to -- it is a multi-GB process
        holding a model open, on someone else's computer, after the tool that started it has exited. The only way that
        guarantee survives a Body that throws is if no caller is ever trusted to remember it, which is why Body is a
        parameter here rather than something a caller sequences for itself.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [Parameter(Mandatory = $true)]$Engine,
        [Parameter(Mandatory = $true)]$Runtime,
        [Parameter(Mandatory = $true)]$Model,
        [Parameter(Mandatory = $true)][int]$CtxSize,
        [Parameter(Mandatory = $true)][int]$Threads,
        [Parameter(Mandatory = $true)][scriptblock]$Body,
        [int]$ReadyTimeoutSec = 300
    )
    $ErrorActionPreference = 'Stop'

    $pre = Resolve-LokiEnginePreflight -AppRoot $AppRoot -Engine $Engine -Runtime $Runtime -Model $Model
    if (-not $pre.Ok) { return $pre }

    $port = Get-LokiFreeLoopbackPort
    if ($port -eq 0) { return @{ Ok = $false; Reason = 'no-free-port' } }

    $argList = Get-LokiLlamaServerArgs -ModelPath ([string]$pre.ModelPath) -Port $port -CtxSize $CtxSize -Threads $Threads
    $childEnv = Get-LokiEngineChildEnv -AppRoot $AppRoot

    $started = Start-LokiEngineServer -ServerExePath ([string]$pre.ServerExePath) -ArgList $argList -ChildEnv $childEnv
    if (-not $started.Ok) { return $started }

    $proc = $started.Process
    try {
        $ready = Wait-LokiEngineReady -Port $port -Process $proc -TimeoutSec $ReadyTimeoutSec
        if (-not $ready.Ok) {
            # Stop FIRST, then read: the pipes close when the process does, so the tail is only readable once it is
            # gone. (The finally below stops it again; Stop-LokiEngineServer is idempotent precisely so this is safe.)
            [void](Stop-LokiEngineServer -Process $proc)
            $tail = ''
            if ($started.ContainsKey('StdErr')) { $tail = Get-LokiProcessOutputTail -Task $started.StdErr }
            return @{ Ok = $false; Reason = ('engine-not-ready:' + $ready.Reason); ElapsedMs = $ready.ElapsedMs
                EngineLog = $tail
            }
        }
        $result = & $Body @{ Port = $port; BaseUri = ("http://127.0.0.1:{0}" -f $port); Process = $proc }
        return @{ Ok = $true; Reason = 'ok'; Result = $result }
    }
    finally {
        [void](Stop-LokiEngineServer -Process $proc)
    }
}

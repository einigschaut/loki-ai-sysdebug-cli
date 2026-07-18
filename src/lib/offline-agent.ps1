# lib/offline-agent.ps1 -- the offline AGENT loop (security core, CLAUDE.md section 5, ADR-0021).
# `offline --agent` is the multi-turn, READ-ONLY, tool-calling loop DESIGN.md section 3 promises from the ~8B tier.
# This file owns the loop, the run_command tool protocol, and the gated read-only execution; the `offline` command
# (commands/offline.ps1) only ROUTES --agent here (thin dispatcher, CLAUDE.md section 2). It REUSES, never
# re-implements: Invoke-LokiEngineChat / Protect-LokiOfflineDumpText / Get-LokiOfflineFailure (lib/offline.ps1) and
# Get-LokiAllowDecision (lib/allowlist.ps1).
#
# SECURITY (ADR-0021): Slice 2a is READ-ONLY. Every model-proposed command goes through the ONE allow-list engine and
# only a `read` decision executes; `mutate`/`denied` are refused this slice (confirm-gated mutation is 2b). The model
# proposes commands (ACTIONS, not data), so command OUTPUT is untrusted too and is neutralized before it re-enters the
# model context; the loop carries hard iteration + time caps. The dangerous parts -- grammar-constrained tool args
# (#20), gated isolated execution + the Get-Command cmdlet-resolution check (#21), and the capped loop (#22) -- land on
# this branch and get the mandatory Opus adversarial review before it merges.
#
# Contract (Slice 2a):
#   Test-LokiOfflineAgentCapable -Model <entry> -> [bool]
#       PURE. True iff the model's tier is at or above the ~8B agent floor (the `mid` tier, DESIGN.md section 3).
#       Fails safe: an unranked/unknown tier id is treated as BELOW the floor.
#   Get-LokiOfflineTierRank -> [string[]]
#       PURE. The tier-capability ranking (smallest first). Exposed so the drift test can assert every manifest tier
#       id is ranked -- a new tier nobody classified fails a test instead of silently declining.
#   Get-LokiOfflineAgentToolset -> [array]   (#20)
#       PURE. The model's entire move set: the run_command + final_answer tool schemas (OpenAI shape) that
#       Invoke-LokiEngineChat sends. llama-server constrains the arguments to each schema (ADR-0021).
#   ConvertFrom-LokiAgentToolCall [-ToolCalls <array>] [-Content <string>] -> [hashtable]{ Kind; Command?; Answer?; Reason? }   (#20)
#       PURE, fail-safe. Turns the engine reply into the loop's next move: 'run' (a command), 'final' (an answer), or
#       'none' (nothing usable). Never throws, never returns 'run' with a command it could not read.
#   Invoke-LokiOfflineAgentCommand -CommandLine <string> [-TimeoutSec -MaxOutputChars] -> [hashtable]{ Executed; Class; Reason; Output?; Truncated?; ExitCode?; TimedOut? }   (#21)
#       SECURITY CORE. Gate a model-proposed command via Resolve-LokiCommandDecision (the one runtime-safe gate) and
#       run it ONLY if it is provably 'read'. 'mutate'/'denied' are refused and NEVER executed. Output is neutralized
#       (Protect-LokiOfflineDumpText) and length-bounded before it can re-enter the model context.
#   Invoke-LokiChildReadCommand -CommandLine <string> [-TimeoutSec] -> [hashtable]{ Ok; ExitCode; StdOut; StdErr; TimedOut }   (#21)
#       Run ONE already-gated read in an isolated child Windows PowerShell (-NoProfile, -NonInteractive, command on
#       STDIN, hard timeout + kill). A failure is data, never a throw. The CALLER must have gated the command first.
#   Invoke-LokiOfflineAgent -AppRoot -Engine -Runtime -Model [-MaxIterations -TimeBudgetSec] -> [hashtable]{ Ok; Reason; Answer? }
#       The loop entry the command calls for a CAPABLE model. #21-#22 implement it; in this scaffold it is an explicit
#       WIP throw so a half-built loop can never masquerade as a working one (CLAUDE.md section 9).
# ASCII-only file -> no BOM (CLAUDE.md section 1).
Set-StrictMode -Version Latest

# Capability rank of the model tiers, smallest first -- the manifest tier ids (DESIGN.md section 3 table:
# nano 1.7B / small 4B / mid 8B / large 14B / max 32B). The agent LOOP needs a model that can plan multi-turn tool
# calls reliably; DESIGN.md puts that floor at the ~8B tier ('mid') and the local tier eval agreed. This is an ORDERED
# floor, not a fixed allow-set: a larger tier added to the catalog later is agent-capable automatically, while a NEW
# tier id that is not ranked here fails tests\offline-agent.Tests.ps1 (which asserts every manifest id is ranked)
# rather than silently passing. Below the floor, `offline --agent` declines and points at --analyze (ADR-0021) -- it
# does not run a loop DESIGN.md itself calls unreliable there.
$script:LokiOfflineTierRank = @('nano', 'small', 'mid', 'large', 'large-longctx', 'max', 'max-ceiling')
$script:LokiOfflineAgentFloorTierId = 'mid'

function Get-LokiOfflineTierRank {
    # Return a COPY (the leading comma keeps a single-element result an array) so a caller cannot mutate the policy.
    return , @($script:LokiOfflineTierRank)
}

function Test-LokiOfflineAgentCapable {
    param([Parameter(Mandatory = $true)]$Model)

    $id = [string]$Model.Id
    $rank  = $script:LokiOfflineTierRank.IndexOf($id)
    $floor = $script:LokiOfflineTierRank.IndexOf($script:LokiOfflineAgentFloorTierId)
    # Fail safe: an id not in the rank (unknown or renamed tier) is -1 -> below the floor -> not agent-capable.
    if ($rank -lt 0) { return $false }
    return ($rank -ge $floor)
}

function Get-LokiOfflineAgentToolset {
    # PURE. The model's ENTIRE move set (ADR-0021): run ONE read-only command, or give the final answer. Two narrow
    # tools, each a single string argument -- never "run a shell". llama-server compiles each `parameters` schema to a
    # grammar and constrains generation to it, so the arguments come back as well-formed JSON (malformed JSON is the
    # dominant small-model failure mode). The single-line / no-CRLF rule a JSON string cannot express is enforced later
    # at the allow-list gate (#21), not claimed here. The descriptions steer the model toward simple, unpiped reads --
    # the conservative allow-list (ADR-0006 v1) classes any pipe as a mutation, so a piped read would be refused.
    return @(
        @{
            type     = 'function'
            function = @{
                name        = 'run_command'
                description = 'Run ONE read-only Windows command to gather a single fact about this machine. One command on one line; no pipes, redirection, or ; & separators (e.g. Get-Volume, Get-CimInstance Win32_OperatingSystem, ipconfig /all). Read-only only.'
                parameters  = @{
                    type       = 'object'
                    properties = @{
                        command = @{
                            type        = 'string'
                            description = 'The single read-only command line to run, e.g. "Get-Volume" or "ipconfig /all".'
                        }
                    }
                    required   = @('command')
                }
            }
        },
        @{
            type     = 'function'
            function = @{
                name        = 'final_answer'
                description = 'Give the diagnosis and stop. Call this once the evidence gathered is enough to name the single most likely fault -- or to say the data is insufficient.'
                parameters  = @{
                    type       = 'object'
                    properties = @{
                        answer = @{
                            type        = 'string'
                            description = 'The diagnosis: the single most likely fault and the evidence for it, or "insufficient-data".'
                        }
                    }
                    required   = @('answer')
                }
            }
        }
    )
}

function ConvertFrom-LokiAgentToolCall {
    <#
        PURE, fail-safe. Turn the engine reply (the { ToolCalls?; Content? } Invoke-LokiEngineChat returns) into the
        loop's next move: { Kind; Command?; Answer?; Reason? }. Kind is 'run' (run_command -> Command), 'final'
        (final_answer, or plain prose the model gave instead of tool-calling -> Answer), or 'none' (nothing usable ->
        Reason). It NEVER throws and NEVER returns 'run' with a command it could not read -- an argument this cannot
        parse is 'none', so the gate/executor downstream is never handed a half-read command. Exactly one move per turn:
        the loop asks for one fact at a time, so extra tool calls in the same reply are ignored.
    #>
    param(
        [array]$ToolCalls = @(),
        [AllowEmptyString()][string]$Content = ''
    )
    if (($null -ne $ToolCalls) -and (@($ToolCalls).Count -gt 0)) {
        $call = @($ToolCalls)[0]
        $name = ''
        $argJson = ''
        # tool_calls come back as objects (pscustomobject under StrictMode) -- a missing .function/.name/.arguments
        # throws on property access, so every read is guarded and a miss becomes '' -> 'none', never a crash.
        try { $name = [string]$call.function.name } catch { $name = '' }
        try { $argJson = [string]$call.function.arguments } catch { $argJson = '' }
        $parsed = $null
        if (-not [string]::IsNullOrWhiteSpace($argJson)) {
            try { $parsed = $argJson | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
        }
        if ($name -eq 'run_command') {
            $cmd = ''
            if ($null -ne $parsed) { try { $cmd = [string]$parsed.command } catch { $cmd = '' } }
            if ([string]::IsNullOrWhiteSpace($cmd)) { return @{ Kind = 'none'; Reason = 'run_command-without-command' } }
            return @{ Kind = 'run'; Command = $cmd.Trim() }
        }
        if ($name -eq 'final_answer') {
            $ans = ''
            if ($null -ne $parsed) { try { $ans = [string]$parsed.answer } catch { $ans = '' } }
            if ([string]::IsNullOrWhiteSpace($ans)) { return @{ Kind = 'none'; Reason = 'final_answer-without-answer' } }
            return @{ Kind = 'final'; Answer = $ans.Trim() }
        }
        return @{ Kind = 'none'; Reason = 'unknown-tool' }
    }
    # No tool call: a model that answered in prose instead of calling final_answer. Non-empty prose is the answer
    # (robust to models that do not always tool-call); empty is nothing usable.
    if (-not [string]::IsNullOrWhiteSpace($Content)) {
        return @{ Kind = 'final'; Answer = $Content.Trim() }
    }
    return @{ Kind = 'none'; Reason = 'no-tool-call-no-content' }
}

function Invoke-LokiChildReadCommand {
    <#
        Run ONE already-gated read-only command in an isolated child Windows PowerShell, capture its output, and never
        let it outlive its welcome. The CALLER must have vetted it read-only first (Invoke-LokiOfflineAgentCommand does)
        -- this function does NOT gate, it only isolates. Isolation: -NoProfile (no profile-defined Function/Alias can
        shadow the command, the execution-layer half of the gate's Get-Command Cmdlet check), -NonInteractive (never
        prompts, never hangs on input), and a hard timeout that KILLS the child (a diagnostic on a broken machine must
        not wedge the loop). The command text goes in on STDIN (`-Command -`), never as an argument, so there is no
        argument-quoting seam. Returns { Ok; ExitCode; StdOut; StdErr; TimedOut } -- a failure is data, never a throw.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [int]$TimeoutSec = 20
    )
    $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }  # fall back to PATH; still target 5.1

    # Pass the (already-gated) command as a base64 -EncodedCommand: it travels VERBATIM with no argument-quoting seam
    # and none of the stdin-timing fragility of `-Command -`. We build the encoding ourselves from a vetted read -- this
    # is invocation, not the obfuscation the allow-list denies in MODEL input (that check guards what the model sends).
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($CommandLine))

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    # -OutputFormat Text keeps stdout plain (not CLIXML). No stdin is redirected: -NonInteractive turns any prompt into
    # a failure rather than a hang, and there is nothing to feed.
    $psi.Arguments = "-NoProfile -NonInteractive -OutputFormat Text -EncodedCommand $encoded"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $p = $null
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    catch { return @{ Ok = $false; ExitCode = -1; StdOut = ''; StdErr = 'child-start-failed'; TimedOut = $false } }

    # Drain both pipes async BEFORE waiting: a child that fills a pipe buffer would otherwise deadlock a sync read
    # (ADR-0015 learned this for the engine).
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()

    $timedOut = $false
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        $timedOut = $true
        try { $p.Kill() } catch { $null = $_ }                    # best-effort kill; a race where it already exited is fine
        try { [void]$p.WaitForExit(2000) } catch { $null = $_ }
    }

    $stdout = ''
    $stderr = ''
    try { $stdout = [string]$outTask.Result } catch { $null = $_ }   # pipes close on kill; a faulted read is just empty
    try { $stderr = [string]$errTask.Result } catch { $null = $_ }
    $exit = -1
    try { if ($p.HasExited) { $exit = [int]$p.ExitCode } } catch { $null = $_ }
    try { $p.Dispose() } catch { $null = $_ }

    return @{ Ok = (-not $timedOut); ExitCode = $exit; StdOut = $stdout; StdErr = $stderr; TimedOut = $timedOut }
}

function Invoke-LokiOfflineAgentCommand {
    <#
        SECURITY CORE (ADR-0021 point 4). Gate ONE model-proposed command and run it ONLY if it is provably read-only.
        The gate is Resolve-LokiCommandDecision -- the SAME runtime-safe engine online and offline (DESIGN.md 5.1): the
        pure allow-list classifier PLUS the runtime Get-Command Cmdlet-resolution check (a hijacked Get-* -> not a
        Cmdlet -> downgraded) PLUS the secret-target and side-effect hard-blocks. Slice 2a is READ-ONLY: only a 'read'
        decision executes; 'mutate' (would need confirmation, a 2b feature) and 'denied' are refused here and NEVER run
        -- the property this whole slice exists to make. Executed output is neutralized (Protect-LokiOfflineDumpText:
        command output off a compromised machine is untrusted data that must not break the dump fence) and bounded
        before the caller feeds it back to the model. Returns { Executed; Class; Reason; Output?; Truncated?; ExitCode?;
        TimedOut? } -- never a throw.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$CommandLine,
        [int]$TimeoutSec = 20,
        [int]$MaxOutputChars = 4000
    )
    $decision = Resolve-LokiCommandDecision -CommandLine $CommandLine
    if ($decision.Class -ne 'read') {
        # mutate OR denied -> refused. 2a runs nothing that is not provably read-only, and the executor is never even
        # reached (a Should -Invoke ... -Times 0 test pins this).
        return @{ Executed = $false; Class = [string]$decision.Class; Reason = [string]$decision.Reason }
    }

    $run = Invoke-LokiChildReadCommand -CommandLine $CommandLine -TimeoutSec $TimeoutSec

    # Give the model stdout; if a read produced nothing but errored, show the error tail so it knows WHY, then say if
    # the command was killed on timeout -- silence would be misdiagnosed.
    $raw = [string]$run.StdOut
    if ([string]::IsNullOrWhiteSpace($raw) -and (-not [string]::IsNullOrWhiteSpace([string]$run.StdErr))) {
        $raw = '[stderr] ' + [string]$run.StdErr
    }
    $raw = $raw.Trim()
    if ($run.TimedOut) { $raw = ($raw + "`r`n[command timed out after $TimeoutSec s and was stopped]").Trim() }

    $safe = Protect-LokiOfflineDumpText -DumpText $raw
    $truncated = $false
    if ($safe.Length -gt $MaxOutputChars) {
        $safe = $safe.Substring(0, $MaxOutputChars) + "`r`n[output truncated at $MaxOutputChars chars]"
        $truncated = $true
    }

    return @{
        Executed  = $true
        Class     = 'read'
        Reason    = [string]$decision.Reason
        Output    = $safe
        Truncated = $truncated
        ExitCode  = $run.ExitCode
        TimedOut  = [bool]$run.TimedOut
    }
}

function Invoke-LokiOfflineAgent {
    <#
        The read-only agent loop entry for a CAPABLE model (Test-LokiOfflineAgentCapable already said yes). Its parts
        are in place: the tool protocol (Get-LokiOfflineAgentToolset + ConvertFrom-LokiAgentToolCall, #20) and the gated
        executor (Invoke-LokiOfflineAgentCommand, #21). What remains is #22 -- the capped multi-turn loop that wires
        them to the engine (chat -> gated command -> observation -> repeat, under iteration + time caps). Until it lands
        this is an explicit WIP throw, on purpose: a security core must never ship a loop that only looks like it runs
        (CLAUDE.md section 9, "never mark a stub as done"). The whole slice merges as one reviewed unit, so this throw is
        replaced before any PR.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [Parameter(Mandatory = $true)]$Engine,
        [Parameter(Mandatory = $true)]$Runtime,
        [Parameter(Mandatory = $true)]$Model,
        [int]$MaxIterations = 8,
        [int]$TimeBudgetSec = 300
    )
    throw 'offline --agent loop is not yet wired (Slice 2a: #22 the multi-turn loop).'
}

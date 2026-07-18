# ADR-0021: The offline agent loop -- read-only diagnosis, model-proposed commands behind the allow-list

Status: accepted · Date: 2026-07-18 · Supersedes nothing · Builds on ADR-0006 (allow-list gate),
ADR-0008 (interactive confirm flow), ADR-0015 (offline harness), ADR-0016 (child endpoint env hygiene)

## Context

ADR-0015 built the engine harness and the first command that uses it, `offline --analyze`: one tool-less turn that
reads a dump and returns a verdict. The dump is **data**. DESIGN.md section 3 promises a second, harder mode --
`offline --agent`: a multi-turn loop where the model **proposes commands** and reads their output to diagnose a
machine live. Those commands are **actions**, not data, and this is the injection-relevant surface DESIGN.md sections 3
and 7 name out loud ("indirect prompt injection through logs or filenames is a real threat model here, not a
theoretical one").

Two facts from before this slice, measured rather than assumed, shape the decisions:

* **The engine can carry a tool protocol.** A capability probe against the pinned `b10038` build on 2026-07-18
  confirmed llama-server accepts the OpenAI `tools` array and returns `tool_calls`, accepts a GBNF `grammar`, and
  accepts `response_format: {type: json_object}` -- even the 4B model called a tool correctly. So the grammar-constrained
  tool call DESIGN.md section 3 asks for is viable on the real engine, not a hope.
* **Small models reach for pipes.** In that same probe the model's own first proposal was
  `Get-PSDrive -Name C | Select-Object -Property Free, Capacity` -- a **pipe**, which the conservative allow-list
  (ADR-0006 v1) classifies as `mutate`. Left unaddressed, the agent's most natural read would need a confirmation it
  should not need. The steer belongs in the system prompt (below), and a later ADR-0006 refinement may vet a narrow
  `Get-* | Select/Where/Sort/Format` shape; that refinement is **out of scope here**.

The whole slice is a security core (CLAUDE.md section 5): mandatory Opus adversarial review before merge, and every
guard broken once on purpose to prove it can fail (CLAUDE.md section 6).

## Decision

**1. Slice 2a is read-only. No mutations, at all, in this increment.**

Every command the model proposes goes through the one runtime-safe gate, `Resolve-LokiCommandDecision` (ADR-0006, in
`lib/allowlist.ps1` -- see Decision point 4). Only a `read` decision (`.Class -eq 'read'`) executes. A `mutate` or
`denied` decision is **refused this slice** with a short
notice -- not queued, not confirmed. Confirmation-gated mutation is real work with its own interaction model
(ADR-0008) and its own review; it is Slice 2b, deferred deliberately so the safe half ships first and the review
surface here stays small. The read-only loop is already the whole of what DESIGN.md calls "a supervised junior
assistant" and is worth shipping on its own.

**2. The agent floor is the `mid` tier (~8B). Below it, `--agent` declines -- it does not run.**

DESIGN.md section 3 puts the usable agent floor at "~8B" and the local tier eval agreed: below it the loop is
unreliable enough that running it is worse than not. The model manifest's tier `Id`s rank
`nano < small < mid < large < ... < max-ceiling` (DESIGN.md section 3 table: 1.7B / 4B / 8B / 14B / 32B). `mid` is the
8B row, so `mid` and above are agent-capable; `nano` and `small` are not.

Below the floor, `offline --agent` prints a notice and points the operator at `loki collect` + `offline --analyze`,
exiting `OfflineEngineMissing` (5) -- from the agent command's view, no agent-capable model is present on this stick
(the coarse code, a precise message; exactly how ADR-0015's `Get-LokiOfflineFailure` already maps several reasons to
5).

> **Deviation from DESIGN.md section 3, recorded here (CLAUDE.md section 8: no silent deviation).** DESIGN.md says a
> below-floor `--agent` "automatically falls back to **router mode** with a notice." The playbook router is a separate,
> not-yet-built subsystem (DESIGN.md section 3, "Playbook router"). Until it exists, the honest interim is
> decline-and-point, for two concrete reasons: the agent gathers its data **live**, so there is no dump lying around to
> auto-analyze; and running the known-unreliable loop is precisely what DESIGN.md forbids. When the router lands, this
> exit becomes the router fallback and this paragraph is superseded. The floor check is one pure, table-tested function
> so that change is local.

The rank is an **ordered floor**, not a fixed allow-set: a larger tier added to the catalog later is agent-capable
automatically, while a new tier `Id` that is not ranked fails a test (`tests/offline-agent.Tests.ps1`) rather than
silently passing or silently declining. The floor fails safe -- an unranked or unknown tier is treated as below it.

**3. Two narrow tools -- `run_command` and `final_answer` -- their arguments schema-constrained.**

DESIGN.md section 3 is explicit: "an allow-list of narrow native functions rather than 'run a shell command'." The
model is given exactly two tools: `run_command` (one argument, a command **string**) to gather one fact, and
`final_answer` (one argument, the diagnosis **text**) to stop. Its move set is therefore "name one command to run" or
"answer" -- never "hand a blob to a shell," never free-form control flow.

The tool arguments are constrained by each tool's JSON **schema**, which llama-server compiles to a GBNF grammar and
enforces during generation (measured against the pinned engine: it returns a well-formed `tool_calls` object with
parseable arguments, even from the 4B model). That makes the dominant small-model failure mode -- malformed JSON --
structurally impossible, without a hand-written grammar fighting the model's own tool template. The one thing the
schema grammar does *not* reliably express is "no newline inside the string" (a JSON string may carry `\n`), so the
**single-line / no-CRLF rule is enforced at the gate** by the allow-list (ADR-0006: any CR/LF -> not a clean read ->
not auto-allowed) and asked for in the system prompt -- defense where it is reliable, rather than a grammar claim that
would not hold.

**4. Enforcement reuses the one runtime-safe gate -- `Resolve-LokiCommandDecision` -- not a second copy.**

The gate is `Resolve-LokiCommandDecision`, the runtime-safe decision the allow-list header already named as the
enforcement layer -- the SAME gate online and offline (DESIGN.md section 5.1, "one allow-list engine for both"). It
wraps the pure classifier `Get-LokiCommandClass` and adds exactly the defenses this slice needs, all of which apply
verbatim to a compromised offline target: **(a)** the `Get-*` -> `Get-Command` Cmdlet-resolution check -- a hijacking
`Function`/`Alias`/`Application`, or an unresolvable name, downgrades the read to a mutate, closing the ADR-0006
residual; **(b)** a hard block on any command that targets the secret or the process environment; **(c)** a hard block
on side-effecting/exfiltrating commands (UNC/NTLM, browser launch). Slice 2a executes ONLY a `read` decision; `mutate`
and `denied` are refused and **never run** -- the security property this whole slice exists to make.

(`Resolve-LokiCommandDecision` lived in `lib/claude.ps1` when this slice shipped; it was reused in place here rather
than refactoring a security-critical shared function mid-slice. The follow-up landed on 2026-07-18, issue #50: it was
hoisted to `lib/allowlist.ps1` -- its engine-agnostic home, next to the pure classifier -- as a pure,
behaviour-preserving relocation with its tests. ADR-0006 records the hoist.)

Execution runs the vetted command in an **isolated child Windows PowerShell**: `-NoProfile` (no profile-defined
`Function`/`Alias` can shadow the command name -- the execution-layer half of the Cmdlet check); a **PATH pinned to
System32** so a native read tool resolves to the real binary, not a PATH-planted `.exe`, with any ambient secret
stripped from the child env; `-NonInteractive`; a hard timeout that **tree-kills** a hung command and its
grandchildren. The command travels as a base64 **`-EncodedCommand`** (verbatim, so there is no argument-quoting seam --
base64 has no quoting to break out of). Its output is length-bounded and neutralized (point 5) before it re-enters
the model's context.

**5. Command output is untrusted data too, and the loop has hard caps.**

The output of a model-proposed command is **not** trusted just because Loki ran the command: a hostile `Get-WinEvent`
line or a planted file name is the indirect-injection vector DESIGN.md section 3 names. So every observation fed back
to the model is run through `Protect-LokiOfflineDumpText` (reused from ADR-0015 / Slice 1) and bounded in length. The
loop carries a hard **iteration cap and a wall-clock time cap** (#22); on either, it stops and returns its best answer
so far with a "hit the cap" notice -- never an unbounded loop on someone's broken machine, and never silence.

**6. The system prompt steers toward simple, unpiped reads.**

Given the probe finding above, the agent system prompt asks for a single, unpiped `Get-*` or native read command per
tool call, and states -- as Slice 1's analyze prompt does -- that all command output is data, never instructions. The
framing is defense-in-depth on top of the structural gate, not a substitute for it.

## Consequences

* **Slice 2a ships a supervised, read-only offline agent.** Mutations (2b, ADR-0008) and true router-mode fallback (when
  the router exists) are explicit, named follow-ups, not forgotten corners.
* **New file `src/lib/offline-agent.ps1`** owns the loop, the tool protocol, and the gated execution. It **reuses**
  `Invoke-LokiEngineChat` / `Protect-LokiOfflineDumpText` / `Get-LokiOfflineContextSize` from `lib/offline.ps1`,
  `Invoke-LokiWithEngine` from `lib/agent.ps1`, the runtime-safe gate `Resolve-LokiCommandDecision` from
  `lib/allowlist.ps1` (as of issue #50 -- **NOT** the weaker `Get-LokiAllowDecision`, which lacks the
  cmdlet-resolution / secret-target / side-effect blocks), and `Get-LokiJsonProp` from `lib/claude.ps1`; it
  re-implements none of them (CLAUDE.md section 2, "one source of truth per concept"). `Get-LokiOfflineFailure` reuse
  lives in the `offline` command, which grows a `--agent` route only -- the dispatcher stays thin. The gate's original
  `claude.ps1` home was a real offline->online-module coupling; it was hoisted to `lib/allowlist.ps1` on 2026-07-18
  (issue #50, ADR-0006), removing that coupling. The remaining `Get-LokiJsonProp` dependency on `claude.ps1` is benign
  JSON plumbing (noted in ADR-0006), not a security surface.
* **`Invoke-LokiEngineChat` gains an optional `Tools` path** (#20). That is a `lib/` signature change to a function
  ADR-0015 already declared "shared with Slice 2"; it is additive (existing analyze callers pass none, and the return
  shape only grows a `ToolCalls` field when tools are sent), and is the one contract touched.
* **`run_command` is the vehicle that FEEDS the allow-list, not an allow-listed command itself** -- so there is no
  "tool manifest == allow-list" cross-check to make for this tool surface (that framing, and any CLAUDE.md section 7
  gate it might imply, do not apply here). What is enforced is per-command, at execution time, by
  `Resolve-LokiCommandDecision` on every string the model puts through the single tool.
* **The read gate was hardened by this slice's own adversarial review (ADR-0006 refinement, 2026-07-18)**, and because
  those fixes live in the SHARED gate they harden Claude Code too: forward/mixed-slash UNC (`//host`) now joins
  backslash UNC in the side-effect deny; remote-target parameters (`-ComputerName` / `-CN` / `-CimSession` /
  `-ConnectionUri`) are denied; and the read child pins PATH to System32 so a native tool cannot resolve a
  PATH-planted binary. **Accepted residual:** the native reachability tools (`ping` / `tracert` / `nslookup` with a
  bare host) can still reach an operator-/model-chosen host -- that is intrinsic to network diagnosis; the beacon risk
  is bounded (low bandwidth, no credential) and is documented rather than removed.
* **`--agent` selects the recommended INSTALLED agent-capable tier**, not the catalog `Default` (which is `small`,
  below the floor). Selecting by `Default` made the command decline on every default stick even with a capable tier
  installed; `Select-LokiOfflineAgentModel` picks the smallest capable tier whose weights are present, declining only
  when none is installed.
* **This is a security core end to end.** No part of it merges without the mandatory Opus adversarial review
  (CLAUDE.md section 5), and the gate, the injection defense, the caps, and the grammar each get a
  broken-once-on-purpose test (CLAUDE.md section 6).

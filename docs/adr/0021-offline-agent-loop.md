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

Every command the model proposes goes through the one allow-list engine (`Get-LokiAllowDecision`, ADR-0006). Only a
`read` decision (`AutoAllowed`) executes. A `mutate` or `denied` decision is **refused this slice** with a short
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

**3. One narrow tool -- `run_command` -- with its argument grammar-constrained.**

DESIGN.md section 3 is explicit: "an allow-list of narrow native functions rather than 'run a shell command'." The
model is given exactly one tool, `run_command`, whose single argument is a command **string**. The argument is
constrained by a GBNF grammar (#20) so that the dominant small-model failure mode -- malformed JSON -- is structurally
impossible, and so the string is a **single line** (no CR/LF), reinforcing at the generation layer the exact rule the
allow-list enforces at the gate (ADR-0006 step 2a). A single narrow tool keeps the model's move set to "name a command
to run," never "hand a blob to a shell."

**4. Enforcement reuses the one allow-list engine, plus the runtime check ADR-0006 promised.**

The gate is `Get-LokiAllowDecision` -- the *same* engine online and offline (DESIGN.md section 5.1, "one allow-list
engine for both"), not a second copy. On top of the pure string classifier, the offline enforcement layer (#21) adds
the defense-in-depth ADR-0006 named as a known residual: a `Get-*` auto-read is honored **only** if `Get-Command`
resolves the name to a real **Cmdlet**, not a `Function`/`Alias`/`Application` -- closing the "same-named hijacked
`Get-*` on the target's PATH" hole on the machine we are there precisely because it is compromised. Execution runs with
the child-environment hygiene of ADR-0016, and its output is length-bounded and neutralized (point 5) before it
re-enters the model's context.

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
  `Invoke-LokiEngineChat`, `Protect-LokiOfflineDumpText`, and `Get-LokiOfflineFailure` from `lib/offline.ps1` and
  `Get-LokiAllowDecision` from `lib/allowlist.ps1`; it does not re-implement any of them (CLAUDE.md section 2,
  "one source of truth per concept"). The `offline` command grows a `--agent` route only -- the dispatcher stays thin.
* **`Invoke-LokiEngineChat` gains an optional `Tools`/`Grammar` path** (#20). That is a `lib/` signature change to a
  function ADR-0015 already declared "shared with Slice 2"; it is additive (existing analyze callers pass neither), and
  is the one contract touched.
* **The `run_command` tool manifest must match the allow-list** -- CI's docs/tool-manifest gate (CLAUDE.md section 7)
  checks that the exposed tool surface and the allow-list agree, so a tool added here without its allow-list entry is a
  red build, by design.
* **This is a security core end to end.** No part of it merges without the mandatory Opus adversarial review
  (CLAUDE.md section 5), and the gate, the injection defense, the caps, and the grammar each get a
  broken-once-on-purpose test (CLAUDE.md section 6).

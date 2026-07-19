# ADR-0022: Confirmation-gated mutations in the offline agent (Slice 2b)

Status: accepted · Date: 2026-07-19 · Builds on ADR-0021 (offline agent loop, Slice 2a), ADR-0008 (interactive
confirm flow, online `chat`), ADR-0006 (allow-list gate), ADR-0016 (child endpoint env hygiene)

## Context

ADR-0021 shipped Slice 2a: a supervised, **read-only** offline agent. Every model-proposed command goes through the
one runtime-safe gate `Resolve-LokiCommandDecision`; only a `read` decision executes, and a `mutate` or `denied` is
**refused this slice**. ADR-0021 named the other half — **confirmation-gated mutation** — as Slice 2b, deferred so the
safe half shipped first.

The obvious model is ADR-0008, which opened the mutation path for the **online** `chat`: a `mutate` becomes an `ask`
that a present human confirms. But ADR-0008 leans entirely on **Claude Code's built-in interactive permission prompt**
— the online engine renders it. The **offline** engine (llama.cpp) has no such prompt. So Slice 2b cannot reuse
ADR-0008's mechanism; it needs a **Loki-side** confirmation, and this ADR is that decision.

The security stakes are the highest in the project: this is the first path that **actually executes a state-changing
command on the machine under diagnosis**. It is a security core end to end (CLAUDE.md §5): mandatory Opus adversarial
review before merge, and every guard broken once on purpose (§6).

## Decision

**1. `mutate` becomes confirmable by the operator; `denied` stays hard-denied and is NEVER offered for confirmation.**
The classification is unchanged and still single-sourced in `Resolve-LokiCommandDecision` (ADR-0006). Slice 2b only
changes what the offline agent *does* with a `mutate`: instead of refusing it, it asks the operator. The hard-block set
— secret-target / process-env, UNC/side-effect exfil, eval/arbitrary-exec, control chars (ADR-0007/0008) — is `denied`
and returns **before** any confirmation, exactly the "never offered for confirmation" guarantee ADR-0008 makes online.
A break-once test asserts a `denied` command reaches the confirm callback **zero** times.

**2. The confirmation is Loki-side, because the offline engine has no permission prompt.** `Confirm-LokiOfflineMutation`
shows the operator the exact command and the gate's machine reason (localized, ADR-0004), and reads a **y/N** answer
that **defaults to No** — only an explicit affirmative runs the command. If the process is **not interactive** (no
console / `[Environment]::UserInteractive` is false), it returns `$false` (fail-safe refuse) rather than block on a
`Read-Host` that cannot be answered.

**3. Enforcement stays in the one security-core function, with the confirmation INJECTED for testability.**
`Invoke-LokiOfflineAgentCommand` gains an optional `-ConfirmCallback` (given the command + reason, returns `$true` to
run a `mutate`). Order: `denied` → refused; `mutate` with no callback → refused (preserves Slice 2a for every existing
caller); `mutate` with a callback → run it, execute only on `$true`, otherwise **declined** (not executed); `read` →
execute as before. `Invoke-LokiOfflineAgent` wires `Confirm-LokiOfflineMutation` as the real callback; tests inject a
fake ("yes"/"no") and never touch `Read-Host`. A callback that throws is treated as **No** (fail-safe).

**4. A confirmed mutation runs in the SAME isolated child as a read — no weaker isolation for the more dangerous
command.** `Invoke-LokiChildReadCommand` (the isolated executor: `-NoProfile`/`-NonInteractive`, the tamper-resistant
System32-pinned PATH from ADR-0016 Part 3, the ambient secret stripped, base64 `-EncodedCommand`, hard timeout +
tree-kill) executes the confirmed mutate verbatim. Its name is historical ("Read"); it runs a **vetted** command — a
`read`, or a `mutate` the operator confirmed — and is not renamed mid-slice to avoid a contract break (CLAUDE.md §2).

**5. The loop distinguishes declined from refused, and feeds it back as data.** A confirmed mutate's output re-enters
the model context through the same neutralization (`Protect-LokiOfflineDumpText`) and length bound as a read (its
output is still untrusted data off a possibly-compromised machine). A **declined** mutate feeds back "the operator
declined that change — do not retry it," so the model moves on rather than looping on the same command.

**6. The charter tells the model it MAY propose a change, gated by confirmation.** Like ADR-0008's chat charter (and
unlike Slice 2a's read-only charter), the agent system prompt now says it may propose a single state-changing command
when genuinely needed — explaining what and why first, one at a time, never assuming approval — and that the hard-block
set stays refused regardless. Defense-in-depth on top of the gate, not a substitute.

## Consequences

* **`offline --agent` gains the mutation path with the operator in the loop.** No separate flag: the operator invoked
  `--agent` at a terminal and is present to answer; the confirmation prompt IS the gate. In a non-interactive
  invocation the fail-safe refuses every mutate, so the loop degrades to Slice 2a's read-only behaviour rather than
  hanging.
* **Backward-compatible by construction.** `-ConfirmCallback` is optional and defaults to none, so every Slice 2a
  caller and test that does not pass it keeps the exact read-only-or-refuse behaviour. Only `Invoke-LokiOfflineAgent`
  opts in.
* **Deferred, documented:** a dry-run/preview before a mutation and a rollback/undo (the `fix` flow, DESIGN.md Stage 2)
  are **not** here — Slice 2b is confirm-then-run. A richer Loki confirm UI (showing the model's rationale inline, a
  "always allow this session" option) is also deferred; the first cut shows command + reason + y/N.
* **Depends on the #54 gate fix (secret-target wildcard/8.3 deny) -- MERGE ORDER MATTERS.** Slice 2b turns a `mutate`
  into a confirmable, EXECUTABLE action, so a mutate-by-glob at the secret (`Remove-Item home\.e*`) would be
  operator-confirmable and run, and a read-by-glob (`Get-Content home\.e*`) would auto-run, UNLESS the gate hard-denies
  the secret-target wildcard/8.3 forms -- which is exactly PR #57 (issue #54). This branch is stacked to include #54;
  Slice 2b must NOT reach a `main` that lacks it (merge order: #57 -> #59 -> this). A break-once test pins it: a
  secret-SPECIFIC glob (`Remove-Item home\.e*`, `Get-Content home\[.]env`) stays `denied` and never reaches the confirm
  callback even when the callback would approve.
* **Residual, shared with the online chat, closed durably by #56.** The #54 fix HARD-denies secret-SPECIFIC globs but
  can only DOWNGRADE a bare `*` or an 8.3 short name (`home\*`, `home\ENV~1`) to `mutate` -- it cannot tell `ENV~1` from
  `PROGRA~1` at the string layer. Slice 2b makes such a downgraded read operator-confirmable, so an operator who
  approves a suspicious `Get-Content home\*` could read the secret-at-rest. Bounded (the model must propose it AND the
  operator must approve a command they can see; the obvious secret-targeting globs are hard-denied). The durable closure
  is storage-layer -- the secret must not be readable by ANY name from the agent cwd -- tracked at #56. This is the same
  residual the online `chat` already carries once mutations are confirmable (ADR-0008 + #54).
* **Security core, reviewed and broken-once.** Mandatory Opus review before merge (§5). Break-once tests: a `denied`
  never reaches the callback; a declined mutate is never executed (executor invoked zero times); a confirmed mutate is
  executed; a `mutate` with no callback stays refused; `Confirm-LokiOfflineMutation` maps only an explicit yes to
  `$true` and refuses in a non-interactive host.

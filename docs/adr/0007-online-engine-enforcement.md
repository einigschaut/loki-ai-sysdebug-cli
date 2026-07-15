# ADR-0007: Online-engine enforcement via a PreToolUse hook (`lib/claude.ps1`, `loki ask`)

Status: Accepted (2026-07-15)

## Context

The online engine runs Claude Code (`claude`) headless against the user's own machine to answer a
diagnostic question (`loki ask`). Something has to gate every command Claude proposes with the SAME
allow-list decision that gates the offline engine (DESIGN.md 5.1: "one allow-list engine for both"),
so that the pure classifier in `src/lib/allowlist.ps1` (ADR-0006) is the single security boundary.

The obvious wiring -- a `--permission-prompt-tool` that Loki supplies -- **does not exist**. Verified
two ways on 2026-07-15: (1) the installed `claude` CLI is **v2.1.153**, and `claude --help` lists no
such flag; (2) the official docs describe permission delegation in headless (`-p`) mode via **hooks**,
not a prompt tool. The relevant, documented facts:

- `PermissionRequest` hooks **do not fire** in non-interactive `-p` mode; **`PreToolUse` hooks do, and
  a `PreToolUse` hook can block a tool call.** ("Use `PreToolUse` hooks for automated permission
  decisions.")
- `PreToolUse` stdin: `{ session_id, cwd, permission_mode, hook_event_name:"PreToolUse", tool_name,
  tool_input:{ command } }`. For Bash, the real command line is `tool_input.command`.
- `PreToolUse` stdout on exit 0: `{ hookSpecificOutput:{ hookEventName:"PreToolUse",
  permissionDecision:"allow"|"deny"|"ask", permissionDecisionReason } }`.
- A hook `allow` does **not** override a deny rule -- explicit deny rules always win (defense in depth).

## Decision

**The enforcement layer is a `PreToolUse` hook that calls Loki's allow-list, plus a fail-closed
permission mode.** `src/lib/claude.ps1` owns it; `src/commands/ask.ps1` is thin wiring.

- **`Get-LokiPreToolUseDecision -HookInputJson`** is the headless gate. It fails closed on anything it
  cannot positively parse (empty/malformed JSON, missing `tool_name`, a non-Bash tool, a missing/blank
  command all return `deny`). For a Bash call it classifies `tool_input.command` via
  **`Resolve-LokiCommandDecision`** and maps `read -> allow`, everything else -> `deny`.
- **`Resolve-LokiCommandDecision`** is `Get-LokiCommandClass` (pure) **plus the ADR-0006 residual
  mitigation**: a `read` whose first token is a `Get-*` name is kept `read` only when `Get-Command`
  resolves that name to a real **Cmdlet** at runtime -- a hijacking Function/Alias/Application, or an
  unresolvable name, is downgraded to `mutate`. This is the promised place where that residual is
  closed; the curated pure-read list and the arg-aware ipconfig/arp/route cases are trusted by explicit
  enumeration and are not subject to the check.
- **Secret-target deny (defense in depth, from the adversarial review).** The pure allow-list trusts any
  `Get-*` by verb with any arguments, so on its own it would auto-allow a genuine read cmdlet aimed at
  the process environment or the secret file -- e.g. `Get-ChildItem Env:`, `Get-Item
  Env:\ANTHROPIC_API_KEY`, `Get-Content home\.env` -- letting the online model read the very API key it
  runs under and surface it back (into its own context, hence to the API, and into the printed answer).
  That defeats the *intent* of CLAUDE.md section 5 through a channel the "never in argv/never in logs"
  invariant does not cover. `Resolve-LokiCommandDecision` therefore blocks any otherwise-`read` command
  whose text targets the `Env:` PSDrive, a `.env` file, or an auth-variable name
  (`ANTHROPIC_API_KEY`/`CLAUDE_CODE_OAUTH_TOKEN`/`LOKI_SECRET`). The charter also tells the model those
  are off-limits. This lives in the enforcement layer (not the pure classifier) because it is specific
  to running an engine child that carries the secret in its environment.
- **Side-effecting/exfiltrating "read" denies (also from the adversarial review).** A command can be a
  provably-*local* read yet still cause an external side effect, so `Resolve-LokiCommandDecision` also
  blocks an otherwise-`read` command that: reaches a **UNC path** (`\\host\share` forces SMB auth and
  can leak the machine's NetNTLM hash to an attacker's listener); runs **`Get-Help` / `-Online`**
  (launches the default browser + a network fetch); or carries **non-space/tab whitespace or a control
  character** (the pure classifier's unsafe-char check is ASCII-only while its tokenizer is
  Unicode-aware, so a U+2028/NBSP/control char could otherwise ride along -- fail closed). The
  `tool_name` check is **case-sensitive** (`-cne 'Bash'`) so only the exact tool the harness registers
  passes. These are all defense in depth; the root cause (trusting the entire `Get-*` naming convention
  and "any arguments" curated reads) is a known, documented residual of the pure allow-list (ADR-0006)
  that a string classifier cannot fully resolve.
- **`src/hooks/pretooluse.ps1`** is the entry point Claude Code spawns per Bash call: it dot-sources the
  two `lib` modules, reads stdin, calls `Get-LokiPreToolUseDecision`, and prints the decision envelope.
  It has an ultimate hardcoded-`deny` fallback so a dot-source/parse failure still fails closed.
- **`loki ask` is strictly read-only.** A `mutate` is **denied**, not interactively confirmed: there is
  no human in a headless `-p` run to answer an `ask` prompt. The confirm-on-mutation flow belongs to a
  later interactive command (`chat`/fix), recorded here so it is not silently dropped.
- **Invocation (`Get-LokiClaudeInvocation` / `Invoke-LokiClaude`):**
  `claude -p --output-format json --model <sonnet> --permission-mode default --tools PowerShell
  --settings <temp hook settings file> --no-session-persistence --max-budget-usd <cap>
  --append-system-prompt <read-only charter> -- <prompt>`, with `CLAUDE_CODE_USE_POWERSHELL_TOOL=1`
  set in the child env.
  - **The Windows shell tool is `PowerShell`, not `Bash`** (verified against the tools reference: on
    Windows the PowerShell tool is Claude Code's primary shell, auto-enabled only when Git Bash is
    absent). Loki's allow-list is PowerShell syntax (`Get-*`, `ipconfig`, ...), so we force the tool on
    (`CLAUDE_CODE_USE_POWERSHELL_TOOL=1`) and expose only it (`--tools PowerShell`); the hook matcher is
    `Bash|PowerShell` so a Bash call can never run un-gated either. Every other tool is unavailable.
  - `--permission-mode default` (not `dontAsk`): in `default`, a hook `allow` skips the (would-be)
    prompt so a read runs, and if the hook is ever absent the command falls to a prompt that a headless
    `-p` run cannot answer -> blocked. That is both **functional** and **fail-closed**, without relying
    on the *undocumented* interaction between `dontAsk` and a hook `allow` (and `dontAsk`'s built-in
    read-only set is Unix Bash commands, disjoint from Loki's). The mode is a parameter so a live test
    can change it. (`--bare` is deliberately NOT used -- it skips hooks, which would remove the gate.)
  - A `.cmd`/`.bat` `claude` shim (npm/Volta install) is spawned via `cmd.exe /c` because
    `CreateProcess` (UseShellExecute=$false) cannot launch a batch file directly; a native `claude.exe`
    is spawned directly.
  - The hook is registered with the **args-array command form**
    (`powershell.exe -NoProfile -ExecutionPolicy Bypass -File <script>`) so no outer shell
    (Git Bash/cmd) re-quotes the Windows path.
  - The settings are written to a BOM-less temp file **under the stick** (`<AppRoot>\temp`) and removed
    after the run -- this keeps a large JSON blob off the command line and keeps traces on the stick.
  - The **secret** is read from the encrypted `.env` (`lib/auth.ps1`), overlaid onto the isolated child
    env block (ADR-0003), and handed to `claude` **only** via the child process env
    (`ANTHROPIC_API_KEY`). It is **never** a command-line argument. A unit test asserts exactly this:
    the secret is present in `ChildEnv` and absent from the built argument string.
  - Model default is `sonnet` (cost-sensible for a tool the user runs repeatedly), overridable via the
    config key `OnlineModel` or the `-Model` parameter. A hard `--max-budget-usd` cap bounds spend.

## Consequences

- `tests/claude.Tests.ps1` table-tests the gate (read->allow, mutate/denied/non-Bash/malformed->deny,
  plus break-the-guard "a destructive command is never allow" paired with "a plain read is allow"),
  the runtime `Get-*` mitigation (Cmdlet stays read; Function/Alias/unresolved downgrade), the Windows
  argv quoting, the hook settings object, and the secret-not-in-argv property. `tests/ask.Tests.ps1`
  tests the command's guards and its engine-result -> exit-code mapping with the engine mocked.
- **Live end-to-end gate -- core wiring VERIFIED 2026-07-15; one documented limitation remains.** The
  enforcement logic, argv/env construction, and hook decision are unit-tested and adversarially reviewed;
  the whole chain was then exercised live with a single `claude -p ... --tools PowerShell
  --permission-mode default --settings <New-LokiHookSettingsObject file>` run against **WinGet `claude`
  2.1.147**, using a throwaway observation hook that logged the raw PreToolUse stdin and returned `allow`.
  Claude ran the requested read (`Get-Date`) and returned its result. That confirms items 1-4 below; a
  regression test (`tests/claude.Tests.ps1`, "GROUND TRUTH") pins the observed stdin so a future Claude
  Code change that renames a field turns the gate red instead of silently mis-reading it.
  1. ✅ **`default` mode + a PreToolUse hook `allow` runs a PowerShell read** -- observed: `permission_mode`
     was `default`, the hook returned `allow`, and the command executed. `--permission-mode default` stays.
  2. ✅ **Claude Code spawns the args-array hook command form and pipes well-formed stdin JSON** -- the hook
     fired via the exact `New-LokiHookSettingsObject` shape and `--settings <file>` was honored like inline JSON.
  3. ✅ **The PowerShell tool's command field is `tool_input.command`** (exactly, same as Bash), and
     **`tool_name` is exactly `"PowerShell"`** (matches the case-sensitive check). Claude also adds a sibling
     `tool_input.description` and top-level `transcript_path` / `effort` / `tool_use_id`; the StrictMode-safe
     `Get-LokiJsonProp` reads ignore them. So `Get-LokiPreToolUseDecision` reads the right field.
  4. ✅ **`--settings <file path>` honored the same as inline JSON** (the hook fired from the settings file).
     The `.cmd`-shim `cmd.exe /c` arg-quoting path was NOT exercised (the live run used a native `.exe`); it is
     only reached when the resolved `claude` is itself a `.cmd`, and `Get-LokiClaudeCommand` now prefers a
     native `.exe` over a shim precisely to avoid depending on that fragile path (see the multi-install note
     below). Left as a lower-priority follow-up to exercise directly.
  5. **The Get-* runtime mitigation is currently Cmdlet-only, which conservatively denies legitimate Windows
     network-diagnostic *Functions*** -- `Get-NetIPConfiguration`, `Get-NetAdapter`, `Get-NetRoute`,
     `Get-DnsClientServerAddress`, `Get-NetTCPConnection` are CDXML/script Functions, not compiled Cmdlets,
     so `Resolve-LokiCommandDecision` downgrades them to `mutate` and the gate blocks them. That removes much
     of `ask`'s value for network diagnosis. Relaxing to trust Functions was deliberately NOT done here: it
     would reverse the hijack protection Lens A validated, and correctness depends on the live PowerShell
     tool's `Get-Command` resolution + whether env-isolation's `PSModulePath` override even lets system
     modules autoload in the hook process (a Function could otherwise resolve as *unresolved* and still be
     denied). The right fix -- trust module-scoped Functions, or keep an explicit vetted read-Function
     allow-list, or stop overriding `PSModulePath` for the shell -- needs the live environment to decide.
  With items 1-4 live-verified, `loki ask` is **enforcement-complete and live-verified for the core wiring**,
  with two known boundaries: **functionally limited** (network Get-* Functions blocked, item 5) and the
  `.cmd`-shim quoting path (item 4) not yet exercised directly. Not yet "production-ready" until item 5 is
  resolved, but the security enforcement and the run chain are both proven.
- **Multi-install `claude` resolution (`Get-LokiClaudeCommand`, added after the live run).** On Windows a
  machine can carry several `claude` entries on PATH -- a Volta/nvm/npm `*.cmd` shim that delegates to a
  runtime, plus a native `*.exe` from the WinGet/native installer. Selecting the first PATH entry can pick a
  shim whose runtime is gone: observed live 2026-07-15, a dead Volta `claude.cmd` shadowed a working WinGet
  `claude.exe`, so bare `claude` failed intermittently. `Get-LokiClaudeCommand` therefore enumerates all
  Application entries and **prefers a self-contained native `.exe`** over a `.cmd`/`.bat` shim, falling back
  to the first resolvable entry so an npm-only (shim-only) install still works. This selects only *which
  binary* is spawned; the allow-list gate (what commands may run) is unaffected. `-Override` / `-ClaudePath`
  still wins for an explicit path.
- **Residual from the secret-target finding (accepted here):** `New-LokiChildEnvBlock` seeds the child
  block from the operator's *full* parent environment before overlaying isolation + the auth var, so any
  other secret already in the parent session is also present in the child. The `Env:`-read deny above
  mitigates the model reading them, but tightening env-isolate to allow-list which parent vars pass
  through is a broader ADR-0003 follow-up, not done here.
- Documented future hardening (not done here): add explicit `--disallowedTools` deny rules for mutating
  tools as a second layer that a hook bug cannot override (deny rules always win), and the
  confirm-on-mutation flow for an interactive `chat` command.
- The gate stays engine-agnostic: the offline engine will reuse `Resolve-LokiCommandDecision` /
  `Get-LokiAllowDecision` the same way, so "is this safe to auto-run" is still decided in exactly one
  place (ADR-0006).

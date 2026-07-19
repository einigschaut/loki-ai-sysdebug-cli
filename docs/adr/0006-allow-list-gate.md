# ADR-0006: The allow-list gate (`Get-LokiCommandClass` / `Get-LokiAllowDecision`)

Status: Accepted (2026-07-15)

## Context

Loki runs two engines against the same target machine: the online Claude Code
engine and the offline llama.cpp agent (DESIGN.md sections 3.1/3.2). Both propose
native PowerShell command lines to run on the host. Something has to decide, for
every proposed command, whether it may run automatically, whether it needs the
user's explicit confirmation, or whether it must not run at all -- and that
decision has to be the *same* decision regardless of which engine proposed the
command (CLAUDE.md section 5: "Allow-list, not deny-list is the gate").

A name-based deny-list (block `Remove-Item`, `Stop-Service`, ...) is trivially
bypassable: aliases, wrapper functions, `Invoke-Expression`, encoded commands, and
simply forgetting to list a mutating cmdlet all defeat it silently. Denying is
also an open-ended list -- there is no way to enumerate "every dangerous thing" and
be confident the enumeration is complete. The only boundary that degrades safely
under an incomplete list is the inverse: enumerate the narrow set of things that
are *provably safe* (read-only diagnostics) and treat everything else -- known or
not, mutating or merely unrecognized -- as requiring a human's confirmation.

## Decision

**The security boundary is allow-only-for-read + ask-by-default.** A single pure
function, `Get-LokiCommandClass -CommandLine <string>` (`src/lib/allowlist.ps1`),
classifies a proposed command line into exactly one of three classes:

- `'read'` -- auto-allowed. Only ever returned when the command is *provably*
  read-only: it contains none of the unsafe characters `; | & \` $ ( ) { } < >`
  and no newline (any separator, pipe, subexpression, redirection, or scriptblock
  disqualifies auto-read outright, regardless of what the command name looks
  like), AND its first token matches a small curated allow-list -- any `Get-*`
  cmdlet, a fixed set of pure-read command names (`hostname`, `whoami`, `netstat`,
  `Test-NetConnection`, `nslookup`, ... -- any arguments), or one of three
  arg-aware cases whose *full* argument list is scanned (not just the first
  token): `ipconfig` (no args, or only `/all`), `arp` (no `-d`/`-s` switch
  anywhere, and bare or `-a`/`-g`), `route` (`print` present and no
  `-f`/`-p`/`add`/`delete`/`change`). Any mutating flag on those three --
  `ipconfig /release`, `arp -a -d x`, `route print -f` (which real
  `arp.exe`/`route.exe` still act on) -- falls through to `'mutate'`.
- `'mutate'` -- requires the user's explicit confirmation. This is the
  conservative default for anything not provably read-only: unknown cmdlets,
  known mutations (`Remove-Item`, `Set-*`, `Stop-Service`, `Restart-Computer`,
  `netsh ... set`, ...), and any command carrying one of the unsafe characters
  above, even if it starts with a `Get-*`/read-looking token (e.g.
  `Get-Foo $(Remove-Item x)`).
- `'denied'` -- blocked outright. This is defense-in-depth, not the primary gate,
  and it is checked *after* the read allow-list (see the ordering note in
  Consequences): eval/dynamic execution
  (`Invoke-Expression`/`iex`, `Invoke-Command`/`icm`, `[scriptblock]`,
  `.Invoke(`), encoded/obfuscated commands (`-enc`, `-encodedcommand`, `-e `,
  `FromBase64String`), and shell-escape/arbitrary-exec (`cmd`, `Start-Process`,
  `Invoke-Item`/`ii`). An empty or whitespace-only command line is also denied.
  A bare download (`curl`/`Invoke-WebRequest`) or a bare mutation is deliberately
  **not** denied -- those are legitimate actions that only need confirmation, not
  an outright block.

`Get-LokiAllowDecision -CommandLine <string>` is the thin, engine-facing wrapper:
it calls `Get-LokiCommandClass` and returns
`@{ CommandLine; Class; AutoAllowed; RequiresConfirm; Blocked; Reason }`, where
`AutoAllowed = (Class -eq 'read')`, `RequiresConfirm = (Class -eq 'mutate')`,
`Blocked = (Class -eq 'denied')`, and `Reason` is one of the stable machine
tokens `'read-allowlisted'` / `'mutation-requires-confirm'` / `'denied'`. This is
the one call site the future engine wiring uses to gate a proposed command
before it runs.

Both functions are **engine-agnostic**: the same gate serves the online and the
offline engine, so there is exactly one place where "is this safe to auto-run"
is decided, matching DESIGN.md section 5.1. The module is also deliberately
**pure and free of i18n**: no environment calls, no external processes, no
user-facing output. `Reason` is an English machine token, not localized prose --
rendering/localizing the confirmation prompt for a `'mutate'` decision, or the
refusal message for a `'denied'` one, is the calling command's job (via
`Get-LokiText`, ADR-0004), not this module's.

## Consequences

- `tests/allowlist.Tests.ps1` table-tests every documented read/mutate/denied
  case and, separately, an adversarial "break-the-guard" block that asserts a
  representative set of smuggling attempts (`ipconfig & del ...`,
  `Get-Process; Remove-Item ...`, `Get-Content x | iex`, `Get-Foo $(Remove-Item x)`,
  and mutating flags on `ipconfig`/`arp`/`route`) can never come back as `'read'`.
  Paired with the plain `ipconfig` -> `'read'` case, this proves the guard can
  fail and that it does not, per CLAUDE.md section 6.
- v1 is **deliberately conservative**: any pipe or mixed-mode command line falls
  to `'mutate'` (confirmation), even when every stage of the pipeline would
  individually be read-only (e.g. `Get-Process | Select-Object Name`). This
  trades a small amount of convenience for a much simpler, more auditable
  boundary in the first release.
- Documented refinement path for a later ADR, not done here: a vetted pipe
  allow-list (e.g. `Get-* | Where-Object/Select-Object/Sort-Object/Format-*`
  chains with no other unsafe character), and richer per-command argument rules
  beyond the three arg-aware cases above (e.g. distinguishing more `netsh show`
  sub-commands as read-only). Both would only ever *narrow* what still requires
  confirmation -- they must not weaken the `'denied'` defense-in-depth list.
- The check order is **read, then deny, then mutate**, and the order is part of
  the security contract. Read is checked first so a genuine read-only command
  whose *arguments* merely contain a deny substring -- a file named `iex.log`, a
  host named `ii`, `cmd` inside a path -- is not fail-closed to `'denied'`; such a
  command cannot execute or mutate, because its name is read-only and the unsafe-
  character check already removed every separator/pipe/subexpression that could
  smuggle a second command. Deny then applies to everything that is not a clean
  read. Reversing this (deny-first) would block legitimate diagnostics and erode
  trust in the gate, and must not be done.
- **Known residual, accepted for this pure-classifier layer:** `Get-*` is trusted
  by the read-verb naming convention, so a same-named hijacked function, alias, or
  `Get-Foo.exe` earlier on `PATH` would be classified `'read'`. A pure string
  classifier cannot detect this. It is mitigated in depth by Loki's isolated child
  environment and by treating scanned data as data, never instructions; and the
  runtime-safe enforcement layer (`Resolve-LokiCommandDecision`, co-located in **this**
  module as of the 2026-07-18 hoist -- issue #50, below) only honors the `Get-*`
  auto-read when a runtime `Get-Command` resolves the name to a real `Cmdlet`, not
  a `Function`/`Alias`/`Application`.

## Refinement (2026-07-18) — offline-agent adversarial review

The `offline --agent` slice (ADR-0021) made this gate's `read` decision auto-execute model-proposed commands, turning
three latent gaps in the SHARED classifier into exploitable ones. Fixed here, so both engines are hardened at once:

* **Forward/mixed-slash UNC.** The side-effect deny matched only `\\host`; `//host` and `/\host` normalize to a UNC in
  .NET too and still coerce SMB/NTLM auth. The deny now catches a `[\\/]{2}` path root at a token boundary (spared:
  `http://` and inline `//`, which are not path roots).
* **Remote-target parameters.** `-ComputerName` / `-CN` / `-CimSession` / `-ConnectionUri` on a read cmdlet reach an
  attacker host over WinRM/DCOM → NetNTLM leak; they are now denied. Native `ping`/`tracert` (bare host) and positional
  `Test-NetConnection` stay allowed — reachability is intrinsic to network diagnosis, an accepted bounded residual.
* **Native-tool PATH hijack.** The runtime `Get-Command` check guards only the `Get-*` branch; a name-trusted native
  tool (`ipconfig`/`whoami`) has no cmdlet to outrank a PATH-planted `.exe`. The offline read executor now runs the
  child with **PATH pinned to System32** (and the ambient secret stripped), closing the hijack at the execution layer.
  The online engine's twin of this hole -- native-read-tool PATH resolution -- landed on 2026-07-18 (issue #50):
  `Get-LokiIsolatedEnv` pins the real System32 (sourced from `[System.Environment]::SystemDirectory`, tamper-resistant)
  ahead of the inherited child PATH -- additive, so Claude Code's own `node`/`git` resolution is unaffected. That
  scoped one hole, not the whole class: the ADR-0016 addendum records the remaining `$env:SystemRoot`/`$env:WINDIR`
  trust the online/offline engines still carry (the credential-carrying `cmd.exe` launcher included) as a tracked
  follow-up.

Each fix has a broken-once-on-purpose test (`tests/allowlist.Tests.ps1`, `tests/offline-agent.Tests.ps1`).

## Hoist (2026-07-18) — the runtime-safe gate now lives in this module (issue #50)

`Resolve-LokiCommandDecision` -- the runtime-safe gate that wraps `Get-LokiCommandClass` with the `Get-Command`
Cmdlet-resolution check and the secret-target / side-effect denies -- was born in `lib/claude.ps1` (the online engine
module), because that was the first slice to enforce. Once the offline agent (ADR-0021) reused it, the shared gate
living in an *engine* module was an inverted dependency: the offline engine importing the online one. It (and its two
`$script:` deny-pattern arrays) moved **here**, next to the pure classifier, so the ONE gate is engine-agnostic --
both `lib/claude.ps1` (`Get-LokiPreToolUseDecision`) and `lib/offline-agent.ps1` call it from this neutral module
(DESIGN.md section 5.1, "one allow-list engine for both"). Behaviour is unchanged: the move is a pure relocation and
every gate test (residual matrix, secret-target, side-effect, the break-the-guard cases) moved with it to
`tests/allowlist.Tests.ps1` and stays green. The live PreToolUse hook already sourced `allowlist.ps1`, so it is
unaffected.

Two honest consequences, recorded rather than hidden:

- **This module is no longer strictly "pure logic".** `Get-LokiCommandClass` / `Get-LokiAllowDecision` remain pure
  string logic (table-testable, no mocking). `Resolve-LokiCommandDecision` is the one function here that consults the
  runtime (`Get-Command`) -- unit-tested by mocking it. The module header states the split explicitly; the value the
  purity gave (a table-testable classifier) is intact.
- **`Get-LokiJsonProp` stayed in `lib/claude.ps1`.** It is generic StrictMode-safe JSON plumbing, not part of the
  gate, so it does not belong in the pure-classifier module, and relocating it to a shared util module was out of
  scope for this security-focused move. The offline agent's remaining dependency on `claude.ps1` for that one reader
  is benign (no security surface) and is noted for a later tidy-up.

## Refinement (2026-07-19) -- wildcard secret-target bypass (issue #54, CRITICAL)

A parallel adversarial review found, and this repo independently reproduced against the real gate, that the
secret-target deny (ADR-0007) is defeated by PowerShell **wildcards**. The deny matches the literal `\.env\b`; a glob
never contains the literal `.env` yet still resolves to the secret at run time:

```
Get-Content home\.env         -> denied  secret-target-blocked   (literal: already blocked)
Get-Content home\.e*          -> read    read-allowlisted        <-- BYPASS
Get-Content home\.en?         -> read                            <-- BYPASS
Get-Content home\[.]env       -> read                            <-- BYPASS
Get-Content home\*            -> read                            <-- BYPASS (scoops the whole home dir, incl .env)
Select-String -Path home\.e*  -> read                            <-- BYPASS (reads file CONTENTS)
```

Root cause: the classifier's unsafe-char disqualifier -- designed to stop a **second command** (separators, pipes,
subexpressions) -- does not include the wildcard metacharacters `* ? [`, which are a **different** threat: target
ambiguity. A glob picks *which file* is read, and can pick the secret. Two rules, both in
`Resolve-LokiCommandDecision`, close it -- on `read` OR `mutate`, path-form and case independent:

1. **A wildcard read is not provably safe -> `read` downgraded to `mutate`** (`read-downgraded-wildcard`). Necessary,
   not just belt-and-suspenders: `Get-Content home\*` scoops the secret and its leaf `*` is not "secret-specific", so
   no surgical rule alone suffices -- any wildcard must leave the auto-allow path. Headless/offline refuse a mutate;
   interactive may confirm it (the operator sees the glob).
2. **A wildcard whose LEAF globs specifically to `.env` -> HARD `denied`** (`secret-target-blocked`), never confirmable
   -- matching the other secret-target denies, and applied to `mutate` too so `Remove-Item home\.e*` is blocked.
   "Secret-specific" = `WildcardPattern.IsMatch('.env')` (IgnoreCase) AND NOT `IsMatch('safe.txt')`, so a bare `*`
   (matches everything) is not hard-denied by this rule -- rule 1 downgrades it. Leaf-only, so a directory prefix
   (`home\`, `.\`, an absolute path) does not change the verdict.

**Behaviour change, recorded (CLAUDE.md section 8, no silent deviation):** legitimate wildcard reads
(`Get-Content C:\logs\*.log`) now require confirmation instead of auto-running. That is the intended
security/convenience trade for a credential handler on a hostile machine; the agent can still enumerate a directory
without a wildcard (`Get-ChildItem C:\logs`) and read named files.

**Accepted residual:** in **interactive** mode a human could still confirm a bare-`*` read of a directory that happens
to contain the secret (`Get-Content home\*`) -- rule 1 makes it confirmable, not auto. The gate is engine-agnostic and
does not know the AppRoot, so it cannot tell "the `*`'s directory is the secret dir" from "it is a logs dir". Bounded
(human-in-the-loop; the secret would be one file among a batch the operator explicitly approved) and documented rather
than papered over. The obvious secret-targeting globs are hard-denied by rule 2 regardless of confirmation.

Broken-once tests (`tests/allowlist.Tests.ps1`): the bypass matrix is now denied/mutate, the pre-fix classifier still
returns `read` for the glob (proving the resolver rule is the load-bearing part), and legit non-wildcard reads are
unaffected.

**Adversarial review of this fix (2026-07-19) found two more evasions of the SAME class -- a name that resolves to the
secret without the literal `.env` -- both now closed here:**

* **8.3 short name (was `read`, CRITICAL).** `home\.env` has a deterministic NTFS/exFAT short name `ENV~1` -- no
  wildcard, no `.env` -- so `Get-Content home\ENV~1` slipped past both rules above AND the literal deny and auto-read
  the key (proven at runtime: `dir /x` -> `ENV~1`; `Get-Content home\ENV~1` -> the key). A read whose leaf matches the
  8.3 shape `~[0-9]` is now downgraded `read -> mutate` (`read-downgraded-shortname`) -- out of auto-allow. It cannot be
  hard-denied at the string layer (`ENV~1` is indistinguishable from `PROGRA~1`), and the leaf-only check does not
  over-block a directory 8.3 (`C:\PROGRA~1\app\log.txt` stays `read`).
* **Trailing separator (was `mutate`, MEDIUM).** `Get-Content home\.e*\` left an empty leaf (last split segment ''),
  so rule 2's hard-deny was skipped though the glob still reads the secret. Fixed by `TrimEnd`-ing separators/quotes
  before leaf extraction; it is now hard-denied like `home\.e*`.

**The durable fix is NOT in the gate (flagged, not solved here).** A string classifier fundamentally cannot enumerate
every filesystem alias (8.3, and in principle hardlink/ADS/symlink). The 8.3 downgrade is belt-and-suspenders that
removes the auto-read; the real closure is storage-layer -- the secret must not be readable by ANY name from the
agent's cwd during a run (disable 8.3 on the AppRoot volume, or don't leave the decrypted key as a readable file in
AppRoot: load to memory / relocate / ACL). Tracked as a separate HIGH-priority issue; the gate belt reduces, but does
not eliminate, the exposure until then.

### Durable closure landed (2026-07-19, issue #56 -> ADR-0023)

The storage-layer closure above is now in place for the **offline agent**: `Invoke-LokiChildReadCommand` pins the gated
child's **working directory to System32** (`Get-LokiSystemDirectory`), never the inherited ambient cwd (which on the
stick *is* AppRoot). From a cwd that is neither `home\` nor an ancestor of it, **no relative name** -- 8.3 short name,
wildcard, hardlink, ADS or symlink under `home\` -- resolves to `home\.env`, on any filesystem and without ACLs. This
delivers the property the gate could not: the secret-at-rest is unreadable by relative name **regardless of the gate's
classification or of an operator confirming** a downgraded `read -> mutate` (the residual the Slice 2b review left, see
ADR-0022). The gate rules here stay as defence-in-depth (name-layer belt); the cwd pin is the structural closure. The
**online** Claude Code child keeps cwd = AppRoot by design (its project model) and relies on the PreToolUse hook gate +
Claude Code's own permission prompt; relocating its cwd is a separate follow-up if desired. See ADR-0023 for the full
decision and the bounded absolute-path/`..`-traversal residual (both name-gated).

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
  enforcement layer (`lib/claude.ps1`, the next slice) will only honor the `Get-*`
  auto-read when a runtime `Get-Command` resolves the name to a real `Cmdlet`, not
  a `Function`/`Alias`/`Application`.

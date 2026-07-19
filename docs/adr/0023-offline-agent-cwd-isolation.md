# ADR-0023: Pin the offline agent child's working directory (durable secret-at-rest closure)

Status: accepted · Date: 2026-07-19 · Builds on ADR-0006 (allow-list gate + 2026-07-19 wildcard/8.3 refinement),
ADR-0022 (confirmation-gated mutations, Slice 2b), ADR-0016 (child endpoint env hygiene), ADR-0003 (isolation model).
Closes issue #56.

## Context

The secret-at-rest is `home\.env` (base64 `LOKI_SECRET`), which at runtime sits under **AppRoot** — and the offline
agent's gated child inherits AppRoot as its working directory, because `Invoke-LokiChildReadCommand` never set
`ProcessStartInfo.WorkingDirectory` (an empty `WorkingDirectory` inherits the parent process cwd, which on the stick is
AppRoot). So a model-proposed command can name the secret by a path **relative** to that cwd: `home\.env`.

ADR-0006's 2026-07-19 refinement (issue #54) closed the *name* families a string gate can see: the literal `.env` deny,
plus a wildcard whose leaf globs to `.env` (hard-denied) and the 8.3 short name / bare wildcard (`home\ENV~1`, `home\*`)
downgraded `read -> mutate`. But that refinement itself flagged that a string classifier **cannot** enumerate every
filesystem alias, and that the durable fix is storage-layer: *the secret must not be readable by any name from the agent
cwd*. The ADR-0022 (Slice 2b) review sharpened the residual: because a `mutate` is now operator-confirmable, a downgraded
`Get-Content home\ENV~1` / `home\*` is a path the operator could **mistakenly confirm** and thereby read the key. Issue
#56 asked for the architectural call, offering two variants:

1. **Disable 8.3 generation on the AppRoot volume.** Closes 8.3 specifically, NTFS-only (FAT/exFAT always carry short
   names), and does nothing for hardlink/ADS/symlink. Fragile and filesystem-dependent.
2. **Don't leave the key readable from the agent cwd during a run** (load-to-memory / relocate / ACL-restrict). Delivers
   the robust property — *not readable by any name from the agent cwd* — for the whole alias class at once.

The maintainer chose **variant 2** (the safe one).

## Decision

**Pin the offline agent's gated child working directory to System32, never the inherited ambient cwd.**
`Invoke-LokiChildReadCommand` now sets `$psi.WorkingDirectory = (Get-LokiSystemDirectory)` — the tamper-resistant OS
answer (`[System.Environment]::SystemDirectory`, Win32 `GetSystemDirectory`) that this file already anchors the PATH pin
to (ADR-0016 / issue #55). From a working directory that is **neither `home\` nor an ancestor of it**, no
**cwd-relative** name — 8.3 short name, wildcard, hardlink, ADS, or symlink under `home\` — resolves to `home\.env`.
This holds on **any** filesystem (NTFS/exFAT/FAT), needs **no** ACLs (which exFAT lacks and which don't bind a
same-user child anyway), and moves **no** credential (so there is no crash-window where the key is lost or a stale copy
lingers).

**One form the cwd pin cannot cover — closed at the gate (adversarial review, 2026-07-19).** A **drive-qualified**
path (`X:home\.env` — drive-relative, no separator after the colon — or `X:\home\.env`) resolves against drive X's
**own** current directory, which defaults to that drive's **root**, *regardless* of the child's cwd. Because AppRoot is
the stick's drive root (`home\` sits directly under `<StickRoot>`, DESIGN.md), `Get-Content X:home\*` reaches
`X:\home\.env` even from the System32-pinned child — and the drive letter is discoverable via the auto-run
`Win32_LogicalDisk` the prompt recommends. The cwd pin is drive-scoped and structurally cannot see this. It is therefore
closed in the **shared gate** (`Resolve-LokiCommandDecision`, `LokiSecretTargetPatterns`): a new pattern
`[A-Za-z]:[\\/]?home(?:[\\/]|$|[\s=,;'"()])` **hard-denies** every drive-qualified reference to a root-level `home\`
directory (relative, absolute, bare, quoted, any drive letter) — so `X:home\ENV~1` / `X:home\*` are `denied`, never the
confirmable mutate the leaf rule alone would yield. Plain relative `home\...` is deliberately **not** added to that deny
(it does not resolve to the stick from a System32 cwd, and denying it would over-block); the cwd pin handles it. The two
layers are complementary: cwd pin for cwd-relative names, gate deny for drive-qualified names.

Why System32 specifically, and unconditionally (no new parameter threaded through the call chain):

* **Guaranteed to exist, secret-free, never the ambient AppRoot.** The read child already runs with the operator's real
  process environment (so diagnosis sees the real machine — ADR-0016), not the stick-isolated env; there is no "operate
  on the stick" reason for its cwd. A fixed, kernel-sourced system directory is the simplest cwd that is provably not
  secret-adjacent. It also reinforces the existing intent that native tools resolve against the real System32.
* **Independent of the gate and of operator judgement.** This is the point of variant 2: even if the gate misclassifies
  an alias, and even if an operator confirms a downgraded `Get-Content home\ENV~1`, the command runs in a child whose
  cwd cannot reach `home\.env` by that relative name — it reads nothing.
* **No contract change.** The pin is one assignment inside the executor; every existing caller and test is unaffected
  (the executor's real-process tests assert stdout/timeout, not cwd). Smallest change that delivers the property
  (CLAUDE.md §B.6).

The gate rules from ADR-0006 (#54) stay in place as **defence-in-depth** at the name layer. The cwd pin is the
structural closure; the gate belt still reduces auto-read to confirm-required and hard-denies the `.env`-specific globs.

## Consequences

* **Closed:** the demonstrated #56 vector (`Get-Content home\ENV~1` / `home\.e*` / `home\*` reaching the secret by a
  relative name from the agent cwd) — including the "operator mistakenly confirms a downgraded mutate" residual ADR-0022
  left open. The secret-at-rest is unreadable by relative name from the offline agent, structurally.
* **Residual (bounded, after the 2026-07-19 review closure).** Every path form that *names* the drive-root
  `home\.env` is now closed by three complementary layers: the **cwd pin** (cwd-relative `home\...` no longer resolves
  to the stick), the **gate's `.env`/leaf rules** (literal `.env` and `.env`-globbing leaves hard-denied; 8.3/bare-`*`
  leaves downgraded), and the **drive-qualified `home\` deny** added here (`X:home\...` drive-relative *and* `X:\home\...`
  drive-absolute-root, any leaf, hard-denied). What remains is narrow: (i) an upward `..` traversal — from the System32
  cwd it stays on the OS drive (C:) and cannot reach a stick mounted on another drive letter; (ii) a filesystem alias
  (hardlink/ADS/symlink) to the secret placed at an absolute path *outside* `home\` — but the agent cannot **forge**
  one, because creating it is a mutate whose target names `home\.env` (a `home\`/`.env` form the gate denies) or a
  relative target that from the System32 cwd does not resolve to the stick; a **pre-existing** planted alias is
  out-of-model host tampering, not something this agent introduces. Net: both the auto-read **and** the
  mistaken-confirm paths to the secret are gone.
* **Online path unchanged (documented, not silently scoped out — CLAUDE.md §8):** the Claude Code child keeps cwd =
  AppRoot by design (its project/workspace model) and is defended by the PreToolUse hook gate (the same
  `Resolve-LokiCommandDecision`) plus Claude Code's own permission prompt. Relocating Claude Code's project cwd is a
  larger, riskier change with its own follow-up if the maintainer wants online brought to parity; it is **not** required
  to close the offline HIGH-severity vector #56 targets.
* **Diagnosis capability unchanged:** the agent gathers state via cmdlets and native tools (absolute or ambient), not by
  relative-path filesystem traversal from its cwd, so pinning the cwd removes only the attack surface, no legitimate
  read.

## Tests (break every guard once — CLAUDE.md §6)

`tests/offline-agent.Tests.ps1`, real-process:

* **Direct:** the child reports `(Get-Location).Path` == `[System.Environment]::SystemDirectory`. Deleting the pin makes
  the child inherit the launcher cwd, flipping the assertion.
* **The #56 vector:** with the parent process cwd set (via `SetCurrentDirectory`, restored in `finally`) to a stick-like
  root that *contains* `home\marker.txt`, a relative `Get-Content home\marker.txt` in the child reads **nothing** (the
  pin sends its cwd to System32); a positive control reads the same file by **absolute** path to prove the file and
  command are valid. Deleting the pin makes the child inherit the marker-bearing cwd and read it — the guard is proven
  load-bearing.

`tests/allowlist.Tests.ps1`, the drive-qualified `home\` deny (added by the 2026-07-19 review):

* Every drive-qualified form (`X:home\.env`, `X:home\ENV~1`, `X:home\*`, `X:\home\ENV~1`, bare `X:home`,
  `X:home -Recurse`, another drive letter, quoted) resolves to `denied` / `secret-target-blocked`.
* **Break-once:** drive-letter-agnostic cases (`D:home\ENV~1`, `Z:home\*`, `E:home\.env`) stay `denied` — delete the
  pattern and each drops back to a confirmable mutate / read whose drive-relative path reads the stick secret.
* **No over-block:** a *deep* `home\` segment (`C:\Users\bob\home\config.txt`) and a home-named *file* (`C:home.txt`)
  stay `read` — the deny is specific to a root-level `home\` directory, and plain relative `home\ENV~1` stays the
  existing confirmable mutate (the cwd pin, not the gate, neutralizes it).

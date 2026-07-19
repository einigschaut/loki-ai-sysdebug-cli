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
to (ADR-0016 / issue #55). From a working directory that is **neither `home\` nor an ancestor of it**, no relative name
— 8.3 short name, wildcard, hardlink, ADS, or symlink under `home\` — resolves to `home\.env`. This holds on **any**
filesystem (NTFS/exFAT/FAT), needs **no** ACLs (which exFAT lacks and which don't bind a same-user child anyway), and
moves **no** credential (so there is no crash-window where the key is lost or a stale copy lingers).

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
* **Residual (name-gated, bounded):** an **absolute** path to the secret (`X:\...\home\.env`) or an upward **`..`
  traversal** (`..\..\home\ENV~1`) still names it. Both are bounded by the ADR-0006 gate, which is leaf-based and thus
  cwd-independent: the literal `.env` is hard-denied; a `.env`-globbing leaf is hard-denied; an 8.3 / bare-wildcard leaf
  is downgraded to a confirmable mutate — and the model does not know the stick's absolute path (it is not in the
  charter/context). A hardlink/ADS/symlink *named* as an innocuous leaf still requires a prior **write** (a gated,
  confirmed mutate) to create, so it is covered by the mutation gate, not this change. Net: the auto-read and
  mistaken-confirm paths are gone; the remaining paths need either information the agent lacks or a separately-gated
  write.
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

# ADR-0010: Footprint gate (`loki doctor --footprint`)

Status: Accepted (2026-07-15)

## Context

Loki's core promise (README honest-scope, DESIGN.md §1/§4): **no Loki or Claude Code configuration,
transcript, cache, or memory lands in the host user profile — every app-level write is redirected
onto the encrypted stick** (the isolation of ADR-0003). DESIGN.md §5.4 requires this be a
*falsifiable* claim, not an assertion — a before/after check of the host profile — and the exit-code
table already reserves `6 = FootprintGuard`.

The full §5.4 vision (a Process Monitor before/after diff across a complete `chat` / `scan` /
`offline` session) is **not** a clean, deterministic, CI-runnable gate: it needs admin (ProcMon), an
external tool, real sessions (non-deterministic, network-dependent), and the offline engine (not
built). So it cannot be the automated release-blocker suite on its own.

## Decision

**Build a deterministic, self-contained footprint gate around Loki's OWN isolation, expose it as
`loki doctor --footprint`, and honestly scope out the deeper (partly manual) layer.** The logic lives
in the new security core `src/lib/footprint.ps1`; `commands/doctor.ps1` is thin wiring.

- **The gate is the inverse of the isolation.** The isolation (ADR-0003) redirects
  `USERPROFILE`/`APPDATA`/`LOCALAPPDATA`/`TEMP` (the vars DESIGN.md §4 flags as leak-prone) onto the
  stick. The gate verifies the **host** versions of those locations stay clean when an isolated child
  runs.
- **Self-probe (the falsifiable core).** `Invoke-LokiFootprintProbe` snapshots the host targets,
  spawns an **isolated** child (`New-LokiChildEnvBlock`) that writes a marker into each redirect
  root's `loki-footprint-probe` dir, then snapshots again and diffs. If the redirect holds, the
  markers land on the **stick** (verified as a positive control — a clean host is never a vacuous
  pass) and the host `loki-footprint-probe` dirs stay absent. If the redirect broke, a marker appears
  in the **host** dir and the diff flags it. The probe is `powershell.exe` writing files — **no
  `claude`, no network** — so it is deterministic and CI-safe.
- **Probe targets (hard gate) vs standing targets (soft).** The `loki-footprint-probe` dirs are
  Loki-exclusive, so a change there is unambiguously a leak → `FootprintGuard (6)`. The curated
  *standing* locations (`%USERPROFILE%\.claude`, `%APPDATA%\Claude`, `%LOCALAPPDATA%\claude`, the
  PSReadLine history file) are the right watch-list for a future real session, but on the self-probe a
  change there may be **unrelated concurrent activity** (e.g. the operator's own `claude` session), so
  it is **reported, not failed**. Gating only on the exclusive probe targets is what makes the check
  deterministic — no concurrent-writer false failures. Because the probe dirs must **never** exist on
  the host, the hard check is **state-based**, not merely a window diff: a probe dir already present at
  snapshot time (stale from a prior broken/crashed run) is seeded into the leak set even without a
  change during the window (it is flagged, never deleted — erasing a leaked host artifact would destroy
  evidence). And a **detected leak always wins**: it maps to `FootprintGuard (6)` and names the target
  even when the positive control is unverified — the two co-occur exactly when the redirect breaks (the
  child wrote to the host, so the stick marker is absent), and the actionable leak must never be
  downgraded to a benign "inconclusive."
- **Cheap, non-recursive fingerprint.** Each target is fingerprinted by existence + (file:
  length+mtime | dir: immediate-child-count+mtime). The probe leak is an *existence transition*, caught
  at any depth; a shallow dir fingerprint avoids snapshotting a large host `.claude` twice **and**
  avoids false-positives on deep concurrent writes into a watched dir (NTFS only bumps the immediate
  parent's mtime). Deep-change detection in standing dirs is deliberately coarse (they are soft).
- **Surface & exit codes.** `loki doctor --footprint` switches doctor into footprint mode (the default
  posture run is unchanged). Inconclusive probe (markers did not reach the stick) → `GeneralError`;
  hard probe leak → `FootprintGuard (6)`; otherwise `Ok` (a soft standing change is printed as a
  warning). All strings via `Get-LokiText` (en+de).

## Consequences

- `tests/footprint.Tests.ps1` (release-blocker suite): table-tests the pure diff (clean / added /
  changed / removal-is-clean / kind-change); the non-recursive fingerprint against real temp dirs; the
  **real** isolation self-probe run once (CLAUDE.md §6 — markers reach the stick, host stays clean, no
  residue left behind); and **break-the-guard** — an operation writing into a host probe target is
  caught (`Leaked`, not `Clean`), while a soft standing change is `Observed` but does not fail the
  gate. `tests/doctor.Tests.ps1` covers the `--footprint` branch → exit-code mapping with the probe
  mocked.
- **Deliberately out of scope (documented residual, NOT a regression):**
  - **Windows Known-Folder APIs** (`SHGetKnownFolderPath`) ignore env redirection (DESIGN.md §4) — a
    write via those bypasses the redirect the self-probe exercises. Accepted residual; a real-session +
    ProcMon layer is where it would surface.
  - **Full chat/scan/offline session end-to-end** and a **Process Monitor cross-check** — the deeper,
    partly manual verification layer. `Invoke-LokiFootprintProbe -Operation` is the seam a future
    real-session gate plugs into (it already watches the standing locations for exactly that).
  - This is **not** a forensic-invisibility claim. OS/USB-level traces (Prefetch, Amcache, USBSTOR,
    event logs) are written by Windows as SYSTEM and are deliberately left alone (README honest-scope).
    The gate proves the *app-level redirection* holds for the watched, attributable locations — nothing
    more.
- **Security core → mandatory 3-vote adversarial review (done).** Ran with false-negative /
  spawn-isolation / test-contract lenses (CLAUDE.md §5), like the allow-list, the enforcement gate, and
  auth. It confirmed the hard-gate leak direction is deterministic and non-vacuous, and surfaced defects
  that were all fixed + regression-tested: (1) a *detected* leak was mislabeled "inconclusive" (exit 1)
  instead of `FootprintGuard (6)` because the handler checked the positive control before the leak —
  now the leak wins; (2) a pre-existing host probe dir read as "Clean" — now a state-based hard leak;
  (3) the "Clean" wording overclaimed vs what the self-probe proves — reworded to scope it to the
  env-var redirect (not Known-Folder writes); (4) wholesale `-Recurse` cleanup could clobber a
  concurrent same-stick run's marker — now removes only this run's own marker + the dir if empty; (5)
  the probe child inherited the operator's auth vars needlessly — now stripped. Verified clean by the
  review: no command injection in the inline argv quoting, `EnvironmentVariables.Clear()`+repopulate
  correct, the gate leaves no host footprint of its own, and the here-string marker replacement cannot
  inject.
- **Stage-2 caveat (honest, so it is not mistaken for done):** the standing targets are described above
  as the watch-list for a future real-session `-Operation`, but *as implemented* they are soft (Clean is
  gated on the probe targets only) and the `-Operation` path forces `ProbeVerified=$true` with no
  positive control. So a future real session that leaks into `%APPDATA%\Claude` would only *warn*. A
  real-session gate must promote the standing targets to hard-fail with their own concurrency-safe
  positive control (or attribute writes via ProcMon) — this ADR does not claim to have done that.
- **Scope of "Clean": the isolation library, not per-command routing.** The self-probe re-invokes
  `env-isolate` directly, so it proves the isolation *redirects correctly*; it does not prove that
  `ask`/`chat`/`scan`/offline each actually launch their child through it. A command that forgot the
  isolation would leak and this self-probe would not catch it — the `-Operation` seam (wiring the real
  launchers in) is the intended future answer.
- `lib/footprint.ps1` depends only on `lib/env-isolate.ps1` (it reuses the same isolation the gate
  verifies); the argv for the probe child is quoted inline (a single guid-named script path) rather
  than pulling the argv quoter from another module, keeping the security core's dependency surface
  minimal.

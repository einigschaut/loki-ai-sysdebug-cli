# ADR-0003 — Isolation Model: Child Env Block Primary, Restore Only for Process-Surviving Mutations

- **Status:** Accepted
- **Date:** 2026-07-14
- **Context:** Concretizes DESIGN.md "Isolation (zero app footprint — redirect instead of clean up)" and
  CLAUDE.md §5. Decided during the implementation of `lib/env-isolate.ps1` (Stage 1), **confirmed by a GitHub
  prior-art review** (among others `pirmd/app2go`, portable app launchers).

## Decision
Isolation places the complete env set (relative to `StickRoot`) into the **env block of the CHILD PROCESS**
(`claude.exe` / `llama-server`); the current PowerShell **parent session** is **NOT** mutated on the normal path.

- `Get-LokiIsolatedEnv -StickRoot [-BasePath]` → a **pure** hashtable of all vars to set
  (USERPROFILE/HOME/CLAUDE_CONFIG_DIR/APPDATA/LOCALAPPDATA/TEMP/TMP/TMPDIR/PATH plus no-persist/telemetry flags
  and `CLAUDE_CODE_CERT_STORE`).
- `New-LokiChildEnvBlock -Isolated [-BaseEnv]` → a copy of the base env with the overlay applied, for handing off
  to the child process (does **not** mutate the parent env that was passed in).
- Restore/teardown logic (`New-LokiTeardownStack` / `Set-LokiProcessEnvTracked` / `Invoke-LokiTeardown`, **LIFO**)
  exists **ONLY** for the few mutations that **survive** the process — the wrapper itself (e.g.
  `PSModuleAnalysisCachePath`) and the registry (EULA keys). For hard kills, the dispatcher's **crash-recovery
  pass** supplements the `try/finally`.

## Why
Prior-art finding (`pirmd/app2go`): env vars are set on the process env block and get **no** restore — the
process dies, the vars die with it. app2go only builds paired undo for artifacts that **survive the process**
(registry via `MergeHiveFile_start`/`_stop`, junctions, shortcuts). This matches the plan's "redirect instead of
clean up" approach and is **safer** than the approach first sketched — mutating the parent session and
restoring it via push/pop: **what you never change can't leak.** Less restore surface means a smaller
error/attack surface in the security core.

## Consequences
- **Positive:** no env leak into the parent session *by construction*; `env-isolate.ps1` stays small; the
  central "no leak" test only has to cover the small tracked set of parent/host-persistent mutations.
- Starting the child (`lib/claude.ps1`, Stage 1 F2; `llama-server`, Stage 2) **must** hand off the env block via
  `New-LokiChildEnvBlock` (`ProcessStartInfo.EnvironmentVariables` / `Start-Process -Environment`) — **no**
  command sets isolation globally.
- `Set-LokiProcessEnvTracked` is the **only** allowed way to change a parent/host var; a direct `Set-Item Env:`
  in the production path is forbidden (it would bypass teardown).
- The names (`Get-LokiIsolatedEnv` / `New-LokiChildEnvBlock` / `*TeardownStack` / `Set-LokiProcessEnvTracked` /
  `Invoke-LokiTeardown`) are **contract** → must not be renamed after release (CLAUDE.md §3/B.6).
- Known-folder APIs (`SHGetKnownFolderPath`) ignore env vars → a residual risk remains; this is checked in the
  **footprint guard** (Stage 1/2), not here.

# ADR-0002 — Command Metadata as Functions, Not a Shared Variable

- **Status:** Accepted
- **Date:** 2026-07-14
- **Context:** Refines ADR-0001 §8 (AI-built → structural error prevention) and CLAUDE.md §3 (command registry =
  single source of truth). Decided during the implementation of the dispatcher + registry (Stage 0).

## Decision
Each `commands/*.ps1` declares **two identically-patterned functions** instead of a shared variable block:
- `Get-LokiCmdMeta_<name>` → returns a metadata hashtable (required: `Name`, `Summary`, `Usage`, `Group`;
  optional: `Examples`, `Flags`).
- `Invoke-LokiCmd_<name>` → `param($Context)`, the handler, returns an exit code (via `Get-LokiExitCode`, never a
  typed number).

`lib/registry.ps1` enumerates all `Get-LokiCmdMeta_*` functions (`Get-Command -Name 'Get-LokiCmdMeta_*'`),
validates the required fields **and** the existence of the matching `Invoke-LokiCmd_<name>` (throws otherwise —
the consistency gate).

## Why not the originally sketched `$LokiCommand = @{...}` variable
The dispatcher **dot-sources all** `commands/*.ps1` files into the **same** script scope to make the handlers
visible. A shared variable name (`$LokiCommand`) would **collide** here: each file overwrites the previous one,
only the **last** value survives → the registry would see exactly one command. Uniquely named functions
(`Get-LokiCmdMeta_version`, `_help`, `_status`, …) don't collide and can be enumerated cleanly. On top of that,
the function pair machine-enforces **consistency** (metadata ↔ handler) — exactly the anti-drift goal from
CLAUDE.md §3.

## Consequences
- **Positive:** collision-free for N commands; the registry can check metadata and handler pairwise; `help`,
  the matrix, and completion continue to be **generated from the registry** (no hand-maintained help text); the
  scaffolding generator (`New-LokiCommand`) generates both functions in standard form.
- **Cost:** two functions instead of one variable per command (marginal); the naming patterns
  `Get-LokiCmdMeta_*` / `Invoke-LokiCmd_*` are part of the contract and must not be renamed after release
  (CLAUDE.md §3).
- **Exit-code metadata** (which codes a command uses) is currently **not** a required field; it arrives with the
  matrix/doc generator (the "documentation gate" task) as an optional field once the CLI matrix is generated.

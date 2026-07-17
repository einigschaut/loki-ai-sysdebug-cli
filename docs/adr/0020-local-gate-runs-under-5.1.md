# ADR-0020: The local gate runs on the runtime it guards (5.1), relaunching from a Core dev shell

Status: accepted - Date: 2026-07-17 - Builds on: the "one gate everyone runs" rule in
`build/module-versions.psd1` and the `shell: powershell` choice in `.github/workflows/ci.yml`

## Context

`build/Invoke-Checks.ps1` is the single gate (CLAUDE.md section 7): PSScriptAnalyzer + structure gate + Pester,
red = no merge. CI runs it deliberately under Windows PowerShell 5.1 (`shell: powershell`), because 5.1 is the
stick's target runtime and the shipped code must run there (CLAUDE.md section 1). The maintainer's dev shell,
however, is usually PowerShell 7 (pwsh, .NET Core).

Two tests assert behaviour that is genuinely different between .NET Framework (5.1) and .NET Core (7), and each is
asserted against the target's (5.1) result:

* `tests/env-isolate.Tests.ps1` -- an environment variable set to the empty string is REMOVED under .NET Framework
  and KEPT under .NET Core, so `Set-LokiProcessEnvTracked` / `Invoke-LokiTeardown` restore is checked against the 5.1
  behaviour.
* `tests/i18n.Tests.ps1` -- `CultureInfo` resolves an unknown but well-formed locale to a different name under Core
  than under Framework, so `Get-LokiLocaleCulture` is checked against the 5.1 result.

Run under pwsh 7 these two produce a FALSE red that CI (5.1) never sees. Measured 2026-07-17: pwsh 7 -> 1006 pass /
2 fail; Windows PowerShell 5.1 -> all pass. That is exactly the "a gate is only worth its red when everyone runs the
same one" problem `build/module-versions.psd1` already solved for tool *versions* -- the same disease one axis over,
the runtime instead of the module version.

## Decision

When `Invoke-Checks.ps1` starts under PowerShell Core, it **relaunches itself under Windows PowerShell 5.1**
(`%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe`) and returns that run's exit code. A `-Relaunched` switch
carries the guard against re-entry -- a switch, not an environment variable, so nothing leaks into the caller's
session and a second run in the same shell is never wrongly skipped. CI is unaffected: it already runs
Desktop-edition, so the branch is never taken there. The gate fails closed (exit 3) with a clear message if 5.1 is
somehow absent.

The alternatives were considered and rejected:

* **Skip the two assertions on Core** (`Set-ItResult -Skipped`). Surgical, but it makes the LOCAL gate verify
  strictly less than CI: the two 5.1-specific behaviours would go unchecked on the maintainer's own machine, and
  every future 5.1-specific test would need its own skip. It treats the symptom (two reds) rather than the cause
  (the gate is running on the wrong runtime).
* **Make the two functions runtime-agnostic.** This changes SHIPPED code to satisfy a runtime Loki does not target,
  adding branches for a case that never runs in production. A gate problem must not reach into shipped behaviour.

Relaunching keeps both assertions running with full force on the target, fixes the whole class rather than two
instances, and touches only the gate script.

## Consequences

* A dev-shell run of the gate now spawns one child process and is bounded by 5.1's toolchain. Both pinned modules
  (Pester 6.0.0, PSScriptAnalyzer 1.25.0) are present under 5.1, verified 2026-07-17.
* The gate now REQUIRES Windows PowerShell 5.1 on the machine. It always exists on the Windows target; the script
  fails closed with exit 3 if `powershell.exe` is somehow absent, rather than silently running on the wrong runtime.
* This does NOT make the code 5.1-only or excuse pwsh-7 incompatibility in shipped code -- it makes the *gate* report
  the target's truth. If a future requirement means code must also run under 7, that is a separate obligation with
  its own tests; there is no such requirement today (CLAUDE.md section 1).

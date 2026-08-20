# Contributing to Loki

Thanks for your interest in contributing. Loki is a small, opinionated
project with a narrow purpose (a portable Windows diagnostic CLI), and it
is maintained by a small team. This document explains what kinds of
contributions are welcome, and the technical ground rules that keep the
codebase consistent.

## Contribution Scope (read this first)

To keep the maintainer's review load sustainable and the codebase
coherent, please read this before opening a PR:

- **Welcome without prior discussion:** bug fixes, small and clearly
  scoped improvements, documentation fixes, test additions for existing
  behavior, and dependency/CI maintenance.
- **Requires an issue first:** anything that adds a new command, changes
  a public contract (command names, flags, exit codes, `lib/` function
  signatures), touches the security-critical modules (isolation,
  allow-list, auth, agent guardrails), or is otherwise a large or
  cross-cutting change. Open an issue describing the problem and your
  proposed approach, and wait for a maintainer to confirm it fits the
  project's direction **before** you invest time in an implementation.
- **Out-of-scope or unsolicited large PRs may be closed without merge,**
  even if the code is correct, if they were not discussed first or don't
  fit the project's scope and direction. This is not a judgment on the
  quality of the contribution — it's how the project stays maintainable.
- **The maintainer merges.** All contributions go through review; nothing
  is merged automatically, and the maintainer has final say on design
  and scope decisions.

If you are unsure whether something needs an issue first, open one
anyway — it's cheaper than a closed PR.

## Before You Start

1. Read [`CLAUDE.md`](CLAUDE.md) — it is the authoritative build-rules
   document for this repository (architecture, contracts, CI gates,
   Definition of Done). This document summarizes the parts relevant to
   external contributors in English; `CLAUDE.md` is the source of truth
   in case of any conflict.
2. Read [`docs/DESIGN.md`](docs/DESIGN.md) for the full project specification
   and [`docs/adr/`](docs/adr/) for architecture decisions already made.
3. For anything beyond a small fix, open an issue first (see Scope above).

## Development Requirements

### Target runtime: Windows PowerShell 5.1

Loki's target runtime is **Windows PowerShell 5.1** — that is the only
version guaranteed to exist on the machines Loki runs on. Your dev shell
may be PowerShell 7 (`pwsh`), but the code you write must run under 5.1.
Concretely, this means:

- **Do not use** syntax that PowerShell 5.1 does not understand:
  `&&` / `||` (pipeline chain operators), the ternary operator `? :`,
  the null-coalescing/conditional operators `??` / `?.`, `-Parallel`,
  or a `Clean` block in `try`/`catch`/`finally`.
- All file I/O must use an explicit `-Encoding utf8`. Don't rely on
  encoding defaults.
- **Any source `.ps1` file containing non-ASCII characters must have a
  UTF-8 BOM.** Without a BOM, PowerShell 5.1 reads the file using the
  system ANSI codepage, which silently corrupts non-ASCII output (a real
  bug, not a cosmetic one). This is enforced in CI via the
  `PSUseBOMForUnicodeEncodedFile` rule.
- Every entry point sets `Set-StrictMode -Version Latest` and
  `$ErrorActionPreference = 'Stop'`.
- No aliases in committed code (`Get-ChildItem`, not `gci`).
- Don't reference `$PSScriptRoot` inside a `param()` default — it can be
  empty there under 5.1. Resolve it in the function/script body instead.

### Architecture & contracts

```
src/loki.ps1        Dispatcher: argument parsing, preflight, routing, exit
                     codes, try/finally teardown. No business logic here.
src/lib/*.ps1        Shared building blocks. One responsibility per file,
                     exposing a documented function contract.
src/commands/*.ps1   One command = one file with a metadata block + handler.
                     A new feature is a new file.
```

- **Contracts first:** modules only talk to each other through documented
  `lib/` function signatures. Changing a `lib/` signature is a contract
  break — it requires updating every caller and an ADR explaining why.
  Otherwise the test suite will fail on purpose.
- **One source of truth per concept, no duplicates.** Shared logic lives
  exclusively in `lib/` (`env-isolate`, `allowlist`, `auth`, `ui`, `log`,
  `footprint`, `config`, `registry`, `hwscan`, `agent`). Re-implementing
  something that already exists in `lib/` will show up in the dead-code /
  duplication scan and is not acceptable.
- `lib/` is shared; `commands/` is additive — a command never reaches
  into another command, and anything shared moves to `lib/`.
- Every command runs through `env-isolate` and `allowlist` — no command
  bypasses the footprint/cleanup/security gate.

### New commands: scaffolding only

**Never hand-write a new command file.** New commands are created **only**
via:

```powershell
pwsh build/New-LokiCommand.ps1 <name>
```

This generates the metadata function, the handler stub, a test stub, and
a documentation stub in the standard shape the command registry expects
(see `docs/adr/0002-command-metadata-as-functions.md`). Commands that
don't go through the registry, or that are registered without a handler
or test, fail CI's registry-consistency gate.

### Tests: Pester, and they must be green

- Tests are written with **Pester** (unit + integration). Every
  `commands/` file and every security-relevant `lib/` module needs tests.
- Core logic (hardware/tier selection, allow-list, environment isolation,
  footprint guard, auth) should be table/property-tested where practical.
- Tests are treated as specification, not an afterthought — they describe
  intended behavior, not just current behavior.
- If you add a new security-relevant guard or test, **break it once on
  purpose** to prove it can actually fail. A test or guard that can never
  fail is worse than no test at all.
- Run the full local check before opening a PR:

  ```powershell
  .\build\Invoke-Checks.ps1
  ```

  This runs PSScriptAnalyzer, the structure/dead-code gate, and the full
  Pester suite — the same checks CI runs. It must be green.

- **The tool versions are pinned exactly**, in `build/module-versions.psd1`.
  CI installs those versions and `Invoke-Checks.ps1` imports those versions,
  which is what makes "the same checks CI runs" literal instead of
  approximate. If you do not have them yet, the first run stops and tells you
  the command to install them. Upgrading one is a PR of its own, so that the
  green CI run on it is the evidence for the change.

### Definition of Done

A PR is ready for review when:

- [ ] Code respects existing contracts (no changed `lib/` signature
      without an ADR and updated callers).
- [ ] `build/Invoke-Checks.ps1` passes locally (lint, structure gate,
      Pester).
- [ ] New security-critical logic is tested, and any new guard has been
      deliberately broken once to prove it can fail.
- [ ] No dead code; PSScriptAnalyzer is clean.
- [ ] New commands were created via `build/New-LokiCommand.ps1`
      (registry entry, handler, and test all present).
- [ ] Generated docs are current (help output, README command table) and
      `CHANGELOG.md` has an entry; an ADR is added for deliberate design
      decisions.
- [ ] PowerShell 5.1 dialect is respected (no `&&`/`||`/ternary/`??`/`?.`;
      explicit `-Encoding utf8`; BOM on non-ASCII `.ps1` files).
- [ ] No secrets in argv, logs, or examples; exactly one auth variable is
      ever set.
- [ ] If the change touches a security core (isolation, allow-list, auth,
      agent guardrails), it is flagged for maintainer review in the PR
      description — these changes get extra scrutiny and may take longer
      to merge.

The [pull request template](.github/PULL_REQUEST_TEMPLATE.md) mirrors
this checklist — fill it in rather than deleting it.

## Commit Conventions

This project uses [Conventional Commits](https://www.conventionalcommits.org/):

```
type(scope): subject
```

Allowed types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `ci`,
`perf`, `build`.

- Use `feat!:` (or a `BREAKING CHANGE:` footer) for breaking changes —
  e.g. a renamed command, flag, or exit code.
- Keep the subject line short and in the imperative mood
  ("add", not "added"/"adds").
- `scope` is optional but encouraged when it clarifies which area changed
  (e.g. `feat(allowlist): ...`, `fix(hwscan): ...`).
- Small, focused commits and PRs are strongly preferred — one command or
  feature per PR, no drive-by unrelated changes bundled in.

Your commit types matter beyond style: they drive the version bump (below).

## Versioning & Releases

Loki follows [Semantic Versioning](https://semver.org). The version lives
in a single file, **`version.txt`** at the repo root, and the CLI reports
exactly what it contains. See
[`docs/adr/0005-versioning-and-releases.md`](docs/adr/0005-versioning-and-releases.md)
for the full policy.

Releases are automated with
[release-please](https://github.com/googleapis/release-please):

- **Do not hand-edit `version.txt`, git tags, or the `CHANGELOG.md` version
  sections.** Those are produced by the release tooling from your commit
  history — so **your commit message is the changelog entry**. Write a clear
  Conventional Commit subject (and a body for detail); there is no
  hand-maintained `[Unreleased]` section to update.
- On merges to `main`, release-please reads your Conventional Commits and,
  when a release is warranted, opens a **Release PR** that bumps
  `version.txt`, moves the changelog, and (on merge, by the maintainer)
  tags `vX.Y.Z`. `feat:` → minor, `fix:` → patch; while Loki is pre-1.0
  (`0.x`), breaking changes bump the minor rather than jumping to `1.0`.
- Nothing releases automatically — the maintainer merges the Release PR
  deliberately.

### Before merging a Release PR: the live-engine ritual

Almost the whole suite mocks the offline engine. Two files do not —
`tests/offline.live.Tests.ps1` and `tests/offline-agent.live.Tests.ps1` start a
real `llama-server`, load real weights, and drive the real loop. They are
**opt-in** and skip unless you set the variables below, which is exactly why
they need a ritual: three defects have reached `main` that the mocked suite
could not catch, and the live path found all three. See
[`docs/adr/0033-live-engine-ritual.md`](docs/adr/0033-live-engine-ritual.md)
for why this is a ritual rather than a CI job.

Run it on a machine with a provisioned stick, before merging a Release PR.

**1. Rebuild the stick from the commit under test.** Skipping this is the
fastest way to lose an hour: a stick built from an older Loki fails with
`Model manifest entry is missing key 'KVCache'` — the validator correctly
rejecting a manifest that predates ADR-0025, which reads like a defect in the
code under test and is not one.

```powershell
powershell -ExecutionPolicy Bypass -File build\New-LokiStick.ps1 -Destination <StickRoot>
```

It writes `src\` and `version.txt` only. `models\*.gguf`, `engine-offline\`,
`home\` and `reports\` are never touched, and nothing is deleted without
`-Prune`.

**2. Run the live tests** under Windows PowerShell 5.1 — the target runtime,
not pwsh 7:

```powershell
$env:LOKI_LIVE_OFFLINE = '1'
$env:LOKI_LIVE_AGENT   = '1'
$env:LOKI_LIVE_STICK   = '<StickRoot>'
$env:LOKI_LANG         = 'en'
Invoke-Pester -Path tests\offline.live.Tests.ps1, tests\offline-agent.live.Tests.ps1 -Output Detailed
```

**3. Read the skips — a skip is not a pass.** `offline --agent` skips when the
stick has no agent-capable tier (the agent floor is `mid`), so a small-only rig
produces a green run that exercised none of the agent path — the half where all
three known defects lived. The skip reason says so; read it.

**4. Confirm no orphans survived.** Both tests assert that no `llama-server`
outlives them. If a run is interrupted, check by hand before trusting the next
one.

## Security-Critical Contributions

Changes to isolation (`env-isolate`), the allow-list gate, authentication,
footprint guarantees, or agent guardrails (Claude or the offline engine)
are treated as security-critical. These always require maintainer review
before merge, regardless of how small the diff looks. If you're proposing
a change in this area, please open an issue first so the approach can be
discussed before you write code.

If you believe you've found an actual **security vulnerability** (as
opposed to a design discussion), do not open a public issue or PR for
it — see [`SECURITY.md`](SECURITY.md) instead.

## Questions

If anything in this document is unclear, or you're not sure whether your
idea fits the project's scope, open an issue and ask before investing
significant time.

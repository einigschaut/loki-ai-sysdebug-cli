# Changelog

All notable changes to **Loki**. Format: [Keep a Changelog](https://keepachangelog.com),
versioning: [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added
- `loki doctor` — a read-only environment & host-posture diagnosis: PowerShell language mode,
  execution policy, Device Guard/WDAC enforcement, effective AppLocker rules, auth-secret status,
  and whether the app root sits on an encrypted removable volume. Backed by the new
  `lib/posture.ps1` (`Get-LokiHostPosture`, `Get-LokiVolumePosture`, the pure
  `ConvertTo-LokiDoctorChecks` interpreter, and `Get-LokiDoctorExitCode`) — every environment probe
  is read-only, requires no admin rights, and degrades to an "unknown" sentinel instead of throwing.

## [0.1.0] - 2026-07-14

Initial public release (pre-1.0). Foundation and first commands; the diagnostic
engines are not wired up yet.

### Added
- Dispatcher (`src/loki.ps1`) and a generated command registry as the single source of truth;
  the `version`, `help`, `status`, and `auth` commands.
- `lib/` building blocks: exit-code contract, UI/output (redirect-safe, colour-aware), a
  short-timeout connectivity probe, config + settings precedence (`Flag > Env > Config > Default`),
  environment isolation (child env-block + LIFO teardown, ADR-0003), and auth/secret handling
  (exactly one auth variable, base64-at-rest, masked display — never the raw secret).
- Localization layer (ADR-0004): user-facing output resolves through a message catalog
  (`src/i18n/*.psd1`); English base + fallback, German shipped, OS-culture auto-detect, `--lang` flag.
- CI gates from day one: PSScriptAnalyzer, a structure/dead-code gate, registry consistency, an
  i18n parity gate, and the full Pester suite — all runnable locally via `build/Invoke-Checks.ps1`.
- Scaffolding generator (`build/New-LokiCommand.ps1`) as the only supported way to add a command.

The online (Claude Code) and offline (llama.cpp) engines are not wired up yet; see
[`docs/DESIGN.md`](docs/DESIGN.md) for the design and roadmap.

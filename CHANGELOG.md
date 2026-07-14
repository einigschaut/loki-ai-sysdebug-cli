# Changelog

All notable changes to **Loki**. Format: [Keep a Changelog](https://keepachangelog.com),
versioning: [Semantic Versioning](https://semver.org).

## [Unreleased]

Pre-release development toward the first public release.

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

# ADR-0004: English base language, with a localizable CLI

Status: Accepted (2026-07-14)

## Context

Loki was built in German (comments, docs, and user-facing CLI output). It is being
prepared for a public open-source release, which requires English as the project
language. At the same time the CLI already had a complete set of German user-facing
strings, and its users are system administrators who may work in different locales.

Two separate questions arise:

1. What language is the *repository* written in (code comments, docs, tests, build)?
2. What language does the *CLI* speak to its users at runtime?

## Decision

**English is the repository's base language.** All code comments, documentation, ADRs,
test descriptions, and build/tooling output are written in English.

**The CLI's user-facing output is localizable.** User-facing strings are not hardcoded;
they live in per-locale message catalogs and are resolved at runtime:

- Catalogs: `src/i18n/<locale>.psd1`, data-only, loaded via `Import-PowerShellDataFile`.
  `en` is the base catalog and the guaranteed fallback; `de` ships as the first
  translation. Non-ASCII catalogs (e.g. `de`) carry a UTF-8 BOM — Windows PowerShell 5.1
  reads BOM-less non-ASCII files as ANSI (see the dialect rules in ADR-0001 / CLAUDE.md).
- Lookup: `Get-LokiText -Key '<area.name>' [-ArgumentList ...]` resolves the active
  locale, falls back to English for a missing key, and returns the key verbatim if it is
  unknown (so synthetic / pass-through values are safe). Placeholders use `-f`.
- Locale resolution follows the project's existing precedence pattern:
  `--lang <xx>` > `LOKI_LANG` (env) > config `Language` > OS UI culture > `en`.
- Scope boundary: **only** the CLI's user-facing output is localized. Code comments,
  documentation, and developer/tooling output (e.g. the build gates) stay English.

**Default behavior: auto-detect the OS UI culture, fall back to English.** A German
Windows shows German output with no flag; anything else falls back to English. This is
always overridable via `--lang` / `LOKI_LANG` / config.

**Command metadata:** a command's one-line `Summary` is a catalog key (resolved when
`loki help` renders it). Group headers stay as structural English labels (category
headers, not prose).

## Consequences

- A CI parity gate (`tests/i18n.Tests.ps1`) fails the build if any shipped locale is
  missing a key present in `en`, or if placeholder sets diverge between locales. Every
  new user-facing string must be added to every locale.
- Tests that assert on output pin the locale explicitly (in-process:
  `Initialize-LokiI18n -Locale en`; dispatcher child process: `LOKI_LANG=en`) so results
  are deterministic regardless of the machine's OS culture.
- Adding a language is additive: drop a new `src/i18n/<xx>.psd1` containing the full key
  set; the parity gate enforces completeness.
- Follow-up: the command scaffolder (`build/New-LokiCommand.ps1`) should emit a `Summary`
  key plus catalog stubs for new commands; until then, a scaffolded command's English
  summary passes through unlocalized. The i18n rule (no hardcoded user-facing strings;
  every locale complete) is to be recorded in CLAUDE.md when it is rewritten in English.

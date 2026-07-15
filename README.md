# Loki — a portable AI debug stick

[![CI](https://github.com/einigschaut/loki-ai-sysdebug-cli/actions/workflows/ci.yml/badge.svg)](https://github.com/einigschaut/loki-ai-sysdebug-cli/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

A self-contained Windows diagnostic CLI (`loki`) that runs from an **encrypted USB stick** and
orchestrates two engines:

- **Online:** [Claude Code](https://claude.com/product/claude-code) — agentic diagnosis and fix
  proposals. This is where the real leverage is.
- **Offline:** a local llama.cpp engine (hardware-adaptive model tiers) for machines with no network.

It is built for the person who walks up to a broken Windows box and wants an answer faster than
manual log-spelunking gets them there — sysadmins, IT support, and anyone who fixes other people's
computers.

> **Status: pre-release (v0.x). Not production-ready.**
> What works today: the dispatcher, the generated command registry, `version` / `help` / `status` /
> `auth`, config + settings precedence, the environment-isolation primitives, and localization.
> The engines themselves (online and offline) are **not wired up yet** — `loki auth login` honestly
> tells you so instead of pretending. See the [roadmap](docs/DESIGN.md#7-roadmap).

## Honest security scope

Loki guarantees **no secrets, config, or transcripts in the host user profile** — all app-level
writes are redirected onto the encrypted stick.

Loki is **not** "forensically invisible", and does not claim to be. OS- and USB-level execution
traces (Prefetch, Amcache, USBSTOR, event logs) are written by Windows as SYSTEM. They cannot be
removed without admin rights, and Loki deliberately does not touch them. If you need
anti-forensics, this is the wrong tool — and you should be suspicious of any tool that claims
otherwise.

Details: [`docs/DESIGN.md`](docs/DESIGN.md). Vulnerability reports: [`SECURITY.md`](SECURITY.md).

## Target environment

Unmanaged machines, or machines you administer yourself. On hardened, managed endpoints
(AppLocker/WDAC, Constrained Language Mode, device control) the host will deliberately block the
tool — `loki status` reports that plainly rather than failing in a confusing way.

**Runtime: Windows PowerShell 5.1.** That is the version guaranteed to exist on the machines Loki
is carried to, so it is the version Loki targets. PowerShell 7 is not required.

## Quickstart

```powershell
git clone https://github.com/einigschaut/loki-ai-sysdebug-cli.git
cd loki-ai-sysdebug-cli

powershell -ExecutionPolicy Bypass -File src\loki.ps1 help     # command overview
powershell -ExecutionPolicy Bypass -File src\loki.ps1 status   # write-free environment check
powershell -ExecutionPolicy Bypass -File src\loki.ps1 auth set # store an API key (hidden input)
```

Authentication uses **exactly one** variable — `ANTHROPIC_API_KEY` (default) or
`CLAUDE_CODE_OAUTH_TOKEN`. The secret is never passed via `argv` and never printed:
`loki auth status` only ever shows a masked value.

## Commands

The full command set — generated from the command registry, so it never drifts. Do not edit the
table by hand; run `build/Update-LokiDocs.ps1` (a CI gate fails the build if it is stale).

<!-- BEGIN GENERATED COMMANDS (build/Update-LokiDocs.ps1 -- do not edit by hand) -->

| Command | Group | Description |
| --- | --- | --- |
| `doctor` | Health | Full environment & host-posture diagnosis |
| `help` | Health | Help / command overview (also: loki <cmd> --help) |
| `status` | Health | Quick environment check (writes nothing) |
| `version` | Health | Show Loki and environment versions |
| `ask` | Online | Ask the online engine a read-only diagnostic question |
| `auth` | Setup | Manage auth method and secret |

<!-- END GENERATED COMMANDS -->

## Language

Loki's user-facing output is localized. It **auto-detects your OS language** and falls back to
English; English and German ship today.

```powershell
loki --lang de status      # force German
loki --lang en status      # force English
$env:LOKI_LANG = 'en'      # or via environment
```

Precedence: `--lang` > `LOKI_LANG` > config `Language` > OS UI culture > English.
Adding a language means dropping a new `src/i18n/<locale>.psd1` with the full key set — a CI gate
fails the build if any locale is incomplete. See [ADR-0004](docs/adr/0004-language-and-localization.md).

## Development

Loki is built **100% with Claude Code**. Because an AI agent wrote every line, the project leans
hard on structural guardrails instead of good intentions: contracts-first modules, a generated
command registry as the single source of truth, mandatory scaffolding for new commands, and CI
gates that fail on dead code, drift, or a missing test.

```powershell
.\build\Invoke-Checks.ps1     # PSScriptAnalyzer + structure/dead-code gate + Pester (same as CI)
```

- **Design & architecture:** [`docs/DESIGN.md`](docs/DESIGN.md)
- **Decisions:** [`docs/adr/`](docs/adr/)
- **Build rules for contributors (and AI agents):** [`CLAUDE.md`](CLAUDE.md)
- **How to contribute:** [`CONTRIBUTING.md`](CONTRIBUTING.md) — please read the contribution-scope
  section before opening a PR.

New commands are created only via the scaffolder, never by hand:

```powershell
.\build\New-LokiCommand.ps1 <name>
```

## License

[Apache-2.0](LICENSE).

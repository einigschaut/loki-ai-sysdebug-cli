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
> `doctor` / `auth` / `hwscan` / `collect`, config + settings precedence, the environment-isolation
> primitives, localization, and the **online engine** (`ask` / `scan` / `chat`) behind the allow-list gate.
> `collect` writes a raw diagnostic dump with no network, model or admin required — the answer when nothing
> else can help. The **offline engine** itself is not wired up yet, and the online commands'
> interactive/live paths are still being hardened. See the [roadmap](docs/DESIGN.md#7-roadmap).

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

Loki runs from a **stick** — a self-contained directory (normally the root of an encrypted USB
volume) that carries the code, the offline engine and the model tiers. A git checkout is the
*source*, not the thing you carry. So there are three steps, and the first one is a build:

```powershell
git clone https://github.com/einigschaut/loki-ai-sysdebug-cli.git
cd loki-ai-sysdebug-cli

# 1. Build the stick from the repository (repeat this to update an existing stick --
#    it never touches the engine, the models or your credential).
powershell -ExecutionPolicy Bypass -File build\New-LokiStick.ps1 -Destination E:\
```

From here on you work **on the stick**, and `loki.cmd` at its root is the entry point:

```powershell
E:\loki.cmd status        # write-free environment check -- start here
E:\loki.cmd setup         # download the offline engine + model tier(s). Needs internet; run it
                          # on the machine where you prepare the stick, never on the target.
E:\loki.cmd auth login    # ONLY if you want the online engine (see below)
E:\loki.cmd help          # command overview
```

Add the stick root to `PATH` (or `cd E:\`) and every command in this README works verbatim as
`loki <command>`.

`loki setup` is the guided part: it lists the model tiers with their RAM needs, marks the
recommended default, and downloads what you pick — verifying every file against a pinned SHA256
and byte size before it is kept. `loki hwscan` tells you beforehand which tiers this machine can
actually run. **The offline engine needs no account and no credential**; if you only want offline
diagnosis you are done after `setup`.

### Working in the repository

For development the same entry point sits next to the dispatcher, so nothing needs building:

```powershell
.\src\loki.cmd help
powershell -ExecutionPolicy Bypass -File build\Invoke-Checks.ps1   # analyzer + structure gate + Pester
```

`loki auth login` is the one-command setup, in the shape of `gh auth login`. It asks how Loki should reach
the online engine and lands **exactly one** credential on the stick:

- **Claude subscription** (`loki auth login sub`) — opens a browser to sign in via `claude setup-token`
  (requires a Pro/Max subscription), then you paste the token it prints. Stored as `CLAUDE_CODE_OAUTH_TOKEN`.
- **API key** (`loki auth login api`) — paste a console API key. Stored as `ANTHROPIC_API_KEY` (the default).

The online engine needs one of these; the **offline engine needs none**. The secret is never passed via
`argv` and never printed — `loki auth status` only ever shows a masked value. (`auth use` / `set` / `clear`
remain as scriptable primitives.)

## Commands

The full command set — generated from the command registry, so it never drifts. Do not edit the
table by hand; run `build/Update-LokiDocs.ps1` (a CI gate fails the build if it is stale).

<!-- BEGIN GENERATED COMMANDS (build/Update-LokiDocs.ps1 -- do not edit by hand) -->

| Command | Group | Description |
| --- | --- | --- |
| `collect` | Diagnostics | Write a raw diagnostic dump (no network, model or admin needed) |
| `doctor` | Health | Full environment & host-posture diagnosis |
| `help` | Health | Help / command overview (also: loki <cmd> --help) |
| `hwscan` | Health | Check what the offline engine can run on this machine (writes nothing) |
| `status` | Health | Quick environment check (writes nothing) |
| `version` | Health | Show Loki and environment versions |
| `offline` | Offline | Analyze a diagnostic dump with the offline engine (no network needed) |
| `ask` | Online | Ask the online engine a read-only diagnostic question |
| `chat` | Online | Interactive diagnostic session with the online engine (mutations require confirmation) |
| `scan` | Online | Run a structured read-only diagnostic scan of an area |
| `auth` | Setup | Manage auth method and secret |
| `setup` | Setup | Prepare the stick: download the offline engine + model(s) (run where you set up the stick) |

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

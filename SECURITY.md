# Security Policy

## Why this matters for Loki

Loki is a security- and privacy-sensitive tool by design: it runs from a USB
stick against machines it does not own, handles authentication secrets
(`ANTHROPIC_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN`), enforces an allow-list
gate around every command, and makes explicit claims about what it does and
does not leave behind on a host system (see the "Honest Security Scope"
section of the [README](README.md) and [`docs/DESIGN.md`](docs/DESIGN.md)).

Because of that, reports touching authentication, the allow-list gate,
environment/host isolation, footprint guarantees, or agent guardrails are
**especially welcome and will be prioritized**, even if you are not sure
the behavior rises to the level of a "real" vulnerability.

## Supported Versions

Loki is currently pre-release (`0.x`). There is one actively maintained
line: the latest `0.x` release / the `main` branch. There are no older
major versions to support yet.

| Version | Supported          |
| ------- | ------------------ |
| 0.x     | :white_check_mark: (active development) |

Once Loki reaches `1.0`, this table will be updated with a concrete
support window for prior major versions.

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for security reports.

Instead, use GitHub's **Private Vulnerability Reporting**:

1. Go to the repository's **Security** tab.
2. Click **"Report a vulnerability"**.
3. Fill in as much detail as you can (see below).

No email address is needed — the private report is created directly in
GitHub and is visible only to the maintainer(s) and, once you submit it,
to you.

If Private Vulnerability Reporting is ever unavailable for some reason,
open a minimal placeholder issue asking for a secure contact channel
instead of describing the vulnerability publicly.

### What to include

To help us triage quickly, please include:

- A clear description of the issue and its potential impact.
- Steps to reproduce, or a minimal proof of concept.
- The affected version/commit and your environment (Windows version,
  PowerShell version — `$PSVersionTable` — and whether you were running
  from the USB stick or a local checkout).
- Whether the issue involves secret handling, the allow-list, host
  isolation/footprint guarantees, or the agent (Claude / offline engine)
  guardrails specifically — these are treated as the highest priority.

### What to expect

- **Acknowledgement:** we aim to acknowledge new reports within a few
  business days.
- **Triage:** we will confirm the issue, assess severity/impact, and
  discuss a fix timeline with you through the private report thread.
- **Fix & disclosure:** for confirmed vulnerabilities, our general target
  is to ship a fix and coordinate disclosure within **approximately 90
  days** of the initial report, faster for high-severity issues. This is
  a goal, not a contractual SLA — Loki is currently maintained by a small
  team.
- **Credit:** with your permission, we are happy to credit you in the
  release notes / advisory once a fix ships.

### Scope

In scope: the Loki CLI and its shipped code under this repository
(`src/`, `build/`, command implementations, the isolation/allow-list/auth
layer, the offline engine integration).

Out of scope: vulnerabilities in third-party dependencies with no
Loki-specific exploitation path (please report those upstream), and
purely theoretical issues with no realistic impact given Loki's documented
security scope in `docs/DESIGN.md`.

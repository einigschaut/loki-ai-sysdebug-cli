# ADR-0005: Versioning and releases (SemVer + automated release PRs)

Status: Accepted (2026-07-14)

## Context

Loki had version numbers scattered as prose in documents but no single source of
truth and no release automation. A `VERSION` file existed and the CLI read it, but the
release tooling (`release-please`, `simple` strategy) bumps a file named `version.txt`
by default — so the automation and the CLI pointed at different files and the reported
version could never move on its own. There was also no defined versioning scheme.

Loki is a CLI with a stable interface (command names, flags, exit codes; see CLAUDE.md
§3/§4). Consumers — and the tool's own `version` command — need a predictable, machine
-parseable version, and the maintainer (a small team building 100% via AI agents) needs
the version to advance without hand-editing that drifts out of sync with the changelog.

## Decision

**Scheme: Semantic Versioning 2.0.0** (`MAJOR.MINOR.PATCH`, optional
`-prerelease`/`+build`). While Loki is pre-1.0 (`0.x`), the public interface is not yet
considered stable; breaking changes bump the **minor** (0.1.0 → 0.2.0), features also
bump the minor, and fixes bump the patch. Once Loki reaches `1.0.0`, breaking changes
bump the major as usual.

**Single source of truth: `version.txt`** at the repo root (and, on the stick, next to
`loki.ps1`). It is a plain SemVer string, no BOM. `Get-LokiVersion` (`lib/meta.ps1`)
reads it; the CLI prints exactly what it contains. **No other file restates the
version as fact** (docs describe the version *line*, e.g. "pre-release `0.x`", not a
specific number that would drift).

**Bumping is automated, not manual.** [`release-please`](https://github.com/googleapis/release-please)
runs in **manifest mode**:
- `release-please-config.json` — the `simple` release strategy on the root package
  (this is the strategy that reads/writes `version.txt` and `CHANGELOG.md`),
  `bump-minor-pre-major: true`, clean `vX.Y.Z` tags.
- `.release-please-manifest.json` — the last released version (baseline `0.1.0`).
- On every push to `main`, release-please reads the Conventional Commits since the last
  release and, if any warrant one, opens/updates a standing **Release PR** that bumps
  `version.txt`, moves the `[Unreleased]` changelog section into a dated version section,
  and — when the maintainer merges it — tags `vX.Y.Z` and creates a GitHub Release.

**Nothing releases automatically.** The workflow never publishes on its own; the
maintainer deliberately merges the Release PR (consistent with the "maintainer merges"
policy and the branch ruleset). The Release PR is authored by the bot, so the maintainer
can review and approve it without hitting the solo self-approval trap.

**Commit types drive the bump** (Conventional Commits, already required — CONTRIBUTING /
CLAUDE.md §8): `feat:` → minor, `fix:` → patch, `feat!:` / `BREAKING CHANGE:` → minor
while pre-1.0. `docs:`/`chore:`/`ci:`/`build:`/`refactor:`/`test:` do not, by themselves,
trigger a release.

## Consequences

- The version the CLI reports, the git tag, the GitHub Release, and the changelog entry
  are always in lockstep — they are produced from one operation.
- **Agents and contributors must not hand-edit `version.txt` or the `CHANGELOG.md`
  version sections** — that is release-please's job. The changelog is generated from the
  Conventional Commit history, so **the commit message *is* the changelog entry**: write a
  clear `feat:`/`fix:` subject (and body for detail). There is no hand-maintained
  `[Unreleased]` section. (Recorded in CLAUDE.md §8.)
- A CI gate (`tests/meta.Tests.ps1`) asserts `version.txt` exists, is valid SemVer, and
  is exactly what `Get-LokiVersion` returns — so the version state cannot silently drift
  into something non-parseable.
- The first automated Release PR appears once a release-worthy Conventional Commit lands
  on `main` after this ADR; the baseline `0.1.0` is declared in the manifest.

## Operational note: the release token

release-please authenticates with the repository secret `RELEASE_PLEASE_TOKEN` — a **fine-grained
PAT** (Contents: RW, Pull requests: RW, this repository only), not the default `GITHUB_TOKEN`.
GitHub's anti-recursion rule means a PR opened via `GITHUB_TOKEN` triggers no further workflows,
which would leave every Release PR without CI — the one gate that must never be skipped before a
release.

The price of that choice is an expiry date, and **the failure mode is silence**: when the token
lapses, no Release PR is opened and nothing says so. Merged work simply stops reaching a release.
That is not hypothetical — the token expired on 2026-08-13 and the gap surfaced only when a
release was wanted, five days later.

Renewing it carries a second trap. `gh secret set` hides the input completely — no echo, no
asterisks — so a paste that does not land stores an **empty** secret and still reports success.
The two failures look different in the run log:

| Symptom | Meaning |
|---|---|
| `Input required and not supplied: token` | the secret is empty — it fails ~4 ms in, inside the action's own input validation, before any network call |
| `Bad credentials` | the secret holds a token that is expired or revoked |

**Set the value in the web form** (Settings > Secrets and variables > Actions). It refuses an empty
input; the CLI prompt cannot, because it shows nothing back.

A **preflight step** in `release-please.yml` now runs ahead of the action and states all of this in
plain words. It fails with a named error when the secret is empty, rejected (401), blocked (403) or
not scoped to this repository (404 — a fine-grained PAT gets 404, not 403, for a repository it may
not read), and it warns when the token expires within 14 days, so the lapse is announced before it
happens rather than after. Any other failure (5xx, network) only warns and lets release-please
report the real outcome: a partial GitHub outage overlapped the 2026-08-17 diagnosis and kept it
ambiguous for a day, and a preflight that turned an outage into a hard stop would recreate that
same confusion from the other side.

What the preflight does **not** prove is scope: it establishes that GitHub accepts the token for
this repository, not that the token carries Contents and Pull requests **write**. A read-only PAT
still passes the preflight and fails inside release-please. That is deliberate -- verifying write
access would mean performing a write -- and it is the rarer mistake, because the permissions are
chosen once when the token is created, while the expiry recurs on its own.

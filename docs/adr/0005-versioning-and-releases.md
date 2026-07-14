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
- **Agents and contributors must not hand-edit `version.txt` or hand-cut a released
  changelog section** — that is release-please's job. Add human-readable notes under
  `## [Unreleased]`; the Release PR promotes them. (Recorded in CLAUDE.md §8.)
- A CI gate (`tests/meta.Tests.ps1`) asserts `version.txt` exists, is valid SemVer, and
  is exactly what `Get-LokiVersion` returns — so the version state cannot silently drift
  into something non-parseable.
- The first automated Release PR appears once a release-worthy Conventional Commit lands
  on `main` after this ADR; the baseline `0.1.0` is declared in the manifest.

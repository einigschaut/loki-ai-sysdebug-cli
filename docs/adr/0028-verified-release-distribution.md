# ADR-0028: Verified release distribution (attested archive, not a package gallery)

Status: Accepted (2026-07-23)

## Context

ADR-0005 automated *versioning* -- release-please tags `vX.Y.Z` and creates a GitHub
Release on merge. It did not define *distribution*. A technician gets Loki onto their own
machine (the preparation machine, from which they build and refresh USB sticks) with no
supported path except `git clone`, and:

- **There is no update path.** `gh repo clone` into an existing directory fails; nothing
  documents `git pull`; a checkout from before a given feature simply lacks files and
  fails with no hint why (found in the field, 2026-07-22 -- issue #91, and #87 for the
  failure-side symptom).
- **The ZIP a non-git technician would grab is unverifiable.** GitHub's auto-generated
  source tarball/zip is produced on the fly; its bytes -- and therefore its hash -- are
  not guaranteed stable across time or infrastructure, so it cannot be pinned, and no
  checksum or signature is published alongside it.
- This is a security tool that pins every *downloaded model* to a SHA256 **and** a byte
  size (ADR-0026), yet shipped its own artifact with no integrity story at all. The
  asymmetry is indefensible.

The maintainer asked whether a package gallery (PowerShell Gallery, winget) is the answer.

## Decision

**Ship a first-class, attested release archive; do not use a package gallery; never
self-update on a target machine.**

1. **The artifact is a deterministic `git archive` of the tag.** The release workflow's
   `publish-assets` job builds `loki-<tag>.zip` with
   `git archive --format=zip --prefix=loki-<tag>/ <tag>`, which is byte-deterministic for
   a fixed commit (verified: built twice, identical SHA256) -- unlike the auto tarball.
   It is the same tree a `git clone` at that tag yields, so it is a true substitute for
   cloning, `New-LokiStick.ps1` and all.

2. **A `sha256` sidecar rides with it**, carrying hash + byte size (the ADR-0026 shape).
   This is transport-integrity only: it sits on the same host as the artifact, so it
   defends against a corrupted download, not against a compromised release.

3. **Build provenance is attested** with `actions/attest-build-provenance@v4`
   (sigstore-backed, free, no certificate). A consumer verifies with
   `gh attestation verify loki-<tag>.zip -R einigschaut/loki-ai-sysdebug-cli`, which
   proves *GitHub Actions built exactly this file from this repo at this commit*. This is
   the real trust anchor -- the thing a self-hosted checksum cannot be.

4. **Least privilege in CI.** The elevated `id-token` / `attestations: write` permissions
   live only on `publish-assets`, which runs only when a release was actually cut. The
   `release-please` job keeps `contents` + `pull-requests: write` and nothing more.

5. **Documented update paths** (README): `git pull` for a checkout; re-download + verify
   for the ZIP; and -- for sticks -- re-run `New-LokiStick.ps1`, which *is* the update
   (it rewrites the code, preserving engine/models/credential).

### Why not a package gallery

- **PowerShell Gallery `Install-Module` is measured-broken on the maintainer's own
  network.** The NuGet provider bootstrap (`cdn.oneget.org`) hangs behind the corporate
  TLS-inspection proxy -- documented in `build/Invoke-Checks.ps1`'s own analyzer-missing
  message. Recommending it as the "easy" update path would recommend the one mechanism
  that demonstrably hangs where the primary technician works.
- **Loki is not a module.** `Install-Module` publishes functions into the user profile's
  module directory -- not `loki.cmd`, not `build/New-LokiStick.ps1`, not the tree sticks
  are built from. Making it module-shaped would mean maintaining a *second shape* of the
  same tool (a module on the workstation, a tree on the stick): exactly the drift the
  whole project is structured against, and it writes into the user profile Loki otherwise
  promises to stay out of.
- **winget** has the same not-a-module shape problem plus review latency via a PR against
  `microsoft/winget-pkgs`, and still needs a hosted, hashed artifact underneath -- which
  is what this ADR provides.
- **A public gallery is also a public name claim** we should not stake pre-1.0.

### Why not self-update on the target

A tool that downloads and replaces itself *on the machine being diagnosed* would break
the footprint promise (network traffic and writes on precisely the machine that must stay
clean) and defeat the ADR-0014 integrity chain, since an updater needs the right to
bypass the very hash verification that chain enforces. Updating is a preparation-machine
activity, exactly like `setup`.

## Consequences

- Every release from now on carries `loki-<tag>.zip` + `loki-<tag>.zip.sha256` and a
  provenance attestation. A technician without git has a verifiable artifact; a technician
  with git uses `git pull`.
- **This job is not exercisable before it runs for real.** GitHub Actions runs in the
  cloud; the YAML and the `git archive`/checksum logic were validated locally, but the
  first true end-to-end run is the next release (v0.14.0). If it misfires, the release is
  still tagged and usable -- only the attached asset would be missing or wrong, which is
  recoverable by re-running the job.
- Pre-v0.14.0 releases (through v0.13.0) have no attached asset; the README update path
  for them is `git pull` / re-clone only.
- A future stick-age stamp (issue #91) and an update helper that consumes this asset
  (`build/Update-Loki.ps1`) build on top of this; they are separate changes.
- No new runtime dependency ships in Loki itself: `git archive`, `sha256sum` and the
  attestation all run in CI, and `gh attestation verify` is the consumer's own tool.

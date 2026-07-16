# ADR-0012: Offline engine binary + the MSVC runtime it needs

Status: Accepted (2026-07-16)

## Context

ADR-0011 put *models* on the stick but deliberately left the **engine** for a later slice: a stick full of GGUF files
with nothing to run them is half a feature. This ADR covers acquiring the engine binary. Unlike a model — which is
data we only ever read — the engine is **code the target machine executes**, so the integrity bar is higher and the
licensing question is real.

Every claim below was verified against the artifact itself on 2026-07-16, not recalled:

* **The engine.** `gh api repos/ggml-org/llama.cpp/releases/latest` → release `b10038`, asset
  `llama-b10038-bin-win-cpu-x64.zip`, 18 418 645 bytes. The GitHub release API returns a `digest` field per asset
  (`sha256:873ac441…5332`); downloading the asset and running `Get-FileHash` reproduced it exactly. This is the same
  "pin from the provider's own metadata" property the Hugging Face LFS `oid` gives us for models (ADR-0011), so the
  manifest is reproducible without hand-copying hashes.
* **One artifact fits every CPU.** The archive contains 15 `ggml-cpu-<arch>.dll` variants (`sse42`, `haswell`,
  `alderlake`, `zen4`, `sapphirerapids`, …) which `ggml-base.dll` selects at runtime. We therefore do **not** detect
  the CPU at download time, and we must not prune the variants.
* **The runtime gap.** Reading the PE import strings of `llama-server.exe`, `llama-server-impl.dll`, `ggml-base.dll`,
  `ggml-cpu-*.dll` and `llama-common.dll` shows exactly three imports that Windows does **not** ship:
  `VCRUNTIME140.dll`, `VCRUNTIME140_1.dll`, `MSVCP140.dll`. The `api-ms-win-crt-*.dll` imports are the Universal CRT,
  which **is** part of Windows 10/11 (`ucrtbase.dll`), and `libomp140.x86_64.dll` is inside the archive. So the gap is
  three files, not "the VC++ redistributable" in general.
* **Licensing.** Microsoft (*Redistribute Visual C++ Files*): "Distribution of the Visual C++ Runtime Redistributable
  package, merge modules, and individual binaries is limited to licensed Visual Studio users and is subject to
  Microsoft Software License Terms." The same page documents app-local deployment as supported ("It's also possible to
  directly install the Redistributable DLLs in the *application local folder*"), only discouraged for servicing.

## Decision

**1. The engine is pinned and acquired exactly like a model, but verified before it is ever opened.**
`src/engine/manifest.psd1` pins Url/FileName/SHA256/SizeBytes for llama.cpp `b10038` `win-cpu-x64` (MIT).
`src/lib/engine.ps1` (security core) validates the manifest fail-closed, and `Expand-LokiVerifiedArchive` re-checks the
archive against the pin **before** expanding it. The verified archive is **kept** next to the expanded files: it is the
chain back to the pinned hash, so the harness slice can re-verify at load time instead of trusting whatever currently
sits on the stick. Nothing in this slice executes the engine.

**2. Zip-slip is gated separately from the hash.** A verified archive could still, in principle, carry a hostile entry
name. `Test-LokiArchiveEntrySafe` (pure, table-tested) rejects rooted, traversing, drive-qualified, ADS (`:`),
wildcard, control-character, empty-segment, trailing-dot/space and reserved-device-name entries. **All** entries are
validated before **any** byte is written. The new tree is then built **completely in a sibling directory** and swapped
in by two directory renames, so no failure mode (long path, full disk, a locked file because `llama-server` is running)
can leave a half-extracted tree — on any failure the destination is as it was. An earlier version of this slice pruned
the destination and *then* moved files in one at a time; a failure in between left a tree that was both pruned and
half-populated — worse than doing nothing, while the prose claimed the destination was untouched. It is documented
here because the lesson generalises: **a rollback you did not build is not a property you may claim.**

**2b. Expansion RECONCILES the engine directory against the pinned archive.** Overwriting only the names the archive
contains is not enough, and this is the subtle one: a planted `ggml-cpu-<arch>.dll` would survive the very `loki setup`
an operator runs to repair a suspect stick, sitting in `llama-server.exe`'s own directory — first in the Windows DLL
search order and exactly where `ggml-base.dll` picks CPU variants **by name**. Verifying the archive can never detect
that, because the planted file is not in the archive; the deferred load-time check would not either. The same hole
would make a pin bump useless — files from the previous build, including the very binary a bump exists to remove,
would linger and stay loadable. So anything in `engine-offline\` that the pinned archive does not produce is removed,
except the verified archive itself and the caller's `-PreserveNames` (the operator-staged Microsoft runtime, which
legitimately is not in the archive). Pruning is reported to the operator, not silent.

**3. Loki never ships or auto-copies the Microsoft runtime. Staging is opt-in and operator-driven.**
Given the licensing sentence above, the repository must stay free of Microsoft binaries — that is not negotiable and
`.gitignore` already excludes `*.dll`. `loki setup --stage-runtime` copies the three DLLs from **the operator's own
machine** (`%SystemRoot%\System32`, hardcoded in the command — never a caller-supplied path) to **the operator's own
stick**, printing a notice that these are Microsoft files under Microsoft terms. Without the flag, setup only prints a
hint. Staging is fail-closed: a missing file, an unreadable version, a version below `MinVersion`, or a destination
that cannot be written (classic case: `llama-server.exe` is running from the stick, so the loaded dll is locked)
aborts **without copying anything**. Copies go to `.staging` names first and are moved into place only once all of
them succeeded — a half-staged runtime (new `VCRUNTIME140` next to a stale `MSVCP140`) is precisely the mixed set the
floor exists to prevent, so it must not be creatable by an interrupted staging either.

**3b. The source is the real System32, not the string "System32".** From a 32-bit process WOW64 silently redirects
`%SystemRoot%\System32` to `SysWOW64`, which holds the **32-bit** DLLs — the wrong architecture for the pinned
`win-cpu-x64` engine, and the version floor happily passes them. `loki setup` uses `Sysnative` when running 32-bit on
a 64-bit OS.

**4. `MinVersion` is a conservative floor, not a derived number — and it is applied in exactly one place.** Microsoft
guarantees the latest redistributable is binary compatible back to 2015, so a *newer* runtime than the engine was built
against is always safe; an *older* one can be missing exports and would fail on the target with an opaque loader error.
We refuse below **14.30** (the Visual Studio 2022 / v143 baseline). The PE linker field on these binaries reads a
generic `14.0` and is **not** a usable signal — this was checked and deliberately not used.

The floor lives in `Get-LokiVcRuntimeFloorCheck` and is used by **both** the staging path and the reporting path. Two
independent adversarial reviewers found the same hole here: presence-only reporting meant setup *refused* a 14.0
runtime when asked to stage it, yet reported that same 14.0 runtime already on the stick as fine — a green check
followed by the exact failure the floor exists to prevent. The weakest file in the set decides.

**4b. Every function whose safety rests on a `catch` sets `$ErrorActionPreference = 'Stop'` itself.** This is the
sharpest lesson of the slice. `Copy-Item` / `Move-Item` / `Remove-Item` failures are **non-terminating by default**, so
a `try/catch` around them is decorative unless the preference says otherwise. The dispatcher sets it globally, which is
why this never showed in production — but the libraries were being *tested* without it, so the suite was exercising the
fail-**open** configuration. Reproduced: with a locked destination, `Invoke-LokiVerifiedDownload` returned
`Ok=$true, Reason='verified'` while the stale, unverified bytes were still on disk. The preference is now set
**inside** each such function (function-scoped: it neither leaks to the caller nor depends on them), and a regression
test drives a genuinely non-terminating failure (`Write-Error`) — a locked-file test cannot cover this, because .NET
throws terminating exceptions regardless of the preference. Related: `Test-LokiFileHash` returns `$false` for a file it
cannot read, rather than letting `Get-FileHash`'s exception escape into a caller that is trying to fail closed.

**5. The verified-download primitive moved to `src/lib/download.ps1`.** It now has two consumers (models and the
engine), and CLAUDE.md §2 requires shared logic to have exactly one home. The functions moved verbatim
(`Test-LokiFileHash`, `Get-LokiHttpFile`, `Invoke-LokiVerifiedDownload`); `lib/models.ps1` keeps the model manifest and
plan. Tests split along the same seam (`tests/download.Tests.ps1`).

**6. Selection is validated before any work.** `loki setup --tier banana` must cost a usage error, not an 18 MB engine
download followed by a usage error. The command resolves and validates the picked tiers first, then does the engine
step, then the models. Picking no model is a legitimate outcome (engine-only stick), not an error.

**7. Each step probes its own host.** The engine comes from `github.com`, the models from `huggingface.co`. A network
that permits one and blocks the other must fail fast and say which — a single up-front probe cannot express that.

## On the review that produced this ADR

Three adversarial reviewers with different lenses (integrity / filesystem / honesty) reviewed this slice. The record is
worth keeping, because it is an argument for the practice:

* The **zip-slip gate survived** ~40 proven attack attempts — the thing most likely to be reached for as "the security
  bit" was not where the bugs were.
* The **honesty lens found the most severe defect** (the fail-open above) — not by attacking the code, but by checking
  whether the comments were true. Two of the fixes written *in response to the first two reviews* were themselves
  wrong, and one of the regression tests written to prove a fix was **vacuous**: it stayed green with the entire
  mechanism deleted, because it only ever tripped an earlier guard.
* Consequently every new guard here is **mutation-checked**: green against the real code, red once the mechanism it
  claims to test is removed. A guard without that check is an assumption, not a test.

## Consequences

* The stick is self-sufficient **only** if the operator ran `--stage-runtime`, or the target already has the VC++
  runtime (very common — Office and most desktop software install it, but a fresh/minimal Windows does not).
  `loki doctor` reporting the runtime status on the target belongs to the harness slice.
* **The setup machine must be Windows.** Staging copies from `System32`, so a Linux/macOS setup machine cannot prepare
  a self-sufficient stick today. This is accepted for now and is a **known limitation for a future major version**, when
  Loki may open up on both ends (setup machine and debug target). Two identified escapes, neither built here:
  (a) download Microsoft's own `vc_redist.x64.exe` and extract the DLLs from its MSI/CAB payload — cross-platform
  extractable, and the operator obtains the files from Microsoft rather than from their own machine; note `/layout` is
  reported broken on recent builds, so this needs a real extraction path, not the documented flag;
  (b) llamafile (Cosmopolitan, no MSVC dependency at all — alive as of 0.10.3, 2026-06-02), at the cost of lagging
  upstream llama.cpp, AV false positives, and a mixed license. This is why the engine lives behind a manifest and a
  thin lib: swapping it is a data + module change, not a redesign.
* Pinning a specific llama.cpp build means the manifest goes stale — llama.cpp releases several times a day. Bumping is
  a deliberate chore: re-run the `gh api` command in the manifest header and replace Version/Url/FileName/Sha256/
  SizeBytes together. Never hand-edit a hash on its own.
* **Load-time verification is not built yet.** The harness slice must verify the engine (and the model it loads)
  against the manifest before starting `llama-server` — otherwise the integrity chain ends at setup time and a stick
  tampered with afterwards would be trusted. Tracked as the next slice, called out here so it is not forgotten.
* **`engine-offline\` is now owned by the archive, and that settles a layout question in the opposite direction to the
  obvious one.** DESIGN.md §2.2 used to lump `llama-server + model tiers + playbooks + grammars` into
  `engine-offline\`, while ADR-0011 put the models in `models\` — which looked like the implementation drifting from
  the design. It is the other way round: once expansion **reconciles** the directory (decision 2b), anything in there
  that the pinned archive does not produce is *deleted*. Laid out the way DESIGN.md described, a `loki setup` re-run
  reports `Pruned: 2` and takes the model tiers (up to 19 GB) and the playbooks with it — verified, not reasoned.
  So the models, playbooks and grammars are **siblings** of `engine-offline\`, each pinned and verified on its own
  lifecycle, and DESIGN.md §2.2 has been corrected to say so and to say why. `models\` (ADR-0011) was right.

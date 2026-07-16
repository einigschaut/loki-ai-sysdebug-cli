# ADR-0011: Offline model acquisition (`loki setup`) + model tiers

Status: Accepted (2026-07-16)

## Context

Stage 2 is the offline engine (DESIGN.md §7): a local CPU-only llama.cpp-style engine running GGUF models, so a
target machine can be diagnosed with **no network**. Two problems shaped the design: (a) nobody wants *all* models, and
not everyone has a 128 GB stick or 32 GB RAM; (b) the models + engine have to get **onto** the stick somehow. The
answer is an **initial setup step, run on the internet-connected machine where the stick is prepared** — it lets the
operator pick which model tier(s) to download, sized to their stick and RAM. This ADR covers the **acquisition**
slice (manifest + `loki setup` picker + verified download); the engine binary, `hwscan` tier auto-select, and the
agent harness are later slices.

Model + binary choices were made from web-verified facts (2026-07), not from memory.

## Decision

**A curated in-repo model manifest pins every downloadable model; `loki setup` lets the operator pick tiers and
downloads each onto the stick, verifying it against a pinned SHA256.** Logic lives in the security core
`src/lib/models.ps1`; `src/commands/setup.ps1` is thin wiring; `src/models/manifest.psd1` is data.

- **Best-in-class FREE model per tier (all Apache-2.0 / MIT — no research/non-commercial licenses).** Quant =
  **Q4_K_M** (size/quality knee for CPU). Picks (benchmark rationale from the research pass):
  - **Nano** ~2 GB RAM — **Qwen3-1.7B** (Apache): universal llama.cpp support, low-RAM fallback. (Granite-4.0-H-1B
    scores higher on IFEval but is a Mamba-hybrid → engine-pin risk; deferred as an alternate.)
  - **Small (default)** ~4.5 GB RAM — **Qwen3-4B-Instruct-2507** (Apache): best small free model (MMLU-Pro 69.6,
    IFEval 83.4), non-thinking (concise), 262K context for long logs. 2.5 GB.
  - **Mid** ~7 GB RAM — **Qwen3-8B** (Apache): best *verified* free ~8B (IFEval 83.18). 5.0 GB.
  - **Large** ~12 GB RAM — **Phi-4 14B** (MIT): best reasoning-per-token at 14B (GPQA 56.1, MMLU-Pro 70.4),
    single-pass. 9.1 GB. 16K context → chunk long logs. Alternate **Qwen3-14B** (Apache, 131K ctx) for long/German
    logs, also shipped.
  - **Max** ~18-24 GB RAM — **Mistral-Small-24B-2501** (Apache, text-only, IFEval 82.9, 14.3 GB) as the practical
    CPU ceiling; **Qwen3-32B** (Apache, 19.8 GB) as the highest free reasoning ceiling for high-RAM machines.
  - Explicitly **excluded** license traps found in research: Qwen2.5-3B (qwen-research), Ministral-8B / Mistral
    Research License, and the 2026 Qwen3.5/3.6 line (implausible/unverified benchmarks + immature GGUF support).
- **Integrity is the point (supply-chain security core).** Each manifest entry pins `Url` (HTTPS), `SizeBytes`, and
  `Sha256`. The SHA256/size are the **Hugging Face LFS object id + size**, read from the HF tree API (reproducible;
  the manifest header documents the exact re-verify command) — not hand-guessed. `Invoke-LokiVerifiedDownload`
  downloads to a `.part` file, verifies the SHA256, and **only then** moves it into place; a **mismatch or a
  download error deletes the partial — nothing unverified is ever kept**, and a non-HTTPS URL is refused outright.
  `Get-LokiModelManifest` is **fail-closed**: it rejects a non-https URL, a malformed hash, an unsafe/traversal
  filename, a non-positive size, or a duplicate id. This module downloads and verifies **only** — it never executes
  a downloaded file (that is the engine slice).
- **`loki setup`** shows the catalog with per-tier size + RAM + license, takes a selection (`--tier <ids|default|
  all>` or an interactive prompt — rudimentary MVP UI on purpose), and downloads + verifies each pick onto
  `…\models\`. It needs the internet (prep-time), so it fails fast with `NetworkRequired` when offline. A failed
  verification maps to `GeneralError`.
- **Binary decision (recorded; used by the next slice, not this one):** the engine will be **llama.cpp's official
  `win-cpu-x64` prebuilt** (MIT, ~18 MB, OpenAI-compatible `llama-server`, **runtime CPU-feature dispatch**
  AVX512→AVX2→AVX→SSE4.2 so one artifact fits any office CPU). Its one caveat — it needs the MSVC runtime
  (`vcruntime140.dll` …) or it silently exits — is solved by **app-local** staging of those DLLs on the stick (no
  admin). llamafile (Apache-2.0, external-gguf, no VC++ dep) is the documented fallback if app-local staging proves
  unreliable (its cost: `.exe`-rename + antivirus false positives on locked-down machines).

## Consequences

- `tests/models.Tests.ps1` (release-blocker): validates the **real** shipped manifest (all https, 64-hex sha256,
  safe filenames, unique ids, Apache/MIT only, exactly one default); fail-closed rejection of http/bad-hash/
  traversal/dup/bad-size; SHA256 verify (match/wrong/missing, case-insensitive); the download plan; and — the key
  property — **break-the-guard**: a tampered download (hash mismatch) is deleted and never kept, a non-https URL is
  refused, an already-verified file is skipped, a download error leaves no `.part`. `tests/setup.Tests.ps1` covers
  the command wiring (offline → NetworkRequired; `default`/`all`/multi/bad-id/verify-fail; interactive picker) with
  the network Mocked.
- **Security core → mandatory 3-vote adversarial review (done).** Ran with integrity-bypass / correctness-PS5.1 /
  test-contract lenses. Outcome: **no integrity bypass** — every write to the destination is SHA256-gated, the
  break-the-guard was proven non-vacuous by a live mutation test, `Test-LokiFileHash` fails **closed** on a hashing
  error, and all 7 pinned hashes/sizes were re-verified byte-for-byte against the HF API. Fixes applied +
  regression-tested: (1) the connectivity preflight probed `api.anthropic.com` instead of the real download host —
  now probes `huggingface.co`; (2) the FileName validator accepted bare `.`/`..`/reserved device names — now
  rejected; (3) an authenticated corporate proxy (HTTP 407) is now handled (default credentials); (4) the
  download-error test now writes a partial then throws, so the cleanup path is actually exercised. Accepted
  residuals (documented): trust-on-pin (TOFU) manifest, an unrestricted https host (the pinned SHA256 gates the
  bytes regardless of origin, so a host allowlist is optional defense-in-depth), and download progress/resume/timeout
  as live-gate polish.
- **The engine slice must verify a model's SHA256 before loading it.** The downloader guarantees an *unverified
  download is never moved into place*, but a stale pre-existing file at the destination that fails re-verification is
  reported (not destroyed). So integrity end to end = this download gate **plus** a load-time hash check in the
  engine slice; the offline engine must not load a `.gguf` whose hash does not match the manifest.
- **Live gate (not unit-tested):** the actual multi-GB download over the real network (HF availability, corporate
  TLS-inspection proxy with a trusted CA, throughput) can only be confirmed live — like the engine/auth live gates.
  The download uses the system proxy + certificate store, so a domain machine behind Sophos/Zscaler with the corp CA
  trusted works transparently; verify on the prep machine.
- **Deliberately out of scope here (later slices, documented so this is not mistaken for the whole offline story):**
  the engine binary download + app-local VC++ staging + extraction; `hwscan` + automatic tier selection for the
  target machine; launching `llama-server` + the agent harness (with the allow-list gate + "scanned data is data"
  prompt-injection defense applied offline too); an optional free-space gate and a manifest-refresh generator
  (`build/Update-LokiModelManifest.ps1`).

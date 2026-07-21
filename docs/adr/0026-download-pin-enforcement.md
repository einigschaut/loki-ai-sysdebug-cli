# ADR-0026: The download primitive enforces its pinned size, checks https end to end, and cannot hang

Status: accepted · Date: 2026-07-21 · Hardens ADR-0011 (model acquisition) and ADR-0012 (engine binary); their
SHA256 pins are unchanged and remain the authority. Contract break on `lib/download.ps1` (see Consequences).

## Context

`lib/download.ps1` is the one path by which a remote file reaches the stick -- the model tiers (data) and the
llama.cpp engine archive (code we later execute). Its own header stated the rules. Checked against the real code and
measured against the real hosts, one rule was a claim rather than a guarantee, and one guard was missing outright:

| stated / expected | measured reality |
|---|---|
| "HTTPS only -- no downgrade" | Only the CALLER's url was checked. Both shipped hosts **302 to a CDN** (`release-assets.githubusercontent.com`, `us.aws.cdn.hf.co`), so a redirect is the NORMAL path -- and the scheme that actually carried the bytes was never inspected. |
| the manifests pin `SizeBytes` | **Never enforced.** `Invoke-LokiVerifiedDownload` had no size parameter at all. Both call sites already read `SizeBytes` -- to *print* "~2.33 GB" -- and then dropped it. |
| "an unverified download is never kept" | True, but only AFTER the whole file is on disk. Nothing bounded how many bytes were written first. |
| (timeouts) | `WebClient.DownloadFile` set none, so a stalled server hangs `loki setup` indefinitely. |

The size gap is the substantive one, and the reason is structural: **a hash cannot be a disk-fill guard.** SHA256 is
only computable once the bytes are already written, so a hostile or broken server could stream until the operator's
stick was full and only then be told its bytes were wrong. The pinned size was a label, not a limit.

Measured on the real hosts (2026-07-21, Windows PowerShell 5.1, headers only): both declare a `Content-Length`
**exactly equal to the pin** (18418645 and 2497281120), both final URIs are https, and the response stream reports
`CanTimeout = True` and accepts a `ReadTimeout`. Every guard below is therefore implementable with information the
real servers already hand us -- none of it is hopeful.

## Decision

**1. The pinned size is enforced in three places, because each catches what the others cannot.**

```
declared Content-Length != pin  -> refuse BEFORE the first byte is written   (free, exact, the common case)
bytes streamed          >  pin  -> abort mid-stream                          (the disk-fill guard)
final .part length      != pin  -> refuse BEFORE hashing                     (catches a SHORT / truncated transfer)
```

The cap bounds the upper end, the final-length check catches the lower end, and the `Content-Length` check makes the
ordinary case cost nothing. `-ExpectedBytes` is **mandatory**: a pin a caller may silently omit is precisely the
decorative pin this ADR exists to remove, so there is no "unenforced" default to fall into.

**2. HTTPS is checked END TO END.** The caller's url must be https (unchanged) *and* the final, post-redirect
`ResponseUri` must still be https. Without it, "HTTPS only" was a statement about hop 0 of a chain that always has at
least two hops.

**3. Timeouts are STALL detection, not a total-time limit.** A multi-GB tier over a slow link is legitimate and must
not be killed for being slow; a transfer that produces no byte at all for two minutes is wedged. Header timeout 60 s,
read timeout 120 s -- both named constants.

**4. `WebClient` is replaced by `HttpWebRequest`, and the proxy/TLS behaviour is deliberately identical.**
`DownloadFile` offers no seam to cap the stream, set a read timeout, or inspect the final URI. What must NOT change is
what makes Loki work behind a corporate TLS-inspection proxy: the system proxy with `DefaultCredentials` (so an
authenticated proxy's HTTP 407 succeeds) and the system certificate store (so a domain-trusted inspection CA
validates). Both are carried over line for line, and the new transport was verified end to end against both real
hosts from inside exactly such a network.

**5. The judgement is split OUT of the transport so it can be tested.** `Get-LokiHttpFile` is the mock seam, so
anything buried inside it is invisible to the unit suite -- a security guard nobody can test is a guard nobody can
trust. The two decisions therefore live in pure functions: `Test-LokiDownloadResponse` (scheme + declared length ->
`ok` / `not-https-final` / `length-mismatch`, table-tested) and `Copy-LokiCappedStream` (the cap itself, unit-tested
with MemoryStreams and no network). The transport is thin wiring over them. Same split as `lib/hwscan.ps1`: the probe
is impure, the judgement is pure.

**6. Every model URL pins an IMMUTABLE revision.** `/resolve/main/` is a moving ref: the repo can replace the file
under it at any time. The SHA256 pin turns that into a *failed* download rather than a poisoned one -- but a failed
download is still a broken stick, and a supply-chain surface should not point at a moving target in the first place.
All seven tiers now pin a 40-hex commit, resolved from the HF API and **verified**: on 2026-07-21 every pinned
revision served exactly the pinned `SizeBytes`. `Get-LokiModelManifest` rejects a `huggingface.co` url that does not
pin a 40-hex revision, so this cannot rot back. The engine url needed no change -- a GitHub release asset at a fixed
tag is already immutable.

## Consequences

* **Contract break, all callers updated** (CLAUDE.md §2): `Invoke-LokiVerifiedDownload` gains a mandatory
  `-ExpectedBytes`; `Get-LokiHttpFile` gains a mandatory `-MaxBytes`. Both `commands/setup.ps1` call sites pass the
  manifest value they were already reading for their progress message. New Reasons: `bad-size-pin` and
  `size-mismatch`; the transport's own refusals surface as `download-failed` with the detail in `Error`.
* **One existing test got SHARPER, not merely adjusted.** The tamper test's payload had to become the same LENGTH as
  the pin, because the size check now runs first. That is the realistic attack anyway: a length-changing swap is
  caught by arithmetic, a length-preserving one only by the hash -- so the test now exercises the hash guard on
  purpose instead of by accident.
* **The SHA256 pin is untouched and still the authority.** Nothing here weakens it. The size checks are a cheaper and
  earlier refusal, plus a bound on the damage a server can do before the hash is able to speak at all.
* **Taking a model update is now an explicit, reviewable act.** A pinned revision does not follow the vendor, so a
  tier upgrade becomes a deliberate manifest change with url + sha256 + size moved together -- rather than something
  a vendor can do to us between two runs. The manifest header documents the two-command re-resolve.
* **Not covered: a redirect chain that stays https but leaves the expected host.** The SHA pin makes that a failed
  download rather than a compromise, and pinning hosts would break the CDN indirection both vendors rely on.

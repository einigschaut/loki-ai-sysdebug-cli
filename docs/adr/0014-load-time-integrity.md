# ADR-0014: Load-time integrity of the offline engine and its models

Status: Accepted (2026-07-16)

## Context

ADR-0011 pinned the models and ADR-0012 the engine, and both verify at **download** time, on the operator's own
machine. ADR-0012 closed with an explicit obligation, quoted here because this ADR exists to discharge it:

> **Load-time verification is not built yet.** The harness slice must verify the engine (and the model it loads)
> against the manifest before starting `llama-server` — otherwise the integrity chain ends at setup time and a stick
> tampered with afterwards would be trusted.

That gap is the whole point. The chain currently ends the moment `loki setup` finishes. Everything after it — the
stick in a drawer, in a pocket, plugged into the very machine we are standing at *because something is wrong with
it* — is unverified. The engine is **code the target executes**, so "whatever is on the stick now" is exactly the
assumption an integrity check exists to remove.

## Decision

**1. The archive is the ROOT of the chain, not the chain.** The manifest pins the **archive's** hash, not the
individual files. So `archive matches the pin` says precisely nothing about the `llama-server.exe` sitting next to
it — an attacker replaces the exe, not the zip nobody runs. `Test-LokiEngineIntegrity` therefore verifies the archive
against the manifest and then verifies **every expanded file against its own entry inside that verified archive**.
That is what ties the bytes Windows will actually load back to the pinned hash. Re-checking only the archive would
have been the comfortable version of this feature and would have proven nothing.

**2. Verification RECONCILES, because the hashes have a hole they structurally cannot see.** A planted
`ggml-cpu-<arch>.dll` is never *mismatched* — there is nothing to compare it against — yet it sits in
`llama-server.exe`'s own directory, first in the Windows DLL search order, exactly where `ggml-base.dll` picks CPU
variants **by name**. So anything the pinned archive does not account for is a failure, the same rule the expand
applies (ADR-0012 §2b) — and against the **same one definition**: `Get-LokiEngineExpectedSet` is now shared by both.
Two copies of "what may live in `engine-offline\`" would eventually disagree, and then `loki setup` would delete what
`loki doctor` calls fine, or bless what setup removes.

**3. The check is read-only, and that is a property, not a detail.** A checker that also repairs cannot be run
against a stick you distrust. Repair is `loki setup` (which reconciles); verification only reads. The test proves it
by **measuring** the tree before and after, not by mocking a writer and calling that proof.

**4. "We verified nothing" must never render as "nothing is wrong."** An archive with zero file entries returns
`nothing-verified` rather than `Ok`. A pinned archive cannot really be empty — but that argument is a chain of
reasoning, and *the shape of every vacuous pass is a loop that ran zero times*. The guard is cheap; the reasoning is
what rots.

**5. An app-local runtime SHADOWS the host's, so a stale one is a failure even on a healthy host.** This inverts the
intuition and is why `Resolve-LokiVcRuntimeAvailability` exists as one function rather than two checks the caller
combines: Windows searches the exe's own directory **before** the system directories, so a too-old staged
`VCRUNTIME140.dll` is loaded in preference to a perfectly good system-wide one, which is never reached. Falling back
to the host here would be a bug wearing the costume of a kindness. A **partially** staged set is the same trap in
disguise: the staged files win, the absent ones fall through to the host, and the engine loads exactly the mixed set
the floor exists to prevent (ADR-0012 §3). `--stage-runtime` cannot create that state, but an interrupted copy or a
deleted file can, so it is diagnosed rather than assumed away.

**6. The host runtime probe reads the 64-bit registry view explicitly — WOW64 again, now in the registry.** ADR-0012
§3b caught WOW64 redirecting `System32` to `SysWOW64`; the same redirection applies to `HKLM:\SOFTWARE\...`, which
from a 32-bit process silently becomes `HKLM:\SOFTWARE\Wow6432Node\...`, where the **x64** runtime does not register.
A 32-bit PowerShell would report a perfectly good runtime as absent. `Get-ItemProperty` cannot express a registry
view, so the 64-bit view is opened through the .NET API. This also makes the manifest's `RegistryKey` field live: it
was declared and validated by ADR-0012 and read by **nothing** until now.

**7. `loki doctor --engine` is opt-in, because honesty about cost beats a fast lie.** It hashes every installed
model: seconds for `nano`, roughly a minute for a 19 GB tier on USB. The default `loki doctor` must stay instant, so
the expensive question is a flag — and an operator who asks it is told up front that it hashes. There is deliberately
**no verified-state cache**: any cache would have to live on the same stick as the thing it vouches for, so whoever
can plant a DLL can fix the cache, and it would buy speed by giving up the only property that matters.

**8. Not installed (5) and does-not-match-the-pin (1) are different exit codes on purpose.** A stick with no engine is
not a broken stick, it is one `loki setup` has not been run for — `OfflineEngineMissing` (5), the same meaning it has
in `hwscan`. An engine that does not match its pin is `GeneralError` (1). Conflating them would make tampering look
routine, and a script could not tell "expected on a fresh stick" from "do not trust this stick".

**9. Absent model tiers are not listed one by one.** `loki setup` deliberately lets the operator take a subset
(ADR-0013), so listing every absent tier as a warning turns a normal stick into a wall of noise and trains the
operator to ignore the report — which is how a real `mismatch` gets scrolled past. Only tiers that are **present**
get a row; a stick with none gets a single line.

## Consequences

* **The enforcement call site does not exist yet, and this ADR must not be read as if it did.** This slice builds and
  proves the mechanism and exposes it as a report. Nothing yet *refuses to start* on a bad hash, because there is
  nothing that starts anything: the harness (`lib/agent.ps1`) is the next slice, and it must call
  `Test-LokiEngineIntegrity` + `Test-LokiModelIntegrity` **before** `llama-server`, treating any non-`verified`
  result — including `not-installed` for the model it was about to load — as fatal. Stated plainly here for the same
  reason ADR-0012 stated its own gap: an obligation that is only implied is an obligation that rots.
* Verification costs one full read of the engine (~46 MB expanded + the 18 MB archive; well under a second) plus one
  full read of every installed model. For the harness that is a real start-up cost on the large tiers and will be
  visible; it is the price of the property and must not be silently optimized away into a cache (§7).
* `Get-LokiModelLayout` now states where the tiers live, once, the way `Get-LokiEngineLayout` always has for the
  engine. The asymmetry was the tell: three call sites had each re-spelled `models\manifest.psd1` by hand.
* Reparse points are **not** specially handled. A symlink cannot defeat the hash check (hashing and loading both
  follow it, so they see the same bytes), and a planted file behind one is still enumerated as unexpected. A junction
  pointing out of the tree is not analysed, and this is recorded as a known limit rather than claimed as covered.

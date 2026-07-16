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

**6. The host runtime probe reads the 64-bit registry view explicitly.** `HKLM:\SOFTWARE\...` is WOW64-redirected to
`HKLM:\SOFTWARE\Wow6432Node\...` from a 32-bit process, and `Get-ItemProperty` cannot express a view, so the 64-bit
view is opened through the .NET API. The reason is **determinism, not repair**: an earlier draft of this ADR claimed
a 32-bit PowerShell "would report a perfectly good runtime as absent", and adversarial review disproved it by running
the naive path from a real 32-bit PowerShell — the x64 redistributable *does* mirror its key into the redirected
view, which answered correctly. But the redirected view also carries an `X86` entry alongside `X64`, and the
mirroring is an installer implementation detail, not a contract. Opening `Registry64` is what makes *"the x64
runtime"* unambiguous by construction rather than by luck. The correction is recorded rather than quietly edited,
because ADR-0012 opens by promising every claim was verified against the artifact and not recalled — this one was
recalled, and a maintainer would have "fixed" other registry reads on a false premise.

*Test gap, stated:* mutating `Registry64` → `Registry32` passes the whole suite, precisely because both views answer
correctly on a real machine. The mechanism is therefore an **assumption**, not a mutation-checked guard, and cannot
be made one without a machine where the mirroring is absent.

This decision also makes the manifest's `RegistryKey` field live: it was declared and validated by ADR-0012 and read
by **nothing** until now.

**6b. The staged Microsoft runtime is verified by SIGNATURE, because it is the one blind spot a hash cannot cover.**
The sharpest finding of the review, and it was a real hole: the three DLLs are not in the pinned archive (nothing to
hash them against) and `-PreserveNames` spares them from the reconcile — yet Windows loads them into `llama-server`
from its own directory, **first** in the DLL search order. That made them the highest-value plant site on the stick,
better than a `ggml-cpu-<arch>.dll`, which at least gets hashed. A reviewer patched 64 bytes of `VCRUNTIME140.dll`
and `doctor --engine` reported `engine=verified runtime=ok`, **exit 0**. The only gate was the version resource —
attacker-controlled metadata inside the very file being vetted, which still read `14.51` after the patch.

`Test-LokiMicrosoftSignature` closes it, and it does **not** re-open §7's no-cache argument: the trust anchor is the
*target's* certificate store, not the stick, so "whoever can plant the DLL can fix the record" does not apply.
Verified against the real files rather than recalled:

* the three DLLs are **embedded** Authenticode-signed, so the signature survives the copy onto the stick (`Valid` on
  the copy). This is not a given — `kernel32.dll` is **catalog**-signed, which validates by hash via the *machine's*
  catalog and would therefore not travel to a different target. A catalog-signed source would be a trap.
* a patched byte → `HashMismatch`, while `VersionInfo.FileVersion` still read fine.
* the chain terminates at `CN=Microsoft Root Certificate Authority 2011, O=Microsoft Corporation`.
* cost: ~72 ms for three files.

`Status = 'Valid'` **alone is not enough** and must not be mistaken for it: it means "signed by someone this machine
trusts", which any attacker holding a public code-signing certificate also achieves. So the chain **root** is pinned
to Microsoft's own PKI — proven necessary by a test against a real, validly signed non-Microsoft binary found on the
host. Revocation is deliberately not re-checked when walking to the root: `Valid` already covers trust, and a
CRL/OCSP fetch would stall the one tool someone is running *because* the machine is broken.

Two traps fixed in the same breath, both found by review, both of which turned the check into a false accusation:
`Get-AuthenticodeSignature -FilePath` is **wildcard-expanding** (`[` and `]` are legal filename characters), so a
stick in a folder named `loki [backup]` reported three genuine Microsoft DLLs as unverifiable → `-LiteralPath`. And
`signature-unreadable` was filed under "do not trust this stick": *could not determine* is not *forged*, and saying
so is the mirror image of the lie §4 forbids. It now lands in `INCOMPLETE` with an honest "could not be determined",
and still cannot reach exit 0.

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

**10. "Could not read it" is its own answer, and it is not "it was altered."** (Added by the follow-up fix; this
replaces a limit the original slice shipped knowingly.) `Test-LokiFileHash` returns `$false` for a file it cannot
read — correct for *downloading*, where anything unproven must be refused, and wrong for *verifying*, where the whole
job is to say what is true. So the primitive is now tri-state (`Get-LokiFileHashState` → `match` / `differ` /
`unreadable` / `missing`) and `Test-LokiFileHash` is a bool wrapper over it, leaving every acquisition decision
byte-for-byte as it was. Verification maps the new states to `archive-unreadable` / `file-unreadable` / a model
`unreadable`, all at severity `unknown` → **exit 5, never 0**.

This matters more here than the phrasing suggests, because **Loki runs off a USB stick**: "this file cannot be read"
is the medium's own failure mode — a bad sector, an AV/EDR scanner holding a brief exclusive handle, a deny-read ACE
on an NTFS-formatted stick — long before it is an adversary. (A *running* executable is not one of these: Windows
maps images with share-read, so `llama-server.exe` hashes fine while it runs. Measured; the intuitive assumption is
wrong.) Answering *do not trust this stick* to a dying stick cries wolf on the common case, and a guard that cries
wolf gets ignored on the day it is right. It is the mirror of §4's rule: not *we verified nothing, so nothing is
wrong*, but *we verified nothing, so everything is wrong*.

Ordering is a safety property, not a preference: `file-mismatch` and `unexpected-file` are both tested **before**
`file-unreadable`, so an unreadable file can never mask a positive finding. It may outrank `file-missing`, which is
merely the other half of the same broken-install answer.

**11. Setup's temporaries live in a SIBLING, `engine-staging\`, not in `engine-offline\`.** (Added by the same fix.)
Everything setup writes on its way in is unverified while it is being written — a download's `.part`, a runtime DLL's
`.staging` copy, the `.bak` of the file it displaces. Inside `engine-offline\` those are indistinguishable from a
planted file, so the reconcile called them out and a `loki setup` killed mid-download (Ctrl-C on 200 MB over a slow
link) made `doctor --engine` report the stick as tampered with. Reproduced before fixing; the baseline verified
clean, so the result was not vacuous.

The tempting fix — add `*.part`/`*.staging`/`*.bak` to the expected set — was rejected: it hands an attacker a naming
convention, because `evil.dll.bak` sits in `llama-server.exe`'s DLL search path exactly like `evil.dll` does. A
suffix is not a permission, and there is now a break-the-guard test per suffix saying so. The sibling follows the
precedent `Expand-LokiVerifiedArchive` already set (it builds `engine-offline.new-<guid>` beside the target, never
inside it), and sits on the same volume so committing a staged file stays a rename rather than a copy.
`Copy-LokiVcRuntimeAppLocal`'s `-StagingDir` is **mandatory** rather than defaulting to `DestDir`: the natural
default is exactly the defect, and a default nobody has to think about is how a defect comes back.

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
* `Get-LokiModelLayout` now states where the tiers live, once; three call sites had each re-spelled
  `models\manifest.psd1` by hand. This does **not** finish the job: `Get-LokiEngineLayout` locates the archive and the
  server exe but not the engine *manifest*, so `'engine\manifest.psd1'` is still hand-spelled — and this slice added
  the second instance of it (`setup.ps1`, `doctor.ps1`). Worth closing next time someone is in these files.
* **A pin bump to an archive that carries directory entries would report an honest stick as tampered.** The pinned
  `b10038` archive is flat (verified: 51 entries, 0 directory entries, no subdirectories), so nothing is wrong today.
  But `Test-LokiArchiveEntrySafe` rejects a trailing separator via its empty-segment rule, and most zip writers *do*
  emit directory entries — so a routine bump could turn `loki setup` into `unsafe-entry` and `doctor --engine` into
  exit 1. The directory-entry handling in `Get-LokiEngineExpectedSet` and both zip loops is consequently **dead code**
  today, reachable only by a caller that does not pre-gate; its unit test passes because it calls the pure function
  directly and bypasses the gate. Left as-is rather than loosening a heavily-reviewed zip-slip gate inside this
  slice, but recorded so the next bump is not a mystery.
* **Known limits, stated rather than implied.** Each of these was demonstrated by adversarial review with a running
  repro, and each is a real gap in the reconcile — the hash chain itself resisted everything thrown at it:
  * **Alternate data streams** are not enumerated: `llama-server.exe:payload.dll` does not change the file's hash and
    is not listed, so the stick reports `verified`. Not loadable by `ggml-base.dll`'s by-name CPU-variant lookup, so
    it yields no code execution — but "was this stick altered?" still gets the wrong answer.
  * **A case-variant twin** (`GGML-CPU-HASWELL.DLL` beside `ggml-cpu-haswell.dll`) on a directory flagged
    case-sensitive is spared: the expected set is `OrdinalIgnoreCase` and the hash loop walks *archive* entries, so
    the twin is never looked at. The loader resolves the archive-cased name, so again: wrong answer, no execution.
  * **MAX_PATH.** PowerShell 5.1 has no long-path support, and `Test-Path` on an existing >259-character path returns
    `$false` rather than throwing — so a deep tree reports `file-missing` (exit 1, "this stick is wrong") for files
    that are present and correct. Reachability is low (a stick is `E:\`; it needs the tree copied somewhere deep like
    a synced folder), but the failure mode is a confident false accusation with no mention of path length.
  * **A file reparse point is deliberately not flagged** (only directory ones are). Hashing follows the link, exactly
    as loading does, so a swapped target is caught as `file-mismatch`; flagging every file reparse point would
    false-alarm on a tree under OneDrive Files On-Demand, whose placeholders *are* reparse points.
  * **An adversary who can make a file unreadable can soften the verdict from 1 to 5** — the residual of §10, and the
    reason that decision is a judgement rather than an obvious call. Holding a `FileShare.None` handle needs a live
    process on the target (i.e. code execution already), but a deny-read ACE on an NTFS-formatted stick is persistent
    and needs no process. Either way the report changes from *this stick was altered* to *could not determine* on a
    stick that **is** altered. It can never reach **0**, so nothing loads and nothing executes; what is lost is the
    operator's belief, not the gate. Accepted knowingly: the alternative accuses every failing stick of tampering,
    and that trade runs the wrong way round on hardware this disposable.
  * **`engine-staging\` is unverified space, by construction.** Nothing in it is trusted and nothing is left in it
    (asserted on both the success and rollback paths), but it does not close the pre-existing gap it inherits: a
    runtime DLL can in principle be swapped between the `.staging` copy and the move that commits it. That window
    existed before §11 and is unchanged by it — the file lands app-local either way, and §6b's signature check is
    what actually catches it at load time.
* **The threat model is narrower than it looks, and saying so is part of the deal.** The pin (`engine/manifest.psd1`)
  and the checker (`lib/integrity.ps1`) live on the same volume as the thing they vouch for. An attacker who can
  write anywhere on the stick rewrites the pin or the checker and every guarantee here evaporates. So this slice's
  real boundary is *"the app tree is trusted; `engine-offline\` may not be"* — which is worth something concrete: it
  catches corruption, a bad pin bump, and the realistic case of an infected target machine writing to a mounted stick
  opportunistically. It does **not** stop a Loki-aware attacker with write access to the whole stick. That is what
  DESIGN.md §2.2's `manifest.sig` is for, and it is not built. Stated here so nobody mistakes the scope.

# ADR-0018: The raw collector — two artifacts, an English dump, and a bound that catches hangs rather than slowness

Status: accepted · Date: 2026-07-17 · Implements the first item of DESIGN.md §7 Stage 2 · Makes good on the escape
hatch promised by DESIGN.md §3.2, ADR-0013 §6 and ADR-0017 §5

## Context

DESIGN.md §7 puts "the raw collector (works everywhere, no AI required)" **first** in Stage 2, and three places in the
shipped product already point at it:

| where | what it says today |
|---|---|
| `loki status`, no network | *"only the offline path (**collect**/offline) is available"* |
| `hwscan.machineTooSmall` | *"Nothing to download would help — collect a raw diagnostic dump instead."* |
| ADR-0013 §6 | *"`loki collect` (**not built yet**) is the path DESIGN.md §3.2 names for it."* |

So this was not merely the next roadmap item: on a machine with no network, `loki status` was sending the operator to
a command that did not exist, in the one situation where they have the fewest options left. `loki collect` is what
Loki can still say with no network, no auth, no model and no admin — the last honest answer before "sorry".

The offline *plumbing* was already built (`Invoke-LokiWithEngine`, `Start-/Stop-LokiEngineServer`,
`Resolve-LokiEnginePreflight` in `lib/agent.ps1`); what was missing were the commands on top of it.

## Decision

### 1. Two artifacts, because the dump has two readers who want opposite things

`reports\collect-<stamp>.json` is canonical; `reports\collect-<stamp>.txt` is rendered from the same in-memory
document. DESIGN.md §3.2 says `offline --analyze` is *"pure summarization over a diagnostic dump"* — that wants
structure. The roadmap says the collector must be useful with *"no AI required"* — that wants a technician-readable
page. One artifact cannot be both without being bad at one. The text costs nothing extra: no second probe, same
document, one more `Set-Content`.

### 2. The artifacts are English and culture-invariant; the CLI around them is localized

CLAUDE.md §10 draws its line at *"user-facing runtime output"*. A written report is an **artifact**, not runtime
output: it gets mailed to a colleague, attached to a ticket, diffed against last week's, and fed to a small local
model. It must read the same regardless of whose machine produced it. So the dump's field names are the JSON's own
keys (structural English — the same exception §10 already makes for group headers) and its values are formatted
culture-invariantly, while everything `loki collect` *prints* goes through `Get-LokiText` as usual.

Proven live on a de-DE host with `LOKI_LANG=de`: the CLI said *"Gesammelt: 2 ok, 0 fehlgeschlagen"* while the JSON
carried `"UptimeHours": 34.2` — a decimal **point**, on a machine where `'{0}' -f 34.2` yields `34,2`.

The measurements that make this cheap (all under Windows PowerShell 5.1):

```
ConvertTo-Json         38.4 under de-DE / en-US / fr-FR alike   -> already invariant, no guard needed
[string]38.4           "38.4" even under de-DE                  -> the invariant formatter
'{0}' -f 38.4          "38,4" under de-DE                       -> correct for the CLI, wrong for the artifact
```

The first of those killed a guard I had planned before writing it. The third reappeared anyway, one branch away, in
the dictionary path of the very function whose contract says "culture-invariant" — caught by its own test.

### 3. Timestamps are ISO-8601 strings; a raw DateTime never reaches `ConvertTo-Json`

Measured: `ConvertTo-Json` renders a `DateTime` as `\/Date(1784205000000)\/`. The first reading — "it loses two
hours" — was **wrong**, and worth stating because it changes the reason:

```
input                : 2026-07-16T14:30:00  Kind=Unspecified   (local, UTC+02:00)
serialized           : {"D":"\/Date(1784205000000)\/"}
epoch decoded as UTC : 2026-07-16T12:30:00Z
that UTC as local    : 2026-07-16T14:30:00+02:00      <- the INSTANT is correct
deserialized         : 2026-07-16T12:30:00Z  Kind=Utc  -> -eq against the original: False
```

The value survives; the *presentation* does not. Anything rendering it naively prints 12:30 for a machine that booted
at 14:30. But the decisive argument is the reader: this dump's two consumers are a technician and a small local
model, and neither reads `\/Date(1784205000000)\/`. ISO-8601 explains itself and round-trips exactly (measured:
`True`). CIM hands back `Kind=Local`, so `[datetimeoffset]` carries the machine's real offset instead of inventing
one. `tests/collect.Tests.ps1` asserts the serialized JSON contains no `/Date(` anywhere — the regression guard for
any future battery that forgets.

### 4. The bound catches a hang, not slowness — and the duration is itself data

The instinct after the `loki doctor` fix (5 s for a BitLocker answer we could never get) is a tight timeout. That
instinct is wrong here. Measured cold on a healthy machine:

| battery | cold | rows |
|---|---|---|
| `Win32_BIOS` | 20 ms | 1 |
| `Win32_ComputerSystem` | 31 ms | 1 |
| `Get-Process` | 61 ms | 399 |
| `Win32_NetworkAdapterConfiguration` (IPEnabled) | 75 ms | 1 |
| `Get-LokiHostPosture` | 173 ms | 1 |
| `Win32_LogicalDisk` | 396 ms | 14 |
| `Win32_OperatingSystem` | 422 ms | 1 |
| `Win32_Service` | **1137 ms** | 316 |
| `Win32_Processor` | **1182 ms** | 1 |
| `Get-LokiHardwareProfile` | **1475 ms** | 1 |

`Win32_Service` legitimately needs ~1050 ms, and `-OperationTimeoutSec 1` kills it outright (measured: `Timed out`,
0 rows; at 2 s: 316 rows). On a thrashing host — the host this command exists for — that honest query is slower
still. A tight bound would cut away the data we came for on exactly the machines that need it. So the bound is 10 s:
roughly ten times the slowest real battery, which catches a hang and tolerates a sick machine being sick.

`-OperationTimeoutSec` is the bounding primitive because it is the one that **works under ConstrainedLanguage**
(measured in the doctor PR: `[PowerShell]::Create()` throws there, `-OperationTimeoutSec` bounds linearly). There is
no universal wall-clock bound available on a CL host; batteries that are not CIM queries are cheap by selection
instead (`Get-Process`: 61 ms). That is a real limit of this design, recorded rather than papered over.

Because there is no tight bound, **`DurationMs` is recorded per battery and is part of the report**. A machine where
enumerating services takes 30 s *is* the finding; the number that proves it should not be thrown away.

A CIM timeout is reported as the distinct status `timeout`, not `failed`, because they are different findings for a
technician: *this machine is sick here* versus *this probe does not work here*. The discriminator is
`MessageId = 'HRESULT 0x40004'` (WBEM_S_TIMEDOUT), **not** the message text — measured on this de-DE box the text
came back as the English "Timed out", but relying on that is a locale trap waiting for the first machine where it
does not. Contrast measured against a bogus class: `HRESULT 0x80041010` / `InvalidClass`.

### 5. A failed battery is content, not a failed run

`loki collect` exits `Ok` whenever a dump was **written**. A denied or timed-out battery is recorded in the dump and
does not change the exit code; only an unwritable dump is `GeneralError`. The reasoning is the command's whole
purpose: it is for machines that are already broken. Exiting non-zero because one probe was denied would make the
tool report failure on exactly the hosts it exists to serve, and a wrapping script would throw the dump away. Even an
all-failed dump is an answer — *"WMI answers nothing on this host"* is a diagnosis, not a nothing.

### 6. Batteries, and what is deliberately not collected

Collected: `os` · `hardware` · `storage` · `network` · `processes` · `services` · `posture`.

Deliberately **not** collected, because this dump is written on a customer's machine and then leaves it:

| not collected | why |
|---|---|
| BIOS serial number | identifies the customer's asset; buys the technician nothing. BIOS *version* and *date* are kept — firmware age is a real lead. |
| MAC addresses | identify the hardware across dumps; answer no question being asked here. |
| logged-in user name | the machine is the subject, not the person at it. Computer name is kept — it is the dump's own label. |
| file contents, document names, browsing history | never in scope for a diagnostic dump. |

IP addresses, gateways and DNS servers **are** collected: network diagnosis is not possible without them, and they
are the customer's own topology on the customer's own stick. `reports/` is `.gitignore`d (see decision 9).

### 7. The event-log battery is deferred to its own PR

It is simultaneously the slowest probe and the **prompt-injection surface** for `offline --analyze` — DESIGN.md §3.2
calls indirect injection through logs and filenames *"a real threat model here, not a theoretical one, and ... tested
against directly"*. That deserves a PR with its own injection tests, not a ride-along in this one. The collector's
stance meanwhile: collected text is typed data in named fields, never concatenated into anything instruction-shaped;
the defence that matters belongs in the analyze prompt, and lands with it.

### 8. Reuse over rebuild, and the 420 ms it costs

`hardware` calls `Get-LokiHardwareProfile`, which re-queries `Win32_OperatingSystem` internally — so it overlaps the
`os` battery by ~420 ms of the 1475 ms. Paid knowingly: the alternative is a second copy of the KB→GB conversion
whose own comment in `lib/hwscan.ps1` warns *"a units mistake here would silently be a factor of a million"*. 420 ms
is not worth owning that twice (CLAUDE.md §2). Likewise `processes` reuses `Get-LokiMemoryConsumer`, `network`
reuses `Test-LokiConnectivity`, `posture` reuses `Get-LokiHostPosture`.

`Win32_Service` is queried **once** and shaped twice on our side: measured, the server-side filter
(`StartMode='Auto' AND State!='Running'`) costs 1044 ms against 1137 ms unfiltered — the price is *enumerating* the
services, not returning them, so a second filtered query would buy nothing and pay another full second.

Whole run, measured live: **3764 ms** for all seven batteries.

### 9. `reports/` is gitignored

This PR makes `reports\` the first written directory in the product (DESIGN.md §2's layout named it; nothing had
ever written there). A dump names the machine that produced it. `.gitignore` did not cover it, so the first
developer to run `loki collect` from a clone and type `git add -A` would publish their own network topology to a
**public** repository. Ignored at the root and under `src/`, because AppRoot is `src/` in a working copy.

## Consequences

* `loki status` and `hwscan.machineTooSmall` now name `loki collect` — a command that exists. The `offline` half of
  the old status string was removed rather than left as a promise; the `offline` PR re-adds it when it is true.
* `Get-LokiCollectPath` uses `[IO.Path]::Combine`, not `Join-Path`. Measured: `Join-Path` is provider-bound and
  throws `DriveNotFoundException` for a path on a drive that does not exist, which would make a function documented
  as PURE depend on the filesystem. Combine is byte-identical on every real path (including trailing separators and
  UNC) and simply lacks the failure mode. This was not a live defect — AppRoot always exists in production — but the
  contract said "pure" and was not. `lib/posture.ps1` had already won the same lesson.
* The report renderer's recursion is bounded by an explicit predicate (`Test-LokiCollectRowList`) rather than an
  inline condition, because the first version **died with `Insufficient stack`** on the first live run:
  `Get-LokiMemoryConsumer` returns *hashtable* rows, a hashtable is `IEnumerable`, and `@($hashtable)` wraps it into
  a single element that is the same object — an identical value, recursed on forever. The `@(...)` around a
  `return ,` callee compounded it into `Object[]{ Object[]{ Object[]{ rows }}}`. Both are covered by tests.
* Mutation-checked, 11 mutations: **10 caught**. `M10` (dropping `-ErrorAction Stop` from the `New-Item` that
  creates `reports\`) **survives by design** and is documented at the call site: it cannot change the observable
  outcome, because a silently-failed `New-Item` leaves `reports\` absent and the following `Set-Content` refuses
  anyway through its own guard. There is no case where `New-Item` fails and `Set-Content` succeeds. It is kept for
  the better error message, not as a second guard, and the mutation stays in the harness so that the day it starts
  being caught, someone notices the relationship changed.
* No universal wall-clock bound exists under ConstrainedLanguage (decision 4). A battery that hangs in a non-CIM
  call would hang the command. Today every non-CIM battery is cheap by selection; a future battery that is not must
  bring its own answer to this, not inherit a guarantee that was never made.
* The tier table in DESIGN.md §3.2 says a machine below every tier gets "raw collection only". That path is now
  real and reachable, but it has not been exercised on a machine that actually fails every tier — only reasoned
  through. Worth a live check on a small box when one is at hand.

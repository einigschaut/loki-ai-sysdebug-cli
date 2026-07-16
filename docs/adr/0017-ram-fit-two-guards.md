# ADR-0017: Two guards instead of one reserve, and a recommended default instead of the largest that fits

Status: accepted · Date: 2026-07-16 · Supersedes the budget rule of ADR-0013 (everything else in ADR-0013 stands:
installed-only selection, unknown RAM is a refusal, pure + table-tested judgement, `--force` is per-tier)

## Context

The rule shipped in ADR-0013 came verbatim from DESIGN.md §3.2:

```
reserve = max(4 GB, 25% of total RAM)
budget  = available RAM - reserve
choose the largest tier whose resident size <= budget
budget < ~2 GB -> no LLM
```

Run against real machines, it is wrong in **both** directions:

| machine | old rule | what it should say |
|---|---|---|
| maintainer's dev box, 31.46 GB total / 7.06 GB available | reserve 7.87 → budget **0.00** → **nothing at all** | `small` |
| small office PC, 8 GB / 3 GB free | reserve 4.00 → budget 0.00 → **nothing** | `nano`, after closing something |
| 128 GB server, 40 GB free | reserve **32.00** → budget 8.00 → `mid` (7 GB) | far more than `mid` |

The measurements behind the first row, taken on the box in question:

```
total=31.46 GB  available=7.06 GB   (in use: 24.4 GB)
claude 17 procs 2.85 GB · firefox 13 procs 2.41 GB · Memory Compression 2.24 GB · Code 11 procs 1.73 GB
```

## The diagnosis

The old rule commits a **category error**: it answers *"how much must we leave behind?"* with a number derived from
**installed** RAM. But what an OS needs in order not to thrash is roughly **constant** — it does not grow because you
bought more RAM. That is why a 128 GB server reserves 32 GB and settles for a 7 GB model, while a 31 GB dev box is
refused outright for RAM it merely *owns*.

The single figure was conflating two questions that have different shapes:

* **don't take what isn't there** — a function of *available* RAM, and absolute.
* **don't dominate the machine you came to help** — a function of *total* RAM, and proportional.

One number cannot be both.

## Decision

**1. Two independent guards.**

```
thrash guard    resident + 1.5 GB <= available RAM
ballast guard   resident <= 60% of TOTAL RAM
```

The 1.5 GB headroom is deliberately absolute: it is "the operator can still keep a window and Task Manager open while
this runs", which does not scale with the memory bank. The 60% cap is deliberately proportional, because burden is.

**60% is not an invented number.** DESIGN.md's own "Min. host RAM" column already encoded a ballast cap implicitly:
its rows sit at 2.5/4, 4/8, 6.5/16, 10.5/24, 23/48 — i.e. **41–62%** of the host. The guard makes explicit what the
table always meant, and lands at the permissive end of it deliberately: ADR-0013 records that `ResidentGB` figures
"err **high**, which is the safe direction", so 60% against conservative resident figures is roughly 50% against true
ones. The `Min. host RAM` column is now *derived* (`resident / 0.6`) rather than hand-maintained, so it cannot drift
away from the rule again.

**2. Ballast is checked FIRST, and that order is a correctness property, not a preference.** A tier can fail both
guards at once (8 GB box, 7 GB free, a 7 GB model). Failing ballast is permanent; failing thrash is a "close something
and retry". Report the wrong one and the operator goes off to free memory that could never be enough. Tested
explicitly rather than left to the order the code happens to be written in.

**3. A per-tier verdict replaces a boolean.** `fits` / `fits-if-freed` (+ how much) / `too-big`. This is what makes the
report actionable, and it is what the old `Ok`/`BudgetGB` pair could not express: "no" was never the useful answer.

**4. The automatic pick is the RECOMMENDED tier that fits — not the largest.** This is the one place the ADR argues
against the obvious. RAM is not the only capacity: the manifest's own note puts the 32B tier at **~1–2 tok/s on CPU**.
"Biggest that fits" would hand a 128 GB server a model that technically runs and practically doesn't. The manifest's
`Default = $true` already encodes somebody balancing quality against speed; a memory figure does not get to overrule
it. Anything larger is **offered** by the report and reachable with `--model` — the ceiling binds the *automatic* pick
only, because a ceiling the operator cannot cross is not a default, it is a cage.

The ceiling is read from the **installed** set. A stick without the recommended tier was curated that way
deliberately, and inventing a ceiling from a model the operator chose not to carry would be a constraint derived from
absent data — so that case falls back to the largest that fits.

**5. "Nothing helps here" is now CHECKED, not asserted.** The old 2 GB floor *declared* that below it no download
could help, and pointed at raw collection. That is right on a 4 GB box and wrong on a stick that merely lacks a small
tier. The catalogue is now consulted: if some tier could run here, the operator is told to fetch it; only if none can
is raw collection named. Same intent as ADR-0013 §6, but true.

**6. The guidance names the memory holders, and does not promise a yield.** Which counter to use was measured on the
real 31.46 GB box (24.5 GB in use):

| counter | sums to | verdict |
|---|---|---|
| `PrivateMemorySize64` | **36.23 GB** | more than the machine *has* — it is commit charge and counts paged-out pages. Would be a lie. |
| `Working Set - Private` | **10.01 GB** | against 24.5 GB in use — excludes shared pages, understates an app by ~half. |
| `WorkingSet64` | **23.15 GB** | the only one in the same quantity as `AvailableRamGB`, and checkable by the operator against Task Manager. |

`WorkingSet64` wins, but it **double-counts pages shared between an app's own processes**, so it is an upper bound.
The honest response to that is *phrasing*, not a better counter: the report says an app is **holding ~X GB**, never
that closing it **frees X GB**. No counter on Windows can honestly promise the latter.

Kernel bookkeeping (`Idle`, `System`, `Registry`, `Memory Compression`, `Secure System`) is excluded — "Memory
Compression" holds *other* processes' pages in compressed form, so listing it double-counts what is already
attributed to the apps, and "close Memory Compression" is not advice anyone can take.

A **"closable app"** classification was prototyped and **rejected**: the property tested (does the app group own a
window in an interactive session?) correctly suppressed `Memory Compression` and `svchost`, but also suppressed
`msedgewebview2` — 45 processes holding 2.19 GB, a genuine consumer with no window of its own. A classifier that hides
the second-largest holder is worse than no classifier. The list reports facts, ranked, and a technician decides.

## Consequences

* **Contract break, all callers updated** (CLAUDE.md §2): `Get-LokiTierBudget` is gone; `Select-LokiTier` takes the
  two RAM figures instead of a pre-computed `-BudgetGB`. Reason tokens `override-too-large` → `override-needs-free` /
  `override-too-big` (the split is the point), and `budget-too-small` disappears with the floor.
* **`Resolve-LokiEnginePreflight` no longer casts the probe's `$null` to `[double]`.** `[double]$null` is `0.0`, which
  turned "the probe could not read this machine" into "this machine has no RAM". Both refused, so it was never
  visible — but only the uncast form can report *which*, and `Get-LokiHardwareProfile`'s whole contract is that a
  field may be `$null`. The Ok result also drops `BudgetGB`, which nothing read.
* **Some machines now get a model where they previously got nothing** — that is the entire point, and it is a
  deliberate loosening. The failure mode it trades against is real: a tier that fits by 0.1 GB on a box whose
  workload grows will swap. The thrash guard is re-checked live in the harness at start time (ADR-0015), not taken
  from a stale report, which is the mitigation.
* **Reading an absent key off a hashtable throws under StrictMode -Latest** (measured on 5.1: `PropertyNotFoundException`,
  it does **not** yield `$null`). `Select-LokiTier` reads `Default`, which older-shaped entries lack, so tier fields go
  through a guarded accessor. Without it the picker would have been green in tests and fatal on real data.
* **The 60% cap and the 1.5 GB headroom are judgement, not physics.** They were chosen with the maintainer against
  measured machines and are the two numbers to revisit if real-world use disagrees. They live as named constants in
  one place for exactly that reason.
* **`loki setup`'s picker is deliberately NOT tier-filtered by this rule.** Setup runs on the machine preparing the
  stick, and the stick is carried somewhere else — filtering the download list by the *preparing* machine's RAM would
  be confidently wrong. The stick stays portable; the verdict happens where it is used.
* **Open, and not fixed here: `Get-LokiText` renders numbers in the ambient culture** while pinning only the message
  catalog — a German box shows "up to 38,4 GB" inside an English sentence, and any output assertion carrying a decimal
  is green in CI (en-US) and red on a German dev box. Found while writing these tests; it belongs to `lib/i18n.ps1`
  and every command, not to a RAM change. `tests/hwscan-command.Tests.ps1` formats its expectations in the ambient
  culture as a local workaround, which should disappear when that is fixed.

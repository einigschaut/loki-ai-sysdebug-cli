# ADR-0013: Hardware scan + offline model tier selection (`loki hwscan`)

Status: Accepted (2026-07-16)

## Context

ADR-0011 put the models on the stick and ADR-0012 the engine. Neither answers the question the operator actually has
when they plug the stick into someone's ailing laptop: **can the offline engine run *here*, and with which model?**

Getting this wrong is not a graceful degradation. Starting a model that does not fit does not fail politely — the host
swaps itself to a standstill, which is the exact opposite of what someone walking up to a broken machine wants. So the
decision is made by us, before anything starts, rather than delegated to the engine's memory mapping.

DESIGN.md §3.2 already specified the rule, and this ADR implements it verbatim rather than inventing one:

```
reserve = max(4 GB, 25% of total RAM)      # the host keeps >= 4 GB AND >= 25%
budget  = available RAM - reserve
choose the largest tier whose resident size <= budget
budget < ~2 GB → no LLM; raw collection only, with a stated reason
```

**AVAILABLE, not total**, is the load-bearing word: on a box that is already thrashing, total RAM is a fiction.

## Decision

**1. `MinRamGB` in the model manifest is renamed to `ResidentGB`, because that is what the values always were.**
This is the finding that shaped the slice. ADR-0011's manifest declared `MinRamGB` per tier — `nano 2.5`, `mid 7`,
`max-ceiling 24` — which reads as *"the host needs this much RAM"*. But DESIGN.md §3.2's table has **two** columns:
"Resident (approx.)" (`~2.5` / `~6.5` / `~23`) and "Min. host RAM" (`4` / `16` / `48`). The manifest's numbers are the
**resident** column; the name pointed at the other one. The two differ by roughly a factor of two, and the selection
formula budgets against *resident* — so anyone implementing against the name rather than the values would have picked
systematically wrong tiers, in the dangerous direction. Renaming is cheap now (pre-1.0, nothing outside the repo reads
the manifest) and would not be later.

`Get-LokiModelManifest` now also rejects a `ResidentGB` that is **at or below the weights on disk**: the weights alone
are resident, plus KV cache, so a lower figure cannot be right — and an under-stated one is precisely the direction
that makes a model which does not fit look like it does.

**2. Selection considers only tiers that are actually INSTALLED.** `loki setup` deliberately lets the operator
download a subset (that is the whole point of the picker), so selecting from the catalogue would cheerfully recommend
a model that is not on the stick. `Get-LokiInstalledTiers` checks presence at the pinned size. Deliberately **not** the
hash: verifying a 19 GB file costs a minute on a machine we are trying to help quickly, and the authoritative
integrity check belongs at load time, in the harness (ADR-0012), not in a report.

**3. Unknown RAM is a refusal, not a default.** If the CIM probe cannot read memory, Loki does not pick a model.
Guessing here means swapping the machine you came to fix. `--model <tier> --force` remains available for the operator
who knows better.

**4. The judgement is pure and table-tested; only the probe touches the machine.** `Get-LokiTierBudget` and
`Select-LokiTier` are pure functions with no I/O, tested as a truth table straight off the rule above (CLAUDE.md §6
names tier selection as property/table-tested). `Get-LokiHardwareProfile` is the single impure function: every probe is
individually guarded and a failure yields a `$null` field, never a guessed number — the same discipline as
`lib/posture.ps1`. Reasons are stable machine tokens (`nothing-fits`, `override-too-large`, `ram-unknown`, …), never
localized — same convention as `lib/allowlist.ps1`.

**5. `--force` is per-tier, not a global off-switch — and `--force` alone is a usage error.** It only means anything
together with `--model`. Accepting it silently would let someone type `loki hwscan --force` expecting the budget to be
lifted and receive a normal, budget-respecting answer with no hint their flag did nothing, so it is rejected instead.
When it does apply it is always reported, and on a host whose RAM could not be read the warning says the risk *cannot
be judged* rather than printing a number we do not have.

**6. The 2 GB floor is a distinct answer, not "nothing fits".** Below it, no tier can ever help, so advising the
operator to fetch a smaller one would be advice that cannot work. `hwscan` names the raw-collection path instead, as
DESIGN.md §3.2's "with a stated reason" requires. (An explicit `--model … --force` still overrides — that is the
operator overruling us knowingly.)

**7. `loki hwscan` is a read-only report.** It shows CPU, total/available RAM, the budget *and the reserve* (so the
number is explainable rather than magic), which tiers are on the stick, and which one would run — exiting
`OfflineEngineMissing` (5) with a stated reason when none can. The test proves "writes nothing" by **measuring** the
tree before and after, rather than mocking a writer and calling that proof.

**8. "Budget" and "free" are not the same number, and the messages must not conflate them.** On a 64 GB host with
60 GB free the budget is 44 GB; a message saying "only 44 GB is free" two lines under "RAM: 60 GB available" is simply
false. Every refusal talks about the *budget*.

## Consequences

* The harness slice consumes `Select-LokiTier` instead of re-deriving a rule — one truth per concept (CLAUDE.md §2).
  `offline --model` / `--force` map onto the same parameters.
* `ResidentGB` figures are approximations (they follow DESIGN.md §3.2's own table). They err **high**, which is the
  safe direction: over-stating resident picks a smaller model, under-stating it thrashes the host. The authoritative
  answer is the engine actually starting, which is why DESIGN.md §3.2 also calls for timing the first response and
  suggesting a downgrade when a tier is persistently slow — not built here.
* The 2 GB floor means some machines get "no LLM, raw collection only". That is a real answer, not a failure, and
  `loki collect` (not built yet) is the path DESIGN.md §3.2 names for it.
* `hwscan` reports RAM at one instant. A box can fall below the budget between the scan and the run; the harness must
  re-check rather than trusting a stale report.

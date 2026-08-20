# ADR-0033: The live-engine tests stay opt-in and run as a pre-release ritual, not in CI

Status: Accepted (2026-08-18)

## Context

Loki's suite mocks the offline engine everywhere but two files. `tests/offline.live.Tests.ps1` and
`tests/offline-agent.live.Tests.ps1` start a real `llama-server`, load real weights, and drive the real loop — the
"the real engine starts at least once for real" requirement (CLAUDE.md section 6, ADR-0015 section 6). They are
opt-in and skip unless `LOKI_LIVE_OFFLINE` / `LOKI_LIVE_AGENT` and `LOKI_LIVE_STICK` are set.

Being opt-in has a measured cost. **Three defects reached `main` that the mocked suite did not catch, and the live
path found all three**: an empty model turn reported as an engine failure and the time-budget boundary reported the
same way (both #82), and a stale stick manifest rejected by the new validation (#87).

Two of the three survived unit testing for one reason, and it is the reason that decides this ADR: **a mock
reproduced a shape the real transport cannot emit.** `tests/offline-agent.Tests.ps1` mocked
`@{ Ok = $true; Reason = 'ok' }` with neither tool calls nor content — a value `lib/offline.ps1` never returns. The
graceful path was reachable only through a reality that does not exist. Writing more mocks cannot find that class;
only the real transport can.

v0.16.0 made the gap concrete again: #104 changed the agent's closing turn (ADR-0031) — a change to the loop itself
— and shipped having met only mocks.

## Decision

**The live tests stay opt-in and are run as a documented ritual before a Release PR is merged. They do not run in
CI.** The ritual lives in `CONTRIBUTING.md`, next to the release process it attaches to.

### Why not in CI

Measured on a provisioned rig (2026-08-18, v0.16.0, Windows PowerShell 5.1):

| Test | Tier used | Duration |
|---|---|---|
| `offline --analyze` | `small` — Qwen3-4B, 2.3 GB | 21.5 s |
| KV geometry vs GGUF headers | every installed tier | 59.4 s |
| `offline --agent` | `mid` — Qwen3-8B, 4.7 GB | **324.6 s** (5 min 25 s) |

The whole ritual takes **6 min 48 s** of wall clock, and the agent test dominates it. Treat these as a scale, not
a benchmark: the agent test's length depends on how long the model reasons, and a second run measured 251.9 s
for the same test. What is stable is the ranking -- the agent run costs several times the other two together.

A CI runner would have to fetch and cache 2.3 GB for the cheap half and 4.7 GB for the agent half, on every cache
miss, for a suite whose normal run is ~4 minutes of pure PowerShell. The agent path — the half where all three
defects lived — is also the expensive half, so the cheap compromise (small tier only in CI) buys the least valuable
coverage: it would exercise `--analyze` and the GGUF cross-check while leaving the agent loop untested. That is the
shape of a gate that reports green for the thing it does not check.

### Why a ritual is enough here — and where it is weak

Be honest about the weakness: a ritual depends on a person, and the first time there is deadline pressure it is the
thing that gets skipped. Two properties make it acceptable anyway:

- It attaches to an act that **already requires a human**. Nothing releases automatically (ADR-0005); the maintainer
  merges the Release PR deliberately. The ritual adds a step to a decision that is already being made, rather than
  inventing a new occasion to remember.
- The rig already exists. The maintainer keeps a provisioned stick, so the ritual costs minutes, not provisioning.

If the project ever gains a second maintainer, or releases become frequent enough that the ritual is skipped in
practice, this ADR should be revisited — the small-tier-in-CI option stays on the table as a partial backstop, with
its coverage limits stated rather than assumed away.

### The stale-stick trap

The first execution of this ritual failed before reaching the engine, with:

```
RuntimeException: Model manifest entry is missing key 'KVCache'.
  at Get-LokiModelManifest, src/lib/models.ps1:63
```

The rig's stick was built from Loki 0.9.0 — its model manifest predates the KV-geometry requirement (ADR-0025). The
validator was right to reject it, but the message reads like a defect in the code under test rather than a stale
deployment, and it costs a diagnosis before the first real assertion runs.

The ritual therefore **begins** by rebuilding the stick from the commit under test with `build\New-LokiStick.ps1`,
which writes `src\` and `version.txt` and never touches `models\*.gguf`, `engine-offline\`, `home\` or `reports\`.

Since #113 the ritual no longer depends on the operator recognising a validator error: both live files check the
stick before they touch the engine and **fail** with the mismatch and the exact rebuild command. Fail rather than
skip, because this suite is run deliberately as a release gate — an unusable rig is an error, not an absence, and
this ADR already warns that a skip is easy to scroll past. The check has two halves and both earn their place: a
version comparison catches the stale deployment in ~200 ms, and a parse of the stick's manifest with the current
validator catches a stick built from an older *commit of the same version* — which the version comparison cannot
see, because `version.txt` only moves at a release.

## Consequences

- A Release PR merged without the ritual is a release whose engine path was verified only against mocks. That is
  now a stated, visible gap rather than an unexamined default.
- **A skip is not a pass.** `offline --agent` skips when the stick carries no agent-capable tier (the agent floor is
  `mid`, DESIGN.md section 3 / ADR-0021). A small-only rig produces a green run that exercised none of the agent
  path. The ritual says so explicitly, because a silent skip reads exactly like success.
- The live tests remain excluded from `build/Invoke-Checks.ps1` and from CI, so the default gate stays fast and
  needs no models.
- The ritual is documentation, not enforcement. Nothing in CI verifies it happened.

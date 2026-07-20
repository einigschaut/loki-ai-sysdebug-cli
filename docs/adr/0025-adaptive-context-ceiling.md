# ADR-0025: The offline context window has an adaptive, RAM-derived ceiling — calculated, not measured

Status: accepted · Date: 2026-07-20 · Builds on ADR-0015 (the context policy belongs to the command slice) and
ADR-0017 (the two RAM guards, whose `UsableNowGB` this reuses). Does not change the guards or the tier pick.

## Context

`offline --analyze`/`--agent` size the llama-server context window (`-c`) to the *workload*: the dump (or the peak
agent conversation) plus the system prompt and the answer, above a 2048 floor. That request was then capped by a
**fixed** ceiling of 16384 tokens (`LokiOfflineCtxCeiling`), independent of the machine and the model.

That constant was a **stand-in for a RAM limit we could not yet compute**. llama.cpp allocates the KV cache for the
*whole* `-c` up front, so a model advertising a 262 144-token window (the `small` tier's real figure) would, asked for
its full window to summarise a 3 KB dump, reserve tens of GB of KV cache and swap the host — the opposite of helping
it. offline.ps1 said so out loud and left the fix deferred: *"a RAM-aware reduction … would need the model's KV
geometry (n_layer / n_kv_head / head_dim), which is not in the manifest; deferred deliberately rather than guessed."*

The maintainer's question was the right one: shouldn't a bigger, more capable model be allowed a bigger window? The
answer is yes — but the thing that actually bounds the window is **not model capability, it is KV-cache RAM**, and the
fixed 16384 was wrong in both directions: it *truncated* a large dump on a roomy machine that could have held far
more, and it *over-committed* on a just-fits machine where 16384 tokens of KV would push into the swap the guards had
just protected. The maintainer's steer was explicit: make the ceiling **adaptive**, but **calculated, not
live-measured** — a single laptop is one data point, and a figure tuned on it would not transfer to other machines;
a closed-form calculation from known quantities does.

## Decision

**1. The ceiling is the largest window whose F16 KV cache fits the RAM left for it, capped by the model's real max.**

```
kv_bytes_per_token = 2 (K and V) * Layers * KVHeads * HeadDim * 2 (F16 = 2 bytes/element)
kv_budget_bytes    = 0.9 * max(0, UsableNowGB - ResidentGB) * 1GB
ram_ceiling        = floor(kv_budget_bytes / kv_bytes_per_token)  snapped DOWN to a multiple of 256, floored at 2048
window             = clamp(workload_need, 2048, min(model_max_context, ram_ceiling))
```

Everything on the right is a **known quantity**, never a measurement of a running model:

* **KV geometry** (`Layers`/`KVHeads`/`HeadDim`) is a property of the model, identical on every machine. It is pinned
  per tier in `models/manifest.psd1`, sourced — like `Sha256` — from an authoritative place rather than guessed: each
  base model's `config.json` (`num_hidden_layers` / `num_key_value_heads` / `head_dim`, and where `head_dim` is absent,
  `hidden_size / num_attention_heads`, exactly as llama.cpp derives it), and cross-verified against the `small` tier's
  actual GGUF header (`block_count=36`, `head_count_kv=8`, `key_length=128` — matches).
* **The RAM budget** reuses the very `Get-LokiModelRamLimit.UsableNowGB` the tier-fit guards already trust
  (`available − 1.5 GB` OS headroom), minus the model's own `ResidentGB` footprint. Reading how much RAM a machine has
  is a system fact, not an inference benchmark — this is the same reading ADR-0017 makes; it is not the trial-run
  tuning the maintainer ruled out.

**2. Deliberately conservative in the safe direction.** `ResidentGB` already *over-counts* a memory-mapped Q4 model
(the `small` tier is 2.33 GB on disk but budgeted at 4.5 GB), so subtracting it whole under-states the free KV space
rather than risking an over-fill. The extra `0.9` holds back 10% for the compute/graph buffers the KV formula does not
model — a **stated margin, not a tuned one**. The RAM ceiling is floored at 2048 (never *below* the existing floor),
because the engine preflight has already proved the model itself fits, so the floor's small KV always does too.

**3. The fixed proxy survives as the unknown-machine fallback.** When the RAM probe returns `$null` (an unreadable
host) or a manifest entry carries no KV geometry, the window falls back to the old 16384 constant — i.e. exactly the
previous, machine-blind behaviour. A probe that cannot read the machine degrades safely instead of guessing. The pure
`Get-LokiOfflineContextSize` gains two **optional** parameters (`-KvBudgetBytes`, `-KvBytesPerToken`) with sentinel
defaults (`-1` / `0`) that select this fallback, so every existing caller and test is unchanged.

**4. Wrong-low geometry is fail-closed at manifest load.** A too-*small* `KVCache` field is the dangerous direction —
it makes the window look cheaper than it is and lets a big dump over-fill KV-cache RAM. So `Get-LokiModelManifest`
now requires `KVCache` and rejects a non-hashtable or any non-positive `Layers`/`KVHeads`/`HeadDim`, alongside the
existing hash/URL/size checks. Presence-and-shape is enforced by the loader; `tests/offline.live.Tests.ps1` closes the
loop by re-reading any *installed* GGUF's header and failing if it disagrees with the pinned geometry.

## Consequences

* **Not a security core.** This is offline-engine *resource* policy (`offline.ps1`, `offline-agent.ps1`, the manifest),
  none of them in the §5 security-core set (`env-isolate`, `footprint`, `allowlist`, `auth`, `agent` = `lib/agent.ps1`).
  A wrong window can truncate or, absent the guard, OOM — it cannot bypass the allow-list or leak a secret. The
  `offline-agent.ps1` edit is the two-line window-sizing wiring only; it touches no allow-list, confirm-flow or
  dump-as-data boundary.
* **Manifest schema change.** `KVCache` is now a required, validated field. There is one manifest and all seven tiers
  carry it, so making it mandatory is safe; the runtime still degrades gracefully for a hypothetical geometry-less
  entry (a test-built model), which is the belt to the loader's suspenders.
* **The window can now exceed 16384 — by design.** On a roomy box a large dump may be read at tens of thousands of
  tokens (up to the model max), which the fixed cap forbade. This is the maintainer's original ask, now bounded by
  real RAM rather than a blanket constant.
* **`0.9` and the F16 assumption are the judgement knobs.** F16 is llama-server's *default* KV cache; if Loki ever
  passes `--cache-type-k/v` (quantized KV), `LokiOfflineKvBytesPerElem` must change with it. Both live as named
  constants in one place, for exactly the "revisit if real use disagrees" reason ADR-0017's 60%/1.5 GB do.
* **Calculated, not measured — honoured.** No number here comes from running a model and timing or watching it. The
  geometry is read from the model's own declaration; the RAM from the OS. The design transfers to a machine Loki has
  never seen, which a laptop-tuned constant could not.
* **A second, cheap RAM probe.** Each offline entry point now calls `Get-LokiHardwareProfile` once for sizing, in
  addition to the one the preflight makes at start. The probe is two CIM reads and never throws; the minor redundancy
  buys a clean split (the sizing decision is the caller's per ADR-0015; the start decision is the harness's).

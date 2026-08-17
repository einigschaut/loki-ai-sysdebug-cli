# ADR-0031: The offline agent's closing turn is constrained to `final_answer`

Status: Accepted (2026-08-17)

## Context

`offline --agent` (ADR-0021) is marked experimental (ADR-0029) because it does not reliably *finish*.
The loop asks the model to conclude -- the system prompt says "when the evidence is enough, call
final_answer" -- and the model may simply not do it. Raising the per-turn generation cap to 2048
(ADR-0029) fixed *truncation*; it did not fix *non-termination*.

The 2026-08-17 tier evaluation measured this across 12 candidate models on the real agent contract
(real system prompt, toolset, allow-list gate, tool-call parser; `max_tokens=2048`; CPU-only):

- **`DeepSeek-R1-0528-Qwen3-8B` ran every turn it had, emitted four valid native tool calls, and never
  called `final_answer`.** It ended on `iteration-cap` with an empty answer -- the run produced facts
  and no diagnosis. That is the same shape as the original #84 finding on Qwen3-8B, reproduced on a
  second, unrelated model family, so it is not a per-model quirk.
- **Only 1 of 12 models both diagnosed correctly and terminated by itself.**
- Several others spent their last turn on a fact-gathering call rather than a conclusion.

The evidence is that termination cannot rest on model goodwill.

## Decision

**On the last turn the iteration cap allows, the model is offered only the `final_answer` tool.**

`Get-LokiOfflineAgentTurnToolset -Tools -Iteration -MaxIterations` (pure) returns the move set for the
turn: the full set before the closing turn, `final_answer` alone on it. `Invoke-LokiOfflineAgentTurnLoop`
passes that per-turn set to `Invoke-LokiEngineChat` instead of the fixed toolset.

Because llama-server compiles each offered tool's schema to a GBNF grammar and constrains generation to
it (ADR-0021), removing `run_command` from the list makes another fact-gathering call **ungeneratable**,
not merely discouraged.

> A prompt shifts probabilities; a grammar removes the alternative. A prompted model concludes *usually*;
> a constrained one *cannot do otherwise*. For a fail-closed tool, "always" is the right category.

The closing turn also carries one Loki-authored user message stating that this is the final step, that
the answer must rest on the evidence already gathered, that `insufficient-data` remains a valid answer,
and that a finding must not be invented. Without it the vanished tool reads as a malfunction, and a
confused model writes a worse diagnosis than an informed one. It is Loki's own text, never scanned data,
so it adds no injection surface.

### Scope boundary

This narrows **what the model may propose**. It does not touch the allow-list gate, does not widen what
may execute, and adds no execution path -- a forced `final_answer` runs nothing at all. The iteration and
time caps are unchanged and still terminate the loop.

### Chosen shape

- A **pure** policy function, so the rule is table-testable in isolation (CLAUDE.md section 6) and the
  tool schema stays defined in exactly one place (`Get-LokiOfflineAgentToolset`, no duplicate).
- `Get-LokiOfflineAgentToolset` keeps its signature -- **no contract break**, no caller changes.
- **k = 0**: only the final turn is constrained. The model keeps every earlier turn to gather freely;
  the intervention is the smallest one that removes the failure.

## Consequences

- A run that previously ended `iteration-cap` + "insufficient-data: reached the step limit" now ends
  `final` with a diagnosis drawn from the evidence actually collected.
- **Forcing an ending must never force a finding.** `final_answer`'s own schema keeps `insufficient-data`
  as an explicit option, and both the pure-function tests and a loop test pin that a constrained close
  can still answer `insufficient-data`. A future edit that removes that option from the tool description
  fails a test rather than silently turning the loop into a diagnosis generator.
- **Fail-safe on rename:** if the toolset ever carries no `final_answer` entry, the filter falls back to
  the full set rather than sending an empty tool list the engine cannot answer with. A toolless turn
  would be a worse failure than a late `run_command`.
- A one-turn budget (`MaxIterations = 1`) now means "answer immediately" rather than "gather once, then
  hit the cap with nothing". That is the better reading of a one-turn budget.
- This does not make `--agent` field-ready on its own; it removes one named failure mode. The models that
  never emit native tool calls at all (measured: Granite 3.3 2b/8b, SmolLM3-3B, phi-4, Phi-4-reasoning-plus)
  are unaffected -- a grammar cannot help a model that does not use the protocol.
- Unit tests can prove Loki *offers* only `final_answer`; that llama-server then *enforces* it is
  ADR-0021 mechanics and covered by the live gate, not by mocks.

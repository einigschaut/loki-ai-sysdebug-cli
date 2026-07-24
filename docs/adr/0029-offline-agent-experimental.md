# ADR-0029: `offline --agent` is experimental; per-turn `max_tokens` raised to 2048

Status: Accepted (2026-07-23)

## Context

`offline --agent` (ADR-0021) runs a multi-turn read-only diagnostic loop on the local engine. Issue
#84 asked whether it is viable as built. It was measured, twice, against the real engine (Qwen3-8B,
the `mid` tier) on hardware the maintainer notes is *above* the field standard.

Two findings, in order:

1. **The per-turn cap `max_tokens = 512` systematically truncated the thinking model.** Qwen3-8B is a
   hybrid-thinking model and, with `--jinja`, its `<think>` block is on. Measured: a turn spends
   1000-2500 characters *thinking* before it emits a tool call. At 512 tokens, generation stopped
   mid-thought (`finish_reason=length`) with no tool call and no content -- a dead turn the loop then
   counted as a strike. Two such turns end the loop. This was invisible until #90 surfaced
   `finish_reason`; it is why #84 first misdiagnosed the loop as "the model is too slow".

2. **Raising the cap fixes the truncation but not the viability.** At `max_tokens = 2048` the same
   turns complete and emit their command (measured: 0 truncated turns vs 2 at 512, over a 6-turn run).
   But neither `max_tokens` value produced a diagnosis: the 512 run died from the truncation, and the
   2048 run made genuine progress (four diagnostic commands) yet never called `final_answer` before
   running out of wall-clock. Both runs cost 9-12 minutes for no answer, on above-standard hardware.
   For comparison, `offline --analyze` gives a real verdict in one turn, ~24 s.

## Decision

**Keep `--agent`, but treat it as EXPERIMENTAL, and raise the per-turn cap to 2048.**

- **`max_tokens` per turn = 2048**, as the named constant `$script:LokiOfflineAgentTurnMaxTokens`
  (was a hard-coded 512 in the turn loop). This is a genuine bug fix: 512 turned working turns into
  dead strikes. It is **necessary but not sufficient** -- it does not make `--agent` field-viable.
- **The context window's `AnswerTokens` is coupled to that constant.** A turn can generate up to the
  cap (thinking + tool call), and the window must hold that alongside the peak history, or the
  truncation simply reappears at the window edge instead of the token cap. The thinking block is
  generated but discarded from the history (only `content` + `tool_calls` are kept), so the larger
  cap costs generation *time* per turn, not a permanently larger window.
- **`--agent` announces itself as experimental** before it runs (`offline.agentExperimental`): it
  needs fast hardware, runs for minutes, may not conclude, and `--analyze` is the fast reliable
  offline verdict. A notice, not a gate -- the operator asked for it.
- **`offline --analyze` is the field tool** for offline diagnosis. That is now stated, not implied.

## Consequences

- `--agent` no longer *silently* fails on the truncation: a turn's thinking completes, so the loop
  gets real moves. It can still run out of time without a diagnosis -- and now says so up front.
- The honest framing is the deliverable here as much as the constant: a technician is steered to
  `--analyze`, and only reaches for `--agent` knowing what it costs.
- **Not viable-as-built is recorded, not hidden.** Making `--agent` actually field-viable (a prompt
  that forces a conclusion by turn N, fewer richer turns, a hardware-derived budget, or simply
  better/faster models over time) is future work, not part of this change. The measurement in #84 is
  the baseline any such rework is judged against.
- `lib/offline-agent.ps1` is a declared security core (CLAUDE.md §5); this change was made under
  Opus review with the guard mutation-tested, and touches only the generation cap and its coupled
  window sizing -- no change to the allow-list gate, the confirmation flow, or the "data is data"
  framing.

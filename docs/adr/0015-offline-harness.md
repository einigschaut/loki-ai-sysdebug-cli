# ADR-0015: The offline engine harness — starting llama-server on a machine we do not trust

Status: accepted · Date: 2026-07-16 · Supersedes nothing · Builds on ADR-0012 (engine on the stick),
ADR-0013 (tier selection), ADR-0014 (load-time integrity)

## Context

ADR-0012 puts the pinned llama.cpp build on the stick. ADR-0014 proves the bytes on the stick are the pinned bytes.
Neither of them *runs* anything, and ADR-0014 said so explicitly rather than implying otherwise: the harness must call
`Test-LokiEngineIntegrity` + `Test-LokiModelIntegrity` **before** `llama-server` and treat any non-`verified` result —
including a model that is merely `not-installed` — as fatal. This ADR is where that obligation is paid.

The situation this code runs in is unusual enough to be worth stating plainly: Loki is plugged into a machine
**because something is wrong with it**. The environment, the running processes, and the free RAM are all facts about a
machine nobody has vetted. That is not paranoia — it is the entire premise of the tool.

Every claim below was **measured against the pinned b10038 binary and the real Qwen3-1.7B model on 2026-07-16**, not
recalled. Two of the measurements contradicted what we believed going in, which is the reason the measuring happened.

## Decision

**1. Two layers against the target's environment, because each covers the other's gap.**

Measured: llama-server documents **132 `LLAMA_ARG_*` environment variables**, one per flag. It also reads four
**undocumented `AIP_*` variables** — `AIP_HTTP_PORT`, `AIP_HEALTH_ROUTE`, `AIP_MODE`, `AIP_PREDICT_ROUTE` — which
appear as strings in `llama-server-impl.dll` and in **no `--help` output whatsoever**. And `lib/env-isolate.ps1` hands
a child a **copy of the full parent environment** with Loki's redirects overlaid (ADR-0003's "redirect instead of
clean up"), so all 136 of them reach the engine from the target machine.

Also measured, and this is the part that corrected us: **an explicit flag beats its environment twin, always.**
`LLAMA_ARG_HOST=0.0.0.0` could not move a server started with `--host 127.0.0.1`; `LLAMA_ARG_ENDPOINT_SLOTS=1` could
not re-open `/slots` against `--no-slots`. The variables are **defaults for flags you do not pass**, not overrides.
The prior belief — that `AIP_*` silently overrides the port — was **half right in the worst way**: the variables are
real, they are undocumented, and they do nothing when the flag is explicit.

So:

* **Layer 1 — pass every security-relevant flag explicitly** (`Get-LokiLlamaServerArgs`, pure and table-tested). This
  is the layer that survives a strip list going stale when a future engine build adds a variable nobody here has heard
  of.
* **Layer 2 — strip the engine's whole environment namespace** (`Get-LokiEngineChildEnv`, prefix-based: `LLAMA_ARG_`,
  `AIP_`, plus `LLAMA_API_KEY`/`HF_TOKEN` which carry no prefix). This is the layer that covers the flags with **no
  negated form**: `--metrics` and `--props` can be switched **on** by an environment variable and there is no
  `--no-metrics` to answer back. Prefixes rather than 132 names, because a name list rots on the next engine bump.

Neither layer alone is enough, and saying "we pass the flags" would have been a comfortable half-answer.

**2. The flags, and why each is there.**

| flag | reason |
|---|---|
| `--host 127.0.0.1` | A diagnostic LLM holds the contents of someone's event log. It must not be reachable from the target's network. |
| `--no-webui` | Default **enabled** (verified in `--help`). A CLI has no use for a browser UI, and it is attack surface. |
| `--no-slots` | Default **enabled**. `/slots` serves the prompt **contents** of every slot — i.e. exactly the data we just read off the machine — to anything that can reach the port. |
| `--jinja` | Default enabled *today*; passed anyway. Not passing it is what lets `LLAMA_ARG_JINJA=0` turn the chat template off, and a Qwen3 without its template does not answer, it rambles. |
| `--ctx-size` | **Mandatory, never defaulted.** The default is `0` = "take it from the model", which hands the RAM decision to a file: the `small` tier declares **262144** tokens of context. |
| `--threads` | Explicit; the default `-1` (auto) is what `LLAMA_ARG_THREADS` moves. |

`Get-LokiLlamaServerArgs` **throws** on `CtxSize <= 0` and `Threads <= 0` rather than accepting a value that means
"let something else decide". The context *policy* (how much fits on this machine) belongs to the command slice; this
function only refuses to leave the question open.

**3. `/health` exists — confirmed by starting the thing, because the binary could not be asked.**

Scanning the binary for the `/health` literal finds nothing (C++ inlines short string literals; `/v1/chat/completions`
at 20 chars does appear). That was never evidence the route was absent, and it was not treated as such. A real start
settled it: **503 while the model loads, then `200 {"status":"ok"}`** — 2.2 s for nano.

`Wait-LokiEngineReady` watches the **process** as well as the port, because the failure that matters most is the
engine dying during load. Without that, a model too large for the machine turns a 4-second crash into a full timeout
of silence followed by the wrong diagnosis.

**4. Identity by image path. No PID marker, anywhere.**

The obvious design — write the PID and port to a marker file, read it back to find an orphan — was rejected. Windows
**recycles PIDs**, so a marker is a number that may name an innocent process by the time anyone reads it, and a tool
whose job is to be safe on someone else's machine must never kill on that basis. A process whose **image path** is
this stick's `llama-server.exe` is self-identifying and needs no bookkeeping to corroborate. It also removes a file
that would otherwise have to live somewhere the ADR-0014 reconcile does not prune.

`Get-LokiEngineOrphan` **reports and never kills**: an orphan means an earlier Loki was killed hard, which is the
operator's situation to understand. Terminating processes we did not start is not a decision a library makes silently.

**5. `Body` is a parameter, so the stop cannot be forgotten.**

`Invoke-LokiWithEngine` runs the caller's work *inside* its own `try/finally`. A leaked llama-server is not an untidy
detail — it is a multi-GB process holding a model open **on someone else's computer** after the tool that started it
has exited. The only way that guarantee survives a `Body` that throws is if no caller is ever trusted to remember it.
Proven live: a throwing body, zero orphans afterwards.

**6. `ReadToEndAsync`, not an output-event handler.**

Both pipes must be drained or the child blocks once a buffer fills, and llama-server is chatty while a model loads —
"the engine hangs at 60%" would be our own unread pipe. The idiomatic-looking choice, `BeginOutputReadLine` plus a
ScriptBlock handler, would have .NET invoke PowerShell on a threadpool thread with no runspace to run it: unreliable
under 5.1 in exactly the way that produces an intermittent hang nobody can reproduce. `ReadToEndAsync` is pure .NET
with no callback into PowerShell, so there is nothing to schedule.

The drained pipes are not thrown away: `Get-LokiProcessOutputTail` turns them into the answer for a start that failed.
`engine-not-ready:exited` on its own is a dead end for whoever has to act on it; llama-server says *why* on stderr.

## Consequences

* **The command that uses this does not exist yet, and this ADR must not be read as if it did.** `lib/agent.ps1` is
  reachable only from its tests. The offline command (`loki offline` / `ask --offline`) is the next slice, and it owns
  the two policies deliberately left out here: how much **context** fits on this machine, and what the agent loop
  actually asks the model. Stated plainly for the same reason ADR-0014 stated its own gap: an obligation that is only
  implied is an obligation that rots.
* **`Get-LokiProcessOutputTail` buffers the engine's whole output in memory** for the life of the session. Bounded and
  fine for a diagnostic run of minutes; it would not be fine for a server running for days, and this harness is not
  for that.
* **The free-port probe is a hint, not a reservation.** `Get-LokiFreeLoopbackPort` asks the OS for port 0 and reads
  back what it was given; the gap between releasing it and llama-server binding it is an unavoidable race. Named
  accordingly, retried, and a bind failure surfaces as `engine-not-ready:exited` with the engine's own message
  attached rather than as a mystery.
* **`GET /props` cannot be turned off, and it discloses the stick's path.** Measured: `--props` gates only *POST*
  `/props` (default disabled); the GET route always serves `model_path`, the chat template and `build_info`. Loopback
  binding means the audience is local processes only — which on the machine we are there to diagnose is not nobody.
  The path is also visible in the process command line, so this discloses nothing new; recorded because "we turned the
  endpoints off" would otherwise read as complete, and it is not.
* **A live-gate finding that is NOT this slice's to fix, and is a real question for the maintainer:** on the dev
  machine (31.46 GB total, 6.4 GB available) the **real preflight refused to start the smallest tier**.
  DESIGN.md §3.2's rule is `reserve = max(4 GB, 25% of total)`, so the reserve was 7.87 GB against 6.4 GB available →
  budget 0 → not even the 2.5 GB nano fits. The rule is working exactly as written and the probe is measuring the
  right thing (verified: `Win32_OperatingSystem.FreePhysicalMemory` tracks `Memory\Available MBytes` to within 0.02 GB
  — the standby cache is already counted, so the obvious "it's measuring free instead of available" bug is **not** the
  explanation). The question is whether the reserve should scale with **installed** RAM at all: a healthy, busy
  Windows box routinely sits at ~20 % available, so as written Loki declines the offline engine on most machines it
  would be carried to. Changing that is a DESIGN.md/ADR-0013 decision, not a harness patch, so the harness was
  live-gated with the probe stubbed **in the live script only** — the engine, the model, and every Start/Wait/Stop
  path in it were real.
* The harness re-measures RAM instead of trusting the tier choice made at setup time. That choice was made on the
  **setup** machine; the entire point of the stick is that it gets carried to a different one.

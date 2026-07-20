# Loki — Design Document

Loki is a portable diagnostic CLI for Windows that runs entirely from an encrypted USB
stick. It orchestrates two independent reasoning engines — **Claude Code** (online,
agentic) and a local **llama.cpp**-based engine (offline, CPU-only) — behind one
professional command-line interface, in the spirit of tools like `git` or `docker`: its
own commands, help system, logging, exit codes, and configuration. It is not a bare
wrapper around an AI CLI.

The target scenario: plug the stick into a Windows machine — a colleague's laptop, a
customer's desktop, a machine with no network access at all — and get AI-assisted
diagnosis of network and Windows problems, faster than manual troubleshooting, while
leaving the host machine's own user profile exactly as it was found.

---

## 1. Scope: what Loki guarantees, and what it doesn't

An early design goal was "zero traces on the host." That claim doesn't survive contact
with reality: on a Windows machine without administrator rights, absolute
trace-freedom is not achievable, and *attempting* to erase OS-level artifacts is a
**stronger** forensic signal than leaving them alone. So the promise is scoped
precisely instead — this is more honest, and it is the promise Loki can actually keep.

**What Loki guarantees, when used correctly:**

- No secrets are ever persisted in plaintext on the host. A secret lives only in the
  environment block of the child process (Claude Code / the offline engine), never on
  a command line, never in a log file.
- No Loki or Claude Code configuration, transcripts, memory, or caches land in the
  **host user profile**. Every app-level write is redirected to the encrypted stick.
  This is a testable claim — it is proven with a Process Monitor before/after diff,
  not just asserted (see the footprint gate, §7.4).

**What Loki explicitly does *not* attempt** (deliberately left alone — deleting these
would be a louder signal than leaving them, and touching most of them needs admin
rights anyway):

- USB/volume traces: `USBSTOR`, `MountedDevices`, `MountPoints2`, `setupapi.dev.log`,
  the `Partition/Diagnostic` event log.
- Execution traces: Prefetch, Amcache, ShimCache, BAM, UserAssist.
- PowerShell engine events (4100/4600 range), which are generated simply by running
  PowerShell at all — and, where enforced by policy, Script Block Logging (4104),
  Module Logging (4103), and process auditing (4688).
- EDR/Sysmon telemetry, device-control USB logs, DNS/proxy/firewall logs.
- Volatile remnants in `pagefile.sys`, `hiberfil.sys`, or crash dumps.
- Decryption of the auth header by corporate TLS-inspection proxies (e.g. Sophos,
  Zscaler) sitting between the stick and the network — this shapes the auth model
  (§7.2), it isn't something a USB stick can prevent.

**Operating rule:** an unlocked stick exposes its plaintext secret to whatever host it
is plugged into. Never unlock it on a machine you suspect is compromised, and treat any
host that has seen the unlocked stick as potentially secret-exposed. If the stick is
lost, revoke the API key first, then rotate.

### Target-machine posture

On a hardened, centrally managed endpoint, Loki is blocked before a single line runs —
AppLocker/WDAC default-deny outside `Program Files`, Constrained Language Mode, an
`AllSigned` execution-policy GPO, "removable disks: deny execute," or device control.
None of these are bypassable without admin rights, and Loki does not try. Its primary
environment is *unmanaged* machines, or machines administered by the same operator
running Loki (where AppLocker/AV exceptions are possible).

Rather than fail halfway, `loki status` / `loki doctor` run a host-posture preflight:
effective execution policy, session language mode (CLM), a probe for AppLocker, the
PowerShell logging policies mentioned above, process auditing, and any device-control
restrictions — then fail fast with a plain-text reason instead of limping along.
Scripts and binaries are Authenticode-signed, which helps against `AllSigned` and
SmartScreen (though it does not clear a WDAC allow-list).

---

## 2. Architecture

```
<StickRoot>
├── loki.cmd            entry point (cmd.exe, no PSReadLine persistence):
│                        powershell -NoProfile -ExecutionPolicy Bypass -File loki.ps1
├── loki.ps1             dispatcher: args, preflight, integrity check, routing,
│                        exit code, try/finally teardown — no business logic
├── lib\                 shared building blocks: env-isolate, auth, footprint,
│                        host-posture, hwscan, allowlist (one gate for both engines),
│                        agent (offline-loop harness), integrity, log, ui, config,
│                        registry, i18n
├── commands\            one command = one file (metadata + handler)
├── bin\claude.exe        Claude Code engine (native binary)
├── home\                 USERPROFILE of the child process (.claude\, .env, …)
├── engine-offline\       the pinned llama.cpp build ONLY — owned by the archive (see below)
├── engine-staging\       scratch space for `loki setup` on its way into engine-offline\ (see below)
├── models\               the pinned GGUF tiers (own lifecycle, own hashes)
├── playbooks\, grammars\ assets for the offline engine
├── tools\                bundled read-only diagnostic tools (on PATH)
├── power-module\         opt-in, off-by-default, NOT on PATH (active/dual-use tools)
├── temp\, reports\, logs\, loki.config.json, manifest.sig
```

The layout above is the **deployed artifact**, produced from the repository by a build
script — it is not assembled by hand.

**`engine-offline\` belongs to the pinned engine archive and nothing else may live there.**
`loki setup` does not merely unpack into it, it **reconciles** it: anything the pinned archive
does not produce is removed (ADR-0012), because otherwise a planted `ggml-cpu-*.dll` would
survive the very setup run meant to repair a suspect stick, and a version bump would leave the
binaries it exists to remove sitting in `llama-server.exe`'s DLL search path. That is why the
model tiers, playbooks and grammars are **siblings**, not children: they are pinned and verified
separately, on their own lifecycle, and putting them under `engine-offline\` would mean the next
`loki setup` deletes them — verified, not assumed: laid out that way, a re-run reports
`Pruned: 2` and the models are gone. The only exceptions the reconcile spares are the verified
archive itself (the chain back to the pin) and the operator-staged Microsoft runtime, which is
passed in explicitly.

**`engine-staging\` exists so that rule can stay absolute.** Everything setup writes on its way
into `engine-offline\` is unverified while it is being written — the `.part` of a download, the
`.staging` copy of a runtime DLL, the `.bak` of the file it displaces. Written *inside*
`engine-offline\`, those temporaries are indistinguishable from a planted file: the reconcile
called them out, so a `loki setup` killed mid-download (Ctrl-C on 200 MB over a slow link) made
the next `loki doctor --engine` report the stick as tampered with. Reproduced, then fixed by
moving them out — **not** by teaching the reconcile to ignore `*.part`/`*.staging`/`*.bak`, which
would have handed an attacker a naming convention: `evil.dll.bak` sits in `llama-server.exe`'s DLL
search path exactly like `evil.dll` does. A sibling, not a child, for the same reason the models
are (a child would be pruned), and on the same volume so committing a staged file stays a rename
rather than a copy. It is scratch space: nothing in it is trusted, and nothing is left in it.

### Contracts-first, one truth per concept

Modules talk to each other only through documented `lib/` function signatures.
Changing a `lib/` signature is a contract break: it requires updating every caller and,
for anything security-relevant, an ADR. Shared logic (environment isolation,
allow-listing, auth, footprint handling, config, UI, logging, the registry) lives
**exclusively** in `lib/` — there is deliberately no second implementation of the same
concept scattered across commands.

### The command registry is the single source of truth

Each file in `commands/` declares two functions: `Get-LokiCmdMeta_<name>` returns a
metadata hashtable (name, one-line summary, usage, group, examples, flags), and
`Invoke-LokiCmd_<name>` is the handler, returning an exit code from the shared exit-code
definition. A shared "one hashtable variable per command" pattern was considered and
rejected: the dispatcher dot-sources every command file into the same scope, so a
shared variable name would collide and only the last file would survive (see
`docs/adr/0002-command-metadata-as-functions.md`).

The registry enumerates every `Get-LokiCmdMeta_*` function, validates the required
fields, and confirms a matching handler exists — a command with metadata but no
handler (or vice versa) fails this consistency gate. `loki help`, `loki <cmd> --help`,
and the README's command table are all **generated** from this one
source, not hand-maintained (`loki completion` is a planned Stage-3 item, §7), so a new command appears everywhere automatically. New
commands are created only through a scaffolding generator that emits the metadata,
handler, and test stub in the standard shape — no hand-rolled deviation between
sessions or contributors.

### Built by AI agents: engineering discipline as a structural property

Loki's code is written entirely by AI coding agents. The architecture above exists
specifically to make the common failure modes of AI-written code — drift between
docs and code, dead code, duplicated logic, hallucinated APIs, silent scope creep —
expensive to introduce and cheap to catch, rather than relying on an agent to "reason
its way" out of them. This is enforced mechanically in CI, not through convention
alone:

- **Anti-drift:** a documentation gate checks that every command has help text and a
  README/registry entry.
- **Single-gate security:** both engines route every command through the one allow-list
  (`Resolve-LokiCommandDecision`) — verified for the online and offline paths in the test suite.
- **Anti-dead-code:** static analysis plus a scan for exported-but-never-called
  functions and unregistered command files.
- **Anti-hallucination:** external facts about Claude Code or llama.cpp flags are
  checked against real documentation, never assumed; tests are treated as executable
  specification and must be green before anything is "done."
- **Registry consistency:** `commands/` on disk, the generated registry, and generated
  docs must agree, or the build fails.

Security-critical modules (isolation, allow-list, auth, agent guardrails) additionally
require a dedicated review pass before merge, and changes are kept small and
single-purpose (one command or feature per change) to keep failures local and visible.

---

## 3. The two engines

### 3.1 Claude Code (online)

The primary engine, and the reason Loki exists: Claude Code running as a standalone
native binary (no separate Node.js runtime required), invoked headlessly
(`-p`, `--output-format json`, `--max-turns`, `--max-budget-usd`) for one-shot commands
and interactively for the `chat` flow. It is fully isolated into the child environment
described in §6, and every action it takes is filtered through the same allow-list gate
described in §7.1.

### 3.2 Offline engine (llama.cpp / llama-server)

Anthropic's terms don't permit routing Claude Code traffic to a non-Claude model, so
offline capability is deliberately a **separate engine**, used only when there is no
network — never a fallback model behind the same interface.

**Two hard, verified design constraints:**

1. **CPU-only.** A GPU code path would need to compile CUDA/ROCm kernels at runtime
   with a toolchain no ordinary office PC has installed — it would fail offline
   anyway. CPU inference with an auto-dispatching SIMD backend needs no extra
   download, works air-gapped, and is a single binary across x86-64 hardware. CPU-only
   is simultaneously the most offline-reliable, the cleanest on footprint, and the most
   portable choice.
2. **One engine binary, several external model files** — not one bundled file per
   model. Windows' 4 GB PE-image limit forces model weights above roughly 8B parameters
   to live outside the binary regardless, so external `.gguf` files are the only
   option once multiple tiers are in play.

**One unified server + harness path.** Because a tool-calling agent loop needs an
OpenAI-compatible server, `llama-server` (CPU-only, loopback-only, `--jinja` templates)
is the *only* offline code path — there is no separate one-shot implementation.
`offline --analyze` is a single turn with no tools (pure summarization over a
diagnostic dump); `offline --agent` is a multi-turn tool-calling loop against the same
running server. Lifecycle is managed by the harness: start → loop → clean kill via
`try`/`finally`, with a crash-recovery pass on the next launch that kills only
Loki's own orphaned server instance (identified by port/PID marker), never a
`llama-server` the user started themselves.

**Hardware-adaptive model tiers.** A hardware scan measures total and *available*
RAM (the number that matters on an already-struggling machine) and decides what may
run here, never trusting the engine's own memory-mapping to fail gracefully if a
model is too large for the host. **Two independent guards** (ADR-0017), because they
answer two different questions:

```
thrash guard    resident + 1.5 GB <= available RAM     don't take what isn't there
ballast guard   resident <= 60% of TOTAL RAM           don't dominate the machine you came to help
```

The 1.5 GB headroom is **absolute, not a percentage**: what an OS needs in order not
to page does not grow with the size of the memory bank. The ballast cap *is*
proportional, because "am I too big a burden on this machine" genuinely is. Their
**order matters**: ballast is decided first, since failing it is permanent (no amount
of closing programs helps) while failing the thrash guard is a "close something and
retry". Reporting the wrong one sends the operator after memory that could never be
enough.

*Available* already includes the standby cache — the "modern OS frees memory on
demand" effect is counted, not ignored. What is deliberately **not** counted is
Windows paging out somebody else's working set to make room: that *is* the ballast,
so the operator is told what is holding memory instead of having their browser
silently made slow.

| Tier | Resident (approx.) | Min. host RAM¹ | Offline capability |
|---|---|---|---|
| 1.7B | ~2.5 GB | 4.2 GB | analysis + playbook routing |
| 4B | ~4 GB | 6.7 GB | analysis + routing |
| 8B | ~6.5 GB | 10.8 GB | + free agent loop (usable floor) |
| 14B | ~10.5 GB | 17.5 GB | + agent loop (tolerable planning) |
| 32B | ~23 GB | 38.3 GB | deep mode (patient, high quality) |

¹ *Derived*, not declared: `resident / 0.6`, straight out of the ballast guard. It is
the RAM below which a tier can never run here, however idle the box is.

**The default is the recommended tier, not the largest that fits.** RAM is not the
only capacity: the 32B tier runs at ~1–2 tok/s on CPU, so "biggest that fits" would
hand a 128 GB server a model that technically runs and practically doesn't. The
model catalog's `Default` flag already encodes a balance of quality against speed,
and a memory figure does not get to overrule it. Anything larger is *offered* by the
report — never auto-selected.

Every "no" is actionable rather than final: each tier is reported as **fits /
needs N GB more free / too big for this machine**, and when freeing memory would
change the answer, the biggest memory holders are named. A manual override
(`--model <tier>`, `--force` to run it anyway with a warning) is always available;
the first response is timed and a persistently slow tier triggers a suggestion to
downgrade. If no catalog tier can run at all, that is a stated answer pointing at
`loki collect` (raw dump) — checked against the catalog, never assumed.

**Two maturity levels in the same harness**, reflecting what small CPU models can
actually do reliably:

- **Playbook router (default, available from ~1.7B):** the model classifies the
  symptom and selects from a fixed menu of deterministic, pre-reviewed playbooks
  (the same collector batteries and guided-fix scripts the online engine uses),
  filling in a few typed parameters. The *scripts* act; the *model* only routes and
  explains. This keeps small models inside what single-call classification can
  reliably do, and closes off the injection surface of model-authored commands
  entirely.
- **Free diagnose-and-act loop (`--agent`, from ~8B):** genuine multi-turn tool
  calling, with tool arguments constrained by a grammar so malformed JSON — the
  dominant failure mode of small models — is structurally impossible rather than
  merely likely to be caught. Below the 8B floor, `--agent` automatically falls back
  to router mode with a notice rather than running a loop known to be unreliable.
  Even at its best, the offline agent is honestly positioned as a supervised junior
  assistant: weaker planning, more confirmations, and answers measured in minutes
  rather than seconds compared to the online engine.

The guardrails that make the agent loop safe are the same ones described in §7 for
Claude Code — read-only by default, an allow-list of narrow native functions rather
than "run a shell command," mandatory confirmation for any mutation, hard iteration
and time caps, and scanned data (event logs, filenames, dump contents) always treated
as data, never as instructions. Indirect prompt injection through logs or filenames is
a real threat model here, not a theoretical one, and is tested against directly.

---

## 4. Isolation model (zero app-level footprint)

Loki's footprint strategy is **redirection, not cleanup**: rather than writing to the
host profile and tidying up afterward, every write is aimed at the stick from the
start. The full environment set below is placed in the environment block of the
**child process only** (Claude Code / the offline engine) — the interactive parent
PowerShell session is not mutated in the normal path:

```
USERPROFILE, HOME             → <StickRoot>\home
CLAUDE_CONFIG_DIR             → <StickRoot>\home\.claude
APPDATA, LOCALAPPDATA         → <StickRoot>\home\appdata   (own vars — not derived
                                                             from USERPROFILE)
TEMP, TMP, TMPDIR             → <StickRoot>\temp
PATH                          = <Stick>\tools\...; + System32 dirs + $env:PATH  (bundled read-only
                                                             tools first, then the REAL System32
                                                             pinned ahead of the inherited PATH so a
                                                             native read can't hit a planted .exe --
                                                             ADR-0016 addendum, #50)
CLAUDE_CODE_SKIP_PROMPT_HISTORY=1, DISABLE_TELEMETRY=1, DO_NOT_TRACK=1,
DISABLE_UPDATES=1, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1,
CLAUDE_CODE_DISABLE_AUTO_MEMORY=1, CLAUDE_CODE_CERT_STORE=system
```

This is documented as **ADR-0003 — isolation model: child env block, restore only for
process-surviving mutations** (`docs/adr/0003-isolation-model-child-env-block.md`).
The reasoning, informed by prior art in portable-app launchers: environment variables
set directly in a child process's environment block die with that process — there is
nothing to leak and nothing to restore. A paired push/pop restore is built only for
the small set of mutations that *do* outlive the process (the wrapper's own module
analysis cache path, a couple of registry EULA keys) — what is never changed cannot
leak, and a smaller restore surface is a smaller place for the security-critical code
to have a bug. A crash-recovery pass on next launch covers the case where a hard kill
skipped the `try`/`finally` teardown entirely.

A few things need calling out explicitly because they're easy to get wrong: `APPDATA`
and `LOCALAPPDATA` are independent environment variables, not derived from
`USERPROFILE`, and must be redirected separately or they leak into the host profile.
Windows' Known-Folder APIs (`SHGetKnownFolderPath`) ignore environment variables
entirely and are an accepted residual risk, checked by the footprint gate rather than
solved architecturally. Secrets never appear on a command line (anything typed into a
parent PowerShell session can be captured by PSReadLine or process-creation auditing)
— they are read from an encrypted file into a variable and handed to the child only
through its environment block.

---

## 5. Security gates

### 5.1 Allow-list, not deny-list

The gate that decides what either engine (Claude Code or the offline agent) is allowed
to do is the **same allow-list engine** for both. Read-only diagnostics
(`ipconfig`, `Get-*` cmdlets, `Test-NetConnection`, `nslookup`, `netstat`, `route
print`, `arp`, and equivalents) are auto-allowed; anything state-changing requires
explicit confirmation; a further deny-list exists only as defense in depth. That
ordering matters: name-based deny rules are trivially bypassable (`&`,
`Invoke-Expression`, aliases, `cmd.exe`), so the actual security boundary is
**allow-only-for-read plus ask-by-default**, not the deny list.

### 5.2 Auth model

Exactly **one** authentication variable is ever set for the child process — either an
API key or an OAuth token, never both. The default is a scoped, spend-capped,
immediately revocable API key rather than the longer-lived OAuth token, specifically
because a corporate TLS-inspection proxy on the network path can see the auth header:
a smaller blast radius matters more than convenience there. If the stick is lost, the
runbook is revoke first, then rotate — never the other way around.

### 5.3 Exit-code contract

Exit codes are a stable interface, defined once centrally and referenced everywhere
else — never a bare integer scattered through the codebase:

```
0  ok                              5  offline engine/model unavailable
1  general error                   6  footprint guard triggered
2  incorrect usage                 7  volume locked or not found
3  auth missing/invalid            8  user declined a proposed fix
4  network required but offline    130 interrupted
```

### 5.4 Footprint gate

`loki doctor --footprint` is the mechanism that turns the guarantee in §1 into a
falsifiable claim rather than an assertion: a before/after snapshot of the host
profile, cross-checked with Process Monitor, across a full session (`chat`, `scan`,
`offline --analyze`, `offline --agent`). The expectation is zero app-level writes
outside the stick — checked against the same session against a machine that already
has an unrelated `~/.claude` profile, which must come out **unchanged**. When the
guard detects an artifact it isn't certain is its own, the rule is to report rather
than delete (exit code 6) — ambiguity is never resolved by removing something that
might not be Loki's.

---

## 6. Localization

Loki's own source, comments, tests, and documentation are English — that's the
repository's base language. Separately, and by explicit design, the CLI's
**user-facing runtime output** is localizable: strings live in per-locale catalogs
(`src/i18n/<locale>.psd1`, English as the base and guaranteed fallback), resolved at
runtime through a lookup helper that falls back to English for a missing key and
returns the key itself if it's entirely unknown — so a lookup can never crash on an
untranslated string. Locale resolution follows the same precedence pattern used
elsewhere in the CLI: an explicit flag, then an environment variable, then config, then
the OS UI culture, then English. A CI parity gate fails the build if any shipped
locale is missing a key present in the English catalog. See
`docs/adr/0004-language-and-localization.md` for the full rationale, including why
this split (English repo / localizable runtime output) was necessary rather than
optional once the project moved toward a public release.

---

## 7. Roadmap

The build proceeds in stages, foundation before features — deliberately, because an
AI-agent-built codebase benefits far more from having its guardrails in place *before*
the first feature lands than from retrofitting them later.

- **Stage 0 — Foundation.** Repository layout, CI with every gate active from day one
  (tests, lint, documentation, anti-drift, dead-code), the command
  scaffolding generator, and the contract conventions in `lib/`. Every feature after
  this point goes through the scaffold — none are added by hand.
- **Stage 1 — MVP.** The dispatcher and help system, the online engine (`chat`, `ask`,
  `scan`), auth/status/doctor including the host-posture preflight, the full isolation
  environment, and the footprint gate. This is the 90%-of-value milestone: the machine
  can be diagnosed online with a proven-clean footprint.
- **Stage 2 — Offline, complete.** The raw collector (works everywhere, no AI
  required) first, then the unified `llama-server` + harness path supporting both
  `--analyze` and `--agent`, hardware scan and tier selection, the category-A
  read-only toolbox, the guided `fix` flow with dry-run and rollback, and report
  management.
- **Stage 3 — Hardening.** The integrity manifest and code signing, an optional
  two-partition volume layout, the opt-in category-B power toolbox, shell completion,
  log rotation, and — optionally — a compiled single-binary distribution.

---

## 8. Further reading

- `docs/adr/0001-core-decisions.md` — the foundational architecture and trade-off
  decisions (standalone CLI, PowerShell 5.1 target, honest security scope, API-key
  default, offline as a separate CPU-only engine, unified agent harness, repo-first
  deployment, AI-build discipline).
- `docs/adr/0002-command-metadata-as-functions.md` — why commands declare a metadata
  function and a handler function instead of a shared variable.
- `docs/adr/0003-isolation-model-child-env-block.md` — the isolation model detailed
  in §4.
- `docs/adr/0004-language-and-localization.md` — the localization model detailed in
  §6.

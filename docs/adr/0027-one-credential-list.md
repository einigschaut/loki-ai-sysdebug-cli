# ADR-0027: One credential list — every child env block and the allow-list gate read the same names

Status: accepted · Date: 2026-07-21 · Builds on ADR-0003 (child env isolation: redirect, don't clean up),
ADR-0007 (the secret-target deny) and ADR-0016 (routing vars). Changes no CLI interface and no exit code.

## Context

Loki spawns five kinds of child process, and every one of them gets its environment from
`New-LokiChildEnvBlock`, which hands the child a **copy of the full parent environment** with Loki's redirects
overlaid (ADR-0003, "redirect instead of clean up"). That is right for `PATH` and `SystemRoot`. It is wrong for
credentials: the parent is the *operator's own shell*, and Loki runs on a machine it does not control and is only
visiting because something is wrong with it.

So each spawn site stripped credentials before handing the block over — and each one did it from **its own list**:

| Site | Spawns | List | Names |
|---|---|---|---|
| `lib/claude.ps1` (normal + setup-token) | `claude` | `$LokiClaudeAuthVars` | 7 |
| `lib/offline-agent.ps1` | a gated read child | `$LokiOfflineChildScrubVars` | 4 |
| `lib/footprint.ps1` | the probe child | inline literal | 3 |
| `lib/allowlist.ps1` | *(the gate, not a spawn)* | `$LokiSecretTargetPatterns` | 3 |
| `lib/agent.ps1` | **llama-server.exe** | — | **0** |

Four lists is not an aesthetic complaint. On 2026-07-16 the four **cloud-provider** credentials were added, because
Claude Code's documented precedence puts provider auth *first*: an inherited `AWS_BEARER_TOKEN_BEDROCK` does not
merely sit in the block, it **wins** over the key Loki injected, and the session silently runs on the target
machine's account. That fix landed in exactly one of the four copies. Four lists is the mechanism by which a fix
goes missing.

### What was measured, before anything was changed

Every claim below was reproduced on the real code with a synthetic parent env holding all eight names:

* **llama-server received all eight**, including Loki's own `LOKI_SECRET`. `Get-LokiEngineChildEnv` stripped
  `LLAMA_*` only — while its own doc-comment claimed *"the same reasoning, and the same shape, as lib/claude.ps1
  stripping inherited auth vars from Claude Code's block."* The code described a guard it did not have.
* the gated **read child kept 4**, the **footprint probe kept 5**, **setup-token kept `LOKI_SECRET`**.
* the **gate auto-allowed** `Select-String -Path C:\dump.txt -Pattern AWS_BEARER_TOKEN_BEDROCK` as
  `read-allowlisted` — 5 of the 8 names were not deny patterns at all.
* the gate's three credential-name patterns were **never-failing guards**: deleting all three left
  `tests/allowlist.Tests.ps1` at *137 passed / 0 failed*, because every test that looked like it exercised them was
  actually satisfied by the structural `Env:` / `.env` patterns. That is why three-of-eight could sit in a security
  core for months without anyone noticing.
* those patterns were also **culture-folded**. `-match` folds case by the *current culture*; under `tr-TR`,
  `ToLower` of a capital I is the dotless U+0131, so a pattern built from a name carrying that letter does not match
  its own lowercase form. Measured in a fresh 5.1 process: `-match` **False**, ordinal `IndexOf` **True**. This is
  the same trap `lib/allowlist.ps1` already documents — and fixed — for its `Get-*` pattern.

### How bad was the llama-server gap, honestly

Not exploitable through the engine: llama-server reads none of these variables, and it is a local process bound to
loopback. What it was, is **inconsistent with Loki's own accepted threat model**. The offline read child already
carries the rule in writing (S6: *"a read child must never carry a credential, even one an operator's shell left in
the ambient environment"*), llama-server is the largest third-party binary Loki executes, and its block is what any
process *it* spawns inherits. The argument had simply never been applied there.

## Decision

**1. One list, in `lib/auth.ps1`.** That file already owns *which env var carries the credential*
(`Get-LokiAuthVarName`); owning *every name that carries one* is the same responsibility. It is also reachable from
everywhere: `lib/*.ps1` is dot-sourced alphabetically and every reference is inside a **function body**, so it
resolves at call time and no load order can break it — `allowlist.ps1` calls into `auth.ps1` even though it loads
first.

The list is the seven names Claude Code can authenticate on (verified against
`code.claude.com/docs/en/authentication.md` + `env-vars.md`) plus `LOKI_SECRET`. Three functions:

```
Get-LokiCredentialVarNames                                  -> [string[]]  (a COPY; a caller cannot edit the SSoT)
Remove-LokiCredentialEnv -ChildEnv <IDictionary> [-Keep]    -> [string[]]  removed; in place; ordinal-ignorecase
Test-LokiCredentialTarget -Text <string>                    -> [bool]      ordinal substring, for the gate
```

**2. Every child gets zero credentials, except the one that needs exactly one.** llama-server, the footprint probe,
the gated read child and `claude setup-token` call `Remove-LokiCredentialEnv` with no `-Keep`. The online engine
passes `-Keep @($authEnv.Keys)` — and `$authEnv` holds exactly one key by construction, so "exactly ONE auth
variable" (CLAUDE.md §5) now rests on one list instead of four.

**3. Comparison is ORDINAL, everywhere.** For env var *names* there is nothing regex-shaped to gain and a culture
bug to lose. `Remove-LokiCredentialEnv` compares keys with `OrdinalIgnoreCase` (so it is correct for a
case-*sensitive* `IDictionary`, not only for a PowerShell hashtable, which folds case for you); the gate matches
names with `IndexOf(..., OrdinalIgnoreCase)`. The structural patterns (`Env:`, `.env`, `GetEnvironmentVariable`,
drive-qualified `home\`) stay regexes — they *are* patterns.

**4. The gate blocks the names as well as the mechanisms.** `Env:` / `.env` / `GetEnvironmentVariable` already cover
reading the *live* environment or the secret file. The name check covers naming a credential in **any other target**:
a grep of a collected dump, a config, a shell history — a realistic read on a machine under diagnosis.

## Consequences

* **A behaviour change in five places, all in the same direction: fewer credentials in child processes.** Nothing
  Loki spawns loses a variable it uses. `tests/footprint.Tests.ps1` and the live engine tests exercise the real
  spawns.
* **The gate denies slightly more.** A read that merely *mentions* a credential name is now `denied` rather than
  `read-allowlisted`. Deliberate and consistent with the deny's existing breadth (ADR-0007 already accepts blocking
  an unrelated `*.env` read): for a read-only diagnosis, losing a dump grep is cheap and losing a key is not.
* **`lib/allowlist.ps1` now depends on `lib/auth.ps1`.** The five test files that load a consumer without loading
  `auth.ps1` were updated, including `tests/culture.Tests.ps1`, which builds its own child-process loader.
* **A second copy cannot come back quietly.** `tests/auth.Tests.ps1` fails if any `src` file other than
  `lib/auth.ps1` contains a credential name as a **quoted string literal** (prose in comments is still fine). It
  caught a violation the first time it ran — in a comment this ADR's own author had just written.
* **The tests are driven from the list**, so adding a name to `lib/auth.ps1` extends the assertions in
  `agent`/`claude`/`footprint`/`offline-agent`/`allowlist` on the same day, with nobody having to remember them.
* **The culture proof lives in `tests/culture.Tests.ps1`, not next to the code it tests** — and that placement is
  load-bearing. .NET caches a compiled `Regex` keyed on (pattern, options) with the **culture not in the key**, so an
  in-process culture switch reuses a regex compiled under the invariant culture and the test passes whatever the
  implementation does. An in-process version of that test was written first and a mutation run proved it could not
  fail; `culture.Tests.ps1` runs each case in a fresh PowerShell 5.1 process, and kills the same mutant.

## Verification

Full 5.1 gate green: **1317 passed, 0 failed, 3 skipped** (the skips are the opt-in live-engine tests).

Every new guard was **mutation-proved able to go red** — 11 mutants, 11 killed:

| Mutation | Red |
|---|---|
| llama-server: drop the credential scrub | 1 |
| footprint probe: drop the credential scrub | 1 |
| read child: drop the credential scrub | 1 |
| online engine: drop the credential scrub | 3 |
| SSoT: drop one name from the list | 7 |
| gate: drop the credential-name check | 12 |
| matcher: culture-sensitive regex instead of ordinal | 3 |
| scrub: ignore `-Keep` (strip the credential the engine needs) | 9 |
| scrub: case-sensitive key comparison | 2 |
| SSoT: return the live array instead of a copy | 4 |
| anti-drift: a second copy of a name reappears in another src file | 1 |

Two of those mutants **survived the first round** and are the reason this ADR's verification section exists at all:
the footprint strip sat inside a function that spawns a process (so nothing could assert on it — it was split into
the pure `Get-LokiFootprintProbeChildEnv`), and the culture guard was the in-process test described above. A guard
nothing can fail is not a guard (CLAUDE.md §6).

## Alternatives considered

* **A new `lib/secrets.ps1`.** Rejected: `auth.ps1` already owns credential identity, is already a named security
  core in CLAUDE.md §5 (so it already carries the mandatory-review requirement and a test file), and a new file
  would have had to be added to that enumeration to get the same treatment.
* **Leave `allowlist.ps1` with its own copy** on the grounds that "what a child may not inherit" and "what a model
  may not read" are different concepts. Rejected: the *verbs* differ, the *set* does not — both ask "is this a
  credential?" — and keeping them apart is precisely what let one list learn about cloud-provider auth while the
  other did not.
* **Fix the regexes with `CultureInvariant` instead of going ordinal.** Would work, and is what the `Get-*` pattern
  had to do because it *is* a pattern. For a literal variable name it buys nothing over an ordinal comparison and
  keeps a regex engine in a path that has no use for one.

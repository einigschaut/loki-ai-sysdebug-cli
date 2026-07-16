# ADR-0016: The target machine does not get to choose where Loki's credential goes

Status: accepted · Date: 2026-07-16 · Builds on ADR-0003 (isolation model), ADR-0007 (online engine),
ADR-0009 (single-door auth) · Numbered 0016 because 0015 is claimed by an open PR; there is no 0015 gap once both land

## Context

Loki decrypts a secret from the stick's `home\.env`, injects it into a child `claude.exe`, and runs that child **on a
machine it does not control and is only plugged into because something is wrong with it**. That is the premise of the
tool, not a hypothetical.

`lib/env-isolate.ps1` hands the child a **copy of the full parent environment** with Loki's redirects overlaid —
ADR-0003's "redirect instead of clean up", deliberately a **patch model, not an allow-list**. `lib/claude.ps1` already
strips inherited *auth* variables so exactly one credential authenticates the session (CLAUDE.md §5).

The gap was the other half of the sentence: **which credential** was controlled, **where it is sent** was not.
`ANTHROPIC_BASE_URL` is not an auth variable, so no list caught it.

## The finding

**Verified against the official documentation** (`code.claude.com/docs/en/env-vars.md`, `authentication.md`,
`llm-gateway-connect.md`, `network-config.md`, `settings.md`) rather than assumed — the whole point of the exercise was
that an invented hole is as bad as a missed one:

* **`ANTHROPIC_BASE_URL` is read by Claude Code**, and `ANTHROPIC_API_KEY` is sent to that host in the `x-api-key`
  header. So a single environment variable on the target machine — **no malware, no privilege, no CA to install** —
  takes the key Loki just decrypted and delivers it to a host of the attacker's choosing.
* **The auth list was incomplete.** Claude Code's documented credential precedence puts **cloud-provider auth first**,
  ahead of `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_API_KEY`. `AWS_BEARER_TOKEN_BEDROCK`, `ANTHROPIC_AWS_API_KEY`,
  `ANTHROPIC_FOUNDRY_API_KEY` and `ANTHROPIC_FOUNDRY_AUTH_TOKEN` were not stripped, and an inherited one does not sit
  harmlessly beside Loki's key — it **wins**, and the session silently runs on the target machine's account.
* **`CLAUDE_CODE_USE_BEDROCK` / `USE_VERTEX` / `USE_FOUNDRY` / `USE_ANTHROPIC_AWS` are routing, not auth**: they select
  a provider at precedence 1, redirecting the entire session. What travels is Loki's prompt — i.e. **the diagnostic
  data just read off the customer's machine**.

## Decision

**1. Strip every variable that decides WHERE the request goes or WHICH credential authenticates it.**
`$script:LokiClaudeRoutingVars` (endpoint overrides, provider selection, gateway auth-bypass, provider targeting,
`ANTHROPIC_CUSTOM_HEADERS`) is removed from the child block by `Remove-LokiClaudeRoutingEnv`, and the four provider
credentials join `$script:LokiClaudeAuthVars`. One definition each; **both** spawn paths use them.

**2. `setup-token` gets the same treatment, and it is not an afterthought.** It opens a browser sign-in and mints a
**long-lived** token. A redirected sign-in is a credential generated straight into someone else's endpoint, while the
operator watches a normal-looking login.

**3. Strip, do not pin.** The obvious alternative — pin `ANTHROPIC_BASE_URL` to the real API in the settings file Loki
already writes for hooks — was rejected because **Claude Code's own docs contradict each other** on whether a
settings-file `env` block overrides a shell export: `llm-gateway-connect.md` says the settings file wins;
`settings.md` documents an empty-string workaround that only makes sense if it does not. A guarantee resting on a
documented ambiguity is not a guarantee. Removing the variable from the block **we build ourselves** depends on
nothing but us, and our own tests can prove it. (Pinning could be added later as defence in depth, once the precedence
is measured rather than read.)

**4. Loki does not support gateway/provider routing at all, and that is the point.** If it ever should, that is a
decision for Loki's config on the stick — never something the machine under investigation asserts.

**5. Proxy and TLS-trust variables are deliberately NOT stripped.** This is the judgement call in the ADR, and it goes
the other way from everything above:

| variable | why it stays |
|---|---|
| `HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY` | **Transport, not endpoint.** The payload stays TLS-protected end-to-end to the pinned host, so a hostile proxy learns a `CONNECT` target and nothing else — unless it also owns a CA the machine trusts, and an attacker who can install a trusted root already owns the machine. Stripping them would break Loki on **every corporate network that requires an explicit proxy**: a certain cost against a conditional benefit. |
| `NODE_EXTRA_CA_CERTS`, `CLAUDE_CODE_CLIENT_CERT*` | **TLS trust**, and the dependency is real — Loki is deployed behind a TLS-inspecting gateway. |
| `CLAUDE_CODE_CERT_STORE` | Needs no strip: `Get-LokiIsolatedEnv` sets it to `'system'` explicitly, and `Isolated` is overlaid **on top of** the inherited block, so an ambient value cannot move it. Asserted by a test so the ordering stays a property rather than an accident. |

Measured on the dev machine while deciding: **no proxy variables set, `ProxyEnable=0`, no PAC** — the corporate TLS
inspection here is transparent at the gateway and needs no `HTTPS_PROXY`. That is one machine and not a proof about
customer networks, which is exactly why the certain-outage risk outweighed the conditional gain.

## Consequences

* **A `HTTPS_PROXY` + `NODE_EXTRA_CA_CERTS` PAIR is an open hole, and this ADR does not close it.** Together they are
  a genuine MITM: the attacker's CA is trusted by Node without touching the machine's root store, and the proxy then
  reads the key. Each half is individually defensible to keep (above); the **combination** is not obviously so. It is
  recorded rather than guessed at because the answer needs a measurement this slice did not run — specifically whether
  `CLAUDE_CODE_CERT_STORE='system'` (which Loki already pins) suppresses `NODE_EXTRA_CA_CERTS` or merely adds to it.
  **Open question for the maintainer**, with a real corporate-network cost attached either way.
* **The patch model is the root cause, and per-variable lists are the symptom fix.** `New-LokiChildEnvBlock` copies the
  whole parent environment; every hole in this class is "a variable nobody listed". An **allow-list** model would close
  the class structurally — and would have caught this one before it was written. It is deliberately **not** in this PR:
  it touches `PATH`, `SystemRoot`, proxy and CA configuration on machines Loki must keep working on, and it deserves
  its own ADR and its own live gate. This list will rot; the ADR says so out loud rather than letting the next reader
  discover it.
* The strip is **name-based, not prefix-based** (unlike `lib/agent.ps1`'s `LLAMA_ARG_*`/`AIP_*` handling, ADR-0015).
  Claude Code's variables share no usable prefix — `ANTHROPIC_*` also covers things we must keep, and
  `CLAUDE_CODE_*` covers the ones Loki sets itself. So a name list is the honest shape here, with the rot risk above.
* Users who genuinely route Claude Code through an LLM gateway on their own machine will find that **Loki ignores that
  setup**. That is intended: Loki's session is Loki's, and "the ambient environment configures my credential's
  destination" is the property being removed.

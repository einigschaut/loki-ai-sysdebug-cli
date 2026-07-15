# ADR-0009: Single-door auth onboarding (`loki auth login`) + subscription browser flow

Status: Accepted (2026-07-15)

## Context

Loki reaches the online engine with **exactly one** auth variable (ADR-0001, CLAUDE.md §5):
`ANTHROPIC_API_KEY` (an API key, the default) or `CLAUDE_CODE_OAUTH_TOKEN` (a Claude subscription
token). The credential is stored on the stick (`home\.env`, base64 at rest) and injected into the
child `claude` process only via the env block — never argv.

The setup UX had drifted into **two parallel doors** for storing that one credential: `auth set`
(paste a secret for whatever method is active) and `auth login` (which set method=sub and pasted a
token). Worse, `auth login` only *told* the operator to run `claude setup-token` themselves and
paste the result — it never launched anything, so "login" opened no browser. A subscription is the
more common credential (more people have a Pro/Max plan than a console API key), yet it was the more
awkward path. This ADR reworks onboarding into one obvious door and makes the subscription flow
actually start the sign-in.

Verified against the installed Claude Code CLI (v2.1.147): `claude setup-token` generates a
**long-lived** subscription token (opens a browser; requires a subscription) and prints it;
`claude auth login [--claudeai|--console]` performs an interactive OAuth sign-in that stores
credentials in claude's **own** store.

## Decision

**`loki auth login` is THE single onboarding door (in the shape of `gh auth login`): it picks the
method, then lands exactly one credential on the stick.** The lower-level verbs stay, but demoted.

- **Method choice.** `loki auth login` with no argument shows a rudimentary chooser (`[1]` Claude
  subscription / `[2]` API key). `loki auth login sub|api` (also `--sub`/`--api`, and the
  `claude`-style synonyms `claudeai`/`console`) skips the chooser for scripted/expert use. An
  explicit but unrecognized method is a `Usage` error.
- **Subscription path launches the real browser flow, in-process.** For `sub`, Loki spawns
  `claude setup-token` **attached to the console** (`Invoke-LokiClaudeSetupToken` in
  `src/lib/claude.ps1`): the operator completes the browser sign-in and sees the token `claude`
  prints, then pastes it back through the **same hidden `Read-Host -AsSecureString` path** as the API
  key. Loki **launches** the flow but **never captures or parses** the token — it only ever handles it
  as a `SecureString` (secret never in argv/logs, CLAUDE.md §5). If `setup-token` is missing
  (`claude-not-found`) or exits non-zero (aborted / no token generated), Loki reports it and changes
  **nothing** — it does not prompt for a paste.
- **API path.** For `api`, a hidden `Read-Host -AsSecureString` for a console API key. No browser.
- **Env-var injection stays; `claude`'s own credential store is deliberately NOT used.** The
  subscription onboarding could instead run `claude auth login` and let `claude` manage its OAuth
  credentials. Rejected: `claude`'s normal store can land the refresh token in the OS keychain
  (Windows Credential Manager / DPAPI) — a **host footprint** that is not redirectable onto the stick
  and would break Loki's core zero-app-level-footprint guarantee. A long-lived
  `CLAUDE_CODE_OAUTH_TOKEN` stored on the stick and injected as an env var is self-contained,
  provably footprint-free, and keeps the existing (already reviewed) auth architecture.
- **The setup-token spawn runs under the full ADR-0003 isolation, with NO auth variable.**
  `Get-LokiSetupTokenChildEnv` builds the isolated child env (redirected `USERPROFILE`/`HOME`/
  `CLAUDE_CONFIG_DIR` onto the stick, neutralized host siblings) and **strips both** auth vars — this
  is the only `claude` spawn with no credential, because it is *generating* one, and no personal
  token from the operator's shell may cross in. So even the one-time subscription setup keeps its
  artifacts on the stick. No PreToolUse hook / `--settings` / charter: `setup-token` runs no agent
  tools, so there is nothing to gate.
- **Order guarantee (no half-state).** The method is written to config and the secret stored only
  **after** a non-empty paste; an empty paste is a `Usage` error that leaves config and secret
  untouched. A failed browser flow returns before any prompt or write.
- **`use` / `set` / `clear` remain as scriptable advanced primitives** (unchanged behaviour), but the
  primary help and the "no credential" hints (`ask`/`scan`/`chat`) now point at the one door:
  *"Run `loki auth login`"*. `auth status` is unchanged.

## Consequences

- `tests/auth-command.Tests.ps1` covers the new door with the browser flow **mocked**
  (`Invoke-LokiClaudeSetupToken`): `login sub` launches the flow + stores the token + sets
  method=sub; `login api` stores the key + sets method=api + does **not** launch the flow; a non-zero
  `setup-token` exit and `claude-not-found` both → `GeneralError` with **no half-state** and **no
  paste prompt**; empty paste (sub and api) → `Usage`, no half-state; an unknown method → `Usage`; the
  interactive chooser (choose `1` → sub); a break-the-guard proving the pasted token never reaches
  stdout/stderr. `tests/claude.Tests.ps1` unit-tests `Get-LokiSetupTokenChildEnv`: the ADR-0003
  isolation is applied and a **break-the-leak** proves both auth vars are stripped even when the parent
  env carried them; plus the `claude-not-found` short-circuit (no spawn).
- **Pending live end-to-end gate — a RELEASE BLOCKER for the `sub` path (NOT satisfied by unit tests).**
  That `claude setup-token` completes its browser OAuth **under Loki's env isolation** (redirected
  `USERPROFILE`/`CLAUDE_CONFIG_DIR`, neutralized `HOME` siblings) can only be confirmed on a real
  machine with a real Claude subscription. Two footprint residuals cannot be governed by env vars and
  must be checked live before this path ships:
  1. **Host credential store.** `setup-token` generates a credential; if it (or a native module)
     persists anything via a Win32 known-folder API, Windows Credential Manager, or DPAPI, that ignores
     the redirected env and lands on the **host** — which would break the zero-app-level-footprint
     guarantee. If live testing confirms such a write, this path must be reworked (or gated to a
     trusted prep machine only) before release; the review rates this MED, HIGH if confirmed.
  2. **OAuth browser session.** Sign-in opens the operator's **default host browser**, whose cookies
     and history live in the host browser profile — outside Loki's isolation entirely. This is an
     expected, non-app-level trace (the same class as Prefetch/USBSTOR that the honest-scope section of
     the README already disclaims), documented here so it is not mistaken for an app-level leak.
  Fallback if isolation interferes with the sign-in, or a host write is confirmed: run the subscription
  onboarding only on a **trusted prep machine** (setup happens there anyway — the stick is prepared
  once), where `setup-token` printing a token is acceptable. Until confirmed, the subscription
  onboarding is wiring-complete + unit-tested, but the isolated browser sign-in is unverified. This
  mirrors the ADR-0007 / ADR-0008 live gates.
- **Security core review (done).** Auth is a security core (CLAUDE.md §5) → this change went through the
  mandatory 3-vote perspective-diverse adversarial review (secret-leak / bypass-isolation-footprint /
  correctness-contract lenses) before merge, like the allow-list and enforcement work. Outcome: **no
  secret leak and no exploitable bypass** (the setup-token arg list is a fixed literal, the ADR-0003
  isolation is fully applied and the auth-var strip is unit-proven, failure branches leave no
  half-state). The substantive item was the footprint live-gate above. One hardening was applied from
  the review: `ANTHROPIC_AUTH_TOKEN` (a third bearer credential Claude Code honors) is now stripped
  from the child env alongside `ANTHROPIC_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN` — via a single
  `$script:LokiClaudeAuthVars` list used by **both** the normal spawn (`Get-LokiClaudeInvocation`,
  strips the ones Loki did not set) and the setup-token spawn (`Get-LokiSetupTokenChildEnv`, strips all
  of them), closing a pre-existing gap in the "exactly one auth variable" guarantee. Break-the-leak
  regression tests cover all three names.
- **Product direction (recorded, not built here).** The goal is a very simple CLI in the shape of
  `claude` — bare `loki` should eventually drop into an interactive session, with a richer UI in a
  later version; the MVP UI (including this chooser) is deliberately rudimentary.
- **Not changed:** the credential model (exactly one auth var, API key default, base64 at rest,
  env-only injection), the enforcement gate, and the `use`/`set`/`clear`/`status` semantics.

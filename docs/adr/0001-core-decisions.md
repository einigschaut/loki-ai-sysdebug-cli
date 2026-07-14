# ADR-0001 — Core Decisions (Architecture & Trade-offs)

- **Status:** Accepted
- **Date:** 2026-07-13
- **Context:** Fundamental, deliberate decisions from the planning process. Detail ADRs (0002+) refine individual points.

## 1. Standalone CLI, not a Claude wrapper
`loki` is a professional CLI (own commands/help/exit codes) that orchestrates Claude Code **and** an offline
engine — not just a launcher. Operated like `git`/`docker`.

## 2. Windows PowerShell 5.1 as the target runtime
Target machines only guarantee 5.1. A compiled single-exe (Go/Rust) is later polish. **Consequence:** 5.1
dialect discipline (CLAUDE.md §1).

## 3. Honest security scope instead of "zero traces"
Absolute traceless operation is impossible without admin rights; deleting OS artifacts is more conspicuous than
leaving them in place. **Guarantee:** no app-level traces in the host profile (proven via ProcMon).
**Consequence:** the footprint guard only checks what's controllable; OS forensics (Prefetch/Amcache/USBSTOR/event
logs) is documented as out of scope.

## 4. Auth: API key as default (not OAuth token)
Corporate TLS-inspection proxies (e.g. Sophos, Zscaler) decrypt the auth header. A scoped, spend-capped,
instantly revocable API key has a smaller blast radius than a one-year OAuth token. **Consequence:** API key is
the default, OAuth is optional; corporate CA + `CLAUDE_CODE_CERT_STORE=system`.

## 5. Offline = own engine (llamafile/llama-server), CPU-only
Claude Code must not be routed to non-Claude models → separate engine. CPU-only is mandatory (the GPU path
compiles at runtime and fails offline) **and** is at the same time the cleanest-footprint, most portable choice.

## 6. The offline agent is core, one unified server+harness path
Instead of a one-shot approach with a later rebuild: one `llama-server`+harness path; `--analyze` (0 tools) and
`--agent` (tool loop) are two modes of the same code → less duplication. Shared allowlist engine for Claude and
the agent.

## 7. Repo-first, the stick is a reproducible artifact
Developing directly on the stick undermines tests/git/reproducibility. The repo (private GitHub) is the source
of truth; large binaries/models are pulled via a fetch manifest (SHA256); the stick is produced by
`Build-LokiStick.ps1`; `loki init` provisions the secret.

## 8. 100% AI-built → structural error prevention
Contracts-first, a generated command registry, mandatory scaffolding, machine-enforced CI gates against
drift/dead code (CLAUDE.md §2/§3/§7). Errors stay local and become visible in CI.

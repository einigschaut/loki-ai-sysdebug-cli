<!-- Loki PR -- Definition of Done (CLAUDE.md section 8 / CONTRIBUTING.md). Small, focused PRs: one command/feature per PR. -->

## What & Why
<!-- Briefly: which feature/command, which problem. Reference to plan/ADR/issue. -->

## Definition of Done
- [ ] **Code** follows the contracts (`lib/` signatures unchanged, or an ADR plus all callers updated)
- [ ] **Tests green** -- `build\Invoke-Checks.ps1` passes locally (Analyzer + structure gate + Pester)
- [ ] **New security-/core logic is tested**, and every new guard was **deliberately broken once** (proves it can fail)
- [ ] **No dead code / lint clean** (dead-code scan + PSScriptAnalyzer with no findings)
- [ ] **Command created via scaffolding** (if a new command) -- registry entry + handler + test present
- [ ] **Docs up to date** -- generated help/README match; **CHANGELOG.md** entry added; ADR added for deliberate design decisions
- [ ] **PowerShell 5.1 dialect** respected (no `&&`/`||`/ternary/`??`/`?.`; explicit `-Encoding utf8`; non-ASCII `.ps1` files have a BOM)
- [ ] **Secret hygiene** -- no secret in argv/logs/examples; exactly ONE auth variable set
- [ ] **Security-critical?** -> maintainer review requested (isolation, allow-list, auth, agent guardrails)

See [`CONTRIBUTING.md`](../CONTRIBUTING.md) for the full contribution guidelines, including the contribution-scope policy (large/out-of-scope changes need an issue first) and the PowerShell 5.1 / testing / commit conventions this checklist is based on.

## Proof
<!-- Output of build\Invoke-Checks.ps1 (summary), or relevant test cases. -->

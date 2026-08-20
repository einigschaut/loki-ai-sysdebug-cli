# ADR-0034: The guided mode is the entry point (`loki` with no arguments)

Status: Accepted (2026-08-18)

## Context

Loki reached a functional state before it reached a usable one. Today, bare `loki` prints four lines pointing at
`help` and `status`; `loki help` then lists twelve commands in five groups and says nothing about order. To reach an
offline diagnosis an operator has to already know that `setup` runs somewhere else beforehand, that `--agent` needs a
`mid`-tier model, and where `collect` put the dump so it can be handed to `--analyze` as a path. The online path adds
`auth login` as a further unannounced prerequisite.

So the gap is not a missing capability. **The order of operations lives in the author's head**, and the tool's own
`status`, `hwscan` and `doctor` already compute every fact needed to say what to do next — there is simply nothing
that puts them together and says it.

That has stopped being an internal inconvenience: the tool is about to be shown to someone outside the project, and a
tool only its author can operate cannot be evaluated.

## Decision

**A guided mode becomes Loki's face: `loki` with no arguments runs it.**

### It is a registered command, not a special case

`guide` is a normal command with its own file, metadata function, handler, tests and generated documentation
(ADR-0002). The dispatcher does not grow a mode — it rewrites an empty command name to `guide` and routes on.
`loki` and `loki guide` therefore travel the identical path: one handler, one context shape, one place where
behaviour lives.

The alternative — a bespoke interactive block inside `loki.ps1` — would have made the entry point the first thing in
this tool that `help` cannot describe, that the registry does not know about, and that the docs gate cannot check.
That is precisely the drift CLAUDE.md section 3 exists to prevent, and the entry point is the worst possible place to
start making exceptions.

### It grants nothing

The guide builds the same context hashtable the dispatcher builds and calls the same registered handler. Every gate —
`env-isolate`, the allow-list, the footprint guard — applies exactly as if the operator had typed the command. **The
guided mode is a signpost, never a side door.** This is stated here because "a mode that runs other commands" is the
shape a reviewer should be suspicious of, and the answer should not have to be reconstructed from the code.

### The model is separate from the screen

Everything that decides anything lives in `lib/guide.ps1` as pure functions; `commands/guide.ps1` only draws and
asks. An interactive screen whose logic is tangled up with `Write-Host` cannot be tested, and untested is not done
here (CLAUDE.md section 6). The menu model is table-tested, including the case where an option has no availability
rule at all.

### Two rules that will look like candidates for "improvement" later

**The numbers never move.** Every option is listed and numbered in a fixed order whether or not it is available on
this machine. Renumbering to hide unavailable entries would make `3` the agent on one machine and the online session
on the next, so the technician who uses this daily would have to re-read the menu every time instead of building
muscle memory. An unavailable entry is shown, numbered, and refused *with its reason* — choosing it is itself a way
of asking "why not?".

**An unavailable entry always carries a remedy.** "Online diagnosis: not available" teaches nothing. The tool knows
why and knows what would fix it, and the operator should not have to go find out. This rule earned itself on the very
first real run: `mid` was installed but did not fit the free RAM, and the remedy said *"run loki setup --tier mid"* —
advice for a model the machine already had. The two causes are now distinct, because confidently wrong guidance is
worse than none.

### The learning curve is a design element, not a hope

After a step runs, the guide prints the command line that would have done the same thing:

```
The same thing from the command line: loki offline --analyze reports\dump-2026-08-18-1042.json
```

A guided mode that never names what it did produces dependants. One that always does produces operators who
eventually stop needing it — which is the goal, not a regrettable side effect.

### Three ways to the same place

Guided (`loki`), direct (`loki offline --agent`, unchanged), and conversational (`chat`, `offline --agent`). The
guided mode is a door to the other two, not a wall in front of them: the conversational paths exist today and are
merely undiscoverable.

## Consequences

- Bare `loki` no longer prints a banner. Its two catalog keys (`dispatch.overviewHint`, `dispatch.statusHint`) were
  removed rather than left orphaned; the version still appears, in the guide's own heading.
- **The guided mode is part of the stable interface.** It therefore has to exist *before* 1.0 rather than after —
  freezing a CLI contract and then replacing its front door immediately afterwards would be the wrong order.
- Every string it can print exists in every locale, enforced by a test that collects the keys from both sources (the
  options table and the handler's literals) rather than from a hand-maintained list.
- Redirected input is not an error: the menu is a perfectly good report of what a machine can do, so it is printed
  and nothing is asked.
- The guide reads facts through the same functions the individual commands use, so it cannot disagree with them.
  Verified against a provisioned stick: the guide refused the agent for exactly the reason `hwscan` gives, down to
  the same tier.
- This slice deliberately contains **no** visual identity — no wordmark, no mascot, no colour beyond the existing
  16-colour semantics. A beautiful menu that lies about what works would be worse than the plain list it replaces,
  so honesty ships first and the face follows.

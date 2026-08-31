# ADR-0040: The guided mode becomes a session, and hands the console over to run anything

Status: Accepted (2026-08-31)

The last slice of #133. ADR-0036 to ADR-0039 built a screen, a keyboard, a line editor and a loop; this is the
command that opens one. `commands/guide.ps1` shrinks to "start a session", exactly as #133 planned it.

## Context

The complaint that opened #133: `Invoke-LokiCmd_guide` ran **one** command and returned, so three actions meant
typing `loki` three times — and the third menu was still computed before the first command had changed anything.
The operator ran `collect` and was then offered "analyse a dump" by a menu that did not know the dump existed.

## Decision

**Two paths, one menu.** The session is the guided mode; the one-shot menu is the fallback, and it is the code that
shipped before, unchanged. `Open-LokiSession` returning `$false` is the normal answer under redirection, in CI,
without VT, on a tiny window and under `--plain` — so the fallback is not a rarely-exercised branch, it is what the
entire test suite and the `bare loki == loki guide` byte-identity test run against.

Both render from `Get-LokiGuideMenuLine`, which is new and pure. The format string existed twice for about ten
minutes while this was written, and the two indentations had already drifted by a space.

**The state is recomputed after every command — and not per keystroke.** `Get-LokiGuideState` reads the disk and
opens a TCP probe; "every round" in #133 means every round of the operator's attention, not of the keyboard's. Both
halves are pinned by a test, because the pair of mistakes is symmetric: never refreshing reproduces the original
complaint, refreshing per keystroke opens a socket per keypress.

**The console is handed over for a command's duration.** The session closes, the command runs in the operator's real
console exactly as if they had typed it, and the session reopens.

This is the deviation from the reference worth stating plainly, because the maintainer's standing instruction is to
get as close to the Claude Code experience as possible, and the reference does the opposite: it captures a child's
output into its own transcript and never gives up the screen. Loki cannot, and should not:

- Loki's commands are whole programs with their own interfaces — spinners, colour, progress, a hidden-input prompt in
  `auth login`, and in `chat` and `offline --agent` an entire interactive child process. Rendering those into a
  diff-painted model means rebuilding every one of them.
- Capturing a **native** child's console output reliably is a project on its own, and `collect`, `chat` and the
  offline engine all spawn one.
- The reference owns the rendering of everything it runs. Loki does not own `claude` or `llama-server`.

Three things fall out of the hand-over, all of them wanted:

| | |
| --- | --- |
| what a command did stays in the **real scrollback** | which is the "nothing survives" complaint in #133 — the alternate screen keeps nothing, so the durable record has to be made outside it |
| there is never a second writer while the screen is open | which **retires open decision 3** of #133 rather than deferring it again |
| Ctrl+C belongs to the command while it runs | `Close-LokiKeyread` gives it back first, so a long `collect` is interruptible the way it always was |

The cost is honest and visible: the screen goes away and comes back. That is the trade, not an accident.

**A session's exit code describes the session** (ADR-0038), so a normal departure is 0 whatever the commands inside
returned. The one exception is a session that cannot be reopened after a command — the console was resized below the
floor, redirected, or the screen disabled itself — where the command's own code is returned, because continuing
would mean looping on a session that cannot draw.

**Choosing an unavailable entry writes its reason and remedy into the transcript**, not into the one-line notice.
Choosing an unavailable option is itself a way of asking "why not?", and the answer must survive the next keystroke.
A typo gets the notice, because that answer is worth exactly one keystroke.

## What the mutation runs said

Four guards broken, four distinct reds, all attributable:

| mutation | red |
| --- | --- |
| an invalid choice falls through instead of being refused | *answers a typo with a notice and runs nothing* |
| no state refresh after a command | *recomputes what the machine can do AFTER a command* |
| the session returns the last command's exit code | *leaves with Ok on the second Ctrl+C* |
| refresh on every round | *does NOT recompute per keystroke* |

A fifth finding came from a test that *failed*, and it is the one worth recording: **three of the four "and it ran
nothing" assertions were vacuously green.** They counted invocations through `$script:ran++` inside a
`.GetNewClosure()` handler, where `$script:` resolves to the closure's own scope rather than the test file's — so
the counter was 0 no matter what happened. Only the single assertion that expected a *non-zero* count exposed it.
They now capture a `List[string]` instead, which is a reference type and is mutated in place.

That is the second time in two days that a guard looked exactly like a real one and tested nothing (ADR-0039 records
the first). Both were found by the same move: assert something that must be **non-**default.

## Consequences

- `lib/guide.ps1` gains two pure functions: `Get-LokiGuideMenuLine` (the menu as text, once, for both renderers) and
  `Get-LokiGuideEngineLabel` (which engine would answer — the only machine fact the status row carries, per
  ADR-0038).
- `Get-LokiGuideMenuLine` returns **plainly**, not with the `return , @(...)` its neighbour `Get-LokiGuideMenu` uses.
  That idiom stops a set unrolling and costs every caller a two-step assignment; here every caller iterates, so
  unrolling is correct. Written the other way first, and the tests caught it — in the tests themselves as well as in
  the command.
- `commands/guide.ps1` gains three small helpers (`Get-LokiGuideCommandTarget`, `New-LokiGuideChildContext`,
  `Get-LokiGuideFlag`) shared by both paths, so the child-context shape has one definition rather than two.
- The guided mode's security position is unchanged and is now stated on both paths: it builds the same context the
  dispatcher builds and calls the same registered handler, so `env-isolate`, the allow-list and the footprint guard
  apply exactly as when the operator types the command. The session does not weaken that — it hands the console over
  and calls the identical handler rather than running anything itself. **`lib/session.ps1` contains no reference to
  the allow-list at all** (ADR-0039), and this command is why that matters.
- Five new catalog keys in both locales. The "every key the guide can emit exists in every locale" test gained a
  third source: the engine label is never a literal in the handler, so the regex that scrapes the file cannot see it
  and it is collected by calling the function.

## What is still not known

- **Windows 10.** Unchanged from ADR-0036: the capability gate refuses rather than assumes, and the refusal path —
  which is now also the fallback path this command relies on — has still never run on a machine that needs it.
- **How the hand-over feels in practice.** The screen leaving and returning for every command is a deliberate trade,
  and the only way to judge it is to use it on a real machine. If it reads as flicker rather than as handing over,
  the alternative is not "capture everything" but "keep the screen closed for a run of commands" — cheap to change,
  and deliberately not pre-decided here.
- **Typing a command name instead of a number.** The line editor makes it possible and the registry makes it cheap;
  it is not in this slice because `Resolve-LokiGuideChoice` is the existing, tested contract and widening it is a
  separate decision.

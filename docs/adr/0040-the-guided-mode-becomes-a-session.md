# ADR-0040: The guided mode becomes a session, and captures what it runs

Status: Accepted (2026-08-31)

The last slice of #133. ADR-0036 to ADR-0039 built a screen, a keyboard, a line editor and a loop; this is the
command that opens one. `commands/guide.ps1` shrinks to "start a session", exactly as #133 planned it.

## Context

The complaint that opened #133: `Invoke-LokiCmd_guide` ran **one** command and returned, so three actions meant
typing `loki` three times — and the third menu was still computed before the first command had changed anything.
The operator ran `collect` and was then offered "analyse a dump" by a menu that did not know the dump existed.

## A rejected first attempt, recorded because the reasoning was wrong

The first version of this slice **handed the console over for every command**: the session closed, the command ran
in the operator's real console, the session reopened. The justification was that Loki's commands are whole programs
with their own output and that "capturing a native child's console output reliably is a job on its own".

The maintainer rejected it as too far from the reference, and **measurement showed the justification was false**:

| | |
| --- | --- |
| `claude.ps1:596` (the `ask` path), `agent.ps1:355` (llama-server), `offline-agent.ps1:306` (gated commands) | **already redirect** stdout and stderr |
| Loki's own output | exactly **two** exits: `Write-LokiConsole` and `Write-LokiToStdErr` |
| `claude.ps1:691` (`chat`), `offline-agent.ps1:480` (the agent's `Read-Host` confirm) | genuinely need the console |

Four of the six menu entries can be captured whole. The claim that they could not was a guess dressed as a
constraint, and it was made without opening the files that answer it. That is the actual failure worth recording:
**not "the design was wrong" but "the design was argued from memory when the answer was two greps away".**

## Decision

**A command runs inside the session and its output is captured.** `lib/ui.ps1` grows a sink beside the write hook
it already had; while a sink is registered, `Write-LokiConsole` and `Write-LokiToStdErr` hand the text over instead
of writing it. The session turns each line into a transcript entry and repaints. With no sink registered not one
byte differs from before, which is what the `bare loki == loki guide` byte-identity test measures.

The screen is never handed over for a command the session can capture. That is what makes this a session rather
than a launcher.

**The exception is declared, and it is two of six.** `lib/guide.ps1` marks `chat` and `agent` `Interactive`, and
only those get the console for their duration — a captured confirm prompt is a prompt nobody can answer, and a
captured TUI is a frozen screen. Getting this list wrong in the safe direction costs a screen flash; getting it
wrong the other way hangs the session on a prompt the operator cannot see.

**A no-newline write is progress, not transcript.** The spinner rewinds its own line with a carriage return several
times a second; one transcript row per frame would bury everything else. It goes to the notice row — which is what
that row is for, and what the reference does with its own spinner row at row 45.

**The repaint is rate-limited, the append never is.** Dropping a frame costs nothing; dropping a line loses output.
The limiter is `Test-LokiSpinnerDue`, because "is a redraw due" already has one answer in this codebase.

**The state is recomputed after every command — and not per keystroke.** `Get-LokiGuideState` reads the disk and
opens a TCP probe; "every round" in #133 means every round of the operator's attention, not of the keyboard's. Both
halves are pinned, because the pair of mistakes is symmetric: never refreshing reproduces the original complaint,
refreshing per keystroke opens a socket per keypress.

**Two paths, one menu.** The session is the guided mode; the one-shot menu is the fallback, and it is the code that
shipped before, unchanged. `Open-LokiSession` returning `$false` is the normal answer under redirection, in CI,
without VT, on a tiny window and under `--plain` — so the fallback is what the entire test suite runs against. Both
render from `Get-LokiGuideMenuLine`, which is new and pure; the format string existed twice for about ten minutes
while this was written, and the two indentations had already drifted by a space.

**A session's exit code describes the session** (ADR-0038), so a normal departure is 0 whatever the commands inside
returned. The one exception is a session that cannot be reopened after an *interactive* command — the only path
that gives the console away — where the command's own code is returned rather than looping on a session that cannot
draw.

## The sink is a plain scriptblock, not a closure

`Open-LokiSessionCapture` registers `{ param($w) Write-LokiSessionCapture -Write $w }` and keeps the session it is
writing into in a script variable. The obvious implementation — build the scriptblock with `.GetNewClosure()` so it
captures the state — **does not work**, and fails in a way worth naming: a closure gets its own module scope, and
Loki dot-sources every lib into one script scope rather than importing modules, so from inside the closure
`Add-LokiSessionEntry` is *not a recognised command at all*. Measured 2026-08-31; it fails the same way in the
dispatcher as in a test.

## What the mutation runs said

Six guards broken, six distinct reds:

| mutation | red |
| --- | --- |
| `Write-LokiConsole` never consults the sink | *captures an ordinary command's output into the transcript* |
| the sink is not cleared in the `finally` | *leaves the sink cleared even when the command throws* |
| a no-newline write becomes a transcript line | *turns a no-newline write into the NOTICE* |
| nothing is marked `Interactive` | *hands the console over ONLY for a command that declares itself interactive* |
| everything is marked `Interactive` (the rejected design) | *runs an ordinary command INSIDE the session* |
| an invalid choice falls through instead of being refused | *answers a typo with a notice and runs nothing* |

Two further findings came from tests that were **green while testing nothing**, and both were exposed by a mutation
rather than by reading them:

- Three of the four "and it ran nothing" assertions counted invocations with `$script:ran++` inside a
  `.GetNewClosure()` handler, where `$script:` resolves to the closure's own scope. The counter was 0 whatever
  happened. Only the one assertion expecting a *non-zero* count exposed it.
- *"clears the notice when the spinner clears its own line"* asserted only the final empty value — which is also the
  default. It passed with the no-newline branch removed. It now asserts the notice was **set** first.

The common shape: **a test whose expected value is also the default value proves nothing.** Both were fixed by
asserting something that must be non-default.

## Consequences

- `lib/ui.ps1` gains `Register-LokiWriteSink` / `Send-LokiWriteSink` / `Test-LokiWriteSinkActive`. A sink that
  throws is cleared and the text falls through to the console, so a broken session cannot swallow a command's
  output — the same argument as `Invoke-LokiWriteHook`.
- `lib/brand.ps1`'s spinner now writes through `Write-LokiConsole` instead of a bare `Write-Host`. Byte-identical on
  a plain console; the difference is that a session can capture it. It also makes `ui.ps1`'s own claim true again —
  "the only `Write-Host` in the codebase" — which `brand.ps1` had quietly contradicted.
- `lib/session.ps1` gains `Open-LokiSessionCapture` / `Write-LokiSessionCapture` / `Close-LokiSessionCapture`.
- `lib/guide.ps1` gains `Get-LokiGuideMenuLine`, `Get-LokiGuideEngineLabel`, and an `Interactive` flag on every
  option. `Get-LokiGuideMenuLine` returns **plainly**, not with the `return , @(...)` its neighbour uses: that idiom
  stops a set unrolling and costs every caller a two-step assignment, and here every caller iterates. Written the
  other way first, and the tests caught it — in the tests themselves as well as in the command.
- The guided mode's security position is unchanged and is now stated on both paths. Capturing output does not touch
  it: the sink reads what a command **prints**, it does not sit between the command and the allow-list.
  `lib/session.ps1` still contains no reference to the gate at all (ADR-0039).

## What is still not known

- **Windows 10.** Unchanged from ADR-0036: the capability gate refuses rather than assumes, and the refusal path —
  which is also the fallback this command relies on — has still never run on a machine that needs it.
- **How a long capture feels.** `collect` prints for tens of seconds; the repaint cap is 8 frames a second by
  inheritance from the spinner, not by measuring this case.
- **Typing a command name instead of a number.** The line editor makes it possible and the registry makes it cheap;
  it is not in this slice because `Resolve-LokiGuideChoice` is the existing, tested contract.

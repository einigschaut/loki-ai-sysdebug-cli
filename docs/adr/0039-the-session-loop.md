# ADR-0039: The session loop, and the line it will not cross

Status: Accepted (2026-08-31)

Slice 3b of the UI rebuild in #133, and the one that joins the previous three. ADR-0036 gave the session a screen,
ADR-0037 a keyboard, ADR-0038 a line editor. `lib/session.ps1` is the layout, the transition table and the order the
three are called in — deliberately the last thing built, because it is the part where a bug is cheapest.

## Context

A session has to decide four things the parts could not: where each piece of chrome goes, what happens to a key
between arriving and changing something, what a submitted line *means*, and who is allowed to run it.

The last of those is not a UI question. Every command in Loki reaches the machine through `Resolve-LokiCommandDecision`
— one allow-list, one entrance, enforced mechanically by the single-gate check in CI (CLAUDE.md §5, §7). A session
loop that ran what it read would be a second entrance, whatever its author intended on the day.

## Decision

**The session dispatches nothing.** A submitted line comes back to the caller as `@{ Action = 'submit'; Text = … }`
and the caller decides what running it means. `lib/session.ps1` contains no reference to the allow-list, and that is
the property to preserve: not "the session calls the gate correctly" but "the session cannot call anything at all".

**The layout, and two of its three landmark rows are measurement rather than taste.**

```
rows 1 .. H-5   transcript      grows downward, oldest at the top, tail kept on overflow
row  H-4        notice          one transient line, blank when there is nothing to say
row  H-3        input box top
row  H-2        input row       <- the caret, at column 3
row  H-1        input box bottom
row  H          status          which engine is answering, and the keys that change things
```

| | reference capture, 51-row window | this arithmetic at H=51 |
| --- | --- | --- |
| input caret row | 49 (drawn 1843 times) | **49** |
| hint / status row | 51 (`ESC[51;3H`) | **51** |
| caret column | 3 | **3** |
| spinner row | 45 | 47 — *not* corroborated |

Column 3 is not fitted to the capture; it falls out of a border of one character plus one space of padding, which is
what `Get-LokiBoxArt` has drawn since #130. The notice row is the one placement the capture cannot confirm: nothing in
it says what occupied rows 46 and 47.

Below H=10 the notice row is dropped, on the rule that **the transcript is never smaller than the chrome framing it**.
Below H=8 or W=20 nothing is drawn but a message saying so — the screen refuses to *open* under those, but a window can
be dragged smaller afterwards, and a session that quit because somebody resized it would have thrown away work over a
reversible mistake.

**A multi-line submission is refused, and the text is handed back.** ADR-0038 left this to the session. Running only
the first line is silently wrong; running each line in turn is precisely the accident the paste-aware Enter rule exists
to prevent, and a machine somebody brought in broken is the worst place to guess. Refusing while *also* discarding the
paste would be two punishments for one mistake, so the buffer is returned with the caret at its end and the notice
names the mark that stands in for the line break.

**Resize is handled by repainting in place, never by leaving the alternate screen.** `Resize-LokiScreen` re-measures,
clears and full-paints, and stays inside `?1049`. Close-then-open would work and is shorter, but `ESC[?1049l` restores
the operator's shell for a frame — a flash of somebody else's window mid-session — and would re-run the capability gate
and the read-back self-check on every drag. The second `ESC[2J` this sends does not contradict ADR-0036's "exactly one":
the reference's window was never resized during the 5.3 minutes captured, so the capture says nothing about this case,
and a resize invalidates every row.

The check runs **after** the key read and can only run there: nothing announces a resize (ADR-0037, measured).

**The caret is the console's own cursor, fenced the way the reference fences its frames** — `Hide-LokiScreenCaret`,
paint, `Show-LokiScreenCaret` (move and show in one write). A real cursor blinks, sits where the terminal's own
selection expects it, and is what a screen reader asks for; a block painted into the model would look similar and be
none of those things.

**No colour anywhere in the model.** This is a constraint, not a preference: `Get-LokiScreenDiff` finds a row's changed
span by comparing character by character, so an embedded escape sequence would be counted as content and every column
after it placed wrong. Emphasis has to come from characters until the diff understands attributes.

**History belongs to the session**, because a list of past commands is not something a line editor has any business
owning. It does not wrap at either end, does not store consecutive duplicates, and gives back the half-typed line when
walking forward off the end — losing that is what makes people stop using history at all.

**The state is mutated in place**, departing from `lib/lineedit.ps1` on purpose. An editor returns a new buffer because
a caller may want to fall back; a session has nothing to fall back to, and copying an accumulating transcript on every
keystroke of a machine that is by definition already struggling buys nothing. Testability is untouched.

## `!` is not built, and that is the maintainer's decision

The reference passes a command through to the shell when the line starts with `!` and pulls the output back into the
session. It was proposed here and **declined**: a second terminal window does the same job, is always available on the
machine being repaired, and does it *outside* Loki — so whatever the technician runs there is their own footprint, not
a trace Loki made and cannot clean up. The zero-app-level-traces promise therefore holds by construction rather than by
policing, and the allow-list keeps exactly one entrance. Recorded so the question is not reopened as an oversight.

The corollary is worth stating because it shrinks an open problem: with `!` out, no arbitrary child process ever writes
to Loki's console. Open decision 3 in #133 — a second writer during a repaint — narrows from "any command the operator
types" to `chat` and `offline --agent`, two commands this project wrote itself and can make close the screen first.

## Corrections to ADR-0038, found while building this

**The pilcrow was the wrong break mark, and the reasoning behind it was the wrong kind of reasoning.** ADR-0038 and
`lib/lineedit.ps1` both stated that U+00B6 "exists in both code pages measured on the target (CP850 0xF4, CP437 0x14)".
CP437 does carry a pilcrow *glyph* at 0x14 — but .NET maps 0x14 to U+0014, the control character, so the round trip
comes back changed and the console shows something else entirely. Measured 2026-08-31:

| | CP850 | CP437 | CP1252 | UTF-8 |
| --- | --- | --- | --- | --- |
| U+00B6 pilcrow | ok | **fails** | ok | ok |
| U+00AC not sign | ok | ok | ok | ok |
| U+00B7 middle dot | ok | ok | ok | ok |
| U+00AB / U+00BB | ok | ok | ok | ok |

The default is now U+00AC. **A glyph in a code-page chart is not the same claim as a character an encoder will
produce**, and only a round trip can tell them apart — which is exactly what `Test-LokiEncodingSupport` was written for
in #121, and exactly what was not used when the pilcrow was chosen.

## What the mutation runs said

Five guards were broken on purpose. Four went red where they should have. **One did not**, and it is the one worth
recording: "never lets Ctrl+C reach the line editor", written the obvious way — type `abc`, send Ctrl+C, assert the
buffer still says `abc` — passed with the guard deliberately removed, because `Edit-LokiLine` ignores Ctrl+C today and
hands the same buffer straight back. It was a test that could not fail (CLAUDE.md §9), it looked exactly like a real
one, and only running the mutation said so. It now asserts on the call rather than on the buffer.

A sixth guard failed on its first run rather than under mutation: the property test over a grid of window sizes caught
that `Initialize-LokiScreenModel` unrolls a one-row model to a bare string. Fixing that at the source was tried and
**reverted** — `return , $rows.ToArray()` hands back `String[]` instead of `Object[]`, which makes the `[string[]]`
binding a no-op cast (array covariance) and turns ADR-0036's trap-reproduction test green while it guards nothing. The
fix belongs to the caller, and both files now say so.

## Consequences

- The caller owns the loop: `while` on the Action from `Invoke-LokiSessionRound`. That is deliberate — the thing that
  decides what a command means is also the thing that must hold the exit code and the transcript.
- `lib/screen.ps1` gains three functions (`Resize-LokiScreen`, `Hide-LokiScreenCaret`, `Show-LokiScreenCaret`). All
  additive; no existing signature changed.
- The status line now carries what ADR-0038 said it should — engine and steering, not the environment. The other
  decision that ADR deferred, the session's exit code, still belongs to whoever writes the command that opens one.
- Five new catalog keys in both locales.
- Still nothing consumes this. Same as the three slices before it: the pieces are built and tested before the command
  that joins them, so that command is assembly rather than invention.

## What is still not known

- **A second writer to the console during a repaint** — narrowed by the `!` decision above, but not settled for `chat`
  and `offline --agent`, and still unmeasured.
- **Whether the reference disarms Ctrl+C on a keystroke or on a timer.** Only its output was captured.
- **Windows 10.** No machine available; the capability gate refuses rather than assumes, and that refusal path has
  still never run on a machine that needs it.
- **Mouse selection and auto-copy** (the reference's `copied N chars to clipboard`) is a later slice needing its own
  probe. Nothing here forecloses it.

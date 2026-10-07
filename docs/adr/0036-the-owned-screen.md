# ADR-0036: Loki owns the screen, and gives it back untouched

Status: Accepted (2026-08-26) — **amended 2026-10-05**: one of its consequences was false as written; see *Amendment* at
the end.

Reverses the central claim of ADR-0035 and the "What is deliberately NOT copied from the reference" section of
issue #133. Both ruled out the alternate screen and every escape sequence, on the grounds that Loki must leave no
app-level trace. That reasoning was sound and its premise was wrong, and the premise was wrong because it had been
inferred rather than measured. ADR-0035's mechanism survives as the fallback path; its model of the reference does
not.

## Context

Issue #133 exists because Loki's UI runs one command at a time while the reference is a session, and the maintainer
asked for the UI layer to be rebuilt rather than retrofitted, in a fixed order: plan, then measure, then review the
plan against the data, then code. This ADR is the output of the third step.

### What the reference actually does

A pseudo-terminal recorder was written for the purpose and a real 5.3-minute session captured — a slash command, a
question, an interactive selector. 249,325 bytes from the program, with the ConPTY's own prologue subtracted at
byte 32.

| | |
| --- | --- |
| alternate screen | byte 1775 to 248,815 — **99.1% of the session** |
| before it | the trust dialog, in the normal buffer, erased line by line before switching |
| after it | one line: `claude --resume <uuid>` |
| `ESC[2J` in the whole session | **1**, at entry. Never cleared again |
| frames | 1836, fenced by `ESC[?25l` … `ESC[?25h` — cursor hidden for the frame, then parked at the input caret |
| frame payload | median **61 bytes**, p90 103, max 11,505; 76% of the whole stream |
| `ESC[?2026h/l` (synchronised output) | 1966 pairs, **all empty** — begin and end adjacent, nothing between them |
| absolute positioning (CUP) | 4048 |
| relative cursor-up (CUU) / scroll region (DECSTBM) | **0** / **0** |
| repaint targets | row 49 ×1843 (input caret), row 45 ×1749 (spinner), every other row < 65 |
| repaint rate | median 8/s, peak 13/s |

It is a full-screen cell-level differential renderer. The chrome repaints; the transcript is written once. The
conversation never exists in the terminal's buffer at all.

ADR-0035 states the opposite — "Its default rendering mode is **not** a fullscreen takeover" — and that sentence
was written from a 4 KB capture in which the switch to the alternate screen happens at byte 1807, which looked like
44% of the file. Here the same switch is at byte 1775. It was never a proportion; it was a fixed startup offset.
A short capture made a constant look like a phase.

Two caveats were registered before the analysis and both were dealt with. The capture ran inside a ConPTY that does
not answer the capability queries (`ESC[>0q`) the way a real terminal does, so the mode choice could have been an
artefact of the instrument — settled independently, by the maintainer running the reference in his own terminal and
confirming the conversation is gone after exit. And the resume hint at the end is not what an ordinary `/exit`
produces, so the capture's exit path differs from normal use; it changes nothing about the rendering.

### What Windows PowerShell 5.1 can do

`Probe-LokiFullscreen.ps1`, a throwaway instrument outside the repository. Five runs, Windows 11 10.0.26200,
WinPS 5.1.26100.8875, ConsoleHost, code page 850.

| | ConPTY 120×30 | ConPTY 63×8 | conhost 120×9001 behind 120×30 |
| --- | --- | --- | --- |
| VT processing active | yes | yes | yes |
| alternate screen entered and left | yes | yes | yes |
| **visible rows changed by the round trip** | **0 of 30** | **0 of 8** | **0 of 30** |
| buffer height before / after | 30 / 30 | 8 / 8 | **9001 / 9001** |
| scrollback marker above the window, row before / after | n/a | n/a | **33 / 33** |
| `GetBufferContents` inside the alternate screen | works | works | works |
| diff paint | 26 B/frame, 0.77–0.88 ms | 25 B/frame, 1.36–1.86 ms | 26 B/frame, 1.47 ms |
| full repaint | 3417 B, 1.07 ms | 391 B, 0.56–0.93 ms | 3417 B, 1.21 ms |
| read-back check, clean run | 0 errors | 0 errors | 0 errors |
| read-back check under `-MutateDiff` | 1 error — **fired** | 1 error — **fired** | — |

The buffer reporting 120×30 while inside the alternate screen is a view change, not a truncation: a marker parked
in the scrollback above the window was found at the same absolute row afterwards. The scrollback is what a
technician needs; the error that brought them to the machine may be sitting in it.

Three further readings matter.

**VT is detectable without `Add-Type`.** Write a colour sequence, read the cell back: with VT on the buffer holds
`A`, with VT off it holds the raw `ESC [ 1 m A`. This is not a stylistic preference — `Add-Type` compiles to a
temporary DLL under `%TEMP%`, and a temporary DLL is a trace.

**The diff is smaller but not faster.** 130× fewer bytes, and in a small window slower than repainting everything,
because the cost is the per-cell comparison running in PowerShell rather than the console write. Both are far
inside budget at 12 frames per second. Bytes are the reason to prefer the diff; speed is not.

**A trap was found and removed before it produced any numbers.** `Initialize-VirtualScreen` returns `Object[]` — a
`return` unrolls the array — and binding that to a `[string[]]` parameter converts it, which copies. Every cell
write would have landed in a copy, silently: the model would never change, every diff would be empty, and the
read-back check would still have reported *zero mismatches*, because it would have compared two unchanged things.
That is the same wrong-against-wrong failure that let 28 deliberately bad anchors through the first live-region
probe (ADR-0035). It is why `Write-LokiScreenCell` carries no type constraint.

### The keyboard, which is the next problem and not this one

| key | what `[Console]::ReadKey($true)` delivered |
| --- | --- |
| letter | `Key=A Char=97` |
| arrow up | `Key=UpArrow Char=0` — clean |
| Ctrl+C | `Key=C Char=3 Mod=Control`, and it did **not** abort — `TreatControlCAsInput` works |
| paste | one run: `P`, `O`, `W` as three separate keys, eating the next two prompts. another: `Key=V Char=22 Mod=Control` — the literal keystroke, no text |

There is no bracketed paste at this layer: the reference enables `ESC[?2004h` and receives a delimited block, and
`ReadKey` cannot see that because the ConPTY has already turned the paste into keystrokes. A pasted multi-line
block arrives as a burst including Enter characters, each of which would submit a line. That is `lib/keyread.ps1`
and its own probe, not this ADR.

## Decision

**Loki takes the whole window, paints it by cell-level difference, and gives it back untouched.**

- **Alternate screen.** `ESC[?1049h` on open, `ESC[?1049l` on close, measured to restore the visible screen and
  the scrollback exactly. It is not the invasive option; it is the only one measured that leaves nothing behind.
  Writing into the technician's normal buffer *is* mutating it.
- **`ESC[2J` exactly once, at entry.** Everything after it is a difference, matching the reference.
- **Absolute addressing only.** No relative motion, no scroll region, and no newline anywhere in a paint. The
  obvious full-paint implementation joins rows with CRLF and is wrong: the newline after the last row scrolls the
  screen by one, so every later absolute position is off by a row. It looks fine in a probe that paints
  `WindowHeight - 2` rows and breaks the moment the screen is the full window.
- **One console write per frame.** The rule that came out of the flicker measurement in ADR-0035 — what makes a
  frame tear is the *number* of console writes, not the cursor motion — and it survives the change of architecture
  unaltered.
- **A capability gate that refuses rather than guesses**, with the same shape as the region's: `plain`,
  `redirected`, `host`, `no-vt`, `window-short`, `window-narrow`. It says nothing about the buffer, because both
  buffer regimes were measured to work; the region's buffer checks exist only because it anchors itself inside
  somebody else's buffer.
- **One read-back self-check, at open.** `GetBufferContents` works inside the alternate screen, so the renderer can
  be verified against the console it is drawing on. If the console does not show what was just painted, this file's
  model of the world is wrong and drawing a whole session on top of a wrong model is worse than not drawing it:
  leave, refuse for good, fall back. It runs once rather than per frame because reading thirty rows costs more than
  painting them. A console that cannot be read back at all is *unverifiable*, not wrong, and is accepted.
- **Windows 10 answered by detection, not by hoping.** No Windows 10 machine was available to measure. The VT probe
  decides at runtime; a console without VT is refused and falls back to the bottom-anchored region from ADR-0035,
  which needs none of this.

### Not copied from the reference, with reasons that outlive the fashion

- **Synchronised output (DEC 2026).** The reference emits it 1966 times as an *empty* pair. It is not what makes
  its frames calm — the cursor hide/show pair is the frame — so sending it would be cargo.
- **Mouse tracking, per-span colour, in-app search.** Nothing needs them yet, and each is a mode to restore on
  every exit path.
- **A fullscreen renderer for `--plain`, for pipes and for CI.** The gate refuses; the region takes over.

## Consequences

- **Nothing Loki shows inside the screen survives in the scrollback.** That is the deliberate price of giving the
  screen back untouched, and it is the reverse of ADR-0035's premise. The compensation is one line printed into the
  normal buffer *after* leaving the alternate screen: what ran and where the report is. The reference prints its
  resume hint in exactly that position; Loki's equivalent is the report path, which is the thing a technician
  pastes into a ticket.
- **ADR-0035's region becomes the fallback, not the target.** Its capability gate, width and geometry logic,
  one-write rule and CP850 tiers all survive; its *anchor* does not, because that solves the problem of a program
  that scrolls and this one does not scroll.
- The dispatcher's teardown gains `Close-LokiScreen` beside `Close-LokiRegion`. There is no path on which Loki
  exits with the alternate screen still active that does not also mean the process was killed outright.
  **— False as written; corrected in the amendment of 2026-10-05.**
- `lib/screen.ps1` reaches into `lib/liveregion.ps1` for `Get-LokiConsoleFact`, and reuses `Test-LokiRegionTextSafe`
  is *not* done — the screen pads by cell count the same way and will need the same rule. Both are recorded debts:
  the console-fact reader belongs in `lib/ui.ps1`, and the cell-text rule belongs in a shared place under a name
  that does not claim to be about regions.

## What is still not known

Stated rather than assumed, because the last time this project assumed a rendering mode it wrote it into an ADR.

- **Windows 10, and the legacy console host on older builds.** Refused by detection if VT is absent, but the
  refusal path has never run on a machine that actually needs it.
- **A second writer to the console during a repaint.** A native child process writing while the screen is up. This
  gates whether `chat` and `offline --agent` may run inside the screen at all, and it is open decision 3 in #133.
- **Resize while the alternate screen is open.** The region closes itself on any geometry change; the screen has no
  answer yet.
- **The flicker result is weaker than it reads.** All six blind arms were rated calm, including the worst
  configuration, and the hidden repeat was consistent — but no arm was *known* to flicker, so the honest conclusion
  is "nothing flickered here", not "the number of writes stopped mattering". The one-write rule stays because it is
  the only thing previously measured to matter and it costs nothing.

## Amendment (2026-10-05): the console was not given back on every path

The consequence above — *no path short of a kill leaves the alternate screen active* — was false. An independent
review of the session layer found the gap, and a fault walk over the real code measured it. A second independent review
of the first fix then found that this amendment itself overclaimed in three places; they are corrected below rather
than silently rewritten.

**What was wrong.** `Open-LokiScreen` wrote the enter sequence first and recorded that the screen was open only at
the very end, after the full paint and the read-back. An exception or a stop anywhere in between left the record
empty, so `Close-LokiScreen` — and with it the dispatcher's `finally` — had nothing to undo, and the operator was left
in the alternate screen with the cursor hidden. The session also opened the screen *before* it claimed Ctrl+C, so a
Ctrl+C pressed while the screen was opening was a real stop, landing exactly in that window.

**How it is measured.** `tests/teardown.Tests.ps1` runs one full lifecycle against a fake console that interprets what
Loki writes and keeps the state a terminal keeps (`tests/helpers/LokiTestConsole.ps1`): open, a frame, a key read
during which the window shrinks, a command whose output is captured, the hand-over to an interactive command and back,
close. It first counts the console calls of a fault-free run (**K**), then fails the lifecycle at each of those
calls in turn, in three ways — before the call took effect, instead of it (the call reports failure), and right after
it (the effect happened, then a stop) — and asks whether the operator got their console back: main screen visible and
untouched, cursor visible **and where it was**, Ctrl+C as it was. It asks right after an open that refused, too,
because the caller carries on in the one-shot menu at that point; and it checks that a console which came back is not
reported as failed.

*Correction.* The first version of this amendment said "17 of 80 points failed, all 80 pass after the change". The
walk then had 80 points, but the cycle it walked made only 24 console calls: 32 of the 80 points lay past its end and
re-ran the fault-free cycle. The 17 failures were among the 48 real points. The walk now covers exactly the calls of
the run it counted — K = **60** calls, so **180** points over three modes, all passing. A second review then found
that 11 of those 60 calls ignored the "reports failure" mode — the fake answered as if nothing had happened, so 11 of
the 180 points re-ran the fault-free cycle once more. Every call now answers that mode the way its real primitive
answers a failure (no console facts, no key, VT off, Ctrl+C not claimed), and all 180 points still pass.

**What changed.**

- A separate flag says a leave is owed. It is set **before** the enter sequence is written and cleared only once a
  leave has been written successfully; `Close-LokiScreen` acts on it even when no screen was ever fully open, and a
  leave that could not be written is tried again by the next close. Every failure path in `Open-LokiScreen` *after*
  the enter leaves through `Close-LokiScreen` instead of writing its own leave sequence.
- **A leave that is not owed is not harmless.** Measured on a real conhost: `ESC[?1049l` without an enter before it
  moves the cursor to the top-left corner of the window (8,7 → 0,0; and 8,60 → 0,31 with the window scrolled to row
  31 of a 9001-row buffer), and a second leave after a successful one jumps the cursor back to where it was at enter,
  over whatever was printed in between. So an enter write that *reports* failure clears the flag again — it never
  reached the terminal — and no leave is sent. For the one case nothing can decide (the enter was attempted but never
  confirmed, because something stopped the open in between), the leave is followed by putting the cursor back where it
  was before the enter. Measured on the same console: back at 8,60, scroll position unchanged. After a *confirmed*
  enter the cursor is left to the terminal, which restores it into a main buffer that a resize may have reflowed.
- The session asks the screen's cheap refusals first (`Get-LokiScreenPrecheck`: `--plain`, redirection, a foreign
  host, a tiny window), then claims Ctrl+C, then opens the screen; it gives Ctrl+C back **last**. A Ctrl+C while the
  screen opens or closes is a key, not a stop. A session that was never going to open does not touch Ctrl+C at all.
  The keyboard records its state **before** it claims Ctrl+C, so a stop right after the claim still gives it back,
  and it gives back what it found at the **first** open — an interactive command that leaves Ctrl+C claimed between
  two opens does not change what the operator gets back. `Close-LokiKeyread` keeps its state until Ctrl+C has really
  been handed back, so a failed attempt is retried.
- One function, `Restore-LokiConsole` (`lib/teardown.ps1`), replaces the four separate teardown calls in the
  dispatcher. It runs every step on its own guard (a step that throws no longer skips the ones after it), in a fixed
  order — capture sink, live region, screen, session, keyboard last — and then asks the state what is still not given
  back. The dispatcher calls it from its `catch` **before** printing the error, because an error printed while the
  alternate screen is still active lands in the alternate buffer and is discarded with it; the `finally` calls it
  again and reports the outcome of that last call only.
  *The region goes before the screen*, in this function and in `Close-LokiSession`. A live region that a command
  opened inside the session (`collect` does) closes by blanking its rows at an anchor read from the console; after the
  leave that is the operator's main buffer. A second review measured it on a real conhost with the region closed after
  the screen: four of the operator's rows blanked, the cursor moved from 11,40 to 0,36, nothing reported. With the
  region first: no row changed, cursor in place.
  *The dispatcher exits from inside its `finally`.* After a stop the `finally` runs to its end but nothing after it
  does; measured by the second review (`powershell -File`, a real `CTRL_C_EVENT`): `exit` after the `finally` ended the
  process with 0 whatever the restore had found, `exit` inside it with the code the `finally` computed.
  *Correction.* The first version said that a run which could not give the console back no longer ended with exit
  code 0. It still did: the Close functions report a failed write by keeping their state, not by throwing, and only
  throws were recorded — the review measured it on a real console (alternate screen active, exit 0, no warning). Now
  the outcome is read from the state after every step has run, `Get-LokiRestoreExitCode` turns Ok into GeneralError
  (any other code is kept: the command's own reason comes first), and `Write-LokiRestoreWarning` says what could not be
  given back, best effort and without throwing.
- A session whose screen is lost — a frame, caret or resize repaint that cannot be written — now ends instead of
  carrying on with nothing drawn and Ctrl+C still claimed, and the guided mode reports it with an error code rather
  than exiting 0. *Correction.* The first version said this of frame and caret writes only; a failed repaint after a
  resize still returned the key's action, and the caller ran a command with the screen gone. The round now checks
  after the resize as well, before it acts on the key. A key that cannot be read ends the session with the keyboard's
  own reason.
- The VT probe puts the operator's cursor row back from a **snapshot of its cells** — characters and colours —
  through `$Host.UI.RawUI.SetBufferContents`, in a `finally`. It used to reprint the row's text through the output
  code page. Measured on a real conhost window (CP850, Windows PowerShell 5.1) with a coloured row holding ✓ and →:
  the old code changed **11 of 120** cells (✓ came back as `V`, colours gone); the new code changed **0 of 120**,
  cursor included. Not measured under Windows Terminal (ConPTY).
- Two additive `lib/` contract changes, every existing caller unaffected: `Move-LokiCursor` takes an optional `-Col`
  (default 0), and `Get-LokiConsoleFact` also reports `CursorLeft`.

**What is still true, and what still is not covered.** A hard kill of the window runs no `finally` anywhere and so
still leaves the alternate screen active; nothing short of a job object (which would need `Add-Type`, a trace) can
change that. While Ctrl+C is claimed, a Ctrl+C typed **on the keyboard** is a key and interrupts nothing, and the
keyboard is given back last, so by the time Ctrl+C is a stop again the screen is already back. That is narrower than
this sentence first said; the second review measured two ways round it on a real conhost:

- **Ctrl+Break** cannot be claimed. In an open session it breaks into the PowerShell debugger on the next key, and the
  `[DBG]` prompt is drawn into the *alternate* screen with Ctrl+C released. Leaving it with `q` stops the script, the
  `finally` runs, and the console came back fully (buffer, cursor, Ctrl+C, no failures). Continuing with `c` was not
  measured conclusively.
- A `CTRL_C_EVENT` sent **programmatically** to the console still stops the script while Ctrl+C is claimed.

Not covered either: the live region (the `collect` footer) outside a session never claims Ctrl+C, so there a second
Ctrl+C inside the `finally` can still cut its cleanup short — the review measured that a stop aborts a running
`finally` under 5.1.

Known residuals, reasoned and not measured, and none of them reported to the operator: the VT probe ignores a failed
restore of its snapshot (a bold `A` would stay in column 0 of the operator's row); the cursor repair after an
unconfirmed enter is best effort; a region failure that does not throw is invisible to `Restore-LokiConsole`, because
the region clears its own state first; and an enter write that reported failure *after* its bytes went out would clear
the leave obligation and strand the operator in the alternate screen. That last one is the same never-observed
failure mode as the leave-retry case below, with a worse outcome.

The fake console does not model, and so nothing green covers:

- a real Ctrl+C stop. A script's `catch` cannot catch one; the injected faults can, so a fault inside a restore step
  lets the next step run where a real stop would not;
- SGR attributes — the leave sequence's attribute reset is pinned by a test of its own instead;
- output between a leave whose effect happened but was reported as failed and its retry. The retry is a second leave
  and jumps the cursor back to where it was at enter; the walk prints nothing in between. A console write that
  reports failure after its bytes went out was never observed;
- ordinary output. `Write-LokiLine` and the one-shot fallback menu write to the real console, not into the fake, so a
  line that falls through a capture sink which failed while the screen was up is invisible to the walk;
- the real console primitives. `Move-LokiCursor`, `Get-LokiConsoleFact` and the buffer snapshot are always replaced in
  the tests, so the *column* half of "cursor where it was" rests on the real-console measurements above alone: three
  mutations that force the column to 0 pass the whole suite;
- a live region inside the session, which is not part of the walk's lifecycle (its order is pinned by a test of its
  own);
- line wrapping, a main buffer reflowed by a resize, and Windows Terminal / ConPTY in general.

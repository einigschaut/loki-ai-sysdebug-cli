# ADR-0036: Loki owns the screen, and gives it back untouched

Status: Accepted (2026-08-26)

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

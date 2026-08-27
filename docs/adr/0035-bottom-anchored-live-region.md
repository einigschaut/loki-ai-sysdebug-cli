# ADR-0035: A bottom-anchored live region, engaged only where it was measured

Status: Accepted (2026-08-25)

> **Amended 2026-08-26 by ADR-0036.** The paragraph below beginning "Anthropic's CLI was examined as the reference"
> is **wrong on its central claim**, and the error is instructive. It says the reference's default rendering mode is
> not a fullscreen takeover. A 249 KB capture of a real session says the opposite: the alternate screen is entered
> at byte 1775 and left at 248,815 -- 99.1% of the run -- and the conversation never exists in the terminal's buffer
> at all. The earlier sentence came from a 4 KB capture in which the same fixed startup offset (byte 1807) looked
> like 44% of the file. A short capture made a constant look like a phase.
>
> The consequence for this ADR is narrower than it sounds. Everything measured here -- the anchor's survival across
> 1000 repaints and 100 scroll events, the mutation control that caught a walking region 189 times, the one-write
> rule against flicker, the CP850 tiers, the fail-closed capability gate -- stands unchanged and is now the
> **fallback path**, taken whenever ADR-0036's screen refuses (no VT, a pipe, `--plain`, a window below the measured
> floor). What does not survive is the *model*: the anchor solves the problem of a program that scrolls, and the
> rebuilt UI does not scroll.
>
> Also corrected: the reason given here for refusing the alternate screen -- that `collect`'s report path must
> survive in real scrollback -- was measured to be backwards. Entering and leaving the alternate screen changed 0 of
> 30 visible rows and left a scrollback marker at the same absolute row, in a 9001-row buffer. Writing into the
> technician's normal buffer is the option that leaves something behind.

Supersedes the blanket refusal in ADR-0034 ("The spinner owns its line", "Two threads writing to a shared cursor is
a class of bug this project should not invite for decoration") with a narrower rule. The reasoning there was right;
what changed is that there is now a measurement instead of a fear.

## Context

Loki reached a functional state before it reached a pleasant one, and the tool is about to be shown to someone
outside the project. The shipped progress indicator is a single line rewritten with a carriage return: honest, but
it can say only one thing at a time, and it cannot show finished work and current work at once.

Anthropic's CLI was examined as the reference. Its default rendering mode is **not** a fullscreen takeover — that
impression comes from its alternate-screen renderer, which Loki must not copy, because `collect`'s last line is the
report path and it has to survive in the terminal's real scrollback. What its default mode does is keep a small
region pinned above the cursor and repaint it in place while finished output scrolls away above.

That mechanism needs one property to be true:

```
regionStart = CursorTop - RegionHeight
```

recomputed on every repaint, never stored. It is self-correcting in theory: when the buffer scrolls, the region and
the cursor move up together and the difference is unchanged. Whether it is true in the consoles Loki actually meets
was the open question, and it was answered with a throwaway probe rather than by reasoning.

## The measurement, and the part of it that failed

| host | geometry | buffer regime | repaints | scrolls | anchor row | drift |
| --- | --- | --- | --- | --- | --- | --- |
| Windows Terminal | 209x51 | buffer = window | 400 | 40 | 48..48 | 0 |
| VS Code terminal | 175x26 | buffer = window | 400 | 40 | 23..23 | 0 |
| conhost | 120x50 | 3000-row buffer | 200 | 20 | 2997..2997 | 0 |

1000 repaints, 100 scroll events, both buffer regimes. The anchor row is not merely stable on average — it is
constant to the row. Every line that scrolled away was read back and found intact above the region.

**The most useful result came from breaking the instrument on purpose.** The probe's first version verified one
thing: the cells at `CursorTop - height` after each write. Fed 28 deliberately wrong anchors, it reported **zero**
errors — and so did the obvious repair of reading those rows *before* overwriting them. A region that walks up the
screen carries its cells *and* the cursor with it, so both checks compare wrong against wrong and agree. What caught
it, 189 times, was a structural invariant nobody had proposed: **once the buffer is full, the cursor must return to
the last buffer row after every repaint.** Anyone changing the anchor rule should re-run that mutation control
before believing a green result.

A second measurement decided how a frame is written. Six blind segments, one variable at a time, with a hidden
repeat as a reliability control:

| | writes | scrolls | flickered |
| --- | --- | --- | --- |
| two console writes per frame | 2 | yes / no | **yes, both** |
| one console write per frame | 1 | yes / no | no, neither |
| cells written directly, no cursor move | 1 | no | no |

The flicker is the **second console write**, not the scroll and not the cursor move. `Write-Host` emits the text and
then `Environment.NewLine` separately, so at the bottom of a full buffer the content arrives in one operation and the
scroll it causes in the next, and the terminal is free to draw the state in between. The hidden repeat agreed with
the segment it repeated, so the comparisons carry weight.

## Decision

**A live region may own the bottom rows of the console, but only inside the regime that was measured.**

### One frame is one console write

`Format-LokiRegionFrame` returns a single string, lines joined with CRLF and carrying its own trailing CRLF, handed
to one `-NoNewline` write. That is the entire flicker fix and it is asserted by a test, not left to convention.
CRLF and not LF, because a bare LF moves down without resetting the column and the next line of a padded full-width
frame would start at the right-hand edge.

### The gate is the design

`Get-LokiRegionCapability` is pure, takes every fact as a parameter, and answers with one machine token. The region
engages only when the answer is `ok`; everywhere else the shipped carriage-return spinner runs unchanged. This is
what makes the change mergeable at all: **it is a no-op wherever the evidence stops.** It refuses on `plain`,
`redirected`, `host`, `region-height`, `buffer-short`, `buffer-wide`, `window-short` and `window-narrow`, and it
disables itself for the rest of the process on a resize, a refused cursor move, or text whose console width is not
its string length.

**A buffer taller than its window is explicitly allowed.** An earlier draft of this design proposed refusing it. That
would have switched the region off in the classic conhost scrollback regime — which is both the single
best-evidenced configuration in the table above and the console a portable diagnostic stick is most likely to land
in. The gate refuses what is measured to fail, not what was assumed to be untested.

### Not SetBufferContents

Writing cells directly looked like the winner at 0.10-0.25 ms against 0.66-1.24 ms. That comparison was unfair: the
cell array was built outside the timing loop and a real footer must rebuild it every frame, so the advantage is
unmeasured rather than established. More decisively, it measured exactly as calm as the ordinary write path — so it
buys nothing — and it cannot scroll, which is half of what a live region is for.

### One mechanism owns the cursor at a time

ADR-0034 refused a second cursor-owning mechanism, and that still holds. The rule is now precise: the choice between
region and spinner is made **once**, at the call site, before any drawing starts, and nothing downstream asks which
one is running. They are alternatives, never neighbours.

The seam that enforces it lives in `lib/ui.ps1`. `Write-LokiConsole` is the only `Write-Host` in the codebase and
fires no hook — it is what the region draws with. Everything else goes through `Write-LokiRaw`, which closes an open
region first. **Including stderr**: `Write-LokiWarn`/`Write-LokiErr` bypass `Write-Host` entirely via
`[Console]::Error.WriteLine` and appear on dozens of source lines, so one unguarded path would have been enough to
print straight through the footer. With no region open the hook is `$null` and the bytes are byte-for-byte what they
were before the seam existed, which is what the dispatcher's bare-`loki`-equals-`loki guide` test measures.

### It changes no console state

No escape sequences, no output code page, no VT mode, no buffer size, and the cursor is not hidden. `lib/ui.ps1`
already makes this argument for encoding: a hard kill skips any restore, so anything mutated stays mutated after
Loki exits. A region abandoned by a crash leaves a stale footer on screen — never a changed console.

## Consequences

- `loki collect` gains a footer: the serpent plus the running battery, and a progress bar. Finished batteries
  scroll away above it. Its content is digits and ASCII bars only, so this adds no catalog key and no new CP850
  surface. Since slice 2a the two content rows sit inside a frame drawn by `Get-LokiBoxArt`, making the region four
  rows tall; the frame uses the same six characters that box the mascot's head, and its corners are **square**
  because the rounded ones (U+256D..U+2570) do not exist in CP850 -- the shape issue #121 took.
- `--plain` and `LOKI_PLAIN` switch it off, mirroring `--no-color` / `NO_COLOR`.
- The dispatcher's teardown anchor, deliberately empty since stage 0, gains its first inhabitant: `Close-LokiRegion`
  on every exit path, including the one through the catch.
- Command tests pass `Plain = $true`. Without it, whether the region engages would depend on how the suite was
  started — piped through CI it refuses, run in a bare console it would engage and repaint over the test output. A
  test whose behaviour changes with the terminal it runs in is not a test.
- Every decision is pure and table-tested; the state machine is tested against three mocked console primitives. The
  deliberate break required by CLAUDE.md section 6 turns the anchor's refusal (`-1`) back into a clamp (`0`) and
  must go red — the exact mutation the probe was blind to.

## What is still not known

Stated because a gate built on assumptions should say which ones they are.

- **Nobody has watched the write path on a classic conhost.** Its numbers come from one unattended, minimised
  window. The arithmetic is measured there; the appearance is not.
- **A second writer to the console during a repaint** is entirely unmeasured. `collect` is safe because its
  batteries are `Get-CimInstance` calls, but no command that spawns a console-attached child may open a region until
  that is measured.
- **The width floor of 40 columns is a judgement, not a measurement.** The narrowest console ever measured here was
  120 columns; an 80x25 window is untested.
- **Resize is refused, not handled.** Every measurement voided itself on resize, so adapting to it would be code
  written against no evidence.
- **Non-ASCII payloads.** Everything measured was ASCII under CP850. `Test-LokiRegionTextSafe` rejects wide and
  combining characters, but East-Asian-Ambiguous characters — which include the box-drawing glyphs of the `oem`
  serpent — are accepted and would render double-width on a CJK code page. The capability gate does not yet see the
  code page.

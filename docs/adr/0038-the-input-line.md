# ADR-0038: The input line, and when a pasted Enter is allowed to submit

Status: Accepted (2026-08-27) — amended 2026-08-31, see **Correction** at the end

Slice 3a of the UI rebuild in #133. Splits the line editor out of the session loop before the loop exists, and
settles the one rule that slice 2's measurements were taken for.

## Context

A line editor is nothing but edge cases: word deletion at a boundary, Home on an empty line, a cursor that must
stay inside a box narrower than its text, a paste that contains newlines. Buried inside a loop that owns a screen
and blocks on a key, none of them can be tested — CI has neither a console nor a keyboard. Split out, all of them
can, and `lib/lineedit.ps1` contains not one console call.

The rule that needed deciding is Enter, and both obvious answers are wrong.

A pasted block arrives as ordinary keystrokes; there is no bracketed paste at this layer (ADR-0037). A three-line
paste therefore contains two Enter keys, and an editor that submits on every Enter fires two commands the operator
never typed. But an editor that refuses every pasted Enter breaks the single most common paste there is — one
command copied out of a ticket, with the trailing newline that copying a line always brings.

## Decision

**Enter submits when it was typed, or when it is the last key of a burst. A pasted Enter with more keys already
waiting behind it inserts a line break instead.**

```
"loki hwscan<CR>"   the CR is last, nothing waiting   -> submits.   What the operator meant.
"a<CR>b<CR>c"       both CRs have keys waiting        -> two line breaks, nothing runs.
```

Both halves come from one measured signal: the next key was already waiting for **59 of 61** pasted characters and
**0 of 23** keystrokes, and the two paste exceptions are exactly the first (no predecessor) and the last (nothing
follows). `tests/lineedit.Tests.ps1` pins the rule from both sides, and both mutations were run rather than
assumed — the naive "every Enter submits" turns two tests red, the over-cautious "no pasted Enter ever submits"
turns a third red.

**A pasted line break is kept in the buffer, not discarded.** The operator gets back exactly what they pasted. A
single-line box cannot show a newline, so `Format-LokiLineView` renders it as one visible mark — which is what lets
them see it and delete it. The mark is a **parameter**, because this file draws nothing and the codebase has three
glyph tiers. Its default was U+00B6; that was wrong, and the **Correction** below replaces it.

**The editor names intents, it never acts on them.** `submit`, `interrupt`, `history-prev`, `history-next`,
`complete`. History and completion need lists this file has no business owning, and an editor that could end a
session would be an editor with a side effect — which is why Ctrl+C is absent from it entirely. The session asks
`Get-LokiExitIntent` before the key ever reaches the editor.

**Readline's chords, because a technician's fingers already know them.** Ctrl+A, Ctrl+E, Ctrl+U, Ctrl+K, Ctrl+W.
Ctrl+A, Ctrl+U and Ctrl+W were measured arriving as 1, 21 and 23; Ctrl+E and Ctrl+K are the same mechanism at 5 and
11 and are handled by the same rule — inference, not measurement, and said so in the code. Ctrl+W skips trailing
whitespace before it looks for a word, without which it deletes nothing after a space and feels dead.

**The view scrolls horizontally and keeps the caret inside the box.** A command line outgrows its box and the box
cannot grow; without this, typing past the right edge either wraps — destroying the screen's row arithmetic from
ADR-0036 — or silently vanishes.

## Consequences

- The buffer may contain newlines, so the session must decide what a multi-line submission means. It has the
  information to refuse one with a clear message, which is better than never letting one exist.
- `Test-LokiLineInsertable` refuses control codes and surrogate halves but **not** characters that occupy two
  console cells. The measured input set is CP850 text on a German layout, where every character is one cell, and
  refusing more would refuse scripts nobody here has tried. The stated consequence: type a full-width character and
  the caret sits one cell off. Known and bounded rather than silently wrong — and it is written in the file, not
  only here.
- Nothing consumes this yet. Same as ADR-0036's screen and ADR-0037's reader: the pieces are built and tested
  before the loop that joins them, so the loop is assembly rather than invention.

## Two decisions this ADR does not make, recorded because they were asked

Both were proposed in #133 and both were revisited on merit rather than accepted as defaults; they belong to the
session slice, and are noted here so the reasoning is not lost between slices.

**A session's exit code describes the session, not the commands inside it.** The proposal was "the last command's",
which makes the exit code depend on which command the operator happened to run last: `collect` (fine) then
`offline` (5) then quit would report 5, though the session did exactly what was asked. So: **0** for a normal
departure, the refusal code if it could never start, **1** if it broke. The individual commands' codes appear in
the transcript, where a human reads them.

**The status line carries capability and steering, not the environment.** *(Implemented in ADR-0039.)* The proposal was machine state plus the
stick path. The reference's always-visible row instead carries the current mode and the keys that change it
(`auto mode on (shift+tab to cycle) · esc to interrupt · ← for agents`) — nothing about the environment. That is
the right way round: what never changes belongs in a header drawn once, not in a row redrawn 1836 times. The stick
path never changes and eats width. What does belong there for Loki is **which engine is answering right now**,
because that genuinely changes mid-session — free some RAM and the offline agent appears, which is the reason #133
recomputes state every round in the first place.

## Correction (2026-08-31): the break mark was the wrong character, for the wrong kind of reason

This ADR claimed U+00B6, the pilcrow, "exists in both code pages measured on the target (CP850 0xF4, CP437 0x14)".
CP437 does carry a pilcrow *glyph* at 0x14 — the claim came from a code-page chart — but .NET maps 0x14 to U+0014, the
control character, so the round trip comes back changed and the console shows something else. Measured with
`Test-LokiEncodingSupport` while building ADR-0039:

| | CP850 | CP437 | CP1252 | UTF-8 |
| --- | --- | --- | --- | --- |
| U+00B6 pilcrow | ok | **fails** | ok | ok |
| U+00AC not sign | ok | ok | ok | ok |

The default in `Format-LokiLineView` is now **U+00AC**, and the live callers take theirs from `Get-LokiSessionChrome`,
whose test round-trips every mark through both code pages — which is what caught this.

The general lesson is the part worth keeping: **a glyph in a code-page chart is not the same claim as a character an
encoder will produce.** Only a round trip separates them, and `Test-LokiEncodingSupport` was written for exactly that
in #121 and then not used here.

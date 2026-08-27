# ADR-0037: Reading the keyboard, and what each key is allowed to mean

Status: Accepted (2026-08-27)

Slice 2 of the UI rebuild in #133, sitting beside ADR-0036's owned screen. Every rule below was measured on a real
console before it was written; where a rule could not be measured, that is said out loud rather than smoothed over.

## Context

The reference CLI enables bracketed paste (`ESC[?2004h`) and receives a pasted block delimited. `[Console]::ReadKey`
cannot see that, because the ConPTY has already turned the paste into keystrokes before PowerShell is involved. So
everything a line editor needs — is this text or a command, did the operator type it or paste it, may this Enter
submit — has to be reconstructed from three facts per key and their arrival pattern.

Two probe runs on the maintainer's machine (Windows 11 10.0.26200, WinPS 5.1.26100.8875, ConsoleHost, code page
850, German layout 1031, 209×51) produced the numbers this file is built on.

### A single `Read-Host` hands Ctrl+C back to PowerShell

| step | measured |
| --- | --- |
| set `TreatControlCAsInput = $true`, read back | `True` |
| **after one `Read-Host`** | **`False`** |
| set again, then read Ctrl+C | `Key=C Char=^C Code=3 Mod=Control` — delivered, the script lived |
| `Read-Host`, then Ctrl+C **without** setting again | the process died |

The first probe found this by accident: it reported `Strg+C uebernommen: True` in its first phase, then died at the
Ctrl+C prompt six phases later, having called `Read-Host` once in between. The report survived because `finally`
ran and `catch` did not — which is exactly how a PowerShell pipeline stop behaves, and is itself worth knowing.

### AltGr reports itself as Ctrl

```
@   Key=Q        Char='@'  Code=64    Mod=Alt, Control
[   Key=D8       Char='['  Code=91    Mod=Alt, Control
\   Key=Oem4     Char='\'  Code=92    Mod=Alt, Control
|   Key=Oem102   Char='|'  Code=124   Mod=Alt, Control
ue  Key=Oem1     Char=252  Mod=0
ss  Key=Oem4     Char=223  Mod=0
```

A reader that treats "Control is set" as a shortcut swallows `@`, `[`, `\` and `|` — every one of which occurs in
paths and commands, on the keyboard this project is actually built on.

### Pasting is separable from typing, and not primarily by time

| | typing | pasting a 3-line block |
| --- | --- | --- |
| keys | 23 | 61 |
| gap, min | **74.33 ms** | 0.08 ms |
| gap, median | 171.91 ms | 0.12 ms |
| gap, max | 470.66 ms | **3.05 ms** |
| next key already waiting when this one was read | **0 of 23** | **59 of 61** |

The two paste exceptions are the first key (no predecessor) and the last (nothing follows it). Line breaks inside a
pasted block arrive as **CR only, never LF** — 2 Enter keys for 3 lines.

### Resize is not announced

Dragging the window from 209×51 to 75×30 while a key read was pending: `ReadKey` returned normally, and the new
size was visible **only after** it returned.

## Decision

**`KeyChar` decides what a key means. `Modifiers` is reported and never consulted.**

```
13 -> enter    8 -> backspace    27 -> escape    9 -> tab
>= 32 and != 127 -> text
 > 0            -> control  (with a letter: 1 -> a, 3 -> c, 21 -> u, 23 -> w)
   0            -> key      (arrows, Home, End, Delete: nothing but a name)
```

`KeyChar` is primary rather than a convenience: it is the only rule that also holds for layouts nobody here has
measured. The editing keys are claimed by name before the chord rule, because Backspace is not Ctrl+H to an
operator whatever the code says.

**`TreatControlCAsInput` is asserted immediately before every read, not once at open.** That is the only form that
survives a stray `Read-Host` anywhere else in the codebase, now or later. `Close-LokiKeyread` restores the value
`Open` found rather than assuming it was off — it was `False` on every console measured, and assuming that is how a
tool leaves a machine changed.

**Loki calls `Read-Host` nowhere inside a session.** This is a property of the file, not of one function.

**Paste is detected by "was the next key already waiting", with the gap as a backstop.** The primary signal was
perfect over 84 measured keys and needs no threshold, so it cannot drift on a slow machine — and the machine this
runs on is by definition a broken one. The backstop threshold is **20 ms**, deliberately not the 38.7 ms midpoint
of the measured gap: it sits 6.5× above the slowest measured paste interval and 3.7× below the fastest measured
keystroke, because the two mistakes are not equally bad. Calling typing "paste" swallows the operator's Enter and
the CLI feels broken; calling a paste "typing" submits one line early, which is annoying and recoverable.

**Escape and Ctrl+C are different keys with different jobs**, copied from the reference:

| key | effect |
| --- | --- |
| Escape | interrupts the running work; the session stays |
| Ctrl+C ×1 | arms, and says so on the hint line |
| Ctrl+C ×2 | leaves the session |

One press exiting is the terminal norm and this breaks it on purpose: a session holds a diagnosis in progress, and
a reflex keystroke should not throw it away. Measured in the reference's own output — a grey
`Press Ctrl-C again to exit` drawn at row 51 column 3 with `ESC[K` after it, so it replaces the standing hint
rather than joining it, followed by teardown on the next press.

**Any other key disarms.** The reference's stream cannot say whether it disarms on a keystroke or on a timer — only
its output was recorded, not its input — so this takes the safer reading. A Ctrl+C from ten minutes ago must not
end the session on the next one.

## Consequences

- The session loop re-reads the console geometry after every key and rebuilds the screen model when it changed.
  Nothing will tell it.
- Ctrl+C becomes an ordinary key rather than a pipeline stop, so leaving the alternate screen goes through the same
  `Close-LokiScreen` path as any other exit instead of relying on a `finally` surviving a stop.
- The armed warning is prose for the operator, so it is a catalog key in every locale (CLAUDE.md §10), drawn on the
  hint row in one write.
- The dispatcher gains `Initialize-LokiKeyread` and `Close-LokiKeyread` beside the screen's pair. Nothing reads keys
  yet; the teardown is wired first on purpose, because leaving Ctrl+C claimed would mean the operator's shell no
  longer stops on it.
- `Read-LokiKey` reports `Modifiers` even though no decision uses it. A later feature may need to tell AltGr from a
  real chord for its own reasons, and throwing away a measured fact to keep an interface tidy is how the next
  measurement gets skipped.

## What is still not known

- **Whether the reference disarms Ctrl+C on a keystroke or on a timer.** Only its output was captured. Settling it
  needs an input capture with timestamps.
- **A second writer to the console during a repaint** — open decision 3 in #133, unmeasured, and it gates whether
  `chat` and `offline --agent` may run inside a session at all.
- **Windows 10.** No machine was available. The capability gate refuses rather than assumes, but the refusal path
  has never run on a machine that needs it.

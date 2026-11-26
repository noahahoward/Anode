# Hardware View — design

Status: the owner approved the interactive mockup on 2026-11-22 ("ready to build into anode"). The mockup is the visual
blueprint: https://claude.ai/artifact/U27znw97cYGaR2uPi8naRF (private). This document records what it means for the code.

## Intent

Make the Mac itself the dashboard. Every reading sits on the part it describes: fan speed in the fan hub, CPU and GPU
temperature on the heat pipe, memory on the memory, storage on the NAND, battery readings on the battery cells, power in at
the port, display readings on the screen. No detached cards. If a reading has no physical home, it does not belong here.

## Goals

- A tab in the main window's left sidebar (⌘6), offered only on Macs with a known layout. (It was first built as a Beta feature with its own window; the owner moved it into the app on 2026-11-23.)
- A data-driven layout per Mac family, so adding a model is adding data, not drawing code.
- Only real readings, each marked real, estimate or example. Nothing is invented to fill a space.
- Efficiency first: no timers of its own, redraw only when the window is drawable, repaint only what changed.

## Non-goals

- No per-core, per-die or per-cell figures that macOS does not expose (see Honesty rules).
- No Wi-Fi signal strength, no display temperature, no per-core GPU load.
- No new polling subsystem. Everything comes from what the sampling tick already reads.
- The CPU/GPU die view is a separate feature (its own spec and release), not part of this one.

## Anti-goals (a failure even if it works)

- A conventional dashboard with a laptop picture beside it.
- Any estimate shown as a measurement, or a guess shown to look complete.
- The window costing noticeable CPU or battery while open.

## Approach (chosen)

Native AppKit, custom `draw(_:)`, in the Memory Watch pattern: a pure model in PowerKit, a thin AppKit view, a controller with
injected closures, a runtime that wires the real parts only when the setting is on. Rejected: embedding the mockup in a
WKWebView (extra processes and GPU use, against Anode's efficiency rules and its hand-drawn AppKit architecture).

## Honesty rules (from the research)

| Reading | Source | Marked |
|---|---|---|
| Fan rpm, min, max | SMC fan keys already read | real |
| CPU and GPU temperature | SMC `Tp*` / `Tg*` means and peaks | real (a mean, never "per core") |
| Memory use, pressure, swap | existing memory readers | real |
| Network down/up | existing per-interface throughput | real |
| Storage free, read/write, SMART | existing readers | real |
| Battery %, temperature, current, health, cycles | `Battery.State` | real |
| Time to full or empty, rates | Anode's estimates | estimate |
| Power drawn from the adapter | derived | estimate (≈) |
| System draw | SMC `PSTR` | real |
| Display power | `PDBR` where identified, else the brightness model | real or estimate |
| Display brightness | `DisplayBrightness` | real |
| Graphs for temperature, fan, display | in-memory ring buffer, empty when the window opens | real, "since you opened this view" |

The battery pack gives one reading for the whole pack. Each reading is drawn on the cell it belongs with, and the detail says
it is a pack reading. Heat-pipe halves: which half is CPU and which GPU follows the die layout and is marked inferred.

## Layout data

`HardwareLayout` (PowerKit): components with a kind, a normalized rectangle or path in the picture's own coordinates, a
confidence (`verified` or `inferred`), and a binding id. Chosen by `HardwareFamily`, resolved from `hw.model` plus chip tier,
then checked against the real fan count (a real reading always overrides the drawing). Unknown models get a plainly labelled
generic schematic. Families for v1: MacBook Pro 14/16 Pro/Max, MacBook Pro 14 base chip (one fan, shorter pipe), MacBook Neo
(fanless), Mac mini M4, generic fallback. M5 Pro / this Mac is `Mac17,9`.

## Picture

The MacBook Pro layout uses a CC0 teardown photo (Netha Hussain, Wikimedia Commons) of an Intel 16-inch MacBook Pro, straightened
to a true rectangle. It is a stand-in and the window says so. Overlay positions are stored in the original photo's pixels and mapped
through the stored straightening (two-step: a homography, then a right-wall correction). Memory and storage are placed from a real
Apple silicon 14-inch photo kept only as a private reference. Other layouts are drawn, not photographed. The straightened
photo and the numbers are in the mockup source; the build script that made it is in the session notes and is reproducible
from the CC0 original.

## Interaction

Hover shows a compact detail (what, value, real/estimate tag, short note). Click pins it beside the part. Fan sliders appear under
each fan when the root helper is installed, and become a quiet install prompt when it is not. Blades turn only while the window
is visible and unoccluded, at a capped rate, at a speed scaled from rpm, stopped at 0 rpm, and not at all with Reduce Motion.
Narrow windows jump between components instead of shrinking text.

## Constraints

CLAUDE.md applies: version bump, CHANGELOG, UPDATE-NOTE, tag and release only when the owner says push; no tests or push
before that; the full suite must pass before a push. Subagents only edit and run on Sonnet; one implementer, one reviewer; one
combined build and test at the end. Work happens on branch `hardware-view` in the worktree `Anode-hardware-view`, cut from
`origin/main` (v1.27.2), so it never mixes with the unrelated work in the main checkout.

## Left to the builder

Window size and chrome, exact fonts and spacing (follow `Palette`), the SVG-path to `NSBezierPath` helper for the Apple logo,
how the menu bar and desktop in the display are drawn, and cache layout of the picture.

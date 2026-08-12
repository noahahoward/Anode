# Anode

A macOS power monitor that reports per-app battery cost in **real, absolute units** —
not Activity Monitor's unitless, relative "Energy Impact" score.

## Why

Activity Monitor's Energy Impact is a heuristic weighted sum, not a measurement. Its
coefficients are visible in `/usr/share/pmenergy/`:

```
kcpu_time = 1     kgpu_time = 4.4     kcpu_wakeups = 0.0002
```

A GPU-second is *defined* as 4.4× a CPU-second. The number has no unit, cannot be
compared across machines, and Apple's own developer support declines to give it one.
It is also relative: quit a heavy app and every other app's number changes, though
nothing about their behaviour did.

Anode measures joules instead.

## How

| Source | Provides | Privilege |
|---|---|---|
| `proc_pid_rusage` V6 → `ri_energy_nj` | Per-process energy in **nanojoules**, from the kernel | none (same-uid only, ~63% of pids) |
| SMC `PSTR` | Whole-system watts, updates on every read | none |
| `AppleSmartBattery.PowerTelemetryData` | Authoritative 60 s mean, used to correct PSTR's gain | none |
| IOReport `Energy Model` | Per-rail energy (on this M5, GPU only) | none |
| `systemstats` `CoalitionUsage` | Root-owned processes, per-app GPU, history | none |

Units displayed: **%/hour**, **10 hr power** (% of battery over a trailing on-battery
window), and **minutes of runtime cost**. Watts are measured internally and never shown.

## The invariant

```
Σ app energy + display + radios + storage + kernel + residual  ≡  measured total
```

Rows sum to a **measured** total and the residual is **printed, never redistributed**.
Showing that honestly is the point.

The unidentified remainder started at 85–95% and is now, measured across 494
windows on the development machine, **1.94 W median (2.7 %/hr)** — about a third
of an idle machine. Naming display, memory, storage, USB and the root-owned
processes is what moved it.

**It is a floor, not a share, and that is the thing worth understanding.** Under
an all-core load the whole-system total rose 10.7 W while the remainder rose
0.4 W; at the busiest moments it reaches zero. So it is roughly constant power —
~38% of an idle machine and ~0% of a busy one — and it looks dominant at idle
precisely because everything else has been driven down around it.

What is left has been attacked and holds: the display rail is complete to 3%
(of 39 rails, only `PDBR` tracks brightness); the remainder *falls* as CPU rises
(r = −0.33), so it is not unmeasured CPU; ~0.3 W is converter loss, which is
inside the measured total but in no load-side rail and therefore irreducible by
construction. Two independent estimates of the floor agree: 2.34 W by regression
across load, 2.25 W from the brightness-sweep intercept.

## Build

```
./build-app.sh          # produces Anode.app
open Anode.app
```

CLI, for diagnostics:

```
swift build
./.build/debug/anode -w 5 -n 15     # one-shot report
./.build/debug/anode --watch -w 2   # live
./.build/debug/anode --smc          # SMC power sensor discovery
```

Handing it to someone else to test: see [TESTING.md](TESTING.md). Short version —
send the repo, not a `.app`, and expect a larger unattributed share on hardware
this was not calibrated on.

## Requirements

macOS 13+ (Apple Silicon), Xcode 26. The app is **not sandboxed** — App Sandbox denies
`process-info-listpids`, which is required to enumerate processes. It therefore cannot
ship on the Mac App Store.

## Attribution

Battery IORegistry key semantics and SMC decoding informed by
[exelban/stats](https://github.com/exelban/stats) (MIT, © 2019 Serhiy Mytrovtsiy).

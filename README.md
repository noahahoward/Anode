# BetterStats

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

BetterStats measures joules instead.

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
On an idle machine the unattributable share is large — often 85–95% — because display
backlight, radios and root-owned processes dominate. Showing that honestly is the point.

## Build

```
./build-app.sh          # produces BetterStats.app
open BetterStats.app
```

CLI, for diagnostics:

```
swift build
./.build/debug/betterstats -w 5 -n 15     # one-shot report
./.build/debug/betterstats --watch -w 2   # live
./.build/debug/betterstats --smc          # SMC power sensor discovery
```

## Requirements

macOS 13+ (Apple Silicon), Xcode 26. The app is **not sandboxed** — App Sandbox denies
`process-info-listpids`, which is required to enumerate processes. It therefore cannot
ship on the Mac App Store.

## Attribution

Battery IORegistry key semantics and SMC decoding informed by
[exelban/stats](https://github.com/exelban/stats) (MIT, © 2019 Serhiy Mytrovtsiy).

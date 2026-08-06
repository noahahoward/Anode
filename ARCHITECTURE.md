# Architecture

Everything here was verified on the target machine (Mac17,9 / M5 Pro / macOS 27.0 / arm64).
Where a number appears, it was measured, not looked up.

---

## 1. Why not just use Energy Impact

Activity Monitor's "Energy Impact" is a weighted heuristic, and its coefficients are
sitting in the filesystem at `/usr/share/pmenergy/`:

```
kcpu_time = 1          kgpu_time = 4.4        kcpu_wakeups = 0.0002
kqos_background = 0.74 kdiskio_bytesread = 1.4e-08
```

Three consequences:

- **It has no unit.** Every coefficient is seconds-per-something. The output is
  charged-seconds per wall-second, and Apple's developer support explicitly declines
  to define it as a physical quantity.
- **It is blind to the GPU on Apple Silicon.** `kgpu_time` is 0 in the fallback
  plist, and all 35 shipped plists are Intel board IDs — there is no `Mac17,9` entry.
- **It is relative.** Quit a heavy app and every other app's number rises, though
  nothing about their behaviour changed.

The original design sketch for this project was to sum those scores and normalize
them against the OS time-remaining estimate. Three independent reviews rejected it,
and the reasons survive even if the score were perfect:

| Problem | Detail |
|---|---|
| Non-conservation | Apps are a minority of draw. Display, radios, SSD and kernel belong to no pid. Forcing rows to sum to 100% smears that onto apps, and the error is *worst when apps are quiet*. |
| Circularity | `AvgTimeToEmpty` ≡ RemainingCapacity / AverageCurrent. Normalizing to it returns the pack current you already had. |
| Sentinels | On AC, `TimeRemaining` and `AvgTimeToEmpty` both read `65535` — the SBS "unknown" value. The anchor is absent most of the time. |
| Arithmetic | For a load consuming fraction `f` of a battery over time `T`, runtime is `T / f`, not `T − (f−1)T`. The subtractive form goes negative at `f ≥ 2`. |

What survives from the original idea is the *unit*: percent-of-battery is genuinely
good, but only as an **energy measure over a named window**, never as a share of an
instantaneous score.

---

## 2. The measurement stack

| Layer | Source | Privilege | Cadence |
|---|---|---|---|
| Per-process energy | `proc_pid_rusage(RUSAGE_INFO_V6)` → `ri_energy_nj` | none, same-uid | every tick |
| Whole-system power | SMC `PSTR` | none | every read |
| Ground truth | `AppleSmartBattery.PowerTelemetryData` | none | ~60 s batches |
| GPU energy | IOReport `Energy Model` / `GPU Energy` | none (private API) | every tick |
| Root-owned processes | `systemstats` `CoalitionUsage` | none | ~30–60 s |

### `ri_energy_nj` — the reason this project is possible

The kernel already accounts energy per task in nanojoules (`kern.pervasive_energy = 1`).
No unit needs inventing. Measured coverage: **~63% of pids readable, 37% EPERM** —
every root-owned process, including `WindowServer` (uid 88), which does all window
compositing and is routinely the largest real consumer.

Two traps, both of which shipped as bugs before being caught:

- The counter is **cumulative since process start**. Treating a process missing from
  the prior sweep as starting at zero attributes its *entire lifetime energy* to one
  2-second window — an enormous phantom spike at the top of the table. Processes are
  now skipped until they have two samples.
- **PIDs are reused.** Identity is `(pid, ri_proc_start_abstime)`, never pid alone.

### SMC — the live anchor

`PSTR` reports whole-system watts and updates on every read, unlike the gas gauge's
60-second batches. Validated against the gauge over one window:

```
PSTR mean over 61s : 5.280 W  (n=61, min 4.24, max 17.90)
gas gauge mean     : 4.681 W  (59 ticks)
ratio              : 1.128
```

A stable offset, so it is corrected as a **gain**, with the gauge demoted to
calibrating it rather than being the anchor itself.

> **Implementation trap.** The SMC request must be an explicit **80-byte buffer**.
> The natural Swift struct translation lays out as **76 bytes**, and
> `IOConnectCallStructMethod` rejects it with `kIOReturnBadArgument` (0xe00002c2).
> Swift does not guarantee C layout for nested structs.

### IOReport — mostly dead on this silicon

Published guidance (asitop, macmon) assumes the `Energy Model` per-core rails work.
On M5 they do not. Of **11,541 channels, exactly one energy channel is live**:
`GPU Energy` (nJ). All 308 mJ per-core PMGR rails — `PACC_*`, `MCPU*`, `CPU Energy`,
`DRAM0`, `DISP0`, `ANE0` — carry unit labels and **delta to zero**.

The sampler therefore *discovers* live rails at runtime rather than hardcoding a list,
so it picks up more on M1/M2/M3 with no code change.

> Units are mixed **within one group**: 308 mJ, 5 µJ, 1 nJ — and `GPU0` is mJ while
> `GPU Energy` is nJ. `IOReportChannelGetUnitLabel` is read per channel. A hardcoded
> divisor would be wrong by 10³–10⁶, silently.

---

## 3. Sensor fusion

Three signals with incompatible characteristics have to become one number.

```
gas gauge    accurate, whole-machine, 60 s mean published once a minute
rusage       every tick, real joules, our-uid CPU only (~27% of total draw)
SMC PSTR     every read, whole-machine, ~13% systematic gain
```

**The mistake worth recording.** The first fusion attempt was multiplicative —
`total = k × fast`, with `k ≈ 3.6` learned from the gauge. It says every watt of
display, Wi-Fi and kernel power scales with CPU activity, which is false. Result:

```
tick  raw_fast  gauge    smoothed   jump
  41    19.874  32.876     34.678
  42    16.983  32.876     60.045   JUMP
  43    10.671  32.876     58.695
  44     5.940  32.876     35.674   JUMP
```

±3 W of ordinary CPU jitter became a 29→60 W swing.

The fix is **additive**, because the invisible part is roughly constant:

```
baseline = gauge − fast          (display, radios, SSD, kernel)
estimate = baseline + fast       (responds instantly to app activity)
```

Same jitter now passes through at 1:1. Measured over ~50 ticks afterwards:

| Signal | Range | Swing |
|---|---|---|
| Raw fast | 5.17 – 11.19 W | 2.16× |
| Raw gauge | 32.86 – 39.91 W | 1.21× |
| **Displayed** | **33.77 – 35.16 W** | **1.04×** |

Multiplicative gain remains correct for `PSTR` specifically, because that signal
already measures the whole machine — scaling it amplifies nothing.

### Anchor priority

```
1. SMC PSTR, gain-corrected     measured, whole machine, every tick
2. baseline + fast              inferred, when SMC is unavailable
3. the gauge itself             accurate but 60 s stale
4. raw fast                     partial, last resort
```

---

## 4. The ledger invariant

```
Σ app energy + GPU + display + radios + storage + kernel + residual  ≡  measured total
```

Rows sum to a **measured** total. The residual is **printed, never redistributed**.

On an idle machine the unattributable share is large — commonly 85–95%, since display
backlight and root-owned processes dominate. Activity Monitor hides this by presenting
app scores as if they were the whole story. Showing it plainly is the point of the
project, not a limitation of it.

Every row carries a provenance flag: `measured` / `modeled` / `derived`.

---

## 5. Identity and rollup

A browser fragmented across nine processes looks cheap in every individual row while
being expensive in aggregate — backwards from what a user needs in order to decide
what to quit. Processes roll up to the **outermost `.app` ancestor** of their
executable path:

```
/Applications/Brave Browser.app/Contents/Frameworks/…/Brave Browser Helper.app/…
  → /Applications/Brave Browser.app          → "Brave Browser"     (12 processes)
/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/…
  → /Applications/Visual Studio Code.app     → "Visual Studio Code" (14 processes)
/usr/libexec/contactsd
  → no bundle                                → "contactsd"          (daemon)
```

Taking the *innermost* bundle gives "Brave Browser Helper" — the bug this replaced.

> Names come from `FileManager.displayName`, **not** `Info.plist`. VS Code sets
> `CFBundleName`, `CFBundleDisplayName` *and* `CFBundleExecutable` all to `"Code"`;
> Brave sets `CFBundleName` to `"Brave"`. Finder shows the bundle filename, and that
> is what a person recognises.

---

## 6. Display units

Per explicit product decision: **%/hour**, **10 hr power** (percent of battery over a
trailing on-battery window), and **minutes of runtime cost**. Watts are computed and
stored internally and **never shown**.

```
%/hr          = 3600 × W / joulesPerPercent
10 hr power   = Σ_window(joules) / joulesPerPercent      over ON-BATTERY time only
runtime cost  = 60 × E_remaining × (1/(P_sys − P_app) − 1/P_sys)
```

The battery scale is seeded from `FullChargeCapacity` (not `DesignCapacity`, so an
aged pack reports honestly) and then self-calibrates: `J_per_% ← EWMA(E_sys / ΔSoC%)`,
which removes the assumed nominal voltage entirely and tracks aging.

This machine: 6197 mAh full charge → **1% ≈ 2,588 J**, **1 W ≈ 1.39 %/hr**.

---

## 7. Observer effect

The instrument must not be a significant entry in its own ledger. It briefly was —
`proc_pidpath` was being called twice per process per tick, once for the name and once
for the app rollup, which put `BetterStats` at the top of its own table. The path is
now captured once per sweep and reused.

For scale, `top` has been measured at 6.9–18.1% of its own denominator.

---

## 8. Distribution

The app **cannot be sandboxed**: App Sandbox denies `process-info-listpids`, and Apple
DTS confirms no entitlement lifts it. That permanently closes the Mac App Store
(guidelines 2.4.5(i), 2.5.1 public-APIs-only, 2.4.5(v) no root escalation).

Path is Developer ID + notarization + Sparkle, optionally a Homebrew cask. Locally the
bundle is ad-hoc signed, which may block `SMAppService` privileged daemon registration
until a real signing identity exists.

`libIOReport` is Apple-signed and dlopens without `disable-library-validation`. It is
not on disk — it resolves only from the dyld shared cache, so `FileManager.fileExists`
returns false and it must be probed with `dlopen`.

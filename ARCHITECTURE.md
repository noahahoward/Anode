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
time to empty = (charge% / rate%hr) × V̄_remaining / V_now
```

### Time to empty projects constant POWER, not constant current

The SoC rails are buck converters, so a load holds watts. As the pack empties
its voltage falls, so the current rises to hold that power, so the charge runs
out **sooner** than `charge ÷ rate` predicts. The honest form is
`T = (1/P)∫V dQ`, which is that division scaled by `V̄_remaining / V_now` —
implemented as `BatteryScale.constantPowerFactor`.

That factor is a **ratio of two points on one curve**, so every absolute scale
cancels — cell count, nominal voltage, capacity, units. It needs the discharge
curve's SHAPE and nothing else, which is why it ports where the voltage seed
below does not.

It is state-dependent, and no single constant can replace it:

| state of charge | estimate reads |
|---|---|
| 78 % | 7.1 % long |
| 50 % | 3.2 % long |
| 20 % | 1.8 % long |

Measured on this machine 2026-08-21 over a 6504-sample run-down from 77.8 % to
12.0 % (`measurements/2026-08-21-rundown.csv.gz`). Slopes: 26.8 mV per SoC point
above 45 %, 12.8 across the 20-45 % plateau, 19.7 into the knee below 22 % — so
a straight line, which two data points would have suggested, is wrong by more
than a factor of two depending on where you stand.

> **The bottom is extrapolated.** The run stopped at 12 % and the pack is
> charge-limited to 80 %, so neither end was reached. A usable-capacity floor —
> the charge at which this machine actually sleeps — has **never been observed**:
> `BatteryShutdownReason.ShutDownTimestamp` reads 0 and `pmset` has no
> low-battery event on record. The floor therefore ships as **0**, which is an
> absent measurement rather than a measured zero.

> **The gauge is not a cross-check on any of this.** `TimeRemaining` is
> `RemainingCapacity / AvgCurrent` to within 1 % — verified live: 3953 mAh over
> 325 min implies 729.8 mA against a measured 739. It makes exactly the constant
> current assumption corrected above, so agreeing with it would mean reproducing
> its error. Anode now reads deliberately shorter than the pack's own estimate.

The battery scale is seeded from `FullChargeCapacity` (not `DesignCapacity`, so an
aged pack reports honestly) times an **assumed nominal voltage of 11.58 V**
(`BatteryScale.seedNominalVoltage_V`).

> **NOT IMPLEMENTED, and this doc previously claimed otherwise.** The design calls
> for the scale to self-calibrate — `J_per_% ← EWMA(E_sys / ΔSoC%)` — which would
> remove the assumed voltage entirely and track pack ageing. It does not exist.
> Every `BatteryScale` in the code is constructed with `isCalibrated: false`, and
> that flag is currently the only trace of the idea.
>
> It sits underneath %/hr, 10 hr power and runtime cost. A pack whose true
> nominal voltage differs from 11.58 V is wrong by that ratio, uniformly and
> invisibly — nothing on screen would look odd. It is a systematic scale error,
> not noise, so it does not average out.
>
> **THIS DOC USED TO ADD "and time to empty" TO THAT LIST, AND THAT WAS WRONG.**
> Trace the shipping `.discharge` path: `remainingPct = mAh / full × 100` and
> `trendRate = current_mA / full × 100`, so `full` cancels exactly, and
> `current_mA` divides by the **measured** window-mean voltage rather than the
> seed. Time to empty is independent of both `nominalVoltage_V` and
> `FullChargeCapacity`. Implementing the calibration above would move most of the
> app's numbers and would not move that one at all — so it is the wrong lever for
> any complaint about time remaining, and the constant-power correction above is
> the right one.
>
> On this machine the seed is close to right (the gauge's own time-to-empty agrees
> with the mAh basis to a few percent). On a different pack — another machine,
> an older battery — this is unchecked. Until this lands, treat cross-machine
> comparisons of absolute %/hr with suspicion; comparisons WITHIN one machine are
> unaffected, since the same constant divides everything.
>
> **Two different flags are both called `isCalibrated`, and they mean unrelated
> things.** `BatteryScale.isCalibrated` is the one above and is always false.
> `PowerMonitor.Snapshot.isCalibrated` — the one the CLI prints and the one the
> "*" in the menu bar reflects — is the SMOOTHER's baseline calibration
> (`Smoother.baselineW != nil`), which says whether the fast signal has been
> anchored to the gas gauge yet. That one does work. Do not read a "calibrated:
> yes" anywhere as evidence that the pack voltage has been measured.

This machine, as first written: 6197 mAh full charge → 1% ≈ 2,588 J, 1 W ≈ 1.39 %/hr.
Re-read 2026-08-22 at 25 cycles: **5,972 mAh** → **1% ≈ 2,489 J**, **1 W ≈ 1.45 %/hr**.
The pack has aged 3.6 % since, which is also why the gap between the mAh basis and
the integer `CurrentCapacity` has widened from the "1-2 points" quoted above to
**3.5-5 points** (measured: 77 % integer against 73.2 % on the mAh basis). Any
figure in this document with a capacity in it is a snapshot, not a constant.

---

### Time to empty looks further ahead than the last hour

Every tier above measures what the machine has been doing: the mean drain since
the lid opened, a regression, or the draw right now. That is honest, but it is
a claim that the next ten hours will look like the last one. A render drags the
mean up for the rest of the session, a quiet stretch makes an evening look
endless, and just after unplugging there is nothing to go on at all.

`LifetimeDrainModel` (`Sources/PowerKit/LifetimeDrain.swift`) learns two things
over the machine's life on battery, and `forecastTimeToEmpty` combines them with
the load now:

- **Where this machine settles.** A time-weighted mean of battery-side watts,
  stored in watts (not %/hr, which drifts as the pack ages). Old data fades with
  a 30-day half-life, and every macOS update starts a new baseline; the previous
  one answers until the new one has two hours behind it. Within a session, the
  target is pulled toward the session's own non-heavy level, halfway after an
  hour, so a long evening that is consistently lighter or heavier than usual
  gets to speak for itself.
- **How long a departure lasts.** Stretches above or below normal are timed:
  one learned length per side, plus one per app when an app dominated at the
  start. An unlearned heavy load is assumed to continue, and one that has
  outlasted its history is expected to go on at least as long again, so a long
  render converges to "the current load continues".

The forecast is `rate(t) = b + (c − b)·e^(−t/τ)`, solved for the moment the %·hr
spent equals the charge. The constant-power factor is applied once, to that
budget. With no excursion it is exactly `timeToEmpty`. Replayed against a
simulated pack on the measured curve (`LifetimeReplayHarness`), mean error drops
from 3.1 to 0.2 min for a sustained render, from 13.6 to 8.8 for bursty use,
and from 69 to 46 for idle → render → idle. It ties (21 min) for a typical day.

It persists to `lifetime-drain.json` beside the discharge trend, on the same
120 s cadence and on quit. A file from a different Mac (by `hw.model` and design
capacity) is refused, because Migration Assistant copies Application Support
wholesale.

## 7. Observer effect

The instrument must not be a significant entry in its own ledger. It briefly was —
`proc_pidpath` was being called twice per process per tick, once for the name and once
for the app rollup, which put `Anode` at the top of its own table. The path is
now captured once per sweep and reused.

For scale, `top` has been measured at 6.9–18.1% of its own denominator.

---

## 8. SSD health, and the endurance model that had to be deleted

### SMART is on the child node, not the controller

"SMART is unavailable on Apple Silicon" is widely believed and wrong. The log
page is one node lower in the registry than everybody looks. Measured, opening
`kIONVMeSMARTUserClientTypeID` on each candidate:

| Node | Class | `IOCreatePlugInInterfaceForService` |
|---|---|---|
| controller | `AppleANS3CGv2Controller` | `0xe00002c7` `kIOReturnUnsupported` |
| namespace | `IOEmbeddedNVMeBlockDevice` | `0x00000000` |
| namespace | `IONVMeBlockStorageDevice` | `0x00000000` |

**Apple documented this in the public header the whole time.** `kIOPropertyNVMe`
`SMARTCapableKey`, in `NVMeSMARTLibExternal.h`, exists — in the header's own
words — to find NVMe SMART capable devices *"without hardcoding the search to a
particular device class"*. That sentence is the answer to the myth, shipped in
the SDK. Measured: exactly **one** node in the entire IORegistry publishes the
key, the namespace node, where it reads `Yes`; it is absent from
`AppleANS3CGv2Controller` entirely, which is the same story the return codes
tell from the other end.

```
+-o NS_01@1  <class IOEmbeddedNVMeBlockDevice>
    "NVMe SMART Capable" = Yes
    "IOCFPlugInTypes" = {"AA0FA6F9-C2D6-457F-B10B-59A13253292F"="NVMeSMARTLib.plugin"}
```

It is used as a **precondition**, never as the measurement: the property is the
device's claim about itself, the 512 bytes are the fact.

> **The two class names are one device.** `IOEmbeddedNVMeBlockDevice` is a
> *subclass* of `IONVMeBlockStorageDevice`, and `IOServiceMatching` matches
> subclasses, so matching both names returns registry entry `0x100000d3a`
> **twice** — one node, one drive, found from two directions.
> `ioreg -c IONVMeBlockStorageDevice` and `ioreg -c IOEmbeddedNVMeBlockDevice`
> print the identical node. Candidates are therefore deduplicated by registry
> entry ID and sorted by it, so device selection is deterministic. Both names
> are still matched, because hardware that publishes only the base class exists.
> Skip the dedupe and the drive appears twice, which is how this is rediscovered.

Unprivileged, uid 501, no entitlement, no helper, no `sudo`.

`diskutil info -plist disk0` publishes the same fields under
`SMARTDeviceSpecificKeysMayVaryNotGuaranteed`, which is how the binary field
mapping here was checked against an independent decoder rather than against the
spec alone.

### Cost, and why the read is outside the lock

| | |
|---|---|
| open the user client | 2.46 ms |
| `SMARTReadData`, median, idle | **0.076 ms** |
| `SMARTReadData`, tail, idle | 2.83 ms |
| `SMARTReadData`, ten concurrent `dd` writers | **12.95 ms** |

The open is 33x the median read, so the client is opened once and held. The last
row is the one that shaped the design: 12.95 ms is most of a 16.7 ms frame, and
the latency is **load-dependent** — it is worst exactly when the machine is
busiest, which is when a stalled UI is most visible. So the read happens
**outside the cache's lock**, and §7's rule applies unchanged: the instrument
must not be a significant entry in its own ledger, and a lock held across a
12.95 ms IOKit round trip would make it one.

Robustness, measured rather than assumed: **378,100 `SMARTReadData` calls across
7,562 open/close cycles, half of them under ten concurrent writers, zero
failures**. 1,000 full probe cycles leak **zero** mach ports.

### The cross-check

The single strongest piece of evidence in this section: the drive's own counter
and the kernel's driver counter, which share no code path, agree to within the
quantisation of the drive's counter.

```
DATA_UNITS_WRITTEN  vs  IOBlockStorageDriver "Bytes (Write)"

passive, 21.7 h window
  Δ DATA_UNITS_WRITTEN         44,291,072,000 B
  Δ driver Bytes (Write)       44,290,940,928 B
  difference                          131,072 B    0.26 of one 512,000 B unit

injected 2 GiB with dd + sync
  Δ DATA_UNITS_WRITTEN          2,157,056,000 B
  Δ driver Bytes (Write)        2,156,703,744 B
  difference                          352,256 B    0.69 of one 512,000 B unit

command counts, same passive window
  Δ HOST_WRITE_COMMANDS             2,292,636
  Δ driver Operations (Write)       2,292,636
  difference                                0    exact
```

Both byte deltas land inside one DUW quantum, which is the closest agreement the
counter's own resolution permits. The command counts are not quantised and are
**exactly** equal.

The obvious deflation is that the two are one accumulator read twice. Ruled out
three ways:

| Ruled out | Evidence |
|---|---|
| Different epochs | SMART is lifetime; the driver counter is per boot. They did not reset together at the Aug 31 boot — the driver went to zero and SMART did not. |
| Live hardware behind it | The temperature field in the same log page moved 307 → 309 → 307 K during the window. A mirror of a software counter has no thermistor in it. |
| Mean I/O size | 21,461 B/command before the boot, 21,073 B/command after: the same physical workload straddling an epoch boundary that only one of the two counters survives. |

### The falsified model

Recorded the way §3 records the multiplicative-fusion mistake, because the
failure here is more seductive than that one: it produced the *right answer*.

The original design derived endurance from NAND geometry, all of it read from
the controller's own `Controller Characteristics`:

```
blocks-per-cau                303
cau-per-die                     4
dies  (num-bus × dies-per-bus)  8
pages-per-block-mlc          7704
page-size                   16384 B
────────────────────────────────────────────────────────────
303 × 4 × 8 × 7704 × 16384  =  1,223,851,769,856 B  =  1.2239 TB raw

self-validating:
  32 CAU × 7704 pages × 4 sec-per-page  =  986,112
  = the controller's own "sec-per-full-band" key, exactly

then, the part that was wrong:
  1.2239 TB × 1000 P/E cycles ÷ 2.0 write amplification  =  612 TB
  conventional vendor rating, 1 TB TLC drive             =  600 TBW
```

Two percent from the industry figure, off a geometry that validates against a
key the controller publishes for a different purpose. It was believed for
several days.

**The agreement was numerology.** Vendor TBW is *itself* computed as
capacity × P/E ÷ WAF. Reproducing it from the same three constants is not a
confirmation; it is the same arithmetic run twice. The tell is that the same
constants, applied to other cell types, miss in **opposite directions** —
1.53x high on MLC, 0.51x low on QLC — which is what a formula does when it is
being fitted rather than measured.

**And it is now falsified outright, by this drive.** `percentageUsed` is still
0 at **7.31 TB written** (14,285,870 data units). If the manufacturer's basis
were 612 TB, the integrator would have passed 1 % at 6.12 TB and would read 1.
It reads 0, which bounds the manufacturer's own basis **above 731 TB** — 20 %
higher than the model, from a single reading, with no assumption about P/E or
WAF at all.

So the number was wrong, the method was circular, and the correct value was
sitting in a field the drive already publishes. Nothing in this project
projects endurance any more.

### `percentageUsed` is not fenced to 0–100, and that is deliberate

Every other percent on the page is fenced: `AVAILABLE_SPARE` and its threshold
are integer percents of a quantity that cannot exceed itself, so 101–255 there
is a decode error and the whole page is rejected.

`percentageUsed` is the exception. The spec permits **101–255**, meaning "past
the manufacturer's rated endurance", saturating at 255. An earlier version
rejected the page above 100 — and rejecting returns `nil`, which every caller
renders as *"this machine has no SMART"*. A worn-out drive would therefore have
presented **exactly like an Intel Mac or a VM**.

> An absent measurement and an alarming one must never be the same pixel.

That is the general rule; this is just where it bit. Consumers downstream take a
"percent" that can exceed 100, which is correct, and `alarms(for:)` carries the
raw value through, so a drive at 150 % reports 150.

### POWER_ON_HOURS is not calendar time, and is not a denominator

Same class of trap as §2's IOReport unit labels — a plausible number, in the
right units, meaning something other than what it says.

```
POWER_ON_HOURS                                203 → 204 h      Δ 1 h
wall clock across the same window                              21.9 h
machine awake across it (pmset -g log)                         99.5 %
──────────────────────────────────────────────────────────────────────
controller active-state residency  =  1 ÷ 21.9  =  4.6 % of calendar
```

It is the NVMe controller's own active-state residency, not machine uptime and
not wall clock. Shown unlabelled it reads about **22x low**, and every
derived-per-hour figure built on it inherits that factor silently — exactly the
10³–10⁶ hardcoded-divisor failure §2 describes, only smaller and therefore
harder to spot. It is either labelled precisely or omitted. It is never a
denominator.

### Over-provisioning is against the exposed LBA capacity

An error that was made and caught, worth recording because the wrong
denominator is the one the controller hands you first:

```
raw NAND         1,223,851,769,856 B   geometry above
exposed LBA      1,000,555,581,440 B   IOMedia "Size" = diskutil Size  = 1.00 TB
"capacity" key   1,024,000,000,000 B   Controller Characteristics

OP vs exposed LBA    223,296,188,416 ÷ 1,000,555,581,440  =  22.3 %   CORRECT
OP vs "capacity"     199,851,769,856 ÷ 1,024,000,000,000  =  19.5 %   WRONG
```

`capacity` is a controller-internal figure and is 2.3 % larger than anything the
host can address. Using it understates over-provisioning by nearly three points,
and describing the drive as "1.024 TB usable" — which the first draft of this
feature did — is the same error worn as a label.

### Swap is the wrong headline; the compressor is the right one

Measured on this machine:

| | |
|---|---|
| swapfiles in `/private/var/vm` | **none** — the directory holds only `sleepimage` |
| `sleepimage` | 2 GiB, `hibernatemode 3` |
| `vm.swapusage` total | 1024.00M — a **reservation**, not an allocation |
| swapouts | 16 pages × 16,384 B = 262,144 B since boot |
| compressions | 1,557,253 pages = **25.51 GB absorbed** |
| decompressions | 680,007 pages = 11.14 GB returned |
| compressor pool | 2.42 GB holding 5.88 GB of anonymous memory = **2.427:1** |

The compressor does roughly **97,000x** the byte traffic swap does. A
swap-centric memory display therefore reads as a column of zeros on a healthy
Mac and only starts moving once the machine is already thrashing — an
instrument that is indistinguishable from broken exactly when it is working.

Three further things this measurement settled:

- **The 1024 MB in `vm.swapusage` is a reservation.** No swapfile exists on
  disk. Reporting it as swap in use would be reporting a number with no bytes
  behind it.
- **The 2 GiB `sleepimage` is the largest write in the whole swap family, and no
  swap counter ever sees it.** It is written on sleep, by a different path.
  Anything claiming to total "what the memory system writes to the disk" that
  omits it is wrong by more than everything it includes.
- **Pageins were 58 % of all reads this boot, and they are FILE-BACKED.**
  `swapins` is **0**. Labelling pageins as memory pressure is not wrong by a
  percentage; with a zero denominator it is wrong by an infinite factor.

### Filesystem write amplification is measurable; NAND write amplification is not

APFS publishes both halves per volume, in `AppleAPFSVolume`'s `Statistics`
dictionary:

```
"Bytes written by user"          user-visible writes
"Bytes written to block device"  what actually left the filesystem

window A   ratio 1.234
window B   ratio 1.260
```

That is a **measured** filesystem write amplification, and it **drifts with
workload** — those two windows are the same machine hours apart. It has to be
recomputed live and must never be baked in as a constant; a fixed 1.25 would be
a fitted parameter wearing a measurement's clothes.

**This is not the FTL/NAND write amplification the falsified model used.** That
one is inside the controller: NAND program bytes are not exposed by any
interface reachable from the host, and no amount of filesystem instrumentation
gets at them. It is also now unnecessary — `percentageUsed` is the
manufacturer's own integrator and already has NAND-level amplification baked
into it. The unreachable number is the one we no longer need.

### This is a reassurance surface, not a monitor

Stated plainly, because without it the next person to touch this file will add a
projection and reinvent the 612 TB:

At the **~50 GB/day** measured on this machine, against a manufacturer basis
bounded **above 731 TB**, this drive outlives the machine by a wide margin. More
importantly, neither counter predicts the failure mode Apple silicon SSDs
actually exhibit — controller and logic-board failure, not wear-out. A wear
projection would be a precise answer to a question that is not the one that
kills these drives.

So the section reports state and reports transitions, and it projects nothing.
The alarms it raises are all measured events: a critical-warning bit set,
available spare falling below the drive's own threshold, a media error, or
`percentageUsed` leaving 0 for the first time. Every one of those is something
that **happened**.

---

## 9. Distribution

The app **cannot be sandboxed**: App Sandbox denies `process-info-listpids`, and Apple
DTS confirms no entitlement lifts it. That permanently closes the Mac App Store
(guidelines 2.4.5(i), 2.5.1 public-APIs-only, 2.4.5(v) no root escalation).

Path is Developer ID + notarization + Sparkle, optionally a Homebrew cask. Locally the
bundle is ad-hoc signed, which may block `SMAppService` privileged daemon registration
until a real signing identity exists.

`libIOReport` is Apple-signed and dlopens without `disable-library-validation`. It is
not on disk — it resolves only from the dyld shared cache, so `FileManager.fileExists`
returns false and it must be probed with `dlopen`.

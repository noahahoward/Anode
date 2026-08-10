# BetterStats — reviewed implementation plan

A research pass produced 39 proposals; two independent reviewers (claude-opus-5,
claude-sonnet-5) then went at it adversarially against the live tree. This file
is the plan **after** that review. Where the two disagree, the review wins — it
verified against source, and in three places the original would have shipped a
bug.

Corroboration is noted as `2 of 2` where both reviewers raised something
independently. That is real agreement: neither saw the other's output.

---

## Done

- **`soc` destroyed by compaction** — `downsampleLocked` omitted `soc` from its
  INSERT and then deleted the raw rows, so every sample older than `rawHorizon`
  became NULL and the battery line could only exist for the trailing hour.
  Duration-weighted fold, two regression tests. *(blocking, opus)*
- **CPU lens wrong by 41.667×** — `ri_user_time` is mach absolute time units,
  not nanoseconds. Two display floors sat on it, so a process using 2% of a core
  computed to 0.048% and was filtered out entirely. `MachTime` helper, fixtures
  converted to mach units, floors re-tuned to 2.0 / 0.1. *(P0 #1)*

---

## Corrections the review made to the original plan

Three items would have introduced bugs if implemented as written. Recorded here
because the reasoning matters more than the verdict.

1. **Network wrap — do NOT use bare `&-` at 32-bit width.** It cannot tell a
   counter wrap from an interface *reset*, and resets are routine (VPN cycling
   recreates `utunN`, docking recreates `enN`). A reset from 0.1 GiB to 0 becomes
   a wrapping delta of ~4.2 GiB, which over a 2 s tick prints **2.1 GB/s** into
   the menu bar. Use `if_data64` via `NET_RT_IFLIST2`, which removes the wrap
   instead of compensating for it, and add a plausibility bound.

2. **Sleep gap — drop the interval, do not clamp it.** The original said clamp a
   nine-hour gap to 120 s. That writes a row asserting the machine drew
   pre-sleep watts for 120 seconds it was asleep — fabricated energy, in a store
   whose entire premise is that measured joules add exactly. Every other
   unmeasured quantity here is written NULL specifically so it cannot masquerade
   as measured. Return `interval = 0` and `measured_W = nil`; `record` already
   returns early on `interval <= 0`, so the gap is simply absent, which is true.

3. **Item 8 targets code that does not exist** *(2 of 2)*. Both reviewers
   searched source, git history and the built binary for the "PROBE status item"
   and found nothing — it was scaffolding already reverted before commit. An
   unexecutable item in the first sprint risks a real widget being deleted in its
   place. Struck.

---

## Next, in order

Ordering is load-bearing where noted.

### 1. Network counter wrap — S
`if_data64` via `NET_RT_IFLIST2`; aggregate as Σ per-interface deltas, not
Δ(Σ), so one interface vanishing no longer blanks the whole reading; drop an
interface from the previous-sample map when it disappears so a reappearing
`utunN` starts a fresh baseline; plausibility bound at 12.5e9 B/s.

### 2. Sleep/wake gap — S/M. **Must land before or with item 3.**
No `NSWorkspace.willSleepNotification` handling exists anywhere. A nine-hour
sleep produces one interval of ~32,400 s; `selectWindowLocked` walks newest-first
so that single row fills the entire 10-hour window by itself.

Drop the straddling interval (above). Then reset the full accumulator set — the
original said "tracker/smoother", which is not the list: `tracker`, `smoother`
(needs a `reset()`), `pstrWindow`, `ppmcWindow`, `fastSincePublish`,
`pstrSincePublish`, `lastSweep`, and **`lastPublished`** — that last one is what
stops the first post-wake gauge window spanning the entire sleep.

Add `interval <= maxPlausibleInterval` to `record` as defence in depth, and a
read-side `dur <= 300` filter, because stores already on disk carry poisoned
rows and will otherwise show no change.

### 3. Serial sampling queue — S. **After item 2.**
`refresh()` dispatches onto the *concurrent* global queue. `PowerMonitor`
mutates `lastSweep`, `pstrWindow`, `ppmcWindow`, `fastSincePublish`,
`lastPublished`; `CPUUsage.previous`, `NetworkThroughput.previous`,
`AppDelegate.lastFullTick` likewise; `SMC` has no lock at all. Concurrent
dictionary mutation is a crash, not a wrong number.

Private serial queue plus an `isSampling` guard — but note the guard makes
**dropped ticks a designed behaviour for the first time**, and the pipeline has
no handling for one. That is item 2's failure mode at small scale arriving
through this fix, which is why item 2 comes first. Count skipped ticks and
surface the count rather than skipping silently.

### 4. Light ticks report confident falsehoods — S
While hidden, `attributed = 0` and `gpu = nil`, so `residualShare` is exactly
1.0 and coverage is 0 — rendered as "100%" and "0%" with `isEstimate: false`.
These are the two metrics whose whole job is stating measurement honesty. Add
`isFullSample` to Snapshot; both providers return nil when false.

### 5. Ledger overflow alarm is suppressed when it does not fit — S
Reclassified from P4 cosmetic. The `⚠︎ attribution overflow` prefix makes the
provenance string longer, so the warning is *more* likely to be dropped in
exactly the state it reports — and it is the only surfaced indicator that the
ledger is physically impossible.

### 6. History is never pruned — S
`prune` exists, `Settings.historyRetentionDays` exists with a Preferences
control and a caption promising it works, and nothing calls it.

**Do not run it inline on a settings change**, and do not call it "on the store's
queue" as though that were free: `record()` blocks on that same serial queue
every tick, so a long prune stalls the sampler — and after item 3 a stalled
sampler *drops* ticks. Chunk the deletes, bound `incremental_vacuum`, run on a
timer, and have a retention decrease schedule the next prune rather than perform
one. Measure it with `--diskwatch` against the 24.9 KB/s sustained limit this app
has already been killed by once.

### 7. Graph hover/zoom geometry disagrees with the drawing — S
`draw` computes `padLeft`/`padRight` from the axis labels; the interaction code
hardcodes 34 / 42 / 76. On a 7-day range that is ~2 hours of tooltip error, and
scroll-zoom drifts the point under the cursor — which the code's own comment
calls the most disorienting thing a zoomable chart can do. Store `lastPlot` in
`draw` and read it. Also guard `abs(scrollingDeltaY) > 0` so a horizontal swipe
does not zoom.

### 8. Time remaining disagrees between surfaces — S/M
Three different answers, and the slew-limited one the code calls "THE value to
display" drives nothing the user sees. **This reverses a documented decision**
(`GlanceCardView.swift:184-191` explains why the card deliberately bypassed the
estimator), so the reversal must be recorded in that comment, not silently
deleted — and the accepted consequence stated: the headline time and the rate row
will visibly fail to multiply out for ~2 minutes after a load change.

### 9. Wire `ModelValidator` — S
426 lines of ground-truth harness, with its own `selfTest()`, that nothing ever
constructs. Add `selfTest()` to the suite and a `--validate` CLI mode. Cheapest
confidence available for a project whose entire pitch is measurement.

### 10. Performance, window-open — S each
Table cells are rebuilt from scratch every tick (`makeView` reuse); autosizing
measures every row not just visible ones; the Sensors pane bypasses the 5 s
cache and re-reads ~270 SMC keys on the main thread; `Timer.tolerance` is never
set anywhere.

---

## Deferred, with the reason stated

The original plan left **11 of 39 items in no sprint at all** *(2 of 2)* with no
signal whether that was deliberate. It is deliberate here:

- **27, 28, 29** — further performance, below the noise floor now that idle is
  0.19% of one core.
- **30, 32, 33, 34, 35, 36** — real but cosmetic or small: a discarded observer
  token, table accessibility, a row context menu, unpersisted sort/lens, 1024-vs-
  1000 byte units, a duplicated block in the graph draw.
- **9 (scale self-calibration)** — `joulesPerPercent` is a hardcoded 11.58 V seed
  under *every* displayed number, and `ARCHITECTURE.md` claims a
  `calibrated(with:)` that does not exist. Deferred because it moves every number
  in the app and wants a quiet on-battery window to validate. **Until it lands the
  docs are wrong, so correct them.**
- **13 (display model)** — the brightness curve is calibrated for one panel and
  applied unconditionally, then *subtracted* from the platform bucket, so on
  other hardware it corrupts the honest bucket too. Minimum: key on `hw.model`
  and return nil elsewhere. That is strictly more honest than a wrong number.
- **15 (discharge session report)** — the flagship feature, and it depends on the
  `soc` compaction fix that is now done. Worth doing properly rather than fast.

## Distribution — blocking for "give it to friends"

- **37** — ad-hoc signed, no hardened runtime. The original's stated *minimum*
  was to document `xattr -dr com.apple.quarantine`, which teaches a recipient to
  disable the one check between "a binary a friend sent me" and "a binary running
  with my full privileges", on an app that is deliberately unsandboxed and
  enumerates every process. Better minimum: **do not distribute a binary** — ship
  source and `build-app.sh`, since a locally built bundle is never quarantined.
- **38** — no update mechanism, so any bug shipped to a friend is permanent.
- **39** — ~~the root helper accepts any process whose path ends in the right
  suffix~~ **CLOSED**, and not the way this entry expected. The path check is
  gone, but so is the daemon: nothing is installed, nothing runs as root unless
  the user starts it, and the helper is a program they run with `sudo` and stop
  with ⌃C. Connections are checked on the caller's euid (`getpeereid`) and on a
  cdhash taken from the peer's audit token, pinned **at helper startup** from the
  app bundle on disk.

  The earlier plan — pin the cdhash in a root-owned file at install time — was
  abandoned for an operational reason rather than a cryptographic one. The app is
  distributed as source, so an ad-hoc cdhash changes on every `./build-app.sh`;
  the pin would go stale every rebuild and the repair would be another admin
  prompt, which trains reflexive `sudo` and is a worse hole than the one the pin
  closes. A pin that lives and dies with the helper process cannot go stale.

  This also **removes the dependency on 37** that this entry claimed. A
  designated-requirement check is indeed satisfiable by anyone who re-signs
  ad-hoc under the same identifier — but a cdhash is a hash of the code, so a
  different binary produces a different hash whatever it calls itself. The
  remaining honest limit is that nothing verifies the *helper* before it runs as
  root; the user does, by reading the path they type. See the trust model at the
  top of `Sources/PowerKit/FanLink.swift`.

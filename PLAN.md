# Anode — reviewed implementation plan

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

- **Model portability — three defects, one mistake** *(shipped)* Found by
  probing `Mac17,5` (A18 Pro, fanless, 1S pack) against `Mac17,9`, which is where
  every number in this repo was measured. `Battery.state()` read one field name
  with no fallback while `Battery.scale()` above it tried three across two dicts,
  so a machine publishing no `RemainingCapacity` read 0 and took the whole drain
  estimator down — "measuring…" forever with the rate still correct, which is why
  it needed a second machine to surface. The halves are now resolved as a PAIR,
  because crossing them is silent and worth 1.6 points. `seedNominalVoltage_V` was
  a 3S constant applied to a 1S pack, overstating `joulesPerPercent` by 3.01x and
  every %/hr under it; the terminal voltage now supplies only the cell COUNT and
  `nominalCellVoltage_V` is the seed over three, so `Mac17,9` moves by nothing.
  `FanPresence` could not conclude `.fanless` without an affirmative `FNum`,
  because "no key decoded" could not be told from "the decoder skips this type" —
  `SMC.exists()` asks key info instead and removes the conflation, Intel `fpe2`
  included. `projectedRuntime_hr()` moved off the integer percent.
- **The open menu bar panel is now sampled and paced for a reader** *(shipped)*
  Its three sensor rows could only ever be dashes, and it updated on the 8 s
  hidden clock whose own justification is that nobody is reading. The app modelled
  only window-visible vs hidden; an open panel is neither. The collapsed group's
  exclusion is untouched — that measured 0.375% -> 0.727% idle CPU and is correct
  while collapsed.

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

## The reviewed list — all ten landed

Verified against the tree while reconciling this file, not from memory. Two were
solved differently from the plan, and those are the interesting ones.

1. **Network counter wrap** — done, and NOT the way this plan said. It proposed
   `sysctl(NET_RT_IFLIST2)`, whose `if_msghdr2.ifm_data` is declared `if_data64`.
   Measured by pushing 7 GB over lo0, that path read 3,392,594,944 against a true
   7,687,562,848 — short by exactly 2^32, high word left zero. So the plan's fix
   would have carried the same bug in a wider-looking type.
   `net.link.generic.ifdata` (`IFMIB_IFALLDATA`, what `netstat -ib` uses) returns
   the counters at full width and matched `netstat` byte for byte. The wrap is
   removed rather than compensated for.

2. **Sleep/wake gap** — done, and also differently. No `willSleepNotification`
   subscription was added. A long interval is treated as the gap in observation
   it already is (`straddlesGap`, `maxPlausibleInterval`), which covers sleep,
   a stalled sampler and a run of dropped ticks with one rule instead of three.

3. **Serial sampling queue** — `SamplingGate` on a private serial queue, and the
   dropped-tick count is published as a metric rather than swallowed.

4. **Light ticks report confident falsehoods** — `isFullSample` on the snapshot;
   the honesty metrics return nil rather than a confident 100%/0%.

5. **Ledger overflow alarm** — the `⚠︎ attribution overflow` prefix survives, and
   the condition is logged as an error as well as drawn.

6. **History pruning** — `pruneChunk(olderThan:)`, chunked and off the sampler's
   critical path, with a retention change scheduling the next prune.

7. **Graph hover/zoom geometry** — `draw` stores `lastPlot` and the interaction
   code reads it, so the tooltip and the drawing agree at every range.

8. **Time remaining** — one reconciled rate feeds the surfaces
   (`reconciledRate`).

9. **`ModelValidator`** — `selfTest()` runs in the suite, and the CLI constructs
   the validator.

10. **Window-open performance** — the largest single item in the whole plan, and
    the numbers are in the log rather than here: 15.05% of a core down to ~3.7%
    window-open, and the background floor 3.02% down to ~0.3%. Table cells are
    written in place rather than rebuilt, autosizing measures only visible rows,
    and `Timer.tolerance` is set.

---

## Next

Nothing left in the reviewed list. What is open is the field-reported defects
below, then release work and the deferred items.

### Field-reported — 2026-08-17

Everything here came off two machines in one session. All but the last has
shipped; see `## Done`.

- **Discharge trend holds a stale burst for the full 30-minute window.**
  MEASURED 2026-08-17: a six-minute 20–27 W burst left the window reading
  11.4 W against a live 5–6 W, so the card showed **4.2 h** where macOS showed
  **8:14**. A 2.5x error that persisted the full thirty minutes and then
  cleared by itself, on schedule, when the burst aged out — which is the proof
  the detector never fired, since a firing would have corrected it in minutes.
  It failed twice over. (a) The drop landed ~384 ticks into the window, under
  `referenceFloorTicks = 600`, so the detector was inert. (b) Once past the
  floor the reference CONTAINED the burst, giving relSD 0.70 and an effective
  band of `max(0.30, 3.0 x 0.70)` = 2.098. The guard is
  `abs(delta) > band * reference`, and a downward change is bounded by the
  reference itself (power cannot go below zero), so downward detection requires
  `band < 1` — **every reference with relSD >= 1/3 is structurally undetectable
  downward, at any magnitude.** The noise term is blinded by exactly the event
  it exists to catch. Fix the band; leave `referenceFloorTicks` alone, as it is
  already the product of one full tuning cycle (0.53 -> 0.00 collapse rate) and
  one incident is not grounds to re-open it. Reproduce in
  `DischargeTrendSweepHarness` BEFORE changing anything, and re-run the
  cold-start sweeps after — this file's own history is a record of a fix that
  repaired one case and broke another.
- **38 — no update mechanism.** The one distribution item still open. Parked
  until the repo is public, since an updater needs somewhere to update from.
- **Publication** — the remote is renamed and the history is scrubbed. What is
  left before it goes public: a LICENSE (there is none, so the default is all
  rights reserved, which contradicts the two places the source calls this project
  open source), a repo description, and GitHub's "keep my email address private"
  so the scrub cannot regress.
- The **deferred** items below, unchanged and still deliberate. Item 9 is the one
  with teeth: the battery scale is a seeded constant under every displayed
  number, and until it is measured, absolute %/hr should not be compared across
  machines.

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
  suffix~~ **CLOSED**, and not the way this entry expected. It has since been
  overtaken twice, so what follows is the state as of this reconciliation rather
  than as of the review.

  **The default is still that nothing is installed.** No LaunchDaemon, no plist,
  no root process when fan control is not in use. The helper is a program the
  user runs with `sudo` and stops with ⌃C, and it pins its client to ONE BUILD by
  cdhash taken from the peer's audit token at helper startup — the strongest
  check available to a project with no Developer ID, and one that cannot go stale
  because it lives and dies with the process.

  **An install path was added after that**, because typing a sudo command every
  session is not a thing to ask of anyone who is not developing this. One
  authorisation, once, then fan control survives rebuilds and reboots. It is a
  weaker check and is documented as one: a daemon that outlives every rebuild
  cannot pin a hash that changes on every rebuild, so it pins the signing
  IDENTIFIER, and anyone who can run `codesign -s - -i dev.anode.app` on their
  own binary satisfies it — verified, not assumed. Its real boundary is the uid
  check, which is the kernel's, plus a vocabulary of two commands whose values
  the fan firmware re-clamps.

  Both models are written out in full where they are implemented — the trust
  model at the top of `Sources/PowerKit/FanLink.swift`, the install's reasoning
  in `FanDaemon.swift`. This entry is a pointer, not the second copy that goes
  stale.

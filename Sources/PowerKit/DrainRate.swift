import Foundation

/// %/hr drain and time-to-empty from OBSERVED battery history.
///
/// The problem this solves: "one minute it says 3 hrs then the next 6 seconds
/// later is 9 hrs". That happened because %/hr was derived from INSTANTANEOUS
/// power (SMC PSTR, measured swinging 4.24–17.90 W within one minute) and
/// time = charge% / (%/hr), so both figures inherited the spike. But the
/// battery gas gauge directly reports how much charge actually left the pack —
/// that is ground truth, and this estimator is built on it.
///
/// ## Why a ROLLING window, not the requested fixed clock-hour bucket
/// The request was "go off how much percent actually drained this hour". A
/// fixed this-clock-hour bucket has a discontinuity at the top of every hour:
/// at 12:00:30 the bucket holds 30 seconds of data and the estimate collapses,
/// once an hour, forever. A rolling window of the last N minutes is the SAME
/// idea — rate = what actually drained recently — with no cliff, and is
/// strictly better. The change is deliberate, not a misreading of the request.
///
/// ## What the gauge actually gives us (measured on this machine)
/// - `BatteryData.RemainingCapacity` is mAh with 1 mAh resolution = 0.016% of
///   the 6197 mAh pack — far finer than the integer `CurrentCapacity` percent.
/// - BUT it republishes in ~60 s batches: sampled 5x over 20 s it read the
///   same value every time. Quantised in TIME, not amplitude.
/// - So over 10 minutes there is ~100 mAh of real signal; over 20 seconds
///   there is none. Hence the minimum span and minimum delta gates below —
///   an observed rate is an ESTIMATE until the window has real signal in it,
///   and before that the power-based figure must carry the display.
///
/// ## Estimation strategy
/// - Linear least-squares of mAh against time over the window — NOT
///   first-minus-last, which throws away every intermediate sample and is
///   maximally sensitive to the two noisiest points (verified: regression is
///   ~2x steadier on the same noisy synthetic discharge).
/// - Two windows, fast (~10 min) and slow (~60 min). The slow one is preferred
///   for steadiness; the fast one takes over only after it has diverged from
///   the slow one on TWO consecutive gauge publishes — the same
///   confirm-before-jumping logic as `AdaptiveSmoother`, so one noisy publish
///   cannot flip the estimate but a real load change is followed within
///   ~2 minutes.
/// - The buffer RESETS on any AC transition. Charge going up is not drain, and
///   mixing charge and discharge samples poisons the fit.
/// - Blend: rate = confidence·observed + (1−confidence)·powerBased. Just after
///   unplugging there is no history, so the power figure carries it
///   (`source == .power`); once the window has span and signal, observation
///   dominates completely (`source == .observed`). `source` is exposed so the
///   UI can label the figure honestly.
///
/// ## What now sits ABOVE all of that: `BatteryDischargeTrend`
/// Everything above infers drain from `RemainingCapacity`, which is the gauge's
/// ESTIMATE of state of charge and moves the wrong way on four publishes in ten
/// (see `DischargeTrend.swift` for the measurement). The battery also publishes an
/// INTEGRAL of measured discharge power, which cannot, and a half-hour mean of it
/// is 7.4x steadier. When that trend has a window it is used outright and the
/// regression below becomes the cross-check and the fallback — for the first
/// couple of minutes on battery, and for any machine where the accumulator is
/// absent or implausible. `source` says which one is speaking, and the UI shows it.
public struct DrainEstimate {
    public enum Source: String, Sendable {
        /// Mean of the battery's own discharge accumulator over the trend window —
        /// measured charge that has already left the pack, not an inference.
        case discharge
        /// Mean battery drain over every display-on minute on battery since the
        /// app began keeping `LifetimeDrainModel.allTimeMean_W`. Never decays.
        case allTime
        /// Regression over observed history; confidence is high enough that
        /// the power-based figure is ignored entirely.
        case observed
        /// Weighted mix of observed history and the power-based rate.
        case blended
        /// Power-based rate only — history too short or too flat to trust.
        case power
        /// No trustworthy history AND no power-based figure. `percentPerHour`
        /// is 0 as a PLACEHOLDER, not a claim of zero drain — display
        /// "estimating…", never the number.
        case insufficient
    }

    /// Drain rate in %/hr, always >= 0. Check `source` for provenance.
    public let percentPerHour: Double
    /// Time to empty — THE value to display. nil when unknowable (on AC, rate ≈ 0,
    /// or no data): show "—" or "estimating…", never a substitute number.
    ///
    /// This is the value AT THE INSTANT THE ESTIMATE WAS MADE. A renderer that
    /// holds it across ticks must project it forward — see `projected` below and
    /// `DisplayedRate`, which is what the app actually publishes.
    public let timeRemaining: TimeInterval?
    /// The charge, on the mAh basis, that `timeRemaining` was divided out of.
    /// nil on `.insufficient`, where the rate is a placeholder and there is
    /// nothing to divide.
    ///
    /// Published rather than kept private for two reasons, both load-bearing.
    /// A renderer cannot count the time down without it — it is the only thing
    /// that changes between gauge publishes. And `MetricUnit.minutes`' own
    /// comment defends the property "that charge / rate and the displayed time
    /// can be checked against each other by hand", which "has caught several
    /// real bugs here"; a projection that did not say which charge it started
    /// from would end that.
    public let chargePercent: Double?
    /// 0…1: how much of `percentPerHour` is measured rather than inferred. 1 for
    /// `.discharge`, which is measurement end to end.
    public let confidence: Double
    public let source: Source
    /// Span of the history window behind the estimate (0 when none).
    public let windowSpan: TimeInterval
    /// Samples inside that window.
    public let sampleCount: Int

    /// The ONE definition of time-to-empty, on the mAh basis.
    ///
    /// A function rather than two divisions in two files, because the last time
    /// this arithmetic existed twice the menu bar and the glance card printed
    /// different answers to the same question three inches apart. Whatever rate is
    /// DISPLAYED goes in here, so charge ÷ rate = the time shown beside it, always.
    ///
    /// `chargePercent` is `RemainingCapacity / FullChargeCapacity`, NOT the integer
    /// `CurrentCapacity`: measured on this machine those disagree by 1–2 points
    /// (61 % vs 59.2 %, 42 % vs 40.0 %), and the integer field is the optimistic one
    /// — it overstates runtime by ~5 %, about 12 minutes at 4 hours. See
    /// `BatteryScale.chargePercent`.
    public static func timeToEmpty(chargePercent: Double, ratePctHr: Double) -> TimeInterval? {
        // Below this the division blows up toward the cap below; treat as "not
        // meaningfully draining" and answer nothing.
        guard ratePctHr >= 0.1, ratePctHr.isFinite, chargePercent > 0 else { return nil }
        // Constant POWER, not constant current. The rails are buck converters,
        // so a load holds watts; as the pack sags the current rises and the
        // charge runs out sooner than `charge / rate` says. The true time is
        // `(1/P)∫V dQ` over the charge that remains, which is this division
        // scaled by `V̄_remaining / V_now` — see `BatteryScale.constantPowerFactor`.
        //
        // Applied HERE, inside the one definition, so every tier and every
        // renderer inherits it and none of them can disagree about it. It needs
        // no new argument: `chargePercent` is already the state of charge on the
        // mAh basis, which is exactly what indexes the curve.
        //
        // Worth 7.1 % at a full pack and 1.8 % near empty — about 20 minutes of
        // an eight-hour estimate, always in the optimistic direction, and
        // previously invisible to every metric in the sweep harness because that
        // harness held the pack at one voltage from full to empty.
        let t = chargePercent / ratePctHr * 3600
            * BatteryScale.constantPowerFactor(atSoCPercent: chargePercent)
        // A displayed time above this is a fit through noise, not a runtime a laptop
        // has. nil (the UI shows "—") rather than "412 hr".
        guard t.isFinite, t > 0, t <= 99 * 3600 else { return nil }
        return t
    }

    /// The same time-to-empty, `elapsedAwake` seconds after the estimate was made.
    ///
    /// ## Why this asserts nothing new
    /// The gauge publishes in ~60-tick batches about once a minute, and both
    /// inputs above come from it, so between publishes the quoted time cannot
    /// move — reported from the field as a headline sitting at "7h 03m" for over
    /// a minute. But at an unchanged rate `r` from a charge `p0`,
    ///
    ///     t(tau) = (p0 - r*tau/3600) / r * 3600 = t0 - tau
    ///
    /// EXACTLY, at every rate and every charge (pinned in
    /// `TimeLeftContinuityTests`). So counting the display down is not an
    /// approximation of the model, and not a second estimator laid over it — it
    /// is the model's own prediction, delivered continuously instead of in one
    /// lump per publish. The rate never moves without new information, which is
    /// the rule `DischargeTrend.record` states and this does not touch; the
    /// CLOCK moves, and it always did.
    ///
    /// ## Why AWAKE seconds
    /// Wall time would bill a sleeping machine for the whole night: the pack
    /// draws ~0.2 W asleep, so subtracting eight hours of runtime from it and
    /// showing that at the moment the lid opens is the exact shape of error
    /// `DischargeTrend` already resets the whole window to avoid. `CLOCK_UPTIME_RAW`
    /// does not advance while asleep, so awake elapsed is what was really spent.
    ///
    /// ## What it refuses
    /// Everything `timeToEmpty` refuses, because it IS `timeToEmpty` — one
    /// definition, for the reason that function's own comment gives. Plus a
    /// projection past the anchor's own death, which falls out of the
    /// `chargePercent > 0` guard rather than being clamped: an anchor whose
    /// charge has run out has no opinion left, and "—" is the honest answer.
    /// A negative or non-finite interval means the two clocks disagreed, and
    /// answers the anchor unchanged rather than adding time to the battery.
    public static func projected(chargePercent: Double, ratePctHr: Double,
                                 elapsedAwake: TimeInterval) -> TimeInterval? {
        guard let t0 = timeToEmpty(chargePercent: chargePercent, ratePctHr: ratePctHr)
        else { return nil }
        guard elapsedAwake.isFinite, elapsedAwake > 0 else { return t0 }
        // SUBTRACT, rather than re-evaluate against a reduced charge.
        //
        // This did re-evaluate, which was right while time-to-empty was
        // `charge / rate` and became WRONG the moment the constant-power
        // correction landed. Re-evaluating decrements the charge at a constant
        // %/hr — a constant-CURRENT assumption — and then applies a correction
        // derived for constant POWER. Two models, one expression: measured on
        // the shipped curve, the display counted down at 0.89 s per second.
        //
        // Under the corrected model the answer is a fixed instant: the pack dies
        // when the integral of its voltage over the remaining charge runs out,
        // and nothing about waiting changes that. So the remaining time falls at
        // exactly one second per second, and subtracting is not an approximation
        // of the arithmetic — it IS the arithmetic, with the curve evaluated
        // once at the anchor where the charge was actually read.
        //
        // nil past the anchor's own death, for the reason the guard below gives:
        // an anchor whose time has run out has no opinion left, and "—" is the
        // honest answer rather than a negative duration.
        let t = t0 - elapsedAwake
        return t > 0 ? t : nil
    }

    /// Time-to-empty when the load now is expected to fade back to what this
    /// machine usually draws: rate(t) = b + (c − b)·e^(−t/τ). See
    /// `LifetimeDrainModel` for where `b` and `τ` are learned.
    ///
    /// The pack is empty when the %·hr spent reaches the charge that remains,
    /// scaled ONCE by the constant-power factor — the same budget `timeToEmpty`
    /// divides, integrated against a rate that moves instead of one that holds.
    /// So wherever the two models describe the same load they are the same
    /// number: no excursion, or one that never ends, IS `timeToEmpty` at the
    /// current rate (pinned in `LifetimeForecastTests`). The result must never be
    /// passed through `timeToEmpty` again, which would apply the factor twice.
    public static func forecastTimeToEmpty(chargePercent: Double, currentPctHr c: Double,
                                           baselinePctHr b: Double,
                                           tau: TimeInterval) -> TimeInterval? {
        guard c.isFinite, b.isFinite, !tau.isNaN, chargePercent.isFinite else { return nil }
        if abs(c - b) < 1e-9 || tau == .infinity {
            return timeToEmpty(chargePercent: chargePercent, ratePctHr: c)
        }
        // Both ends of the curve must be a real drain, for the reason
        // `timeToEmpty` gives for its own floor.
        guard chargePercent > 0, min(b, c) > 0, max(b, c) >= 0.1, tau > 0 else { return nil }
        let budget = chargePercent * BatteryScale.constantPowerFactor(atSoCPercent: chargePercent)
        let tauH = tau / 3600
        func spent(_ hours: Double) -> Double {
            b * hours + (c - b) * tauH * (1 - exp(-hours / tauH))
        }
        // `spent` rises monotonically (the rate is positive throughout), so
        // bisection converges; beyond the cap there is no runtime worth quoting.
        let cap = 99.0
        guard spent(cap) >= budget else { return nil }
        var lo = 0.0, hi = cap
        for _ in 0..<100 {
            let mid = (lo + hi) / 2
            if spent(mid) < budget { lo = mid } else { hi = mid }
        }
        let t = (lo + hi) / 2 * 3600
        return t > 0 ? t : nil
    }
}

public final class DrainRateEstimator {

    private struct Sample {
        let t: Date
        let mAh: Double
        let onBattery: Bool  // always true in practice: AC samples reset the buffer
    }

    /// A least-squares fit over one window. `delta_mAh` is first-minus-last
    /// (positive when draining) — used only to gate/score signal magnitude,
    /// never as the rate itself.
    private struct Fit {
        let ratePctHr: Double
        let span: TimeInterval
        let delta_mAh: Double
        let n: Int
    }

    private let fastWindow: TimeInterval
    private let slowWindow: TimeInterval

    // ── Trust gates, sized from the measured gauge behaviour ────────────────
    /// Below this span the window holds at most a handful of ~60 s publishes
    /// and the fit is dominated by publish-timing jitter. 5 min ≈ 5 publishes.
    private let minSpan: TimeInterval = 300
    /// Span at which the span term of confidence saturates.
    private let fullSpan: TimeInterval = 900
    /// Minimum observed drop before the rate is trusted at all. The gauge step
    /// is 1 mAh but each endpoint carries up to one publish period (~60 s) of
    /// timing uncertainty, so demand several steps of real signal.
    private let minDelta_mAh: Double = 5
    /// Drop at which the signal term of confidence saturates (~0.5% of pack).
    private let fullDelta_mAh: Double = 30

    // ── Fast/slow arbitration (confirm-before-jumping) ──────────────────────
    /// Consecutive NEW gauge publishes on which fast must disagree with slow
    /// before the fast window takes over. Ticks between publishes repeat the
    /// same staircase value and carry no new information, so confirmation is
    /// counted per publish, not per record().
    private let divergeConfirmations = 2
    private var divergeStreak = 0
    private var preferFast = false

    /// The primary signal. Owned here rather than beside it so the app drives ONE
    /// object and reads ONE estimate: two published drain figures is exactly the
    /// bug this class was last changed to fix.
    private let dischargeTrend: BatteryDischargeTrend

    private var samples: [Sample] = []
    private let maxSamples = 8192
    private var fullCharge_mAh: Double?
    private var lastMAh: Double?
    private var wasOnBattery = false
    /// Latest power-based rate, with its timestamp so it can go stale (the
    /// caller may lose SMC access mid-run; a 5-minute-old wattage is not a
    /// current rate).
    private var lastPower: (pctHr: Double, at: Date)?
    private let powerMaxAge: TimeInterval = 300
    /// Every power-based figure recorded, for the cross-check below. Pruned to the
    /// same horizon as `samples`, which is always longer than the trend window the
    /// check averages over.
    private var powerHistory: [(t: Date, watts: Double)] = []
    /// `joulesPerPercent` from the last scale seen, so the %/hr the caller hands
    /// in can be turned back into the watts it was made from. See
    /// `agreesWithMeasuredPower` for why the comparison must happen in watts.
    private var joulesPerPercent: Double?
    /// Latched, so the tier does not flip every time the ratio grazes the
    /// threshold. See `crossCheckRestore`.
    private var demoted = false

    /// How far the discharge accumulator and the whole-system power measurement may
    /// disagree ABOUT THE SAME INTERVAL before the accumulator is disbelieved.
    ///
    /// The failure this exists for: on a cold boot the trend published a 25-hour
    /// time-to-empty, implying 1.7 W, while the pack was independently measured at
    /// 9.1 W the same instant — a 5.35x disagreement with a figure the app already
    /// held. Raising the trend's floor from 120 to 300 ticks dilutes such an error
    /// across more windows; it does not notice it.
    ///
    /// The comparison must be WINDOW-MATCHED, and that is the whole of the design.
    /// Comparing the trend against the live figure at this instant does not
    /// separate the failure from ordinary life: driven through the four load
    /// profiles this file and `DischargeTrend` are scored on, the instantaneous
    /// disagreement reaches
    ///
    ///     load                              instantaneous   matched to the window
    ///     4-9 W random walk                     1.69x              1.01x
    ///     4 min at 20 W every 20 min            3.39x              1.05x
    ///     1 min at 54 W every 10 min            5.94x              1.68x
    ///     4 min at 54 W every 30 min           10.72x              1.68x
    ///     sustained 6 -> 18 W step              2.82x              1.04x
    ///     sustained 18 -> 6 W step              2.93x              1.12x
    ///
    /// — i.e. a legitimate `swift build` burst disagrees with a half-hour mean by
    /// TWICE what the boot bug did, because that disagreement is the trend doing
    /// its job. Averaged over the trend's own span the two instruments measure the
    /// same joules over the same seconds and must agree: the worst legitimate
    /// disagreement measured anywhere above is 1.68x, and over a full window 1.06x.
    ///
    /// 3.0 is the geometric midpoint of 1.68x (worst legitimate) and 5.35x (the
    /// reported failure): 1.8x of headroom over any load profile measured here, and
    /// 1.8x of margin under the fault it has to catch. Chosen in log space because
    /// the quantity is a ratio and the two errors are symmetric in it.
    ///
    /// (The table above was measured against the trend's original fixed-band
    /// detector. The detector has since been redesigned — noise-scaled band,
    /// frozen reference; see `DischargeTrend` — which only makes the trend's
    /// window-matched mean steadier, so the worst-legitimate side of the midpoint
    /// can only have shrunk and the margin here can only have grown. Re-measure
    /// the table if this constant is ever revisited.)
    private static let crossCheckFactor = 3.0

    /// Where a demoted trend is BELIEVED AGAIN, below the 3.0 that demoted it.
    ///
    /// Without a gap the threshold is a cliff: at 2.99 the app publishes the
    /// trend and at 3.01 it publishes something up to three times different, so
    /// a ratio wandering across 3.0 steps the displayed time by the full size of
    /// the disagreement and back. The failure this check exists for is a 5.35x
    /// blowout — nothing near the boundary — so the boundary can afford to be
    /// sticky, and the only cost is holding a genuinely wrong trend for about
    /// one extra publish.
    private static let crossCheckRestore = 2.2

    public init(fastWindow: TimeInterval = 600, slowWindow: TimeInterval = 3600,
                trend: BatteryDischargeTrend = BatteryDischargeTrend()) {
        self.fastWindow = max(60, fastWindow)
        self.slowWindow = max(self.fastWindow, slowWindow)
        self.dischargeTrend = trend
    }

    // ── Recording ───────────────────────────────────────────────────────────

    /// Convenience wrapper over the raw-value `record`. Call once per monitor
    /// tick (~5 s); the estimator itself notices which ticks carry a new gauge
    /// publish.
    ///
    /// Reads the discharge accumulator here rather than making every caller do it:
    /// it comes out of the same `Battery.properties()` dictionary as `state`, which
    /// is cached for 0.25 s, so on a tick that already read the battery this costs
    /// no extra IORegistry traversal.
    public func record(state: Battery.State, scale: BatteryScale,
                       powerBased_pctHr: Double?, at: Date = Date()) {
        record(remainingCapacity_mAh: state.remainingCapacity_mAh,
               onAC: state.onAC, isCharging: state.isCharging,
               scale: scale, powerBased_pctHr: powerBased_pctHr,
               voltage_mV: state.voltage_mV > 0 ? Double(state.voltage_mV) : nil,
               discharge: BatteryDischargeTrend.Sample.sample(at: at), at: at)
    }

    /// Raw-value entry point. Public so harnesses/tests can drive the
    /// estimator with synthetic history (`Battery.State` has no public init).
    ///
    /// `discharge` nil means the accumulator was unreadable this tick; the trend
    /// simply does not advance and the regression below carries the estimate.
    public func record(remainingCapacity_mAh: Double, onAC: Bool, isCharging: Bool,
                       scale: BatteryScale, powerBased_pctHr: Double?,
                       voltage_mV: Double? = nil,
                       discharge: BatteryDischargeTrend.Sample? = nil,
                       at now: Date = Date()) {
        if scale.fullChargeCapacity_mAh > 0 { fullCharge_mAh = scale.fullChargeCapacity_mAh }
        if scale.joulesPerPercent > 0 { joulesPerPercent = scale.joulesPerPercent }
        if let p = powerBased_pctHr, p.isFinite, p >= 0 {
            // `p` arrives on the NOMINAL-voltage basis (it is `3600 W / J%`), but
            // the power tier is published as a rate that `timeToEmpty` divides,
            // and that assumes the LIVE-voltage basis the discharge tier is on.
            // Converted here, with the pack voltage, so the power, blended and
            // demoted tiers stop quoting times short by nominal / live — 7.8 %
            // on a 1S pack at 4.19 V — and the handover to the discharge tier
            // stops jumping. Without a voltage it stays as it was.
            let watts = p * (joulesPerPercent ?? 0) / 3600
            let live = voltage_mV.flatMap { v -> Double? in
                guard v > 0, watts > 0, let full = fullCharge_mAh, full > 0 else { return nil }
                let r = watts * 1e8 / (v * full)
                return r.isFinite ? r : nil
            }
            lastPower = (live ?? p, now)
            // Recorded before the AC guard below and never on a clock that went
            // backwards, so the buffer is always in order and always covers the
            // trend's window whenever the trend has one.
            if let lastT = powerHistory.last?.t, now < lastT { powerHistory.removeAll() }
            // Stored as WATTS. `p` is `3600 * W / joulesPerPercent`, so this
            // multiplication recovers the measurement exactly and cancels the
            // assumed nominal voltage that the division introduced.
            powerHistory.append((now, watts))
            let cutoff = now.addingTimeInterval(-slowWindow * 1.05)
            var drop = 0
            while drop < powerHistory.count && powerHistory[drop].t < cutoff { drop += 1 }
            if drop > 0 { powerHistory.removeFirst(drop) }
        }

        let onBattery = !onAC && !isCharging
        // Fed before the AC guard below: `onBattery: false` is how the trend learns
        // to throw its window away, and it has to hear about the transition.
        if let d = discharge { dischargeTrend.record(d, onBattery: onBattery) }
        guard onBattery else {
            // AC transition: charge going UP is not drain, and mixing the two
            // poisons the fit. Drop everything; the power figure carries the
            // display until battery history rebuilds.
            if wasOnBattery || !samples.isEmpty { resetHistory() }
            wasOnBattery = false
            // The trend threw its window away at the transition, so the buffer that
            // cross-checks it must go too: an on-AC wattage averaged into the check
            // would compare the adapter's load against the pack's discharge.
            powerHistory.removeAll()
            return
        }
        if !wasOnBattery { resetHistory(); powerHistory.removeAll() }  // fresh segment
        wasOnBattery = true

        let mAh = remainingCapacity_mAh
        guard mAh.isFinite, mAh > 0 else { return }         // gauge glitch: skip, never poison
        if let t = samples.last?.t, now < t { resetHistory() }  // clock went backwards
        // A sample buffer that straddles a sleep fits a line through hours the
        // machine was not awake for. The long case is already harmless — a nine
        // hour gap puts every pre-sleep sample outside `prune`'s cutoff — but a
        // sleep SHORTER than the slow window is not: the pre-sleep samples stay,
        // and the fit is dragged toward the ~1%/hr the machine drew asleep,
        // under-reporting drain exactly when the user has just opened the lid to
        // look at it.
        //
        // Detected from the record cadence rather than a sleep notification, so
        // it holds for the CLI (no AppKit) and for a suspended process, which
        // sleeps no clock but breaks the series the same way. `record` is driven
        // every couple of seconds, so a gap this long is never an ordinary tick.
        //
        // The discharge trend has its OWN, tighter gap rule (see
        // `BatteryDischargeTrend.record`): it compares the wall clock against
        // CLOCK_UPTIME_RAW and so also catches a sleep shorter than this.
        if let t = samples.last?.t,
           now.timeIntervalSince(t) > HistoryStore.maxPlausibleInterval {
            resetHistory()
            // Same argument as the AC branch: a mean of power figures straddling a
            // sleep is not a measurement of the window the trend now covers.
            powerHistory.removeAll()
        }
        // MEASURED on this machine: the gauge can revise RemainingCapacity
        // UP by ~11 mAh mid-discharge (voltage-relaxation recovery). Small
        // rises are gauge noise and belong in the fit — regression absorbs
        // them. Only a rise too big to be noise (~0.5% of pack) means the
        // AC/charging flags lied and the history is genuinely poisoned.
        if let lm = lastMAh, mAh > lm + max(8, 0.005 * (fullCharge_mAh ?? 6000)) {
            resetHistory()
        }

        let isNewPublish = (mAh != lastMAh)
        samples.append(Sample(t: now, mAh: mAh, onBattery: true))
        lastMAh = mAh
        prune(now: now)
        if isNewPublish { arbitrate() }
    }

    public func reset() {
        resetHistory()
        dischargeTrend.reset()
        wasOnBattery = false
        lastPower = nil
        powerHistory.removeAll()
        fullCharge_mAh = nil
    }

    private func resetHistory() {
        samples.removeAll(keepingCapacity: true)
        lastMAh = nil
        divergeStreak = 0
        preferFast = false
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-slowWindow * 1.05)
        var drop = 0
        while drop < samples.count && samples[drop].t < cutoff { drop += 1 }
        if samples.count - drop > maxSamples { drop = samples.count - maxSamples }
        if drop > 0 { samples.removeFirst(drop) }
    }

    // ── Regression ──────────────────────────────────────────────────────────

    /// Least-squares slope of mAh against time over the trailing `window`.
    /// Regression, not first-minus-last: endpoints carry the most quantisation
    /// noise and first-minus-last uses ONLY them; the fit uses every sample.
    private func fit(window: TimeInterval) -> Fit? {
        guard let last = samples.last, let full = fullCharge_mAh, full > 0 else { return nil }
        let cutoff = last.t.addingTimeInterval(-window)
        var lo = samples.count - 1
        while lo > 0 && samples[lo - 1].t >= cutoff { lo -= 1 }
        let n = samples.count - lo
        guard n >= 2 else { return nil }

        let t0 = samples[lo].t
        var sn = 0.0, st = 0.0, sy = 0.0, stt = 0.0, sty = 0.0
        for i in lo..<samples.count {
            let x = samples[i].t.timeIntervalSince(t0)
            let y = samples[i].mAh
            sn += 1; st += x; sy += y; stt += x * x; sty += x * y
        }
        let denom = sn * stt - st * st
        guard denom > 1e-9 else { return nil }               // all samples at one instant
        let slope_mAhPerSec = (sn * sty - st * sy) / denom   // negative when draining
        let rate = -slope_mAhPerSec * 3600 / full * 100      // %/hr, positive = draining
        guard rate.isFinite else { return nil }
        return Fit(ratePctHr: rate,
                   span: last.t.timeIntervalSince(t0),
                   delta_mAh: samples[lo].mAh - last.mAh,
                   n: n)
    }

    private func isTrusted(_ f: Fit) -> Bool {
        f.span >= minSpan && f.delta_mAh >= minDelta_mAh
    }

    /// Runs once per NEW gauge publish. Prefer the slow window; switch to the
    /// fast one only after it disagrees on `divergeConfirmations` consecutive
    /// publishes (one outlier publish is noise, two is a regime change —
    /// `AdaptiveSmoother`'s rule). Switch back when they reconverge, which
    /// happens naturally once the slow window has flushed the old regime.
    private func arbitrate() {
        guard let s = fit(window: slowWindow), let f = fit(window: fastWindow),
              isTrusted(s), isTrusted(f),
              s.span > f.span + 60   // identical windows → nothing to arbitrate
        else {
            divergeStreak = 0
            preferFast = false
            return
        }
        let band = max(0.30 * abs(s.ratePctHr), 0.5)
        if abs(f.ratePctHr - s.ratePctHr) > band {
            divergeStreak += 1
            if divergeStreak >= divergeConfirmations { preferFast = true }
        } else {
            divergeStreak = 0
            preferFast = false
        }
    }

    // ── Cross-check ─────────────────────────────────────────────────────────

    /// Does the discharge accumulator's rate agree with the whole-system power
    /// measurement OVER THE SAME SECONDS?
    ///
    /// True when they agree, and true when the question cannot be asked — a check
    /// that could not run must not demote a measurement that is otherwise sound.
    /// The two ways it cannot run are both honest nils rather than failures: no
    /// power figures were recorded, or the buffer does not reach back far enough to
    /// be a mean over the trend's span, which is the case for the first few seconds
    /// after an AC transition or a wake.
    ///
    /// A plain mean over the buffer, not a time-weighted one: `record` is driven on
    /// a fixed ~2 s cadence, so the samples are evenly spaced and the two are the
    /// same number. Coverage is required to be 80 % of the span so that a buffer
    /// still refilling cannot pass itself off as the mean of a window it only
    /// partly saw.
    /// How far the two instruments disagree about the same seconds, as a ratio
    /// ≥ 1. nil when the question cannot be asked, which is never a disagreement.
    ///
    /// ## IN WATTS, and that is a correctness fix rather than a tidy-up
    /// This compared `trendRate` against a mean of the power tier's %/hr. Expand
    /// the two:
    ///
    ///     trendRate   = 10^5 · P_batt / (V_measured · full_mAh)
    ///     power_pctHr = 10^5 · P_sys  / (V_nominal  · full_mAh)   <- the 11.58 V SEED
    ///     ratio       = (P_batt/P_sys) · (V_nom / V_meas)
    ///
    /// So the arbitration ratio carried the seed error as a multiplicative
    /// factor. On this machine that is 0.96 and harmless against a threshold of
    /// 3.0. On the `Mac17,5` class of pack this project has already met — where
    /// the seed overstated `joulesPerPercent` by 3.01x (see `Battery.swift`) —
    /// the factor IS 3.01, the check fires on every window, and `estimate()`
    /// does not merely demote: by its own comment it "publishes the figure the
    /// check believed". The app would have published a rate and a time wrong by
    /// three times, on the strength of a check whose only disagreement was with
    /// itself.
    ///
    /// Comparing watts to watts removes the coupling entirely: `full_mAh`
    /// cancels because neither side has it, and no voltage enters either side.
    /// The cell-count fix makes that particular pack unreachable; it does not
    /// make the coupling correct.
    private func crossCheckRatio(_ trend_mW: Double,
                                 over span: TimeInterval,
                                 at now: Date) -> Double? {
        guard span > 0, trend_mW > 0 else { return nil }
        let cutoff = now.addingTimeInterval(-span)
        var lo = powerHistory.count
        while lo > 0 && powerHistory[lo - 1].t >= cutoff { lo -= 1 }
        let n = powerHistory.count - lo
        guard n >= 2 else { return nil }
        guard now.timeIntervalSince(powerHistory[lo].t) >= 0.8 * span else { return nil }

        var sum = 0.0
        for i in lo..<powerHistory.count { sum += powerHistory[i].watts }
        let mean = sum / Double(n)
        // Below this the ratio is dominated by the resolution of the power figure
        // itself, not by any disagreement — a machine drawing a fraction of a watt
        // has nothing to cross-check. (0.1 %/hr on this pack is ~0.07 W.)
        guard mean > 0.07 else { return nil }
        let w = trend_mW / 1000
        return max(w / mean, mean / w)
    }

    // ── Estimation ──────────────────────────────────────────────────────────

    /// nil while on AC (time-to-empty is meaningless while plugged in — the
    /// SBS gauge returns its 65535 sentinel there for the same reason) or when
    /// nothing has been recorded. Otherwise always returns something, with
    /// `source` saying how much of it is measured.
    ///
    /// Call after each `record()`. It is a pure read of accumulated state: extra
    /// calls between records return the same answer, so a UI re-render cannot
    /// creep the number.
    public func estimate() -> DrainEstimate? {
        guard wasOnBattery, let last = samples.last,
              let full = fullCharge_mAh, full > 0 else { return nil }

        // Charge left on the mAh basis, NOT the integer `CurrentCapacity` — at
        // 6193 mAh one integer percent is ~62 mAh of invisible movement, and the
        // integer field reads 1-2 points high (see `BatteryScale.chargePercent`).
        let remainingPct = last.mAh / full * 100

        // Computed before the measured tier rather than after it, because the power
        // figure is now that tier's cross-check as well as its fallback.
        let slowFit = fit(window: slowWindow)
        let chosen = preferFast ? (fit(window: fastWindow) ?? slowFit) : slowFit
        let power: Double? = {
            guard let p = lastPower, last.t.timeIntervalSince(p.at) <= powerMaxAge else { return nil }
            return p.pctHr
        }()

        // The discharge accumulator outranks everything below it whenever it has a
        // window: it is charge that has already left the pack, measured, where the
        // regression is an inference from a state-of-charge estimate that moves the
        // wrong way on four publishes in ten. No blend and no slew limit on this
        // path — the half-hour window IS the stabiliser, and a filter on top could
        // only hide a change the measurement had genuinely seen.
        if let t = dischargeTrend.trend, t.current_mA > 0 {
            let trendRate = t.current_mA / full * 100     // mA / mAh -> %/hr
            // The one thing that can invalidate a measured integral: a counter that
            // was not integrating what we think it was. Two instruments, the same
            // seconds, the same joules — they must agree. See `crossCheckFactor`
            // for the loads this was sized against and why the comparison is over
            // the trend's own span rather than against this instant's draw.
            //
            // Failing the check does not merely demote the trend, it publishes the
            // figure the check believed: the power-based rate is the corroborated
            // one, and falling through to the mAh regression would answer with a
            // third number that nothing had checked.
            // Latched with hysteresis: demote above `crossCheckFactor`, believe
            // again only below `crossCheckRestore`. An unassessable window
            // (nil) clears the latch rather than holding it — the historical
            // behaviour there was "agrees", and a latch that survives a gap
            // would carry a verdict across history it never saw.
            if let ratio = crossCheckRatio(t.power_mW, over: t.span, at: last.t) {
                demoted = ratio > (demoted ? Self.crossCheckRestore : Self.crossCheckFactor)
            } else {
                demoted = false
            }
            if let p = power, demoted {
                return DrainEstimate(
                    percentPerHour: p,
                    timeRemaining: DrainEstimate.timeToEmpty(chargePercent: remainingPct,
                                                             ratePctHr: p),
                    chargePercent: remainingPct,
                    confidence: 0,
                    source: .power,
                    // How much history has ACCUMULATED — and the trend's span is
                    // part of that even when its rate lost the cross-check.
                    //
                    // This used to report `slowFit?.span` alone, which is the mAh
                    // regression's window and is EMPTY for the first minutes after
                    // a launch. So a freshly started app holding a restored trend
                    // with half an hour of measured discharge in it announced that
                    // it had no history at all, and anything keying on that — the
                    // "still measuring" gate — believed it.
                    //
                    // The rate published here is the power figure, deliberately.
                    // The SPAN is not about which number won; it is about how long
                    // this estimator has been watching, and it has been watching
                    // for the whole of the trend's window.
                    windowSpan: max(slowFit?.span ?? 0, t.span),
                    sampleCount: samples.count)
            }
            return DrainEstimate(
                percentPerHour: trendRate,
                timeRemaining: DrainEstimate.timeToEmpty(chargePercent: remainingPct,
                                                         ratePctHr: trendRate),
                chargePercent: remainingPct,
                confidence: 1,
                source: .discharge,
                windowSpan: t.span,
                sampleCount: t.publishes)
        }

        let rate: Double
        var confidence = 0.0
        let source: DrainEstimate.Source
        let span: TimeInterval
        let count: Int

        if let c = chosen, isTrusted(c) {
            // Confidence: span term (enough publishes for the fit to mean
            // something) x signal term (drop large vs the ~1 mAh / ~60 s
            // quantisation). Floor of 0.2 once past the trust gates: real
            // history always outranks nothing.
            let spanC = min(1, max(0, (c.span - minSpan) / (fullSpan - minSpan)))
            let sigC = min(1, max(0, (c.delta_mAh - minDelta_mAh) / (fullDelta_mAh - minDelta_mAh)))
            confidence = min(1, 0.2 + 0.8 * spanC * sigC)
            // A trusted-but-negative fit means the pack is not measurably
            // draining; clamp to 0 rather than report charge as drain.
            let observed = max(0, c.ratePctHr)
            if let p = power, confidence < 0.95 {
                rate = confidence * observed + (1 - confidence) * p
                source = .blended
            } else {
                rate = observed           // observation dominates completely
                source = .observed
            }
            span = c.span
            count = c.n
        } else if let p = power {
            rate = p
            source = .power
            span = slowFit?.span ?? 0     // how much history has accumulated
            count = samples.count
        } else {
            // History too short/flat AND no power figure: claim nothing.
            return DrainEstimate(percentPerHour: 0, timeRemaining: nil,
                                 chargePercent: nil, confidence: 0,
                                 source: .insufficient,
                                 windowSpan: slowFit?.span ?? 0,
                                 sampleCount: samples.count)
        }

        // Same arithmetic as the measured path above, from the same shared
        // definition: whatever rate is published, the time beside it is the charge
        // divided by it. The slew limiter that used to sit here is gone — it was
        // 12% per record() call, and record() runs every 2 s, which is ~6%/s and
        // lets the display cross its whole range in twenty seconds. It limited
        // nothing, and stability now comes from the window rather than from a
        // filter over a number computed the wrong way.
        return DrainEstimate(percentPerHour: max(0, rate),
                             timeRemaining: DrainEstimate.timeToEmpty(
                                 chargePercent: remainingPct, ratePctHr: max(0, rate)),
                             chargePercent: remainingPct,
                             confidence: confidence,
                             source: source,
                             windowSpan: span,
                             sampleCount: count)
    }
}

// ─────────────────────────────────────────────────────────────────────────────

extension DrainEstimate {

    /// How much measured history a TIME-to-empty needs behind it.
    ///
    /// Two minutes. This used to be the same bar `DischargeTrend.minTicks` set,
    /// and the two were documented as one; they have since deliberately diverged.
    /// The trend now waits FIVE minutes before speaking (one publish must not
    /// dominate its window — see `minTicks`), but this gate answers a smaller
    /// question: is the power tier's time-quote past the just-unplugged
    /// transient, where the instant it extrapolates is whatever the machine
    /// happened to be doing? Two minutes of watching clears that transient, and
    /// blanking the display for five instead would hide an honest, labelled
    /// figure for the three minutes in between — the gap the power tier exists
    /// to carry.
    public static let settleSeconds: TimeInterval = 120

    /// Is there enough behind this estimate to put a TIME on it?
    ///
    /// The RATE is always worth showing: even the power-only tier is a real
    /// reading of what the machine is drawing right now. The TIME is not the same
    /// claim — it extrapolates that instant across the whole rest of the battery,
    /// and in the first seconds after an unplug or a wake the instant it
    /// extrapolates is whatever the machine happened to be doing.
    ///
    /// Reported from the field: a laptop unplugged while idle read 3 %/hr — which
    /// was TRUE, an idle Mac draws about 2.2 W — and beside it "25 hours", which
    /// nobody was going to get. The rate was honest and the time was not, because
    /// only one of them claimed to know about the future.
    ///
    /// So a time is quoted once there is real history, and before that the UI says
    /// it is still measuring. `DrainEstimate.timeRemaining`'s own documentation
    /// already asked for this — "nil when unknowable: show '—' or 'estimating…',
    /// never a substitute number" — for the case where nothing is known at all.
    /// This extends it to the case where too little is.
    public static func canQuoteTime(source: Source, windowSpan: TimeInterval) -> Bool {
        switch source {
        case .insufficient:
            return false
        case .power:
            // The instantaneous tier. Fine once it has been watching a while,
            // misleading in the first seconds after a reset.
            return windowSpan >= settleSeconds
        case .discharge, .allTime, .observed, .blended:
            // All of these are backed by an accumulated window by construction.
            return true
        }
    }

    public var canQuoteTime: Bool {
        DrainEstimate.canQuoteTime(source: source, windowSpan: windowSpan)
    }
}

// ─────────────────────────────────────────────────────────────────────────────

extension DrainRateEstimator {
    /// The measured-discharge trend, for saving across a restart. See
    /// `BatteryDischargeTrend.Persisted` for why this is safe and what still
    /// invalidates it.
    public func persistedTrend() -> BatteryDischargeTrend.Persisted { dischargeTrend.persisted() }

    public func restoreTrend(_ p: BatteryDischargeTrend.Persisted) {
        dischargeTrend.restore(p)
    }
}

extension BatteryDischargeTrend.Persisted {

    /// Beside the history database, because it is the same kind of thing: state
    /// about this machine's battery that outlives the process.
    public static func fileURL(fileManager fm: FileManager = .default) -> URL? {
        guard let base = fm.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("Anode/discharge-trend.json")
    }

    /// nil when there is nothing saved, when it cannot be read, or when it is
    /// from a format this build does not know. Every one of those is "start
    /// fresh", which is the behaviour this replaces and therefore cannot be worse
    /// than.
    public static func load(fileManager fm: FileManager = .default)
        -> BatteryDischargeTrend.Persisted? {
        guard let url = fileURL(fileManager: fm),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BatteryDischargeTrend.Persisted.self, from: data)
    }

    /// Small and rare on purpose: a few dozen samples of five numbers, written on
    /// quit and occasionally in between. macOS has killed this app before for
    /// dirtying pages too fast, so nothing here goes near a per-tick write.
    @discardableResult
    public func save(fileManager fm: FileManager = .default) -> Bool {
        guard let url = Self.fileURL(fileManager: fm),
              let data = try? JSONEncoder().encode(self) else { return false }
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// The one figure the app has DECIDED to display, published once per tick and
/// read by every surface that shows a drain or a time left.
///
/// ## Why this is an ANCHOR and not a number
/// It used to carry `timeRemaining_hr` — a scalar, computed at publish time and
/// then held. Both of that scalar's inputs come from the gas gauge, which
/// publishes in ~60-tick batches about once a minute, so the displayed time
/// could not move between publishes and was reported from the field sitting at
/// "7h 03m" for over a minute.
///
/// Worse, one renderer added that frozen duration to a LIVE `Date()` to say when
/// the pack would die. So the headline stood still while the wall clock beside
/// it slid one second later per second, and the two halves of one row disagreed
/// about whether time was passing.
///
/// Carrying the charge and the instant it was taken instead fixes both, and adds
/// no claim: `projected` is the anchor's own arithmetic, and at the anchor it is
/// a no-op. See `DrainEstimate.projected`.
///
/// ## What it does NOT do
/// It does not feed back into `DrainRateEstimator`, whose `estimate()` is
/// documented as a pure read of accumulated state "so a UI re-render cannot
/// creep the number". That promise still holds where it matters. This type is
/// display-layer only, and a re-render is exactly when the clock should be
/// re-read.
public struct DisplayedRate {
    /// %/hr. NOT a function of the clock — only the charge is.
    public let pctHr: Double
    /// Charge on the mAh basis at `anchorAwake`. nil when nothing is known yet,
    /// and then no time is quoted at all.
    public let chargePercent: Double?
    /// `PowerMonitor.awakeSeconds()` when this anchor was taken.
    public let anchorAwake: TimeInterval
    /// Which tier answered. Carried because a figure measured from the pack's
    /// own discharge integral and one inferred from this instant's draw are not
    /// the same claim, and the renderer is where that has to become visible.
    public let source: DrainEstimate.Source
    /// How much measured history stands behind it, so the TIME can be withheld
    /// while the RATE is still shown. See `DrainEstimate.canQuoteTime`.
    public let windowSpan: TimeInterval

    /// What the lifetime model expects of the next few hours, already on the
    /// gauge's basis. nil until the model has learned this machine — the time
    /// is then the anchor's plain projection, exactly as before it existed.
    public let prior: Prior?

    /// The trailing few minutes' drain, for READING. nil until `RecentDrain`
    /// has enough to average, and off battery.
    ///
    /// Deliberately not what the time is divided from: `pctHr` is, and on a
    /// machine with history that is the all-time average — the definition of
    /// time left the user chose, and a number that by design barely moves.
    /// Shown as "Drain" it read as stuck, so the row and the widget show this
    /// instead and the time keeps its own rate.
    public let recentPctHr: Double?

    /// The rate to put in front of a person. Never use it to project a time.
    public var shownPctHr: Double { recentPctHr ?? pctHr }

    /// The lifetime forecast's inputs in %/hr at the live voltage. See
    /// `LifetimeDrainModel` and `DrainEstimate.forecastTimeToEmpty`.
    public struct Prior: Equatable {
        public let baselinePctHr: Double
        public let currentPctHr: Double
        public let tau_s: Double
        public let band: LoadBand
        public let appName: String?

        public init(baselinePctHr: Double, currentPctHr: Double, tau_s: Double,
                    band: LoadBand, appName: String?) {
            self.baselinePctHr = baselinePctHr
            self.currentPctHr = currentPctHr
            self.tau_s = tau_s
            self.band = band
            self.appName = appName
        }

        /// Which case the time is answering, in words — the provenance line
        /// under the headline.
        public var label: String { Self.label(band: band, tau_s: tau_s, appName: appName) }

        public static func label(band: LoadBand, tau_s: Double, appName: String?) -> String {
            guard band.isHigh else { return "typical use" }
            var s = "heavy load"
            if tau_s.isFinite { s += ", ~\(Int((tau_s / 60).rounded())) min" }
            if let app = appName { s += " (\(app))" }
            return s
        }
    }

    public init(pctHr: Double, chargePercent: Double?, anchorAwake: TimeInterval,
                source: DrainEstimate.Source, windowSpan: TimeInterval,
                prior: Prior? = nil, recentPctHr: Double? = nil) {
        self.recentPctHr = recentPctHr
        self.pctHr = pctHr
        self.chargePercent = chargePercent
        self.anchorAwake = anchorAwake
        self.source = source
        self.windowSpan = windowSpan
        self.prior = prior
    }

    /// Whether a time may be shown at all. A learned machine may quote one from
    /// the first tick, because the forecast rests on its history rather than on
    /// the seconds since unplugging.
    public var canQuoteTime: Bool {
        prior != nil || DrainEstimate.canQuoteTime(source: source, windowSpan: windowSpan)
    }

    /// Hours left as of `now`, on the awake clock. Defaulted so every renderer
    /// reads the same clock without each one remembering to.
    ///
    /// With a prior, the forecast is re-evaluated from the anchor's charge on
    /// every read and the awake seconds since are subtracted — the same shape as
    /// `projected`, so it counts down one second per second while the load
    /// holds, and follows the load when it moves.
    public func timeRemaining_hr(now awake: TimeInterval = PowerMonitor.awakeSeconds())
        -> Double? {
        guard let charge = chargePercent else { return nil }
        if let p = prior {
            guard let t0 = DrainEstimate.forecastTimeToEmpty(
                    chargePercent: charge, currentPctHr: p.currentPctHr,
                    baselinePctHr: p.baselinePctHr, tau: p.tau_s) else { return nil }
            let elapsed = awake - anchorAwake
            let t = elapsed.isFinite && elapsed > 0 ? t0 - elapsed : t0
            return t > 0 ? t / 3600 : nil
        }
        return DrainEstimate.projected(chargePercent: charge, ratePctHr: pctHr,
                                       elapsedAwake: awake - anchorAwake)
            .map { $0 / 3600 }
    }

    /// The instant the pack is predicted to die, given the same `now` the caller
    /// projected with. A FIXED point while the anchor stands — which is what a
    /// prediction about when something happens has to be, and what the previous
    /// `Date() + frozenHours` shape could not be.
    public func deathInstant(now: Date = Date(),
                             awake: TimeInterval = PowerMonitor.awakeSeconds()) -> Date? {
        timeRemaining_hr(now: awake).map { now.addingTimeInterval($0 * 3600) }
    }
}

// ── the rate that is shown ──────────────────────────────────────────────────

/// Mean watts leaving the pack over the last few minutes awake on battery.
///
/// Fed the same `LifetimeDrainModel.batteryWatts` figure the all-time average
/// is built from, so the two differ only in how far back they look.
///
/// Stamped on the AWAKE clock, which does not run while the lid is shut: ten
/// minutes means ten minutes of use, and a night asleep neither empties the
/// window nor counts as part of it.
public struct RecentDrain {
    /// How far back "current" looks. Short enough to follow a change in what
    /// the machine is doing, long enough to span several of the gauge's
    /// once-a-minute publishes.
    public static let window: TimeInterval = 600
    /// Below this the mean is an instant, and the caller falls back to the
    /// rate it would have shown anyway.
    public static let minimumSpan: TimeInterval = 60

    /// How far one reading may sit from the last before it counts as a jump,
    /// in %/hr. The caller converts it to watts at the live voltage.
    public static let jumpPctHr: Double = 5

    private var samples: [(awake: TimeInterval, watts: Double, dt: TimeInterval)] = []
    private var lastAwake: TimeInterval?
    private var lastWatts: Double?
    /// The window was thrown away by a jump, so what is in it is quoted
    /// however short it is. Cleared with everything else on AC.
    private var droppedByJump = false

    public init() {}

    /// `interval` is only believed for the first sample after a reset. After
    /// that each sample covers the awake time since the one before it.
    ///
    /// A snapshot's own interval cannot be used throughout: while the window is
    /// closed a full sweep runs about once a minute between the 8 s light
    /// ticks, and it reports the ~60 s since the previous SWEEP — time the
    /// light ticks in between have already been counted for. Seen live:
    /// intervals of 8, 8, 8, 59, 8, 8 … which gave one reading in eight
    /// roughly half the weight of the window.
    ///
    /// `jump_W` is the step that drops the average. A mean answers a change in
    /// load a whole window late — the machine had settled at 11 %/hr and the
    /// row still read 28 — so a reading that far from the one before it empties
    /// the window and stands on its own. While readings keep moving by that
    /// much each is shown as it arrives; the first one that does not starts the
    /// average again, from the new level. nil never drops anything.
    public mutating func observe(batteryWatts: Double, onBattery: Bool,
                                 interval: TimeInterval, awake: TimeInterval,
                                 jump_W: Double? = nil) {
        guard onBattery else {
            lastAwake = nil; lastWatts = nil; droppedByJump = false
            return samples.removeAll()
        }
        let dt = lastAwake.map { awake - $0 } ?? interval
        lastAwake = awake
        guard batteryWatts.isFinite, batteryWatts > 0, dt.isFinite, dt > 0 else { return }
        if let last = lastWatts, let jump = jump_W, jump > 0,
           abs(batteryWatts - last) >= jump {
            samples.removeAll()
            droppedByJump = true
        }
        lastWatts = batteryWatts
        // Weighted by the time each sample covers: the tick is 2 s with the
        // window open and 8 s without, and a mean of samples would let the
        // faster cadence outvote the slower.
        samples.append((awake, batteryWatts, min(dt, Self.window)))
        samples.removeAll { $0.awake <= awake - Self.window }
    }

    public var mean_W: Double? {
        let span = samples.reduce(0) { $0 + $1.dt }
        guard span > 0, droppedByJump || span >= Self.minimumSpan else { return nil }
        return samples.reduce(0) { $0 + $1.watts * $1.dt } / span
    }
}

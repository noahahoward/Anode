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
    public let timeRemaining: TimeInterval?
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
        let t = chargePercent / ratePctHr * 3600
        // A displayed time above this is a fit through noise, not a runtime a laptop
        // has. nil (the UI shows "—") rather than "412 hr".
        guard t.isFinite, t > 0, t <= 99 * 3600 else { return nil }
        return t
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
    private var powerHistory: [(t: Date, pctHr: Double)] = []

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
    private static let crossCheckFactor = 3.0

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
               discharge: BatteryDischargeTrend.Sample.sample(at: at), at: at)
    }

    /// Raw-value entry point. Public so harnesses/tests can drive the
    /// estimator with synthetic history (`Battery.State` has no public init).
    ///
    /// `discharge` nil means the accumulator was unreadable this tick; the trend
    /// simply does not advance and the regression below carries the estimate.
    public func record(remainingCapacity_mAh: Double, onAC: Bool, isCharging: Bool,
                       scale: BatteryScale, powerBased_pctHr: Double?,
                       discharge: BatteryDischargeTrend.Sample? = nil,
                       at now: Date = Date()) {
        if scale.fullChargeCapacity_mAh > 0 { fullCharge_mAh = scale.fullChargeCapacity_mAh }
        if let p = powerBased_pctHr, p.isFinite, p >= 0 {
            lastPower = (p, now)
            // Recorded before the AC guard below and never on a clock that went
            // backwards, so the buffer is always in order and always covers the
            // trend's window whenever the trend has one.
            if let lastT = powerHistory.last?.t, now < lastT { powerHistory.removeAll() }
            powerHistory.append((now, p))
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
    private func agreesWithMeasuredPower(_ rate_pctHr: Double,
                                         over span: TimeInterval,
                                         at now: Date) -> Bool {
        guard span > 0, rate_pctHr > 0 else { return true }
        let cutoff = now.addingTimeInterval(-span)
        var lo = powerHistory.count
        while lo > 0 && powerHistory[lo - 1].t >= cutoff { lo -= 1 }
        let n = powerHistory.count - lo
        guard n >= 2 else { return true }
        guard now.timeIntervalSince(powerHistory[lo].t) >= 0.8 * span else { return true }

        var sum = 0.0
        for i in lo..<powerHistory.count { sum += powerHistory[i].pctHr }
        let mean = sum / Double(n)
        // Below this the ratio is dominated by the resolution of the power figure
        // itself, not by any disagreement — a machine drawing a tenth of a percent
        // an hour has nothing to cross-check.
        guard mean > 0.1 else { return true }
        return max(rate_pctHr / mean, mean / rate_pctHr) <= Self.crossCheckFactor
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
            if let p = power, !agreesWithMeasuredPower(trendRate, over: t.span, at: last.t) {
                return DrainEstimate(
                    percentPerHour: p,
                    timeRemaining: DrainEstimate.timeToEmpty(chargePercent: remainingPct,
                                                             ratePctHr: p),
                    confidence: 0,
                    source: .power,
                    // The same pair the ordinary power tier reports: how much
                    // history has ACCUMULATED, not the span of a window this
                    // figure did not come from.
                    windowSpan: slowFit?.span ?? 0,
                    sampleCount: samples.count)
            }
            return DrainEstimate(
                percentPerHour: trendRate,
                timeRemaining: DrainEstimate.timeToEmpty(chargePercent: remainingPct,
                                                         ratePctHr: trendRate),
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
            return DrainEstimate(percentPerHour: 0, timeRemaining: nil, confidence: 0,
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
                             confidence: confidence,
                             source: source,
                             windowSpan: span,
                             sampleCount: count)
    }
}

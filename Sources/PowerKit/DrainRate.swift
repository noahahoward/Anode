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
public struct DrainEstimate {
    public enum Source: String, Sendable {
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

    /// Blended drain rate in %/hr, always >= 0. Check `source` for provenance.
    public let percentPerHour: Double
    /// Slew-limited time to empty — THE value to display. nil when unknowable
    /// (on AC, rate ≈ 0, or no data): show "—", never a substitute number.
    public let timeRemaining: TimeInterval?
    /// Pre-slew time to empty, for diagnostics only. Never display directly —
    /// it jumps exactly the way the slew limit exists to prevent.
    public let rawTimeRemaining: TimeInterval?
    /// 0…1: the weight observed history carried in the blend.
    public let confidence: Double
    public let source: Source
    /// Span of the history window behind the estimate (0 when none).
    public let windowSpan: TimeInterval
    /// Samples inside that window.
    public let sampleCount: Int
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

    // ── Slew limiter for the DISPLAYED time (kills "3 hrs then 9 hrs") ─────
    /// Max relative change of the displayed time per update.
    private let slewRel = 0.12
    /// Absolute floor on the allowed change so small values can still move.
    /// Kept modest (2 min): at very low charge the absolute time is small and
    /// the user explicitly wants it steady there.
    private let slewFloor: TimeInterval = 120
    private var displayedTime: TimeInterval?
    private var lastSlewKey: Date?

    /// A displayed time above this is a fit through noise, not a runtime a
    /// laptop has. Return nil (UI shows "—") rather than "412 hr".
    private let maxDisplayableTime: TimeInterval = 99 * 3600
    /// Below this rate the division blows up toward the cap above; treat as
    /// "not meaningfully draining" and return nil.
    private let minRate_pctHr = 0.1

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

    public init(fastWindow: TimeInterval = 600, slowWindow: TimeInterval = 3600) {
        self.fastWindow = max(60, fastWindow)
        self.slowWindow = max(self.fastWindow, slowWindow)
    }

    // ── Recording ───────────────────────────────────────────────────────────

    /// Convenience wrapper over the raw-value `record`. Call once per monitor
    /// tick (~5 s); the estimator itself notices which ticks carry a new gauge
    /// publish.
    public func record(state: Battery.State, scale: BatteryScale,
                       powerBased_pctHr: Double?, at: Date = Date()) {
        record(remainingCapacity_mAh: state.remainingCapacity_mAh,
               onAC: state.onAC, isCharging: state.isCharging,
               scale: scale, powerBased_pctHr: powerBased_pctHr, at: at)
    }

    /// Raw-value entry point. Public so harnesses/tests can drive the
    /// estimator with synthetic history (`Battery.State` has no public init).
    public func record(remainingCapacity_mAh: Double, onAC: Bool, isCharging: Bool,
                       scale: BatteryScale, powerBased_pctHr: Double?, at now: Date = Date()) {
        if scale.fullChargeCapacity_mAh > 0 { fullCharge_mAh = scale.fullChargeCapacity_mAh }
        if let p = powerBased_pctHr, p.isFinite, p >= 0 { lastPower = (p, now) }

        let onBattery = !onAC && !isCharging
        guard onBattery else {
            // AC transition: charge going UP is not drain, and mixing the two
            // poisons the fit. Drop everything; the power figure carries the
            // display until battery history rebuilds. Slew state goes too —
            // the charge level may move arbitrarily while plugged in, so the
            // next displayed time legitimately starts fresh.
            if wasOnBattery || !samples.isEmpty { resetHistory(clearSlew: true) }
            wasOnBattery = false
            return
        }
        if !wasOnBattery { resetHistory(clearSlew: true) }  // fresh discharge segment
        wasOnBattery = true

        let mAh = remainingCapacity_mAh
        guard mAh.isFinite, mAh > 0 else { return }         // gauge glitch: skip, never poison
        // Anomalies below reset the HISTORY but keep the slew state: we are
        // still on battery and still displaying, and a discontinuity in the
        // shown time is precisely what this class exists to prevent.
        if let t = samples.last?.t, now < t { resetHistory(clearSlew: false) }  // clock went backwards
        // MEASURED on this machine: the gauge can revise RemainingCapacity
        // UP by ~11 mAh mid-discharge (voltage-relaxation recovery). Small
        // rises are gauge noise and belong in the fit — regression absorbs
        // them. Only a rise too big to be noise (~0.5% of pack) means the
        // AC/charging flags lied and the history is genuinely poisoned.
        if let lm = lastMAh, mAh > lm + max(8, 0.005 * (fullCharge_mAh ?? 6000)) {
            resetHistory(clearSlew: false)
        }

        let isNewPublish = (mAh != lastMAh)
        samples.append(Sample(t: now, mAh: mAh, onBattery: true))
        lastMAh = mAh
        prune(now: now)
        if isNewPublish { arbitrate() }
    }

    public func reset() {
        resetHistory(clearSlew: true)
        wasOnBattery = false
        lastPower = nil
        fullCharge_mAh = nil
    }

    private func resetHistory(clearSlew: Bool) {
        samples.removeAll(keepingCapacity: true)
        lastMAh = nil
        divergeStreak = 0
        preferFast = false
        if clearSlew {
            displayedTime = nil
            lastSlewKey = nil
        }
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

    // ── Estimation ──────────────────────────────────────────────────────────

    /// nil while on AC (time-to-empty is meaningless while plugged in — the
    /// SBS gauge returns its 65535 sentinel there for the same reason) or when
    /// nothing has been recorded. Otherwise always returns something, with
    /// `source` saying how much of it is measured.
    ///
    /// Call after each `record()`. Extra calls between records return the same
    /// displayed value — the slew limiter only advances on new data, so a UI
    /// re-render cannot creep the number.
    public func estimate() -> DrainEstimate? {
        guard wasOnBattery, let last = samples.last,
              let full = fullCharge_mAh, full > 0 else { return nil }

        let slowFit = fit(window: slowWindow)
        let chosen = preferFast ? (fit(window: fastWindow) ?? slowFit) : slowFit
        let power: Double? = {
            guard let p = lastPower, last.t.timeIntervalSince(p.at) <= powerMaxAge else { return nil }
            return p.pctHr
        }()

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
                                 rawTimeRemaining: nil, confidence: 0,
                                 source: .insufficient,
                                 windowSpan: slowFit?.span ?? 0,
                                 sampleCount: samples.count)
        }

        // Time remaining from the mAh-derived FRACTIONAL percent, not the
        // coarse integer `percent` — at 6197 mAh, 1 integer % is ~62 mAh of
        // invisible movement.
        let remainingPct = last.mAh / full * 100
        var raw: TimeInterval? = nil
        if rate >= minRate_pctHr, rate.isFinite {
            let t = remainingPct / rate * 3600
            if t.isFinite, t > 0, t <= maxDisplayableTime { raw = t }
        }
        let displayed = slew(target: raw, key: last.t)

        return DrainEstimate(percentPerHour: max(0, rate),
                             timeRemaining: displayed,
                             rawTimeRemaining: raw,
                             confidence: confidence,
                             source: source,
                             windowSpan: span,
                             sampleCount: count)
    }

    /// Cap how far the displayed time may move per NEW sample:
    /// max(12% of current, 2 min). This is the direct fix for "3 hrs then
    /// 9 hrs": a wild new target drags the display a bounded step, and only a
    /// target that persists walks it the whole way. Keyed on the sample
    /// timestamp so repeated estimate() calls on the same data are idempotent.
    private func slew(target: TimeInterval?, key: Date) -> TimeInterval? {
        if lastSlewKey == key { return displayedTime }
        lastSlewKey = key
        guard let target else { displayedTime = nil; return nil }
        guard let current = displayedTime else { displayedTime = target; return target }
        let maxStep = max(slewRel * current, slewFloor)
        displayedTime = current + min(max(target - current, -maxStep), maxStep)
        return displayedTime
    }
}

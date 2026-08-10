import Foundation

/// Where charging will actually stop, and how long the last stretch really takes.
///
/// ## The machine will not tell us the limit
///
/// Every property of `AppleSmartBattery`, `AppleSmartBatteryManager`,
/// `IOPMPowerSource` and `IOPMrootDomain` was enumerated on this machine
/// (Mac17,9, macOS 27) looking for a stated charge limit. There is no such key:
/// nothing named `ChargeLimit`, `Optimized*`, `*Target*`, `*Threshold*` or
/// `MaxCharge*` exists at any level, the `BatteryData` sub-dictionary carries only
/// capacity fields, and `pmset` reports nothing either. The limit is enforced
/// somewhere we cannot read.
///
/// What the machine DOES publish is the consequence: `ChargerData` gains
/// `NotChargingReason` = 128 while it sits on the adapter refusing to charge, with
/// `FullyCharged` false and `IsCharging` false. So the limit is INFERRED, never
/// read — the level at which the machine deliberately stops IS the limit, and it
/// is learned by watching for that stop and remembered across launches (the same
/// bargain `USBPowerTracker` makes with device costs).
///
/// TRAP, verified: `NotChargingReason` keeps its last value after the adapter is
/// unplugged. Read live at 83% on battery it still said 128. Every rule below is
/// therefore gated on `onAC` — without that gate the machine would "learn" a limit
/// at whatever charge it happened to be unplugged at.
///
/// ## What the history says this machine does
///
/// Four charge sessions in `history.sqlite` (08-08 to 08-09, 1-minute buckets):
///
///     41.0 -> 80.0 %   then held at exactly 80.0 for  91 min
///     72.0 -> 80.0 %   then held at exactly 80.0 for  68 min
///     32.0 -> 80.0 %   then held at exactly 80.0 for 435 min (overnight)
///     61.0 -> 83.0 %   (and one 80 -> 92 run at 04:43)
///
/// So 80% is the limit, and it is NOT absolute — the machine tops up past it
/// sometimes. A remembered limit therefore has to yield the moment charge is
/// observed above it, which `target(atPercent:isCharging:)` does.
public enum ChargeTarget {

    /// The level charging is heading for, as a percent on the mAh basis
    /// (`BatteryScale.chargePercent`), and where that number came from.
    public struct Level: Equatable {
        public let percent: Double
        /// True when `percent` is a limit this machine was seen to stop and hold
        /// at, false when it is the pack's own 100% because no limit is known.
        /// The UI has to say which: "45 min to 80%" and "45 min to full" are
        /// different claims and only one of them is going to happen.
        public let isLearnedLimit: Bool
    }

    /// A time-to-target, which is ALWAYS an estimate — see `hours`.
    public struct Estimate: Equatable {
        /// Hours until charging stops. A projection into a future nobody has
        /// measured; `MetricValue.isEstimate` must be true wherever this is shown,
        /// for exactly the reason time-to-empty is marked (see MetricRegistry's
        /// note on `.timeLeft`): the RATE behind it is measured, the future is not.
        public let hours: Double
        public let target: Level
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// The taper: what the constant-current model gets wrong at the end of a charge.
///
/// ## Measured, not assumed
///
/// A lithium pack charges constant-current then constant-voltage, and the CV tail
/// is the part that takes forever — so the first thing checked was whether this
/// machine's rate falls off with charge level at all. Per-minute rates from the
/// four sessions above, regressed WITHIN each session (pooling them is
/// meaningless: session mean rates were 80.9, 71.6, 45.7 and 62.8 %/hr, so
/// between-session spread of 1.8x swamps any trend inside one):
///
///     24 -> 43 %   slope +0.06 %/hr per point   R² = 0.001   flat
///     42 -> 80 %   slope -0.45                  R² = 0.18    flat but for the end
///
/// It is FLAT. There is no gradual taper below 80% on this pack, and the one run
/// that went to 92% was still holding 60 %/hr at 91%. The knee is somewhere above
/// 92%, which this machine — limited to 80 — essentially never reaches. No curve
/// is claimed for that region because none has ever been observed here.
///
/// ## What is real is the last step into the target
///
/// The final recorded step before the machine stopped, against that session's own
/// constant-current rate:
///
///     session      stop   CC rate    final step        took   CC predicts   extra
///     08-08 18:19  80.0   71.6 %/hr  79.9 -> 80.0      1 min    0.08 min   +0.92
///     08-08 21:19  80.0   45.7 %/hr  79.7 -> 80.0      1 min    0.34 min   +0.66
///
/// and the CONTROL — the two sessions that were UNPLUGGED mid-charge rather than
/// reaching a limit, where no taper should appear and none does:
///
///     08-08 15:25  44.0   80.7 %/hr  42.8 -> 44.0      1 min    0.87 min   +0.13
///     08-09 16:11  83.0   61.6 %/hr  82.1 -> 83.0      1 min    0.84 min   +0.16
///
/// The extra minute appears only where charging actually terminated. That
/// separation is the evidence; the constant below is its mean.
public enum ChargeCurve {

    /// Extra time the charger spends easing into a limit, beyond what the measured
    /// current accounts for. Mean of the +0.92 and +0.66 min above.
    ///
    /// This is a FIT, not a measurement, and a thin one — two terminating sessions.
    /// Leave-one-session-out is honest about that: holding out the first session
    /// beats constant-current (MAE 1.20 vs 1.66 min), holding out the second loses
    /// to it (1.00 vs 0.76). In-sample across all 45 ground-truth samples it is a
    /// clear improvement — MAE 1.44 -> 1.00 min, median 1.29 -> 0.70, and the
    /// systematic bias that matters most falls from -1.19 min to -0.39 — but the
    /// value it produces is an estimate and is marked as one.
    ///
    /// The history's 1-minute buckets are also the resolution floor here: both
    /// terminal steps are recorded as "1 min" because that is the smallest a
    /// bucket can be, so the true cost is somewhere at or under a minute and this
    /// constant cannot be sharpened without finer sampling.
    ///
    /// Kept deliberately small in the scheme of things. It is worth saying plainly
    /// which of this file's two fixes matters: on these same sessions, projecting
    /// to 100% instead of to the real 80% limit overstated the remaining time by
    /// 15, 16 and 28 minutes. The taper is worth under one.
    public static let terminalTaper_hr = 0.8 / 60.0

    /// Hours to close `headroom` percentage points at a measured `rate_pctHr`.
    ///
    /// `tapers` is false when the target is the pack's own 100%: the constant above
    /// was measured against an 80% limit, and nothing has ever been observed above
    /// 92% on this machine, so spending it on a target whose approach was never
    /// sampled would be fabricating a number to fill a gap.
    ///
    /// Nil rather than a guess when there is no rate to project, or when the pack
    /// is already at or past the target.
    public static func hours(headroom_pct: Double, rate_pctHr: Double, tapers: Bool) -> Double? {
        guard rate_pctHr > 0, headroom_pct > 0 else { return nil }
        let h = headroom_pct / rate_pctHr + (tapers ? terminalTaper_hr : 0)
        return h.isFinite ? h : nil
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Learns the level this machine stops charging at, and remembers it.
///
/// The rule is the inference described at the top of this file: on AC, not
/// charging, not full, with a non-zero `NotChargingReason`, held long enough that
/// it is a decision rather than a pause — then this charge level is the limit.
///
/// Thread-safe because `PowerMonitor.tick` runs on a sampling queue while the UI
/// reads the learned limit off the snapshot on the main one.
public final class ChargeLimitLearner {

    /// How long the machine must sit refusing to charge before that is read as a
    /// limit rather than a hiccup. The three genuine holds in history lasted 68,
    /// 91 and 435 minutes and every one of them was already steady within a single
    /// 1-minute bucket of arriving, so a five-minute wait costs nothing real and
    /// rejects a transient pause — a thermal throttle, or the settle between the
    /// charger topping off and the gauge catching up.
    ///
    /// `NotChargingReason` is required to be non-zero but its VALUE is not matched
    /// against anything. This machine reports 128 while holding at 80%; that is one
    /// observation of one undocumented field, and turning it into a magic number
    /// would be asserting a meaning nobody has verified.
    static let holdToConfirm: TimeInterval = 300

    /// Below this a refusal to charge is a fault, not a preference — a dead
    /// adapter or a cold pack — and must not be remembered as the user's limit.
    static let plausibleFloor = 20.0
    /// At or above this the pack is simply full and `FullyCharged` says so;
    /// there is no limit to learn and nothing for the UI to do differently.
    static let plausibleCeiling = 99.0

    /// How far above a remembered limit the charge has to climb before the limit
    /// is treated as not binding. The gauge's mAh basis wanders a few hundredths
    /// of a point at rest, and one session genuinely ran 80 -> 92, so this only
    /// has to clear the noise.
    static let overshootTolerance = 0.5

    private let lock = NSLock()
    private let defaults: UserDefaults
    private static let storeKey = "com.betterstats.charge.limitPercent.v1"

    /// The remembered limit, or nil until one has ever been confirmed.
    private var learned: Double?
    /// Start of the current uninterrupted hold, and the level it started at.
    /// Cleared by anything that is not a steady on-AC refusal to charge.
    private var holdSince: Date?
    private var holdAt: Double?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.double(forKey: Self.storeKey)
        if stored >= Self.plausibleFloor && stored <= Self.plausibleCeiling {
            learned = stored
        }
    }

    /// Feed one battery reading. `percent` is on the mAh basis
    /// (`BatteryScale.chargePercent`), the same basis every projection in this app
    /// divides, so the learned limit and the headroom subtracted from it agree.
    public func observe(_ s: Battery.State, percent: Double, at now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        // The gate that makes the stale `NotChargingReason` harmless: off AC there
        // is nothing to refuse, so nothing here is evidence of anything.
        let holding = s.onAC && !s.isCharging && !s.fullyCharged
            && s.notChargingReason != 0
            && percent >= Self.plausibleFloor && percent <= Self.plausibleCeiling

        guard holding else {
            holdSince = nil
            holdAt = nil
            return
        }

        // A hold that DRIFTS is not a hold. If the level moved the machine is
        // still settling, so the clock restarts at the new level rather than
        // crediting the elapsed time to a level that no longer applies.
        if let at = holdAt, abs(percent - at) > 0.5 {
            holdSince = now
            holdAt = percent
            return
        }
        if holdSince == nil {
            holdSince = now
            holdAt = percent
            return
        }

        guard let since = holdSince, now.timeIntervalSince(since) >= Self.holdToConfirm
        else { return }

        // Overwritten, not averaged. A limit is a SETTING, not a noisy measurement
        // of a moving quantity — USBPowerTracker averages device watts because a
        // phone's draw really does change, but if this user moves the limit from
        // 80 to 100 the mean of the two is a level the machine will never stop at.
        // The latest confirmed hold is the current truth.
        if learned != percent {
            learned = percent
            defaults.set(percent, forKey: Self.storeKey)
        }
    }

    /// The remembered limit, or nil if none has ever been confirmed.
    public var limit: Double? {
        lock.lock(); defer { lock.unlock() }
        return learned
    }

    /// Where charging is heading right now.
    ///
    /// Falls back to the pack's own 100% when no limit is known, and — this is the
    /// part the remembering makes necessary — ALSO when charge is already above the
    /// remembered limit while still climbing. The machine tops up past its limit
    /// sometimes (one session ran 80 -> 92), and reporting "already at the limit"
    /// while the gauge visibly rises would be the same lie in the other direction.
    public func target(atPercent percent: Double, isCharging: Bool) -> ChargeTarget.Level {
        guard let l = limit else { return ChargeTarget.Level(percent: 100, isLearnedLimit: false) }
        if isCharging && percent > l + Self.overshootTolerance {
            return ChargeTarget.Level(percent: 100, isLearnedLimit: false)
        }
        return ChargeTarget.Level(percent: l, isLearnedLimit: true)
    }
}

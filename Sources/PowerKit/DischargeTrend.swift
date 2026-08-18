import Foundation

/// The battery's own discharge INTEGRAL, and the half-hour trend built from it.
///
/// ## Why a third signal at all
/// `DrainRateEstimator` fits a line through `BatteryData.RemainingCapacity`. That
/// field is the gauge's ESTIMATE of state of charge, and it is noisy in a way no
/// filter can remove: over 10 minutes of real publishes on this machine consecutive
/// values moved −26, +16, +5, −4, −42, +29, −27, +7, −14, −29 mAh (sd 21.6) against
/// a true drain of ~6.4 mAh per publish. FOUR OF TEN publishes went UP while the
/// pack was discharging. `FullChargeCapacity`, the denominator, wandered 6177…6213
/// over the same ten minutes.
///
/// `PowerTelemetryData.AccumulatedBatteryDischarge` is a different KIND of number: a
/// running integral of measured battery power in mW·ticks, paired with
/// `BatteryDischargeAccumulatorCount`, which advances at 1 Hz while the pack
/// discharges. Its delta cannot go the wrong way, because it is not a re-estimate of
/// anything — it is energy that has already left the pack. Measured over the same
/// windows it is 7.4x less noisy than differencing `RemainingCapacity` (sd 4.31 vs
/// 31.84 %/hr) and never negative.
///
/// Units verified live on this machine (Mac17,9): across one 60-tick window the
/// delta ratio read −4104.8 mW while the scalar `BatteryPower` snapshots either side
/// read −4071 and −4240 mW; −4104.8 mW ÷ 11878 mV = 345.6 mA, and 3667 mAh ÷ 345.6 mA
/// = 637 minutes against the gauge's own `TimeRemaining` of 636. Same convention
/// `SystemPowerWindow` already relies on for `AccumulatedSystemLoad`.
///
/// This counter is battery-specific in a way `AccumulatedSystemLoad` is not: on this
/// machine the discharge count stood at 72,367 against a system-load count of
/// 245,047, i.e. it advances only while running on the pack. `AccumulatedSystemLoad`
/// keeps counting on AC, where it measures the ADAPTER's load and not drain at all.
///
/// ## Why the window is HALF AN HOUR
/// One 60 s window is an exact measurement of one minute, and one minute of `swift
/// build` is not the question being asked. Time-to-empty is a TREND quantity — "when
/// does this die", not "what am I drawing right now", which is a different number
/// with its own row. Over a 30-minute window a one-minute spike carries 1/30 of the
/// weight, so a build or a video call moves the answer by a few percent instead of
/// halving it.
///
/// The mean over the window needs no buffer of rates and no filter: because the
/// counter is cumulative, the mean over the whole window is exactly
/// `(newest − oldest) / (ticks between them)`. Every intermediate publish is
/// accounted for at exactly its own duration, including the short ones — `dCount`
/// has been observed at 33, 58 and 59 as well as 60, so a mean over SAMPLES rather
/// than over TICKS would silently misweight them.
///
/// ## Why the window can still move quickly
/// A window this long would take half an hour to crawl to a genuine sustained load
/// change, which is too slow to be honest about a real one. So the trend also
/// watches each incoming window against a reference: five unbroken MINUTES of
/// windows that all disagree with it, all in the same direction, are a regime
/// change rather than noise — the accumulator has no estimation noise for them to
/// be — and the window collapses onto them.
///
/// A one- or two-minute spike cannot reach that, which is the whole point, and it
/// does not need to: the mean already holds a 60 s spike to a thirtieth of its
/// weight. Measured, against the pre-change path:
///
///     event                        old moves    new moves
///     60 s spike to 3x             245 min      44 min
///     120 s spike to 3x            247 min      63 min
///     sustained 3x                 376 s        300 s   (to settle within 12 %)
///     sustained 1.67x              420 s        300 s
///     sustained 1.25x             1094 s        960 s
///
/// A FIVE-minute burst does move it, by design: five minutes at three times the
/// trend is not a swing, it is what the machine is doing now.
///
/// ## How much disagreement counts: scaled by the reference's own noise
/// How big that disagreement must be cannot be one number. Reported from the
/// field (2026-08-16): sixteen minutes of build at a measured 8.39 W, then the
/// machine settled to a measured 4.95 W — a 41 % sustained drop — and the display
/// held the build's time-to-empty for the whole half-hour roll-off. But the sweep
/// (`TrendSweepHarness`, committed beside the tests) shows a fixed band low
/// enough to catch that drop is catastrophic on a bursty load: the base stretches
/// between build bursts sit 35–45 % below the running mean, indistinguishable
/// from a settle by magnitude and duration, and adopting them scores 27–59
/// death-time minutes of error against 16 for leaving them alone. No fixed band
/// separates the two cases.
///
/// What separates them is the reference itself. Before a real settle the window
/// is QUIET — publish after publish of the same load, relative sd near zero.
/// A bursty window's own publishes disagree with each other by ~70 %. So the band
/// scales with the reference's tick-weighted relative standard deviation:
/// max(0.30, 3·relSD). On the settle that is 0.30 and the drop confirms in five
/// minutes; on the bursty load it is ~2 and the detector is silent, where the
/// old fixed 0.50 band was NOT: scored over a full hour rather than the original
/// fifteen minutes, the fixed band collapsed spuriously on 0.50 of build-like
/// traces — a 3-minute 54 W burst pushes a half-hour mean past 9 W, which puts
/// the 4.5 W base more than 50 % below it — a latent defect the shorter horizon
/// never saw. Swept over 234 configurations: this configuration scores
/// IDENTICALLY to the fixed band on every accuracy metric (wander, bursty,
/// spike, swing), zeroes the spurious-collapse rate the fixed band failed, and
/// follows the field-reported settle in 300 s where the fixed band took 1560.
/// (3·relSD, not 2: at 2 one build-like trace in forty still collapsed; at 3
/// none do, and nothing else moves.)

public final class BatteryDischargeTrend {

    /// One reading of the discharge accumulator plus what is needed to turn it into
    /// a rate. Values, not IOKit calls, so tests and harnesses can drive this.
    public struct Sample: Codable {
        /// `AccumulatedBatteryDischarge`. SIGNED and NEGATIVE while discharging, so
        /// it counts DOWN; the delta is taken in two's complement so a wrap through
        /// either end of the range is still the true difference.
        public let accumulatedDischarge: Int64
        /// `BatteryDischargeAccumulatorCount`, 1 Hz, published in ~60-tick batches.
        public let accumulatorCount: UInt64
        /// Pack terminal voltage at publish time. The accumulator measures POWER;
        /// charge is what runs out, and only the measured voltage relates them.
        public let voltage_mV: Double
        public let timestamp: Date
        /// `PowerMonitor.awakeSeconds()` at the same instant. Wall time alone cannot
        /// tell an hour of work from an hour of sleep.
        public let awake: TimeInterval

        public init(accumulatedDischarge: Int64, accumulatorCount: UInt64,
                    voltage_mV: Double, timestamp: Date, awake: TimeInterval) {
            self.accumulatedDischarge = accumulatedDischarge
            self.accumulatorCount = accumulatorCount
            self.voltage_mV = voltage_mV
            self.timestamp = timestamp
            self.awake = awake
        }

        /// Live read, which always pairs the wall clock with the live awake clock —
        /// tests build a `Sample` directly so they can drive the two apart and
        /// simulate a sleep. Shares `Battery.properties()`' 0.25 s cache with the
        /// rest of the tick, so this costs no extra IORegistry traversal when it is
        /// taken alongside `Battery.state()`.
        public static func sample(at now: Date = Date()) -> Sample? {
            let awake = PowerMonitor.awakeSeconds()
            guard let props = Battery.properties(),
                  let t = props["PowerTelemetryData"] as? [String: Any],
                  let count = (t["BatteryDischargeAccumulatorCount"] as? NSNumber)?.uint64Value,
                  let acc = (t["AccumulatedBatteryDischarge"] as? NSNumber)?.int64Value,
                  count > 0
            else { return nil }
            let mV = (props["Voltage"] as? NSNumber)?.doubleValue ?? 0
            guard mV > 0 else { return nil }
            return Sample(accumulatedDischarge: acc, accumulatorCount: count,
                          voltage_mV: mV, timestamp: now, awake: awake)
        }
    }

    /// The exact mean discharge between two accumulator readings.
    ///
    /// nil when no new batch has published yet, when the counters imply something
    /// impossible, or when the pack was not discharging over the interval. Never a
    /// number derived by dividing by wall-clock time: the counter runs at 1 Hz but is
    /// only ever OBSERVED in ~60-tick jumps, so wall-clock division is what made the
    /// original menu bar swing 4.8 → 10.08 → 5.0 %/hr.
    public struct Window {
        /// Mean battery power over the window, mW, POSITIVE while discharging.
        public let power_mW: Double
        public let ticks: UInt64
        public let span: TimeInterval

        public static func between(_ a: Sample, _ b: Sample) -> Window? {
            // Counters wrap. `AdapterEfficiencyLoss` has been observed at 2^64−119
            // in a live sample, so every monotonic counter here uses wrapping
            // arithmetic — and the same plausibility rule as `SystemPowerWindow`,
            // because `&-` renders a wrap and a RESET identically and only the
            // answer's size tells them apart.
            let dCount = b.accumulatorCount &- a.accumulatorCount
            guard dCount > 0, dCount < SystemPowerWindow.maxPlausibleTicks else { return nil }

            // Two's complement difference: correct across a wrap at either end of
            // the range, and correctly NEGATIVE while discharging because the
            // counter accumulates negative battery power.
            let dDischarge = Int64(bitPattern:
                UInt64(bitPattern: b.accumulatedDischarge) &- UInt64(bitPattern: a.accumulatedDischarge))
            // A non-negative delta is not drain: either the pack gained charge or the
            // counter was reset. Report nothing rather than a sign-flipped rate.
            guard dDischarge < 0 else { return nil }

            let mW = Double(-dDischarge) / Double(dCount)
            guard mW.isFinite, mW <= SystemPowerWindow.maxPlausible_mW else { return nil }
            return Window(power_mW: mW, ticks: dCount,
                          span: b.timestamp.timeIntervalSince(a.timestamp))
        }
    }

    public struct Trend {
        /// Mean battery power over the whole window, mW.
        public let power_mW: Double
        /// The same power at the pack's mean measured voltage over that window.
        /// This — not an assumed nominal voltage — is what converts an energy
        /// integral into the charge that actually runs out.
        public let current_mA: Double
        /// 1 Hz ticks the mean covers. The honest span: it excludes anything the
        /// window was reset across, and it is not wall-clock time.
        public let ticks: UInt64
        public let span: TimeInterval
        public let publishes: Int
        /// True once the window holds its full length. A shorter window is still an
        /// exact measurement, of a shorter period — not a guess — but a caller may
        /// want to say which.
        public let isFull: Bool
    }

    // ── Sizing, all measured ────────────────────────────────────────────────
    /// 30 minutes.
    ///
    /// Scored against the thing actually being asked for — the wall time until the
    /// pack really reached zero, taken from the simulated future rather than from
    /// "charge ÷ the load at this instant", which structurally rewards an
    /// instantaneous estimator and is not what an ETD is. Two 3 h loads: a 4-9 W
    /// random walk, and a bursty one (4 min at 20 W every 20 min, the shape a real
    /// machine has — the recorded trace from this machine swung 4.1 W to 54 W in
    /// minute-scale bursts of `swift build`).
    ///
    ///     window   MAE wander   MAE bursty   60 s spike moves it   1.25x change followed in
    ///      600 s      5.8          11.9           70 min (20 %)            360 s
    ///     1200 s      5.4           3.0           53 min (15 %)            660 s
    ///     1800 s      4.5           5.0           44 min (12 %)            960 s
    ///     2700 s      3.8           4.6           38 min (11 %)           1430 s
    ///     3600 s      2.9           4.6           34 min (10 %)           1854 s
    ///     (pre-change path: 10.5, 13.6, 245 min (68 %), 1094 s)
    ///
    /// Accuracy keeps improving with length because these loads are statistically
    /// stationary and a real day is not. What a longer window costs is the LAST
    /// column: a sustained change too small to trip the detector below is followed
    /// by the window and nothing else, and that latency is linear in the window.
    /// 1800 s answers within 1.6 min of the best window on both loads, holds a
    /// one-minute spike to a twelfth of the answer, and still notices a 25 % change
    /// in a quarter of an hour rather than half of one.
    private let window: TimeInterval
    /// Below five published windows there is not yet a trend to speak of; the
    /// caller falls back to the power-based figure and says so, and the UI marks
    /// it. (The cold-start measurement that sized the original two-minute floor:
    /// the fallback carried the first 120 s reading 289-457 min against a truth
    /// of 439-444, after which the trend took over and sat within 5 min of the
    /// truth. The floor has since been raised to 300 — see the initializer's
    /// comment for the 25-hour headline that forced it — so the fallback now
    /// carries five minutes.)
    ///
    /// TICKS rather than seconds because the counter, not the clock, is what the
    /// mean is over — a window is only as long as the discharge it accumulated.
    private let minTicks: UInt64
    /// The FLOOR of the fractional disagreement that counts as evidence of a
    /// regime change; the effective band is max(this, `noiseScaledBand`·relSD of
    /// the reference). There is no measurement noise for this to clear — the
    /// counter is an integral — so the pair is chosen purely on how much real
    /// change is worth restarting the window for, jointly with `confirmTicks`.
    ///
    /// It was a fixed 0.50 for the reasons the original table records (its
    /// scoring harness was never committed; the numbers are kept because the
    /// ORDERINGS were re-verified in `TrendSweepHarness`, which is):
    ///
    ///     confirm  band    MAE wander   MAE bursty   mean|Δ|/tick   worst swing in 2 min
    ///      180 s   0.25        6.0         19.3          0.09              58
    ///      180 s   0.35        5.5         19.3          0.09              58
    ///      300 s   0.35        4.5         10.3          0.05              31
    ///      300 s   0.50        4.5          5.0          0.04              14
    ///      600 s   0.50        4.5          5.0          0.04              14
    ///     (pre-change path:   10.5         13.6          0.29              85)
    ///
    /// — i.e. on a bursty load, lowering a FIXED band is a measured regression:
    /// the base stretches between bursts sit 35–45 % below the mean and a low
    /// fixed band adopts them. But 0.50 could not see the 2026-08-16 settle
    /// (a 41 % sustained drop after a build; see the class comment), and no fixed
    /// value separates the two — the magnitudes overlap. The committed sweep
    /// (234 configurations, `ANODE_TREND_SWEEP=1 swift test --filter TrendSweep`)
    /// found the separation in the reference's own noise instead: 0.30 with the
    /// 3·relSD term scores identically to 0.50 on every column above and follows
    /// the settle in 300 s where 0.50 took 1560. 0.30 rather than 0.35 for margin
    /// under the 0.41 drop the field actually reported.
    private let changeBand: Double
    /// How long the disagreement must persist, in accumulator TICKS, before the
    /// trend is restarted on it. 300 = five minutes of measured discharge, and it is
    /// what sets the response to a genuine sustained change: a load change big
    /// enough to clear `changeBand` is followed in 300 s, one below it in ~960 s by
    /// the window alone. See the table above for why five and not three.
    ///
    /// Ticks and not publishes: this machine batches 60 ticks at a time, so five
    /// publishes and five minutes are the same thing here — but the cadence is
    /// undocumented, and counting publishes on hardware that batched every 10 s
    /// would restart the trend on a 50-second spike, which is exactly the failure
    /// this design exists to prevent. Measured in the harness while it had that bug:
    /// a 60 s spike moved the answer 246 minutes.
    private let confirmTicks: UInt64

    /// Band for a disagreement BELOW the trend, when it differs from `changeBand`.
    /// nil = symmetric (the historical behaviour). Internal, settable only through
    /// the sweep initializer below, so the shipped asymmetry is whatever the
    /// harness scored, not whatever a caller felt like.
    private let downBand: Double?
    /// Compare candidate windows against the trend FROZEN at the start of the
    /// disagreement run, instead of the live trend the run itself is dragging.
    /// See `detectRegimeChange` for what the drift does to long confirmations.
    private let referenceExcludesRun: Bool
    /// Substance the reference needs before the detector may fire, in ticks.
    /// nil = the historical gate, a FULL window.
    private let referenceFloorTicks: UInt64?
    /// Scale the band by the reference's own publish-to-publish noise:
    /// effective band = max(changeBand, k·relSD), where relSD is the
    /// tick-weighted relative standard deviation of the window's publish rates.
    /// A quiet window (a machine holding one load) may be left on a moderate
    /// sustained change; a window full of build bursts must not be — its base
    /// stretches LOOK like regime changes and are not. nil = fixed band.
    private let noiseScaledBand: Double?

    /// Ceiling on the effective band for a DOWNWARD change only.
    ///
    /// A drop is bounded by the reference itself — power does not go below zero —
    /// so `abs(delta) > band * reference` is unsatisfiable downward whenever
    /// `band >= 1`, at ANY magnitude, including a machine falling to a dead stop.
    /// `max(changeBand, k * relSD)` crosses 1 at `relSD = 1/3`, and a window holding
    /// a burst is far noisier than that: 0.70 measured in the field. So the noise
    /// term was blinded by precisely the event it exists to detect — it protects
    /// against firing on a bursty reference by making it impossible to notice the
    /// burst ENDING.
    ///
    /// Upward is deliberately left uncapped. A rise has no such bound, so a large
    /// band is satisfiable there and still does its job; the asymmetry is a
    /// property of the direction, not a tuning preference.
    ///
    /// MEASURED (`TrendSweepHarness.testDownwardCeilingSweep`, the field shape:
    /// 20 min quiet, 6 min at 25 W, quiet again) — settle is minutes from the drop
    /// until the trend is within 20 % of the truth, warm-up is the spurious
    /// cold-start collapse rate the floor and noise term exist to hold at zero:
    ///
    ///     ceiling   settle   warm-up   maeBursty   swing2m
    ///     none        29        0.00       16.0        45.6   <- ships today
    ///     0.80        29        0.00       16.0        45.6
    ///     0.70        29        0.25       16.0        45.6
    ///     0.60         8        0.50       16.0        45.6
    ///     0.50         8        0.50       15.8        42.7
    ///     0.40         8        1.00       38.3       176.5
    ///     0.30         8        1.00       55.2       148.4
    ///
    /// **SO THIS SHIPS AS nil, AND THE KNOB EXISTS TO RECORD THAT.** No ceiling
    /// separates the two failures: every value that settles faster than the
    /// window's own roll-off collapses between a quarter and all bursty cold
    /// starts, which is the exact regression the floor and the noise term were
    /// added to remove (0.53 -> 0.00, and this would undo it). A ceiling is
    /// therefore the WRONG SHAPE of fix, not a mis-tuned one.
    ///
    /// What the table says the real fix needs: a band cannot tell "the load was
    /// bursty and has now stopped" from "the load is bursty and continues",
    /// because at the moment of the test both have the same heterogeneous
    /// reference. The discriminator is not in the reference at all — it is that
    /// the publishes SINCE the drop are homogeneous in the first case and not in
    /// the second. `confirmTicks` already requires persistence, but of the
    /// out-of-band condition, which never begins when the band cannot be crossed.
    /// Whatever lands here has to be measured against both columns at once.
    private let downBandCeiling: Double?

    private var samples: [Sample] = []
    /// Ticks accumulated in the current run of same-direction disagreement, and
    /// where that run started — the trend is rebuilt from there when it confirms.
    private var outOfBandTicks: UInt64 = 0
    private var outOfBandSign = 0
    private var runStart: Date?
    /// The reference power banked when the current run began (`referenceExcludesRun`).
    private var runReference_mW: Double?
    /// The effective band banked at the same moment (`noiseScaledBand`): the run's
    /// own publishes joining the window must not inflate the bar mid-run.
    private var runBand: Double?

    /// 300 ticks — five minutes of measured discharge before ANY figure is
    /// published, up from 120.
    ///
    /// Two minutes was chosen when the window's early behaviour had only been
    /// tested under a steady synthetic load, where a short window really does
    /// agree with a long one. Reported from a real cold boot on battery:
    ///
    ///     ETD read 25 h, then 5 h one second later, then held for a minute
    ///     drain read near zero, then jumped to 15.7 %/hr and held
    ///
    /// Both readings were defensible in isolation — measured at that instant the
    /// pack was drawing 712 mA at 12.81 V (9.1 W, 11.5 %/hr) and the load average
    /// was collapsing from 8.78 to 3.35 as login items settled. The fault is that
    /// a 120-tick window is a third of one publish, so a single new batch moves
    /// the answer by hours, and the app said "25 hours" out loud on the strength
    /// of it.
    ///
    /// Five minutes is five publishes: enough that one batch cannot dominate, and
    /// short enough that a user who unplugs is not left staring at "estimating…".
    /// It does not make the early estimate accurate — a machine still settling
    /// after boot has no stable answer to give — it stops the app from asserting
    /// one it cannot support.
    public convenience init(window: TimeInterval = 1800, minTicks: UInt64 = 300,
                            changeBand: Double = 0.30, confirmTicks: UInt64 = 300) {
        // The structural knobs are fixed here, not exposed: the shipped detector
        // judges runs against a reference FROZEN at run start, may fire once ten
        // minutes of reference exist, and scales its band by the reference's own
        // noise. The values are the winners of the committed sweep
        // (`TrendSweepHarness`); the sweep initializer below is how they were
        // chosen and how a successor should change them.
        self.init(window: window, minTicks: minTicks, changeBand: changeBand,
                  confirmTicks: confirmTicks, downBand: nil,
                  referenceExcludesRun: true, referenceFloorTicks: 600,
                  noiseScaledBand: 3.0)
    }

    /// The sweep initializer: every structural knob of the regime detector,
    /// so the scoring harness can drive the whole design space through the REAL
    /// class rather than a copy that would drift from it. Internal on purpose —
    /// the public initializer above pins the shipped configuration.
    init(window: TimeInterval, minTicks: UInt64,
         changeBand: Double, confirmTicks: UInt64,
         downBand: Double?, referenceExcludesRun: Bool,
         referenceFloorTicks: UInt64?, noiseScaledBand: Double? = nil,
         downBandCeiling: Double? = nil) {
        self.window = max(60, window)
        self.minTicks = max(1, minTicks)
        self.changeBand = changeBand
        self.confirmTicks = max(1, confirmTicks)
        self.downBand = downBand
        self.referenceExcludesRun = referenceExcludesRun
        self.referenceFloorTicks = referenceFloorTicks
        self.noiseScaledBand = noiseScaledBand
        self.downBandCeiling = downBandCeiling
    }

    /// Tick-weighted relative standard deviation of the window's publish rates —
    /// how much the machine's own minutes disagree with each other. ~0 for a
    /// machine holding one load; large for one alternating base and bursts.
    ///
    /// nil when the question cannot be answered, and the caller must then treat
    /// the reference as unassessable rather than as quiet. Two ways it cannot:
    /// fewer than two measurable publish rates (nothing to disagree), or ANY
    /// single window longer than `maxAssessableTicks`. The second is the subtle
    /// one, found in adversarial review: a 600-tick gap window (a stopped
    /// process, or a long gauge silence) averaging a burst-and-base load reads
    /// as ONE rate — its internal variance is laundered by its own length — so
    /// a tick-weighted sd over [one long blend, a few base publishes] comes out
    /// near zero for a load whose visible publishes disagree by 70 %. A window
    /// as long as the whole confirmation could hide a full burst cycle inside;
    /// it cannot testify to quietness.
    private static let maxAssessableTicks: UInt64 = 300
    private func referenceRelSD() -> Double? {
        guard samples.count >= 3 else { return nil }
        var wSum = 0.0, wTicks = 0.0
        var rates: [(mW: Double, ticks: Double)] = []
        for i in 1..<samples.count {
            guard let w = Window.between(samples[i - 1], samples[i]) else { continue }
            guard w.ticks <= Self.maxAssessableTicks else { return nil }
            rates.append((w.power_mW, Double(w.ticks)))
            wSum += w.power_mW * Double(w.ticks)
            wTicks += Double(w.ticks)
        }
        guard wTicks > 0, rates.count >= 2 else { return nil }
        let mean = wSum / wTicks
        guard mean > 0 else { return nil }
        var varSum = 0.0
        for r in rates { varSum += r.ticks * (r.mW - mean) * (r.mW - mean) }
        return (varSum / wTicks).squareRoot() / mean
    }

    /// Feed every tick. The trend itself only advances when the gauge publishes a
    /// new batch — between publishes there is no new information, and a display that
    /// moves without new information is the bug this replaces.
    ///
    /// - Returns: true when this sample carried a new accumulator batch.
    @discardableResult
    public func record(_ s: Sample, onBattery: Bool) -> Bool {
        // On AC the counter stops advancing and charge moves the other way. Nothing
        // to average, and averaging across the transition would mix two regimes.
        guard onBattery else { reset(); return false }
        guard s.voltage_mV > 0 else { return false }

        guard let last = samples.last else { samples.append(s); return false }

        // A window that straddles a SLEEP is not a long window, it is the absence of
        // one: the counter is hardware and keeps advancing at the ~0.2 W a sleeping
        // Mac draws, which averaged into a half-hour window reads as a machine
        // sipping nothing — told to the user at the exact moment they opened the lid
        // to look. `CLOCK_UPTIME_RAW` does not advance while asleep, so wall time
        // minus awake time IS the sleep, to the second.
        //
        // Only that. Deliberately NOT `PowerMonitor.straddlesGap`, whose other arm
        // condemns any gap over 120 s: that is the right rule for a differenced
        // sample, and the wrong one here, because a cumulative counter loses nothing
        // when a poll is missed — the unobserved ticks are still inside the next
        // difference. Measured on a real 53-minute trace: the gauge went 156 s
        // between publishes on a plainly awake machine, and the tick-cadence rule
        // threw half an hour of good history away for it.
        let wall = s.timestamp.timeIntervalSince(last.timestamp)
        if wall < 0 || wall - (s.awake - last.awake) > PowerMonitor.clockSkewTolerance {
            reset()
            samples.append(s)
            return false
        }

        guard s.accumulatorCount != last.accumulatorCount else { return false }
        // Implausible or non-discharging: drop everything rather than fit across it.
        // A counter reset lands here, and so does a charge cycle the AC flag missed.
        guard let published = Window.between(last, s) else {
            reset()
            samples.append(s)
            return false
        }

        // One window longer than the whole trend window cannot be pruned back to it —
        // there are no intermediate samples to prune TO — so keeping it would quietly
        // turn the half-hour trend into a mean over however long the process was
        // stopped. Start the window again rather than claim a length it does not have.
        guard published.ticks <= UInt64(window) else {
            reset()
            samples.append(s)
            return false
        }

        detectRegimeChange(published, from: last)
        samples.append(s)
        prune()
        return true
    }

    public func reset() {
        samples.removeAll(keepingCapacity: true)
        endRun()
    }

    /// nil until the window holds `minTicks` of measured discharge. nil is the
    /// honest answer there — the caller shows the power-based figure, labelled.
    public var trend: Trend? {
        guard let first = samples.first, let last = samples.last,
              let w = Window.between(first, last), w.ticks >= minTicks else { return nil }
        // The accumulator measures ENERGY; charge is what runs out. Dividing by the
        // pack voltage averaged over the same ticks — not by a single snapshot,
        // because the pack sags under load: measured across 26 minutes of real work
        // it ranged 11136…11878 mV, a 6.4 % spread.
        //
        // Averaging the voltage and averaging the current are not the same
        // operation, since the sag correlates with the load. Measured on that trace
        // the two answers differ by at most 0.5 %, which is not worth carrying a
        // second accumulator for. The result is corroborated end to end: integrating
        // this current over those 26 minutes gives 487 mAh against a
        // `RemainingCapacity` drop of 501 mAh, 2.8 % apart on a load that swung
        // 4.1 W to 54 W.
        var vTicks = 0.0, vSum = 0.0
        for i in 1..<samples.count {
            guard let sub = Window.between(samples[i - 1], samples[i]) else { continue }
            vSum += samples[i].voltage_mV * Double(sub.ticks)
            vTicks += Double(sub.ticks)
        }
        let mV = vTicks > 0 ? vSum / vTicks : last.voltage_mV
        guard mV > 0 else { return nil }
        return Trend(power_mW: w.power_mW,
                     current_mA: w.power_mW / mV * 1000,
                     ticks: w.ticks,
                     span: w.span,
                     publishes: samples.count,
                     isFull: w.span >= window * 0.95)
    }

    // ── Internals ───────────────────────────────────────────────────────────

    /// One 60 s window that disagrees with the trend is a minute of unusual load and
    /// belongs IN the average. Five minutes of it, all the same way, is a new
    /// regime: keep only those windows, so the trend restarts from the new load
    /// rather than spending half an hour crawling to it.
    ///
    /// A run that changes direction starts over, so a load oscillating either side
    /// of the trend never confirms — it is noise about a mean, which is what the
    /// mean is for.
    ///
    /// ## Warm-up: the ten-minute floor, and why it replaced the full-window gate
    /// The detector once refused to fire until the window was FULL, because its
    /// reference was `trend`, which CONTAINS the window being tested: at five
    /// minutes of history one 60 s publish is a fifth of its own reference, so a
    /// burst dragged the reference toward itself and the comparison was a
    /// hypothesis tested against itself. Measured then on 6 h traces: the window
    /// collapsed inside the first fifteen minutes on 0.53 of bursty cold starts.
    ///
    /// The gate stopped those firings, but it also held the detector inert
    /// through the one case the field actually reported (2026-08-16): a 41 %
    /// settle arriving SIXTEEN minutes into the window's life. By the time the
    /// window filled at minute 30, the mean had blended to within ~25 % of the
    /// new load and no band could see the change — so the gate turned a
    /// five-minute confirmation into a thirty-minute roll-off precisely when the
    /// window was old enough to be sound. Ten minutes of reference
    /// (`referenceFloorTicks` = 600) plus the noise-scaled band now carry the
    /// same protection: the frozen reference removes the self-comparison, and a
    /// reference noisy enough to be mid-warm-up-burst raises its own bar.
    /// Re-measured in `TrendSweepHarness` over 40 bursty and build-like cold
    /// starts: 0.00 collapse inside fifteen minutes, the same as the gate.
    ///
    /// ## The reference drift, now fixed rather than left alone
    /// `running` contains every prior window of the run being confirmed, so it
    /// drifts toward the very change it is measuring — under the old fixed band
    /// the nominal 50 % behaved as 62.5 %. An earlier attempt to remove the
    /// drift was withdrawn because it fired MORE (bursty MAE 30.0 -> 109.0):
    /// the drift was accidental hysteresis, and with a FIXED band that
    /// hysteresis was load-bearing. With the band scaled to the reference's
    /// noise the hysteresis is redundant — the noisy loads it protected raise
    /// their own bar — so the reference is banked at run start
    /// (`runReference_mW`) and the run is judged end to end against what the
    /// load USED to be. That is also what lets a near-band change confirm at
    /// all: judged against a drifting mean, a 41 % drop falls back inside any
    /// usable band before a long confirmation completes.
    private func detectRegimeChange(_ published: Window, from left: Sample) {
        guard let running = trend, running.power_mW > 0 else { endRun(); return }
        // The substance gate: how much reference the detector needs before it may
        // fire. Historically a FULL window; `referenceFloorTicks` swaps that for a
        // fixed floor, which only makes sense together with a frozen reference —
        // an immature INCLUSIVE reference is the self-comparison the full-window
        // gate was built to stop.
        if let floor = referenceFloorTicks {
            guard running.ticks >= floor else { endRun(); return }
        } else {
            guard running.isFull else { endRun(); return }
        }
        // `running` is computed BEFORE the candidate is appended, so the first
        // window of a run is always judged against a clean reference. On the
        // SECOND and later windows `running` contains the run so far, and drifts
        // toward it — which shrinks the measured disagreement while the run is
        // being confirmed. `referenceExcludesRun` banks the clean reference at
        // run start and judges the whole run against it instead.
        let reference = (referenceExcludesRun ? runReference_mW : nil)
            ?? running.power_mW
        let delta = published.power_mW - reference
        let directionalBand = delta < 0 ? (downBand ?? changeBand) : changeBand
        let band: Double
        if let k = noiseScaledBand {
            if let banked = runBand {
                // Mid-run: the bar was banked at run start so the run's own
                // out-of-band publishes joining the window cannot raise it
                // against themselves.
                band = banked
            } else if let rel = referenceRelSD() {
                band = max(directionalBand, k * rel)
            } else {
                // Fewer than two measurable publish rates in the reference — a
                // single long gap window after a reset, or the two samples a
                // confirm-trim leaves behind. Its internal noise is UNKNOWABLE,
                // and "unknowable" fired the floor band on exactly the bursty
                // blends the noise term exists to bar (found in adversarial
                // review, reproduced through this class: a 600-tick gap window
                // averaging base and burst read as a quiet 8 W reference and the
                // 5 W base stretches collapsed it). No reference noise, no
                // detector — the same shape as the old full-window gate.
                endRun()
                return
            }
        } else {
            band = directionalBand
        }
        // Downward only, and see `downBandCeiling` for why the direction matters.
        let effective = (delta < 0 && downBandCeiling != nil)
            ? min(band, downBandCeiling!) : band
        guard abs(delta) > effective * reference else { endRun(); return }

        let sign = delta > 0 ? 1 : -1
        if sign != outOfBandSign {
            outOfBandSign = sign
            outOfBandTicks = 0
            runStart = left.timestamp
            // Frozen from the pre-candidate trend, so the run is judged end to
            // end against what the load USED to be. (On a direction flip this is
            // the live trend, which still holds the abandoned run — imperfect,
            // but a flip means the "run" was oscillation, and oscillation is what
            // the mean is for.)
            runReference_mW = running.power_mW
            // Banked FRESH from the NEW direction's base band and the reference
            // as it stands now: on a flip the band tested above was the
            // abandoned run's, and carrying it forward would floor the new run
            // at a bar computed for a reference that may have pruned away. The
            // reference here includes the abandoned run's publishes, so on an
            // oscillating load the recomputed bar is higher — the right
            // direction, since oscillation is what the mean is for.
            if let k = noiseScaledBand {
                guard let rel = referenceRelSD() else { endRun(); return }
                runBand = max(directionalBand, k * rel)
            } else {
                runBand = directionalBand
            }
        }
        outOfBandTicks &+= published.ticks
        guard outOfBandTicks >= confirmTicks, let from = runStart else { return }
        // Keep the run and nothing older. The caller-visible span shrinks to those
        // minutes, which is the truth: that is all the history describing the load
        // the machine is under now.
        while let f = samples.first, f.timestamp < from { samples.removeFirst() }
        endRun()
    }

    private func endRun() {
        outOfBandTicks = 0
        outOfBandSign = 0
        runStart = nil
        runReference_mW = nil
        runBand = nil
    }

    private func prune() {
        guard let last = samples.last else { return }
        let cutoff = last.timestamp.addingTimeInterval(-window)
        // One older-than-cutoff sample is KEPT as the window's left endpoint, so the
        // mean covers the full window instead of only the part of it that begins at
        // a publish boundary.
        var drop = 0
        while drop + 1 < samples.count && samples[drop + 1].timestamp < cutoff { drop += 1 }
        if drop > 0 { samples.removeFirst(drop) }
    }
}

// ─────────────────────────────────────────────────────────────────────────────

extension BatteryDischargeTrend {

    /// Carrying the trend across an app restart.
    ///
    /// THE APP RESTARTING IS NOT AN EVENT THE BATTERY KNOWS ABOUT. Without this
    /// the trend began empty on every launch, so quitting and reopening threw
    /// away up to half an hour of measured discharge and put the estimate back to
    /// "measuring" — which a user correctly read as wrong, since nothing about
    /// the machine had changed. The three things that SHOULD clear it are a
    /// reboot, a first-ever launch, and going on and off the adapter.
    ///
    /// This works because the accumulator is HARDWARE and cumulative. It keeps
    /// counting while nothing is watching, and this file already says what that
    /// means: "a cumulative counter loses nothing when a poll is missed — the
    /// unobserved ticks are still inside the next difference." So a sample from
    /// before the restart differences correctly against one from after it.
    ///
    /// NOTHING NEW IS TRUSTED HERE. The restored samples go back exactly where
    /// they were and the next `record` validates them with the guards that were
    /// already there, each of which catches one of the three cases above:
    ///
    ///   * a REBOOT resets `CLOCK_UPTIME_RAW`, so the awake clock disagrees with
    ///     the wall clock and the sleep guard clears the trend;
    ///   * TIME ON THE ADAPTER makes the discharge delta non-negative, and
    ///     `Window.between` returns nil, which clears it;
    ///   * a long absence produces one window longer than the trend window, which
    ///     clears it too — so a restart after an hour starts fresh, and one after
    ///     a minute does not.
    ///
    /// The guards are load-bearing rather than decorative: restoring without them
    /// would fit a rate across a gap that may contain a charge, a sleep, or a
    /// different boot entirely.
    public struct Persisted: Codable {
        public let samples: [Sample]
        /// Stamped so a file from a previous format is ignored rather than
        /// decoded into something that looks plausible.
        public let version: Int
        public static let currentVersion = 1
    }

    public func persisted() -> Persisted {
        Persisted(samples: samples, version: Persisted.currentVersion)
    }

    /// Put a saved trend back. Ignored when the file is from another format.
    public func restore(_ p: Persisted) {
        guard p.version == Persisted.currentVersion else { return }
        samples = p.samples
        endRun()
    }
}

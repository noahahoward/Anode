import Foundation

/// Rolling sampler shared by the CLI watch loop and the app.
///
/// Three signals with very different characteristics are fused here:
///
///   battery gas gauge   accurate, whole-machine, but publishes a 60 s MEAN once a minute
///   per-process rusage  every tick, real joules, but only our-uid CPU (~63% of pids)
///   IOReport GPU rail   every tick, real joules, GPU only on this hardware
///
/// Reporting the gas gauge directly is what made the menu bar swing 4.8 -> 10.08 -> 5.0
/// %/hr: consecutive reads are different 60 s windows, not different truths. So we take
/// SHAPE from the fast signals and LEVEL from the gas gauge, then smooth adaptively.
public final class PowerMonitor {

    public struct Snapshot {
        /// Raw per-process rows, for the drill-down view.
        public let drains: [ProcessDrain]
        /// Per-application rows — processes collapsed onto the app that owns them.
        public let apps: [AppDrain]

        /// Named shares of the CPU power rusage could not attribute — WindowServer
        /// and the root daemons. These sum to `systemProcesses_W` rather than
        /// adding to it: the bucket's TOTAL is measured, and these rows are a
        /// partition of it, so the ledger stays conserving. Every row is modeled,
        /// and the UI must keep saying so.
        public let systemApps: [SystemAttribution.Row]

        /// Named shares of the measured GPU rail. macOS exposes no per-process GPU
        /// power at all, so this is the only per-app GPU figure available — and it
        /// is apportioned by coalition GPU time, never measured directly.
        public let gpuApps: [SystemAttribution.Row]

        /// Seconds since the coalition rollup behind `systemApps`/`gpuApps` was
        /// refreshed. Nil before the first one lands. Surfaced because these rows
        /// lag the measured ones by up to a minute and a stale row that looks live
        /// is worse than one labelled stale.
        public let systemAttributionAge: TimeInterval?

        /// False on a light tick: no per-process sweep ran and no GPU rail was
        /// read, so `drains`, `apps`, `attributed_W`, `gpu_W` and `coverage` are
        /// ABSENT rather than zero.
        ///
        /// Everything derived from them has to say so. Without this flag
        /// `residualShare` computed to exactly 1.0 and `coverage` to 0 on every
        /// hidden tick, and both were rendered with `isEstimate: false` — the two
        /// metrics whose entire job is stating how much of the measurement we can
        /// explain, asserting a falsehood as measured fact.
        ///
        /// Defaulted, and therefore `var`, only so the in-module synthetic
        /// snapshots (ModelValidator's self-test) keep describing a full sample
        /// without restating it.
        public var isFullSample: Bool = true

        public let attributed_W: Double
        /// Live energy rails that actually moved. On M5 this is GPU only.
        public let rails: [IOReportSampler.Rail]
        public let gpu_W: Double?
        /// Fast proxy: attributable CPU + measured GPU. Updates every tick.
        public let fast_W: Double
        /// Gas gauge, nil until the first 60 s telemetry batch lands.
        public let measured_W: Double?
        public let measuredAge: TimeInterval?
        /// The number to display: fast signal scaled to gas-gauge level, then smoothed.
        public let smoothed_W: Double
        public let isCalibrated: Bool
        /// SMC whole-system watts, gain-corrected against the gauge.
        public let smcTotal_W: Double?
        public let smcGain: Double?
        /// Measured CPU-package power. Identified empirically: under an all-core
        /// load PPMC rose +13.3 W, under a pure Metal GPU load only +1.5 W — a 9x
        /// discriminator. Not documented by Apple, so it is treated as best-effort.
        public let cpuRail_W: Double?

        /// CPU power we MEASURED but cannot attribute to a named process, because
        /// proc_pid_rusage is same-uid only. This is WindowServer and the root
        /// daemons — real process energy, just anonymous. Naming it separately is
        /// the difference between "we do not know" and "we know, but not whose".
        /// Nil on a light tick: nothing was attributed, so `cpu - attributed`
        /// would name the ENTIRE measured CPU rail as anonymous daemon power.
        public var systemProcesses_W: Double? {
            guard isFullSample, let cpu = cpuRail_W else { return nil }
            return max(0, cpu - attributed_W)
        }

        /// Everything that belongs to no process at all: display backlight, radios,
        /// SSD, DRAM, kernel, leakage. On a laptop with the screen on this is
        /// genuinely the largest share, and no amount of better process accounting
        /// will move it — it is not process energy.
        /// Derived from `smoothed_W`, NOT from the raw SMC total. The ledger bar
        /// spans the smoothed figure, so computing this bucket against a different
        /// total made the segments sum to slightly less than the bar and left a gap
        /// of bare background at the right end.
        /// What is left after every named claim. Still a partition of the
        /// measured total, never an addition to it.
        ///
        /// Ordering matters and is deliberate: CPU, GPU, memory and storage are
        /// MEASURED rails and are taken first; display is taken last because on
        /// hardware without a backlight rail it is MODELLED, and a model must
        /// never crowd out a measurement when the total is tight.
        ///
        /// Nil on a light tick for the same reason the buckets it subtracts are:
        /// the GPU rail is not read there, so the residue would quietly swallow
        /// the GPU's watts and file them under "always-on & unidentified".
        public var platform_W: Double? {
            guard isFullSample, cpuRail_W != nil else { return nil }
            var remaining = smoothed_W
            for claim in [cpuRail_W, gpu_W, memory_W, storage_W, usb_W, display_W] {
                remaining = max(0, remaining - max(0, claim ?? 0))
            }
            return remaining
        }

        /// Estimated display backlight watts, or nil when brightness is unreadable.
        /// MODELED, not measured: a calibrated response curve for this panel. It
        /// is carved OUT of the platform bucket rather than added to the total,
        /// so the ledger still sums to what was measured.
        public let display_W: Double?
        /// Memory (DRAM/controller/fabric) and storage (SSD), from their own
        /// rails. Measured, not modelled. Nil where the rail is unavailable —
        /// which on other hardware is the normal case and must show no segment
        /// rather than a zero one.
        public let memory_W: Double?
        public let storage_W: Double?
        /// Measured USB device draw. A phone charging from the port cost 11.55 W
        /// when measured directly — power that belongs to no process and appears
        /// in no per-app view anywhere.
        public let usb_W: Double?
        /// Devices attached whose cost was never observed (present at launch, so
        /// there was no step to measure). The usb_W figure is a floor when true.
        public let usbHasUnmeasured: Bool
        /// Any contributing figure is remembered from a previous step, not measured now.
        public let usbHasRemembered: Bool
        public let usbDevices: [USBPowerTracker.Device]
        public var usb_pctHr: Double? { usb_W.map(pctHr) }
        public var memory_pctHr: Double? { memory_W.map(pctHr) }
        public var storage_pctHr: Double? { storage_W.map(pctHr) }
        /// True when `display_W` came from the backlight rail rather than the
        /// brightness curve. The UI must not call a modeled figure measured.
        public let displayIsMeasured: Bool
        public var display_pctHr: Double? { display_W.map(pctHr) }

        public var systemProcesses_pctHr: Double? { systemProcesses_W.map(pctHr) }
        public var platform_pctHr: Double? { platform_W.map(pctHr) }
        /// Watts belonging to no visible process: display, radios, SSD, kernel.
        public let baseline_W: Double?
        public let didJump: Bool
        public let residual_W: Double?
        /// Unclamped residual. Negative means we attributed more than we measured —
        /// impossible in physics, so it is a double-counting bug signal, not a value
        /// to display. See the construction note at the assignment site.
        public let rawResidual_W: Double
        /// True when attribution exceeded measurement this tick.
        public var hasAttributionOverflow: Bool { rawResidual_W < -0.05 }
        public let scale: BatteryScale
        public let state: Battery.State?
        public let coverage: Double
        public let denied: Int
        public let readable: Int
        public let attempted: Int
        public var active: Int { drains.count }
        public let interval: TimeInterval

        private func pctHr(_ w: Double) -> Double { 3600 * w / scale.joulesPerPercent }

        public var attributed_pctHr: Double { pctHr(attributed_W) }
        public var smoothed_pctHr: Double { pctHr(smoothed_W) }
        public var measured_pctHr: Double? { measured_W.map(pctHr) }
        public var residual_pctHr: Double? { residual_W.map(pctHr) }
        public var gpu_pctHr: Double? { gpu_W.map(pctHr) }

        /// How much of the measurement no named claim explains. On a light tick
        /// nothing was claimed, so this would be exactly 1.0 — "100% of your
        /// battery is unexplained", stated by the very number that exists to say
        /// how trustworthy the explanation is. `isFullSample` is checked as well
        /// as `residual_W` so the answer stays nil even if a caller reconstructs
        /// a residual of its own.
        public var residualShare: Double? {
            guard isFullSample, let r = residual_W, smoothed_W > 0 else { return nil }
            return r / smoothed_W
        }

        /// Which way charge is actually moving. Reporting "drain" while the battery
        /// is filling is simply wrong, and macOS often reports no estimate at all
        /// while charging (verified: `pmset` said "(no estimate)" at 73% charging),
        /// so this is computed rather than read.
        public enum Direction { case draining, charging, acIdle }

        public var direction: Direction {
            guard let s = state else { return .draining }
            // Amperage is signed: positive while charging, negative while
            // discharging. Verified at +3629 mA on this machine.
            if s.isCharging && s.amperage_mA > 0 { return .charging }
            if s.onAC { return .acIdle }
            return .draining
        }

        /// SIGNED battery rate: positive means gaining charge, negative means losing.
        /// The magnitude while charging comes from the actual charge current, not
        /// from system power draw — those are different quantities, and the wall
        /// adapter is supplying both at once.
        public var batteryRate_pctHr: Double? {
            guard let s = state, scale.fullChargeCapacity_mAh > 0 else { return nil }
            switch direction {
            case .charging:
                return 100.0 * Double(s.amperage_mA) / scale.fullChargeCapacity_mAh
            case .draining:
                return -smoothed_pctHr
            case .acIdle:
                return 0
            }
        }

        /// Where charging is heading — the learned limit when there is one, the
        /// pack's own 100% when there is not. Nil before the first tick has fed
        /// the learner. See `ChargeTarget` for why this is inferred and not read.
        ///
        /// Defaulted, and therefore `var`, for the same reason `isFullSample` is:
        /// the synthetic fixtures describe a battery without having an opinion
        /// about a charge limit.
        public var chargeTarget: ChargeTarget.Level?

        /// Hours until charging STOPS, and what it will stop at.
        ///
        /// Two things were wrong with the constant-current projection to
        /// `fullChargeCapacity_mAh` this replaces, and they compound:
        ///
        ///  1. It counted to 100%. With this machine's 80% limit that is a target
        ///     the charger will never reach, so the figure overstated the wait by
        ///     15, 16 and 28 minutes on the three recorded sessions and then went
        ///     to nil the instant the machine stopped — a countdown that never
        ///     read zero, which is exactly how "the last 1% takes the longest"
        ///     feels from the outside.
        ///  2. It assumed constant current right to the target. The current is in
        ///     fact flat on this pack (measured, see `ChargeCurve`) up until the
        ///     final approach, where it collapses; the last step into the limit
        ///     cost +0.92 and +0.66 min beyond what the rate accounted for.
        ///
        /// Nil, never a substitute number, when the pack is at or past its target:
        /// there is no wait left to report.
        public var chargeEstimate: ChargeTarget.Estimate? {
            guard direction == .charging, let s = state, s.amperage_mA > 0,
                  let target = chargeTarget, scale.fullChargeCapacity_mAh > 0
            else { return nil }
            // Rate and headroom on the same mAh basis the target was learned on,
            // so the subtraction is between two comparable percentages rather than
            // the gauge's integer percent against a capacity ratio.
            let rate = 100.0 * Double(s.amperage_mA) / scale.fullChargeCapacity_mAh
            let headroom = target.percent - scale.chargePercent(s)
            guard let hr = ChargeCurve.hours(headroom_pct: headroom,
                                             rate_pctHr: rate,
                                             tapers: target.isLearnedLimit)
            else { return nil }
            return ChargeTarget.Estimate(hours: hr, target: target)
        }

        /// Hours until charging stops. ALWAYS an estimate — see `ChargeCurve`.
        public var timeToFull_hr: Double? { chargeEstimate?.hours }

        /// True when the machine is sitting on AC at the limit it was learned to
        /// hold at, rather than merely idle on AC. "Not charging" and "held at 80%"
        /// are different facts and the second one is the one the user chose.
        ///
        /// A BAND around the limit, not merely at-or-above it. A session that
        /// overrode the limit and stopped at 92% is on AC and not charging, but it
        /// is not sitting at its 80% limit and must not claim to be.
        public var isHeldAtChargeLimit: Bool {
            guard direction == .acIdle, let s = state, s.onAC, !s.fullyCharged,
                  s.notChargingReason != 0, let t = chargeTarget, t.isLearnedLimit
            else { return false }
            return abs(scale.chargePercent(s) - t.percent) <= 1
        }

        /// Projected runtime at the smoothed draw — independent of macOS's estimate.
        public func projectedRuntime_hr() -> Double? {
            guard smoothed_W > 0, let s = state, !s.onAC else { return nil }
            return Double(s.percent) * scale.joulesPerPercent / smoothed_W / 3600
        }

        /// Energy left in the pack, in joules.
        public var remainingEnergy_J: Double? {
            state.map { Double($0.percent) * scale.joulesPerPercent }
        }

        /// "Quitting this would buy you N more minutes."
        ///
        /// This is a MARGINAL, counterfactual quantity, not a share — which is exactly
        /// what makes it honest where a percentage-of-total is not. Runtime is E/P, so
        /// removing a load of P_app changes runtime by:
        ///
        ///     seconds gained = E_remaining * (1/(P_sys - P_app) - 1/P_sys)
        ///
        /// Note this is a RECIPROCAL of a rate. The intuitive-looking subtractive form
        /// (T - (f-1)T) is not merely imprecise, it is structurally wrong: it is linear
        /// in the load fraction and goes negative once an app exceeds the whole battery.
        ///
        /// Deliberately gated, because the number is only meaningful in a narrow band:
        ///  - on battery only (on AC there is no runtime to extend),
        ///  - only above a share floor, since below it the answer is rounding noise,
        ///  - and never when the app would account for essentially all draw, where the
        ///    formula's denominator collapses and the answer tends to infinity.
        /// The floor was 5%, which made this column empty for every row. Apps are
        /// only ~20% of measured draw in total, so a top app is typically 2-4% of the
        /// machine — 5% assumed apps explain most of the battery, which is the exact
        /// assumption this project exists to reject. 0.5% is the point below which
        /// the answer rounds to under a minute on a full charge.
        public func runtimeCost_min(appWatts: Double, floorShare: Double = 0.005) -> Double? {
            guard let s = state, !s.onAC,
                  let energy = remainingEnergy_J,
                  smoothed_W > 0.01,
                  appWatts > 0
            else { return nil }
            _ = s
            let share = appWatts / smoothed_W
            guard share >= floorShare, share < 0.9 else { return nil }
            let without = smoothed_W - appWatts
            guard without > 0.01 else { return nil }
            let seconds = energy * (1.0 / without - 1.0 / smoothed_W)
            guard seconds.isFinite, seconds > 0 else { return nil }
            return seconds / 60.0
        }
    }

    public let scale: BatteryScale
    private var lastSweep: ProcessSampler.Sweep?
    /// Awake-clock reading taken with `lastSweep`. Stored alongside it because a
    /// wall-clock interval on its own cannot tell nine hours of work from nine
    /// hours of sleep — see `straddlesGap`.
    private var lastSweepAwake: TimeInterval?
    private var lastPublished: PowerTelemetry?
    private var currentMeasured_W: Double?
    private var measuredAt: Date?

    private let ioreport = IOReportSampler()
    /// SMC PSTR: whole-system watts, no root, updates every read — unlike the gauge's
    /// 60 s batches. This is the live anchor; the gauge now only corrects its gain.
    private let smc = SMC()
    private let gain = GainCalibrator()
    private var pstrSincePublish: [Double] = []
    private let calibrator = BaselineCalibrator()
    private let smoother = AdaptiveSmoother()
    /// The CPU's SHARE of system power, smoothed — not its absolute watts.
    ///
    /// Smoothing the two rails independently was not enough, and made a worse
    /// problem visible: `system` is `cpuRail - attributed` and `platform` is
    /// `total - cpuRail - gpu`, so BOTH buckets hang off cpuRail and move in
    /// opposite directions when it wobbles. With two independent adaptive
    /// smoothers whose jump detection fired at different moments, the split
    /// thrashed — measured across 25 ticks, the hatched share ranged 13% to 83%
    /// with a standard deviation of 22 points, while apps sat steady near 8%.
    ///
    /// PPMC/PSTR is bounded, physically meaningful, and genuinely slow-moving: it
    /// is the fraction of the machine's power the CPU is drawing. Smoothing that
    /// and multiplying by the displayed total makes the buckets consistent with
    /// the bar BY CONSTRUCTION, and a spike in total no longer reshuffles the
    /// split. The gain cancels in the ratio, so raw rails are used.
    /// Rolling MEDIANS of the two raw rails, not an EWMA of either.
    ///
    /// A single SMC read of PPMC is not a power measurement. Consecutive reads on
    /// a quiet machine went 10.66, 0.76, 0.52, 1.81, 0.26 W — a 20x swing — and
    /// the same rail averaged over 14 s during the brightness sweep sat calmly at
    /// 2.5-5 W. The instantaneous value is sampling something PWM-like; only its
    /// central tendency means anything.
    ///
    /// A median is the right tool rather than an average or an EWMA: those both
    /// carry the 10 W outliers into the result, and the adaptive smoother actively
    /// chases them because a 20x jump is exactly what its jump detector exists to
    /// follow. A median discards them.
    private var ppmcWindow: [Double] = []
    private var pstrWindow: [Double] = []
    private let railWindow = 15

    private static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2]
                                : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
    /// Fast samples accumulated since the last gas-gauge publish, so calibration
    /// compares like with like: a mean over the same period, not a single instant.
    private var fastSincePublish: [Double] = []
    private var lastLightTick: Date?
    /// The awake-clock twin of `lastLightTick`, for the same reason.
    private var lastLightTickAwake: TimeInterval?
    /// Rolling-window per-process rates. Replaces sweep-to-sweep differencing,
    /// which dropped any process whose sparse energy counter did not happen to
    /// move during that particular 2 s window. See DrainTracker.
    private let tracker = DrainTracker(window: 10)
    /// Names the CPU power rusage cannot attribute. Refreshed on its own queue —
    /// it shells out to `systemstats`, which must never happen on a tick path.
    private let systemAttribution = SystemAttribution()
    /// Backlight response curve, or nil on hardware it was never fitted for.
    /// One struct so a different panel means different coefficients rather than
    /// edits scattered through the monitor — and nil rather than a plausible
    /// wrong number, because this claim is subtracted from the honest bucket.
    private let displayModel = DisplayPowerModel.forThisMachine
    /// Attributes power to attached USB devices by measuring the step each one
    /// causes. There is no USB rail; the step IS the measurement.
    private let usbTracker: USBPowerTracker = { let t = USBPowerTracker(); t.adoptExisting(); return t }()
    /// Learns the level this machine stops charging at. Nothing in IOKit states
    /// it, so it is inferred from the machine refusing to charge on AC and
    /// remembered across launches — see `ChargeTarget`.
    ///
    /// Deliberately NOT cleared by `resetAcrossGap`, for the same reason the
    /// calibrators are not: a charge limit is a property of the machine, and it is
    /// the same machine when it wakes. A sleep is in fact the most likely time to
    /// LEARN one, since the overnight session that sat at 80% for seven hours is
    /// precisely the evidence this is looking for.
    private let chargeLimits = ChargeLimitLearner()

    public var ioReportAvailable: Bool { ioreport != nil }

    public init?(scale: BatteryScale? = nil) {
        guard let s = scale ?? Battery.scale() else { return nil }
        self.scale = s
        self.lastPublished = PowerTelemetry.sample()
    }

    /// Awake seconds since boot.
    ///
    /// `CLOCK_UPTIME_RAW` is documented as the one Darwin monotonic clock that does
    /// NOT increment while the system is asleep (it is `mach_absolute_time` in
    /// seconds); `Date` runs straight through a sleep. So wall elapsed minus awake
    /// elapsed IS the sleep, to the second — no notification to subscribe to, none
    /// to miss, and no AppKit dependency in a library the CLI also links.
    static func awakeSeconds() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
    }

    /// The longest interval a legitimate sample can span. Ticks run at 1-30 s with
    /// the window open and 8 s while hidden, with a full sweep forced at least
    /// every 60 s, so ~68 s is the worst legitimate case and this is nearly double
    /// it. The error costs are wildly asymmetric: a false positive discards one
    /// 2 s row, a false negative lets one row own the whole 10 hr window.
    static let maxPlausibleInterval: TimeInterval = 120

    /// How far the two clocks may disagree without the machine having slept. They
    /// are read a few milliseconds apart, and NTP can step the wall clock; five
    /// seconds is longer than either and shorter than any sleep worth keeping a
    /// sample across.
    static let clockSkewTolerance: TimeInterval = 5

    /// True when a sample spans time nothing was observing. Two ways that happens,
    /// and the awake clock only catches the first:
    ///   sleep      — the wall clock ran on while the awake clock stood still.
    ///   suspension — both clocks ran, but far past any tick cadence, because the
    ///                process itself was stopped.
    static func straddlesGap(wall: TimeInterval, awake: TimeInterval) -> Bool {
        wall > maxPlausibleInterval || wall - awake > clockSkewTolerance
    }

    /// Returns nil on the very first tick — there is no window to diff against yet.
    /// A full tick sweeps every process; a light tick does not.
    ///
    /// This distinction is the difference between a monitor you can leave running
    /// and one you can't. The per-process sweep is ~800 `proc_pid_rusage` calls plus
    /// the app rollup, and it exists purely to populate the table — which nobody is
    /// looking at when the window is closed. The menu bar needs only two numbers,
    /// total drain and time remaining, and both come from SMC PSTR plus the battery:
    /// three cheap IOKit reads.
    ///
    /// Measured motivation: the full path spiked ~5% CPU every tick and drove ~20 KB/s
    /// of SQLite WAL. On a laptop used for schoolwork that is not an acceptable idle
    /// cost, and it buys nothing while hidden.
    @discardableResult
    /// - Parameter attribution: whether to refresh the coalition rollup that
    ///   names system processes and per-app GPU. It costs a `systemstats`
    ///   subprocess and the parse of a few thousand records, and it feeds ONLY the
    ///   process table and the ledger drill-down. With the window closed nothing
    ///   displays either, so doing it anyway was — measured — the single largest
    ///   consumer of idle CPU in the whole app, by roughly forty to one over the
    ///   next item.
    public func tick(full: Bool = true, attribution: Bool = true) -> Snapshot? {
        let sweep = full ? ProcessSampler.sweep() : nil
        // Skipped on light ticks: the menu bar shows the whole-system total from
        // PSTR and never the GPU rail, so differencing 314 channels would be work
        // done for a number nobody reads.
        let reading = full ? ioreport?.sample() : nil
        let awakeNow = Self.awakeSeconds()
        defer { if let s = sweep { lastSweep = s; lastSweepAwake = awakeNow } }

        // In light mode the per-process numbers are simply absent rather than stale:
        // callers get empty `drains`/`apps` and an attributed figure of zero, which
        // the UI must not render as "apps used nothing". Nothing draws them while
        // hidden, and the next full tick repopulates before the window is shown.
        var drains: [ProcessDrain] = []
        var attributed = 0.0
        var interval: TimeInterval = 0
        // Awake seconds spanned by that same interval. Identical to it on a running
        // machine; the difference is time spent asleep.
        var awake: TimeInterval = 0
        if let sweep {
            guard let prior = lastSweep else { return nil }
            interval = sweep.timestamp.timeIntervalSince(prior.timestamp)
            awake = lastSweepAwake.map { awakeNow - $0 } ?? interval
        } else {
            interval = lastLightTick.map { Date().timeIntervalSince($0) } ?? 0
            awake = lastLightTickAwake.map { awakeNow - $0 } ?? interval
        }

        // A sample straddling a sleep is not a long sample, it is the absence of
        // samples. A nine-hour sleep hands this one interval of ~32,400 s, and the
        // store's window walk takes rows newest-first, so that single row fills the
        // entire 10 hr window on its own and every displayed figure becomes a
        // reading of the sleep.
        //
        // The interval is DROPPED, not clamped to something plausible. A clamp
        // would write a row asserting the machine drew its pre-sleep watts for the
        // clamped seconds it actually spent asleep — fabricated energy, in a store
        // whose entire premise is that measured joules add exactly. `record`
        // returns early on interval <= 0, so the gap is simply absent from history,
        // which is what happened.
        if Self.straddlesGap(wall: interval, awake: awake) {
            resetAcrossGap()
            interval = 0
        }

        // After the reset, never before: the tracker's pre-gap samples would
        // otherwise be differenced against this sweep, and every process would
        // report its mean rate across a nine-hour window nothing sampled as though
        // it were the rate right now.
        if let sweep {
            drains = tracker.update(with: sweep, scale: scale)
            attributed = drains.reduce(0) { $0 + $1.watts }
        }
        lastLightTick = Date()
        lastLightTickAwake = awakeNow
        let gpu = reading?.gpu_W
        let fast = attributed + (gpu ?? 0)
        // Full ticks only. On a light tick `fast` is 0 because nothing was
        // sampled, not because nothing was drawing power, and observing
        // (fast: 0, slow: 5 W) teaches the calibrator that a machine using no
        // attributable power still costs 5 W — fitting a line through a point
        // that was never measured. Fewer observations, none of them invented; the
        // `!fastSincePublish.isEmpty` guard below already handles a publish window
        // that contained no full tick at all.
        if full { fastSincePublish.append(fast) }

        // Live whole-system measurement. PSTR spikes (measured 4.24-17.90 W range
        // within one minute), so it is smoothed downstream like any other input.
        let pstrRaw = smc?.read("PSTR")?.value
        let ppmcRaw = smc?.read("PPMC")?.value
        if let p = pstrRaw, p.isFinite, p > 0 { pstrSincePublish.append(p) }

        // Rail windows are fed before anything reads them, so the anchor and the
        // bucket split are computed from the same samples on the same tick.
        if let p = pstrRaw, p.isFinite, p > 0.05 {
            pstrWindow.append(p)
            if pstrWindow.count > railWindow { pstrWindow.removeFirst() }
        }
        if let c = ppmcRaw, c.isFinite, c >= 0 {
            ppmcWindow.append(c)
            if ppmcWindow.count > railWindow { ppmcWindow.removeFirst() }
        }

        // Gas gauge: only recompute when a genuinely new batch has published.
        if let now = PowerTelemetry.sample() {
            if let prev = lastPublished, now.accumulatorCount != prev.accumulatorCount {
                if let w = SystemPowerWindow.between(prev, now) {
                    currentMeasured_W = w.power_mW / 1000
                    measuredAt = Date()
                    if !fastSincePublish.isEmpty {
                        let meanFast = fastSincePublish.reduce(0, +) / Double(fastSincePublish.count)
                        calibrator.observe(fast: meanFast, slow: w.power_mW / 1000)
                    }
                    if !pstrSincePublish.isEmpty {
                        let meanPstr = pstrSincePublish.reduce(0, +) / Double(pstrSincePublish.count)
                        gain.observe(fast: meanPstr, slow: w.power_mW / 1000)
                    }
                    fastSincePublish.removeAll()
                    pstrSincePublish.removeAll()
                }
                lastPublished = now
            } else if lastPublished == nil {
                lastPublished = now
            }
        }

        // Anchor priority: a live whole-system measurement beats an inferred one.
        //   1. SMC PSTR, gain-corrected  — measured, whole machine, every tick
        //   2. baseline + fast           — inferred, when SMC is unavailable
        //   3. the gauge itself          — accurate but 60 s stale
        //   4. raw fast                  — partial, last resort
        // The MEDIAN raw rail, not this tick's read. PSTR is as spiky as PPMC —
        // it swung 1.5 to 18 W on an idle-to-active machine within one minute —
        // and feeding that to an adaptive smoother whose jump detector exists to
        // chase step changes made the headline number chase noise instead. The
        // median rejects the excursions; the smoother then only has to track what
        // is left. Falls back to this tick's value until the window fills.
        let smcTotal = (Self.median(pstrWindow) ?? pstrRaw).map { gain.corrected($0) }

        let target = smcTotal ?? calibrator.estimate(fast: fast) ?? currentMeasured_W ?? fast
        let smoothed = smoother.update(target)

        let apps = DrainCalculator.group(drains, scale: scale)

        // Updated on every tick, light or full, so the filter keeps tracking
        // rather than jumping when the window is reopened after a gap.
        // The share of the two medians, applied to the displayed total, so the
        // buckets are consistent with the bar they are drawn in by construction.
        // Clamped at 1: the CPU cannot draw more than the whole machine.
        let smoothedCPURail: Double? = {
            guard let mc = Self.median(ppmcWindow), let mp = Self.median(pstrWindow),
                  mp > 0.05 else { return nil }
            // Scaled by the measured cost of a PPMC watt at the battery. Taking
            // PPMC at face value filed 17-25% of CPU power as unattributed.
            return min(1, mc / mp) * smoothed * SubsystemRails.cpuRailToBattery
        }()

        // Put names to the anonymous buckets. Only on full ticks: nothing renders
        // a process table while the window is hidden, and this costs a subprocess.
        var systemApps: [SystemAttribution.Row] = []
        var gpuApps: [SystemAttribution.Row] = []
        if full && attribution {
            systemAttribution.refreshIfNeeded()
            // Names as well as bundle ids: daemons have no bundle, so matching on
            // id alone lets exactly the overlapping population through twice.
            // Names of every process that currently exists, so a quit app cannot
            // be handed present-tense power from an hour-old rollup.
            let living = Set(ProcessSampler.runningNames().map { $0.lowercased() })
            let known = SystemAttribution.Attributed(
                bundleIDs: Set(apps.compactMap { $0.identity.bundleID }),
                names: Set(apps.map { $0.name }))
            if let cpu = smoothedCPURail {
                systemApps = systemAttribution.apportion(
                    watts: max(0, cpu - attributed), by: .cpuTime,
                    excluding: known, living: living, scale: scale)
            }
            // GPU is apportioned across ALL coalitions, not just the ones rusage
            // missed: rusage's energy counter is CPU-side, so no app has already
            // been credited with GPU power and there is nothing to exclude.
            if let g = gpu, g > 0 {
                gpuApps = systemAttribution.apportion(
                    watts: g, by: .gpuTime, excluding: .none, living: living, scale: scale)
            }
        }

        // Modeled from brightness, and clamped so it can never exceed what is
        // left after CPU and GPU. Without that clamp a bright screen on a busy
        // machine could claim more than the measurement allows, and the platform
        // bucket would hit its own zero floor while the bar overflowed.
        // MEASURED first. PDBR is the backlight's own rail: it tracked a
        // brightness sweep 0.204 -> 8.197 W and its full scale matches the
        // independently fitted span to within noise. Preferring it also captures
        // local dimming — this panel's backlight power depends on what is on
        // screen, which no brightness curve can know.
        //
        // The curve is the fallback for hardware whose rail cannot be read, and
        // stays labelled modeled there.
        // Quiet enough to attribute a step: the CPU rail is the thing most likely
        // to move by watts on its own, so a plug measured through a build is
        // rejected rather than credited to the device.
        let quiet = (ppmcRaw ?? 0) < 3.0
        usbTracker.update(systemWatts: smoothed, systemQuiet: quiet)

        // One battery read, fed to the limit learner and then handed to the
        // snapshot. Read twice it could straddle the cache TTL and teach the
        // learner about a charge level the snapshot does not report.
        let battery = Battery.state()
        if let b = battery { chargeLimits.observe(b, percent: scale.chargePercent(b)) }

        let usbMeasured = usbTracker.measuredWatts
        let memoryW = SubsystemRails.watts(smc, keys: SubsystemRails.memoryKeys)
        let storageW = SubsystemRails.watts(smc, keys: SubsystemRails.storageKeys)
        let displayMeasured = DisplayRail.watts(smc)
        let displayW: Double? = {
            let claim: Double?
            if let m = displayMeasured {
                claim = m
            } else if let m = displayModel, let b = DisplayBrightness.current() {
                claim = m.watts(brightness: b)
            } else {
                claim = nil
            }
            guard let c = claim else { return nil }
            let headroom = max(0, smoothed - (smoothedCPURail ?? 0) - (gpu ?? 0))
            return min(c, headroom)
        }()

        return Snapshot(
            drains: drains,
            apps: apps,
            systemApps: systemApps,
            gpuApps: gpuApps,
            systemAttributionAge: systemAttribution.age,
            isFullSample: full,
            attributed_W: attributed,
            rails: reading?.rails ?? [],
            gpu_W: gpu,
            fast_W: fast,
            measured_W: currentMeasured_W,
            measuredAge: measuredAt.map { Date().timeIntervalSince($0) },
            smoothed_W: smoothed,
            isCalibrated: gain.isCalibrated || calibrator.isCalibrated,
            smcTotal_W: smcTotal,
            smcGain: gain.value,
            // Same gain as PSTR: they are the same measurement family, so correcting
            // one and not the other would make the buckets fail to sum.
            cpuRail_W: smoothedCPURail,
            display_W: displayW,
            memory_W: memoryW,
            storage_W: storageW,
            usb_W: usbMeasured > 0 ? usbMeasured : nil,
            usbHasUnmeasured: usbTracker.hasUnmeasuredDevices,
            usbHasRemembered: usbTracker.hasRememberedDevices,
            usbDevices: usbTracker.attached,
            displayIsMeasured: displayMeasured != nil,
            baseline_W: calibrator.baseline,
            didJump: smoother.didJump,
            // Nil on a light tick. "Everything we measured minus everything we
            // attributed" is not a residual when the attribution step never ran —
            // it is the whole measurement wearing the residual's name, and it
            // reached the UI as "100% unattributed".
            residual_W: full ? max(0, smoothed - attributed - (gpu ?? 0)) : nil,
            // UNCLAMPED. The clamped residual above makes the ledger identity
            // attributed + gpu + residual == smoothed true BY CONSTRUCTION, so
            // checking it proves nothing. This raw value is the only informative
            // signal: if it goes NEGATIVE we have attributed more power than we
            // measured, which is physically impossible and means double counting
            // (most likely rusage CPU energy overlapping the IOReport GPU rail,
            // or the PSTR gain drifting low). Surfaced so it can be alarmed on
            // rather than silently absorbed by max(0, ...).
            rawResidual_W: smoothed - attributed - (gpu ?? 0),
            scale: scale,
            state: battery,
            // Light ticks report zeroes rather than carrying the last full sweep's
            // figures forward — a stale coverage figure would be worse. But a zero
            // here means "no sweep was attempted", NOT "no process was readable",
            // and nothing in the number itself says which. `isFullSample` is what
            // tells them apart, and every consumer must consult it: rendered
            // bare, this zero reads as "we can see 0% of your processes".
            coverage: sweep?.coverage ?? 0,
            denied: sweep?.denied ?? 0,
            readable: sweep?.processes.count ?? 0,
            attempted: sweep?.attempted ?? 0,
            interval: interval,
            chargeTarget: battery.map {
                chargeLimits.target(atPercent: scale.chargePercent($0),
                                    isCharging: $0.isCharging && $0.amperage_mA > 0)
            }
        )
    }

    /// Throw away every quantity that accumulated ACROSS a gap in observation.
    ///
    /// Each of these fuses samples over time, so one pre-gap entry taints
    /// everything computed after the wake: the rolling medians would still be
    /// describing the rails as they were nine hours ago, the smoother would treat
    /// the first real post-wake reading as an outlier to resist for two more ticks,
    /// and `lastPublished` — the one that matters most — would make the next
    /// gas-gauge window span the whole sleep and hand `record` a 32,400 s mean.
    ///
    /// The calibrators are deliberately NOT reset. A learned baseline and a PSTR
    /// gain are properties of the machine, and it is the same machine when it
    /// wakes; discarding them would cost a minute of uncorrected readings for no
    /// gain in honesty.
    func resetAcrossGap() {
        tracker.reset()
        smoother.reset()
        pstrWindow.removeAll()
        ppmcWindow.removeAll()
        fastSincePublish.removeAll()
        pstrSincePublish.removeAll()
        lastSweep = nil
        lastSweepAwake = nil
        lastLightTick = nil
        lastLightTickAwake = nil
        lastPublished = nil
        // The gauge figure is a 60 s mean from before the sleep, and `measuredAge`
        // would report it as nine hours old rather than absent. Nil, not stale: an
        // unmeasured window must not be reported as a measured one.
        currentMeasured_W = nil
        measuredAt = nil
    }

    /// Everything `resetAcrossGap` has to clear, in one comparable value.
    ///
    /// It exists so the regression test can assert on the WHOLE set at once rather
    /// than a hand-picked few, and so an accumulator added later shows up here and
    /// fails that test until the reset handles it. The first cut of this fix reset
    /// the tracker and the smoother and left everything below them poisoning the
    /// first post-wake minute.
    struct Accumulators: Equatable {
        var trackedProcesses = 0
        var smoothed: Double?
        var pstrSamples = 0
        var ppmcSamples = 0
        var fastSincePublish = 0
        var pstrSincePublish = 0
        var hasLastSweep = false
        var hasLastLightTick = false
        var hasLastPublished = false
        var measured_W: Double?
        var hasMeasuredAt = false
    }

    /// The paired timestamps are OR-ed rather than reported separately so that
    /// clearing one and forgetting its twin still fails the test.
    var accumulators: Accumulators {
        Accumulators(trackedProcesses: tracker.trackedCount,
                     smoothed: smoother.value,
                     pstrSamples: pstrWindow.count,
                     ppmcSamples: ppmcWindow.count,
                     fastSincePublish: fastSincePublish.count,
                     pstrSincePublish: pstrSincePublish.count,
                     hasLastSweep: lastSweep != nil || lastSweepAwake != nil,
                     hasLastLightTick: lastLightTick != nil || lastLightTickAwake != nil,
                     hasLastPublished: lastPublished != nil,
                     measured_W: currentMeasured_W,
                     hasMeasuredAt: measuredAt != nil)
    }
}

/// One sample at a time, and a count of the ticks that were turned away.
///
/// The sampling loop dispatched onto the global CONCURRENT queue, so a tick that
/// ran long simply overlapped the next one. Both then mutated the same state:
/// `PowerMonitor`'s rolling rail windows, its paired wall/awake timestamps and
/// `lastPublished`; `CPUUsage.previous` and `NetworkThroughput.previous`; the SMC
/// wrapper, which takes no lock at all. Concurrent Swift Dictionary mutation is a
/// crash, not a wrong number.
///
/// A serial queue alone only DEFERS the overlap: ticks would queue behind the slow
/// one and then run back to back, each differencing an interval that no longer
/// matches the cadence it is supposed to represent. So the late tick is dropped
/// instead — which is honest, because it never happened — and the drop is counted.
///
/// Dropping is safe for the sleep-gap logic and does not need to tell it anything.
/// A drop is a no-op on the monitor, so the next admitted tick measures the whole
/// elapsed span and `straddlesGap` judges it on its merits: a short run of drops
/// widens the interval within the plausible window and is recorded as the longer
/// (still genuinely differenced) sample it is, while a stall past
/// `maxPlausibleInterval` is treated as the gap in observation it also is. The one
/// thing that would break it is holding the gate across the gap, which is why
/// `submit` owns the release rather than trusting the call site to unwind.
public final class SamplingGate {

    private let lock = NSLock()
    private var isSampling = false
    private var droppedTicks = 0

    public init() {}

    /// Runs `sample` on `queue` unless a sample is still in flight, in which case
    /// this tick is counted as dropped and `sample` never runs. Returns whether it
    /// was admitted.
    ///
    /// Releasing the gate is deliberately not the caller's job: the sampling block
    /// has several early returns (no snapshot, deallocated delegate), and one of
    /// them forgetting to unwind would stop sampling permanently and silently — a
    /// far worse failure than the overlap this exists to prevent.
    @discardableResult
    public func submit(on queue: DispatchQueue, _ sample: @escaping () -> Void) -> Bool {
        lock.lock()
        if isSampling {
            droppedTicks += 1
            lock.unlock()
            return false
        }
        isSampling = true
        lock.unlock()

        queue.async { [self] in
            defer {
                lock.lock()
                isSampling = false
                lock.unlock()
            }
            sample()
        }
        return true
    }

    /// Ticks turned away since launch. Surfaced as `MetricID.samplerDrops` rather
    /// than only counted: dropped ticks are gaps in the history, and a monitor
    /// quietly sampling less often than it claims to is exactly the kind of thing
    /// this app refuses to do to its own numbers.
    public var dropped: Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedTicks
    }
}

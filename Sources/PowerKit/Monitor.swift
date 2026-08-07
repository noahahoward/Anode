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
        public var systemProcesses_W: Double? {
            guard let cpu = cpuRail_W else { return nil }
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
        public var platform_W: Double? {
            guard cpuRail_W != nil else { return nil }
            // Display is subtracted here so the segments still sum to the bar:
            // it is a named slice OF this bucket, not an addition to the total.
            return max(0, smoothed_W - (cpuRail_W ?? 0) - (gpu_W ?? 0) - (display_W ?? 0))
        }

        /// Estimated display backlight watts, or nil when brightness is unreadable.
        /// MODELED, not measured: a calibrated response curve for this panel. It
        /// is carved OUT of the platform bucket rather than added to the total,
        /// so the ledger still sums to what was measured.
        public let display_W: Double?
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

        public var residualShare: Double? {
            guard let r = residual_W, smoothed_W > 0 else { return nil }
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

        /// Hours until the pack is full, from measured charge current.
        public var timeToFull_hr: Double? {
            guard direction == .charging, let s = state, s.amperage_mA > 0 else { return nil }
            let missing = scale.fullChargeCapacity_mAh - s.remainingCapacity_mAh
            guard missing > 0 else { return nil }
            return missing / Double(s.amperage_mA)
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
    /// Rolling-window per-process rates. Replaces sweep-to-sweep differencing,
    /// which dropped any process whose sparse energy counter did not happen to
    /// move during that particular 2 s window. See DrainTracker.
    private let tracker = DrainTracker(window: 10)
    /// Names the CPU power rusage cannot attribute. Refreshed on its own queue —
    /// it shells out to `systemstats`, which must never happen on a tick path.
    private let systemAttribution = SystemAttribution()
    /// Backlight response curve. One struct so a different panel means different
    /// coefficients rather than edits scattered through the monitor.
    private let displayModel = DisplayPowerModel.measuredOnThisMac

    public var ioReportAvailable: Bool { ioreport != nil }

    public init?(scale: BatteryScale? = nil) {
        guard let s = scale ?? Battery.scale() else { return nil }
        self.scale = s
        self.lastPublished = PowerTelemetry.sample()
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
        defer { if let s = sweep { lastSweep = s } }

        // In light mode the per-process numbers are simply absent rather than stale:
        // callers get empty `drains`/`apps` and an attributed figure of zero, which
        // the UI must not render as "apps used nothing". Nothing draws them while
        // hidden, and the next full tick repopulates before the window is shown.
        var drains: [ProcessDrain] = []
        var attributed = 0.0
        var interval: TimeInterval = 0
        if let sweep {
            guard let prior = lastSweep else { return nil }
            drains = tracker.update(with: sweep, scale: scale)
            attributed = drains.reduce(0) { $0 + $1.watts }
            interval = sweep.timestamp.timeIntervalSince(prior.timestamp)
        } else {
            interval = lastLightTick.map { Date().timeIntervalSince($0) } ?? 0
        }
        lastLightTick = Date()
        let gpu = reading?.gpu_W
        let fast = attributed + (gpu ?? 0)
        fastSincePublish.append(fast)

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
            return min(1, mc / mp) * smoothed
        }()

        // Put names to the anonymous buckets. Only on full ticks: nothing renders
        // a process table while the window is hidden, and this costs a subprocess.
        var systemApps: [SystemAttribution.Row] = []
        var gpuApps: [SystemAttribution.Row] = []
        if full && attribution {
            systemAttribution.refreshIfNeeded()
            // Names as well as bundle ids: daemons have no bundle, so matching on
            // id alone lets exactly the overlapping population through twice.
            let known = SystemAttribution.Attributed(
                bundleIDs: Set(apps.compactMap { $0.identity.bundleID }),
                names: Set(apps.map { $0.name }))
            if let cpu = smoothedCPURail {
                systemApps = systemAttribution.apportion(
                    watts: max(0, cpu - attributed), by: .cpuTime,
                    excluding: known, scale: scale)
            }
            // GPU is apportioned across ALL coalitions, not just the ones rusage
            // missed: rusage's energy counter is CPU-side, so no app has already
            // been credited with GPU power and there is nothing to exclude.
            if let g = gpu, g > 0 {
                gpuApps = systemAttribution.apportion(
                    watts: g, by: .gpuTime, excluding: .none, scale: scale)
            }
        }

        // Modeled from brightness, and clamped so it can never exceed what is
        // left after CPU and GPU. Without that clamp a bright screen on a busy
        // machine could claim more than the measurement allows, and the platform
        // bucket would hit its own zero floor while the bar overflowed.
        let displayW: Double? = {
            guard let b = DisplayBrightness.current() else { return nil }
            let modeled = displayModel.watts(brightness: b)
            let headroom = max(0, smoothed - (smoothedCPURail ?? 0) - (gpu ?? 0))
            return min(modeled, headroom)
        }()

        return Snapshot(
            drains: drains,
            apps: apps,
            systemApps: systemApps,
            gpuApps: gpuApps,
            systemAttributionAge: systemAttribution.age,
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
            baseline_W: calibrator.baseline,
            didJump: smoother.didJump,
            residual_W: max(0, smoothed - attributed - (gpu ?? 0)),
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
            state: Battery.state(),
            // Light ticks report zero coverage rather than carrying the last full
            // sweep's figures forward, so the UI can tell "not measured this tick"
            // apart from "measured and found nothing".
            coverage: sweep?.coverage ?? 0,
            denied: sweep?.denied ?? 0,
            readable: sweep?.processes.count ?? 0,
            attempted: sweep?.attempted ?? 0,
            interval: interval
        )
    }
}

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
        /// Watts belonging to no visible process: display, radios, SSD, kernel.
        public let baseline_W: Double?
        public let didJump: Bool
        public let residual_W: Double?
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

        /// Projected runtime at the smoothed draw — independent of macOS's estimate.
        public func projectedRuntime_hr() -> Double? {
            guard smoothed_W > 0, let s = state, !s.onAC else { return nil }
            return Double(s.percent) * scale.joulesPerPercent / smoothed_W / 3600
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
    /// Fast samples accumulated since the last gas-gauge publish, so calibration
    /// compares like with like: a mean over the same period, not a single instant.
    private var fastSincePublish: [Double] = []

    public var ioReportAvailable: Bool { ioreport != nil }

    public init?(scale: BatteryScale? = nil) {
        guard let s = scale ?? Battery.scale() else { return nil }
        self.scale = s
        self.lastPublished = PowerTelemetry.sample()
    }

    /// Returns nil on the very first tick — there is no window to diff against yet.
    @discardableResult
    public func tick() -> Snapshot? {
        let sweep = ProcessSampler.sweep()
        let reading = ioreport?.sample()
        defer { lastSweep = sweep }

        guard let prior = lastSweep else { return nil }

        let drains = DrainCalculator.between(prior, sweep, scale: scale)
        let attributed = drains.reduce(0) { $0 + $1.watts }
        let gpu = reading?.gpu_W
        let fast = attributed + (gpu ?? 0)
        fastSincePublish.append(fast)

        // Live whole-system measurement. PSTR spikes (measured 4.24-17.90 W range
        // within one minute), so it is smoothed downstream like any other input.
        let pstrRaw = smc?.read("PSTR")?.value
        if let p = pstrRaw, p.isFinite, p > 0 { pstrSincePublish.append(p) }

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
        let smcTotal = pstrRaw.map { gain.corrected($0) }
        let target = smcTotal ?? calibrator.estimate(fast: fast) ?? currentMeasured_W ?? fast
        let smoothed = smoother.update(target)

        return Snapshot(
            drains: drains,
            apps: DrainCalculator.group(drains, scale: scale),
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
            baseline_W: calibrator.baseline,
            didJump: smoother.didJump,
            residual_W: max(0, smoothed - attributed - (gpu ?? 0)),
            scale: scale,
            state: Battery.state(),
            coverage: sweep.coverage,
            denied: sweep.denied,
            readable: sweep.processes.count,
            attempted: sweep.attempted,
            interval: sweep.timestamp.timeIntervalSince(prior.timestamp)
        )
    }
}

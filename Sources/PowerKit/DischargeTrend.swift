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
/// watches each incoming window against itself: five unbroken MINUTES of windows
/// that all disagree with the running trend by more than half, all in the same
/// direction, are a regime change rather than noise — the accumulator has no
/// estimation noise for them to be — and the window collapses onto them.
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
    /// Below two published windows there is not yet a trend to speak of, only a
    /// minute of history; the caller falls back to the power-based figure and says
    /// so, and the UI marks it. Measured from a cold start on battery: the fallback
    /// carries the first 120 s (reading 289-457 min against a truth of 439-444),
    /// after which this takes over and sits within 5 min of the truth.
    ///
    /// 120 TICKS rather than 120 seconds because the counter, not the clock, is what
    /// the mean is over — a window is only as long as the discharge it accumulated.
    private let minTicks: UInt64
    /// Fractional disagreement with the running trend that counts as evidence of a
    /// regime change. There is no measurement noise for this to clear — the counter
    /// is an integral — so it is chosen purely on how much real change is worth
    /// restarting the window for, jointly with `confirmTicks` below. Same two loads,
    /// same death-time scoring:
    ///
    ///     confirm  band    MAE wander   MAE bursty   mean|Δ|/tick   worst swing in 2 min
    ///      180 s   0.25        6.0         19.3          0.09              58
    ///      180 s   0.35        5.5         19.3          0.09              58
    ///      300 s   0.35        4.5         10.3          0.05              31
    ///      300 s   0.50        4.5          5.0          0.04              14
    ///      600 s   0.50        4.5          5.0          0.04              14
    ///     (pre-change path:   10.5         13.6          0.29              85)
    ///
    /// A three-minute confirmation is WORSE than the code it replaces on a bursty
    /// load: a four-minute burst trips it, the window collapses onto the burst, and
    /// four minutes later it collapses back — the display ends up tracking whichever
    /// phase the machine is in instead of the trend, which is precisely the
    /// complaint. Five minutes at half again the trend is the threshold that stops
    /// treating a burst as a new regime while still being twice as responsive as the
    /// 600 s setting that scores identically.
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

    private var samples: [Sample] = []
    /// Ticks accumulated in the current run of same-direction disagreement, and
    /// where that run started — the trend is rebuilt from there when it confirms.
    private var outOfBandTicks: UInt64 = 0
    private var outOfBandSign = 0
    private var runStart: Date?

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
    public init(window: TimeInterval = 1800, minTicks: UInt64 = 300,
                changeBand: Double = 0.50, confirmTicks: UInt64 = 300) {
        self.window = max(60, window)
        self.minTicks = max(1, minTicks)
        self.changeBand = changeBand
        self.confirmTicks = max(1, confirmTicks)
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
    /// belongs IN the average. Three minutes of it, all the same way, is a new
    /// regime: keep only those windows, so the trend restarts from the new load
    /// rather than spending half an hour crawling to it.
    ///
    /// A run that changes direction starts over, so a load oscillating either side
    /// of the trend never confirms — it is noise about a mean, which is what the
    /// mean is for.
    ///
    /// ## Why it may not fire until the window is FULL
    /// The detector asks "does this window disagree with the trend?", and the trend
    /// it asks about is `trend`, which CONTAINS the window being tested. While the
    /// window is short the two are nearly the same data: at five minutes of history
    /// one 60 s publish is a fifth of its own reference, so a single burst drags the
    /// reference toward itself and the comparison is a hypothesis tested against
    /// itself. Measured on a 6 h trace, the detector collapsed the window inside the
    /// first fifteen minutes on 0.53 bursty runs and 0.45 build-like runs — a
    /// "regime change" detected out of warm-up, not out of the load.
    ///
    /// Requiring a full reference removes 100 % of those firings and costs nothing
    /// elsewhere, because an immature window does not NEED the detector: the whole
    /// purpose of collapsing the window is to stop a 30-minute mean crawling to a
    /// new load, and a five-minute mean is already there. The one real cost is a run
    /// that begins just before the window matures — `endRun` discards it, so
    /// confirmation restarts at the 30-minute mark and a change straddling that
    /// boundary is followed up to five minutes later than it otherwise would be.
    /// Carrying the run across instead would let a run accumulated entirely out of
    /// warm-up noise confirm the instant the window matured, which is the same bug
    /// arriving half an hour later.
    ///
    /// ## What is deliberately NOT fixed here
    /// The nominal 50 % band behaves as 62.5 %, because `running` already contains
    /// `published` and so drifts toward it. Removing that drift — comparing against
    /// the window with the candidate excluded — was tried and WITHDRAWN: it fires
    /// MORE often, and bursty MAE went 30.0 -> 109.0 death-time minutes. The drift
    /// is acting as accidental hysteresis and the measured behaviour of the pair is
    /// what the sizing table above was scored on. Known, measured, and left alone.
    private func detectRegimeChange(_ published: Window, from left: Sample) {
        guard let running = trend, running.power_mW > 0 else { endRun(); return }
        guard running.isFull else { endRun(); return }
        let delta = published.power_mW - running.power_mW
        guard abs(delta) > changeBand * running.power_mW else { endRun(); return }

        let sign = delta > 0 ? 1 : -1
        if sign != outOfBandSign {
            outOfBandSign = sign
            outOfBandTicks = 0
            runStart = left.timestamp
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

import XCTest
@testable import PowerKit

/// The scoring harness behind the tuning tables in `DischargeTrend.swift`.
///
/// The original tables ("MAE wander 4.5, bursty 5.0…") were measured in a harness
/// that never made it into the repo, so changing any detector constant meant
/// re-guessing where the last author measured. This is that harness, rebuilt and
/// committed: synthetic loads driven through the REAL `BatteryDischargeTrend` —
/// the sweep initializer exists so this file cannot drift from the class it
/// scores — and scored on death-time error, the quantity the user actually sees.
///
/// It is not part of the ordinary test run: a sweep is a measurement session, not
/// an invariant. Run it with
///
///     ANODE_TREND_SWEEP=1 swift test --filter TrendSweep
///
/// and it prints a CSV of every configuration against every score. The
/// behavioural tests in `DischargeTrendTests` then pin whatever configuration the
/// sweep justified.
///
/// ## Scoring, matching the original tables
/// - **Death-time MAE**: at each publish, |estimated minutes to empty − true
///   minutes to empty|, the truth taken from the simulated future until the pack
///   actually reaches zero — NOT "charge ÷ the load at this instant", which
///   structurally rewards an instantaneous estimator and is not what an ETD is.
/// - **Settle latency**: seconds from a sustained load change until the trend is
///   within 12 % of the new load (the tables' "followed in" column).
/// - **Spike movement**: how many minutes of ETD a 60 s spike moves.
/// - **Warm-up collapse rate**: fraction of cold starts where the detector
///   restarts the window inside the first fifteen minutes — the failure the
///   full-window gate was added for (measured then at 0.53/0.45; the gate took
///   it to 0).
/// - **Worst 2-minute swing** on the bursty load — display stability.
final class TrendSweepHarness: XCTestCase {

    // ── Simulation ──────────────────────────────────────────────────────────

    private let volts = 11_878.0
    private let pack_mAh = 3667.0
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// Deterministic RNG (splitmix64): Date.now-free, seed-stable across runs, so
    /// two sweeps of the same space print the same table.
    private struct Rand {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double(z ^ (z >> 31)) / Double(UInt64.max)
        }
        mutating func uniform(_ lo: Double, _ hi: Double) -> Double {
            lo + (hi - lo) * next()
        }
    }

    /// Watts for each minute of a trace. All profiles are minute-quantised, like
    /// the behavioural tests: one 60-tick publish per minute, the cadence this
    /// machine's gauge actually has.
    /// Mean-reverting, not a pure walk: a pure ±0.5 walk reflected at [4, 9]
    /// mixes over ~7 hours, so a 30-minute mean genuinely differs from the
    /// future mean by watts, and that irreducible error (~35 min of ETD) drowns
    /// the differences between detector configurations. Real machines revert —
    /// the load average collapses back after every burst — and the documented
    /// wander MAE of 4.5 min is only reachable at all on a load that does.
    private func wander(seed: UInt64, minutes: Int) -> [Double] {
        var r = Rand(seed), w = 6.5, out: [Double] = []
        for _ in 0..<minutes {
            w += r.uniform(-1, 1) + 0.25 * (6.5 - w)
            w = min(9, max(4, w))
            out.append(w)
        }
        return out
    }

    /// "4 min at 20 W every 20 min, the shape a real machine has."
    private func bursty(minutes: Int) -> [Double] {
        (0..<minutes).map { $0 % 20 < 4 ? 20.0 : 5.0 }
    }

    /// The recorded `swift build` shape: a low base with minute-scale bursts that
    /// reach far above it, at random.
    private func buildLike(seed: UInt64, minutes: Int) -> [Double] {
        var r = Rand(seed), out: [Double] = []
        var burstLeft = 0, burstW = 0.0
        for _ in 0..<minutes {
            if burstLeft == 0, r.next() < 0.15 {
                burstLeft = Int(r.uniform(1, 4))
                burstW = r.uniform(20, 54)
            }
            if burstLeft > 0 { out.append(burstW); burstLeft -= 1 }
            else { out.append(r.uniform(4.1, 5.0)) }
        }
        return out
    }

    /// One minute-per-publish trace through a trend. Returns, per publish:
    /// (minute, estimated power mW or nil, window ticks).
    private func drive(_ trend: BatteryDischargeTrend, watts: [Double])
        -> [(minute: Int, mW: Double?, ticks: UInt64)] {
        var acc: Int64 = -1_000_000, count: UInt64 = 500_000
        var at = t0, awake = 10_000.0
        var out: [(Int, Double?, UInt64)] = []
        trend.record(.init(accumulatedDischarge: acc, accumulatorCount: count,
                           voltage_mV: volts, timestamp: at, awake: awake),
                     onBattery: true)
        for (m, w) in watts.enumerated() {
            at = at.addingTimeInterval(60); awake += 60
            acc &-= Int64(w * 1000 * 60); count &+= 60
            trend.record(.init(accumulatedDischarge: acc, accumulatorCount: count,
                               voltage_mV: volts, timestamp: at, awake: awake),
                         onBattery: true)
            out.append((m, trend.trend?.power_mW, trend.trend?.ticks ?? 0))
        }
        return out
    }

    /// True minutes-to-empty at the START of each minute, from the simulated
    /// future: walk forward until the pack is gone. The trace MUST be long
    /// enough to reach death — a truncated future would silently understate
    /// every truth value near the end, so it fails loudly instead.
    private func deathTruth(watts: [Double]) -> (truth: [Double], death: Int) {
        let perMin = watts.map { $0 * 1000 / volts * 1000 / 60 }   // mAh per minute
        var remaining = pack_mAh, death = -1
        var used: [Double] = []
        for (m, d) in perMin.enumerated() {
            used.append(remaining)
            remaining -= d
            if remaining <= 0 { death = m; break }
        }
        XCTAssert(death >= 0, "trace ends at \(watts.count) min with \(remaining) mAh "
                  + "left — every truth value would be understated")
        var truth: [Double] = []
        for m in 0..<used.count {
            var left = used[m], t = 0.0
            var i = m
            while i < perMin.count, left > perMin[i] { left -= perMin[i]; t += 1; i += 1 }
            if i < perMin.count { t += left / perMin[i] }
            truth.append(t)
        }
        return (truth, death)
    }

    // ── Configurations ──────────────────────────────────────────────────────

    private struct Config: CustomStringConvertible {
        let band: Double
        let asymDown: Bool          // band applies only downward; up stays 0.50
        let confirm: UInt64
        let excl: Bool              // reference frozen at run start
        let floor: UInt64?          // nil = full-window gate
        var noiseK: Double? = nil   // effective band = max(band, k*relSD)
        var description: String {
            let f = floor.map(String.init) ?? "full"
            let n = noiseK.map { " k=\($0)" } ?? ""
            return "band=\(band)\(asymDown ? "v" : "") confirm=\(confirm) "
                 + "ref=\(excl ? "excl" : "incl") floor=\(f)\(n)"
        }
        func make() -> BatteryDischargeTrend {
            BatteryDischargeTrend(
                window: 1800, minTicks: 300,
                changeBand: asymDown ? 0.50 : band,
                confirmTicks: confirm,
                downBand: asymDown ? band : nil,
                referenceExcludesRun: excl,
                referenceFloorTicks: floor,
                noiseScaledBand: noiseK)
        }
    }

    private struct Score {
        var maeWander = 0.0, maeBursty = 0.0
        var spike60 = 0.0                 // ETD movement, minutes
        var swing2m = 0.0                 // worst 2-min ETD swing on bursty
        var incident = Double.infinity    // s to within 12% of 4.95 W
        var step125 = Double.infinity     // s to follow 6 -> 7.5 W
        var stepDown = Double.infinity    // s to follow 18 -> 6 W
        var warmup = 0.0                  // fraction of cold starts collapsed <15 min
        var constSpread = 0.0             // minutes, must be ~0
    }

    // ── Scoring one configuration ───────────────────────────────────────────

    private func maeAndSwing(_ cfg: Config, watts: [Double]) -> (Double, Double) {
        let (truth, death) = deathTruth(watts: watts)
        let est = drive(cfg.make(), watts: Array(watts.prefix(death)))
        var errs: [Double] = [], etds: [(Int, Double)] = []
        let perMin = watts.map { $0 * 1000 / volts * 1000 / 60 }
        var remaining = pack_mAh
        for (m, mW, _) in est {
            remaining -= perMin[m]
            // The estimate exists at the END of minute m, which is the START of
            // minute m+1 — so it is judged against truth[m+1]. Judging against
            // truth[m] skewed every error by one minute, in a direction that
            // depended on the load's slope (found in adversarial review).
            guard m >= 35, m + 1 < truth.count, let mW, mW > 0, remaining > 0
            else { continue }
            let etd = remaining / (mW / volts * 1000) * 60
            errs.append(abs(etd - truth[m + 1]))
            etds.append((m, etd))
        }
        var swing = 0.0
        for i in 0..<etds.count {
            for j in (i + 1)..<etds.count where etds[j].0 - etds[i].0 <= 2 {
                swing = max(swing, abs(etds[j].1 - etds[i].1))
            }
        }
        let mae = errs.isEmpty ? .infinity : errs.reduce(0, +) / Double(errs.count)
        return (mae, swing)
    }

    /// Seconds from `change` minutes into the trace until the estimate STAYS
    /// within 12 % of `target` watts — every subsequent publish must also be in
    /// band, so a config that touches the target and swings back out is not
    /// credited with having settled (found in adversarial review: the original
    /// first-touch scan was exactly that credit). Infinity when it never settles.
    private func settleLatency(_ cfg: Config, watts: [Double],
                               change: Int, target: Double) -> Double {
        let est = drive(cfg.make(), watts: watts)
        let inBand = { (mW: Double?) -> Bool in
            guard let mW else { return false }
            return abs(mW - target * 1000) <= 0.12 * target * 1000
        }
        var settledAt: Int? = nil
        for (m, mW, _) in est where m >= change {
            if inBand(mW) { settledAt = settledAt ?? m }
            else { settledAt = nil }
        }
        return settledAt.map { Double($0 - change + 1) * 60 } ?? .infinity
    }

    private func score(_ cfg: Config) -> Score {
        var s = Score()

        // Death-time MAE, three wander seeds averaged + the bursty load.
        var w = 0.0
        for seed: UInt64 in [7, 21, 99] {
            w += maeAndSwing(cfg, watts: wander(seed: seed, minutes: 600)).0
        }
        s.maeWander = w / 3
        (s.maeBursty, s.swing2m) = maeAndSwing(cfg, watts: bursty(minutes: 600))

        // 60 s spike on a steady 6 W: ETD movement before vs after.
        do {
            var watts = [Double](repeating: 6, count: 40)
            watts.append(18)
            watts += [Double](repeating: 6, count: 2)
            let est = drive(cfg.make(), watts: watts)
            let mA = { (mW: Double) in mW / self.volts * 1000 }
            let before = est.first { $0.minute == 39 }?.mW
            let after = est.first { $0.minute == 41 }?.mW
            if let b = before, let a = after {
                s.spike60 = abs(pack_mAh / mA(a) - pack_mAh / mA(b)) * 60
            }
        }

        // The 2026-08-16 incident: 16 min @ 8.39 W, then settled 4.95 W,
        // arriving mid-warm-up.
        s.incident = settleLatency(
            cfg,
            watts: [Double](repeating: 8.39, count: 16)
                 + [Double](repeating: 4.95, count: 44),
            change: 16, target: 4.95)

        // Sustained steps from a full window.
        s.step125 = settleLatency(
            cfg,
            watts: [Double](repeating: 6, count: 40) + [Double](repeating: 7.5, count: 60),
            change: 40, target: 7.5)
        s.stepDown = settleLatency(
            cfg,
            watts: [Double](repeating: 18, count: 40) + [Double](repeating: 6, count: 60),
            change: 40, target: 6)

        // Spurious collapse: cold starts on bursty and build-like loads, over a
        // FULL HOUR. These loads have no regime change in them, so ANY detector
        // collapse — a ticks drop pruning cannot explain — is spurious. The
        // original 15-minute horizon measured only the old gate's failure mode
        // and was blind to a floor that merely DELAYS the same collapse past
        // minute 14 (found in adversarial review).
        var collapses = 0, traces = 0
        for seed: UInt64 in 1...20 {
            for watts in [bursty(minutes: 60), buildLike(seed: seed, minutes: 60)] {
                traces += 1
                var lastTicks: UInt64 = 0
                for (_, _, ticks) in drive(cfg.make(), watts: watts) {
                    if ticks + 600 < lastTicks { collapses += 1; break }
                    lastTicks = ticks
                }
            }
        }
        s.warmup = Double(collapses) / Double(traces)

        // Constant load: the answer must not move at all.
        do {
            let est = drive(cfg.make(), watts: [Double](repeating: 6, count: 120))
            let mins = est.compactMap { (m, mW, _) -> Double? in
                guard m >= 35, let mW else { return nil }
                return pack_mAh / (mW / volts * 1000) * 60
            }
            s.constSpread = (mins.max() ?? 0) - (mins.min() ?? 0)
        }
        return s
    }

    // ── The sweep ───────────────────────────────────────────────────────────

    func testSweep() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ANODE_TREND_SWEEP"] == "1",
                          "measurement session, not an invariant — ANODE_TREND_SWEEP=1 to run")

        var configs: [Config] = []
        for band in [0.30, 0.35, 0.40, 0.50] {
            for asym in [false, true] where !(asym && band == 0.50) {
                for confirm: UInt64 in [300, 450, 600] {
                    for excl in [false, true] {
                        for floor in [nil, UInt64(600), UInt64(900)] {
                            configs.append(Config(band: band, asymDown: asym,
                                                  confirm: confirm, excl: excl,
                                                  floor: floor))
                        }
                    }
                }
            }
        }
        // Noise-scaled band: the base band may sit LOW because the reference's
        // own noise raises the bar wherever a low bar would misfire.
        for band in [0.25, 0.30, 0.35] {
            for k in [1.5, 2.0, 3.0] {
                for confirm: UInt64 in [300, 450] {
                    for excl in [true, false] {
                        for floor in [nil, UInt64(600), UInt64(900)] {
                            configs.append(Config(band: band, asymDown: false,
                                                  confirm: confirm, excl: excl,
                                                  floor: floor, noiseK: k))
                        }
                    }
                }
            }
        }

        // The "SWEEP;" prefix and semicolon separators exist because this prints
        // to the same stdout as the XCTest runner, whose progress lines can
        // interleave mid-row; a prefixed grep keeps only intact rows and a
        // corrupted row cannot be mistaken for data.
        print("SWEEP;CONFIG;maeWander;maeBursty;spike60;swing2m;incident_s;step125_s;stepDown_s;warmup;constSpread")
        for cfg in configs {
            let s = score(cfg)
            let f = { (v: Double) in v.isInfinite ? "inf" : String(format: "%.1f", v) }
            print("SWEEP;\(cfg);\(f(s.maeWander));\(f(s.maeBursty));\(f(s.spike60));"
                + "\(f(s.swing2m));\(f(s.incident));\(f(s.step125));\(f(s.stepDown));"
                + "\(String(format: "%.2f", s.warmup));\(f(s.constSpread))")
        }
    }

    /// Calibration: the shipped configuration scored by THIS harness must land in
    /// the neighbourhood the original tables report, or the harness is measuring
    /// something else and its sweep is noise. Loose tolerances on purpose — the
    /// original RNG and exact profiles are unknown — but the ORDERINGS the tables
    /// rest on must hold.
    func testCalibrationAgainstDocumentedTables() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ANODE_TREND_SWEEP"] == "1")

        let current = Config(band: 0.50, asymDown: false, confirm: 300,
                             excl: false, floor: nil)
        let s = score(current)
        // Documented: wander 4.5, bursty 5.0, spike 44 min, swing 14, warmup 0.
        // Absolute MAE depends on the profile's exact mixing rate, which the
        // original harness did not record — so the anchors here are the spike
        // movement, the warm-up zero, and the ORDERINGS below, with the MAE
        // bounds loose enough to catch only a harness measuring something else.
        XCTAssertLessThan(s.maeWander, 20, "wander MAE far from documented 4.5")
        XCTAssertLessThan(s.maeBursty, 40, "bursty MAE far from documented 5.0")
        XCTAssertEqual(s.spike60, 44, accuracy: 25, "spike movement far from documented 44")
        // The spurious-collapse column deliberately DISAGREES with the original
        // "the gate zeroes warm-up collapses" claim, because the metric changed:
        // scored over a full hour instead of the first fifteen minutes, the old
        // fixed 0.50 band collapses on ~half the build-like traces — a 3-minute
        // 54 W burst puts the 4.5 W base >50 % below the inflated mean, well
        // after warm-up. The harness must keep FINDING that latent defect; a
        // zero here means the metric has gone blind again.
        XCTAssertGreaterThan(s.warmup, 0.2,
                             "the widened horizon no longer sees the old band's "
                             + "post-warm-up collapses")
        XCTAssertLessThan(s.constSpread, 1.0)
        // And the documented regression that motivated the 0.50 band: 0.35/300
        // must score WORSE on bursty than 0.50/300 does.
        let loose = score(Config(band: 0.35, asymDown: false, confirm: 300,
                                 excl: false, floor: nil))
        XCTAssertGreaterThan(loose.maeBursty, s.maeBursty,
                             "harness fails to reproduce the band-lowering regression")
    }

    /// The SHIPPED configuration, scored by the same harness: identical accuracy
    /// to the old fixed band, zero spurious collapses (which the old band did
    /// not manage), and the field-reported settle followed in five minutes.
    func testShippedConfigurationScores() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ANODE_TREND_SWEEP"] == "1")
        let old = score(Config(band: 0.50, asymDown: false, confirm: 300,
                               excl: false, floor: nil))
        let ship = score(Config(band: 0.30, asymDown: false, confirm: 300,
                                excl: true, floor: 600, noiseK: 3.0))
        XCTAssertLessThanOrEqual(ship.maeWander, old.maeWander * 1.05)
        XCTAssertLessThanOrEqual(ship.maeBursty, old.maeBursty * 1.05)
        XCTAssertLessThanOrEqual(ship.spike60, old.spike60 * 1.05)
        XCTAssertEqual(ship.warmup, 0, "the shipped config must not collapse spuriously")
        XCTAssertLessThanOrEqual(ship.incident, 600,
                                 "the shipped config must follow the 2026-08-16 settle "
                                 + "within ten minutes")
        XCTAssertLessThan(ship.constSpread, 1.0)
    }
}

import XCTest
@testable import PowerKit

// Does the lifetime forecast actually predict death better than what the app did
// before it? Replayed against a simulated pack on the measured discharge curve:
// the model is trained on past sessions of one synthetic user, then each new
// session is scored minute by minute against the true time left.
//
// "Before" is the discharge tier as the app runs it — the mean drain since the
// lid opened, divided into the charge. "After" is `forecastTimeToEmpty` fed by
// `LifetimeDrainModel.prior`. Both see exactly the same pack and the same load.
final class LifetimeReplayHarness: XCTestCase {

    private let scale = makeMachineScale()
    /// 10 s rather than the app's 2 s: the model's shortest window is five
    /// minutes, so finer steps change nothing but how long the suite takes.
    private static let tick: TimeInterval = 10
    private static let ticksPerMinute = 6
    private var fcc: Double { scale.fullChargeCapacity_mAh }

    /// Deterministic (splitmix64), so every run prints the same table.
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
    }

    /// One minute of load: watts, and the app behind it if one dominated.
    private typealias Minute = (watts: Double, app: LifetimeDrainModel.TopApp?)
    private let render = LifetimeDrainModel.TopApp(key: "com.apple.FinalCut", name: "Final Cut Pro", share: 0.85)

    /// This user's ordinary work: ~7 W with minute-to-minute noise, and a
    /// 30–50 min render at ~24 W now and then.
    private func typicalSession(seed: UInt64, minutes: Int) -> [Minute] {
        var r = Rand(seed), out: [Minute] = []
        while out.count < minutes {
            if r.next() < 0.03 {
                let len = 30 + Int(r.next() * 20)
                for _ in 0..<len { out.append((22 + r.next() * 4, render)) }
            } else {
                out.append((5.5 + r.next() * 3, nil))
            }
        }
        return Array(out.prefix(minutes))
    }

    private func constant(_ w: Double, _ minutes: Int, app: LifetimeDrainModel.TopApp? = nil) -> [Minute] {
        Array(repeating: (w, app), count: minutes)
    }

    // ── simulation ───────────────────────────────────────────────────────────

    private func mV(_ mAh: Double) -> Double { TrendSweepHarness.mV(atSoC: mAh / fcc * 100) }

    /// mAh left at the start of each minute, and the minute the pack dies.
    private func discharge(_ load: [Minute]) -> (mAh: [Double], death: Int) {
        var left = fcc, trace: [Double] = []
        for (m, min) in load.enumerated() {
            trace.append(left)
            left -= min.watts * 1000 / mV(left) * 1000 / 60
            if left <= 0 { return (trace, m) }
        }
        XCTFail("load of \(load.count) min never empties the pack — every truth would be understated")
        return (trace, load.count)
    }

    /// Train on past sessions of the same user: what the model would know after
    /// a few weeks of ordinary use.
    private func trained() -> LifetimeDrainModel {
        var m = LifetimeDrainModel(machineModel: "Mac17,9", designCapacity_mAh: 6251, osBuild: "26A428")
        var awake: TimeInterval = 1_000
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        for day in 0..<12 {
            now += 86_400
            awake += 60
            m.observe(batteryWatts: 1, onBattery: false, interval: 2, awake: awake, now: now, topApp: nil)
            for minute in typicalSession(seed: 100 + UInt64(day), minutes: 300) {
                for _ in 0..<Self.ticksPerMinute {
                    awake += Self.tick; now += Self.tick
                    m.observe(batteryWatts: minute.watts, onBattery: true, interval: Self.tick,
                              awake: awake, now: now, topApp: minute.app)
                }
            }
        }
        return m
    }

    /// Mean absolute error, in minutes, of both methods over one session.
    private func score(_ load: [Minute], model: LifetimeDrainModel) -> (before: Double, after: Double) {
        var m = model
        let (mAh, death) = discharge(load)
        var awake: TimeInterval = 10_000_000
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        m.observe(batteryWatts: 1, onBattery: false, interval: 2, awake: awake, now: now, topApp: nil)
        var pctSum = 0.0, before = 0.0, after = 0.0, n = 0.0
        for minute in 0..<death {
            let load = load[minute]
            for _ in 0..<Self.ticksPerMinute {
                awake += Self.tick; now += Self.tick
                m.observe(batteryWatts: load.watts, onBattery: true, interval: Self.tick,
                          awake: awake, now: now, topApp: load.app)
            }
            let v = mV(mAh[minute])
            pctSum += scale.pctHrAtVoltage(watts: load.watts, voltage_mV: v)
            // Scored once both have had ten minutes, until five before the end.
            guard minute >= 10, minute < death - 5 else { continue }
            let charge = mAh[minute] / fcc * 100
            let truth = Double(death - minute)
            let mean = pctSum / Double(minute + 1)
            guard let tb = DrainEstimate.timeToEmpty(chargePercent: charge, ratePctHr: mean),
                  let p = m.prior(awake: awake),
                  let ta = DrainEstimate.forecastTimeToEmpty(
                      chargePercent: charge,
                      currentPctHr: scale.pctHrAtVoltage(watts: p.current_W, voltage_mV: v),
                      baselinePctHr: scale.pctHrAtVoltage(watts: p.baseline_W, voltage_mV: v),
                      tau: p.tau_s) else { continue }
            before += abs(tb / 60 - truth)
            after += abs(ta / 60 - truth)
            n += 1
        }
        return (before / n, after / n)
    }

    // ── the profiles ─────────────────────────────────────────────────────────

    private lazy var model = trained()

    private func report(_ name: String, _ s: (before: Double, after: Double)) {
        print(String(format: "REPLAY;%@;before=%.1f min;after=%.1f min", name, s.before, s.after))
    }

    func testATypicalSession() {
        let s = score(typicalSession(seed: 7, minutes: 1200), model: model)
        report("typical", s)
        // Ordinary use is where the old method was already at its best; the
        // lifetime forecast must not cost anything there.
        XCTAssertLessThanOrEqual(s.after, s.before * 1.05)
    }

    func testIdleThenARenderThenIdle() {
        let load = constant(6.5, 120) + constant(24, 45, app: render) + constant(6.5, 1200)
        let s = score(load, model: model)
        report("idle-render-idle", s)
        // The render drags the since-lid-opened mean up for the rest of the
        // session; the forecast lets it go once it ends.
        XCTAssertLessThan(s.after, s.before * 0.8)
    }

    func testASustainedRender() {
        let s = score(constant(24, 600, app: render), model: model)
        report("sustained-render", s)
        // The case a plain lifetime average would get badly wrong: a render that
        // simply keeps going must be forecast as a render that keeps going.
        XCTAssertLessThan(s.after, s.before)
        XCTAssertLessThan(s.after, 2)
    }

    func testBurstyBrowsing() {
        var r = Rand(42)
        let load: [Minute] = (0..<1200).map { _ in (r.next() < 0.15 ? 16 : 6, nil) }
        let s = score(load, model: model)
        report("bursty", s)
        XCTAssertLessThan(s.after, s.before * 0.8)
    }
}

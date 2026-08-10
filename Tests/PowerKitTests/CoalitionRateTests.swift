import XCTest
@testable import PowerKit

/// The apportionment WEIGHT: a rate, not an hour.
///
/// The bucket being divided is measured right now. Dividing it by each
/// coalition's CPU time over the trailing hour put 52.0 % of it on the wrong
/// process (total variation distance, n = 28, share-normalised against the
/// processes rusage can read so any level bias cancels), agreed with truth within
/// 2x only half the time, spread 217-fold, and — the part a user actually sees —
/// named the wrong top row: the real leader took 53.8 % of the bucket and was
/// handed 14.4 %, while a coalition genuinely using 1.4 % was crowned at 14.1x.
///
/// Everything here is synthetic records fed straight to the rollup, so nothing
/// depends on what this machine's sysmond store happens to hold.
final class CoalitionRateTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private var windowStart: Date { t0.addingTimeInterval(-3600) }

    /// One record. `cpu`/`gpu` are CUMULATIVE, as the store writes them.
    private func rec(_ bundle: String, cid: Int, at: TimeInterval,
                     cpu: UInt64, gpu: UInt64 = 0, energy: Double = 1,
                     runtime: UInt64 = 100_000) -> SystemStats.Raw {
        SystemStats.Raw(
            sample: CoalitionSample(timestamp: t0.addingTimeInterval(at), cid: cid,
                                    cpu_ms: cpu, gpu_ms: gpu, energyScore: energy,
                                    bundleID: bundle, displayName: nil,
                                    pkgIdleWkups: 0, interruptWkups: 0,
                                    diskReadBytes: 0, diskWriteBytes: 0),
            runtime_s: runtime)
    }

    private func rate(_ rows: [CoalitionUsage], _ id: String) -> Double {
        rows.first { $0.bundleID == id }?.cpuRate_msPerS ?? 0
    }

    // ── The rate itself ─────────────────────────────────────────────────────

    /// The reported failure, in its exact shape. `busyAnHourAgo` burned 900 s of
    /// CPU early and has been idle since; `busyNow` burned 60 s of it in the last
    /// two minutes. The hour totals say the first is 15x the second. The rates say
    /// the opposite, and the rates are what the current watts are divided by.
    func testTheWeightIsTheRecentRateAndNotTheHourTotal() {
        let raws = [
            // 900 s of CPU in the first minutes of the window, then flat.
            rec("busyAnHourAgo", cid: 1, at: -3500, cpu: 0),
            rec("busyAnHourAgo", cid: 1, at: -3400, cpu: 900_000),
            rec("busyAnHourAgo", cid: 1, at: -120, cpu: 900_000),
            rec("busyAnHourAgo", cid: 1, at: 0, cpu: 900_000),
            // 60 s of CPU inside the last two minutes.
            rec("busyNow", cid: 2, at: -3500, cpu: 0),
            rec("busyNow", cid: 2, at: -120, cpu: 0),
            rec("busyNow", cid: 2, at: 0, cpu: 60_000),
        ]
        let rows = SystemStats.rollup(raws, since: windowStart)

        // The hour totals, which is what the defect divided by.
        let hourly = Dictionary(uniqueKeysWithValues: rows.map { ($0.bundleID, $0.cpu_ms) })
        XCTAssertEqual(hourly["busyAnHourAgo"], 900_000)
        XCTAssertEqual(hourly["busyNow"], 60_000)

        // The rates, which is what it divides by now: 0 ms/s against 500 ms/s.
        XCTAssertEqual(rate(rows, "busyAnHourAgo"), 0, accuracy: 1e-9)
        XCTAssertEqual(rate(rows, "busyNow"), 60_000.0 / 120, accuracy: 1e-9)
    }

    /// A rate is over the last two records, not over the window: two coalitions
    /// with identical hour totals but different recent activity must separate.
    func testTwoCoalitionsWithTheSameHourSeparateOnTheirRates() {
        let raws = [
            rec("steady", cid: 1, at: -3600, cpu: 0),
            rec("steady", cid: 1, at: -1800, cpu: 300_000),
            rec("steady", cid: 1, at: -100, cpu: 600_000),
            rec("steady", cid: 1, at: 0, cpu: 600_000 + 16_667),
            rec("spiking", cid: 2, at: -3600, cpu: 0),
            rec("spiking", cid: 2, at: -1800, cpu: 0),
            rec("spiking", cid: 2, at: -100, cpu: 516_667),
            rec("spiking", cid: 2, at: 0, cpu: 616_667),
        ]
        let rows = SystemStats.rollup(raws, since: windowStart)
        XCTAssertEqual(rows.first { $0.bundleID == "steady" }?.cpu_ms,
                       rows.first { $0.bundleID == "spiking" }?.cpu_ms,
                       "the fixture must make the hour totals identical")
        XCTAssertEqual(rate(rows, "steady"), 16_667.0 / 100, accuracy: 1e-6)
        XCTAssertEqual(rate(rows, "spiking"), 100_000.0 / 100, accuracy: 1e-6)
    }

    /// A birth is an observation of the counter at zero, so a coalition that has
    /// only ever emitted once still has a rate — otherwise a process spawned
    /// thirty seconds ago and pinning a core would be invisible.
    func testACoalitionBornInsideTheWindowHasARateFromItsFirstRecord() {
        let raws = [rec("newborn", cid: 9, at: 0, cpu: 20_000, runtime: 40)]
        let rows = SystemStats.rollup(raws, since: windowStart)
        XCTAssertEqual(rate(rows, "newborn"), 20_000.0 / 40, accuracy: 1e-9)
    }

    /// The honest nil. A single record from a coalition that predates the window
    /// is a LEVEL, not a rate: there is no earlier observation to difference it
    /// against, and the quantity being divided is a rate. It has no window total
    /// either — the pre-existing rule already refuses to credit a slice it did not
    /// observe — so it is not a row at all rather than a row of zeroes.
    func testASingleRecordOlderThanTheWindowYieldsNoRate() {
        let raws = [rec("ancient", cid: 7, at: -1800, cpu: 500_000, runtime: 100_000)]
        XCTAssertTrue(SystemStats.rollup(raws, since: windowStart).isEmpty)
    }

    /// The other half of that rule, and the one that matters for the defect: a
    /// coalition that DID work inside the window but has done none of it lately
    /// keeps its window total — the history is real and still reportable — while
    /// its weight goes to zero. It stays in the list, so the coverage gate that
    /// decides whether the rollup saw enough of the machine still counts it.
    func testAnIdleCoalitionKeepsItsHistoryButLosesItsWeight() {
        let raws = [
            rec("wasBusy", cid: 3, at: -3000, cpu: 0),
            rec("wasBusy", cid: 3, at: -2900, cpu: 400_000),
            rec("wasBusy", cid: 3, at: 0, cpu: 400_000),
        ]
        let rows = SystemStats.rollup(raws, since: windowStart)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].cpu_ms, 400_000, "the hour is still reported")
        XCTAssertEqual(rows[0].cpuRate_msPerS, 0, "…and takes none of the current watts")
    }

    /// cids are reused across a reboot, and only the runtime field exposes it.
    /// A reborn coalition's cumulative values are its whole life, so its rate is
    /// over that life — not a difference against the previous tenant of the cid,
    /// which would be an arbitrary number.
    func testARebornCidRatesFromItsOwnLifeAndNotAgainstThePreviousTenant() {
        let raws = [
            rec("previousTenant", cid: 4, at: -600, cpu: 5_000_000, runtime: 100_000),
            rec("newTenant", cid: 4, at: 0, cpu: 30_000, runtime: 60),
        ]
        let rows = SystemStats.rollup(raws, since: windowStart)
        XCTAssertEqual(rate(rows, "newTenant"), 30_000.0 / 60, accuracy: 1e-9)
    }

    /// Several coalitions roll up to one bundle id, and an app whose helpers each
    /// burn a core is using both of them.
    func testRatesSumAcrossTheCoalitionsOfOneApp() {
        let raws = [
            rec("app", cid: 1, at: -100, cpu: 0),
            rec("app", cid: 1, at: 0, cpu: 10_000),
            rec("app", cid: 2, at: -100, cpu: 0),
            rec("app", cid: 2, at: 0, cpu: 20_000),
        ]
        let rows = SystemStats.rollup(raws, since: windowStart)
        XCTAssertEqual(rate(rows, "app"), 30_000.0 / 100, accuracy: 1e-9)
    }

    /// GPU is weighted by its own counter, on the same basis.
    func testTheGPURateIsSeparateFromTheCPURate() {
        let raws = [
            rec("gpuOnly", cid: 1, at: -100, cpu: 5_000, gpu: 0),
            rec("gpuOnly", cid: 1, at: 0, cpu: 5_000, gpu: 40_000),
        ]
        let rows = SystemStats.rollup(raws, since: windowStart)
        XCTAssertEqual(rows[0].cpuRate_msPerS, 0, accuracy: 1e-9)
        XCTAssertEqual(rows[0].gpuRate_msPerS, 400, accuracy: 1e-9)
    }

    /// A counter that went backwards to near zero is a reboot, not negative work.
    /// The reset rule that guards the window totals has to guard the rate too, or
    /// one boot boundary hands a coalition the whole of its post-boot cumulative
    /// counter as a per-second rate.
    func testACounterResetDoesNotBecomeAnEnormousRate() {
        let raws = [
            rec("rebooted", cid: 1, at: -100, cpu: 7_843_261),
            rec("rebooted", cid: 1, at: 0, cpu: 3_026, runtime: 100_000),
        ]
        let rows = SystemStats.rollup(raws, since: windowStart)
        XCTAssertEqual(rate(rows, "rebooted"), 3_026.0 / 100, accuracy: 1e-6,
                       "a reset credits the current value, not the whole counter")
    }
}

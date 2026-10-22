import XCTest
@testable import PowerKit

// Anode Stats is arithmetic over kernel counters and a ledger the tick feeds.
// None of it needs a window, so none of it is tested through one.

final class SelfUsageRateTests: XCTestCase {

    private func sample(uptime: UInt64, cpu: UInt64 = 0, energy: UInt64 = 0,
                        wakeups: UInt64 = 0, read: UInt64 = 0, gpu: UInt64? = nil,
                        launched: UInt64 = 0) -> SelfUsage.Sample {
        .init(uptime_ns: uptime, cpu_ns: cpu, energy_nJ: energy, footprint: 0,
              peakFootprint: 0, idleWakeups: wakeups, interruptWakeups: 0,
              diskRead: read, diskWritten: 0, instructions: 0, cycles: 0,
              gpu_ns: gpu, threads: nil, launchedAt_ns: launched)
    }

    func testRatesDivideByElapsedAwakeTime() throws {
        let a = sample(uptime: 10_000_000_000, gpu: 0)
        let b = sample(uptime: 12_000_000_000, cpu: 40_000_000, energy: 3_000_000,
                       wakeups: 50, read: 4_000, gpu: 20_000_000)
        let r = try XCTUnwrap(SelfUsage.rates(from: a, to: b))
        XCTAssertEqual(r.cpuPercent, 2.0, accuracy: 1e-9)       // 40 ms over 2 s
        XCTAssertEqual(r.watts, 0.0015, accuracy: 1e-12)        // 3 mJ over 2 s
        XCTAssertEqual(r.wakeupsPerSecond, 25, accuracy: 1e-9)
        XCTAssertEqual(r.diskReadBytesPerSecond, 2_000, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(r.gpuPercent), 1.0, accuracy: 1e-9)
    }

    /// A counter running backwards is the process having un-run. It is a
    /// measurement problem, and a rate made from it would be an invented one.
    func testBackwardsOrZeroSpanIsNoRate() {
        let a = sample(uptime: 5_000_000_000, cpu: 100, energy: 100)
        XCTAssertNil(SelfUsage.rates(from: a, to: sample(uptime: 6_000_000_000, cpu: 50, energy: 100)))
        XCTAssertNil(SelfUsage.rates(from: a, to: sample(uptime: 6_000_000_000, cpu: 100, energy: 50)))
        XCTAssertNil(SelfUsage.rates(from: a, to: sample(uptime: 5_000_000_000, cpu: 100, energy: 100)))
    }

    /// Absent is not zero: no GPU reading on either end means no GPU rate.
    func testMissingGPUIsNilNotZero() throws {
        let a = sample(uptime: 1_000_000_000, gpu: nil)
        let b = sample(uptime: 2_000_000_000, gpu: 5)
        XCTAssertNil(try XCTUnwrap(SelfUsage.rates(from: a, to: b)).gpuPercent)
    }

    func testLifetimeRatesUseTheProcessesOwnLife() throws {
        // Launched at 100 s of awake time, sampled at 200 s: a 100 s life.
        let s = sample(uptime: 200_000_000_000, cpu: 500_000_000, energy: 2_000_000_000,
                       launched: 100_000_000_000)
        let r = try XCTUnwrap(SelfUsage.lifetimeRates(s))
        XCTAssertEqual(r.cpuPercent, 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.watts, 0.02, accuracy: 1e-12)
    }

    func testLifetimeRatesRefuseASubSecondLife() {
        XCTAssertNil(SelfUsage.lifetimeRates(
            sample(uptime: 100_500_000_000, launched: 100_000_000_000)))
    }

    /// The live read must come back with a plausible shape for THIS process —
    /// the one place the kernel is actually asked.
    func testReadingThisProcessIsPlausible() throws {
        var burn = 0.0
        for i in 0..<2_000_000 { burn += sin(Double(i)) }   // some CPU to count
        XCTAssertNotEqual(burn, 1)
        let s = try XCTUnwrap(SelfUsage.read(gpu: nil))
        XCTAssertGreaterThan(s.cpu_ns, 1_000_000)
        XCTAssertGreaterThan(s.footprint, 1_000_000)
        XCTAssertGreaterThan(s.uptime_ns, s.launchedAt_ns)
        XCTAssertLessThan(s.uptime_ns - s.launchedAt_ns, 3_600_000_000_000, "a test run is not an hour old")
        XCTAssertGreaterThan(try XCTUnwrap(s.threads), 0)
    }
}

final class SelfGPUTests: XCTestCase {

    func testSumsAccumulatedTimeAcrossClients() {
        let usage: [[String: Any]] = [
            ["API": "Metal", "lastSubmittedTime": 9, "accumulatedGPUTime": 1_500],
            ["API": "Metal", "lastSubmittedTime": 0, "accumulatedGPUTime": 0],
            ["API": "Metal", "accumulatedGPUTime": 2_500],
        ]
        XCTAssertEqual(SelfGPU.gpuNanoseconds(inAppUsage: usage), 4_000)
    }

    func testAnUnexpectedShapeIsZeroNotACrash() {
        XCTAssertEqual(SelfGPU.gpuNanoseconds(inAppUsage: "nope"), 0)
        XCTAssertEqual(SelfGPU.gpuNanoseconds(inAppUsage: [[String: Any]]()), 0)
        XCTAssertEqual(SelfGPU.gpuNanoseconds(inAppUsage: [["API": "Metal"]]), 0)
    }

    /// pid 683 must not claim pid 6830's client.
    func testCreatorMatchesTheWholePID() {
        XCTAssertTrue(SelfGPU.creator("pid 683, AnodeApp", isPID: 683))
        XCTAssertFalse(SelfGPU.creator("pid 6830, Other", isPID: 683))
        XCTAssertFalse(SelfGPU.creator("pid 68, Other", isPID: 683))
    }
}

final class TickLedgerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func record(_ l: TickLedger, _ kind: TickLedger.Kind, at offset: TimeInterval,
                        cpu: UInt64 = 1_000_000, wall: UInt64 = 5_000_000,
                        machine_W: Double? = nil) {
        l.record(kind: kind, startedAt: t0.addingTimeInterval(offset), cpu_ns: cpu, wall_ns: wall,
                 machine_W: machine_W, joulesPerPercent: nil)
    }

    func testCountsAndMeansPerKind() throws {
        let l = TickLedger()
        record(l, .light, at: 0, cpu: 1_000_000)
        record(l, .light, at: 8, cpu: 3_000_000)
        record(l, .full, at: 16, cpu: 10_000_000)
        let s = l.summary()
        XCTAssertEqual(s.light.count, 2)
        XCTAssertEqual(s.full.count, 1)
        XCTAssertEqual(s.totalTicks, 3)
        XCTAssertEqual(try XCTUnwrap(s.light.meanCPU_ms), 2.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(s.full.meanCPU_ms), 10.0, accuracy: 1e-9)
        XCTAssertEqual(s.full.lastCPU_ns, 10_000_000)
        XCTAssertEqual(s.lastFullAt, t0.addingTimeInterval(16))
    }

    func testAKindWithNoTicksHasNoMeanRatherThanZero() {
        XCTAssertNil(TickLedger().summary().full.meanCPU_ms)
    }

    func testGapsAreStartToStartAndBounded() throws {
        let l = TickLedger()
        for i in 0..<(TickLedger.gapWindow + 10) {
            record(l, .light, at: Double(i) * 2)
        }
        let gaps = l.summary().recentGaps
        XCTAssertEqual(gaps.count, TickLedger.gapWindow)
        XCTAssertTrue(gaps.allSatisfy { $0 == 2 })
        let g = try XCTUnwrap(TickLedger.gapStats([1, 2, 6]))
        XCTAssertEqual(g.mean, 3, accuracy: 1e-9)
        XCTAssertEqual(g.min, 1)
        XCTAssertEqual(g.max, 6)
        XCTAssertNil(TickLedger.gapStats([]))
    }

    /// A light tick carries no pack figure. It must not erase the last one.
    func testALaterTickWithoutAReadingKeepsTheLastReading() {
        let l = TickLedger()
        record(l, .full, at: 0, machine_W: 7.5)
        record(l, .light, at: 8, machine_W: nil)
        XCTAssertEqual(l.summary().machine_W, 7.5)
    }

    func testMainThreadHalfIsTalliedSeparately() {
        let l = TickLedger()
        l.recordMain(cpu_ns: 2_000_000)
        l.recordMain(cpu_ns: 4_000_000)
        let s = l.summary()
        XCTAssertEqual(s.main.count, 2)
        XCTAssertEqual(s.main.meanCPU_ms ?? 0, 3.0, accuracy: 1e-9)
        XCTAssertEqual(s.totalTicks, 0, "the main half is not a tick of its own")
    }
}

final class TickModeWordingTests: XCTestCase {

    private func mode(effective: TimeInterval = 2, setting: TimeInterval = 2,
                      visible: Bool = false, panel: Bool = false, fans: Bool = false,
                      logging: Bool = true) -> TickLedger.Mode {
        .init(effectiveInterval: effective, settingInterval: setting, windowVisible: visible,
              panelOpen: panel, drivingFans: fans, historyLogging: logging,
              backgroundFullInterval: 60)
    }

    func testHiddenSaysTheFloorOverrodeTheSetting() {
        let m = mode(effective: 8, visible: false)
        XCTAssertEqual(m.headline, "Window hidden")
        XCTAssertTrue(m.reason.contains("8 s"))
        XCTAssertTrue(m.reason.contains("2 s"))
    }

    func testVisibleFollowsTheSetting() {
        let m = mode(visible: true)
        XCTAssertEqual(m.headline, "Window on screen")
        XCTAssertEqual(m.reason, "your setting of 2 s")
    }

    func testAHeldFanOutranksTheRest() {
        XCTAssertEqual(mode(effective: 1, visible: true, panel: true, fans: true).headline,
                       "Holding a fan")
    }

    func testFullTickPolicyFollowsWhoIsReading() {
        XCTAssertTrue(mode(visible: true).fullTickPolicy.hasPrefix("every tick"))
        XCTAssertTrue(mode(logging: true).fullTickPolicy.contains("minute"))
        XCTAssertTrue(mode(logging: false).fullTickPolicy.contains("logging is off"))
    }
}

final class BuildInfoTests: XCTestCase {

    func testReadsTheKeysBuildAppWrites() {
        let b = BuildInfo(info: ["CFBundleShortVersionString": "1.2", "CFBundleVersion": "34",
                                 "BSSourceCommit": "abc1234", "BSSourcePath": "/src/anode"])
        XCTAssertEqual(b.version, "1.2")
        XCTAssertEqual(b.build, "34")
        XCTAssertEqual(b.commit, "abc1234")
        XCTAssertFalse(b.isModified)
        XCTAssertEqual(b.sourcePath, "/src/anode")
        XCTAssertEqual(b.summary, "1.2 (build 34) · abc1234")
    }

    func testTheDirtyMarkerIsSplitOffTheHash() {
        let b = BuildInfo(info: ["BSSourceCommit": "abc1234+"])
        XCTAssertEqual(b.commit, "abc1234")
        XCTAssertTrue(b.isModified)
        XCTAssertTrue(b.summary.hasSuffix("abc1234+"))
    }

    /// `swift run` has no Info.plist, and "unknown" is what the script writes
    /// when git could not be read. Neither is a commit.
    func testAbsentAndUnknownAreNotCommits() {
        XCTAssertNil(BuildInfo(info: nil).commit)
        XCTAssertNil(BuildInfo(info: ["BSSourceCommit": "unknown"]).commit)
        XCTAssertNil(BuildInfo(info: ["BSSourcePath": ""]).sourcePath)
        XCTAssertEqual(BuildInfo(info: nil).summary, "? (build ?) · unknown")
    }
}

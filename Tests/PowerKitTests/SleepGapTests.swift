import XCTest
import SQLite3
@testable import PowerKit

/// Sleep is not a long sample.
///
/// The app had no handling for it at all. A nine-hour sleep produced ONE interval
/// of ~32,400 s, and `selectWindowLocked` walks newest-first, so that single row
/// filled the entire 10 hr window by itself and every figure drawn from the window
/// became a reading of the sleep.
///
/// The fix drops the straddling interval rather than clamping it. A clamp writes a
/// row asserting the machine drew its pre-sleep watts for seconds it spent asleep,
/// which is fabricated energy in a store whose premise is that measured joules add
/// exactly.
final class SleepGapDetectionTests: XCTestCase {

    /// The case from the bug report.
    func testANineHourSleepIsAGapNotALongSample() {
        XCTAssertTrue(PowerMonitor.straddlesGap(wall: 32_400, awake: 2.1))
    }

    /// A nap shorter than the interval limit is invisible to a duration check and
    /// is caught only because the awake clock stood still through it. This is the
    /// case a `interval > 120` test alone would let through — three minutes of
    /// pre-sleep watts, recorded as measurement.
    func testASleepShorterThanTheIntervalLimitIsStillCaught() {
        XCTAssertTrue(PowerMonitor.straddlesGap(wall: 180, awake: 2))
    }

    /// Both clocks ran, so nothing slept — but ten minutes is far past any tick
    /// cadence, so nothing was sampling either.
    func testASuspendedProcessIsAGapEvenThoughNothingSlept() {
        XCTAssertTrue(PowerMonitor.straddlesGap(wall: 600, awake: 600))
    }

    /// Every cadence the app actually runs at, plus the worst legitimate case:
    /// an 8 s hidden tick that also crosses the 60 s forced-full-sweep mark.
    func testOrdinaryTicksAreNotGaps() {
        for dt in [0.0, 1.0, 2.0, 8.0, 30.0, 68.0] {
            XCTAssertFalse(PowerMonitor.straddlesGap(wall: dt, awake: dt),
                           "\(dt) s is a normal tick interval")
        }
        // The two clocks are read milliseconds apart and NTP can step the wall
        // clock; neither may be mistaken for a sleep.
        XCTAssertFalse(PowerMonitor.straddlesGap(wall: 2.0, awake: 1.9))
    }

    /// Guards the units. `clock_gettime_nsec_np` returns NANOseconds, and a missed
    /// conversion would make awake elapsed ~1e9x the wall elapsed — after which
    /// `wall - awake` is hugely negative and NO gap is ever detected again, quietly.
    func testTheAwakeClockIsSecondsAndTracksTheWallClockWhileAwake() {
        let wall0 = Date()
        let awake0 = PowerMonitor.awakeSeconds()
        Thread.sleep(forTimeInterval: 0.2)
        let wall = Date().timeIntervalSince(wall0)
        let awake = PowerMonitor.awakeSeconds() - awake0
        XCTAssertEqual(awake, wall, accuracy: 0.05,
                       "the two clocks must agree while the machine is awake")
        XCTAssertFalse(PowerMonitor.straddlesGap(wall: wall, awake: awake))
    }

    /// The reset is the half of the fix that stops the FIRST post-wake tick from
    /// being a reading of the sleep. Asserting the whole `Accumulators` value, not
    /// a chosen few fields, is deliberate: the original fix reset two of these and
    /// left the rest — `lastPublished` above all — carrying pre-sleep state.
    func testResetAcrossAGapClearsEveryAccumulator() throws {
        guard let m = PowerMonitor(scale: makeExactScale()) else {
            throw XCTSkip("no battery scale on this machine")
        }
        // Two full ticks. The first only seeds `lastSweep` — there is no window to
        // diff against yet — so the second is the one that populates the tracker.
        m.tick(full: true, attribution: false)
        Thread.sleep(forTimeInterval: 0.2)
        m.tick(full: true, attribution: false)

        let before = m.accumulators
        // Only the accumulators that need no optional hardware are asserted to be
        // populated: SMC and the gas gauge may be absent, and this test is about
        // the reset rather than about what this particular Mac exposes.
        XCTAssertGreaterThan(before.trackedProcesses, 0)
        XCTAssertNotNil(before.smoothed)
        XCTAssertTrue(before.hasLastSweep)
        XCTAssertTrue(before.hasLastLightTick)

        m.resetAcrossGap()
        XCTAssertEqual(m.accumulators, PowerMonitor.Accumulators(),
                       "an accumulator survived the gap and will poison the wake")
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// The store's half: reject a gap on the way in, and ignore the ones already on
/// disk on the way out. Both are needed — every existing user's store holds rows
/// written before the sampler learned to drop them, and a write-side guard alone
/// would change nothing for any of them.
final class SleepGapStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bs-sleepgap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private var url: URL { dir.appendingPathComponent("history.sqlite") }

    private func realApp() -> AppDrain {
        AppDrain(identity: AppIdentity(name: "Real", bundleID: "com.real", isApp: true),
                 joules: 4, over: 2)
    }

    /// Writes the row an older build left behind, straight past `record` — which is
    /// the only way to get one now, and exactly how the ones on disk got there.
    private func seedSleepRow(ts: Double, dur: Double, watts: Double, app: String) {
        var h: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &h), SQLITE_OK)
        defer { sqlite3_close(h) }
        let j = watts * dur
        XCTAssertEqual(sqlite3_exec(h, """
            INSERT INTO interval(ts, dur, on_battery, agg, measured_j, attributed_j, residual_j, soc)
                VALUES(\(ts), \(dur), 1, 0, \(j), 0, \(j), 50);
            INSERT INTO app_energy(interval_id, app, name, joules)
                VALUES(last_insert_rowid(), '\(app)', '\(app)', \(j));
            """, nil, nil, nil), SQLITE_OK)
    }

    /// Nine hours of sleep must leave no row at all. Absence is the truth about a
    /// window nothing measured.
    func testASampleStraddlingASleepIsNeverStored() {
        guard let s = HistoryStore(path: url) else { return XCTFail("store") }
        s.record(apps: [realApp()], measured_W: 5, attributed_W: 2, residual_W: 3,
                 onBattery: true, socPercent: 50, interval: 32_400, at: Date())
        XCTAssertEqual(s.stats().intervals, 0)
        XCTAssertEqual(s.stats().appRows, 0, "the app rows must not survive either")

        // Control: the identical call with a real interval does land, so the guard
        // is rejecting the duration and not the row.
        s.record(apps: [realApp()], measured_W: 5, attributed_W: 2, residual_W: 3,
                 onBattery: true, socPercent: 50, interval: 2, at: Date())
        XCTAssertEqual(s.stats().intervals, 1)
    }

    /// The sampler signals a dropped gap by handing `record` an interval of 0. That
    /// contract is what lets the monitor stay honest without a second code path.
    func testAZeroIntervalWritesNothing() {
        guard let s = HistoryStore(path: url) else { return XCTFail("store") }
        s.record(apps: [realApp()], measured_W: 5, attributed_W: 2, residual_W: 3,
                 onBattery: true, socPercent: 50, interval: 0, at: Date())
        XCTAssertEqual(s.stats().intervals, 0)
    }

    /// The read-side filter, against a store that already holds the poison. Ten
    /// seconds of real samples and one nine-hour row: without the filter the walk
    /// takes the sleep first, reports the window as full, and never reaches a
    /// single real sample.
    func testAStoredSleepRowIsExcludedFromTheWindow() {
        guard let s = HistoryStore(path: url) else { return XCTFail("store") }
        let t0 = Date()
        for i in 0..<5 {
            s.record(apps: [realApp()], measured_W: 5, attributed_W: 2, residual_W: 3,
                     onBattery: true, socPercent: 80, interval: 2,
                     at: t0.addingTimeInterval(Double(i) * 2 - 10))
        }
        // Newest, which is where waking up actually puts it.
        seedSleepRow(ts: t0.timeIntervalSince1970, dur: 32_400, watts: 40, app: "com.sleeper")

        XCTAssertEqual(s.onBatterySeconds(hours: 10), 10, accuracy: 1e-9,
                       "the window holds ten seconds of samples, not ten hours of sleep")
        let rows = s.windowPower(hours: 10, joulesPerPercent: 3600)
        XCTAssertEqual(rows.map(\.name), ["Real"], "the sleep must claim no app energy")
        XCTAssertEqual(rows.first?.joules ?? 0, 20, accuracy: 1e-9)
        XCTAssertEqual(s.windowTotals(hours: 10).measured_J ?? 0, 50, accuracy: 1e-9)
    }

    /// The graph reads its own query, so it needs its own filter. 40 W over the
    /// sleep is a plausible-looking wattage — the existing `measured_j / dur <= 200`
    /// guard passes it happily, and only the duration gives it away.
    func testAStoredSleepRowIsExcludedFromTheGraph() {
        guard let s = HistoryStore(path: url) else { return XCTFail("store") }
        let t0 = Date()
        for i in 0..<5 {
            s.record(apps: [], measured_W: 5, attributed_W: nil, residual_W: nil,
                     onBattery: true, socPercent: 80, interval: 2,
                     at: t0.addingTimeInterval(Double(i) * 2 - 10))
        }
        seedSleepRow(ts: t0.timeIntervalSince1970, dur: 32_400, watts: 40, app: "com.sleeper")

        let pts = s.powerSeries(since: t0.addingTimeInterval(-60),
                                until: t0.addingTimeInterval(60), maxPoints: 600)
        XCTAssertEqual(pts.count, 5)
        for p in pts {
            XCTAssertEqual(p.watts, 5, accuracy: 1e-9, "a sleep row reached the graph")
        }
    }

    /// Compaction must not launder the poison into a bucket. Folding a 32,400 s row
    /// into its minute would push that bucket past the read filter and take the
    /// minute's genuine samples out of the window along with it.
    func testCompactionDropsASleepRowInsteadOfFoldingIt() {
        guard let s = HistoryStore(path: url, rawHorizon: 1, bucketWidth: 60) else {
            return XCTFail("store")
        }
        let t0 = Date().addingTimeInterval(-7200)
        for i in 0..<5 {
            s.record(apps: [realApp()], measured_W: 5, attributed_W: 2, residual_W: 3,
                     onBattery: true, socPercent: 80, interval: 2,
                     at: t0.addingTimeInterval(Double(i) * 2))
        }
        seedSleepRow(ts: t0.timeIntervalSince1970 + 10, dur: 32_400, watts: 40, app: "com.sleeper")
        s.downsample()

        XCTAssertEqual(s.stats().rawIntervals, 0, "the raw rows were all compactable")
        XCTAssertEqual(s.onBatterySeconds(hours: 10), 10, accuracy: 1e-9,
                       "the minute's real samples must survive the sleep row")
        let rows = s.windowPower(hours: 10, joulesPerPercent: 3600)
        XCTAssertEqual(rows.map(\.name), ["Real"])
        XCTAssertEqual(rows.first?.joules ?? 0, 20, accuracy: 1e-9)
    }
}

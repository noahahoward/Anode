import XCTest
import SQLite3
@testable import PowerKit

/// Retention has to actually happen.
///
/// `prune` existed, `Settings.historyRetentionDays` existed with a Preferences
/// control and a caption reading "Sampled history older than this is pruned",
/// and NOTHING EVER CALLED IT. The store grew without bound and the setting was
/// decoration. Every test here drives the path the app really uses — the store's
/// own schedule — rather than calling `prune()` by hand, because calling it by
/// hand is the one thing that was never the problem.
final class StoreRetentionTests: XCTestCase {

    private var dir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bs-retention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A throwaway suite: these tests write retention settings, and the user's
        // real preferences are not a fixture.
        suiteName = "com.betterstats.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: dir)
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    private func makeStore(retention: HistoryStore.Retention,
                           rawHorizon: TimeInterval = 3600,
                           bucketWidth: TimeInterval = 60) -> HistoryStore? {
        HistoryStore(path: dir.appendingPathComponent("h.sqlite"),
                     rawHorizon: rawHorizon, bucketWidth: bucketWidth,
                     retention: retention)
    }

    private func write(_ store: HistoryStore, at date: Date, apps: [String] = ["Safari", "Xcode"]) {
        let drains = apps.map {
            AppDrain(identity: AppIdentity(name: $0, bundleID: "com.test.\($0)", isApp: true),
                     joules: 4, over: 2)
        }
        store.record(apps: drains, measured_W: 5, attributed_W: 4, residual_W: 1,
                     onBattery: true, socPercent: 60, interval: 2, at: date)
    }

    /// A second read-only connection, because `stats()` cannot answer "is any app
    /// row pointing at an interval that no longer exists".
    private func scalar(_ sql: String) -> Int {
        var h: OpaquePointer?
        guard sqlite3_open_v2(dir.appendingPathComponent("h.sqlite").path, &h,
                              SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(h) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : -1
    }

    /// Poll rather than sleep a fixed amount: the pass runs on the store's own
    /// maintenance queue and there is no completion to await.
    @discardableResult
    private func wait(upTo seconds: TimeInterval, for condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    // ── The bug ─────────────────────────────────────────────────────────────

    /// The headline: nobody calls prune, and history still gets trimmed.
    ///
    /// Rows outside the horizon go, rows inside it stay — driven entirely by the
    /// store's own schedule. Without the fix the store never schedules anything
    /// and every row survives forever.
    func testAScheduledPassPrunesWithoutAnyoneCallingPrune() throws {
        let settings = Settings(defaults: defaults)
        settings.historyRetentionDays = 30
        guard let s = makeStore(retention: .follow(settings)) else { return XCTFail("store") }
        s.retentionChangeDelay = 0.05

        let now = Date()
        write(s, at: now.addingTimeInterval(-10 * 86400))   // outside a 1-day horizon
        write(s, at: now.addingTimeInterval(-5 * 86400))
        write(s, at: now.addingTimeInterval(-1800))         // inside it
        XCTAssertEqual(s.stats().intervals, 3)

        settings.historyRetentionDays = 1

        XCTAssertTrue(wait(upTo: 5) { s.stats().intervals == 1 },
                      "the scheduled pass never ran: history is \(s.stats().intervals) rows")
        XCTAssertEqual(s.stats().intervals, 1, "the row inside retention must survive")
        XCTAssertEqual(s.earliestSample()?.timeIntervalSince1970 ?? 0,
                       now.addingTimeInterval(-1800).timeIntervalSince1970, accuracy: 1,
                       "the surviving row must be the recent one, not an older one")
    }

    /// Construction arms the timer. This is what makes the fix un-forgettable:
    /// no call site anywhere else has to remember retention exists.
    func testAStoreArmsItsOwnMaintenanceAtConstruction() throws {
        let settings = Settings(defaults: defaults)
        guard let s = makeStore(retention: .follow(settings)) else { return XCTFail("store") }
        XCTAssertTrue(wait(upTo: 2) { s.nextScheduledPrune != nil },
                      "a store that follows Settings must schedule its own first pass")
        let due = try XCTUnwrap(s.nextScheduledPrune).timeIntervalSinceNow
        XCTAssertGreaterThan(due, 60, "pruning at launch competes with the first samples")
        XCTAssertLessThan(due, s.firstPassDelay + 5)
    }

    /// …and `.manual` really means manual, so a test or a one-shot tool can hold
    /// a store without a timer running behind it.
    func testAManualStoreSchedulesNothing() throws {
        guard let s = makeStore(retention: .manual) else { return XCTFail("store") }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertNil(s.nextScheduledPrune)
    }

    // ── Retention decrease: schedule, never perform ─────────────────────────

    /// Dragging the stepper from 365 to 7 writes once per step, on the main
    /// thread. Pruning inline would run a several-hundred-thousand-row delete
    /// inside the drag; the write must only re-arm the timer.
    func testARetentionDecreaseSchedulesRatherThanPrunes() throws {
        let settings = Settings(defaults: defaults)
        settings.historyRetentionDays = 365
        guard let s = makeStore(retention: .follow(settings)) else { return XCTFail("store") }
        // Long enough that the pass cannot have run by the time we assert.
        s.retentionChangeDelay = 30

        let now = Date()
        for d in 1...20 { write(s, at: now.addingTimeInterval(-Double(d) * 86400)) }
        XCTAssertEqual(s.stats().intervals, 20)

        let before = Date()
        // The drag: every intermediate value is a real write with a real observer
        // firing on the main thread.
        for day in stride(from: 365.0, through: 7.0, by: -1) {
            settings.historyRetentionDays = day
        }
        let dragCost = Date().timeIntervalSince(before)

        XCTAssertEqual(s.stats().intervals, 20,
                       "the drag deleted rows synchronously — that is the stall this must not do")
        XCTAssertLessThan(dragCost, 1.0,
                          "359 writes took \(dragCost)s: something is doing real work on main")
        let due = try XCTUnwrap(s.nextScheduledPrune).timeIntervalSinceNow
        XCTAssertGreaterThan(due, 1, "the change must have SCHEDULED a pass")
        XCTAssertLessThan(due, s.retentionChangeDelay + 5,
                          "…and scheduled it soon, not an hour out")
    }

    // ── Chunking ────────────────────────────────────────────────────────────

    /// A chunk is bounded, chunks make progress, and the sequence ends. The
    /// "does not spin" half matters most: a chunk that deleted nothing and still
    /// reported work would loop the maintenance queue forever.
    func testChunkingIsBoundedTerminatesAndDoesNotSpin() throws {
        guard let s = makeStore(retention: .manual) else { return XCTFail("store") }
        s.chunkRows = 10

        let now = Date()
        for i in 0..<35 { write(s, at: now.addingTimeInterval(-10 * 86400 + Double(i))) }
        XCTAssertEqual(s.stats().intervals, 35)

        var sizes: [Int] = []
        var calls = 0
        while calls < 100 {
            calls += 1
            let n = s.pruneChunk(olderThan: 1)
            sizes.append(n)
            if n < s.chunkRows { break }
        }
        XCTAssertEqual(sizes, [10, 10, 10, 5], "each chunk must be bounded by chunkRows")
        XCTAssertEqual(s.stats().intervals, 0)

        // Nothing left: further chunks must report 0 rather than rediscovering
        // work, which is what would turn the chained pass into a spin.
        XCTAssertEqual(s.pruneChunk(olderThan: 1), 0)
        XCTAssertEqual(s.pruneChunk(olderThan: 1), 0)
    }

    /// The blocking form has to terminate too, in one call, with the chunk loop
    /// underneath it.
    func testPruneTerminatesAcrossManyChunks() throws {
        guard let s = makeStore(retention: .manual) else { return XCTFail("store") }
        s.chunkRows = 7
        let now = Date()
        for i in 0..<50 { write(s, at: now.addingTimeInterval(-10 * 86400 + Double(i))) }
        write(s, at: now.addingTimeInterval(-60))

        s.prune(olderThan: 1)

        XCTAssertEqual(s.stats().intervals, 1, "everything outside the horizon, and only that")
    }

    // ── Orphans ─────────────────────────────────────────────────────────────

    /// An app row whose interval is gone is unreachable by every query in the
    /// store and is never selected by a later prune: it is permanent, and it is
    /// the whole reason the two deletes share one transaction.
    func testAppRowsNeverOrphan() throws {
        let settings = Settings(defaults: defaults)
        settings.historyRetentionDays = 30
        guard let s = makeStore(retention: .follow(settings)) else { return XCTFail("store") }
        s.retentionChangeDelay = 0.05
        s.chunkRows = 3

        let now = Date()
        for i in 0..<11 { write(s, at: now.addingTimeInterval(-10 * 86400 + Double(i))) }
        write(s, at: now.addingTimeInterval(-120))
        XCTAssertEqual(s.stats().appRows, 24, "2 apps per interval, 12 intervals")

        settings.historyRetentionDays = 1
        XCTAssertTrue(wait(upTo: 5) { s.stats().intervals == 1 }, "pass never completed")

        XCTAssertEqual(s.stats().appRows, 2, "only the surviving interval's app rows remain")
        XCTAssertEqual(scalar("""
            SELECT COUNT(*) FROM app_energy a
             WHERE NOT EXISTS (SELECT 1 FROM interval i WHERE i.id = a.interval_id)
            """), 0, "orphaned app rows survive every future prune")
    }

    // ── Both storage tiers ──────────────────────────────────────────────────

    /// Raw ticks and compacted buckets are pruned by different rules, because a
    /// bucket's `ts` is its START and it covers a further `bucketWidth` of wall
    /// clock. A bucket straddling the cutoff still holds time INSIDE retention,
    /// so deleting on `ts` alone throws away data the user asked to keep.
    func testACompactedBucketStraddlingTheCutoffIsKept() throws {
        guard let s = makeStore(retention: .manual, rawHorizon: 60, bucketWidth: 60) else {
            return XCTFail("store")
        }
        // Choose the cutoff rather than accept whatever "1 day ago" lands on:
        // the straddle only exists for one alignment in sixty.
        let nowT = Date().timeIntervalSince1970
        let edge = ((nowT - 86400) / 60).rounded(.down) * 60   // a bucket boundary
        let cutoff = edge + 30                                 // mid-bucket
        let days = (nowT - cutoff) / 86400

        write(s, at: Date(timeIntervalSince1970: edge + 10))        // -> bucket at `edge`
        write(s, at: Date(timeIntervalSince1970: edge + 40))        // -> same bucket
        write(s, at: Date(timeIntervalSince1970: edge - 30))        // -> bucket at edge-60
        s.downsample()
        XCTAssertEqual(s.stats().rawIntervals, 0, "everything must be compacted for this test")
        XCTAssertEqual(s.stats().intervals, 2, "two buckets")

        s.prune(olderThan: days)

        XCTAssertEqual(s.stats().intervals, 1,
                       "the fully expired bucket must go and the straddling one must stay")
        XCTAssertEqual(s.earliestSample()?.timeIntervalSince1970 ?? 0, edge, accuracy: 0.5,
                       "the surviving bucket is the one that still covers time inside retention")
    }

    /// The other tier, and the one that must NOT get the bucket's grace period:
    /// a raw row's `ts` is the end of the interval it measured, so `ts < cutoff`
    /// already means the whole interval is outside the horizon.
    func testRawTicksAndBucketsArePrunedInTheSamePass() throws {
        guard let s = makeStore(retention: .manual, rawHorizon: 60, bucketWidth: 60) else {
            return XCTFail("store")
        }
        let now = Date()
        // Old, and compacted into buckets.
        for i in 0..<4 { write(s, at: now.addingTimeInterval(-10 * 86400 + Double(i) * 120)) }
        s.downsample()
        XCTAssertEqual(s.stats().rawIntervals, 0)
        let buckets = s.stats().intervals
        XCTAssertGreaterThan(buckets, 0)

        // Old, and still raw — a store the app quit before compaction reached.
        for i in 0..<3 { write(s, at: now.addingTimeInterval(-9 * 86400 + Double(i))) }
        // Recent, raw, must survive.
        write(s, at: now.addingTimeInterval(-30))
        XCTAssertEqual(s.stats().rawIntervals, 4)

        s.prune(olderThan: 1)

        XCTAssertEqual(s.stats().intervals, 1, "both tiers must be pruned, not just one")
        XCTAssertEqual(s.stats().rawIntervals, 1)
        XCTAssertEqual(scalar("SELECT COUNT(*) FROM interval WHERE agg=1"), 0,
                       "expired buckets survived: the compacted tier is not being pruned")
    }
}

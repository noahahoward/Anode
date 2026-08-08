import XCTest
import SQLite3
@testable import PowerKit

/// Opening a store created by an OLDER build must work.
///
/// This exists because it did not. Adding a `soc` column to the schema was safe
/// on a fresh database and fatal on an existing one: CREATE TABLE IF NOT EXISTS
/// silently does nothing when the table is already there, so the column was
/// missing, every INSERT naming it failed to prepare, init returned nil, and
/// deinit then finalised uninitialised statement pointers — a SIGSEGV inside
/// sqlite3_finalize, on launch, for every existing user. The app shipped that
/// way for one build.
///
/// A schema change is not tested by a fresh-database test.
final class StoreMigrationTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bs-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Builds a database with the pre-soc schema, exactly as an older build left it.
    private func makeLegacyStore(at path: String) throws {
        var h: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &h), SQLITE_OK)
        defer { sqlite3_close(h) }
        let legacy = """
        CREATE TABLE interval(
            id          INTEGER PRIMARY KEY,
            ts          REAL    NOT NULL,
            dur         REAL    NOT NULL,
            on_battery  INTEGER NOT NULL,
            agg         INTEGER NOT NULL DEFAULT 0,
            measured_j  REAL,
            attributed_j REAL,
            residual_j  REAL
        );
        CREATE TABLE app_energy(
            interval_id INTEGER NOT NULL,
            app         TEXT    NOT NULL,
            name        TEXT    NOT NULL,
            joules      REAL    NOT NULL,
            PRIMARY KEY(interval_id, app)
        ) WITHOUT ROWID;
        INSERT INTO interval(ts, dur, on_battery, agg, measured_j)
            VALUES(1000, 2.0, 1, 0, 20.0);
        """
        XCTAssertEqual(sqlite3_exec(h, legacy, nil, nil, nil), SQLITE_OK)
    }

    func testOpeningAPreSocDatabaseMigratesInsteadOfCrashing() throws {
        let path = dir.appendingPathComponent("history.sqlite").path
        try makeLegacyStore(at: path)

        let store = HistoryStore(path: URL(fileURLWithPath: path))
        XCTAssertNotNil(store, "a store from an older build must still open")

        // And it must be usable, not merely non-nil: the migration has to have
        // actually added the column the prepared INSERT names.
        store?.record(apps: [], measured_W: 5, attributed_W: 1, residual_W: 1,
                      onBattery: true, socPercent: 77, interval: 2,
                      at: Date(timeIntervalSince1970: 2000))

        let pts = store?.powerSeries(since: Date(timeIntervalSince1970: 0),
                                     until: Date(timeIntervalSince1970: 3000),
                                     maxPoints: 100) ?? []
        XCTAssertFalse(pts.isEmpty, "legacy rows must still be readable after migration")
        XCTAssertTrue(pts.contains { $0.socPercent == 77 },
                      "the newly written soc value must round-trip")
    }

    /// The legacy row has no soc. It must come back as nil rather than 0 —
    /// "not recorded" and "battery was empty" are different claims.
    func testLegacyRowsHaveNoFabricatedStateOfCharge() throws {
        let path = dir.appendingPathComponent("history.sqlite").path
        try makeLegacyStore(at: path)
        let store = HistoryStore(path: URL(fileURLWithPath: path))
        let pts = store?.powerSeries(since: Date(timeIntervalSince1970: 0),
                                     until: Date(timeIntervalSince1970: 1500),
                                     maxPoints: 100) ?? []
        XCTAssertEqual(pts.count, 1)
        XCTAssertNil(pts.first?.socPercent)
    }

    /// Opening the same database twice in a row must work — the migration runs
    /// again and its duplicate-column error has to stay harmless.
    func testMigrationIsIdempotent() throws {
        let path = dir.appendingPathComponent("history.sqlite").path
        try makeLegacyStore(at: path)
        XCTAssertNotNil(HistoryStore(path: URL(fileURLWithPath: path)))
        XCTAssertNotNil(HistoryStore(path: URL(fileURLWithPath: path)))
        XCTAssertNotNil(HistoryStore(path: URL(fileURLWithPath: path)))
    }

    /// The write guard that was added after four stored buckets held Int64.max
    /// scaled, which poisoned every SUM they landed in.
    func testImplausiblePowerIsNeverStored() throws {
        let path = dir.appendingPathComponent("history.sqlite").path
        let store = HistoryStore(path: URL(fileURLWithPath: path))
        XCTAssertNotNil(store)
        store?.record(apps: [], measured_W: 9.2e15, attributed_W: Double?.none, residual_W: Double?.none,
                      onBattery: true, socPercent: 50, interval: 2,
                      at: Date(timeIntervalSince1970: 5000))
        let pts = store?.powerSeries(since: Date(timeIntervalSince1970: 4000),
                                     until: Date(timeIntervalSince1970: 6000),
                                     maxPoints: 10) ?? []
        XCTAssertTrue(pts.isEmpty,
                      "a wrapped counter must not reach the graph or any SUM")
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Compaction must not destroy state of charge.
///
/// It did. `downsampleLocked`'s INSERT named every column except `soc`, then
/// deleted the raw rows it had folded — so every SoC sample older than
/// `rawHorizon` became NULL, and the battery line could only ever exist for the
/// trailing hour. That is precisely the range the multi-day graph was added to
/// escape, and nothing failed: the column existed, the query succeeded, the
/// numbers were simply gone.
///
/// The write path was verified when this shipped. Compaction was not.
final class StoreCompactionTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bs-compact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func store() -> HistoryStore? {
        // Tiny rawHorizon so everything written is immediately compactable.
        HistoryStore(path: dir.appendingPathComponent("h.sqlite"),
                     rawHorizon: 1, bucketWidth: 60)
    }

    func testCompactionPreservesStateOfCharge() throws {
        guard let s = store() else { return XCTFail("store") }
        let t0 = Date().addingTimeInterval(-7200)
        for i in 0..<20 {
            s.record(apps: [], measured_W: 5, attributed_W: 1, residual_W: 1,
                     onBattery: true, socPercent: Double(90 - i), interval: 2,
                     at: t0.addingTimeInterval(Double(i) * 2))
        }
        s.downsample()

        let pts = s.powerSeries(since: t0.addingTimeInterval(-60),
                                until: t0.addingTimeInterval(3600), maxPoints: 200)
        XCTAssertFalse(pts.isEmpty, "compacted rows must still be readable")
        XCTAssertTrue(pts.contains { $0.socPercent != nil },
                      "state of charge must survive compaction — it was being dropped entirely")
        for p in pts {
            if let soc = p.socPercent {
                XCTAssertTrue((70...91).contains(soc),
                              "compacted soc \(soc) is outside the range that was written")
            }
        }
    }

    /// The mean must be weighted by duration. Rows folded into one bucket have
    /// different durations, so a plain average lets a 0.8 s tick pull as hard as
    /// a 60 s one.
    func testCompactedStateOfChargeIsDurationWeighted() throws {
        guard let s = store() else { return XCTFail("store") }
        let t0 = Date().addingTimeInterval(-7200)
        // 1 s at 100%, then 99 s at 0% -> weighted mean 1%, plain mean 50%.
        s.record(apps: [], measured_W: 5, attributed_W: nil, residual_W: nil,
                 onBattery: true, socPercent: 100, interval: 1, at: t0)
        s.record(apps: [], measured_W: 5, attributed_W: nil, residual_W: nil,
                 onBattery: true, socPercent: 0, interval: 99, at: t0.addingTimeInterval(1))
        s.downsample()

        let pts = s.powerSeries(since: t0.addingTimeInterval(-60),
                                until: t0.addingTimeInterval(3600), maxPoints: 10)
        let soc = pts.compactMap(\.socPercent).first
        XCTAssertNotNil(soc)
        XCTAssertEqual(soc ?? -1, 1.0, accuracy: 0.5,
                       "a plain average would report ~50 here")
    }
}

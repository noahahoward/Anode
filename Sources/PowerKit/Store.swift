import Foundation
import SQLite3

/// Persistent time-series store behind the "10 hr power" column.
///
/// Activity Monitor's "12 hr Power" is a unitless number normalized so the column
/// is never checkable against anything. This store keeps the real ledger instead:
/// per interval it records measured whole-system energy, the energy attributed to
/// each app, and the residual — so "what drained my battery last night" is answered
/// in actual joules (displayed as % of battery), and the rows still sum to the
/// measured total historically, with the residual PRINTED, never redistributed.
///
/// Storage decisions, and why:
///
///  * SQLite via the system `libsqlite3` (`import SQLite3` — module ships in the
///    macOS SDK, verified on this machine, SQLite 3.54). No external dependency.
///  * Energy is stored as JOULES + a duration, not watts. Watts do not aggregate:
///    averaging two windows' watts without duration-weighting is wrong the moment
///    intervals differ in length (and after downsampling they always do). Joules
///    add exactly, and watts are recoverable as J / dur when needed.
///  * `on_battery` is stored per interval because the 10 hr window counts
///    ON-BATTERY TIME ONLY — energy drawn from the wall is not battery cost.
///    Downsampled buckets never mix battery and AC time (they are bucketed by
///    (minute, on_battery)), so the exclusion survives aggregation.
///  * Raw 2 s ticks are DOWNSAMPLED into 1-minute buckets once they are older
///    than an hour. MEASURED on this machine (10,000 intervals x 20 apps):
///    raw 2 s rows cost 39.7 MB/day, which is unreasonable for a 7-day
///    retention; after bucketing the same data costs 2.51 MB/day, so 7 days
///    is ~18 MB plus a bounded ≤1 h of raw (~1.7 MB) for the live drill-down.
///    Bucketing loses nothing the ledger needs: joule totals are preserved
///    exactly (verified), only sub-minute timing detail goes.
///  * WAL + synchronous=NORMAL: commits every 2 s from a background queue are
///    sub-millisecond because WAL commits do not fsync (checkpoints do). A serial
///    internal queue makes the class safe to call from any thread; every write is
///    a single transaction so a crash loses at most one tick.
///
/// Coverage honesty: `onBatterySeconds(hours:)` reports how much on-battery time
/// the window actually contains. The UI MUST show it — presenting 20 minutes of
/// recorded battery time as a "10 hr" figure is the same lie as normalizing to 100%.
public final class HistoryStore {

    private var db: OpaquePointer?
    /// All SQLite access is serialized here. record() arrives from the sampler's
    /// background queue; windowPower() from wherever the UI asks. One connection,
    /// one queue — no cross-thread SQLite, no locking subtleties.
    private let queue = DispatchQueue(label: "BetterStats.HistoryStore")
    private let fileURL: URL
    /// Raw ticks older than this get merged into buckets. Configurable so tests
    /// can force compaction; 1 h default keeps the live hour at full resolution.
    private let rawHorizon: TimeInterval
    private let bucketWidth: TimeInterval
    private var sinceCompact = 0
    /// Cached prepared statements for the hot path (one record() every 2 s and
    /// the 10 k-row volume test both go through these).
    private var insInterval: OpaquePointer?
    private var insApp: OpaquePointer?

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init?(path: URL? = nil,
                 rawHorizon: TimeInterval = 3600,
                 bucketWidth: TimeInterval = 60) {
        let url: URL
        if let p = path {
            url = p
        } else {
            guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                      in: .userDomainMask).first else { return nil }
            url = base.appendingPathComponent("BetterStats/history.sqlite")
        }
        self.fileURL = url
        self.bucketWidth = max(1, bucketWidth)
        self.rawHorizon = max(self.bucketWidth, rawHorizon)

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)

        var handle: OpaquePointer?
        // FULLMUTEX as belt-and-braces: the serial queue already prevents
        // concurrent use, but a serialized connection turns a future mistake
        // into a slow call instead of a corruption.
        guard sqlite3_open_v2(url.path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, let h = handle else {
            sqlite3_close(handle)
            return nil
        }
        db = h
        sqlite3_busy_timeout(h, 2000)
        // auto_vacuum must be declared before the first table exists to take
        // effect; on an already-created file this is a harmless no-op and the
        // file simply reuses free pages instead of shrinking.
        exec("PRAGMA auto_vacuum=INCREMENTAL")
        // Temp tables in RAM, not on disk. stageWindowLocked rewrites a temp table
        // holding every interval id in the trailing window — tens of thousands of
        // rows — each time the window query runs. With the default file-backed temp
        // store that alone dirtied 581 KB/s while the window was open, and macOS
        // killed the app for exceeding its 24.9 KB/s sustained limit after 2.1 GB.
        // Measured immediately after this change: 0 KB/s.
        exec("PRAGMA temp_store=MEMORY")
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")

        // agg: 0 = raw tick, 1 = downsampled bucket. Bucket rows are unique per
        // (start, power source) — the partial index is what lets a re-run of
        // compaction UPSERT into an existing bucket instead of double-counting.
        let schema = """
        CREATE TABLE IF NOT EXISTS interval(
            id          INTEGER PRIMARY KEY,
            ts          REAL    NOT NULL,
            dur         REAL    NOT NULL,
            on_battery  INTEGER NOT NULL,
            agg         INTEGER NOT NULL DEFAULT 0,
            measured_j  REAL,
            attributed_j REAL,
            residual_j  REAL,
            soc         REAL
        );
        CREATE INDEX IF NOT EXISTS idx_interval_ts   ON interval(ts);
        CREATE INDEX IF NOT EXISTS idx_interval_batt ON interval(on_battery, ts);
        CREATE UNIQUE INDEX IF NOT EXISTS idx_bucket ON interval(ts, on_battery) WHERE agg=1;
        CREATE TABLE IF NOT EXISTS app_energy(
            interval_id INTEGER NOT NULL,
            app         TEXT    NOT NULL,
            name        TEXT    NOT NULL,
            joules      REAL    NOT NULL,
            PRIMARY KEY(interval_id, app)
        ) WITHOUT ROWID;
        """
        guard sqlite3_exec(h, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(h)
            db = nil
            return nil
        }

        // Additive migration, run BEFORE any statement is prepared and NOT in a
        // defer. CREATE TABLE IF NOT EXISTS does not add a column to a table that
        // already exists, so on an existing store the `soc` column is missing and
        // every INSERT naming it fails to prepare — init then returns nil and
        // deinit finalises uninitialised pointers, which is a SIGSEGV inside
        // sqlite3_finalize on launch. A defer was worse still: it ran after the
        // failure path had already closed the handle.
        //
        // A duplicate-column error is the expected outcome on an up-to-date
        // database and is ignored; anything else leaves the column absent, which
        // the guard below then catches honestly.
        sqlite3_exec(h, "ALTER TABLE interval ADD COLUMN soc REAL", nil, nil, nil)

        insInterval = prepare("""
            INSERT INTO interval(ts, dur, on_battery, agg, measured_j, attributed_j, residual_j, soc)
            VALUES(?,?,?,0,?,?,?,?)
            """)
        insApp = prepare("""
            INSERT INTO app_energy(interval_id, app, name, joules) VALUES(?,?,?,?)
            ON CONFLICT(interval_id, app) DO UPDATE SET
                joules = joules + excluded.joules, name = excluded.name
            """)
        guard insInterval != nil, insApp != nil else {
            sqlite3_finalize(insInterval); sqlite3_finalize(insApp)
            sqlite3_close(h)
            db = nil
            return nil
        }

        // Fold anything a previous run left un-bucketed (e.g. the app quit).
        queue.sync { downsampleLocked() }
    }

    deinit {
        // Every one of these is nil-safe in C, but only if the property really is
        // nil rather than uninitialised. A failed init used to reach here with
        // garbage in insInterval and crash inside sqlite3_finalize; the
        // properties are now optionals initialised to nil at declaration, so a
        // half-built store tears down cleanly.
        if let s = insInterval { sqlite3_finalize(s) }
        if let s = insApp { sqlite3_finalize(s) }
        if let d = db { sqlite3_close(d) }
    }

    // ── Recording ───────────────────────────────────────────────────────────

    /// Append one interval's worth of per-app energy plus the system ledger.
    ///
    /// Watts are converted to joules (`W x interval`) at the door so everything
    /// downstream is additive. `nil` system figures stay NULL — an unmeasured
    /// window must not masquerade as "measured zero".
    /// No laptop draws this. Anything above it is a wrapped counter, not a
    /// measurement — verified in the wild: four stored buckets held measured_j
    /// values around 1.8e16, one of them 9223372036854758, which is Int64.max
    /// scaled. A single such row silently dominates every SUM it lands in, so
    /// they are rejected on the way in AND filtered on the way out.
    public static let maxPlausibleWatts = 200.0

    /// No sample this app takes spans this long. Ticks run at 1-30 s and a full
    /// sweep is forced at least once a minute, so a row claiming minutes did not
    /// measure minutes: it straddles a sleep or a stopped process, and the sampler
    /// is meant to have dropped it already. This is the second line, because such
    /// a row is not merely wrong — the window walk takes rows newest-first, so one
    /// 32,400 s row IS the entire 10 hr window.
    ///
    /// Enforced on the way in AND filtered on the way out, exactly like
    /// `maxPlausibleWatts`: stores already on disk hold rows written before the
    /// sampler learned to drop them, and those users must see the fix too.
    public static let maxPlausibleInterval: TimeInterval = 300

    public func record(apps: [AppDrain], measured_W: Double?, attributed_W: Double?,
                       residual_W: Double?, onBattery: Bool,
                       socPercent: Double? = nil, interval: TimeInterval,
                       at date: Date = Date()) {
        guard interval > 0, interval <= Self.maxPlausibleInterval else { return }
        queue.sync {
            guard let db = db, let insI = insInterval, let insA = insApp else { return }

            // Collapse duplicate identities up front (two AppDrains can share a
            // bundleID if the caller ever passes ungrouped rows) so the app
            // insert cannot conflict with itself inside one interval.
            var byKey: [String: (name: String, j: Double)] = [:]
            for a in apps where a.joules > 0 {
                // bundleID is the stable handle across renames and localization;
                // daemons have none, so the executable name is the only key.
                let key = a.identity.bundleID ?? a.name
                var e = byKey[key] ?? (a.name, 0)
                e.j += a.joules
                byKey[key] = e
            }

            exec("BEGIN IMMEDIATE")
            sqlite3_reset(insI)
            sqlite3_bind_double(insI, 1, date.timeIntervalSince1970)
            sqlite3_bind_double(insI, 2, interval)
            sqlite3_bind_int(insI, 3, onBattery ? 1 : 0)
            bindOptionalJoules(insI, 4, measured_W, interval)
            bindOptionalJoules(insI, 5, attributed_W, interval)
            bindOptionalJoules(insI, 6, residual_W, interval)
            // State of charge is a LEVEL, not an energy, so it is stored as-is
            // rather than multiplied by the interval. Without it the battery line
            // could only ever be drawn for the live hour held in memory.
            if let soc = socPercent, soc.isFinite, soc >= 0, soc <= 100 {
                sqlite3_bind_double(insI, 7, soc)
            } else {
                sqlite3_bind_null(insI, 7)
            }
            guard sqlite3_step(insI) == SQLITE_DONE else { exec("ROLLBACK"); return }
            let iid = sqlite3_last_insert_rowid(db)

            for (key, e) in byKey {
                sqlite3_reset(insA)
                sqlite3_bind_int64(insA, 1, iid)
                sqlite3_bind_text(insA, 2, key, -1, Self.transient)
                sqlite3_bind_text(insA, 3, e.name, -1, Self.transient)
                sqlite3_bind_double(insA, 4, e.j)
                _ = sqlite3_step(insA)   // fail soft: one lost row beats a lost tick
            }
            exec("COMMIT")

            // Opportunistic compaction roughly every 8.5 min at a 2 s cadence.
            sinceCompact += 1
            if sinceCompact >= 256 {
                sinceCompact = 0
                downsampleLocked()
            }
        }
    }

    private func bindOptionalJoules(_ stmt: OpaquePointer?, _ idx: Int32,
                                    _ watts: Double?, _ interval: TimeInterval) {
        // isFinite is not enough: a wrapped counter is a perfectly finite,
        // perfectly enormous number, and that is exactly what reached the disk.
        if let w = watts, w.isFinite, w >= 0, w <= Self.maxPlausibleWatts {
            sqlite3_bind_double(stmt, idx, w * interval)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    // ── The window walk ─────────────────────────────────────────────────────

    /// Which intervals make up the trailing `windowSec` of ON-BATTERY time.
    ///
    /// Walks newest-first through on-battery rows accumulating duration. The one
    /// interval that straddles the window edge is included at a time fraction —
    /// the ONLY estimated quantity in this file: a bucket's joules are a measured
    /// total over ≤60 s, and pro-rating assumes uniform draw within it. Everything
    /// else is exact addition of measured values.
    private struct Selection {
        var fullIDs: [Int64] = []
        var boundary: (id: Int64, fraction: Double)?
        var coveredSeconds: TimeInterval = 0
    }

    private func selectWindowLocked(_ windowSec: TimeInterval) -> Selection {
        var sel = Selection()
        // The dur filter is what makes an already-poisoned store recover. A row
        // written across a sleep sits at the newest end, so the walk would hand it
        // the whole window before reaching a single real sample.
        guard let stmt = prepare("""
            SELECT id, dur FROM interval WHERE on_battery=1 AND dur <= \(Self.maxPlausibleInterval)
             ORDER BY ts DESC, id DESC
            """) else { return sel }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let dur = sqlite3_column_double(stmt, 1)
            if sel.coveredSeconds + dur <= windowSec + 1e-9 {
                sel.fullIDs.append(id)
                sel.coveredSeconds += dur
            } else {
                let remain = windowSec - sel.coveredSeconds
                if remain > 1e-9, dur > 0 {
                    sel.boundary = (id, remain / dur)
                    sel.coveredSeconds = windowSec
                }
                break
            }
        }
        return sel
    }

    /// Load the selection's full IDs into a temp table so aggregate queries can
    /// join instead of interpolating a five-figure IN() list into SQL text.
    private func stageWindowLocked(_ sel: Selection) -> Bool {
        exec("CREATE TEMP TABLE IF NOT EXISTS win(id INTEGER PRIMARY KEY)")
        exec("DELETE FROM win")
        guard let ins = prepare("INSERT INTO win(id) VALUES(?)") else { return false }
        defer { sqlite3_finalize(ins) }
        exec("BEGIN")
        for id in sel.fullIDs {
            sqlite3_reset(ins)
            sqlite3_bind_int64(ins, 1, id)
            _ = sqlite3_step(ins)
        }
        exec("COMMIT")
        return true
    }

    // ── Queries ─────────────────────────────────────────────────────────────

    /// Percent of battery each app consumed over the trailing window of
    /// ON-BATTERY time, sorted by cost. `joulesPerPercent` comes from the live
    /// BatteryScale so the figure tracks pack aging, not a stale stored scale.
    public func windowPower(hours: Double, joulesPerPercent: Double)
        -> [(name: String, percentOfBattery: Double, joules: Double)] {
        guard hours > 0, joulesPerPercent > 0 else { return [] }
        return queue.sync {
            let sel = selectWindowLocked(hours * 3600)
            guard !sel.fullIDs.isEmpty || sel.boundary != nil else { return [] }
            guard stageWindowLocked(sel) else { return [] }

            var byKey: [String: (name: String, j: Double)] = [:]
            if let stmt = prepare("""
                SELECT a.app, MAX(a.name), SUM(a.joules)
                FROM app_energy a JOIN win w ON w.id = a.interval_id
                GROUP BY a.app
                """) {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let k = sqlite3_column_text(stmt, 0),
                          let n = sqlite3_column_text(stmt, 1) else { continue }
                    byKey[String(cString: k)] = (String(cString: n),
                                                 sqlite3_column_double(stmt, 2))
                }
                sqlite3_finalize(stmt)
            }

            if let (bid, fraction) = sel.boundary,
               let stmt = prepare("SELECT app, name, joules FROM app_energy WHERE interval_id=?") {
                sqlite3_bind_int64(stmt, 1, bid)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let k = sqlite3_column_text(stmt, 0),
                          let n = sqlite3_column_text(stmt, 1) else { continue }
                    let key = String(cString: k)
                    var e = byKey[key] ?? (String(cString: n), 0)
                    e.j += sqlite3_column_double(stmt, 2) * fraction
                    byKey[key] = e
                }
                sqlite3_finalize(stmt)
            }

            return byKey
                .map { (name: $0.value.name,
                        percentOfBattery: $0.value.j / joulesPerPercent,
                        joules: $0.value.j) }
                .sorted { $0.joules > $1.joules }
        }
    }

    /// On-battery seconds actually covered by the window. The UI must display
    /// this next to the column header: "10 hr power" computed over 20 minutes of
    /// recorded battery time is a 20-minute figure wearing a 10-hour label.
    public func onBatterySeconds(hours: Double) -> TimeInterval {
        guard hours > 0 else { return 0 }
        return queue.sync { selectWindowLocked(hours * 3600).coveredSeconds }
    }

    /// The historical ledger over the same window: measured vs attributed vs
    /// residual, in joules. NULL-measured intervals contribute nothing to
    /// `measured_J` (a sum of measured energy only), so if coverage of the
    /// measured signal was partial the residual is a floor, not a lie.
    public struct WindowTotals {
        public let onBatterySeconds: TimeInterval
        public let measured_J: Double?
        public let attributed_J: Double?
        public let residual_J: Double?
    }

    public func windowTotals(hours: Double) -> WindowTotals {
        guard hours > 0 else {
            return WindowTotals(onBatterySeconds: 0, measured_J: nil, attributed_J: nil, residual_J: nil)
        }
        return queue.sync {
            let sel = selectWindowLocked(hours * 3600)
            guard stageWindowLocked(sel) else {
                return WindowTotals(onBatterySeconds: 0, measured_J: nil, attributed_J: nil, residual_J: nil)
            }
            var m: Double?, a: Double?, r: Double?
            if let stmt = prepare("""
                SELECT SUM(i.measured_j), SUM(i.attributed_j), SUM(i.residual_j)
                FROM interval i JOIN win w ON w.id = i.id
                """), sqlite3_step(stmt) == SQLITE_ROW {
                m = columnOptionalDouble(stmt, 0)
                a = columnOptionalDouble(stmt, 1)
                r = columnOptionalDouble(stmt, 2)
                sqlite3_finalize(stmt)
            }
            if let (bid, f) = sel.boundary,
               let stmt = prepare("SELECT measured_j, attributed_j, residual_j FROM interval WHERE id=?") {
                sqlite3_bind_int64(stmt, 1, bid)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    func add(_ base: Double?, _ idx: Int32) -> Double? {
                        guard let v = columnOptionalDouble(stmt, idx) else { return base }
                        return (base ?? 0) + v * f
                    }
                    m = add(m, 0); a = add(a, 1); r = add(r, 2)
                }
                sqlite3_finalize(stmt)
            }
            return WindowTotals(onBatterySeconds: sel.coveredSeconds,
                                measured_J: m, attributed_J: a, residual_J: r)
        }
    }

    // ── Maintenance ─────────────────────────────────────────────────────────

    // ── Graph series ────────────────────────────────────────────────────────

    public struct SeriesPoint {
        public let time: Date
        /// Whole-system watts over the bucket.
        public let watts: Double
        /// True when every interval in the bucket was on battery. Mixed buckets
        /// read false, so a shaded "on battery" region never over-claims.
        public let onBattery: Bool
        /// Mean state of charge over the bucket, when any interval recorded one.
        public let socPercent: Double?
    }

    /// Whole-system power over an arbitrary range, bucketed to at most
    /// `maxPoints` rows.
    ///
    /// Bucketing happens in SQL rather than in Swift because the point of a 7-day
    /// range is NOT to hand the graph 300,000 rows and let it throw them away: at
    /// one row per two seconds a week is a quarter of a million intervals, and
    /// materialising that to draw 900 pixels would cost more than every other
    /// query in the app combined. The bucket width is derived from the requested
    /// span, so the cost of a 7-day query and a 1-hour query is the same.
    public func powerSeries(since: Date, until: Date = Date(),
                            maxPoints: Int = 600) -> [SeriesPoint] {
        let from = since.timeIntervalSince1970
        let to = until.timeIntervalSince1970
        guard to > from, maxPoints > 0 else { return [] }
        let width = max((to - from) / Double(maxPoints), 1)

        return queue.sync {
            // Energy and duration are SUMMED per bucket and divided once, so the
            // result is energy-weighted. Averaging per-interval watts would weight
            // a 0.1 s tick the same as a 60 s bucket and skew every mixed range.
            guard let st = prepare("""
                SELECT CAST((ts - ?) / ? AS INTEGER) AS b,
                       MIN(ts), SUM(measured_j), SUM(dur), MIN(on_battery),
                       CASE WHEN SUM(CASE WHEN soc IS NULL THEN 0 ELSE dur END) > 0
                            THEN SUM(COALESCE(soc,0)*dur) / SUM(CASE WHEN soc IS NULL THEN 0 ELSE dur END)
                            ELSE NULL END
                  FROM interval
                 WHERE ts >= ? AND ts <= ? AND measured_j IS NOT NULL
                   AND dur > 0 AND dur <= \(Self.maxPlausibleInterval)
                   AND measured_j >= 0
                   AND measured_j / dur <= 200.0
                 GROUP BY b
                 ORDER BY b
                """) else { return [] }
            defer { sqlite3_finalize(st) }
            sqlite3_bind_double(st, 1, from)
            sqlite3_bind_double(st, 2, width)
            sqlite3_bind_double(st, 3, from)
            sqlite3_bind_double(st, 4, to)

            var out: [SeriesPoint] = []
            while sqlite3_step(st) == SQLITE_ROW {
                let ts = sqlite3_column_double(st, 1)
                let joules = sqlite3_column_double(st, 2)
                let dur = sqlite3_column_double(st, 3)
                guard dur > 0 else { continue }
                let soc: Double? = sqlite3_column_type(st, 5) == SQLITE_NULL
                    ? nil : sqlite3_column_double(st, 5)
                out.append(SeriesPoint(time: Date(timeIntervalSince1970: ts),
                                       watts: joules / dur,
                                       onBattery: sqlite3_column_int(st, 4) == 1,
                                       socPercent: soc))
            }
            return out
        }
    }

    /// Oldest retained sample, so the UI can offer only ranges that have data
    /// rather than showing an empty 7-day plot on a first run.
    public func earliestSample() -> Date? {
        queue.sync { () -> Date? in
            guard let st = prepare("SELECT MIN(ts) FROM interval") else { return nil }
            defer { sqlite3_finalize(st) }
            guard sqlite3_step(st) == SQLITE_ROW,
                  sqlite3_column_type(st, 0) != SQLITE_NULL else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(st, 0))
        }
    }

    /// Drop everything older than the horizon, then actually give the pages back
    /// (incremental_vacuum) and truncate the WAL so `sizeOnDisk` tells the truth.
    public func prune(olderThan days: Double = 7) {
        guard days > 0 else { return }
        queue.sync {
            let cutoff = Date().timeIntervalSince1970 - days * 86400
            exec("BEGIN IMMEDIATE")
            exec("DELETE FROM app_energy WHERE interval_id IN (SELECT id FROM interval WHERE ts < \(cutoff))")
            exec("DELETE FROM interval WHERE ts < \(cutoff)")
            exec("COMMIT")
            exec("PRAGMA incremental_vacuum")
            exec("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    /// Merge raw ticks older than `rawHorizon` into `bucketWidth` buckets,
    /// preserving total joules exactly and never mixing battery with AC time.
    /// Runs automatically from record(); public so tests and a manual "compact
    /// now" can force it.
    public func downsample() {
        queue.sync { downsampleLocked() }
    }

    private func downsampleLocked() {
        // Align the cutoff to a bucket edge so a bucket is only ever built from
        // minutes wholly inside the compaction region — a later run can still
        // land in the same bucket (late rows after a sleep), which is why the
        // insert is an UPSERT against the partial unique index, not a plain insert.
        let bw = bucketWidth
        let cutoff = (Date().timeIntervalSince1970 - rawHorizon)
            .rounded(.down)
        let aligned = (cutoff / bw).rounded(.down) * bw

        exec("BEGIN IMMEDIATE")
        // 1. Fold raw system rows into bucket rows. SUM() skips NULLs and only
        //    returns NULL when every input is NULL — exactly the "unmeasured
        //    stays unmeasured" semantics we want. The CASE in the upsert keeps it.
        let foldedIntervals = exec("""
            INSERT INTO interval(ts, dur, on_battery, agg, measured_j, attributed_j, residual_j, soc)
            SELECT CAST(ts/\(bw) AS INTEGER)*\(bw), SUM(dur), on_battery, 1,
                   SUM(measured_j), SUM(attributed_j), SUM(residual_j),
                   -- Duration-weighted, not AVG(soc): the rows folded into one
                   -- bucket have different durations, so a plain mean would let a
                   -- 0.8 s tick pull as hard as a 60 s one.
                   CASE WHEN SUM(CASE WHEN soc IS NULL THEN 0 ELSE dur END) > 0
                        THEN SUM(COALESCE(soc,0)*dur) / SUM(CASE WHEN soc IS NULL THEN 0 ELSE dur END)
                        ELSE NULL END
            FROM interval WHERE agg=0 AND ts < \(aligned)
              -- Poisoned rows are excluded from the fold and then deleted with the
              -- rest below, rather than being summed into a bucket: one 32,400 s
              -- row would push its bucket past the read filter and take that
              -- minute's genuine samples out of the window with it.
              AND dur <= \(Self.maxPlausibleInterval)
            GROUP BY CAST(ts/\(bw) AS INTEGER), on_battery
            ON CONFLICT(ts, on_battery) WHERE agg=1 DO UPDATE SET
                -- soc BEFORE dur: the re-weighting below divides by the OLD dur,
                -- so updating dur first would weight the existing value against a
                -- total that already includes the incoming rows.
                soc = CASE WHEN soc IS NULL AND excluded.soc IS NULL THEN NULL
                      WHEN soc IS NULL THEN excluded.soc
                      WHEN excluded.soc IS NULL THEN soc
                      ELSE (soc*dur + excluded.soc*excluded.dur) / (dur + excluded.dur) END,
                dur = dur + excluded.dur,
                measured_j = CASE WHEN measured_j IS NULL AND excluded.measured_j IS NULL
                             THEN NULL ELSE COALESCE(measured_j,0)+COALESCE(excluded.measured_j,0) END,
                attributed_j = CASE WHEN attributed_j IS NULL AND excluded.attributed_j IS NULL
                             THEN NULL ELSE COALESCE(attributed_j,0)+COALESCE(excluded.attributed_j,0) END,
                residual_j = CASE WHEN residual_j IS NULL AND excluded.residual_j IS NULL
                             THEN NULL ELSE COALESCE(residual_j,0)+COALESCE(excluded.residual_j,0) END
            """)
        // 2. Re-point app rows at their bucket, summing per app. The unique
        //    bucket index guarantees the join matches exactly one target row.
        let foldedApps = exec("""
            INSERT INTO app_energy(interval_id, app, name, joules)
            SELECT n.id, a.app, MAX(a.name), SUM(a.joules)
            FROM app_energy a
            JOIN interval o ON o.id = a.interval_id
            JOIN interval n ON n.agg=1 AND n.on_battery = o.on_battery
                           AND n.ts = CAST(o.ts/\(bw) AS INTEGER)*\(bw)
            WHERE o.agg=0 AND o.ts < \(aligned) AND o.dur <= \(Self.maxPlausibleInterval)
            GROUP BY n.id, a.app
            ON CONFLICT(interval_id, app) DO UPDATE SET
                joules = joules + excluded.joules, name = excluded.name
            """)
        // 3. Only when BOTH folds succeeded may the raw rows go — otherwise a
        //    disk-full mid-compaction would delete energy that was never folded.
        //    ROLLBACK keeps the raw rows; the next compaction simply retries.
        guard foldedIntervals && foldedApps else { exec("ROLLBACK"); return }
        exec("DELETE FROM app_energy WHERE interval_id IN (SELECT id FROM interval WHERE agg=0 AND ts < \(aligned))")
        exec("DELETE FROM interval WHERE agg=0 AND ts < \(aligned)")
        exec("COMMIT")
        exec("PRAGMA incremental_vacuum")
    }

    /// Database + WAL + SHM, because until a checkpoint most of the data IS the WAL.
    public var sizeOnDisk: Int64 {
        queue.sync {
            var total: Int64 = 0
            for suffix in ["", "-wal", "-shm"] {
                let p = fileURL.path + suffix
                if let attrs = try? FileManager.default.attributesOfItem(atPath: p),
                   let n = attrs[.size] as? NSNumber {
                    total += n.int64Value
                }
            }
            return total
        }
    }

    /// Row counts for the debug view and the volume test. Cheap (index-only).
    public func stats() -> (intervals: Int, rawIntervals: Int, appRows: Int) {
        queue.sync {
            func count(_ sql: String) -> Int {
                guard let s = prepare(sql) else { return 0 }
                defer { sqlite3_finalize(s) }
                return sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int64(s, 0)) : 0
            }
            return (count("SELECT COUNT(*) FROM interval"),
                    count("SELECT COUNT(*) FROM interval WHERE agg=0"),
                    count("SELECT COUNT(*) FROM app_energy"))
        }
    }

    // ── Plumbing ────────────────────────────────────────────────────────────

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return nil }
        return s
    }

    private func columnOptionalDouble(_ stmt: OpaquePointer?, _ idx: Int32) -> Double? {
        sqlite3_column_type(stmt, idx) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, idx)
    }
}

// The memberwise inits of AppIdentity/AppDrain are internal (Swift default), but
// the store's callers and tests need to construct rows outside the sweep pipeline
// (seeding history, replaying imports). Public inits via extension keep the
// original files untouched.
public extension AppIdentity {
    init(name: String, bundleID: String?, bundlePath: String? = nil, isApp: Bool) {
        self.init(name: name, bundlePath: bundlePath, bundleID: bundleID, isApp: isApp)
    }
}

public extension AppDrain {
    /// A row reconstructed outside the live sweep (history seeding, tests).
    /// Only identity and joules matter to the store; watts is derived and
    /// percentPerHour is deliberately 0 because no BatteryScale is in scope
    /// here — computing it would require inventing one.
    init(identity: AppIdentity, joules: Double, over interval: TimeInterval) {
        // Historical rows carry energy only. CPU, memory and disk are live-sample
        // quantities that were never persisted, so they are zero here rather than
        // reconstructed — inventing them would be worse than admitting the gap.
        self.init(identity: identity, joules: joules,
                  watts: interval > 0 ? joules / interval : 0,
                  percentPerHour: 0, processCount: 1, pids: [],
                  cpuPercent: 0, memoryBytes: 0, diskBytesPerSec: 0)
    }
}

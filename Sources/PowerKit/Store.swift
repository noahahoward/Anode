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

    /// Where the retention horizon comes from, and whether this store trims
    /// itself at all.
    ///
    /// The store maintains ITSELF rather than exposing a prune the app is
    /// expected to remember to call, because that is exactly what shipped:
    /// `prune` existed, `historyRetentionDays` existed, the Preferences caption
    /// promised it worked, and no call site was ever written. A store that
    /// schedules its own retention has no call site left to forget.
    public enum Retention {
        /// Follow `Settings.historyRetentionDays` live, re-scheduling when the
        /// user changes it. The app's path.
        case follow(Settings)
        /// A fixed horizon with no observation.
        case fixed(days: Double)
        /// Never prune on a timer; `prune()` still works when called.
        case manual
    }

    // Maintenance tuning. Internal rather than private so tests can compress the
    // schedule and shrink the chunk without waiting an hour or writing 100k rows.
    //
    /// Interval rows per delete transaction. MEASURED on this machine against a
    /// store shaped like a real one (1 min buckets, 20 app rows each): 400 rows
    /// plus their ~8,000 app rows commits in 12 ms, and the worst record() stall
    /// observed while a pass ran was 14 ms — under 1% of a 2 s tick, so a tick
    /// that lands mid-chunk is late, not dropped. 2,000-row chunks measured
    /// 58 ms, which is the same work at 5x the blast radius for no gain.
    var chunkRows = 400
    /// Idle between chunks. record() blocks on the store's serial queue every
    /// tick and the sampler now DROPS a tick it cannot start, so a stalled queue
    /// is a lost measurement rather than a late one. This gap is what makes the
    /// prune interruptible: at 12 ms of work per 250 ms it occupies under 5% of
    /// the queue while a backlog clears.
    var chunkGap: TimeInterval = 0.25
    /// Chunks per pass. A backlog larger than this (a store that ran for months
    /// unpruned, or 365 -> 7) clears over the following passes instead of in one
    /// 20-minute burst of disk writes — the failure mode that got this app killed
    /// by macOS once already.
    var maxChunksPerPass = 200
    /// Free pages handed back per chunk. Unbounded `incremental_vacuum` after a
    /// large delete moves every free page in the file in a single call, holding
    /// the queue record() lands on for as long as that takes.
    var vacuumPagesPerChunk = 64
    /// Between passes. Retention is measured in days, so an hour of slack past
    /// the horizon costs nothing and 24 wakeups a day is cheap.
    var passInterval: TimeInterval = 3600
    /// Before the first pass. Launch is the busiest the app ever is — window
    /// building, first sweep, first telemetry batch — and a backlog prune there
    /// competes for the same serial queue as the first samples.
    var firstPassDelay: TimeInterval = 300
    /// After a retention change. Long enough that dragging the stepper from 365
    /// to 7 (one write per step, every one of them on the main thread) coalesces
    /// into a single pass once the drag stops.
    var retentionChangeDelay: TimeInterval = 60

    private var db: OpaquePointer?
    /// All SQLite access is serialized here. record() arrives from the sampler's
    /// background queue; windowPower() from wherever the UI asks. One connection,
    /// one queue — no cross-thread SQLite, no locking subtleties.
    private let queue = DispatchQueue(label: "Anode.HistoryStore")
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

    /// Retention horizon, and whether this store trims itself at all.
    private let retention: Retention
    private var retentionObserver: AnyObject?
    /// Maintenance runs HERE, never on `queue` directly and never on main.
    /// Chunks hop onto `queue` one at a time and let go in between; the gap is
    /// what keeps record() off the back of a long delete.
    private let maintenanceQueue = DispatchQueue(label: "Anode.HistoryStore.maintenance",
                                                 qos: .utility)
    /// Timer and generation are touched ONLY from `maintenanceQueue`.
    private var maintenanceTimer: DispatchSourceTimer?
    private var passGeneration = 0
    private let scheduleLock = NSLock()
    private var scheduledPrune: Date?

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // ── The interval row's measured columns ─────────────────────────────────

    /// How compaction carries one column from raw ticks into a bucket.
    enum Fold {
        /// Energies. They are quantities the interval ACCUMULATED, so they add
        /// exactly and SUM is not an approximation of anything.
        case additive
        /// Levels and rates — state of charge, utilisation, throughput. A mean
        /// weighted by the duration of the rows that actually measured the
        /// column, so a 0.8 s tick cannot pull as hard as a 60 s one and a row
        /// that never measured it cannot dilute the rows that did.
        case durationWeighted
    }

    /// Every measured column on `interval`, in the order the write path binds
    /// them and the fold reads them.
    ///
    /// WHY THIS IS A LIST RATHER THAN SQL SPELLED OUT THREE TIMES: `soc` was
    /// added to the schema and to the write path and NOT to `downsampleLocked`'s
    /// INSERT, so every state-of-charge sample older than the raw horizon was
    /// folded to NULL — for weeks, silently, with every query still succeeding.
    /// One column made that a coin flip; eleven make it a near certainty. The
    /// INSERT, the fold and the upsert are all generated from this enum, so a
    /// column can only be half-handled by being missing from `allCases`, and
    /// `StoreCompactionTests.testEveryMeasuredColumnSurvivesCompaction` reads the
    /// column list back out of the SCHEMA rather than from here, so leaving one
    /// out fails a test instead of losing data quietly.
    enum Column: String, CaseIterable {
        case measured_j, attributed_j, residual_j
        case soc
        case cpu_pct, mem_pct, gpu_pct
        case net_in_bps, net_out_bps
        case disk_read_bps, disk_write_bps

        var fold: Fold {
            switch self {
            case .measured_j, .attributed_j, .residual_j: return .additive
            default: return .durationWeighted
            }
        }

        /// Columns the original schema shipped with. Everything else is added by
        /// an ALTER TABLE at open time, because CREATE TABLE IF NOT EXISTS does
        /// nothing to a table that already exists.
        static let original: Set<Column> = [.measured_j, .attributed_j, .residual_j]
    }

    /// Take over the history the app kept when it was called BetterStats.
    ///
    /// The rename moved this file. Left alone, the app would open a new empty
    /// store beside a full one and the graphs would say the machine had no past —
    /// which is not a small loss here, since the whole point of this store is that
    /// it goes back further than the session does.
    ///
    /// MOVED, not copied, and only when there is nothing at the new path. Copying
    /// would duplicate a store that is already hundreds of megabytes, and moving
    /// is safe because the old build is gone by the time this runs. The guard
    /// means running it twice does nothing and it can never overwrite history
    /// recorded since the rename.
    ///
    /// SQLite's sidecars come too. A `-wal` holds committed transactions that are
    /// not yet in the main file, so moving the database and leaving them behind
    /// silently drops the most recent writes — the exact rows a user would look
    /// for first.
    static func adoptPreviousName(at destination: URL, under base: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { return }
        let old = base.appendingPathComponent("BetterStats/history.sqlite")
        guard fm.fileExists(atPath: old.path) else { return }
        try? fm.createDirectory(at: destination.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: old.path + suffix)
            let to = URL(fileURLWithPath: destination.path + suffix)
            guard fm.fileExists(atPath: from.path) else { continue }
            try? fm.moveItem(at: from, to: to)
        }
        // Anything else the old directory held — the discharge trend, for one —
        // moves with it rather than being left for nobody to read.
        let oldDir = old.deletingLastPathComponent()
        let newDir = destination.deletingLastPathComponent()
        for name in (try? fm.contentsOfDirectory(atPath: oldDir.path)) ?? [] {
            let to = newDir.appendingPathComponent(name)
            guard !fm.fileExists(atPath: to.path) else { continue }
            try? fm.moveItem(at: oldDir.appendingPathComponent(name), to: to)
        }
    }

    /// A duration-weighted mean of `col` over only the rows that measured it.
    /// Used by the fold and by every read that buckets rows, so the value the
    /// graph draws is computed the same way whether it came from raw ticks or
    /// from a bucket that folded them.
    static func weightedMean(_ col: String) -> String {
        """
        CASE WHEN SUM(CASE WHEN \(col) IS NULL THEN 0 ELSE dur END) > 0
             THEN SUM(COALESCE(\(col),0)*dur) / SUM(CASE WHEN \(col) IS NULL THEN 0 ELSE dur END)
             ELSE NULL END
        """
    }

    /// One column's value when a group of raw rows becomes a bucket.
    private static func foldSelect(_ c: Column) -> String {
        switch c.fold {
        // SUM() skips NULLs and returns NULL only when every input is NULL —
        // exactly the "unmeasured stays unmeasured" semantics we want.
        case .additive: return "SUM(\(c.rawValue))"
        case .durationWeighted: return weightedMean(c.rawValue)
        }
    }

    /// One column's value when the fold lands in a bucket that already exists
    /// (late rows after a sleep, or a re-run of compaction).
    private static func foldUpsert(_ c: Column) -> String {
        let n = c.rawValue
        switch c.fold {
        case .additive:
            return """
            \(n) = CASE WHEN \(n) IS NULL AND excluded.\(n) IS NULL
                        THEN NULL ELSE COALESCE(\(n),0)+COALESCE(excluded.\(n),0) END
            """
        case .durationWeighted:
            return """
            \(n) = CASE WHEN \(n) IS NULL AND excluded.\(n) IS NULL THEN NULL
                        WHEN \(n) IS NULL THEN excluded.\(n)
                        WHEN excluded.\(n) IS NULL THEN \(n)
                        ELSE (\(n)*dur + excluded.\(n)*excluded.dur) / (dur + excluded.dur) END
            """
        }
    }

    public init?(path: URL? = nil,
                 rawHorizon: TimeInterval = 3600,
                 bucketWidth: TimeInterval = 60,
                 retention: Retention = .follow(.shared)) {
        self.retention = retention
        let url: URL
        if let p = path {
            url = p
        } else {
            guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                      in: .userDomainMask).first else { return nil }
            url = base.appendingPathComponent("Anode/history.sqlite")
            HistoryStore.adoptPreviousName(at: url, under: base)
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
            soc         REAL,
            -- Whole-machine utilisation, one column per lens that draws a line.
            -- Levels and rates rather than accumulated quantities, so they fold
            -- duration-weighted (see Column.fold). NULL is load-bearing: the app
            -- skips subsystems nobody is displaying, and a night with the window
            -- shut is a night nobody read the GPU — not a night it was idle.
            --
            -- Per-machine, never per-process. Per-process history was measured
            -- once: it drove 2.1 GB of writes in 40 minutes and macOS killed the
            -- app for exceeding its sustained rate.
            cpu_pct     REAL,
            mem_pct     REAL,
            gpu_pct     REAL,
            net_in_bps  REAL,
            net_out_bps REAL,
            disk_read_bps  REAL,
            disk_write_bps REAL
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
        //
        // Driven off `Column.allCases` for the same reason the fold is: the next
        // column added to the enum migrates an existing store without anybody
        // remembering to write a line here. Existing rows get NULL, which is the
        // truth about them — nothing measured a CPU percentage in March.
        for c in Column.allCases where !Column.original.contains(c) {
            sqlite3_exec(h, "ALTER TABLE interval ADD COLUMN \(c.rawValue) REAL", nil, nil, nil)
        }

        let cols = Column.allCases
        insInterval = prepare("""
            INSERT INTO interval(ts, dur, on_battery, agg, \(cols.map(\.rawValue).joined(separator: ", ")))
            VALUES(?,?,?,0,\(cols.map { _ in "?" }.joined(separator: ",")))
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
        startMaintenance()
    }

    deinit {
        // An active dispatch source is only torn down by cancel(); dropping the
        // last reference leaks a timer that goes on waking the CPU forever, which
        // in a battery-measuring app is its own small lie.
        maintenanceTimer?.cancel()
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

    /// The non-power readings recorded beside the ledger: how BUSY the machine
    /// was, never how much battery that cost — the two are kept apart everywhere
    /// (see `SystemMetrics`), and joining them here would be the first place they
    /// blurred.
    ///
    /// Every field is optional and nil means NOT MEASURED. It is stored as NULL,
    /// folded as NULL, read back as nil and drawn as a break in the line. The app
    /// deliberately skips subsystems nobody is displaying (`SystemMetrics.Needs`),
    /// so a night with the window closed is a night nobody read the GPU — and a
    /// GPU line at 0% across it would be the same lie as telling a two-fan
    /// machine it has no fans.
    public struct Utilization {
        /// 0…100 across all cores combined, as `CPUUsage.Sample.total`.
        public var cpuPercent: Double?
        /// 0…100 of physical memory, Activity Monitor's "Memory Used" basis.
        public var memoryPercent: Double?
        /// 0…100 device utilisation. Utilisation, NOT power.
        public var gpuPercent: Double?
        public var networkInBytesPerSec: Double?
        public var networkOutBytesPerSec: Double?
        /// Bytes per second, not a percentage — there is no honest disk
        /// utilisation on this hardware (see `DiskActivity`).
        public var diskReadBytesPerSec: Double?
        public var diskWriteBytesPerSec: Double?

        public init(cpuPercent: Double? = nil, memoryPercent: Double? = nil,
                    gpuPercent: Double? = nil,
                    networkInBytesPerSec: Double? = nil, networkOutBytesPerSec: Double? = nil,
                    diskReadBytesPerSec: Double? = nil, diskWriteBytesPerSec: Double? = nil) {
            self.cpuPercent = cpuPercent
            self.memoryPercent = memoryPercent
            self.gpuPercent = gpuPercent
            self.networkInBytesPerSec = networkInBytesPerSec
            self.networkOutBytesPerSec = networkOutBytesPerSec
            self.diskReadBytesPerSec = diskReadBytesPerSec
            self.diskWriteBytesPerSec = diskWriteBytesPerSec
        }

        /// Nothing measured — the default, so a caller recording only energy
        /// stores seven honest NULLs instead of seven zeros.
        public static let none = Utilization()

        /// What one sample of `SystemMetrics` has to say. A subsystem the sweep
        /// skipped arrives here as nil and stays nil; nothing is defaulted.
        public init(_ s: SystemMetrics.Snapshot) {
            self.init(cpuPercent: s.cpu?.total,
                      memoryPercent: s.memory.map(\.usedPercent),
                      gpuPercent: s.gpu?.utilization,
                      networkInBytesPerSec: s.network?.bytesInPerSec,
                      networkOutBytesPerSec: s.network?.bytesOutPerSec,
                      diskReadBytesPerSec: s.disk?.bytesReadPerSec,
                      diskWriteBytesPerSec: s.disk?.bytesWrittenPerSec)
        }
    }

    public func record(apps: [AppDrain], measured_W: Double?, attributed_W: Double?,
                       residual_W: Double?, onBattery: Bool,
                       socPercent: Double? = nil,
                       utilization: Utilization = .none,
                       interval: TimeInterval,
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
            // Bound in `Column.allCases` order, which is the order the statement
            // was prepared in — one list, so a new column cannot reach the
            // schema and miss the write path.
            for (i, c) in Column.allCases.enumerated() {
                let idx = Int32(4 + i)
                if let v = Self.storedValue(c, measured_W: measured_W,
                                            attributed_W: attributed_W,
                                            residual_W: residual_W,
                                            socPercent: socPercent,
                                            utilization: utilization,
                                            interval: interval) {
                    sqlite3_bind_double(insI, idx, v)
                } else {
                    sqlite3_bind_null(insI, idx)
                }
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

    /// What goes in one column for this interval, or nil for NULL.
    ///
    /// One exhaustive switch, so adding a case to `Column` is a compile error
    /// until the value it stores has been named. Every branch validates: a
    /// reading that cannot be true is stored as NULL rather than as itself,
    /// because a single implausible row silently dominates every SUM and every
    /// axis it lands in — four stored buckets once held measured_j around 1.8e16.
    private static func storedValue(_ c: Column,
                                    measured_W: Double?, attributed_W: Double?,
                                    residual_W: Double?, socPercent: Double?,
                                    utilization: Utilization,
                                    interval: TimeInterval) -> Double? {
        // isFinite is not enough: a wrapped counter is a perfectly finite,
        // perfectly enormous number, and that is exactly what reached the disk.
        func joules(_ watts: Double?) -> Double? {
            guard let w = watts, w.isFinite, w >= 0, w <= maxPlausibleWatts else { return nil }
            return w * interval
        }
        // Levels are stored AS THEY ARE, never multiplied by the interval: a
        // percentage is not a quantity the interval accumulated. `dur` is what
        // weights them when a bucket averages several rows.
        func percent(_ v: Double?) -> Double? {
            guard let v, v.isFinite, v >= 0, v <= 100 else { return nil }
            return v
        }
        func rate(_ v: Double?, _ ceiling: Double) -> Double? {
            guard let v, v.isFinite, v >= 0, v <= ceiling else { return nil }
            return v
        }
        switch c {
        case .measured_j:   return joules(measured_W)
        case .attributed_j: return joules(attributed_W)
        case .residual_j:   return joules(residual_W)
        case .soc:          return percent(socPercent)
        case .cpu_pct:      return percent(utilization.cpuPercent)
        case .mem_pct:      return percent(utilization.memoryPercent)
        case .gpu_pct:      return percent(utilization.gpuPercent)
        // The same ceilings the live samplers already reject against, so a
        // counter doing something unexplained becomes a missing point rather
        // than a headline number — on the graph as well as in the sidebar.
        case .net_in_bps:   return rate(utilization.networkInBytesPerSec,
                                        NetworkThroughput.maxPlausibleBytesPerSec)
        case .net_out_bps:  return rate(utilization.networkOutBytesPerSec,
                                        NetworkThroughput.maxPlausibleBytesPerSec)
        case .disk_read_bps:  return rate(utilization.diskReadBytesPerSec,
                                          DiskActivity.maxPlausibleBytesPerSec)
        case .disk_write_bps: return rate(utilization.diskWriteBytesPerSec,
                                          DiskActivity.maxPlausibleBytesPerSec)
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
                       -- The same weighting the fold uses, so a bucket built by
                       -- compaction and a bucket built here from raw ticks give
                       -- the same number for the same seconds.
                       \(Self.weightedMean("soc"))
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

    /// One bucket of whole-machine utilisation. Every field is independently
    /// optional: the app samples only what something is displaying, so a bucket
    /// can hold a CPU percentage and no GPU percentage, and the two must not be
    /// forced to share a fate.
    public struct UtilizationPoint {
        public let time: Date
        public let cpuPercent: Double?
        public let memoryPercent: Double?
        public let gpuPercent: Double?
        public let networkInBytesPerSec: Double?
        public let networkOutBytesPerSec: Double?
        public let diskReadBytesPerSec: Double?
        public let diskWriteBytesPerSec: Double?
    }

    /// Whole-machine utilisation over an arbitrary range, bucketed to at most
    /// `maxPoints` rows — the CPU/memory/GPU/network/disk equivalent of
    /// `powerSeries`, and bucketed in SQL for the same reason: a week is a
    /// quarter of a million rows and the graph has ~900 pixels.
    ///
    /// A bucket where nothing measured ANY of these is not returned at all. That
    /// absence is the point: it is how "the window was shut and nobody was
    /// looking" reaches the screen as a break in the line instead of a run of
    /// zeros. Per-field NULLs survive for the same reason one step down.
    public func utilizationSeries(since: Date, until: Date = Date(),
                                  maxPoints: Int = 600) -> [UtilizationPoint] {
        let from = since.timeIntervalSince1970
        let to = until.timeIntervalSince1970
        guard to > from, maxPoints > 0 else { return [] }
        let width = max((to - from) / Double(maxPoints), 1)

        // The utilisation columns only, in a fixed order this function then reads
        // back by index.
        let cols: [Column] = [.cpu_pct, .mem_pct, .gpu_pct,
                              .net_in_bps, .net_out_bps, .disk_read_bps, .disk_write_bps]

        return queue.sync {
            guard let st = prepare("""
                SELECT CAST((ts - ?) / ? AS INTEGER) AS b, MIN(ts),
                       \(cols.map { Self.weightedMean($0.rawValue) }.joined(separator: ",\n                       "))
                  FROM interval
                 WHERE ts >= ? AND ts <= ?
                   -- The same duration filter the power graph carries. A row
                   -- written across a nine-hour sleep is not a nine-hour
                   -- measurement, and a store on disk may already hold one from
                   -- before the sampler learned to drop them.
                   AND dur > 0 AND dur <= \(Self.maxPlausibleInterval)
                 GROUP BY b
                 ORDER BY b
                """) else { return [] }
            defer { sqlite3_finalize(st) }
            sqlite3_bind_double(st, 1, from)
            sqlite3_bind_double(st, 2, width)
            sqlite3_bind_double(st, 3, from)
            sqlite3_bind_double(st, 4, to)

            var out: [UtilizationPoint] = []
            while sqlite3_step(st) == SQLITE_ROW {
                let v = (0..<cols.count).map { columnOptionalDouble(st, Int32(2 + $0)) }
                // Nothing measured in this bucket: emit no point rather than a
                // point made of seven nils, which every caller would have to
                // filter anyway and one of them would forget to.
                guard v.contains(where: { $0 != nil }) else { continue }
                out.append(UtilizationPoint(
                    time: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)),
                    cpuPercent: v[0], memoryPercent: v[1], gpuPercent: v[2],
                    networkInBytesPerSec: v[3], networkOutBytesPerSec: v[4],
                    diskReadBytesPerSec: v[5], diskWriteBytesPerSec: v[6]))
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

    // ── Retention ───────────────────────────────────────────────────────────

    /// When the next maintenance pass is due, or nil for a store that does not
    /// maintain itself. Exists so "a retention change SCHEDULES a prune" is an
    /// assertable claim rather than a comment.
    public var nextScheduledPrune: Date? {
        scheduleLock.lock(); defer { scheduleLock.unlock() }
        return scheduledPrune
    }

    private func startMaintenance() {
        if case .manual = retention { return }
        if case .follow(let settings) = retention {
            // A retention DECREASE must SCHEDULE, never perform. Dragging the
            // stepper 365 -> 7 writes once per step, on the main thread, and
            // pruning here would run a several-hundred-thousand-row delete inside
            // the drag. Re-arming also debounces: the pass lands once, after the
            // user has stopped.
            retentionObserver = settings.observe(Settings.Key.historyRetentionDays) { [weak self] in
                guard let self else { return }
                self.schedulePass(after: self.retentionChangeDelay)
            }
        }
        schedulePass(after: firstPassDelay)
    }

    /// (Re)arm the maintenance timer. A later call supersedes an earlier one —
    /// including one made from inside a running pass, which is how a settings
    /// change coalesces instead of stacking passes on top of each other.
    private func schedulePass(after delay: TimeInterval) {
        maintenanceQueue.async { [weak self] in
            guard let self else { return }
            self.passGeneration &+= 1
            let generation = self.passGeneration
            self.maintenanceTimer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: self.maintenanceQueue)
            // Leeway is deliberately a tenth of the delay. Nothing here is
            // time-critical to the second, and a wakeup the system can coalesce
            // with one it was taking anyway is a wakeup this app does not spend.
            t.schedule(deadline: .now() + delay, leeway: .milliseconds(Int(delay * 100)))
            t.setEventHandler { [weak self] in self?.beginPass(generation) }
            self.maintenanceTimer = t
            self.scheduleLock.lock()
            self.scheduledPrune = Date().addingTimeInterval(delay)
            self.scheduleLock.unlock()
            t.resume()
        }
    }

    private func beginPass(_ generation: Int) {
        let days: Double
        switch retention {
        case .follow(let settings): days = settings.historyRetentionDays
        case .fixed(let d): days = d
        case .manual: return
        }
        guard days > 0 else { schedulePass(after: passInterval); return }
        // ONE cutoff for the whole pass. Recomputing it per chunk moves the target
        // while the loop walks toward it, which is how a chunked delete loses its
        // proof of termination.
        step(generation: generation,
             cutoff: Date().timeIntervalSince1970 - days * 86400,
             chunksLeft: maxChunksPerPass, removedSoFar: 0)
    }

    private func step(generation: Int, cutoff: Double, chunksLeft: Int, removedSoFar: Int) {
        guard generation == passGeneration else { return }   // superseded mid-pass
        let removed = queue.sync { pruneChunkLocked(cutoff: cutoff) }
        let total = removedSoFar + removed
        // Short of the LIMIT means the SELECT was exhausted, so there is nothing
        // left inside this pass's cutoff and a confirming empty chunk would only
        // be another transaction.
        if removed >= chunkRows, chunksLeft > 1 {
            maintenanceQueue.asyncAfter(deadline: .now() + chunkGap) { [weak self] in
                self?.step(generation: generation, cutoff: cutoff,
                           chunksLeft: chunksLeft - 1, removedSoFar: total)
            }
            return
        }
        if total > 0 {
            // Once per pass, not per chunk: TRUNCATE rewrites and shortens the
            // WAL, and it is the single largest write the prune makes.
            queue.sync { exec("PRAGMA wal_checkpoint(TRUNCATE)") }
        }
        schedulePass(after: passInterval)
    }

    /// One chunk in isolation, for tests: the maintenance loop's unit of work.
    @discardableResult
    func pruneChunk(olderThan days: Double) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = Date().timeIntervalSince1970 - days * 86400
        return queue.sync { pruneChunkLocked(cutoff: cutoff) }
    }

    /// Delete at most `chunkRows` intervals older than the cutoff, with their app
    /// rows. Returns how many interval rows went, so the caller can tell "more to
    /// do" from "done" without a second query.
    private func pruneChunkLocked(cutoff: Double) -> Int {
        // A bucket's ts is its START and it covers bucketWidth of wall clock, so
        // a bucket straddling the cutoff still holds time INSIDE retention.
        // Deleting on ts alone would take that time with it — a quieter bug than
        // "history grows forever", and just as wrong.
        let bucketCutoff = cutoff - bucketWidth
        exec("CREATE TEMP TABLE IF NOT EXISTS doomed(id INTEGER PRIMARY KEY)")
        exec("DELETE FROM doomed")
        exec("BEGIN IMMEDIATE")
        // Oldest first, and ordered by (ts, id) so the chunk is a prefix of
        // history rather than a scatter through it: an interrupted prune then
        // leaves a store that is short at the old end, which is what retention
        // means anyway.
        guard exec("""
            INSERT INTO doomed(id) SELECT id FROM interval
             WHERE ts < \(cutoff) AND (agg = 0 OR ts <= \(bucketCutoff))
             ORDER BY ts, id LIMIT \(chunkRows)
            """),
            // App rows go FIRST and in the SAME transaction as their intervals.
            // Split across two transactions, a crash in between leaves app_energy
            // rows whose interval_id matches nothing: unreachable by every query
            // in this file, never selected by a later prune, permanent.
            exec("DELETE FROM app_energy WHERE interval_id IN (SELECT id FROM doomed)"),
            exec("DELETE FROM interval WHERE id IN (SELECT id FROM doomed)")
        else {
            exec("ROLLBACK")
            return 0
        }
        let removed = Int(sqlite3_changes(db))
        exec("COMMIT")
        if removed > 0 { exec("PRAGMA incremental_vacuum(\(vacuumPagesPerChunk))") }
        return removed
    }

    /// Drop everything older than the horizon, then actually give the pages back
    /// (incremental_vacuum, inside each chunk) and truncate the WAL so
    /// `sizeOnDisk` tells the truth.
    ///
    /// BLOCKING: it holds the store queue for chunk after chunk with no gap, so
    /// the timer path deliberately does not use it. This is the explicit
    /// "prune now" form, and what tests drive.
    public func prune(olderThan days: Double = 7) {
        guard days > 0 else { return }
        // Termination: the cutoff is fixed before the first chunk, so the set of
        // matching rows is fixed too, and every full chunk removes `chunkRows` of
        // it. A chunk that comes back short hit the end of that set — or failed
        // and rolled back, which must also end the loop rather than retry forever.
        let cutoff = Date().timeIntervalSince1970 - days * 86400
        while queue.sync(execute: { pruneChunkLocked(cutoff: cutoff) }) >= chunkRows {}
        queue.sync { exec("PRAGMA wal_checkpoint(TRUNCATE)") }
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

        // EVERY measured column, generated from one list. Energies SUM (they add
        // exactly); levels and rates take a mean weighted by the duration of the
        // rows that measured them, not AVG(), because the rows folded into one
        // bucket have different durations and a plain mean would let a 0.8 s tick
        // pull as hard as a 60 s one. A column no row measured stays NULL —
        // "unmeasured stays unmeasured" — and the CASEs in the upsert keep it
        // that way when a later fold lands in the same bucket.
        let cols = Column.allCases
        let names = cols.map(\.rawValue).joined(separator: ", ")
        let folds = cols.map(Self.foldSelect).joined(separator: ",\n                   ")
        // The weighted columns come BEFORE dur: the re-weighting divides by the
        // OLD dur, so updating dur first would weight each existing value against
        // a total that already includes the incoming rows.
        let upserts = cols.map(Self.foldUpsert).joined(separator: ",\n                ")

        exec("BEGIN IMMEDIATE")
        // 1. Fold raw system rows into bucket rows.
        let foldedIntervals = exec("""
            INSERT INTO interval(ts, dur, on_battery, agg, \(names))
            SELECT CAST(ts/\(bw) AS INTEGER)*\(bw), SUM(dur), on_battery, 1,
                   \(folds)
            FROM interval WHERE agg=0 AND ts < \(aligned)
              -- Poisoned rows are excluded from the fold and then deleted with the
              -- rest below, rather than being summed into a bucket: one 32,400 s
              -- row would push its bucket past the read filter and take that
              -- minute's genuine samples out of the window with it.
              AND dur <= \(Self.maxPlausibleInterval)
            GROUP BY CAST(ts/\(bw) AS INTEGER), on_battery
            ON CONFLICT(ts, on_battery) WHERE agg=1 DO UPDATE SET
                \(upserts),
                dur = dur + excluded.dur
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
                  cpuPercent: 0, memoryBytes: 0, diskReadPerSec: 0, diskWrittenPerSec: 0)
    }
}

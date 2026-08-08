import Foundation

/// Puts names to the energy `proc_pid_rusage` cannot see.
///
/// rusage is same-uid only, so roughly a third of measured CPU power belongs to
/// processes we can measure in aggregate but not identify — WindowServer above
/// all, plus coreaudiod, airportd, bluetoothd, locationd. The ledger has always
/// shown that as a solid but anonymous bucket: "we know, but not whose."
///
/// Apple's own coalition rollup does see them. This class turns the anonymous
/// bucket into named rows without changing its total, so the ledger stays
/// conserving: the rows are a partition of a measured quantity, never an
/// addition to it.
///
/// The weight is deliberately NOT Apple's energy score. That score folds CPU,
/// GPU, wakeups and I/O into one unitless number, and the bucket being divided
/// here is specifically CPU-rail watts. Dividing measured CPU power by a weight
/// that partly reflects GPU work would misattribute in proportion to how
/// GPU-heavy an app is. CPU watts are split by CPU time and GPU watts by GPU
/// time, each by the quantity it actually is.
public final class SystemAttribution {

    /// One named share of a measured bucket. `isModeled` is always true: the
    /// total is measured, this row's slice of it is apportioned, and the
    /// distinction has to survive all the way to the UI.
    public struct Row {
        public let bundleID: String
        public let name: String
        public let watts: Double
        public let percentPerHour: Double
        public let cpu_ms: UInt64
        public let gpu_ms: UInt64
        public let isSystem: Bool
        public let isModeled: Bool = true
    }

    /// Which measured bucket a set of rows divides, and therefore which
    /// coalition counter is the correct weight for it.
    public enum Weight {
        case cpuTime
        case gpuTime
    }

    private let window: TimeInterval
    private let refreshInterval: TimeInterval

    private let lock = NSLock()
    private var cached: [CoalitionUsage] = []
    private var lastRefresh: Date?
    private var refreshing = false

    private let queue = DispatchQueue(label: "com.betterstats.systemattribution",
                                      qos: .utility)

    /// An hour, and the length is load-bearing rather than a round number.
    ///
    /// A coalition only contributes if two of its records can be differenced, or
    /// if it was born inside the window. Long-lived daemons emit rarely, so short
    /// windows drop them entirely — measured on this machine, the same instant
    /// yielded 2 coalitions at 5 minutes, 3 at 15, then 383 at 30 and 440 at 60.
    /// Below that cliff the result is not merely sparse but actively wrong:
    /// WindowServer vanished while Plexamp, which happened to emit twice, was
    /// handed 52% of the whole system-process bucket.
    ///
    /// The cost is that shares reflect the trailing hour rather than this instant,
    /// so a daemon that spikes now takes a while to show. That is the right trade:
    /// a lagging number that is roughly right beats a live one that is confidently
    /// wrong about which process is draining the battery.
    ///
    /// 120 s refresh, not 60: a 60 minute rollup costs ~0.2 s to spawn and ~0.2 s
    /// to parse, and 0.4 s per minute is 0.65% of a core spent by a tool whose
    /// entire premise is not costing what it measures. At 120 s the window still
    /// moves far faster than an hour of history changes.
    public init(window: TimeInterval = 3600, refreshInterval: TimeInterval = 120) {
        self.window = window
        self.refreshInterval = refreshInterval
    }

    public var isAvailable: Bool { SystemStats.isAvailable }

    /// Most recent rollup. Never blocks: returns whatever the last background
    /// refresh produced, or empty before the first one lands.
    public var latest: [CoalitionUsage] {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    public var age: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return lastRefresh.map { Date().timeIntervalSince($0) }
    }

    /// Kicks off a refresh if one is due. Safe to call every tick — it returns
    /// immediately and does the subprocess work on a utility queue, because
    /// `systemstats` takes ~0.2 s and this app must not cost what it measures.
    public func refreshIfNeeded() {
        lock.lock()
        let due = lastRefresh.map { Date().timeIntervalSince($0) >= refreshInterval } ?? true
        guard due, !refreshing, SystemStats.isAvailable else { lock.unlock(); return }
        refreshing = true
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let rows = SystemStats.usage(since: Date().addingTimeInterval(-self.window),
                                         timeout: 15)
            self.lock.lock()
            // A refresh that parsed nothing keeps the previous rollup rather than
            // blanking the table: an empty window is far more likely to mean the
            // subprocess was killed or the format drifted than that the machine
            // genuinely ran no coalitions for five minutes.
            if !rows.isEmpty {
                self.cached = rows
                self.lastRefresh = Date()
            } else {
                // Still stamp the attempt, or a persistently empty parse would
                // respawn the subprocess on every single tick.
                self.lastRefresh = Date()
            }
            self.refreshing = false
            self.lock.unlock()
        }
    }

    /// Identifiers for an app rusage already measured. Both forms are needed.
    ///
    /// Matching on bundle id alone silently fails for daemons — they live outside
    /// any bundle, so `AppIdentity.bundleID` is nil for them, which is precisely
    /// the population most likely to also appear in the coalition rollup. Observed
    /// live: `contactsd` was measured at 0.03 %/hr AND handed a modeled 0.04 %/hr,
    /// appearing twice in one table.
    ///
    /// Names are compared case-insensitively because the two sources derive them
    /// differently: rusage from the executable, the rollup from the last
    /// reverse-DNS component of the bundle id.
    public struct Attributed {
        public let bundleIDs: Set<String>
        public let names: Set<String>

        public init(bundleIDs: Set<String>, names: Set<String>) {
            self.bundleIDs = bundleIDs
            self.names = Set(names.map { $0.lowercased() })
        }

        public static let none = Attributed(bundleIDs: [], names: [])

        func covers(_ c: CoalitionUsage) -> Bool {
            bundleIDs.contains(c.bundleID) || names.contains(c.displayName.lowercased())
        }
    }

    /// Divides `watts` among the coalitions NOT already attributed by name.
    ///
    /// Excluding the already-measured apps is what prevents double counting:
    /// their energy is already a measured row elsewhere in the ledger, and
    /// letting them also take a slice of the unattributed remainder would credit
    /// them twice — and show them twice.
    ///
    /// Returns rows summing to `watts` (up to float error), so substituting them
    /// for the anonymous bucket preserves the conservation invariant.
    public func apportion(watts: Double,
                          by weight: Weight,
                          excluding attributed: Attributed,
                          living: Set<String> = [],
                          scale: BatteryScale,
                          minimumShare: Double = 0.01) -> [Row] {
        Self.apportion(watts: watts, among: latest, by: weight,
                       excluding: attributed, living: living, scale: scale,
                       minimumShare: minimumShare)
    }

    /// The apportionment itself, as a pure function of its inputs. Split out from
    /// the instance method so it can be tested against a known coalition list —
    /// otherwise every test would have to drive a background subprocess refresh
    /// and assert on whatever the machine happened to be doing.
    /// Below this many observed coalitions, the rollup is treated as a failed
    /// observation rather than a small machine.
    ///
    /// Apportionment divides a MACHINE-WIDE bucket, so it is only meaningful when
    /// the rollup saw enough of the machine to divide it. Coverage does not
    /// degrade gracefully — it collapses from hundreds of coalitions to a handful
    /// — and a handful of survivors still sum to 100% of the bucket, which looks
    /// exactly as authoritative as a good sample while being an artifact of which
    /// coalitions happened to report twice. Showing nothing is the honest output.
    public static let minimumCoalitions = 20

    public static func apportion(watts: Double,
                                 among all: [CoalitionUsage],
                                 by weight: Weight,
                                 excluding attributed: Attributed,
                                 living: Set<String> = [],
                                 scale: BatteryScale,
                                 minimumShare: Double = 0.01) -> [Row] {
        guard watts > 0, all.count >= minimumCoalitions else { return [] }

        // Only LIVING processes may take a share.
        //
        // The rollup window is an hour, because shorter ones had unusable
        // coverage — but that window is HISTORICAL, and the watts being divided
        // are CURRENT. Without this filter an app that quit forty minutes ago
        // keeps receiving present-tense power for the rest of the hour. Observed
        // live: Brave fully quit, zero processes, still holding 14% of the share
        // on 15,581 ms of CPU it burned before it exited.
        //
        // An empty `living` set means the caller could not enumerate, and the
        // filter is skipped rather than silently zeroing every row.
        let candidates = all.filter {
            guard !attributed.covers($0) else { return false }
            guard !living.isEmpty else { return true }
            return living.contains($0.displayName.lowercased())
        }
        func w(_ c: CoalitionUsage) -> Double {
            switch weight {
            case .cpuTime: return Double(c.cpu_ms)
            case .gpuTime: return Double(c.gpu_ms)
            }
        }
        let total = candidates.reduce(0.0) { $0 + w($1) }
        guard total > 0 else { return [] }

        // Rows below the threshold are dropped and their weight left in the
        // total, so the surviving rows deliberately sum to slightly LESS than
        // `watts`. The shortfall stays in the anonymous bucket where it belongs;
        // inflating the visible rows to close the gap would be exactly the
        // redistribution this app exists to avoid.
        return candidates.compactMap { c -> Row? in
            let share = w(c) / total
            guard share >= minimumShare else { return nil }
            let watt = watts * share
            return Row(bundleID: c.bundleID,
                       name: c.displayName,
                       watts: watt,
                       percentPerHour: 3600 * watt / scale.joulesPerPercent,
                       cpu_ms: c.cpu_ms,
                       gpu_ms: c.gpu_ms,
                       isSystem: c.isSystem)
        }
        .sorted { $0.watts > $1.watts }
    }
}

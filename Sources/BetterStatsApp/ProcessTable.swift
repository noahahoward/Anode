import AppKit
import PowerKit

/// The Processes tab: one row per application, one column per resource.
///
/// This replaces five lenses that each drew the same table with two columns
/// swapped. Making them columns is what lets a question like "which app is both
/// hot on CPU and holding a gigabyte" be answered at all — under the old rail it
/// needed two tabs and a memory of what the other one said.
///
/// Everything about a column lives in ONE `ProcessColumn`: its header, its width,
/// the string a cell shows, the value it sorts by, and whether it is measured or
/// apportioned. The renderer, the sizer, the sorter and the header tooltips all
/// read that list, so a column cannot be shown with one definition and sorted with
/// another — which is precisely the drift the old parallel `columns(for:)` /
/// `cellText` / `sortRows` switches invited.

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Row

/// One line of the table.
///
/// Three sources are joined here, and the row keeps them apart on purpose:
///
///   `app`    — MEASURED, from `proc_pid_rusage` over our own uid. Battery rate,
///              CPU percent, memory and disk.
///   `system` — MODELED. A named share of the CPU power rusage cannot see
///              (WindowServer, the root daemons), apportioned from Apple's
///              coalition rollup.
///   `gpu`    — MODELED, always. macOS exposes no per-process GPU power or GPU
///              utilisation at all, so every GPU figure in this table is the
///              measured GPU rail split by coalition GPU time.
///
/// A row can have any combination. An ordinary app has `app` and usually `gpu`;
/// WindowServer has `system` and `gpu` and no measured columns at all.
final class Row: NSObject {
    let name: String
    let isApp: Bool
    /// nil for system rows: those come from Apple's coalition rollup, which
    /// reports per-app totals and no pids at all, so there is no process to
    /// inspect, no memory footprint to read and nothing to quit.
    let app: AppDrain?
    /// Set when this row's battery figure is an apportioned share of a measured
    /// bucket rather than a measured quantity in its own right.
    let system: SystemAttribution.Row?
    /// This app's share of the measured GPU rail. Always apportioned.
    let gpu: SystemAttribution.Row?
    /// Fraction of all attributed GPU time this row accounts for, 0…1. Apportioned
    /// like everything else GPU-side.
    let gpuTimeShare: Double?
    /// Percent of battery consumed over the trailing on-battery window. nil until
    /// the history store has data for this app — shown as "—", never as 0, because
    /// "no data yet" and "used nothing" are different claims.
    let windowPct: Double?
    /// Minutes of runtime quitting this would buy back. nil below the point where
    /// the counterfactual rounds to nothing. See `RuntimeCost`.
    let costMin: Double?
    /// Resident memory as a percent of physical RAM. nil when there is no measured
    /// footprint — a coalition row has none.
    let memoryPercent: Double?

    /// True when NOTHING in this row was measured per-process: it is a named share
    /// of a bucket. Drives the name's colour, as it always has.
    var isModeled: Bool { app == nil }

    var procs: Int { app?.processCount ?? 0 }
    /// The battery rate attributable to this row's CPU time. nil for a row that
    /// only ever appeared in the GPU rollup — its CPU cost was never measured, and
    /// 0 would claim it was measured at zero.
    var pctHr: Double? { app?.percentPerHour ?? system?.percentPerHour }

    init(app: AppDrain?,
         system: SystemAttribution.Row?,
         gpu: SystemAttribution.Row?,
         gpuTimeShare: Double?,
         windowPct: Double?,
         costMin: Double?,
         totalMemoryBytes: UInt64) {
        // Whichever source is present names the row; they are joined on that name
        // (and on the bundle id where both have one), so they cannot disagree.
        self.name = app?.name ?? system?.name ?? gpu?.name ?? ""
        self.isApp = app?.isApp ?? false
        self.app = app
        self.system = system
        self.gpu = gpu
        self.gpuTimeShare = gpuTimeShare
        self.windowPct = windowPct
        self.costMin = costMin
        self.memoryPercent = {
            guard let bytes = app?.memoryBytes, bytes > 0, totalMemoryBytes > 0 else { return nil }
            return Double(bytes) / Double(totalMemoryBytes) * 100
        }()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Runtime cost

/// "Quitting this would buy you N more minutes."
///
/// The arithmetic is `PowerMonitor.Snapshot.runtimeCost_min`'s and is unchanged —
/// runtime is E/P, so removing a load of P_app changes it by
/// `E * (1/(P_sys - P_app) - 1/P_sys)`. What changed is the two gates that were
/// deciding when to answer, both of which blanked the column outright.
///
/// MEASURED on this machine (M5 Pro, 8 sweeps, adapter detached, 83% charge,
/// 214 kJ in the pack):
///
///     smoothed_W   top app W   share    old gate      real answer
///        3.97        0.0404    1.02%    passed        9.2 min
///        3.97        0.0103    0.26%    REJECTED      2.3 min
///       21.0         0.0404    0.19%    REJECTED      0.3 min
///
/// 1. THE SHARE FLOOR WAS A PROXY FOR THE WRONG THING. It rejected anything under
///    0.5% of whole-machine power, on the stated assumption that "a top app is
///    typically 2-4% of the machine". Measured, the top app is 1.0% of an idle
///    machine and 0.19% of a busy one — the assumption is an order of magnitude
///    out, so the floor rejected every row on a busy machine and all but the top
///    three on an idle one. The floor's own justification was that below it "the
///    answer rounds to under a minute", and that is a statement about the ANSWER,
///    not about the share: whether 0.5% is worth a minute depends entirely on
///    system power. So the floor is applied where it was always aimed — at the
///    minutes.
///
/// 2. THE ON-AC GATE BLANKED THE COLUMN WHENEVER THE ADAPTER WAS ATTACHED, on the
///    grounds that there is no runtime to extend. But every other battery figure
///    in this window — the %/hr column beside it, the ledger bar, the graph, the
///    10 hr window — is reported on AC as well, and each is the same kind of
///    statement: what this costs the battery at the current draw. Blanking one of
///    them and not the others is not extra honesty, it is one column that looks
///    broken. The pack's charge and the machine's draw are both measured on AC,
///    which is everything the formula reads.
enum RuntimeCost {

    /// Below one minute the answer rounds to "0 min", which is noise dressed as a
    /// measurement. This is the floor the share floor was trying to express.
    static let minimumReportable_min: Double = 1

    /// nil when the counterfactual has no meaning or no content:
    ///   • nothing is drawing, or the app draws nothing;
    ///   • the app would account for essentially the whole machine, where the
    ///     denominator collapses and the answer tends to infinity;
    ///   • the answer is under a minute.
    static func minutes(appWatts: Double, systemWatts: Double,
                        remainingEnergy_J: Double) -> Double? {
        guard systemWatts > 0.01, appWatts > 0, remainingEnergy_J > 0 else { return nil }
        let without = systemWatts - appWatts
        // 10% of system power left is already an app that explains the machine;
        // past that the reciprocal runs away and prints days.
        guard without > 0.01, appWatts / systemWatts < 0.9 else { return nil }
        let seconds = remainingEnergy_J * (1.0 / without - 1.0 / systemWatts)
        guard seconds.isFinite else { return nil }
        let minutes = seconds / 60
        return minutes >= minimumReportable_min ? minutes : nil
    }

    /// nil when the machine has no battery to spend — there is then no runtime for
    /// quitting anything to extend.
    static func minutes(appWatts: Double, snapshot s: PowerMonitor.Snapshot) -> Double? {
        guard let energy = s.remainingEnergy_J else { return nil }
        return minutes(appWatts: appWatts, systemWatts: s.smoothed_W, remainingEnergy_J: energy)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Columns

/// One column, completely described.
struct ProcessColumn {
    let id: String
    let title: String
    /// Starting width. Columns only ever grow from here — see `autosizeColumns`.
    let width: CGFloat
    /// Header tooltip. Every column carries one: a header this narrow cannot say
    /// what "%/hr" divides by or that a GPU figure is apportioned, and the answer
    /// has to be reachable somewhere other than the source.
    let tooltip: String
    /// The string a cell shows, and whether it is a "no reading" that should be
    /// drawn dim. Single source of truth: the sizer measures exactly what the
    /// renderer draws, which is how a column ends up one character too narrow.
    let text: (Row) -> (text: String, dim: Bool)
    /// What the column sorts by. nil ranks BELOW every real value, so "not
    /// measurable here" never outranks a genuine zero.
    let value: (Row) -> Double?
    /// Set only on the name column: sorting a name numerically is meaningless.
    let stringValue: ((Row) -> String)?
    /// True when EVERY cell in this column is apportioned rather than measured.
    /// The header carries "*" for it, the same mark the rest of the app uses for
    /// an estimate.
    let isModeled: Bool

    init(id: String, title: String, width: CGFloat, isModeled: Bool = false,
         tooltip: String,
         text: @escaping (Row) -> (text: String, dim: Bool),
         value: @escaping (Row) -> Double? = { _ in nil },
         stringValue: ((Row) -> String)? = nil) {
        self.id = id
        self.title = isModeled ? title + "*" : title
        self.width = width
        self.tooltip = tooltip
        self.text = text
        self.value = value
        self.stringValue = stringValue
        self.isModeled = isModeled
    }
}

enum ProcessColumns {

    /// The one place the table's shape is written down.
    ///
    /// Order is the user's: identity, then what it costs the battery, then what it
    /// is using right now, then the GPU — which is last because every figure in it
    /// is apportioned and the measured columns should be the ones read first.
    ///
    /// - Parameter powerWindowHours: titles the trailing-window column from the
    ///   setting that defines it, so changing the window cannot leave a header
    ///   claiming ten hours over a two-hour figure.
    static func all(powerWindowHours: Double) -> [ProcessColumn] {
        [
            ProcessColumn(
                id: "name", title: "Process", width: 200,
                tooltip: "Application, or the coalition a share of system power was "
                       + "attributed to.",
                text: { ($0.name, false) },
                stringValue: { $0.name }),

            ProcessColumn(
                id: "pctHr", title: "%/hr", width: 70,
                tooltip: "Percent of a full battery per hour, from this app's measured "
                       + "CPU energy. Not a share of anything — 1.0 means it alone "
                       + "would flatten the pack in 100 hours.",
                text: { r in
                    guard let v = r.pctHr else { return ("—", true) }
                    return (v < 0.01 ? "<0.01" : String(format: "%.2f", v), v < 0.01)
                },
                value: { $0.pctHr }),

            ProcessColumn(
                id: "window", title: "\(Int(powerWindowHours.rounded())) hr power", width: 86,
                tooltip: "Percent of the battery this app has actually consumed over the "
                       + "trailing window, from recorded history. \"—\" means nothing has "
                       + "been recorded for it yet, which is not the same as zero.",
                text: { r in
                    (r.windowPct.map { String(format: "%.2f%%", $0) } ?? "—", r.windowPct == nil)
                },
                value: { $0.windowPct }),

            ProcessColumn(
                id: "cost", title: "Runtime cost", width: 96,
                tooltip: "Minutes of battery life quitting this would buy back at the "
                       + "current draw and current charge. Blank below a minute, where "
                       + "the answer is rounding noise.",
                text: { r in
                    (r.costMin.map { $0 >= 60
                        ? String(format: "%dh %02dm", Int($0 / 60), Int($0) % 60)
                        : String(format: "%.0f min", $0) } ?? "—",
                     r.costMin == nil)
                },
                value: { $0.costMin }),

            ProcessColumn(
                id: "procs", title: "Procs", width: 54,
                tooltip: "How many processes this app is running. Blank for one.",
                text: { r in (r.procs > 1 ? "\(r.procs)" : "—", true) },
                value: { $0.app.map { Double($0.processCount) } }),

            ProcessColumn(
                id: "cpu", title: "% CPU", width: 66,
                tooltip: "Percent of ONE core, Activity Monitor's convention: a busy "
                       + "four-thread process reads 400%.",
                text: { r in
                    guard let a = r.app else { return ("—", true) }
                    return (a.cpuPercent < 0.1 ? "—" : String(format: "%.1f", a.cpuPercent),
                            a.cpuPercent < 0.1)
                },
                value: { $0.app?.cpuPercent }),

            ProcessColumn(
                id: "memPct", title: "% Mem", width: 62,
                tooltip: "Resident memory as a percent of installed RAM.",
                text: { r in
                    guard let p = r.memoryPercent else { return ("—", true) }
                    return (p < 0.05 ? "<0.05" : String(format: "%.2f", p), p < 0.05)
                },
                value: { $0.memoryPercent }),

            ProcessColumn(
                id: "mem", title: "Memory", width: 76,
                tooltip: "Resident footprint, summed across the app's processes.",
                text: { r in
                    guard let a = r.app, a.memoryBytes > 0 else { return ("—", true) }
                    return (MetricUnit.bytes.format(Double(a.memoryBytes)), false)
                },
                value: { $0.app.map { Double($0.memoryBytes) } }),

            ProcessColumn(
                id: "disk", title: "Disk I/O", width: 78,
                // Read and write ARE sampled separately per process, and then summed
                // before they reach here — `DrainTracker` keeps one `diskBytes`
                // counter. Splitting the column needs that type to carry both, which
                // is a PowerKit change; until then one honest combined figure beats
                // two invented ones.
                tooltip: "Bytes per second read AND written, combined. The per-process "
                       + "sampler sums the two counters, so this app cannot split them.",
                text: { r in
                    guard let a = r.app, a.diskBytesPerSec >= 1 else { return ("—", true) }
                    return (MetricUnit.bytesPerSecond.format(a.diskBytesPerSec), false)
                },
                value: { $0.app?.diskBytesPerSec }),

            ProcessColumn(
                id: "gpuPct", title: "GPU %", width: 62, isModeled: true,
                tooltip: "Share of all GPU time in the rollup window. Apportioned from "
                       + "Apple's coalition rollup, never measured per process — macOS "
                       + "exposes no per-process GPU utilisation.",
                text: { r in
                    guard let s = r.gpuTimeShare, s > 0 else { return ("—", true) }
                    let pct = s * 100
                    return (pct < 0.1 ? "<0.1" : String(format: "%.1f", pct), false)
                },
                value: { $0.gpuTimeShare }),

            ProcessColumn(
                id: "gputime", title: "GPU time", width: 74, isModeled: true,
                tooltip: "GPU milliseconds this COALITION accumulated over the rollup "
                       + "window. Apple's own counter, at coalition granularity rather "
                       + "than per process, and lagging by up to a minute.",
                text: { r in
                    guard let ms = r.gpu?.gpu_ms, ms > 0 else { return ("—", true) }
                    return (ms >= 1000 ? String(format: "%.1f s", Double(ms) / 1000)
                                       : "\(ms) ms", false)
                },
                value: { $0.gpu.map { Double($0.gpu_ms) } }),

            ProcessColumn(
                id: "gpuPctHr", title: "GPU %/hr", width: 78, isModeled: true,
                tooltip: "The measured GPU rail's percent-per-hour, split by coalition "
                       + "GPU time. The rail is measured; this row's share of it is not.",
                text: { r in
                    guard let v = r.gpu?.percentPerHour, v > 0 else { return ("—", true) }
                    return (v < 0.01 ? "<0.01" : String(format: "%.2f", v), v < 0.01)
                },
                value: { $0.gpu?.percentPerHour }),
        ]
    }

    /// Trailing slack absorber. Not a column of data: it exists so spare width goes
    /// somewhere other than into the app name, which would push the numbers to the
    /// window edge and outside the row's hover pill.
    static let spacerID = "spacer"

    static func byID(_ powerWindowHours: Double) -> [String: ProcessColumn] {
        Dictionary(all(powerWindowHours: powerWindowHours).map { ($0.id, $0) },
                   uniquingKeysWith: { a, _ in a })
    }

    /// Sorted by battery rate, descending — the question the app was opened to
    /// answer.
    static let defaultSortKey = "pctHr"
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Building the rows

enum ProcessRowBuilder {

    /// Join the three sources into one row per app.
    ///
    /// Matching is on bundle id first and name second, because daemons have no
    /// bundle at all: matching on id alone lets exactly the overlapping population
    /// through twice, which is the same trap `PowerMonitor` documents for its own
    /// exclusion set.
    ///
    /// A coalition that matched no measured app still gets a row. WindowServer is
    /// the whole point of the system rollup and has no pids we can read; dropping
    /// it because it has no `AppDrain` would hide the largest named consumer on the
    /// machine.
    static func rows(apps: [AppDrain],
                     systemApps: [SystemAttribution.Row],
                     gpuApps: [SystemAttribution.Row],
                     windowPercents: [String: Double],
                     runtimeCost: (Double) -> Double?,
                     totalMemoryBytes: UInt64) -> [Row] {

        func key(bundleID: String?, name: String) -> String {
            // Bundle ids are already lowercase by convention; names are not, and
            // "Google Chrome" and "Google chrome" are the same app.
            (bundleID?.isEmpty == false ? bundleID! : name).lowercased()
        }

        var gpuByKey: [String: SystemAttribution.Row] = [:]
        for g in gpuApps {
            gpuByKey[key(bundleID: g.bundleID, name: g.name)] = g
            // Also reachable by name, so an app whose measured identity carries no
            // bundle id can still find its GPU share.
            gpuByKey[g.name.lowercased()] = g
        }
        let totalGPUms = gpuApps.reduce(0.0) { $0 + Double($1.gpu_ms) }

        func share(_ g: SystemAttribution.Row?) -> Double? {
            guard let g, totalGPUms > 0 else { return nil }
            return Double(g.gpu_ms) / totalGPUms
        }

        var claimedGPU = Set<String>()
        func takeGPU(bundleID: String?, name: String) -> SystemAttribution.Row? {
            let k = key(bundleID: bundleID, name: name)
            guard let g = gpuByKey[k] ?? gpuByKey[name.lowercased()] else { return nil }
            // One GPU row can only be spent once, or two apps sharing a name would
            // each be credited with the whole coalition's GPU time.
            let identity = key(bundleID: g.bundleID, name: g.name)
            guard !claimedGPU.contains(identity) else { return nil }
            claimedGPU.insert(identity)
            return g
        }

        var out: [Row] = []
        for a in apps {
            let g = takeGPU(bundleID: a.identity.bundleID, name: a.name)
            out.append(Row(app: a, system: nil, gpu: g, gpuTimeShare: share(g),
                           windowPct: windowPercents[a.name],
                           costMin: runtimeCost(a.watts),
                           totalMemoryBytes: totalMemoryBytes))
        }
        for s in systemApps {
            let g = takeGPU(bundleID: s.bundleID, name: s.name)
            // No `windowPct` and no runtime cost: there is no per-app history for a
            // coalition, and the quit-this counterfactual needs a process to quit.
            out.append(Row(app: nil, system: s, gpu: g, gpuTimeShare: share(g),
                           windowPct: nil, costMin: nil,
                           totalMemoryBytes: totalMemoryBytes))
        }
        for g in gpuApps where !claimedGPU.contains(key(bundleID: g.bundleID, name: g.name)) {
            out.append(Row(app: nil, system: nil, gpu: g, gpuTimeShare: share(g),
                           windowPct: nil, costMin: nil,
                           totalMemoryBytes: totalMemoryBytes))
        }
        return out
    }

    /// Whether a row earns a place in a table that now shows everything at once.
    ///
    /// Applications are always listed — an app you have open and that is doing
    /// nothing is an answer, and blinking it out of the table reads as a bug.
    /// Everything else has to be doing something in at least one of the columns,
    /// because the union of five lenses' populations is otherwise ~220 rows of
    /// mostly-idle daemons.
    ///
    /// Memory is held to 128 MB rather than to "greater than zero", which is what
    /// the old Memory lens used: every process on the machine has a footprint, so
    /// that test admitted all of them. 128 MB is the point where a daemon's
    /// footprint is worth a row of its own.
    static let notableMemoryBytes: UInt64 = 128 * 1024 * 1024

    static func isNotable(_ r: Row, floor_pctHr: Double) -> Bool {
        if r.isApp { return true }
        if let v = r.pctHr, v >= floor_pctHr { return true }
        if let a = r.app {
            // 2.0% of one core, the threshold the CPU lens used. Below it a daemon
            // has executed but has not done anything.
            if a.cpuPercent >= 2.0 { return true }
            if a.memoryBytes >= notableMemoryBytes { return true }
            if a.diskBytesPerSec >= 1 { return true }
        }
        if let ms = r.gpu?.gpu_ms, ms > 0 { return true }
        return false
    }
}

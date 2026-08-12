import Foundation

/// Per-process network throughput.
///
/// The Network pane has always said this was unavailable without elevated
/// privileges. That was wrong in the same way the earlier claim about Activity
/// Monitor's energy data was wrong: `nettop` is not setuid, needs no
/// entitlement, and reports per-process byte counters as a normal user.
///
/// It is spawned rather than linked because the underlying NetworkStatistics
/// framework is private. The subprocess blocks for a fixed ~5 s no matter what
/// sampling flags it is given, but that time is spent SLEEPING — 0.02 s of CPU —
/// so it is harmless on a background queue and merely means the figures are a few
/// seconds old. It never runs on a tick path.
public final class NetworkAttribution {

    public struct Row {
        public let pid: pid_t
        public let name: String
        public let bytesInPerSec: Double
        public let bytesOutPerSec: Double
        public var totalPerSec: Double { bytesInPerSec + bytesOutPerSec }
    }

    /// One process's cumulative counters at a point in time.
    private struct Sample {
        let bytesIn: UInt64
        let bytesOut: UInt64
    }

    private let lock = NSLock()
    private var previous: [ProcessKey: Sample] = [:]
    private var previousAt: Date?
    private var cached: [Row] = []
    private var lastRefresh: Date?
    private var refreshing = false

    /// Keyed by pid AND name: pids are recycled, and a recycled pid inheriting the
    /// previous occupant's counters would produce a colossal phantom delta the
    /// first time the new process was seen.
    private struct ProcessKey: Hashable {
        let pid: pid_t
        let name: String
    }

    private let refreshInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.anode.networkattribution",
                                      qos: .utility)

    public init(refreshInterval: TimeInterval = 15) {
        self.refreshInterval = refreshInterval
    }

    public static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/nettop")
    }

    public var latest: [Row] {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    public var age: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return lastRefresh.map { Date().timeIntervalSince($0) }
    }

    /// Call from whatever displays the rows. Returns immediately; the first call
    /// only establishes a baseline, because a rate needs two samples and
    /// cumulative counters read once are just totals since each process started.
    public func refreshIfNeeded() {
        lock.lock()
        let due = lastRefresh.map { Date().timeIntervalSince($0) >= refreshInterval } ?? true
        guard due, !refreshing, Self.isAvailable else { lock.unlock(); return }
        refreshing = true
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let now = Self.sample()
            let at = Date()

            self.lock.lock()
            defer { self.refreshing = false; self.lock.unlock() }
            guard !now.isEmpty else { self.lastRefresh = at; return }

            if let prevAt = self.previousAt, !self.previous.isEmpty {
                let dt = at.timeIntervalSince(prevAt)
                if dt > 0.5 {
                    var rows: [Row] = []
                    for (key, cur) in now {
                        guard let old = self.previous[key] else { continue }
                        // Counters only grow within a process's lifetime. A
                        // decrease means the row is a different process that
                        // reused the pid, so it contributes nothing rather than a
                        // negative or a full-cumulative spike.
                        guard cur.bytesIn >= old.bytesIn, cur.bytesOut >= old.bytesOut else { continue }
                        let dIn = Double(cur.bytesIn - old.bytesIn) / dt
                        let dOut = Double(cur.bytesOut - old.bytesOut) / dt
                        guard dIn > 0 || dOut > 0 else { continue }
                        rows.append(Row(pid: key.pid, name: key.name,
                                        bytesInPerSec: dIn, bytesOutPerSec: dOut))
                    }
                    self.cached = rows.sorted { $0.totalPerSec > $1.totalPerSec }
                    self.lastRefresh = at
                }
            }
            self.previous = now
            self.previousAt = at
            if self.lastRefresh == nil { self.lastRefresh = at }
        }
    }

    // ── Parsing ─────────────────────────────────────────────────────────────

    /// Rows look like `Google Chrome.1234,15738,2996,`. The name may itself
    /// contain dots and spaces, so the pid is taken from the LAST dot before the
    /// first comma rather than by splitting the field.
    private static func sample() -> [ProcessKey: Sample] {
        guard let out = run() else { return [:] }
        var result: [ProcessKey: Sample] = [:]
        for line in out.split(separator: "\n") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            let ident = String(fields[0])
            guard let dot = ident.lastIndex(of: "."),
                  let pid = pid_t(ident[ident.index(after: dot)...]) else { continue }
            let name = String(ident[..<dot])
            guard !name.isEmpty,
                  let bin = UInt64(fields[1].trimmingCharacters(in: .whitespaces)),
                  let bout = UInt64(fields[2].trimmingCharacters(in: .whitespaces))
            else { continue }
            // Same process can appear more than once; sum rather than overwrite.
            let key = ProcessKey(pid: pid, name: name)
            let prior = result[key]
            result[key] = Sample(bytesIn: (prior?.bytesIn ?? 0) + bin,
                                 bytesOut: (prior?.bytesOut ?? 0) + bout)
        }
        return result
    }

    private static func run() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // -P per-process totals, -L 1 one sample then exit, -x raw bytes (no
        // "KiB" suffixes to parse), -J restricts output to the two columns.
        p.arguments = ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }

        // Read before waiting: a full pipe buffer with nobody draining it would
        // deadlock the child against our wait.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

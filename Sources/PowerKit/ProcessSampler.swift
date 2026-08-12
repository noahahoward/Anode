import Darwin
import Foundation

/// Per-process energy in REAL NANOJOULES, straight from the kernel.
///
/// `proc_pid_rusage(pid, RUSAGE_INFO_V6, &info)` -> `ri_energy_nj`. This is a public
/// API, backed by hardware per-task energy accounting (`kern.pervasive_energy = 1`
/// on Apple Silicon). It is the reason this project does not need to invent a unit:
/// the joules already exist.
///
/// COVERAGE LIMIT: same-uid only. Measured on this machine, ~63% of pids are
/// readable and the rest return EPERM — including WindowServer (uid 88, routinely
/// the single largest real consumer) and every root daemon. Full live coverage
/// needs the privileged helper; historical coverage comes from CoalitionUsage.
public struct ProcessEnergy {
    public let pid: pid_t
    public let name: String
    /// Cumulative since process start.
    public let energy_nJ: UInt64
    /// Portion attributed to perf-level 0. P-cores and E-cores differ several-fold
    /// in J/cycle, so this split matters for any modeled apportionment.
    public let pEnergy_nJ: UInt64
    public let cycles: UInt64
    public let pCycles: UInt64
    /// PIDs are reused. Identity is (pid, startTime), never pid alone.
    public let startAbsTime: UInt64
    /// Executable path, captured once per sweep. Kept so the app rollup does not
    /// have to re-issue proc_pidpath for every process on every tick.
    public let path: String

    // The rest of the rusage struct, which we were filling and throwing away. Four
    // of the five lenses are built from these, at no extra sampling cost — the
    // syscall already returns them.
    /// Cumulative CPU time in nanoseconds.
    public let userTime_ns: UInt64
    public let systemTime_ns: UInt64
    /// Instantaneous, not cumulative: what Activity Monitor calls Memory.
    public let footprint: UInt64
    public let diskRead: UInt64
    public let diskWritten: UInt64

    public var key: ProcessKey { ProcessKey(pid: pid, startAbsTime: startAbsTime) }
}

public struct ProcessKey: Hashable {
    public let pid: pid_t
    public let startAbsTime: UInt64
}

public enum ProcessSampler {

    /// Names of every process that currently exists.
    ///
    /// Cheap by design: one `proc_listpids` plus a name lookup each, no rusage
    /// call. It exists so the coalition rollup cannot hand present-tense power to
    /// an app that has already quit — the rollup window is an hour, and without
    /// this a browser closed forty minutes ago keeps drawing battery on screen.
    /// Names of every process on the machine, whatever user owns it.
    ///
    /// This is used to decide whether a coalition in the hour-old `systemstats`
    /// rollup is still alive, so a name MISSING here is not a neutral gap — it
    /// removes that coalition from the ledger and hands its share of measured
    /// CPU watts to whoever remains.
    ///
    /// It used to call `proc_name`, which fails with EPERM for processes owned
    /// by another user. Measured: 340 names for ~700 processes, and the ones it
    /// could not see were `WindowServer`, `bluetoothd`, `coreaudiod` — exactly
    /// the root-owned daemons the coalition rollup exists to reach, since they
    /// are also the ones `proc_pid_rusage` cannot measure. WindowServer alone
    /// had 6,295 ms of CPU in the hour it was dropped, 40x the largest row that
    /// survived, and its watts were redistributed across trivial user daemons —
    /// which is how a Batteries widget that used 17 ms in an hour reached the
    /// top of the battery list.
    ///
    /// `sysctl KERN_PROC_ALL` returns `p_comm` for every process without any
    /// privilege at all. The cost is that `p_comm` is truncated to
    /// `MAXCOMLEN` (16) characters, which is why callers must compare with
    /// `nameMatches` rather than by equality.
    public static func runningNames() -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0
        else { return [] }

        // The table can grow between sizing and reading, so ask for headroom and
        // trust the byte count that comes back rather than the one we asked for.
        size += size / 8
        var buf = [UInt8](repeating: 0, count: size)
        var got = size
        let rc = buf.withUnsafeMutableBytes {
            sysctl(&mib, UInt32(mib.count), $0.baseAddress, &got, nil, 0)
        }
        guard rc == 0, got > 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        var names: [String] = []
        names.reserveCapacity(got / stride)
        buf.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<(got / stride) {
                var kp = base.load(fromByteOffset: i * stride, as: kinfo_proc.self)
                guard kp.kp_proc.p_pid > 0 else { continue }
                let name = withUnsafeBytes(of: &kp.kp_proc.p_comm) { c -> String in
                    let bytes = c.prefix { $0 != 0 }
                    return String(decoding: bytes, as: UTF8.self)
                }
                if !name.isEmpty { names.append(name) }
            }
        }
        return names
    }

    /// Does a rollup's display name refer to one of these running processes?
    ///
    /// Not equality, because `p_comm` is truncated at 16 characters while the
    /// rollup's name comes from a bundle id and is not. `BatteriesAvocadoWidgetExtension`
    /// arrives as `BatteriesAvocado`, and comparing those two for equality drops
    /// every process with a long name — the same failure this replaced, in a new
    /// place.
    ///
    /// Matching is deliberately generous: a false "alive" leaves a dead
    /// coalition in the rollup for up to an hour, which understates other rows
    /// slightly. A false "dead" deletes a live process's power and redistributes
    /// it, which is what actually went wrong.
    public static func nameMatches(_ displayName: String, in running: Set<String>) -> Bool {
        LivingNames(running).matches(displayName)
    }

    /// A set of living process names, prepared once for repeated matching.
    ///
    /// The naive form of `matches` is a linear scan of every living name, with an
    /// O(name) `String.count` inside it — and it is asked once per coalition, for
    /// each of the two apportionments in a tick. Profiled under `sample`, that
    /// scan was a THIRD of the entire sampling queue's CPU: roughly 500 living
    /// names against 300 coalitions, six times over, every refresh.
    ///
    /// Bucketing by the first `truncationFloor` characters makes it a hash lookup
    /// into a bucket that is almost always empty. The semantics are unchanged, and
    /// exactly so: a name long enough to have been truncated can only be a prefix
    /// of `n` if it agrees with `n` on those first characters.
    public struct LivingNames: ExpressibleByArrayLiteral {
        /// `p_comm` truncates at 16 characters, so anything at least this long may
        /// be a truncation of something longer. Shorter names must match exactly,
        /// which is what stops `secd` from matching `secdiagnosticd`.
        public static let truncationFloor = 15

        private let exact: Set<String>
        private let longByPrefix: [String: [String]]

        public var isEmpty: Bool { exact.isEmpty }

        public init(_ names: some Sequence<String>) {
            var all = Set<String>()
            var buckets: [String: [String]] = [:]
            for name in names {
                all.insert(name)
                guard name.count >= Self.truncationFloor else { continue }
                buckets[String(name.prefix(Self.truncationFloor)), default: []].append(name)
            }
            exact = all
            longByPrefix = buckets
        }

        public init(arrayLiteral elements: String...) { self.init(elements) }

        /// Matching is deliberately generous: a false "alive" leaves a dead
        /// coalition in the rollup for up to an hour, which understates other rows
        /// slightly. A false "dead" deletes a live process's power and
        /// redistributes it, which is what actually went wrong.
        public func matches(_ displayName: String) -> Bool {
            let n = displayName.lowercased()
            if exact.contains(n) { return true }
            // A prefix cannot be longer than the string it prefixes, so a name
            // shorter than the floor can never be matched by a truncated one.
            guard n.count >= Self.truncationFloor,
                  let bucket = longByPrefix[String(n.prefix(Self.truncationFloor))]
            else { return false }
            return bucket.contains { n.hasPrefix($0) }
        }
    }

    public static func allPIDs() -> [pid_t] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bytes)
        guard written > 0 else { return [] }
        return pids.prefix(Int(written) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    /// One syscall per process per sweep. Previously this was called separately from
    /// the app rollup, doubling the syscall count and putting our own process at the
    /// top of its own table — the instrument must not be the largest entry in its
    /// own ledger.
    public static func path(of pid: pid_t) -> String {
        // PROC_PIDPATHINFO_MAXSIZE (4*MAXPATHLEN) is a macro Swift cannot import.
        var buf = [CChar](repeating: 0, count: 4 * 1024)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        return String(cString: buf)
    }

    public static func name(fromPath path: String, pid: pid_t) -> String {
        if !path.isEmpty { return (path as NSString).lastPathComponent }
        var nameBuf = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 {
            return String(cString: nameBuf)
        }
        return "pid \(pid)"
    }

    /// Returns nil on EPERM (cross-uid) or if the process exited mid-sweep.
    public static func energy(of pid: pid_t, reusing cache: IdentityCache? = nil) -> ProcessEnergy? {
        var info = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard rc == 0 else { return nil }

        let identity = cache?.identity(for: pid, start: info.ri_proc_start_abstime)
            ?? { let p = path(of: pid); return (p, name(fromPath: p, pid: pid)) }()
        let p = identity.path
        return ProcessEnergy(
            pid: pid,
            name: identity.name,
            energy_nJ: info.ri_energy_nj,
            pEnergy_nJ: info.ri_penergy_nj,
            cycles: info.ri_cycles,
            pCycles: info.ri_pcycles,
            startAbsTime: info.ri_proc_start_abstime,
            path: p,
            userTime_ns: info.ri_user_time,
            systemTime_ns: info.ri_system_time,
            footprint: info.ri_phys_footprint,
            diskRead: info.ri_diskio_bytesread,
            diskWritten: info.ri_diskio_byteswritten
        )
    }

    public struct Sweep {
        public let processes: [ProcessKey: ProcessEnergy]
        public let timestamp: Date
        public let attempted: Int
        public let denied: Int

        public var coverage: Double {
            attempted == 0 ? 0 : Double(processes.count) / Double(attempted)
        }
    }

    /// Executable path and display name for a pid, reused across sweeps.
    ///
    /// `path(of:)` is a syscall and `name(fromPath:pid:)` bridges to `NSString`,
    /// and both were paid for every process on the machine on every tick. A
    /// process's executable path is fixed for its lifetime, so the only thing that
    /// can invalidate an entry is the pid being reused — which `startAbsTime`
    /// detects exactly, the same identity the ledger already keys on.
    ///
    /// Not thread-safe, and deliberately so: it is owned by whoever runs the
    /// sweep, which is a serial queue. Pass one per sampler, never a shared global.
    public final class IdentityCache {
        private var entries: [pid_t: (start: UInt64, path: String, name: String)] = [:]

        public init() {}

        public var count: Int { entries.count }

        fileprivate func identity(for pid: pid_t, start: UInt64) -> (path: String, name: String) {
            if let hit = entries[pid], hit.start == start { return (hit.path, hit.name) }
            let path = ProcessSampler.path(of: pid)
            let name = ProcessSampler.name(fromPath: path, pid: pid)
            entries[pid] = (start, path, name)
            return (path, name)
        }

        /// Drops processes that no longer exist, so the cache tracks the machine
        /// rather than growing for the life of the app.
        fileprivate func keep(_ live: Set<pid_t>) {
            guard entries.count != live.count else { return }
            entries = entries.filter { live.contains($0.key) }
        }
    }

    public static func sweep(reusing cache: IdentityCache? = nil) -> Sweep {
        let pids = allPIDs()
        var out: [ProcessKey: ProcessEnergy] = [:]
        var denied = 0
        for pid in pids {
            if let e = energy(of: pid, reusing: cache) { out[e.key] = e } else { denied += 1 }
        }
        cache?.keep(Set(pids))
        return Sweep(processes: out, timestamp: Date(), attempted: pids.count, denied: denied)
    }
}

/// A process's measured draw across two sweeps.
public struct ProcessDrain {
    public let name: String
    public let pid: pid_t
    public let path: String
    public let joules: Double
    public let watts: Double
    /// The headline unit: percent of battery consumed per hour.
    public let percentPerHour: Double

    /// Percent of the WHOLE machine's CPU: 0-100, whatever the thread count.
    ///
    /// NOT Activity Monitor's convention, deliberately. Activity Monitor reports
    /// percent of one core, so a busy four-thread process reads 400% there. That
    /// number cannot be read against anything else this app shows: a row saying
    /// "30%" next to a utilisation bar saying "9%" reads as a contradiction, when
    /// 30% of one core out of fifteen is 2% of the machine and the two agree.
    ///
    /// It is therefore directly comparable to `CPUUsage.total` and to
    /// `HistoryStore`'s identically-named utilisation figure, which is the point:
    /// the mismatch is what once printed "CPU 129.0% in use" on a machine sitting
    /// at 17.3%. These now sum to something that belongs on the same axis.
    public let cpuPercent: Double
    /// Physical footprint right now. Instantaneous, so it is not differenced.
    public let memoryBytes: UInt64
    /// Read and write kept APART all the way to the table.
    ///
    /// They were summed in `DrainTracker` the moment they were read, which threw
    /// away the more useful half of the fact: a process reading 40 MB/s is warming
    /// a cache, and one writing 40 MB/s is wearing the SSD and dirtying pages the
    /// OS has to flush. One number cannot say which, and this app has already been
    /// killed once by macOS for the second kind.
    public let diskReadPerSec: Double
    public let diskWrittenPerSec: Double
    /// Both directions, for the places that legitimately want one figure — the
    /// sidebar row and the sort that ranks "busiest disk".
    public var diskBytesPerSec: Double { diskReadPerSec + diskWrittenPerSec }
}

public enum DrainCalculator {
    public static func between(_ a: ProcessSampler.Sweep,
                               _ b: ProcessSampler.Sweep,
                               scale: BatteryScale,
                               cores: Int = MachTime.activeCores) -> [ProcessDrain] {
        let dt = b.timestamp.timeIntervalSince(a.timestamp)
        guard dt > 0 else { return [] }

        var out: [ProcessDrain] = []
        for (key, now) in b.processes {
            // Skip processes absent from the first sweep. `ri_energy_nj` is cumulative
            // since process start, so treating a missing prior as 0 would attribute a
            // long-lived process's ENTIRE lifetime energy to one 3-second window the
            // first time we see it — producing huge phantom spikes. They are picked up
            // from the next tick onward.
            //
            // KNOWN GAP: genuinely short-lived processes (compilers, scripts) that both
            // start and exit between sweeps are never counted. Closing that needs the
            // exit-time accounting in CoalitionUsage.
            guard let prior = a.processes[key]?.energy_nJ else { continue }
            guard now.energy_nJ >= prior else { continue }
            let joules = Double(now.energy_nJ &- prior) / 1e9
            guard joules > 0 else { continue }

            let watts = joules / dt
            // Kept as UInt64 so the wrapping subtraction stays exact; MachTime
            // does the unit conversion.
            let cpuDeltaUnits = (now.userTime_ns &+ now.systemTime_ns)
                &- (a.processes[key]!.userTime_ns &+ a.processes[key]!.systemTime_ns)
            out.append(ProcessDrain(
                name: now.name,
                pid: key.pid,
                path: now.path,
                joules: joules,
                watts: watts,
                percentPerHour: 3600.0 * watts / scale.joulesPerPercent,
                // Percent of the whole machine — the unit the table displays.
                // MachTime, not /1e9 — see MachTime for why this was 41.667x low.
                cpuPercent: MachTime.machinePercent(units: cpuDeltaUnits, over: dt, cores: cores),
                memoryBytes: now.footprint,
                diskReadPerSec: 0,
                diskWrittenPerSec: 0
            ))
        }
        return out.sorted { $0.percentPerHour > $1.percentPerHour }
    }
}

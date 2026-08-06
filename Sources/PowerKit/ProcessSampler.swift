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

    public var key: ProcessKey { ProcessKey(pid: pid, startAbsTime: startAbsTime) }
}

public struct ProcessKey: Hashable {
    public let pid: pid_t
    public let startAbsTime: UInt64
}

public enum ProcessSampler {
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
    public static func energy(of pid: pid_t) -> ProcessEnergy? {
        var info = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard rc == 0 else { return nil }

        let p = path(of: pid)
        return ProcessEnergy(
            pid: pid,
            name: name(fromPath: p, pid: pid),
            energy_nJ: info.ri_energy_nj,
            pEnergy_nJ: info.ri_penergy_nj,
            cycles: info.ri_cycles,
            pCycles: info.ri_pcycles,
            startAbsTime: info.ri_proc_start_abstime,
            path: p
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

    public static func sweep() -> Sweep {
        let pids = allPIDs()
        var out: [ProcessKey: ProcessEnergy] = [:]
        var denied = 0
        for pid in pids {
            if let e = energy(of: pid) { out[e.key] = e } else { denied += 1 }
        }
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
}

public enum DrainCalculator {
    public static func between(_ a: ProcessSampler.Sweep,
                               _ b: ProcessSampler.Sweep,
                               scale: BatteryScale) -> [ProcessDrain] {
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
            out.append(ProcessDrain(
                name: now.name,
                pid: key.pid,
                path: now.path,
                joules: joules,
                watts: watts,
                percentPerHour: 3600.0 * watts / scale.joulesPerPercent
            ))
        }
        return out.sorted { $0.percentPerHour > $1.percentPerHour }
    }
}

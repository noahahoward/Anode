import Foundation

/// Per-process drain measured over a ROLLING WINDOW rather than between two
/// consecutive sweeps.
///
/// ## Why this exists
///
/// `ri_energy_nj` is cumulative, but the kernel does not update it continuously —
/// it flushes per-task energy in bursts. Measured on this machine, sampling once a
/// second for 15 seconds:
///
///     audioaccessoryd     15/15 seconds changed
///     lsd                 13/15
///     WindowManager        7/15
///     secd                 4/15
///     accountsd            3/15
///     CoreServicesUIAgent  0/15
///
/// Differencing two consecutive 2 s sweeps and discarding zero deltas therefore
/// throws away most processes most of the time: a process whose counter moves 3
/// times in 15 seconds appears in 3 ticks and disappears from the other 12. That
/// presented as "the app is missing tons of processes, and the ones it does find
/// only show up one refresh cycle every 10 seconds".
///
/// The sampling rate cannot fix this — sampling *faster* makes it worse, because
/// each window contains proportionally fewer counter updates. The window has to be
/// long enough to contain the updates.
///
/// ## How it works
///
/// Each process keeps a short ring of (time, cumulative energy) samples. Its rate is
/// measured across the oldest and newest samples still inside the window, so a burst
/// anywhere in that window is captured and amortised rather than appearing as one
/// spike followed by silence. Rows become stable and persistent, and the reported
/// watts are a genuine mean over the window rather than an artefact of when the
/// kernel happened to flush.
///
/// A process idle for the whole window correctly reports zero and is dropped by the
/// caller — that is a real observation, not a sampling gap.
public final class DrainTracker {

    /// How far back a rate is measured. Long enough to contain the sparse counter
    /// updates seen above; short enough to still feel live.
    public let window: TimeInterval

    private struct Sample {
        let time: Date
        let energy_nJ: UInt64
        /// user + system, nanoseconds. Same rolling treatment as energy: CPU time
        /// is also cumulative, and also updates irregularly.
        let cpu_ns: UInt64
        let diskBytes: UInt64
    }

    private var history: [ProcessKey: [Sample]] = [:]
    private var meta: [ProcessKey: (name: String, path: String, pid: pid_t)] = [:]

    public init(window: TimeInterval = 10) {
        self.window = window
    }

    /// Feed a sweep and get per-process drain measured over the rolling window.
    /// Returns rows sorted by drain descending; processes idle across the whole
    /// window are omitted.
    public func update(with sweep: ProcessSampler.Sweep, scale: BatteryScale) -> [ProcessDrain] {
        let now = sweep.timestamp
        let cutoff = now.addingTimeInterval(-window)

        var out: [ProcessDrain] = []

        for (key, proc) in sweep.processes {
            meta[key] = (proc.name, proc.path, proc.pid)

            var samples = history[key] ?? []

            // A decreasing counter means this is not the same process run: pid reuse
            // that slipped past the (pid, startAbsTime) key, or a counter reset.
            // Discard the history rather than emitting a negative or absurd rate.
            let cpu = proc.userTime_ns &+ proc.systemTime_ns
            let disk = proc.diskRead &+ proc.diskWritten
            if let last = samples.last, proc.energy_nJ < last.energy_nJ || cpu < last.cpu_ns {
                samples.removeAll()
            }

            // Only record when the value actually moved, plus the first sample.
            // Storing unchanged repeats would push the real oldest sample out of the
            // ring and shrink the effective window back toward the sampling interval,
            // reintroducing the bug this class exists to fix.
            // Record when ANY tracked counter moves — a process can burn CPU in a
            // window where the energy counter has not been flushed yet, and dropping
            // that sample would hide it from the CPU lens.
            if samples.isEmpty || samples[samples.count - 1].energy_nJ != proc.energy_nJ
                || samples[samples.count - 1].cpu_ns != cpu {
                samples.append(Sample(time: now, energy_nJ: proc.energy_nJ,
                                      cpu_ns: cpu, diskBytes: disk))
            }

            // Keep one sample older than the cutoff so the window is fully spanned
            // rather than truncated to the newest update inside it.
            if let firstInside = samples.firstIndex(where: { $0.time >= cutoff }), firstInside > 1 {
                samples.removeFirst(firstInside - 1)
            }
            history[key] = samples

            guard let oldest = samples.first, let newest = samples.last, samples.count >= 2 else {
                continue    // first sighting: no elapsed time to divide by yet
            }

            let dt = newest.time.timeIntervalSince(oldest.time)
            guard dt > 0.05, newest.energy_nJ >= oldest.energy_nJ else { continue }

            // A zero delta is emitted, not discarded. Once a process is being
            // tracked we know its rate over the window is genuinely ~0, which is a
            // measurement — dropping the row instead makes an idle app blink out of
            // the table and back, which reads as a bug and hides the app entirely
            // between bursts. The UI decides what to show: apps are always listed,
            // daemons are held to a display floor.
            let joules = Double(newest.energy_nJ &- oldest.energy_nJ) / 1e9
            let watts = joules / dt
            // Percent of ONE core-second per wall-second, matching Activity Monitor:
            // a fully busy four-thread process reads 400%, not 100%.
            let cpuPct = Double(newest.cpu_ns &- oldest.cpu_ns) / 1e9 / dt * 100
            let diskRate = Double(newest.diskBytes &- oldest.diskBytes) / dt

            out.append(ProcessDrain(
                name: proc.name,
                pid: proc.pid,
                path: proc.path,
                joules: joules,
                watts: watts,
                percentPerHour: 3600 * watts / scale.joulesPerPercent,
                cpuPercent: cpuPct,
                memoryBytes: proc.footprint,
                diskBytesPerSec: diskRate))
        }

        // Drop processes that have exited so the dictionaries cannot grow unbounded
        // over a long uptime.
        let live = Set(sweep.processes.keys)
        history = history.filter { live.contains($0.key) }
        meta = meta.filter { live.contains($0.key) }

        return out.sorted { $0.percentPerHour > $1.percentPerHour }
    }

    public func reset() {
        history.removeAll()
        meta.removeAll()
    }

    /// Processes currently being tracked — useful for diagnostics.
    public var trackedCount: Int { history.count }
}

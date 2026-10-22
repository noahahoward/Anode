import Darwin
import Foundation
import IOKit

// What Anode costs, measured by Anode — the data behind Developer Tools → Anode
// Stats.
//
// Two halves, deliberately different in what they cost while nobody is looking:
//
//  - `TickLedger` is fed by the tick itself and is ALWAYS on. It is a lock, a
//    handful of integer stores and one array append per tick, and it exists
//    because the questions it answers — how often are we really sampling, and
//    what does one tick cost — cannot be answered later from outside. The
//    cadence the timer asks for and the cadence the sampling queue delivers are
//    different numbers, and the gap between them is a finding.
//
//  - `SelfUsage` reads the kernel's own account of this process (rusage, the
//    GPU's per-client table) and is called ONLY by the stats window's timer.
//    This app's background floor is argued down to fractions of a percent of one
//    core, so nothing here may run on the hidden tick.

// MARK: - Tick ledger

/// A running account of what the sampling tick has been doing since launch.
public final class TickLedger {

    public static let shared = TickLedger()

    public enum Kind { case light, full }

    /// One finished tick on the sampling queue.
    public struct Tick {
        public let kind: Kind
        public let startedAt: Date
        /// CPU the tick's own thread burned. The queue is serial, so the thread
        /// is the tick — not the machine, and not another queue.
        public let cpu_ns: UInt64
        /// Wall time. Differs from `cpu_ns` by however long the tick sat blocked
        /// in IOKit and syscalls, which is most of it.
        public let wall_ns: UInt64
    }

    /// Why the timer is running at the rate it is. The inputs, not the English:
    /// the window words them, and this stays testable.
    public struct Mode: Equatable {
        public var effectiveInterval: TimeInterval
        public var settingInterval: TimeInterval
        public var windowVisible: Bool
        public var panelOpen: Bool
        public var drivingFans: Bool
        public var historyLogging: Bool
        public var backgroundFullInterval: TimeInterval

        /// What is setting the rate, in a few words.
        public var headline: String {
            if drivingFans { return "Holding a fan" }
            if panelOpen { return "Menu bar panel open" }
            if windowVisible { return "Window on screen" }
            return "Window hidden"
        }

        /// Why that rate and not the setting — the rule `cadence` applied.
        public var reason: String {
            func s(_ t: TimeInterval) -> String {
                t == t.rounded() ? String(format: "%.0f s", t) : String(format: "%.1f s", t)
            }
            if drivingFans { return "a held fan needs a feedback loop: \(s(effectiveInterval))" }
            if effectiveInterval > settingInterval {
                return "nobody is reading, so the background floor of \(s(effectiveInterval)) "
                    + "applies instead of your \(s(settingInterval))"
            }
            return "your setting of \(s(settingInterval))"
        }

        /// What the full tick — the per-process sweep — is doing at this rate.
        public var fullTickPolicy: String {
            if windowVisible || panelOpen { return "every tick (something is reading per-app data)" }
            return historyLogging
                ? "one a minute, to keep the history accruing"
                : "only when a widget needs one (history logging is off)"
        }

        public init(effectiveInterval: TimeInterval, settingInterval: TimeInterval,
                    windowVisible: Bool, panelOpen: Bool, drivingFans: Bool,
                    historyLogging: Bool, backgroundFullInterval: TimeInterval) {
            self.effectiveInterval = effectiveInterval
            self.settingInterval = settingInterval
            self.windowVisible = windowVisible
            self.panelOpen = panelOpen
            self.drivingFans = drivingFans
            self.historyLogging = historyLogging
            self.backgroundFullInterval = backgroundFullInterval
        }
    }

    public struct Summary {
        public var light = Tally()
        public var full = Tally()
        public var lastTick: Tick?
        public var lastFullAt: Date?
        /// Start-to-start gaps of the most recent admitted ticks, oldest first.
        public var recentGaps: [TimeInterval] = []
        /// CPU the MAIN thread spent on the other half of a tick — the part that
        /// redraws the menu bar and, when the window is up, the whole UI.
        public var main = Tally()
        public var mode: Mode?
        /// Whole-machine draw at the last tick, and the pack energy that turns
        /// watts into %/hr. nil on a desktop, or before the first full reading.
        public var machine_W: Double?
        public var joulesPerPercent: Double?
        public var dropped = 0

        public var totalTicks: Int { light.count + full.count }
    }

    /// Count and cumulative cost of one sort of tick.
    public struct Tally {
        public var count = 0
        public var cpu_ns: UInt64 = 0
        public var wall_ns: UInt64 = 0
        public var lastCPU_ns: UInt64 = 0

        public var meanCPU_ms: Double? {
            count > 0 ? Double(cpu_ns) / Double(count) / 1e6 : nil
        }
        public var meanWall_ms: Double? {
            count > 0 ? Double(wall_ns) / Double(count) / 1e6 : nil
        }
        fileprivate mutating func add(cpu: UInt64, wall: UInt64) {
            count += 1; cpu_ns &+= cpu; wall_ns &+= wall; lastCPU_ns = cpu
        }
    }

    /// 30 gaps is a minute of visible ticks and four of hidden ones — enough to
    /// see jitter, short enough to notice a cadence change.
    static let gapWindow = 30

    private let lock = NSLock()
    private var state = Summary()

    public init() {}

    /// Called from the sampling queue when a tick completes.
    public func record(kind: Kind, startedAt: Date, cpu_ns: UInt64, wall_ns: UInt64,
                       machine_W: Double?, joulesPerPercent: Double?) {
        lock.lock()
        defer { lock.unlock() }
        let tick = Tick(kind: kind, startedAt: startedAt, cpu_ns: cpu_ns, wall_ns: wall_ns)
        if let previous = state.lastTick {
            let gap = startedAt.timeIntervalSince(previous.startedAt)
            if gap > 0 {
                state.recentGaps.append(gap)
                if state.recentGaps.count > Self.gapWindow { state.recentGaps.removeFirst() }
            }
        }
        switch kind {
        case .light: state.light.add(cpu: cpu_ns, wall: wall_ns)
        case .full:
            state.full.add(cpu: cpu_ns, wall: wall_ns)
            state.lastFullAt = startedAt
        }
        state.lastTick = tick
        // Keep the last reading rather than overwrite it with nil: a light tick
        // has no pack figure, and "—" flickering between ticks is not a finding.
        if let w = machine_W { state.machine_W = w }
        if let j = joulesPerPercent { state.joulesPerPercent = j }
    }

    /// Called on the main thread for the other half of the tick.
    public func recordMain(cpu_ns: UInt64) {
        lock.lock()
        state.main.add(cpu: cpu_ns, wall: cpu_ns)
        lock.unlock()
    }

    public func note(mode: Mode, dropped: Int) {
        lock.lock()
        state.mode = mode
        state.dropped = dropped
        lock.unlock()
    }

    public func summary() -> Summary {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// Spread of the observed tick gaps. nil until there are two ticks to
    /// compare.
    public static func gapStats(_ gaps: [TimeInterval])
        -> (mean: TimeInterval, min: TimeInterval, max: TimeInterval)? {
        guard let lo = gaps.min(), let hi = gaps.max() else { return nil }
        return (gaps.reduce(0, +) / Double(gaps.count), lo, hi)
    }
}

// MARK: - This process, from the kernel

public enum SelfUsage {

    /// Cumulative counters for this process at one instant. Rates are differences
    /// between two of these; a single sample only supports the lifetime totals.
    public struct Sample {
        /// `CLOCK_UPTIME_RAW`, which stops while the machine sleeps — as does
        /// CPU time, so the two stay on the same clock and a sleep between two
        /// samples does not read as an idle spell.
        public let uptime_ns: UInt64
        public let cpu_ns: UInt64
        public let energy_nJ: UInt64
        public let footprint: UInt64
        public let peakFootprint: UInt64
        public let idleWakeups: UInt64
        public let interruptWakeups: UInt64
        public let diskRead: UInt64
        public let diskWritten: UInt64
        public let instructions: UInt64
        public let cycles: UInt64
        /// Cumulative GPU time across this process's Metal clients. nil when the
        /// registry would not say — which is not the same as zero.
        public let gpu_ns: UInt64?
        public let threads: Int?
        /// When the process began, in the same `CLOCK_UPTIME_RAW` terms — so
        /// "since launch" averages divide by the process's life, not the window's.
        public let launchedAt_ns: UInt64
    }

    public struct Rates {
        /// Percent of ONE core, Activity Monitor's convention.
        public let cpuPercent: Double
        public let watts: Double
        public let wakeupsPerSecond: Double
        public let diskReadBytesPerSecond: Double
        public let diskWriteBytesPerSecond: Double
        /// Percent of one second of GPU time per second. nil without GPU data.
        public let gpuPercent: Double?
        public let instructionsPerSecond: Double
    }

    /// Differences two samples. nil when no time has passed or a counter ran
    /// backwards — the process cannot have un-run, so that is a measurement
    /// problem, and a rate computed from it would be a made-up one.
    public static func rates(from a: Sample, to b: Sample) -> Rates? {
        guard b.uptime_ns > a.uptime_ns,
              b.cpu_ns >= a.cpu_ns, b.energy_nJ >= a.energy_nJ else { return nil }
        let dt = Double(b.uptime_ns - a.uptime_ns) / 1e9
        func per(_ x: UInt64, _ y: UInt64) -> Double { y >= x ? Double(y - x) / dt : 0 }
        var gpu: Double?
        if let ga = a.gpu_ns, let gb = b.gpu_ns, gb >= ga {
            gpu = Double(gb - ga) / 1e9 / dt * 100
        }
        return Rates(
            cpuPercent: Double(b.cpu_ns - a.cpu_ns) / 1e9 / dt * 100,
            watts: Double(b.energy_nJ - a.energy_nJ) / 1e9 / dt,
            wakeupsPerSecond: per(a.idleWakeups &+ a.interruptWakeups,
                                  b.idleWakeups &+ b.interruptWakeups),
            diskReadBytesPerSecond: per(a.diskRead, b.diskRead),
            diskWriteBytesPerSecond: per(a.diskWritten, b.diskWritten),
            gpuPercent: gpu,
            instructionsPerSecond: per(a.instructions, b.instructions))
    }

    /// Averages over the whole life of the process, from one sample. The
    /// counters are cumulative from launch, so this needs no history — which is
    /// why it is right the moment the window opens.
    public static func lifetimeRates(_ s: Sample) -> Rates? {
        guard s.uptime_ns > s.launchedAt_ns else { return nil }
        let life = Double(s.uptime_ns - s.launchedAt_ns) / 1e9
        guard life > 1 else { return nil }
        return Rates(
            cpuPercent: Double(s.cpu_ns) / 1e9 / life * 100,
            watts: Double(s.energy_nJ) / 1e9 / life,
            wakeupsPerSecond: Double(s.idleWakeups &+ s.interruptWakeups) / life,
            diskReadBytesPerSecond: Double(s.diskRead) / life,
            diskWriteBytesPerSecond: Double(s.diskWritten) / life,
            gpuPercent: s.gpu_ns.map { Double($0) / 1e9 / life * 100 },
            instructionsPerSecond: Double(s.instructions) / life)
    }

    /// Reads this process. `gpu` is separate because it walks the IORegistry and
    /// the CPU side is one syscall.
    public static func read(gpu: UInt64?) -> Sample? {
        var info = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0)
            }
        }
        guard rc == 0 else { return nil }
        // Mach ticks, not nanoseconds — see `MachTime`. Converted here so that
        // every field of `Sample` that says _ns is.
        let cpuUnits = info.ri_user_time &+ info.ri_system_time
        let cpu = UInt64(MachTime.seconds(units: cpuUnits) * 1e9)
        let launched = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            &- UInt64(MachTime.seconds(units: mach_absolute_time() &- info.ri_proc_start_abstime) * 1e9)
        return Sample(
            uptime_ns: clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
            cpu_ns: cpu,
            energy_nJ: info.ri_energy_nj,
            footprint: info.ri_phys_footprint,
            peakFootprint: info.ri_lifetime_max_phys_footprint,
            idleWakeups: info.ri_pkg_idle_wkups,
            interruptWakeups: info.ri_interrupt_wkups,
            diskRead: info.ri_diskio_bytesread,
            diskWritten: info.ri_diskio_byteswritten,
            instructions: info.ri_instructions,
            cycles: info.ri_cycles,
            gpu_ns: gpu,
            threads: threadCount(),
            launchedAt_ns: launched)
    }

    private static func threadCount() -> Int? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return Int(info.pti_threadnum)
    }
}

// MARK: - This process's GPU time

/// Cumulative GPU time for this process, from the accelerator's own client table.
///
/// Each process with a Metal device holds a user client under `IOAccelerator`,
/// tagged `IOUserClientCreator = "pid N, name"` and carrying an `AppUsage` array
/// of `accumulatedGPUTime` in NANOSECONDS (checked against wall time on this
/// machine: a process submitting nothing stays flat). It is the same table
/// Activity Monitor's GPU column reads, and it needs no privilege.
///
/// There are hundreds of clients, so the walk that finds ours happens once and
/// the entries are kept; each later read is a property copy on a few services.
/// A kept entry whose process has gone is dropped, and the next read looks again.
public final class SelfGPU {

    private var entries: [io_registry_entry_t] = []
    private var discovered = false
    private var lastDiscovery = Date.distantPast
    private let pid = getpid()

    public init() {}

    deinit { release() }

    /// nil when there is no accelerator or the registry would not answer. A
    /// process that has never touched the GPU has no client, and is 0 — it was
    /// asked and had none, which is an answer.
    public func accumulated_ns() -> UInt64? {
        // At most every ten seconds: a process that has never opened a Metal
        // device has no client to find, and walking hundreds of them once a
        // second to learn that again is the sort of cost this window exists to
        // show, not to add.
        if !discovered, Date().timeIntervalSince(lastDiscovery) > 10 { discover() }
        var total: UInt64 = 0
        var live: [io_registry_entry_t] = []
        for e in entries {
            guard let usage = IORegistryEntryCreateCFProperty(
                e, "AppUsage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            else { IOObjectRelease(e); continue }
            live.append(e)
            total &+= Self.gpuNanoseconds(inAppUsage: usage)
        }
        let lost = live.count != entries.count
        entries = live
        // A client can appear after the first look (the first Metal call comes
        // late in a window's life), so look again whenever we hold none.
        if lost || entries.isEmpty { discovered = false }
        return total
    }

    /// Sums `accumulatedGPUTime` across an `AppUsage` array. Pure, so the shape
    /// the registry returns is pinned by a test rather than by a running GPU.
    public static func gpuNanoseconds(inAppUsage usage: Any) -> UInt64 {
        guard let rows = usage as? [[String: Any]] else { return 0 }
        return rows.reduce(0) { sum, row in
            sum &+ ((row["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0)
        }
    }

    /// True for "pid 68304, AnodeApp" when the pid is ours. Exact on the number,
    /// so pid 683 never claims pid 6830's client.
    public static func creator(_ text: String, isPID pid: pid_t) -> Bool {
        text.hasPrefix("pid \(pid),")
    }

    private func discover() {
        release()
        discovered = true
        lastDiscovery = Date()
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &accelerators) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(accelerators) }
        while case let accel = IOIteratorNext(accelerators), accel != 0 {
            defer { IOObjectRelease(accel) }
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accel, kIOServicePlane, &children)
                    == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(children) }
            while case let child = IOIteratorNext(children), child != 0 {
                let creator = IORegistryEntryCreateCFProperty(
                    child, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
                if let creator, Self.creator(creator, isPID: pid) {
                    entries.append(child)      // keep the reference
                } else {
                    IOObjectRelease(child)
                }
            }
        }
    }

    private func release() {
        entries.forEach { IOObjectRelease($0) }
        entries = []
    }
}

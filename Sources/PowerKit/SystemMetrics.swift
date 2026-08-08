import Darwin
import Foundation
import IOKit

/// CPU, memory, GPU and network utilisation.
///
/// These are the classic system-monitor readings. They are deliberately kept apart
/// from the power model: utilisation is NOT power. A GPU at 100% and a GPU at 20%
/// can draw similar wattage depending on clocks, and CPU percent says nothing about
/// which cores. Everything here answers "how busy", never "how much battery" — that
/// question is only ever answered by the joule path.
///
/// All four sources are unprivileged and were verified on this machine.

// ─────────────────────────────────────────────────────────────────────────────
// MARK: CPU

/// Whole-machine CPU utilisation from cumulative kernel tick counters.
///
/// `host_statistics(HOST_CPU_LOAD_INFO)` returns ticks since boot, so a single read
/// is meaningless — utilisation only exists between two samples. This holds the
/// previous read and reports the mean across that interval.
public final class CPUUsage {

    public struct Sample {
        /// 0…100 across all cores combined.
        public let total: Double
        public let user: Double
        public let system: Double
        public let idle: Double
        public let interval: TimeInterval
    }

    private var previous: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var previousAt: Date?

    public init() {}

    private func read() -> (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)? {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size
                                          / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard rc == KERN_SUCCESS else { return nil }
        return (info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3)
    }

    /// nil on the first call — there is no interval to average over yet.
    public func sample() -> Sample? {
        guard let now = read() else { return nil }
        let at = Date()
        defer { previous = now; previousAt = at }

        guard let prev = previous, let prevAt = previousAt else { return nil }

        // Tick counters are UInt32 and DO wrap on long uptimes. Wrapping
        // subtraction keeps a wrap from producing a nonsense negative delta.
        let du = Double(now.user &- prev.user)
        let ds = Double(now.system &- prev.system)
        let di = Double(now.idle &- prev.idle)
        let dn = Double(now.nice &- prev.nice)
        let total = du + ds + di + dn
        guard total > 0 else { return nil }

        return Sample(total: (du + ds + dn) / total * 100,
                      user: (du + dn) / total * 100,
                      system: ds / total * 100,
                      idle: di / total * 100,
                      interval: at.timeIntervalSince(prevAt))
    }

    public static var coreCount: Int { ProcessInfo.processInfo.processorCount }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Memory

public enum MemoryUsage {

    public struct Sample {
        public let total: UInt64
        /// What Activity Monitor calls "Memory Used": app memory + wired + compressed.
        public let used: UInt64
        public let wired: UInt64
        public let compressed: UInt64
        public let app: UInt64
        public let free: UInt64
        public var usedPercent: Double {
            total == 0 ? 0 : Double(used) / Double(total) * 100
        }
    }

    public static var totalBytes: UInt64 {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        return sysctlbyname("hw.memsize", &size, &len, nil, 0) == 0 ? size : 0
    }

    public static func sample() -> Sample? {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
                                          / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let rc = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard rc == KERN_SUCCESS else { return nil }

        let page = UInt64(vm_kernel_page_size)
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        // "App memory" is internal (anonymous) pages minus what is purgeable —
        // purgeable pages are reclaimable on demand, so counting them as used
        // overstates pressure. This is the same split Activity Monitor shows.
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = (internalPages > purgeable ? internalPages - purgeable : 0) * page

        return Sample(total: totalBytes,
                      used: app + wired + compressed,
                      wired: wired,
                      compressed: compressed,
                      app: app,
                      free: UInt64(stats.free_count) * page)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: GPU

public enum GPUUsage {

    public struct Sample {
        /// 0…100. Utilisation, NOT power — see the note at the top of this file.
        public let utilization: Double
        public let rendererUtilization: Double?
        public let inUseMemory: UInt64?
        public let allocatedMemory: UInt64?
    }

    /// Reads `PerformanceStatistics` from the accelerator node. Unprivileged;
    /// verified reporting "Device Utilization %" = 67 on this M5 Pro.
    ///
    /// The class name differs by generation (`IOAccelerator` on Apple Silicon,
    /// `AGXAccelerator` historically), so both are tried rather than assuming one.
    public static func sample() -> Sample? {
        for className in ["IOAccelerator", "AGXAccelerator"] {
            guard let match = IOServiceMatching(className) else { continue }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS
            else { continue }
            defer { IOObjectRelease(iterator) }

            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                var props: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
                        == KERN_SUCCESS,
                      let dict = props?.takeRetainedValue() as? [String: Any],
                      let perf = dict["PerformanceStatistics"] as? [String: Any]
                else { continue }

                func num(_ key: String) -> Double? { (perf[key] as? NSNumber)?.doubleValue }
                guard let util = num("Device Utilization %") ?? num("GPU Activity(%)")
                else { continue }

                return Sample(
                    utilization: util,
                    rendererUtilization: num("Renderer Utilization %"),
                    inUseMemory: num("In use system memory").map { UInt64($0) },
                    allocatedMemory: num("Alloc system memory").map { UInt64($0) })
            }
        }
        return nil
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Network

/// Throughput from per-interface byte counters.
///
/// Like the CPU ticks these are cumulative since boot, so throughput only exists
/// between two samples. Loopback is excluded — it is real traffic but it never
/// leaves the machine, and counting it makes local IPC look like network activity.
///
/// The counter source matters more than it looks. `getifaddrs`' `ifa_data` is a
/// `struct if_data`, whose `ifi_ibytes`/`ifi_obytes` are `u_int32_t` — 4 GiB of
/// traffic and the counter is back at zero, which at 1 Gbit/s is every ~34 s. A
/// difference taken across that wrap is negative, so the reading blanked out
/// precisely during the large transfer you opened the app to watch. Verified on
/// this machine: `getifaddrs` reported en0 out = 2,581,578,752 while the true
/// count was 6,876,546,330 — low 32 bits only.
///
/// `sysctl(NET_RT_IFLIST2)` is the usual answer and is NOT one here: its
/// `if_msghdr2.ifm_data` is declared `struct if_data64` (8-byte fields, checked),
/// but this kernel fills only the low 32 bits of the byte counts. Measured by
/// pushing 7 GB over lo0: that path read 3,392,594,944 where the true count was
/// 7,687,562,848 — short by exactly 2^32, with the high word left zero.
///
/// `net.link.generic.ifdata` (`IFMIB_IFALLDATA`, what `netstat -ib` itself uses)
/// returns the same `if_data64` with the counters at full width — it matched
/// `netstat` byte for byte across the same experiment. That is the source below,
/// so the wrap is removed rather than compensated for.
public final class NetworkThroughput {

    public struct Interface {
        public let name: String
        public let inPerSec: Double
        public let outPerSec: Double
        public var totalPerSec: Double { inPerSec + outPerSec }
    }

    public struct Sample {
        public let bytesInPerSec: Double
        public let bytesOutPerSec: Double
        public var totalPerSec: Double { bytesInPerSec + bytesOutPerSec }
        /// Per-interface breakdown, busiest first. Which link the traffic is on
        /// matters: 12 MB/s is saturation on Wi-Fi and idle on Thunderbolt.
        public let interfaces: [Interface]
        public let interval: TimeInterval
    }

    /// One interface's cumulative counters, at the kernel's full 64-bit width.
    struct Counters: Equatable {
        var inBytes: UInt64
        var outBytes: UInt64
    }

    /// 100 Gbit/s, above any link this machine can physically have — Thunderbolt 5
    /// networking tops out at 80. Nothing plausible is ever rejected by this; it
    /// exists so that a counter doing something unexplained becomes a missing row
    /// rather than a headline number, the same bargain `Store.maxPlausibleWatts`
    /// and `Sensors.plausible` make.
    static let maxPlausibleBytesPerSec: Double = 12.5e9

    private var previous: [String: Counters] = [:]
    private var previousAt: Date?

    public init() {}

    /// nil on the first call — throughput only exists between two reads — and
    /// whenever the counters cannot be read at all. It is NOT nil merely because
    /// an interface went away or reset: the aggregate is the sum of the
    /// per-interface deltas, so the surviving links still report.
    public func sample() -> Sample? {
        guard let now = Self.readCounters() else { return nil }
        return sample(counters: now, at: Date())
    }

    /// The half of `sample()` that does not touch the kernel, so the wrap, reset
    /// and disappearing-interface paths can be driven exactly in tests.
    func sample(counters now: [String: Counters], at: Date) -> Sample? {
        let was = previous
        let wasAt = previousAt
        // Replacing the map wholesale rather than merging into it is load-bearing.
        // An interface that vanished this tick must not leave its counters behind
        // as a baseline: utun3 going down and a new utun3 coming up minutes later
        // would otherwise be differenced against a dead tunnel's totals.
        previous = now
        previousAt = at

        guard let wasAt, !was.isEmpty else { return nil }
        let dt = at.timeIntervalSince(wasAt)
        guard dt > 0.05 else { return nil }

        var inTotal = 0.0
        var outTotal = 0.0
        var rows: [Interface] = []
        var contributing = 0

        for (name, cur) in now {
            // No baseline: first sight of this interface. It contributes nothing
            // this tick and everything from the next one.
            guard let old = was[name] else { continue }

            // At 64 bits a byte counter does not wrap in any human timescale
            // (2^64 bytes is centuries of 100 Gbit/s), so a decrease is a counter
            // reset — the interface was torn down and recreated under the same
            // name — never a wrap. Differencing across it with wrapping arithmetic
            // would turn a 0.1 GiB → 0 reset into a ~4.2 GiB delta and print
            // gigabytes per second, so the interface is simply dropped for this
            // tick; `previous` already holds its fresh baseline.
            guard cur.inBytes >= old.inBytes, cur.outBytes >= old.outBytes else { continue }

            let inRate = Double(cur.inBytes - old.inBytes) / dt
            let outRate = Double(cur.outBytes - old.outBytes) / dt
            guard inRate <= Self.maxPlausibleBytesPerSec,
                  outRate <= Self.maxPlausibleBytesPerSec else { continue }

            contributing += 1
            inTotal += inRate
            outTotal += outRate
            if inRate + outRate > 0 {
                rows.append(Interface(name: name, inPerSec: inRate, outPerSec: outRate))
            }
        }

        // Every interface either new or dropped: there is no interval anything can
        // be said about. Zero would be a claim of silence rather than of ignorance.
        guard contributing > 0 else { return nil }

        rows.sort { $0.totalPerSec > $1.totalPerSec }
        return Sample(bytesInPerSec: inTotal,
                      bytesOutPerSec: outTotal,
                      interfaces: rows,
                      interval: dt)
    }

    /// Every non-loopback interface's cumulative byte counters, keyed by BSD name.
    ///
    /// One sysctl for the whole table — `IFMIB_IFALLDATA` returns a packed array
    /// of `struct ifmibdata`, whose `ifmd_data` is the full-width `if_data64`.
    /// Measured at ~20 µs for 22 interfaces, which is the point: this runs on
    /// every tick of a monitor that must not cost what it measures.
    static func readCounters() -> [String: Counters]? {
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFALLDATA, 0, IFDATA_GENERAL]
        let recordSize = MemoryLayout<ifmibdata>.size

        var needed = 0
        guard sysctl(&mib, u_int(mib.count), nil, &needed, nil, 0) == 0,
              needed >= recordSize else { return nil }

        // Slack for interfaces appearing between the sizing call and the read —
        // a VPN coming up at that instant would otherwise cost ENOMEM and a tick.
        var buffer = [UInt8](repeating: 0, count: needed + recordSize * 4)
        var got = buffer.count
        guard buffer.withUnsafeMutableBytes({ raw in
            sysctl(&mib, u_int(mib.count), raw.baseAddress, &got, nil, 0)
        }) == 0, got >= recordSize else { return nil }

        // A length that is not a whole number of records means the struct the
        // kernel is writing is not the one this was compiled against, and walking
        // it at the wrong stride would read the wrong fields. Report nothing.
        guard got % recordSize == 0 else { return nil }

        var out: [String: Counters] = [:]
        buffer.withUnsafeBytes { raw in
            for index in 0..<(got / recordSize) {
                let entry = raw.loadUnaligned(fromByteOffset: index * recordSize, as: ifmibdata.self)
                let name = Self.name(of: entry)
                guard !name.isEmpty, !name.hasPrefix("lo") else { continue }
                out[name] = Counters(inBytes: entry.ifmd_data.ifi_ibytes,
                                     outBytes: entry.ifmd_data.ifi_obytes)
            }
        }
        return out.isEmpty ? nil : out
    }

    /// `ifmd_name` is a fixed 16-byte field, not a string — read it bounded and
    /// stop at the NUL rather than trusting one to be there.
    private static func name(of entry: ifmibdata) -> String {
        withUnsafeBytes(of: entry.ifmd_name) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Aggregate

/// One place the app can pull every non-power reading, so the sampling loop does
/// not grow a new dependency per metric.
public final class SystemMetrics {
    public struct Snapshot {
        public let cpu: CPUUsage.Sample?
        public let memory: MemoryUsage.Sample?
        public let gpu: GPUUsage.Sample?
        public let network: NetworkThroughput.Sample?
        public let cpuTemperature: Double?
        public let gpuTemperature: Double?
        public let fans: [FanInfo]
    }

    private let cpu = CPUUsage()
    private let net = NetworkThroughput()
    /// Sensor discovery walks 3,588 SMC keys on first use, so it is not something
    /// to do on every tick of a monitor that must stay near zero cost.
    private var lastSensors: (cpu: Double?, gpu: Double?, fans: [FanInfo], at: Date)?
    private let sensorInterval: TimeInterval = 5

    public init() {}

    /// Which subsystems a caller actually needs this tick.
    ///
    /// Every one of these costs a syscall or an IOKit round trip, and while the
    /// window is hidden the only reader is whatever the menu bar widgets are bound
    /// to. Computing a GPU utilisation nobody displays is pure battery cost in an
    /// app whose entire premise is not costing what it measures.
    public struct Needs: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let cpu     = Needs(rawValue: 1 << 0)
        public static let memory  = Needs(rawValue: 1 << 1)
        public static let gpu     = Needs(rawValue: 1 << 2)
        public static let network = Needs(rawValue: 1 << 3)
        public static let sensors = Needs(rawValue: 1 << 4)
        public static let all: Needs = [.cpu, .memory, .gpu, .network, .sensors]
    }

    public func sample(needs: Needs) -> Snapshot {
        var cpuTemp: Double?
        var gpuTemp: Double?
        var fans: [FanInfo] = []

        if needs.contains(.sensors) {
            if let last = lastSensors, Date().timeIntervalSince(last.at) < sensorInterval {
                cpuTemp = last.cpu; gpuTemp = last.gpu; fans = last.fans
            } else {
                // ONE sweep, three figures. These used to be three separate
                // calls, and each one re-reads every classified SMC key and
                // every fan — there is no cache beneath them. Measured: 88 ms
                // wall / 9.1 ms CPU per sweep, so three cost 264 ms / 28 ms to
                // read the same keys three times. At this 5 s cadence that was
                // 0.56% of one core, larger than every other window-open cost
                // in the app combined.
                let inv = Sensors.inventory()
                cpuTemp = inv.cpuTemperature
                gpuTemp = inv.gpuTemperature
                fans = inv.fans
                lastSensors = (cpuTemp, gpuTemp, fans, Date())
            }
        }

        // A skipped subsystem yields its zero/empty value, NOT a stale one. The
        // registry then reports "no data" rather than a number from a minute ago
        // that looks live.
        return Snapshot(cpu: needs.contains(.cpu) ? cpu.sample() : nil,
                        memory: needs.contains(.memory) ? MemoryUsage.sample() : nil,
                        gpu: needs.contains(.gpu) ? GPUUsage.sample() : nil,
                        network: needs.contains(.network) ? net.sample() : nil,
                        cpuTemperature: cpuTemp,
                        gpuTemperature: gpuTemp,
                        fans: fans)
    }

    public func sample(includeSensors: Bool = true) -> Snapshot {
        var cpuTemp: Double?
        var gpuTemp: Double?
        var fans: [FanInfo] = []

        if includeSensors {
            if let last = lastSensors, Date().timeIntervalSince(last.at) < sensorInterval {
                cpuTemp = last.cpu; gpuTemp = last.gpu; fans = last.fans
            } else {
                // ONE sweep, three figures. These used to be three separate
                // calls, and each one re-reads every classified SMC key and
                // every fan — there is no cache beneath them. Measured: 88 ms
                // wall / 9.1 ms CPU per sweep, so three cost 264 ms / 28 ms to
                // read the same keys three times. At this 5 s cadence that was
                // 0.56% of one core, larger than every other window-open cost
                // in the app combined.
                let inv = Sensors.inventory()
                cpuTemp = inv.cpuTemperature
                gpuTemp = inv.gpuTemperature
                fans = inv.fans
                lastSensors = (cpuTemp, gpuTemp, fans, Date())
            }
        }

        return Snapshot(cpu: cpu.sample(),
                        memory: MemoryUsage.sample(),
                        gpu: GPUUsage.sample(),
                        network: net.sample(),
                        cpuTemperature: cpuTemp,
                        gpuTemperature: gpuTemp,
                        fans: fans)
    }
}

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
public final class NetworkThroughput {

    public struct Sample {
        public let bytesInPerSec: Double
        public let bytesOutPerSec: Double
        public var totalPerSec: Double { bytesInPerSec + bytesOutPerSec }
        public let interval: TimeInterval
    }

    private var previous: (inBytes: UInt64, outBytes: UInt64)?
    private var previousAt: Date?

    public init() {}

    private func read() -> (inBytes: UInt64, outBytes: UInt64)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let start = head else { return nil }
        defer { freeifaddrs(head) }

        var inB: UInt64 = 0, outB: UInt64 = 0
        var cur: UnsafeMutablePointer<ifaddrs>? = start
        while let ptr = cur {
            defer { cur = ptr.pointee.ifa_next }
            // Only AF_LINK entries carry if_data; the AF_INET aliases would
            // double-count the same interface.
            guard let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK),
                  let raw = ptr.pointee.ifa_data else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard !name.hasPrefix("lo") else { continue }

            let d = raw.assumingMemoryBound(to: if_data.self).pointee
            inB &+= UInt64(d.ifi_ibytes)
            outB &+= UInt64(d.ifi_obytes)
        }
        return (inB, outB)
    }

    /// nil on the first call, and whenever the counters go backwards — an
    /// interface disappearing (VPN down, dock unplugged) reduces the total, and
    /// reporting that as negative throughput would be nonsense.
    public func sample() -> Sample? {
        guard let now = read() else { return nil }
        let at = Date()
        defer { previous = now; previousAt = at }

        guard let prev = previous, let prevAt = previousAt else { return nil }
        let dt = at.timeIntervalSince(prevAt)
        guard dt > 0.05, now.inBytes >= prev.inBytes, now.outBytes >= prev.outBytes
        else { return nil }

        return Sample(bytesInPerSec: Double(now.inBytes - prev.inBytes) / dt,
                      bytesOutPerSec: Double(now.outBytes - prev.outBytes) / dt,
                      interval: dt)
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

    public func sample(includeSensors: Bool = true) -> Snapshot {
        var cpuTemp: Double?
        var gpuTemp: Double?
        var fans: [FanInfo] = []

        if includeSensors {
            if let last = lastSensors, Date().timeIntervalSince(last.at) < sensorInterval {
                cpuTemp = last.cpu; gpuTemp = last.gpu; fans = last.fans
            } else {
                cpuTemp = Sensors.cpuTemperature()
                gpuTemp = Sensors.gpuTemperature()
                fans = Sensors.fans()
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

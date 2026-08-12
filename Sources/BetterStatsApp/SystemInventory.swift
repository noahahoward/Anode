import Darwin
import Foundation
import IOKit
import SystemConfiguration

/// The facts about this machine that never change while it is running, and the
/// ones that change slowly enough that reading them every tick would be waste.
///
/// Lives in the app rather than in PowerKit because none of it is a power
/// measurement — it is the "what am I looking at" header the Resources tab needs
/// so its numbers have something to be numbers OF.
enum MachineInfo {

    /// One `hw.perflevelN` cluster, WITH THE KERNEL'S OWN NAME FOR IT.
    ///
    /// The name is read, never assumed. This code used to map perflevel0 to
    /// "performance" and perflevel1 to "efficiency", which is the split every
    /// Apple-silicon write-up describes and is WRONG on this machine: an M5 Pro
    /// (Mac17,9) reports `hw.perflevel0.name = "Super"` and
    /// `hw.perflevel1.name = "Performance"` — there is no level called
    /// "Efficiency" at all, so the old label printed "5 performance · 10
    /// efficiency" for a machine whose kernel says 5 Super and 10 Performance.
    /// `hw.nperflevels` is also read rather than assumed to be 2.
    struct CoreLevel {
        let name: String
        let physical: Int
        let logical: Int
        let l1dCacheBytes: Int?
        let l1iCacheBytes: Int?
        let l2CacheBytes: Int?
    }

    struct Facts {
        let model: String
        let chip: String
        /// The core clusters, fastest first, as the kernel names them. Empty on
        /// hardware that publishes no `hw.perflevel*` tree at all.
        let coreLevels: [CoreLevel]
        let physicalCores: Int
        let logicalCores: Int
        let memoryBytes: UInt64
        /// `hw.memsize_usable` — what the kernel will actually hand out, which is
        /// less than what is fitted by whatever firmware has carved off (0.9 GB
        /// here). Task Manager calls the difference "Hardware reserved". nil where
        /// the sysctl does not exist, rather than assumed equal to `memoryBytes`.
        let usableMemoryBytes: UInt64?
        let pageSizeBytes: Int?
        let osVersion: String
        let bootTime: Date?

        /// "5 Super + 10 Performance", or just the total when there is no split to
        /// report. Built from the kernel's names, so it cannot go stale against a
        /// future part with three levels or different words.
        var coreSummary: String {
            guard !coreLevels.isEmpty else { return "\(logicalCores)" }
            return coreLevels.map { "\($0.physical) \($0.name)" }.joined(separator: " + ")
        }
    }

    /// Read once. `hw.model` cannot change without a reboot, and neither can the
    /// core counts — re-reading them on a 2 s tick is a dozen syscalls for a dozen
    /// constants.
    static let facts: Facts = Facts(
        model: string("hw.model") ?? "Mac",
        chip: string("machdep.cpu.brand_string") ?? "Apple silicon",
        coreLevels: coreLevels(),
        physicalCores: integer("hw.physicalcpu")
            ?? integer("hw.logicalcpu") ?? ProcessInfo.processInfo.processorCount,
        logicalCores: integer("hw.logicalcpu") ?? ProcessInfo.processInfo.processorCount,
        memoryBytes: UInt64(integer("hw.memsize") ?? 0),
        usableMemoryBytes: integer("hw.memsize_usable").map(UInt64.init),
        pageSizeBytes: integer("hw.pagesize"),
        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        bootTime: bootTime())

    /// NOMINAL CPU FREQUENCY IS NOT AVAILABLE, and nothing here invents one.
    ///
    /// Windows' Task Manager prints "Base speed: 2.30 GHz" next to a live "Speed"
    /// reading, and both come from an SMBIOS field Apple silicon has no equivalent
    /// of. Checked on this machine (Mac17,9, macOS 27): `hw.cpufrequency`,
    /// `hw.cpufrequency_max`, `hw.cpufrequency_min` and `hw.busfrequency` are all
    /// ABSENT — the sysctls do not exist, so there is not even a zero to
    /// misinterpret. `hw.tbfrequency` (24 MHz) exists and is the timebase counter's
    /// rate, which is a constant of the timer and says nothing about core clocks.
    ///
    /// A per-cluster P-state residency histogram does exist in IOReport
    /// (`CPU Stats`/`CPU Complex Performance States`) and could in principle be
    /// folded into a mean frequency, but the DVFS table naming those states is not
    /// published and would have to be guessed. So there is no Speed row and no Base
    /// speed row, rather than a plausible number.
    static let nominalFrequencyHz: Double? = nil

    /// MEMORY MODULE SPEED, FORM FACTOR AND SLOT COUNT ARE NOT AVAILABLE EITHER.
    ///
    /// Task Manager fills those from SPD data on a DIMM. There is no DIMM here:
    /// the RAM is on the package, and macOS publishes nothing standing in for SPD.
    /// Searched on this machine and found nothing usable — `IODeviceTree:/memory`
    /// carries a `compat-dimm-serial-number` whose contents are the literal
    /// placeholder strings "0x01234567" and "0x76543210", `IOService:/AppleARMPE/
    /// memory` does not exist, and `AppleSMBIOSMemory` matches zero nodes. The one
    /// remaining source is `system_profiler SPMemoryDataType`, which on Apple
    /// silicon reports the same absence and costs a subprocess to hear it.
    ///
    /// So the Memory detail states total, page size and the usage split, and has no
    /// Speed row at all.
    static let memoryModuleSpeed: String? = nil

    private static func coreLevels() -> [CoreLevel] {
        let levels = integer("hw.nperflevels") ?? 0
        return (0..<max(0, levels)).compactMap { index in
            let prefix = "hw.perflevel\(index)"
            guard let physical = integer("\(prefix).physicalcpu") else { return nil }
            return CoreLevel(
                name: string("\(prefix).name") ?? "Level \(index)",
                physical: physical,
                logical: integer("\(prefix).logicalcpu") ?? physical,
                l1dCacheBytes: integer("\(prefix).l1dcachesize"),
                l1iCacheBytes: integer("\(prefix).l1icachesize"),
                l2CacheBytes: integer("\(prefix).l2cachesize"))
        }
    }

    // ── Live whole-machine figures ──────────────────────────────────────────

    struct Swap {
        let totalBytes: UInt64
        let usedBytes: UInt64
        let isEncrypted: Bool
    }

    /// Backing store usage. A machine that has never swapped reports a total of
    /// zero, which is a measurement rather than a missing one.
    static func swap() -> Swap? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return Swap(totalBytes: usage.xsu_total,
                    usedBytes: usage.xsu_used,
                    isEncrypted: usage.xsu_encrypted != 0)
    }

    /// How many processes are running, and how many threads they hold.
    ///
    /// The process count is EXACT: `proc_listallpids` enumerates every task
    /// regardless of owner. The thread count is not, and the shortfall is reported
    /// rather than hidden. `proc_pidinfo(PROC_PIDTASKINFO)` needs the same
    /// credentials as the process it is asked about, so an unprivileged session
    /// reads its own processes and is refused for root's — measured here, 563 of
    /// 906 readable. Publishing 2,541 as "Threads" would be understating the
    /// machine by roughly a third with no sign that anything was missing, so the
    /// caller is handed the denominator and prints it.
    ///
    /// MEASURED: 0.48 ms of CPU for the full sweep of ~900 processes, which is why
    /// the Resources tab only pays for it while the CPU detail is the one on screen.
    struct Census {
        let processes: Int
        let threads: Int
        /// Processes whose thread count could be read. `threads` covers these only.
        let processesRead: Int
        var isComplete: Bool { processesRead == processes }
    }

    static func census() -> Census? {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return nil }
        // Slack for processes spawning between the sizing call and the read, the
        // same bargain `NetworkThroughput.readCounters` makes with its interface
        // table: a launch at that instant would otherwise truncate the list.
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return nil }

        let infoSize = Int32(MemoryLayout<proc_taskinfo>.size)
        var threads = 0
        var read = 0
        for index in 0..<Int(count) {
            var info = proc_taskinfo()
            guard proc_pidinfo(pids[index], PROC_PIDTASKINFO, 0, &info, infoSize) == infoSize
            else { continue }
            threads += Int(info.pti_threadnum)
            read += 1
        }
        return Census(processes: Int(count), threads: threads, processesRead: read)
    }

    /// Seconds since boot. This one is not a constant, so it is computed from the
    /// cached boot instant rather than cached itself.
    static var uptime: TimeInterval? {
        facts.bootTime.map { Date().timeIntervalSince($0) }
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        let days = s / 86400, hours = (s % 86400) / 3600, minutes = (s % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // The kernel counts the trailing NUL in `size`; String(cString:) stops at it
        // anyway, but a value that is somehow unterminated must not read past the end.
        buffer[size - 1] = 0
        return String(cString: buffer)
    }

    private static func integer(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        // Some of these keys are 32-bit and some 64-bit, and sysctl writes only as
        // many bytes as the key has. Reading a 4-byte key into an Int64 leaves the
        // high word as whatever was there, so the width the kernel reported decides.
        return size == 4 ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }

    private static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// What the accelerator says it is, as opposed to how busy it is.
///
/// `GPUUsage` in PowerKit reads `PerformanceStatistics` on every tick; this reads
/// the identity keys beside it exactly once. Same registry node, different
/// lifetime — a GPU does not change model between ticks.
enum GPUInfo {

    struct Facts {
        let model: String?
        let coreCount: Int?
    }

    /// Verified on this machine: `model` = "Apple M5 Pro" and `gpu-core-count` = 16
    /// on the `AGXAcceleratorG17X` node. Both are nil-able because neither key is
    /// documented and a future part may simply not carry them — an absent row beats
    /// a guessed core count.
    ///
    /// NOT FOUND, and therefore not shown: any nominal or maximum GPU clock, and
    /// any figure for dedicated video memory. The latter does not exist to be
    /// found — the memory is unified, and `In use system memory` (which IS read,
    /// per tick, by `GPUUsage`) is a share of the same RAM the Memory card counts.
    static let facts: Facts = read()

    private static func read() -> Facts {
        for className in ["IOAccelerator", "AGXAccelerator"] {
            guard let match = IOServiceMatching(className) else { continue }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator)
                    == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }

            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                var props: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
                        == KERN_SUCCESS,
                      let dict = props?.takeRetainedValue() as? [String: Any] else { continue }
                let cores = (dict["gpu-core-count"] as? NSNumber)?.intValue
                let model = Self.text(dict["model"])
                if model != nil || cores != nil {
                    return Facts(model: model, coreCount: cores)
                }
            }
        }
        return Facts(model: nil, coreCount: nil)
    }

    /// IORegistry string properties arrive as either an NSString or a NUL-terminated
    /// `Data` blob depending on whether the kext published a CFString or a device
    /// tree property. `model` on this machine is the latter.
    private static func text(_ value: Any?) -> String? {
        if let s = value as? String { return s.isEmpty ? nil : s }
        guard let d = value as? Data else { return nil }
        let s = String(decoding: d.prefix { $0 != 0 }, as: UTF8.self)
        return s.isEmpty ? nil : s
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Which network interfaces exist, what kind each is, and how to reach them.
///
/// WHY NOT "THE FIRST INTERFACE UP". This machine has twenty-two of them: three
/// `anpi*` links to the co-processors, four Thunderbolt `en*` ports, a bridge, an
/// `ap1`, an `awdl0`, an `llw0`, a `nan0`, and FOUR `utun*` tunnels because the
/// user runs WireGuard — every one of them flagged UP and RUNNING. Picking the
/// first would name a tunnel or a co-processor link as "the network". The primary
/// interface is asked for by name instead: `State:/Network/Global/IPv4` names the
/// service macOS is actually routing through, which on this machine is `en7`
/// ("Thunderbolt Ethernet Slot 0") with Wi-Fi `en0` up beside it.
///
/// MAIN THREAD ONLY. The shared `SCDynamicStore` and the caches below have no
/// locking; the Resources pane is their only caller and it runs on main.
enum NetworkInventory {

    /// What kind of link this is, which is what the Resources card renames itself
    /// after — "the network graph got renamed ethernet if plugged in".
    enum Kind {
        case wifi, ethernet, thunderbolt, bridge, tunnel, peerToPeer, other

        var title: String {
            switch self {
            case .wifi:        return "Wi-Fi"
            case .ethernet:    return "Ethernet"
            case .thunderbolt: return "Thunderbolt"
            case .bridge:      return "Bridge"
            case .tunnel:      return "VPN"
            case .peerToPeer:  return "Peer-to-peer Wi-Fi"
            case .other:       return "Network"
            }
        }

        /// The rail's glyph for a machine connected THIS way.
        ///
        /// The tab used to wear `network` — a wire-frame globe, which reads as
        /// "the internet" in the abstract and is the least specific thing it could
        /// say. The Wi-Fi arc is far more universally recognised, and that is the
        /// right instinct; taken literally it would also be a lie on this machine,
        /// which is on Ethernet. So the glyph follows the link instead: the arc
        /// when the traffic really is over Wi-Fi, a cable when it is not.
        ///
        /// Falls back to the arc when nothing is routing at all — an unconnected
        /// machine has no link to describe, and the arc is the shape people read
        /// as "network" fastest.
        var symbolName: String {
            switch self {
            case .wifi, .peerToPeer: return "wifi"
            case .ethernet:          return "cable.connector"
            case .thunderbolt:       return "bolt.horizontal"
            case .tunnel:            return "lock.shield"
            case .bridge, .other:    return "wifi"
            }
        }
    }

    struct Interface {
        let bsdName: String
        /// The name macOS shows in Network settings, e.g. "Wi-Fi" or "Thunderbolt
        /// Ethernet Slot 0". nil for the interfaces SystemConfiguration does not
        /// model as services — every `utun*`, `awdl0`, `llw0` and `anpi*` here.
        let displayName: String?
        let kind: Kind
        let ipv4: [String]
        let ipv6: [String]
        let macAddress: String?
        /// `if_data.ifi_baudrate`: the NEGOTIATED link rate, not a nominal one.
        /// Measured here as 1,000,000,000 on the Ethernet adapter and 748,800,000
        /// on Wi-Fi, which is a live PHY rate and moves as the radio adapts. Zero
        /// means the driver publishes none, and becomes nil rather than "0 bps".
        let linkSpeedBitsPerSec: UInt64?
        let mtu: Int?
        let isRunning: Bool
    }

    struct Snapshot {
        let interfaces: [Interface]
        /// BSD name of the interface macOS is routing through, or nil when nothing
        /// is — an offline machine has no primary interface, and inventing one
        /// would title the card after a link carrying nothing.
        let primaryBSDName: String?
        let dnsServers: [String]
        let searchDomains: [String]

        func interface(_ bsdName: String) -> Interface? {
            interfaces.first { $0.bsdName == bsdName }
        }
        var primary: Interface? { primaryBSDName.flatMap(interface) }
    }

    /// Classify a link. Pure string logic, kept separate from the syscalls so the
    /// cases that matter — Wi-Fi against Ethernet against a WireGuard tunnel — can
    /// be driven in a test rather than waiting for the right cable to be plugged in.
    ///
    /// SystemConfiguration's answer wins where it has one, because it comes from
    /// the driver's own service type. Where it has none the BSD name prefix is
    /// the only evidence there is, and these prefixes are stable kernel
    /// conventions rather than guesses.
    ///
    /// SC has none more often than you would expect. Its public headers define
    /// no bridge type and no VPN type at all — the complete set is Ethernet,
    /// IEEE80211, PPP, IPSec, L2TP, PPTP, Bond, VLAN, Modem, Serial, FireWire,
    /// IrDA, WWAN, Bluetooth, 6to4 and IPv4. So `bridge0` and `utun*` are
    /// classified by prefix below and nowhere else. Do not reach for
    /// `kSCNetworkInterfaceTypeBridge` or `…TypeVPN`: they read like they ought
    /// to exist, and neither does.
    ///
    /// The one genuine heuristic is inside `Ethernet`, which SC returns for both a
    /// real Ethernet adapter ("Thunderbolt Ethernet Slot 0") and for the IP-over-
    /// Thunderbolt links ("Thunderbolt 1"). The display name is what tells them
    /// apart, so a link that says Ethernet anywhere in its name is Ethernet, and a
    /// Thunderbolt one that does not is a Thunderbolt link.
    static func classify(bsdName: String, serviceType: String?, displayName: String?) -> Kind {
        if let serviceType {
            if serviceType == kSCNetworkInterfaceTypeIEEE80211 as String { return .wifi }
            if serviceType == kSCNetworkInterfaceTypePPP as String
                || serviceType == kSCNetworkInterfaceTypeIPSec as String
                || serviceType == kSCNetworkInterfaceTypeL2TP as String { return .tunnel }
            if serviceType == kSCNetworkInterfaceTypeEthernet as String {
                let name = displayName ?? ""
                if name.localizedCaseInsensitiveContains("ethernet") { return .ethernet }
                if name.localizedCaseInsensitiveContains("thunderbolt") { return .thunderbolt }
                return .ethernet
            }
        }
        for (prefix, kind) in [("utun", Kind.tunnel), ("ipsec", .tunnel), ("ppp", .tunnel),
                               ("tap", .tunnel), ("gif", .tunnel), ("stf", .tunnel),
                               ("awdl", .peerToPeer), ("llw", .peerToPeer),
                               ("bridge", .bridge), ("ap", .wifi), ("en", .ethernet)]
        where bsdName.hasPrefix(prefix) {
            return kind
        }
        // anpi* (the links to the co-processors), nan0, and anything a future
        // kernel invents. Named "Network" rather than guessed at.
        return .other
    }

    // ── Reading ─────────────────────────────────────────────────────────────

    /// Addresses and flags move when a cable is plugged in, which is not a 2 s
    /// event; 3 s of staleness is invisible and takes `getifaddrs` off the tick.
    private static let ttl: TimeInterval = 3
    private static var cached: (snapshot: Snapshot, at: Date)?

    static func snapshot(now: Date = Date()) -> Snapshot {
        if let c = cached, now.timeIntervalSince(c.at) < ttl { return c.snapshot }
        let fresh = read()
        cached = (fresh, now)
        return fresh
    }

    private static var store: SCDynamicStore? = SCDynamicStoreCreate(
        nil, "BetterStats.NetworkInventory" as CFString, nil, nil)

    /// BSD name → what SystemConfiguration knows about it.
    ///
    /// MEASURED: `SCNetworkInterfaceCopyAll` is 2.0 ms of CPU, which is four times
    /// the whole per-process thread sweep and far too much for a 2 s tick. The set
    /// of physical adapters only changes when hardware is plugged in, so it is
    /// cached and re-read only when a link turns up that is not in the map — and
    /// then at most every 30 s, so an interface SC will never model (every `utun*`)
    /// cannot turn the cache into a per-tick re-read.
    private struct Service {
        let type: String?
        let displayName: String?
        let macAddress: String?
    }
    private static var services: [String: Service] = [:]
    private static var servicesReadAt: Date?

    private static func service(for bsdName: String, now: Date) -> Service? {
        if let known = services[bsdName] { return known }
        if let at = servicesReadAt, now.timeIntervalSince(at) < 30 { return nil }
        servicesReadAt = now
        var fresh: [String: Service] = [:]
        for iface in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String? else { continue }
            fresh[bsd] = Service(
                type: SCNetworkInterfaceGetInterfaceType(iface) as String?,
                displayName: SCNetworkInterfaceGetLocalizedDisplayName(iface) as String?,
                macAddress: SCNetworkInterfaceGetHardwareAddressString(iface) as String?)
        }
        services = fresh
        return services[bsdName]
    }

    private static func read(now: Date = Date()) -> Snapshot {
        var addresses: [String: (v4: [String], v6: [String])] = [:]
        var links: [String: (speed: UInt64, mtu: Int, running: Bool)] = [:]
        var order: [String] = []

        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0, let head = list {
            var cursor: UnsafeMutablePointer<ifaddrs>? = head
            while let entry = cursor {
                defer { cursor = entry.pointee.ifa_next }
                let name = String(cString: entry.pointee.ifa_name)
                // Loopback is excluded here for the same reason `NetworkThroughput`
                // excludes it from the counters: it is real traffic that never
                // leaves the machine, and a "network" that lists lo0 is not the
                // question anyone is asking.
                guard !name.hasPrefix("lo") else { continue }
                if addresses[name] == nil { order.append(name); addresses[name] = ([], []) }
                guard let sa = entry.pointee.ifa_addr else { continue }
                let running = entry.pointee.ifa_flags & UInt32(IFF_RUNNING) != 0

                switch Int32(sa.pointee.sa_family) {
                case AF_INET, AF_INET6:
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                                      &host, socklen_t(host.count),
                                      nil, 0, NI_NUMERICHOST) == 0 else { continue }
                    // The scope suffix on a link-local ("fe80::1%en0") names the
                    // interface we are already standing on; keeping it would print
                    // the interface twice on its own row.
                    let text = String(cString: host).components(separatedBy: "%")[0]
                    if Int32(sa.pointee.sa_family) == AF_INET {
                        addresses[name]?.v4.append(text)
                    } else {
                        addresses[name]?.v6.append(text)
                    }
                case AF_LINK:
                    guard let raw = entry.pointee.ifa_data else { continue }
                    let data = raw.assumingMemoryBound(to: if_data.self).pointee
                    links[name] = (UInt64(data.ifi_baudrate), Int(data.ifi_mtu), running)
                default:
                    break
                }
            }
            freeifaddrs(list)
        }

        var interfaces: [Interface] = []
        for name in order {
            let sc = service(for: name, now: now)
            let link = links[name]
            interfaces.append(Interface(
                bsdName: name,
                displayName: sc?.displayName,
                kind: classify(bsdName: name, serviceType: sc?.type,
                               displayName: sc?.displayName),
                ipv4: addresses[name]?.v4 ?? [],
                ipv6: addresses[name]?.v6 ?? [],
                macAddress: sc?.macAddress,
                // Zero is "the driver publishes no rate", not "a zero-speed link".
                linkSpeedBitsPerSec: (link?.speed).flatMap { $0 > 0 ? $0 : nil },
                mtu: link?.mtu,
                isRunning: link?.running ?? false))
        }

        var primary: String?
        var dns: [String] = []
        var domains: [String] = []
        if let store {
            let global = SCDynamicStoreCopyValue(
                store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
            primary = global?["PrimaryInterface"] as? String
            // IPv6-only networks route through the v6 key instead, and a machine on
            // one has no v4 primary at all.
            if primary == nil {
                let v6 = SCDynamicStoreCopyValue(
                    store, "State:/Network/Global/IPv6" as CFString) as? [String: Any]
                primary = v6?["PrimaryInterface"] as? String
            }
            let resolver = SCDynamicStoreCopyValue(
                store, "State:/Network/Global/DNS" as CFString) as? [String: Any]
            dns = resolver?["ServerAddresses"] as? [String] ?? []
            domains = resolver?["SearchDomains"] as? [String] ?? []
        }
        return Snapshot(interfaces: interfaces, primaryBSDName: primary,
                        dnsServers: dns, searchDomains: domains)
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Mounted volumes and how full they are.
///
/// "Drive x: y GB / z TB" is a question about the filesystem, not about power, and
/// nothing in this app answered it before. `URLResourceValues` is the honest source:
/// `volumeAvailableCapacityForImportantUsage` is what the Finder shows, and it
/// differs from raw free space by however much is currently purgeable — reporting
/// the raw figure would say a full disk had 200 GB free.
enum StorageInfo {

    struct Volume {
        let name: String
        let totalBytes: Int64
        /// Free space the system would actually let you use, after purging what it
        /// can. nil when the volume declines to report it.
        let availableBytes: Int64?
        let isInternal: Bool
        var usedBytes: Int64? { availableBytes.map { max(0, totalBytes - $0) } }
        var usedFraction: Double? {
            guard totalBytes > 0, let used = usedBytes else { return nil }
            return min(1, Double(used) / Double(totalBytes))
        }
    }

    /// Volume capacity moves in gigabytes over hours, so a 2 s tick re-reading it is
    /// pure cost. Held for 30 s, which is far shorter than any change a user could
    /// notice and long enough that the Resources tab does not stat every mount
    /// fifteen times a minute.
    private static let ttl: TimeInterval = 30
    private static var cached: (volumes: [Volume], at: Date)?

    static func volumes(now: Date = Date()) -> [Volume] {
        if let c = cached, now.timeIntervalSince(c.at) < ttl { return c.volumes }
        let found = read()
        cached = (found, now)
        return found
    }

    private static func read() -> [Volume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsInternalKey, .volumeIsBrowsableKey,
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            // Skip the hidden ones: this machine mounts four OS cryptexes and a
            // preboot volume that no user thinks of as a drive.
            options: [.skipHiddenVolumes]) else { return [] }

        var out: [Volume] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable ?? true,
                  let total = values.volumeTotalCapacity, total > 0 else { continue }
            out.append(Volume(
                name: values.volumeName ?? url.lastPathComponent,
                totalBytes: Int64(total),
                availableBytes: values.volumeAvailableCapacityForImportantUsage,
                isInternal: values.volumeIsInternal ?? false))
        }
        // Internal disks first, then largest — the boot volume is the one being
        // looked for, and on this machine it is also the only internal one.
        return out.sorted {
            $0.isInternal != $1.isInternal ? $0.isInternal : $0.totalBytes > $1.totalBytes
        }
    }
}

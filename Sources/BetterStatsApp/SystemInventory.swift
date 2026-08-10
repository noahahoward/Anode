import Foundation

/// The facts about this machine that never change while it is running, and the
/// ones that change slowly enough that reading them every tick would be waste.
///
/// Lives in the app rather than in PowerKit because none of it is a power
/// measurement — it is the "what am I looking at" header the Resources tab needs
/// so its numbers have something to be numbers OF.
enum MachineInfo {

    struct Facts {
        let model: String
        let chip: String
        /// Performance and efficiency core counts, where the kernel publishes the
        /// split. nil on hardware that has no such split to publish.
        let performanceCores: Int?
        let efficiencyCores: Int?
        let logicalCores: Int
        let memoryBytes: UInt64
        let osVersion: String
        let bootTime: Date?
    }

    /// Read once. `hw.model` cannot change without a reboot, and neither can the
    /// core counts — re-reading them on a 2 s tick is six syscalls for six
    /// constants.
    static let facts: Facts = Facts(
        model: string("hw.model") ?? "Mac",
        chip: string("machdep.cpu.brand_string") ?? "Apple silicon",
        performanceCores: integer("hw.perflevel0.logicalcpu"),
        efficiencyCores: integer("hw.perflevel1.logicalcpu"),
        logicalCores: integer("hw.logicalcpu") ?? ProcessInfo.processInfo.processorCount,
        memoryBytes: UInt64(integer("hw.memsize") ?? 0),
        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        bootTime: bootTime())

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

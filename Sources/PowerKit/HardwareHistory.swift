import Foundation

/// The recent readings behind the hardware view's graphs.
///
/// In memory only: it starts empty when the window opens, is dropped when the
/// window closes, and is never written to disk. One value is kept per tick
/// (oldest dropped past `capacity`), and a tick on which a reading was missing
/// keeps a gap (nil) rather than a zero, so a graph shows the break.
///
/// Units are the readings' own: °C, rpm, bytes per second, bytes, watts.
public final class HardwareHistory {

    public enum Channel: Hashable {
        case cpuTemp
        case gpuTemp
        case fanRPM(index: Int)
        case netDown
        case netUp
        case storageRead
        /// Memory in use (app + wired + compressed), in bytes.
        case memoryUsed
        case displayWatts
    }

    private struct Entry {
        var cpuTemp: Double?
        var gpuTemp: Double?
        var fans: [Int: Double]
        var netDown: Double?
        var netUp: Double?
        var storageRead: Double?
        var memoryUsed: Double?
        var displayWatts: Double?
    }

    public let capacity: Int
    private var entries: [Entry] = []
    private let lock = NSLock()

    public init(capacity: Int = 120) {
        self.capacity = max(1, capacity)
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    public func append(_ r: HardwareReadings) {
        var fans: [Int: Double] = [:]
        if r.fansMeasured {
            for f in r.fans { fans[f.index] = f.rpm }
        }
        let used: Double? = r.memory.map { Double($0.app &+ $0.wired &+ $0.compressed) }
        let entry = Entry(cpuTemp: r.cpuTemp.value,
                          gpuTemp: r.gpuTemp.value,
                          fans: fans,
                          netDown: r.network?.down,
                          netUp: r.network?.up,
                          storageRead: r.storage?.readBPS,
                          memoryUsed: used,
                          displayWatts: r.display?.watts.value)
        lock.lock(); defer { lock.unlock() }
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// The channel's values, oldest first. nil entries are ticks with no
    /// reading.
    public func series(_ c: Channel) -> [Double?] {
        lock.lock(); defer { lock.unlock() }
        return entries.map { e -> Double? in
            switch c {
            case .cpuTemp: return e.cpuTemp
            case .gpuTemp: return e.gpuTemp
            case .fanRPM(let index): return e.fans[index]
            case .netDown: return e.netDown
            case .netUp: return e.netUp
            case .storageRead: return e.storageRead
            case .memoryUsed: return e.memoryUsed
            case .displayWatts: return e.displayWatts
            }
        }
    }
}

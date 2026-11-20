import Darwin
import Foundation

// Memory Watch, the high-memory warning: a late safety net beside the leak tiers.
//
// The leak tiers ask "is this process growing?". This part asks "is the Mac running out of memory, whoever is to blame?":
// the kernel says memory pressure has been up for a while, or swap has grown large, or one app holds half of the RAM. Like
// `MemoryGrowth.swift` the decision is pure: numbers in, a verdict out, no clock, no disk, no process spawned. The one
// reading it needs is `SystemMemoryReader.read()`, which is two unprivileged system calls (the same ones Activity Monitor's
// memory figures come from) and nothing else.

/// One look at the whole machine's memory.
public struct SystemMemoryReading: Equatable {
    /// Physical RAM.
    public var totalBytes: UInt64
    /// App + wired + compressed memory, as Activity Monitor's "Memory Used".
    public var usedBytes: UInt64
    /// Swap in use right now (`vm.swapusage`'s used field): occupancy, not the amount ever written.
    public var swapUsedBytes: UInt64
    /// The kernel's own verdict: 1 normal, 2 warning, 4 critical. nil when it could not be read.
    public var pressureLevel: Int32?

    public init(totalBytes: UInt64, usedBytes: UInt64, swapUsedBytes: UInt64 = 0, pressureLevel: Int32? = nil) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.swapUsedBytes = swapUsedBytes
        self.pressureLevel = pressureLevel
    }

    /// Memory in use as a percentage of RAM (0 when the total is unknown).
    public var usedPercent: Double {
        totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes) * 100
    }
}

/// The one read the high-memory warning makes per tick, and only while the feature is on.
///
/// `MemoryUsage.sample()` (one `host_statistics64` call, `hw.memsize` and `kern.memorystatus_vm_pressure_level`) plus
/// `vm.swapusage`. Every one of them is readable without any privilege; nothing is spawned and no helper is involved.
public enum SystemMemoryReader {

    public static func read() -> SystemMemoryReading? {
        guard let m = MemoryUsage.sample(), m.total > 0 else { return nil }
        return SystemMemoryReading(totalBytes: m.total,
                                   usedBytes: min(m.used, m.total),
                                   swapUsedBytes: swapUsedBytes() ?? 0,
                                   pressureLevel: m.pressureLevel)
    }

    /// `vm.swapusage`: an `xsw_usage` struct. nil when the system call fails.
    static func swapUsedBytes() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage.xsu_used
    }
}

/// Every threshold the high-memory warning decides by, in one place. Starting values, tuned against real use.
public struct PressureRules: Equatable {

    /// The kernel's pressure level at warning (2, the orange of Activity Monitor's graph) or above, held this long. Two
    /// minutes: a build or a test run pushes the level up for a minute and lets it fall, and nobody needs telling.
    public var warningSeconds: Double = 120
    /// The kernel's pressure level at critical (4), held this long.
    public var criticalSeconds: Double = 15

    /// Swap in use at or above `max(swapMinBytes, swapFractionOfRAM x RAM)`, held `swapSeconds`. Both numbers must be
    /// passed: a 64 GB Mac with 3 GB of swap is fine, and so is an 8 GB Mac with 1.5 GB.
    public var swapFractionOfRAM: Double = 0.25
    public var swapMinBytes: UInt64 = 4 << 30
    public var swapSeconds: Double = 120
    /// Whether swap use raises an alert of its own. OFF by default: macOS leaves swap files in use long after pressure has
    /// gone, so a Mac that is running well can show gigabytes of swap, and the warning must follow the pressure level.
    public var watchesSwap: Bool = false

    /// The single largest app at or above this share of physical RAM, held `dominantSeconds`.
    public var dominantShareOfRAM: Double = 0.50
    public var dominantSeconds: Double = 300
    /// Whether one app holding a large share of the RAM raises an alert of its own. OFF by default for the same reason:
    /// the warning follows the pressure level (orange, then red), and a slow leak is the leak detector's to find.
    public var watchesDominantApp: Bool = false

    /// After a warning or a critical alert, the same level may not fire again until pressure has been back to normal AND
    /// no other rule has been true for this long.
    public var rearmSeconds: Double = 180
    /// The shortest gap between two alerts of the same level. A critical alert is not held back by a warning's cooldown.
    public var warningCooldownSeconds: Double = 1800
    public var criticalCooldownSeconds: Double = 600

    /// How many apps the finding lists (the largest first).
    public var topAppsCount: Int = 3
    /// When a verdict fires, only processes at least this big are looked up by path to group into apps.
    public var topAppMinProcessBytes: UInt64 = 100 << 20
    /// The most executable paths read when a verdict fires (cached paths cost nothing).
    public var maxPathLookups: Int = 64

    public init() {}

    /// Pressure only: orange (level 2) held two minutes is the warning, red (level 4) held 15 seconds is the critical one.
    public static let standard = PressureRules()

    /// The first version's rules: a warning after one minute, and swap and one big app as triggers of their own. Kept so
    /// those rules stay tested and can be switched on again; nothing uses them by default.
    public static var everything: PressureRules {
        var r = PressureRules()
        r.warningSeconds = 60
        r.watchesSwap = true
        r.watchesDominantApp = true
        return r
    }

    /// The swap level the swap rule needs on a Mac with this much RAM.
    public func swapThreshold(totalBytes: UInt64) -> UInt64 {
        max(swapMinBytes, UInt64(max(0, swapFractionOfRAM * Double(totalBytes))))
    }
}

/// Why the high-memory warning fired. When several are true at once the highest wins:
/// `critical` > `warning` > `swap` > `oneAppDominates`.
public enum PressureReason: Equatable {
    /// The kernel reports critical memory pressure.
    case critical
    /// The kernel reports memory pressure (warning or worse).
    case warning
    /// A lot of swap is in use.
    case swap
    /// One app holds half of the RAM or more.
    case oneAppDominates
}

/// One app in the high-memory warning's list: every process of an app added together.
public struct PressureApp: Equatable {
    public var name: String
    /// The outermost `.app` bundle path for an app, else the executable path (`IdentityKey`).
    public var identityKey: String
    public var isApp: Bool
    public var bytes: UInt64

    public init(name: String, identityKey: String, isApp: Bool, bytes: UInt64) {
        self.name = name
        self.identityKey = identityKey
        self.isApp = isApp
        self.bytes = bytes
    }
}

/// What the tracker saw when it decided to warn.
public struct PressureVerdict: Equatable {
    public let reason: PressureReason
    public let reading: SystemMemoryReading
    /// The largest app's footprint at the moment (an estimate from the candidate table).
    public let topAppBytes: UInt64
    /// How long the condition behind `reason` had been true, in awake seconds.
    public let sustainedSeconds: Double
}

/// The high-memory warning's state: four sustained-condition timers, two cooldowns and the re-arm flags. A plain value of
/// a fixed size (a few optional numbers and two booleans) with nothing on the heap, so keeping it costs nothing.
///
/// Each of the four rules is true or false at every reading; a timer holds the time its rule BECAME true, or nil. A rule
/// that goes false even for one reading loses its timer, so a reading that flaps (up 40 s, down 10 s, up 40 s) never
/// reaches a 60 s rule. A verdict is returned only on the reading that makes a rule sustained, and only when the level it
/// belongs to may fire:
///
/// - Two levels exist. CRITICAL is the critical reason. WARNING is the warning, swap and one-app-dominates reasons.
/// - A level fires at most once per cooldown (`criticalCooldownSeconds`, `warningCooldownSeconds`), and after it fires it
///   stays quiet until the machine has been calm (pressure normal, swap and one-app rules false) for `rearmSeconds`.
/// - A critical alert may fire while the warning level is cooling down (things got worse), and it also uses up the warning
///   level (a warning straight after a critical alert would say less than what was just said).
/// - A warning-level alert does not fire while a critical alert is cooling down.
///
/// `t` is awake seconds and must not go backwards; if it does, the timers start over.
public struct PressureTracker: Equatable {

    private var criticalSince: Double?
    private var warningSince: Double?
    private var swapSince: Double?
    private var dominantSince: Double?
    /// When the machine became calm (pressure normal and neither swap nor one-app rule true).
    private var calmSince: Double?
    private var lastCriticalAt: Double?
    private var lastWarningAt: Double?
    private var criticalNeedsRearm = false
    private var warningNeedsRearm = false
    private var lastT: Double?

    public init() {}

    /// Forget everything: timers, cooldowns and re-arm state.
    public mutating func reset() { self = PressureTracker() }

    /// A sleep or a suspension is the absence of readings, not a run of high ones: every timer starts again. Cooldowns and
    /// the re-arm state are kept (they run on the awake clock and an alert already given is still given).
    public mutating func noteGap() {
        criticalSince = nil
        warningSince = nil
        swapSince = nil
        dominantSince = nil
        calmSince = nil
        lastT = nil
    }

    /// Feed one reading. Returns a verdict only on the reading that makes a rule sustained and allowed to fire.
    ///
    /// - Parameters:
    ///   - reading: the machine's memory now.
    ///   - topAppBytes: the largest app's footprint now.
    ///   - t: awake seconds.
    ///   - rules: every threshold; `.standard` unless a test says otherwise.
    public mutating func ingest(_ reading: SystemMemoryReading, topAppBytes: UInt64, at t: TimeInterval,
                                rules: PressureRules = .standard) -> PressureVerdict? {
        if let last = lastT, t < last {
            // The clock went backwards: trust nothing measured across it.
            noteGap()
            if let c = lastCriticalAt, c > t { lastCriticalAt = t }
            if let w = lastWarningAt, w > t { lastWarningAt = t }
        }
        lastT = t

        let level = reading.pressureLevel ?? 1
        let critical = level >= 4
        let warning = level >= 2
        let swap = rules.watchesSwap && reading.swapUsedBytes >= rules.swapThreshold(totalBytes: reading.totalBytes)
        let dominant = rules.watchesDominantApp && reading.totalBytes > 0
            && topAppBytes >= UInt64(max(0, rules.dominantShareOfRAM * Double(reading.totalBytes)))
        let calm = !warning && !swap && !dominant

        Self.track(&criticalSince, critical, t)
        Self.track(&warningSince, warning, t)
        Self.track(&swapSince, swap, t)
        Self.track(&dominantSince, dominant, t)
        Self.track(&calmSince, calm, t)

        // Back to normal for long enough: both levels may fire again.
        if let c = calmSince, t - c >= rules.rearmSeconds {
            criticalNeedsRearm = false
            warningNeedsRearm = false
        }

        let criticalCooling = Self.cooling(lastCriticalAt, rules.criticalCooldownSeconds, t)

        if let s = criticalSince, t - s >= rules.criticalSeconds, !criticalNeedsRearm, !criticalCooling {
            lastCriticalAt = t
            criticalNeedsRearm = true
            warningNeedsRearm = true
            return PressureVerdict(reason: .critical, reading: reading, topAppBytes: topAppBytes, sustainedSeconds: t - s)
        }

        guard !warningNeedsRearm, !criticalCooling, !Self.cooling(lastWarningAt, rules.warningCooldownSeconds, t) else {
            return nil
        }
        var reason: PressureReason?
        var since = 0.0
        if let s = warningSince, t - s >= rules.warningSeconds {
            reason = .warning; since = s
        } else if let s = swapSince, t - s >= rules.swapSeconds {
            reason = .swap; since = s
        } else if let s = dominantSince, t - s >= rules.dominantSeconds {
            reason = .oneAppDominates; since = s
        }
        guard let why = reason else { return nil }
        lastWarningAt = t
        warningNeedsRearm = true
        return PressureVerdict(reason: why, reading: reading, topAppBytes: topAppBytes, sustainedSeconds: t - since)
    }

    // MARK: Arithmetic

    /// A timer starts on the first reading its rule is true, and is dropped on the first reading it is false.
    private static func track(_ since: inout Double?, _ on: Bool, _ t: Double) {
        if on {
            if since == nil { since = t }
        } else {
            since = nil
        }
    }

    private static func cooling(_ last: Double?, _ cooldown: Double, _ t: Double) -> Bool {
        guard let l = last else { return false }
        return t - l < cooldown
    }
}

/// Sizes in the high-memory warning's sentences: "38 GB", "64 GB", "1.5 GB", "512 MB". Binary units, as macOS shows memory.
enum MemorySizeText {
    static func text(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / Double(1 << 30)
        if gib >= 1 {
            let rounded = (gib * 10).rounded() / 10
            if rounded == rounded.rounded() { return "\(Int(rounded)) GB" }
            return String(format: "%.1f GB", rounded)
        }
        let mib = Double(bytes) / Double(1 << 20)
        return "\(Int(mib.rounded())) MB"
    }
}

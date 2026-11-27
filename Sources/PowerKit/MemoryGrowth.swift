import Darwin
import Foundation

// Memory Watch, the pure core: when does one process's memory look like a leak?
//
// Nothing here reads the machine, keeps time or touches the disk. Every input is a number handed in, so the whole of it
// is played in tests against synthetic series. `MemoryWatch` (the candidate table) feeds it; the app layer shows what it
// finds.

/// Every threshold Memory Watch decides by, in one place so they are easy to find and to tune against real traces.
///
/// These are starting values, not facts: the checks reject, in turn, tiny rises, noise on big processes, a single jump, a
/// rise that already stopped, one big allocation and a process still warming up. Nothing outside this struct holds a
/// threshold.
public struct GrowthRules: Equatable {

    // How the rolling window is cut.
    /// The shortest span a verdict may rest on. Four buckets of `minBucketSeconds` make exactly this.
    public var windowSeconds: Double = 60
    /// The shortest bucket. A bucket is `max(minBucketSeconds, bucketCadenceFactor x the cadence it opens at)` long, so a
    /// slow cadence stretches the window (a 30 s cadence gives 60 s buckets and a window near 240 s).
    public var minBucketSeconds: Double = 15
    public var bucketCadenceFactor: Double = 2

    // What a window must show.
    /// Net growth over the window, in bytes: at least this ...
    public var minNetGrowthBytes: UInt64 = 50 << 20
    /// ... and at least this fraction of the footprint the window started at (noise on a big process).
    public var minNetGrowthFraction: Double = 0.10
    /// Each of the four buckets must have gained at least this share of the net growth (a jump, a plateau and slow drift
    /// all fail it, whatever the cadence).
    public var minBucketShareOfNet: Double = 0.10
    /// No single sample-to-sample rise may be more than this share of the net growth (one big allocation).
    public var maxLargestStepShare: Double = 0.50

    // What a dip may be before the growth no longer counts as sustained.
    /// A sample below the window's high-water mark by more than the largest of these re-anchors the window.
    public var dipToleranceMinBytes: UInt64 = 8 << 20
    public var dipToleranceFractionOfStart: Double = 0.02
    public var dipToleranceFractionOfGrowth: Double = 0.25

    // Who may be flagged, and when.
    /// A process younger than this is warming up, not leaking.
    public var minProcessAgeSeconds: Double = 180
    /// After a sleep or a suspension every window starts again, and nothing is flagged for this long.
    public var quietAfterGapSeconds: Double = 120
    /// Growth while a process is busy is expected (a long test run streaming output, an export, a build), and growth while
    /// it is nearly idle is the high-confidence leak signature. A window whose average CPU use was at least this share of
    /// ONE core (0.25 is a quarter of a core, may exceed 1 for several threads) is not judged; the window slides and is
    /// judged again at the next hop. Unknown CPU never gates. The slow tier sets this to infinity: a leaking app that is
    /// used all day is busy, and it still has to be found, slowly.
    public var maxBusyFraction: Double = 0.25

    /// What counts as a sample having risen at all (informational: it feeds the explanation, never a verdict).
    public var risingEpsilonMinBytes: UInt64 = 256 << 10
    public var risingEpsilonFraction: Double = 0.001

    // The candidate table (`MemoryWatch`).
    public var maxCandidates: Int = 32
    /// A process that gained this much since the previous discovery is looked at first.
    public var ascenderMinGainBytes: UInt64 = 24 << 20
    /// After the ascenders, the largest processes at least this big fill the table.
    public var largeProcessMinBytes: UInt64 = 150 << 20
    /// How often a discovery pass may run off full sweeps, and (with no full sweep for as long) off a footprint-only pass.
    public var sweepDiscoveryIntervalSeconds: Double = 30
    public var probeDiscoveryIntervalSeconds: Double = 60
    /// A candidate that has not moved by more than `flatToleranceBytes` for this long, and is not among the largest, goes.
    public var flatEvictionSeconds: Double = 300
    public var flatToleranceBytes: UInt64 = 1 << 20
    /// A finding keeps its process in the table this long (the diagnostic window may open on it).
    public var pinSeconds: Double = 600
    /// At most one notification per app in this long (more flagged helpers of the same app collapse into it).
    public var notifyCooldownSeconds: Double = 600

    // The slow tier (`GrowthRules.slow`): a second tracker per candidate that sees leaks too slow for the fast one.
    /// How often a candidate is fed to its slow tracker, in awake seconds. A table entry checks one number against the
    /// clock on every tick and does nothing else for the slow tier until this long has passed.
    public var slowFeedIntervalSeconds: Double = 300
    /// Points in a candidate's slow ring: 48 at 300 s is about four hours, enough for the diagnostic graph to show the
    /// whole slow climb.
    public var slowRingCapacity: Int = 48

    public init() {}

    public static let standard = GrowthRules()

    /// The slow tier's rules: the same tracker over a two-hour window cut into four 30-minute buckets, fed once per
    /// `slowFeedIntervalSeconds`. It rejects the same things the fast rules do (a jump, a plateau, a rise that already
    /// stopped, noise on a big process, a young process), only measured over hours: 768 MiB and 15 % net growth, so about
    /// 6.4 MiB a minute is the slowest leak it can see, and 9 MiB a minute on a 3 GiB process is found in a little over two
    /// hours. Every threshold of the slow tier is here and nowhere else.
    public static let slow: GrowthRules = {
        var r = GrowthRules.standard
        r.windowSeconds = 7200
        r.minBucketSeconds = 1800
        r.minNetGrowthBytes = 768 << 20
        r.minNetGrowthFraction = 0.15
        r.minBucketShareOfNet = 0.10
        r.maxLargestStepShare = 0.50
        r.minProcessAgeSeconds = 1800
        r.dipToleranceMinBytes = 32 << 20
        r.slowFeedIntervalSeconds = 300
        r.slowRingCapacity = 48
        r.maxBusyFraction = .infinity
        return r
    }()
}

/// Which of a candidate's two trackers raised a finding.
public enum GrowthTier: Equatable {
    /// Fifty megabytes or more inside a minute or so: a leak that is happening now.
    case fast
    /// A steady climb over hours that the fast tier cannot see.
    case slow
    /// Not a leak: the Mac as a whole is low on memory (the high-memory warning, `PressureTracker`).
    case pressure
}

/// One reading of a process's footprint, for the graph.
public struct MemorySample: Equatable {
    /// Awake-clock seconds (`PowerMonitor.awakeSeconds()`): monotonic, and a sleep does not count.
    public var seconds: Double
    public var bytes: UInt64
    public init(seconds: Double, bytes: UInt64) { self.seconds = seconds; self.bytes = bytes }
}

/// What a tracker saw when it decided a process looks like a leak.
public struct GrowthVerdict: Equatable {
    public let startBytes: UInt64
    public let nowBytes: UInt64
    /// The span the verdict rests on, in awake seconds: at least `GrowthRules.windowSeconds`.
    public let windowSeconds: Double
    /// The average length of the four buckets.
    public let bucketSeconds: Double
    public let risingSamples: Int
    public let totalSamples: Int
    /// An upper bound on how far memory ever fell back from its high-water mark inside the window.
    public let largestDipBytes: UInt64
    public let largestStepBytes: UInt64
    /// The CPU the process used over the window, as a share of ONE core (0.8 is 80 %, may exceed 1). Nil when the CPU
    /// time was not handed in, or not for the whole window.
    public let cpuFraction: Double?

    public var netGrowthBytes: UInt64 { nowBytes > startBytes ? nowBytes - startBytes : 0 }
}

/// One process's rolling window: four buckets in a ring, a fixed handful of numbers, no allocation.
///
/// The buckets measure TIME, not samples, and they are continuous: a bucket starts at the previous bucket's last sample,
/// so a bucket that holds a single sample (an 8 s cadence against a 15 s bucket) still measures growth over its whole
/// span. The window is evaluated once per rotation, so a 15 s hop. `t` is awake seconds; the caller deals with sleeps (it
/// calls `reset(quietUntil:)`), because a sleep is the absence of samples, not "no growth".
///
/// "Rose in N of M samples" is counted for the explanation text only. It is not a gate: a leak that allocates in chunks
/// rises on a third of the samples at a 2 s cadence and on nearly all at 8 s, and gating on it would flag the same leak
/// with the window closed and miss it with the window open.
public struct GrowthTracker {

    public enum Phase: UInt8, Equatable {
        /// The window is not yet four buckets long, or the process is too young.
        case learning
        /// A full window is being judged once per hop.
        case watching
        /// A finding was raised; this tracker never raises another.
        case reported
        /// After a sleep: nothing is tracked until `quietUntil`.
        case quiet
    }

    /// One slice of the window. 40 bytes.
    private struct Bucket {
        var end: UInt64
        var peak: UInt64
        var endTime: Double
        /// The largest single rise between two samples, in KiB.
        var largestStepKiB: UInt32
        /// CPU time used while this bucket was filling, in milliseconds (the sum of the sample-to-sample rises).
        var cpuMs: UInt32
        var rising: UInt8
        var samples: UInt8
        /// How many of `samples` came with a CPU time to take a rise from. The bucket's `cpuMs` is the whole truth only
        /// when this equals `samples`.
        var cpuSeen: UInt8

        static func opening(at bytes: UInt64, _ t: Double) -> Bucket {
            Bucket(end: bytes, peak: bytes, endTime: t, largestStepKiB: 0, cpuMs: 0, rising: 0, samples: 0, cpuSeen: 0)
        }
    }

    // Four fields, not an array: the tracker is a plain value of a fixed size with nothing on the heap. Slot `cur` is the
    // bucket being filled; the `closed` slots before it (wrapping) are finished; the oldest starts at `anchorBytes`.
    private var b0 = Bucket.opening(at: 0, 0)
    private var b1 = Bucket.opening(at: 0, 0)
    private var b2 = Bucket.opening(at: 0, 0)
    private var b3 = Bucket.opening(at: 0, 0)
    /// Footprint and time at the start of the window (the start of its oldest bucket).
    private var anchorBytes: UInt64 = 0
    private var anchorTime: Double = 0
    /// The most the window has reached since it began.
    private var highWater: UInt64 = 0
    /// The deepest dip tolerated since the last re-anchor. An upper bound for the window: a dip that has slid out of it is
    /// still counted, which only ever overstates "never fell back by more than".
    private var deepestDip: UInt64 = 0
    /// When the open bucket closes. While `quiet`, when the quiet period ends.
    private var rotateAt: Double = 0
    private var cur: UInt8 = 0
    private var closed: UInt8 = 0
    private var hasWindow = false
    /// The process's CPU time (nanoseconds) at the previous sample, and whether there is one. The next sample's CPU time
    /// less this is what it adds to its bucket; a CPU time that went DOWN (a reused pid, a counter reset) adds nothing.
    private var lastCPU: UInt64 = 0
    private var hasLastCPU = false
    public private(set) var phase: Phase = .learning

    public init() {}

    /// Stop this tracker for good: the other tier of the same process raised the finding, so this one must not raise a
    /// second. Unlike `reset(quietUntil:)` this is also meant for a tracker that is still learning.
    public mutating func markReported() { phase = .reported }

    /// The end of the quiet period, while there is one.
    public var quietUntil: TimeInterval? { phase == .quiet ? rotateAt : nil }
    /// The footprint the window started at, once there is a window.
    public var windowStartBytes: UInt64? { hasWindow ? anchorBytes : nil }
    /// Finished buckets in the window (0 to 3 while it fills; the open one is not counted).
    public var closedBuckets: Int { hasWindow ? Int(closed) : 0 }

    /// Forget the window and ignore samples until `quietUntil`. A tracker that has reported stays reported: a finding is
    /// raised once per process, whatever happens to the clock.
    public mutating func reset(quietUntil: TimeInterval) {
        guard phase != .reported else { return }
        phase = .quiet
        rotateAt = quietUntil
        hasWindow = false
    }

    /// Feed one reading. Returns a verdict only on the sample that makes the tracker report, which happens once.
    ///
    /// - Parameters:
    ///   - bytes: the process's footprint.
    ///   - t: awake seconds, never going backwards.
    ///   - cpuNanos: the process's total CPU time so far (user plus system) in nanoseconds, a counter that only goes up.
    ///     Nil when unknown, and then nothing is gated on CPU. A window whose average use was at least
    ///     `rules.maxBusyFraction` of one core is not judged: the work explains the growth.
    ///   - processAge: awake seconds since the process started.
    ///   - rules: every threshold; `.standard` unless a test says otherwise.
    @discardableResult
    public mutating func ingest(bytes: UInt64, at t: TimeInterval, cpuNanos: UInt64? = nil, processAge: TimeInterval,
                                rules: GrowthRules = .standard) -> GrowthVerdict? {
        switch phase {
        case .reported:
            return nil
        case .quiet:
            guard t >= rotateAt else { return nil }
            phase = .learning
            hasWindow = false
        case .learning, .watching:
            break
        }

        guard hasWindow else {
            startWindow(bytes: bytes, at: t, cpuNanos: cpuNanos, cadence: 0, rules: rules)
            return nil
        }
        var open = bucket(Int(cur))
        guard t >= open.endTime else {
            // Time went backwards. Trust nothing measured across it.
            startWindow(bytes: bytes, at: t, cpuNanos: cpuNanos, cadence: 0, rules: rules)
            return nil
        }
        let delta = t - open.endTime

        // The dip rule. Memory that falls back by more than a few percent was not growing steadily (a cache purge, a
        // garbage collection, a finished export), so the window starts again here. Small dips are tolerated.
        if bytes < highWater {
            let dip = Self.diff(highWater, bytes)
            let growth = Self.diff(highWater, anchorBytes)
            if dip > Self.dipTolerance(anchor: anchorBytes, growth: growth, rules: rules) {
                startWindow(bytes: bytes, at: t, cpuNanos: cpuNanos, cadence: delta, rules: rules)
                return nil
            }
            if dip > deepestDip { deepestDip = dip }
        }

        // Fold the sample into the open bucket.
        let previous = open.end
        open.end = bytes
        open.endTime = t
        if bytes > open.peak { open.peak = bytes }
        if bytes > highWater { highWater = bytes }
        if open.samples < UInt8.max { open.samples += 1 }
        if bytes > previous {
            let step = bytes - previous
            if step > Self.risingEpsilon(at: previous, rules: rules), open.rising < UInt8.max { open.rising += 1 }
            let kib = UInt32(clamping: step >> 10)
            if kib > open.largestStepKiB { open.largestStepKiB = kib }
        }
        if let cpu = cpuNanos {
            if hasLastCPU {
                let rise = cpu > lastCPU ? cpu - lastCPU : 0
                let ms = rise / 1_000_000 + (rise % 1_000_000 >= 500_000 ? 1 : 0)
                open.cpuMs = UInt32(clamping: UInt64(open.cpuMs) + ms)
                if open.cpuSeen < UInt8.max { open.cpuSeen += 1 }
            }
            lastCPU = cpu
            hasLastCPU = true
        }
        setBucket(Int(cur), open)

        guard t >= rotateAt else { return nil }

        // The open bucket closes on this sample, and the next one starts from it.
        let nextLength = Self.bucketSeconds(cadence: delta, rules: rules)
        if closed < 3 {
            closed += 1
            cur += 1
            setBucket(Int(cur), Bucket.opening(at: bytes, t))
            rotateAt = t + nextLength
            phase = .learning
            return nil
        }

        // Four finished buckets: judge the window, then slide it by one bucket.
        if let verdict = evaluate(bytes: bytes, at: t, processAge: processAge, rules: rules) {
            phase = .reported
            return verdict
        }
        let oldest = (Int(cur) + 1) & 3
        let dropped = bucket(oldest)
        anchorBytes = dropped.end
        anchorTime = dropped.endTime
        var high = dropped.end
        for i in 1..<4 {
            let p = bucket((oldest + i) & 3).peak
            if p > high { high = p }
        }
        highWater = high
        cur = UInt8(oldest)
        setBucket(oldest, Bucket.opening(at: bytes, t))
        rotateAt = t + nextLength
        phase = processAge >= rules.minProcessAgeSeconds ? .watching : .learning
        return nil
    }

    // MARK: Judging

    private func evaluate(bytes: UInt64, at t: Double, processAge: Double, rules: GrowthRules) -> GrowthVerdict? {
        guard processAge >= rules.minProcessAgeSeconds else { return nil }
        let elapsed = t - anchorTime
        guard elapsed >= rules.windowSeconds else { return nil }
        guard bytes > anchorBytes else { return nil }
        let net = bytes - anchorBytes
        guard net >= rules.minNetGrowthBytes else { return nil }
        let netD = Double(net)
        guard netD >= rules.minNetGrowthFraction * Double(anchorBytes) else { return nil }

        // Every bucket must have carried its share of the growth.
        let oldest = (Int(cur) + 1) & 3
        var from = anchorBytes
        var step: UInt32 = 0
        var rising = 0
        var samples = 0
        var cpuMs: UInt64 = 0
        var cpuSeen = 0
        for i in 0..<4 {
            let b = bucket((oldest + i) & 3)
            guard b.end > from else { return nil }
            guard Double(b.end - from) >= rules.minBucketShareOfNet * netD else { return nil }
            from = b.end
            if b.largestStepKiB > step { step = b.largestStepKiB }
            rising += Int(b.rising)
            samples += Int(b.samples)
            cpuMs += UInt64(b.cpuMs)
            cpuSeen += Int(b.cpuSeen)
        }
        let largestStep = UInt64(step) << 10
        guard Double(largestStep) <= rules.maxLargestStepShare * netD else { return nil }

        // How busy the process was over the window, as a share of one core. Known only when every sample of it came with a
        // CPU time. A busy window is not judged (the caller slides it and tries again at the next hop).
        var cpuFraction: Double?
        if samples > 0, cpuSeen == samples, elapsed > 0 {
            let fraction = Double(cpuMs) / 1000 / elapsed
            if fraction >= rules.maxBusyFraction { return nil }
            cpuFraction = fraction
        }

        return GrowthVerdict(startBytes: anchorBytes,
                             nowBytes: bytes,
                             windowSeconds: elapsed,
                             bucketSeconds: elapsed / 4,
                             risingSamples: rising,
                             totalSamples: samples,
                             largestDipBytes: deepestDip,
                             largestStepBytes: largestStep,
                             cpuFraction: cpuFraction)
    }

    // MARK: Window

    private mutating func startWindow(bytes: UInt64, at t: Double, cpuNanos: UInt64?, cadence: Double,
                                      rules: GrowthRules) {
        lastCPU = cpuNanos ?? 0
        hasLastCPU = cpuNanos != nil
        anchorBytes = bytes
        anchorTime = t
        highWater = bytes
        deepestDip = 0
        b0 = Bucket.opening(at: bytes, t)
        cur = 0
        closed = 0
        hasWindow = true
        rotateAt = t + Self.bucketSeconds(cadence: cadence, rules: rules)
        phase = .learning
    }

    private func bucket(_ i: Int) -> Bucket {
        switch i {
        case 0: return b0
        case 1: return b1
        case 2: return b2
        default: return b3
        }
    }

    private mutating func setBucket(_ i: Int, _ b: Bucket) {
        switch i {
        case 0: b0 = b
        case 1: b1 = b
        case 2: b2 = b
        default: b3 = b
        }
    }

    // MARK: Arithmetic (nothing here can underflow)

    private static func diff(_ a: UInt64, _ b: UInt64) -> UInt64 { a > b ? a - b : 0 }

    /// A bucket opening at a cadence of `cadence` seconds lasts this long: never under `minBucketSeconds`, and at least
    /// two samples at a slow cadence.
    static func bucketSeconds(cadence: Double, rules: GrowthRules) -> Double {
        max(rules.minBucketSeconds, rules.bucketCadenceFactor * max(0, cadence))
    }

    static func dipTolerance(anchor: UInt64, growth: UInt64, rules: GrowthRules) -> UInt64 {
        let fromStart = UInt64(max(0, Double(anchor) * rules.dipToleranceFractionOfStart))
        let fromGrowth = UInt64(max(0, Double(growth) * rules.dipToleranceFractionOfGrowth))
        return max(rules.dipToleranceMinBytes, max(fromStart, fromGrowth))
    }

    static func risingEpsilon(at bytes: UInt64, rules: GrowthRules) -> UInt64 {
        max(rules.risingEpsilonMinBytes, UInt64(max(0, Double(bytes) * rules.risingEpsilonFraction)))
    }
}

/// A possible memory leak: what was seen, and the words for it.
public struct Finding: Equatable {
    public var processKey: ProcessKey
    public var pid: pid_t
    /// The app's name for an app (its bundle's file name), else the executable's name.
    public var name: String
    public var path: String
    /// The outermost `.app` bundle path for an app, else the executable path (`IdentityKey`).
    public var identityKey: String
    public var isApp: Bool
    public var startBytes: UInt64
    public var nowBytes: UInt64
    public var netGrowthBytes: UInt64
    /// The span the growth was measured over: the actual window, not a fixed 60.
    public var windowSeconds: Double
    /// The average length of one of the four stretches the window was cut into.
    public var bucketSeconds: Double
    public var flaggedAtWall: Date
    /// The awake-clock reading at the same moment, the base of `history`'s seconds.
    public var flaggedAtAwake: Double
    public var risingSamples: Int
    public var totalSamples: Int
    public var largestDipBytes: UInt64
    /// The graph's points, oldest first, copied when the finding was made so the graph outlives the process.
    public var history: [MemorySample]
    /// False when another process of the same app was flagged less than ten minutes ago: the finding is still listed, but
    /// it does not raise a second notification.
    public var shouldNotify: Bool
    /// Which tracker raised it. A slow finding's `windowSeconds` is hours and its `history` is the slow ring.
    public var tier: GrowthTier
    /// The whole machine's memory when a pressure finding was raised; nil for a leak finding.
    public var system: SystemMemoryReading?
    /// Which rule of the high-memory warning fired; nil for a leak finding.
    public var reason: PressureReason?
    /// A pressure finding's largest apps, biggest first (the finding's own app is the first); empty for a leak finding.
    public var topApps: [PressureApp]
    /// The CPU the process used while its memory grew, as a share of ONE core (0.03 is 3 %; may exceed 1). A fast finding's
    /// is over the window, a slow finding's over its hours. Nil when it was not known, and for a pressure finding.
    public var cpuFraction: Double?

    public init(processKey: ProcessKey, pid: pid_t, name: String, path: String, identityKey: String, isApp: Bool,
                startBytes: UInt64, nowBytes: UInt64, netGrowthBytes: UInt64,
                windowSeconds: Double, bucketSeconds: Double,
                flaggedAtWall: Date, flaggedAtAwake: Double,
                risingSamples: Int, totalSamples: Int, largestDipBytes: UInt64,
                history: [MemorySample], shouldNotify: Bool, tier: GrowthTier = .fast,
                system: SystemMemoryReading? = nil, reason: PressureReason? = nil, topApps: [PressureApp] = [],
                cpuFraction: Double? = nil) {
        self.processKey = processKey
        self.pid = pid
        self.name = name
        self.path = path
        self.identityKey = identityKey
        self.isApp = isApp
        self.startBytes = startBytes
        self.nowBytes = nowBytes
        self.netGrowthBytes = netGrowthBytes
        self.windowSeconds = windowSeconds
        self.bucketSeconds = bucketSeconds
        self.flaggedAtWall = flaggedAtWall
        self.flaggedAtAwake = flaggedAtAwake
        self.risingSamples = risingSamples
        self.totalSamples = totalSamples
        self.largestDipBytes = largestDipBytes
        self.history = history
        self.shouldNotify = shouldNotify
        self.tier = tier
        self.system = system
        self.reason = reason
        self.topApps = topApps
        self.cpuFraction = cpuFraction
    }

    /// Bytes per second over the window.
    public var growthBytesPerSecond: Double {
        windowSeconds > 0 ? Double(netGrowthBytes) / windowSeconds : 0
    }

    /// A leak finding is withdrawn when the memory falls back: at or below the start plus half of the growth that was
    /// flagged. A leak keeps what it took; memory that goes back down was work that finished or memory the app gave back.
    /// False for a low-memory warning (it is about the whole Mac) and when there was no growth to give back.
    public func hasRecovered(currentBytes: UInt64) -> Bool {
        guard tier != .pressure, netGrowthBytes > 0 else { return false }
        return currentBytes <= startBytes + netGrowthBytes / 2
    }

    /// Growth as a fraction of where the window started (0.29 for +29%).
    public var growthFraction: Double {
        startBytes > 0 ? Double(netGrowthBytes) / Double(startBytes) : 0
    }

    /// The notification's title: a leak is "possible", a Mac running low on memory is not.
    public var notificationTitle: String {
        tier == .pressure ? "Memory is running low" : "Possible memory leak detected"
    }

    /// Why Anode flagged it, from the numbers that tripped, so it always matches what happened.
    public var explanation: String {
        if tier == .pressure { return pressureExplanation }
        let fell = largestDipBytes == 0
            ? "never fell back"
            : "never fell back by more than \(MetricUnit.bytes.format(Double(largestDipBytes)))"
        switch tier {
        case .slow:
            let span = DurationText.approximate(seconds: windowSeconds)
            let stretch = DurationText.text(seconds: bucketSeconds)
            let base = "Its memory rose steadily for about \(span), grew in every stretch of \(stretch), and \(fell). "
                + "Long sessions and apps that keep opening things look similar, so Anode can only say \"possible\"."
            guard let share = coreShareText else { return base }
            return base + " It averaged \(share) of a core over that time."
        default:
            let rose = "Its memory rose in \(risingSamples) of \(totalSamples) samples"
            let stretch = "grew steadily in every \(Int(bucketSeconds.rounded()))-second stretch"
            let base = "\(rose), \(stretch), and \(fell). Leaks look like this, but so do large exports and cache fills, "
                + "so Anode can only say \"possible\"."
            guard let share = coreShareText else { return base }
            return base + " It used \(share) of a core while its memory grew, so work it was doing does not explain the growth."
        }
    }

    /// How much of one core the process used, in words for the explanation: "about 3%", or "under 1%" below one percent.
    /// Nil when the CPU was not known (or is not a number).
    private var coreShareText: String? {
        guard let fraction = cpuFraction, fraction.isFinite, fraction >= 0 else { return nil }
        let percent = fraction * 100
        return percent < 1 ? "under 1%" : "about \(Int(min(percent, 1_000_000).rounded()))%"
    }

    /// The notification's text. The duration is the window actually measured, never a hard-coded "last minute".
    public var notificationBody: String {
        if tier == .pressure { return pressureBody }
        let grew = MetricUnit.bytes.format(Double(netGrowthBytes))
        let now = MetricUnit.bytes.format(Double(nowBytes))
        let span = DurationText.text(seconds: windowSeconds)
        switch tier {
        case .slow:
            return "\(name)'s memory has grown \(grew) over \(span) and is now \(now). Click to see details."
        default:
            return "\(name)'s memory grew \(grew) over \(span) and is now \(now). Click to see details."
        }
    }

    // MARK: The high-memory warning's words

    /// The opening sentence, from the rule that fired (no full stop).
    private var pressureLead: String {
        switch reason {
        case .critical?: return "Your Mac is critically low on memory"
        case .warning?: return "Your Mac is low on memory"
        case .memoryLow?: return "Your Mac is low on memory: \(leftText) left"
        case .memoryCritical?: return "Your Mac is almost out of memory: \(leftText) left"
        case .swap?: return "Your Mac is using a lot of swap"
        case .oneAppDominates?: return "\(name) is using over half of your memory"
        case nil: return "Your Mac is running low on memory"
        }
    }

    /// The RAM not in use, "2.1 GB" (or "less than 1 GB"-style "512 MB").
    private var leftText: String { MemorySizeText.text(system?.leftBytes ?? 0) }

    /// "38 GB of 64 GB" when the total is known, else just "38 GB".
    private var appShare: String {
        let now = MemorySizeText.text(nowBytes)
        guard let total = system?.totalBytes, total > 0 else { return now }
        return "\(now) of \(MemorySizeText.text(total))"
    }

    private var pressureBody: String {
        let hasApp = !name.isEmpty && nowBytes > 0
        if !hasApp { return "\(pressureLead). Click to see what to quit." }
        if reason == .oneAppDominates { return "\(pressureLead): \(appShare). Click to see what to quit." }
        return "\(pressureLead). \(name) is using \(appShare). Click to see what to quit."
    }

    private var pressureExplanation: String {
        var parts: [String] = []
        if let s = system, s.totalBytes > 0 {
            let swap = s.swapUsedBytes == 0 ? "no swap is in use" : "\(MemorySizeText.text(s.swapUsedBytes)) of swap is in use"
            parts.append("\(MemorySizeText.text(s.usedBytes)) of \(MemorySizeText.text(s.totalBytes)) of memory is in use "
                         + "(\(Int(s.usedPercent.rounded())) %), and \(swap).")
        }
        switch reason {
        case .critical?: parts.append("macOS reports critical memory pressure.")
        case .warning?: parts.append("macOS has reported memory pressure for a while.")
        case .memoryLow?: parts.append("Only \(leftText) of memory is left, so the Mac will soon have to compress and swap hard, which slows everything down.")
        case .memoryCritical?: parts.append("Only \(leftText) of memory is left. The Mac is about to stall, and macOS may start closing apps. Anode repeats this alert every two minutes until memory is freed.")
        case .swap?: parts.append("Swap use has stayed high, which slows the Mac down.")
        case .oneAppDominates?: parts.append("One app has held more than half of the memory for several minutes.")
        case nil: break
        }
        if !name.isEmpty, nowBytes > 0 {
            var largest = "The largest app is \(name), using \(appShare)"
            if let total = system?.totalBytes, total > 0 {
                largest += " (\(Int((Double(nowBytes) / Double(total) * 100).rounded())) %)"
            }
            largest += "."
            let others = topApps.dropFirst().map { "\($0.name) \(MemorySizeText.text($0.bytes))" }
            if !others.isEmpty { largest += " Next: " + others.joined(separator: ", ") + "." }
            parts.append(largest)
            parts.append("Quitting \(name) first will help most.")
        }
        parts.append("Anode only reads memory sizes. It never quits anything by itself.")
        return parts.joined(separator: " ")
    }
}

/// A length of time in words, for the notification and the explanation. Pure: seconds in, text out.
public enum DurationText {

    /// "45 seconds", "75 seconds", "240 seconds" under ten minutes (the fast tier's wording, unchanged), then whole minutes
    /// up to two hours ("10 minutes", "90 minutes"), then "2 hours" or "2 hours 10 minutes". Rounded to the nearest second,
    /// or minute from ten minutes on.
    public static func text(seconds: Double) -> String {
        let s = seconds.isFinite ? max(0, seconds) : 0
        if s < 600 {
            let n = Int(s.rounded())
            return n == 1 ? "1 second" : "\(n) seconds"
        }
        let minutes = Int((s / 60).rounded())
        if minutes < 120 { return "\(minutes) minutes" }
        let hours = minutes / 60
        let rest = minutes % 60
        let h = "\(hours) hours"
        if rest == 0 { return h }
        return rest == 1 ? "\(h) 1 minute" : "\(h) \(rest) minutes"
    }

    /// The same, snapped to the nearest five minutes from an hour on, for a sentence that says "about" (a window of 7296
    /// seconds reads "2 hours", not "2 hours 2 minutes").
    public static func approximate(seconds: Double) -> String {
        let s = seconds.isFinite ? max(0, seconds) : 0
        return text(seconds: s >= 3600 ? (s / 300).rounded() * 300 : s)
    }
}

/// Which app or tool a process belongs to, by string work alone (no disk reads, so it costs nothing and cannot raise a
/// consent prompt for a folder).
///
/// An app is its OUTERMOST `.app` bundle: the first path component ending in ".app", as `AppResolver` takes it, so a
/// browser's helper process belongs to the browser. Anything else is its own executable path, which keeps every `node` on
/// a Mac from being one thing.
public enum IdentityKey {

    public static func key(forExecutablePath path: String) -> (key: String, isApp: Bool) {
        let parts = path.components(separatedBy: "/")
        if let idx = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
            let bundle = parts[0...idx].joined(separator: "/")
            // Only the app's OWN processes are "the app". A tool that merely lives inside a bundle (Xcode ships python3,
            // clang and a language server under Contents/Developer) is a process of its own: treating it as the app
            // would make Quit App and Force Quit App act on everything under that folder.
            if belongsToApp(path: path, bundle: bundle) { return (bundle, true) }
        }
        return (path, false)
    }

    /// Is this executable one of the app's own running processes, rather than a tool shipped inside its folder?
    ///
    /// Yes for the main executable (`Contents/MacOS/`) and for the executable of a helper bundle nested in the app: a
    /// `.app` or `.xpc` under `Contents/Frameworks/`, `Contents/XPCServices/` or `Contents/Library/LoginItems/` (how Chrome
    /// and Electron helpers are laid out). Everything else under the bundle (`Contents/Developer`, `Contents/Resources`,
    /// `Contents/SharedSupport` and so on) is a tool, and in doubt a process is treated as its own thing.
    public static func belongsToApp(path: String, bundle: String) -> Bool {
        let prefix = bundle + "/Contents/"
        guard path.hasPrefix(prefix) else { return false }
        let rest = String(path.dropFirst(prefix.count))
        if rest.hasPrefix("MacOS/") { return true }
        for dir in ["Frameworks/", "XPCServices/", "Library/LoginItems/"] where rest.hasPrefix(dir) {
            let tail = rest.dropFirst(dir.count)
            return tail.contains(".app/Contents/MacOS/") || tail.contains(".xpc/Contents/MacOS/")
        }
        return false
    }

    /// The name to show for an identity KEY as `key(forExecutablePath:)` returns it (the ignore list holds keys, not
    /// executable paths): an app's bundle file name without ".app", else the last part of a tool's path.
    public static func name(forKey key: String) -> String {
        let leaf = (key as NSString).lastPathComponent
        guard key.hasSuffix(".app") else { return leaf }
        let trimmed = String(leaf.dropLast(4))
        return trimmed.isEmpty ? leaf : trimmed
    }

    /// The name to show: an app's bundle file name without ".app" (what Finder shows), else the executable's own name.
    public static func name(forExecutablePath path: String) -> String {
        let k = key(forExecutablePath: path)
        if k.isApp {
            let leaf = (k.key as NSString).lastPathComponent
            let trimmed = String(leaf.dropLast(4))
            return trimmed.isEmpty ? leaf : trimmed
        }
        return (path as NSString).lastPathComponent
    }
}

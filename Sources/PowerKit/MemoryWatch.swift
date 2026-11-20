import Darwin
import Foundation

/// Memory Watch's candidate table: which few dozen processes are tracked, and the feed that keeps them tracked.
///
/// Tracking all ~800 processes every tick would cost a sweep, so a bounded table of `GrowthRules.maxCandidates` is kept.
/// Candidates come from discovery passes (ascenders first, then the largest processes), are fed from a full sweep for
/// nothing or re-read one `footprintOf` call each on a light tick, and leave when they exit, when their pid is reused,
/// when they go flat, or when something better needs the slot. A candidate that is pinned (a diagnostic window is open on
/// it, or it was flagged less than ten minutes ago) is never pushed out.
///
/// PURE LOGIC. Everything it reads (footprints, paths) and everything it knows about time (`awake`, `wall`) comes in
/// through an argument or an injected closure: no timer, no queue, no observer, no file. It is NOT thread-safe, by design:
/// one serial queue owns it (the sampling queue), and the hot path takes no lock.
///
/// Per candidate it keeps a `GrowthTracker` (a fixed-size value) and a ring of 192 `(Float32 seconds, UInt32 KiB)` points
/// for the graph. The ring is appended to and never read by the detector; a `Finding` copies it, so the graph survives the
/// process exiting. Seconds are stored relative to the moment of admission, because a Float32 of raw awake seconds loses
/// sub-second precision after weeks of uptime.
///
/// CPU. Every reading carries the process's CPU time (`Reading`/`Seen`'s `cpuNanos`, from the same rusage call, so it
/// costs nothing) and both trackers are given it. The fast tracker does not judge a window in which the process averaged
/// `GrowthRules.maxBusyFraction` of a core or more (growth while busy is work, not a leak); the slow tracker's rules never
/// gate on it, and only use it to say how busy the process was on average.
///
/// THE SLOW TIER. The same entry holds a second tracker, driven by `GrowthRules.slow` (two-hour window), and a small ring
/// of the last `slowRingCapacity` slow points (48 x 8 bytes, about four hours). It is NOT fed on every tick: each entry
/// keeps `nextSlowAt`, and a tick costs the entry one comparison `awake >= nextSlowAt`. Only when that passes (once per
/// `slowFeedIntervalSeconds`, 300 s) is the slow tracker fed, a slow point pushed and `nextSlowAt` moved on. The slow
/// state lives and dies with the entry, so it is bounded by the candidate cap. It uses the awake clock, so a sleep does not
/// advance it and does not reset it. Whichever tier reports a process, both trackers are marked reported, so one process
/// is one finding.
public final class MemoryWatch {

    /// What reading one process gives: its start time (pid reuse), its footprint and its total CPU time so far (user plus
    /// system, real nanoseconds, a counter that only goes up), all from the one `proc_pid_rusage` call.
    public typealias Reading = (start: UInt64, footprint: UInt64, cpuNanos: UInt64)
    /// One process in a discovery pass.
    public typealias Seen = (pid: pid_t, start: UInt64, footprint: UInt64, cpuNanos: UInt64)

    /// Points kept per candidate for its graph: about 6 minutes at 2 s, about 25 minutes at 8 s.
    public static let ringCapacity = 192

    // MARK: Injected

    private let rules: GrowthRules
    private let slowRules: GrowthRules
    private let ownPID: pid_t
    private let excludedPaths: Set<String>
    private let pathOf: (pid_t) -> String
    private let isIgnored: (String) -> Bool
    private let footprintOf: (pid_t) -> Reading?
    private let discover: () -> [Seen]
    private let startSeconds: (UInt64) -> TimeInterval

    /// Called on the sampling queue when a process looks like a leak. Every finding is delivered; `shouldNotify` says
    /// whether it earns a notification of its own. It must not call back into the watch synchronously (hop to another
    /// queue first): the watch is part-way through a feed when it runs.
    public var onFinding: (Finding) -> Void = { _ in }
    /// Called after each feed with the newest point of each key in `setLive`'s set, and never when the set is empty.
    public var onLivePoint: ((ProcessKey, MemorySample) -> Void)?

    // MARK: Modes (leak detection and the high-memory warning)

    /// Whether candidates are fed to their leak trackers and leak findings are raised. When false the table is still kept
    /// up (its sizes are what the high-memory warning needs) but no tracker is fed, which is the whole per-tick leak cost.
    /// Turning it back on starts every tracker again behind a quiet period, so a window never spans the time it was off.
    public var detectsLeaks: Bool = true {
        didSet {
            guard detectsLeaks, !oldValue else { return }
            let now = lastCallAwake ?? 0
            for entry in table.values {
                entry.tracker.reset(quietUntil: now + rules.quietAfterGapSeconds)
                entry.slowTracker.reset(quietUntil: now + slowRules.quietAfterGapSeconds)
            }
        }
    }

    /// Whether `ingestSystem` does anything. Off (the default): it returns at once. Turning it off forgets the warning's
    /// timers and cooldowns.
    public var watchesPressure: Bool = false {
        didSet {
            guard !watchesPressure, oldValue else { return }
            pressureTracker.reset()
            lastSystemAwake = nil
            lastSystemWall = nil
        }
    }

    /// Every threshold of the high-memory warning (`PressureRules.standard`).
    public var pressureRules = PressureRules.standard

    /// Both modes at once.
    public func setModes(leaks: Bool, pressure: Bool) {
        detectsLeaks = leaks
        watchesPressure = pressure
    }

    /// - Parameters:
    ///   - ownPID: never a candidate.
    ///   - excludedPaths: executable paths (or identity keys) that are never candidates, such as Anode's own worker copies.
    ///   - pathOf: a process's executable path. Called once per process lifetime at most, for a process that qualifies
    ///     for the table (admitted, ignored or excluded alike), and never by a light tick or a footprint-only pass.
    ///   - isIgnored: whether the person asked not to be warned about this identity key (`IdentityKey`).
    ///   - footprintOf: one process's start time, footprint and CPU time, nil when it is gone or unreadable.
    ///   - discover: every readable process, for a footprint-only discovery pass (no paths, no names).
    ///   - startSeconds: a process's start time (`ri_proc_start_abstime`) on the awake clock, so its age is `awake` minus
    ///     this. The default converts mach absolute time units, which are the units `awakeSeconds()` counts in.
    ///   - slowRules: the slow tier's thresholds, its feed interval and its ring size (`GrowthRules.slow`).
    public init(rules: GrowthRules = .standard,
                ownPID: pid_t,
                excludedPaths: Set<String> = [],
                pathOf: @escaping (pid_t) -> String,
                isIgnored: @escaping (String) -> Bool = { _ in false },
                footprintOf: @escaping (pid_t) -> Reading?,
                discover: @escaping () -> [Seen],
                startSeconds: @escaping (UInt64) -> TimeInterval = { MachTime.seconds(units: $0) },
                slowRules: GrowthRules = .slow) {
        self.rules = rules
        self.slowRules = slowRules
        self.ownPID = ownPID
        self.excludedPaths = excludedPaths
        self.pathOf = pathOf
        self.isIgnored = isIgnored
        self.footprintOf = footprintOf
        self.discover = discover
        self.startSeconds = startSeconds
        table.reserveCapacity(rules.maxCandidates + 1)
        scratchKeys.reserveCapacity(rules.maxCandidates + 1)
        appTotals.reserveCapacity(rules.maxCandidates + 1)
    }

    // MARK: State

    /// What was worked out about a process the one time its path was read.
    fileprivate struct Identity {
        let path: String
        let key: String
        let isApp: Bool
        let name: String
        /// Unreadable path, or one of Anode's own copies: never a candidate.
        let blocked: Bool
    }

    /// How much a candidate is wanted: an ascender (tier 2, by its gain) before a large process (tier 1, by its size).
    fileprivate struct Rank: Comparable {
        var tier: Int
        var score: UInt64
        static func < (a: Rank, b: Rank) -> Bool { a.tier != b.tier ? a.tier < b.tier : a.score < b.score }
    }

    fileprivate struct Slot {
        var offset: Float
        var kib: UInt32
    }

    fileprivate final class Entry {
        let key: ProcessKey
        let identity: Identity
        var tracker = GrowthTracker()
        var rank: Rank
        /// Awake time at admission: the base of both rings' offsets.
        let origin: Double
        var slots = ContiguousArray<Slot>()
        var head = 0
        var lastBytes: UInt64
        /// The footprint last seen to move, and when: a candidate that stays near it for long is flat.
        var flatRef: UInt64
        var lastMoved: Double
        var pinnedUntil: Double = -Double.infinity

        // The slow tier: a second tracker, its ring, and the one number a tick compares against.
        var slowTracker = GrowthTracker()
        var slowSlots = ContiguousArray<Slot>()
        var slowHead = 0
        let slowCapacity: Int
        /// The awake time from which the slow tracker may be fed next. Admission is the first feed.
        var nextSlowAt: Double
        /// How many times the slow tracker has been fed (tests and the soak).
        var slowFeeds = 0

        init(key: ProcessKey, identity: Identity, origin: Double, bytes: UInt64, rank: Rank, slowCapacity: Int) {
            self.key = key
            self.identity = identity
            self.origin = origin
            self.lastBytes = bytes
            self.flatRef = bytes
            self.lastMoved = origin
            self.rank = rank
            self.slowCapacity = max(0, slowCapacity)
            self.nextSlowAt = origin
            slots.reserveCapacity(MemoryWatch.ringCapacity)
            slowSlots.reserveCapacity(self.slowCapacity)
        }

        func append(_ s: Slot) {
            Entry.push(s, into: &slots, head: &head, capacity: MemoryWatch.ringCapacity)
        }

        func appendSlow(_ s: Slot) {
            Entry.push(s, into: &slowSlots, head: &slowHead, capacity: slowCapacity)
        }

        private static func push(_ s: Slot, into slots: inout ContiguousArray<Slot>, head: inout Int, capacity: Int) {
            guard capacity > 0 else { return }
            if slots.count < capacity {
                slots.append(s)
            } else {
                slots[head] = s
                head += 1
                if head == capacity { head = 0 }
            }
        }

        private func ordered(_ slots: ContiguousArray<Slot>, head: Int) -> [MemorySample] {
            var out: [MemorySample] = []
            out.reserveCapacity(slots.count)
            let n = slots.count
            for i in 0..<n {
                let s = slots[(head + i) % n]
                out.append(MemorySample(seconds: origin + Double(s.offset), bytes: UInt64(s.kib) << 10))
            }
            return out
        }

        /// The fast ring's points, oldest first: what a fast finding carries as its graph.
        func fastSamples() -> [MemorySample] { ordered(slots, head: head) }

        /// The slow ring's points, oldest first (about four hours at 300 s): what a slow finding carries as its graph.
        func slowSamples() -> [MemorySample] { ordered(slowSlots, head: slowHead) }

        /// The whole timeline, oldest first, with no point twice: the slow ring's points that are OLDER than the fast ring's
        /// first point (the strict `<` drops a slow point that the fast ring also holds, since both are cut from the same
        /// feed and the same offset), then every fast point. A candidate whose fast ring is empty gives the slow ring.
        func samples() -> [MemorySample] {
            let recent = fastSamples()
            guard !slowSlots.isEmpty else { return recent }
            let older = slowSamples()
            guard let cut = recent.first?.seconds else { return older }
            var out: [MemorySample] = []
            out.reserveCapacity(older.count + recent.count)
            for point in older where point.seconds < cut { out.append(point) }
            out.append(contentsOf: recent)
            return out
        }
    }

    /// One process of a discovery pass, with the path when the sweep already carried it for free.
    fileprivate struct Observed {
        let key: ProcessKey
        let footprint: UInt64
        /// Total CPU time so far in nanoseconds: the first reading of a candidate's CPU baseline.
        let cpuNanos: UInt64
        let path: String
    }

    fileprivate struct Contender {
        let observed: Observed
        let rank: Rank
    }

    private var table: [ProcessKey: Entry] = [:]
    /// Every process's footprint at the previous discovery pass: replaced by each pass, so it never outgrows the machine.
    private var previous: [ProcessKey: UInt64] = [:]
    /// The result of the one path read per process, for processes that qualified (admitted or not); trimmed to the
    /// processes that still exist on every pass.
    private var identities: [ProcessKey: Identity] = [:]
    /// Processes already reported: a finding is raised once per `ProcessKey`. Trimmed like `identities`.
    private var reported: Set<ProcessKey> = []
    private var lastNotified: [String: Double] = [:]
    private var ignoredKeys: Set<String> = []
    private var pinned: Set<ProcessKey> = []
    private var liveKeys: Set<ProcessKey> = []

    /// Times the slow tracker has been fed, over all entries, since the last `reset()`: at most one per entry per
    /// `slowFeedIntervalSeconds`.
    private var slowFeedTotal = 0

    private var lastSweepStamp: Date?
    private var lastSweepAwake: Double?
    private var lastDiscoveryAwake: Double?
    private var lastCallAwake: Double?
    private var lastCallWall: Date?

    private var scratchKeys: [ProcessKey] = []
    private var observedScratch: [Observed] = []

    // The high-memory warning: a fixed-size tracker, the clock of its last reading, and a reused scratch map.
    private var pressureTracker = PressureTracker()
    private var lastSystemAwake: Double?
    private var lastSystemWall: Date?
    private var appTotals: [String: UInt64] = [:]
    private var pressureFindings = 0

    // MARK: Entry points

    /// Feed every candidate from a full sweep, with no syscall of its own, and run a discovery pass over the sweep if one
    /// is due. A sweep that is not newer than the last one ingested is ignored, so a light tick that finds the monitor's
    /// latest sweep unchanged cannot feed it twice.
    public func ingest(sweep: ProcessSampler.Sweep, awake: TimeInterval) {
        if let last = lastSweepStamp, sweep.timestamp <= last { return }
        lastSweepStamp = sweep.timestamp
        noteTime(awake: awake, wall: sweep.timestamp)
        lastSweepAwake = awake

        scratchKeys.removeAll(keepingCapacity: true)
        for entry in table.values {
            if let p = sweep.processes[entry.key] {
                feed(entry, bytes: p.footprint, cpuNanos: p.cpuNanos, awake: awake, wall: sweep.timestamp)
            } else {
                scratchKeys.append(entry.key)       // gone, or its pid was reused (a different key)
            }
        }
        drop(scratchKeys, forgetPins: true)

        if let last = lastDiscoveryAwake, awake - last < rules.sweepDiscoveryIntervalSeconds { return }
        observedScratch.removeAll(keepingCapacity: true)
        for (key, p) in sweep.processes {
            observedScratch.append(Observed(key: key, footprint: p.footprint, cpuNanos: p.cpuNanos, path: p.path))
        }
        discovery(observedScratch, awake: awake, wall: sweep.timestamp)
        observedScratch.removeAll(keepingCapacity: true)
    }

    /// The light tick: re-read each candidate (one call each), and run a footprint-only discovery pass when no full sweep
    /// and no discovery has happened for `probeDiscoveryIntervalSeconds`.
    public func probe(awake: TimeInterval, wall: Date) {
        noteTime(awake: awake, wall: wall)

        if !table.isEmpty {
            scratchKeys.removeAll(keepingCapacity: true)
            for entry in table.values {
                if let r = footprintOf(entry.key.pid), r.start == entry.key.startAbsTime {
                    feed(entry, bytes: r.footprint, cpuNanos: r.cpuNanos, awake: awake, wall: wall)
                } else {
                    scratchKeys.append(entry.key)   // exited, unreadable, or the pid now belongs to another process
                }
            }
            drop(scratchKeys, forgetPins: true)
        }

        let sinceSweep = lastSweepAwake.map { awake - $0 } ?? Double.infinity
        let sinceDiscovery = lastDiscoveryAwake.map { awake - $0 } ?? Double.infinity
        guard sinceSweep >= rules.probeDiscoveryIntervalSeconds,
              sinceDiscovery >= rules.probeDiscoveryIntervalSeconds else { return }
        let found = discover()
        var observed: [Observed] = []
        observed.reserveCapacity(found.count)
        for f in found {
            observed.append(Observed(key: ProcessKey(pid: f.pid, startAbsTime: f.start), footprint: f.footprint,
                                     cpuNanos: f.cpuNanos, path: ""))
        }
        discovery(observed, awake: awake, wall: wall)
    }

    /// The high-memory warning's tick: one reading of the whole machine, fed on the same tick as `probe` or `ingest(sweep:)`.
    /// Does nothing unless `watchesPressure` is on and there is a reading.
    ///
    /// Each call finds the largest app by adding the candidate table's footprints per identity key (O(32), through a map
    /// whose storage is reused, so no allocation) and hands it to the `PressureTracker`. The table's sum is an ESTIMATE of
    /// the app's memory: it holds only the candidates (processes of 150 MiB or more, and recent risers), and it leaves out
    /// ignored apps and Anode's own processes, so those are never blamed. Only when the tracker returns a verdict is the
    /// heavier work done, once: a footprint-only pass over every process (`discover`) grouped by app to name the largest
    /// ones precisely. A pressure finding is delivered through `onFinding` with its own cooldown (the tracker's); it does
    /// not mark any leak tracker reported. A gap (sleep) starts the tracker's timers again but keeps its cooldowns.
    public func ingestSystem(_ reading: SystemMemoryReading?, awake: TimeInterval, wall: Date) {
        guard watchesPressure, let reading = reading else { return }
        if let lastAwake = lastSystemAwake, let lastWall = lastSystemWall {
            let awakeDelta = awake - lastAwake
            if awakeDelta < 0 || PowerMonitor.straddlesGap(wall: wall.timeIntervalSince(lastWall), awake: awakeDelta) {
                pressureTracker.noteGap()
            }
        }
        lastSystemAwake = awake
        lastSystemWall = wall
        guard let verdict = pressureTracker.ingest(reading, topAppBytes: largestAppBytes(), at: awake,
                                                   rules: pressureRules) else { return }
        raisePressure(verdict, awake: awake, wall: wall)
    }

    /// Keep this process in the table (a diagnostic window is open on it).
    public func pin(_ key: ProcessKey) { pinned.insert(key) }
    public func unpin(_ key: ProcessKey) { pinned.remove(key) }

    /// The processes whose newest point is handed to `onLivePoint` after every feed. Empty: nothing is called.
    public func setLive(_ keys: Set<ProcessKey>) { liveKeys = keys }

    /// Never warn about this identity key again (the person said so): its candidates go now, even pinned ones, and none is
    /// admitted later.
    public func ignore(identityKey: String) {
        ignoredKeys.insert(identityKey)
        scratchKeys.removeAll(keepingCapacity: true)
        for entry in table.values where entry.identity.key == identityKey { scratchKeys.append(entry.key) }
        drop(scratchKeys, forgetPins: false)
    }

    /// Forget everything: the table, rings, the discovery map, pins and the live set. The ignore list the person keeps is
    /// not in here (it is in the settings, read through `isIgnored`); only what `ignore(identityKey:)` added this session
    /// goes too.
    public func reset() {
        table.removeAll()
        previous.removeAll()
        identities.removeAll()
        reported.removeAll()
        lastNotified.removeAll()
        ignoredKeys.removeAll()
        pinned.removeAll()
        liveKeys.removeAll()
        lastSweepStamp = nil
        lastSweepAwake = nil
        lastDiscoveryAwake = nil
        lastCallAwake = nil
        lastCallWall = nil
        slowFeedTotal = 0
        scratchKeys.removeAll()
        observedScratch.removeAll()
        pressureTracker.reset()
        lastSystemAwake = nil
        lastSystemWall = nil
        appTotals.removeAll()
        pressureFindings = 0
    }

    // MARK: Looking in (tests and the app layer)

    public var candidateCount: Int { table.count }
    /// Points held across all rings: at most `maxCandidates x ringCapacity`.
    public var ringCount: Int { table.values.reduce(0) { $0 + $1.slots.count } }
    /// Points held across all slow rings: at most `maxCandidates x slowRingCapacity`.
    public var slowRingCount: Int { table.values.reduce(0) { $0 + $1.slowSlots.count } }
    /// How many times a slow tracker has been fed, over every candidate, since the last `reset()`.
    public var slowFeedCount: Int { slowFeedTotal }
    public var previousDiscoveryCount: Int { previous.count }
    public var identityCacheCount: Int { identities.count }
    public var reportedCount: Int { reported.count }
    /// High-memory findings raised since the last `reset()`.
    public var pressureFindingCount: Int { pressureFindings }
    public var candidateKeys: [ProcessKey] { Array(table.keys) }

    public func isCandidate(_ key: ProcessKey) -> Bool { table[key] != nil }
    public func phase(of key: ProcessKey) -> GrowthTracker.Phase? { table[key]?.tracker.phase }
    public func identityKey(of key: ProcessKey) -> String? { table[key]?.identity.key }
    /// A candidate's graph points, oldest first, covering the slow ring's hours and then the fast ring's recent minutes,
    /// each point once (see `Entry.samples()`).
    public func samples(of key: ProcessKey) -> [MemorySample] { table[key]?.samples() ?? [] }
    /// The slow ring alone, oldest first.
    public func slowSamples(of key: ProcessKey) -> [MemorySample] { table[key]?.slowSamples() ?? [] }
    public func slowSampleCount(of key: ProcessKey) -> Int { table[key]?.slowSlots.count ?? 0 }
    /// How many times this candidate's slow tracker has been fed.
    public func slowFeeds(of key: ProcessKey) -> Int { table[key]?.slowFeeds ?? 0 }
    public func slowPhase(of key: ProcessKey) -> GrowthTracker.Phase? { table[key]?.slowTracker.phase }
    /// Whether the candidate cannot be evicted right now (a window is open on it, or it was flagged lately).
    public func isHeld(_ key: ProcessKey) -> Bool {
        guard let e = table[key] else { return false }
        return held(e, at: lastCallAwake ?? 0)
    }

    // MARK: Feeding

    /// A gap (sleep, or the process itself being stopped) is the absence of samples, not "no growth": every FAST window
    /// starts again and nothing is flagged for the quiet period. The discovery baseline goes too, since growth across a gap
    /// is not growth to chase. The slow tier is left alone on purpose: its clock is awake time, which a sleep does not
    /// advance, so a slow climb that was interrupted by a night's sleep simply goes on where it was.
    private func noteTime(awake: Double, wall: Date) {
        defer { lastCallAwake = awake; lastCallWall = wall }
        guard let lastAwake = lastCallAwake, let lastWall = lastCallWall else { return }
        let awakeDelta = awake - lastAwake
        // `PowerMonitor.straddlesGap` is the rule the rest of the app uses for the same question.
        if awakeDelta < 0 || PowerMonitor.straddlesGap(wall: wall.timeIntervalSince(lastWall), awake: awakeDelta) {
            let until = awake + rules.quietAfterGapSeconds
            for entry in table.values {
                entry.tracker.reset(quietUntil: until)
                // The awake clock never runs backwards; should it, the slow feed must not wait for it to catch up.
                if awakeDelta < 0, entry.nextSlowAt > awake + slowRules.slowFeedIntervalSeconds { entry.nextSlowAt = awake }
            }
            previous.removeAll()
            lastDiscoveryAwake = nil
        }
    }

    private func feed(_ e: Entry, bytes: UInt64, cpuNanos: UInt64, awake: Double, wall: Date) {
        e.lastBytes = bytes
        e.append(Slot(offset: Float(awake - e.origin), kib: UInt32(clamping: bytes >> 10)))
        let moved = bytes > e.flatRef ? bytes - e.flatRef : e.flatRef - bytes
        if moved > rules.flatToleranceBytes {
            e.flatRef = bytes
            e.lastMoved = awake
        }
        if detectsLeaks {
            let age = max(0, awake - startSeconds(e.key.startAbsTime))
            if let verdict = e.tracker.ingest(bytes: bytes, at: awake, cpuNanos: cpuNanos, processAge: age, rules: rules) {
                raise(e, verdict, tier: .fast, awake: awake, wall: wall)
            }
            // The slow tier costs this one comparison per tick; the rest happens once per `slowFeedIntervalSeconds`.
            if awake >= e.nextSlowAt { feedSlow(e, bytes: bytes, cpuNanos: cpuNanos, awake: awake, age: age, wall: wall) }
        }
        if !liveKeys.isEmpty, liveKeys.contains(e.key), let post = onLivePoint {
            post(e.key, MemorySample(seconds: awake, bytes: bytes))
        }
    }

    private func feedSlow(_ e: Entry, bytes: UInt64, cpuNanos: UInt64, awake: Double, age: Double, wall: Date) {
        e.nextSlowAt = awake + slowRules.slowFeedIntervalSeconds
        e.slowFeeds += 1
        slowFeedTotal += 1
        e.appendSlow(Slot(offset: Float(awake - e.origin), kib: UInt32(clamping: bytes >> 10)))
        if let verdict = e.slowTracker.ingest(bytes: bytes, at: awake, cpuNanos: cpuNanos, processAge: age, rules: slowRules) {
            raise(e, verdict, tier: .slow, awake: awake, wall: wall)
        }
    }

    private func raise(_ e: Entry, _ v: GrowthVerdict, tier: GrowthTier, awake: Double, wall: Date) {
        // Either tier reporting the process stops both: one process is one finding.
        e.tracker.markReported()
        e.slowTracker.markReported()
        guard !reported.contains(e.key) else { return }
        reported.insert(e.key)
        // An app is one thing however many helpers it has: one notification per app per cooldown. A tool or daemon is
        // keyed by its process, so every flagged process earns its own.
        var notify = true
        if e.identity.isApp {
            if let last = lastNotified[e.identity.key], awake - last < rules.notifyCooldownSeconds {
                notify = false
            } else {
                lastNotified[e.identity.key] = awake
            }
        }
        e.pinnedUntil = awake + rules.pinSeconds
        onFinding(Finding(processKey: e.key,
                          pid: e.key.pid,
                          name: e.identity.name,
                          path: e.identity.path,
                          identityKey: e.identity.key,
                          isApp: e.identity.isApp,
                          startBytes: v.startBytes,
                          nowBytes: v.nowBytes,
                          netGrowthBytes: v.netGrowthBytes,
                          windowSeconds: v.windowSeconds,
                          bucketSeconds: v.bucketSeconds,
                          flaggedAtWall: wall,
                          flaggedAtAwake: awake,
                          risingSamples: v.risingSamples,
                          totalSamples: v.totalSamples,
                          largestDipBytes: v.largestDipBytes,
                          history: tier == .slow ? e.slowSamples() : e.fastSamples(),
                          shouldNotify: notify,
                          tier: tier,
                          cpuFraction: v.cpuFraction))
    }

    // MARK: High-memory warning

    /// One app of the verdict-time pass: its processes added together, and the biggest of them.
    fileprivate struct AppGroup {
        let identity: Identity
        var total: UInt64
        var biggestKey: ProcessKey
        var biggestBytes: UInt64
    }

    /// The largest app's footprint by the candidate table: every entry's last footprint added per identity key (a non-app
    /// is its own key, so a tool counts as itself). Reuses `appTotals`' storage; allocates nothing.
    private func largestAppBytes() -> UInt64 {
        guard !table.isEmpty else { return 0 }
        appTotals.removeAll(keepingCapacity: true)
        var best: UInt64 = 0
        for e in table.values {
            let sum = (appTotals[e.identity.key] ?? 0) + e.lastBytes
            appTotals[e.identity.key] = sum
            if sum > best { best = sum }
        }
        return best
    }

    /// The largest apps, precisely, biggest first: a footprint-only pass over every process, the ones of at least
    /// `topAppMinProcessBytes` looked up by path (largest first, at most `maxPathLookups` reads of a path not already
    /// known) and grouped with `IdentityKey`. Ignored apps, excluded paths and Anode's own processes are left out.
    private func topApps(limit: Int) -> [AppGroup] {
        var big = discover().filter { $0.footprint >= pressureRules.topAppMinProcessBytes && $0.pid != ownPID }
        big.sort { $0.footprint != $1.footprint ? $0.footprint > $1.footprint : $0.pid < $1.pid }
        var lookups = 0
        var groups: [String: AppGroup] = [:]
        for s in big {
            let key = ProcessKey(pid: s.pid, startAbsTime: s.start)
            if identities[key] == nil {
                guard lookups < pressureRules.maxPathLookups else { continue }
                lookups += 1
            }
            let id = identity(of: Observed(key: key, footprint: s.footprint, cpuNanos: s.cpuNanos, path: ""))
            if id.blocked || ignoredKeys.contains(id.key) || isIgnored(id.key) { continue }
            // Sorted largest first, so the first process of a group is its biggest.
            if groups[id.key] != nil {
                groups[id.key]?.total += s.footprint
            } else {
                groups[id.key] = AppGroup(identity: id, total: s.footprint, biggestKey: key, biggestBytes: s.footprint)
            }
        }
        let ranked = groups.values.sorted {
            $0.total != $1.total ? $0.total > $1.total : $0.identity.key < $1.identity.key
        }
        return Array(ranked.prefix(max(1, limit)))
    }

    private func raisePressure(_ v: PressureVerdict, awake: Double, wall: Date) {
        pressureFindings += 1
        let apps = topApps(limit: pressureRules.topAppsCount)
        let list = apps.map {
            PressureApp(name: $0.identity.name, identityKey: $0.identity.key, isApp: $0.identity.isApp, bytes: $0.total)
        }
        guard let top = apps.first else {
            // Nothing readable to blame: the machine's numbers still go out.
            onFinding(Finding(processKey: ProcessKey(pid: 0, startAbsTime: 0), pid: 0, name: "", path: "",
                              identityKey: "", isApp: false, startBytes: 0, nowBytes: 0, netGrowthBytes: 0,
                              windowSeconds: 0, bucketSeconds: 0, flaggedAtWall: wall, flaggedAtAwake: awake,
                              risingSamples: 0, totalSamples: 0, largestDipBytes: 0, history: [], shouldNotify: true,
                              tier: .pressure, system: v.reading, reason: v.reason, topApps: []))
            return
        }
        // The graph and the "before" figure come from the app's biggest process, when it is in the table: its fast ring is
        // the graph, and the app's total then is today's total with that one process taken back to its oldest point.
        let entry = table[top.biggestKey]
        let history = entry?.fastSamples() ?? []
        var start = top.total
        var window = 0.0
        if let first = history.first {
            start = top.total - top.biggestBytes + first.bytes
            window = max(0, awake - first.seconds)
        }
        // The window that opens on this finding can still be fed from the table.
        entry?.pinnedUntil = max(entry?.pinnedUntil ?? -Double.infinity, awake + rules.pinSeconds)
        onFinding(Finding(processKey: top.biggestKey,
                          pid: top.biggestKey.pid,
                          name: top.identity.name,
                          path: top.identity.path,
                          identityKey: top.identity.key,
                          isApp: top.identity.isApp,
                          startBytes: start,
                          nowBytes: top.total,
                          netGrowthBytes: top.total > start ? top.total - start : 0,
                          windowSeconds: window,
                          bucketSeconds: 0,
                          flaggedAtWall: wall,
                          flaggedAtAwake: awake,
                          risingSamples: 0,
                          totalSamples: history.count,
                          largestDipBytes: 0,
                          history: history,
                          shouldNotify: true,
                          tier: .pressure,
                          system: v.reading,
                          reason: v.reason,
                          topApps: list))
    }

    // MARK: Discovery

    private func held(_ e: Entry, at awake: Double) -> Bool {
        pinned.contains(e.key) || e.pinnedUntil > awake
    }

    private func drop(_ keys: [ProcessKey], forgetPins: Bool) {
        for k in keys {
            table[k] = nil
            if forgetPins { pinned.remove(k) }
        }
    }

    private func discovery(_ seen: [Observed], awake: Double, wall: Date) {
        lastDiscoveryAwake = awake

        var next: [ProcessKey: UInt64] = [:]
        next.reserveCapacity(seen.count)
        var contenders: [Contender] = []
        var sizes: [UInt64] = []
        for o in seen {
            next[o.key] = o.footprint
            if o.footprint >= rules.largeProcessMinBytes { sizes.append(o.footprint) }
            if o.key.pid == ownPID { continue }
            var gain: UInt64 = 0
            if let before = previous[o.key], o.footprint > before { gain = o.footprint - before }
            let ascending = gain >= rules.ascenderMinGainBytes
            let rank = ascending ? Rank(tier: 2, score: gain) : Rank(tier: 1, score: o.footprint)
            if let existing = table[o.key] {
                existing.rank = rank
                continue
            }
            if reported.contains(o.key) { continue }
            if ascending || o.footprint >= rules.largeProcessMinBytes {
                contenders.append(Contender(observed: o, rank: rank))
            }
        }
        previous = next

        // The caches follow the machine: nothing is kept for a process that is no longer there.
        if !identities.isEmpty {
            for k in Array(identities.keys) where next[k] == nil { identities[k] = nil }
        }
        if !reported.isEmpty {
            for k in Array(reported) where next[k] == nil { reported.remove(k) }
        }
        if !lastNotified.isEmpty {
            for (k, t) in Array(lastNotified) where awake - t >= rules.notifyCooldownSeconds { lastNotified[k] = nil }
        }

        // Flat for long and not among the largest: nothing to watch.
        sizes.sort(by: >)
        let topFloor = sizes.count > rules.maxCandidates ? sizes[rules.maxCandidates - 1] : rules.largeProcessMinBytes
        scratchKeys.removeAll(keepingCapacity: true)
        for e in table.values {
            guard awake - e.lastMoved >= rules.flatEvictionSeconds, !held(e, at: awake) else { continue }
            let inTopSet = e.lastBytes >= rules.largeProcessMinBytes && e.lastBytes >= topFloor
            if !inTopSet { scratchKeys.append(e.key) }
        }
        drop(scratchKeys, forgetPins: false)

        // Ascenders first (the biggest gain first), then the largest.
        contenders.sort { a, b in
            a.rank != b.rank ? a.rank > b.rank : a.observed.key.pid < b.observed.key.pid
        }
        for c in contenders {
            let id = identity(of: c.observed)
            if id.blocked || ignoredKeys.contains(id.key) || isIgnored(id.key) { continue }
            if table.count >= rules.maxCandidates {
                guard makeRoom(for: c.rank, awake: awake) else { break }
            }
            let entry = Entry(key: c.observed.key, identity: id, origin: awake,
                              bytes: c.observed.footprint, rank: c.rank, slowCapacity: slowRules.slowRingCapacity)
            table[entry.key] = entry
            feed(entry, bytes: c.observed.footprint, cpuNanos: c.observed.cpuNanos, awake: awake, wall: wall)
        }
    }

    /// Frees one slot by evicting the least wanted candidate that is not held, if the newcomer outranks it.
    private func makeRoom(for rank: Rank, awake: Double) -> Bool {
        var victim: Entry?
        for e in table.values where !held(e, at: awake) {
            guard let v = victim else { victim = e; continue }
            if e.rank < v.rank || (e.rank == v.rank && e.key.pid > v.key.pid) { victim = e }
        }
        guard let chosen = victim, chosen.rank < rank else { return false }
        table[chosen.key] = nil
        return true
    }

    /// The one path read for a process: from the sweep when it carried one, else from `pathOf`. Cached for the process's
    /// lifetime, ignored and excluded processes included, so none of them is looked up again on every pass.
    private func identity(of o: Observed) -> Identity {
        if let hit = identities[o.key] { return hit }
        let path = o.path.isEmpty ? pathOf(o.key.pid) : o.path
        let id: Identity
        if path.isEmpty {
            id = Identity(path: "", key: "", isApp: false, name: "", blocked: true)
        } else {
            let k = IdentityKey.key(forExecutablePath: path)
            id = Identity(path: path,
                          key: k.key,
                          isApp: k.isApp,
                          name: IdentityKey.name(forExecutablePath: path),
                          blocked: excludedPaths.contains(path) || excludedPaths.contains(k.key))
        }
        identities[o.key] = id
        return id
    }
}

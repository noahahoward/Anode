import XCTest
@testable import PowerKit

/// Shared by the Memory Watch tests: sizes in MiB and a seeded random source of their own (no system RNG, so every run
/// plays the same series).
enum MemoryTestKit {
    static func mib(_ x: Double) -> UInt64 { UInt64((x * 1_048_576).rounded()) }

    struct Random {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        /// In [0, 1).
        mutating func unit() -> Double { Double(next() % 1_000_000) / 1_000_000 }
        /// In [-r, r).
        mutating func signed(_ r: Double) -> Double { (unit() * 2 - 1) * r }
        mutating func int(below n: Int) -> Int { Int(next() % UInt64(n)) }
    }
}

/// One tracker fed a synthetic series, remembering every verdict and when it came.
private struct Feeder {
    var tracker = GrowthTracker()
    var rules = GrowthRules.standard
    var found: [(t: Double, verdict: GrowthVerdict)] = []

    mutating func feed(_ bytes: UInt64, at t: Double, cpu: UInt64? = nil, age: Double = 10_000) {
        if let v = tracker.ingest(bytes: bytes, at: t, cpuNanos: cpu, processAge: age, rules: rules) {
            found.append((t: t, verdict: v))
        }
    }
}

/// A process's total CPU time in nanoseconds at awake second `t`, when it used `fraction` of one core the whole time.
private func cpuNanos(_ fraction: Double, at t: Double) -> UInt64 { UInt64((fraction * t * 1e9).rounded()) }

private func mib(_ x: Double) -> UInt64 { MemoryTestKit.mib(x) }

/// The growth rule, played against synthetic series with an injected clock. Every "found" case below is checked by hand
/// against each gate (50 MiB and 10 % of the starting footprint, four buckets each carrying a tenth of the growth, no
/// step over half of it, age over three minutes); every "never" case fails a gate by arithmetic, not by luck of a seed.
final class MemoryGrowthTests: XCTestCase {

    // MARK: Found

    /// A leak of 1 MiB a second on a 200 MiB process must be found as soon as the first full window exists, and named with
    /// the numbers that tripped. Failing here means the detector is blind to the plainest leak there is.
    func testASteadyLeakIsFoundWithinOneHopOfTheFirstFullWindow() {
        var f = Feeder()
        for i in 0...150 { let t = Double(i) * 2; f.feed(mib(200 + t), at: t) }
        XCTAssertEqual(f.found.count, 1, "one finding, once")
        guard let hit = f.found.first else { return }
        XCTAssertGreaterThanOrEqual(hit.t, 60)
        XCTAssertLessThanOrEqual(hit.t, 64 + 16, "the first full window is 64 s at a 2 s cadence; one hop of slack")
        XCTAssertEqual(hit.verdict.startBytes, mib(200))
        XCTAssertEqual(hit.verdict.netGrowthBytes, mib(64))
        XCTAssertEqual(hit.verdict.windowSeconds, 64, accuracy: 0.001)
        XCTAssertGreaterThan(hit.verdict.totalSamples, 0)
        XCTAssertEqual(hit.verdict.risingSamples, hit.verdict.totalSamples, "every sample of a smooth ramp rose")
        XCTAssertEqual(hit.verdict.largestDipBytes, 0)
    }

    /// Real memory is never smooth: +/-3 MiB of noise on every sample is inside the dip tolerance (8 MiB), so a noisy
    /// leak is still a leak. Failing here means ordinary jitter hides leaks.
    func testALeakWithThreeMiBOfNoiseIsStillFound() {
        var f = Feeder()
        var rand = MemoryTestKit.Random(seed: 11)
        for i in 0...200 {
            let t = Double(i) * 2
            f.feed(mib(200 + t + rand.signed(3)), at: t)
        }
        XCTAssertEqual(f.found.count, 1)
        XCTAssertLessThanOrEqual(f.found.first?.t ?? 999, 120)
        XCTAssertLessThanOrEqual(f.found.first?.verdict.largestDipBytes ?? .max, mib(8),
                                 "a tolerated dip is never more than the tolerance")
    }

    /// A dip inside the tolerance does not reset detection, and the explanation can say how deep it was.
    func testASmallDipInsideTheToleranceIsTolerated() {
        var f = Feeder()
        for i in 0...60 {
            let t = Double(i) * 2
            var v = 200 + t
            if t == 30 { v = 221 }          // the high-water mark was 228 at t = 28: a dip of 7 MiB
            f.feed(mib(v), at: t)
        }
        XCTAssertEqual(f.found.count, 1)
        XCTAssertEqual(f.found.first?.t, 64)
        XCTAssertEqual(f.found.first?.verdict.largestDipBytes, mib(7))
    }

    /// A process that is still warming up is not leaking: an otherwise perfect leak is not flagged until it is three
    /// minutes old, and then it is flagged on the next hop.
    func testAYoungProcessIsNotFlaggedUntilItIsThreeMinutesOld() {
        var f = Feeder()
        for i in 0...150 {
            let t = Double(i) * 2
            f.feed(mib(100 + t), at: t, age: t)      // it started at t = 0
        }
        XCTAssertEqual(f.found.count, 1)
        guard let hit = f.found.first else { return }
        XCTAssertGreaterThanOrEqual(hit.t, 180, "nothing before its third minute")
        XCTAssertLessThanOrEqual(hit.t, 180 + 16, "and the next hop after it")
    }

    // MARK: Never

    /// Noise around a constant gains nothing: net growth stays far under 50 MiB. Failing here means a quiet process can
    /// notify.
    func testANoisyPlateauIsNeverFlagged() {
        var f = Feeder()
        var rand = MemoryTestKit.Random(seed: 5)
        for i in 0...900 { let t = Double(i) * 2; f.feed(mib(500 + rand.signed(5)), at: t) }
        XCTAssertTrue(f.found.isEmpty)
    }

    /// One big allocation (a document opened, a model loaded) is a step, not a trend: it is over half the net growth and
    /// the buckets around it are flat. Failing here means every big open notifies.
    func testASingleJumpThenFlatIsNeverFlagged() {
        var f = Feeder()
        for i in 0...300 {
            let t = Double(i) * 2
            f.feed(mib(t < 100 ? 300 : 800), at: t)
        }
        XCTAssertTrue(f.found.isEmpty)
    }

    /// Growth that already stopped (40 s of ramp, then a plateau) fails the spread rule: the newest bucket gained nothing.
    func testARampThatStopsAfterFortySecondsIsNeverFlagged() {
        var f = Feeder()
        for i in 0...300 {
            let t = Double(i) * 2
            f.feed(mib(200 + 2 * min(t, 40)), at: t)
        }
        XCTAssertTrue(f.found.isEmpty)
    }

    /// A spike that comes back down (+300 MiB for 20 s) is a dip beyond tolerance and re-anchors the window.
    func testAShortSpikeIsNeverFlagged() {
        var f = Feeder()
        for i in 0...300 {
            let t = Double(i) * 2
            f.feed(mib(t >= 100 && t < 120 ? 800 : 500), at: t)
        }
        XCTAssertTrue(f.found.isEmpty)
    }

    /// Grow 100 MiB, drop 80, repeat: every drop re-anchors the window before it can hold four buckets, whatever the net
    /// drift over the hours. Failing here means garbage-collected heaps notify.
    func testASawtoothIsNeverFlagged() {
        var f = Feeder()
        for i in 0..<1200 {
            let cycle = i / 16, p = i % 16
            let v = 200 + 20 * Double(cycle) + 100 * Double(p) / 15
            f.feed(mib(v), at: Double(i) * 2)
        }
        XCTAssertTrue(f.found.isEmpty)
    }

    /// DOCUMENTED LIMIT: a leak of about 6 MiB a minute is never found, because under 50 MiB over a 60 s window is below
    /// the absolute threshold. This test pins that limit so lowering the threshold is a decision, not an accident.
    func testASlowLeakOfSixMiBAMinuteIsNeverFlagged() {
        var f = Feeder()
        for i in 0..<3600 {                      // two hours at 2 s
            let t = Double(i) * 2
            f.feed(mib(200 + t * 0.1), at: t)
        }
        XCTAssertTrue(f.found.isEmpty, "documented limit: slower than about 50 MiB a minute is out of reach")
    }

    /// A random walk of +/-50 MiB steps on a 3 GiB process, reflected inside a 250 MiB band. The band is narrower than
    /// 10 % of the footprint (about 295 MiB), so no window can ever show the relative growth the rule asks for: this
    /// guards the false positive named in the plan (a big, noisy process whose walk gains in every bucket), and does it by
    /// arithmetic, not by the luck of a seed.
    func testARandomWalkOnABigProcessNeverFlagsInsideABandNarrowerThanTheRelativeThreshold() {
        var f = Feeder()
        var rand = MemoryTestKit.Random(seed: 3)
        let centre = 3.0 * 1024
        var v = centre
        for i in 0..<5400 {
            v += rand.signed(50)
            v = min(max(v, centre - 125), centre + 125)
            f.feed(mib(v), at: Double(i) * 2)
        }
        XCTAssertTrue(f.found.isEmpty)
    }

    // MARK: Dips

    /// A large dip in the middle of a window re-anchors it: the growth before the dip no longer counts, so a leak that
    /// resumes is flagged one FULL window after the dip, starting from the dip's footprint.
    func testALargeDipReanchorsTheWindow() {
        var f = Feeder()
        for i in 0...90 {
            let t = Double(i) * 2
            let v = t <= 40 ? 200 + t : (t == 42 ? 180 : 180 + (t - 42))
            f.feed(mib(v), at: t)
        }
        XCTAssertEqual(f.found.count, 1)
        guard let hit = f.found.first else { return }
        XCTAssertGreaterThanOrEqual(hit.t, 42 + 60, "a whole new window after the dip")
        XCTAssertEqual(hit.verdict.startBytes, mib(180), "measured from the dip, not from before it")
    }

    /// The same dip with nothing after it is simply no alert.
    func testALargeDipInTheMiddleOfAGrowingWindowGivesNoAlertWhenGrowthStops() {
        var f = Feeder()
        for i in 0...300 {
            let t = Double(i) * 2
            f.feed(mib(t <= 40 ? 200 + t : 180), at: t)
        }
        XCTAssertTrue(f.found.isEmpty)
    }

    // MARK: Cadence

    private func ramp(cadence: Double, seconds: Double) -> Feeder {
        var f = Feeder()
        var rand = MemoryTestKit.Random(seed: UInt64(cadence * 100))
        var i = 0
        while Double(i) * cadence < seconds {
            defer { i += 1 }
            if i % 7 == 3 { continue }                                  // a dropped tick, never two in a row
            let t = Double(i) * cadence + rand.signed(0.2 * cadence)    // jitter, never enough to reorder samples
            guard t >= 0 else { continue }
            f.feed(mib(200 + t), at: t)
        }
        return f
    }

    /// A smooth ramp, jittered, with dropped ticks, gets the same verdict at a 1, 2, 8 and 30 s cadence: found once. At
    /// 30 s the buckets are 60 s long, so the window stretches. Failing here means the answer depends on how often Anode
    /// happens to sample (window open or closed).
    func testASmoothRampGivesTheSameVerdictAtEveryCadenceAndTheWindowStretchesAtThirtySeconds() {
        var windows: [Double: Double] = [:]
        for cadence in [1.0, 2.0, 8.0, 30.0] {
            let f = ramp(cadence: cadence, seconds: 1800)
            XCTAssertEqual(f.found.count, 1, "found exactly once at a \(cadence) s cadence")
            windows[cadence] = f.found.first?.verdict.windowSeconds ?? 0
            XCTAssertGreaterThanOrEqual(windows[cadence] ?? 0, 60)
        }
        XCTAssertGreaterThan(windows[30] ?? 0, 120, "a 30 s cadence stretches the window")
        XCTAssertGreaterThan(windows[30] ?? 0, windows[8] ?? .infinity)
        XCTAssertGreaterThan(windows[30] ?? 0, windows[2] ?? .infinity)
        XCTAssertGreaterThan(windows[30] ?? 0, windows[1] ?? .infinity)
    }

    /// 10 MiB every 6 s. Counting the share of samples that rise would flag this at 8 s (nearly every sample rises) and miss
    /// it at 2 s (one in three): the bucket spread rule measures the same thing in time, so both cadences give the same
    /// verdict, the same numbers and the same moment. Failing here means detection depends on the window being open.
    func testAStepwiseLeakGivesTheSameVerdictAtTwoAndEightSeconds() {
        func run(cadence: Double) -> Feeder {
            var f = Feeder()
            var i = 0
            while Double(i) * cadence <= 200 {
                let t = Double(i) * cadence
                f.feed(mib(200 + 10 * (t / 6).rounded(.down)), at: t)
                i += 1
            }
            return f
        }
        let two = run(cadence: 2), eight = run(cadence: 8)
        XCTAssertEqual(two.found.count, 1)
        XCTAssertEqual(eight.found.count, 1)
        XCTAssertEqual(two.found.first?.t, 64)
        XCTAssertEqual(eight.found.first?.t, 64)
        XCTAssertEqual(two.found.first?.verdict.netGrowthBytes, mib(100))
        XCTAssertEqual(eight.found.first?.verdict.netGrowthBytes, mib(100))
        XCTAssertEqual(two.found.first?.verdict.windowSeconds, eight.found.first?.verdict.windowSeconds)
    }

    /// The window closing or opening changes the cadence mid-detection (2 s to 8 s, or 8 s to 2 s). A steady leak is still
    /// found, once, with no reset and no second report.
    func testCadenceSwitchingMidDetectionStillFindsTheLeakOnce() {
        func series(_ times: [Double]) -> Feeder {
            var f = Feeder()
            for t in times { f.feed(mib(100 + 2 * t), at: t) }      // 2 MiB a second
            return f
        }
        let slowAfter = (0...15).map { Double($0) * 2 } + stride(from: 38.0, through: 400, by: 8).map { $0 }
        let fastAfter = stride(from: 0.0, through: 32, by: 8).map { $0 } + stride(from: 34.0, through: 400, by: 2).map { $0 }
        for times in [slowAfter, fastAfter] {
            let f = series(times)
            XCTAssertEqual(f.found.count, 1, "found once, never twice")
            XCTAssertLessThanOrEqual(f.found.first?.t ?? 999, 150)
        }
    }

    /// A bucket that holds a single sample (a 16 s cadence against a 15 s bucket) still measures its growth, because each
    /// bucket starts at the previous one's last sample. Without that the first bucket would read zero and a clean leak
    /// would never pass the spread rule.
    func testABucketHoldingOneSampleStillMeasuresGrowth() {
        var f = Feeder()
        for i in 0...12 { let t = Double(i) * 16; f.feed(mib(200 + t), at: t) }
        XCTAssertEqual(f.found.count, 1)
        XCTAssertEqual(f.found.first?.t, 112, "first bucket 16 s (one sample), then 32 s buckets")
    }

    func testBucketLengthIsTwiceTheCadenceButNeverUnderFifteenSeconds() {
        XCTAssertEqual(GrowthTracker.bucketSeconds(cadence: 2, rules: .standard), 15)
        XCTAssertEqual(GrowthTracker.bucketSeconds(cadence: 8, rules: .standard), 16)
        XCTAssertEqual(GrowthTracker.bucketSeconds(cadence: 30, rules: .standard), 60)
        XCTAssertEqual(GrowthTracker.bucketSeconds(cadence: 0, rules: .standard), 15)
    }

    // MARK: Sleep, reporting, size

    /// After a sleep the owner resets the tracker: nothing is tracked through the quiet period, then a whole new window
    /// is built, so the leak is flagged one full window after the quiet ends and not before.
    func testAResetHoldsAQuietPeriodAndThenBuildsAFreshWindow() {
        var f = Feeder()
        for i in 0...20 { let t = Double(i) * 2; f.feed(mib(200 + t), at: t) }
        f.tracker.reset(quietUntil: 200)
        XCTAssertEqual(f.tracker.phase, .quiet)
        XCTAssertEqual(f.tracker.quietUntil, 200)
        XCTAssertNil(f.tracker.windowStartBytes)
        for i in 21...250 { let t = Double(i) * 2; f.feed(mib(200 + t), at: t) }
        XCTAssertEqual(f.found.count, 1)
        XCTAssertGreaterThanOrEqual(f.found.first?.t ?? 0, 200 + 60)
        XCTAssertEqual(f.found.first?.verdict.startBytes, mib(200 + 200), "the window starts at the end of the quiet period")
    }

    /// A tracker that has reported never reports again, and a reset (a sleep) does not make it forget.
    func testAReportedTrackerStaysReportedThroughAReset() {
        var f = Feeder()
        for i in 0...60 { let t = Double(i) * 2; f.feed(mib(200 + t), at: t) }
        XCTAssertEqual(f.tracker.phase, .reported)
        f.tracker.reset(quietUntil: 5000)
        XCTAssertEqual(f.tracker.phase, .reported)
        for i in 61...600 { let t = Double(i) * 2; f.feed(mib(200 + t), at: t) }
        XCTAssertEqual(f.found.count, 1)
    }

    /// The tracker is a fixed-size value with nothing on the heap. The budget was 192 bytes; each of the four buckets
    /// gained a CPU total and a count (32 to 40 bytes) and the tracker a last CPU reading, so it is about 218 bytes and
    /// the budget is 224 (its 224-byte stride, a multiple of 16).
    func testTheTrackerIsAFixedSizeValueWithinItsBudget() {
        XCTAssertLessThanOrEqual(MemoryLayout<GrowthTracker>.size, 224)
        XCTAssertLessThanOrEqual(MemoryLayout<GrowthTracker>.stride, 224)
    }

    /// Every starting value is in GrowthRules.standard and nowhere else. A change to one is a decision, so it changes
    /// this test too.
    func testTheStandardRulesAreTheDocumentedStartingValues() {
        let r = GrowthRules.standard
        XCTAssertEqual(r.windowSeconds, 60)
        XCTAssertEqual(r.minBucketSeconds, 15)
        XCTAssertEqual(r.bucketCadenceFactor, 2)
        XCTAssertEqual(r.minNetGrowthBytes, 50 * 1_048_576)
        XCTAssertEqual(r.minNetGrowthFraction, 0.10)
        XCTAssertEqual(r.minBucketShareOfNet, 0.10)
        XCTAssertEqual(r.maxLargestStepShare, 0.50)
        XCTAssertEqual(r.dipToleranceMinBytes, 8 * 1_048_576)
        XCTAssertEqual(r.dipToleranceFractionOfStart, 0.02)
        XCTAssertEqual(r.dipToleranceFractionOfGrowth, 0.25)
        XCTAssertEqual(r.minProcessAgeSeconds, 180)
        XCTAssertEqual(r.quietAfterGapSeconds, 120)
        XCTAssertEqual(r.maxBusyFraction, 0.25, "a quarter of one core, averaged over the window")
        XCTAssertEqual(r.risingEpsilonMinBytes, 256 * 1024)
        XCTAssertEqual(r.risingEpsilonFraction, 0.001)
        XCTAssertEqual(r.maxCandidates, 32)
        XCTAssertEqual(r.ascenderMinGainBytes, 24 * 1_048_576)
        XCTAssertEqual(r.largeProcessMinBytes, 150 * 1_048_576)
        XCTAssertEqual(r.flatEvictionSeconds, 300)
        XCTAssertEqual(r.pinSeconds, 600)
        XCTAssertEqual(r.notifyCooldownSeconds, 600)
        XCTAssertEqual(r.slowFeedIntervalSeconds, 300)
        XCTAssertEqual(r.slowRingCapacity, 48)
    }

    /// The slow tier's thresholds are the documented ones, all in `GrowthRules.slow`, and the rest stays as the standard
    /// rules have it. A change to one is a decision, so it changes this test too.
    func testTheSlowRulesAreTheDocumentedStartingValues() {
        let r = GrowthRules.slow
        let standard = GrowthRules.standard
        XCTAssertEqual(r.windowSeconds, 7200)
        XCTAssertEqual(r.minBucketSeconds, 1800)
        XCTAssertEqual(r.bucketCadenceFactor, standard.bucketCadenceFactor)
        XCTAssertEqual(r.minNetGrowthBytes, 768 * 1_048_576)
        XCTAssertEqual(r.minNetGrowthFraction, 0.15)
        XCTAssertEqual(r.minBucketShareOfNet, 0.10)
        XCTAssertEqual(r.maxLargestStepShare, 0.50)
        XCTAssertEqual(r.minProcessAgeSeconds, 1800)
        XCTAssertEqual(r.dipToleranceMinBytes, 32 * 1_048_576)
        XCTAssertEqual(r.dipToleranceFractionOfStart, standard.dipToleranceFractionOfStart)
        XCTAssertEqual(r.dipToleranceFractionOfGrowth, standard.dipToleranceFractionOfGrowth)
        XCTAssertEqual(r.slowFeedIntervalSeconds, 300)
        XCTAssertEqual(r.slowRingCapacity, 48)
        XCTAssertEqual(r.maxBusyFraction, .infinity, "the slow tier never gates on CPU")
        XCTAssertEqual(r.maxCandidates, standard.maxCandidates, "the candidate table is shared and unchanged")
    }

    // MARK: The slow tier, tracker alone

    /// 9 MiB a minute on a 3 GiB process, one reading every 300 s: found once, at the first moment a two-hour window of
    /// four 30-minute buckets exists, with the numbers that tripped. Failing here means the slow rules cannot see the leak the
    /// fast rules are blind to.
    func testTheSlowRulesFindANineMiBAMinuteLeakFedEveryFiveMinutes() {
        var f = Feeder()
        f.rules = .slow
        for i in 0...(3 * 3600 / 300) {
            let t = Double(i) * 300
            f.feed(mib(3072 + 0.15 * t), at: t)
        }
        XCTAssertEqual(f.found.count, 1, "found once")
        guard let hit = f.found.first else { return }
        XCTAssertEqual(hit.t, 7200, "four 1800 s buckets, the window judged as the fourth closes")
        XCTAssertEqual(hit.verdict.windowSeconds, 7200, accuracy: 0.001)
        XCTAssertEqual(hit.verdict.bucketSeconds, 1800, accuracy: 0.001)
        XCTAssertEqual(hit.verdict.startBytes, mib(3072))
        XCTAssertEqual(hit.verdict.netGrowthBytes, mib(1080))
        XCTAssertEqual(hit.verdict.totalSamples, 24)
        XCTAssertEqual(hit.verdict.risingSamples, 24, "every 45 MiB step is a rise")
        XCTAssertEqual(hit.verdict.largestDipBytes, 0)
    }

    /// The fast rules cannot see that leak at all: 9 MiB a minute is far under 50 MiB inside a window of a minute.
    func testTheFastRulesNeverSeeTheSameNineMiBAMinuteLeak() {
        var f = Feeder()
        for i in 0..<(3 * 3600 / 8) {
            let t = Double(i) * 8
            f.feed(mib(3072 + 0.15 * t), at: t)
        }
        XCTAssertTrue(f.found.isEmpty)
    }

    /// `markReported` stops a tracker that never found anything itself (the other tier reported the process): it never
    /// raises, and a reset does not undo it.
    func testMarkReportedStopsATrackerThatIsStillLearning() {
        var f = Feeder()
        f.rules = .slow
        f.feed(mib(3072), at: 0)
        f.tracker.markReported()
        XCTAssertEqual(f.tracker.phase, .reported)
        for i in 1...(4 * 3600 / 300) {
            let t = Double(i) * 300
            f.feed(mib(3072 + 0.15 * t), at: t)
        }
        XCTAssertTrue(f.found.isEmpty, "a perfect leak raises nothing from a tracker marked reported")
        f.tracker.reset(quietUntil: 99_999)
        XCTAssertEqual(f.tracker.phase, .reported)
    }

    // MARK: The words

    private func finding(net: UInt64, now: UInt64, window: Double, rising: Int = 21, total: Int = 24,
                         bucket: Double = 15, dip: UInt64 = 6 << 20, tier: GrowthTier = .fast,
                         cpu: Double? = nil) -> Finding {
        Finding(processKey: ProcessKey(pid: 1, startAbsTime: 1), pid: 1, name: "Safari",
                path: "/Applications/Safari.app/Contents/MacOS/Safari", identityKey: "/Applications/Safari.app",
                isApp: true, startBytes: now - net, nowBytes: now, netGrowthBytes: net,
                windowSeconds: window, bucketSeconds: bucket,
                flaggedAtWall: Date(timeIntervalSinceReferenceDate: 0), flaggedAtAwake: 0,
                risingSamples: rising, totalSamples: total, largestDipBytes: dip, history: [], shouldNotify: true,
                tier: tier, cpuFraction: cpu)
    }

    /// A finding built the way every existing caller builds one (no tier) is a fast finding.
    func testAFindingDefaultsToTheFastTier() {
        XCTAssertEqual(finding(net: mib(100), now: mib(500), window: 64).tier, .fast)
        XCTAssertEqual(finding(net: mib(100), now: mib(500), window: 64, tier: .slow).tier, .slow)
    }

    /// Durations are worded in seconds up to ten minutes (the fast tier's wording, which existing notifications rely on),
    /// then in minutes up to two hours, then in hours and minutes.
    func testDurationTextWordsSecondsMinutesAndHours() {
        XCTAssertEqual(DurationText.text(seconds: 45), "45 seconds")
        XCTAssertEqual(DurationText.text(seconds: 75), "75 seconds")
        XCTAssertEqual(DurationText.text(seconds: 240.4), "240 seconds")
        XCTAssertEqual(DurationText.text(seconds: 1), "1 second")
        XCTAssertEqual(DurationText.text(seconds: 600), "10 minutes")
        XCTAssertEqual(DurationText.text(seconds: 5400), "90 minutes")
        XCTAssertEqual(DurationText.text(seconds: 7199.7), "2 hours", "rounds to 120 minutes, which is 2 hours")
        XCTAssertEqual(DurationText.text(seconds: 7200), "2 hours")
        XCTAssertEqual(DurationText.text(seconds: 7260), "2 hours 1 minute")
        XCTAssertEqual(DurationText.text(seconds: 7800), "2 hours 10 minutes")
        XCTAssertEqual(DurationText.text(seconds: 10_800), "3 hours")
        XCTAssertEqual(DurationText.text(seconds: -5), "0 seconds")
        XCTAssertEqual(DurationText.approximate(seconds: 7296), "2 hours", "snapped to five minutes for \"about\"")
        XCTAssertEqual(DurationText.approximate(seconds: 5400), "90 minutes")
        XCTAssertEqual(DurationText.approximate(seconds: 75), "75 seconds")
    }

    /// A slow finding's notification says the growth took hours and never "the last minute" or a count of seconds.
    /// Failing here means a leak found over two hours is announced as if it had happened in a moment.
    func testTheSlowNotificationBodyWordsTheDurationInHoursAndMinutes() {
        let net: UInt64 = 1 << 30, now: UInt64 = 4 << 30
        XCTAssertEqual(finding(net: net, now: now, window: 7200, tier: .slow).notificationBody,
                       "Safari's memory has grown 1.0 GB over 2 hours and is now 4.0 GB. Click to see details.")
        XCTAssertEqual(finding(net: net, now: now, window: 7800, tier: .slow).notificationBody,
                       "Safari's memory has grown 1.0 GB over 2 hours 10 minutes and is now 4.0 GB. Click to see details.")
        XCTAssertEqual(finding(net: net, now: now, window: 5400, tier: .slow).notificationBody,
                       "Safari's memory has grown 1.0 GB over 90 minutes and is now 4.0 GB. Click to see details.")
        XCTAssertFalse(finding(net: net, now: now, window: 7200, tier: .slow).notificationBody.contains("minute and"))
    }

    /// The slow explanation says it rose for about so many hours, grew in every stretch of so many minutes and never fell
    /// back by more than the dip, and why Anode can only say "possible". The fast wording is untouched (its own test above).
    func testTheSlowExplanationSaysHoursAndStretchesAndStaysPossible() {
        let text = finding(net: 1 << 30, now: 4 << 30, window: 7296, bucket: 1824, dip: 32 << 20, tier: .slow).explanation
        XCTAssertTrue(text.contains("rose steadily for about 2 hours"), text)
        XCTAssertTrue(text.contains("grew in every stretch of 30 minutes"), text)
        XCTAssertTrue(text.contains("never fell back by more than 32.0 MB"), text)
        XCTAssertTrue(text.contains("Long sessions and apps that keep opening things look similar"), text)
        XCTAssertTrue(text.contains("can only say \"possible\""), text)
        XCTAssertFalse(text.contains("seconds"), text)
        let flat = finding(net: 1 << 30, now: 4 << 30, window: 7200, bucket: 1800, dip: 0, tier: .slow).explanation
        XCTAssertTrue(flat.contains("never fell back."), flat)
    }

    /// The notification says how long the growth was really measured over, not a fixed minute: 75 s here, 240 s at a slow
    /// sampling setting.
    func testTheNotificationBodyUsesTheActualWindowSeconds() {
        let now = UInt64(1.8 * 1_073_741_824)
        XCTAssertEqual(finding(net: mib(412), now: now, window: 75).notificationBody,
                       "Safari's memory grew 412 MB over 75 seconds and is now 1.8 GB. Click to see details.")
        XCTAssertEqual(finding(net: mib(412), now: now, window: 240.4).notificationBody,
                       "Safari's memory grew 412 MB over 240 seconds and is now 1.8 GB. Click to see details.")
    }

    /// The explanation is built from the numbers that tripped, and always says "possible".
    func testTheExplanationComesFromTheNumbersThatTripped() {
        let text = finding(net: mib(412), now: mib(1800), window: 75).explanation
        XCTAssertTrue(text.contains("Its memory rose in 21 of 24 samples"), text)
        XCTAssertTrue(text.contains("grew steadily in every 15-second stretch"), text)
        XCTAssertTrue(text.contains("never fell back by more than 6.0 MB"), text)
        XCTAssertTrue(text.contains("can only say \"possible\""), text)
        let flat = finding(net: mib(100), now: mib(500), window: 64, dip: 0).explanation
        XCTAssertTrue(flat.contains("never fell back."), flat)
    }

    func testRateAndFractionAreWorkedOutFromTheWindow() {
        let f = finding(net: mib(300), now: mib(1500), window: 60)
        XCTAssertEqual(f.growthBytesPerSecond, Double(mib(5)), accuracy: 1)
        XCTAssertEqual(f.growthFraction, 0.25, accuracy: 0.0001)
    }

    // MARK: CPU

    /// A fast-tier leak that otherwise fires (1 MiB a second on a 200 MiB process) does not fire while the process averages
    /// 80 % of a core: the growth is work it was doing. Failing here means a busy build or test run is called a leak.
    func testALeakWhileTheProcessIsBusyIsNeverFlagged() {
        var f = Feeder()
        for i in 0...300 { let t = Double(i) * 2; f.feed(mib(200 + t), at: t, cpu: cpuNanos(0.8, at: t)) }
        XCTAssertTrue(f.found.isEmpty)
        XCTAssertNotEqual(f.tracker.phase, .reported)
    }

    /// The same growth at 3 % of a core is flagged on the first full window, and the verdict says how busy the process was.
    func testTheSameLeakWhileTheProcessIsNearlyIdleIsFlaggedWithItsCPU() {
        var f = Feeder()
        for i in 0...150 { let t = Double(i) * 2; f.feed(mib(200 + t), at: t, cpu: cpuNanos(0.03, at: t)) }
        XCTAssertEqual(f.found.count, 1)
        guard let hit = f.found.first else { return }
        XCTAssertEqual(hit.t, 64)
        XCTAssertEqual(hit.verdict.cpuFraction ?? -1, 0.03, accuracy: 0.002)
    }

    /// Either side of the line: 20 % of a core is under the quarter and flagged, 30 % is over it and is not.
    func testTheBusyLineIsAQuarterOfACore() {
        var under = Feeder(), over = Feeder()
        for i in 0...150 {
            let t = Double(i) * 2
            under.feed(mib(200 + t), at: t, cpu: cpuNanos(0.20, at: t))
            over.feed(mib(200 + t), at: t, cpu: cpuNanos(0.30, at: t))
        }
        XCTAssertEqual(under.found.count, 1)
        XCTAssertTrue(over.found.isEmpty)
    }

    /// Several busy threads read above one core (300 %): gated all the same.
    func testMoreThanOneCoreIsBusy() {
        var f = Feeder()
        for i in 0...300 { let t = Double(i) * 2; f.feed(mib(200 + t), at: t, cpu: cpuNanos(3.0, at: t)) }
        XCTAssertTrue(f.found.isEmpty)
    }

    /// A busy stretch followed by an idle one: nothing while it is busy, and then the window slides until it holds
    /// (almost) only idle time and the leak is flagged. 80 % of a core until t = 100, then 3 %: the window [96, 160] holds
    /// four busy seconds, which averages about 8 %, and the one before it (20 busy seconds) is still over the quarter.
    func testABusyWindowFollowedByAnIdleOneFiresOnTheIdleOne() {
        var f = Feeder()
        let busyUntil = 100.0
        for i in 0...250 {
            let t = Double(i) * 2
            let cpu = UInt64((0.8 * min(t, busyUntil) * 1e9 + 0.03 * max(0, t - busyUntil) * 1e9).rounded())
            f.feed(mib(200 + t), at: t, cpu: cpu)
        }
        XCTAssertEqual(f.found.count, 1)
        guard let hit = f.found.first else { return }
        XCTAssertGreaterThan(hit.t, busyUntil, "never while it was busy")
        XCTAssertLessThanOrEqual(hit.t, busyUntil + 80, "and within a window and a hop of it going quiet")
        XCTAssertLessThan(hit.verdict.cpuFraction ?? 1, 0.25)
        XCTAssertGreaterThan(hit.verdict.cpuFraction ?? 0, 0.03, "the window still held a little of the busy stretch")
    }

    /// A window that is re-anchored by a dip takes none of the CPU used before it: a busy ramp that falls back (a finished
    /// job), then a quiet leak, is judged on the quiet leak alone.
    func testACPUSpentBeforeAReanchorDoesNotCountAgainstTheNewWindow() {
        var f = Feeder()
        let dipAt = 42.0
        for i in 0...150 {
            let t = Double(i) * 2
            let bytes = t < dipAt ? mib(200 + t) : mib(150 + (t - dipAt))
            let cpu = UInt64((0.8 * min(t, dipAt) * 1e9 + 0.03 * max(0, t - dipAt) * 1e9).rounded())
            f.feed(bytes, at: t, cpu: cpu)
        }
        XCTAssertEqual(f.found.count, 1)
        guard let hit = f.found.first else { return }
        XCTAssertEqual(hit.verdict.startBytes, mib(150), "the window began at the dip")
        XCTAssertEqual(hit.verdict.cpuFraction ?? -1, 0.03, accuracy: 0.002)
    }

    /// CPU unknown (nil) gates nothing: the verdict is the one it always was, and carries no fraction.
    func testAnUnknownCPUFiresAsBefore() {
        var f = Feeder()
        for i in 0...150 { let t = Double(i) * 2; f.feed(mib(200 + t), at: t) }
        XCTAssertEqual(f.found.count, 1)
        XCTAssertEqual(f.found.first?.t, 64)
        XCTAssertNil(f.found.first?.verdict.cpuFraction)
        // A tracker that sees the CPU on only some samples cannot call the window busy, so it does not gate either.
        var some = Feeder()
        for i in 0...150 {
            let t = Double(i) * 2
            some.feed(mib(200 + t), at: t, cpu: i % 2 == 0 ? cpuNanos(0.8, at: t) : nil)
        }
        XCTAssertEqual(some.found.count, 1)
        XCTAssertNil(some.found.first?.verdict.cpuFraction)
    }

    /// The slow tier's rules never gate: the same slow climb at 80 % of a core is found, and says it averaged that.
    func testTheSlowRulesFindTheSameClimbAtEightyPercentOfACore() {
        var f = Feeder()
        f.rules = .slow
        for i in 0...(3 * 3600 / 300) {
            let t = Double(i) * 300
            f.feed(mib(3072 + 0.15 * t), at: t, cpu: cpuNanos(0.8, at: t))
        }
        XCTAssertEqual(f.found.count, 1)
        XCTAssertEqual(f.found.first?.t, 7200)
        XCTAssertEqual(f.found.first?.verdict.cpuFraction ?? -1, 0.8, accuracy: 0.01)
    }

    /// A CPU counter that goes backwards (a reused pid, a counter reset) adds nothing for that sample and breaks nothing:
    /// no trap, a quiet leak is still flagged with a fraction a hair under the true one, and a busy one is still gated.
    func testACPUCounterThatGoesBackwardsContributesNothing() {
        func cpuWithReset(_ fraction: Double, at t: Double) -> UInt64 {
            t < 30 ? cpuNanos(fraction, at: t) : cpuNanos(fraction, at: t - 30)    // back to nearly zero at t = 30
        }
        var quiet = Feeder(), busy = Feeder()
        for i in 0...150 {
            let t = Double(i) * 2
            quiet.feed(mib(200 + t), at: t, cpu: cpuWithReset(0.03, at: t))
            busy.feed(mib(200 + t), at: t, cpu: cpuWithReset(0.8, at: t))
        }
        XCTAssertEqual(quiet.found.count, 1)
        let fraction = quiet.found.first?.verdict.cpuFraction ?? -1
        XCTAssertGreaterThan(fraction, 0.02)
        XCTAssertLessThanOrEqual(fraction, 0.03)
        XCTAssertTrue(busy.found.isEmpty, "losing one sample's CPU does not make a 80 % window look idle")
        // The most extreme counters do not trap either.
        var wild = Feeder()
        for i in 0...150 {
            let t = Double(i) * 2
            wild.feed(mib(200 + t), at: t, cpu: i % 2 == 0 ? UInt64.max : 0)
        }
        XCTAssertLessThanOrEqual(wild.found.count, 1)
    }

    // MARK: The words, with CPU

    /// A fast finding with a known fraction adds one sentence, with the percentage rounded, and keeps every other.
    func testTheFastExplanationSaysHowBusyTheProcessWas() {
        let plain = finding(net: mib(412), now: mib(1800), window: 75).explanation
        let text = finding(net: mib(412), now: mib(1800), window: 75, cpu: 0.034).explanation
        XCTAssertEqual(text, plain + " It used about 3% of a core while its memory grew, "
                       + "so work it was doing does not explain the growth.")
        XCTAssertTrue(finding(net: mib(412), now: mib(1800), window: 75, cpu: 0.2449).explanation.contains("about 24% of a core"))
        XCTAssertTrue(finding(net: mib(412), now: mib(1800), window: 75, cpu: 0.0049).explanation.contains("It used under 1% of a core"))
        XCTAssertTrue(finding(net: mib(412), now: mib(1800), window: 75, cpu: 0).explanation.contains("It used under 1% of a core"))
    }

    /// With the CPU unknown the explanation is exactly what it was, and so is the notification, known or not.
    func testNoSentenceAboutCPUWhenItIsUnknownAndTheNotificationNeverChanges() {
        let plain = finding(net: mib(412), now: mib(1800), window: 75)
        XCTAssertNil(plain.cpuFraction)
        XCTAssertFalse(plain.explanation.contains("core"), plain.explanation)
        XCTAssertEqual(finding(net: mib(412), now: mib(1800), window: 75, cpu: 0.03).notificationBody, plain.notificationBody)
        let slow = finding(net: 1 << 30, now: 4 << 30, window: 7200, bucket: 1800, tier: .slow)
        XCTAssertFalse(slow.explanation.contains("core"), slow.explanation)
        XCTAssertEqual(finding(net: 1 << 30, now: 4 << 30, window: 7200, bucket: 1800, tier: .slow, cpu: 0.8).notificationBody,
                       slow.notificationBody)
    }

    /// A slow finding says what it averaged over the hours, after its existing sentences.
    func testTheSlowExplanationSaysWhatTheProcessAveraged() {
        let plain = finding(net: 1 << 30, now: 4 << 30, window: 7200, bucket: 1800, tier: .slow).explanation
        let text = finding(net: 1 << 30, now: 4 << 30, window: 7200, bucket: 1800, tier: .slow, cpu: 0.8).explanation
        XCTAssertEqual(text, plain + " It averaged about 80% of a core over that time.")
        XCTAssertTrue(finding(net: 1 << 30, now: 4 << 30, window: 7200, bucket: 1800, tier: .slow, cpu: 0.001)
            .explanation.hasSuffix("It averaged under 1% of a core over that time."))
    }

    // MARK: Identity keys

    /// A browser's helper belongs to the browser: the outermost `.app`, the way AppResolver takes it.
    func testAHelperInsideAnAppResolvesToTheOutermostBundle() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/"
            + "Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        let k = IdentityKey.key(forExecutablePath: helper)
        XCTAssertEqual(k.key, "/Applications/Google Chrome.app")
        XCTAssertTrue(k.isApp)
        XCTAssertEqual(IdentityKey.name(forExecutablePath: helper), "Google Chrome")
        let spaced = IdentityKey.key(forExecutablePath: "/Volumes/Data/My Apps/Foo.app/Contents/MacOS/Foo")
        XCTAssertEqual(spaced.key, "/Volumes/Data/My Apps/Foo.app")
    }

    /// A tool that merely lives inside an app's folder is NOT the app. Xcode ships python3, clang and a language server under
    /// Contents/Developer; treating those as "Xcode" made Force Quit App kill everything under that folder.
    func testAToolShippedInsideAnAppIsNotTheApp() {
        let python = "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/bin/python3"
        let k = IdentityKey.key(forExecutablePath: python)
        XCTAssertFalse(k.isApp)
        XCTAssertEqual(k.key, python)
        XCTAssertEqual(IdentityKey.name(forExecutablePath: python), "python3")
        let lsp = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp"
        XCTAssertFalse(IdentityKey.key(forExecutablePath: lsp).isApp)
        XCTAssertFalse(IdentityKey.key(forExecutablePath: "/Applications/Foo.app/Contents/Resources/helper").isApp)
        XCTAssertFalse(IdentityKey.key(forExecutablePath: "/Applications/Foo.app/Contents/Frameworks/tool").isApp)
    }

    /// The app's own processes still are: its main executable, and the executable of a helper bundle nested in it.
    func testAnAppsOwnProcessesStillBelongToIt() {
        XCTAssertTrue(IdentityKey.belongsToApp(path: "/Applications/Xcode.app/Contents/MacOS/Xcode",
                                               bundle: "/Applications/Xcode.app"))
        XCTAssertTrue(IdentityKey.belongsToApp(path: "/Applications/Foo.app/Contents/XPCServices/Bar.xpc/Contents/MacOS/Bar",
                                               bundle: "/Applications/Foo.app"))
        XCTAssertTrue(IdentityKey.belongsToApp(path: "/Applications/Foo.app/Contents/Library/LoginItems/Agent.app/Contents/MacOS/Agent",
                                               bundle: "/Applications/Foo.app"))
        XCTAssertFalse(IdentityKey.belongsToApp(path: "/Applications/Foo.app.backup/Contents/MacOS/Foo",
                                                bundle: "/Applications/Foo.app"))
        XCTAssertFalse(IdentityKey.belongsToApp(path: "/Applications/Other.app/Contents/MacOS/Other",
                                                bundle: "/Applications/Foo.app"))
    }

    /// The ignore list holds identity keys, and a key is not an executable path: the app's bundle path shows as its name.
    func testANameCanBeReadFromAnIdentityKey() {
        XCTAssertEqual(IdentityKey.name(forKey: "/Applications/Safari.app"), "Safari")
        XCTAssertEqual(IdentityKey.name(forKey: "/Applications/Google Chrome.app"), "Google Chrome")
        XCTAssertEqual(IdentityKey.name(forKey: "/usr/local/bin/node"), "node")
        XCTAssertEqual(IdentityKey.name(forKey: ".app"), ".app")
    }

    /// A tool is itself: keyed by its executable path, so every `node` on a Mac is not one thing.
    func testAToolKeepsItsExecutablePath() {
        let k = IdentityKey.key(forExecutablePath: "/usr/local/bin/node")
        XCTAssertEqual(k.key, "/usr/local/bin/node")
        XCTAssertFalse(k.isApp)
        XCTAssertEqual(IdentityKey.name(forExecutablePath: "/usr/local/bin/node"), "node")
        XCTAssertEqual(IdentityKey.key(forExecutablePath: "").key, "")
        XCTAssertFalse(IdentityKey.key(forExecutablePath: "").isApp)
    }
}

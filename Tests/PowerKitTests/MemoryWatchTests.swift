import XCTest
@testable import PowerKit

private func mib(_ x: Double) -> UInt64 { MemoryTestKit.mib(x) }
private func key(_ pid: pid_t, start: UInt64 = 1) -> ProcessKey { ProcessKey(pid: pid, startAbsTime: start) }

/// A pretend machine: processes with a start time, a footprint and a path, and a count of every read made of it.
private final class FakeMachine {
    struct Proc {
        var start: UInt64
        var footprint: UInt64
        var path: String
        /// Total CPU time so far in nanoseconds, a counter that only goes up (unless a test resets it).
        var cpuNanos: UInt64 = 0
    }

    var procs: [pid_t: Proc] = [:]
    var ignored: Set<String> = []
    var pathReads: [pid_t] = []
    var footprintReads = 0
    var discoverCalls = 0

    func add(_ pid: pid_t, _ mibs: Double, path: String, start: UInt64 = 1) {
        procs[pid] = Proc(start: start, footprint: mib(mibs), path: path)
    }
    func setMiB(_ pid: pid_t, _ mibs: Double) { procs[pid]?.footprint = mib(mibs) }

    func pathOf(_ pid: pid_t) -> String {
        pathReads.append(pid)
        return procs[pid]?.path ?? ""
    }
    /// The CPU counter of one process, in nanoseconds.
    func setCPU(_ pid: pid_t, nanos: UInt64) { procs[pid]?.cpuNanos = nanos }
    func footprintOf(_ pid: pid_t) -> (start: UInt64, footprint: UInt64, cpuNanos: UInt64)? {
        footprintReads += 1
        guard let p = procs[pid] else { return nil }
        return (start: p.start, footprint: p.footprint, cpuNanos: p.cpuNanos)
    }
    func discover() -> [(pid: pid_t, start: UInt64, footprint: UInt64, cpuNanos: UInt64)] {
        discoverCalls += 1
        return procs.map { (pid: $0.key, start: $0.value.start, footprint: $0.value.footprint, cpuNanos: $0.value.cpuNanos) }
            .sorted { $0.pid < $1.pid }
    }
}

/// A watch on a pretend machine, with an injected clock. A process's start time is a number of seconds here (the watch is
/// given `startSeconds: { Double($0) }`), and every process starts at 1, so each is long past its third minute.
private final class WatchRig {
    let machine: FakeMachine
    let watch: MemoryWatch
    var findings: [Finding] = []
    var awake: Double = 1000
    /// Extra wall-clock time that has passed with the Mac asleep.
    var wallOffset: Double = 0

    init(rules: GrowthRules = .standard, excluded: Set<String> = [], ownPID: pid_t = 999) {
        let m = FakeMachine()
        machine = m
        watch = MemoryWatch(rules: rules, ownPID: ownPID, excludedPaths: excluded,
                            pathOf: { m.pathOf($0) },
                            isIgnored: { m.ignored.contains($0) },
                            footprintOf: { m.footprintOf($0) },
                            discover: { m.discover() },
                            startSeconds: { Double($0) })
        watch.onFinding = { [unowned self] f in self.findings.append(f) }
    }

    func wall(_ t: Double) -> Date { Date(timeIntervalSinceReferenceDate: t + wallOffset) }

    /// One light tick at the current time.
    func probe() { watch.probe(awake: awake, wall: wall(awake)) }

    /// Light ticks every `step` seconds for `seconds`; `update` sets the machine to its state at each tick's time first.
    func run(for seconds: Double, step: Double = 2, update: (Double) -> Void = { _ in }) {
        let end = awake + seconds
        while awake < end {
            update(awake)
            probe()
            awake += step
        }
    }

    var candidatePIDs: Set<pid_t> { Set(watch.candidateKeys.map { $0.pid }) }
}

private let leakyPath = "/Applications/Leaky.app/Contents/MacOS/Leaky"
private let bigHelperPath = "/Applications/Big.app/Contents/Frameworks/Big Helper.app/Contents/MacOS/Big Helper"

/// The candidate table and the feed that keeps it: who is tracked, who goes, what is read and when, and what happens
/// around a finding. Played on a pretend machine and an injected clock; nothing here reads the real system.
final class MemoryWatchTests: XCTestCase {

    // MARK: Finding a leak end to end

    /// A process leaking 1 MiB a second is admitted at the first discovery, tracked by light ticks alone, and flagged once
    /// a full window exists, with its identity, numbers and graph. A steady process beside it is never flagged.
    func testALeakingAppIsFoundThroughLightTicksAndASteadyOneIsNot() {
        let r = WatchRig()
        r.machine.add(100, 300, path: leakyPath)
        r.machine.add(101, 400, path: "/Applications/Steady.app/Contents/MacOS/Steady")
        r.run(for: 200) { t in r.machine.setMiB(100, 300 + (t - 1000)) }

        XCTAssertEqual(r.findings.count, 1)
        guard let f = r.findings.first else { return }
        XCTAssertEqual(f.pid, 100)
        XCTAssertEqual(f.name, "Leaky")
        XCTAssertEqual(f.identityKey, "/Applications/Leaky.app")
        XCTAssertTrue(f.isApp)
        XCTAssertTrue(f.shouldNotify)
        XCTAssertEqual(f.startBytes, mib(300))
        XCTAssertEqual(f.netGrowthBytes, mib(64))
        XCTAssertEqual(f.windowSeconds, 64, accuracy: 0.001)
        XCTAssertEqual(f.flaggedAtAwake, 1064, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(f.history.count, 30, "the graph is copied into the finding")
        XCTAssertEqual(f.history.last?.bytes, mib(364))
        XCTAssertEqual(f.history.first?.seconds ?? 0, 1000, accuracy: 0.001)
    }

    /// Once per process: the finding does not come again however long the leak goes on.
    func testAProcessIsReportedOnceForItsLifetime() {
        let r = WatchRig()
        r.machine.add(100, 300, path: leakyPath)
        r.run(for: 900) { t in r.machine.setMiB(100, 300 + (t - 1000)) }
        XCTAssertEqual(r.findings.count, 1)
        XCTAssertEqual(r.watch.phase(of: key(100)), .reported)
    }

    /// Several helpers of one app leaking together are one story: every finding is delivered, but only the first earns a
    /// notification. Ten minutes later another helper of the same app earns one again. Failing here means one leaking
    /// browser buzzes the Mac once per helper.
    func testAnAppNotifiesOncePerTenMinutesHoweverManyHelpersLeak() {
        let r = WatchRig()
        r.machine.add(100, 300, path: bigHelperPath)
        r.machine.add(102, 300, path: bigHelperPath)
        r.machine.add(103, 200, path: bigHelperPath)             // flat for now, leaks later
        r.run(for: 900) { t in
            r.machine.setMiB(100, 300 + (t - 1000))
            r.machine.setMiB(102, 300 + (t - 1000))
            r.machine.setMiB(103, 200 + max(0, t - 1700))
        }
        XCTAssertEqual(r.findings.count, 3, "every flagged process is delivered")
        let early = r.findings.filter { $0.pid != 103 }
        XCTAssertEqual(early.count, 2)
        XCTAssertEqual(early.filter { $0.shouldNotify }.count, 1, "one notification for the two helpers flagged together")
        XCTAssertTrue(early.allSatisfy { $0.identityKey == "/Applications/Big.app" })
        guard let late = r.findings.first(where: { $0.pid == 103 }), let first = early.first else {
            return XCTFail("the late helper was not flagged")
        }
        XCTAssertGreaterThan(late.flaggedAtAwake - first.flaggedAtAwake, 600)
        XCTAssertTrue(late.shouldNotify, "more than ten minutes after the last notification for the app")
    }

    /// A tool is not an app: two `node` processes leaking at once are two findings, and each earns its own notification.
    func testEveryFlaggedToolProcessNotifiesOnItsOwn() {
        let r = WatchRig()
        r.machine.add(110, 300, path: "/usr/local/bin/node")
        r.machine.add(111, 300, path: "/usr/local/bin/node")
        r.run(for: 120) { t in
            r.machine.setMiB(110, 300 + (t - 1000))
            r.machine.setMiB(111, 300 + (t - 1000))
        }
        XCTAssertEqual(r.findings.count, 2)
        XCTAssertTrue(r.findings.allSatisfy { !$0.isApp && $0.shouldNotify })
        XCTAssertTrue(r.findings.allSatisfy { $0.identityKey == "/usr/local/bin/node" && $0.name == "node" })
    }

    /// A finding keeps its process in the table for ten minutes, so the window that opens on it can still be fed, and
    /// lets go after that.
    func testAFindingHoldsItsProcessForTenMinutes() {
        let r = WatchRig()
        r.machine.add(100, 300, path: leakyPath)
        r.run(for: 100) { t in r.machine.setMiB(100, 300 + (t - 1000)) }
        XCTAssertEqual(r.findings.count, 1)
        XCTAssertTrue(r.watch.isHeld(key(100)))
        r.run(for: 650) { t in r.machine.setMiB(100, 300 + (t - 1000)) }
        XCTAssertFalse(r.watch.isHeld(key(100)))
        XCTAssertTrue(r.watch.isCandidate(key(100)), "still tracked, just no longer held")
    }

    /// The finding's graph is a copy: it survives the process exiting and the table forgetting it.
    func testAFindingsHistorySurvivesTheProcessExiting() {
        let r = WatchRig()
        r.machine.add(100, 300, path: leakyPath)
        r.run(for: 100) { t in r.machine.setMiB(100, 300 + (t - 1000)) }
        let kept = r.findings.first?.history.count ?? 0
        XCTAssertGreaterThan(kept, 0)
        r.machine.procs[100] = nil
        r.run(for: 10)
        XCTAssertFalse(r.watch.isCandidate(key(100)))
        XCTAssertTrue(r.watch.samples(of: key(100)).isEmpty)
        XCTAssertEqual(r.findings.first?.history.count, kept)
    }

    // MARK: Sleep and pid reuse

    /// A sleep (nine hours of wall clock, ten seconds awake) resets every window and holds a two-minute quiet period; a
    /// leak that goes on is flagged one full window after the quiet ends, not before. Failing here means a night's sleep
    /// reads as a burst of growth or as no growth.
    func testASleepResetsTheWindowsAndHoldsAQuietPeriod() {
        let r = WatchRig()
        r.machine.add(100, 300, path: leakyPath)
        r.run(for: 30) { t in r.machine.setMiB(100, 300 + (t - 1000)) }
        XCTAssertTrue(r.findings.isEmpty)
        r.awake += 10
        r.wallOffset += 9 * 3600
        let gapAt = r.awake
        r.run(for: 4) { t in r.machine.setMiB(100, 300 + (t - 1000)) }
        XCTAssertEqual(r.watch.phase(of: key(100)), .quiet)
        r.run(for: 150) { t in r.machine.setMiB(100, 300 + (t - 1000)) }
        XCTAssertTrue(r.findings.isEmpty, "nothing during the quiet period or the window that follows it")
        r.run(for: 250) { t in r.machine.setMiB(100, 300 + (t - 1000)) }
        XCTAssertEqual(r.findings.count, 1)
        let at = r.findings.first?.flaggedAtAwake ?? 0
        XCTAssertGreaterThanOrEqual(at, gapAt + 120 + 60)
        XCTAssertLessThanOrEqual(at, gapAt + 120 + 64 + 16)
    }

    /// A pid that now belongs to a different process (its start time differs) is a different process: the old candidate
    /// goes at the next read and the new one starts with a fresh tracker and an empty graph. Failing here means a new
    /// process inherits an old one's history.
    func testAReusedPidGetsAFreshTracker() {
        let r = WatchRig()
        r.machine.add(100, 300, path: leakyPath, start: 1)
        r.run(for: 30) { t in r.machine.setMiB(100, 300 + (t - 1000)) }
        XCTAssertTrue(r.watch.isCandidate(key(100, start: 1)))
        r.machine.add(100, 400, path: leakyPath, start: 5)
        r.run(for: 2)
        XCTAssertFalse(r.watch.isCandidate(key(100, start: 1)), "the old process is gone")
        r.run(for: 70)
        XCTAssertTrue(r.watch.isCandidate(key(100, start: 5)), "the new one is found at the next discovery")
        XCTAssertEqual(r.watch.samples(of: key(100, start: 5)).first?.bytes, mib(400), "its graph starts at admission")
        XCTAssertEqual(r.watch.phase(of: key(100, start: 5)), .learning)
        XCTAssertTrue(r.findings.isEmpty)
    }

    // MARK: Admission and eviction

    private func orderRig(maxCandidates: Int = 3) -> WatchRig {
        var rules = GrowthRules.standard
        rules.maxCandidates = maxCandidates
        let r = WatchRig(rules: rules)
        r.machine.add(10, 900, path: "/Applications/L1.app/Contents/MacOS/L1")
        r.machine.add(11, 500, path: "/Applications/L2.app/Contents/MacOS/L2")
        r.machine.add(12, 200, path: "/Applications/L3.app/Contents/MacOS/L3")
        r.machine.add(13, 100, path: "/Applications/A1.app/Contents/MacOS/A1")
        r.machine.add(14, 100, path: "/Applications/A2.app/Contents/MacOS/A2")
        r.machine.add(15, 50, path: "/Applications/T.app/Contents/MacOS/T")
        return r
    }

    private func growTheAscenders(_ r: WatchRig, _ t: Double) {
        if t >= 1060 {
            r.machine.setMiB(13, 200)          // +100 MiB since the first pass
            r.machine.setMiB(14, 140)          // +40 MiB
        }
    }

    /// Ascenders (processes that gained 24 MiB or more since the last pass) come before the largest processes: with room
    /// for three, the second pass swaps the two smaller large processes for the two ascenders, and keeps the largest.
    func testAscendersAreAdmittedBeforeTheLargestProcesses() {
        let r = orderRig()
        r.run(for: 4) { _ in }
        XCTAssertEqual(r.candidatePIDs, [10, 11, 12], "the first pass has no ascenders: the largest three")
        r.run(for: 60) { self.growTheAscenders(r, $0) }
        XCTAssertEqual(r.candidatePIDs, [10, 13, 14])
    }

    /// A pinned candidate (a diagnostic window is open on it) is never pushed out, even by an ascender and even when it is
    /// the least wanted. Failing here means the window shows a process the watch has stopped reading.
    func testAPinnedCandidateIsNeverEvictedByAnAscender() {
        let r = orderRig()
        r.run(for: 4) { _ in }
        r.watch.pin(key(11))
        r.watch.pin(key(12))
        r.run(for: 60) { self.growTheAscenders(r, $0) }
        XCTAssertEqual(r.candidatePIDs, [11, 12, 13], "the unpinned largest goes; the second ascender finds no room")
    }

    /// A process that falls below the largest and then stays flat for five minutes is dropped; pinned, it stays.
    func testAFlatCandidateThatIsNoLongerLargeIsEvictedUnlessPinned() {
        func scenario(pinned: Bool) -> WatchRig {
            let r = WatchRig()
            r.machine.add(20, 160, path: "/Applications/F.app/Contents/MacOS/F")
            r.machine.add(21, 600, path: "/Applications/G.app/Contents/MacOS/G")
            r.run(for: 4) { _ in }
            if pinned { r.watch.pin(key(20)) }
            r.run(for: 396) { t in if t >= 1100 { r.machine.setMiB(20, 120) } }       // now at 1400
            XCTAssertTrue(r.watch.isCandidate(key(20)), "flat for under five minutes")
            r.run(for: 40) { _ in }
            return r
        }
        let free = scenario(pinned: false)
        XCTAssertFalse(free.watch.isCandidate(key(20)), "flat for five minutes and not large")
        XCTAssertTrue(free.watch.isCandidate(key(21)), "a large process stays however flat")
        XCTAssertTrue(scenario(pinned: true).watch.isCandidate(key(20)))
    }

    /// A process that exits leaves the table at the next read, pinned or not.
    func testAnExitedProcessLeavesTheTable() {
        let r = WatchRig()
        r.machine.add(30, 400, path: "/Applications/Gone.app/Contents/MacOS/Gone")
        r.run(for: 6)
        r.watch.pin(key(30))
        XCTAssertTrue(r.watch.isCandidate(key(30)))
        r.machine.procs[30] = nil
        r.run(for: 2)
        XCTAssertFalse(r.watch.isCandidate(key(30)))
        XCTAssertEqual(r.watch.candidateCount, 0)
    }

    /// Anode itself, its worker copies and ignored apps never take a slot, and the path of each is read once however many
    /// discovery passes see it.
    func testIgnoredAndExcludedProcessesNeverTakeASlotAndTheirPathIsReadOnce() {
        let anode = "/Applications/Anode.app/Contents/MacOS/Anode"
        let r = WatchRig(excluded: [anode], ownPID: 999)
        r.machine.ignored = ["/Applications/Noisy.app"]
        r.machine.add(30, 800, path: "/Applications/Noisy.app/Contents/MacOS/Noisy")
        r.machine.add(998, 500, path: anode)
        r.machine.add(999, 700, path: anode)
        r.machine.add(31, 400, path: "/Applications/Normal.app/Contents/MacOS/Normal")
        r.run(for: 250)                                            // five discovery passes
        XCTAssertEqual(r.candidatePIDs, [31])
        let reads = r.machine.pathReads
        XCTAssertEqual(reads.filter { $0 == 30 }.count, 1, "the ignored app's path is read once")
        XCTAssertEqual(reads.filter { $0 == 998 }.count, 1, "the excluded copy's path is read once")
        XCTAssertEqual(reads.filter { $0 == 31 }.count, 1, "an admitted process's path is read once")
        XCTAssertFalse(reads.contains(999), "Anode's own pid is skipped before any path is read")
    }

    /// Ignoring an app (the person pressed "don't warn about this app") removes its candidates now, even a pinned one, and
    /// none is admitted again.
    func testIgnoringAnAppRemovesItNowAndKeepsItOut() {
        let r = WatchRig()
        r.machine.add(31, 400, path: "/Applications/Normal.app/Contents/MacOS/Normal")
        r.run(for: 6)
        r.watch.pin(key(31))
        r.watch.ignore(identityKey: "/Applications/Normal.app")
        XCTAssertEqual(r.watch.candidateCount, 0)
        r.run(for: 200)
        XCTAssertEqual(r.watch.candidateCount, 0)
    }

    /// Ten thousand processes, random sizes, some growing at every pass: the table never passes its cap, the rings never
    /// pass theirs, and the caches stay the size of the machine. Failing here means a busy Mac grows Anode.
    func testTheTableNeverExceedsItsCapAgainstTenThousandRandomProcesses() {
        let r = WatchRig()
        var rand = MemoryTestKit.Random(seed: 77)
        for i in 0..<10_000 {
            r.machine.add(pid_t(1000 + i), Double(rand.int(below: 2048)),
                          path: "/Applications/App\(i % 400).app/Contents/MacOS/App")
        }
        var worstTable = 0, worstRings = 0
        for _ in 0..<300 {
            for _ in 0..<20 {
                let pid = pid_t(1000 + rand.int(below: 10_000))
                r.machine.procs[pid]?.footprint += mib(30)
            }
            r.probe()
            r.awake += 2
            worstTable = max(worstTable, r.watch.candidateCount)
            worstRings = max(worstRings, r.watch.ringCount)
        }
        XCTAssertLessThanOrEqual(worstTable, 32)
        XCTAssertGreaterThan(worstTable, 0)
        XCTAssertLessThanOrEqual(worstRings, 32 * MemoryWatch.ringCapacity)
        XCTAssertLessThanOrEqual(r.watch.previousDiscoveryCount, 10_000)
        XCTAssertLessThanOrEqual(r.watch.identityCacheCount, 10_000)
    }

    /// The fast ring keeps the newest 192 points, oldest first, and no more. `samples(of:)` hands over the whole timeline:
    /// the slow ring's older points (once per 300 s) in front of those 192, oldest first and each point once. Failing here
    /// means the graph shows a gap, a point twice or points out of order where the two rings meet.
    func testTheGraphRingKeepsTheNewestPointsOldestFirst() {
        let r = WatchRig()
        r.machine.add(40, 400, path: "/Applications/Flat.app/Contents/MacOS/Flat")
        r.run(for: 1000)
        let s = r.watch.samples(of: key(40))
        XCTAssertGreaterThan(s.count, MemoryWatch.ringCapacity, "the slow ring's older points come first")
        XCTAssertEqual(s.count, MemoryWatch.ringCapacity + 3, "slow points at 1000, 1300 and 1600 are older than the fast ring")
        XCTAssertTrue(zip(s, s.dropFirst()).allSatisfy { $0.seconds < $1.seconds })
        XCTAssertEqual(s.first?.seconds ?? 0, 1000, accuracy: 0.001)
        XCTAssertEqual(s.last?.seconds ?? 0, 1998, accuracy: 0.001)
        XCTAssertEqual(s.last?.bytes, mib(400))
        XCTAssertEqual(r.watch.ringCount, MemoryWatch.ringCapacity, "the fast ring alone is still 192")
    }

    // MARK: Feeding from sweeps

    private func sweep(at s: Double, _ mibs: Double, pid: pid_t = 40, path: String = "/Applications/Sw.app/Contents/MacOS/Sw") -> ProcessSampler.Sweep {
        makeSweep(at: s, [makeProcess(pid: pid, start: 1, nJ: 0, path: path, footprint: mib(mibs))])
    }

    /// A full sweep feeds the candidates with no read of its own, and a sweep that is not newer than the last one is
    /// ignored: a light tick that finds the monitor's latest sweep unchanged cannot feed it twice. A sweep carries the path
    /// already, so admitting from one reads none.
    func testAStaleSweepIsIgnoredAndASweepCarriesItsOwnPath() {
        let r = WatchRig()
        r.machine.add(40, 400, path: "/Applications/Sw.app/Contents/MacOS/Sw")
        r.watch.ingest(sweep: sweep(at: 1000, 400), awake: 1000)
        XCTAssertEqual(r.watch.candidateCount, 1)
        XCTAssertEqual(r.watch.ringCount, 1)
        XCTAssertTrue(r.machine.pathReads.isEmpty, "the sweep already held the path")
        r.watch.ingest(sweep: sweep(at: 1000, 500), awake: 1000)
        r.watch.ingest(sweep: sweep(at: 990, 600), awake: 1001)
        XCTAssertEqual(r.watch.ringCount, 1, "neither the same sweep nor an older one is fed")
        XCTAssertEqual(r.watch.samples(of: key(40)).last?.bytes, mib(400))
        r.watch.ingest(sweep: sweep(at: 1002, 500), awake: 1002)
        XCTAssertEqual(r.watch.ringCount, 2)
        XCTAssertEqual(r.watch.samples(of: key(40)).last?.bytes, mib(500))
        XCTAssertEqual(r.machine.footprintReads, 0, "a sweep costs no read of its own")
    }

    /// With a full sweep just ingested, light ticks run no discovery pass of their own until sixty seconds have passed: no
    /// double sweep.
    func testDiscoveryIsSkippedRightAfterAFullSweep() {
        let r = WatchRig()
        r.machine.add(40, 400, path: "/Applications/Sw.app/Contents/MacOS/Sw")
        r.watch.ingest(sweep: sweep(at: 1000, 400), awake: 1000)
        r.awake = 1002
        r.run(for: 58)                                   // light ticks 1002 ... 1058
        XCTAssertEqual(r.machine.discoverCalls, 0)
        XCTAssertEqual(r.machine.footprintReads, 29, "one read per candidate per light tick")
        r.run(for: 2)                                    // the tick at 1060
        XCTAssertEqual(r.machine.discoverCalls, 1)
    }

    /// A full sweep runs a discovery pass at most every thirty seconds.
    func testASweepRunsDiscoveryAtMostEveryThirtySeconds() {
        let r = WatchRig()
        r.watch.ingest(sweep: sweep(at: 1000, 400, pid: 40), awake: 1000)
        XCTAssertEqual(r.watch.candidateCount, 1)
        // A new large process appears; the next sweeps see it only when a pass is due.
        let two = makeSweep(at: 1010, [makeProcess(pid: 40, start: 1, nJ: 0, path: "/Applications/Sw.app/Contents/MacOS/Sw", footprint: mib(400)),
                                       makeProcess(pid: 41, start: 1, nJ: 0, path: "/Applications/Two.app/Contents/MacOS/Two", footprint: mib(300))])
        r.watch.ingest(sweep: two, awake: 1010)
        XCTAssertEqual(r.watch.candidateCount, 1, "10 s after the last pass: none due")
        let later = makeSweep(at: 1031, [makeProcess(pid: 40, start: 1, nJ: 0, path: "/Applications/Sw.app/Contents/MacOS/Sw", footprint: mib(400)),
                                         makeProcess(pid: 41, start: 1, nJ: 0, path: "/Applications/Two.app/Contents/MacOS/Two", footprint: mib(300))])
        r.watch.ingest(sweep: later, awake: 1031)
        XCTAssertEqual(r.watch.candidateCount, 2)
    }

    // MARK: Live feed

    /// With no key in the live set nothing is called; with one, its newest point is handed over after every feed; emptied
    /// again, nothing more. Failing here means a closed window still costs a hop to the main thread on every tick.
    func testTheLiveFeedPostsNothingWhenTheSetIsEmpty() {
        let r = WatchRig()
        r.machine.add(40, 400, path: "/Applications/Flat.app/Contents/MacOS/Flat")
        var posts: [(ProcessKey, MemorySample)] = []
        r.watch.onLivePoint = { k, s in posts.append((k, s)) }
        r.run(for: 10)
        XCTAssertTrue(posts.isEmpty)
        r.watch.setLive([key(40)])
        r.run(for: 10)
        XCTAssertEqual(posts.count, 5)
        XCTAssertTrue(posts.allSatisfy { $0.0 == key(40) && $0.1.bytes == mib(400) })
        XCTAssertEqual(posts.first?.1.seconds ?? 0, 1010, accuracy: 0.001)
        r.watch.setLive([])
        r.run(for: 10)
        XCTAssertEqual(posts.count, 5)
    }

    // MARK: Reset

    func testResetForgetsEverything() {
        let r = WatchRig()
        r.machine.add(100, 300, path: leakyPath)
        r.run(for: 100) { t in r.machine.setMiB(100, 300 + (t - 1000)) }
        r.watch.pin(key(100))
        r.watch.reset()
        XCTAssertEqual(r.watch.candidateCount, 0)
        XCTAssertEqual(r.watch.ringCount, 0)
        XCTAssertEqual(r.watch.previousDiscoveryCount, 0)
        XCTAssertEqual(r.watch.identityCacheCount, 0)
        XCTAssertEqual(r.watch.reportedCount, 0)
        XCTAssertFalse(r.watch.isHeld(key(100)))
    }

    // MARK: Soak

    /// A day of 2 s ticks on a machine of 800 processes that start, exit, grow and jitter all the time, with a full sweep
    /// every five minutes. The table, the rings, the discovery map and the caches stay within their bounds the whole way,
    /// and when every process is gone everything returns to empty. Failing here means Anode's memory grows with uptime.
    func testA24HourSoakStaysBoundedAndReturnsToEmpty() {
        let r = WatchRig()
        var rand = MemoryTestKit.Random(seed: 20_261_119)
        let first: pid_t = 5000
        let slots = 800
        for s in 0..<slots {
            r.machine.add(first + pid_t(s), Double(20 + rand.int(below: 1480)),
                          path: "/Applications/App\(s % 60).app/Contents/MacOS/App")
        }
        var worstTable = 0, worstRings = 0, worstPrevious = 0, worstIdentities = 0, worstReported = 0
        let steps = 24 * 3600 / 2
        for step in 0..<steps {
            // Churn: a process exits and another takes its pid (the first five slots leak steadily and stay).
            for _ in 0..<2 {
                let s = 5 + rand.int(below: slots - 5)
                r.machine.procs[first + pid_t(s)] = FakeMachine.Proc(
                    start: UInt64(step + 2), footprint: mib(Double(20 + rand.int(below: 1480))),
                    path: "/Applications/App\(s % 60).app/Contents/MacOS/App")
            }
            for _ in 0..<3 {
                let s = rand.int(below: slots)
                r.machine.procs[first + pid_t(s)]?.footprint += mib(Double(rand.int(below: 40)))
            }
            for _ in 0..<3 {
                let s = rand.int(below: slots)
                if let p = r.machine.procs[first + pid_t(s)], p.footprint > mib(10) {
                    r.machine.procs[first + pid_t(s)]?.footprint -= mib(Double(rand.int(below: 5)))
                }
            }
            for s in 0..<5 { r.machine.procs[first + pid_t(s)]?.footprint += mib(2) }

            if step % 150 == 0 {
                let procs = r.machine.procs.map { entry in
                    makeProcess(pid: entry.key, start: entry.value.start, nJ: 0, name: "p",
                                path: entry.value.path, footprint: entry.value.footprint)
                }
                r.watch.ingest(sweep: makeSweep(at: r.awake, procs), awake: r.awake)
            } else {
                r.probe()
            }
            r.awake += 2
            worstTable = max(worstTable, r.watch.candidateCount)
            worstRings = max(worstRings, r.watch.ringCount)
            worstPrevious = max(worstPrevious, r.watch.previousDiscoveryCount)
            worstIdentities = max(worstIdentities, r.watch.identityCacheCount)
            worstReported = max(worstReported, r.watch.reportedCount)
        }
        XCTAssertLessThanOrEqual(worstTable, 32)
        XCTAssertLessThanOrEqual(worstRings, 32 * MemoryWatch.ringCapacity)
        XCTAssertLessThanOrEqual(worstPrevious, slots)
        XCTAssertLessThanOrEqual(worstIdentities, slots)
        XCTAssertLessThanOrEqual(worstReported, slots)

        r.machine.procs.removeAll()
        r.run(for: 130)
        XCTAssertEqual(r.watch.candidateCount, 0)
        XCTAssertEqual(r.watch.ringCount, 0)
        XCTAssertEqual(r.watch.previousDiscoveryCount, 0)
        XCTAssertEqual(r.watch.identityCacheCount, 0)
        XCTAssertEqual(r.watch.reportedCount, 0)
    }

    // MARK: The slow tier

    private let slowLeakStart = 1000.0

    /// A process leaking 9 MiB a minute (0.15 MiB a second) on a 3 GiB base, read by light ticks every `step` seconds.
    private func runSlowLeak(step: Double, hours: Double = 3) -> WatchRig {
        let r = WatchRig()
        r.machine.add(100, 3072, path: leakyPath)
        r.run(for: hours * 3600, step: step) { t in r.machine.setMiB(100, 3072 + 0.15 * (t - 1000)) }
        return r
    }

    /// A leak of 9 MiB a minute (90 GB over a week) is far under the fast tier's 50 MiB a minute: the fast tier never fires
    /// and the slow tier fires exactly once, a little over two hours in, with a window of about two hours. Played at the 8 s
    /// cadence the app uses with its window closed. Failing here means a slow leak in a browser goes unseen.
    func testASlowLeakOfNineMiBAMinuteIsFoundOnceByTheSlowTierAtTheHiddenCadence() {
        let r = runSlowLeak(step: 8)
        XCTAssertEqual(r.findings.count, 1, "exactly one finding in three hours")
        guard let f = r.findings.first else { return }
        XCTAssertEqual(f.tier, .slow)
        let hours = (f.flaggedAtAwake - slowLeakStart) / 3600
        XCTAssertGreaterThanOrEqual(hours, 2.0)
        XCTAssertLessThanOrEqual(hours, 2.7)
        XCTAssertEqual(f.windowSeconds, 7200, accuracy: 400)
        XCTAssertEqual(f.startBytes, mib(3072))
        XCTAssertGreaterThanOrEqual(f.netGrowthBytes, mib(768))
        XCTAssertEqual(f.growthBytesPerSecond, Double(mib(0.15)), accuracy: Double(mib(0.02)))
        XCTAssertEqual(f.name, "Leaky")
        XCTAssertTrue(f.shouldNotify)
        XCTAssertEqual(r.watch.phase(of: key(100)), .reported, "a slow finding stops the fast tracker too")
        XCTAssertEqual(r.watch.slowPhase(of: key(100)), .reported)
    }

    /// The same leak at the 2 s cadence (window open) gives the same verdict: one slow finding, about two hours. Failing
    /// here means the answer depends on how often Anode happens to sample.
    func testTheSameSlowLeakGivesTheSameVerdictAtTwoSeconds() {
        let slow = runSlowLeak(step: 2)
        let hidden = runSlowLeak(step: 8)
        XCTAssertEqual(slow.findings.count, 1)
        XCTAssertEqual(hidden.findings.count, 1)
        guard let a = slow.findings.first, let b = hidden.findings.first else { return }
        XCTAssertEqual(a.tier, .slow)
        XCTAssertEqual(b.tier, .slow)
        XCTAssertEqual(a.windowSeconds, 7200, accuracy: 0.001, "feeds land exactly on the 300 s grid at 2 s")
        XCTAssertEqual(a.windowSeconds, b.windowSeconds, accuracy: 120)
        XCTAssertEqual(a.startBytes, b.startBytes)
        XCTAssertEqual(a.flaggedAtAwake, b.flaggedAtAwake, accuracy: 120)
    }

    /// A slow finding's graph is the slow ring: time ordered, one point per feed, the whole two-hour climb and not just the
    /// last minutes, ending at the footprint it was flagged at.
    func testASlowFindingsHistoryIsTheSlowRingInTimeOrder() {
        let r = runSlowLeak(step: 8)
        guard let f = r.findings.first else { return XCTFail("no finding") }
        XCTAssertGreaterThanOrEqual(f.history.count, 20)
        XCTAssertLessThanOrEqual(f.history.count, 48)
        XCTAssertTrue(zip(f.history, f.history.dropFirst()).allSatisfy { $0.seconds < $1.seconds })
        XCTAssertEqual(f.history.first?.seconds ?? 0, 1000, accuracy: 0.001, "the first slow point is the admission")
        XCTAssertGreaterThanOrEqual((f.history.last?.seconds ?? 0) - (f.history.first?.seconds ?? 0), 7200,
                                    "the fast ring would hold about 25 minutes; this holds the whole climb")
        XCTAssertEqual(Double(f.history.last?.bytes ?? 0), Double(f.nowBytes), accuracy: 1024)
        XCTAssertEqual(f.history.last?.seconds ?? 0, f.flaggedAtAwake, accuracy: 0.001)
    }

    /// 3 MiB a minute is 360 MiB in two hours, under the slow tier's 768 MiB: never flagged by either tier over eight hours.
    func testALeakBelowTheSlowThresholdIsNeverFlagged() {
        let r = WatchRig()
        r.machine.add(100, 3072, path: leakyPath)
        r.run(for: 8 * 3600, step: 8) { t in r.machine.setMiB(100, 3072 + 0.05 * (t - 1000)) }
        XCTAssertTrue(r.findings.isEmpty)
        XCTAssertNotEqual(r.watch.slowPhase(of: key(100)), .reported)
    }

    /// One 2 GiB allocation and then nothing is a step, not a trend: the buckets after it are flat and the step is all of the
    /// growth. Failing here means opening a big document looks like a leak after two hours.
    func testASingleTwoGiBJumpThenFlatIsNeverFlagged() {
        let r = WatchRig()
        r.machine.add(100, 3072, path: leakyPath)
        r.run(for: 8 * 3600, step: 8) { t in r.machine.setMiB(100, t < 1000 + 3600 ? 3072 : 5120) }
        XCTAssertTrue(r.findings.isEmpty)
    }

    /// A plateau with +/-100 MiB of noise on every reading, for eight hours: the noise cannot reach 768 MiB of net growth
    /// and every dip beyond tolerance re-anchors the window. Failing here means a big, busy process notifies for nothing.
    func testAPlateauWithOneHundredMiBOfNoiseIsNeverFlagged() {
        let r = WatchRig()
        var rand = MemoryTestKit.Random(seed: 9)
        r.machine.add(100, 3072, path: leakyPath)
        r.run(for: 8 * 3600, step: 8) { _ in r.machine.setMiB(100, 3072 + rand.signed(100)) }
        XCTAssertTrue(r.findings.isEmpty)
    }

    /// Grow 1 GiB over an hour, drop 900 MiB, again and again: every drop re-anchors the window before it can be two hours
    /// long, whatever the drift across the day. Failing here means a heap that is cleaned up hourly notifies.
    func testASawtoothThatGrowsAGiBAnHourAndDropsNineHundredMiBIsNeverFlagged() {
        let r = WatchRig()
        r.machine.add(100, 3072, path: leakyPath)
        r.run(for: 8 * 3600, step: 8) { t in
            let elapsed = t - 1000
            let cycle = (elapsed / 3600).rounded(.down)
            let within = elapsed - cycle * 3600
            r.machine.setMiB(100, 3072 + 124 * cycle + 1024 * within / 3600)
        }
        XCTAssertTrue(r.findings.isEmpty)
    }

    /// A sleep in the middle of a slow climb (nine hours of wall clock, ten seconds awake) resets the fast tracker and holds
    /// its quiet period, and does NOT touch the slow tracker, its ring or its schedule: awake time did not advance, so the
    /// leak is still found on the same awake schedule. Failing here means every night's sleep throws away hours of evidence.
    func testASleepInTheMiddleOfASlowClimbDoesNotResetTheSlowTracker() {
        let r = WatchRig()
        r.machine.add(100, 3072, path: leakyPath)
        let level: (Double) -> Void = { t in r.machine.setMiB(100, 3072 + 0.15 * (t - 1000)) }
        r.run(for: 3600, step: 8, update: level)
        XCTAssertTrue(r.findings.isEmpty, "an hour is not yet a two-hour window")
        let samplesBefore = r.watch.slowSampleCount(of: key(100))
        let feedsBefore = r.watch.slowFeeds(of: key(100))
        XCTAssertGreaterThanOrEqual(feedsBefore, 11)

        r.awake += 10
        r.wallOffset += 9 * 3600
        r.run(for: 8, step: 8, update: level)
        XCTAssertEqual(r.watch.phase(of: key(100)), .quiet, "the fast tracker starts again")
        XCTAssertNotEqual(r.watch.slowPhase(of: key(100)), .quiet, "the slow tracker does not")
        XCTAssertNotNil(r.watch.slowPhase(of: key(100)))
        XCTAssertGreaterThanOrEqual(r.watch.slowSampleCount(of: key(100)), samplesBefore, "its ring is kept")
        XCTAssertGreaterThanOrEqual(r.watch.slowFeeds(of: key(100)), feedsBefore)

        r.run(for: 2.5 * 3600, step: 8, update: level)
        XCTAssertEqual(r.findings.count, 1)
        guard let f = r.findings.first else { return }
        XCTAssertEqual(f.tier, .slow)
        let awakeSinceStart = f.flaggedAtAwake - 1000
        XCTAssertGreaterThanOrEqual(awakeSinceStart, 7200)
        XCTAssertLessThanOrEqual(awakeSinceStart, 2.7 * 3600 + 10,
                                 "found on the awake schedule: a reset at the sleep would push it past three hours")
    }

    /// A fast leak (1 MiB a second) is reported by the fast tier, and the slow tier never reports the same process: three
    /// hours later there is still the one fast finding. Failing here means one leak notifies twice.
    func testAFastLeakReportedByTheFastTierGivesNoSecondSlowFinding() {
        let r = WatchRig()
        r.machine.add(100, 300, path: leakyPath)
        r.run(for: 3 * 3600, step: 8) { t in r.machine.setMiB(100, 300 + (t - 1000)) }
        XCTAssertEqual(r.findings.count, 1)
        XCTAssertEqual(r.findings.first?.tier, .fast)
        XCTAssertEqual(r.watch.slowPhase(of: key(100)), .reported, "marked when the fast tier reported")
    }

    /// A pid that now belongs to a different process starts a new entry with a fresh slow tracker, an empty slow ring and
    /// its own feed count: it inherits nothing of an hour of slow climbing by the old one.
    func testAReusedPidGetsAFreshSlowTracker() {
        let r = WatchRig()
        r.machine.add(100, 3072, path: leakyPath, start: 1)
        r.run(for: 3600, step: 8) { t in r.machine.setMiB(100, 3072 + 0.15 * (t - 1000)) }
        XCTAssertGreaterThanOrEqual(r.watch.slowFeeds(of: key(100, start: 1)), 11)
        XCTAssertGreaterThanOrEqual(r.watch.slowSampleCount(of: key(100, start: 1)), 11)
        r.machine.add(100, 3072, path: leakyPath, start: 5)
        r.run(for: 70, step: 8) { _ in }
        XCTAssertFalse(r.watch.isCandidate(key(100, start: 1)))
        XCTAssertTrue(r.watch.isCandidate(key(100, start: 5)), "found at the next discovery")
        XCTAssertEqual(r.watch.slowFeeds(of: key(100, start: 5)), 1, "fed once, at admission")
        XCTAssertEqual(r.watch.slowSampleCount(of: key(100, start: 5)), 1)
        XCTAssertEqual(r.watch.slowPhase(of: key(100, start: 5)), .learning)
        XCTAssertTrue(r.findings.isEmpty)
    }

    /// The slow tracker is fed once per 300 s, however often the watch ticks: over a simulated hour about 12 feeds at 2 s
    /// (1800 ticks) and at 8 s (450 ticks) alike. Failing here means the slow tier costs work on every tick.
    func testTheSlowTrackerIsFedAtMostOncePerThreeHundredSecondsAtEveryCadence() {
        for step in [2.0, 8.0] {
            let r = WatchRig()
            r.machine.add(40, 400, path: "/Applications/Flat.app/Contents/MacOS/Flat")
            r.run(for: 3600, step: step)
            let feeds = r.watch.slowFeeds(of: key(40))
            XCTAssertTrue((11...13).contains(feeds), "\(feeds) feeds in an hour at \(step) s")
            XCTAssertEqual(r.watch.slowFeedCount, feeds, "the total is the one candidate's")
            XCTAssertEqual(r.watch.slowSampleCount(of: key(40)), feeds)
        }
    }

    /// The slow ring never holds more than 48 points however long the process lives, the whole table's slow rings never
    /// pass 32 x 48, and an entry that leaves the table takes its slow ring with it.
    func testTheSlowRingNeverExceedsFortyEightPointsAndIsFreedWithItsEntry() {
        let r = WatchRig()
        r.machine.add(40, 400, path: "/Applications/Flat.app/Contents/MacOS/Flat")
        var worst = 0
        let end = r.awake + 6 * 3600
        while r.awake < end {
            r.probe()
            r.awake += 8
            worst = max(worst, r.watch.slowSampleCount(of: key(40)))
        }
        XCTAssertEqual(worst, 48)
        XCTAssertEqual(r.watch.slowSampleCount(of: key(40)), 48)
        XCTAssertEqual(r.watch.slowRingCount, 48)
        r.machine.procs[40] = nil
        r.run(for: 8, step: 8)
        XCTAssertEqual(r.watch.candidateCount, 0)
        XCTAssertEqual(r.watch.slowRingCount, 0)
        XCTAssertEqual(r.watch.slowSampleCount(of: key(40)), 0)
    }

    /// After hours the timeline `samples(of:)` hands to the window is the slow ring's older points followed by the fast
    /// ring's 192, strictly increasing: no point twice where the rings overlap and no gap between them.
    func testTheHandOverTimelineIsOrderedAndHasNoDuplicatesAcrossBothRings() {
        let r = WatchRig()
        r.machine.add(40, 400, path: "/Applications/Flat.app/Contents/MacOS/Flat")
        r.run(for: 6 * 3600, step: 8)
        let all = r.watch.samples(of: key(40))
        let slow = r.watch.slowSamples(of: key(40))
        XCTAssertEqual(slow.count, 48)
        XCTAssertTrue(zip(all, all.dropFirst()).allSatisfy { $0.seconds < $1.seconds }, "strictly increasing")
        XCTAssertGreaterThan(all.count, MemoryWatch.ringCapacity)
        XCTAssertLessThanOrEqual(all.count, MemoryWatch.ringCapacity + 48)
        let firstFast = all[all.count - MemoryWatch.ringCapacity].seconds
        let older = slow.filter { $0.seconds < firstFast }
        XCTAssertEqual(all.count - MemoryWatch.ringCapacity, older.count, "every older slow point, and only those")
        XCTAssertEqual(all.first, older.first)
        XCTAssertGreaterThan((all.last?.seconds ?? 0) - (all.first?.seconds ?? 0), 3 * 3600, "hours, not minutes")
    }

    /// Seven days of 8 s light ticks (with a footprint-only discovery every minute) on 800 processes that start, exit, grow
    /// and shrink all the time. The table, both rings, the discovery map and the caches stay within their bounds the whole
    /// way; five pinned steady processes are fed by the slow tracker about 12 times an hour each (every 304 s on this clock),
    /// not once per tick; and when every process is gone everything is empty. Failing here means Anode's memory or work
    /// grows with uptime.
    func testA7DaySoakStaysBoundedAndTheSlowTierIsFedAboutTwelveTimesAnHour() {
        let r = WatchRig()
        var rand = MemoryTestKit.Random(seed: 20_261_120)
        let first: pid_t = 5000
        let slots = 800
        let steady = 5
        for s in 0..<slots {
            r.machine.add(first + pid_t(s), s < steady ? 2048 : Double(20 + rand.int(below: 1480)),
                          path: "/Applications/App\(s % 60).app/Contents/MacOS/App")
        }
        for s in 0..<steady { r.watch.pin(key(first + pid_t(s))) }
        var worstTable = 0, worstRings = 0, worstSlowRings = 0, worstPrevious = 0, worstIdentities = 0, worstReported = 0
        let steps = 7 * 24 * 3600 / 8
        for step in 0..<steps {
            for _ in 0..<2 {
                let s = steady + rand.int(below: slots - steady)
                r.machine.procs[first + pid_t(s)] = FakeMachine.Proc(
                    start: UInt64(step + 2), footprint: mib(Double(20 + rand.int(below: 1480))),
                    path: "/Applications/App\(s % 60).app/Contents/MacOS/App")
            }
            for _ in 0..<3 {
                let s = steady + rand.int(below: slots - steady)
                r.machine.procs[first + pid_t(s)]?.footprint += mib(Double(rand.int(below: 40)))
            }
            for _ in 0..<3 {
                let s = steady + rand.int(below: slots - steady)
                if let p = r.machine.procs[first + pid_t(s)], p.footprint > mib(10) {
                    r.machine.procs[first + pid_t(s)]?.footprint -= mib(Double(rand.int(below: 5)))
                }
            }
            r.probe()
            r.awake += 8
            worstTable = max(worstTable, r.watch.candidateCount)
            worstRings = max(worstRings, r.watch.ringCount)
            worstSlowRings = max(worstSlowRings, r.watch.slowRingCount)
            worstPrevious = max(worstPrevious, r.watch.previousDiscoveryCount)
            worstIdentities = max(worstIdentities, r.watch.identityCacheCount)
            worstReported = max(worstReported, r.watch.reportedCount)
        }
        XCTAssertLessThanOrEqual(worstTable, 32)
        XCTAssertLessThanOrEqual(worstRings, 32 * MemoryWatch.ringCapacity)
        XCTAssertLessThanOrEqual(worstSlowRings, 32 * 48)
        XCTAssertLessThanOrEqual(worstPrevious, slots)
        XCTAssertLessThanOrEqual(worstIdentities, slots)
        XCTAssertLessThanOrEqual(worstReported, slots)

        let elapsedHours = Double(steps - 1) * 8 / 3600
        var feedsOfSteady = 0
        for s in 0..<steady {
            let k = key(first + pid_t(s))
            XCTAssertTrue(r.watch.isCandidate(k), "a pinned process is never evicted")
            let feeds = r.watch.slowFeeds(of: k)
            feedsOfSteady += feeds
            let perHour = Double(feeds) / elapsedHours
            XCTAssertGreaterThanOrEqual(perHour, 11.5, "slot \(s): \(feeds) feeds")
            XCTAssertLessThanOrEqual(perHour, 12.1, "slot \(s): \(feeds) feeds")
            XCTAssertEqual(r.watch.slowSampleCount(of: k), 48)
        }
        XCTAssertGreaterThanOrEqual(r.watch.slowFeedCount, feedsOfSteady)

        r.machine.procs.removeAll()
        r.run(for: 130, step: 8)
        XCTAssertEqual(r.watch.candidateCount, 0)
        XCTAssertEqual(r.watch.ringCount, 0)
        XCTAssertEqual(r.watch.slowRingCount, 0)
        XCTAssertEqual(r.watch.previousDiscoveryCount, 0)
        XCTAssertEqual(r.watch.identityCacheCount, 0)
        XCTAssertEqual(r.watch.reportedCount, 0)
    }

    /// `reset()` clears the slow tier with the rest: no slow ring, no feed count.
    func testResetForgetsTheSlowTierToo() {
        let r = WatchRig()
        r.machine.add(40, 400, path: "/Applications/Flat.app/Contents/MacOS/Flat")
        r.run(for: 700, step: 8)
        XCTAssertGreaterThan(r.watch.slowFeedCount, 0)
        r.watch.reset()
        XCTAssertEqual(r.watch.slowFeedCount, 0)
        XCTAssertEqual(r.watch.slowRingCount, 0)
        XCTAssertNil(r.watch.slowPhase(of: key(40)))
    }

    // MARK: CPU

    /// The leak is flagged while the process is nearly idle (3 % of a core), and the finding says so; busy at 80 % of a
    /// core, the same growth is work and is never flagged by the fast tier. Failing here means a long test run or build is
    /// reported as a leak, or a real leak of an idle process is missed.
    func testTheFastTierFlagsAnIdleLeakWithItsCPUAndNotABusyOne() {
        let idle = WatchRig()
        idle.machine.add(100, 300, path: leakyPath)
        idle.run(for: 200) { t in
            idle.machine.setMiB(100, 300 + (t - 1000))
            idle.machine.setCPU(100, nanos: UInt64(0.03 * (t - 1000) * 1e9))
        }
        XCTAssertEqual(idle.findings.count, 1)
        guard let f = idle.findings.first else { return }
        XCTAssertEqual(f.tier, .fast)
        XCTAssertEqual(f.cpuFraction ?? -1, 0.03, accuracy: 0.002)
        XCTAssertTrue(f.explanation.contains("It used about 3% of a core while its memory grew"), f.explanation)

        let busy = WatchRig()
        busy.machine.add(100, 300, path: leakyPath)
        busy.run(for: 200) { t in
            busy.machine.setMiB(100, 300 + (t - 1000))
            busy.machine.setCPU(100, nanos: UInt64(0.8 * (t - 1000) * 1e9))
        }
        XCTAssertTrue(busy.findings.isEmpty)
        XCTAssertNotEqual(busy.watch.phase(of: key(100)), .reported)
    }

    /// A reading that carries no CPU (a counter that stays at zero is still a reading) is judged as always: the machine
    /// fake that never sets a CPU gives a finding whose fraction is zero, not nil, and the explanation says "under 1%".
    func testACPUCounterThatNeverMovesReadsAsIdle() {
        let r = WatchRig()
        r.machine.add(100, 300, path: leakyPath)
        r.run(for: 200) { t in r.machine.setMiB(100, 300 + (t - 1000)) }
        XCTAssertEqual(r.findings.first?.cpuFraction, 0)
        XCTAssertTrue(r.findings.first?.explanation.contains("It used under 1% of a core") ?? false)
    }

    /// The CPU of a process read from a full sweep is converted from mach time units to nanoseconds, so the same gate holds
    /// whether the feed is a sweep or a light tick: busy through sweeps is gated, quiet through sweeps is flagged.
    func testAFullSweepCarriesTheCPUToo() {
        func play(_ fraction: Double) -> [Finding] {
            let r = WatchRig()
            var t = 1000.0
            while t < 1200 {
                let nanos = fraction * (t - 1000) * 1e9
                let units = UInt64((nanos / MachTime.nanosPerUnit).rounded())
                let proc = makeProcess(pid: 100, start: 1, nJ: 0, path: leakyPath, cpu_ns: units,
                                       footprint: mib(300 + (t - 1000)))
                r.awake = t
                r.watch.ingest(sweep: makeSweep(at: t, [proc]), awake: t)
                t += 2
            }
            return r.findings
        }
        XCTAssertTrue(play(0.8).isEmpty)
        let quiet = play(0.03)
        XCTAssertEqual(quiet.count, 1)
        XCTAssertEqual(quiet.first?.cpuFraction ?? -1, 0.03, accuracy: 0.005)
    }

    /// The slow tier is not gated: a 9 MiB a minute climb on a process that averages 80 % of a core all day is still found
    /// once, by the slow tier, and the finding says how busy it was. Failing here means a leaking app that is used all day
    /// could never be found.
    func testTheSlowTierFindsALeakInAProcessThatIsBusyAllDay() {
        let r = WatchRig()
        r.machine.add(100, 3072, path: leakyPath)
        r.run(for: 3 * 3600, step: 8) { t in
            r.machine.setMiB(100, 3072 + 0.15 * (t - 1000))
            r.machine.setCPU(100, nanos: UInt64(0.8 * (t - 1000) * 1e9))
        }
        XCTAssertEqual(r.findings.count, 1)
        guard let f = r.findings.first else { return }
        XCTAssertEqual(f.tier, .slow)
        XCTAssertEqual(f.cpuFraction ?? -1, 0.8, accuracy: 0.01)
        XCTAssertTrue(f.explanation.hasSuffix("It averaged about 80% of a core over that time."), f.explanation)
    }

    /// With the CPU going backwards on the machine (a reused pid reads as a different process by its start time, but a
    /// counter reset must still be harmless): the watch keeps running and the quiet leak is still found.
    func testACPUCounterResetOnTheMachineIsHarmless() {
        let r = WatchRig()
        r.machine.add(100, 300, path: leakyPath)
        r.run(for: 200) { t in
            r.machine.setMiB(100, 300 + (t - 1000))
            let elapsed = t < 1030 ? t - 1000 : t - 1030
            r.machine.setCPU(100, nanos: UInt64(0.03 * elapsed * 1e9))
        }
        XCTAssertEqual(r.findings.count, 1)
        XCTAssertLessThan(r.findings.first?.cpuFraction ?? 1, 0.05)
    }

    // MARK: The real readers

    /// The two narrow readers this feature adds to ProcessSampler see this very process: its start time and footprint, in
    /// one call each, with no path or name.
    func testTheFootprintReadersSeeThisProcess() {
        let me = getpid()
        guard let one = ProcessSampler.footprint(of: me) else { return XCTFail("could not read this process") }
        XCTAssertGreaterThan(one.start, 0)
        XCTAssertGreaterThan(one.footprint, 1_048_576)
        let all = ProcessSampler.footprints()
        XCTAssertFalse(all.isEmpty)
        let mine = all.first { $0.pid == me }
        XCTAssertNotNil(mine)
        XCTAssertEqual(mine?.start, one.start, "the start time is the identity a pid reuse is judged by")
        // The CPU time rides along: a test process has used some, the counter never goes down, and a later pass sees at
        // least what an earlier read did.
        XCTAssertGreaterThan(one.cpuNanos, 1_000_000, "a process that has run a test has used more than a millisecond")
        XCTAssertLessThan(one.cpuNanos, 1_000_000_000_000_000, "and not centuries")
        XCTAssertGreaterThanOrEqual(mine?.cpuNanos ?? 0, one.cpuNanos)
        XCTAssertGreaterThanOrEqual(ProcessSampler.footprint(of: me)?.cpuNanos ?? 0, mine?.cpuNanos ?? 0)
    }

    /// The CPU figure is in real nanoseconds, not the mach time units rusage reports (41.7 times smaller on Apple Silicon):
    /// after burning about 100 ms of this process's own CPU, the reader and libc's `clock()` agree to within a factor of two.
    func testTheCPUReadIsInRealNanosecondsAgainstTheProcessOwnClock() {
        let me = getpid()
        let began = Double(clock()) / 1_000_000
        while Double(clock()) / 1_000_000 - began < 0.1 { _ = sqrt(Double(clock())) }
        let before = Double(clock()) / 1_000_000
        guard let read = ProcessSampler.footprint(of: me) else { return XCTFail("could not read this process") }
        let after = Double(clock()) / 1_000_000
        let seconds = Double(read.cpuNanos) / 1e9
        XCTAssertGreaterThanOrEqual(seconds, before * 0.5, "a 41.7x error would put this far below")
        XCTAssertLessThanOrEqual(seconds, after * 2 + 0.1)
    }

    func testMachTimeNanosecondsConvertsAndSaturates() {
        XCTAssertEqual(MachTime.nanoseconds(units: 0), 0)
        XCTAssertEqual(Double(MachTime.nanoseconds(units: 24_000_000)), 24_000_000 * MachTime.nanosPerUnit, accuracy: 1)
        XCTAssertEqual(MachTime.nanoseconds(units: UInt64.max), UInt64.max, "saturates instead of trapping")
        XCTAssertEqual(makeProcess(pid: 1, nJ: 0, cpu_ns: 1_000).cpuNanos, MachTime.nanoseconds(units: 1_000),
                       "a sweep's process converts its mach time units the same way")
    }
}

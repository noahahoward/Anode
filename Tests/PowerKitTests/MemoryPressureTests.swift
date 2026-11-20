import XCTest
@testable import PowerKit

private let gib: UInt64 = 1 << 30
private func mib(_ x: Double) -> UInt64 { MemoryTestKit.mib(x) }
private func key(_ pid: pid_t, start: UInt64 = 1) -> ProcessKey { ProcessKey(pid: pid, startAbsTime: start) }

/// A 64 GB Mac by default, 30 GB in use, no swap; `level` is the kernel's pressure level.
private func reading(_ level: Int32? = 1, swap: UInt64 = 0, total: UInt64 = 64 * gib, used: UInt64 = 30 * gib) -> SystemMemoryReading {
    SystemMemoryReading(totalBytes: total, usedBytes: used, swapUsedBytes: swap, pressureLevel: level)
}

/// One tracker fed readings on an injected clock, remembering every verdict and when it came.
private struct PressureFeeder {
    var tracker = PressureTracker()
    /// The first version's rules (a minute of orange, swap and one big app as triggers) so those stay tested; the new
    /// pressure-only defaults have their own tests below.
    var rules = PressureRules.everything
    var found: [(t: Double, verdict: PressureVerdict)] = []

    mutating func feed(_ r: SystemMemoryReading, top: UInt64 = gib, at t: Double) {
        if let v = tracker.ingest(r, topAppBytes: top, at: t, rules: rules) { found.append((t: t, verdict: v)) }
    }

    /// The same reading every `step` seconds from `from` to `end`, both included.
    mutating func hold(_ r: SystemMemoryReading, top: UInt64 = gib, from: Double, through end: Double, step: Double = 5) {
        var t = from
        while t <= end {
            feed(r, top: top, at: t)
            t += step
        }
    }

    var times: [Double] { found.map { $0.t } }
    var reasons: [PressureReason] { found.map { $0.verdict.reason } }
}

/// The high-memory warning's decision, played against synthetic readings on an injected clock. No system call is made:
/// every number is handed in.
final class PressureTrackerTests: XCTestCase {

    // MARK: Kernel pressure

    /// Pressure that is over in 55 seconds is not a warning: the rule needs a full minute.
    func testAPressureWarningShorterThanSixtySecondsNeverFires() {
        var f = PressureFeeder()
        f.hold(reading(2), from: 0, through: 55)
        f.hold(reading(1), from: 60, through: 600)
        XCTAssertTrue(f.found.isEmpty)
    }

    /// Held for a minute it fires once, with the numbers behind it, and never again however long it goes on.
    func testASustainedPressureWarningFiresOnceAtSixtySeconds() {
        var f = PressureFeeder()
        f.hold(reading(2), top: 8 * gib, from: 0, through: 600)
        XCTAssertEqual(f.times, [60])
        XCTAssertEqual(f.reasons, [.warning])
        XCTAssertEqual(f.found.first?.verdict.sustainedSeconds ?? 0, 60, accuracy: 0.001)
        XCTAssertEqual(f.found.first?.verdict.reading, reading(2))
        XCTAssertEqual(f.found.first?.verdict.topAppBytes, 8 * gib)
    }

    /// Critical pressure needs fifteen seconds, and being critical already covers the warning: one alert, not two.
    func testCriticalFiresAfterFifteenSecondsAndTheWarningDoesNotFollowIt() {
        var f = PressureFeeder()
        f.hold(reading(4), from: 0, through: 100)
        XCTAssertEqual(f.times, [15])
        XCTAssertEqual(f.reasons, [.critical])
    }

    /// Things getting worse is news even while a warning is cooling down: a critical alert fires inside the warning's
    /// thirty minutes.
    func testACriticalAlertMayFireInsideAWarningsCooldown() {
        var f = PressureFeeder()
        f.hold(reading(2), from: 0, through: 95)
        f.hold(reading(4), from: 100, through: 140)
        XCTAssertEqual(f.times, [60, 115])
        XCTAssertEqual(f.reasons, [.warning, .critical])
    }

    /// A warning does not fire while a critical alert is cooling down (ten minutes), even once the machine has been calm
    /// long enough to re-arm: it fires when the critical cooldown ends.
    func testAWarningWaitsOutACriticalAlertsCooldown() {
        var f = PressureFeeder()
        f.hold(reading(4), from: 0, through: 20)          // critical at 15
        f.hold(reading(1), from: 25, through: 210)        // calm for over three minutes: re-armed
        f.hold(reading(2), from: 215, through: 620)       // sustained from 275, held back until 15 + 600
        XCTAssertEqual(f.times, [15, 615])
        XCTAssertEqual(f.reasons, [.critical, .warning])
    }

    /// An unreadable pressure level counts as normal.
    func testAnUnreadablePressureLevelIsNormal() {
        var f = PressureFeeder()
        f.hold(reading(nil), from: 0, through: 1000)
        XCTAssertTrue(f.found.isEmpty)
    }

    // MARK: Swap

    /// Swap has to clear both bars: at least 4 GiB, and at least a quarter of the RAM. 10 GiB on a 64 GiB Mac is the first
    /// but not the second; 3 GiB on an 8 GiB Mac is the second but not the first.
    func testSwapNeedsBothTheByteFloorAndTheFractionOfRAM() {
        var big = PressureFeeder()
        big.hold(reading(1, swap: 10 * gib), from: 0, through: 600)
        XCTAssertTrue(big.found.isEmpty, "10 GiB of swap on 64 GiB is under a quarter")

        var small = PressureFeeder()
        small.hold(reading(1, swap: 3 * gib, total: 8 * gib), from: 0, through: 600)
        XCTAssertTrue(small.found.isEmpty, "3 GiB on 8 GiB is over a quarter but under the 4 GiB floor")
    }

    /// And it has to last two minutes.
    func testSwapMustBeSustainedForTwoMinutes() {
        var brief = PressureFeeder()
        brief.hold(reading(1, swap: 16 * gib), from: 0, through: 115)
        brief.hold(reading(1), from: 120, through: 600)
        XCTAssertTrue(brief.found.isEmpty)

        var held = PressureFeeder()
        held.hold(reading(1, swap: 16 * gib), from: 0, through: 300)
        XCTAssertEqual(held.times, [120])
        XCTAssertEqual(held.reasons, [.swap])

        var small = PressureFeeder()
        small.hold(reading(1, swap: 4 * gib, total: 8 * gib), from: 0, through: 300)
        XCTAssertEqual(small.times, [120], "4 GiB on 8 GiB clears both bars")
    }

    // MARK: One app dominates

    /// An app at half of the RAM for five minutes fires; the same app at 62 % of 64 GiB (the browser case) fires with its
    /// size in the verdict.
    func testOneAppAtHalfTheRAMForFiveMinutesFires() {
        var half = PressureFeeder()
        half.hold(reading(1), top: 32 * gib, from: 0, through: 600)
        XCTAssertEqual(half.times, [300])
        XCTAssertEqual(half.reasons, [.oneAppDominates])

        let brave = UInt64(0.62 * Double(64 * gib))
        var f = PressureFeeder()
        f.hold(reading(1), top: brave, from: 0, through: 600)
        XCTAssertEqual(f.times, [300])
        XCTAssertEqual(f.found.first?.verdict.topAppBytes, brave)
        XCTAssertEqual(f.found.first?.verdict.sustainedSeconds ?? 0, 300, accuracy: 0.001)
    }

    /// A ten minute spike at 47 % is not half, and a spike above half that ends after 200 seconds is not five minutes.
    func testASpikeBelowHalfOrShorterThanFiveMinutesDoesNotFire() {
        var below = PressureFeeder()
        below.hold(reading(1), top: 30 * gib, from: 0, through: 600)
        XCTAssertTrue(below.found.isEmpty)

        var short = PressureFeeder()
        short.hold(reading(1), top: 40 * gib, from: 0, through: 200)
        short.hold(reading(1), top: 10 * gib, from: 205, through: 900)
        XCTAssertTrue(short.found.isEmpty)
    }

    // MARK: Priority

    /// critical > warning > swap > oneAppDominates.
    func testWhenSeveralRulesAreTrueTheHighestPriorityWins() {
        var critical = PressureFeeder()
        critical.hold(reading(4, swap: 20 * gib), top: 40 * gib, from: 0, through: 400)
        XCTAssertEqual(critical.reasons, [.critical])

        var warning = PressureFeeder()
        warning.hold(reading(2, swap: 20 * gib), top: 40 * gib, from: 0, through: 400)
        XCTAssertEqual(warning.reasons, [.warning], "the swap and the big app are covered by the one warning")

        var swap = PressureFeeder()
        swap.rules.swapSeconds = 300
        swap.hold(reading(1, swap: 20 * gib), top: 40 * gib, from: 0, through: 400)
        XCTAssertEqual(swap.reasons, [.swap], "swap and one app sustained on the same reading: swap wins")
    }

    // MARK: Cooldown and re-arm

    /// After a warning the same level stays quiet until pressure has been normal for three minutes, and a reading that is
    /// back to normal for less than that, or that goes up again, does not count. (The cooldown is switched off here so the
    /// re-arm is what is tested.)
    func testAWarningFiresAgainOnlyAfterThreeCalmMinutes() {
        var f = PressureFeeder()
        f.rules.warningCooldownSeconds = 0
        f.hold(reading(2), from: 0, through: 400)
        XCTAssertEqual(f.times, [60])
        f.hold(reading(1), from: 405, through: 570)       // calm for 165 s: not enough
        f.hold(reading(2), from: 575, through: 700)       // up again: the calm run is lost
        XCTAssertEqual(f.times, [60])
        f.hold(reading(1), from: 705, through: 890)       // calm for over 180 s
        f.hold(reading(2), from: 895, through: 1000)
        XCTAssertEqual(f.times, [60, 955])
    }

    /// "Calm" means every rule is quiet: a normal pressure level with a lot of swap in use is not calm.
    func testHighSwapOrABigAppKeepsTheMachineFromBeingCalm() {
        var f = PressureFeeder()
        f.rules.warningCooldownSeconds = 0
        f.hold(reading(2), from: 0, through: 65)
        XCTAssertEqual(f.times, [60])
        f.hold(reading(1, swap: 20 * gib), from: 70, through: 800)    // pressure normal, swap still high
        f.hold(reading(1), from: 805, through: 900)                   // calm only from 805
        f.hold(reading(2), from: 905, through: 1000)
        XCTAssertEqual(f.times, [60], "with swap high the machine is never calm, so nothing re-armed (not the swap alert at 190 either)")
    }

    /// Re-armed is not enough: the same level also waits out its cooldown (30 minutes for a warning).
    func testAWarningAlsoWaitsOutItsThirtyMinuteCooldown() {
        var f = PressureFeeder()
        f.hold(reading(2), from: 0, through: 60)
        f.hold(reading(1), from: 65, through: 300)         // re-armed at 245
        f.hold(reading(2), from: 305, through: 1900)       // sustained from 365; cooling until 60 + 1800
        XCTAssertEqual(f.times, [60, 1860])
    }

    // MARK: Flapping, gaps, reset

    /// Up for 40 s, down for 10 s, up for 40 s, over and over: no stretch reaches a minute.
    func testAFlappingReadingNeverFires() {
        var f = PressureFeeder()
        for cycle in 0..<12 {
            let base = Double(cycle) * 55
            f.hold(reading(2), from: base, through: base + 40)
            f.hold(reading(1), from: base + 45, through: base + 50)
        }
        XCTAssertTrue(f.found.isEmpty)
    }

    /// A sleep starts every timer again, and what has already been said is still said.
    func testAGapRestartsTheTimersButKeepsTheCooldownState() {
        var f = PressureFeeder()
        f.hold(reading(2), from: 0, through: 50)
        f.tracker.noteGap()
        f.hold(reading(2), from: 100, through: 400)
        XCTAssertEqual(f.times, [160], "a minute after the gap, not a minute after the first reading")
        f.tracker.noteGap()
        f.hold(reading(2), from: 500, through: 900)
        XCTAssertEqual(f.times, [160], "the alert already given is still given")
    }

    /// Reset forgets everything, cooldowns included.
    func testResetForgetsEverything() {
        var f = PressureFeeder()
        f.hold(reading(2), from: 0, through: 60)
        XCTAssertEqual(f.times, [60])
        f.tracker.reset()
        XCTAssertEqual(f.tracker, PressureTracker())
        f.hold(reading(2), from: 100, through: 160)
        XCTAssertEqual(f.times, [60, 160])
    }

    /// A clock that goes backwards starts the timers again and does not leave a cooldown stuck in the future.
    func testAClockThatGoesBackwardsDoesNotStickACooldown() {
        var f = PressureFeeder()
        f.hold(reading(2), from: 10_000, through: 10_060)
        XCTAssertEqual(f.times, [10_060])
        f.hold(reading(1), from: 100, through: 300)        // the clock is now at 100: the cooldown counts from there
        f.hold(reading(2), from: 305, through: 5000)       // sustained from 365, held until 100 + 1800
        XCTAssertEqual(f.times, [10_060, 1900])
    }
}

/// The one read of the machine, run on this machine. Skipped, not failed, when the system will not say.
final class SystemMemoryReaderTests: XCTestCase {

    func testTheReaderGivesAPlausibleReading() throws {
        guard let r = SystemMemoryReader.read() else { throw XCTSkip("memory statistics are not readable here") }
        XCTAssertGreaterThan(r.totalBytes, 0)
        XCTAssertLessThanOrEqual(r.usedBytes, r.totalBytes)
        if let level = r.pressureLevel { XCTAssertTrue([1, 2, 4].contains(level)) }
        XCTAssertGreaterThanOrEqual(r.usedPercent, 0)
        XCTAssertLessThanOrEqual(r.usedPercent, 100)
    }
}

// MARK: - The words

/// A pressure finding as the watch builds one, for the wording tests.
private func pressureFinding(_ reason: PressureReason?, system: SystemMemoryReading? = SystemMemoryReading(
    totalBytes: 64 * gib, usedBytes: 60 * gib, swapUsedBytes: 6 * gib + gib / 2, pressureLevel: 4)) -> Finding {
    Finding(processKey: key(101), pid: 101, name: "Brave Browser",
            path: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
            identityKey: "/Applications/Brave Browser.app", isApp: true,
            startBytes: 30 * gib, nowBytes: 38 * gib, netGrowthBytes: 8 * gib,
            windowSeconds: 120, bucketSeconds: 0,
            flaggedAtWall: Date(timeIntervalSinceReferenceDate: 0), flaggedAtAwake: 0,
            risingSamples: 0, totalSamples: 0, largestDipBytes: 0, history: [], shouldNotify: true,
            tier: .pressure, system: system, reason: reason,
            topApps: [PressureApp(name: "Brave Browser", identityKey: "/Applications/Brave Browser.app", isApp: true, bytes: 38 * gib),
                      PressureApp(name: "Safari", identityKey: "/Applications/Safari.app", isApp: true, bytes: 4 * gib),
                      PressureApp(name: "node", identityKey: "/usr/local/bin/node", isApp: false, bytes: 2 * gib)])
}

final class PressureFindingWordsTests: XCTestCase {

    /// The title says what is wrong: a Mac low on memory, not a "possible leak". A leak keeps its own title.
    func testTheTitleFollowsTheTier() {
        XCTAssertEqual(pressureFinding(.critical).notificationTitle, "Memory is running low")
        var leak = pressureFinding(nil)
        leak.tier = .fast
        XCTAssertEqual(leak.notificationTitle, "Possible memory leak detected")
        leak.tier = .slow
        XCTAssertEqual(leak.notificationTitle, "Possible memory leak detected")
    }

    /// The body leads with the rule that fired, then names the app and its size against the total, and says what to do.
    func testTheBodyNamesTheAppAndItsSizeForEveryReason() {
        XCTAssertEqual(pressureFinding(.critical).notificationBody,
                       "Your Mac is critically low on memory. Brave Browser is using 38 GB of 64 GB. Click to see what to quit.")
        XCTAssertEqual(pressureFinding(.warning).notificationBody,
                       "Your Mac is low on memory. Brave Browser is using 38 GB of 64 GB. Click to see what to quit.")
        XCTAssertEqual(pressureFinding(.swap).notificationBody,
                       "Your Mac is using a lot of swap. Brave Browser is using 38 GB of 64 GB. Click to see what to quit.")
        XCTAssertEqual(pressureFinding(.oneAppDominates).notificationBody,
                       "Brave Browser is using over half of your memory: 38 GB of 64 GB. Click to see what to quit.")
        XCTAssertEqual(pressureFinding(nil).notificationBody,
                       "Your Mac is running low on memory. Brave Browser is using 38 GB of 64 GB. Click to see what to quit.")
    }

    /// Without a total the size stands alone; without an app there is nothing to name.
    func testTheBodyCopesWithAMissingTotalOrAnUnnamedApp() {
        XCTAssertEqual(pressureFinding(.warning, system: nil).notificationBody,
                       "Your Mac is low on memory. Brave Browser is using 38 GB. Click to see what to quit.")
        var unnamed = pressureFinding(.warning)
        unnamed.name = ""
        unnamed.nowBytes = 0
        XCTAssertEqual(unnamed.notificationBody, "Your Mac is low on memory. Click to see what to quit.")
        XCTAssertTrue(unnamed.explanation.contains("never quits anything by itself"))
    }

    /// The window's text says how full the memory is, how much swap is in use, which app is largest and by how much,
    /// that quitting it first helps most, and that Anode only reads sizes.
    func testTheExplanationSaysWhatTheMachineLooksLikeAndWhatToDo() {
        let text = pressureFinding(.critical).explanation
        XCTAssertTrue(text.contains("60 GB of 64 GB of memory is in use (94 %)"), text)
        XCTAssertTrue(text.contains("6.5 GB of swap is in use"), text)
        XCTAssertTrue(text.contains("critical memory pressure"), text)
        XCTAssertTrue(text.contains("The largest app is Brave Browser, using 38 GB of 64 GB (59 %)"), text)
        XCTAssertTrue(text.contains("Next: Safari 4 GB, node 2 GB."), text)
        XCTAssertTrue(text.contains("Quitting Brave Browser first will help most."), text)
        XCTAssertTrue(text.contains("Anode only reads memory sizes. It never quits anything by itself."), text)

        var none = SystemMemoryReading(totalBytes: 64 * gib, usedBytes: 60 * gib, swapUsedBytes: 0, pressureLevel: 2)
        XCTAssertTrue(pressureFinding(.warning, system: none).explanation.contains("no swap is in use"))
        none.swapUsedBytes = gib
        XCTAssertTrue(pressureFinding(.swap, system: none).explanation.contains("Swap use has stayed high"))
    }

    /// A finding built the way every leak caller builds one carries no machine reading and no reason.
    func testALeakFindingHasNoMachineReading() {
        let f = Finding(processKey: key(1), pid: 1, name: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari",
                        identityKey: "/Applications/Safari.app", isApp: true, startBytes: 1, nowBytes: 2, netGrowthBytes: 1,
                        windowSeconds: 64, bucketSeconds: 15,
                        flaggedAtWall: Date(timeIntervalSinceReferenceDate: 0), flaggedAtAwake: 0,
                        risingSamples: 21, totalSamples: 24, largestDipBytes: 0, history: [], shouldNotify: true)
        XCTAssertEqual(f.tier, .fast)
        XCTAssertNil(f.system)
        XCTAssertNil(f.reason)
        XCTAssertTrue(f.topApps.isEmpty)
        XCTAssertTrue(f.explanation.contains("Leaks look like this"))
    }

    func testSizesAreWordedInBinaryUnitsAsMacOSShowsMemory() {
        XCTAssertEqual(MemorySizeText.text(38 * gib), "38 GB")
        XCTAssertEqual(MemorySizeText.text(6 * gib + gib / 2), "6.5 GB")
        XCTAssertEqual(MemorySizeText.text(512 << 20), "512 MB")
        XCTAssertEqual(MemorySizeText.text(0), "0 MB")
    }
}

// MARK: - The watch

private let bravePath = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
private let braveHelperPath = "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Helper.app/Contents/MacOS/Brave Browser Helper"
private let safariPath = "/Applications/Safari.app/Contents/MacOS/Safari"
private let nodePath = "/usr/local/bin/node"

/// A pretend machine: processes with a start time, a footprint and a path, and a count of every path read made of it.
private final class PressureMachine {
    struct Proc {
        var start: UInt64
        var footprint: UInt64
        var path: String
        var cpuNanos: UInt64 = 0
    }

    var procs: [pid_t: Proc] = [:]
    var ignored: Set<String> = []
    var pathReads = 0

    func add(_ pid: pid_t, _ mibs: Double, _ path: String) { procs[pid] = Proc(start: 1, footprint: mib(mibs), path: path) }
    func setMiB(_ pid: pid_t, _ mibs: Double) { procs[pid]?.footprint = mib(mibs) }

    func pathOf(_ pid: pid_t) -> String {
        pathReads += 1
        return procs[pid]?.path ?? ""
    }
    func footprintOf(_ pid: pid_t) -> (start: UInt64, footprint: UInt64, cpuNanos: UInt64)? {
        guard let p = procs[pid] else { return nil }
        return (start: p.start, footprint: p.footprint, cpuNanos: p.cpuNanos)
    }
    func discover() -> [(pid: pid_t, start: UInt64, footprint: UInt64, cpuNanos: UInt64)] {
        procs.map { (pid: $0.key, start: $0.value.start, footprint: $0.value.footprint, cpuNanos: $0.value.cpuNanos) }
            .sorted { $0.pid < $1.pid }
    }
}

/// A watch on a pretend machine, fed the way the app feeds it: a light tick, then the system reading, on an injected clock.
private final class PressureRig {
    let machine: PressureMachine
    let watch: MemoryWatch
    var findings: [Finding] = []
    var awake: Double = 1000
    var wallOffset: Double = 0

    init(ownPID: pid_t = 999) {
        let m = PressureMachine()
        machine = m
        watch = MemoryWatch(ownPID: ownPID,
                            pathOf: { m.pathOf($0) },
                            isIgnored: { m.ignored.contains($0) },
                            footprintOf: { m.footprintOf($0) },
                            discover: { m.discover() },
                            startSeconds: { Double($0) })
        watch.onFinding = { [unowned self] f in self.findings.append(f) }
        watch.pressureRules = .everything
    }

    /// Brave (a main process and two helpers, 38 GiB in all), Safari (4 GiB) and a tool (2 GiB).
    func addTypicalMac() {
        machine.add(100, 8192, bravePath)
        machine.add(101, 20480, braveHelperPath)
        machine.add(102, 10240, braveHelperPath)
        machine.add(103, 4096, safariPath)
        machine.add(104, 2048, nodePath)
    }

    var pressureFindings: [Finding] { findings.filter { $0.tier == .pressure } }

    func tick(_ r: SystemMemoryReading?, step: Double = 5) {
        let wall = Date(timeIntervalSinceReferenceDate: awake + wallOffset)
        watch.probe(awake: awake, wall: wall)
        watch.ingestSystem(r, awake: awake, wall: wall)
        awake += step
    }

    func run(_ r: SystemMemoryReading?, ticks: Int, step: Double = 5) {
        for _ in 0..<ticks { tick(r, step: step) }
    }
}

private let criticalReading = SystemMemoryReading(totalBytes: 64 * gib, usedBytes: 60 * gib, swapUsedBytes: 6 * gib,
                                                  pressureLevel: 4)

final class MemoryWatchPressureTests: XCTestCase {

    /// Off is the default and off does nothing: no finding, whatever the readings say, and a missing reading is ignored too.
    func testNothingHappensWhileTheWarningIsOff() {
        let r = PressureRig()
        r.addTypicalMac()
        XCTAssertFalse(r.watch.watchesPressure)
        XCTAssertTrue(r.watch.detectsLeaks)
        r.run(criticalReading, ticks: 100)
        XCTAssertTrue(r.pressureFindings.isEmpty)
        XCTAssertEqual(r.watch.pressureFindingCount, 0)

        r.watch.setModes(leaks: true, pressure: true)
        r.run(nil, ticks: 100)
        XCTAssertTrue(r.pressureFindings.isEmpty, "no reading, no verdict")
    }

    /// A verdict becomes exactly one finding, for the app that is largest once its helpers are added up, with the machine's
    /// numbers, the reason, and the biggest apps in order.
    func testAVerdictRaisesExactlyOnePressureFindingNamingTheLargestApp() {
        let r = PressureRig()
        r.addTypicalMac()
        r.watch.setModes(leaks: true, pressure: true)
        r.run(criticalReading, ticks: 4)                     // critical from the first tick: sustained 15 s on the fourth
        XCTAssertEqual(r.findings.count, 1)
        guard let f = r.findings.first else { return }
        XCTAssertEqual(f.tier, .pressure)
        XCTAssertEqual(f.reason, .critical)
        XCTAssertEqual(f.system, criticalReading)
        XCTAssertEqual(f.name, "Brave Browser")
        XCTAssertEqual(f.identityKey, "/Applications/Brave Browser.app")
        XCTAssertTrue(f.isApp)
        XCTAssertEqual(f.pid, 101, "the app's biggest process")
        XCTAssertEqual(f.processKey, key(101))
        XCTAssertEqual(f.path, braveHelperPath)
        XCTAssertEqual(f.nowBytes, mib(38_912), "the main process and both helpers")
        XCTAssertEqual(f.startBytes, f.nowBytes, "nothing grew")
        XCTAssertEqual(f.netGrowthBytes, 0)
        XCTAssertTrue(f.shouldNotify)
        XCTAssertFalse(f.history.isEmpty, "the biggest process's ring is the graph")
        XCTAssertEqual(f.history.last?.bytes, mib(20_480))
        XCTAssertEqual(f.topApps.map { $0.name }, ["Brave Browser", "Safari", "node"])
        XCTAssertEqual(f.topApps.map { $0.bytes }, [mib(38_912), mib(4096), mib(2048)])
        XCTAssertEqual(f.topApps.map { $0.isApp }, [true, true, false])
        XCTAssertEqual(r.watch.pressureFindingCount, 1)

        r.run(criticalReading, ticks: 40)
        XCTAssertEqual(r.findings.count, 1, "the cooldown and the re-arm keep it to one")
    }

    /// The app's "before" is its total with its biggest process taken back to the oldest point of its ring, and the window
    /// is that ring's span.
    func testTheFindingCarriesHowMuchTheBiggestProcessGrewOverItsRing() {
        let r = PressureRig()
        r.addTypicalMac()
        r.watch.setModes(leaks: true, pressure: true)
        for i in 0..<4 {
            r.machine.setMiB(101, 16_384 + 1024 * Double(i))
            r.tick(criticalReading)
        }
        guard let f = r.findings.first else { return XCTFail("no finding") }
        XCTAssertEqual(f.nowBytes, mib(8192 + 19_456 + 10_240))
        XCTAssertEqual(f.startBytes, mib(8192 + 16_384 + 10_240))
        XCTAssertEqual(f.netGrowthBytes, mib(3072))
        XCTAssertEqual(f.windowSeconds, 15, accuracy: 0.001)
    }

    /// An app's helpers are one app; tools are not apps and are grouped by their executable, never into an app. Only the
    /// largest three are listed.
    func testTheTopAppsSumHelpersUnderOneAppAndKeepToolsSeparate() {
        let r = PressureRig()
        r.addTypicalMac()
        r.machine.add(105, 1024, nodePath)                   // a second node: the same tool
        r.machine.add(106, 3000, "/usr/bin/python3")         // a different tool, fourth in size
        r.watch.setModes(leaks: true, pressure: true)
        r.run(criticalReading, ticks: 4)
        guard let f = r.findings.first else { return XCTFail("no finding") }
        XCTAssertEqual(f.topApps.map { $0.name }, ["Brave Browser", "Safari", "node"],
                       "the two node processes are 3072 MiB together, ahead of python3's 3000 MiB")
        XCTAssertEqual(f.topApps.last?.bytes, mib(3072))
        XCTAssertEqual(f.topApps.last?.isApp, false)
        XCTAssertFalse(f.topApps.contains { $0.name == "python3" }, "only the largest three are listed")
    }

    /// An app nobody wants warnings about is not blamed, however large.
    func testAnIgnoredAppIsNotBlamed() {
        let r = PressureRig()
        r.addTypicalMac()
        r.machine.add(110, 30_000, "/Applications/Big.app/Contents/MacOS/Big")
        r.machine.ignored = ["/Applications/Big.app"]
        r.watch.setModes(leaks: true, pressure: true)
        r.run(criticalReading, ticks: 4)
        guard let f = r.findings.first else { return XCTFail("no finding") }
        XCTAssertEqual(f.name, "Brave Browser")
        XCTAssertFalse(f.topApps.contains { $0.name == "Big" })
    }

    /// One app holding more than half of the RAM for five minutes, with the kernel saying all is well, is a finding of its
    /// own kind.
    func testOneAppAboveHalfTheMemoryIsFoundThroughTheTable() {
        let r = PressureRig()
        r.addTypicalMac()                                    // Brave is 38 of 64 GiB: 59 %
        r.watch.setModes(leaks: true, pressure: true)
        r.run(reading(1), ticks: 62)
        XCTAssertEqual(r.findings.count, 1)
        XCTAssertEqual(r.findings.first?.reason, .oneAppDominates)
        XCTAssertEqual(r.findings.first?.name, "Brave Browser")
        XCTAssertEqual(r.findings.first?.flaggedAtAwake ?? 0, 1300, accuracy: 0.001)
    }

    /// A pressure finding is not a leak finding: it leaves every leak tracker as it was, and the process stays a candidate.
    func testAPressureFindingDoesNotMarkLeakTrackersReported() {
        let r = PressureRig()
        r.addTypicalMac()
        r.watch.setModes(leaks: true, pressure: true)
        r.run(criticalReading, ticks: 4)
        XCTAssertEqual(r.findings.count, 1)
        XCTAssertEqual(r.watch.reportedCount, 0)
        XCTAssertNotEqual(r.watch.phase(of: key(101)), .reported)
        XCTAssertNotEqual(r.watch.slowPhase(of: key(101)), .reported)
        XCTAssertTrue(r.watch.isCandidate(key(101)))
    }

    /// With leak detection off the table is still kept up (the warning needs its sizes) but no leak is ever raised; the
    /// warning still works. The same leaking process, with detection on, is found.
    func testWithLeakDetectionOffNoLeakIsRaisedButThePressureRuleStillRuns() {
        func play(leaks: Bool) -> PressureRig {
            let r = PressureRig()
            r.machine.add(100, 300, "/Applications/Leaky.app/Contents/MacOS/Leaky")
            r.watch.setModes(leaks: leaks, pressure: true)
            for _ in 0..<100 {
                r.machine.setMiB(100, 300 + (r.awake - 1000))
                r.tick(reading(2), step: 2)
            }
            return r
        }
        let on = play(leaks: true)
        XCTAssertEqual(on.findings.filter { $0.tier == .fast }.count, 1, "the process does leak")
        XCTAssertEqual(on.pressureFindings.count, 1)

        let off = play(leaks: false)
        XCTAssertTrue(off.findings.filter { $0.tier != .pressure }.isEmpty)
        XCTAssertEqual(off.pressureFindings.count, 1)
        XCTAssertEqual(off.pressureFindings.first?.reason, .warning)
        XCTAssertEqual(off.pressureFindings.first?.name, "Leaky")
        XCTAssertGreaterThan(off.watch.ringCount, 0, "the table is still kept up")
        XCTAssertEqual(off.watch.slowFeedCount, 0, "no slow tracker was fed")
    }

    /// Switching leak detection back on starts the trackers again behind a quiet period: no window spans the time it was off.
    func testLeakDetectionComesBackQuietly() {
        let r = PressureRig()
        r.machine.add(100, 300, "/Applications/Leaky.app/Contents/MacOS/Leaky")
        r.watch.setModes(leaks: false, pressure: false)
        for _ in 0..<50 {
            r.machine.setMiB(100, 300 + (r.awake - 1000))
            r.tick(nil, step: 2)
        }
        r.watch.setModes(leaks: true, pressure: false)
        r.machine.setMiB(100, 300 + (r.awake - 1000))
        r.tick(nil, step: 2)
        XCTAssertEqual(r.watch.phase(of: key(100)), .quiet)
    }

    /// Turning the warning off forgets its timers: after off and on again it needs its full fifteen seconds again.
    func testTurningTheWarningOffStartsItsTimersAgain() {
        let r = PressureRig()
        r.addTypicalMac()
        r.watch.setModes(leaks: true, pressure: true)
        r.run(criticalReading, ticks: 3)                     // 10 s of 15
        r.watch.setModes(leaks: true, pressure: false)
        r.watch.setModes(leaks: true, pressure: true)
        r.run(criticalReading, ticks: 3)
        XCTAssertTrue(r.findings.isEmpty)
        r.run(criticalReading, ticks: 1)
        XCTAssertEqual(r.findings.count, 1)
    }

    /// A sleep starts the warning's timers again: a verdict comes a full minute after waking, not sooner.
    func testASleepStartsTheWarningsTimersAgain() {
        let r = PressureRig()
        r.addTypicalMac()
        r.watch.setModes(leaks: true, pressure: true)
        r.run(reading(2), ticks: 11)                         // 1000 to 1050: 50 s of 60
        r.awake += 10
        r.wallOffset += 9 * 3600
        let gapAt = r.awake
        r.run(reading(2), ticks: 20)
        XCTAssertEqual(r.findings.count, 1)
        XCTAssertEqual(r.findings.first?.reason, .warning)
        XCTAssertEqual(r.findings.first?.flaggedAtAwake ?? 0, gapAt + 60, accuracy: 0.001)
    }

    /// When a verdict fires, no more than 64 paths are read to name the apps; processes whose path is already known cost
    /// nothing, and the finding is still raised from what was read.
    func testAtMostSixtyFourPathsAreReadWhenAVerdictFires() {
        let r = PressureRig()
        // 150 processes of 120 MiB and a little more: big enough to be grouped, too small to be candidates.
        for i in 0..<150 {
            r.machine.add(pid_t(1000 + i), 120 + Double(i) * 0.1, "/Applications/App\(i).app/Contents/MacOS/App\(i)")
        }
        r.watch.setModes(leaks: true, pressure: true)
        r.tick(nil)
        XCTAssertEqual(r.machine.pathReads, 0, "discovery reads no path for a process that is not a candidate")
        r.run(criticalReading, ticks: 4)
        XCTAssertEqual(r.machine.pathReads, 64)
        XCTAssertEqual(r.findings.count, 1)
        XCTAssertEqual(r.findings.first?.name, "App149", "the largest processes are looked up first")
        XCTAssertEqual(r.findings.first?.topApps.count, 3)
    }

    /// The per-tick path leaves the table alone and raises nothing on calm readings, however many times it runs.
    func testIngestSystemOnCalmReadingsLeavesTheTableAloneAndRaisesNothing() {
        let r = PressureRig()
        r.machine.add(103, 4096, safariPath)
        r.machine.add(104, 2048, nodePath)
        r.watch.setModes(leaks: true, pressure: true)
        r.tick(reading(1))
        let keys = Set(r.watch.candidateKeys)
        let rings = r.watch.ringCount
        XCTAssertEqual(keys.count, 2)

        let calm = reading(1)
        var t = r.awake
        for _ in 0..<100_000 {
            r.watch.ingestSystem(calm, awake: t, wall: Date(timeIntervalSinceReferenceDate: t))
            t += 2
        }
        XCTAssertTrue(r.findings.isEmpty)
        XCTAssertEqual(r.watch.pressureFindingCount, 0)
        XCTAssertEqual(Set(r.watch.candidateKeys), keys)
        XCTAssertEqual(r.watch.ringCount, rings, "the system tick feeds no ring")
    }

    /// `reset()` forgets the warning with the rest.
    func testResetForgetsTheWarning() {
        let r = PressureRig()
        r.addTypicalMac()
        r.watch.setModes(leaks: true, pressure: true)
        r.run(criticalReading, ticks: 4)
        XCTAssertEqual(r.watch.pressureFindingCount, 1)
        r.watch.reset()
        XCTAssertEqual(r.watch.pressureFindingCount, 0)
        r.run(criticalReading, ticks: 4)
        XCTAssertEqual(r.findings.count, 2, "its cooldown went with the reset")
    }
}


/// The defaults follow macOS's own pressure graph and nothing else: orange held two minutes warns, red held 15 seconds is
/// critical, and neither swap nor one big app raises an alert by itself.
final class PressureOnlyDefaultsTests: XCTestCase {

    private func feeder() -> PressureFeeder2 { PressureFeeder2() }

    func testTheDefaultsWatchOnlyThePressureLevel() {
        let r = PressureRules.standard
        XCTAssertFalse(r.watchesSwap)
        XCTAssertFalse(r.watchesDominantApp)
        XCTAssertEqual(r.warningSeconds, 120)
        XCTAssertEqual(r.criticalSeconds, 15)
    }

    /// A build or a test run: orange for a minute and a half, then back to green. Nothing to say.
    func testOrangeForAMinuteAndAHalfIsNotWarnedAbout() {
        var f = feeder()
        f.hold(reading(2), from: 0, through: 100)
        f.hold(reading(1), from: 105, through: 400)
        XCTAssertTrue(f.found.isEmpty)
    }

    func testOrangeHeldTwoMinutesWarnsOnceAsAWarning() {
        var f = feeder()
        f.hold(reading(2), from: 0, through: 300)
        XCTAssertEqual(f.found.map(\.verdict.reason), [.warning])
        XCTAssertEqual(f.found.first?.t ?? 0, 120, accuracy: 0.001)
    }

    func testRedHeldFifteenSecondsIsCritical() {
        var f = feeder()
        f.hold(reading(4), from: 0, through: 60)
        XCTAssertEqual(f.found.map(\.verdict.reason), [.critical])
        XCTAssertEqual(f.found.first?.t ?? 0, 15, accuracy: 0.001)
    }

    /// Normal pressure never alerts, however much swap is in use or however big one app is.
    func testSwapAndOneBigAppAloneNeverAlert() {
        var f = feeder()
        f.hold(reading(1, swap: 40 * gib, total: 64 * gib), top: 50 * gib, from: 0, through: 3600)
        XCTAssertTrue(f.found.isEmpty, "the pressure level was green the whole time")
    }
}

private struct PressureFeeder2 {
    var tracker = PressureTracker()
    var found: [(t: Double, verdict: PressureVerdict)] = []
    mutating func hold(_ r: SystemMemoryReading, top: UInt64 = gib, from: Double, through end: Double, step: Double = 5) {
        var t = from
        while t <= end {
            if let v = tracker.ingest(r, topAppBytes: top, at: t) { found.append((t: t, verdict: v)) }
            t += step
        }
    }
}

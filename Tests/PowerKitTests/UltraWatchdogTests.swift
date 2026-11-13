import XCTest
@testable import AnodeApp
@testable import PowerKit

/// The watchdog's decisions: what its command line means, what it undoes from the record, and how it waits for Anode to
/// end. Nothing here starts a watchdog, sends a signal to a process or touches the screen: the freezer, the backlight
/// and the record store are fakes. The wait is tried on a short-lived `sleep` of the test's own, which it only watches.
final class UltraWatchdogTests: XCTestCase {

    // ── Fakes ───────────────────────────────────────────────────────────────

    /// One list of calls shared by several fakes, so a test can say which came first.
    private final class CallLog {
        var entries: [String] = []
    }

    private final class FakeFreezer: ProcessFreezing {
        struct Call: Equatable {
            var pid: pid_t
            var startTime: UInt64
        }
        var stopped: [Call] = []
        var resumed: [Call] = []
        private let log: CallLog?
        init(log: CallLog? = nil) { self.log = log }
        func stop(pid: pid_t, startTime: UInt64) -> Bool {
            stopped.append(Call(pid: pid, startTime: startTime))
            log?.entries.append("stop \(pid)")
            return true
        }
        func resume(pid: pid_t, startTime: UInt64) -> Bool {
            resumed.append(Call(pid: pid, startTime: startTime))
            log?.entries.append("resume \(pid)@\(startTime)")
            return true
        }
    }

    private final class FakeThrottler: ProcessThrottling {
        struct Call: Equatable {
            var pid: pid_t
            var startTime: UInt64
        }
        var throttled: [Call] = []
        var lifted: [Call] = []
        private let log: CallLog?
        init(log: CallLog? = nil) { self.log = log }
        func throttle(pid: pid_t, startTime: UInt64) -> ThrottleResult {
            throttled.append(Call(pid: pid, startTime: startTime))
            log?.entries.append("throttle \(pid)")
            return .done
        }
        func unthrottle(pid: pid_t, startTime: UInt64) -> Bool {
            lifted.append(Call(pid: pid, startTime: startTime))
            log?.entries.append("unthrottle \(pid)@\(startTime)")
            return true
        }
    }

    private final class FakeBacklight: BacklightControl {
        var value: Float?
        var reads = 0
        var sets: [Float] = []
        private let log: CallLog?
        init(_ value: Float?, log: CallLog? = nil) { self.value = value; self.log = log }
        func brightness() -> Float? { reads += 1; log?.entries.append("brightness()"); return value }
        func setBrightness(_ v: Float) -> Bool { sets.append(v); log?.entries.append("setBrightness(\(v))"); value = v; return true }
    }

    /// A watchdog process that is a few values and nothing else: no process is started or ended.
    private final class FakeWatchdogProcess: WatchdogProcess {
        let pid: pid_t
        var isRunning: Bool
        var terminated = 0
        init(pid: pid_t, isRunning: Bool = true) { self.pid = pid; self.isRunning = isRunning }
        func terminate() { terminated += 1; isRunning = false }
    }

    private struct LaunchRefused: Error {}

    private final class FakeStore: UltraRecordStoring {
        var record: UltraRecord?
        var loads = 0
        var saves = 0
        var clears = 0
        init(_ record: UltraRecord?) { self.record = record }
        func load() -> UltraRecord? { loads += 1; return record }
        func save(_ record: UltraRecord) -> Bool { saves += 1; return true }
        func clear() { clears += 1 }
    }

    /// Two groups still frozen (one with an app that was hidden), one already released, and every setting changed. The
    /// kept app's processes (70, 71) and the released group's (600) are under the background policy.
    private func sessionRecord(brightnessBefore: Float? = 0.8) -> UltraRecord {
        var record = UltraRecord()
        record.groups = [
            .init(id: "com.example.browser", name: "Browser",
                  members: [.init(pid: 400, startTime: 4_000), .init(pid: 401, startTime: 4_010)], appPID: 400),
            .init(id: "com.example.sync", name: "Sync", members: [.init(pid: 500, startTime: 5_000)]),
            .init(id: "com.example.mail", name: "Mail", members: [.init(pid: 600, startTime: 6_000)], released: true),
        ]
        record.brightnessBefore = brightnessBefore
        record.rateLowered = true
        record.keyboardBefore = 0.4
        record.powerModeBefore = 0
        record.throttled = [.init(pid: 70, startTime: 7_000), .init(pid: 71, startTime: 7_010), .init(pid: 600, startTime: 6_000)]
        return record
    }

    /// One row of the process table as the walk down the children reads it: pid, parent and start time.
    private func row(_ pid: pid_t, parent: pid_t, startTime: UInt64? = nil) -> UltraProcess {
        UltraProcess(pid: pid, parent: parent, uid: 501, startTime: startTime ?? UInt64(pid) * 100, path: "", name: "p\(pid)")
    }

    /// The kept app's processes (70, 71, as the record has them) and, born since the last sweep, a child of 70 (72) with a child of
    /// its own (73), and a stranger. The children inherited the policy and are on no record.
    private var tableWithChildren: [UltraProcess] {
        [row(70, parent: 1, startTime: 7_000), row(71, parent: 1, startTime: 7_010), row(72, parent: 70), row(73, parent: 72),
         row(90, parent: 1)]
    }

    // ── The command line ────────────────────────────────────────────────────

    func testWatchdogArgumentsAreParsed() throws {
        let request = try XCTUnwrap(UltraWatchdog.parse(["Anode", "--ultra-watchdog", "123", "/x/y.json"]))
        XCTAssertEqual(request.parent, 123)
        XCTAssertEqual(request.recordPath, "/x/y.json")
        let spaced = try XCTUnwrap(UltraWatchdog.parse(["/A/Anode", "--ultra-watchdog", "7", "/Users/a b/Library/u.json"]))
        XCTAssertEqual(spaced.recordPath, "/Users/a b/Library/u.json")
    }

    func testAnythingElseIsNotAWatchdogRequest() {
        let bad: [[String]] = [
            [],
            ["Anode"],
            ["Anode", "--ultra-watchdog"],
            ["Anode", "--ultra-watchdog", "123"],
            ["Anode", "--ultra-watchdog", "123", "/x/y.json", "extra"],
            ["Anode", "--ultra-watchdog", "abc", "/x/y.json"],
            ["Anode", "--ultra-watchdog", "12.5", "/x/y.json"],
            ["Anode", "--ultra-watchdog", "0", "/x/y.json"],
            ["Anode", "--ultra-watchdog", "1", "/x/y.json"],
            ["Anode", "--ultra-watchdog", "-5", "/x/y.json"],
            ["Anode", "--ultra-watchdog", "99999999999", "/x/y.json"],
            ["Anode", "--ultra-watchdog", "123", ""],
            ["Anode", "123", "/x/y.json"],
            ["--ultra-watchdog", "123", "/x/y.json"],
            ["Anode", "--restore-charge-settings"],
        ]
        for arguments in bad {
            XCTAssertNil(UltraWatchdog.parse(arguments), "\(arguments)")
        }
    }

    func testTheLauncherAndTheParserAgree() throws {
        let url = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Anode/ultra-record.json")
        let arguments = LiveUltraWatchdog.arguments(parent: 4242, recordURL: url)
        XCTAssertEqual(arguments.first, "--ultra-watchdog")
        // The program's own path comes first in `CommandLine.arguments`, which is what the parser is given.
        let request = try XCTUnwrap(UltraWatchdog.parse(["/Applications/Anode.app/Contents/MacOS/Anode"] + arguments))
        XCTAssertEqual(request.parent, 4242)
        XCTAssertEqual(request.recordPath, url.path)
    }

    func testWithoutTheFlagTheAppStartsAsUsual() {
        // Returns at once. With the flag it would wait for a process to end and then exit, which is not run here.
        UltraWatchdog.runIfRequested(["Anode"])
        UltraWatchdog.runIfRequested(["Anode", "--restore-charge-settings"])
    }

    // ── What it undoes ──────────────────────────────────────────────────────

    func testUndoResumesWhatTheRecordNamesAndRestoresBrightness() {
        let freezer = FakeFreezer()
        let throttler = FakeThrottler()
        let panel = FakeBacklight(BrightnessCeiling.ceiling)   // still where the mode left it
        UltraWatchdog.undo(record: sessionRecord(), freezer: freezer, throttler: throttler, processTable: { nil }, backlight: panel)

        // Every member of the groups still frozen, by pid AND start time; a released group is not continued again.
        XCTAssertEqual(freezer.resumed, [.init(pid: 400, startTime: 4_000), .init(pid: 401, startTime: 4_010),
                                         .init(pid: 500, startTime: 5_000)])
        XCTAssertTrue(freezer.stopped.isEmpty)
        XCTAssertEqual(panel.sets, [0.8])
    }

    /// Whatever the record says was put under the policy is lifted by pid AND start time, whether or not its group was
    /// released; nothing is ever put under it by the watchdog.
    func testUndoLiftsThePolicyFromEveryProcessTheRecordNames() {
        let throttler = FakeThrottler()
        UltraWatchdog.undo(record: sessionRecord(), freezer: FakeFreezer(), throttler: throttler, processTable: { nil }, backlight: FakeBacklight(BrightnessCeiling.ceiling))
        XCTAssertEqual(throttler.lifted, [.init(pid: 70, startTime: 7_000), .init(pid: 71, startTime: 7_010),
                                          .init(pid: 600, startTime: 6_000)])
        XCTAssertTrue(throttler.throttled.isEmpty)
    }

    func testARecordThatNamesNothingUnderThePolicyLiftsNothing() {
        let throttler = FakeThrottler()
        var record = sessionRecord()
        record.throttled = nil
        UltraWatchdog.undo(record: record, freezer: FakeFreezer(), throttler: throttler, processTable: { nil }, backlight: FakeBacklight(BrightnessCeiling.ceiling))
        record.throttled = []
        UltraWatchdog.undo(record: record, freezer: FakeFreezer(), throttler: throttler, processTable: { nil }, backlight: FakeBacklight(BrightnessCeiling.ceiling))
        UltraWatchdog.undo(record: UltraRecord(), freezer: FakeFreezer(), throttler: throttler, processTable: { nil }, backlight: FakeBacklight(BrightnessCeiling.ceiling))
        XCTAssertTrue(throttler.lifted.isEmpty)
    }

    /// The policy comes off even when there is no brightness to put back: the backlight is not what decides it.
    func testThePolicyIsLiftedWhenThereIsNoBrightnessToPutBack() {
        let throttler = FakeThrottler()
        UltraWatchdog.undo(record: sessionRecord(brightnessBefore: nil), freezer: FakeFreezer(), throttler: throttler, processTable: { nil },
                           backlight: FakeBacklight(BrightnessCeiling.ceiling))
        XCTAssertEqual(throttler.lifted.count, 3)
    }

    /// A child started after the last sweep inherited the policy and is on no record: the watchdog finds it in a table it reads
    /// itself, when it undoes, and lifts the policy from it too. A stranger is not touched.
    func testAChildBornAfterTheLastSweepIsLiftedByTheWatchdogToo() {
        let throttler = FakeThrottler()
        UltraWatchdog.undo(record: sessionRecord(), freezer: FakeFreezer(), throttler: throttler,
                           processTable: { self.tableWithChildren }, backlight: FakeBacklight(BrightnessCeiling.ceiling))
        XCTAssertEqual(throttler.lifted, [.init(pid: 70, startTime: 7_000), .init(pid: 71, startTime: 7_010),
                                          .init(pid: 600, startTime: 6_000), .init(pid: 72, startTime: 7_200),
                                          .init(pid: 73, startTime: 7_300)],
                       "what the record names, then every living child of one of them, by the start time the table says")
    }

    /// A recorded pid that has been recycled is another process: it is not a root, and what is its child is not walked.
    func testTheChildrenOfARecycledPidAreNotWalked() {
        let throttler = FakeThrottler()
        let table = [row(70, parent: 1, startTime: 9_999), row(72, parent: 70), row(71, parent: 1, startTime: 7_010), row(74, parent: 71)]
        UltraWatchdog.undo(record: sessionRecord(), freezer: FakeFreezer(), throttler: throttler, processTable: { table },
                           backlight: FakeBacklight(BrightnessCeiling.ceiling))
        XCTAssertFalse(throttler.lifted.contains { $0.pid == 72 }, "the child of a process that is not the recorded one")
        XCTAssertTrue(throttler.lifted.contains(.init(pid: 74, startTime: 7_400)), "the child of the one that is")
    }

    func testAParentCycleInTheTableEndsTheWalk() {
        let throttler = FakeThrottler()
        let table = [row(70, parent: 72, startTime: 7_000), row(72, parent: 70), row(71, parent: 71, startTime: 7_010)]
        UltraWatchdog.undo(record: sessionRecord(), freezer: FakeFreezer(), throttler: throttler, processTable: { table },
                           backlight: FakeBacklight(BrightnessCeiling.ceiling))
        XCTAssertEqual(throttler.lifted.filter { $0.pid == 72 }.count, 1)
    }

    /// A table that cannot be read leaves the recorded processes lifted all the same.
    func testATableThatCannotBeReadStillLiftsWhatTheRecordNames() {
        let throttler = FakeThrottler()
        UltraWatchdog.undo(record: sessionRecord(), freezer: FakeFreezer(), throttler: throttler, processTable: { nil },
                           backlight: FakeBacklight(BrightnessCeiling.ceiling))
        XCTAssertEqual(throttler.lifted.count, 3)
    }

    /// With nothing under the policy there is no walk and no table to read.
    func testTheTableIsReadOnlyWhenTheRecordNamesProcessesUnderThePolicy() {
        var reads = 0
        var record = sessionRecord()
        record.throttled = nil
        UltraWatchdog.undo(record: record, freezer: FakeFreezer(), throttler: FakeThrottler(),
                           processTable: { reads += 1; return nil }, backlight: FakeBacklight(BrightnessCeiling.ceiling))
        UltraWatchdog.undo(record: UltraRecord(), freezer: FakeFreezer(), throttler: FakeThrottler(),
                           processTable: { reads += 1; return nil }, backlight: FakeBacklight(BrightnessCeiling.ceiling))
        XCTAssertEqual(reads, 0)
    }

    func testUndoLeavesTheBrightnessAloneWhenTheOwnerMovedIt() {
        let freezer = FakeFreezer()
        let dimmer = FakeBacklight(0.15)
        UltraWatchdog.undo(record: sessionRecord(), freezer: freezer, throttler: FakeThrottler(), processTable: { nil }, backlight: dimmer)
        XCTAssertTrue(dimmer.sets.isEmpty, "the owner went dimmer: not the mode's to change")
        XCTAssertEqual(freezer.resumed.count, 3, "the processes are continued all the same")

        let unreadable = FakeBacklight(nil)
        UltraWatchdog.undo(record: sessionRecord(), freezer: FakeFreezer(), throttler: FakeThrottler(), processTable: { nil }, backlight: unreadable)
        XCTAssertTrue(unreadable.sets.isEmpty, "no way to tell the owner did not go dimmer")
    }

    func testUndoWithNoRecordDoesNothing() {
        // No record on disk.
        let missing = FakeStore(nil)
        let freezer = FakeFreezer()
        let panel = FakeBacklight(BrightnessCeiling.ceiling)
        let throttler = FakeThrottler()
        UltraWatchdog.undo(from: missing, freezer: freezer, throttler: throttler, processTable: { nil }, backlight: panel)
        XCTAssertEqual(missing.loads, 1)
        XCTAssertTrue(freezer.resumed.isEmpty)
        XCTAssertTrue(throttler.lifted.isEmpty)
        XCTAssertTrue(freezer.stopped.isEmpty)
        XCTAssertTrue(panel.sets.isEmpty)
        XCTAssertEqual(missing.clears, 0)

        // A record of a session that changed nothing.
        UltraWatchdog.undo(record: UltraRecord(), freezer: freezer, throttler: throttler, processTable: { nil }, backlight: panel)
        XCTAssertTrue(freezer.resumed.isEmpty)
        XCTAssertTrue(throttler.lifted.isEmpty)
        XCTAssertTrue(panel.sets.isEmpty)
    }

    func testUndoReadsTheRecordFromTheStoreAndLeavesItForTheNextLaunch() {
        let store = FakeStore(sessionRecord())
        let freezer = FakeFreezer()
        UltraWatchdog.undo(from: store, freezer: freezer, throttler: FakeThrottler(), processTable: { nil }, backlight: FakeBacklight(BrightnessCeiling.ceiling))
        XCTAssertEqual(freezer.resumed.count, 3)
        // The next launch reads the record to finish what the watchdog does not do (unhide, rate, keyboard, power mode).
        XCTAssertEqual(store.clears, 0)
        XCTAssertEqual(store.saves, 0)
        XCTAssertEqual(store.record, sessionRecord())
    }

    func testUndoResumesEveryProcessAndLiftsThePolicyFromThemAndTheirChildrenBeforeTouchingTheBacklight() {
        // The Mac is least responsive when Anode died with the lid shut or the display asleep; the backlight's start-up
        // and its first read must not hold up a single continue, nor a process left slow.
        let log = CallLog()
        let freezer = FakeFreezer(log: log)
        let throttler = FakeThrottler(log: log)
        let panel = FakeBacklight(BrightnessCeiling.ceiling, log: log)
        func makePanel() -> BacklightControl { log.entries.append("backlight built"); return panel }
        UltraWatchdog.undo(from: FakeStore(sessionRecord()), freezer: freezer, throttler: throttler,
                           processTable: { log.entries.append("table read"); return self.tableWithChildren }, backlight: makePanel())
        XCTAssertEqual(log.entries, ["resume 400@4000", "resume 401@4010", "resume 500@5000",
                                     "unthrottle 70@7000", "unthrottle 71@7010", "unthrottle 600@6000",
                                     "table read", "unthrottle 72@7200", "unthrottle 73@7300",
                                     "backlight built", "brightness()", "setBrightness(0.8)"])
    }

    func testTheBacklightIsNeverBuiltWhenThereIsNoBrightnessToPutBack() {
        var built = 0
        func makePanel() -> BacklightControl { built += 1; return FakeBacklight(BrightnessCeiling.ceiling) }
        let freezer = FakeFreezer()
        UltraWatchdog.undo(from: FakeStore(sessionRecord(brightnessBefore: nil)), freezer: freezer, throttler: FakeThrottler(), processTable: { nil },
                           backlight: makePanel())
        XCTAssertEqual(freezer.resumed.count, 3)
        UltraWatchdog.undo(from: FakeStore(nil), freezer: freezer, throttler: FakeThrottler(), processTable: { nil }, backlight: makePanel())
        XCTAssertEqual(built, 0)
    }

    // ── Waiting for Anode to end ────────────────────────────────────────────

    func testTheWaitEndsWhenTheProcessEnds() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["0.4"]
        try child.run()
        let began = Date()
        XCTAssertEqual(UltraWatchdog.waitForExit(of: child.processIdentifier, timeout: 10), .exited)
        XCTAssertGreaterThan(Date().timeIntervalSince(began), 0.25, "not before it ended")
        child.waitUntilExit()

        // Gone for good now: a watchdog started after Anode died undoes at once instead of waiting for nothing.
        let again = Date()
        XCTAssertEqual(UltraWatchdog.waitForExit(of: child.processIdentifier, timeout: 10), .exited)
        XCTAssertLessThan(Date().timeIntervalSince(again), 2)
    }

    func testTheWaitDoesNotEndWhileTheProcessLives() {
        // This test process lives for as long as the wait does.
        XCTAssertEqual(UltraWatchdog.waitForExit(of: getpid(), timeout: 0.2), .timedOut)
    }

    func testAParentThatIsNoLongerTheOneGivenCountsAsGone() {
        XCTAssertFalse(UltraWatchdog.parentHasEnded(given: 123, current: 123))
        // An orphan is re-parented: to launchd when its parent ended, and a pid reused since is not the parent either.
        XCTAssertTrue(UltraWatchdog.parentHasEnded(given: 123, current: 1))
        XCTAssertTrue(UltraWatchdog.parentHasEnded(given: 123, current: 456))
    }

    func testTheWaitAsksOnceTheEventIsRegisteredWhetherItIsStillTheParent() {
        // Not the parent any more: gone, though the process watched lives (this test process).
        XCTAssertEqual(UltraWatchdog.waitForExit(of: getpid(), timeout: 5, confirm: { false }), .exited)
        // Still the parent: the wait goes on.
        XCTAssertEqual(UltraWatchdog.waitForExit(of: getpid(), timeout: 0.1, confirm: { true }), .timedOut)
    }

    // ── Starting and stopping it from Anode ─────────────────────────────────

    private let recordURL = URL(fileURLWithPath: "/x/y.json")

    func testAWatchdogThatFailsToLaunchIsReportedAsNotStarted() {
        var attempts = 0
        var logged: [String] = []
        let watchdog = LiveUltraWatchdog(recordURL: recordURL, log: { logged.append($0) },
                                         launch: { _ in attempts += 1; throw LaunchRefused() })
        XCTAssertFalse(watchdog.start())
        XCTAssertNil(watchdog.pid)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(logged.count, 1, "said, not silent")
    }

    func testAWatchdogThatLaunchesIsReportedWithItsPid() throws {
        var given: [String] = []
        let watchdog = LiveUltraWatchdog(recordURL: recordURL, launch: { arguments in
            given = arguments
            return FakeWatchdogProcess(pid: 4321)
        })
        XCTAssertTrue(watchdog.start())
        XCTAssertEqual(watchdog.pid, 4321)
        // Started for this process and this record.
        let request = try XCTUnwrap(UltraWatchdog.parse(["Anode"] + given))
        XCTAssertEqual(request.parent, getpid())
        XCTAssertEqual(request.recordPath, "/x/y.json")
    }

    func testAProcessThatIsNotRunningRightAfterTheLaunchIsNotAStartedWatchdog() {
        let watchdog = LiveUltraWatchdog(recordURL: recordURL, launch: { _ in FakeWatchdogProcess(pid: 4321, isRunning: false) })
        XCTAssertFalse(watchdog.start())
        XCTAssertNil(watchdog.pid)
    }

    func testStartingTwiceLaunchesOnce() {
        var launched = 0
        let watchdog = LiveUltraWatchdog(recordURL: recordURL, launch: { _ in launched += 1; return FakeWatchdogProcess(pid: 4321) })
        XCTAssertTrue(watchdog.start())
        XCTAssertTrue(watchdog.start(), "one is running: that counts")
        XCTAssertEqual(launched, 1)
        XCTAssertEqual(watchdog.pid, 4321)
    }

    func testAWatchdogThatEndedByItselfIsStartedAgain() {
        var launched: [FakeWatchdogProcess] = []
        let watchdog = LiveUltraWatchdog(recordURL: recordURL, launch: { _ in
            let process = FakeWatchdogProcess(pid: pid_t(4000 + launched.count))
            launched.append(process)
            return process
        })
        XCTAssertTrue(watchdog.start())
        launched[0].isRunning = false
        XCTAssertNil(watchdog.pid, "none runs now")
        XCTAssertTrue(watchdog.start())
        XCTAssertEqual(launched.count, 2)
        XCTAssertEqual(watchdog.pid, 4001)
    }

    func testStopEndsItAndForgetsItsPid() {
        let process = FakeWatchdogProcess(pid: 4321)
        let watchdog = LiveUltraWatchdog(recordURL: recordURL, launch: { _ in process })
        watchdog.stop()                      // none runs yet: nothing to do
        XCTAssertEqual(process.terminated, 0)
        XCTAssertTrue(watchdog.start())
        watchdog.stop()
        XCTAssertEqual(process.terminated, 1)
        XCTAssertNil(watchdog.pid)
        watchdog.stop()
        XCTAssertEqual(process.terminated, 1, "not twice")
    }

    func testStopLeavesAProcessThatEndedAloneAndStillForgetsIt() {
        let process = FakeWatchdogProcess(pid: 4321)
        let watchdog = LiveUltraWatchdog(recordURL: recordURL, launch: { _ in process })
        XCTAssertTrue(watchdog.start())
        process.isRunning = false
        watchdog.stop()
        XCTAssertEqual(process.terminated, 0, "ended already: no signal to a pid that may mean something else now")
        XCTAssertNil(watchdog.pid)
    }
}

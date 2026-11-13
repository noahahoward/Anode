import XCTest
@testable import AnodeApp
@testable import PowerKit

/// The watchdog's decisions: what its command line means, what it undoes from the record, and how it waits for Anode to
/// end. Nothing here starts a watchdog, sends a signal to a process or touches the screen: the freezer, the backlight
/// and the record store are fakes. The wait is tried on a short-lived `sleep` of the test's own, which it only watches.
final class UltraWatchdogTests: XCTestCase {

    // ── Fakes ───────────────────────────────────────────────────────────────

    private final class FakeFreezer: ProcessFreezing {
        struct Call: Equatable {
            var pid: pid_t
            var startTime: UInt64
        }
        var stopped: [Call] = []
        var resumed: [Call] = []
        func stop(pid: pid_t, startTime: UInt64) -> Bool { stopped.append(Call(pid: pid, startTime: startTime)); return true }
        func resume(pid: pid_t, startTime: UInt64) -> Bool { resumed.append(Call(pid: pid, startTime: startTime)); return true }
    }

    private final class FakeBacklight: BacklightControl {
        var value: Float?
        var reads = 0
        var sets: [Float] = []
        init(_ value: Float?) { self.value = value }
        func brightness() -> Float? { reads += 1; return value }
        func setBrightness(_ v: Float) -> Bool { sets.append(v); value = v; return true }
    }

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

    /// Two groups still frozen (one with an app that was hidden), one already released, and every setting changed.
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
        return record
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
        let panel = FakeBacklight(BrightnessCeiling.ceiling)   // still where the mode left it
        UltraWatchdog.undo(record: sessionRecord(), freezer: freezer, backlight: panel)

        // Every member of the groups still frozen, by pid AND start time; a released group is not continued again.
        XCTAssertEqual(freezer.resumed, [.init(pid: 400, startTime: 4_000), .init(pid: 401, startTime: 4_010),
                                         .init(pid: 500, startTime: 5_000)])
        XCTAssertTrue(freezer.stopped.isEmpty)
        XCTAssertEqual(panel.sets, [0.8])
    }

    func testUndoLeavesTheBrightnessAloneWhenTheOwnerMovedIt() {
        let freezer = FakeFreezer()
        let dimmer = FakeBacklight(0.3)
        UltraWatchdog.undo(record: sessionRecord(), freezer: freezer, backlight: dimmer)
        XCTAssertTrue(dimmer.sets.isEmpty, "the owner went dimmer: not the mode's to change")
        XCTAssertEqual(freezer.resumed.count, 3, "the processes are continued all the same")

        let unreadable = FakeBacklight(nil)
        UltraWatchdog.undo(record: sessionRecord(), freezer: FakeFreezer(), backlight: unreadable)
        XCTAssertTrue(unreadable.sets.isEmpty, "no way to tell the owner did not go dimmer")
    }

    func testUndoWithNoRecordDoesNothing() {
        // No record on disk.
        let missing = FakeStore(nil)
        let freezer = FakeFreezer()
        let panel = FakeBacklight(0.5)
        UltraWatchdog.undo(from: missing, freezer: freezer, backlight: panel)
        XCTAssertEqual(missing.loads, 1)
        XCTAssertTrue(freezer.resumed.isEmpty)
        XCTAssertTrue(freezer.stopped.isEmpty)
        XCTAssertTrue(panel.sets.isEmpty)
        XCTAssertEqual(missing.clears, 0)

        // A record of a session that changed nothing.
        UltraWatchdog.undo(record: UltraRecord(), freezer: freezer, backlight: panel)
        XCTAssertTrue(freezer.resumed.isEmpty)
        XCTAssertTrue(panel.sets.isEmpty)
    }

    func testUndoReadsTheRecordFromTheStoreAndLeavesItForTheNextLaunch() {
        let store = FakeStore(sessionRecord())
        let freezer = FakeFreezer()
        UltraWatchdog.undo(from: store, freezer: freezer, backlight: FakeBacklight(0.5))
        XCTAssertEqual(freezer.resumed.count, 3)
        // The next launch reads the record to finish what the watchdog does not do (unhide, rate, keyboard, power mode).
        XCTAssertEqual(store.clears, 0)
        XCTAssertEqual(store.saves, 0)
        XCTAssertEqual(store.record, sessionRecord())
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
}

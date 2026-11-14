import XCTest
@testable import AnodeApp
@testable import PowerKit

/// Charge Control's watchdog: an Anode that ends without quitting has macOS's own charge settings put back at once,
/// not when Anode is next opened.
///
/// Nothing here starts a process, sends a signal or touches the real Mac: the launcher and the signal are closures the
/// test gives, macOS is `FakeChargeLimitClient`, the helper is `FakeHelperLink`, and the shared record is a file in a
/// temporary folder (never `/Users/Shared`).
final class ChargeWatchdogTests: XCTestCase {

    private final class FakeProcess: WatchdogProcess {
        let pid: pid_t
        var isRunning: Bool
        var terminated = 0
        init(pid: pid_t, isRunning: Bool = true) {
            self.pid = pid
            self.isRunning = isRunning
        }
        func terminate() { terminated += 1 }
    }

    private struct LaunchRefused: Error {}

    private final class FakeWatchdog: ChargeWatchdogging {
        var starts = 0
        var stops = 0
        var startsWork = true
        var onStart: (() -> Void)?
        func start() -> Bool {
            starts += 1
            onStart?()
            return startsWork
        }
        func stop() { stops += 1 }
    }

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var settings: Settings!
    private var client: FakeChargeLimitClient!
    private var helper: FakeHelperLink!
    private var lines: [String] = []
    private var watchdog: FakeWatchdog!
    private var controller: ChargeController?
    private var directory: String!
    private var live: Set<Int32> = []

    /// What macOS says before Charge Control has touched it.
    private let found = NativeChargeState(mclEnabled: true, mclLimit: 90, optimizedChargingEnabled: true)

    override func setUpWithError() throws {
        (defaults, suiteName) = try TestDefaults.make(owner: "ChargeWatchdog", test: name)
        settings = Settings(defaults: defaults)
        client = FakeChargeLimitClient(state: found)
        helper = FakeHelperLink()
        lines = []
        watchdog = FakeWatchdog()
        live = []
        directory = NSTemporaryDirectory() + "cc-watchdog-\(UUID().uuidString.prefix(8))/Anode"
        try FileManager.default.createDirectory(atPath: (directory as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        controller?.shutdown()
        controller = nil
        settings = nil
        TestDefaults.destroy(defaults, suiteName)
        try? FileManager.default.removeItem(atPath: (directory as NSString).deletingLastPathComponent)
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    @discardableResult
    private func make(enabled: Bool = true, records: ChargeRecords? = nil, clientToMake: ChargeLimitClient?? = nil,
                      liftedAtLaunch: Bool = false) -> ChargeController {
        settings.chargeControlEnabled = enabled
        let made: ChargeLimitClient? = clientToMake ?? client
        let c = ChargeController(settings: settings, records: records, makeClient: { made }, helper: helper,
                                 battery: { ChargeControllerTests.state(70) }, chargerSwitch: { nil },
                                 log: { [weak self] in self?.lines.append($0) }, workspace: NotificationCenter(),
                                 limitInForce: ChargeLimitInForce(), liftedAtLaunch: liftedAtLaunch,
                                 onConsole: { true }, watchdog: watchdog)
        controller = c
        return c
    }

    /// The process dies: nothing runs, nothing is put back, and the watchdog is never told to stop.
    private func crash() {
        controller = nil
    }

    private func liftAfterAnodeEnded(pid: Int32 = 4242, records: ChargeRecords? = nil,
                                     wait: (TimeInterval) -> Void = { _ in }) -> Bool {
        ChargeController.liftAfterAnodeEnded(pid: pid, settings: settings, records: records,
                                             makeClient: { [client] in client }, helper: { [helper] in helper! },
                                             log: { [weak self] in self?.lines.append($0) }, wait: wait)
    }

    private func store(uid: UInt32 = 501, pid: Int32, lockTimeout: TimeInterval = 3) -> ChargeRecordStore {
        ChargeRecordStore(directory: directory, uid: uid, pid: pid, isLive: { [unowned self] in live.contains($0) },
                          lockTimeout: lockTimeout)
    }

    private func sharedRecords(uid: UInt32 = 501, pid: Int32, lockTimeout: TimeInterval = 3) -> ChargeRecords {
        ChargeRecords(settings: settings, store: store(uid: uid, pid: pid, lockTimeout: lockTimeout),
                      log: { [weak self] in self?.lines.append($0) })
    }

    /// An Anode of this account, process `pid`, holding `limit` through the shared record.
    private func holding(limit: Int = 85, pid: Int32) {
        settings.chargeLimit = limit
        live.insert(pid)
        make(records: sharedRecords(pid: pid))
        XCTAssertEqual(client.state?.mclLimit, limit, "the run did not hold its limit")
    }

    // ── The command line ────────────────────────────────────────────────────

    func testWatchdogArgumentsAreParsed() {
        XCTAssertEqual(ChargeWatchdog.parse(["Anode", "--charge-watchdog", "123"]), 123)
    }

    func testAnythingElseIsNotAWatchdogRequest() {
        XCTAssertNil(ChargeWatchdog.parse(["Anode"]))
        XCTAssertNil(ChargeWatchdog.parse(["Anode", "--charge-watchdog"]))
        XCTAssertNil(ChargeWatchdog.parse(["Anode", "--charge-watchdog", "x"]))
        XCTAssertNil(ChargeWatchdog.parse(["Anode", "--charge-watchdog", "123", "extra"]))
        XCTAssertNil(ChargeWatchdog.parse(["Anode", "--ultra-watchdog", "123"]))
        XCTAssertNil(ChargeWatchdog.parse(["Anode", "--charge-watchdog", "0"]), "0 is Anode's own group")
        XCTAssertNil(ChargeWatchdog.parse(["Anode", "--charge-watchdog", "1"]), "launchd never ends")
        XCTAssertNil(ChargeWatchdog.parse(["Anode", "--charge-watchdog", "-5"]))
    }

    func testTheLauncherAndTheParserAgree() {
        XCTAssertEqual(ChargeWatchdog.parse(["Anode"] + ChargeWatchdog.arguments(parent: 777)), 777)
    }

    /// SIGTERM is what `killall AnodeApp` and a shutdown send to Anode and its watchdog alike: a watchdog that ended
    /// on it would be gone exactly when Anode ends without a quit. So Anode ends it with another signal.
    func testTheWatchdogIsNotEndedWithTheSignalThatEndsAnode() {
        XCTAssertNotEqual(ChargeWatchdog.stopSignal, SIGTERM)
        XCTAssertNotEqual(ChargeWatchdog.stopSignal, SIGKILL)
    }

    /// `main.swift` runs it before the record, the lift and anything of the app: a watchdog must never build an app.
    func testMainRunsTheWatchdogBeforeAnythingElseOfChargeControl() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let main = try String(contentsOf: root.appendingPathComponent("Sources/AnodeApp/main.swift"), encoding: .utf8)
        func at(_ s: String) throws -> String.Index { try XCTUnwrap(main.range(of: s)?.lowerBound, s) }
        let run = try at("ChargeWatchdog.runIfRequested(CommandLine.arguments)")
        XCTAssertLessThan(run, try at("let chargeRecords = ChargeRecords.live()"))
        XCTAssertLessThan(run, try at("ChargeController.liftAtLaunch("))
        XCTAssertLessThan(run, try at("let app = NSApplication.shared"))
        XCTAssertTrue(main.contains("watchdog: LiveChargeWatchdog()"), "the app's controller has no watchdog")
    }

    // ── Starting and ending the process ─────────────────────────────────────

    func testAWatchdogThatFailsToLaunchIsReportedAsNotStarted() {
        var logged: [String] = []
        let w = LiveChargeWatchdog(log: { logged.append($0) }, launch: { _ in throw LaunchRefused() },
                                   signal: { _, _ in XCTFail("nothing to signal") })
        XCTAssertFalse(w.start())
        XCTAssertEqual(logged.count, 1, "said, not silent")
    }

    func testAProcessThatIsNotRunningRightAfterTheLaunchIsNotAStartedWatchdog() {
        var logged: [String] = []
        let w = LiveChargeWatchdog(log: { logged.append($0) }, launch: { _ in FakeProcess(pid: 4321, isRunning: false) },
                                   signal: { _, _ in XCTFail("nothing to signal") })
        XCTAssertFalse(w.start())
        XCTAssertEqual(logged.count, 1)
    }

    func testItIsStartedForThisProcessAndOnce() {
        var given: [[String]] = []
        let w = LiveChargeWatchdog(log: { _ in }, launch: { given.append($0); return FakeProcess(pid: 4321) },
                                   signal: { _, _ in })
        XCTAssertTrue(w.start())
        XCTAssertTrue(w.start(), "one is running: that counts")
        XCTAssertEqual(given.count, 1)
        XCTAssertEqual(ChargeWatchdog.parse(["Anode"] + given[0]), getpid())
    }

    func testAWatchdogThatEndedByItselfIsStartedAgain() {
        var launched: [FakeProcess] = []
        let w = LiveChargeWatchdog(log: { _ in }, launch: { _ in
            launched.append(FakeProcess(pid: pid_t(4000 + launched.count)))
            return launched.last!
        }, signal: { _, _ in })
        XCTAssertTrue(w.start())
        launched[0].isRunning = false
        XCTAssertTrue(w.start())
        XCTAssertEqual(launched.count, 2)
    }

    func testStoppingSendsTheStopSignalAndNeverTerminate() {
        let process = FakeProcess(pid: 4321)
        var signals: [(pid_t, Int32)] = []
        let w = LiveChargeWatchdog(log: { _ in }, launch: { _ in process }, signal: { signals.append(($0, $1)) })
        w.stop()
        XCTAssertTrue(signals.isEmpty, "none was running")
        XCTAssertTrue(w.start())
        w.stop()
        XCTAssertEqual(signals.map(\.0), [4321])
        XCTAssertEqual(signals.map(\.1), [ChargeWatchdog.stopSignal])
        XCTAssertEqual(process.terminated, 0, "terminate() is SIGTERM, which the watchdog ignores")
        w.stop()
        XCTAssertEqual(signals.count, 1, "stopped once")
    }

    func testAWatchdogThatHasEndedIsNotSignalled() {
        let process = FakeProcess(pid: 4321)
        let w = LiveChargeWatchdog(log: { _ in }, launch: { _ in process },
                                   signal: { _, _ in XCTFail("the pid may be another process by now") })
        XCTAssertTrue(w.start())
        process.isRunning = false
        w.stop()
    }

    // ── When the controller wants one ───────────────────────────────────────

    /// Started as the limit is taken: the way back is written down first, and nothing of macOS's is changed yet.
    func testSwitchingOnStartsTheWatchdogAfterTheRecordAndBeforeAnythingIsChanged() {
        settings.chargeLimit = 85
        var recordWritten: Bool?
        var macOSAtStart: NativeChargeState?
        watchdog.onStart = { [unowned self] in
            recordWritten = settings.chargeRestoreRecord != nil
            macOSAtStart = client.state
        }
        make()
        XCTAssertEqual(watchdog.starts, 1)
        XCTAssertEqual(recordWritten, true)
        XCTAssertEqual(macOSAtStart, found)
        XCTAssertEqual(client.state?.mclLimit, 85)
        XCTAssertEqual(watchdog.stops, 0)
    }

    func testOffStartsNoWatchdog() {
        let c = make(enabled: false)
        c.tick()
        XCTAssertEqual(watchdog.starts, 0)
    }

    func testAMacWithoutTheClientStartsNoWatchdog() {
        make(clientToMake: .some(nil))
        XCTAssertEqual(watchdog.starts, 0, "nothing is held, so there is nothing to put back")
    }

    func testSwitchingOffEndsTheWatchdogAfterMacOSIsPutBack() {
        settings.chargeLimit = 85
        make()
        settings.chargeControlEnabled = false
        XCTAssertEqual(client.state, found)
        XCTAssertEqual(watchdog.stops, 1)
        settings.chargeControlEnabled = true
        XCTAssertEqual(watchdog.starts, 2, "switching on again starts one again")
    }

    func testQuittingEndsTheWatchdogAfterMacOSIsPutBack() {
        settings.chargeLimit = 85
        let c = make()
        c.shutdown()
        XCTAssertEqual(client.state, found)
        XCTAssertEqual(watchdog.stops, 1)
    }

    /// The limit is still held, and still lifted at the next launch; the log says what is missing.
    func testAWatchdogThatWillNotStartIsSaidAndTheLimitIsStillHeld() {
        settings.chargeLimit = 85
        watchdog.startsWork = false
        make()
        XCTAssertEqual(client.state?.mclLimit, 85)
        XCTAssertTrue(lines.contains { $0.contains("no watchdog is running") }, lines.joined(separator: "\n"))
    }

    /// The headless restores hold nothing, so they start none.
    func testTheLiftAtLaunchStartsNoWatchdog() {
        settings.chargeLimit = 85
        make()
        crash()
        let starts = watchdog.starts
        XCTAssertTrue(ChargeController.liftAtLaunch(settings: settings, makeClient: { [client] in client },
                                                    helper: { [helper] in helper! }, log: { _ in }))
        XCTAssertEqual(watchdog.starts, starts)
    }

    // ── What it does when Anode has ended ───────────────────────────────────

    /// The bug: an Anode that crashed and was never opened again left its limit in force for good.
    func testAnAnodeThatEndedWithoutQuittingHasMacOSPutBackAtOnce() {
        settings.chargeLimit = 85
        make()
        XCTAssertEqual(client.state?.mclLimit, 85)
        crash()
        XCTAssertEqual(watchdog.stops, 0, "a crash tells the watchdog nothing")
        XCTAssertTrue(liftAfterAnodeEnded())
        XCTAssertEqual(client.state, found, "the limit was left in force")
        XCTAssertNil(settings.chargeRestoreRecord)
        XCTAssertTrue(settings.chargeControlEnabled, "the setting was changed")
        XCTAssertEqual(settings.chargeLimit, 85, "the person's limit was changed")
        XCTAssertTrue(lines.contains { $0.contains("ended without quitting") }, lines.joined(separator: "\n"))
        XCTAssertFalse(lines.contains { $0.contains("starts again in") }, "nothing starts again until Anode is opened")
    }

    /// The launch that follows still waits before it holds a limit again, as after any run that did not quit.
    func testTheNextLaunchStillWaitsBeforeHoldingALimitAgain() {
        settings.chargeLimit = 85
        make()
        crash()
        XCTAssertTrue(liftAfterAnodeEnded())
        XCTAssertTrue(settings.chargeStartPending)
        let lifted = ChargeController.liftAtLaunch(settings: settings, makeClient: { [client] in client },
                                                   helper: { [helper] in helper! }, log: { _ in })
        XCTAssertTrue(lifted)
        let c = make(liftedAtLaunch: lifted)
        XCTAssertEqual(c.status, .waiting(ChargeController.liftedText))
        XCTAssertEqual(client.state, found, "a limit was set during the wait")
        c.resumeIfDue(now: Date().addingTimeInterval(ChargeController.startDelay + 1))
        XCTAssertEqual(client.state?.mclLimit, 85)
        XCTAssertFalse(settings.chargeStartPending)
    }

    func testAnAnodeThatQuitLeavesTheWatchdogNothingToDo() {
        settings.chargeLimit = 85
        let c = make()
        c.shutdown()
        controller = nil
        let calls = client.limitCalls.count
        XCTAssertFalse(liftAfterAnodeEnded())
        XCTAssertEqual(client.limitCalls.count, calls, "macOS was written to after a clean quit")
        XCTAssertFalse(settings.chargeStartPending, "a clean quit is not followed by a wait")
        XCTAssertFalse(lines.contains { $0.contains("ended without quitting") })
    }

    /// Switched off in the setting while a record was left over (a put-back macOS refused): it is put back, and
    /// nothing is left pending, because nothing is switched on again.
    func testWithChargeControlOffALeftoverRecordIsPutBackAndNothingIsPending() {
        settings.chargeRestoreRecord = ChargeController.encodeRecord(found)
        client.state = NativeChargeState(mclEnabled: true, mclLimit: 80, optimizedChargingEnabled: false)
        settings.chargeControlEnabled = false
        XCTAssertTrue(liftAfterAnodeEnded())
        XCTAssertEqual(client.state, found)
        XCTAssertFalse(settings.chargeStartPending)
    }

    // ── With the shared record: whose hold it is ────────────────────────────

    func testWithTheSharedRecordTheDeadProcesssHoldIsLifted() {
        holding(limit: 85, pid: 1001)
        crash()
        live.remove(1001)
        XCTAssertTrue(liftAfterAnodeEnded(pid: 1001, records: sharedRecords(pid: 2001)))
        XCTAssertEqual(client.state, found)
        XCTAssertEqual(store(pid: 2001).peek(), ChargeRecordStore.Contents.none, "the record was not cleared")
    }

    /// A quit released the record before the watchdog could see the end, and the person opened Anode again at once:
    /// the limit in force is the new Anode's, held under its own pid, and is not the old watchdog's to lift.
    func testAnAnodeOpenedSinceKeepsItsLimit() {
        holding(limit: 85, pid: 1001)
        controller?.shutdown()
        controller = nil
        live.remove(1001)
        holding(limit: 85, pid: 1002)
        XCTAssertFalse(liftAfterAnodeEnded(pid: 1001, records: sharedRecords(pid: 2001)))
        XCTAssertEqual(client.state?.mclLimit, 85, "the new Anode's limit was lifted")
        XCTAssertFalse(settings.chargeStartPending)
    }

    /// Another account's Anode is running and holds the limit too: nothing is put back, and this account is no
    /// longer a holder, so that Anode's quit puts macOS back.
    func testAnotherAccountsRunningAnodeKeepsTheLimit() throws {
        holding(limit: 85, pid: 1001)
        live.insert(3001)
        XCTAssertNotNil(store(uid: 502, pid: 3001).acquire(readMacOS: { XCTFail("a record stands"); return nil }))
        crash()
        live.remove(1001)
        XCTAssertTrue(liftAfterAnodeEnded(pid: 1001, records: sharedRecords(pid: 2001)))
        XCTAssertEqual(client.state?.mclLimit, 85, "the other account's limit was lifted")
        guard case .record(let r)? = store(pid: 2001).peek() else { return XCTFail("the record went") }
        XCTAssertEqual(r.holders, [ChargeHolder(uid: 502, pid: 3001)])
        XCTAssertEqual(r.original, found)
    }

    /// Another Anode is in the middle of its own restore and holds the record's lock: the watchdog looks again
    /// instead of giving up, and lifts once it can read it.
    func testARecordThatIsBusyIsLookedAtAgain() throws {
        holding(limit: 85, pid: 1001)
        crash()
        live.remove(1001)
        let busy = open(directory + "/" + ChargeRecordStore.fileName, O_RDWR)
        XCTAssertGreaterThanOrEqual(busy, 0)
        defer { close(busy) }
        XCTAssertEqual(flock(busy, LOCK_EX | LOCK_NB), 0)
        var waits: [TimeInterval] = []
        let lifted = liftAfterAnodeEnded(pid: 1001, records: sharedRecords(pid: 2001, lockTimeout: 0.05), wait: {
            waits.append($0)
            if waits.count == 2 { flock(busy, LOCK_UN) }
        })
        XCTAssertTrue(lifted)
        XCTAssertEqual(waits, [ChargeWatchdog.recordLookInterval, ChargeWatchdog.recordLookInterval])
        XCTAssertEqual(client.state, found)
    }

    func testARecordThatStaysBusyIsLeftForTheNextLaunch() throws {
        holding(limit: 85, pid: 1001)
        crash()
        live.remove(1001)
        let busy = open(directory + "/" + ChargeRecordStore.fileName, O_RDWR)
        XCTAssertGreaterThanOrEqual(busy, 0)
        defer { close(busy) }
        XCTAssertEqual(flock(busy, LOCK_EX | LOCK_NB), 0)
        var waits = 0
        XCTAssertFalse(liftAfterAnodeEnded(pid: 1001, records: sharedRecords(pid: 2001, lockTimeout: 0.05),
                                           wait: { _ in waits += 1 }))
        XCTAssertEqual(waits, ChargeWatchdog.recordLooks - 1)
        XCTAssertEqual(client.state?.mclLimit, 85, "nothing was written without the record")
        flock(busy, LOCK_UN)
        guard case .record? = store(pid: 2001).peek() else { return XCTFail("the record went") }
    }
}

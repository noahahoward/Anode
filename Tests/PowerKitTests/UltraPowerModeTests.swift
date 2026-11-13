import XCTest
@testable import AnodeApp
@testable import PowerKit

// Low Power Mode through the helper, from the other side of the wire: the pure parts the helper and the app both lean
// on (the packed value, what `pmset -g custom` prints, the command lines), and `HelperPowerMode`, which is the app's
// `PowerModeControlling` over the shared connection.
//
// Nothing here runs `pmset`, opens the real socket or reads the real settings. The one real program run is `echo` (and
// `false`), to show that the runner reads a child's output and status; it is handed a path of its own, and the helper
// never is.
//
// The classes match `--filter UltraPowerMode`.

// ── The packed value, the reading, the command lines ────────────────────────

final class UltraPowerModePureTests: XCTestCase {

    // ── Packing ─────────────────────────────────────────────────────────────

    func testThePackedValueIsBatteryPlusTenTimesCharger() {
        XCTAssertEqual(PowerModes(battery: 2, charger: 0)?.packed, 2)
        XCTAssertEqual(PowerModes(battery: 0, charger: 2)?.packed, 20)
        XCTAssertEqual(PowerModes(battery: 1, charger: 2)?.packed, 21)
        XCTAssertEqual(PowerModes(battery: 0, charger: 0)?.packed, 0)
        XCTAssertEqual(PowerModes(battery: 2, charger: 2)?.packed, 22)
    }

    func testEveryPairOfDigitsRoundTrips() {
        for battery in 0...2 {
            for charger in 0...2 {
                let modes = PowerModes(battery: battery, charger: charger)
                XCTAssertEqual(modes.flatMap { PowerModes(packed: $0.packed) }, modes, "\(battery) \(charger)")
                XCTAssertEqual(modes?.digit(of: .battery), battery)
                XCTAssertEqual(modes?.digit(of: .charger), charger)
            }
        }
    }

    /// Each digit is 0, 1 or 2: nothing else is a power mode, and nothing else may reach a command line.
    func testNothingButTwoDigitsOfZeroToTwoIsAPowerMode() {
        for bad in [-1, 3, 9, 13, 19, 23, 30, 33, 100, 222, 1_000_000, Int.max, Int.min] {
            XCTAssertNil(PowerModes(packed: bad), "\(bad)")
        }
        XCTAssertNil(PowerModes(battery: 3, charger: 0))
        XCTAssertNil(PowerModes(battery: 0, charger: 3))
        XCTAssertNil(PowerModes(battery: -1, charger: 0))
        XCTAssertNil(PowerModes(battery: 0, charger: -1))
    }

    // ── Reading `pmset -g custom` ───────────────────────────────────────────

    private let bothWithPowermode = """
    Battery Power:
     lidwake              1
     lowpowermode         0
     standby              1
     powermode            0
     displaysleep         2
    AC Power:
     lidwake              1
     lowpowermode         0
     powermode            2
     displaysleep         10
    """

    private let bothWithLowpowermode = """
    Battery Power:
     lidwake              1
     lowpowermode         1
     sleep                1
    AC Power:
     lidwake              1
     lowpowermode         0
     sleep                0
    """

    private let aDesktop = """
    AC Power:
     sleep                0
     powermode            1
     displaysleep         10
    """

    private let neitherKey = """
    Battery Power:
     lidwake              1
     sleep                1
    AC Power:
     lidwake              1
     sleep                0
    """

    func testBothSourcesWithPowermodeAreReadByIt() {
        XCTAssertEqual(PowerModeReading.parse(bothWithPowermode),
                       PowerModeReading(key: .powermode, battery: 0, charger: 2))
    }

    /// What `pmset -g custom` printed on the owner's Mac, as it was captured: no `lowpowermode` at all, and a line whose
    /// first word is not a key. The fixtures above are made up; this one is not.
    func testTheRealCaptureFromTheOwnersMacIsReadAsPowermodeTwoOnBoth() {
        let capture = """
        Battery Power:
         Sleep On Power Button 1
         powermode            2
         standby              1
         ttyskeepawake        1
         hibernatemode        3
         powernap             1
         hibernatefile        /var/vm/sleepimage
         displaysleep         0
         womp                 0
         networkoversleep     0
         sleep                1
         lessbright           1
         tcpkeepalive         1
         disksleep            10
        AC Power:
         Sleep On Power Button 1
         powermode            2
         standby              1
         ttyskeepawake        1
         hibernatemode        3
         powernap             1
         hibernatefile        /var/vm/sleepimage
         displaysleep         0
         womp                 1
         networkoversleep     0
         sleep                0
         tcpkeepalive         1
         disksleep            10

        """
        XCTAssertEqual(PowerModeReading.parse(capture), PowerModeReading(key: .powermode, battery: 2, charger: 2))
        XCTAssertEqual(PowerModeReading.parse(capture)?.modes, PowerModes(battery: 2, charger: 2))
    }

    func testBothSourcesWithLowpowermodeAreReadByIt() {
        XCTAssertEqual(PowerModeReading.parse(bothWithLowpowermode),
                       PowerModeReading(key: .lowpowermode, battery: 1, charger: 0))
    }

    func testADesktopHasOneSourceAndNoBattery() {
        XCTAssertEqual(PowerModeReading.parse(aDesktop), PowerModeReading(key: .powermode, battery: nil, charger: 1))
    }

    func testNeitherKeyMeansTheMacHasNoLowPowerMode() {
        XCTAssertNil(PowerModeReading.parse(neitherKey))
        XCTAssertNil(PowerModeReading.parse(""))
        XCTAssertNil(PowerModeReading.parse("pmset: something went wrong\n"))
    }

    func testASectionThatIsNeitherTheBatteryNorTheChargerIsLeftOut() {
        let text = """
        Battery Power:
         powermode            1
        UPS Power:
         powermode            2
        AC Power:
         powermode            0
        """
        XCTAssertEqual(PowerModeReading.parse(text), PowerModeReading(key: .powermode, battery: 1, charger: 0))
    }

    /// The key is the whole word, and its value a number: a longer name, or a word where the number goes, is not it.
    func testOnlyTheKeyItselfWithANumberCounts() {
        let text = """
        Battery Power:
         powermodes           2
         powermode            auto
         lowpowermodex        1
        AC Power:
         powermode            1
        """
        XCTAssertEqual(PowerModeReading.parse(text), PowerModeReading(key: .powermode, battery: nil, charger: 1))
    }

    /// The Mac's own value, only if it is one this helper knows.
    func testAReadingBecomesPowerModesOnlyWhenEveryValueItHasIsOneThisKeyKnows() {
        XCTAssertEqual(PowerModeReading(key: .powermode, battery: 2, charger: 0).modes, PowerModes(battery: 2, charger: 0))
        XCTAssertEqual(PowerModeReading(key: .powermode, battery: nil, charger: 2).modes, PowerModes(battery: 0, charger: 2),
                       "a source the Mac has not packs as 0")
        XCTAssertNil(PowerModeReading(key: .powermode, battery: 3, charger: 0).modes)
        XCTAssertNil(PowerModeReading(key: .powermode, battery: 0, charger: -1).modes)
        XCTAssertNil(PowerModeReading(key: .lowpowermode, battery: 2, charger: 0).modes, "2 is not on or off")
        XCTAssertEqual(PowerModeReading(key: .lowpowermode, battery: 1, charger: 0).modes, PowerModes(battery: 1, charger: 0))
    }

    // ── The command lines ───────────────────────────────────────────────────

    func testAWriteIsAFlagAKeyAndADigitAndNothingElse() {
        XCTAssertEqual(PowerModeSwitch.arguments(setting: 1, of: .powermode, for: .battery), ["-b", "powermode", "1"])
        XCTAssertEqual(PowerModeSwitch.arguments(setting: 2, of: .powermode, for: .charger), ["-c", "powermode", "2"])
        XCTAssertEqual(PowerModeSwitch.arguments(setting: 0, of: .lowpowermode, for: .battery), ["-b", "lowpowermode", "0"])
        XCTAssertEqual(PowerModeSwitch.readArguments, ["-g", "custom"])
    }

    func testADigitTheKeyDoesNotHaveIsNotMadeIntoACommandLine() {
        XCTAssertNil(PowerModeSwitch.arguments(setting: 2, of: .lowpowermode, for: .battery))
        for bad in [-1, 3, 10, 100] {
            XCTAssertNil(PowerModeSwitch.arguments(setting: bad, of: .powermode, for: .charger), "\(bad)")
        }
    }

    func testTheRunnerIsAskedForOneProgramAtOneAbsolutePath() {
        XCTAssertEqual(SystemPowerModeRunner.tool, "/usr/bin/pmset")
        XCTAssertTrue(SystemPowerModeRunner.tool.hasPrefix("/"), "a path that is looked up is a path that can be planted")
    }

    // ── A child that has not ended ──────────────────────────────────────────

    /// A child as far as ending it goes, with no process behind it. The helper's own dispositions are inherited by what it
    /// runs: it ignores SIGTERM for its own sake (the signal is routed to `stop()`), so a hung `pmset` may ignore it too.
    private final class FakeChild: PowerModeChild {
        private(set) var running = true
        let processIdentifier: Int32
        let endsWhenAsked: Bool
        let endsWhenKilled: Bool
        private(set) var asked = 0
        private(set) var killed = 0
        init(pid: Int32 = 4242, endsWhenAsked: Bool, endsWhenKilled: Bool = true) {
            processIdentifier = pid
            self.endsWhenAsked = endsWhenAsked
            self.endsWhenKilled = endsWhenKilled
        }
        var isRunning: Bool { running }
        func terminate() { asked += 1; if endsWhenAsked { running = false } }
        func kill() { killed += 1; if endsWhenKilled { running = false } }
        func endBehindTheirBack() { running = false }
    }

    /// `end` with every wait it makes written down, and every line it says.
    private func end(_ child: FakeChild, exits: (TimeInterval) -> Bool = { _ in false }) -> (waited: [TimeInterval], said: [String]) {
        var waited: [TimeInterval] = []
        var said: [String] = []
        SystemPowerModeRunner.end(child, exitedWithin: { waited.append($0); return exits($0) }, log: { said.append($0) })
        return (waited, said)
    }

    func testAChildThatEndsWhenAskedIsNotKilled() {
        let child = FakeChild(endsWhenAsked: true)
        let r = end(child) { _ in !child.isRunning }
        XCTAssertEqual(child.asked, 1)
        XCTAssertEqual(child.killed, 0)
        XCTAssertEqual(r.waited, [SystemPowerModeRunner.endGrace], "the child was given the grace to end")
        XCTAssertEqual(r.said, [])
    }

    /// A child that ignores the request is not left running: after the grace it is killed, its own pid and no other.
    func testAChildThatIgnoresTheRequestIsKilledAfterTheGraceAndWaitedFor() {
        let child = FakeChild(endsWhenAsked: false)
        let r = end(child) { _ in !child.isRunning }
        XCTAssertEqual(child.asked, 1)
        XCTAssertEqual(child.killed, 1)
        XCTAssertEqual(r.waited.first, SystemPowerModeRunner.endGrace)
        XCTAssertEqual(r.waited, [SystemPowerModeRunner.endGrace, SystemPowerModeRunner.killWait],
                       "after the kill the child is waited for, for a short bounded time, and not for ever")
        XCTAssertFalse(child.isRunning)
        XCTAssertEqual(r.said, [], "it ended: nothing to say")
    }

    /// Nothing the daemon does depends on an object going out of scope to reap a child: one that has not ended by the end
    /// of the wait after the kill is said once, with its pid, and the call goes on.
    func testAChildThatSurvivesTheKillIsSaidOnceAndTheCallGoesOn() {
        let child = FakeChild(endsWhenAsked: false, endsWhenKilled: false)
        let r = end(child)
        XCTAssertEqual(child.killed, 1, "killed once, not again and again")
        XCTAssertEqual(r.waited, [SystemPowerModeRunner.endGrace, SystemPowerModeRunner.killWait])
        XCTAssertEqual(r.said.count, 1, "\(r.said)")
        guard let line = r.said.first else { return }
        XCTAssertTrue(line.contains("4242"), line)
        XCTAssertTrue(line.contains("WARNING"), line)
    }

    func testAChildThatHasAlreadyEndedIsLeftAlone() {
        let child = FakeChild(endsWhenAsked: false)
        child.endBehindTheirBack()
        let r = end(child) { _ in true }
        XCTAssertEqual(child.asked, 0)
        XCTAssertEqual(child.killed, 0)
        XCTAssertEqual(r.waited, [])
        XCTAssertEqual(r.said, [])
    }

    /// It ended while the grace ran out: its pid may already be someone else's, so nothing is sent to it.
    func testAChildThatEndedDuringTheGraceIsNotKilled() {
        let child = FakeChild(endsWhenAsked: false)
        let r = end(child) { _ in child.endBehindTheirBack(); return false }
        XCTAssertEqual(child.asked, 1)
        XCTAssertEqual(child.killed, 0, "a signal to a pid that is no longer this child's")
        XCTAssertEqual(r.waited, [SystemPowerModeRunner.endGrace])
    }

    /// `kill(-1, SIGKILL)` as root ends every process the user can see, and `kill(0, ...)` the process group: a pid of 1 or
    /// less is never signalled, by either signal, whatever the child says about itself.
    func testAPidOfOneOrLessIsNeverSignalled() {
        for pid in [Int32.min, -1000, -1, 0, 1] {
            let child = FakeChild(pid: pid, endsWhenAsked: false)
            let r = end(child)
            XCTAssertEqual(child.asked, 0, "pid \(pid) was asked to end")
            XCTAssertEqual(child.killed, 0, "pid \(pid) was killed")
            XCTAssertEqual(r.waited, [], "pid \(pid)")
        }
        let first = FakeChild(pid: 2, endsWhenAsked: false)
        _ = end(first)
        XCTAssertEqual(first.killed, 1, "an ordinary pid is still ended")
    }

    // ── The time a call can take ────────────────────────────────────────────

    /// A call is given `callLimit`; one that has not finished is asked to end, given `endGrace`, killed, and given
    /// `killWait` to be gone. The most a call can take is the sum, and `end` waits exactly the last two.
    func testTheMostACallCanTakeIsWhatItIsGivenPlusWhatEndingItTakes() {
        XCTAssertEqual(PowerModeSwitch.slowestCall,
                       PowerModeSwitch.callLimit + SystemPowerModeRunner.endGrace + SystemPowerModeRunner.killWait,
                       accuracy: 1e-9)
        XCTAssertEqual(PowerModeSwitch.slowestCall, 1.0, accuracy: 1e-9)
        let child = FakeChild(endsWhenAsked: false, endsWhenKilled: false)
        let r = end(child)
        XCTAssertEqual(PowerModeSwitch.callLimit + r.waited.reduce(0, +), PowerModeSwitch.slowestCall, accuracy: 1e-9,
                       "`end` waits something other than the two constants the bound is made of")
    }

    /// The two worst cases that can really happen, as sums: the read and the writes that can hang.
    func testTheWorstCasesAreTheReachableSums() {
        let call = PowerModeSwitch.callLimit, slowest = PowerModeSwitch.slowestCall
        // A read that has to be ended ends the command, so a read counts `callLimit`; a write that goes counts `callLimit`;
        // a write that hangs, `slowestCall`.
        XCTAssertEqual(PowerModeSwitch.slowestCommand, call + 2 * slowest, accuracy: 1e-9)
        XCTAssertEqual(PowerModeSwitch.slowestRolledBackEnter, call + call + slowest + call + 2 * slowest, accuracy: 1e-9)
        XCTAssertEqual(PowerModeSwitch.slowestCommand, 2.6, accuracy: 1e-9)
        XCTAssertEqual(PowerModeSwitch.slowestRolledBackEnter, 4.8, accuracy: 1e-9)
    }

    /// The deadline the sleep watch gives the loop belongs to the charge feature and is not changed here. It no longer bears
    /// on the sleep answer: with the tool run on the worker, no pass of the loop takes the worst rolled-back switch-on's
    /// time, so nothing the loop does for Low Power Mode can outlast it. What is kept is that it still covers that time with
    /// a second to spare, so that the figure the worker's bound and the stop's wait are made of is never one the deadline
    /// would not have survived, and a change to either number that eats the margin is noticed.
    func testTheSleepAnswerDeadlineKeepsAMarginOverTheWorstRolledBackSwitchOn() {
        XCTAssertGreaterThanOrEqual(FanHelperServer.sleepAnswerDeadline, PowerModeSwitch.slowestRolledBackEnter + 1)
    }

    /// The comments that state the worker's bound state the figures these constants make, where the worker's time is
    /// described; and the loop's own docs, with the work off the loop, state none of them: the tool's time is no loop time.
    func testTheCommentsThatStateTheWorkersBoundStateTheReachableFiguresAndTheLoopsDocsStateNone() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        func s(_ seconds: Double) -> String { String(format: "%.1f s", seconds) }
        let slowest = PowerModeSwitch.slowestCall
        let switchFile = try source("Sources/PowerKit/PowerModeSwitch.swift")
        let serverFile = try source("Sources/PowerKit/FanHelperService.swift")
        // The docs of `callLimit` and of the two worst cases, the worker's time.
        for figure in [s(slowest), s(PowerModeSwitch.slowestCommand), s(PowerModeSwitch.slowestRolledBackEnter)] {
            XCTAssertTrue(switchFile.contains(figure), "PowerModeSwitch.swift does not say \(figure)")
            XCTAssertFalse(serverFile.contains(figure), "FanHelperService.swift says \(figure), as if the loop waited for it")
        }
        // The loop's doc says what it always said.
        XCTAssertTrue(serverFile.contains("NOTHING A CLIENT DOES CAN HOLD THIS THREAD"))
        // Figures that were true of an earlier version, or cannot happen.
        for old in ["3.6 s", "3.0 s", "6.0 s", "up to 0.6 s a call"] {
            XCTAssertFalse(switchFile.contains(old), "PowerModeSwitch.swift still says \(old)")
            XCTAssertFalse(serverFile.contains(old), "FanHelperService.swift still says \(old)")
        }
    }

    // ── The real runner, on a program that is harmless ──────────────────────

    func testTheRunnerHandsBackWhatTheChildPrintedAndHowItEnded() {
        let echo = SystemPowerModeRunner(path: "/bin/echo")
        XCTAssertEqual(echo.run(["hello", "there"], within: 5), PowerModeRun(status: 0, output: "hello there\n"))
        let no = SystemPowerModeRunner(path: "/usr/bin/false")
        XCTAssertEqual(no.run([], within: 5)?.status, 1)
    }

    func testAProgramThatIsNotThereIsNoAnswerRatherThanACrash() {
        XCTAssertNil(SystemPowerModeRunner(path: "/no/such/tool-\(UUID().uuidString)").run([], within: 1))
    }
}

// ── The app's side: HelperPowerMode over the shared connection ──────────────

/// The helper as the app sees it over the wire. `enterLowPowerMode` and `restorePowerMode` are answered "started" at once;
/// `powerModeResult` is answered pending for the first `pendingAsks` times it is asked, and then with how the job that was
/// started ended: done (with the mode before, for an enter), or failed with a reason.
private final class ScriptedHelper {
    var before = 21
    var pendingAsks = 0
    /// The job ends in this refusal, instead of in done.
    var failsWith: String?
    /// The command itself is refused, at once.
    var refusesStart: String?
    private var last: FanCommand?
    private var asked = 0

    func answer(_ command: FanCommand) -> FanReply {
        switch command {
        case .enterLowPowerMode, .restorePowerMode:
            if let why = refusesStart { return FanReply(ok: false, message: why) }
            last = command
            asked = 0
            return FanReply(ok: true, message: "started")
        case .powerModeResult:
            if asked < pendingAsks {
                asked += 1
                return FanReply(ok: true, message: "pending", pending: true)
            }
            if let why = failsWith { return FanReply(ok: false, message: why) }
            switch last {
            case .enterLowPowerMode?: return FanReply(ok: true, message: "Low Power Mode is on", powerModeBefore: before)
            case .restorePowerMode?: return FanReply(ok: true, message: "power mode put back")
            default: return FanReply(ok: false, message: PowerModeRefusal.nothingAsked.message)
            }
        default:
            return FanReply(ok: true, message: "ok")
        }
    }
}

/// A wire whose answer to `powerModeResult` is whatever the test sets, to show what happens to an answer that comes after
/// the app has stopped waiting.
private final class DeferredWire: HelperWire {
    var onPeerClosed: (() -> Void)?
    var version: Int? = 4
    var result = FanReply(ok: true, message: "pending", pending: true)
    private(set) var sent: [FanCommand] = []
    private(set) var disconnects = 0

    func ensureConnected(_ done: @escaping (FanControlLink.Status, Bool) -> Void) {
        done(.connected(fanCount: 1, version: version), true)
    }
    func ping(_ done: @escaping (FanControlLink.Status) -> Void) { done(.connected(fanCount: 1, version: version)) }
    func send(_ command: FanCommand, _ done: @escaping (FanReply) -> Void) {
        sent.append(command)
        switch command {
        case .powerModeResult: done(result)
        case .enterLowPowerMode, .restorePowerMode: done(FanReply(ok: true, message: "started"))
        default: done(FanReply(ok: true, message: "ok"))
        }
    }
    func sendWaiting(_ command: FanCommand, timeout: TimeInterval) -> FanReply? { nil }
    func drain(timeout: TimeInterval) -> Bool { true }
    func disconnect() { disconnects += 1 }
    func disconnectWithoutWaiting() { disconnect() }
}

final class UltraPowerModeTests: XCTestCase {

    private var wire: ScriptedWire!
    private var connection: HelperConnection!
    private var installed = true
    private var scheduled: [(after: TimeInterval, work: () -> Void)] = []
    private var mode: HelperPowerMode!
    private var helper = ScriptedHelper()

    override func setUp() {
        super.setUp()
        installed = true
        scheduled = []
        helper = ScriptedHelper()
        wire = ScriptedWire()
        wire.answerAtOnce = .connected(fanCount: 1, version: 4)
        wire.pingStatus = .connected(fanCount: 1, version: 4)
        wire.reply = { [unowned self] command in helper.answer(command) }
        connection = HelperConnection(wire: wire)
        mode = makeMode(over: connection)
    }

    private func makeMode(over connection: HelperConnection) -> HelperPowerMode {
        HelperPowerMode(connection: connection, isInstalled: { [unowned self] in installed },
                        schedule: { [unowned self] after, work in scheduled.append((after, work)) })
    }

    /// What the helper answers an enter with, in the end: it took it, and the mode before was `before`.
    private func helperTakesIt(before: Int = 21) {
        helper.before = before
    }

    private func enter() -> [Int?] {
        var answers: [Int?] = []
        mode.enterLowPower { answers.append($0) }
        return answers
    }

    /// Time passes: whatever was scheduled for `after` seconds from its start runs, once, and is no longer waiting.
    private func fire(_ after: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        guard let i = scheduled.firstIndex(where: { $0.after == after }) else {
            return XCTFail("nothing was scheduled for \(after) s: \(scheduled.map(\.after))", file: file, line: line)
        }
        scheduled.remove(at: i).work()
    }

    // ── What the helper speaks ──────────────────────────────────────────────

    func testAnOlderHelperIsReportedAsOld() {
        for version in [3, 2, 1, nil] as [Int?] {
            let wire = ScriptedWire()
            wire.answerAtOnce = .connected(fanCount: 1, version: version)
            let connection = HelperConnection(wire: wire)
            let mode = makeMode(over: connection)
            connection.connect(for: .fans) { _ in }
            XCTAssertEqual(mode.availability, .oldHelper, "protocol \(version.map(String.init) ?? "none")")
            connection.release(.fans)
        }
    }

    func testAHelperThatSpeaksFourIsReady() {
        for version in [4, 5] {
            let wire = ScriptedWire()
            wire.answerAtOnce = .connected(fanCount: 1, version: version)
            let connection = HelperConnection(wire: wire)
            let mode = makeMode(over: connection)
            connection.connect(for: .fans) { _ in }
            XCTAssertEqual(mode.availability, .ready, "protocol \(version)")
            connection.release(.fans)
        }
    }

    func testNoHelperIsReportedAsMissing() {
        installed = false
        XCTAssertEqual(mode.availability, .noHelper, "nothing installed and nothing connected")
    }

    /// A helper started by hand is reachable though nothing is installed.
    func testAHelperStartedByHandCountsWhileItIsConnected() {
        installed = false
        connection.connect(for: .fans) { _ in }
        XCTAssertEqual(mode.availability, .ready)
        wire.answerAtOnce = .connected(fanCount: 1, version: 3)
        connection.release(.fans)
        connection.connect(for: .fans) { _ in }
        XCTAssertEqual(mode.availability, .oldHelper)
    }

    /// Installed and not yet heard from: the gate on the connect decides, and what it learns is remembered.
    func testAnInstalledHelperNotYetHeardFromIsReadyUntilItSaysOtherwise() {
        XCTAssertEqual(mode.availability, .ready)
        wire.answerAtOnce = .connected(fanCount: 1, version: 3)
        XCTAssertEqual(enter(), [nil])
        XCTAssertEqual(mode.availability, .oldHelper, "what the helper said was not remembered")
    }

    /// An install or an uninstall is about to change what the helper speaks: what it last said is not kept.
    func testWhatAnOldHelperSaidIsForgottenWhenTheHelperIsBeingReplaced() {
        wire.answerAtOnce = .connected(fanCount: 1, version: 3)
        connection.connect(for: .fans) { _ in }
        XCTAssertEqual(mode.availability, .oldHelper)
        connection.suspend()
        XCTAssertEqual(mode.availability, .ready)
        connection.resume()
        connection.release(.fans)
    }

    func testTheConnectionSpeaksThePowerModeFromProtocolFourOnly() {
        let cases: [(version: Int?, charge: Bool, powerMode: Bool)] = [
            (nil, false, false), (1, false, false), (2, true, false), (3, true, false), (4, true, true), (5, true, true),
        ]
        for c in cases {
            let wire = ScriptedWire()
            wire.answerAtOnce = .connected(fanCount: 1, version: c.version)
            let connection = HelperConnection(wire: wire)
            XCTAssertFalse(connection.speaksPowerMode, "before it has answered")
            connection.connect(for: .charge) { _ in }
            let label = "protocol \(c.version.map(String.init) ?? "none")"
            XCTAssertEqual(connection.speaksCharge, c.charge, label)
            XCTAssertEqual(connection.speaksPowerMode, c.powerMode, label)
            connection.release(.charge)
        }
    }

    /// An app that speaks 4 with the helper that was installed before this release (3): fans and every charge feature
    /// are what they were, and the power mode alone says the helper is old.
    func testAHelperThatSpeaksThreeKeepsEveryChargeFeatureAndOnlyTheModeIsOld() {
        let wire = ScriptedWire()
        wire.answerAtOnce = .connected(fanCount: 2, version: 3)
        let connection = HelperConnection(wire: wire)
        let adapter = ChargeHelperAdapter(connection: connection, isInstalled: { true })
        adapter.follow {}
        XCTAssertTrue(adapter.available, "a discharge and a limit")
        XCTAssertTrue(adapter.speaksReadyBy, "the plan")
        XCTAssertFalse(adapter.outdated)
        connection.connect(for: .fans) { _ in }
        XCTAssertTrue(connection.speaksCharge)
        XCTAssertFalse(connection.speaksPowerMode)
        XCTAssertEqual(makeMode(over: connection).availability, .oldHelper)
        XCTAssertEqual(FanDaemon.state(installed: true, answered: true, helloVersion: 3), .installedButOlder(daemonVersion: 3),
                       "the Fans tab's own line, which is a line and not a refusal")
        connection.release(.fans)
        adapter.letGo()
    }

    // ── Entering ────────────────────────────────────────────────────────────

    /// The helper runs `pmset` off its loop, so the enter is answered "started" and its end is asked for.
    func testEnterSendsTheCommandThenAsksForTheResultAndAnswersTheModeBefore() {
        helperTakesIt(before: 21)
        XCTAssertEqual(enter(), [21])
        XCTAssertEqual(wire.sent, [.enterLowPowerMode, .powerModeResult])
    }

    /// Asked every 0.2 s while the helper says pending, and answered when it says done.
    func testEnterAsksEveryTwoTenthsOfASecondUntilTheHelperSaysDone() {
        XCTAssertEqual(HelperPowerMode.pollEvery, 0.2)
        helper.pendingAsks = 2
        var answers: [Int?] = []
        mode.enterLowPower { answers.append($0) }
        XCTAssertEqual(answers, [])
        XCTAssertEqual(wire.sent, [.enterLowPowerMode, .powerModeResult], "the first ask is at once")
        fire(HelperPowerMode.pollEvery)
        XCTAssertEqual(answers, [], "still pending")
        XCTAssertEqual(wire.sent.count, 3)
        fire(HelperPowerMode.pollEvery)
        XCTAssertEqual(answers, [21])
        XCTAssertEqual(wire.sent, [.enterLowPowerMode, .powerModeResult, .powerModeResult, .powerModeResult])
        XCTAssertFalse(scheduled.contains { $0.after == HelperPowerMode.pollEvery }, "went on asking after the answer")
        XCTAssertEqual(connection.holders, [.powerMode], "held from the enter until the restore")
    }

    func testEnterAsksUntilTheHelperSaysFailedAndThenAnswersNilAndLetsGo() {
        helper.pendingAsks = 1
        helper.failsWith = PowerModeRefusal.notTaken.message
        var answers: [Int?] = []
        mode.enterLowPower { answers.append($0) }
        XCTAssertEqual(answers, [])
        fire(HelperPowerMode.pollEvery)
        XCTAssertEqual(answers, [nil])
        XCTAssertTrue(connection.holders.isEmpty)
        XCTAssertEqual(wire.disconnects, 1, "nobody else was holding it")
        XCTAssertFalse(scheduled.contains { $0.after == HelperPowerMode.pollEvery }, "went on asking after the answer")
    }

    /// Held from a successful enter until the restore: that is what the helper's rule on a closed connection rests on.
    func testTheConnectionIsHeldFromASuccessfulEnterUntilTheRestoreAnswers() {
        helperTakesIt(before: 21)
        _ = enter()
        XCTAssertEqual(connection.holders, [.powerMode])
        XCTAssertEqual(wire.disconnects, 0, "the socket was let go with the mode still on")

        var restored: [Bool] = []
        mode.restore(21) { restored.append($0) }
        XCTAssertEqual(restored, [true])
        XCTAssertEqual(wire.sent, [.enterLowPowerMode, .powerModeResult, .restorePowerMode(before: 21), .powerModeResult])
        XCTAssertTrue(connection.holders.isEmpty)
        XCTAssertEqual(wire.disconnects, 1, "nobody else was holding it")
    }

    /// Someone else holding the socket keeps it open after the restore.
    func testTheSocketStaysOpenForSomeoneElseAfterTheRestore() {
        helperTakesIt(before: 21)
        connection.connect(for: .fans) { _ in }
        _ = enter()
        mode.restore(21) { _ in }
        XCTAssertEqual(connection.holders, [.fans])
        XCTAssertEqual(wire.disconnects, 0)
    }

    /// A refusal at once (a job is already running, a Mac with no Low Power Mode is a failed result and not this).
    func testAnEnterTheHelperRefusesAnswersNilAndLetsGoOfTheSocket() {
        helper.refusesStart = PowerModeRefusal.busy.message
        XCTAssertEqual(enter(), [nil])
        XCTAssertEqual(wire.sent, [.enterLowPowerMode], "asked for the result of a job that was never started")
        XCTAssertTrue(connection.holders.isEmpty)
        XCTAssertEqual(wire.disconnects, 1)
    }

    func testAnEnterThatFailsInTheHelperAnswersNilAndLetsGoOfTheSocket() {
        helper.failsWith = PowerModeRefusal.noLowPowerMode.message
        XCTAssertEqual(enter(), [nil])
        XCTAssertTrue(connection.holders.isEmpty)
        XCTAssertEqual(wire.disconnects, 1)
    }

    /// An answer that says yes and carries nothing that is a power mode is not taken for one.
    func testAYesWithNoUsablePowerModeIsNotTakenForOne() {
        for reply in [FanReply(ok: true, message: "on"), FanReply(ok: true, message: "on", powerModeBefore: 77),
                      FanReply(ok: true, message: "on", powerModeBefore: -1)] {
            wire.reply = { command in command == .powerModeResult ? reply : FanReply(ok: true, message: "started") }
            XCTAssertEqual(enter(), [nil], "\(reply)")
            XCTAssertTrue(connection.holders.isEmpty)
        }
    }

    // ── A helper that is too old, or not there, is never sent these ─────────

    /// The commands are not in a helper at 3's vocabulary: it closes the connection on one it cannot decode, which hands
    /// the fans back, ends a discharge and drops the Ready By plan. So the hello is read first, every time.
    func testAnOlderHelperIsNeverSentEitherCommand() {
        for version in [3, 2, nil] as [Int?] {
            let wire = ScriptedWire()
            wire.answerAtOnce = .connected(fanCount: 1, version: version)
            let connection = HelperConnection(wire: wire)
            let mode = makeMode(over: connection)
            var entered: [Int?] = [], restored: [Bool] = []
            mode.enterLowPower { entered.append($0) }
            mode.restore(21) { restored.append($0) }
            let label = "protocol \(version.map(String.init) ?? "none")"
            XCTAssertEqual(entered, [nil], label)
            XCTAssertEqual(restored, [false], label)
            XCTAssertTrue(wire.sent.isEmpty, "\(label): a command a helper cannot decode was put on its socket: \(wire.sent)")
            XCTAssertTrue(connection.holders.isEmpty, label)
        }
    }

    /// Even when `availability` had said ready: it is a guess, the hello is the answer.
    func testAnInstalledHelperThatTurnsOutOldIsNotSentAnythingEither() {
        XCTAssertEqual(mode.availability, .ready)
        wire.answerAtOnce = .connected(fanCount: 1, version: 3)
        XCTAssertEqual(enter(), [nil])
        XCTAssertTrue(wire.sent.isEmpty)
    }

    func testNoHelperAnswersNilAndSendsNothing() {
        wire.answerAtOnce = .notRunning
        var entered: [Int?] = [], restored: [Bool] = []
        mode.enterLowPower { entered.append($0) }
        mode.restore(2) { restored.append($0) }
        XCTAssertEqual(entered, [nil])
        XCTAssertEqual(restored, [false])
        XCTAssertTrue(wire.sent.isEmpty)
        XCTAssertTrue(connection.holders.isEmpty)
    }

    func testAnInstallUnderWayAnswersOnceAndSendsNothing() {
        connection.suspend()
        var entered: [Int?] = []
        mode.enterLowPower { entered.append($0) }
        XCTAssertEqual(entered, [nil])
        XCTAssertTrue(wire.sent.isEmpty)
        XCTAssertTrue(connection.holders.isEmpty)
        connection.resume()
    }

    // ── Bounded, and exactly once ───────────────────────────────────────────

    /// The controller waits on this answer: it comes when the time is up whatever the helper does, and only once.
    func testTheAnswerIsBoundedAndComesOnce() {
        wire.answerAtOnce = nil          // the helper does not answer the hello
        var answers: [Int?] = []
        mode.enterLowPower { answers.append($0) }
        XCTAssertEqual(answers, [])
        XCTAssertEqual(HelperPowerMode.answerWithin, 3)
        XCTAssertEqual(scheduled.map(\.after).sorted(), [HelperPowerMode.answerWithin, HelperPowerMode.watchWithin])
        XCTAssertLessThanOrEqual(HelperPowerMode.answerWithin, 10, "the session waits on this")
        fire(HelperPowerMode.answerWithin)
        XCTAssertEqual(answers, [nil])
        XCTAssertTrue(connection.holders.isEmpty, "the socket was kept for an answer nobody is waiting for")
        // The hello is answered after all: nothing is sent, and nothing is answered twice.
        wire.answerConnects(.connected(fanCount: 1, version: 4), reopened: true)
        XCTAssertEqual(answers, [nil])
        XCTAssertTrue(wire.sent.isEmpty)
        fire(HelperPowerMode.watchWithin)
        XCTAssertEqual(answers, [nil])
    }

    func testTheTimeIsNotWaitedOutWhenTheAnswerComes() {
        helperTakesIt(before: 12)
        var answers: [Int?] = []
        mode.enterLowPower { answers.append($0) }
        XCTAssertEqual(answers, [12])
        scheduled.forEach { $0.work() }
        XCTAssertEqual(answers, [12], "answered again when the time was up")
        XCTAssertEqual(connection.holders, [.powerMode], "the mode is on and the socket was let go")
    }

    /// Three seconds without an end: the answer is nil. The helper was started, though, and may well take it: the enter is
    /// still watched, and a "before" that comes after is put back at once, because nobody recorded the mode.
    func testAnAnswerThatComesAfterTheTimeIsPutBack() {
        let late = DeferredWire()
        let connection = HelperConnection(wire: late)
        let mode = makeMode(over: connection)
        var answers: [Int?] = []
        mode.enterLowPower { answers.append($0) }
        XCTAssertEqual(late.sent, [.enterLowPowerMode, .powerModeResult])
        fire(HelperPowerMode.answerWithin)
        XCTAssertEqual(answers, [nil])
        XCTAssertEqual(connection.holders, [.powerMode], "let go while the helper may still be switching the mode on")
        fire(HelperPowerMode.pollEvery)
        XCTAssertEqual(late.sent.last, .powerModeResult, "stopped asking when the time was up")

        late.result = FanReply(ok: true, message: "Low Power Mode is on", powerModeBefore: 12)
        fire(HelperPowerMode.pollEvery)
        XCTAssertEqual(answers, [nil], "answered twice")
        XCTAssertEqual(late.sent.suffix(2), [.powerModeResult, .restorePowerMode(before: 12)])
        XCTAssertTrue(connection.holders.isEmpty, "the claim was kept after the mode was put back")
        XCTAssertFalse(scheduled.contains { $0.after == HelperPowerMode.pollEvery }, "went on asking")
    }

    /// A late answer that is a failure puts nothing back, and lets go.
    func testALateFailureIsNotPutBackAndTheSocketIsLetGo() {
        let late = DeferredWire()
        let connection = HelperConnection(wire: late)
        let mode = makeMode(over: connection)
        mode.enterLowPower { _ in }
        fire(HelperPowerMode.answerWithin)
        late.result = FanReply(ok: false, message: PowerModeRefusal.notTaken.message)
        fire(HelperPowerMode.pollEvery)
        XCTAssertFalse(late.sent.contains { if case .restorePowerMode = $0 { return true } else { return false } })
        XCTAssertTrue(connection.holders.isEmpty)
    }

    /// The watch ends: nothing more is asked, and the claim is let go (which closes the socket if nobody else holds it, so
    /// that the helper puts back whatever it holds).
    func testTheWatchForALateAnswerEndsAndLetsGo() {
        let late = DeferredWire()
        let connection = HelperConnection(wire: late)
        let mode = makeMode(over: connection)
        mode.enterLowPower { _ in }
        fire(HelperPowerMode.answerWithin)
        fire(HelperPowerMode.watchWithin)
        XCTAssertTrue(connection.holders.isEmpty)
        XCTAssertEqual(late.disconnects, 1)
        let asked = late.sent.count
        fire(HelperPowerMode.pollEvery)
        XCTAssertEqual(late.sent.count, asked, "went on asking after the watch ended")
    }

    /// The watch is longer than the helper's worst case, which is what makes it a watch for the answer and not for nothing.
    func testTheWatchOutlastsTheHelpersSlowestSwitchOn() {
        XCTAssertGreaterThan(HelperPowerMode.watchWithin, PowerModeSwitch.slowestRolledBackEnter + 2)
        XCTAssertGreaterThan(HelperPowerMode.watchWithin, HelperPowerMode.answerWithin)
    }

    // ── A restore: started, then asked for ──────────────────────────────────

    /// `restore` can be asked from the work queue (recovery at launch): the connection is the main thread's.
    func testARestoreAskedOffTheMainThreadIsAnsweredOnIt() {
        helperTakesIt()
        let answered = expectation(description: "restored")
        var onMain: Bool?
        DispatchQueue.global().async {
            self.mode.restore(21) { _ in
                onMain = Thread.isMainThread
                answered.fulfill()
            }
        }
        wait(for: [answered], timeout: 3)
        XCTAssertEqual(onMain, true)
        XCTAssertEqual(wire.sent, [.restorePowerMode(before: 21), .powerModeResult])
    }

    /// After a crash nothing is held and the helper remembers nothing: the restore connects, sends the packed value from
    /// the record, asks how it ended, and lets go.
    func testARestoreWithNothingHeldConnectsSendsAsksAndLetsGo() {
        var restored: [Bool] = []
        mode.restore(20) { restored.append($0) }
        XCTAssertEqual(restored, [true])
        XCTAssertEqual(wire.sent, [.restorePowerMode(before: 20), .powerModeResult])
        XCTAssertTrue(connection.holders.isEmpty)
    }

    func testARestoreAsksEveryTwoTenthsOfASecondUntilTheHelperSaysDone() {
        helper.pendingAsks = 2
        var restored: [Bool] = []
        mode.restore(20) { restored.append($0) }
        XCTAssertEqual(restored, [])
        XCTAssertEqual(connection.holders, [.powerMode], "let go before the put-back was done")
        fire(HelperPowerMode.pollEvery)
        XCTAssertEqual(restored, [])
        fire(HelperPowerMode.pollEvery)
        XCTAssertEqual(restored, [true])
        XCTAssertEqual(wire.sent, [.restorePowerMode(before: 20), .powerModeResult, .powerModeResult, .powerModeResult])
        XCTAssertTrue(connection.holders.isEmpty)
    }

    func testARestoreTheHelperRefusesOrFailsAnswersFalseAndStillLetsGo() {
        for refuse in [true, false] {
            helper = ScriptedHelper()
            if refuse { helper.refusesStart = PowerModeRefusal.busy.message } else { helper.failsWith = PowerModeRefusal.notTaken.message }
            wire.reply = { [unowned self] command in helper.answer(command) }
            var restored: [Bool] = []
            mode.restore(20) { restored.append($0) }
            XCTAssertEqual(restored, [false], "refused: \(refuse)")
            XCTAssertTrue(connection.holders.isEmpty, "letting go is the helper's own second try")
        }
    }

    /// Three seconds without an end: false, and let go, so that a put-back the helper has not finished is its own, when the
    /// socket closes.
    func testARestoreThatIsNotAnsweredInThreeSecondsAnswersFalseOnceAndLetsGo() {
        helper.pendingAsks = Int.max
        var restored: [Bool] = []
        mode.restore(20) { restored.append($0) }
        XCTAssertEqual(restored, [])
        fire(HelperPowerMode.answerWithin)
        XCTAssertEqual(restored, [false])
        XCTAssertTrue(connection.holders.isEmpty)
        fire(HelperPowerMode.pollEvery)
        XCTAssertEqual(restored, [false], "answered twice")
    }

    // ── The shared connection ───────────────────────────────────────────────

    /// The charge feature holds its own claim and relies on the socket not being closed or reset while it does. An enter, a
    /// poll that times out, a late watch that ends, and a restore leave it alone: no reset recorded, no close, no new socket.
    func testAnotherHoldersConnectionIsLeftUntouchedByAnEnterATimedOutPollAndARestore() {
        connection.connect(for: .charge) { _ in }
        let resets = connection.resets
        let connects = wire.connectsAsked
        let status = connection.status

        helper.pendingAsks = Int.max
        var answers: [Int?] = []
        mode.enterLowPower { answers.append($0) }
        fire(HelperPowerMode.answerWithin)
        XCTAssertEqual(answers, [nil], "the poll timed out")
        fire(HelperPowerMode.pollEvery)
        fire(HelperPowerMode.watchWithin)
        helper = ScriptedHelper()
        helper.before = 21
        wire.reply = { [unowned self] command in helper.answer(command) }
        var entered: [Int?] = []
        mode.enterLowPower { entered.append($0) }
        XCTAssertEqual(entered, [21])
        var restored: [Bool] = []
        mode.restore(21) { restored.append($0) }
        XCTAssertEqual(restored, [true])

        XCTAssertEqual(connection.holders, [.charge], "the other holder's claim was let go, or this one was kept")
        XCTAssertEqual(connection.resets, resets, "a reset was recorded: the socket the other holder relies on went")
        XCTAssertEqual(wire.disconnects, 0, "the socket was closed under the other holder")
        XCTAssertEqual(connection.status, status)
        XCTAssertEqual(wire.connectsAsked, connects + 3, "a hello each (an enter, an enter, a restore), never a new socket")
        XCTAssertTrue(wire.open)
    }

    /// A helper that goes while an enter is being asked for: nothing is sent to a socket that is not there, and no socket
    /// is opened to send it on.
    func testAHelperThatGoesWhileAnEnterIsPolledIsNotSentToAndNoSocketIsOpened() {
        helper.pendingAsks = Int.max
        var answers: [Int?] = []
        mode.enterLowPower { answers.append($0) }
        XCTAssertEqual(wire.sent, [.enterLowPowerMode, .powerModeResult])
        let connects = wire.connectsAsked
        wire.peerCloses()                    // the helper closed the socket between exchanges
        fire(HelperPowerMode.pollEvery)
        XCTAssertEqual(answers, [nil])
        XCTAssertEqual(wire.sent.count, 2, "a command was sent with no connection")
        XCTAssertEqual(wire.connectsAsked, connects, "a socket was opened to send it on")
        XCTAssertTrue(connection.holders.isEmpty)
    }

    // ── The wire form ───────────────────────────────────────────────────────

    /// The commands round trip in `ChargeHelperTestsWatch`, beside the charge ones; this is the answer that carries the
    /// mode before.
    func testTheAnswerThatCarriesTheModeBeforeRoundTripsOverTheWire() throws {
        let answer = FanReply(ok: true, message: "Low Power Mode is on", powerModeBefore: 21)
        var line = try FanWire.encode(answer)
        line.removeLast()
        XCTAssertEqual(try FanWire.decode(FanReply.self, from: line), answer)
    }

    /// Every reply the helper gave before still reads, and still writes, the same: the new field is absent unless set.
    func testAnAnswerWithoutAPowerModeIsWrittenAndReadAsItAlwaysWas() throws {
        let plain = FanReply(ok: true, message: "fan helper ready", fanCount: 2, version: 4)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any]
        XCTAssertEqual(Set((object ?? [:]).keys), ["ok", "message", "fanCount", "version"])
        let old = Data(#"{"ok":true,"message":"fan helper ready","fanCount":2,"version":3}"#.utf8)
        let read = try JSONDecoder().decode(FanReply.self, from: old)
        XCTAssertEqual(read, FanReply(ok: true, message: "fan helper ready", fanCount: 2, version: 3))
        XCTAssertNil(read.powerModeBefore)
    }

    /// The commands that exist are written exactly as they were: a helper at 2 or 3 reads every one of them.
    func testEveryOlderCommandIsStillWrittenExactlyAsItWas() throws {
        let at = Date(timeIntervalSinceReferenceDate: 1000)
        let expected: [(FanCommand, String)] = [
            (.setTarget(FanTarget(index: 0, rpm: 5000)), #"{"setTarget":{"_0":{"rpm":5000,"index":0}}}"#),
            (.releaseAll, #"{"releaseAll":{}}"#),
            (.setChargeLimit(63), #"{"setChargeLimit":{"_0":63}}"#),
            (.discharge(toPercent: 40), #"{"discharge":{"toPercent":40}}"#),
            (.stopDischarge, #"{"stopDischarge":{}}"#),
            (.scheduleChargeLimit(limit: 80, at: at), #"{"scheduleChargeLimit":{"limit":80,"at":1000}}"#),
            (.cancelScheduledChargeLimit, #"{"cancelScheduledChargeLimit":{}}"#),
        ]
        for (command, json) in expected {
            let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? NSDictionary
            let wanted = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary
            XCTAssertEqual(written, wanted, "\(command)")
            XCTAssertEqual(try JSONDecoder().decode(FanCommand.self, from: Data(json.utf8)), command)
        }
    }
}

// ── A session, end to end ───────────────────────────────────────────────────

/// The real controller with the real `HelperPowerMode`, over a scripted wire, and made-up parts for everything else: what
/// the owner sees after one session against a helper of each kind. Nothing reaches the Mac.
final class UltraPowerModeSessionTests: XCTestCase {

    private typealias Rig = UltraLowPowerControllerTests

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        (defaults, suiteName) = try TestDefaults.make(owner: "UltraPowerModeSession", test: name)
    }

    override func tearDownWithError() throws {
        TestDefaults.destroy(defaults, suiteName)
    }

    private struct Session {
        let controller: UltraLowPowerController
        let confirm: Rig.FakeConfirm
        let store: Rig.FakeStore
    }

    private func session(over power: PowerModeControlling) -> Session {
        let calls = Rig.Calls()
        let store = Rig.FakeStore(calls)
        let confirm = Rig.FakeConfirm()
        func proc(_ pid: pid_t, _ path: String, _ bundle: String, _ name: String) -> UltraProcess {
            UltraProcess(pid: pid, parent: 1, uid: 501, startTime: UInt64(pid) * 10, path: path, app: .regular,
                         bundleID: bundle, name: name)
        }
        let world = [proc(1000, "/Applications/Anode.app/Contents/MacOS/Anode", "dev.example.self", "Anode"),
                     proc(10, "/Applications/Editor.app/Contents/MacOS/Editor", "com.example.editor", "Editor"),
                     proc(20, "/Applications/Browser.app/Contents/MacOS/Browser", "com.example.browser", "Browser")]
        let controller = UltraLowPowerController(
            settings: Settings(defaults: defaults), processes: Rig.FakeProcesses(world), freezer: Rig.FakeFreezer(calls),
            hider: Rig.FakeHider(calls), backlight: Rig.FakeBacklight(calls), ownBrightness: OwnBrightness(),
            rate: Rig.FakeRate(calls), keyboard: Rig.FakeKeyboard(calls), power: power, watchdog: Rig.FakeWatchdog(calls),
            store: store, confirm: confirm, load: Rig.FakeLoad(calls), lastOtherFrontApp: { 10 }, ownPIDs: { [1000] },
            user: 501, work: { $0() }, schedule: { _, _ in }, log: { _ in })
        return Session(controller: controller, confirm: confirm, store: store)
    }

    /// Every owner has the helper installed before this release, which speaks 3, and nothing has greeted it yet this
    /// run. The one session they start must say the helper is an older one and offer the install, not say it refused.
    func testTheFirstSessionAgainstAHelperThatSpeaksThreeSaysItIsOldAndOffersTheInstall() {
        let wire = ScriptedWire()
        wire.answerAtOnce = .connected(fanCount: 1, version: 3)
        let connection = HelperConnection(wire: wire)
        let power = HelperPowerMode(connection: connection, isInstalled: { true }, schedule: { _, _ in })
        XCTAssertEqual(power.availability, .ready, "installed, and not heard from yet")
        let s = session(over: power)
        s.controller.request()
        s.confirm.press(true)
        XCTAssertEqual(s.controller.state, .on)
        XCTAssertEqual(s.controller.skipped, [.lowPowerOldHelper])
        XCTAssertTrue(wire.sent.isEmpty, "a command was put on the socket of a helper that cannot read it")
        XCTAssertTrue(connection.holders.isEmpty)
        XCTAssertNil(s.store.record?.powerModeBefore)
        let lines = UltraLowPowerFeature.describe(s.controller.skipped)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("an older one"), lines[0])
        XCTAssertTrue(lines[0].contains("Install Helper\u{2026}"), lines[0])
        s.controller.turnOff()
    }

    /// A helper that speaks 4 is asked, the mode before is on the record, the socket is held, and turning the mode off
    /// puts it back and lets the socket go.
    func testASessionAgainstAHelperThatSpeaksFourRecordsTheModeAndPutsItBack() {
        let wire = ScriptedWire()
        wire.answerAtOnce = .connected(fanCount: 1, version: 4)
        let helper = ScriptedHelper()
        helper.before = 21
        wire.reply = { helper.answer($0) }
        let connection = HelperConnection(wire: wire)
        let power = HelperPowerMode(connection: connection, isInstalled: { true }, schedule: { _, _ in })
        let s = session(over: power)
        s.controller.request()
        s.confirm.press(true)
        XCTAssertEqual(s.controller.state, .on)
        XCTAssertEqual(s.controller.skipped, [])
        XCTAssertEqual(s.store.record?.powerModeBefore, 21)
        XCTAssertEqual(connection.holders, [.powerMode], "held while the mode is on")
        s.controller.turnOff()
        XCTAssertEqual(wire.sent, [.enterLowPowerMode, .powerModeResult, .restorePowerMode(before: 21), .powerModeResult])
        XCTAssertTrue(connection.holders.isEmpty)
    }
}

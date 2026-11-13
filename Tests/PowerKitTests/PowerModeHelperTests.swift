import XCTest
@testable import PowerKit

// The helper's Low Power Mode: two commands (`enterLowPowerMode`, `restorePowerMode`), one tool (`pmset`, through a
// runner the server is handed), and the rule every other thing the helper holds follows: what a client switched on
// goes back when that client goes.
//
// NOTHING HERE MAY RUN `pmset`. The server is given a `FakePmset`, a table in memory that prints what `pmset -g custom`
// prints and takes what `pmset -b|-c <key> <digit>` writes, and refuses any other command line. Only the helper's own
// `main` is handed `SystemPowerModeRunner`; a server built anywhere else has no runner and refuses both commands.
//
// The classes match `--filter PowerModeHelper`.

/// `pmset` as a table. `-g custom` prints a section for each power source the Mac has, with the key this Mac has; a
/// write changes the value, and is refused unless it is exactly `-b|-c <this Mac's key> <digit>`.
final class FakePmset: PowerModeRunner {
    struct Call: Equatable {
        let arguments: [String]
        let limit: TimeInterval
        /// How it ended: nil is a call that was never answered (the runner would have had to end the tool).
        let status: Int32?
    }

    private let lock = NSLock()
    private var _key: String?
    private var _values: [String: Int]
    private var _companion: Bool
    private var _calls: [Call] = []
    private var _writes: [[String]] = []
    private var _unexpected: [[String]] = []
    private var _refusedFlags: Set<String> = []
    private var _landsButFails: [String: Int] = [:]
    private var _writeAttempts = 0
    private var _failingAttempts: Set<Int> = []
    private var _writesAllowed: Int?
    private var _readFails = false
    private var _readStatus: Int32 = 0
    private var _silent = false

    /// `key` is what `-g custom` lists (nil: neither key). `battery` and `charger` are each source's value; nil is a Mac
    /// with no such source. `companion` also prints `lowpowermode 0` beside `powermode`, as a Mac with both does.
    init(key: String? = "powermode", battery: Int? = 2, charger: Int? = 0, companion: Bool = false) {
        _key = key
        _companion = companion
        _values = [:]
        if let battery { _values["-b"] = battery }
        if let charger { _values["-c"] = charger }
    }

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    /// Every write that was taken, in order.
    var writes: [[String]] { lock.lock(); defer { lock.unlock() }; return _writes }
    /// Every command line that was neither a read nor a legal write: always empty in a passing test.
    var unexpected: [[String]] { lock.lock(); defer { lock.unlock() }; return _unexpected }
    func value(_ flag: String) -> Int? { lock.lock(); defer { lock.unlock() }; return _values[flag] }
    var battery: Int? { value("-b") }
    var charger: Int? { value("-c") }

    /// The owner changing the mode in System Settings: not a write the helper made.
    func ownerSets(_ flag: String, _ value: Int) { lock.lock(); _values[flag] = value; lock.unlock() }
    /// A write to this source is refused.
    func refuseWrites(to flag: String) { lock.lock(); _refusedFlags.insert(flag); lock.unlock() }
    func acceptWritesAgain() { lock.lock(); _refusedFlags = []; _landsButFails = [:]; _writesAllowed = nil; lock.unlock() }
    /// The next `times` writes to this source take effect and are reported as failed: a tool that was cut off after it had
    /// done the work.
    func writesLandButFail(for flag: String, times: Int = 1) { lock.lock(); _landsButFails[flag] = times; lock.unlock() }
    /// The writes numbered like this (1 is the first the tool is asked for) take effect and are reported as failed: a tool
    /// that was cut off after it had done the work, at the moments a test chooses.
    func writesNumberedLandButFail(_ numbers: Set<Int>) { lock.lock(); _failingAttempts = numbers; lock.unlock() }
    /// This many more writes are taken, and every one after them is refused.
    func allowWrites(_ n: Int) { lock.lock(); _writesAllowed = n; lock.unlock() }
    /// The tool does not finish in time (the runner's answer for it).
    var neverAnswers: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _silent }
        set { lock.lock(); _silent = newValue; lock.unlock() }
    }
    /// The read exits with this status.
    func readExits(with status: Int32) { lock.lock(); _readFails = status != 0; _readStatus = status; lock.unlock() }

    private func section(_ title: String, _ flag: String) -> String {
        guard let v = _values[flag] else { return "" }
        var out = "\(title):\n lidwake              1\n sleep                1\n"
        if _companion { out += " lowpowermode         0\n" }
        if let key = _key { out += " \(key)            \(v)\n" }
        out += " displaysleep         2\n"
        return out
    }

    func run(_ arguments: [String], within limit: TimeInterval) -> PowerModeRun? {
        lock.lock(); defer { lock.unlock() }
        let result = answer(arguments)
        _calls.append(Call(arguments: arguments, limit: limit, status: result?.status))
        return result
    }

    private func answer(_ arguments: [String]) -> PowerModeRun? {
        if _silent { return nil }
        if arguments == ["-g", "custom"] {
            if _readFails { return PowerModeRun(status: _readStatus, output: "") }
            return PowerModeRun(status: 0, output: section("Battery Power", "-b") + section("AC Power", "-c"))
        }
        guard arguments.count == 3, ["-b", "-c"].contains(arguments[0]), let key = _key, arguments[1] == key,
              let digit = Int(arguments[2]), arguments[2] == String(digit),
              (0...(key == "powermode" ? 2 : 1)).contains(digit), _values[arguments[0]] != nil else {
            _unexpected.append(arguments)
            return PowerModeRun(status: 1, output: "")
        }
        _writeAttempts += 1
        if _failingAttempts.contains(_writeAttempts) {
            _values[arguments[0]] = digit
            _writes.append(arguments)
            return PowerModeRun(status: 1, output: "")
        }
        if _refusedFlags.contains(arguments[0]) || _writesAllowed == 0 {
            return PowerModeRun(status: 1, output: "")
        }
        if let n = _writesAllowed { _writesAllowed = n - 1 }
        _values[arguments[0]] = digit
        _writes.append(arguments)
        let lands = (_landsButFails[arguments[0]] ?? 0) > 0
        if lands { _landsButFails[arguments[0]] = (_landsButFails[arguments[0]] ?? 1) - 1 }
        return PowerModeRun(status: lands ? 1 : 0, output: "")
    }
}

/// A `pmset` that holds every call until the test lets it go: the tool as it is when it hangs. It ignores the limit it is
/// given, which is what a runner that overruns its own bound looks like from outside. Calls that go through are answered
/// by the table behind it.
final class GatedPmset: PowerModeRunner {
    let table: FakePmset
    private let condition = NSCondition()
    private var held = false
    private var inside = 0
    private var arrived = 0

    init(_ table: FakePmset = FakePmset()) { self.table = table }

    /// From now on a call waits at the gate until `release()`.
    func hold() { condition.lock(); held = true; condition.unlock() }

    func release() { condition.lock(); held = false; condition.broadcast(); condition.unlock() }

    /// Calls waiting at the gate right now.
    var waiting: Int { condition.lock(); defer { condition.unlock() }; return inside }
    /// Calls that have reached `run`, held or not.
    var calls: Int { condition.lock(); defer { condition.unlock() }; return arrived }

    func run(_ arguments: [String], within limit: TimeInterval) -> PowerModeRun? {
        condition.lock()
        arrived += 1
        if held {
            inside += 1
            while held { condition.wait() }
            inside -= 1
        }
        condition.unlock()
        return table.run(arguments, within: limit)
    }
}

final class PowerModeHelperTests: XCTestCase {

    private var pmset: FakePmset!
    private var lines: [String] = []

    override func setUp() {
        super.setUp()
        pmset = FakePmset()
        lines = []
    }

    private func makeServer(withRunner: Bool = true, runner: PowerModeRunner? = nil) -> FanHelperServer {
        FanHelperServer(
            hardware: FakeFans([:]),
            configuration: .init(socketPath: NSTemporaryDirectory() + "bs-unused.sock", ownerUID: getuid(),
                                 pin: .signingIdentifier(FanDaemon.clientSigningIdentifier)),
            log: { [weak self] in self?.lines.append($0) },
            powerMode: withRunner ? (runner ?? pmset) : nil)
    }

    private let started = FanReply(ok: true, message: "started")

    /// A client's enter, as the app makes it: the command answers "started" at once (or is refused), and how it ended is
    /// asked for once the worker has finished. The test stands in for the loop, which is what reads the worker's notice.
    private func enter(_ server: FanHelperServer) -> FanReply {
        let started = server.handle(.command(.enterLowPowerMode))
        return started.ok ? finished(server) : started
    }

    private func restore(_ server: FanHelperServer, _ before: Int) -> FanReply {
        let started = server.handle(.command(.restorePowerMode(before: before)))
        return started.ok ? finished(server) : started
    }

    /// `powerModeResult`, once the worker has run what it was given and the loop has read the outcome.
    private func finished(_ server: FanHelperServer) -> FanReply {
        server.settlePowerModeWork(within: 3)
        return server.handle(.command(.powerModeResult))
    }

    // ── Entering ────────────────────────────────────────────────────────────

    func testLowPowerRemembersTheModeBeforeAndRepliesWithIt() {
        let server = makeServer()
        let reply = enter(server)       // battery 2 (high), charger 0 (automatic)
        XCTAssertTrue(reply.ok, reply.message)
        XCTAssertEqual(reply.powerModeBefore, 2, "battery + 10 * charger")
        XCTAssertEqual(pmset.writes, [["-b", "powermode", "1"], ["-c", "powermode", "1"]])
        XCTAssertEqual(pmset.battery, 1)
        XCTAssertEqual(pmset.charger, 1)
        XCTAssertEqual(server.heldPowerModes, PowerModes(battery: 2, charger: 0))
        XCTAssertTrue(pmset.unexpected.isEmpty, "\(pmset.unexpected)")
    }

    func testTheBatteryAndTheChargerAreEachPackedInTheirOwnDigit() {
        pmset = FakePmset(battery: 0, charger: 2)
        XCTAssertEqual(enter(makeServer()).powerModeBefore, 20)
        pmset = FakePmset(battery: 2, charger: 1)
        XCTAssertEqual(enter(makeServer()).powerModeBefore, 12)
    }

    /// If low power was already on for a source, that source is not written and is left exactly as it was at the end.
    func testASourceAlreadyInLowPowerIsNeverWrittenAndEndsAsItWas() {
        pmset = FakePmset(battery: 1, charger: 2)
        let server = makeServer()
        let reply = enter(server)
        XCTAssertEqual(reply.powerModeBefore, 21)
        XCTAssertEqual(pmset.writes, [["-c", "powermode", "1"]], "the battery was already low")
        XCTAssertTrue(restore(server, 21).ok)
        XCTAssertEqual(pmset.writes, [["-c", "powermode", "1"], ["-c", "powermode", "2"]], "only what was switched on")
        XCTAssertEqual(pmset.battery, 1)
        XCTAssertEqual(pmset.charger, 2)
    }

    func testTheKeyIsTheOneThisMacHas() {
        pmset = FakePmset(key: "lowpowermode", battery: 0, charger: 0)
        let server = makeServer()
        XCTAssertEqual(enter(server).powerModeBefore, 0)
        XCTAssertEqual(pmset.writes, [["-b", "lowpowermode", "1"], ["-c", "lowpowermode", "1"]])
        XCTAssertTrue(restore(server, 0).ok)
        XCTAssertEqual(pmset.writes.suffix(2), [["-b", "lowpowermode", "0"], ["-c", "lowpowermode", "0"]])
        XCTAssertTrue(pmset.unexpected.isEmpty)
    }

    /// A Mac that lists both keys is read, and written, by the one with three values.
    func testPowermodeIsPreferredWhenAMacListsBothKeys() {
        pmset = FakePmset(key: "powermode", battery: 2, charger: 2, companion: true)
        _ = enter(makeServer())
        XCTAssertEqual(pmset.writes, [["-b", "powermode", "1"], ["-c", "powermode", "1"]])
    }

    /// A Mac with one power source (a desktop): the source it does not have is never written, and packs as 0.
    func testAMacWithOnePowerSourceIsHandledAndTheMissingOneIsNeverWritten() {
        pmset = FakePmset(battery: nil, charger: 2)
        let server = makeServer()
        XCTAssertEqual(enter(server).powerModeBefore, 20)
        XCTAssertEqual(pmset.writes, [["-c", "powermode", "1"]])
        XCTAssertTrue(restore(server, 20).ok)
        XCTAssertEqual(pmset.writes.last, ["-c", "powermode", "2"])
        XCTAssertEqual(pmset.writes.count, 2)
        XCTAssertFalse(pmset.calls.contains { $0.arguments.first == "-b" }, "a source this Mac has not was written")
    }

    func testAMacWithNoLowPowerModeIsToldSoAndNothingIsWritten() {
        pmset = FakePmset(key: nil)
        let server = makeServer()
        let reply = enter(server)
        XCTAssertEqual(reply, FanReply(ok: false, message: PowerModeRefusal.noLowPowerMode.message))
        XCTAssertTrue(pmset.writes.isEmpty)
        XCTAssertNil(server.heldPowerModes)
    }

    func testAMacThatCannotBeReadIsRefusedWithNothingWritten() {
        for unreadable in [{ self.pmset.neverAnswers = true }, { self.pmset.readExits(with: 1) }] {
            pmset = FakePmset()
            unreadable()
            let server = makeServer()
            let reply = enter(server)
            XCTAssertEqual(reply, FanReply(ok: false, message: PowerModeRefusal.unreadable.message))
            XCTAssertTrue(pmset.writes.isEmpty)
            XCTAssertNil(server.heldPowerModes)
        }
    }

    func testAValueThisHelperDoesNotKnowIsRefusedWithNothingWritten() {
        for (key, value) in [("powermode", 3), ("powermode", -1), ("lowpowermode", 2)] {
            pmset = FakePmset(key: key, battery: value, charger: 0)
            let server = makeServer()
            XCTAssertEqual(enter(server), FanReply(ok: false, message: PowerModeRefusal.notUnderstood.message),
                           "\(key) \(value)")
            XCTAssertTrue(pmset.writes.isEmpty)
            XCTAssertNil(server.heldPowerModes)
        }
    }

    /// The second source is refused: the first is put back, the reply is a refusal, and nothing is held.
    func testAWriteThatIsRefusedIsRolledBackAndNothingIsHeld() {
        pmset.refuseWrites(to: "-c")
        let server = makeServer()
        let reply = enter(server)
        XCTAssertEqual(reply, FanReply(ok: false, message: PowerModeRefusal.notTaken.message))
        XCTAssertEqual(pmset.writes, [["-b", "powermode", "1"], ["-b", "powermode", "2"]], "the battery was not put back")
        XCTAssertEqual(pmset.battery, 2)
        XCTAssertEqual(pmset.charger, 0)
        XCTAssertNil(server.heldPowerModes)
    }

    /// A roll-back that is refused too leaves the memory, so the client going, or the helper stopping, tries again.
    func testARollBackThatFailsTooKeepsTheMemory() {
        pmset.allowWrites(1)           // the battery goes low; every write after that is refused
        let server = makeServer()
        XCTAssertFalse(enter(server).ok)
        XCTAssertEqual(pmset.battery, 1, "the helper left the battery low")
        XCTAssertEqual(server.heldPowerModes, PowerModes(battery: 2, charger: 0), "and forgot what it was")
    }

    /// The same client asking again does not read its own work as what the Mac was: the first "before" stays.
    func testEnteringTwiceKeepsTheFirstBefore() {
        let server = makeServer()
        XCTAssertEqual(enter(server).powerModeBefore, 2)
        let writesAfterTheFirst = pmset.writes.count
        let second = enter(server)
        XCTAssertTrue(second.ok)
        XCTAssertEqual(second.powerModeBefore, 2, "the second ask read the mode it had set (11) as the one before")
        XCTAssertEqual(pmset.writes.count, writesAfterTheFirst, "nothing was low-powered twice")
        XCTAssertTrue(restore(server, 2).ok)
        XCTAssertEqual(pmset.battery, 2)
        XCTAssertEqual(pmset.charger, 0)
    }

    // ── Putting it back ─────────────────────────────────────────────────────

    func testRestorePutsBackTheRememberedMode() {
        let server = makeServer()
        let before = enter(server).powerModeBefore ?? -1
        let reply = restore(server, before)
        XCTAssertTrue(reply.ok, reply.message)
        XCTAssertEqual(pmset.writes.suffix(2), [["-b", "powermode", "2"], ["-c", "powermode", "0"]])
        XCTAssertEqual(pmset.battery, 2)
        XCTAssertEqual(pmset.charger, 0)
        XCTAssertNil(server.heldPowerModes, "what is put back is not remembered any more")
    }

    /// The app's recovery after it was killed: the helper remembers nothing (it was restarted), and the packed value
    /// from the app's record is all there is.
    func testRestoreWorksWhenTheHelperRemembersNothing() {
        pmset = FakePmset(battery: 1, charger: 1)
        let server = makeServer()
        XCTAssertTrue(restore(server, 20).ok)
        XCTAssertEqual(pmset.writes, [["-b", "powermode", "0"], ["-c", "powermode", "2"]])
    }

    /// What the client's digits say is only ever acted on where a source reads low power now. A source that reads anything
    /// else is left alone whatever the digits ask, when the helper remembers nothing as when it does: the root ability is
    /// "put it back", never "set it".
    func testDigitsAskingForTwoWriteNothingToASourceThatDoesNotReadLowPower() {
        for (battery, charger) in [(0, 0), (2, 2), (0, 2), (2, 0)] {
            pmset = FakePmset(battery: battery, charger: charger)
            let server = makeServer()
            XCTAssertNil(server.heldPowerModes, "the helper remembers nothing")
            for digits in [22, 20, 2, 12, 21, 0] {
                XCTAssertTrue(restore(server, digits).ok, "\(digits) on \(battery), \(charger)")
            }
            XCTAssertTrue(pmset.writes.isEmpty, "wrote to a source that was not in low power: \(pmset.writes)")
            XCTAssertEqual(pmset.battery, battery)
            XCTAssertEqual(pmset.charger, charger)
        }
    }

    func testDigitsAskingForTwoWriteTwoToASourceThatReadsLowPowerAndNoOtherSource() {
        pmset = FakePmset(battery: 0, charger: 1)
        XCTAssertTrue(restore(makeServer(), 22).ok)
        XCTAssertEqual(pmset.writes, [["-c", "powermode", "2"]], "only the charger read low power")
        XCTAssertEqual(pmset.battery, 0)
        XCTAssertEqual(pmset.charger, 2)
        pmset = FakePmset(battery: 1, charger: 2)
        XCTAssertTrue(restore(makeServer(), 22).ok)
        XCTAssertEqual(pmset.writes, [["-b", "powermode", "2"]])
        XCTAssertEqual(pmset.charger, 2)
    }

    /// A source that no longer reads low power is the owner's own choice since: it is not this feature's to put back.
    func testRestoreLeavesASourceTheOwnerChangedSinceAlone() {
        let server = makeServer()
        _ = enter(server)
        pmset.ownerSets("-b", 2)        // the owner chose High Power while the mode was on
        XCTAssertTrue(restore(server, 2).ok)
        XCTAssertEqual(pmset.writes.filter { $0.first == "-b" }, [["-b", "powermode", "1"]], "the owner's choice was overwritten")
        XCTAssertEqual(pmset.battery, 2)
        XCTAssertEqual(pmset.charger, 0)
    }

    /// The second restore (the helper's own, then the app's after a crash) finds nothing low and writes nothing.
    func testAnotherRestoreAfterTheFirstWritesNothing() {
        let server = makeServer()
        _ = enter(server)
        XCTAssertTrue(restore(server, 2).ok)
        let writes = pmset.writes.count
        XCTAssertTrue(restore(server, 2).ok)
        XCTAssertEqual(pmset.writes.count, writes)
    }

    /// Validated before anything runs: not a power mode, not a command line, and not a single call to the tool.
    func testARestoreOfSomethingThatIsNotAPowerModeIsRefusedBeforeAnythingRuns() {
        let server = makeServer()
        for bad in [-1, 3, 9, 13, 23, 30, 100, 222, 1_000_000, Int.max, Int.min] {
            XCTAssertEqual(restore(server, bad), FanReply(ok: false, message: PowerModeRefusal.badValue.message), "\(bad)")
        }
        XCTAssertTrue(pmset.calls.isEmpty, "the tool was run for a value nobody checked: \(pmset.calls)")
    }

    /// A Mac whose key has only off and on is not asked to write a 2.
    func testATwoIsRefusedOnAMacWhoseKeyHasOnlyOffAndOn() {
        pmset = FakePmset(key: "lowpowermode", battery: 1, charger: 1)
        let server = makeServer()
        XCTAssertEqual(restore(server, 2), FanReply(ok: false, message: PowerModeRefusal.badValue.message))
        XCTAssertEqual(restore(server, 20), FanReply(ok: false, message: PowerModeRefusal.badValue.message))
        XCTAssertTrue(pmset.writes.isEmpty)
    }

    func testARestoreThatFailsKeepsTheMemoryAndSaysSo() {
        let server = makeServer()
        _ = enter(server)
        pmset.refuseWrites(to: "-b")
        XCTAssertEqual(restore(server, 2), FanReply(ok: false, message: PowerModeRefusal.notTaken.message))
        XCTAssertNotNil(server.heldPowerModes, "forgotten while the battery was still low")
        pmset.acceptWritesAgain()
        XCTAssertTrue(restore(server, 2).ok)
        XCTAssertNil(server.heldPowerModes)
        XCTAssertEqual(pmset.battery, 2)
    }

    // ── What may run, and how ───────────────────────────────────────────────

    func testAHelperWithNoRunnerRefusesBothCommands() {
        let server = makeServer(withRunner: false)
        let refusal = FanReply(ok: false, message: PowerModeRefusal.cannotChange.message)
        XCTAssertEqual(enter(server), refusal)
        XCTAssertEqual(restore(server, 2), refusal)
        XCTAssertTrue(pmset.calls.isEmpty)
    }

    /// Every command line the helper ever builds is `-g custom`, or a flag from a closed set, one of two key names and
    /// a digit it has checked: nothing taken from the output it read, nothing from the client but a number it validated.
    func testEveryCommandLineIsBuiltOnlyFromFixedStringsAndCheckedDigits() {
        let scenarios: [FakePmset] = [
            FakePmset(), FakePmset(battery: 1, charger: 2), FakePmset(key: "lowpowermode", battery: 0, charger: 1),
            FakePmset(battery: nil, charger: 0), FakePmset(key: nil),
        ]
        for scenario in scenarios {
            pmset = scenario
            let server = makeServer()
            _ = enter(server)
            _ = restore(server, 12)
            _ = restore(server, 99)
            for call in scenario.calls {
                if call.arguments == ["-g", "custom"] { continue }
                XCTAssertEqual(call.arguments.count, 3, "\(call.arguments)")
                XCTAssertTrue(["-b", "-c"].contains(call.arguments[0]), "\(call.arguments)")
                XCTAssertTrue(["powermode", "lowpowermode"].contains(call.arguments[1]), "\(call.arguments)")
                XCTAssertTrue(["0", "1", "2"].contains(call.arguments[2]), "\(call.arguments)")
            }
            XCTAssertTrue(scenario.unexpected.isEmpty, "\(scenario.unexpected)")
        }
    }

    /// Every call to the tool is handed the same bound, which is the one thing the runner enforces.
    func testEveryCallToTheToolIsHandedTheSameBound() {
        let server = makeServer()
        _ = enter(server)
        _ = restore(server, 2)
        XCTAssertFalse(pmset.calls.isEmpty)
        for call in pmset.calls { XCTAssertEqual(call.limit, PowerModeSwitch.callLimit) }
    }

    /// The link answers within 2 s of a request or closes the socket, which hands everything back. An enter that goes
    /// through, and a restore that works, make three calls each (a read and two writes); when every call finishes in the
    /// time it is given, they fit inside it.
    func testAnEnterAndARestoreInWhichEveryCallFinishesMakeThreeCallsAndSoFitInsideTheLinksTwoSeconds() {
        let server = makeServer()
        _ = enter(server)
        let enterCalls = pmset.calls.count
        _ = restore(server, 2)
        let restoreCalls = pmset.calls.count - enterCalls
        XCTAssertEqual(enterCalls, 3)
        XCTAssertEqual(restoreCalls, 3)
        XCTAssertLessThan(Double(max(enterCalls, restoreCalls)) * PowerModeSwitch.callLimit, 2.0)
    }

    /// A restore whose writes hang is three calls too (a read and two writes, each source tried), but two of them can each
    /// take `slowestCall`: 0.6 + 1.0 + 1.0 = 2.6 s, past the link's two seconds. The link closes the socket then, and what
    /// the helper holds is still held: the put-back on close is what finishes the job.
    func testARestoreWithHungWritesCanRunPastTheLinksTwoSecondsAndWhatIsHeldIsKeptForTheClose() {
        let server = makeServer()
        _ = enter(server)
        let before = pmset.calls.count
        pmset.refuseWrites(to: "-b")
        pmset.refuseWrites(to: "-c")
        XCTAssertFalse(restore(server, 2).ok)
        let calls = pmset.calls.count - before
        XCTAssertEqual(calls, 3, "a read, and each source tried once")
        XCTAssertGreaterThan(PowerModeSwitch.slowestCommand, 2.0)
        XCTAssertNotNil(server.heldPowerModes, "forgotten while both sources were still low")
    }

    /// A switch-on that fails and is rolled back is more: a read and a write that goes, a write that is refused, then the
    /// read and the put-back of what went. Five calls when the refused write did not land.
    func testAFailedEnterWhoseFailedWriteDidNotLandMakesFiveCallsAndLeavesNothingOn() {
        pmset.refuseWrites(to: "-c")
        let server = makeServer()
        XCTAssertFalse(enter(server).ok)
        XCTAssertEqual(pmset.calls.count, 5, "\(pmset.calls.map(\.arguments))")
        XCTAssertEqual(pmset.battery, 2)
        XCTAssertEqual(pmset.charger, 0)
        XCTAssertNil(server.heldPowerModes)
    }

    /// Six when it did: a write the tool was cut off after it had done the work is reported failed and is on, so the
    /// put-back writes both sources. Six is the most a command makes (two writes before the failure, two after, and a read
    /// each side). Each call can take `PowerModeSwitch.slowestCall`, so this is the command the link may not wait for; the
    /// link closes the socket and the helper's own put-back on close runs, and nothing is left on.
    func testAFailedEnterWhoseFailedWriteHadLandedMakesSixCallsAndLeavesNothingOn() {
        pmset.writesLandButFail(for: "-c")
        let server = makeServer()
        XCTAssertFalse(enter(server).ok)
        XCTAssertEqual(pmset.calls.count, 6, "\(pmset.calls.map(\.arguments))")
        XCTAssertGreaterThan(PowerModeSwitch.slowestRolledBackEnter, 2.0, "this is the case the link may not wait for")
        XCTAssertEqual(pmset.battery, 2)
        XCTAssertEqual(pmset.charger, 0)
        XCTAssertNil(server.heldPowerModes)
    }

    /// What `slowestCommand` and `slowestRolledBackEnter` add up, by the calls a command really makes. A call that was
    /// answered in time took at most `callLimit`; one that failed, or was never answered, can have been ended, and took at
    /// most `slowestCall`.
    private func slowest(_ calls: [FakePmset.Call]) -> TimeInterval {
        calls.map { $0.status == 0 ? PowerModeSwitch.callLimit : PowerModeSwitch.slowestCall }.reduce(0, +)
    }

    /// A read that has to be ended is no answer, and ends the command: so in a command that goes on, every read finished in
    /// the time it was given.
    func testAReadThatHasToBeEndedStopsTheCommand() {
        pmset.neverAnswers = true
        let server = makeServer()
        XCTAssertFalse(enter(server).ok)
        XCTAssertEqual(pmset.calls.count, 1, "\(pmset.calls.map(\.arguments))")
        XCTAssertFalse(restore(server, 2).ok)
        XCTAssertEqual(pmset.calls.count, 2, "a restore makes one call too, the read")
        XCTAssertEqual(slowest(pmset.calls), 2 * PowerModeSwitch.slowestCall)
    }

    /// The slowest command that is not a rolled-back switch-on: a read that finished, and two writes that each had to be
    /// ended (each source is tried).
    func testTheSlowestRestoreIsOneReadAndTwoWritesThatHadToBeEnded() {
        let server = makeServer()
        _ = enter(server)
        let before = pmset.calls.count
        pmset.refuseWrites(to: "-b")
        pmset.refuseWrites(to: "-c")
        XCTAssertFalse(restore(server, 2).ok)
        let calls = Array(pmset.calls.dropFirst(before))
        XCTAssertEqual(calls.map { $0.arguments.first }, ["-g", "-b", "-c"])
        XCTAssertEqual(slowest(calls), PowerModeSwitch.slowestCommand, accuracy: 1e-9)
    }

    /// The slowest switch-on that fails and is rolled back, as the code can really go: the read finishes; the first write
    /// goes; the second is cut off (it lands, and is reported failed); the read of the roll-back finishes; and both
    /// put-back writes are cut off. Six calls, three of them as slow as a call can be.
    func testTheSlowestRolledBackSwitchOnIsSixCallsOfWhichThreeHadToBeEnded() {
        pmset.writesNumberedLandButFail([2, 3, 4])
        let server = makeServer()
        XCTAssertFalse(enter(server).ok)
        XCTAssertEqual(pmset.calls.map { $0.arguments.first }, ["-g", "-b", "-c", "-g", "-b", "-c"])
        XCTAssertEqual(pmset.calls.map(\.status), [0, 0, 1, 0, 1, 1])
        XCTAssertEqual(slowest(pmset.calls), PowerModeSwitch.slowestRolledBackEnter, accuracy: 1e-9)
        XCTAssertGreaterThan(PowerModeSwitch.slowestRolledBackEnter, PowerModeSwitch.slowestCommand)
    }

    // ── Off the loop: what the loop reads, owes and answers ─────────────────

    /// The worker's outcome is the loop's to read: until the loop has acted on the notice, the answer is pending, however
    /// far the worker has got.
    func testTheAnswerIsPendingUntilTheLoopHasReadTheWorkersNotice() {
        let server = makeServer()
        XCTAssertEqual(server.handle(.command(.enterLowPowerMode)), started)
        while pmset.writes.count < 2 { Thread.sleep(forTimeInterval: 0.005) }
        Thread.sleep(forTimeInterval: 0.05)           // the notice is posted by now
        XCTAssertEqual(server.handle(.command(.powerModeResult)), FanReply(ok: true, message: "pending", pending: true))
        XCTAssertNil(server.heldPowerModes, "the worker wrote the loop's books")
        server.actOnPowerNotices()
        XCTAssertEqual(server.handle(.command(.powerModeResult)),
                       FanReply(ok: true, message: "Low Power Mode is on", powerModeBefore: 2))
        XCTAssertEqual(server.heldPowerModes, PowerModes(battery: 2, charger: 0))
    }

    /// An outcome the loop is not waiting for is ignored: a notice for a job that is not the one running.
    func testAnOutcomeForAJobTheLoopIsNotWaitingForChangesNothing() {
        let server = makeServer()
        XCTAssertEqual(enter(server), FanReply(ok: true, message: "Low Power Mode is on", powerModeBefore: 2))
        let lines = self.lines.count
        server.actOnPowerNotices()
        XCTAssertEqual(server.heldPowerModes, PowerModes(battery: 2, charger: 0))
        XCTAssertEqual(self.lines.count, lines)
    }

    /// A put-back that is owed is a job on the worker, which is not an idle helper. Idle again once it has run.
    func testAHelperIsNotIdleWithAJobRunningOrAPutBackOwedAndIsIdleOnceItHasRun() {
        let gate = GatedPmset(pmset)
        let server = makeServer(runner: gate)
        XCTAssertTrue(server.isIdle)
        gate.hold()
        XCTAssertEqual(server.handle(.command(.enterLowPowerMode)), started)
        XCTAssertFalse(server.isIdle, "a job is running on the worker")
        gate.release()
        XCTAssertTrue(finished(server).ok)
        XCTAssertTrue(server.isIdle, "no client, nothing owed, nothing running")

        gate.hold()
        server.owePowerModePutBack(because: "the client went away")
        XCTAssertTrue(server.powerModePutBackOwed)
        XCTAssertFalse(server.isIdle, "a put-back is owed and running")
        gate.release()
        server.settlePowerModeWork(within: 3)
        XCTAssertFalse(server.powerModePutBackOwed)
        XCTAssertTrue(server.isIdle, "the put-back has run")
        XCTAssertEqual(pmset.battery, 2)
        XCTAssertEqual(pmset.charger, 0)
        XCTAssertNil(server.heldPowerModes)
    }

    /// A put-back that fails is tried again from its own result, up to `putBackTries`, and then the helper stops owing it
    /// and is idle: nothing keeps it up for ever. What it remembers is kept for the stop's try, which is another go.
    func testAPutBackThatFailsItsTriesIsGivenUpAndTheHelperIsIdleAgain() {
        XCTAssertEqual(PowerModeSwitch.putBackTries, 2, "the bound is a decision: a put-back is given a second try, and no more")
        let server = makeServer()
        XCTAssertTrue(enter(server).ok)
        pmset.refuseWrites(to: "-b")
        let readsBefore = pmset.calls.filter { $0.arguments == ["-g", "custom"] }.count
        server.owePowerModePutBack(because: "the client went away")
        server.settlePowerModeWork(within: 3)
        let reads = pmset.calls.filter { $0.arguments == ["-g", "custom"] }.count - readsBefore
        XCTAssertEqual(reads, PowerModeSwitch.putBackTries, "one put-back job per try")
        XCTAssertFalse(server.powerModePutBackOwed)
        XCTAssertTrue(server.isIdle, "a put-back that cannot be made keeps the helper up for ever")
        XCTAssertNotNil(server.heldPowerModes)
        XCTAssertEqual(lines.filter { $0.contains("it is tried again when the helper stops") }.count, 1, "\(lines)")

        pmset.acceptWritesAgain()
        server.owePowerModePutBack(because: "the helper is stopping")
        server.settlePowerModeWork(within: 3)
        XCTAssertNil(server.heldPowerModes, "the stop's own try")
        XCTAssertEqual(pmset.battery, 2)
        XCTAssertTrue(server.isIdle)
    }

    /// Nothing is owed, and nothing is run, for a client that held nothing.
    func testNothingIsOwedForAClientThatSwitchedNothingOn() {
        let server = makeServer()
        server.owePowerModePutBack(because: "the client went away")
        XCTAssertFalse(server.powerModePutBackOwed)
        XCTAssertTrue(server.isIdle)
        XCTAssertTrue(pmset.calls.isEmpty)
    }

    /// A switch-on that fails cleanly leaves nothing to put back, so nothing is owed when the client goes.
    func testNothingIsOwedAfterASwitchOnThatFailedCleanly() {
        pmset.refuseWrites(to: "-c")
        let server = makeServer()
        XCTAssertFalse(enter(server).ok)
        server.owePowerModePutBack(because: "the client went away")
        XCTAssertFalse(server.powerModePutBackOwed)
        XCTAssertTrue(server.isIdle)
    }

    /// The loop breaks out of `run()` on a stop before it reads any notice, and drops every notice that is not a sleep
    /// notice on the way out. An outcome that was posted before the stop is still read, or the mode that was just switched
    /// on would be left on.
    func testAnOutcomePostedBeforeTheStopIsStillReadAndTheModeIsPutBack() throws {
        let path = NSTemporaryDirectory() + "bs-pwr-\(UUID().uuidString.prefix(8)).sock"
        let server = FanHelperServer(
            hardware: FakeFans([:]),
            configuration: .init(socketPath: path, ownerUID: getuid(),
                                 pin: .signingIdentifier(FanDaemon.clientSigningIdentifier)),
            log: { [weak self] in self?.lines.append($0) },
            powerMode: pmset)
        try server.start()
        XCTAssertEqual(server.handle(.command(.enterLowPowerMode)), started)
        while pmset.writes.count < 2 { Thread.sleep(forTimeInterval: 0.005) }
        Thread.sleep(forTimeInterval: 0.05)           // the worker has finished and posted its outcome
        server.stop()
        server.run()                                  // stopped already: leaves the loop without reading a notice
        XCTAssertEqual(pmset.battery, 2, "the mode that was switched on was left on")
        XCTAssertEqual(pmset.charger, 0)
        XCTAssertNil(server.heldPowerModes)
    }

    // ── What the stop's wait reads ──────────────────────────────────────────
    //
    // The stop waits for the worker after everything else is done, and reads the power mode's outcomes only. A charge or
    // sleep notice is the loop's to act on, and the loop has gone: the plan is dropped, the sleep notices are answered, and
    // nothing posted after that is acted on while the wait runs.

    /// A full server on a socket of its own: the charger, the plan's wake and timer as fakes, and the tool behind a gate.
    private struct Rig {
        let server: FanHelperServer
        let hw: FakeChargeHardware
        let events: FakePowerEvents
        let timer: FakeWallTimer
        let gate: GatedPmset
    }

    private func makeRig() throws -> Rig {
        let hw = FakeChargeHardware(percent: 54, onAC: true)
        let events = FakePowerEvents()
        let timer = FakeWallTimer()
        let gate = GatedPmset(pmset)
        let server = FanHelperServer(
            hardware: FakeFans([:]),
            configuration: .init(socketPath: NSTemporaryDirectory() + "bs-pwr-\(UUID().uuidString.prefix(8)).sock",
                                 ownerUID: getuid(), pin: .signingIdentifier(FanDaemon.clientSigningIdentifier)),
            log: { [weak self] in self?.lines.append($0) },
            charge: hw, powerEvents: events, wakeTimer: timer, powerMode: gate)
        server.chargeTiming = .immediate
        try server.start()
        return Rig(server: server, hw: hw, events: events, timer: timer, gate: gate)
    }

    /// `stop()` and then `run()` on a thread of its own, which leaves the loop at once and goes to the stop's wait. The
    /// semaphore is signalled when the helper has gone.
    private func stopOnAThread(_ server: FanHelperServer) -> DispatchSemaphore {
        let gone = DispatchSemaphore(value: 0)
        Thread { server.stop(); server.run(); gone.signal() }.start()
        return gone
    }

    /// A wake notice that arrives while the stop waits for the worker is not acted on: the loop has gone, and acting on it
    /// would be the loop doing its work after it has handed everything back.
    func testAWakeNoticePostedWhileTheStopWaitsIsNotActedOn() throws {
        let rig = try makeRig()
        rig.server.systemWillSleep()
        XCTAssertTrue(rig.server.systemAsleep)
        rig.gate.hold()
        XCTAssertEqual(rig.server.handle(.command(.enterLowPowerMode)), started)
        rig.server.powerModeStopWait = 3
        let gone = stopOnAThread(rig.server)
        Thread.sleep(forTimeInterval: 0.2)               // in the wait, with the tool held
        rig.server.noteSystemDidWake()
        Thread.sleep(forTimeInterval: 0.1)
        rig.gate.release()                               // the worker finishes, and the wait reads what is posted
        XCTAssertEqual(gone.wait(timeout: .now() + 3), .success)
        XCTAssertTrue(rig.server.systemAsleep, "a wake notice was acted on by the loop after it had left")
        // What the wait is for is still done: the held switch-on's outcome was read, and the mode put back.
        XCTAssertEqual(pmset.battery, 2)
        XCTAssertEqual(pmset.charger, 0)
        XCTAssertNil(rig.server.heldPowerModes)
    }

    /// THE ORDER THE STOP KEEPS, pinned with the worker held for the whole of the wait: the plan is dropped and its wake
    /// cancelled, a sleep notice waiting is answered, and neither waits for the tool; a plan that is due writes nothing.
    func testAStopWithTheWorkerHeldAPlanDueAndASleepNoticeWaitingDropsThePlanAndAnswersSleepAtOnce() throws {
        let rig = try makeRig()
        let at = Date().addingTimeInterval(1)             // within the plan's slack: due now
        XCTAssertTrue(rig.server.handle(.command(.scheduleChargeLimit(limit: 80, at: at))).ok)
        let wake = try XCTUnwrap(rig.server.chargePlan?.wakeAt)
        rig.timer.fireNow()                               // the plan's due notice is waiting for the loop
        rig.gate.hold()
        XCTAssertEqual(rig.server.handle(.command(.enterLowPowerMode)), started)
        spinUntil { rig.gate.waiting == 1 }
        rig.server.powerModeStopWait = 2

        let answered = DispatchSemaphore(value: 0)
        let sleepAnsweredAfter = Locked<TimeInterval?>(nil)
        let began = Date()
        DispatchQueue.global().async {
            if rig.server.noteSystemWillSleep(timeout: 5) { sleepAnsweredAfter.set(Date().timeIntervalSince(began)) }
            answered.signal()
        }
        Thread.sleep(forTimeInterval: 0.1)                // posted, waiting for a loop that is not running
        let gone = stopOnAThread(rig.server)
        XCTAssertEqual(answered.wait(timeout: .now() + 1), .success, "macOS was not answered while the stop waited for the tool")
        XCTAssertLessThan(sleepAnsweredAfter.get() ?? .infinity, 1.0, "the sleep answer waited for the tool")
        XCTAssertTrue(rig.events.cancelled.contains(wake), "the plan's wake was still there while the stop waited for the tool")
        XCTAssertNil(rig.events.pending.first)
        XCTAssertEqual(gone.wait(timeout: .now() + 0.2), .timedOut, "the wait is over, so it was not waiting for the tool")
        XCTAssertTrue(rig.hw.limitWrites.isEmpty, "the plan's limit was written during the stop")

        rig.gate.release()
        XCTAssertEqual(gone.wait(timeout: .now() + 3), .success)
        XCTAssertTrue(rig.hw.limitWrites.isEmpty)
    }

    /// A reconnect owed by the sleep watch, a plan's due notice and a wake that are waiting when the stop begins are dropped,
    /// not acted on: no charger write, no limit write, and the Mac is still the way the loop left it.
    func testAReconnectOwedAPlanDueAndAWakeNoticeWaitingAtTheStopAreDroppedAndNotActedOn() throws {
        let rig = try makeRig()
        rig.server.systemWillSleep()
        XCTAssertTrue(rig.server.systemAsleep)
        // The loop is not running, so the sleep notice goes unanswered: the sleep watch reconnects the charger itself (one
        // write) and hands the loop a reconnect that it owes.
        XCTAssertFalse(rig.server.noteSystemWillSleep(timeout: 0.05))
        let writes = rig.hw.cutWrites.count
        XCTAssertGreaterThan(writes, 0)
        XCTAssertTrue(rig.server.handle(.command(.scheduleChargeLimit(limit: 80, at: Date().addingTimeInterval(1)))).ok)
        rig.timer.fireNow()
        rig.server.noteSystemDidWake()

        rig.server.stop()
        rig.server.run()
        XCTAssertEqual(rig.hw.cutWrites.count, writes, "the reconnect the sleep watch handed over was acted on at the stop")
        XCTAssertTrue(rig.hw.limitWrites.isEmpty, "the plan's limit was written at the stop")
        XCTAssertTrue(rig.server.systemAsleep, "the wake notice was acted on at the stop")
        XCTAssertFalse(rig.server.reconnectOwed)
    }

    private func spinUntil(timeout: TimeInterval = 3, _ done: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !done(), Date() < end { Thread.sleep(forTimeInterval: 0.005) }
    }

    private final class Locked<T> {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
        func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// The stop answers every sleep notice still waiting, as it always did, and keeps a finished power-mode outcome for
    /// itself: the filter that keeps the one must not drop the other.
    func testASleepNoticeStillWaitingWhenTheHelperStopsIsAnsweredAndTheModeIsStillPutBack() throws {
        let path = NSTemporaryDirectory() + "bs-pwr-\(UUID().uuidString.prefix(8)).sock"
        let server = FanHelperServer(
            hardware: FakeFans([:]),
            configuration: .init(socketPath: path, ownerUID: getuid(),
                                 pin: .signingIdentifier(FanDaemon.clientSigningIdentifier)),
            log: { [weak self] in self?.lines.append($0) },
            powerMode: pmset)
        try server.start()
        XCTAssertEqual(server.handle(.command(.enterLowPowerMode)), started)
        while pmset.writes.count < 2 { Thread.sleep(forTimeInterval: 0.005) }
        Thread.sleep(forTimeInterval: 0.05)
        let answered = expectation(description: "the sleep notice was answered")
        DispatchQueue.global().async {
            XCTAssertTrue(server.noteSystemWillSleep(timeout: 5), "the sleep notice was left to time out")
            answered.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)            // posted, and waiting for a loop that is not running
        server.stop()
        server.run()
        wait(for: [answered], timeout: 3)
        XCTAssertEqual(pmset.battery, 2, "the mode that was switched on was left on")
        XCTAssertEqual(pmset.charger, 0)
    }

    // ── The wire: the third command, and the one field the reply gained ─────

    func testThePowerModeResultCommandRoundTripsThroughTheWire() throws {
        var line = try FanWire.encode(FanRequest.command(.powerModeResult))
        line.removeLast()
        XCTAssertEqual(try FanWire.decode(FanRequest.self, from: line), .command(.powerModeResult))
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(FanCommand.powerModeResult)) as? NSDictionary
        XCTAssertEqual(written, ["powerModeResult": [String: Any]()] as NSDictionary)
    }

    /// The reply gained one field, `pending`, left out of the line unless set: it round trips, a reply without it is
    /// written with exactly the keys it always had, and a line from before it reads as nil.
    func testThePendingAnswerRoundTripsAndEveryOtherReplyHasTheKeysItAlwaysHad() throws {
        let pending = FanReply(ok: true, message: "pending", pending: true)
        var line = try FanWire.encode(pending)
        line.removeLast()
        XCTAssertEqual(try FanWire.decode(FanReply.self, from: line), pending)
        func keys(_ reply: FanReply) throws -> Set<String> {
            Set(((try JSONSerialization.jsonObject(with: JSONEncoder().encode(reply))) as? [String: Any] ?? [:]).keys)
        }
        XCTAssertEqual(try keys(pending), ["ok", "message", "pending"])
        XCTAssertEqual(try keys(FanReply(ok: true, message: "started")), ["ok", "message"])
        XCTAssertEqual(try keys(FanReply(ok: true, message: "Low Power Mode is on", powerModeBefore: 21)),
                       ["ok", "message", "powerModeBefore"])
        XCTAssertEqual(try keys(FanReply(ok: true, message: "fan helper ready", fanCount: 2, version: 4)),
                       ["ok", "message", "fanCount", "version"])
        let old = Data(#"{"ok":true,"message":"fan helper ready","fanCount":2,"version":3}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(FanReply.self, from: old).pending)
    }

    // ── What it does not touch ──────────────────────────────────────────────

    /// The Fans tab's "release everything" is not this client going away.
    func testReleasingTheFansDoesNotPutTheModeBack() {
        let server = makeServer()
        _ = enter(server)
        let writes = pmset.writes
        XCTAssertTrue(server.handle(.command(.releaseAll)).ok)
        XCTAssertEqual(pmset.writes, writes)
        XCTAssertNotNil(server.heldPowerModes)
        XCTAssertEqual(pmset.battery, 1)
    }

    /// A helper at protocol 4 serves every command it served at 2 and 3 exactly as one without the tool does, and never
    /// runs the tool for them.
    func testTheOlderCommandsAnswerAsTheyDidAndNeverRunTheTool() {
        let at = Date().addingTimeInterval(3600)
        func replies(_ runner: PowerModeRunner?) -> [FanReply] {
            let charge = FakeChargeHardware(percent: 77, onAC: true)
            let fans = FakeFans([0: .init(minRPM: 2317, maxRPM: 7826)])
            fans.seedTarget(0, 0)
            fans.seedMode(0, SMCFanMode.automatic)
            let events = FakePowerEvents()
            let server = FanHelperServer(
                hardware: fans,
                configuration: .init(socketPath: NSTemporaryDirectory() + "bs-unused.sock", ownerUID: getuid(),
                                     pin: .signingIdentifier(FanDaemon.clientSigningIdentifier)),
                charge: charge, powerEvents: events, powerMode: runner)
            server.chargeTiming = .immediate
            let commands: [FanRequest] = [
                .hello, .command(.setTarget(FanTarget(index: 0, rpm: 5000))), .command(.setChargeLimit(63)),
                .command(.setChargeLimit(5)), .command(.discharge(toPercent: 40)), .command(.stopDischarge),
                .command(.scheduleChargeLimit(limit: 80, at: at)), .command(.cancelScheduledChargeLimit),
                .command(.releaseAll),
            ]
            return commands.map { server.handle($0) }
        }
        XCTAssertEqual(replies(pmset), replies(nil))
        XCTAssertTrue(pmset.calls.isEmpty, "the tool was run for a command that has nothing to do with it")
    }

    func testTheHelloSaysFourAndNothingElseAboutItChanged() {
        let reply = makeServer().handle(.hello)
        XCTAssertEqual(FanDaemon.protocolVersion, 4)
        XCTAssertEqual(reply, FanReply(ok: true, message: "fan helper ready", fanCount: 0, version: 4))
        XCTAssertNil(reply.powerModeBefore)
    }

    func testAFanSessionTracksNothingForThePowerModeCommands() {
        var session = FanSession(enabled: true, helper: .connected(fanCount: 2))
        session.completed(.enterLowPowerMode, ok: true)
        session.completed(.restorePowerMode(before: 2), ok: false)
        XCTAssertTrue(session.held.isEmpty)
    }
}

// ── Over a real socket: the client going, and the helper stopping ───────────

/// A real server on a real socket, with a fake `pmset`. A client leaving or the helper stopping is the loop's
/// business, and only the loop can show it is done.
final class PowerModeHelperLoopTests: XCTestCase {

    /// The helper's log lines, written from the loop's thread and read from the test's.
    private final class Log {
        private let lock = NSLock()
        private var _lines: [String] = []
        func add(_ line: String) { lock.lock(); _lines.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
    }

    private var server: FanHelperServer!
    private var thread: Thread!
    private var link: FanControlLink!
    private var socketPath = ""
    private var pmset: FakePmset!
    /// The tool, as the server is given it: the table, behind a gate a test can close.
    private var gated: GatedPmset!
    private var log = Log()
    private var lines: [String] { log.lines }
    private var rawClients: [RawClient] = []

    override func setUp() {
        super.setUp()
        pmset = FakePmset()
        gated = GatedPmset(pmset)
        log = Log()
    }

    override func tearDown() {
        // First: a call held at the gate holds the worker, and the loop may be waiting for it.
        gated.release()
        rawClients = []
        link?.disconnect()
        server?.stop()
        spin(until: { self.thread == nil || self.thread.isFinished }, timeout: 3, failOnTimeout: false)
        super.tearDown()
    }

    private func spin(until done: () -> Bool, timeout: TimeInterval = 3, failOnTimeout: Bool = true) {
        let end = Date().addingTimeInterval(timeout)
        while !done(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        if failOnTimeout { XCTAssertTrue(done(), "timed out") }
    }

    /// A real server on a real socket. `runner` is the tool it is given (the table itself unless a test closes a gate
    /// in front of it); the charger, the fans and the plan's wake and timer are fakes, and left out unless asked for.
    private func start(runner: PowerModeRunner? = nil, charge: ChargeHardware? = nil, fans: FakeFans = FakeFans([:]),
                       events: PowerEventScheduler? = nil, timer: WallClockTimer? = nil,
                       connectLink: Bool = true, configure: (FanHelperServer) -> Void = { _ in }) throws {
        socketPath = NSTemporaryDirectory() + "bs-pwr-\(UUID().uuidString.prefix(8)).sock"
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0, let mine = FanPeer.of(socket: pair[0])?.cdhash else {
            throw XCTSkip("no code identity available in this test environment")
        }
        close(pair[0]); close(pair[1])
        server = FanHelperServer(hardware: fans,
                                 configuration: .init(socketPath: socketPath, ownerUID: getuid(),
                                                      pin: .exactBuild(cdhash: mine)),
                                 log: { [log] in log.add($0) },
                                 charge: charge,
                                 powerEvents: events,
                                 wakeTimer: timer ?? DispatchWallClockTimer(),
                                 powerMode: runner ?? pmset)
        // So that a bound of half a second is about the tool and not about the charger's read-back pauses.
        server.chargeTiming = .immediate
        configure(server)
        try server.start()
        thread = Thread { [server] in server?.run() }
        thread.start()
        link = FanControlLink(socketPath: socketPath)
        guard connectLink else { return }
        var status: FanControlLink.Status?
        link.connect { status = $0 }
        spin(until: { status != nil })
    }

    private func send(_ command: FanCommand) -> FanReply {
        var result: FanReply?
        link.send(command) { result = $0 }
        spin(until: { result != nil })
        return result ?? FanReply(ok: false, message: "no reply")
    }

    /// A client that talks to the socket itself, so that a request can be written without waiting for the answer to
    /// the one before: `FanControlLink` sends one and waits, which hides whether the helper could have answered the next.
    private final class RawClient {
        private let fd: Int32
        private var buffer = Data()

        init?(path: String) {
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0, var addr = FanSocketIO.address(path),
                  FanSocketIO.withAddress(&addr, { p, len in Darwin.connect(fd, p, len) }) == 0 else { return nil }
            FanSocketIO.configure(fd, timeout: 2)
        }

        deinit { close(fd) }

        func write(_ request: FanRequest) -> Bool {
            guard let data = try? FanWire.encode(request) else { return false }
            return FanSocketIO.writeAll(fd, data)
        }

        /// The next answer, or nil when none comes within `timeout`.
        func read(within timeout: TimeInterval) -> FanReply? {
            FanSocketIO.configure(fd, timeout: timeout)
            guard let line = try? FanSocketIO.readLine(fd, buffer: &buffer) else { return nil }
            return try? FanWire.decode(FanReply.self, from: line)
        }
    }

    private func rawClient() throws -> RawClient {
        guard let client = RawClient(path: socketPath) else { throw XCTSkip("could not connect a client socket") }
        rawClients.append(client)
        return client
    }

    /// The answer to `command`, and how long it took to come. nil when none came within `cap`.
    private func timed(_ command: FanCommand, cap: TimeInterval = 1.5) -> (reply: FanReply?, took: TimeInterval) {
        var result: FanReply?
        let began = Date()
        link.send(command) { result = $0 }
        spin(until: { result != nil }, timeout: cap, failOnTimeout: false)
        return (result, Date().timeIntervalSince(began))
    }

    /// `powerModeResult` until it is no longer pending (at most `within` seconds), as the app polls it.
    private func result(within: TimeInterval = 3) -> FanReply {
        let end = Date().addingTimeInterval(within)
        var reply = send(.powerModeResult)
        while reply.pending == true, Date() < end {
            spin(until: { false }, timeout: 0.02, failOnTimeout: false)
            reply = send(.powerModeResult)
        }
        return reply
    }

    /// A client's enter as the app makes it: started at once, then its end asked for until it has one.
    private func enter() -> FanReply {
        let started = send(.enterLowPowerMode)
        return started.ok ? result() : started
    }

    /// The tool is held, and an enter is in it: started, and the worker is at the gate.
    private func holdAnEnter() throws {
        gated.hold()
        XCTAssertEqual(send(.enterLowPowerMode), FanReply(ok: true, message: "started"))
        spin(until: { self.gated.waiting == 1 })
        XCTAssertEqual(gated.waiting, 1, "the tool was never run, so there is no switch in progress to be held by")
    }

    // ── The loop is not held by the tool ────────────────────────────────────

    /// THE OWNER'S TEST. The loop also keeps the charger's floor and answers the app within its link's two seconds; a
    /// switch of the power mode that is stuck in `pmset` must hold neither. Both requests are written before either
    /// answer is read: the answers come in order, and the second is the one that shows whether the loop was free.
    func testAStopDischargeSentWhileAPowerModeSwitchIsInProgressIsAnsweredWithinHalfASecond() throws {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        try start(runner: gated, charge: hw, connectLink: false)
        gated.hold()
        let client = try rawClient()
        XCTAssertTrue(client.write(.command(.enterLowPowerMode)))
        spin(until: { self.gated.waiting == 1 })
        XCTAssertEqual(gated.waiting, 1, "the tool was never run, so there is no switch in progress to be held by")

        let sentAt = Date()
        XCTAssertTrue(client.write(.command(.stopDischarge)))
        let first = client.read(within: 1.5)
        let second = first == nil ? nil : client.read(within: 1.5)
        let took = Date().timeIntervalSince(sentAt)
        XCTAssertNotNil(first, "the enter was not answered while the tool was held: the loop was waiting for it")
        XCTAssertNotNil(second, "the helper did not answer a stopDischarge in \(String(format: "%.1f", took)) s while the "
                              + "tool was held: the loop was waiting for it")
        XCTAssertLessThan(took, 0.5)
        XCTAssertEqual(first, FanReply(ok: true, message: "started"))
        XCTAssertEqual(second?.ok, true)
    }

    /// The same for a fan command: the fans are the helper's first job, and a stuck `pmset` must not hold a slider.
    func testAFanCommandSentWhileAPowerModeSwitchIsInProgressIsAnsweredWithinHalfASecond() throws {
        let fans = FakeFans([0: .init(minRPM: 2317, maxRPM: 7826)])
        fans.seedTarget(0, 0)
        fans.seedMode(0, SMCFanMode.automatic)
        try start(runner: gated, fans: fans)
        try holdAnEnter()
        let (reply, took) = timed(.setTarget(FanTarget(index: 0, rpm: 5000)))
        XCTAssertEqual(reply?.ok, true, reply?.message ?? "no answer in \(took) s")
        XCTAssertLessThan(took, 0.5)
        XCTAssertFalse(fans.targetWrites.isEmpty, "the fan was not set")
    }

    /// And for the scheduled plan's two commands.
    func testTheScheduledPlanCommandsSentWhileAPowerModeSwitchIsInProgressAreAnsweredWithinHalfASecond() throws {
        try start(runner: gated, charge: FakeChargeHardware(percent: 54, onAC: true), events: FakePowerEvents(),
                  timer: FakeWallTimer())
        try holdAnEnter()
        let at = Date().addingTimeInterval(8 * 3600)
        for command in [FanCommand.scheduleChargeLimit(limit: 80, at: at), .cancelScheduledChargeLimit] {
            let (reply, took) = timed(command)
            XCTAssertEqual(reply?.ok, true, "\(command): \(reply?.message ?? "no answer in \(took) s")")
            XCTAssertLessThan(took, 0.5, "\(command)")
        }
    }

    /// The loop is not held: with the tool stuck, the helper goes on answering, command after command.
    func testWithTheToolHeldTheServerAnswersTenOtherCommandsInARowEachWithinHalfASecond() throws {
        let fans = FakeFans([0: .init(minRPM: 2317, maxRPM: 7826)])
        fans.seedTarget(0, 0)
        fans.seedMode(0, SMCFanMode.automatic)
        try start(runner: gated, charge: FakeChargeHardware(percent: 54, onAC: true), fans: fans,
                  events: FakePowerEvents(), timer: FakeWallTimer())
        try holdAnEnter()
        let at = Date().addingTimeInterval(8 * 3600)
        let commands: [FanCommand] = [
            .stopDischarge, .setChargeLimit(70), .cancelScheduledChargeLimit, .setTarget(FanTarget(index: 0, rpm: 4000)),
            .releaseAll, .powerModeResult, .stopDischarge, .scheduleChargeLimit(limit: 80, at: at), .setChargeLimit(60),
            .cancelScheduledChargeLimit,
        ]
        XCTAssertEqual(commands.count, 10)
        for command in commands {
            let (reply, took) = timed(command)
            XCTAssertEqual(reply?.ok, true, "\(command): \(reply?.message ?? "no answer in \(took) s")")
            XCTAssertLessThan(took, 0.5, "\(command)")
        }
        XCTAssertEqual(gated.waiting, 1, "the tool was let go on the way, so the loop was never tested against it")
    }

    // ── The three commands ──────────────────────────────────────────────────

    /// Started at once; the result is pending while the tool is held, then done with the packed "before", and the same
    /// every time it is asked.
    func testEnterAnswersStartedAtOnceAndItsResultIsPendingUntilTheToolFinishesThenDoneWithTheModeBefore() throws {
        try start(runner: gated)
        gated.hold()
        let (started, took) = timed(.enterLowPowerMode)
        XCTAssertEqual(started, FanReply(ok: true, message: "started"))
        XCTAssertLessThan(took, 0.5)
        spin(until: { self.gated.waiting == 1 })
        let pending = FanReply(ok: true, message: "pending", pending: true)
        XCTAssertEqual(send(.powerModeResult), pending)
        XCTAssertEqual(send(.powerModeResult), pending, "asking is not taking the answer")
        XCTAssertTrue(pmset.writes.isEmpty)
        XCTAssertEqual(pmset.battery, 2, "the mode was changed before the tool was let go")

        gated.release()
        let done = result()
        XCTAssertEqual(done, FanReply(ok: true, message: "Low Power Mode is on", powerModeBefore: 2))
        XCTAssertEqual(send(.powerModeResult), done)
        XCTAssertEqual(pmset.battery, 1)
        XCTAssertEqual(pmset.charger, 1)
    }

    func testAFailedSwitchGivesFailedWithTheReason() throws {
        for (why, setUp) in [(PowerModeRefusal.unreadable, { self.pmset.neverAnswers = true }),
                             (.noLowPowerMode, { self.pmset = FakePmset(key: nil); self.gated = GatedPmset(self.pmset) }),
                             (.notTaken, { self.pmset.refuseWrites(to: "-b") })] as [(PowerModeRefusal, () -> Void)] {
            setUp()
            try start(runner: gated)
            XCTAssertEqual(send(.enterLowPowerMode), FanReply(ok: true, message: "started"), "\(why)")
            XCTAssertEqual(result(), FanReply(ok: false, message: why.message), "\(why)")
            link.disconnect()
            server.stop()
            spin(until: { self.thread.isFinished })
            pmset = FakePmset()
            gated = GatedPmset(pmset)
        }
    }

    /// One job at a time: a second enter, or a restore, while one runs is refused, and the one that runs is not disturbed.
    func testASecondEnterOrARestoreWhileOneRunsIsRefused() throws {
        try start(runner: gated)
        gated.hold()
        XCTAssertEqual(send(.enterLowPowerMode), FanReply(ok: true, message: "started"))
        spin(until: { self.gated.waiting == 1 })
        let busy = FanReply(ok: false, message: PowerModeRefusal.busy.message)
        XCTAssertEqual(send(.enterLowPowerMode), busy)
        XCTAssertEqual(send(.restorePowerMode(before: 2)), busy)
        XCTAssertEqual(send(.restorePowerMode(before: 99)), FanReply(ok: false, message: PowerModeRefusal.badValue.message),
                       "a value that is not a power mode is refused for what it is, before anything else is asked")
        XCTAssertEqual(send(.powerModeResult), FanReply(ok: true, message: "pending", pending: true))
        XCTAssertEqual(gated.calls, 1, "a refused command ran the tool")

        gated.release()
        XCTAssertEqual(result(), FanReply(ok: true, message: "Low Power Mode is on", powerModeBefore: 2))
        XCTAssertEqual(pmset.writes, [["-b", "powermode", "1"], ["-c", "powermode", "1"]], "switched on more than once")
    }

    /// A connection that has started nothing is refused, not crashed.
    func testAskingForTheResultWithNothingStartedIsARefusal() throws {
        try start(runner: gated)
        XCTAssertEqual(send(.powerModeResult), FanReply(ok: false, message: PowerModeRefusal.nothingAsked.message))
        XCTAssertTrue(send(.releaseAll).ok, "the helper stopped answering")
        XCTAssertEqual(gated.calls, 0)
    }

    /// A restore is started at once and ends the same way: pending while the tool is held, done after.
    func testARestoreAnswersStartedAtOnceAndItsResultIsPendingThenDone() throws {
        try start(runner: gated)
        XCTAssertEqual(enter().powerModeBefore, 2)
        gated.hold()
        let (started, took) = timed(.restorePowerMode(before: 2))
        XCTAssertEqual(started, FanReply(ok: true, message: "started"))
        XCTAssertLessThan(took, 0.5)
        spin(until: { self.gated.waiting == 1 })
        XCTAssertEqual(send(.powerModeResult), FanReply(ok: true, message: "pending", pending: true))
        XCTAssertEqual(pmset.battery, 1, "put back before the tool was let go")
        gated.release()
        XCTAssertEqual(result(), FanReply(ok: true, message: "power mode put back"))
        XCTAssertEqual(pmset.battery, 2)
        XCTAssertEqual(pmset.charger, 0)
    }

    // ── The client going ────────────────────────────────────────────────────

    /// The close does not wait for the tool: the loop is back to serving the moment the put-back is handed over, and the
    /// put-back runs when the worker is free. The mode ends as it was.
    func testAClientGoingWhileTheToolIsHeldReturnsTheLoopAtOnceAndThePutBackRunsWhenTheWorkerIsFree() throws {
        try start(runner: gated)
        XCTAssertTrue(enter().ok)
        gated.hold()
        link.disconnect()
        // Another client, at once: the loop has to be free to accept it and answer it.
        spin(until: { self.gated.waiting == 1 })
        XCTAssertEqual(gated.waiting, 1, "the put-back never reached the tool")
        let other = try rawClient()
        let began = Date()
        XCTAssertTrue(other.write(.hello))
        let hello = other.read(within: 1.5)
        XCTAssertEqual(hello?.ok, true, "the loop was waiting for the put-back")
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.5)
        XCTAssertEqual(pmset.battery, 1, "put back while the tool was held")

        gated.release()
        spin(until: { self.pmset.battery == 2 && self.pmset.charger == 0 })
        XCTAssertEqual(pmset.battery, 2)
        XCTAssertEqual(pmset.charger, 0)
        XCTAssertTrue(pmset.unexpected.isEmpty)
    }

    /// The put-back is owed by the helper, not by the client that went: a new client connecting, asking and being refused
    /// leaves it alone, and it is carried out.
    func testANewClientConnectingWhileThePutBackIsOwedDoesNotLoseIt() throws {
        try start(runner: gated)
        XCTAssertTrue(enter().ok)
        gated.hold()
        link.disconnect()
        spin(until: { self.gated.waiting == 1 })

        let next = try rawClient()
        XCTAssertTrue(next.write(.command(.enterLowPowerMode)))
        XCTAssertEqual(next.read(within: 1.5), FanReply(ok: false, message: PowerModeRefusal.busy.message),
                       "a second switch-on while the put-back is owed")
        XCTAssertTrue(next.write(.command(.powerModeResult)))
        XCTAssertEqual(next.read(within: 1.5), FanReply(ok: false, message: PowerModeRefusal.nothingAsked.message),
                       "the client that went answered the one that came")
        XCTAssertEqual(pmset.battery, 1)

        gated.release()
        spin(until: { self.pmset.battery == 2 && self.pmset.charger == 0 })
        XCTAssertEqual(pmset.battery, 2, "the put-back was lost")
        XCTAssertEqual(pmset.charger, 0)
        // And the helper is free again for that client.
        XCTAssertTrue(next.write(.command(.enterLowPowerMode)))
        XCTAssertEqual(next.read(within: 1.5), FanReply(ok: true, message: "started"))
    }

    /// The client goes while its switch-on is still in the tool. The loop cannot yet say what to put back; it is owed, and
    /// given to the worker when the switch-on's outcome says what there is.
    func testAClientGoingWhileItsSwitchOnIsRunningHasTheModePutBackWhenItFinishes() throws {
        try start(runner: gated)
        gated.hold()
        XCTAssertEqual(send(.enterLowPowerMode), FanReply(ok: true, message: "started"))
        spin(until: { self.gated.waiting == 1 })
        link.disconnect()
        let other = try rawClient()
        XCTAssertTrue(other.write(.hello))
        XCTAssertEqual(other.read(within: 1.5)?.ok, true, "the loop was waiting for the switch-on")

        gated.release()
        spin(until: { self.pmset.writes.count == 4 })
        XCTAssertEqual(pmset.writes, [["-b", "powermode", "1"], ["-c", "powermode", "1"],
                                      ["-b", "powermode", "2"], ["-c", "powermode", "0"]])
        XCTAssertEqual(pmset.battery, 2)
        XCTAssertEqual(pmset.charger, 0)
    }

    /// A client that went has no answer waiting for the next: its result is for the books only.
    func testTheResultOfAClientThatWentIsNotTheNextClientsAnswer() throws {
        try start(runner: gated)
        gated.hold()
        XCTAssertEqual(send(.enterLowPowerMode), FanReply(ok: true, message: "started"))
        spin(until: { self.gated.waiting == 1 })
        link.disconnect()
        gated.release()
        spin(until: { self.pmset.writes.count == 4 })
        let next = try rawClient()
        XCTAssertTrue(next.write(.command(.powerModeResult)))
        XCTAssertEqual(next.read(within: 1.5), FanReply(ok: false, message: PowerModeRefusal.nothingAsked.message))
    }

    // ── The helper stopping ─────────────────────────────────────────────────

    /// The stop waits for the worker, within its bound, so that the mode is put back before the process ends.
    func testTheHelperStoppingWaitsForTheWorkerWithinTheBoundAndTheModeEndsAsItWas() throws {
        try start(runner: gated)
        XCTAssertTrue(enter().ok)
        gated.hold()
        let stoppedAt = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { self.gated.release() }
        server.stop()
        spin(until: { self.thread.isFinished })
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(stoppedAt), 0.35, "the stop did not wait for the worker")
        XCTAssertLessThan(Date().timeIntervalSince(stoppedAt), PowerModeSwitch.slowestCommand)
        XCTAssertEqual(pmset.battery, 2, "a helper that stops leaves the Mac in Low Power Mode")
        XCTAssertEqual(pmset.charger, 0)
        XCTAssertNil(server.heldPowerModes)
        XCTAssertFalse(lines.contains { $0.contains("had not finished") }, "\(lines)")
    }

    /// A worker that never finishes is said once, and the stop is back within the bound and a small margin.
    func testAWorkerThatNeverFinishesIsLoggedOnceAndTheStopReturnsWithinTheBound() throws {
        try start(runner: gated)
        XCTAssertTrue(enter().ok)
        XCTAssertEqual(server.powerModeStopWait, PowerModeSwitch.slowestCommand, "the bound is the slowest command")
        gated.hold()
        let stoppedAt = Date()
        server.stop()
        spin(until: { self.thread.isFinished }, timeout: 6)
        let took = Date().timeIntervalSince(stoppedAt)
        XCTAssertGreaterThanOrEqual(took, PowerModeSwitch.slowestCommand - 0.1, "gave up before the bound")
        XCTAssertLessThan(took, PowerModeSwitch.slowestCommand + 0.5)
        XCTAssertEqual(lines.filter { $0.contains("had not finished") }.count, 1, "\(lines)")
        XCTAssertEqual(pmset.battery, 1, "nothing could have put it back")
    }

    /// Condition one: everything that exists today runs and completes before the wait. A reconnect that is owed and fails
    /// is attempted at once, while the tool is still held, and is still owed when the helper is gone: the wait neither
    /// delays it nor changes what the helper leaves behind. (This helper's `run()` has no exit status: the one exit status
    /// that reads a reconnect is `--uninstall`'s, in its own process.)
    func testTheChargerIsReconnectedBeforeTheWaitAndAFailedReconnectIsStillOwedAfterIt() throws {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        try start(runner: gated, charge: hw) { $0.powerModeStopWait = 1.0 }
        XCTAssertTrue(send(.discharge(toPercent: 40)).ok)
        XCTAssertEqual(hw.isCut, true)
        gated.hold()
        XCTAssertEqual(send(.restorePowerMode(before: 2)), FanReply(ok: true, message: "started"),
                       "a power mode job in flight")
        spin(until: { self.gated.waiting == 1 })
        hw.refuseRestore = true
        let writes = hw.cutWrites.count

        let stoppedAt = Date()
        server.stop()
        spin(until: { hw.cutWrites.count > writes }, timeout: 1)
        let attemptedAfter = Date().timeIntervalSince(stoppedAt)
        XCTAssertGreaterThan(hw.cutWrites.count, writes, "the reconnect was not attempted")
        XCTAssertLessThan(attemptedAfter, 0.5, "the reconnect waited for the tool")
        XCTAssertFalse(thread.isFinished, "the loop was gone, so the wait cannot have followed the reconnect")

        spin(until: { self.thread.isFinished }, timeout: 3)
        XCTAssertTrue(thread.isFinished)
        XCTAssertEqual(Date().timeIntervalSince(stoppedAt), 1.0, accuracy: 0.5, "the wait is the bound and no more")
        XCTAssertTrue(server.reconnectOwed, "a reconnect the helper owed and could not make is forgotten")
        XCTAssertEqual(hw.isCut, true)
        XCTAssertEqual(lines.filter { $0.contains("had not finished") }.count, 1, "\(lines)")
    }

    // ── Idle ────────────────────────────────────────────────────────────────

    /// An on-demand helper exits when it is idle. It must not exit under a job on the worker, and it must exit once the
    /// put-back has run.
    func testAnOnDemandHelperStaysUpUnderAPutBackAndLeavesOnceItHasRun() throws {
        try start(runner: gated) { $0.idleExit = 0.3 }
        XCTAssertTrue(enter().ok)
        gated.hold()
        link.disconnect()
        spin(until: { self.gated.waiting == 1 })
        spin(until: { false }, timeout: 1.0, failOnTimeout: false)
        XCTAssertFalse(thread.isFinished, "an on-demand helper exited under the put-back, with the mode still on")
        XCTAssertEqual(pmset.battery, 1)

        gated.release()
        spin(until: { self.thread.isFinished }, timeout: 3)
        XCTAssertTrue(thread.isFinished, "it never left once the put-back had run")
        XCTAssertEqual(pmset.battery, 2)
        XCTAssertEqual(pmset.charger, 0)
    }

    /// And a put-back that fails its tries does not keep the helper up for ever.
    func testAnOnDemandHelperLeavesOnceAPutBackHasFailedItsTries() throws {
        try start(runner: gated) { $0.idleExit = 0.3 }
        XCTAssertTrue(enter().ok)
        pmset.refuseWrites(to: "-b")
        link.disconnect()
        spin(until: { self.thread.isFinished }, timeout: 4)
        XCTAssertTrue(thread.isFinished, "a put-back that cannot be made keeps the helper up for ever")
        XCTAssertTrue(lines.contains { $0.contains("it is tried again when the helper stops") }, "\(lines)")
        XCTAssertEqual(pmset.battery, 1, "refused all along")
    }

    /// Release, not hold: the app going away without a restore puts the mode back, by the same path an ordinary quit
    /// takes.
    func testAClosedConnectionPutsTheModeBack() throws {
        try start()
        let reply = enter()
        XCTAssertTrue(reply.ok, reply.message)
        XCTAssertEqual(reply.powerModeBefore, 2)
        XCTAssertEqual(pmset.battery, 1)
        // Still on between exchanges, and a release of the fans is not the client going.
        XCTAssertTrue(send(.releaseAll).ok)
        XCTAssertEqual(pmset.battery, 1)

        link.disconnect()
        spin(until: { self.lines.contains { $0.contains("put the macOS power mode back (the client went away)") } })
        XCTAssertEqual(pmset.battery, 2, "the mode stayed on after the app went away")
        XCTAssertEqual(pmset.charger, 0)
        XCTAssertNil(server.heldPowerModes)
        XCTAssertTrue(pmset.unexpected.isEmpty)
    }

    func testTheHelperStoppingPutsTheModeBack() throws {
        try start()
        XCTAssertTrue(enter().ok)
        server.stop()
        spin(until: { self.thread.isFinished })
        XCTAssertEqual(pmset.battery, 2, "a helper that stops leaves the Mac in Low Power Mode")
        XCTAssertEqual(pmset.charger, 0)
        XCTAssertTrue(lines.contains { $0.contains("the helper is stopping") }, "\(lines)")
    }

    /// A restore the app made itself leaves nothing for the close to do.
    func testAModeTheAppPutBackIsNotWrittenAgainOnClose() throws {
        try start()
        let before = enter().powerModeBefore ?? -1
        XCTAssertEqual(send(.restorePowerMode(before: before)), FanReply(ok: true, message: "started"))
        XCTAssertTrue(result().ok)
        let writes = pmset.writes
        link.disconnect()
        spin(until: { self.lines.contains { $0.hasPrefix("client gone") } })
        XCTAssertEqual(pmset.writes, writes)
    }

    /// A client that never asked for it never has the mode touched on its way out.
    func testAClientThatNeverEnteredTouchesNothingOnClose() throws {
        try start()
        pmset.ownerSets("-b", 1)
        XCTAssertTrue(send(.releaseAll).ok)
        link.disconnect()
        spin(until: { self.lines.contains { $0.hasPrefix("client gone") } })
        XCTAssertTrue(pmset.calls.isEmpty, "the tool was run for a client that never switched anything on")
        XCTAssertEqual(pmset.battery, 1, "a mode this feature did not set was changed")
    }

    /// A source the owner changed since is theirs: the close writes nothing to it.
    func testAModeThisFeatureDidNotSetIsNotTouchedOnClose() throws {
        try start()
        XCTAssertTrue(enter().ok)
        pmset.ownerSets("-c", 2)
        link.disconnect()
        spin(until: { self.pmset.battery == 2 })
        XCTAssertEqual(pmset.charger, 2, "the owner's own choice was overwritten")
        XCTAssertEqual(pmset.writes.filter { $0.first == "-c" }, [["-c", "powermode", "1"]])
    }

    /// A put-back that failed its tries when the client went is tried again when the helper stops.
    func testAPutBackThatFailedOnCloseIsTriedAgainWhenTheHelperStops() throws {
        try start()
        XCTAssertTrue(enter().ok)
        pmset.refuseWrites(to: "-b")
        link.disconnect()
        spin(until: { self.lines.contains { $0.contains("it is tried again when the helper stops") } })
        XCTAssertEqual(pmset.battery, 1)
        XCTAssertNotNil(server.heldPowerModes)
        pmset.acceptWritesAgain()
        server.stop()
        spin(until: { self.thread.isFinished })
        XCTAssertEqual(pmset.battery, 2)
        XCTAssertNil(server.heldPowerModes)
    }
}

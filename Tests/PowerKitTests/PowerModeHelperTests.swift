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
        _calls.append(Call(arguments: arguments, limit: limit))
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

final class PowerModeHelperTests: XCTestCase {

    private var pmset: FakePmset!
    private var lines: [String] = []

    override func setUp() {
        super.setUp()
        pmset = FakePmset()
        lines = []
    }

    private func makeServer(withRunner: Bool = true) -> FanHelperServer {
        FanHelperServer(
            hardware: FakeFans([:]),
            configuration: .init(socketPath: NSTemporaryDirectory() + "bs-unused.sock", ownerUID: getuid(),
                                 pin: .signingIdentifier(FanDaemon.clientSigningIdentifier)),
            log: { [weak self] in self?.lines.append($0) },
            powerMode: withRunner ? pmset : nil)
    }

    private func enter(_ server: FanHelperServer) -> FanReply { server.handle(.command(.enterLowPowerMode)) }
    private func restore(_ server: FanHelperServer, _ before: Int) -> FanReply {
        server.handle(.command(.restorePowerMode(before: before)))
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
        XCTAssertGreaterThan(PowerModeSwitch.callLimit + Double(calls - 1) * PowerModeSwitch.slowestCall, 2.0)
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
        XCTAssertGreaterThan(Double(pmset.calls.count) * PowerModeSwitch.callLimit, 2.0, "this is the case the link may not wait for")
        XCTAssertEqual(pmset.battery, 2)
        XCTAssertEqual(pmset.charger, 0)
        XCTAssertNil(server.heldPowerModes)
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
    private var log = Log()
    private var lines: [String] { log.lines }

    override func setUp() {
        super.setUp()
        pmset = FakePmset()
        log = Log()
    }

    override func tearDown() {
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

    private func start() throws {
        socketPath = NSTemporaryDirectory() + "bs-pwr-\(UUID().uuidString.prefix(8)).sock"
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0, let mine = FanPeer.of(socket: pair[0])?.cdhash else {
            throw XCTSkip("no code identity available in this test environment")
        }
        close(pair[0]); close(pair[1])
        server = FanHelperServer(hardware: FakeFans([:]),
                                 configuration: .init(socketPath: socketPath, ownerUID: getuid(),
                                                      pin: .exactBuild(cdhash: mine)),
                                 log: { [log] in log.add($0) },
                                 powerMode: pmset)
        try server.start()
        thread = Thread { [server] in server?.run() }
        thread.start()
        link = FanControlLink(socketPath: socketPath)
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

    /// Release, not hold: the app going away without a restore puts the mode back, by the same path an ordinary quit
    /// takes.
    func testAClosedConnectionPutsTheModeBack() throws {
        try start()
        let reply = send(.enterLowPowerMode)
        XCTAssertTrue(reply.ok, reply.message)
        XCTAssertEqual(reply.powerModeBefore, 2)
        XCTAssertEqual(pmset.battery, 1)
        // Still on between exchanges, and a release of the fans is not the client going.
        XCTAssertTrue(send(.releaseAll).ok)
        XCTAssertEqual(pmset.battery, 1)

        link.disconnect()
        spin(until: { self.pmset.battery == 2 && self.pmset.charger == 0 })
        XCTAssertEqual(pmset.battery, 2, "the mode stayed on after the app went away")
        XCTAssertEqual(pmset.charger, 0)
        XCTAssertNil(server.heldPowerModes)
        XCTAssertTrue(pmset.unexpected.isEmpty)
    }

    func testTheHelperStoppingPutsTheModeBack() throws {
        try start()
        XCTAssertTrue(send(.enterLowPowerMode).ok)
        server.stop()
        spin(until: { self.thread.isFinished })
        XCTAssertEqual(pmset.battery, 2, "a helper that stops leaves the Mac in Low Power Mode")
        XCTAssertEqual(pmset.charger, 0)
        XCTAssertTrue(lines.contains { $0.contains("the helper is stopping") }, "\(lines)")
    }

    /// A restore the app made itself leaves nothing for the close to do.
    func testAModeTheAppPutBackIsNotWrittenAgainOnClose() throws {
        try start()
        let before = send(.enterLowPowerMode).powerModeBefore ?? -1
        XCTAssertTrue(send(.restorePowerMode(before: before)).ok)
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
        XCTAssertTrue(send(.enterLowPowerMode).ok)
        pmset.ownerSets("-c", 2)
        link.disconnect()
        spin(until: { self.pmset.battery == 2 })
        XCTAssertEqual(pmset.charger, 2, "the owner's own choice was overwritten")
        XCTAssertEqual(pmset.writes.filter { $0.first == "-c" }, [["-c", "powermode", "1"]])
    }

    /// A put-back that was refused when the client went is tried again when the helper stops.
    func testAPutBackThatFailedOnCloseIsTriedAgainWhenTheHelperStops() throws {
        try start()
        XCTAssertTrue(send(.enterLowPowerMode).ok)
        pmset.refuseWrites(to: "-b")
        link.disconnect()
        spin(until: { self.lines.contains { $0.contains("could not put") } })
        XCTAssertEqual(pmset.battery, 1)
        XCTAssertNotNil(server.heldPowerModes)
        pmset.acceptWritesAgain()
        server.stop()
        spin(until: { self.thread.isFinished })
        XCTAssertEqual(pmset.battery, 2)
        XCTAssertNil(server.heldPowerModes)
    }
}

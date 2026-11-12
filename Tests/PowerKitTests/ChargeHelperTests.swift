import XCTest
@testable import PowerKit

// The helper's three charge commands — set macOS's charge limit, cut the charger
// to discharge, reconnect it — exercised against a fake. NOTHING here may build a
// `SystemChargeHardware`: that writes the real SMC and the real root preferences,
// and a cut outlives the process that made it.

// ── Pure decisions ──────────────────────────────────────────────────────────

final class DischargeWatchTests: XCTestCase {

    func testWatchRestoresAtTarget() {
        XCTAssertTrue(DischargeWatch.shouldRestore(target: 40, percent: 40, onAC: true))
        XCTAssertFalse(DischargeWatch.shouldRestore(target: 40, percent: 41, onAC: true))
        XCTAssertTrue(DischargeWatch.shouldRestore(target: 40, percent: nil, onAC: true),
                      "an unreadable battery must reconnect the charger, not keep draining")
        XCTAssertTrue(DischargeWatch.shouldRestore(target: 5, percent: 9, onAC: true),
                      "10% is a floor whatever the target says")
        XCTAssertTrue(DischargeWatch.shouldRestore(target: 40, percent: 70, onAC: false))
    }

    /// Unknown AC is not "unplugged". It is what the hardware reports while the
    /// charger is cut (see `ChargeAC.presence`), and treating it as unplugged
    /// would end every discharge on its first check.
    func testUnknownACDoesNotEndADischarge() {
        XCTAssertFalse(DischargeWatch.shouldRestore(target: 40, percent: 70, onAC: nil))
    }

    /// MEASURED: `ExternalConnected` reads No about 10 s after `CHIE` = 08, with
    /// the cable still in. While the charger is cut, that flag says nothing about
    /// the cable, so it is reported as unknown.
    func testACIsUnknownWhileTheChargerIsCut() {
        XCTAssertNil(ChargeAC.presence(externalConnected: false, cutByte: 0x08))
        XCTAssertNil(ChargeAC.presence(externalConnected: true, cutByte: 0x08))
        XCTAssertEqual(ChargeAC.presence(externalConnected: true, cutByte: 0x00), true)
        XCTAssertEqual(ChargeAC.presence(externalConnected: false, cutByte: 0x00), false)
        // Cut state unreadable: believe the flag. If it says unplugged, the
        // charger is reconnected, which is the direction that cannot hurt.
        XCTAssertEqual(ChargeAC.presence(externalConnected: false, cutByte: nil), false)
        XCTAssertNil(ChargeAC.presence(externalConnected: nil, cutByte: 0x00))
    }

    func testProtocolVersionIsTwo() {
        XCTAssertEqual(FanDaemon.protocolVersion, 2)
    }

    func testWireRoundTripOfChargeCommands() throws {
        let requests: [FanRequest] = [
            .command(.setChargeLimit(63)),
            .command(.discharge(toPercent: 40)),
            .command(.stopDischarge),
        ]
        for r in requests {
            var line = try FanWire.encode(r)
            XCTAssertEqual(line.last, 0x0A)
            line.removeLast()
            XCTAssertFalse(line.contains(0x0A))
            XCTAssertEqual(try FanWire.decode(FanRequest.self, from: line), r)
        }
    }
}

// ── The server, driven directly ─────────────────────────────────────────────

final class ChargeHelperTests: XCTestCase {

    private func makeServer(_ charge: FakeChargeHardware) -> FanHelperServer {
        FanHelperServer(hardware: FakeFans([:]),
                        configuration: .init(socketPath: NSTemporaryDirectory() + "bs-unused.sock",
                                             ownerUID: getuid(),
                                             pin: .signingIdentifier(FanDaemon.clientSigningIdentifier)),
                        charge: charge)
    }

    func testSetChargeLimitWritesOnceAndRejectsOutOfRange() {
        let hw = FakeChargeHardware()
        let server = makeServer(hw)

        XCTAssertTrue(server.handle(.command(.setChargeLimit(63))).ok)
        XCTAssertEqual(hw.limitWrites, [63])

        for bad in [19, 101, 0, -5] {
            let reply = server.handle(.command(.setChargeLimit(bad)))
            XCTAssertFalse(reply.ok, "\(bad) was accepted")
            XCTAssertFalse(reply.message.isEmpty)
        }
        XCTAssertEqual(hw.limitWrites, [63], "an out-of-range limit reached the preferences")
        XCTAssertTrue(hw.cutWrites.isEmpty, "a limit write touched the charger")
    }

    func testSetChargeLimitReportsAFailedWrite() {
        let hw = FakeChargeHardware()
        hw.refuseLimitWrites = true
        XCTAssertFalse(makeServer(hw).handle(.command(.setChargeLimit(80))).ok)
    }

    func testDischargeCutsAndRecordsTarget() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw)

        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)
        XCTAssertEqual(hw.cutWrites, [true])
        XCTAssertEqual(hw.isCut, true)
        XCTAssertEqual(server.dischargeTarget, 40)
    }

    func testDischargeRefusedWhenAlreadyAtTargetOrUnplugged() {
        let atTarget = FakeChargeHardware(percent: 40, onAC: true)
        let s1 = makeServer(atTarget)
        XCTAssertFalse(s1.handle(.command(.discharge(toPercent: 40))).ok)
        XCTAssertTrue(atTarget.cutWrites.isEmpty)
        XCTAssertNil(s1.dischargeTarget)

        let unplugged = FakeChargeHardware(percent: 77, onAC: false)
        let s2 = makeServer(unplugged)
        XCTAssertFalse(s2.handle(.command(.discharge(toPercent: 40))).ok)
        XCTAssertTrue(unplugged.cutWrites.isEmpty)
        XCTAssertNil(s2.dischargeTarget)
    }

    func testDischargeRefusesATargetOutOfRange() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw)
        for bad in [9, 101, 0, -1] {
            XCTAssertFalse(server.handle(.command(.discharge(toPercent: bad))).ok, "\(bad)")
        }
        XCTAssertTrue(hw.cutWrites.isEmpty)
        XCTAssertNil(server.dischargeTarget)
    }

    /// A refused cut takes nothing — but the reconnect is still sent, because a
    /// write the SMC "refused" is not proof that it did nothing.
    func testAFailedCutIsReportedAndHoldsNothing() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        hw.refuseCut = true
        let server = makeServer(hw)
        XCTAssertFalse(server.handle(.command(.discharge(toPercent: 40))).ok)
        XCTAssertNil(server.dischargeTarget)
        XCTAssertEqual(hw.cutWrites.last, false, "a failed cut was not followed by a reconnect")
    }

    func testStopDischargeRestores() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw)
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)

        XCTAssertTrue(server.handle(.command(.stopDischarge)).ok)
        XCTAssertEqual(hw.cutWrites, [true, false])
        XCTAssertEqual(hw.isCut, false)
        XCTAssertNil(server.dischargeTarget)
    }

    /// Asked to reconnect, it reconnects — even a cut this helper does not
    /// remember making.
    func testStopDischargeClearsACutItDidNotMake() {
        let hw = FakeChargeHardware(percent: 77, onAC: true, cut: true)
        let server = makeServer(hw)
        XCTAssertTrue(server.handle(.command(.stopDischarge)).ok)
        XCTAssertEqual(hw.isCut, false)
    }

    func testStopDischargeWithNothingCutWritesNothing() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        XCTAssertTrue(makeServer(hw).handle(.command(.stopDischarge)).ok)
        XCTAssertTrue(hw.cutWrites.isEmpty)
    }

    func testReleaseAllRestoresAdapterCut() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw)
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)

        // No fan is held, which is the case the fan release used to return early on.
        XCTAssertTrue(server.handle(.command(.releaseAll)).ok)
        XCTAssertEqual(hw.isCut, false)
        XCTAssertNil(server.dischargeTarget)
    }

    /// A reconnect that fails keeps the target, so the helper stays up and tries
    /// again on its next check rather than forgetting a cut it still holds.
    func testAFailedReconnectIsKeptAndRetried() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw)
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)

        hw.refuseRestore = true
        XCTAssertFalse(server.handle(.command(.stopDischarge)).ok)
        XCTAssertNotNil(server.dischargeTarget)
        XCTAssertFalse(server.isIdle)

        hw.refuseRestore = false
        server.watchDischarge()
        XCTAssertEqual(hw.isCut, false)
        XCTAssertNil(server.dischargeTarget)
    }

    func testTheWatchReconnectsAtTheTarget() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw)
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)

        hw.percent = 41
        server.watchDischarge()
        XCTAssertEqual(hw.isCut, true, "reconnected above the target")
        XCTAssertEqual(server.dischargeTarget, 40)

        hw.percent = 40
        server.watchDischarge()
        XCTAssertEqual(hw.isCut, false)
        XCTAssertNil(server.dischargeTarget)
    }

    func testTheWatchReconnectsWhenTheBatteryCannotBeRead() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw)
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)
        hw.percent = nil
        server.watchDischarge()
        XCTAssertEqual(hw.isCut, false)
    }

    func testStartupClearsOrphanedCut() {
        let hw = FakeChargeHardware(percent: 77, onAC: true, cut: true)
        var lines: [String] = []
        let server = FanHelperServer(hardware: FakeFans([:]),
                                     configuration: .init(socketPath: "/unused",
                                                          ownerUID: getuid(),
                                                          pin: .signingIdentifier("x")),
                                     log: { lines.append($0) },
                                     charge: hw)
        server.clearOrphanedAdapterCut()
        XCTAssertEqual(hw.isCut, false)
        XCTAssertEqual(hw.cutWrites, [false])
        XCTAssertTrue(lines.contains("cleared an adapter cut nobody owned"), "\(lines)")
    }

    func testStartupLeavesAConnectedChargerAlone() {
        let hw = FakeChargeHardware(percent: 77, onAC: true, cut: false)
        makeServer(hw).clearOrphanedAdapterCut()
        XCTAssertTrue(hw.cutWrites.isEmpty, "the default path must write nothing")
    }

    /// Both start paths run it, so neither mode can forget.
    func testStartingTheServerClearsAnOrphanedCut() throws {
        let hw = FakeChargeHardware(percent: 77, onAC: true, cut: true)
        let path = NSTemporaryDirectory() + "bs-chg-\(UUID().uuidString.prefix(8)).sock"
        let server = FanHelperServer(hardware: FakeFans([:]),
                                     configuration: .init(socketPath: path, ownerUID: getuid(),
                                                          pin: .signingIdentifier("x")),
                                     charge: hw)
        try server.start()
        defer { server.stop(); server.run() }   // run() unwinds at once and cleans up
        XCTAssertEqual(hw.isCut, false)
    }

    func testIdleRuleCountsADischargeAsHolding() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw)
        XCTAssertTrue(server.isIdle)
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)
        XCTAssertFalse(server.isIdle, "an on-demand daemon would exit mid-discharge")
        XCTAssertTrue(server.handle(.command(.stopDischarge)).ok)
        XCTAssertTrue(server.isIdle)
    }

    /// A helper with no charge hardware refuses the charge commands rather than
    /// pretending.
    func testAHelperWithoutChargeHardwareRefuses() {
        let server = FanHelperServer(hardware: FakeFans([:]),
                                     configuration: .init(socketPath: "/unused", ownerUID: getuid(),
                                                          pin: .signingIdentifier("x")))
        XCTAssertFalse(server.handle(.command(.setChargeLimit(80))).ok)
        XCTAssertFalse(server.handle(.command(.discharge(toPercent: 40))).ok)
        XCTAssertNil(server.dischargeTarget)
    }
}

// ── The server, over a real socket ──────────────────────────────────────────

/// The dead man's switch only exists on the socket path: `dropClient` runs when
/// a real connection goes away, and the shutdown release when the loop ends.
final class ChargeHelperSocketTests: XCTestCase {

    private var server: FanHelperServer!
    private var thread: Thread!
    private var link: FanControlLink!

    override func tearDown() {
        link?.disconnect()
        server?.stop()
        spin(until: { self.thread == nil || self.thread.isFinished }, timeout: 2)
        super.tearDown()
    }

    private func start(_ hw: FakeChargeHardware, watchEvery interval: TimeInterval? = nil) throws {
        let path = NSTemporaryDirectory() + "bs-chg-\(UUID().uuidString.prefix(8)).sock"
        guard let mine = ownCDHash() else {
            throw XCTSkip("no code identity available in this test environment")
        }
        server = FanHelperServer(hardware: FakeFans([:]),
                                 configuration: .init(socketPath: path, ownerUID: getuid(),
                                                      pin: .exactBuild(cdhash: mine)),
                                 charge: hw)
        if let interval { server.dischargeWatchInterval = interval }
        try server.start()
        thread = Thread { [server] in server?.run() }
        thread.start()
        link = FanControlLink(socketPath: path)
        var status: FanControlLink.Status?
        link.connect { status = $0 }
        spin(until: { status != nil })
    }

    private func ownCDHash() -> String? {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return nil }
        defer { close(pair[0]); close(pair[1]) }
        return FanPeer.of(socket: pair[0])?.cdhash
    }

    private func send(_ command: FanCommand) -> FanReply {
        var result: FanReply?
        link.send(command) { result = $0 }
        spin(until: { result != nil })
        return result ?? FanReply(ok: false, message: "no reply")
    }

    func testClientDropRestoresAdapterCut() throws {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        try start(hw)
        XCTAssertTrue(send(.discharge(toPercent: 40)).ok)
        XCTAssertEqual(hw.isCut, true)

        link.disconnect()
        spin(until: { hw.isCut == false })
        XCTAssertEqual(hw.isCut, false, "the charger stayed cut after the app went away")
        XCTAssertEqual(hw.cutWrites, [true, false])
    }

    /// The floor holds with the app connected and SILENT: the loop wakes on its
    /// own timer, looks at the battery, and reconnects at the target.
    func testTheLoopReconnectsAtTheTargetWithNoRequest() throws {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        try start(hw, watchEvery: 0.05)
        XCTAssertTrue(send(.discharge(toPercent: 40)).ok)
        spin(until: { false }, timeout: 0.2, failOnTimeout: false)
        XCTAssertEqual(hw.isCut, true, "reconnected above the target")

        hw.percent = 40   // nothing is sent; only the timed wake can see this
        spin(until: { hw.isCut == false })
        XCTAssertEqual(hw.isCut, false, "the loop never checked the battery on its own")
    }

    /// The charge limit is macOS's own setting and is deliberately left where
    /// it was put when the app goes away.
    func testTheLimitIsNotUndoneWhenTheClientLeaves() throws {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        try start(hw)
        XCTAssertTrue(send(.setChargeLimit(63)).ok)
        link.disconnect()
        spin(until: { false }, timeout: 0.3, failOnTimeout: false)
        XCTAssertEqual(hw.limitWrites, [63])
        XCTAssertTrue(hw.cutWrites.isEmpty)
    }

    /// SIGTERM and SIGINT reach the server as `stop()`.
    func testStoppingTheHelperRestoresAdapterCut() throws {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        try start(hw)
        XCTAssertTrue(send(.discharge(toPercent: 40)).ok)

        server.stop()
        spin(until: { self.thread.isFinished })
        XCTAssertEqual(hw.isCut, false, "the charger stayed cut after the helper stopped")
    }

    private func spin(until done: () -> Bool, timeout: TimeInterval = 3,
                      failOnTimeout: Bool = true,
                      file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if done() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if failOnTimeout && !done() {
            XCTFail("timed out after \(timeout)s", file: file, line: line)
        }
    }
}

// ── The fake ────────────────────────────────────────────────────────────────

/// Charge hardware that records instead of writing. Locked because the socket
/// tests touch it from the server's thread and inspect it from the main one.
final class FakeChargeHardware: ChargeHardware {
    private let lock = NSLock()
    private var _percent: Int?
    private var _onAC: Bool?
    private var _cut: Bool?
    private var _cutWrites: [Bool] = []
    private var _limitWrites: [Int] = []
    private var _refuseCut = false
    private var _refuseRestore = false
    private var _refuseLimit = false

    init(percent: Int? = 50, onAC: Bool? = true, cut: Bool? = false) {
        _percent = percent; _onAC = onAC; _cut = cut
    }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    var percent: Int? {
        get { locked { _percent } }
        set { locked { _percent = newValue } }
    }
    var isCut: Bool? { locked { _cut } }
    var cutWrites: [Bool] { locked { _cutWrites } }
    var limitWrites: [Int] { locked { _limitWrites } }
    var refuseCut: Bool {
        get { locked { _refuseCut } }
        set { locked { _refuseCut = newValue } }
    }
    var refuseRestore: Bool {
        get { locked { _refuseRestore } }
        set { locked { _refuseRestore = newValue } }
    }
    var refuseLimitWrites: Bool {
        get { locked { _refuseLimit } }
        set { locked { _refuseLimit = newValue } }
    }

    func adapterCut() -> Bool? { locked { _cut } }
    func setAdapterCut(_ on: Bool) -> Bool {
        locked {
            _cutWrites.append(on)
            if on ? _refuseCut : _refuseRestore { return false }
            _cut = on
            return true
        }
    }
    func batteryPercent() -> Int? { locked { _percent } }
    func onAC() -> Bool? { locked { _onAC } }
    func writeChargeLimit(_ percent: Int) -> Bool {
        locked {
            _limitWrites.append(percent)
            return !_refuseLimit
        }
    }
}

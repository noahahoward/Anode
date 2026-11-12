import XCTest
@testable import AnodeApp
@testable import PowerKit

/// The one connection to the helper that the Fans tab and Charge Control share.
///
/// The helper serves one client at a time, and a client leaving hands the fans back and reconnects the charger. So
/// sharing is only right if neither user can close or reopen the socket under the other. These tests run a real
/// `FanHelperServer` on a temporary socket, with fake fans behind it, and hold a fan target as the witness: anything
/// that closed or reopened the socket would have released that fan, and the fake would have recorded the write.
final class HelperConnectionTests: XCTestCase {

    private var server: FanHelperServer!
    private var thread: Thread!
    private var hardware: FakeFans!
    private var connection: HelperConnection!

    override func tearDown() {
        connection?.release(.fans)
        connection?.release(.charge)
        server?.stop()
        spin(until: { self.thread == nil || self.thread.isFinished }, timeout: 2, failOnTimeout: false)
        super.tearDown()
    }

    private func start() throws {
        let hw = FakeFans([0: .init(minRPM: 2317, maxRPM: 7826)])
        hw.seedTarget(0, 0)
        hardware = hw
        let socketPath = NSTemporaryDirectory() + "bs-share-\(UUID().uuidString.prefix(8)).sock"
        guard let mine = ownCDHash() else {
            throw XCTSkip("no code identity available in this test environment")
        }
        server = FanHelperServer(hardware: hw,
                                 configuration: .init(socketPath: socketPath, ownerUID: getuid(),
                                                      pin: .exactBuild(cdhash: mine)))
        try server.start()
        thread = Thread { [server] in server?.run() }
        thread.start()
        connection = HelperConnection(wire: FanControlLink(socketPath: socketPath))
    }

    private func ownCDHash() -> String? {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return nil }
        defer { close(pair[0]); close(pair[1]) }
        return FanPeer.of(socket: pair[0])?.cdhash
    }

    @discardableResult
    private func connect(_ holder: HelperConnection.Holder) -> FanControlLink.Status {
        var result: FanControlLink.Status?
        connection.connect(for: holder) { result = $0 }
        spin(until: { result != nil })
        return result ?? .disconnected
    }

    @discardableResult
    private func send(_ command: FanCommand) -> FanReply {
        var result: FanReply?
        connection.send(command) { result = $0 }
        spin(until: { result != nil })
        return result ?? FanReply(ok: false, message: "no reply")
    }

    /// Take fan 0 and forget the writes that took it, so any later write is a release.
    private func holdAFan() {
        XCTAssertTrue(send(.setTarget(FanTarget(index: 0, rpm: 5000))).ok)
        hardware.clear()
    }

    /// Give the helper every chance to release something it should not.
    private func settle() {
        spin(until: { false }, timeout: 0.4, failOnTimeout: false)
    }

    private func spin(until done: () -> Bool, timeout: TimeInterval = 3, failOnTimeout: Bool = true,
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

    // ── Over a real socket ──────────────────────────────────────────────────

    /// Two separate links would have the second turned away as "another Anode window".
    func testTheFansTabAndChargeControlShareOneSocket() throws {
        try start()
        XCTAssertEqual(connect(.fans), .connected(fanCount: 1, version: FanDaemon.protocolVersion))
        XCTAssertEqual(connect(.charge), .connected(fanCount: 1, version: FanDaemon.protocolVersion),
                       "the second user was turned away as a second client")
        XCTAssertTrue(connection.speaksCharge)
    }

    /// `FanControlLink.connect` closes an open socket before it opens a new one, which the helper takes as its
    /// client leaving. A connect on the shared link must greet over the open socket instead.
    func testConnectingAgainDoesNotReopenTheSocket() throws {
        try start()
        connect(.fans)
        holdAFan()
        connect(.fans)
        connect(.charge)
        settle()
        XCTAssertTrue(hardware.writes.isEmpty, "a connect reopened the socket and the helper released the fan")
        XCTAssertTrue(server.hasWrittenATarget)
    }

    /// Switching Charge Control off must not hand back fans the person is holding.
    func testChargeControlLettingGoKeepsTheFansHeld() throws {
        try start()
        connect(.fans)
        connect(.charge)
        holdAFan()
        connection.release(.charge)
        settle()
        XCTAssertTrue(hardware.writes.isEmpty, "Charge Control letting go closed the Fans tab's socket")
        XCTAssertTrue(server.hasWrittenATarget)
        XCTAssertTrue(connection.isConnected)
    }

    /// And switching fan control off must not close the socket a discharge depends on.
    func testTheFansTabLettingGoKeepsChargeControlsSocket() throws {
        try start()
        connect(.charge)
        connect(.fans)
        holdAFan()
        connection.release(.fans)
        settle()
        XCTAssertTrue(hardware.writes.isEmpty, "the Fans tab letting go closed Charge Control's socket")
        XCTAssertTrue(server.hasWrittenATarget)
        XCTAssertTrue(connection.isConnected)
    }

    /// The last user letting go is still the dead man's switch.
    func testTheLastToLetGoClosesTheSocket() throws {
        try start()
        connect(.charge)
        connect(.fans)
        holdAFan()
        connection.release(.fans)
        connection.release(.charge)
        spin(until: { !self.hardware.writes.isEmpty })
        XCTAssertFalse(server.hasWrittenATarget)
        XCTAssertFalse(connection.isConnected)
    }

    /// Installing or uninstalling stops the daemon under the socket, so it is closed for everyone and nobody may
    /// reconnect until that is over.
    func testSuspendClosesForEveryoneUntilResumed() throws {
        try start()
        connect(.charge)
        connect(.fans)
        holdAFan()
        connection.release(.fans)
        connection.suspend()
        spin(until: { !self.hardware.writes.isEmpty })
        XCTAssertFalse(connection.isConnected)
        XCTAssertEqual(connect(.charge), .notRunning, "a connect got through while suspended")
        connection.resume()
        spin(until: { self.connection.isConnected })
    }

    /// Charge Control's will-sleep handler waits for this answer on the main thread, so it must not come by way of
    /// the main thread.
    func testSendWaitingAnswersBeforeItReturns() throws {
        try start()
        connect(.charge)
        let reply = connection.sendWaiting(.stopDischarge, timeout: 2)
        XCTAssertNotNil(reply, "no answer before the call returned")
    }

    func testSendWaitingWithNothingConnectedReturnsNil() throws {
        try start()
        XCTAssertNil(connection.sendWaiting(.stopDischarge, timeout: 1))
    }

    // ── Bookkeeping, with a scripted wire ───────────────────────────────────

    /// The Fans tab's "return to automatic" also reconnects the charger. Charge Control is told after the command is
    /// on the wire, so whatever it asks for in answer goes after it.
    func testReleaseAllIsAnnouncedAsAResetAfterItIsSent() {
        let wire = ScriptedWire()
        let c = HelperConnection(wire: wire)
        var sentWhenTold: [FanCommand] = []
        let token = c.watch { sentWhenTold = wire.sent }
        let before = c.resets
        c.send(.releaseAll) { _ in }
        XCTAssertEqual(c.resets, before + 1)
        XCTAssertEqual(sentWhenTold, [.releaseAll])
        withExtendedLifetime(token) {}
    }

    /// A connect answered after its user has already let go is about a socket the release has since closed.
    func testAConnectAnsweredAfterTheLastHolderLeftIsIgnored() {
        let wire = ScriptedWire()
        let c = HelperConnection(wire: wire)
        var answered: FanControlLink.Status?
        c.connect(for: .charge) { answered = $0 }
        c.release(.charge)
        wire.answerConnects(.connected(fanCount: 0, version: 2), reopened: true)
        XCTAssertFalse(c.isConnected)
        XCTAssertNotNil(answered)
        XCTAssertNotEqual(answered, .connected(fanCount: 0, version: 2))
    }

    /// A reopened socket means the helper dropped whatever it held for the last one.
    func testAReopenedSocketCountsAsAReset() {
        let wire = ScriptedWire()
        let c = HelperConnection(wire: wire)
        c.connect(for: .charge) { _ in }
        wire.answerConnects(.connected(fanCount: 0, version: 2), reopened: true)
        let opened = c.resets
        c.connect(for: .charge) { _ in }
        wire.answerConnects(.connected(fanCount: 0, version: 2), reopened: false)
        XCTAssertEqual(c.resets, opened, "a greeting over the open socket was counted as a reset")
        c.connect(for: .charge) { _ in }
        wire.answerConnects(.connected(fanCount: 0, version: 2), reopened: true)
        XCTAssertEqual(c.resets, opened + 1)
    }

    func testAnOlderHelperDoesNotSpeakCharge() {
        let wire = ScriptedWire()
        let c = HelperConnection(wire: wire)
        c.connect(for: .charge) { _ in }
        wire.answerConnects(.connected(fanCount: 2, version: nil), reopened: true)
        XCTAssertTrue(c.isConnected)
        XCTAssertFalse(c.speaksCharge)
        let adapter = ChargeHelperAdapter(connection: c)
        XCTAssertFalse(adapter.available)
        XCTAssertTrue(adapter.outdated)
    }
}

/// A wire that answers connects only when told to, and records what it sent.
final class ScriptedWire: HelperWire {
    private(set) var sent: [FanCommand] = []
    private(set) var disconnects = 0
    private var connects: [(FanControlLink.Status, Bool) -> Void] = []

    func ensureConnected(_ done: @escaping (FanControlLink.Status, Bool) -> Void) { connects.append(done) }
    func ping(_ done: @escaping (FanControlLink.Status) -> Void) { done(.notRunning) }
    func send(_ command: FanCommand, _ done: @escaping (FanReply) -> Void) {
        sent.append(command)
        done(FanReply(ok: true, message: "ok"))
    }
    func sendWaiting(_ command: FanCommand, timeout: TimeInterval) -> FanReply? {
        sent.append(command)
        return FanReply(ok: true, message: "ok")
    }
    func disconnect() { disconnects += 1 }

    func answerConnects(_ status: FanControlLink.Status, reopened: Bool) {
        let pending = connects
        connects = []
        pending.forEach { $0(status, reopened) }
    }
}

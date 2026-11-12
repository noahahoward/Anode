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
        c.release(.charge)

        // Charge Control remembers what the helper said after letting the connection go.
        wire.answerAtOnce = .connected(fanCount: 2, version: nil)
        let adapter = ChargeHelperAdapter(connection: c, isInstalled: { true })
        adapter.follow {}
        XCTAssertFalse(c.isConnected, "let go after the greeting")
        XCTAssertFalse(adapter.available)
        XCTAssertTrue(adapter.outdated)
        adapter.letGo()
    }
}

/// Charge Control over the real adapter and the real shared connection, on a scripted wire: when it talks to the
/// helper, and when it leaves it alone.
///
/// The helper is a root daemon launchd starts on demand. Every hello wakes it, so Charge Control connects once at
/// launch (the daemon's startup clears a charger cut a dead helper left behind) and then only when it has something
/// to ask, and keeps the connection open only while a discharge lives on it.
final class ChargeControlConnectionTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var settings: Settings!
    private var client: FakeChargeLimitClient!
    private var wire: ScriptedWire!
    private var connection: HelperConnection!
    private var adapter: ChargeHelperAdapter!
    private var installed = true
    private var battery: Battery.State?
    private var lines: [String] = []
    private var controller: ChargeController?

    override func setUpWithError() throws {
        (defaults, suiteName) = try TestDefaults.make(owner: "ChargeControlConnection", test: name)
        settings = Settings(defaults: defaults)
        client = FakeChargeLimitClient()
        wire = ScriptedWire()
        wire.answerAtOnce = .connected(fanCount: 1, version: 2)
        connection = HelperConnection(wire: wire)
        installed = true
        adapter = ChargeHelperAdapter(connection: connection, isInstalled: { [weak self] in self?.installed ?? false })
        battery = ChargeControllerTests.state(70)
        lines = []
        // A limit the helper sets is macOS's own, and what the client then reads back.
        wire.reply = { [weak self] cmd in
            if case .setChargeLimit(let p) = cmd { self?.client.state?.mclLimit = p }
            return FanReply(ok: true, message: "ok")
        }
    }

    override func tearDownWithError() throws {
        controller?.shutdown()
        controller = nil
        settings = nil
        TestDefaults.destroy(defaults, suiteName)
    }

    @discardableResult
    private func make() -> ChargeController {
        settings.chargeControlEnabled = true
        let c = ChargeController(settings: settings, makeClient: { [weak self] in self?.client },
                                 helper: adapter, battery: { [weak self] in self?.battery },
                                 log: { [weak self] in self?.lines.append($0) })
        controller = c
        return c
    }

    private var traffic: [Int] { [wire.connectsAsked, wire.pings, wire.sent.count] }

    // ── Launch ──────────────────────────────────────────────────────────────

    /// Ruling 7: a connect at launch starts the daemon, whose startup clears an orphaned cut. Then it is let go.
    func testAtLaunchAnInstalledHelperIsGreetedOnceAndLetGo() {
        let c = make()
        XCTAssertEqual(wire.connectsAsked, 1)
        XCTAssertTrue(connection.holders.isEmpty, "Charge Control kept the connection with nothing to ask")
        XCTAssertEqual(wire.disconnects, 1)
        XCTAssertTrue(adapter.available)
        XCTAssertEqual(c.status, .active(ChargeDecision(osLimit: 80, dischargeTo: nil, reason: .limit)))
    }

    func testAHelperThatIsNotInstalledIsNeverConnected() {
        installed = false
        settings.chargeLimit = 63
        let c = make()
        XCTAssertEqual(wire.connectsAsked, 0)
        XCTAssertEqual(c.status, .needsHelper(ChargeController.limitNeedsHelperText),
                       "a helper known not to be installed is known at once")
        c.periodicTick()
        c.periodicTick()
        XCTAssertEqual(wire.connectsAsked, 0)
    }

    /// Nothing is said about the helper until it has answered: no "needs the helper" flash before the hello.
    func testNothingIsSaidAboutTheHelperBeforeItAnswers() {
        wire.answerAtOnce = nil
        settings.chargeLimit = 63
        let c = make()
        XCTAssertNotEqual(c.status, .needsHelper(ChargeController.limitNeedsHelperText))
        XCTAssertTrue(client.limitCalls.isEmpty)
        wire.answerConnects(.notRunning, reopened: true)
        XCTAssertEqual(c.status, .needsHelper(ChargeController.limitNeedsHelperText))
        XCTAssertEqual(client.limitCalls, [80])
    }

    // ── Quiet while nothing needs it ────────────────────────────────────────

    /// The 30 s timer never wakes the daemon while no discharge runs.
    func testNoPeriodicTrafficWhileNoDischargeRuns() {
        let c = make()
        let before = traffic
        for _ in 0..<5 { c.periodicTick() }
        XCTAssertEqual(traffic, before, "the timer talked to the helper with no discharge running")
    }

    /// Not even while the Fans tab holds the socket open.
    func testNoPeriodicTrafficWhileTheFansTabHoldsTheSocket() {
        let c = make()
        connection.connect(for: .fans) { _ in }
        let before = traffic
        for _ in 0..<5 { c.periodicTick() }
        XCTAssertEqual(traffic, before)
        connection.release(.fans)
    }

    /// The adapter's own check on the connection does nothing unless a discharge keeps it open.
    func testRefreshIsQuietUnlessKeptOpen() {
        adapter.follow {}
        let before = traffic
        adapter.refresh()
        XCTAssertEqual(traffic, before)
        adapter.keepOpen(true)
        let open = traffic
        adapter.refresh()
        XCTAssertEqual(wire.connectsAsked, open[0] + 1)
        adapter.letGo()
        XCTAssertTrue(connection.holders.isEmpty)
    }

    /// A limit only the helper can set: connect, set it, let go.
    func testALimitOnlyTheHelperCanSetIsSetAndTheConnectionLetGo() {
        settings.chargeLimit = 63
        let c = make()
        XCTAssertEqual(wire.sent, [.setChargeLimit(63)])
        XCTAssertTrue(connection.holders.isEmpty)
        XCTAssertEqual(c.status, .active(ChargeDecision(osLimit: 63, dischargeTo: nil, reason: .limit)))
        settings.chargeLimit = 64
        XCTAssertEqual(wire.sent, [.setChargeLimit(63), .setChargeLimit(64)])
        XCTAssertTrue(connection.holders.isEmpty)
        let before = traffic
        c.periodicTick()
        XCTAssertEqual(traffic, before)
    }

    // ── Open while a discharge lives on it ──────────────────────────────────

    /// Closing the socket would end the cut, so a discharge keeps it open; the timer may check on it then. Once the
    /// discharge has stopped, it is let go.
    func testADischargeKeepsTheConnectionUntilItStops() {
        battery = ChargeControllerTests.state(90)
        let c = make()
        c.pressDischarge()
        XCTAssertEqual(wire.sent, [.discharge(toPercent: 80)])
        XCTAssertTrue(connection.holders.contains(.charge))
        let closes = wire.disconnects
        c.periodicTick()
        XCTAssertEqual(wire.disconnects, closes, "the connection under a discharge was closed")
        XCTAssertTrue(connection.holders.contains(.charge))

        battery = ChargeControllerTests.state(89, ac: false, adapter: false)
        c.tick()
        XCTAssertEqual(wire.sent, [.discharge(toPercent: 80), .stopDischarge])
        XCTAssertTrue(connection.holders.isEmpty, "the connection was kept after the discharge stopped")
    }

    // ── Looking again ───────────────────────────────────────────────────────

    /// Showing the section looks again for a helper that has not answered (started since, say): one connect, let
    /// go. A helper that has answered is not woken for it.
    func testShowingTheSectionLooksAgainForAHelperThatHasNotAnswered() {
        wire.answerAtOnce = .notRunning
        settings.chargeLimit = 63
        let c = make()
        XCTAssertEqual(c.status, .needsHelper(ChargeController.limitNeedsHelperText))
        XCTAssertEqual(wire.connectsAsked, 1)

        wire.answerAtOnce = .connected(fanCount: 1, version: 2)
        c.recheckHelper()
        XCTAssertEqual(wire.connectsAsked, 2)
        XCTAssertEqual(wire.sent, [.setChargeLimit(63)])
        XCTAssertEqual(c.status, .active(ChargeDecision(osLimit: 63, dischargeTo: nil, reason: .limit)))
        XCTAssertTrue(connection.holders.isEmpty)

        let before = traffic
        c.recheckHelper()
        XCTAssertEqual(traffic, before, "a helper that had answered was woken to answer again")
    }

    /// An install or an uninstall closes the connection for everyone and opens it again; Charge Control looks
    /// again then. A limit the helper set stays in force after an uninstall (it is macOS's own setting); the next
    /// one it cannot set falls back.
    func testAnUninstallAndAnInstallAreNoticed() {
        settings.chargeLimit = 63
        let c = make()
        XCTAssertTrue(adapter.available)

        connection.suspend()
        installed = false
        connection.resume()
        XCTAssertFalse(adapter.available)
        settings.chargeLimit = 62
        XCTAssertEqual(c.status, .needsHelper(ChargeController.limitNeedsHelperText))
        XCTAssertEqual(client.limitCalls, [80])

        connection.suspend()
        installed = true
        connection.resume()
        XCTAssertTrue(adapter.available)
        XCTAssertEqual(wire.sent.last, .setChargeLimit(62))
        XCTAssertEqual(c.status, .active(ChargeDecision(osLimit: 62, dischargeTo: nil, reason: .limit)))
        XCTAssertTrue(connection.holders.isEmpty)
    }

    /// The real link answers a socket that is gone with "stopped answering", never with nothing. That helper is
    /// unavailable until it answers again, and the limit falls back to the nearest value macOS takes above it.
    func testAHelperThatStoppedAnsweringIsUnavailable() {
        settings.chargeLimit = 63
        let c = make()
        wire.answerAtOnce = .notRunning
        settings.chargeLimit = 64
        XCTAssertFalse(adapter.available)
        XCTAssertEqual(c.status, .needsHelper(ChargeController.limitNeedsHelperText))
        XCTAssertEqual(client.limitCalls, [80], "the limit was not held at the nearest value above it")
    }

    /// The same when the hello still answered and the command did not.
    func testAStoppedAnsweringReplyMakesTheHelperUnavailable() {
        settings.chargeLimit = 63
        let c = make()
        wire.reply = { _ in FanReply(ok: false, message: HelperConnection.stoppedAnswering) }
        settings.chargeLimit = 64
        XCTAssertFalse(adapter.available)
        XCTAssertEqual(c.status, .needsHelper(ChargeController.limitNeedsHelperText))
        XCTAssertEqual(client.limitCalls, [80])
        XCTAssertTrue(connection.holders.isEmpty)
    }

    /// What `HelperConnection` calls "stopped answering" is what `FanControlLink` really says.
    func testStoppedAnsweringIsWhatTheLinkSays() {
        let link = FanControlLink(socketPath: NSTemporaryDirectory() + "no-such-\(UUID().uuidString.prefix(8)).sock")
        var reply: FanReply?
        link.send(.stopDischarge) { reply = $0 }
        let deadline = Date().addingTimeInterval(3)
        while reply == nil, Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(reply, FanReply(ok: false, message: HelperConnection.stoppedAnswering))
    }
}

/// A wire that answers connects only when told to (or at once, with `answerAtOnce`), and records what it sent.
final class ScriptedWire: HelperWire {
    private(set) var sent: [FanCommand] = []
    private(set) var disconnects = 0
    /// Every `ensureConnected`: each is a hello, and the first after a close starts the daemon.
    private(set) var connectsAsked = 0
    private(set) var pings = 0
    private(set) var drains = 0
    private var connects: [(FanControlLink.Status, Bool) -> Void] = []

    /// When set, every connect is answered at once with this, as reopened when no socket was open; and a command
    /// with no socket open is answered the way `FanControlLink` answers it. Unset, connects wait for
    /// `answerConnects` and every command is answered ok.
    var answerAtOnce: FanControlLink.Status?
    /// A connect has answered "connected" and nothing has closed the socket since.
    private(set) var open = false
    var reply: (FanCommand) -> FanReply = { _ in FanReply(ok: true, message: "ok") }
    var pingStatus: FanControlLink.Status = .notRunning

    func ensureConnected(_ done: @escaping (FanControlLink.Status, Bool) -> Void) {
        connectsAsked += 1
        guard let status = answerAtOnce else { return connects.append(done) }
        let reopened = !open
        if case .connected = status { open = true } else { open = false }
        done(status, reopened)
    }
    func ping(_ done: @escaping (FanControlLink.Status) -> Void) {
        pings += 1
        done(pingStatus)
    }
    func send(_ command: FanCommand, _ done: @escaping (FanReply) -> Void) {
        sent.append(command)
        done(answer(command))
    }
    func sendWaiting(_ command: FanCommand, timeout: TimeInterval) -> FanReply? {
        sent.append(command)
        return answer(command)
    }
    func drain(timeout: TimeInterval) -> Bool {
        drains += 1
        return true
    }
    func disconnect() {
        disconnects += 1
        open = false
    }

    private func answer(_ command: FanCommand) -> FanReply {
        if answerAtOnce != nil, !open { return FanReply(ok: false, message: HelperConnection.stoppedAnswering) }
        return reply(command)
    }

    func answerConnects(_ status: FanControlLink.Status, reopened: Bool) {
        if case .connected = status { open = true } else { open = false }
        let pending = connects
        connects = []
        pending.forEach { $0(status, reopened) }
    }
}

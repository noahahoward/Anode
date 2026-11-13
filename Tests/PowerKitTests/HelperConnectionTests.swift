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

    /// The helper closing its socket while nothing is on it (it was killed, say) is a socket that went away: the
    /// status says so now and `resets` goes up, as it does for a command that finds the socket gone, so what listens
    /// (Charge Control, with a discharge on that socket) is told at once and not at its next tick.
    func testThePeerClosingBetweenExchangesIsRecordedAtOnce() {
        let wire = ScriptedWire()
        let c = HelperConnection(wire: wire)
        var heard = 0
        let token = c.watch { heard += 1 }
        c.connect(for: .charge) { _ in }
        wire.answerConnects(.connected(fanCount: 0, version: 2), reopened: true)
        let resets = c.resets, told = heard
        XCTAssertTrue(c.isConnected)
        wire.peerCloses()
        XCTAssertFalse(c.isConnected, "a helper that closed its socket was still taken to be connected")
        XCTAssertEqual(c.resets, resets + 1)
        XCTAssertGreaterThan(heard, told, "nobody was told")
        withExtendedLifetime(token) {}
    }

    /// A close made here is recorded where it is made; a report that comes after it is about a socket already gone.
    func testAPeerCloseReportedAfterALocalCloseChangesNothing() {
        let wire = ScriptedWire()
        let c = HelperConnection(wire: wire)
        c.connect(for: .charge) { _ in }
        wire.answerConnects(.connected(fanCount: 0, version: 2), reopened: true)
        c.release(.charge)
        let resets = c.resets
        wire.peerCloses()
        XCTAssertEqual(c.resets, resets, "one close was counted twice")
        XCTAssertFalse(c.isConnected)
    }

    /// What the real adapter takes a helper to speak, from what it says in its hello. The plan commands go only to one that
    /// has said 3: an older helper cannot decode them, closes the connection, and so ends a drain and hands the fans back.
    func testTheAdapterSpeaksReadyByOnlyFromProtocolThree() {
        let cases: [(version: Int?, available: Bool, readyBy: Bool, outdated: Bool)] = [
            (nil, false, false, true), (1, false, false, true),
            (2, true, false, false), (3, true, true, false), (4, true, true, false),
        ]
        for c in cases {
            let wire = ScriptedWire()
            wire.answerAtOnce = .connected(fanCount: 2, version: c.version)
            let adapter = ChargeHelperAdapter(connection: HelperConnection(wire: wire), isInstalled: { true })
            adapter.follow {}
            let label = "protocol \(c.version.map(String.init) ?? "none")"
            XCTAssertEqual(adapter.available, c.available, label)
            XCTAssertEqual(adapter.speaksReadyBy, c.readyBy, label)
            XCTAssertEqual(adapter.outdated, c.outdated, label)
            adapter.letGo()
        }
        // And one that is not there, or has stopped answering, speaks nothing.
        let wire = ScriptedWire()
        wire.answerAtOnce = .notRunning
        let adapter = ChargeHelperAdapter(connection: HelperConnection(wire: wire), isInstalled: { true })
        adapter.follow {}
        XCTAssertFalse(adapter.speaksReadyBy)
        adapter.letGo()
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
    private func make(enabled: Bool = true) -> ChargeController {
        settings.chargeControlEnabled = enabled
        let c = ChargeController(settings: settings, makeClient: { [weak self] in self?.client },
                                 helper: adapter, battery: { [weak self] in self?.battery },
                                 chargerSwitch: { nil }, log: { [weak self] in self?.lines.append($0) },
                                 onConsole: { true })
        controller = c
        return c
    }

    private var traffic: [Int] { [wire.connectsAsked, wire.pings, wire.sent.count] }

    // ── Ready By, over the real adapter ─────────────────────────────────────

    private func isPlan(_ c: FanCommand) -> Bool {
        if case .scheduleChargeLimit = c { return true } else { return false }
    }

    /// Charge Control holding at 54 for Ready By, at 23:00 UTC with 7:00 to be ready by, the helper saying `version`.
    @discardableResult
    private func makeReadyBy(helperSpeaks version: Int) -> ChargeController {
        wire.answerAtOnce = .connected(fanCount: 1, version: version)
        settings.chargeReadyByEnabled = true
        settings.chargeControlEnabled = true
        battery = ReadyByControllerTests.plugged(54)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let c = ChargeController(settings: settings, makeClient: { [weak self] in self?.client },
                                 helper: adapter, battery: { [weak self] in self?.battery },
                                 chargerSwitch: { nil }, log: { [weak self] in self?.lines.append($0) },
                                 onConsole: { true }, rateStore: MemoryRateStore(),
                                 now: { ISO8601DateFormatter().date(from: "2026-11-12T23:00:00Z")! },
                                 calendar: { utc })
        controller = c
        return c
    }

    /// The plan goes out on a connection that stays open, and is let go when the plan is cancelled: the link would
    /// otherwise close the socket after the waited command, and the helper drops a plan with its connection. (The
    /// controller asks for the connection to be held before the waited send; so would the news of it opening. What is
    /// pinned here is that it is still open afterwards, and that it goes with the plan.)
    func testThePlanSurvivesTheLinkLettingGoAfterItsCommand() {
        let c = makeReadyBy(helperSpeaks: 3)
        XCTAssertEqual(c.lastDecision?.reason, .readyBy)
        XCTAssertTrue(connection.holders.isEmpty, "nothing is pending before the Mac sleeps")
        let disconnects = wire.disconnects
        c.willSleep()
        XCTAssertEqual(wire.sent.filter(isPlan).count, 1, "\(wire.sent)")
        XCTAssertNotNil(c.wakePlan)
        XCTAssertEqual(wire.disconnects, disconnects, "the socket the plan went out on was closed")
        XCTAssertTrue(connection.holders.contains(.charge), "the connection is not held for the plan")
        XCTAssertTrue(wire.open)
        c.didWake(now: ISO8601DateFormatter().date(from: "2026-11-13T01:00:00Z")!)
        XCTAssertTrue(wire.open, "a wake before the moment closed the connection the plan lives on")
        XCTAssertEqual(wire.sent.filter { $0 == .cancelScheduledChargeLimit }.count, 0)

        settings.chargeReadyByEnabled = false
        XCTAssertEqual(wire.sent.filter { $0 == .cancelScheduledChargeLimit }.count, 1)
        XCTAssertTrue(connection.holders.isEmpty, "the connection is held for a plan that is gone")
        XCTAssertFalse(wire.open)
    }

    /// A helper that speaks 2 would close the connection on a command it cannot decode, which ends a drain and hands
    /// the fans back. It is never sent one: not the plan, and not the cancel.
    func testAProtocolTwoHelperIsNeverSentAPlanOrACancelOverTheRealLink() {
        let c = makeReadyBy(helperSpeaks: 2)
        XCTAssertEqual(c.lastDecision?.reason, .limit, "Ready By is not in force without a helper that can wake the Mac")
        c.willSleep()
        c.didWake(now: ISO8601DateFormatter().date(from: "2026-11-13T01:00:00Z")!)
        settings.chargeReadyByEnabled = false
        settings.chargeReadyByEnabled = true
        c.pressFullCharge()
        c.pressFullCharge()
        c.shutdown()
        XCTAssertTrue(wire.sent.filter(isPlan).isEmpty, "\(wire.sent)")
        XCTAssertFalse(wire.sent.contains(.cancelScheduledChargeLimit), "\(wire.sent)")
    }

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
        c.pressDrain()
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

    // ── A helper that dies under a discharge ────────────────────────────────

    /// Measured: a killed helper leaves the charger cut, and the installed daemon is not kept alive; only a new
    /// connection to its socket starts a fresh helper, whose startup reconnects the charger. Stop pressed moments
    /// after the death must open that connection and ask the new helper, not take the dead socket's silence for an
    /// end.
    func testAHelperThatDiesUnderADischargeIsGreetedAgain() {
        battery = ChargeControllerTests.state(90)
        let c = make()
        c.pressDrain()
        XCTAssertEqual(wire.sent, [.discharge(toPercent: 80)])
        let connects = wire.connectsAsked
        wire.die()
        c.pressDrain()   // Stop
        XCTAssertGreaterThan(wire.connectsAsked, connects, "nothing greeted the helper again")
        XCTAssertEqual(wire.sent.last, .stopDischarge)
        XCTAssertEqual(wire.reachedAHelper.last, true, "the stop was not asked of a fresh helper")
        XCTAssertFalse(settings.chargeCutUnconfirmed, "the fresh helper's answer did not settle the debt")
        XCTAssertNil(c.dischargeInForce)
        XCTAssertEqual(c.status, .active(ChargeDecision(osLimit: 80, dischargeTo: nil, reason: .limit)))
        XCTAssertTrue(connection.holders.isEmpty, "the connection was kept after the charger was confirmed connected")
    }

    /// The same when the target is reached instead, and the stop is Charge Control's own.
    func testAHelperThatDiesBeforeTheTargetIsReachedIsGreetedAgain() {
        battery = ChargeControllerTests.state(90)
        let c = make()
        c.pressDrain()
        wire.die()
        battery = ChargeControllerTests.state(80)
        c.tick()
        XCTAssertEqual(wire.sent.last, .stopDischarge)
        XCTAssertEqual(wire.reachedAHelper.last, true)
        XCTAssertFalse(settings.chargeCutUnconfirmed)
    }

    /// Switching Charge Control off moments after the helper died: the waited stop opens a fresh connection rather
    /// than going to the dead one.
    func testSwitchingOffAfterTheHelperDiedStillReconnects() {
        battery = ChargeControllerTests.state(90)
        let c = make()
        c.pressDrain()
        let connects = wire.connectsAsked
        wire.die()
        settings.chargeControlEnabled = false
        XCTAssertGreaterThan(wire.connectsAsked, connects, "switching off did not greet the helper again")
        XCTAssertEqual(wire.sent.last, .stopDischarge)
        XCTAssertEqual(wire.reachedAHelper.last, true, "the stop went to the dead socket")
        XCTAssertFalse(settings.chargeCutUnconfirmed, "the stop did not reach a running helper")
        XCTAssertNil(settings.chargeRestoreRecord)
        XCTAssertEqual(c.status, .off)
        XCTAssertTrue(connection.holders.isEmpty)
    }

    /// A relaunch with Charge Control off and the debt left over greets the installed helper and asks it to
    /// reconnect; then lets go.
    func testARelaunchWhileOffWithTheDebtGreetsTheHelper() {
        settings.chargeCutUnconfirmed = true
        make(enabled: false)
        XCTAssertGreaterThan(wire.connectsAsked, 0, "a relaunch while off never greeted the helper")
        XCTAssertEqual(wire.sent, [.stopDischarge])
        XCTAssertFalse(settings.chargeCutUnconfirmed)
        XCTAssertTrue(connection.holders.isEmpty)
    }

    /// A helper that answered nothing at launch (a cold start slower than its hello) is looked for again while
    /// something needs it: 30 s, 60 s and 120 s apart, then every five minutes.
    func testAHelperMissingAtLaunchIsLookedForAgainWithBackoff() {
        let t0 = Date()
        wire.answerAtOnce = .notRunning
        settings.chargeLimit = 60
        let c = make()
        XCTAssertEqual(wire.connectsAsked, 1)
        func at(_ s: TimeInterval) { c.periodicTick(now: t0.addingTimeInterval(s)) }
        at(31)
        XCTAssertEqual(wire.connectsAsked, 2, "not looked for again 30 s later")
        at(61)
        XCTAssertEqual(wire.connectsAsked, 2, "looked for again too soon")
        at(92)
        XCTAssertEqual(wire.connectsAsked, 3)
        at(152)
        XCTAssertEqual(wire.connectsAsked, 3)
        at(213)
        XCTAssertEqual(wire.connectsAsked, 4)
        at(400)
        XCTAssertEqual(wire.connectsAsked, 4)
        at(514)
        XCTAssertEqual(wire.connectsAsked, 5)
        at(815)
        XCTAssertEqual(wire.connectsAsked, 6)

        wire.answerAtOnce = .connected(fanCount: 1, version: 2)
        at(1116)
        XCTAssertEqual(c.status, .active(ChargeDecision(osLimit: 60, dischargeTo: nil, reason: .limit)))
        XCTAssertEqual(wire.sent, [.setChargeLimit(60)])
        let found = wire.connectsAsked
        at(2000)
        at(3000)
        XCTAssertEqual(wire.connectsAsked, found, "looked for again after it was found")
    }

    /// Nothing is looked for when nothing needs the helper.
    func testAHelperMissingWhileNothingNeedsItIsLeftAlone() {
        let t0 = Date()
        wire.answerAtOnce = .notRunning
        let c = make()
        let before = wire.connectsAsked
        for s in stride(from: 30.0, through: 1200, by: 30) { c.periodicTick(now: t0.addingTimeInterval(s)) }
        XCTAssertEqual(wire.connectsAsked, before)
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
        // 80 twice: once ahead of the helper's 63 at switch-on (that is what turns macOS's limit on), once as the
        // nearest value macOS takes itself now that no helper can set 62.
        XCTAssertEqual(client.limitCalls, [80, 80])

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
        // 80 ahead of the helper's 63 at switch-on, then 80 as the fall-back for 64.
        XCTAssertEqual(client.limitCalls, [80, 80], "the limit was not held at the nearest value above it")
    }

    /// The same when the hello still answered and the command did not.
    func testAStoppedAnsweringReplyMakesTheHelperUnavailable() {
        settings.chargeLimit = 63
        let c = make()
        wire.reply = { _ in FanReply(ok: false, message: HelperConnection.stoppedAnswering) }
        settings.chargeLimit = 64
        XCTAssertFalse(adapter.available)
        XCTAssertEqual(c.status, .needsHelper(ChargeController.limitNeedsHelperText))
        XCTAssertEqual(client.limitCalls, [80, 80])   // ahead of the helper's 63, then the fall-back for 64
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

/// The Fans tab on the shared connection: when someone else replaced or closed the socket, the helper has handed the
/// fans back, and the strip must stop claiming them.
///
/// The panel is built on a test `Settings` and a `HelperConnection` over a scripted wire; nothing reaches the real
/// helper, the real preferences, or an install dialog.
final class FanPanelSharingTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var settings: Settings!
    private var wire: ScriptedWire!
    private var connection: HelperConnection!
    private let fans = [FanInfo(index: 0, currentRPM: 2317, minRPM: 2317, maxRPM: 7826, targetRPM: 2317)]
    private let limits = FanPolicy.Limits(minRPM: 2317, maxRPM: 7826)
    /// Holds a scripted authorisation open; let go in tearDown too, so a failed test cannot leave a thread waiting.
    private var gate: DispatchSemaphore?

    override func setUpWithError() throws {
        _ = NSApplication.shared
        (defaults, suiteName) = try TestDefaults.make(owner: "FanPanelSharing", test: name)
        settings = Settings(defaults: defaults)
        wire = ScriptedWire()
        wire.answerAtOnce = .connected(fanCount: 1, version: 2)
        wire.pingStatus = .connected(fanCount: 1, version: 2)
        connection = HelperConnection(wire: wire)
    }

    override func tearDownWithError() throws {
        gate?.signal()
        gate = nil
        connection.release(.fans)
        connection.release(.charge)
        settings = nil
        TestDefaults.destroy(defaults, suiteName)
    }

    /// A strip whose install reaches nothing outside the test: a made-up bundled helper, a confirmation that answers
    /// `confirm` without a dialog, and an authorisation that answers `authorise` without running anything.
    private func installingPanel(bundled: String? = "/Applications/Anode.app/Contents/MacOS/AnodeHelper",
                                 confirm: @escaping (String, FanControlPanel.InstallOrigin) -> Bool = { _, _ in true },
                                 authorise: @escaping () -> FanElevation.Result,
                                 uninstalled: @escaping () -> Void = {}) -> FanControlPanel {
        FanControlPanel(frame: NSRect(x: 0, y: 0, width: 420, height: 200), settings: settings, link: connection,
                        installSteps: FanControlPanel.InstallSteps(bundledHelper: { bundled },
                                                                   confirm: confirm,
                                                                   authorise: { _, _ in authorise() }),
                        helperUninstalled: uninstalled)
    }

    // ── Uninstalling the helper ─────────────────────────────────────────────

    /// The helper's uninstall reconnects the charger, and fails when it cannot (`FanElevation.uninstallEnd`). So
    /// one that finished tells Charge Control, which settles a discharge's end it could no longer confirm; and it
    /// does so before the shared connection opens again, so nothing asks the gone helper first. One that was
    /// cancelled or failed says nothing.
    func testAHelperUninstallThatFinishedTellsChargeControlFirst() {
        func uninstall(answering result: FanElevation.Result) -> [Bool] {
            var told: [Bool] = []
            let panel = installingPanel(authorise: { result },
                                        uninstalled: { told.append(self.connection.suspended) })
            panel.uninstallHelper()
            XCTAssertTrue(connection.suspended)
            let deadline = Date().addingTimeInterval(5)
            while connection.suspended, Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            XCTAssertFalse(connection.suspended, "the shared connection was left shut")
            withExtendedLifetime(panel) {}
            return told
        }
        XCTAssertEqual(uninstall(answering: .done("Reconnecting the charger…\n  charger reconnected\n")), [true],
                       "Charge Control was not told, or was told after the connection opened again")
        XCTAssertEqual(uninstall(answering: .cancelled), [])
        XCTAssertEqual(uninstall(answering: .failed("The charger may still be switched off")), [])
    }

    /// A strip with fan control on, connected through the shared connection, holding fan 0.
    private func panelHoldingAFan() -> FanControlPanel {
        settings.fanControlEnabled = true
        let panel = FanControlPanel(frame: NSRect(x: 0, y: 0, width: 420, height: 200),
                                    settings: settings, link: connection)
        panel.update(fans: fans)   // not connected yet: connects
        guard case .connected = panel.session.helper else {
            XCTFail("the strip did not connect: \(panel.session.helper)")
            return panel
        }
        var s = panel.session
        _ = s.apply(.setSpeed(index: 0, rpm: 5000, limits: limits))
        panel.session = s
        XCTAssertTrue(panel.isDriving)
        return panel
    }

    /// Fans held, Fans tab closed. The helper drops the socket; Charge Control opens a new one, and the helper has
    /// released the fans with the old one. The Fans tab opens: its hello answers on the new socket. The strip must
    /// not go on claiming the fan.
    func testASocketReplacedBySomeoneElseHandsTheFansBack() {
        let panel = panelHoldingAFan()
        wire.disconnect()   // the helper went away under the open socket
        connection.connect(for: .charge) { _ in }   // Charge Control's next connect opens a new one
        connection.release(.charge)
        panel.update(fans: fans)
        XCTAssertFalse(panel.isDriving, "the strip still claims a fan the helper handed back")
        XCTAssertTrue(panel.session.held.isEmpty)
    }

    /// Charge Control greeting the helper over the socket the strip holds, and letting go of it, changes nothing.
    func testChargeControlSharingTheSocketKeepsTheFansHeld() {
        let panel = panelHoldingAFan()
        connection.connect(for: .charge) { _ in }
        connection.release(.charge)
        panel.update(fans: fans)
        panel.update(fans: fans)
        XCTAssertTrue(panel.isDriving, "the strip let go of a fan nobody released")
        XCTAssertEqual(panel.session.held[0], 5000)
    }

    /// Without Charge Control, nothing changes: a strip left alone keeps its fan.
    func testWithoutChargeControlTheStripKeepsItsFan() {
        let panel = panelHoldingAFan()
        for _ in 0..<3 { panel.update(fans: fans) }
        XCTAssertTrue(panel.isDriving)
        XCTAssertEqual(wire.connectsAsked, 1)
    }

    // ── Installing from Charge Control ──────────────────────────────────────

    /// "Install Helper…" in Charge Control installs the helper; it is not a request for fan control.
    func testAnInstallFromChargeControlDoesNotTurnFanControlOn() {
        settings.fanControlEnabled = false
        let panel = FanControlPanel(frame: NSRect(x: 0, y: 0, width: 420, height: 200),
                                    settings: settings, link: connection)
        panel.installSucceeded(from: .chargeControl)
        XCTAssertFalse(settings.fanControlEnabled, "installing for Charge Control turned fan control on")
        XCTAssertFalse(panel.session.enabled)
    }

    /// The same, through the whole install Charge Control starts (`installHelper`), not only its last step: fan
    /// control stays off, and Charge Control is told each step.
    func testAnInstallStartedFromChargeControlLeavesFanControlOffAndSaysSo() {
        settings.fanControlEnabled = false
        var origins: [FanControlPanel.InstallOrigin] = []
        let panel = installingPanel(confirm: { _, origin in origins.append(origin); return true },
                                    authorise: { .done("") })
        var heard: [String] = []
        let finished = expectation(description: "the install finished")
        panel.installHelper { text in
            heard.append(text)
            if heard.count == 2 { finished.fulfill() }
        }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(heard, ["Waiting for authorisation\u{2026}",
                               "The Anode helper is installed. Fan control is as it was."])
        XCTAssertEqual(origins, [.chargeControl])
        XCTAssertFalse(settings.fanControlEnabled, "installing for Charge Control turned fan control on")
        XCTAssertFalse(panel.session.enabled)
        XCTAssertFalse(connection.suspended, "the shared connection was left shut")
    }

    /// Every way an install from Charge Control can end is said to Charge Control, which cannot see this strip.
    func testAnInstallFromChargeControlSaysEveryStepWhereItWasStarted() {
        // A second press while the authorisation is up, then a failure.
        let gate = DispatchSemaphore(value: 0)
        self.gate = gate
        let panel = installingPanel(authorise: { gate.wait(); return .failed("the disk is locked") })
        var heard: [String] = []
        let failed = expectation(description: "the install failed")
        let report = { (text: String) in
            heard.append(text)
            if text.hasPrefix("The Anode helper was not installed") { failed.fulfill() }
        }
        panel.installHelper(report: report)
        XCTAssertEqual(heard, ["Waiting for authorisation\u{2026}"])
        panel.installHelper(report: report)
        XCTAssertEqual(heard.last, "Finish the authorisation already on screen.")
        gate.signal()
        wait(for: [failed], timeout: 5)
        XCTAssertEqual(heard.last, "The Anode helper was not installed: the disk is locked")

        // Cancelled in the system's dialog.
        heard = []
        let cancelled = expectation(description: "the install was cancelled")
        let cancelling = installingPanel(authorise: { .cancelled })
        cancelling.installHelper { text in
            heard.append(text)
            if heard.count == 2 { cancelled.fulfill() }
        }
        wait(for: [cancelled], timeout: 5)
        withExtendedLifetime(cancelling) {}
        XCTAssertEqual(heard.last, "Cancelled \u{2014} nothing was changed.")

        // Not a bundled build: nothing to install, and no dialog.
        heard = []
        var asked = 0
        installingPanel(bundled: nil, confirm: { _, _ in asked += 1; return true },
                        authorise: { XCTFail("authorised without a helper to install"); return .cancelled })
            .installHelper { heard.append($0) }
        XCTAssertEqual(heard, ["Only a bundled build can be installed. Run ./build-app.sh and open "
                               + "~/Applications/Anode.app."])
        XCTAssertEqual(asked, 0)

        // The person said no to the confirmation: nothing happens, so there is nothing to say.
        heard = []
        installingPanel(confirm: { _, _ in false },
                        authorise: { XCTFail("authorised after the person said no"); return .cancelled })
            .installHelper { heard.append($0) }
        XCTAssertEqual(heard, [])
    }

    /// "Install Helper…" in Ultra Low Power Mode's section takes the same route, and says what is true of this feature:
    /// nothing about fans, and what the helper will now do. Fan control stays off; what the other two say is unchanged.
    func testAnInstallStartedFromTheLowPowerSectionSaysSoWithoutTalkingAboutFans() {
        settings.fanControlEnabled = false
        var origins: [FanControlPanel.InstallOrigin] = []
        let panel = installingPanel(confirm: { _, origin in origins.append(origin); return true },
                                    authorise: { .done("") })
        var heard: [String] = []
        let finished = expectation(description: "the install finished")
        panel.installHelper(report: { text in
            heard.append(text)
            if heard.count == 2 { finished.fulfill() }
        }, from: .ultraLowPower)
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(heard, ["Waiting for authorisation\u{2026}",
                               "The Anode helper is installed. Low Power Mode will be switched on the next time "
                               + "Ultra Low Power Mode starts."])
        XCTAssertEqual(heard.last, FanControlPanel.installedForUltraLowPowerText)
        XCTAssertFalse(FanControlPanel.installedForUltraLowPowerText.localizedCaseInsensitiveContains("fan"))
        XCTAssertEqual(origins, [.ultraLowPower])
        XCTAssertFalse(settings.fanControlEnabled, "installing for Low Power Mode turned fan control on")
        XCTAssertFalse(panel.session.enabled)
        XCTAssertFalse(connection.suspended, "the shared connection was left shut")
        // The other two are as they were.
        XCTAssertEqual(FanControlPanel.installedForChargeControlText, "The Anode helper is installed. Fan control is as it was.")
        let alert = FanControlPanel.installAlert(helper: "/x", origin: .ultraLowPower)
        XCTAssertEqual(alert.messageText, "Install the Anode helper?")
        XCTAssertTrue(alert.informativeText.contains("switch macOS's Low Power Mode on and put it back"), alert.informativeText)
    }

    /// The helper installed before this release speaks 3, and this app speaks 4. The strip does not turn it away: it
    /// connects, a fan can be taken, and all it says about the helper is its own line that a newer one can be installed.
    func testAHelperThatSpeaksThreeStillDrivesTheFans() {
        wire.answerAtOnce = .connected(fanCount: 1, version: 3)
        wire.pingStatus = .connected(fanCount: 1, version: 3)
        let panel = panelHoldingAFan()
        XCTAssertEqual(panel.session.helper, .connected(fanCount: 1))
        XCTAssertEqual(panel.session.mode, .manual(fans: 1))
        XCTAssertTrue(panel.isDriving)
        XCTAssertEqual(FanDaemon.state(installed: true, answered: true, helloVersion: 3), .installedButOlder(daemonVersion: 3))
        XCTAssertTrue(FanDaemon.summary(.installedButOlder(daemonVersion: 3)).contains("Install it again"))
    }

    /// The Fans tab's own install still is.
    func testAnInstallFromTheFansTabTurnsFanControlOn() {
        settings.fanControlEnabled = false
        let panel = FanControlPanel(frame: NSRect(x: 0, y: 0, width: 420, height: 200),
                                    settings: settings, link: connection)
        panel.installSucceeded(from: .fansTab)
        XCTAssertTrue(settings.fanControlEnabled)
        XCTAssertTrue(panel.session.enabled)
    }

    /// The confirmation names the helper; from Charge Control it does not call it the fan helper. The body lists
    /// everything the helper can do either way.
    func testTheConfirmationFromChargeControlIsNotAboutFans() {
        let charge = FanControlPanel.installAlert(helper: "/Applications/Anode.app/Contents/MacOS/AnodeHelper",
                                                  origin: .chargeControl)
        XCTAssertFalse(charge.messageText.localizedCaseInsensitiveContains("fan"), charge.messageText)
        XCTAssertTrue(charge.messageText.contains("Anode helper"), charge.messageText)
        XCTAssertTrue(charge.informativeText.contains("set the macOS charge limit"), charge.informativeText)
        XCTAssertTrue(charge.informativeText.contains("cut the charger"), charge.informativeText)
        let fansTab = FanControlPanel.installAlert(helper: "/x", origin: .fansTab)
        XCTAssertEqual(fansTab.messageText, "Install the fan helper?")
    }

    /// The body is the same from both places, so it is true from both: it does not point at "this strip" (from
    /// Charge Control there is none on screen), it names the Anode helper, and it names the Fans tab's uninstall by
    /// its exact title and says where it is.
    func testTheConfirmationBodyIsTrueFromBothPlaces() {
        for origin in [FanControlPanel.InstallOrigin.fansTab, .chargeControl] {
            let body = FanControlPanel.installAlert(helper: "/x", origin: origin).informativeText
            XCTAssertFalse(body.contains("strip"), body)
            XCTAssertTrue(body.contains("the Anode helper"), body)
            XCTAssertTrue(body.contains("\"Uninstall Fan Helper\u{2026}\" in the Fans tab"), body)
            XCTAssertTrue(body.contains("The safer alternative is in the Fans tab"), body)
        }
    }
}

/// A wire that answers connects only when told to (or at once, with `answerAtOnce`), and records what it sent.
final class ScriptedWire: HelperWire {
    private(set) var sent: [FanCommand] = []
    /// For each command sent, whether a helper was there to take it (a socket open on a running one).
    private(set) var reachedAHelper: [Bool] = []
    private(set) var disconnects = 0
    /// Every `ensureConnected`: each is a hello, and the first after a close starts the daemon.
    private(set) var connectsAsked = 0
    private(set) var pings = 0
    private(set) var drains = 0
    private var connects: [(FanControlLink.Status, Bool) -> Void] = []
    var onPeerClosed: (() -> Void)?

    /// The helper closed the socket while nothing was on it, and the link says so.
    func peerCloses() {
        open = false
        onPeerClosed?()
    }

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
        reachedAHelper.append(answerAtOnce == nil || open)
        done(answer(command))
    }
    /// Like `FanControlLink`: nothing, not a refusal, when there is no socket.
    func sendWaiting(_ command: FanCommand, timeout: TimeInterval) -> FanReply? {
        sent.append(command)
        reachedAHelper.append(answerAtOnce == nil || open)
        if answerAtOnce != nil, !open { return nil }
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
    /// Nothing is ever queued here, so there is nothing not to wait for.
    func disconnectWithoutWaiting() { disconnect() }

    /// The helper was killed: the socket is dead under the app, which has not noticed. The next connect starts a
    /// fresh helper (answered with `answerAtOnce`), as launchd does for the installed daemon.
    func die() {
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

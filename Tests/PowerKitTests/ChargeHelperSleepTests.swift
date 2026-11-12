import XCTest
@testable import PowerKit

// The helper reconnects the charger before the Mac sleeps. Nothing in the helper
// runs while the Mac sleeps, so a cut left in place over sleep has nobody
// watching the floor: the battery drains on a plugged-in charger until the next
// wake. Whether `CHIE` survives sleep is unmeasured, and nothing here depends on
// it.
//
// Every test uses the fake. NOTHING here may build a `SystemChargeHardware`, and
// nothing here puts this Mac to sleep: the one test that touches the system only
// registers a `SystemSleepWatch` and deregisters it again.
//
// The class matches `--filter ChargeHelperSleepTests` and `--filter ChargeHelper`,
// but NOT `--filter ChargeHelperTests`: run the wider gate as `ChargeHelper`.

final class ChargeHelperSleepTests: XCTestCase {

    private func makeServer(_ charge: FakeChargeHardware,
                            fans: FakeFans = FakeFans([:]),
                            socketPath: String = NSTemporaryDirectory() + "bs-unused.sock",
                            log: @escaping (String) -> Void = { _ in }) -> FanHelperServer {
        let server = FanHelperServer(
            hardware: fans,
            configuration: .init(socketPath: socketPath,
                                 ownerUID: getuid(),
                                 pin: .signingIdentifier(FanDaemon.clientSigningIdentifier)),
            log: log,
            charge: charge)
        server.chargeTiming = .immediate
        return server
    }

    // ── The server, driven directly ─────────────────────────────────────────

    func testWillSleepReconnectsAnActiveDischarge() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        var lines: [String] = []
        let server = makeServer(hw, log: { lines.append($0) })
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)
        XCTAssertEqual(hw.isCut, true)

        server.systemWillSleep()
        XCTAssertEqual(hw.isCut, false, "the charger was left cut over sleep")
        XCTAssertEqual(hw.cutWrites, [true, false])
        XCTAssertNil(server.dischargeTarget)
        XCTAssertTrue(server.systemAsleep)
        XCTAssertTrue(server.isIdle)
        XCTAssertEqual(lines.last, "reconnected the charger before sleep", "\(lines)")
    }

    func testWillSleepWithNoDischargeWritesNothing() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        var lines: [String] = []
        let server = makeServer(hw, log: { lines.append($0) })

        server.systemWillSleep()
        XCTAssertTrue(hw.cutWrites.isEmpty, "a sleep with nothing cut wrote to the charger")
        XCTAssertTrue(server.systemAsleep)
        XCTAssertTrue(lines.isEmpty, "the default path must say nothing: \(lines)")
    }

    func testDischargeRefusedWhileAsleep() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw)
        server.systemWillSleep()

        let reply = server.handle(.command(.discharge(toPercent: 40)))
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.message, "the Mac is going to sleep")
        XCTAssertTrue(hw.cutWrites.isEmpty, "a refused discharge wrote to the charger")
        XCTAssertNil(server.dischargeTarget)
        XCTAssertTrue(server.isIdle)
    }

    func testDischargeAcceptedAgainAfterWake() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw)
        server.systemWillSleep()
        server.systemDidWake()
        XCTAssertFalse(server.systemAsleep)

        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)
        XCTAssertEqual(hw.cutWrites, [true])
        XCTAssertEqual(server.dischargeTarget, 40)
    }

    /// Wake does not resume a discharge: the app decides again.
    func testWakeDoesNotResumeTheDischarge() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw)
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)

        server.systemWillSleep()
        server.systemDidWake()
        XCTAssertEqual(hw.isCut, false)
        XCTAssertNil(server.dischargeTarget)

        // Nor does the watch, on its next pass.
        server.watchDischarge()
        XCTAssertEqual(hw.cutWrites, [true, false])
        XCTAssertTrue(server.isIdle)
    }

    func testLimitWriteStillWorksWhileAsleep() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw)
        server.systemWillSleep()

        XCTAssertTrue(server.handle(.command(.setChargeLimit(80))).ok)
        XCTAssertEqual(hw.limitWrites, [80])
        XCTAssertTrue(hw.cutWrites.isEmpty)
    }

    /// Fans are not the charger: sleep refuses nothing about them.
    func testAFanCommandStillWorksWhileAsleep() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let fans = FakeFans([0: .init(minRPM: 2317, maxRPM: 7826)])
        fans.seedTarget(0, 0)
        fans.seedMode(0, SMCFanMode.automatic)
        let server = makeServer(hw, fans: fans)
        server.systemWillSleep()

        XCTAssertTrue(server.handle(.command(.setTarget(FanTarget(index: 0, rpm: 5000)))).ok)
        XCTAssertEqual(fans.targetWrites.map(\.rpm), [5000])
        XCTAssertTrue(server.handle(.command(.releaseAll)).ok)
    }

    /// Asked to reconnect while asleep, it still reconnects — a reconnect is
    /// never refused.
    func testStopDischargeStillWorksWhileAsleep() {
        let hw = FakeChargeHardware(percent: 77, onAC: true, cut: true)
        let server = makeServer(hw)
        server.systemWillSleep()

        XCTAssertTrue(server.handle(.command(.stopDischarge)).ok)
        XCTAssertEqual(hw.isCut, false)
    }

    /// A reconnect that fails before sleep keeps the books the way every other
    /// failed reconnect does: still owed, the helper not idle, and retried by
    /// the watch after wake until it lands. It says so first.
    func testAFailedReconnectBeforeSleepIsOwedAndRetriedAfterWake() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        var lines: [String] = []
        let server = makeServer(hw, log: { lines.append($0) })
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)

        hw.refuseRestore = true
        server.systemWillSleep()
        XCTAssertEqual(hw.isCut, true)
        XCTAssertTrue(server.reconnectOwed)
        XCTAssertFalse(server.isIdle)
        XCTAssertTrue(server.systemAsleep)
        XCTAssertTrue(lines.last?.hasPrefix("WARNING") ?? false, "\(lines)")

        server.systemDidWake()
        hw.refuseRestore = false
        server.watchDischarge()
        XCTAssertEqual(hw.isCut, false)
        XCTAssertNil(server.dischargeTarget)
        XCTAssertTrue(server.isIdle)
    }

    /// The same when the key cannot be read before sleep: the held cut is
    /// written back anyway, not called "no adapter-cut key" — which used to log
    /// "reconnected the charger before sleep", clear the target and leave the
    /// charger cut over sleep with nothing owed. Owed, it is retried after wake.
    func testAnUnconfirmedReconnectBeforeSleepIsOwedAndRetriedAfterWake() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        var lines: [String] = []
        let server = makeServer(hw, log: { lines.append($0) })
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)

        hw.keyExists = false
        server.systemWillSleep()
        XCTAssertEqual(hw.cutWrites, [true, false, false, false], "nothing was written before sleep")
        XCTAssertEqual(hw.isCut, true)
        XCTAssertEqual(server.dischargeTarget, 40)
        XCTAssertTrue(server.reconnectOwed)
        XCTAssertFalse(server.isIdle)
        XCTAssertTrue(lines.last?.hasPrefix("WARNING") ?? false, "\(lines)")
        XCTAssertFalse(lines.contains("reconnected the charger before sleep"), "\(lines)")

        server.systemDidWake()
        hw.keyExists = true
        server.watchDischarge()
        XCTAssertEqual(hw.isCut, false)
        XCTAssertNil(server.dischargeTarget)
        XCTAssertTrue(server.isIdle)
    }

    /// A helper the system would not register for sleep notices has no way to
    /// reconnect the charger before the Mac sleeps, so it takes no discharge at
    /// all. Nothing is written. The limit, the fans and a reconnect still work.
    func testWithoutSleepNoticesADischargeIsRefusedAndNothingElseIs() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let fans = FakeFans([0: .init(minRPM: 2317, maxRPM: 7826)])
        fans.seedTarget(0, 0)
        fans.seedMode(0, SMCFanMode.automatic)
        let server = makeServer(hw, fans: fans)
        server.sleepNoticesUnavailable = true

        let reply = server.handle(.command(.discharge(toPercent: 40)))
        XCTAssertFalse(reply.ok, reply.message)
        XCTAssertEqual(reply.message, "this Mac cannot warn the helper before it sleeps")
        XCTAssertTrue(hw.cutWrites.isEmpty, "a refused discharge wrote to the charger")
        XCTAssertNil(server.dischargeTarget)
        XCTAssertTrue(server.isIdle)

        XCTAssertTrue(server.handle(.command(.setChargeLimit(80))).ok)
        XCTAssertEqual(hw.limitWrites, [80])
        XCTAssertTrue(server.handle(.command(.setTarget(FanTarget(index: 0, rpm: 5000)))).ok)
        XCTAssertEqual(fans.targetWrites.map(\.rpm), [5000])
        XCTAssertTrue(server.handle(.command(.releaseAll)).ok)

        // A reconnect is never refused.
        let cut = FakeChargeHardware(percent: 77, onAC: true, cut: true)
        let other = makeServer(cut)
        other.sleepNoticesUnavailable = true
        XCTAssertTrue(other.handle(.command(.stopDischarge)).ok)
        XCTAssertEqual(cut.isCut, false)
    }

    /// The default takes discharges: a server nobody told otherwise is not
    /// refusing them.
    func testSleepNoticesAreAssumedUnlessTheEntrySaysOtherwise() {
        XCTAssertFalse(makeServer(FakeChargeHardware()).sleepNoticesUnavailable)
    }

    /// A cut this helper owes a reconnect for — one nobody owned that would not
    /// clear at startup — is a cut all the same, and is tried again before sleep.
    func testWillSleepRetriesAnOwedReconnect() {
        let hw = FakeChargeHardware(cut: true)
        hw.refuseRestore = true
        let server = makeServer(hw)
        server.clearOrphanedAdapterCut()
        XCTAssertTrue(server.reconnectOwed)

        hw.refuseRestore = false
        server.systemWillSleep()
        XCTAssertEqual(hw.isCut, false)
        XCTAssertFalse(server.reconnectOwed)
    }

    // ── The handoff to the loop thread ──────────────────────────────────────

    /// The sleep notice goes to the loop thread the way a stop signal does, and
    /// is answered only once the loop has reconnected the charger. The reconnect
    /// is made to take a while — two refusals, a pause before each retry — so an
    /// answer sent before it finished would find the charger still cut.
    func testTheLoopReconnectsBeforeTheSleepNoticeIsAnswered() throws {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw, socketPath: tempSocket())
        server.chargeTiming = ChargeRelease.Timing(tries: 3, readsPerTry: 1, readPause: 0, retryPause: 0.1)
        try server.start()
        // Before the loop runs, so this thread and the loop never share the server.
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)
        let thread = Thread { server.run() }
        thread.start()
        defer { server.stop(); spin(until: { thread.isFinished }) }

        hw.restoreRefusalsLeft = 2
        let began = Date()
        XCTAssertTrue(server.noteSystemWillSleep(timeout: 2), "the loop never answered")
        XCTAssertEqual(hw.isCut, false, "the sleep notice was answered with the charger still cut")
        XCTAssertEqual(hw.cutWrites, [true, false, false, false])
        XCTAssertLessThan(Date().timeIntervalSince(began), 1.0)
    }

    /// On the loop: a reconnect before sleep that cannot be read back is retried
    /// by the FIRST pass after wake — the one the wake notice itself causes.
    /// The watch's own timer is set to a minute, so nothing else can be what
    /// reconnects it within the second this test waits.
    func testTheFirstPassAfterWakeRetriesAnUnconfirmedReconnect() throws {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw, socketPath: tempSocket())
        server.dischargeWatchInterval = 60
        try server.start()
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)
        let thread = Thread { server.run() }
        thread.start()
        defer { server.stop(); spin(until: { thread.isFinished }) }

        hw.keyExists = false
        XCTAssertTrue(server.noteSystemWillSleep(timeout: 2), "the loop never answered")
        // Let the loop finish that pass and settle into its minute-long wait.
        spin(until: { false }, timeout: 0.2, failOnTimeout: false)
        XCTAssertEqual(hw.isCut, true)
        XCTAssertGreaterThan(hw.cutWrites.count, 1, "nothing was written before sleep")

        hw.keyExists = true
        let began = Date()
        server.noteSystemDidWake()
        spin(until: { hw.isCut == false }, timeout: 2)
        XCTAssertEqual(hw.isCut, false, "the first pass after wake did not retry the reconnect")
        XCTAssertLessThan(Date().timeIntervalSince(began), 1.0)
    }

    /// End to end, over a real connection: a discharge, a sleep that reconnects
    /// it, a discharge refused while asleep, and accepted again after the wake.
    func testOverTheSocketASleepReconnectsAndRefusesUntilTheWake() throws {
        guard let mine = ownCDHash() else {
            throw XCTSkip("no code identity available in this test environment")
        }
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let path = tempSocket()
        let server = FanHelperServer(hardware: FakeFans([:]),
                                     configuration: .init(socketPath: path, ownerUID: getuid(),
                                                          pin: .exactBuild(cdhash: mine)),
                                     charge: hw)
        server.chargeTiming = .immediate
        let clock = ChargeTestClock()
        server.now = { clock.now }
        try server.start()
        let thread = Thread { server.run() }
        thread.start()
        let link = FanControlLink(socketPath: path)
        defer {
            link.disconnect()
            server.stop()
            spin(until: { thread.isFinished })
        }
        var status: FanControlLink.Status?
        link.connect { status = $0 }
        spin(until: { status != nil })

        XCTAssertEqual(send(link, .discharge(toPercent: 40)).ok, true)
        XCTAssertEqual(hw.isCut, true)

        XCTAssertTrue(server.noteSystemWillSleep())
        XCTAssertEqual(hw.isCut, false)

        let refused = send(link, .discharge(toPercent: 40))
        XCTAssertEqual(refused.ok, false)
        XCTAssertEqual(refused.message, "the Mac is going to sleep")
        XCTAssertEqual(hw.cutWrites, [true, false])

        server.noteSystemDidWake()
        // Past the spacing between cuts, which is not what this test is about.
        clock.advance(FanHelperServer.cutSpacing)
        XCTAssertEqual(send(link, .discharge(toPercent: 40)).ok, true)
        XCTAssertEqual(hw.isCut, true)
    }

    /// A loop that never gets to the notice cannot hold up sleep: the answer goes
    /// after the timeout whatever the loop is doing.
    func testAStuckLoopDoesNotHoldUpSleep() throws {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw, socketPath: tempSocket())
        try server.start()
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)

        // No `run()`: nothing will ever act on the notice.
        let began = Date()
        XCTAssertFalse(server.noteSystemWillSleep(timeout: 0.2))
        let waited = Date().timeIntervalSince(began)
        XCTAssertGreaterThanOrEqual(waited, 0.2)
        XCTAssertLessThan(waited, 1.0, "a stuck loop held up the answer")
        XCTAssertEqual(hw.isCut, false, "sleep was answered with the charger still cut")

        // The way out still reconnects.
        server.stop()
        server.run()
        XCTAssertEqual(hw.isCut, false)
    }

    /// THE LOOP IS STUCK — inside a limit write that does not return, as
    /// `CFPreferencesSynchronize` can — when the Mac says it will sleep. The
    /// answer still goes at the deadline, and the charger reads reconnected
    /// BEFORE it: the sleep watch writes the reconnect itself and reads it
    /// back, needing nothing from the loop. It used to let the Mac sleep with
    /// the charger cut.
    ///
    /// Once free, the loop settles its own books on its first pass, by its own
    /// read-back: by the time the client goes, nothing is held or owed, so the
    /// dead man's switch has nothing left to reconnect.
    func testAStuckLoopHasTheChargerReconnectedBeforeSleepIsAnswered() throws {
        guard let mine = ownCDHash() else {
            throw XCTSkip("no code identity available in this test environment")
        }
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let log = ChargeLogRecorder(hw)
        let path = tempSocket()
        let server = FanHelperServer(hardware: FakeFans([:]),
                                     configuration: .init(socketPath: path, ownerUID: getuid(),
                                                          pin: .exactBuild(cdhash: mine)),
                                     log: { log.record($0) },
                                     charge: hw)
        server.chargeTiming = .immediate
        // A minute, so only the notices and the client can move the loop.
        server.dischargeWatchInterval = 60
        try server.start()
        let thread = Thread { server.run() }
        thread.start()
        let gate = DispatchSemaphore(value: 0)
        let link = FanControlLink(socketPath: path)
        defer {
            hw.limitWriteGate = nil
            gate.signal()
            link.disconnect()
            server.stop()
            spin(until: { thread.isFinished })
        }
        var status: FanControlLink.Status?
        link.connect { status = $0 }
        spin(until: { status != nil })
        XCTAssertEqual(send(link, .discharge(toPercent: 40)).ok, true)
        XCTAssertEqual(hw.isCut, true)

        // Stick the loop.
        hw.limitWriteGate = gate
        var limitReply: FanReply?
        link.send(.setChargeLimit(80)) { limitReply = $0 }
        spin(until: { hw.limitWritesWaiting == 1 })

        let began = Date()
        let answered = server.noteSystemWillSleep(timeout: 0.3)
        let cutAtTheAnswer = hw.isCut
        XCTAssertFalse(answered, "a stuck loop answered")
        XCTAssertEqual(cutAtTheAnswer, false, "sleep was answered with the charger still cut")
        XCTAssertEqual(hw.cutWrites, [true, false])
        XCTAssertLessThan(Date().timeIntervalSince(began), 1.0)
        XCTAssertEqual(hw.limitWritesWaiting, 1, "the loop was not stuck after all")
        let warning = log.entries(after: "cut the charger").first { $0.line.hasPrefix("WARNING") }
        XCTAssertNotNil(warning, "\(log.lines)")
        XCTAssertEqual(warning?.cut, false, "logged before the reconnect")

        // The Mac wakes, and the loop comes free.
        server.noteSystemDidWake()
        hw.limitWriteGate = nil
        gate.signal()
        spin(until: { limitReply != nil })
        XCTAssertEqual(limitReply?.ok, true)
        // A request served after the notices, so the pass that acted on them
        // has finished before the client goes. One that leaves the charger's
        // books alone: a stop would settle them itself.
        XCTAssertEqual(send(link, .setChargeLimit(81)).ok, true)

        let writesBeforeTheDrop = hw.cutWrites.count
        link.disconnect()
        spin(until: { log.lines.contains { $0.hasPrefix("client gone") } })
        XCTAssertEqual(hw.cutWrites.count, writesBeforeTheDrop,
                       "the loop still thought it held a cut: \(log.lines)")
        XCTAssertFalse(log.lines.contains { $0.contains("(released)") }, "\(log.lines)")
        XCTAssertEqual(hw.isCut, false)
        XCTAssertEqual(Array(hw.cutWrites.dropFirst()).filter { $0 }, [], "something cut it again")
    }

    /// With no loop running at all, the sleep watch's own reconnect writes the
    /// charger and touches nothing of the server's: until the loop runs, its
    /// books still say discharging to 40%. Its first pass settles them with its
    /// own read-back, and an on-demand helper then has nothing to stay up for.
    func testTheSleepWatchsReconnectLeavesTheBooksToTheLoop() throws {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw, socketPath: tempSocket())
        server.dischargeWatchInterval = 60
        server.idleExit = 0.3
        try server.start()
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)

        XCTAssertFalse(server.noteSystemWillSleep(timeout: 0.05))
        XCTAssertEqual(hw.isCut, false, "sleep was answered with the charger still cut")
        XCTAssertEqual(hw.cutWrites, [true, false])
        XCTAssertEqual(server.dischargeTarget, 40, "the sleep watch changed the loop's books")
        XCTAssertFalse(server.reconnectOwed, "the sleep watch changed the loop's books")
        XCTAssertFalse(server.systemAsleep, "the sleep watch changed the loop's books")

        server.noteSystemDidWake()
        let thread = Thread { server.run() }
        thread.start()
        defer { server.stop(); spin(until: { thread.isFinished }) }
        spin(until: { thread.isFinished }, timeout: 3)
        XCTAssertTrue(thread.isFinished, "the loop never settled its books")
        XCTAssertNil(server.dischargeTarget)
        XCTAssertFalse(server.reconnectOwed)
        XCTAssertFalse(server.systemAsleep, "a sleep and a wake were acted on out of order")
        XCTAssertEqual(hw.isCut, false)
        XCTAssertEqual(Array(hw.cutWrites.dropFirst()).filter { $0 }, [], "something cut it again")
    }

    /// A cut the loop's books do not show — the stuck pass had not recorded it
    /// — and a reconnect from the sleep watch that does not take. The loop is
    /// told it owes the reconnect, so an on-demand helper stays up and keeps
    /// writing until a read shows connected, instead of idling out with the
    /// charger cut and nobody watching.
    func testAReconnectFromTheSleepWatchThatDidNotTakeIsOwedByTheLoop() throws {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw, socketPath: tempSocket())
        server.dischargeWatchInterval = 0.05
        server.idleExit = 0.3
        try server.start()
        XCTAssertTrue(hw.setAdapterCut(true))   // behind the books' back
        XCTAssertTrue(server.isIdle)

        hw.refuseRestore = true
        XCTAssertFalse(server.noteSystemWillSleep(timeout: 0.05))
        XCTAssertEqual(hw.cutWrites, [true, false, false, false], "the sleep watch wrote nothing")
        XCTAssertFalse(server.reconnectOwed, "the sleep watch changed the loop's books")

        server.noteSystemDidWake()
        let thread = Thread { server.run() }
        thread.start()
        defer { server.stop(); spin(until: { thread.isFinished }) }
        spin(until: { false }, timeout: 1.0, failOnTimeout: false)
        XCTAssertFalse(thread.isFinished, "an on-demand helper idled out with the charger cut")
        XCTAssertEqual(hw.isCut, true)
        XCTAssertGreaterThan(hw.cutWrites.count, 5, "the loop did not keep writing the reconnect")

        hw.refuseRestore = false
        spin(until: { thread.isFinished }, timeout: 3)
        XCTAssertTrue(thread.isFinished, "it never left once the charger read connected")
        XCTAssertEqual(hw.isCut, false)
        XCTAssertFalse(server.reconnectOwed)
    }

    /// The sleep watch writes through its OWN connection to the charger, never
    /// the loop's: a loop stuck in a call on its connection is not in the way,
    /// and no charger object is used from two threads. A helper with no charge
    /// control writes nothing from the sleep watch either.
    func testTheSleepWatchWritesThroughItsOwnConnection() throws {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let loopSide = ChargeLine(hw), watchSide = ChargeLine(hw)
        let server = FanHelperServer(hardware: FakeFans([:]),
                                     configuration: .init(socketPath: tempSocket(), ownerUID: getuid(),
                                                          pin: .signingIdentifier("x")),
                                     charge: loopSide, sleepCharge: watchSide)
        server.chargeTiming = .immediate
        try server.start()
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)

        XCTAssertFalse(server.noteSystemWillSleep(timeout: 0.05))
        XCTAssertEqual(loopSide.writes, [true], "the sleep watch used the loop's connection")
        XCTAssertEqual(watchSide.writes, [false])
        XCTAssertEqual(hw.isCut, false)
        server.stop()
        server.run()

        let spare = ChargeLine(FakeChargeHardware(percent: 77, cut: true))
        let bare = FanHelperServer(hardware: FakeFans([:]),
                                   configuration: .init(socketPath: tempSocket(), ownerUID: getuid(),
                                                        pin: .signingIdentifier("x")),
                                   sleepCharge: spare)
        try bare.start()
        XCTAssertFalse(bare.noteSystemWillSleep(timeout: 0.05))
        XCTAssertTrue(spare.writes.isEmpty, "a helper without charge control wrote the charger")
        bare.stop()
        bare.run()
    }

    /// On a Mac the SMC says has no adapter-cut key, the sleep watch's writes
    /// cannot land and owe nothing: an on-demand helper is not kept up for
    /// ever by a reconnect it can never read back.
    func testASleepWatchReconnectOnAMacWithNoKeyOwesNothing() throws {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        hw.keyExists = false
        let server = makeServer(hw, socketPath: tempSocket())
        server.dischargeWatchInterval = 0.05
        server.idleExit = 0.2
        try server.start()

        XCTAssertFalse(server.noteSystemWillSleep(timeout: 0.05))
        server.noteSystemDidWake()
        let thread = Thread { server.run() }
        thread.start()
        defer { server.stop(); spin(until: { thread.isFinished }) }
        spin(until: { thread.isFinished }, timeout: 2)
        XCTAssertTrue(thread.isFinished, "a reconnect that can never land kept the helper up")
        XCTAssertFalse(server.reconnectOwed)
    }

    /// The bound on a sleep answer must outlast one loop pass a slow client can
    /// hold up: a reply write that stalls for its whole deadline, then the
    /// reconnect's read-back (about 0.65 s). When it was equal to the reply
    /// deadline, that pass could overrun it and the Mac was let sleep with the
    /// charger still cut. It must also stay well inside the ~30 s macOS waits.
    func testTheSleepAnswerOutlastsAStalledReplyAndAReconnect() {
        let server = makeServer(FakeChargeHardware())
        XCTAssertGreaterThanOrEqual(FanHelperServer.sleepAnswerDeadline,
                                    server.replyWriteDeadline + 3)
        XCTAssertLessThan(FanHelperServer.sleepAnswerDeadline, 30)
    }

    /// A stop that lands while a sleep notice waits answers it on the way out,
    /// after the release has reconnected the charger — not two seconds later.
    func testStoppingAnswersAWaitingSleepNotice() throws {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw, socketPath: tempSocket())
        try server.start()
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)

        let answer = AnswerBox()
        let waiter = Thread {
            let ok = server.noteSystemWillSleep(timeout: 2)
            answer.set(ok: ok, cutAtAnswer: hw.isCut)
        }
        waiter.start()
        spin(until: { false }, timeout: 0.1, failOnTimeout: false)

        let began = Date()
        server.stop()
        server.run()
        spin(until: { answer.value != nil })
        XCTAssertLessThan(Date().timeIntervalSince(began), 1.0)
        XCTAssertEqual(answer.value?.ok, true)
        XCTAssertEqual(answer.value?.cutAtAnswer, false)
    }

    /// Notices the loop could not get to are acted on IN ORDER when it does: a
    /// sleep then a wake leaves the helper awake, not refusing discharges for
    /// the rest of its life.
    ///
    /// The sleep it was too late for was answered with the sleep watch's own
    /// reconnect; the loop then makes its own — for the held cut, and for the
    /// reconnect it was told it owes — and the way out has nothing left to do.
    func testNoticesAreActedOnInTheOrderTheyCame() throws {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw, socketPath: tempSocket())
        try server.start()
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)

        XCTAssertFalse(server.noteSystemWillSleep(timeout: 0.05))
        XCTAssertEqual(hw.cutWrites, [true, false], "the sleep watch did not reconnect")
        server.noteSystemDidWake()

        let thread = Thread { server.run() }
        thread.start()
        spin(until: { hw.cutWrites.count == 4 })
        spin(until: { false }, timeout: 0.1, failOnTimeout: false)
        server.stop()
        spin(until: { thread.isFinished })
        XCTAssertFalse(server.systemAsleep, "a sleep and a wake were acted on out of order")
        XCTAssertEqual(hw.cutWrites, [true, false, false, false])
        XCTAssertEqual(hw.isCut, false)
    }

    // ── The watch itself ────────────────────────────────────────────────────

    /// Registers with the system and deregisters. Puts nothing to sleep.
    func testSleepWatchCanBeMadeAndStopped() throws {
        guard let watch = SystemSleepWatch(willSleep: {}, didWake: {}) else {
            throw XCTSkip("IORegisterForSystemPower is not available in this test environment")
        }
        XCTAssertTrue(watch.isRegistered)
        watch.stop()
        XCTAssertFalse(watch.isRegistered)
        watch.stop()   // a second stop is harmless
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    private func tempSocket() -> String {
        NSTemporaryDirectory() + "bs-slp-\(UUID().uuidString.prefix(8)).sock"
    }

    private func ownCDHash() -> String? {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return nil }
        defer { close(pair[0]); close(pair[1]) }
        return FanPeer.of(socket: pair[0])?.cdhash
    }

    private func send(_ link: FanControlLink, _ command: FanCommand) -> FanReply {
        var result: FanReply?
        link.send(command) { result = $0 }
        spin(until: { result != nil })
        return result ?? FanReply(ok: false, message: "no reply")
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

    private final class AnswerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (ok: Bool, cutAtAnswer: Bool)?
        var value: (ok: Bool, cutAtAnswer: Bool)? { lock.lock(); defer { lock.unlock() }; return stored }
        func set(ok: Bool, cutAtAnswer: Bool) { lock.lock(); stored = (ok, cutAtAnswer); lock.unlock() }
    }
}

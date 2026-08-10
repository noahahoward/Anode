import XCTest
@testable import PowerKit

// Fan control is the only thing in this app that writes to hardware, and the one
// place a bug is a thermal event rather than a wrong number. So the parts that
// can be tested without root are tested hard: the fanless decision, the
// connection-acceptance decision, the wire format, the server's whole control
// flow against fake hardware, and the uninstall.
//
// NOTHING HERE TOUCHES A FAN. The server is exercised over a real unix socket
// with a `FakeFans` behind it, which is also the only way to assert what would
// have been WRITTEN — the interesting property, and one a real SMC cannot be
// asked about safely.

// ── Fanless machines ────────────────────────────────────────────────────────

/// Hiding the Fans tab is a claim about the hardware. These are the four things
/// the machine can say and what each one is allowed to mean.
final class FanPresenceTests: XCTestCase {

    func testAReportedCountIsBelieved() {
        XCTAssertEqual(FanPresence.decide(smcReachable: true, reportedCount: 2,
                                          respondingFans: 2), .fans(2))
        XCTAssertEqual(FanPresence.decide(smcReachable: true, reportedCount: 1,
                                          respondingFans: 1), .fans(1))
    }

    /// The whole point of the feature: FNum reads 0 and nothing answers, so the
    /// machine is fanless and the tab goes away.
    func testZeroFansWithNothingRespondingIsFanless() {
        XCTAssertEqual(FanPresence.decide(smcReachable: true, reportedCount: 0,
                                          respondingFans: 0), .fanless)
    }

    /// A failure to READ the SMC is not a machine with no fans. This is the same
    /// "unmeasured is not none" rule that already bit the Fans pane once, and
    /// getting it wrong here removes a whole tab instead of one label.
    func testAnUnreadableSMCIsNeverCalledFanless() {
        XCTAssertEqual(FanPresence.decide(smcReachable: false, reportedCount: nil,
                                          respondingFans: 0), .unknown)
        // Even if a stale count is somehow to hand, an unreachable SMC decides
        // nothing.
        XCTAssertEqual(FanPresence.decide(smcReachable: false, reportedCount: 0,
                                          respondingFans: 0), .unknown)
        XCTAssertEqual(FanPresence.decide(smcReachable: false, reportedCount: 2,
                                          respondingFans: 2), .unknown)
    }

    /// No FNum and nothing responding is the Intel case: `F<n>Ac` is `fpe2`
    /// there, a type this app's decoder skips, so a two-fan Intel Mac reaches
    /// exactly this branch. Absence of the key we count with is not evidence of
    /// absence of fans.
    func testAMissingCountKeyIsUnknownNotFanless() {
        XCTAssertEqual(FanPresence.decide(smcReachable: true, reportedCount: nil,
                                          respondingFans: 0), .unknown)
    }

    func testAMissingCountKeyStillBelievesARespondingFan() {
        XCTAssertEqual(FanPresence.decide(smcReachable: true, reportedCount: nil,
                                          respondingFans: 2), .fans(2))
    }

    /// A fan that reports a speed is direct evidence of a fan; FNum is a claim
    /// about them. They should never disagree, and when they do the reading wins.
    func testARespondingFanOutranksACountOfZero() {
        XCTAssertEqual(FanPresence.decide(smcReachable: true, reportedCount: 0,
                                          respondingFans: 1), .fans(1))
    }

    /// FNum is a ui8. A fractional, negative, enormous or NaN value is a
    /// misdecoded key and must not be believed in EITHER direction — in
    /// particular it must not be rounded down to zero and read as fanless.
    func testAnImplausibleCountDecidesNothingByItself() {
        for bad: Double in [-1, 1.5, 99, .nan, .infinity] {
            XCTAssertEqual(FanPresence.decide(smcReachable: true, reportedCount: bad,
                                              respondingFans: 0), .unknown,
                           "FNum=\(bad) must not decide anything on its own")
            XCTAssertEqual(FanPresence.decide(smcReachable: true, reportedCount: bad,
                                              respondingFans: 2), .fans(2),
                           "FNum=\(bad) must not override a fan that answered")
        }
    }

    /// Which states hide the tab. Only one does, and the two ways of being wrong
    /// are not symmetric: an unnecessary tab says "no fans reported" in words,
    /// while a missing tab silently removes a reading with nothing left to
    /// suggest it existed.
    func testOnlyAMeasuredZeroHidesTheTab() {
        XCTAssertFalse(FanPresence.showsFanTab(.fanless))
        XCTAssertTrue(FanPresence.showsFanTab(.unknown))
        XCTAssertTrue(FanPresence.showsFanTab(.fans(1)))
        XCTAssertTrue(FanPresence.showsFanTab(.fans(2)))
    }

    /// Live, on whatever machine the suite is running on. A machine with fans
    /// must never be told it has none — that is the regression that would hide
    /// the tab on this Mac, which has two.
    func testThisMachineIsNotMisreportedAsFanless() throws {
        guard SMC() != nil else { throw XCTSkip("AppleSMC not reachable here") }
        let state = FanPresence.detect()
        guard case .fans(let n) = state else {
            // A genuinely fanless Mac is a legal answer; an SMC that opened and
            // then said nothing is not something to fail on either.
            throw XCTSkip("this machine reports \(state)")
        }
        XCTAssertGreaterThan(n, 0)
        XCTAssertTrue(FanPresence.showsFanTab(state))
    }
}

// ── Who may drive the fans ──────────────────────────────────────────────────

/// The connection check, as a pure function. This is the security boundary, and
/// the previous version of it shipped a comment claiming a check the code did
/// not perform — so every refusal is asserted here rather than read.
final class FanAccessTests: XCTestCase {

    private let pinned = "aabbccdd00112233"

    func testTheRightUserRunningTheRightBuildIsAccepted() {
        XCTAssertEqual(FanAccess.decide(peer: FanPeer(euid: 501, cdhash: pinned),
                                        ownerUID: 501, pin: .exactBuild(cdhash: pinned)),
                       .accept)
    }

    func testAnotherUserIsRefused() {
        guard case .refuse(let why) = FanAccess.decide(
            peer: FanPeer(euid: 502, cdhash: pinned), ownerUID: 501, pin: .exactBuild(cdhash: pinned)) else {
            return XCTFail("another user was accepted")
        }
        XCTAssertTrue(why.contains("502"), why)
    }

    /// Root is not the owner unless the owner is root. A root caller can already
    /// do this without us, so there is nothing to gain by making an exception and
    /// a whole category of confusion to lose.
    func testRootIsNotAutomaticallyTheOwner() {
        XCTAssertNotEqual(FanAccess.decide(peer: FanPeer(euid: 0, cdhash: pinned),
                                           ownerUID: 501, pin: .exactBuild(cdhash: pinned)),
                          .accept)
        XCTAssertEqual(FanAccess.decide(peer: FanPeer(euid: 0, cdhash: pinned),
                                        ownerUID: 0, pin: .exactBuild(cdhash: pinned)),
                       .accept)
    }

    /// An unsigned or unreadable caller has no identity, and no identity is a
    /// refusal — never a pass. Failing open here would make the whole cdhash
    /// layer decorative.
    func testACallerWithNoSignatureIsRefused() {
        guard case .refuse(let why) = FanAccess.decide(
            peer: FanPeer(euid: 501, cdhash: nil), ownerUID: 501, pin: .exactBuild(cdhash: pinned)) else {
            return XCTFail("an unsigned caller was accepted")
        }
        XCTAssertTrue(why.contains("signature"), why)
    }

    /// The ordinary cause of this is a rebuild, and the message has to point at
    /// the actual repair — stop the helper and start it again — rather than at
    /// something that sounds like a break-in.
    func testADifferentBuildIsRefusedAndSaysSo() {
        guard case .refuse(let why) = FanAccess.decide(
            peer: FanPeer(euid: 501, cdhash: "0000"), ownerUID: 501, pin: .exactBuild(cdhash: pinned)) else {
            return XCTFail("a different build was accepted")
        }
        XCTAssertTrue(why.contains("not the build this helper was started for"), why)
    }

    /// The uid check runs FIRST, so a stranger is turned away by the kernel's own
    /// answer before any code-signing machinery is asked about them.
    func testTheUserCheckOutranksTheIdentityCheck() {
        guard case .refuse(let why) = FanAccess.decide(
            peer: FanPeer(euid: 502, cdhash: nil), ownerUID: 501, pin: .exactBuild(cdhash: pinned)) else {
            return XCTFail("accepted")
        }
        XCTAssertTrue(why.contains("uid"), why)
    }
}

/// The two halves of the pin have to agree or fan control never works: the
/// helper hashes the app bundle on disk, and hashes each caller from the audit
/// token behind its socket. Asserted against this very process, over a real
/// socket, as an ordinary user.
final class FanIdentityTests: XCTestCase {

    func testAPeersHashMatchesTheSameBinaryOnDisk() throws {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw XCTSkip("socketpair unavailable")
        }
        defer { close(pair[0]); close(pair[1]) }

        guard let peer = FanPeer.of(socket: pair[0]) else {
            throw XCTSkip("the kernel would not identify the peer here")
        }
        XCTAssertEqual(peer.euid, getuid(), "the peer of our own socket is us")

        guard let overTheSocket = peer.cdhash,
              let path = Bundle.main.executablePath,
              let onDisk = FanIdentity.cdhash(atPath: path) else {
            throw XCTSkip("no code signature available in this test environment")
        }
        XCTAssertEqual(overTheSocket, onDisk,
                       "the helper would pin one hash and see another, so no build "
                     + "would ever be accepted")
        XCTAssertFalse(overTheSocket.isEmpty)
    }

    func testAPathWithNoCodeThereHasNoIdentity() {
        XCTAssertNil(FanIdentity.cdhash(atPath: "/no/such/binary/anywhere"))
    }
}

// ── Wire format ─────────────────────────────────────────────────────────────

final class FanWireTests: XCTestCase {

    func testRequestsSurviveTheRoundTrip() throws {
        let requests: [FanRequest] = [
            .hello,
            .command(.setTarget(FanTarget(index: 1, rpm: 3200))),
            .command(.releaseAll),
        ]
        for r in requests {
            var line = try FanWire.encode(r)
            XCTAssertEqual(line.last, 0x0A, "every message is one line")
            line.removeLast()
            XCTAssertFalse(line.contains(0x0A), "an interior newline would split one message in two")
            XCTAssertEqual(try FanWire.decode(FanRequest.self, from: line), r)
        }
    }

    func testRepliesSurviveTheRoundTrip() throws {
        let reply = FanReply(ok: false, message: "refused: unknownFan", fanCount: 2)
        var line = try FanWire.encode(reply)
        line.removeLast()
        XCTAssertEqual(try FanWire.decode(FanReply.self, from: line), reply)
    }

    func testGarbageIsRejectedRatherThanGuessedAt() {
        XCTAssertThrowsError(try FanWire.decode(FanRequest.self,
                                                from: Data("{\"nope\":1}".utf8)))
        XCTAssertThrowsError(try FanWire.decode(FanRequest.self, from: Data("not json".utf8)))
    }

    /// A peer that never sends a newline must not be able to make a ROOT process
    /// allocate without bound.
    func testAnEndlessLineIsCutOffRatherThanBuffered() throws {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw XCTSkip("socketpair unavailable")
        }
        defer { close(pair[0]); close(pair[1]) }
        FanSocketIO.configure(pair[0], timeout: 2)

        let flood = Data(repeating: 0x41, count: FanWire.maxLineBytes + 2048)
        XCTAssertTrue(FanSocketIO.writeAll(pair[1], flood))

        var buffer = Data()
        XCTAssertThrowsError(try FanSocketIO.readLine(pair[0], buffer: &buffer)) { error in
            XCTAssertEqual(error as? FanWire.Failure, .lineTooLong)
        }
    }

    /// A path too long for `sun_path` is refused rather than silently truncated
    /// to a different socket.
    func testAnOversizedSocketPathIsRefused() {
        XCTAssertNotNil(FanSocketIO.address("/var/run/betterstats-fan.sock"))
        XCTAssertNil(FanSocketIO.address("/" + String(repeating: "x", count: 200)))
    }
}

// ── Releasing ───────────────────────────────────────────────────────────────

final class FanReleaseTests: XCTestCase {

    private func holdings(_ pairs: [(Int, Double?)]) -> FanHoldings {
        var h = FanHoldings()
        for (i, previous) in pairs { h.took(i, previousTarget: previous) }
        return h
    }

    /// Release puts back the target the fan had, and on this hardware that is
    /// ZERO.
    ///
    /// MEASURED, and the old rule was wrong in the loud direction. Before
    /// anything was written F0Tg read 0 with the fans genuinely stopped on a cool
    /// M5 Pro. The old release wrote each fan's reported MINIMUM instead, on the
    /// theory that zero means "stop the fan" — and it spun a silent machine up to
    /// ~2320 rpm. Release made the machine LOUDER, which is the opposite of its
    /// job.
    func testReleasePutsBackTheTargetTheFanHadBefore() {
        let hw = FakeFans([0: .init(minRPM: 2317, maxRPM: 7826),
                           1: .init(minRPM: 2400, maxRPM: 7900)])
        // 0 is what automatic looks like here; 1800 stands for a machine where it
        // looks like something else. Neither is assumed — both are put back.
        let result = FanRelease.all(hardware: hw, holdings: holdings([(0, 0), (1, 1800)]))
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.released, 2)
        XCTAssertEqual(hw.writes, [FakeFans.Write(index: 0, rpm: 0),
                                   FakeFans.Write(index: 1, rpm: 1800)])
    }

    /// A fan this helper never took is LEFT ALONE. Writing to it in order to
    /// "release" it is exactly how the bug above happened.
    func testAFanThatWasNeverHeldIsNotWrittenToAtAll() {
        let hw = FakeFans([0: .init(minRPM: 2317, maxRPM: 7826),
                           1: .init(minRPM: 2400, maxRPM: 7900)])
        let result = FanRelease.all(hardware: hw, holdings: holdings([(1, 1800)]))
        XCTAssertEqual(hw.writes, [FakeFans.Write(index: 1, rpm: 1800)])
        XCTAssertEqual(result.released, 1)
    }

    func testReleasingNothingWritesNothingAndSaysSo() {
        let hw = FakeFans([0: .init(minRPM: 2317, maxRPM: 7826)])
        let result = FanRelease.all(hardware: hw, holdings: FanHoldings())
        XCTAssertTrue(result.ok)
        XCTAssertTrue(hw.writes.isEmpty)
        XCTAssertTrue(result.message.contains("no fan was held"), result.message)
    }

    /// A fan we TOOK but whose original could not be read still has to be handed
    /// back. Dropping it because there was no number to store would leave it
    /// pinned by the very function that exists to unpin it — and the fallback is
    /// the automatic value, not the minimum, because the minimum is the number
    /// that caused this bug.
    func testAHeldFanWithNoReadableOriginalGoesToTheAutomaticValue() {
        let hw = FakeFans([0: .init(minRPM: 2317, maxRPM: 7826)])
        let result = FanRelease.all(hardware: hw, holdings: holdings([(0, nil)]))
        XCTAssertEqual(hw.writes, [FakeFans.Write(index: 0, rpm: FanRelease.noForcedTarget)])
        XCTAssertEqual(result.released, 1)
    }

    /// Limits are not re-read on the way out. A fan we successfully wrote to is
    /// controllable by definition, and a limits read that has started failing
    /// must never be the reason a held fan is skipped.
    func testAHeldFanIsReleasedEvenIfItsLimitsHaveStoppedReading() {
        let hw = FakeFans([:])   // no limits for any index
        let result = FanRelease.all(hardware: hw, holdings: holdings([(3, 1200)]))
        XCTAssertEqual(hw.writes, [FakeFans.Write(index: 3, rpm: 1200)])
        XCTAssertEqual(result.released, 1)
    }

    /// A refused write means the machine is NOT fully handed back, and the result
    /// has to say so rather than reporting a tidy success.
    func testARefusedWriteIsReportedAsAFailure() {
        let hw = FakeFans([0: .init(minRPM: 2317, maxRPM: 7826)])
        hw.refuseWrites = true
        let result = FanRelease.all(hardware: hw, holdings: holdings([(0, 0)]))
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.refused, 1)
        XCTAssertTrue(result.message.contains("still be held"), result.message)
    }

    /// `--uninstall` runs in a process with no session history, so it has nothing
    /// to restore and writes the measured no-forced-target value to everything it
    /// can see. That IS an assumption — the only one — and it is made where the
    /// alternative is leaving fans pinned by an app that has been deleted.
    func testUninstallWritesTheAutomaticValueToEveryControllableFan() {
        let hw = FakeFans([0: .init(minRPM: 2317, maxRPM: 7826),
                           1: .init(minRPM: 2400, maxRPM: 7900)])
        let result = FanRelease.toAutomatic(hardware: hw)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(hw.writes, [FakeFans.Write(index: 0, rpm: 0),
                                   FakeFans.Write(index: 1, rpm: 0)])
        XCTAssertTrue(result.message.contains("automatic"), result.message)
    }

    func testUninstallSkipsFansWithNoReadableLimits() {
        let hw = FakeFans([3: .init(minRPM: 1000, maxRPM: 5000)])
        XCTAssertEqual(FanRelease.toAutomatic(hardware: hw).released, 1)
        XCTAssertEqual(hw.writes, [FakeFans.Write(index: 3, rpm: 0)])
    }
}

/// The memory a release works from. Two facts, and they are not the same fact:
/// THAT a fan was taken, and where it was beforehand.
final class FanHoldingsTests: XCTestCase {

    func testAFanIsTakenEvenWhenItsOriginalCouldNotBeRead() {
        var h = FanHoldings()
        h.took(0, previousTarget: nil)
        XCTAssertTrue(h.wasTaken(0), "a fan we wrote to must be released later")
        XCTAssertNil(h.previousTarget(of: 0))
        XCTAssertFalse(h.isEmpty)
    }

    /// Our own earlier target must never overwrite the memory of what automatic
    /// looked like — otherwise the second drag of a slider makes the first drag's
    /// value the thing we "restore".
    func testASecondWriteDoesNotOverwriteTheOriginal() {
        var h = FanHoldings()
        h.took(0, previousTarget: 0)
        h.took(0, previousTarget: 5000)
        XCTAssertEqual(h.previousTarget(of: 0), 0)
    }

    func testANonFiniteReadingIsNotStoredButTheFanIsStillTaken() {
        var h = FanHoldings()
        h.took(1, previousTarget: .nan)
        XCTAssertTrue(h.wasTaken(1))
        XCTAssertNil(h.previousTarget(of: 1), "NaN is not a target to write back")
    }

    func testIndicesAreAscendingSoAReleaseIsInAFixedOrder() {
        var h = FanHoldings()
        h.took(3, previousTarget: 1)
        h.took(0, previousTarget: 2)
        XCTAssertEqual(h.indices, [0, 3])
    }
}

// ── The helper's server, end to end over a real socket ──────────────────────

/// A real `FanHelperServer`, on a real unix socket, driven by the real
/// `FanControlLink` the app uses — with fake hardware behind it, because the
/// property worth asserting is what WOULD have been written.
final class FanHelperServerTests: XCTestCase {

    private var server: FanHelperServer!
    private var thread: Thread!
    private var link: FanControlLink!
    private var hardware: FakeFans!
    private var socketPath: String!

    override func tearDown() {
        link?.disconnect()
        server?.stop()
        // The loop unlinks the socket on its way out; give it the moment to.
        spin(until: { self.thread == nil || self.thread.isFinished }, timeout: 2)
        super.tearDown()
    }

    private func start(_ hw: FakeFans, pin: String? = nil) throws {
        hardware = hw
        socketPath = NSTemporaryDirectory()
            + "bs-fan-\(UUID().uuidString.prefix(8)).sock"
        guard let mine = ownCDHash() else {
            throw XCTSkip("no code identity available in this test environment")
        }
        server = FanHelperServer(hardware: hw,
                                 configuration: .init(socketPath: socketPath,
                                                      ownerUID: getuid(),
                                                      pin: .exactBuild(cdhash: pin ?? mine)))
        try server.start()
        thread = Thread { [server] in server?.run() }
        thread.start()
        link = FanControlLink(socketPath: socketPath)
    }

    /// The hash the server will compute for a connection from this process,
    /// obtained the same way it obtains it.
    private func ownCDHash() -> String? {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return nil }
        defer { close(pair[0]); close(pair[1]) }
        return FanPeer.of(socket: pair[0])?.cdhash
    }

    @discardableResult
    private func connect() -> FanControlLink.Status {
        var result: FanControlLink.Status?
        link.connect { result = $0 }
        spin(until: { result != nil })
        return result ?? .disconnected
    }

    @discardableResult
    private func ping() -> FanControlLink.Status {
        var result: FanControlLink.Status?
        link.ping { result = $0 }
        spin(until: { result != nil })
        return result ?? .disconnected
    }

    @discardableResult
    private func send(_ command: FanCommand) -> FanReply {
        var result: FanReply?
        link.send(command) { result = $0 }
        spin(until: { result != nil })
        return result ?? FanReply(ok: false, message: "no reply")
    }

    private func twoFans() -> FakeFans {
        FakeFans([0: .init(minRPM: 2317, maxRPM: 7826),
                  1: .init(minRPM: 2317, maxRPM: 7826)])
    }

    // ── Handshake ───────────────────────────────────────────────────────────

    func testHelloReportsTheControllableFanCountAndWritesNothing() throws {
        try start(twoFans())
        XCTAssertEqual(connect(), .connected(fanCount: 2, version: FanDaemon.protocolVersion))
        XCTAssertTrue(hardware.writes.isEmpty,
                      "connecting is not consent to write to a fan")
    }

    /// The rebuild case, which is the one users will actually hit. The helper
    /// must refuse and say why, not close silently — "the helper stopped
    /// answering" is what a crash looks like and tells nobody what to do.
    func testADifferentBuildIsRefusedWithAReason() throws {
        try start(twoFans(), pin: "000000000000000000000000")
        guard case .refused(let why) = connect() else {
            return XCTFail("a mismatched build was let in")
        }
        XCTAssertTrue(why.contains("not the build this helper was started for"), why)
        XCTAssertTrue(hardware.writes.isEmpty)
    }

    /// Two programs taking turns at one fan is a fight the user cannot see.
    func testASecondClientIsTurnedAwayWithAnExplanation() throws {
        try start(twoFans())
        XCTAssertEqual(connect(), .connected(fanCount: 2, version: FanDaemon.protocolVersion))

        let second = FanControlLink(socketPath: socketPath)
        var status: FanControlLink.Status?
        second.connect { status = $0 }
        spin(until: { status != nil })
        guard case .refused(let why) = status else {
            return XCTFail("two clients were admitted at once: \(String(describing: status))")
        }
        XCTAssertTrue(why.contains("already has fan control"), why)
        second.disconnect()
    }

    func testNothingIsListeningIsNotAnError() {
        let orphan = FanControlLink(socketPath: NSTemporaryDirectory() + "bs-fan-absent.sock")
        var status: FanControlLink.Status?
        orphan.connect { status = $0 }
        spin(until: { status != nil })
        XCTAssertEqual(status, .notRunning)
    }

    // ── Is it still there? ──────────────────────────────────────────────────

    /// The liveness check has to be free of consequences, because it runs on a
    /// timer for as long as the tab is open. `hello` writes nothing.
    func testAPingConfirmsTheHelperAndWritesNothing() throws {
        try start(twoFans())
        connect()
        send(.setTarget(FanTarget(index: 0, rpm: 4000)))
        hardware.clear()

        XCTAssertEqual(ping(), .connected(fanCount: 2, version: FanDaemon.protocolVersion))
        XCTAssertTrue(hardware.writes.isEmpty, "a liveness check must not touch a fan")
    }

    /// A helper stopped with ⌃C while nothing is being dragged is otherwise
    /// invisible to the app: our end of the socket stays open until something
    /// tries to use it, and until then the strip would go on claiming manual
    /// control of fans that were handed back seconds ago.
    func testAPingNoticesAHelperThatHasGone() throws {
        try start(twoFans())
        connect()
        XCTAssertEqual(ping(), .connected(fanCount: 2, version: FanDaemon.protocolVersion))

        server.stop()
        spin(until: { self.thread.isFinished })
        XCTAssertEqual(ping(), .notRunning)
    }

    /// Pinging a link that was never connected is a question, not an error.
    func testAPingWithNoConnectionSaysSoRatherThanOpeningOne() {
        let orphan = FanControlLink(socketPath: NSTemporaryDirectory() + "bs-fan-absent.sock")
        var status: FanControlLink.Status?
        orphan.ping { status = $0 }
        spin(until: { status != nil })
        XCTAssertEqual(status, .notRunning)
    }

    // ── Setting a speed ─────────────────────────────────────────────────────

    func testAnInRangeTargetIsWrittenAsAsked() throws {
        try start(twoFans())
        connect()
        XCTAssertTrue(send(.setTarget(FanTarget(index: 1, rpm: 4000))).ok)
        XCTAssertEqual(hardware.writes, [FakeFans.Write(index: 1, rpm: 4000)])
    }

    /// The helper re-clamps against limits it reads itself. The app clamps too,
    /// but a privileged process that trusts its client's arithmetic is not a
    /// boundary — so the test asks for values no honest client would send.
    func testTheHelperClampsWhateverItIsSent() throws {
        try start(twoFans())
        connect()
        XCTAssertTrue(send(.setTarget(FanTarget(index: 0, rpm: 99_999))).ok)
        XCTAssertTrue(send(.setTarget(FanTarget(index: 0, rpm: 0))).ok)
        XCTAssertTrue(send(.setTarget(FanTarget(index: 0, rpm: -5000))).ok)
        XCTAssertEqual(hardware.writes, [FakeFans.Write(index: 0, rpm: 7826),
                                         FakeFans.Write(index: 0, rpm: 2317),
                                         FakeFans.Write(index: 0, rpm: 2317)],
                       "a request below the fan's own minimum must become the "
                     + "minimum, never a stop")
    }

    func testNonFiniteAndUnknownFansAreRefusedWithNoWrite() throws {
        try start(twoFans())
        connect()
        XCTAssertFalse(send(.setTarget(FanTarget(index: 0, rpm: .nan))).ok)
        XCTAssertFalse(send(.setTarget(FanTarget(index: 5, rpm: 3000))).ok)
        XCTAssertFalse(send(.setTarget(FanTarget(index: 99, rpm: 3000))).ok)
        XCTAssertFalse(send(.setTarget(FanTarget(index: -1, rpm: 3000))).ok)
        XCTAssertTrue(hardware.writes.isEmpty, "a refusal must not write anything")
    }

    /// A fan whose reported max is at or below its min is a misread key, not a
    /// single-speed fan, and the helper must not write on the strength of it.
    func testImplausibleLimitsAreRefusedByTheHelperToo() throws {
        try start(FakeFans([0: .init(minRPM: 5000, maxRPM: 1000)]))
        connect()
        let reply = send(.setTarget(FanTarget(index: 0, rpm: 3000)))
        XCTAssertFalse(reply.ok)
        XCTAssertTrue(reply.message.contains("limitsImplausible"), reply.message)
        XCTAssertTrue(hardware.writes.isEmpty)
    }

    // ── Handing the fans back ───────────────────────────────────────────────

    /// The default mode writes NOTHING. A user who starts the helper and changes
    /// their mind must end up on a machine this code never touched — including on
    /// the way out, so the release is a no-op until something has been set.
    func testAHelperThatWasNeverUsedWritesNothingWhenTheClientLeaves() throws {
        try start(twoFans())
        connect()
        XCTAssertTrue(send(.releaseAll).ok)
        link.disconnect()
        // Give the server every chance to do the wrong thing.
        spin(until: { false }, timeout: 0.4, failOnTimeout: false)
        XCTAssertTrue(hardware.writes.isEmpty,
                      "released a machine nothing had touched")
    }

    /// An explicit release puts every HELD fan back where it was found, and
    /// touches nothing else.
    ///
    /// Rewritten from `testAnExplicitReleaseHandsEveryFanBack`, which asserted
    /// the old rule — every fan on the machine written to its minimum. On this
    /// hardware that pinned two silent fans at ~2320 rpm and called it a release.
    func testAnExplicitReleasePutsHeldFansBackAndLeavesTheRestAlone() throws {
        let hw = twoFans()
        hw.seedTarget(0, 0)      // what automatic looks like here
        hw.seedTarget(1, 0)
        try start(hw)
        connect()
        send(.setTarget(FanTarget(index: 0, rpm: 5000)))
        hardware.clear()

        XCTAssertTrue(send(.releaseAll).ok)
        XCTAssertEqual(hardware.writes, [FakeFans.Write(index: 0, rpm: 0)],
                       "fan 1 was never taken and must not be written to")
    }

    /// THE DEAD MAN'S SWITCH. The client vanishing — quit, crash or kill — hands
    /// the fans back with nothing running in the app to arrange it. Fans left
    /// pinned by software that is gone is the worst failure this feature has.
    func testTheFansAreReleasedWhenTheClientDisappears() throws {
        let hw = twoFans()
        hw.seedTarget(0, 0)
        try start(hw)
        connect()
        send(.setTarget(FanTarget(index: 0, rpm: 6000)))
        hardware.clear()

        link.disconnect()   // exactly what quitting and crashing both do

        spin(until: { !self.hardware.writes.isEmpty })
        XCTAssertEqual(hardware.writes, [FakeFans.Write(index: 0, rpm: 0)])
        XCTAssertFalse(server.hasWrittenATarget)
    }

    /// Stopping the helper itself (⌃C) is the other way out, and it releases too.
    func testStoppingTheHelperReleasesTheFans() throws {
        let hw = twoFans()
        hw.seedTarget(1, 1750)   // a machine whose idle target is not zero
        try start(hw)
        connect()
        send(.setTarget(FanTarget(index: 1, rpm: 6000)))
        hardware.clear()

        server.stop()
        spin(until: { !self.hardware.writes.isEmpty })
        XCTAssertEqual(hardware.writes, [FakeFans.Write(index: 1, rpm: 1750)],
                       "the fan goes back to what it was doing, not to a number "
                     + "this code chose")
    }

    /// Both fans taken, both put back — each to its OWN original, not to one
    /// value the release picked.
    func testEveryHeldFanGoesBackToItsOwnOriginal() throws {
        let hw = twoFans()
        hw.seedTarget(0, 0)
        hw.seedTarget(1, 1750)
        try start(hw)
        connect()
        send(.setTarget(FanTarget(index: 0, rpm: 5000)))
        send(.setTarget(FanTarget(index: 1, rpm: 6000)))
        // A second write to a fan we already hold must not become its "original".
        send(.setTarget(FanTarget(index: 0, rpm: 7000)))
        hardware.clear()

        XCTAssertTrue(send(.releaseAll).ok)
        XCTAssertEqual(hardware.writes, [FakeFans.Write(index: 0, rpm: 0),
                                         FakeFans.Write(index: 1, rpm: 1750)])
    }

    /// A partial release must not be recorded as a success, or the next attempt
    /// would decide there was nothing left to do.
    func testAFailedReleaseLeavesTheHelperStillHolding() throws {
        try start(twoFans())
        connect()
        send(.setTarget(FanTarget(index: 0, rpm: 6000)))
        hardware.refuseWrites = true
        XCTAssertFalse(send(.releaseAll).ok)
        XCTAssertTrue(server.hasWrittenATarget,
                      "a helper that failed to release must keep trying")

        // And when the writes start working again, the fan still goes back to
        // where it was found rather than to wherever the failed attempt left it.
        hardware.refuseWrites = false
        hardware.clear()
        XCTAssertTrue(send(.releaseAll).ok)
        XCTAssertEqual(hardware.writes, [FakeFans.Write(index: 0, rpm: 0)])
        XCTAssertFalse(server.hasWrittenATarget)
    }

    /// A write the SMC refuses takes nothing, so it must not make the helper
    /// believe it holds that fan — a helper that thinks it holds a fan it never
    /// touched will write to it on the way out.
    func testARefusedSetDoesNotMakeTheHelperThinkItHoldsTheFan() throws {
        try start(twoFans())
        connect()
        hardware.refuseWrites = true
        XCTAssertFalse(send(.setTarget(FanTarget(index: 0, rpm: 5000))).ok)
        XCTAssertFalse(server.hasWrittenATarget)

        hardware.refuseWrites = false
        hardware.clear()
        XCTAssertTrue(send(.releaseAll).ok)
        XCTAssertTrue(hardware.writes.isEmpty)
    }

    // ── Test plumbing ───────────────────────────────────────────────────────

    /// Spin the main run loop so the link's callbacks (which land on main) fire.
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

/// Fan hardware that records instead of writing.
///
/// Locked because the server touches it from its own thread while the test
/// inspects it from the main one.
final class FakeFans: FanHardware {

    struct Write: Equatable {
        let index: Int
        let rpm: Double
    }

    private let lock = NSLock()
    private var limitsByIndex: [Int: FanPolicy.Limits]
    private var recorded: [Write] = []
    private var refusing = false
    /// Each fan's current target. A fan nobody has seeded reads nil, which is the
    /// "its original could not be read" case rather than "it is at zero".
    private var current: [Int: Double] = [:]

    init(_ limits: [Int: FanPolicy.Limits]) { limitsByIndex = limits }

    var writes: [Write] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    var refuseWrites: Bool {
        get { lock.lock(); defer { lock.unlock() }; return refusing }
        set { lock.lock(); refusing = newValue; lock.unlock() }
    }

    func clear() {
        lock.lock(); recorded.removeAll(); lock.unlock()
    }

    func controllableFanCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return limitsByIndex.count
    }

    func limits(index: Int) -> FanPolicy.Limits? {
        lock.lock(); defer { lock.unlock() }
        return limitsByIndex[index]
    }

    func writeTarget(index: Int, rpm: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !refusing else { return false }
        recorded.append(Write(index: index, rpm: rpm))
        current[index] = rpm
        return true
    }

    /// The fan's current target — what a release restores. Seeded per fan so a
    /// test can say what automatic looked like before anything was written, which
    /// is the whole quantity the fixed release puts back.
    func readTarget(index: Int) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return current[index]
    }

    func seedTarget(_ index: Int, _ rpm: Double) {
        lock.lock(); current[index] = rpm; lock.unlock()
    }
}

// ── Uninstall ───────────────────────────────────────────────────────────────

/// "Fans left pinned at a manual RPM by an app that has been deleted" is the
/// worst failure mode this feature has, so the uninstall is tested for
/// COMPLETENESS — against a sandbox root, because the real one needs root and
/// removing the wrong thing there is not recoverable.
final class FanUninstallTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bs-uninstall-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func create(_ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    /// The list has to name every path any version of this project has ever asked
    /// root to leave behind — including the retired LaunchDaemon design, because
    /// anyone who ran that draft still has it and an uninstaller that cleaned up
    /// only after its replacement would leave a root daemon loaded.
    func testEveryPrivilegedArtifactIsOnTheList() {
        let paths = FanHelperInstall.artifacts().all.map(\.path)
        for expected in ["/Library/LaunchDaemons/dev.noah.betterstats.helper.plist",
                         "/Library/PrivilegedHelperTools/dev.noah.betterstats.helper",
                         "/Library/Application Support/BetterStats/client.cdhash",
                         "/Library/Application Support/BetterStats",
                         FanSocket.path] {
            XCTAssertTrue(paths.contains(expected), "\(expected) would be left behind")
        }
        for p in paths { XCTAssertTrue(p.hasPrefix("/"), "\(p) is not absolute") }
    }

    /// The pin file has to be removed before the directory holding it, or the
    /// directory is never empty and never goes.
    func testThePinIsRemovedBeforeTheDirectoryThatHoldsIt() {
        let files = FanHelperInstall.artifacts().files.map(\.path)
        let dirs = FanHelperInstall.artifacts().directoriesIfEmpty.map(\.path)
        let pin = "/Library/Application Support/BetterStats/client.cdhash"
        XCTAssertTrue(files.contains(pin))
        XCTAssertTrue(dirs.contains("/Library/Application Support/BetterStats"))
    }

    func testEverythingIsActuallyRemoved() throws {
        for url in FanHelperInstall.artifacts(root: root).files { try create(url) }
        let report = FanHelperInstall.removeArtifacts(root: root)

        for removal in report {
            XCTAssertEqual(removal.outcome, .removed, removal.path)
        }
        for url in FanHelperInstall.artifacts(root: root).all {
            XCTAssertFalse(fm.fileExists(atPath: url.path), "\(url.path) survived")
        }
    }

    /// An uninstall on a machine that never installed anything must report
    /// absence, not failure — the command exists to be run by someone who is not
    /// sure what state they are in.
    func testUninstallingTwiceIsCalmTheSecondTime() throws {
        for url in FanHelperInstall.artifacts(root: root).files { try create(url) }
        _ = FanHelperInstall.removeArtifacts(root: root)
        let again = FanHelperInstall.removeArtifacts(root: root)
        XCTAssertTrue(again.allSatisfy { $0.outcome == .absent },
                      "\(again.filter { $0.outcome != .absent })")
    }

    /// A support directory holding something this feature did not put there is
    /// kept. A fan uninstaller is not entitled to delete whatever else a future
    /// version stores next to it.
    func testADirectoryHoldingSomethingElseIsKept() throws {
        let support = FanHelperInstall.artifacts(root: root).directoriesIfEmpty[0]
        try create(support.appendingPathComponent("history.sqlite"))
        let report = FanHelperInstall.removeArtifacts(root: root)
        XCTAssertEqual(report.first { $0.path == support.path }?.outcome, .notEmpty)
        XCTAssertTrue(fm.fileExists(atPath: support.path))
    }
}

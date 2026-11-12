import XCTest
@testable import AnodeApp
@testable import PowerKit

/// A helper that dies is noticed when it dies. `FanControlLink` read its socket only inside an exchange, so a closed
/// peer was invisible between exchanges: `HelperConnection.status` stayed connected, and a discharge's charger stayed
/// cut with nothing watching until the next 30 s tick found out (measured: 28 s). Now an open socket is watched, and
/// the end of the stream is reported at once (`onPeerClosed`).
///
/// Against `StallingHelper` on a temporary socket. Nothing here reaches the real helper socket.
final class FanLinkPeerClosedTests: XCTestCase {

    private var helper: StallingHelper!
    private var link: FanControlLink!
    private var reports = 0

    override func setUpWithError() throws {
        helper = try StallingHelper()
        link = FanControlLink(socketPath: helper.path, socketTimeout: 0.5)
        reports = 0
        link.onPeerClosed = { [weak self] in self?.reports += 1 }
    }

    override func tearDownWithError() throws {
        helper.stop()
        link.disconnect()
        link = nil
    }

    private func connect(file: StaticString = #filePath, line: UInt = #line) {
        let greeted = expectation(description: "greeted")
        link.connect { status in
            if case .connected = status {} else { XCTFail("not connected: \(status)", file: file, line: line) }
            greeted.fulfill()
        }
        wait(for: [greeted], timeout: 5)
    }

    private func spin(for seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    private func spin(until done: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private func send(_ c: FanCommand) -> FanReply? {
        var reply: FanReply?
        let answered = expectation(description: "answered")
        link.send(c) { reply = $0; answered.fulfill() }
        wait(for: [answered], timeout: 5)
        return reply
    }

    /// The helper going away between exchanges is reported within a fraction of a second, with nothing sent.
    func testThePeerClosingBetweenExchangesIsReportedAtOnce() {
        connect()
        let start = Date()
        helper.dropClients()
        spin(until: { reports > 0 })
        XCTAssertEqual(reports, 1, "a helper that closed its socket was not noticed")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "it was noticed, but not at once")
        spin(for: 0.2)
        XCTAssertEqual(reports, 1, "reported more than once")
    }

    /// Once reported, the socket is closed here: a command finds no helper, as it would have after a failed exchange.
    func testAfterTheReportACommandFindsNoHelper() {
        connect()
        helper.dropClients()
        spin(until: { reports > 0 })
        XCTAssertEqual(send(.stopDischarge)?.ok, false)
        XCTAssertEqual(send(.stopDischarge)?.message, HelperConnection.stoppedAnswering)
        XCTAssertEqual(reports, 1)
    }

    /// Every exchange makes the socket readable for a moment (the reply); that is not the helper leaving.
    func testNormalExchangesReportNothing() {
        connect()
        for p in 60..<70 { XCTAssertEqual(send(.setChargeLimit(p))?.ok, true) }
        let pinged = expectation(description: "pinged")
        link.ping { _ in pinged.fulfill() }
        wait(for: [pinged], timeout: 5)
        let waited = link.sendWaiting(.stopDischarge, timeout: 5)
        XCTAssertEqual(waited?.ok, true)
        spin(for: 0.3)
        XCTAssertEqual(reports, 0, "a helper that was answering was reported closed")
        XCTAssertEqual(send(.setChargeLimit(71))?.ok, true, "the link was closed by a false report")
    }

    /// A reply that arrives with nobody waiting for it is read and dropped; the next exchange gets its own answer,
    /// and the helper is not reported closed.
    func testALateReplyIsDroppedAndDoesNotAnswerTheNextRequest() throws {
        connect()
        helper.sendUnsolicited(try FanWire.encode(FanReply(ok: false, message: "a late answer to something else")))
        spin(for: 0.3)
        XCTAssertEqual(reports, 0, "bytes nobody asked for were taken for the helper leaving")
        let reply = send(.setChargeLimit(70))
        XCTAssertEqual(reply?.ok, true)
        XCTAssertEqual(reply?.message, "ok", "the next request was answered with the stale reply")
        XCTAssertEqual(reports, 0)
    }

    /// A close made here is not news to anyone: `disconnect`, `disconnectWithoutWaiting`, and a reopen over an old
    /// socket.
    func testADeliberateLocalCloseIsNotReported() {
        connect()
        link.disconnect()
        spin(for: 0.3)
        XCTAssertEqual(reports, 0, "disconnect was reported as the helper leaving")
        connect()
        link.disconnectWithoutWaiting()
        spin(for: 0.3)
        XCTAssertEqual(reports, 0, "disconnectWithoutWaiting was reported as the helper leaving")
        connect()
        connect()   // `connect` closes the open socket before opening another
        spin(for: 0.3)
        XCTAssertEqual(reports, 0, "a reopen was reported as the helper leaving")
        helper.dropClients()
        spin(until: { reports > 0 })
        XCTAssertEqual(reports, 1, "the new socket was not watched")
    }

    /// The helper sees a local close as soon as it is made, not when a dispatch source gets round to it: it takes
    /// that as the client leaving, and serves one client at a time.
    func testALocalCloseReachesTheHelperAtOnce() {
        connect()
        link.disconnect()
        // The helper serves one connection at a time and counts a closed one as gone: a new one is greeted at once.
        let start = Date()
        connect()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.4)
    }

    /// A new socket after a report is watched as well.
    func testAReopenedSocketIsWatchedToo() {
        connect()
        helper.dropClients()
        spin(until: { reports == 1 })
        XCTAssertEqual(reports, 1)
        connect()
        helper.dropClients()
        spin(until: { reports == 2 })
        XCTAssertEqual(reports, 2, "the second socket was not watched")
    }

    /// An exchange that fails because the helper went away during it is that exchange's own news (its caller is told
    /// "stopped answering"); the watcher says nothing as well.
    func testACloseDuringAnExchangeIsTheExchangesNewsNotAReport() {
        connect()
        helper.commandDelay = 0.3
        var reply: FanReply?
        let answered = expectation(description: "answered")
        link.send(.setChargeLimit(70)) { reply = $0; answered.fulfill() }
        spin(for: 0.05)
        helper.dropClients()
        wait(for: [answered], timeout: 5)
        XCTAssertEqual(reply?.message, HelperConnection.stoppedAnswering)
        spin(for: 0.3)
        XCTAssertEqual(reports, 0)
    }
}

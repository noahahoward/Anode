import XCTest
@testable import AnodeApp
@testable import PowerKit

/// `FanControlLink.drain` says whether everything handed to the link has LANDED, not only whether the link is done
/// with it. An exchange that ended with no answer (the socket's timeout ran out on a helper that is slow) is not
/// known to have landed: the helper may apply it a moment later, after a caller that trusted the drain has put
/// something else back. Charge Control's restore is that caller; it keeps its record when the drain says false.
///
/// Against `StallingHelper` on a temporary socket, with the link's timeout cut to a fraction of a second so a helper
/// that answers late does not take seconds to model. Nothing here reaches the real helper socket.
final class FanLinkDrainTests: XCTestCase {

    private var helper: StallingHelper!
    private var link: FanControlLink!

    override func setUpWithError() throws {
        helper = try StallingHelper()
        link = FanControlLink(socketPath: helper.path, socketTimeout: 0.2)
    }

    override func tearDownWithError() throws {
        helper.stop()
        _ = link.drain(timeout: 5)
        link = nil
    }

    private func connect() {
        let greeted = expectation(description: "greeted")
        link.connect { _ in greeted.fulfill() }
        wait(for: [greeted], timeout: 5)
    }

    private func spin(until done: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// The reviewer's sequence on the real link: a limit goes to a helper that takes longer than the link waits.
    /// The exchange ends with no answer, so the drain behind it must say false, and the helper does apply the limit
    /// afterwards: a drain that said true would have let the caller put the original back first.
    func testADrainBehindACommandTheHelperAnswersLateSaysItHasNotLanded() {
        connect()
        helper.commandDelay = 0.6
        link.send(.setChargeLimit(62)) { _ in }
        XCTAssertFalse(link.drain(timeout: 5), "a command nobody answered was taken for landed")
        XCTAssertFalse(helper.commands.contains(.setChargeLimit(62)), "it had not landed when the drain returned")
        spin(until: { helper.commands.contains(.setChargeLimit(62)) })
        XCTAssertTrue(helper.commands.contains(.setChargeLimit(62)), "the helper applies it after all")
    }

    /// The doubt lasts until the helper answers something: the socket the timeout closed is not a reason to trust
    /// anything, and an answer on a new one is.
    func testTheDoubtLastsUntilTheHelperAnswersAgain() {
        connect()
        helper.commandDelay = 0.6
        link.send(.setChargeLimit(62)) { _ in }
        XCTAssertFalse(link.drain(timeout: 5))
        XCTAssertFalse(link.drain(timeout: 5), "asked again, with nothing new, the doubt was forgotten")
        spin(until: { helper.commands.contains(.setChargeLimit(62)) })
        connect()   // the helper serves one connection at a time: this hello is answered after the old command
        XCTAssertTrue(link.drain(timeout: 5), "an answer from the helper did not end the doubt")
    }

    /// A helper that answers in time leaves nothing in doubt, however much goes through.
    func testADrainBehindAnsweredCommandsSaysYes() {
        connect()
        link.send(.setChargeLimit(70)) { _ in }
        link.send(.setChargeLimit(71)) { _ in }
        XCTAssertTrue(link.drain(timeout: 5))
        XCTAssertEqual(helper.commands, [.setChargeLimit(70), .setChargeLimit(71)])
    }

    /// A command refused is still an answer from a helper that handled it: nothing is left in doubt by it. (The
    /// StallingHelper never refuses, so this is the plain case of nothing sent at all.)
    func testADrainWithNothingSentSaysYes() {
        XCTAssertTrue(link.drain(timeout: 5))
        connect()
        XCTAssertTrue(link.drain(timeout: 5))
    }

    /// The wait itself is still bounded: a drain that cannot be served in time says false, as before.
    func testADrainGivesUpAfterItsTimeout() {
        connect()
        helper.commandDelay = 0.8
        link.send(.setChargeLimit(62)) { _ in }
        let start = Date()
        XCTAssertFalse(link.drain(timeout: 0.05))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
}

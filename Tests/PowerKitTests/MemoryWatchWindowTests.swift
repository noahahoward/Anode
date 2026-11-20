import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The diagnostic window, built but NEVER ordered on screen: no window server is asked to show it, and the quitter, the
/// scheduler and the app lookup are all fakes, so nothing is signalled, no modal appears and no real app is read.
final class MemoryWatchWindowTests: XCTestCase {

    override func setUp() { _ = NSApplication.shared }

    private final class FakeQuitter: MemoryWatchQuitting {
        var nextPlan = MemoryWatchFixtures.plan(wholeApp: true, pids: [200, 201, 202])
        var planRequests = 0
        var performed: [(plan: MemoryWatchQuitPlan, force: Bool)] = []
        var performLine = MemoryWatchQuitter.quitRequestedLine
        var stillRunningAnswer = true
        var stillRunningChecks = 0
        var nextPlanIsGone = false

        func plan(for finding: Finding, completion: @escaping (MemoryWatchQuitPlan) -> Void) {
            planRequests += 1
            completion(nextPlanIsGone ? MemoryWatchFixtures.plan(wholeApp: true, pids: [], gone: true) : nextPlan)
        }
        func perform(_ plan: MemoryWatchQuitPlan, force: Bool) -> String {
            performed.append((plan, force))
            return performLine
        }
        func isStillRunning(_ plan: MemoryWatchQuitPlan, completion: @escaping (Bool) -> Void) {
            stillRunningChecks += 1
            completion(stillRunningAnswer)
        }
    }

    private final class Log {
        var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
        var ignored: [String] = []
        var shown: [Finding] = []
    }

    private func make(_ finding: Finding = MemoryWatchFixtures.finding(), quitter: FakeQuitter = FakeQuitter(),
                      log: Log = Log()) -> MemoryWatchWindowController {
        MemoryWatchWindowController(
            finding: finding,
            ignoreApp: { log.ignored.append($0) },
            showInProcesses: { log.shown.append($0) },
            quitter: quitter,
            schedule: { delay, work in log.scheduled.append((delay, work)) },
            appIdentity: { _ in (icon: NSImage(size: NSSize(width: 1, height: 1)), bundleID: "com.example.safari") })
    }

    private func sample(_ n: Int) -> MemorySample {
        MemorySample(seconds: 1000 + Double(n), bytes: MemoryWatchFixtures.mib(1800) + UInt64(n))
    }

    // MARK: Nothing happens by itself

    func testCreatingTheControllerShowsNothingAndAsksForNothing() {
        let quitter = FakeQuitter()
        let log = Log()
        let c = make(quitter: quitter, log: log)
        XCTAssertEqual(c.window?.isVisible, false)
        XCTAssertFalse(c.isDrawable(), "a window that was never ordered front cannot be seen")
        XCTAssertEqual(quitter.planRequests, 0)
        XCTAssertTrue(quitter.performed.isEmpty)
        XCTAssertTrue(log.scheduled.isEmpty)
    }

    // MARK: Live points

    func testALivePointIsKeptButNotDrawnWhileTheWindowCannotBeSeen() {
        let c = make()
        for n in 1...5 { c.appendLive(sample(n)) }
        XCTAssertEqual(c.liveSamples.count, 5, "kept, so the graph is whole when it is looked at again")
        XCTAssertEqual(c.liveRedraws, 0, "nothing was drawn for a window nobody can see")
    }

    func testALivePointIsDrawnWhileTheWindowCanBeSeen() {
        let c = make()
        c.isDrawable = { true }
        c.appendLive(sample(1))
        c.appendLive(sample(2))
        XCTAssertEqual(c.liveRedraws, 2)
        c.isDrawable = { false }   // minimised, or covered by another window
        c.appendLive(sample(3))
        XCTAssertEqual(c.liveRedraws, 2)
        XCTAssertEqual(c.liveSamples.count, 3)
    }

    func testTheLiveBufferIsBounded() {
        let c = make()
        let limit = MemoryWatchWindowModel.maxLivePoints
        for n in 1...(limit + 88) { c.appendLive(sample(n)) }
        XCTAssertEqual(c.liveSamples.count, limit)
        XCTAssertEqual(c.liveSamples.first?.seconds, 1089, "the oldest were dropped")
        XCTAssertEqual(c.liveSamples.last?.seconds, 1000 + Double(limit + 88))
    }

    // MARK: Closing

    func testOnCloseFiresOnceFromWindowWillClose() {
        let c = make()
        var closed = 0
        c.onClose = { closed += 1 }
        c.appendLive(sample(1))
        c.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertEqual(closed, 1)
        XCTAssertTrue(c.isClosed)
        XCTAssertTrue(c.liveSamples.isEmpty, "references and buffers are let go")
        XCTAssertNil(c.plan)
        c.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertEqual(closed, 1, "a second close notice does not fire it again")
    }

    func testAClosedWindowTakesNoMorePoints() {
        let c = make()
        c.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        c.appendLive(sample(1))
        XCTAssertTrue(c.liveSamples.isEmpty)
        XCTAssertEqual(c.liveRedraws, 0)
    }

    func testCloseFromTheOutsideFiresOnCloseOnceAndNothingIfItWasCleared() {
        let c = make()
        var closed = 0
        c.onClose = { closed += 1 }
        c.close()
        c.close()
        XCTAssertEqual(closed, 1)

        let quiet = make()
        quiet.onClose = nil   // how the controller of the watch closes a window it no longer wants a call from
        quiet.close()
        XCTAssertTrue(quiet.isClosed)
    }

    // MARK: A low-memory warning

    func testTheWindowTitleFollowsTheKindOfFinding() {
        let c = make(MemoryWatchFixtures.pressureFinding())
        XCTAssertEqual(c.window?.title, "Memory Is Running Low")
        c.update(with: MemoryWatchFixtures.finding())
        XCTAssertEqual(c.window?.title, "Possible Memory Leak")
        c.update(with: MemoryWatchFixtures.pressureFinding())
        XCTAssertEqual(c.window?.title, "Memory Is Running Low")
        XCTAssertEqual(make().window?.title, "Possible Memory Leak", "a leak's window is as it was")
        c.close()
    }

    func testALowMemoryWindowOffersTheSameButtonsAndCaptions() {
        let quitter = FakeQuitter()
        let c = make(MemoryWatchFixtures.pressureFinding(), quitter: quitter)
        c.update(with: MemoryWatchFixtures.pressureFinding())
        XCTAssertEqual(c.buttonTitles.quit, "Quit App")
        XCTAssertEqual(c.buttonTitles.forceQuit, "Force Quit App")
        XCTAssertEqual(c.captions.quit, "Asks the whole app to quit: all 3 processes.")
        XCTAssertTrue(c.buttonsAreEnabled.quit)
        c.close()
    }

    // MARK: Plan, buttons, captions

    func testAnUpdateFetchesThePlanAndTheCaptionsAndButtonsFollowIt() {
        let quitter = FakeQuitter()
        let c = make(quitter: quitter)
        c.update(with: MemoryWatchFixtures.finding())
        XCTAssertEqual(quitter.planRequests, 1)
        XCTAssertEqual(c.buttonTitles.quit, "Quit App")
        XCTAssertEqual(c.buttonTitles.forceQuit, "Force Quit App")
        XCTAssertEqual(c.captions.quit, "Asks the whole app to quit: all 3 processes.")
        XCTAssertEqual(c.captions.forceQuit, "Kills the whole app: all 3 processes.")
        XCTAssertTrue(c.buttonsAreEnabled.quit)
        XCTAssertTrue(c.buttonsAreEnabled.forceQuit)
    }

    func testANonAppWindowSaysProcessAndOnlyThisOne() {
        let quitter = FakeQuitter()
        quitter.nextPlan = MemoryWatchFixtures.plan(wholeApp: false, pids: [100])
        let c = make(MemoryWatchFixtures.nodeFinding(), quitter: quitter)
        c.update(with: MemoryWatchFixtures.nodeFinding())
        XCTAssertEqual(c.buttonTitles.quit, "Quit Process")
        XCTAssertEqual(c.buttonTitles.forceQuit, "Force Quit Process")
        XCTAssertTrue(c.captions.quit.contains("only this one process (pid 100)"))
        XCTAssertTrue(c.captions.forceQuit.contains("only this one process (pid 100)"))
    }

    func testButtonsAreOffAndTheReasonShownWhenThereIsNothingToQuit() {
        let quitter = FakeQuitter()
        quitter.nextPlan = MemoryWatchFixtures.plan(wholeApp: true, pids: [], gone: true)
        let c = make(quitter: quitter)
        c.update(with: MemoryWatchFixtures.finding())
        XCTAssertFalse(c.buttonsAreEnabled.quit)
        XCTAssertFalse(c.buttonsAreEnabled.forceQuit)
        XCTAssertEqual(c.statusLine, "That process already exited")
    }

    func testTheButtonsWaitForThePlan() {
        let c = make()
        XCTAssertFalse(c.buttonsAreEnabled.quit)
        XCTAssertFalse(c.buttonsAreEnabled.forceQuit)
    }

    // MARK: Clicks

    func testQuitPerformsAfterResolvingAgainAndLooksTwiceAtMost() {
        let quitter = FakeQuitter()
        let log = Log()
        let c = make(quitter: quitter, log: log)
        c.update(with: MemoryWatchFixtures.finding())
        XCTAssertEqual(quitter.planRequests, 1)

        c.quitClicked()
        XCTAssertEqual(quitter.planRequests, 2, "the plan is worked out again at the click")
        XCTAssertEqual(quitter.performed.count, 1)
        XCTAssertEqual(quitter.performed.first?.force, false)
        XCTAssertEqual(c.statusLine, "Quit requested, waiting for it to close")
        XCTAssertEqual(log.scheduled.count, 1)
        XCTAssertEqual(log.scheduled.first?.delay ?? 0, 1.5, accuracy: 0.001, "an early first look")
        XCTAssertEqual(quitter.stillRunningChecks, 0, "nothing is checked until the scheduled call fires")

        // Still running at the first look: one more look, at the ten second mark, and nothing after it.
        log.scheduled[0].work()
        XCTAssertEqual(quitter.stillRunningChecks, 1)
        XCTAssertEqual(c.statusLine, "Quit requested, waiting for it to close")
        XCTAssertEqual(log.scheduled.count, 2)
        XCTAssertEqual(log.scheduled[1].delay, 8.5, accuracy: 0.001)

        log.scheduled[1].work()
        XCTAssertEqual(quitter.stillRunningChecks, 2)
        XCTAssertEqual(c.statusLine, "Still running; it may be asking to save. Use Force Quit if it is stuck.")
        XCTAssertEqual(log.scheduled.count, 2, "no third look is ever scheduled: nothing polls")
    }

    /// A plain tool exits the moment it is asked to; the window must say so at once, not ten seconds later.
    func testAProcessThatClosedAtOnceIsReportedAtTheFirstLook() {
        let quitter = FakeQuitter()
        quitter.stillRunningAnswer = false
        let log = Log()
        let c = make(quitter: quitter, log: log)
        c.update(with: MemoryWatchFixtures.finding())
        c.quitClicked()
        let before = quitter.planRequests
        log.scheduled[0].work()
        XCTAssertEqual(c.statusLine, "It has closed.")
        XCTAssertEqual(quitter.planRequests, before + 1, "the buttons are worked out again, and go off")
        XCTAssertEqual(log.scheduled.count, 1, "closed: no second look")
    }

    /// The reported case: Quit worked, the window had not said so yet, and the next click found the process gone. That is
    /// the quit working, so it says "It has closed." rather than "That process already exited".
    func testClickingAfterAQuitThatWorkedSaysItClosed() {
        let quitter = FakeQuitter()
        let log = Log()
        let c = make(quitter: quitter, log: log)
        c.update(with: MemoryWatchFixtures.finding())
        c.quitClicked()
        quitter.nextPlanIsGone = true
        c.forceQuitClicked()
        XCTAssertEqual(c.statusLine, "It has closed.")
        XCTAssertTrue(quitter.performed.count == 1, "nothing more was signalled")
    }

    func testTheCheckDoesNothingIfTheWindowWasClosedFirst() {
        let quitter = FakeQuitter()
        let log = Log()
        let c = make(quitter: quitter, log: log)
        c.update(with: MemoryWatchFixtures.finding())
        c.quitClicked()
        c.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        log.scheduled[0].work()
        XCTAssertEqual(quitter.stillRunningChecks, 0)
    }

    func testForceQuitPerformsAndSchedulesNoCheck() {
        let quitter = FakeQuitter()
        quitter.performLine = "Force quit 3 processes"
        let log = Log()
        let c = make(quitter: quitter, log: log)
        c.update(with: MemoryWatchFixtures.finding())
        c.forceQuitClicked()
        XCTAssertEqual(quitter.performed.count, 1)
        XCTAssertEqual(quitter.performed.first?.force, true)
        XCTAssertEqual(c.statusLine, "Force quit 3 processes")
        XCTAssertTrue(log.scheduled.isEmpty)
    }

    func testAClickOnAPlanThatCannotActPerformsNothing() {
        let quitter = FakeQuitter()
        quitter.nextPlan = MemoryWatchFixtures.plan(wholeApp: true, pids: [], gone: true)
        let log = Log()
        let c = make(quitter: quitter, log: log)
        c.quitClicked()
        c.forceQuitClicked()
        XCTAssertTrue(quitter.performed.isEmpty)
        XCTAssertEqual(c.statusLine, "That process already exited")
        XCTAssertTrue(log.scheduled.isEmpty)
    }

    // MARK: Links

    func testDontWarnPassesTheIdentityKeyOnceAndSaysSo() {
        let log = Log()
        let c = make(log: log)
        c.ignoreClicked()
        c.ignoreClicked()
        XCTAssertEqual(log.ignored, ["/Applications/Safari.app"])
        XCTAssertEqual(c.statusLine, "Anode won't warn about Safari again.")
    }

    func testShowInProcessesPassesTheFinding() {
        let log = Log()
        let finding = MemoryWatchFixtures.finding()
        let c = make(finding, log: log)
        c.showClicked()
        XCTAssertEqual(log.shown, [finding])
    }

    // MARK: Updates

    func testUpdatingToAnotherProcessStartsItsLiveLineAgain() {
        let c = make()
        c.appendLive(sample(1))
        c.update(with: MemoryWatchFixtures.finding())
        XCTAssertEqual(c.liveSamples.count, 1, "the same process keeps its live points")
        c.update(with: MemoryWatchFixtures.finding(pid: 4500, start: 888))
        XCTAssertTrue(c.liveSamples.isEmpty)
    }
}

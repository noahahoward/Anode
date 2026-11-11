import XCTest
import AppKit
@testable import AnodeApp

/// When the menu bar's layout is read again. Every notification centre here is a private one made for the test (nothing is
/// posted system-wide), and timers and the debounce are fakes the test runs by hand.
final class BarEventsTests: XCTestCase {

    private final class FakeTimer: BarEventTimer {
        let interval: TimeInterval
        let fire: () -> Void
        private(set) var invalidated = false
        init(interval: TimeInterval, fire: @escaping () -> Void) { self.interval = interval; self.fire = fire }
        func invalidate() { invalidated = true }
    }

    private let workspace = NotificationCenter()
    private let app = NotificationCenter()
    private let session = NotificationCenter()
    private var timers: [FakeTimer] = []
    private var deferred: [DispatchWorkItem] = []
    private var changes: [Bool] = []
    private var invalidations = 0

    private var live: [FakeTimer] { timers.filter { !$0.invalidated } }

    private func makeEvents() -> BarEvents {
        BarEvents(fallbackSeconds: 30, onChange: { [unowned self] in changes.append($0) }, onInvalidate: { [unowned self] in invalidations += 1 },
                  workspaceCenter: workspace, appCenter: app, sessionCenter: session,
                  makeTimer: { [unowned self] interval, fire in
                      let t = FakeTimer(interval: interval, fire: fire)
                      timers.append(t)
                      return t
                  },
                  after: { [unowned self] _, work in deferred.append(work) })
    }

    /// Runs the debounced work that is due (the fake has no clock: everything deferred is due).
    private func flush() {
        let due = deferred
        deferred = []
        for work in due where !work.isCancelled { work.perform() }
    }

    private func post(_ name: Notification.Name, to center: NotificationCenter) { center.post(name: name, object: nil) }

    private static let locked = Notification.Name("com.apple.screenIsLocked")
    private static let unlocked = Notification.Name("com.apple.screenIsUnlocked")

    // ── Events ──────────────────────────────────────────────────────────────

    func testNothingIsObservedOrTimedBeforeStart() {
        let events = makeEvents()
        post(NSWorkspace.didActivateApplicationNotification, to: workspace)
        post(NSWorkspace.screensDidWakeNotification, to: workspace)
        events.urgent = true
        flush()
        XCTAssertEqual(changes, [])
        XCTAssertEqual(invalidations, 0)
        XCTAssertTrue(timers.isEmpty)
    }

    /// An app with wide menus coming forward makes macOS drop status items on a notched Mac.
    func testAnAppComingForwardReadsTheBarAgain() {
        let events = makeEvents()
        events.start()
        post(NSWorkspace.didActivateApplicationNotification, to: workspace)
        XCTAssertEqual(changes, [], "debounced")
        flush()
        XCTAssertEqual(changes, [false])
        XCTAssertEqual(invalidations, 0)
    }

    /// Waking (the Mac, the screens, or the session being unlocked) is a display change: the covers come down at once and the
    /// bar is read again.
    func testWakingIsTreatedLikeADisplayChange() {
        let cases: [(Notification.Name, NotificationCenter)] = [(NSWorkspace.didWakeNotification, workspace),
                                                                (NSWorkspace.screensDidWakeNotification, workspace),
                                                                (Self.unlocked, session)]
        for (name, center) in cases {
            changes = []; invalidations = 0
            let events = makeEvents()
            events.start()
            post(name, to: center)
            XCTAssertEqual(invalidations, 1, name.rawValue)
            flush()
            XCTAssertEqual(changes, [true], name.rawValue)
            events.stop()
        }
    }

    func testTheTimerReadsTheBarAgain() {
        let events = makeEvents()
        events.start()
        XCTAssertEqual(live.map(\.interval), [30])
        live[0].fire()
        flush()
        XCTAssertEqual(changes, [false])
    }

    func testNothingHappensAfterStop() {
        let events = makeEvents()
        events.start()
        events.stop()
        XCTAssertTrue(live.isEmpty)
        post(NSWorkspace.didActivateApplicationNotification, to: workspace)
        post(NSWorkspace.screensDidWakeNotification, to: workspace)
        post(Self.unlocked, to: session)
        events.urgent = true
        flush()
        XCTAssertEqual(changes, [])
        XCTAssertEqual(invalidations, 0)
        XCTAssertTrue(live.isEmpty)
    }

    // ── Urgent: covers are on screen ────────────────────────────────────────

    func testUrgentReadsEveryThreeSecondsAndBackToTheFallback() {
        let events = makeEvents()
        events.start()
        events.urgent = true
        XCTAssertEqual(live.map(\.interval), [3])
        events.urgent = false
        XCTAssertEqual(live.map(\.interval), [30])
    }

    /// Set on every pass while covers are up; restarting the timer each time would put the next read off for ever.
    func testSettingUrgentAgainKeepsTheTimer() {
        let events = makeEvents()
        events.start()
        events.urgent = true
        let timer = live.first
        events.urgent = true
        XCTAssertTrue(live.first === timer)
        XCTAssertEqual(timers.count, 2)
    }

    func testUrgentWhileStoppedStartsNothingButCountsOnStart() {
        let events = makeEvents()
        events.urgent = true
        XCTAssertTrue(timers.isEmpty)
        events.start()
        XCTAssertEqual(live.map(\.interval), [3])
    }

    // ── Asleep or locked: nobody is looking ─────────────────────────────────

    func testNoTimerWhileTheScreensSleep() {
        let events = makeEvents()
        events.start()
        post(NSWorkspace.screensDidSleepNotification, to: workspace)
        XCTAssertTrue(live.isEmpty)
        events.urgent = true
        XCTAssertTrue(live.isEmpty, "urgent while asleep starts nothing")
        post(NSWorkspace.screensDidWakeNotification, to: workspace)
        XCTAssertEqual(live.map(\.interval), [3])
    }

    /// A missed screens-wake must not leave the timer off: the Mac waking means the screens are on.
    func testTheMacWakingAlsoRestartsTheTimer() {
        let events = makeEvents()
        events.start()
        post(NSWorkspace.screensDidSleepNotification, to: workspace)
        post(NSWorkspace.didWakeNotification, to: workspace)
        XCTAssertEqual(live.map(\.interval), [30])
    }

    func testNoTimerWhileTheSessionIsLocked() {
        let events = makeEvents()
        events.start()
        post(Self.locked, to: session)
        XCTAssertTrue(live.isEmpty)
        // The screens waking on the lock screen does not restart it; unlocking does.
        post(NSWorkspace.screensDidWakeNotification, to: workspace)
        XCTAssertTrue(live.isEmpty)
        post(Self.unlocked, to: session)
        XCTAssertEqual(live.map(\.interval), [30])
    }

    func testStopForgetsSleepAndLock() {
        let events = makeEvents()
        events.start()
        post(NSWorkspace.screensDidSleepNotification, to: workspace)
        post(Self.locked, to: session)
        events.stop()
        events.start()
        XCTAssertEqual(live.map(\.interval), [30])
    }
}

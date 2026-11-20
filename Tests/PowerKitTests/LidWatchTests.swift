import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// Always Stay Awake notices the lid through a notification, not a once-a-second timer: the only timer left is a slow
/// safety net, and nothing at all runs when the mode is not on.
final class LidWatchTests: XCTestCase {

    final class FakeLidNotifier: LidChangeNotifying {
        private(set) var isRunning = false
        private(set) var starts = 0
        private(set) var stops = 0
        private var handler: (() -> Void)?
        func start(onChange: @escaping () -> Void) {
            guard !isRunning else { return }
            isRunning = true; starts += 1; handler = onChange
        }
        func stop() {
            if isRunning { stops += 1 }
            isRunning = false; handler = nil
        }
        /// A lid change arriving; nothing happens when the watch is not running, as with the real one.
        func fire() { handler?() }
    }

    final class CountingLid: LidStateReader {
        var closed: Bool? = false
        private(set) var reads = 0
        func isClosed() -> Bool? { reads += 1; return closed }
    }

    private struct Rig {
        let controller: KeepAwakeController
        let notifier: FakeLidNotifier
        let lid: CountingLid
        let panel: LidDimmerTests.FakeBacklight
        let defaults: UserDefaults
        let suite: String
    }

    private func rig() throws -> Rig {
        let (defaults, suite) = try TestDefaults.make(owner: "LidWatch", test: name)
        let settings = Settings(defaults: defaults)
        settings.keepAwakeEnabled = true
        let core = KeepAwake(assertions: KeepAwakeTests.FakeAssertions(), lid: KeepAwakeTests.FakeLid(), defaults: defaults)
        let lid = CountingLid(), panel = LidDimmerTests.FakeBacklight()
        let dimmer = LidDimmer(lid: lid, backlight: panel, defaults: defaults, ownBrightness: OwnBrightness())
        let notifier = FakeLidNotifier()
        let c = KeepAwakeController(settings: settings, defaults: defaults, core: core, dimmer: dimmer, lidNotifier: notifier)
        c.log = { _ in }
        return Rig(controller: c, notifier: notifier, lid: lid, panel: panel, defaults: defaults, suite: suite)
    }

    private func startAlwaysAwake(_ r: Rig) {
        r.controller.cycle()   // Never Sleep
        r.controller.cycle()   // Always Stay Awake
    }

    func testALidChangeNotificationPollsTheDimmerOnceAndDimsAtOnce() throws {
        let r = try rig()
        defer { r.controller.core.stop(); TestDefaults.destroy(r.defaults, r.suite) }
        startAlwaysAwake(r)
        XCTAssertEqual(r.controller.core.session?.mode, .alwaysAwake)
        XCTAssertTrue(r.notifier.isRunning)
        XCTAssertEqual(r.lid.reads, 1, "one look when the watch starts")
        r.lid.closed = true
        r.notifier.fire()
        XCTAssertEqual(r.lid.reads, 2, "exactly one poll for one notification")
        XCTAssertTrue(r.controller.dimmer.isDimmed, "closing the lid dims at once, without waiting for a timer")
        XCTAssertEqual(r.panel.value, 0)
        r.lid.closed = false
        r.notifier.fire()
        XCTAssertEqual(r.lid.reads, 3)
        XCTAssertFalse(r.controller.dimmer.isDimmed, "opening the lid restores at once")
        XCTAssertEqual(r.panel.value, 0.6, accuracy: 0.001)
    }

    func testThereIsNoRepeatingTimerShorterThanTwentySecondsAndTheSafetyPollCoalesces() throws {
        let r = try rig()
        defer { r.controller.core.stop(); TestDefaults.destroy(r.defaults, r.suite) }
        startAlwaysAwake(r)
        let timer = try XCTUnwrap(r.controller.lidTimer, "the slow safety poll exists while Always Stay Awake runs")
        XCTAssertTrue(timer.isValid)
        XCTAssertGreaterThanOrEqual(timer.timeInterval, 20, "no 1 Hz timer any more")
        XCTAssertGreaterThanOrEqual(KeepAwakeController.lidSafetyPollInterval, 20)
        XCTAssertGreaterThan(timer.tolerance, 0, "the system may merge its wake-up with others")
    }

    func testStoppingTearsTheNotifierAndTheSafetyPollDown() throws {
        let r = try rig()
        defer { r.controller.core.stop(); TestDefaults.destroy(r.defaults, r.suite) }
        startAlwaysAwake(r)
        let timer = try XCTUnwrap(r.controller.lidTimer)
        r.controller.core.stop()
        XCTAssertFalse(r.notifier.isRunning)
        XCTAssertEqual(r.notifier.starts, 1)
        XCTAssertEqual(r.notifier.stops, 1)
        XCTAssertNil(r.controller.lidTimer)
        XCTAssertFalse(timer.isValid)
        let reads = r.lid.reads
        r.notifier.fire()
        XCTAssertEqual(r.lid.reads, reads, "a late notification after the stop does nothing")
    }

    func testNothingRunsWhenAlwaysStayAwakeIsNotOn() throws {
        let r = try rig()
        defer { r.controller.core.stop(); TestDefaults.destroy(r.defaults, r.suite) }
        XCTAssertFalse(r.notifier.isRunning)
        XCTAssertNil(r.controller.lidTimer)
        r.controller.cycle()   // Never Sleep: awake, but the lid is not watched
        XCTAssertEqual(r.controller.core.session?.mode, .neverSleep)
        XCTAssertEqual(r.notifier.starts, 0)
        XCTAssertNil(r.controller.lidTimer)
        XCTAssertEqual(r.lid.reads, 0)
    }

    func testTheRealNotifierStartsAndStopsCleanlyAndTheLidMessageIsTheHeadersValue() {
        let n = IOKitLidChangeNotifier()
        XCTAssertFalse(n.isRunning)
        n.stop()   // stopping what never started is harmless
        n.start {}
        n.start {}   // a second start does nothing
        n.stop()
        XCTAssertFalse(n.isRunning)
        // kIOPMMessageClamshellStateChange = iokit_family_msg(sub_iokit_powermanagement, 0x100) in IOKit/pwr_mgt/IOPM.h
        XCTAssertEqual(IOKitLidChangeNotifier.clamshellStateChange, 0xE000_0000 | (13 << 14) | 0x100)
    }

    // ── The dimmer's side: retries and the brightness it will restore ──────

    private var suite: String!
    private var defaults: UserDefaults!
    private let lid = LidDimmerTests.FakeLidState()
    private let panel = LidDimmerTests.FakeBacklight()

    private func dimmer(now: @escaping () -> Date = Date.init) throws -> LidDimmer {
        (defaults, suite) = try TestDefaults.make(owner: "LidWatchDimmer", test: name)
        return LidDimmer(lid: lid, backlight: panel, defaults: defaults, ownBrightness: OwnBrightness(), now: now)
    }

    func testARefusedDimAsksForAShortRetryUntilTheAttemptsRunOut() throws {
        let d = try dimmer()
        defer { TestDefaults.destroy(defaults, suite) }
        d.poll(); lid.closed = true; panel.refuse = true
        for _ in 1..<LidDimmer.maxDimAttempts { d.poll(); XCTAssertTrue(d.wantsRetry) }
        d.poll()
        XCTAssertFalse(d.wantsRetry, "after the last attempt there is nothing left to retry")
        panel.refuse = false; lid.closed = false; d.poll()
        XCTAssertFalse(d.wantsRetry)
    }

    func testAFailedRestoreAsksForARetryUntilItWorks() throws {
        let d = try dimmer()
        defer { TestDefaults.destroy(defaults, suite) }
        d.poll(); lid.closed = true; d.poll()
        XCTAssertFalse(d.wantsRetry, "a dim that worked needs no retry")
        lid.closed = false; panel.refuse = true; d.poll()
        XCTAssertTrue(d.wantsRetry)
        panel.refuse = false; d.poll()
        XCTAssertFalse(d.wantsRetry)
        XCTAssertEqual(panel.value, 0.6, accuracy: 0.001)
    }

    func testTheBrightnessToRestoreIsReadAgainWhenTheLastReadIsOldEvenWithFewPolls() throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let d = try dimmer(now: { clock })
        defer { TestDefaults.destroy(defaults, suite) }
        d.poll()                                   // reads 0.6
        panel.value = 0.35                         // changed in System Settings
        clock.addTimeInterval(LidDimmer.refreshSeconds + 1)
        d.poll()                                   // a slow safety poll: far fewer than refreshEvery polls, but the read is old
        lid.closed = true; d.poll()
        XCTAssertEqual(d.saved ?? -1, 0.35, accuracy: 0.001)
        lid.closed = false; d.poll()
        XCTAssertEqual(panel.value, 0.35, accuracy: 0.001)
    }
}

/// Every repeating timer in the files the wake-up pass touched sets a tolerance, so the system can merge its wake-ups.
final class TimerToleranceSourceTests: XCTestCase {

    private static let files = [
        "KeepAwakeController", "BatteryMenuController", "SoundMenuController", "DockPreviews", "AppAudioRouter",
        "WindowSwitcher", "DesktopSwitcher", "MenuBarHiderRuntime", "KeyboardCleaner", "FanControlPanel", "HardDrain",
    ]

    /// Not idle timers: the 30 ms pointer tracking while the Dock preview panel is on screen is animation-like.
    private static let exempt = ["trackInterval"]

    func testEveryRepeatingTimerHereSetsAToleranceWithinTheNextFewLines() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var found = 0
        for name in Self.files {
            let text = try String(contentsOf: root.appendingPathComponent("Sources/AnodeApp/\(name).swift"), encoding: .utf8)
            let lines = text.components(separatedBy: "\n")
            for (i, line) in lines.enumerated()
            where line.contains("Timer(timeInterval:") || line.contains("scheduledTimer(withTimeInterval:") {
                let call = lines[i..<min(i + 3, lines.count)].joined(separator: "\n")
                guard call.contains("repeats: true"), !Self.exempt.contains(where: { call.contains($0) }) else { continue }
                found += 1
                let after = lines[i..<min(i + 12, lines.count)].joined(separator: "\n")
                XCTAssertTrue(after.contains("tolerance") || after.contains(".coalescing("),
                              "\(name).swift line \(i + 1): a repeating timer with no tolerance")
            }
        }
        XCTAssertGreaterThanOrEqual(found, 10, "the scan found the timers it is meant to check")
    }

    func testTheLidWatchHasNoOneSecondTimerLeft() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/AnodeApp/KeepAwakeController.swift"), encoding: .utf8)
        XCTAssertFalse(text.contains("Timer(timeInterval: 1, repeats: true)"))
    }
}

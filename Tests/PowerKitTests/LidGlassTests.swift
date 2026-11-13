import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The Lid Glass controller, driven by a fake lid, a fake picture and a fake overlay, so every sequence of
/// angles can be played without a lid, a permission or a window.
final class LidGlassTests: XCTestCase {

    // ── Fakes ──

    private final class FakeSensor: LidAngleSource {
        var isAvailable = true
        var startedHz: [Double] = [], rates: [Double] = []
        var stops = 0
        var onLost: (() -> Void)?
        func start(hz: Double, onSample: @escaping (Double, TimeInterval) -> Void, onLost: @escaping () -> Void) {
            startedHz.append(hz); self.onLost = onLost
        }
        func setRate(hz: Double) { rates.append(hz) }
        func stop() { stops += 1 }
        var lastRate: Double? { rates.last ?? startedHz.last }
    }

    private final class FakeOverlay: LidGlassOverlaying {
        var windowID: CGWindowID = 7
        var calls: [String] = []
        var shows: [(start: Double, from: Double, to: Double)] = []
        var angles: [Double] = [], clearDurations: [TimeInterval] = []
        var finishClearAtOnce = true
        var prepares = 0
        func prepare(image: CGImage) { prepares += 1 }
        func present(startAngle: Double, from: Double, to: Double) {
            calls.append("show"); shows.append((startAngle, from, to))
        }
        func setAngle(_ angle: Double) { angles.append(angle) }
        func animateClear(duration: TimeInterval, completion: @escaping () -> Void) {
            calls.append("clear"); clearDurations.append(duration)
            if finishClearAtOnce { completion() }
        }
        func hide() { calls.append("hide") }
    }

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var settings: Settings!
    private let sensor = FakeSensor()
    private var overlays: [FakeOverlay] = []
    private var picture: CGImage? = LidGlassTests.onePixel
    private var captures = 0
    private var pendingCapture: CheckedContinuation<CGImage?, Never>?
    private var holdCaptures = false
    private var external = false
    /// Is Ultra Low Power Mode on, as the glass is told.
    private var ultra = false
    private var finishClearsAtOnce = true

    private static let onePixel: CGImage = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!

    override func setUpWithError() throws {
        (defaults, suiteName) = try TestDefaults.make(owner: "LidGlass", test: name)
        settings = Settings(defaults: defaults)
    }

    override func tearDownWithError() throws {
        TestDefaults.destroy(defaults, suiteName)
    }

    private func makeGlass(enabled: Bool = true) -> LidGlass {
        settings.lidGlassEnabled = enabled
        return LidGlass(
            settings: settings, sensor: sensor,
            makeOverlay: { [unowned self] in
                let o = FakeOverlay(); o.finishClearAtOnce = finishClearsAtOnce; overlays.append(o); return o },
            capture: { [unowned self] in
                captures += 1
                if holdCaptures { return await withCheckedContinuation { pendingCapture = $0 } }
                return picture
            },
            externalDisplayPresent: { [unowned self] in external },
            ultraOn: { [unowned self] in ultra },
            log: { _ in })
    }

    private func waitUntil(_ done: @autoclosure () -> Bool, timeout: TimeInterval = 2) {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    /// A fast close from 125° that crosses the 110° trigger at t = 0.35.
    private func closeFast(_ g: LidGlass) {
        g.handle(angle: 125, time: 0); g.handle(angle: 120, time: 0.1); g.handle(angle: 100, time: 0.35)
    }

    // ── Switching on and off ──

    func testOffStartsNothingAndOnStartsTheSensorAtTheIdleRate() {
        let g = makeGlass(enabled: false)
        XCTAssertEqual(g.status, .off)
        XCTAssertTrue(sensor.startedHz.isEmpty)
        XCTAssertTrue(overlays.isEmpty)
        settings.lidGlassEnabled = true
        XCTAssertEqual(g.status, .idle)
        XCTAssertEqual(sensor.startedHz, [8])
        settings.lidGlassEnabled = false
        XCTAssertEqual(g.status, .off)
        XCTAssertEqual(sensor.stops, 1)
    }

    // ── While Ultra Low Power Mode is on ──

    /// The mode ends or begins: the controller says so, and the glass reads again.
    private func ultraChanged(to on: Bool) {
        ultra = on
        NotificationCenter.default.post(name: UltraLowPowerController.didChange, object: nil)
    }

    func testTheSensorIsStoppedWhileTheModeIsOnAndStartedAgainWhenItEnds() {
        let g = makeGlass()
        XCTAssertEqual(g.status, .idle)
        XCTAssertEqual(sensor.startedHz, [8])
        ultraChanged(to: true)
        XCTAssertEqual(g.status, .pausedForUltra)
        XCTAssertEqual(sensor.stops, 1, "the lid-angle sensor is stopped: it is not read for as long as the mode lasts")
        ultraChanged(to: true)
        XCTAssertEqual(sensor.stops, 1, "and not stopped again by every change the controller announces")
        ultraChanged(to: false)
        XCTAssertEqual(g.status, .idle)
        XCTAssertEqual(sensor.startedHz, [8, 8], "started again, at the rate the setting says")
    }

    func testAnEffectUnderWayWhenTheModeBeginsIsTakenAway() {
        let g = makeGlass()
        closeFast(g)
        waitUntil(g.status == .active && overlays.first?.calls.isEmpty == false)
        ultraChanged(to: true)
        XCTAssertEqual(g.status, .pausedForUltra)
        XCTAssertEqual(overlays.first?.calls.last, "hide")
    }

    func testTheGlassTurnedOffDuringTheModeStaysOffAtTheEnd() {
        let g = makeGlass()
        ultraChanged(to: true)
        settings.lidGlassEnabled = false
        XCTAssertEqual(g.status, .off)
        XCTAssertEqual(sensor.stops, 1, "already stopped: not stopped a second time")
        ultraChanged(to: false)
        XCTAssertEqual(g.status, .off)
        XCTAssertEqual(sensor.startedHz, [8])
    }

    func testTheGlassTurnedOnDuringTheModeStartsAtTheEndAndNotBefore() {
        let g = makeGlass(enabled: false)
        ultraChanged(to: true)
        settings.lidGlassEnabled = true
        XCTAssertEqual(g.status, .pausedForUltra)
        XCTAssertTrue(sensor.startedHz.isEmpty, "nothing is read while the mode lasts")
        ultraChanged(to: false)
        XCTAssertEqual(g.status, .idle)
        XCTAssertEqual(sensor.startedHz, [8])
    }

    func testAnUntickedGlassIsNotStartedWhenTheModeEnds() {
        let g = makeGlass(enabled: false)
        ultraChanged(to: true)
        ultraChanged(to: false)
        XCTAssertEqual(g.status, .off)
        XCTAssertTrue(sensor.startedHz.isEmpty)
    }

    func testAGlassMadeWhileTheModeIsOnStartsNothing() {
        ultra = true
        let g = makeGlass()
        XCTAssertEqual(g.status, .pausedForUltra)
        XCTAssertTrue(sensor.startedHz.isEmpty)
        ultraChanged(to: false)
        XCTAssertEqual(g.status, .idle)
    }

    func testASettingChangedDuringTheModeStartsNothing() {
        let g = makeGlass()
        ultraChanged(to: true)
        settings.lidGlassIdleHz = 20
        settings.lidGlassTriggerAngle = 100
        XCTAssertEqual(g.status, .pausedForUltra)
        XCTAssertEqual(sensor.startedHz, [8])
        XCTAssertEqual(sensor.stops, 1)
    }

    func testChangingTheIdleRateWhileIdleRetunesTheSensor() {
        let g = makeGlass()
        settings.lidGlassIdleHz = 20
        XCTAssertEqual(sensor.lastRate, 20)
        _ = g
    }

    // ── Polling rate ──

    /// The sensor only changes about ten times a second, so reading it more slowly than that near a close means
    /// the effect starts late (at 4 Hz, up to a quarter of a second after the lid began to move).
    func testWhileTheLidIsNearClosingTheRateIsNeverBelowTheSensorsOwn() {
        settings.lidGlassIdleHz = 4
        let g = makeGlass()
        XCTAssertEqual(sensor.startedHz, [4], "before the first reading it is what was asked for")
        g.handle(angle: 100, time: 0)
        XCTAssertEqual(sensor.lastRate, 10)
        g.handle(angle: 170, time: 1)
        XCTAssertEqual(sensor.lastRate, 4, "wide open, a close is not about to start: the slider's rate")
        g.handle(angle: 135, time: 60)                 // eased down slowly, not a close
        XCTAssertEqual(sensor.lastRate, 10)
    }

    func testAFasterSliderIsNeverSlowedDown() {
        settings.lidGlassIdleHz = 25
        let g = makeGlass()
        g.handle(angle: 100, time: 0)
        XCTAssertEqual(sensor.lastRate, 25)
    }

    func testTheRateIsNotRewrittenOnEverySample() {
        settings.lidGlassIdleHz = 4
        let g = makeGlass()
        for i in 0..<50 { g.handle(angle: 100, time: Double(i) * 0.1) }
        XCTAssertEqual(sensor.rates.count, 1, "one change to 10 Hz, not fifty")
    }

    // ── Closing ──

    func testClosingShowsTheOverlayThenFrostsWithTheAngleAndSpeedsUpPolling() {
        let g = makeGlass()
        closeFast(g)
        XCTAssertEqual(g.status, .active)
        XCTAssertEqual(sensor.lastRate, 120)
        waitUntil(!overlays.isEmpty && overlays[0].calls == ["show"])
        XCTAssertEqual(overlays[0].calls, ["show"])
        // Detected at 100° while closing at about 52°/s. The picture takes about a tenth of a second to appear, so the
        // fold is placed ahead of the lid by that much travel: flat at about 94.75°, where the lid will be by then.
        XCTAssertEqual(overlays[0].shows[0].start, 100 - 5.25, accuracy: 0.05)
        XCTAssertEqual(overlays[0].shows[0].from, overlays[0].shows[0].start)
        XCTAssertEqual(overlays[0].shows[0].to, 100)
        g.handle(angle: 90, time: 0.45)
        XCTAssertEqual(overlays[0].angles.last, 90)
    }

    func testNoPictureMeansNoOverlayAndBackToIdle() {
        picture = nil
        let g = makeGlass()
        closeFast(g)
        waitUntil(g.status == .idle)
        XCTAssertEqual(g.status, .idle)
        XCTAssertTrue(overlays.isEmpty || overlays.allSatisfy { !$0.calls.contains("show") })
        XCTAssertEqual(sensor.lastRate, 10, "the lid is near closing, so no slower than the sensor itself")
    }

    /// People work at 100–120°. A lid resting below the trigger does nothing, ever.
    func testRestingBelowTheTriggerDoesNothing() {
        let g = makeGlass()
        for i in 0..<480 { g.handle(angle: 105 + (i % 2 == 0 ? 1 : -1), time: Double(i) / 8) }
        settle()
        XCTAssertEqual(captures, 0)
        XCTAssertTrue(overlays.isEmpty)
        XCTAssertEqual(g.status, .idle)
        XCTAssertEqual(sensor.lastRate, 10, "the lid is near closing, so no slower than the sensor itself")
    }

    func testReopeningMidCloseClearsTheFrostAndReturnsToTheIdleRate() {
        let g = makeGlass()
        closeFast(g)
        waitUntil(overlays.first?.calls == ["show"])
        g.handle(angle: 90, time: 0.5)
        g.handle(angle: 115, time: 0.9)
        XCTAssertEqual(overlays[0].calls, ["show", "clear", "hide"])
        XCTAssertEqual(g.status, .idle)
        XCTAssertEqual(sensor.lastRate, 10, "the lid is near closing, so no slower than the sensor itself")
    }

    func testAnExternalDisplayBlocksTheClosingEffect() {
        external = true
        let g = makeGlass()
        closeFast(g)
        settle()
        XCTAssertEqual(captures, 0)
        XCTAssertTrue(overlays.isEmpty)
        XCTAssertEqual(g.status, .idle)
        XCTAssertEqual(sensor.lastRate, 10, "the lid is near closing, so no slower than the sensor itself")
    }

    func testChangingTheTriggerAppliesToTheNextClose() {
        let g = makeGlass()
        settings.lidGlassTriggerAngle = 90
        g.handle(angle: 125, time: 0); g.handle(angle: 100, time: 0.25)
        settle()
        XCTAssertTrue(overlays.allSatisfy { !$0.calls.contains("show") }, "100° is above a 90° trigger: nothing shown")
        g.handle(angle: 80, time: 0.4)
        waitUntil(!overlays.isEmpty)
        XCTAssertEqual(g.status, .active)
    }

    // ── Warming the picture ──

    /// A slow close: 6° a second, one degree per sensor update, from a lid resting at 104°.
    private func slowClose(_ g: LidGlass, upTo seconds: Double, from start: Double = 104, rate: Double = 6) {
        var t = 0.0
        while t <= seconds {
            let held = (t * 10).rounded(.down) / 10
            g.handle(angle: (start - rate * held).rounded(), time: t)
            t += 0.1
        }
    }

    func testASlowCloseWarmsThePictureBeforeItIsConfirmedAndThenShowsAtOnce() {
        let g = makeGlass()
        slowClose(g, upTo: 0.5)
        waitUntil(overlays.first?.prepares == 1)
        XCTAssertEqual(captures, 1, "one screenshot, taken when the descent was first seen")
        XCTAssertEqual(overlays.first?.prepares, 1)
        XCTAssertEqual(overlays.first?.calls, [], "warming shows nothing")
        XCTAssertEqual(g.status, .idle)
        slowClose(g, upTo: 1.5)
        XCTAssertEqual(overlays.first?.calls, ["show"])
        XCTAssertEqual(captures, 1, "the warmed picture was used, not a second screenshot")
        XCTAssertEqual(overlays.count, 1)
    }

    func testAWarmedPictureThatIsNeverUsedIsThrownAway() {
        let g = makeGlass()
        slowClose(g, upTo: 0.5)
        waitUntil(overlays.first?.prepares == 1)
        for i in 0..<30 { g.handle(angle: 101, time: 0.6 + Double(i) * 0.1) }     // the lid stops where it is; three seconds pass
        XCTAssertEqual(overlays.first?.calls, ["hide"])
        XCTAssertEqual(g.status, .idle)
    }

    func testNothingIsWarmedForALidThatIsNotClosing() {
        let g = makeGlass()
        for i in 0..<400 { g.handle(angle: 100 + (i % 2 == 0 ? 1 : -1), time: Double(i) / 8) }
        for i in 0..<100 { g.handle(angle: 101, time: 60 + Double(i) * 0.1) }
        settle()
        XCTAssertEqual(captures, 0)
        XCTAssertTrue(overlays.isEmpty)
    }

    func testAnExternalDisplayBlocksWarmingToo() {
        external = true
        let g = makeGlass()
        slowClose(g, upTo: 1.5)
        settle()
        XCTAssertEqual(captures, 0)
        XCTAssertTrue(overlays.isEmpty)
    }

    func testTurningOffWhileWarmThrowsThePictureAway() {
        let g = makeGlass()
        slowClose(g, upTo: 0.5)
        waitUntil(overlays.first?.prepares == 1)
        settings.lidGlassEnabled = false
        XCTAssertEqual(overlays.first?.calls, ["hide"])
        _ = g
    }

    // ── After the lid is closed ──

    /// There was once an opening effect after unlock. It looked like a glitch and is gone: after a close, a sleep and an
    /// unlock nothing more is captured or shown.
    func testNothingIsShownAfterUnlockFollowingACloseAndASleep() {
        let g = makeGlass()
        closeFast(g)
        waitUntil(overlays.first?.calls == ["show"])
        g.systemWillSleep()
        let capturesBefore = captures
        DistributedNotificationCenter.default().post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        waitUntil(captures > capturesBefore || overlays.count > 1, timeout: 0.6)
        settle()
        XCTAssertEqual(captures, capturesBefore, "no picture is taken for an opening effect")
        XCTAssertEqual(overlays.count, 1)
        XCTAssertEqual(g.status, .idle)
    }

    // ── Where the fold starts ──

    func testASlowCloseHasNoLeadBecauseThereIsNothingToCatchUpWith() {
        let g = makeGlass()
        g.handle(angle: 105, time: 0); g.handle(angle: 105, time: 1); g.handle(angle: 102, time: 1.2)
        waitUntil(overlays.first?.calls == ["show"])
        XCTAssertEqual(overlays[0].shows[0].start, 102, accuracy: 0.5)
    }

    func testTheLeadIsCappedSoAFlickOfTheLidDoesNotPlaceTheFoldFarAhead() {
        let g = makeGlass()
        g.handle(angle: 125, time: 0); g.handle(angle: 90, time: 0.1); g.handle(angle: 60, time: 0.2)
        waitUntil(overlays.first?.calls == ["show"])
        XCTAssertGreaterThanOrEqual(overlays[0].shows[0].start, 60 - LidGlass.maxStartLead)
    }

    // ── Letting go ──

    /// Back above where the picture was frozen the fold is flat, so there is nothing to show: let go at once
    /// rather than leave a frozen picture over a live screen.
    func testTheFoldLetsGoAsSoonAsTheLidRisesPastWhereItWasFrozen() {
        let g = makeGlass()
        closeFast(g)                                   // frozen at 100°
        waitUntil(overlays.first?.calls == ["show"])
        g.handle(angle: 95, time: 0.45)
        g.handle(angle: 98, time: 0.55)
        XCTAssertEqual(overlays[0].calls, ["show"], "98° is still below 103°")
        g.handle(angle: 104, time: 0.65)
        XCTAssertEqual(overlays[0].calls, ["show", "clear", "hide"])
        XCTAssertEqual(g.status, .idle)
        XCTAssertEqual(sensor.lastRate, 10, "the lid is near closing, so no slower than the sensor itself")
    }

    func testASlightFoldClearsQuicklyAfterTheLidStops() {
        let g = makeGlass()
        closeFast(g)                                   // frozen at 100°
        waitUntil(overlays.first?.calls == ["show"])
        g.handle(angle: 92, time: 0.5)
        g.handle(angle: 92, time: 0.7)
        XCTAssertEqual(overlays[0].calls, ["show"], "0.2 s of stillness is not a stop")
        g.handle(angle: 92, time: 1.0)
        XCTAssertEqual(overlays[0].calls, ["show", "clear", "hide"], "half a second at most")
        XCTAssertLessThanOrEqual(LidGlass.stillSettle, 0.5)
        XCTAssertLessThanOrEqual(LidGlass.reopenClear, 0.25)
    }

    // ── A lid that stops deep in the fold ──

    /// Stopping half way waits, as the iPhone Duo does; opening then plays the fold backwards and lets go at the end.
    func testALidStoppedDeepInTheFoldWaitsThenUnfoldsAsItOpens() {
        let g = makeGlass()
        closeFast(g)                                   // frozen at 100°
        waitUntil(overlays.first?.calls == ["show"])
        for i in 0...20 { g.handle(angle: 60, time: 0.5 + Double(i) * 0.1) }      // two seconds still
        XCTAssertEqual(overlays[0].calls, ["show"], "a deep fold is not cleared at once for being still")
        XCTAssertEqual(g.status, .active)
        for (i, a) in [64.0, 72, 84, 96].enumerated() { g.handle(angle: a, time: 5 + Double(i) * 0.1) }
        XCTAssertEqual(overlays[0].angles.suffix(4), [64, 72, 84, 96], "the overlay follows the lid up, so it unfolds")
        XCTAssertEqual(overlays[0].calls, ["show"], "not yet above where the picture was frozen")
        g.handle(angle: 104, time: 5.5)
        XCTAssertEqual(overlays[0].calls, ["show", "clear", "hide"])
        XCTAssertEqual(g.status, .idle)
    }

    // ── A lid left alone ──

    /// Someone may want the Mac almost closed and awake: the effect must not keep a GPU busy for that. Three seconds
    /// without the lid moving stops it, however deep the fold.
    func testTheEffectStopsWhenTheLidHasNotMovedForThreeSeconds() {
        let g = makeGlass()
        closeFast(g)
        waitUntil(overlays.first?.calls == ["show"])
        for i in 0..<25 { g.handle(angle: 20, time: 0.5 + Double(i) * 0.1) }          // 2.4 s
        XCTAssertEqual(overlays[0].calls, ["show"], "not yet")
        XCTAssertEqual(g.status, .active)
        for i in 25..<40 { g.handle(angle: 20, time: 0.5 + Double(i) * 0.1) }         // past 3 s
        XCTAssertEqual(overlays[0].calls, ["show", "clear", "hide"])
        XCTAssertEqual(g.status, .idle)
        XCTAssertEqual(sensor.lastRate, 10, "back to watching")
    }

    func testAnAlmostShutLidLeftAloneStopsToo() {
        let g = makeGlass()
        closeFast(g)
        waitUntil(overlays.first?.calls == ["show"])
        for i in 0..<40 { g.handle(angle: 3, time: 0.5 + Double(i) * 0.1) }
        XCTAssertEqual(overlays[0].calls, ["show", "clear", "hide"])
    }

    func testAnyRealMovementRestartsTheThreeSeconds() {
        let g = makeGlass()
        closeFast(g)
        waitUntil(overlays.first?.calls == ["show"])
        for i in 0..<25 { g.handle(angle: 40, time: 0.5 + Double(i) * 0.1) }          // 2.4 s still
        for i in 0..<25 { g.handle(angle: 34, time: 3.0 + Double(i) * 0.1) }          // moved 6 degrees, then 2.4 s still
        XCTAssertEqual(overlays[0].calls, ["show"], "five seconds in all, but never three still in a row")
        XCTAssertEqual(g.status, .active)
    }

    func testAfterItStoppedAFreshCloseStartsANewEffect() {
        let g = makeGlass()
        closeFast(g)
        waitUntil(overlays.first?.calls == ["show"])
        for i in 0..<40 { g.handle(angle: 20, time: 0.5 + Double(i) * 0.1) }
        XCTAssertEqual(g.status, .idle)
        g.handle(angle: 20, time: 5); g.handle(angle: 15, time: 5.1); g.handle(angle: 8, time: 5.2)
        waitUntil(overlays.count == 2)
        XCTAssertEqual(g.status, .active)
    }

    // ── A lid that stops ──

    /// Without this, nudging the lid down 6° and carrying on working would leave a frozen picture over the live screen.
    func testALidNudgedASlightWayAndLeftSettlesBackToTheLiveScreen() {
        let g = makeGlass()
        closeFast(g)                                   // frozen at 100°
        waitUntil(overlays.first?.calls == ["show"])
        g.handle(angle: 92, time: 0.5)
        for i in 1...20 { g.handle(angle: 92, time: 0.5 + Double(i) * 0.1) }
        XCTAssertEqual(overlays[0].calls, ["show", "clear", "hide"])
        XCTAssertEqual(g.status, .idle)
        XCTAssertEqual(sensor.lastRate, 10, "the lid is near closing, so no slower than the sensor itself")
    }

    func testALidStillMovingDoesNotSettle() {
        let g = makeGlass()
        closeFast(g)
        waitUntil(overlays.first?.calls == ["show"])
        for i in 0..<40 { g.handle(angle: 95 - Double(i), time: 0.5 + Double(i) * 0.1) }
        XCTAssertEqual(overlays[0].calls, ["show"])
        XCTAssertEqual(g.status, .active)
    }

    /// A lid that is shut sits at about 0° until the Mac sleeps; that is not a pause to clear the fold for (a lid left
    /// alone for three seconds is stopped, tested separately).
    func testAShutLidDoesNotSettle() {
        let g = makeGlass()
        closeFast(g)
        waitUntil(overlays.first?.calls == ["show"])
        g.handle(angle: 2, time: 0.6)
        for i in 1...20 { g.handle(angle: 2, time: 0.6 + Double(i) * 0.1) }      // two seconds: not the three-second rest
        XCTAssertEqual(overlays[0].calls, ["show"])
    }

    func testAnotherCloseStartsAfterTheLidSettled() {
        let g = makeGlass()
        closeFast(g)
        waitUntil(overlays.first?.calls == ["show"])
        for i in 0...20 { g.handle(angle: 92, time: 0.5 + Double(i) * 0.1) }
        g.handle(angle: 60, time: 2.7)
        g.handle(angle: 40, time: 2.9)
        waitUntil(overlays.count == 2)
        XCTAssertEqual(overlays.count, 2)
        XCTAssertEqual(g.status, .active)
    }

    // ── The sensor going wrong ──

    func testALostSensorStopsEverythingAndSaysSo() {
        let g = makeGlass()
        closeFast(g)
        waitUntil(overlays.first?.calls == ["show"])
        sensor.onLost?()
        waitUntil(g.status == .sensorLost)
        XCTAssertEqual(g.status, .sensorLost)
        XCTAssertEqual(overlays[0].calls, ["show", "hide"])
        XCTAssertGreaterThanOrEqual(sensor.stops, 1)
    }

    func testAMacWithoutTheSensorIsUnsupportedAndNeverPolls() {
        sensor.isAvailable = false
        let g = makeGlass()
        XCTAssertEqual(g.status, .unsupported)
        XCTAssertTrue(sensor.startedHz.isEmpty)
    }

    // ── Things that end the effect ──

    func testSleepAndScreenChangesRemoveTheOverlayAndRestoreTheIdleRate() {
        for event in [{ (g: LidGlass) in g.systemWillSleep() }, { (g: LidGlass) in g.displayConfigurationChanged() }] {
            overlays = []
            let g = makeGlass()
            closeFast(g)
            waitUntil(overlays.first?.calls == ["show"])
            event(g)
            XCTAssertEqual(overlays[0].calls, ["show", "hide"])
            XCTAssertEqual(g.status, .idle)
            XCTAssertEqual(sensor.lastRate, 10, "the lid is near closing, so no slower than the sensor itself")
            settings.lidGlassEnabled = false
        }
    }

    func testAPictureThatArrivesAfterTheScreenChangedIsDiscarded() {
        holdCaptures = true
        let g = makeGlass()
        closeFast(g)
        waitUntil(pendingCapture != nil)
        g.displayConfigurationChanged()
        pendingCapture?.resume(returning: picture)
        settle()
        XCTAssertTrue(overlays.isEmpty || overlays.allSatisfy { !$0.calls.contains("show") })
        XCTAssertEqual(g.status, .idle)
    }

    func testTurningTheFeatureOffMidEffectTearsEverythingDown() {
        let g = makeGlass()
        closeFast(g)
        waitUntil(overlays.first?.calls == ["show"])
        settings.lidGlassEnabled = false
        XCTAssertEqual(overlays[0].calls, ["show", "hide"])
        XCTAssertEqual(g.status, .off)
        XCTAssertGreaterThanOrEqual(sensor.stops, 1)
    }

    func testTurningOffWhileThePictureIsStillComingNeverShowsAnOverlay() {
        holdCaptures = true
        let g = makeGlass()
        closeFast(g)
        waitUntil(pendingCapture != nil)
        settings.lidGlassEnabled = false
        pendingCapture?.resume(returning: picture)
        settle()
        XCTAssertTrue(overlays.isEmpty || overlays.allSatisfy { !$0.calls.contains("show") })
        _ = g
    }

}

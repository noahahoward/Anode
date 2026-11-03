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
        var shownBlur: [Double] = [], blurs: [Double] = [], clearDurations: [TimeInterval] = []
        var finishClearAtOnce = true
        func show(image: CGImage, blur: Double) { calls.append("show"); shownBlur.append(blur) }
        func setBlur(_ amount: Double) { blurs.append(amount) }
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

    func testChangingTheIdleRateWhileIdleRetunesTheSensor() {
        let g = makeGlass()
        settings.lidGlassIdleHz = 20
        XCTAssertEqual(sensor.lastRate, 20)
        _ = g
    }

    // ── Closing ──

    func testClosingShowsTheOverlayThenFrostsWithTheAngleAndSpeedsUpPolling() {
        let g = makeGlass()
        closeFast(g)
        XCTAssertEqual(g.status, .active)
        XCTAssertEqual(sensor.lastRate, 120)
        waitUntil(!overlays.isEmpty && overlays[0].calls == ["show"])
        let curve = LidBlurCurve(trigger: 110)
        XCTAssertEqual(overlays[0].calls, ["show"])
        XCTAssertEqual(overlays[0].shownBlur[0], curve.amount(at: 100), accuracy: 1e-9)
        g.handle(angle: 90, time: 0.45)
        XCTAssertEqual(overlays[0].blurs.last ?? -1, curve.amount(at: 90), accuracy: 1e-9)
    }

    func testNoPictureMeansNoOverlayAndBackToIdle() {
        picture = nil
        let g = makeGlass()
        closeFast(g)
        waitUntil(g.status == .idle)
        XCTAssertEqual(g.status, .idle)
        XCTAssertTrue(overlays.isEmpty || overlays.allSatisfy { !$0.calls.contains("show") })
        XCTAssertEqual(sensor.lastRate, 8)
    }

    /// People work at 100–120°. A lid resting below the trigger does nothing, ever.
    func testRestingBelowTheTriggerDoesNothing() {
        let g = makeGlass()
        for i in 0..<480 { g.handle(angle: 105 + (i % 2 == 0 ? 1 : -1), time: Double(i) / 8) }
        settle()
        XCTAssertEqual(captures, 0)
        XCTAssertTrue(overlays.isEmpty)
        XCTAssertEqual(g.status, .idle)
        XCTAssertEqual(sensor.lastRate, 8)
    }

    func testReopeningMidCloseClearsTheFrostAndReturnsToTheIdleRate() {
        let g = makeGlass()
        closeFast(g)
        waitUntil(overlays.first?.calls == ["show"])
        g.handle(angle: 90, time: 0.5)
        g.handle(angle: 115, time: 0.9)
        XCTAssertEqual(overlays[0].calls, ["show", "clear", "hide"])
        XCTAssertEqual(g.status, .idle)
        XCTAssertEqual(sensor.lastRate, 8)
    }

    func testAnExternalDisplayBlocksTheClosingEffect() {
        external = true
        let g = makeGlass()
        closeFast(g)
        settle()
        XCTAssertEqual(captures, 0)
        XCTAssertTrue(overlays.isEmpty)
        XCTAssertEqual(g.status, .idle)
        XCTAssertEqual(sensor.lastRate, 8)
    }

    func testChangingTheTriggerAppliesToTheNextClose() {
        let g = makeGlass()
        settings.lidGlassTriggerAngle = 90
        g.handle(angle: 125, time: 0); g.handle(angle: 100, time: 0.25)
        settle()
        XCTAssertEqual(captures, 0, "100° is above a 90° trigger")
        g.handle(angle: 80, time: 0.4)
        waitUntil(!overlays.isEmpty)
        XCTAssertEqual(g.status, .active)
    }

    // ── A lid that stops ──

    /// Without this, nudging the lid down 6° and carrying on working would leave a frozen picture over the live screen.
    func testALidThatStopsMidCloseSettlesBackToTheLiveScreen() {
        let g = makeGlass()
        closeFast(g)
        waitUntil(overlays.first?.calls == ["show"])
        g.handle(angle: 80, time: 0.5)
        for i in 1...20 { g.handle(angle: 80, time: 0.5 + Double(i) * 0.1) }
        XCTAssertEqual(overlays[0].calls, ["show", "clear", "hide"])
        XCTAssertEqual(g.status, .idle)
        XCTAssertEqual(sensor.lastRate, 8)
    }

    func testALidStillMovingDoesNotSettle() {
        let g = makeGlass()
        closeFast(g)
        waitUntil(overlays.first?.calls == ["show"])
        for i in 0..<40 { g.handle(angle: 95 - Double(i), time: 0.5 + Double(i) * 0.1) }
        XCTAssertEqual(overlays[0].calls, ["show"])
        XCTAssertEqual(g.status, .active)
    }

    /// A lid that is shut sits at about 0° until the Mac sleeps; that is not a pause to clear the frost for.
    func testAShutLidDoesNotSettle() {
        let g = makeGlass()
        closeFast(g)
        waitUntil(overlays.first?.calls == ["show"])
        g.handle(angle: 2, time: 0.6)
        for i in 1...30 { g.handle(angle: 2, time: 0.6 + Double(i) * 0.1) }
        XCTAssertEqual(overlays[0].calls, ["show"])
    }

    func testAfterTheLidSettlesTheNextUnlockPlaysNothing() {
        let g = makeGlass()
        closeFast(g)
        waitUntil(overlays.first?.calls == ["show"])
        for i in 0...20 { g.handle(angle: 80, time: 0.5 + Double(i) * 0.1) }
        g.screenUnlocked()
        settle()
        XCTAssertEqual(overlays.count, 1)
        XCTAssertEqual(captures, 1)
    }

    func testAnotherCloseStartsAfterTheLidSettled() {
        let g = makeGlass()
        closeFast(g)
        waitUntil(overlays.first?.calls == ["show"])
        for i in 0...20 { g.handle(angle: 80, time: 0.5 + Double(i) * 0.1) }
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
            XCTAssertEqual(sensor.lastRate, 8)
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

    // ── After unlock ──

    func testUnlockAfterACloseClearsTheFrostOnce() {
        let g = makeGlass()
        closeFast(g)
        waitUntil(overlays.first?.calls == ["show"])
        g.systemWillSleep()
        g.screenUnlocked()
        waitUntil(overlays.count == 2 && overlays[1].calls.contains("hide"))
        XCTAssertEqual(overlays[1].calls, ["show", "clear", "hide"])
        XCTAssertEqual(overlays[1].shownBlur, [1])
        XCTAssertEqual(overlays[1].clearDurations, [0.5])
        g.screenUnlocked()
        settle()
        XCTAssertEqual(overlays.count, 2, "a second unlock does nothing")
    }

    func testUnlockWithoutACloseDoesNothing() {
        let g = makeGlass()
        g.screenUnlocked()
        settle()
        XCTAssertEqual(captures, 0)
        XCTAssertTrue(overlays.isEmpty)
    }

    func testReopeningBeforeTheLidShutMeansTheNextUnlockPlaysNothing() {
        let g = makeGlass()
        closeFast(g)
        waitUntil(overlays.first?.calls == ["show"])
        g.handle(angle: 115, time: 0.9)
        g.screenUnlocked()
        settle()
        XCTAssertEqual(overlays.count, 1)
    }

    func testInputDuringTheClosingEffectIsIgnored() {
        let g = makeGlass()
        closeFast(g)
        waitUntil(overlays.first?.calls == ["show"])
        g.userInput()
        XCTAssertEqual(overlays[0].calls, ["show"])
    }

    func testInputDuringTheOpeningEffectHidesIt() {
        let g = makeGlass()
        closeFast(g)
        waitUntil(overlays.first?.calls == ["show"])
        g.systemWillSleep()
        finishClearsAtOnce = false
        g.screenUnlocked()
        waitUntil(overlays.count == 2 && overlays[1].calls.contains("clear"))
        g.userInput()
        XCTAssertEqual(overlays[1].calls, ["show", "clear", "hide"])
    }
}

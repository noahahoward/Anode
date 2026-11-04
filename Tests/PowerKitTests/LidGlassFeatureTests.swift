import XCTest
import AppKit
import ScreenCaptureKit
@testable import AnodeApp
@testable import PowerKit

/// Lid Glass's pieces that can be checked without a lid, a permission prompt, or a visible window.
final class LidGlassFeatureTests: XCTestCase {

    // ── Capture ──

    /// The frozen picture is swapped in for the live screen, so it must have the screen's own pixels.
    @available(macOS 14.0, *)
    func testConfigurationIsPixelExactAndHidesTheCursor() {
        let c = LidGlassCapture.configuration(pointSize: CGSize(width: 1512, height: 982), scale: 2)
        XCTAssertEqual(c.width, 3024)
        XCTAssertEqual(c.height, 1964)
        XCTAssertFalse(c.showsCursor)
        XCTAssertEqual(c.pixelFormat, kCVPixelFormatType_32BGRA)
    }

    func testTheBuiltInDisplayIsFoundOnThisMacOrNilNeverAnExternalOne() {
        if let id = LidGlassCapture.builtInDisplayID() {
            XCTAssertNotEqual(CGDisplayIsBuiltin(id), 0)
        }
    }

    // ── Overlay window ──
    //
    // Nothing here shows a window: the tests look at what the window is, and at the one path (no renderer) that must
    // leave it hidden.

    @available(macOS 14.0, *)
    private func overlay(renderer: Bool = true) throws -> LidGlassOverlay {
        let screen = try XCTUnwrap(NSScreen.screens.first, "needs a screen")
        return LidGlassOverlay(screen: screen, makeRenderer: { renderer ? LidGlassRenderer() : nil })
    }

    @available(macOS 14.0, *)
    func testWindowIsAFullScreenClickThroughOverlay() throws {
        let o = try overlay()
        let screen = try XCTUnwrap(NSScreen.screens.first)
        XCTAssertEqual(o.window.frame, screen.frame)
        XCTAssertTrue(o.window.ignoresMouseEvents)
        XCTAssertGreaterThanOrEqual(o.window.level.rawValue, NSWindow.Level.screenSaver.rawValue)
        XCTAssertTrue(o.window.styleMask.isEmpty || o.window.styleMask == [.borderless])
        XCTAssertFalse(o.window.hasShadow)
    }

    @available(macOS 14.0, *)
    func testNothingRunsWhileHidden() throws {
        let o = try overlay()
        XCTAssertFalse(o.window.isVisible)
        XCTAssertFalse(o.isDisplayLinkRunning)
        o.hide()
        XCTAssertFalse(o.window.isVisible)
        XCTAssertFalse(o.isDisplayLinkRunning)
    }

    /// An overlay with nothing to draw would be a black window over the screen.
    @available(macOS 14.0, *)
    func testShowIsIgnoredWhenThereIsNoRenderer() throws {
        let o = try overlay(renderer: false)
        let image = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        o.show(image: image, startAngle: 90, from: 90, to: 80)
        XCTAssertFalse(o.window.isVisible)
        XCTAssertFalse(o.isDisplayLinkRunning)
    }

    // The overlay's own life cycle, with the window kept off the screen (`showsWindow = false`).

    @available(macOS 14.0, *)
    private func tinyImage() throws -> CGImage {
        try XCTUnwrap(CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
    }

    private func spin(until done: @autoclosure () -> Bool, timeout: TimeInterval = 3) {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// The picture is prepared off the main thread, so the display link starts a little after `show`, and stops with `hide`.
    @available(macOS 14.0, *)
    func testShowPreparesInTheBackgroundThenRunsAndHideStopsIt() throws {
        let o = try overlay(); o.showsWindow = false
        o.show(image: try tinyImage(), startAngle: 90, from: 90, to: 70)
        XCTAssertFalse(o.isDisplayLinkRunning, "not before the picture is ready")
        spin(until: o.isDisplayLinkRunning)
        XCTAssertTrue(o.isDisplayLinkRunning)
        o.hide()
        XCTAssertFalse(o.isDisplayLinkRunning)
    }

    /// The opening effect asks for the clear straight after `show`; it must wait for the picture, not finish at once.
    @available(macOS 14.0, *)
    func testAClearAskedForBeforeThePictureIsReadyRunsOnceItIs() throws {
        let o = try overlay(); o.showsWindow = false
        var done = false
        o.show(image: try tinyImage(), startAngle: 90, from: 42, to: 42)
        o.animateClear(duration: 0.1) { done = true }
        XCTAssertFalse(done)
        spin(until: o.isDisplayLinkRunning)
        XCTAssertFalse(done, "the clear starts when the picture is ready, not before")
        o.advance(dt: 1.0 / 60, now: CACurrentMediaTime() + 1)
        XCTAssertTrue(done)
        o.hide()
    }

    @available(macOS 14.0, *)
    func testHidingBeforeThePictureIsReadyMeansItNeverAppears() throws {
        let o = try overlay(); o.showsWindow = false
        o.show(image: try tinyImage(), startAngle: 90, from: 90, to: 70)
        o.hide()
        spin(until: o.isDisplayLinkRunning, timeout: 0.5)
        XCTAssertFalse(o.isDisplayLinkRunning)
    }

    /// A fold held still draws nothing and, now, wakes nothing: the display link stops until the lid moves again.
    @available(macOS 14.0, *)
    func testTheDisplayLinkStopsWhenNothingIsMovingAndWakesWhenTheLidMoves() throws {
        let o = try overlay(); o.showsWindow = false
        o.show(image: try tinyImage(), startAngle: 90, from: 70, to: 70)
        spin(until: o.isDisplayLinkRunning)
        XCTAssertTrue(o.isDisplayLinkRunning)
        var now = CACurrentMediaTime()
        for _ in 0..<20 { now += 1.0 / 120; o.advance(dt: 1.0 / 120, now: now) }
        XCTAssertFalse(o.isDisplayLinkRunning, "twenty frames of nothing changing")
        o.setAngle(70)
        XCTAssertFalse(o.isDisplayLinkRunning, "the same angle again is not movement")
        o.setAngle(66)
        XCTAssertTrue(o.isDisplayLinkRunning, "the lid moved")
        o.hide()
    }

    @available(macOS 14.0, *)
    func testAClearAskedForWhileTheLinkIsPausedStillRuns() throws {
        let o = try overlay(); o.showsWindow = false
        o.show(image: try tinyImage(), startAngle: 90, from: 70, to: 70)
        spin(until: o.isDisplayLinkRunning)
        var now = CACurrentMediaTime()
        for _ in 0..<20 { now += 1.0 / 120; o.advance(dt: 1.0 / 120, now: now) }
        XCTAssertFalse(o.isDisplayLinkRunning)
        var done = false
        o.animateClear(duration: 0.1) { done = true }
        XCTAssertTrue(o.isDisplayLinkRunning, "a clear needs frames")
        o.advance(dt: 1.0 / 120, now: CACurrentMediaTime() + 1)
        XCTAssertTrue(done)
        o.hide()
    }

    /// Smoothness matters at speed; a slow or settling fold looks as smooth at half the rate, for half the GPU.
    @available(macOS 14.0, *)
    func testTheFrameRateIsFullWhileTheLidIsFastAndHalvedWhenItIsSlowOrStill() throws {
        let o = try overlay(); o.showsWindow = false
        o.show(image: try tinyImage(), startAngle: 90, from: 90, to: 90)
        spin(until: o.isDisplayLinkRunning)
        XCTAssertEqual(o.frameRate, 120, "a close starts fast")
        var t = CACurrentMediaTime()
        for (i, angle) in [90.0, 85, 80, 75, 70].enumerated() { o.setAngle(angle, at: t + Double(i) * 0.1) }      // 50°/s
        o.advance(dt: 1.0 / 120, now: t + 0.5)
        XCTAssertEqual(o.frameRate, 120)
        t += 5
        for i in 0..<8 { o.setAngle(70, at: t + Double(i) * 0.1) }                                              // stopped
        o.advance(dt: 1.0 / 120, now: t + 0.8)
        XCTAssertEqual(o.frameRate, 60)
        o.hide()
    }

    /// A deep fold is soft, so it is drawn smaller; an unfolded picture is drawn full size.
    @available(macOS 14.0, *)
    func testTheOverlayDrawsSmallerDeepIntoTheFoldAndFullSizeAtTheStart() throws {
        let deep = try overlay(); deep.showsWindow = false
        deep.show(image: try tinyImage(), startAngle: 90, from: 40, to: 40)
        spin(until: deep.isDisplayLinkRunning)
        deep.advance(dt: 1.0 / 120, now: CACurrentMediaTime())
        XCTAssertEqual(deep.renderScale, 0.35, "86 percent of the way in")
        deep.hide()
        XCTAssertEqual(deep.renderScale, 1, "reset for the next one")

        let start = try overlay(); start.showsWindow = false
        start.show(image: try tinyImage(), startAngle: 90, from: 89, to: 89)
        spin(until: start.isDisplayLinkRunning)
        start.advance(dt: 1.0 / 120, now: CACurrentMediaTime())
        XCTAssertEqual(start.renderScale, 1)
        start.hide()
    }

    /// With nothing showing, a clear has nothing to wait for.
    @available(macOS 14.0, *)
    func testClearWithNothingShowingCompletesAtOnce() throws {
        let o = try overlay(); o.showsWindow = false
        var done = false
        o.animateClear(duration: 0.1) { done = true }
        XCTAssertTrue(done)
    }

    // ── The Beta Features section ──

    private var defaults: UserDefaults!
    private var suiteName: String!

    private func feature(allowed: Bool = true, status: LidGlassStatus = .idle, macOS14: Bool = true,
                         enabled: Bool = false) throws -> (LidGlassFeature, Settings) {
        (defaults, suiteName) = try TestDefaults.make(owner: "LidGlassFeature", test: name)
        addTeardownBlock { [defaults, suiteName] in TestDefaults.destroy(defaults!, suiteName!) }
        let settings = Settings(defaults: defaults)
        settings.lidGlassEnabled = enabled
        let f = LidGlassFeature(settings: settings, screenRecordingAllowed: { allowed }, status: { status }, macOS14: macOS14)
        _ = f.makeView()
        return (f, settings)
    }

    func testTheSectionExistsAndStartsOff() throws {
        let (f, settings) = try feature()
        XCTAssertEqual(f.title, "Lid Glass")
        XCTAssertEqual(f.enableCheckbox.state, .off)
        XCTAssertFalse(settings.lidGlassEnabled)
        XCTAssertTrue(BetaFeaturesWindowController().features.contains { $0.title == "Lid Glass" })
    }

    func testTheCheckboxAndSlidersWriteTheirSettings() throws {
        let (f, settings) = try feature()
        XCTAssertEqual(f.idleRateSlider.minValue, 4); XCTAssertEqual(f.idleRateSlider.maxValue, 30)
        XCTAssertEqual(f.triggerSlider.minValue, 60); XCTAssertEqual(f.triggerSlider.maxValue, 150)
        f.enableCheckbox.state = .on
        _ = f.enableCheckbox.target?.perform(f.enableCheckbox.action, with: f.enableCheckbox)
        XCTAssertTrue(settings.lidGlassEnabled)
        f.idleRateSlider.doubleValue = 12.4
        _ = f.idleRateSlider.target?.perform(f.idleRateSlider.action, with: f.idleRateSlider)
        XCTAssertEqual(settings.lidGlassIdleHz, 12, "whole hertz")
        f.triggerSlider.doubleValue = 95
        _ = f.triggerSlider.target?.perform(f.triggerSlider.action, with: f.triggerSlider)
        XCTAssertEqual(settings.lidGlassTriggerAngle, 95)
    }

    func testOnMacOS13TheToggleIsDisabledWithAnExplanation() throws {
        let (f, _) = try feature(macOS14: false)
        XCTAssertFalse(f.enableCheckbox.isEnabled)
        XCTAssertTrue(f.accessStatus.stringValue.contains("macOS 14"))
    }

    func testMissingPermissionShowsTheButtonAndTheStatusText() throws {
        let (f, _) = try feature(allowed: false, enabled: true)
        XCTAssertFalse(f.accessButton.isHidden)
        XCTAssertTrue(f.accessStatus.stringValue.contains("Screen Recording"))
        let (g, _) = try feature(allowed: true, enabled: true)
        XCTAssertTrue(g.accessButton.isHidden)
    }

    func testUnsupportedAndLostSensorAreSaid() throws {
        let (a, _) = try feature(status: .unsupported, enabled: true)
        XCTAssertTrue(a.accessStatus.stringValue.contains("not supported on this Mac"))
        let (b, _) = try feature(status: .sensorLost, enabled: true)
        XCTAssertTrue(b.accessStatus.stringValue.contains("stopped responding"))
    }

    func testTheDetailRowsAreHiddenWhileOff() throws {
        let (f, _) = try feature(enabled: false)
        XCTAssertTrue(f.idleRateSlider.isHidden)
        XCTAssertTrue(f.triggerSlider.isHidden)
        XCTAssertTrue(f.accessStatus.isHidden)
    }
}

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
        o.show(image: image)
        XCTAssertFalse(o.window.isVisible)
        XCTAssertFalse(o.isDisplayLinkRunning)
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

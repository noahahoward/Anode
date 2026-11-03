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
}

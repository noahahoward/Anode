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
}

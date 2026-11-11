import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The pill's pictures: which source each icon gets and where it is cut out of a capture of the bar. No panel is created and
/// nothing is captured.
final class BarPillWindowTests: XCTestCase {

    private func item(x: CGFloat, y: CGFloat = 0, w: CGFloat = 22, h: CGFloat = 39, pid: pid_t? = 5) -> BarItem {
        BarItem(key: "a|b", bundleID: "a", appName: "A", title: "b", frame: CGRect(x: x, y: y, width: w, height: h),
                isLocked: false, hasPress: true, pid: pid)
    }

    func testCropRectIsInPixelsFromBandOrigin() {
        // A 2x capture of a band starting at x 1000: an item at x 1430, 22 wide, 39 high, is at pixel x 860, 44 wide.
        let r = BarPictures.crop(imageSize: CGSize(width: 1600, height: 80), itemFrame: CGRect(x: 1430, y: 0, width: 22, height: 39),
                                 bandOrigin: CGPoint(x: 1000, y: 0), scale: 2)
        XCTAssertEqual(r, CGRect(x: 860, y: 0, width: 44, height: 78))
    }

    func testCropClampsToImage() {
        let r = BarPictures.crop(imageSize: CGSize(width: 100, height: 80), itemFrame: CGRect(x: 40, y: 0, width: 22, height: 39),
                                 bandOrigin: .zero, scale: 2)
        XCTAssertEqual(r.maxX, 100)
        XCTAssertGreaterThan(r.width, 0)
        let off = BarPictures.crop(imageSize: CGSize(width: 100, height: 80), itemFrame: CGRect(x: 400, y: 0, width: 22, height: 39),
                                   bandOrigin: .zero, scale: 2)
        XCTAssertTrue(off.isEmpty, "an item outside the capture has nothing to cut out")
    }

    func testParkedItemUsesAppIcon() {
        XCTAssertEqual(BarPictures.source(for: item(x: -1, y: 1157, w: 34, h: 24), screens: [CGRect(x: 0, y: 0, width: 1800, height: 1169)],
                                          captureAvailable: true), .appIcon)
        XCTAssertEqual(BarPictures.source(for: item(x: 1430), screens: [CGRect(x: 0, y: 0, width: 1800, height: 1169)],
                                          captureAvailable: true), .capture)
    }

    func testNoCaptureAvailableUsesAppIcon() {
        XCTAssertEqual(BarPictures.source(for: item(x: 1430), screens: [CGRect(x: 0, y: 0, width: 1800, height: 1169)],
                                          captureAvailable: false), .appIcon)
    }
}

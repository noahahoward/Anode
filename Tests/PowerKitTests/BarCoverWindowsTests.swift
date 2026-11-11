import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The cover panels' geometry and look. No panel is created: only the pure parts are tested.
final class BarCoverWindowsTests: XCTestCase {

    func testTopLeftToAppKitConversion() {
        // A menu-bar-high rectangle at the top of a 1169-high primary screen.
        let f = BarCoverWindows.appKitFrame(forTopLeft: CGRect(x: 1111, y: 0, width: 92, height: 37), primaryScreenHeight: 1169)
        XCTAssertEqual(f, NSRect(x: 1111, y: 1132, width: 92, height: 37))
    }

    func testConversionOnASecondaryScreenWithOffsetOrigin() {
        // A second display above and to the right of the primary: its top-left-space y is negative.
        let f = BarCoverWindows.appKitFrame(forTopLeft: CGRect(x: 1800, y: -500, width: 100, height: 24), primaryScreenHeight: 1169)
        XCTAssertEqual(f, NSRect(x: 1800, y: 1645, width: 100, height: 24))
    }

    /// The owner's bar is solid black (measured 2026-11-11, four captures over a minute), so the cover is black.
    func testCoverIsBlack() {
        XCTAssertEqual(BarCoverWindows.fill, NSColor.black)
    }

    /// Never over a full-screen app's Space: the covers must not carry `fullScreenAuxiliary`.
    func testCoversDoNotJoinFullScreenSpaces() {
        XCTAssertFalse(BarCoverWindows.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(BarCoverWindows.collectionBehavior.contains(.canJoinAllSpaces))
    }
}

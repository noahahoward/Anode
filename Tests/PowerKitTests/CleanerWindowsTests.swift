import XCTest
import AppKit
@testable import AnodeApp

/// The black windows: geometry and flags. None of these is ordered onto a screen.
final class CleanerWindowsTests: XCTestCase {

    func testOneFramePerScreenCoveringItExactly() {
        let screens = [NSRect(x: 0, y: 0, width: 1800, height: 1169), NSRect(x: 1800, y: -200, width: 1920, height: 1080)]
        XCTAssertEqual(CleanerWindows.frames(for: screens), screens)
        XCTAssertEqual(CleanerWindows.frames(for: []), [])
    }

    func testHintSitsBottomLeftWithA24PointMargin() {
        let frame = NSRect(x: 1800, y: -200, width: 1920, height: 1080)
        let p = CleanerWindows.hintOrigin(in: frame, hintSize: NSSize(width: 300, height: 20))
        XCTAssertEqual(p, NSPoint(x: frame.minX + 24, y: frame.minY + 24))
    }

    func testWindowIsBlackOpaqueAndAboveTheMenuBar() {
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let w = CleanerWindows.makeWindow(frame: frame, hint: "Press ⌃⌥⌘⎋ to finish")
        XCTAssertEqual(w.frame, frame)
        XCTAssertEqual(w.backgroundColor, NSColor.black)
        XCTAssertTrue(w.isOpaque)
        XCTAssertGreaterThanOrEqual(w.level.rawValue, Int(CGShieldingWindowLevel()))
        XCTAssertTrue(w.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(w.collectionBehavior.contains(.stationary))
        XCTAssertFalse(w.ignoresMouseEvents)
        XCTAssertEqual(w.animationBehavior, .none)
        XCTAssertFalse(w.hasShadow)
        XCTAssertFalse(w.isReleasedWhenClosed)
    }

    func testWindowCarriesTheHintAndNothingElse() throws {
        let w = CleanerWindows.makeWindow(frame: NSRect(x: 0, y: 0, width: 800, height: 600), hint: "Press ⌃⌥⌘⎋ to finish")
        let labels = (w.contentView?.subviews ?? []).compactMap { $0 as? NSTextField }
        XCTAssertEqual(labels.map(\.stringValue), ["Press ⌃⌥⌘⎋ to finish"])
        XCTAssertEqual(w.contentView?.subviews.count, 1)
        let label = try XCTUnwrap(labels.first)
        XCTAssertEqual(label.frame.origin, NSPoint(x: 24, y: 24), "bottom-left of the window, in its own coordinates")
    }

    func testHidingWithNothingShownIsHarmless() {
        let windows = CleanerWindows()
        XCTAssertFalse(windows.isShowing)
        windows.hide()
        XCTAssertFalse(windows.isShowing)
    }
}

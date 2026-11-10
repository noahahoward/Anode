import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The hot-spot panels, built but never ordered on screen.
final class HotCornerWindowsTests: XCTestCase {

    override func setUp() { _ = NSApplication.shared }

    func testOneFramePerScreenFlushToTheChosenCorner() {
        let screens = [CGRect(x: 0, y: 0, width: 1800, height: 1169), CGRect(x: 1800, y: -200, width: 1920, height: 1080)]
        XCTAssertEqual(HotCornerWindows.frames(corner: .topRight, screens: screens),
                       [CGRect(x: 1794, y: 1163, width: 6, height: 6), CGRect(x: 3714, y: 874, width: 6, height: 6)])
        XCTAssertEqual(HotCornerWindows.frames(corner: .topRight, screens: []), [])
    }

    func testPanelRecipe() {
        let w = HotCornerWindows().makeWindow(frame: CGRect(x: 1794, y: 1163, width: 6, height: 6), onEnter: {})
        XCTAssertTrue(w is NSPanel)
        XCTAssertTrue(w.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual((w as? NSPanel)?.hidesOnDeactivate, false)
        XCTAssertEqual(w.level, .screenSaver)
        XCTAssertEqual(w.collectionBehavior, [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle])
        XCTAssertFalse(w.ignoresMouseEvents, "it has to notice the pointer")
        XCTAssertFalse(w.canBecomeKey)
        XCTAssertFalse(w.hasShadow)
        XCTAssertEqual(w.frame.size, CGSize(width: 6, height: 6))
        let areas = w.contentView?.trackingAreas ?? []
        XCTAssertEqual(areas.count, 1)
        XCTAssertTrue(areas.first?.options.contains(.activeAlways) ?? false)
        XCTAssertTrue(areas.first?.options.contains(.mouseEnteredAndExited) ?? false)
        XCTAssertFalse(w.isVisible)
    }

    func testNothingIsShownUntilAskedTo() {
        let hot = HotCornerWindows()
        XCTAssertEqual(hot.windowCount, 0)
        hot.hide()
        XCTAssertEqual(hot.windowCount, 0)
    }
}

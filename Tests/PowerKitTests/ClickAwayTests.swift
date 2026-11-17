import XCTest
@testable import PowerKit

/// How macOS closes a menu bar panel when the click that closes it lands somewhere else (measured at 120 fps on macOS 27): on another
/// menu bar item (another icon's panel, the Apple menu) the old panel is gone in the very frame the new one is there, with no fade; on
/// empty menu bar, a window or the desktop it fades out in a straight line over about 240 ms.
final class ClickAwayTests: XCTestCase {

    func testAClickOnAnotherMenuBarItemClosesAtOnce() {
        XCTAssertFalse(ClickAway.fades(whenClickLandsOn: "AXMenuBarItem"))
    }

    func testAClickOnEmptyMenuBarFades() {
        XCTAssertTrue(ClickAway.fades(whenClickLandsOn: "AXMenuBar"))
    }

    func testAClickOnAWindowOrTheDesktopFades() {
        XCTAssertTrue(ClickAway.fades(whenClickLandsOn: "AXGroup"))
        XCTAssertTrue(ClickAway.fades(whenClickLandsOn: "AXWindow"))
    }

    func testWhenNothingCanBeSaidAboutTheClickTheMenuFades() {
        XCTAssertTrue(ClickAway.fades(whenClickLandsOn: nil), "no Accessibility, or no answer in time: the usual close")
    }
}

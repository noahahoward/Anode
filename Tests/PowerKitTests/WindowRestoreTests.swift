import AppKit
import XCTest
@testable import AnodeApp

/// Getting the window back.
///
/// `makeKeyAndOrderFront` does not restore a MINIATURIZED window — ordering a
/// window front and taking it out of the Dock are different operations, and only
/// `deminiaturize` does the second. The distinction is invisible in code review
/// because both spellings compile and both "show the window" in the reading, so
/// it is pinned here instead.
///
/// The failure it guards is not cosmetic: `show()` also sets `.regular` and
/// activates, so the app took the menu bar and key focus while its window stayed
/// in the Dock — frontmost with nothing on screen. And because hiding the window
/// drops the app to `.accessory`, the Dock tile was gone too, leaving no way back
/// short of relaunching.
final class WindowRestoreTests: XCTestCase {

    func testShowRestoresAMiniaturisedWindow() throws {
        let controller = MainWindowController()
        controller.show()

        controller.window.miniaturize(nil)
        // Miniaturising needs a window server. Where there is none the call is a
        // no-op, and asserting on it would test the environment, not the fix.
        try XCTSkipUnless(controller.window.isMiniaturized,
                          "no window server: miniaturize() is a no-op here")

        controller.show()

        XCTAssertFalse(controller.window.isMiniaturized,
                       "show() left the window in the Dock; the app would be frontmost with nothing on screen")
        XCTAssertTrue(controller.window.isVisible)
    }
}

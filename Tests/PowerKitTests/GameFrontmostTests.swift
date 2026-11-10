import XCTest
import AppKit
@testable import AnodeApp

/// How "the frontmost app is fullscreen" is read: from the presentation options in force for the whole system, which a
/// fullscreen app changes (measured with Bloons TD6 frontmost on 2026-11-09: hideMenuBar and hideDock; with a browser, none).
/// The menu bar's own window cannot tell, because it stays listed on a notched screen even in fullscreen.
final class GameFrontmostTests: XCTestCase {

    func testNoSpecialOptionsIsNotFullscreen() {
        XCTAssertFalse(RealFrontmost.isFullscreen(presentationOptions: []))
    }

    func testAHiddenMenuBarIsFullscreen() {
        XCTAssertTrue(RealFrontmost.isFullscreen(presentationOptions: [.hideMenuBar, .hideDock]))
        XCTAssertTrue(RealFrontmost.isFullscreen(presentationOptions: [.autoHideMenuBar]))
    }

    func testCocoaFullscreenIsFullscreen() {
        XCTAssertTrue(RealFrontmost.isFullscreen(presentationOptions: [.fullScreen, .autoHideMenuBar, .autoHideDock]))
        XCTAssertTrue(RealFrontmost.isFullscreen(presentationOptions: [.fullScreen]))
    }

    func testAHiddenDockAloneIsNot() {
        XCTAssertFalse(RealFrontmost.isFullscreen(presentationOptions: [.autoHideDock]))
        XCTAssertFalse(RealFrontmost.isFullscreen(presentationOptions: [.hideDock]))
    }
}

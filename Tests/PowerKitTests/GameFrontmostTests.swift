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

    func testObserverStartTwiceThenStopLeavesNothingListening() {
        let observer = WorkspaceActivationObserver()
        XCTAssertFalse(observer.isListening)
        observer.start {}
        observer.start {}
        XCTAssertTrue(observer.isListening)
        observer.stop()
        XCTAssertFalse(observer.isListening)
        observer.stop()   // stopping what is stopped is harmless
        XCTAssertFalse(observer.isListening)
    }

    func testReaderAnswersWithoutCrashing() {
        // The value depends on what is in front right now; the call must simply be safe to make any number of times.
        _ = AppleGameModeReader.isOn()
        _ = AppleGameModeReader.isOn()
    }
}

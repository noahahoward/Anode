import XCTest
import AppKit
@testable import AnodeApp

/// The black backdrop of Ultra Low Power Mode: where it sits, what its windows are, and when they are made and taken away.
/// No window is ever put on screen: what the backdrop shows and closes is written down instead, over screens and a
/// notification center of the test's own.
final class UltraBackdropTests: XCTestCase {

    private let main = NSRect(x: 0, y: 0, width: 1800, height: 1169)
    private let side = NSRect(x: 1800, y: 0, width: 1920, height: 1080)

    /// What the backdrop was told to put on screen and to take away, and the screens it is told about.
    private final class Rig {
        let center = NotificationCenter()
        var screens: [NSRect]
        private(set) var presented: [NSRect] = []
        private(set) var dismissed: [NSRect] = []
        private(set) var backdrop: LiveUltraBackdrop!

        init(screens: [NSRect]) {
            _ = NSApplication.shared
            self.screens = screens
            backdrop = LiveUltraBackdrop(screens: { [unowned self] in self.screens },
                                         present: { [unowned self] in self.presented.append($0.frame) },
                                         dismiss: { [unowned self] in self.dismissed.append($0.frame) },
                                         center: center)
        }

        func screensChanged() {
            center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }
    }

    // ── Where it sits ───────────────────────────────────────────────────────

    func testOneFramePerScreenAndEachIsTheScreensWholeFrame() {
        XCTAssertEqual(LiveUltraBackdrop.frames(for: [main, side]), [main, side])
        XCTAssertEqual(LiveUltraBackdrop.frames(for: [main]), [main])
        XCTAssertEqual(LiveUltraBackdrop.frames(for: []), [])
        // A screen to the left of the main one has a frame that begins below zero: it is the screen's, as it is.
        let left = NSRect(x: -1440, y: 120, width: 1440, height: 900)
        XCTAssertEqual(LiveUltraBackdrop.frames(for: [main, left]), [main, left])
    }

    /// Above the desktop picture and the desktop icons, below every app window: what is lit on a screen is then the app's
    /// windows, the menu bar and the Dock.
    func testTheLevelIsAboveTheDesktopIconsAndBelowEveryAppWindow() {
        let icons = Int(CGWindowLevelForKey(.desktopIconWindow))
        XCTAssertEqual(LiveUltraBackdrop.level.rawValue, icons + 1, "one above the icons")
        XCTAssertGreaterThan(LiveUltraBackdrop.level.rawValue, DesktopWallpaperWindow.level().rawValue,
                             "over the live wallpaper's window and the system's own picture")
        XCTAssertLessThan(LiveUltraBackdrop.level.rawValue, NSWindow.Level.normal.rawValue, "under every app window")
        XCTAssertLessThan(LiveUltraBackdrop.level.rawValue, NSWindow.Level.floating.rawValue)
        XCTAssertLessThan(LiveUltraBackdrop.level.rawValue, NSWindow.Level.mainMenu.rawValue, "and under the menu bar")
    }

    // ── What a window is ────────────────────────────────────────────────────

    func testAWindowIsBlackOpaqueAndClickThroughOnEverySpaceAndNeverKeyOrMain() {
        _ = NSApplication.shared
        let window = UltraBackdropWindow(frame: main)
        XCTAssertEqual(window.frame, main)
        XCTAssertEqual(window.backgroundColor, NSColor.black)
        XCTAssertTrue(window.isOpaque)
        XCTAssertTrue(window.ignoresMouseEvents, "a click goes through to the desktop and to the app behind it")
        XCTAssertFalse(window.hasShadow)
        XCTAssertFalse(window.isReleasedWhenClosed, "the backdrop closes it and lets it go itself")
        XCTAssertEqual(window.level, LiveUltraBackdrop.level)
        XCTAssertEqual(window.collectionBehavior, [.canJoinAllSpaces, .stationary, .ignoresCycle])
        XCTAssertEqual(window.styleMask, .borderless)
        XCTAssertEqual(window.identifier?.rawValue, "dev.anode.ultraBackdrop")
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertTrue(window.isExcludedFromWindowsMenu)
        XCTAssertFalse(window.isVisible, "this test never shows it")
    }

    // ── Showing and hiding ──────────────────────────────────────────────────

    func testShowMakesOneWindowPerScreenAndPutsEachOnScreen() {
        let r = Rig(screens: [main, side])
        XCTAssertTrue(r.backdrop.windows.isEmpty, "nothing until it is asked for")
        r.backdrop.show()
        XCTAssertEqual(r.backdrop.windows.map(\.frame), [main, side])
        XCTAssertEqual(r.presented, [main, side])
        XCTAssertEqual(r.dismissed, [])
    }

    func testShowingTwiceIsOneShow() {
        let r = Rig(screens: [main, side])
        r.backdrop.show()
        let first = r.backdrop.windows
        r.backdrop.show()
        XCTAssertEqual(r.presented, [main, side], "not a second set on top of the first")
        XCTAssertEqual(r.dismissed, [])
        XCTAssertTrue(zip(first, r.backdrop.windows).allSatisfy { $0 === $1 }, "the same windows")
        r.screensChanged()
        XCTAssertEqual(r.presented.count, 4, "one rebuild after the screens change, and only one observer to cause it")
    }

    func testHideClosesTheWindowsAndHidingAgainDoesNothing() {
        let r = Rig(screens: [main, side])
        r.backdrop.show()
        r.backdrop.hide()
        XCTAssertEqual(r.dismissed, [main, side])
        XCTAssertTrue(r.backdrop.windows.isEmpty)
        r.backdrop.hide()
        XCTAssertEqual(r.dismissed, [main, side], "nothing more to close")
    }

    func testHidingWhatWasNeverShownDoesNothing() {
        let r = Rig(screens: [main])
        r.backdrop.hide()
        XCTAssertEqual(r.dismissed, [])
        XCTAssertEqual(r.presented, [])
        // And it can still be shown afterwards.
        r.backdrop.show()
        XCTAssertEqual(r.presented, [main])
    }

    func testItCanBeShownAgainAfterItWasHidden() {
        let r = Rig(screens: [main])
        r.backdrop.show()
        r.backdrop.hide()
        r.backdrop.show()
        XCTAssertEqual(r.presented, [main, main])
        XCTAssertEqual(r.backdrop.windows.count, 1)
    }

    // ── Displays that change ────────────────────────────────────────────────

    func testItIsRebuiltForTheScreensThereAreWhenTheyChange() {
        let r = Rig(screens: [main])
        r.backdrop.show()
        r.screens = [main, side]
        r.screensChanged()
        XCTAssertEqual(r.dismissed, [main], "the old set is closed")
        XCTAssertEqual(r.presented, [main, main, side], "and one for each screen there is now")
        XCTAssertEqual(r.backdrop.windows.map(\.frame), [main, side])
        r.screens = [side]
        r.screensChanged()
        XCTAssertEqual(r.backdrop.windows.map(\.frame), [side], "an unplugged display loses its window")
    }

    func testAChangeOfScreensWhileHiddenDoesNothingAndHidingLetsGoOfTheNotice() {
        let r = Rig(screens: [main])
        r.screensChanged()
        XCTAssertEqual(r.presented, [], "never shown: nothing to rebuild")
        r.backdrop.show()
        r.backdrop.hide()
        r.screens = [main, side]
        r.screensChanged()
        XCTAssertEqual(r.presented, [main], "hidden: the notice is not listened to any more")
        XCTAssertEqual(r.dismissed, [main])
        XCTAssertTrue(r.backdrop.windows.isEmpty)
    }
}

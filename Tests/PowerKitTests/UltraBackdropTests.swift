import XCTest
import AppKit
@testable import AnodeApp

/// The black backdrop of Ultra Low Power Mode: where it sits, what its windows are, and when they are made and taken away.
/// No window is ever put on screen: what the backdrop shows and closes is written down instead, over screens and a
/// notification center of the test's own.
final class UltraBackdropTests: XCTestCase {

    private typealias Screen = LiveUltraBackdrop.Screen

    /// A 14-inch MacBook Pro's screen with its menu bar (37 pt), and a display beside it with a 24 pt bar.
    private let main = Screen(frame: NSRect(x: 0, y: 0, width: 1800, height: 1169), menuBarHeight: 37)
    private let side = Screen(frame: NSRect(x: 1800, y: -100, width: 1920, height: 1080), menuBarHeight: 24)
    /// What a window of each is: the screen's frame without the strip at the top, where the menu bar is.
    private let mainWindow = NSRect(x: 0, y: 0, width: 1800, height: 1132)
    private let sideWindow = NSRect(x: 1800, y: -100, width: 1920, height: 1056)

    /// What the backdrop was told to put on screen and to take away, and the screens it is told about.
    private final class Rig {
        let center = NotificationCenter()
        var screens: [Screen]
        private(set) var presented: [NSRect] = []
        private(set) var dismissed: [NSRect] = []
        private(set) var backdrop: LiveUltraBackdrop!

        init(screens: [Screen]) {
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

    /// One window per screen, the screen's whole frame except the strip at its top where the menu bar is (the top of a screen is
    /// its highest y). macOS picks the menu bar's text colour from the real picture behind it, so the picture is left there.
    func testAFrameIsTheScreensFrameWithoutExactlyTheMenuBarStrip() {
        XCTAssertEqual(LiveUltraBackdrop.frames(for: [main, side]), [mainWindow, sideWindow])
        XCTAssertEqual(LiveUltraBackdrop.frames(for: [main]), [mainWindow])
        XCTAssertEqual(LiveUltraBackdrop.frames(for: []), [])
        // The strip is at the top: the bottom edge and both sides stay where the screen's are.
        let frame = LiveUltraBackdrop.frames(for: [main])[0]
        XCTAssertEqual(frame.minX, 0)
        XCTAssertEqual(frame.minY, 0)
        XCTAssertEqual(frame.maxX, 1800)
        XCTAssertEqual(frame.maxY, 1169 - 37)
        // A screen to the left of the main one has a frame that begins below zero: it is the screen's, as it is.
        let left = Screen(frame: NSRect(x: -1440, y: 120, width: 1440, height: 900), menuBarHeight: 25)
        XCTAssertEqual(LiveUltraBackdrop.frames(for: [left]), [NSRect(x: -1440, y: 120, width: 1440, height: 875)])
    }

    /// A screen with no menu bar strip (a bar that hides itself, a display that has none) gets its whole frame.
    func testAScreenWithNoMenuBarStripGetsItsWholeFrame() {
        let bare = Screen(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080), menuBarHeight: 0)
        XCTAssertEqual(LiveUltraBackdrop.frames(for: [bare]), [bare.frame])
        XCTAssertEqual(LiveUltraBackdrop.frames(for: [bare, main]), [bare.frame, mainWindow])
    }

    /// A strip that is not a strip (negative, or taller than the screen) never makes a frame that is not on the screen.
    func testAStripThatMakesNoSenseNeverMakesAFrameOutsideTheScreen() {
        let odd = NSRect(x: 0, y: 0, width: 1000, height: 600)
        XCTAssertEqual(LiveUltraBackdrop.frames(for: [Screen(frame: odd, menuBarHeight: -20)]), [odd])
        XCTAssertEqual(LiveUltraBackdrop.frames(for: [Screen(frame: odd, menuBarHeight: 9_999)]), [NSRect(x: 0, y: 0, width: 1000, height: 0)])
    }

    /// The menu bar's height is what the visible frame gives up at the TOP of the frame. The Dock takes the bottom, the left or the
    /// right, and none of that is the strip.
    func testTheMenuBarHeightIsWhatTheVisibleFrameGivesUpAtTheTopAndNothingTheDockTakes() {
        let frame = NSRect(x: 0, y: 0, width: 1800, height: 1169)
        XCTAssertEqual(LiveUltraBackdrop.menuBarHeight(frame: frame, visibleFrame: NSRect(x: 0, y: 0, width: 1800, height: 1132)), 37)
        // The Dock at the bottom, on the left and on the right.
        XCTAssertEqual(LiveUltraBackdrop.menuBarHeight(frame: frame, visibleFrame: NSRect(x: 0, y: 70, width: 1800, height: 1062)), 37)
        XCTAssertEqual(LiveUltraBackdrop.menuBarHeight(frame: frame, visibleFrame: NSRect(x: 64, y: 0, width: 1736, height: 1132)), 37)
        XCTAssertEqual(LiveUltraBackdrop.menuBarHeight(frame: frame, visibleFrame: NSRect(x: 0, y: 0, width: 1736, height: 1132)), 37)
        // No bar: the visible frame reaches the top (and the Dock still takes the bottom).
        XCTAssertEqual(LiveUltraBackdrop.menuBarHeight(frame: frame, visibleFrame: NSRect(x: 0, y: 70, width: 1800, height: 1099)), 0)
        // A screen that is not at the origin.
        let side = NSRect(x: 1800, y: -100, width: 1920, height: 1080)
        XCTAssertEqual(LiveUltraBackdrop.menuBarHeight(frame: side, visibleFrame: NSRect(x: 1800, y: -100, width: 1920, height: 1056)), 24)
        // A visible frame that reaches past the frame's top is no strip.
        XCTAssertEqual(LiveUltraBackdrop.menuBarHeight(frame: frame, visibleFrame: NSRect(x: 0, y: 0, width: 1800, height: 1200)), 0)
    }

    /// Over the desktop picture, the icons and the widgets, which all sit far below, and one under every ordinary window: so the
    /// windows of the apps the owner uses are over it, and nothing of the desktop is.
    func testTheLevelIsOneUnderOrdinaryWindowsAndAboveTheDesktop() {
        XCTAssertEqual(LiveUltraBackdrop.level.rawValue, NSWindow.Level.normal.rawValue - 1)
        XCTAssertLessThan(LiveUltraBackdrop.level.rawValue, NSWindow.Level.normal.rawValue, "under every app window")
        XCTAssertGreaterThan(LiveUltraBackdrop.level.rawValue, Int(CGWindowLevelForKey(.desktopIconWindow)), "over the desktop icons")
        XCTAssertGreaterThan(LiveUltraBackdrop.level.rawValue, DesktopWallpaperWindow.level().rawValue,
                             "over the live wallpaper's window and the system's own picture")
        XCTAssertGreaterThan(LiveUltraBackdrop.level.rawValue, Int(CGWindowLevelForKey(.desktopIconWindow)) + 2,
                             "over the desktop widgets, which the trial measured two above the icons")
        XCTAssertLessThan(LiveUltraBackdrop.level.rawValue, NSWindow.Level.floating.rawValue)
        XCTAssertLessThan(LiveUltraBackdrop.level.rawValue, NSWindow.Level.mainMenu.rawValue, "and under the menu bar")
    }

    // ── What a window is ────────────────────────────────────────────────────

    func testAWindowIsBlackOpaqueAndClickThroughOnEverySpaceAndNeverKeyOrMain() {
        _ = NSApplication.shared
        let window = UltraBackdropWindow(frame: mainWindow)
        XCTAssertEqual(window.frame, mainWindow)
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
        XCTAssertEqual(r.backdrop.windows.map(\.frame), [mainWindow, sideWindow])
        XCTAssertEqual(r.presented, [mainWindow, sideWindow])
        XCTAssertEqual(r.dismissed, [])
    }

    func testShowingTwiceIsOneShow() {
        let r = Rig(screens: [main, side])
        r.backdrop.show()
        let first = r.backdrop.windows
        r.backdrop.show()
        XCTAssertEqual(r.presented, [mainWindow, sideWindow], "not a second set on top of the first")
        XCTAssertEqual(r.dismissed, [])
        XCTAssertTrue(zip(first, r.backdrop.windows).allSatisfy { $0 === $1 }, "the same windows")
        r.screensChanged()
        XCTAssertEqual(r.presented.count, 4, "one rebuild after the screens change, and only one observer to cause it")
    }

    func testHideClosesTheWindowsAndHidingAgainDoesNothing() {
        let r = Rig(screens: [main, side])
        r.backdrop.show()
        r.backdrop.hide()
        XCTAssertEqual(r.dismissed, [mainWindow, sideWindow])
        XCTAssertTrue(r.backdrop.windows.isEmpty)
        r.backdrop.hide()
        XCTAssertEqual(r.dismissed, [mainWindow, sideWindow], "nothing more to close")
    }

    func testHidingWhatWasNeverShownDoesNothing() {
        let r = Rig(screens: [main])
        r.backdrop.hide()
        XCTAssertEqual(r.dismissed, [])
        XCTAssertEqual(r.presented, [])
        // And it can still be shown afterwards.
        r.backdrop.show()
        XCTAssertEqual(r.presented, [mainWindow])
    }

    func testItCanBeShownAgainAfterItWasHidden() {
        let r = Rig(screens: [main])
        r.backdrop.show()
        r.backdrop.hide()
        r.backdrop.show()
        XCTAssertEqual(r.presented, [mainWindow, mainWindow])
        XCTAssertEqual(r.backdrop.windows.count, 1)
    }

    // ── Displays that change ────────────────────────────────────────────────

    func testItIsRebuiltForTheScreensThereAreWhenTheyChange() {
        let r = Rig(screens: [main])
        r.backdrop.show()
        r.screens = [main, side]
        r.screensChanged()
        XCTAssertEqual(r.dismissed, [mainWindow], "the old set is closed")
        XCTAssertEqual(r.presented, [mainWindow, mainWindow, sideWindow], "and one for each screen there is now")
        XCTAssertEqual(r.backdrop.windows.map(\.frame), [mainWindow, sideWindow])
        r.screens = [side]
        r.screensChanged()
        XCTAssertEqual(r.backdrop.windows.map(\.frame), [sideWindow], "an unplugged display loses its window")
    }

    /// The strip is read again with the screens: a bar that goes (or comes back) changes the windows too.
    func testTheMenuBarStripIsReadAgainWhenTheScreensChange() {
        let r = Rig(screens: [main])
        r.backdrop.show()
        r.screens = [Screen(frame: main.frame, menuBarHeight: 0)]
        r.screensChanged()
        XCTAssertEqual(r.backdrop.windows.map(\.frame), [main.frame])
        r.screens = [main]
        r.screensChanged()
        XCTAssertEqual(r.backdrop.windows.map(\.frame), [mainWindow])
    }

    func testAChangeOfScreensWhileHiddenDoesNothingAndHidingLetsGoOfTheNotice() {
        let r = Rig(screens: [main])
        r.screensChanged()
        XCTAssertEqual(r.presented, [], "never shown: nothing to rebuild")
        r.backdrop.show()
        r.backdrop.hide()
        r.screens = [main, side]
        r.screensChanged()
        XCTAssertEqual(r.presented, [mainWindow], "hidden: the notice is not listened to any more")
        XCTAssertEqual(r.dismissed, [mainWindow])
        XCTAssertTrue(r.backdrop.windows.isEmpty)
    }
}

/// How often the backdrop that follows the windows looks at them: once a second, and while Ultra Low Power Mode is on every five
/// seconds. Slowed, not stopped: it is what notices a window going under the menu bar, and a stale strip can make it unreadable.
final class MenuBarBackdropPollingTests: XCTestCase {

    func testTheBackdropLooksOnceASecondNormally() {
        let normal = MenuBarBackdropPolling.interval(ultraOn: false)
        XCTAssertEqual(normal.seconds, 1)
        XCTAssertEqual(normal.tolerance, 0.5)
    }

    func testWhileTheModeIsOnItLooksEveryFiveSecondsWithHalfThatToSpare() {
        let slowed = MenuBarBackdropPolling.interval(ultraOn: true)
        XCTAssertEqual(slowed.seconds, 5)
        XCTAssertEqual(slowed.tolerance, 2.5)
    }

    func testItIsNeverStopped() {
        for on in [false, true] { XCTAssertGreaterThan(MenuBarBackdropPolling.interval(ultraOn: on).seconds, 0) }
    }
}

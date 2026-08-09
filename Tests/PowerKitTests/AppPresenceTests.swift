import AppKit
import XCTest
@testable import BetterStatsApp

/// The rule that keeps BetterStats reachable.
///
/// `MainWindowController.hide()` drops the app to `.accessory`, which removes the
/// Dock tile AND the application menu — `AppMenu.showMainWindow` documents that
/// even ⌘0 cannot get the window back from there. That is fine while a menu bar
/// widget exists to click and it is a dead end the moment one does not: no tile,
/// no menu, no Quit, nothing on screen, and a process still sampling. These are
/// the only two functions that can produce that state, so the state is asserted
/// unreachable here rather than left to a reading of the launch path.
///
/// Pure by construction: `NSApplication.ActivationPolicy` is an enum, so none of
/// this needs a running app.
final class AppPresenceTests: XCTestCase {

    // ── Launch ──────────────────────────────────────────────────────────────

    func testTheDefaultLaunchShowsTheWindow() {
        XCTAssertTrue(AppPresence.showsWindowAtLaunch(startInMenuBarOnly: false,
                                                      widgetsEnabled: true))
        XCTAssertEqual(AppPresence.launchActivationPolicy(startInMenuBarOnly: false,
                                                          widgetsEnabled: true), .regular)
    }

    func testMenuBarOnlyLaunchesWithNoWindowAndNoDockTile() {
        XCTAssertFalse(AppPresence.showsWindowAtLaunch(startInMenuBarOnly: true,
                                                       widgetsEnabled: true))
        XCTAssertEqual(AppPresence.launchActivationPolicy(startInMenuBarOnly: true,
                                                          widgetsEnabled: true), .accessory)
    }

    /// THE TRAP. Menu-bar-only plus no menu bar is an app with no surface at all,
    /// so the window wins and the request is overridden rather than obeyed.
    func testMenuBarOnlyIsOverriddenWhenThereIsNoMenuBar() {
        XCTAssertTrue(AppPresence.showsWindowAtLaunch(startInMenuBarOnly: true,
                                                      widgetsEnabled: false),
                      "no window and no widgets is an app the user cannot reach or quit")
        XCTAssertEqual(AppPresence.launchActivationPolicy(startInMenuBarOnly: true,
                                                          widgetsEnabled: false), .regular)
    }

    func testWidgetsOffAloneStillLaunchesNormally() {
        XCTAssertTrue(AppPresence.showsWindowAtLaunch(startInMenuBarOnly: false,
                                                      widgetsEnabled: false))
    }

    // ── Window closed ───────────────────────────────────────────────────────

    /// The existing behaviour, unchanged: a closed window with widgets up means
    /// the app is a menu bar tool and has no business holding a Dock tile.
    func testClosingTheWindowDropsTheDockTileWhileWidgetsAreUp() {
        XCTAssertEqual(AppPresence.policyWithWindowHidden(widgetsEnabled: true), .accessory)
    }

    /// With no widgets the Dock tile is the last way back to the window, so it
    /// stays — clicking it reaches `applicationShouldHandleReopen`.
    func testClosingTheWindowKeepsTheDockTileWhenThereAreNoWidgets() {
        XCTAssertEqual(AppPresence.policyWithWindowHidden(widgetsEnabled: false), .regular,
                       "the tile is the only affordance left once the widgets are gone")
    }

    /// Stated as one property over the whole input space rather than as four
    /// examples: for every combination, something is clickable.
    func testSomethingIsAlwaysClickableForEveryCombinationOfSettings() {
        for menuBarOnly in [false, true] {
            for widgets in [false, true] {
                let windowShown = AppPresence.showsWindowAtLaunch(
                    startInMenuBarOnly: menuBarOnly, widgetsEnabled: widgets)
                let hiddenPolicy = AppPresence.policyWithWindowHidden(widgetsEnabled: widgets)
                XCTAssertTrue(windowShown || widgets,
                              "launch(menuBarOnly: \(menuBarOnly), widgets: \(widgets)) "
                              + "leaves nothing on screen")
                XCTAssertTrue(widgets || hiddenPolicy == .regular,
                              "window closed with widgets: \(widgets) leaves no way back")
            }
        }
    }
}

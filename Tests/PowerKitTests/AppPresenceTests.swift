import AppKit
import XCTest
@testable import AnodeApp
import PowerKit

/// The rule that keeps Anode reachable.
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
                                                       widgetsEnabled: true,
                                                       openedAtLogin: true))
        XCTAssertEqual(AppPresence.launchActivationPolicy(startInMenuBarOnly: true,
                                                          widgetsEnabled: true,
                                                          openedAtLogin: true), .accessory)
    }

    /// THE SETTING IS ABOUT STARTING, NOT ABOUT OPENING.
    ///
    /// "Start in menu bar only" was applied to every launch, so double-clicking
    /// the app put nothing on screen — from the user's side, indistinguishable
    /// from a launch that failed. Starting is what a machine does at login;
    /// opening is what a person does on purpose, and a person who just opened an
    /// app is asking to see it.
    func testOpeningTheAppByHandAlwaysShowsTheWindow() {
        XCTAssertTrue(AppPresence.showsWindowAtLaunch(startInMenuBarOnly: true,
                                                      widgetsEnabled: true,
                                                      openedAtLogin: false),
                      "double-clicking the app did nothing visible")
        XCTAssertEqual(AppPresence.launchActivationPolicy(startInMenuBarOnly: true,
                                                          widgetsEnabled: true,
                                                          openedAtLogin: false), .regular)
    }

    /// The default when the origin is unknown is to SHOW.
    ///
    /// Only the login agent's own plist carries the marker, so anything else —
    /// a double-click, `open`, a launch by `SMAppService`, a debugger — reads as
    /// opened by hand. That last one is a genuine miss: `SMAppService` starts the
    /// app through LaunchServices, so its login launch cannot be told from a
    /// double-click, and such a user gets a window they asked not to have.
    ///
    /// That is the right way round. An unwanted window is visible and one click
    /// from gone; a launch that appears to do nothing teaches people the app is
    /// broken, and they cannot tell it apart from a crash.
    func testAnUnknownOriginShowsTheWindow() {
        XCTAssertTrue(AppPresence.showsWindowAtLaunch(startInMenuBarOnly: true,
                                                      widgetsEnabled: true,
                                                      openedAtLogin: false))
    }

    /// The marker is only ever set by the agent we write ourselves.
    func testTheLoginMarkerIsReadFromOurOwnArguments() {
        // The running test process was not started by the agent.
        XCTAssertFalse(AppPresence.openedAtLogin)
        XCTAssertFalse(CommandLine.arguments.contains(LoginAgent.loginArgument))
        // And it is a flag, not something a user could type by accident.
        XCTAssertTrue(LoginAgent.loginArgument.hasPrefix("--"))
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

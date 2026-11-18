import XCTest
@testable import PowerKit
@testable import AnodeApp

/// macOS 27.3's privacy indicator says "Accessing all apps" for an app that holds an event tap (see `PrivacyIndicatorNote`), and an
/// active tap sits in the path of every key press until its callback returns. The shared shortcut tap therefore runs only while there
/// is a shortcut to listen for: a feature registered with every one of its shortcuts cleared needs no tap at all.
final class ShortcutTapNeededTests: XCTestCase {

    func testTheTapIsNotNeededWhenNoShortcutIsSet() {
        let none: [Shortcut: String] = [:]
        XCTAssertFalse(KeybindCenter.needsTap(table: none, recording: false))
    }

    func testTheTapIsNeededWhileAnyShortcutIsSet() {
        let one = [Shortcut(key: 40, flags: .maskControl): "x"]
        XCTAssertTrue(KeybindCenter.needsTap(table: one, recording: false))
    }

    func testTheTapIsNeededWhileAShortcutIsBeingRecordedEvenWithNoneSet() {
        let none: [Shortcut: String] = [:]
        XCTAssertTrue(KeybindCenter.needsTap(table: none, recording: true))
    }

    func testEveryDefaultShortcutKeepsTheTapRunningSoNothingChangesForAFreshInstall() {
        // Each feature that registers a shortcut ships a default one: with the defaults the table is never empty.
        let store = ShortcutStore(defaults: VolatileDefaults.named("ShortcutTapNeededTests"))
        for commands in [ShortcutCommands.window, ShortcutCommands.groups, ShortcutCommands.wallpaper, ShortcutCommands.hider,
                         ShortcutCommands.ultra] {
            XCTAssertTrue(KeybindCenter.needsTap(table: store.table(for: commands), recording: false))
        }
        VolatileDefaults.forget("ShortcutTapNeededTests")
    }
}

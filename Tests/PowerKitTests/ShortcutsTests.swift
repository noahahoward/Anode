import XCTest
import AppKit
import Carbon.HIToolbox
@testable import AnodeApp

final class ShortcutsTests: XCTestCase {
    private func store() -> ShortcutStore {
        ShortcutStore(defaults: UserDefaults(suiteName: "shortcuts-\(UUID().uuidString)")!)
    }
    private let left = WindowAction.leftHalf.command, right = WindowAction.rightHalf.command, top = WindowAction.topHalf.command
    private let all = ShortcutCommands.all

    // ── The shortcut itself ──

    func testLabelsAreWrittenTheWayMacOSWritesThem() {
        XCTAssertEqual(Shortcut(key: kVK_LeftArrow, modifiers: Shortcut.control | Shortcut.option).label, "⌃⌥←")
        XCTAssertEqual(Shortcut(key: kVK_ANSI_G, modifiers: Shortcut.control | Shortcut.option | Shortcut.command).label, "⌃⌥⌘G")
        XCTAssertEqual(Shortcut(key: kVK_UpArrow, modifiers: Shortcut.control | Shortcut.option | Shortcut.shift).label, "⌃⌥⇧↑")
        XCTAssertEqual(Shortcut(key: kVK_Return, modifiers: Shortcut.command).label, "⌘↩")
        XCTAssertEqual(WindowAction.leftHalf.defaultShortcut.label, "⌃⌥←")
    }

    func testMatchingIsExactAboutModifiersAndIgnoresCapsLockFnAndTheArrowFlags() {
        let s = Shortcut(key: kVK_LeftArrow, modifiers: Shortcut.control | Shortcut.option)
        let flags: CGEventFlags = [.maskControl, .maskAlternate]
        XCTAssertTrue(s.matches(key: kVK_LeftArrow, flags: flags))
        XCTAssertTrue(s.matches(key: kVK_LeftArrow, flags: flags.union([.maskSecondaryFn, .maskNumericPad, .maskAlphaShift])),
                      "the flags a real arrow key carries are not modifiers")
        XCTAssertFalse(s.matches(key: kVK_LeftArrow, flags: flags.union(.maskShift)), "Shift added: a different shortcut")
        XCTAssertFalse(s.matches(key: kVK_LeftArrow, flags: [.maskControl]))
        XCTAssertFalse(s.matches(key: kVK_RightArrow, flags: flags))
    }

    func testABareKeyIsNotUsableButAFunctionKeyIs() {
        XCTAssertFalse(Shortcut(key: kVK_ANSI_A, modifiers: 0).isUsable, "it would swallow typing")
        XCTAssertTrue(Shortcut(key: kVK_ANSI_A, modifiers: Shortcut.command).isUsable)
        XCTAssertTrue(Shortcut(key: kVK_F5, modifiers: 0).isUsable)
    }

    func testCarbonDefaultsConvertToOurBits() {
        let s = Shortcut(key: kVK_ANSI_G, carbon: controlKey | optionKey | cmdKey | shiftKey)
        XCTAssertEqual(s.modifiers, Shortcut.control | Shortcut.option | Shortcut.command | Shortcut.shift)
    }

    // ── The store ──

    func testEveryCommandStartsOnItsDefaultAndTheDefaultsDoNotClash() {
        let s = store()
        for c in all { XCTAssertEqual(s.shortcut(for: c), c.defaultShortcut) }
        XCTAssertEqual(s.table(for: all).count, all.count, "no two commands share a default")
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
    }

    func testChoosingAShortcutReplacesTheDefaultAndPersists() {
        let defaults = UserDefaults(suiteName: "shortcuts-\(UUID().uuidString)")!
        let s = ShortcutStore(defaults: defaults)
        let mine = Shortcut(key: kVK_ANSI_J, modifiers: Shortcut.control | Shortcut.command)
        XCTAssertNil(s.assign(mine, to: left, among: all))
        XCTAssertEqual(s.shortcut(for: left), mine)
        XCTAssertTrue(s.isChanged(left))
        XCTAssertEqual(ShortcutStore(defaults: defaults).shortcut(for: left), mine, "it survives a relaunch")
        s.reset(left)
        XCTAssertEqual(s.shortcut(for: left), left.defaultShortcut)
        XCTAssertFalse(ShortcutStore(defaults: defaults).isChanged(left))
    }

    func testClearingLeavesACommandWithNoShortcutAndThatIsRemembered() {
        let defaults = UserDefaults(suiteName: "shortcuts-\(UUID().uuidString)")!
        let s = ShortcutStore(defaults: defaults)
        s.assign(nil, to: left, among: all)
        XCTAssertNil(s.shortcut(for: left))
        XCTAssertNil(ShortcutStore(defaults: defaults).shortcut(for: left), "a cleared shortcut does not come back as the default")
        XCTAssertFalse(s.table(for: all).values.contains(left.id))
    }

    /// One key combination, one command: the one that had it loses it, and is told.
    func testTakingAnotherCommandsShortcutMovesIt() {
        let s = store()
        let stolen = s.assign(right.defaultShortcut, to: left, among: all)
        XCTAssertEqual(stolen, right)
        XCTAssertEqual(s.shortcut(for: left), right.defaultShortcut)
        XCTAssertNil(s.shortcut(for: right), "the old owner has none now, rather than both firing")
        XCTAssertEqual(s.table(for: all)[right.defaultShortcut], left.id)
    }

    func testPuttingTheDefaultBackIsNotACustomisation() {
        let s = store()
        s.assign(Shortcut(key: kVK_ANSI_J, modifiers: Shortcut.command), to: top, among: all)
        s.assign(top.defaultShortcut, to: top, among: all)
        XCTAssertFalse(s.isChanged(top))
    }

    func testResetAllRestoresEverything() {
        let s = store()
        s.assign(nil, to: left, among: all)
        s.assign(Shortcut(key: kVK_ANSI_J, modifiers: Shortcut.command), to: top, among: all)
        s.resetAll()
        for c in all { XCTAssertEqual(s.shortcut(for: c), c.defaultShortcut) }
    }

    func testChangesAreAnnounced() {
        let s = store()
        let e = expectation(forNotification: ShortcutStore.didChange, object: s)
        s.assign(nil, to: left, among: all)
        wait(for: [e], timeout: 1)
    }

    // ── What the tap looks up ──

    func testALookupFindsTheCommandForExactlyThatCombination() {
        let table = store().table(for: all)
        XCTAssertEqual(KeybindCenter.lookup(table, key: kVK_LeftArrow, flags: [.maskControl, .maskAlternate, .maskSecondaryFn, .maskNumericPad]),
                       left.id)
        XCTAssertNil(KeybindCenter.lookup(table, key: kVK_LeftArrow, flags: [.maskControl]), "Control-Left is macOS's, not ours")
        XCTAssertNil(KeybindCenter.lookup(table, key: kVK_ANSI_Q, flags: [.maskCommand]))
    }

    // ── macOS's own shortcuts ──

    func testAChoiceThatReplacesAMacOSShortcutIsNamed() {
        // ⌃→ is "move right a space" (id 81): key 124, Control = 0x40000.
        let hotKeys: [String: Any] = [
            "81": ["enabled": true, "value": ["parameters": [65535, 124, 0x40000], "type": "standard"]],
            "79": ["enabled": false, "value": ["parameters": [65535, 123, 0x40000], "type": "standard"]],
            "64": ["enabled": 1, "value": ["parameters": [32, 49, 0x100000], "type": "standard"]],
        ]
        XCTAssertEqual(SystemShortcuts.clash(for: Shortcut(key: kVK_RightArrow, modifiers: Shortcut.control), hotKeys: hotKeys),
                       "Move right a space")
        XCTAssertNil(SystemShortcuts.clash(for: Shortcut(key: kVK_LeftArrow, modifiers: Shortcut.control), hotKeys: hotKeys),
                     "that one is switched off")
        XCTAssertEqual(SystemShortcuts.clash(for: Shortcut(key: kVK_Space, modifiers: Shortcut.command), hotKeys: hotKeys), "Spotlight search")
        XCTAssertNil(SystemShortcuts.clash(for: WindowAction.leftHalf.defaultShortcut, hotKeys: hotKeys))
        XCTAssertNil(SystemShortcuts.clash(for: Shortcut(key: kVK_ANSI_A, modifiers: 1), hotKeys: nil))
    }

    // ── The window ──

    func testTheWindowShowsTheSelectedCommandsShortcutAndOffersTheRest() {
        _ = NSApplication.shared
        let s = store()
        s.assign(Shortcut(key: kVK_ANSI_J, modifiers: Shortcut.control | Shortcut.command), to: left, among: all)
        let c = ShortcutsWindowController(store: s, prefs: WindowPrefs(defaults: UserDefaults(suiteName: "t-\(UUID())")!), commands: all)
        func buttons(_ v: NSView) -> [NSButton] { ([v as? NSButton].compactMap { $0 }) + v.subviews.flatMap(buttons) }
        XCTAssertEqual(c.selectedID, all.first?.id, "the first command is shown")
        var titles = buttons(c.window!.contentView!).map(\.title)
        XCTAssertTrue(titles.contains("⌃⌘J"), "the changed shortcut shows")
        XCTAssertTrue(titles.contains("Clear"))
        XCTAssertTrue(titles.contains("Reset all to defaults"))
        c.select(commandID: WindowAction.rightHalf.commandID)
        titles = buttons(c.window!.contentView!).map(\.title)
        XCTAssertTrue(titles.contains("⌃⌥→"), "another command shows its default")
        XCTAssertFalse(titles.contains("⌃⌘J"))
        c.select(commandID: "options")
        XCTAssertEqual(c.selectedID, "options")
    }
}

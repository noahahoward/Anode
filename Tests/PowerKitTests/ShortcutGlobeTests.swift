import CoreGraphics
import XCTest
import Carbon.HIToolbox
@testable import AnodeApp

/// The Globe (fn) key as a shortcut modifier, which Clipboard History's Globe + Space needs.
///
/// The fn flag is not a clean modifier: the arrow keys, Home, End, Page Up and Down, Forward Delete, Help and the function keys
/// all carry it on every press, whether or not Globe is held. So it counts on every other key, and on those it is ignored, which
/// is also what keeps Control-Option-Left what it always was.
final class ShortcutGlobeTests: XCTestCase {

    private let all = ShortcutCommands.all

    // ── The command and its default ─────────────────────────────────────────

    /// Open Clipboard History is Globe + Space, in a section of its own, and is one of the commands the Shortcuts window lists.
    func testClipboardOpenIsGlobeSpaceAndIsInTheList() {
        let command = ShortcutCommands.clipboardOpen
        XCTAssertEqual(command.defaultShortcut.label, "\u{1F310}Space")
        XCTAssertEqual(command.defaultShortcut.key, kVK_Space)
        XCTAssertEqual(command.defaultShortcut.modifiers, Shortcut.function)
        XCTAssertEqual(command.id, "clipboard.open")
        XCTAssertEqual(command.section, "Clipboard History")
        XCTAssertEqual(ShortcutCommands.clipboard.map(\.id), ["clipboard.open"])
        XCTAssertTrue(all.contains(command))
        XCTAssertTrue(command.defaultShortcut.isUsable, "a modifier is held, so it would not swallow typing")
    }

    /// One key combination, one command: the new default is nobody else's, and every command still starts on its own.
    func testTheNewDefaultIsDistinctFromEveryOtherDefault() {
        XCTAssertEqual(Set(all.map { $0.defaultShortcut }).count, all.count, "every default shortcut is distinct")
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        let others = all.filter { $0.id != "clipboard.open" }
        XCTAssertFalse(others.contains { $0.defaultShortcut == ShortcutCommands.clipboardOpen.defaultShortcut })
        let store = ShortcutStore(defaults: TestDefaults.throwaway("globe-defaults"))
        XCTAssertEqual(store.shortcut(for: ShortcutCommands.clipboardOpen), ShortcutCommands.clipboardOpen.defaultShortcut)
        XCTAssertEqual(store.table(for: all)[ShortcutCommands.clipboardOpen.defaultShortcut], "clipboard.open")
        XCTAssertEqual(store.table(for: all).count, all.count)
    }

    /// The bit is Globe's own and does not overlap the four that were there.
    func testTheGlobeBitIsItsOwn() {
        XCTAssertEqual(Shortcut.function, 16)
        XCTAssertEqual([Shortcut.control, Shortcut.option, Shortcut.command, Shortcut.shift, Shortcut.function].reduce(0, |), 31)
    }

    // ── Matching ────────────────────────────────────────────────────────────

    /// What the tap sees when Globe + Space is pressed is exactly the default: the same shortcut, and a match.
    func testGlobePlusSpaceFromAnEventIsTheDefaultAndMatches() {
        let pressed = Shortcut(key: kVK_Space, flags: [.maskSecondaryFn])
        XCTAssertEqual(pressed, ShortcutCommands.clipboardOpen.defaultShortcut)
        XCTAssertEqual(pressed.modifiers, Shortcut.function)
        let command = ShortcutCommands.clipboardOpen.defaultShortcut
        XCTAssertTrue(command.matches(key: kVK_Space, flags: [.maskSecondaryFn]))
        XCTAssertTrue(command.matches(key: kVK_Space, flags: [.maskSecondaryFn, .maskAlphaShift]), "caps lock is not a modifier")
    }

    /// Space alone is typing: with no Globe it does not match, and neither does Globe with something else added.
    func testSpaceWithoutGlobeDoesNotMatch() {
        let command = ShortcutCommands.clipboardOpen.defaultShortcut
        XCTAssertFalse(command.matches(key: kVK_Space, flags: []))
        XCTAssertFalse(command.matches(key: kVK_Space, flags: [.maskAlphaShift]))
        XCTAssertFalse(command.matches(key: kVK_Space, flags: [.maskCommand]))
        XCTAssertFalse(command.matches(key: kVK_Space, flags: [.maskSecondaryFn, .maskCommand]), "exactly Globe, as for every shortcut")
        XCTAssertFalse(command.matches(key: kVK_Space, flags: [.maskSecondaryFn, .maskShift]))
        XCTAssertFalse(command.matches(key: kVK_Return, flags: [.maskSecondaryFn]))
        XCTAssertNotEqual(Shortcut(key: kVK_Space, flags: []), command)
    }

    /// The tap looks a key press up in the table of every registered shortcut: Globe + Space finds the command, Space does not.
    func testTheTablesLookupFindsTheCommandOnlyWithGlobeHeld() {
        let table = ShortcutStore(defaults: TestDefaults.throwaway("globe-lookup")).table(for: all)
        XCTAssertEqual(KeybindCenter.lookup(table, key: kVK_Space, flags: [.maskSecondaryFn]), "clipboard.open")
        XCTAssertNil(KeybindCenter.lookup(table, key: kVK_Space, flags: []))
        XCTAssertNil(KeybindCenter.lookup(table, key: kVK_Space, flags: [.maskSecondaryFn, .maskControl]))
    }

    // ── The keys that carry fn themselves ───────────────────────────────────

    /// Control-Option-Left is what it always was: a real arrow press has fn on it, and the match does not care.
    func testFnOnAnArrowKeyIsIgnored() {
        let s = Shortcut(key: kVK_LeftArrow, modifiers: Shortcut.control | Shortcut.option)
        let flags: CGEventFlags = [.maskControl, .maskAlternate]
        XCTAssertTrue(s.matches(key: kVK_LeftArrow, flags: flags))
        XCTAssertTrue(s.matches(key: kVK_LeftArrow, flags: flags.union(.maskSecondaryFn)))
        XCTAssertTrue(s.matches(key: kVK_LeftArrow, flags: flags.union([.maskSecondaryFn, .maskNumericPad])))
        XCTAssertEqual(Shortcut.mask(flags.union(.maskSecondaryFn), key: kVK_LeftArrow), Shortcut.control | Shortcut.option)
        XCTAssertEqual(Shortcut(key: kVK_RightArrow, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad]).modifiers, Shortcut.control)
    }

    /// A function key carries fn too, and a shortcut on F5 is still F5.
    func testFnOnAFunctionKeyIsIgnored() {
        let f5 = Shortcut(key: kVK_F5, modifiers: 0)
        XCTAssertTrue(f5.matches(key: kVK_F5, flags: []))
        XCTAssertTrue(f5.matches(key: kVK_F5, flags: [.maskSecondaryFn]))
        let withCommand = Shortcut(key: kVK_F5, modifiers: Shortcut.command)
        XCTAssertTrue(withCommand.matches(key: kVK_F5, flags: [.maskCommand, .maskSecondaryFn]))
        XCTAssertEqual(Shortcut.mask([.maskSecondaryFn], key: kVK_F5), 0)
    }

    /// Every key that is known to set the flag itself drops it, and the ordinary keys keep it.
    func testTheKeysThatSetFnDropItAndNoOtherKeyDoes() {
        let setsFn = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
                      kVK_ForwardDelete, kVK_Help, kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9,
                      kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for key in setsFn {
            XCTAssertTrue(Shortcut.keysThatSetFn.contains(key), "key \(key)")
            XCTAssertEqual(Shortcut.mask([.maskSecondaryFn], key: key), 0, "key \(key)")
        }
        for key in [kVK_Space, kVK_Return, kVK_Tab, kVK_Escape, kVK_Delete, kVK_ANSI_A, kVK_ANSI_Z, kVK_ANSI_0, kVK_ANSI_Grave] {
            XCTAssertFalse(Shortcut.keysThatSetFn.contains(key), "key \(key)")
            XCTAssertEqual(Shortcut.mask([.maskSecondaryFn], key: key), Shortcut.function, "key \(key)")
        }
    }

    // ── Globe on an ordinary key ────────────────────────────────────────────

    /// On a letter, Globe is a choice somebody made: Globe + A is not A.
    func testFnOnALetterCounts() {
        let pressed = Shortcut(key: kVK_ANSI_A, flags: [.maskSecondaryFn])
        XCTAssertEqual(pressed.modifiers, Shortcut.function)
        let globeA = Shortcut(key: kVK_ANSI_A, modifiers: Shortcut.function)
        XCTAssertEqual(pressed, globeA)
        XCTAssertTrue(globeA.matches(key: kVK_ANSI_A, flags: [.maskSecondaryFn]))
        XCTAssertFalse(globeA.matches(key: kVK_ANSI_A, flags: []))

        let bareA = Shortcut(key: kVK_ANSI_A, modifiers: 0)
        XCTAssertFalse(bareA.matches(key: kVK_ANSI_A, flags: [.maskSecondaryFn]), "Globe + A is not A")
        XCTAssertNotEqual(pressed, bareA)
    }

    /// Globe with other modifiers on a letter: all of them have to be there.
    func testGlobeWithOtherModifiersMustMatchExactly() {
        let s = Shortcut(key: kVK_ANSI_K, modifiers: Shortcut.function | Shortcut.command)
        XCTAssertTrue(s.matches(key: kVK_ANSI_K, flags: [.maskSecondaryFn, .maskCommand]))
        XCTAssertFalse(s.matches(key: kVK_ANSI_K, flags: [.maskCommand]))
        XCTAssertFalse(s.matches(key: kVK_ANSI_K, flags: [.maskSecondaryFn]))
        XCTAssertFalse(s.matches(key: kVK_ANSI_K, flags: [.maskSecondaryFn, .maskCommand, .maskShift]))
    }

    // ── Writing it ──────────────────────────────────────────────────────────

    /// Globe comes first, then Control, Option, Shift, Command, then the key.
    func testTheLabelIsInTheOrderMacOSWritesTheModifiers() {
        let everything = Shortcut.function | Shortcut.control | Shortcut.option | Shortcut.shift | Shortcut.command
        XCTAssertEqual(Shortcut(key: kVK_ANSI_A, modifiers: everything).label, "\u{1F310}\u{2303}\u{2325}\u{21E7}\u{2318}A")
        XCTAssertEqual(Shortcut(key: kVK_Space, modifiers: Shortcut.function | Shortcut.shift).label, "\u{1F310}\u{21E7}Space")
        XCTAssertEqual(Shortcut(key: kVK_ANSI_G, modifiers: Shortcut.command | Shortcut.function).label, "\u{1F310}\u{2318}G")
        XCTAssertEqual(Shortcut(key: kVK_ANSI_G, modifiers: Shortcut.control | Shortcut.option | Shortcut.command).label, "\u{2303}\u{2325}\u{2318}G",
                       "no Globe, no globe in the label")
    }

    // ── Stored ──────────────────────────────────────────────────────────────

    /// A shortcut is stored as JSON and comes back the same, the new bit included; the bit is 16 on disk, so what an earlier
    /// build stored (no bit) still reads, and what this build stores is the number written here.
    func testAGlobeShortcutSurvivesBeingStoredAsJSON() throws {
        let shortcut = Shortcut(key: kVK_Space, modifiers: Shortcut.function | Shortcut.command)
        let data = try JSONEncoder().encode(shortcut)
        XCTAssertEqual(try JSONDecoder().decode(Shortcut.self, from: data), shortcut)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(object["modifiers"], 20)
        XCTAssertEqual(object["key"], kVK_Space)

        let stored = try JSONDecoder().decode(Shortcut.self, from: Data(#"{"key":49,"modifiers":16}"#.utf8))
        XCTAssertEqual(stored, ShortcutCommands.clipboardOpen.defaultShortcut)
        let earlier = try JSONDecoder().decode(Shortcut.self, from: Data(#"{"key":123,"modifiers":3}"#.utf8))
        XCTAssertEqual(earlier, Shortcut(key: kVK_LeftArrow, modifiers: Shortcut.control | Shortcut.option))
    }

    /// Through the store a person's choice is kept in: a Globe shortcut given to another command is still there on the next
    /// launch, and takes the shortcut from the command that had it.
    func testAGlobeShortcutIsKeptByTheStoreAndMovesBetweenCommands() {
        let defaults = TestDefaults.throwaway("globe-store")
        let store = ShortcutStore(defaults: defaults)
        let left = WindowAction.leftHalf.command
        let mine = Shortcut(key: kVK_ANSI_J, modifiers: Shortcut.function | Shortcut.command)
        XCTAssertNil(store.assign(mine, to: left, among: all))
        XCTAssertEqual(ShortcutStore(defaults: defaults).shortcut(for: left), mine, "it survives a relaunch")

        let stolenFrom = store.assign(ShortcutCommands.clipboardOpen.defaultShortcut, to: left, among: all)
        XCTAssertEqual(stolenFrom, ShortcutCommands.clipboardOpen)
        XCTAssertNil(store.shortcut(for: ShortcutCommands.clipboardOpen), "the old owner has none now, rather than both firing")
        XCTAssertEqual(store.table(for: all)[ShortcutCommands.clipboardOpen.defaultShortcut], left.id)
    }

    // ── macOS's own shortcuts ───────────────────────────────────────────────

    /// macOS writes Globe into a shortcut as the 0x800000 bit of its modifiers: an enabled shortcut that has it is the same
    /// combination as ours, and is named.
    func testAnEnabledMacOSShortcutWithTheGlobeBitIsFound() {
        // "Select the next input source" (61) on Globe + Space: key 49, the fn bit.
        let hotKeys: [String: Any] = [
            "61": ["enabled": true, "value": ["parameters": [32, 49, 0x800000], "type": "standard"]],
        ]
        XCTAssertEqual(SystemShortcuts.clash(for: Shortcut(key: kVK_Space, modifiers: Shortcut.function), hotKeys: hotKeys),
                       "Select the next input source")
        XCTAssertNil(SystemShortcuts.clash(for: Shortcut(key: kVK_Space, modifiers: 0), hotKeys: hotKeys),
                     "Space alone is not Globe + Space")
        XCTAssertNil(SystemShortcuts.clash(for: Shortcut(key: kVK_Space, modifiers: Shortcut.command), hotKeys: hotKeys))
        XCTAssertNil(SystemShortcuts.clash(for: Shortcut(key: kVK_Space, modifiers: Shortcut.function | Shortcut.command), hotKeys: hotKeys),
                     "exactly the same modifiers")
    }

    /// With the bit missing it is a different shortcut: Globe + Space does not clash with one that is only Space or Command-Space.
    func testAMacOSShortcutWithoutTheGlobeBitDoesNotClashWithGlobeSpace() {
        let hotKeys: [String: Any] = [
            "61": ["enabled": true, "value": ["parameters": [32, 49, 0], "type": "standard"]],
            "64": ["enabled": true, "value": ["parameters": [32, 49, 0x100000], "type": "standard"]],
        ]
        XCTAssertNil(SystemShortcuts.clash(for: ShortcutCommands.clipboardOpen.defaultShortcut, hotKeys: hotKeys))
        XCTAssertEqual(SystemShortcuts.clash(for: Shortcut(key: kVK_Space, modifiers: Shortcut.command), hotKeys: hotKeys), "Spotlight search")
    }

    /// Globe among other modifiers is read the same way, a switched-off shortcut is not a clash, and neither is the absence of
    /// any list; an id the table has no name for is still "a macOS shortcut".
    func testTheGlobeBitIsReadAlongsideTheOtherModifiersAndSwitchedOffShortcutsAreIgnored() {
        let hotKeys: [String: Any] = [
            "999": ["enabled": true, "value": ["parameters": [65535, 40, 0x800000 | 0x40000], "type": "standard"]],
            "61": ["enabled": false, "value": ["parameters": [32, 49, 0x800000], "type": "standard"]],
        ]
        XCTAssertEqual(SystemShortcuts.clash(for: Shortcut(key: kVK_ANSI_K, modifiers: Shortcut.function | Shortcut.control), hotKeys: hotKeys),
                       "a macOS shortcut")
        XCTAssertNil(SystemShortcuts.clash(for: Shortcut(key: kVK_ANSI_K, modifiers: Shortcut.function), hotKeys: hotKeys))
        XCTAssertNil(SystemShortcuts.clash(for: Shortcut(key: kVK_ANSI_K, modifiers: Shortcut.control), hotKeys: hotKeys))
        XCTAssertNil(SystemShortcuts.clash(for: ShortcutCommands.clipboardOpen.defaultShortcut, hotKeys: hotKeys), "that one is switched off")
        XCTAssertNil(SystemShortcuts.clash(for: ShortcutCommands.clipboardOpen.defaultShortcut, hotKeys: nil))
    }
}

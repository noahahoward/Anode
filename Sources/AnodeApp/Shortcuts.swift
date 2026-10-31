import AppKit
import ApplicationServices
import Carbon.HIToolbox

// ── Keyboard shortcuts you can change ───────────────────────────────────────
//
// Every shortcut that does something in Anode (window actions, window groups) is a COMMAND with a
// default, and the user can give it another key combination, or none.
//
// A user's choice must beat the system's, and the first version of this did not. The shortcuts were
// registered with the system's hot key service (Carbon `RegisterEventHotKey`), and measured against a
// real macOS shortcut (Control-Right, "move right a space") it reported success, never fired, and the
// system switched desktop anyway: a silent failure for exactly the shortcuts a user is most likely to
// want. An ACTIVE EVENT TAP sees a key press before the system does, so swallowing it there leaves the
// system nothing to act on (same measurement: Control-Right swallowed, desktop unchanged). That is what
// `KeybindCenter` does; it also beats another app's hot key (Rectangle's) for the same reason.
// Needs Accessibility, which every feature here needs anyway.

/// A key and the modifiers held with it.
struct Shortcut: Codable, Hashable {
    var key: Int
    /// Control 1, Option 2, Command 4, Shift 8: our own bits, so nothing depends on Carbon's or AppKit's.
    var modifiers: Int

    static let control = 1, option = 2, command = 4, shift = 8

    init(key: Int, modifiers: Int) {
        self.key = key
        self.modifiers = modifiers
    }

    /// From Carbon's modifier bits, which the default tables are written in.
    init(key: Int, carbon: Int) {
        var m = 0
        if carbon & controlKey != 0 { m |= Self.control }
        if carbon & optionKey != 0 { m |= Self.option }
        if carbon & cmdKey != 0 { m |= Self.command }
        if carbon & shiftKey != 0 { m |= Self.shift }
        self.init(key: key, modifiers: m)
    }

    /// The modifiers of an event, as our bits. Caps lock, fn and the numeric-pad flag an arrow key
    /// carries are not modifiers anybody chooses, and are ignored.
    static func mask(_ flags: CGEventFlags) -> Int {
        var m = 0
        if flags.contains(.maskControl) { m |= control }
        if flags.contains(.maskAlternate) { m |= option }
        if flags.contains(.maskCommand) { m |= command }
        if flags.contains(.maskShift) { m |= shift }
        return m
    }

    init(key: Int, flags: CGEventFlags) { self.init(key: key, modifiers: Self.mask(flags)) }

    /// Exactly these modifiers: Control-Option-Left is not Control-Option-Shift-Left.
    func matches(key: Int, flags: CGEventFlags) -> Bool { self.key == key && modifiers == Self.mask(flags) }

    /// Something a user can sensibly bind: a modifier is held (a bare letter would swallow typing), or it is
    /// a function key, which has no typing to lose.
    var isUsable: Bool { modifiers != 0 || KeyNames.isFunctionKey(key) }

    /// "⌃⌥⇧⌘" in the order macOS writes them, then the key.
    var label: String {
        (modifiers & Self.control != 0 ? "⌃" : "") + (modifiers & Self.option != 0 ? "⌥" : "")
            + (modifiers & Self.shift != 0 ? "⇧" : "") + (modifiers & Self.command != 0 ? "⌘" : "")
            + KeyNames.name(for: key)
    }
}

enum KeyNames {
    private static let names: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
    private static let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                                                kVK_F9, kVK_F10, kVK_F11, kVK_F12]

    static func name(for key: Int) -> String { names[key] ?? "key \(key)" }
    static func isFunctionKey(_ key: Int) -> Bool { functionKeys.contains(key) }
}

/// One thing a shortcut can do.
struct ShortcutCommand: Hashable {
    let id: String
    let title: String
    let section: String
    let defaultShortcut: Shortcut
}

extension WindowAction {
    var defaultShortcut: Shortcut { Shortcut(key: shortcut.key, carbon: shortcut.modifiers) }
    var commandID: String { "window.\(rawValue)" }
    var command: ShortcutCommand { ShortcutCommand(id: commandID, title: title, section: "Window actions", defaultShortcut: defaultShortcut) }
}

extension GroupAction {
    var defaultShortcut: Shortcut { Shortcut(key: shortcut.key, carbon: shortcut.modifiers) }
    var commandID: String {
        switch self {
        case .toggleGroup: return "group.toggle"
        case .addToGroup: return "group.add"
        case .removeFromGroup: return "group.remove"
        case .restoreLayout: return "group.restore"
        }
    }
    var command: ShortcutCommand { ShortcutCommand(id: commandID, title: title, section: "Window groups", defaultShortcut: defaultShortcut) }
}

enum ShortcutCommands {
    static var window: [ShortcutCommand] { WindowAction.allCases.map(\.command) }
    static var groups: [ShortcutCommand] { GroupAction.allCases.map(\.command) }
    static var all: [ShortcutCommand] { window + groups }
}

/// The user's choices: each command's shortcut, its default unless changed, or none.
final class ShortcutStore {
    static let shared = ShortcutStore()
    static let didChange = Notification.Name("AnodeShortcutsDidChange")

    private struct Entry: Codable { let id: String; let shortcut: Shortcut? }

    private let defaults: UserDefaults
    private let storageKey: String
    /// A command listed here has been changed; a nil shortcut means the user cleared it.
    private var overrides: [String: Shortcut?] = [:]

    init(defaults: UserDefaults = .standard, key: String = "anode.shortcuts.v1") {
        self.defaults = defaults
        self.storageKey = key
        if let data = defaults.data(forKey: key), let entries = try? JSONDecoder().decode([Entry].self, from: data) {
            for e in entries { overrides[e.id] = .some(e.shortcut) }
        }
    }

    func shortcut(for command: ShortcutCommand) -> Shortcut? {
        if let override = overrides[command.id] { return override }
        return command.defaultShortcut
    }

    func isChanged(_ command: ShortcutCommand) -> Bool { overrides[command.id] != nil }

    /// Give `command` the shortcut `new` (nil clears it). If another of `commands` had it, that one loses it
    /// (it would otherwise be unreachable, or both would fire); the one that lost it is returned.
    @discardableResult
    func assign(_ new: Shortcut?, to command: ShortcutCommand, among commands: [ShortcutCommand]) -> ShortcutCommand? {
        var stolenFrom: ShortcutCommand?
        if let new {
            for other in commands where other.id != command.id && shortcut(for: other) == new {
                overrides[other.id] = .some(nil)
                stolenFrom = other
            }
        }
        // Back to the default is not a change worth remembering.
        if new == command.defaultShortcut { overrides[command.id] = nil } else { overrides[command.id] = .some(new) }
        save()
        return stolenFrom
    }

    func reset(_ command: ShortcutCommand) {
        overrides[command.id] = nil
        save()
    }

    func resetAll() {
        overrides = [:]
        save()
    }

    /// Shortcut → command, for the commands given. A shortcut two commands share goes to the first listed.
    func table(for commands: [ShortcutCommand]) -> [Shortcut: String] {
        var t: [Shortcut: String] = [:]
        for c in commands { if let s = shortcut(for: c), t[s] == nil { t[s] = c.id } }
        return t
    }

    private func save() {
        let entries = overrides.map { Entry(id: $0.key, shortcut: $0.value) }.sorted { $0.id < $1.id }
        if entries.isEmpty { defaults.removeObject(forKey: storageKey) } else if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: storageKey)
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

/// macOS's own keyboard shortcuts, so the editor can say when a choice replaces one of them.
enum SystemShortcuts {
    private static let names: [Int: String] = [
        32: "Mission Control", 34: "Mission Control", 33: "Application windows", 36: "Show Desktop",
        79: "Move left a space", 80: "Move left a space", 81: "Move right a space", 82: "Move right a space",
        64: "Spotlight search", 65: "Finder search window", 52: "Turn Dock hiding on or off",
        27: "Move focus to the next window of the app", 28: "Screenshot", 29: "Screenshot", 30: "Screenshot", 31: "Screenshot",
        60: "Select the previous input source", 61: "Select the next input source",
        118: "Switch to Desktop 1", 119: "Switch to Desktop 2", 120: "Switch to Desktop 3", 121: "Switch to Desktop 4",
        122: "Switch to Desktop 5", 123: "Switch to Desktop 6", 124: "Switch to Desktop 7", 125: "Switch to Desktop 8",
        126: "Switch to Desktop 9", 175: "Do Not Disturb", 190: "Quick Note",
    ]

    /// The enabled macOS shortcut `shortcut` is the same key combination as, if there is one.
    static func clash(for shortcut: Shortcut,
                      hotKeys: [String: Any]? = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
                          .dictionary(forKey: "AppleSymbolicHotKeys")) -> String? {
        guard let hotKeys else { return nil }
        for (idString, raw) in hotKeys {
            guard let id = Int(idString), let entry = raw as? [String: Any], (entry["enabled"] as? Bool ?? ((entry["enabled"] as? Int) == 1)),
                  let value = entry["value"] as? [String: Any], let p = value["parameters"] as? [Int], p.count >= 3 else { continue }
            var m = 0
            if p[2] & 0x40000 != 0 { m |= Shortcut.control }
            if p[2] & 0x80000 != 0 { m |= Shortcut.option }
            if p[2] & 0x100000 != 0 { m |= Shortcut.command }
            if p[2] & 0x20000 != 0 { m |= Shortcut.shift }
            if p[1] == shortcut.key && m == shortcut.modifiers { return names[id] ?? "a macOS shortcut" }
        }
        return nil
    }
}

/// The one place that listens for shortcuts: an active event tap that swallows a bound combination (so
/// the system and the app in front never see it) and tells the owner which command it was.
final class KeybindCenter {

    static let shared = KeybindCenter()

    enum Recording: Equatable {
        case shortcut(Shortcut)
        case cancelled
        /// A bare key that would swallow typing; the recorder keeps listening.
        case needsModifier
        /// No Accessibility, so no tap and nothing to record with.
        case unavailable
    }

    private struct Owner {
        let commands: [ShortcutCommand]
        let handler: (String) -> Void
    }

    private let store: ShortcutStore
    private var owners: [String: Owner] = [:]
    private var table: [Shortcut: (owner: String, command: String)] = [:]
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    /// Keys whose key-down was swallowed: their key-up is too, so no app sees half a press.
    private var swallowed = Set<Int>()
    private var recorder: ((Recording) -> Void)?
    private var storeToken: NSObjectProtocol?

    init(store: ShortcutStore = .shared) {
        self.store = store
        storeToken = NotificationCenter.default.addObserver(forName: ShortcutStore.didChange, object: store, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
    }

    var isListening: Bool { tap != nil }

    /// Listen for `commands` and call `handler` with the command id when one is pressed. Replaces whatever
    /// this `owner` registered before.
    func register(owner: String, commands: [ShortcutCommand], handler: @escaping (String) -> Void) {
        owners[owner] = Owner(commands: commands, handler: handler)
        rebuild()
    }

    func unregister(owner: String) {
        owners[owner] = nil
        rebuild()
    }

    private func rebuild() {
        table = [:]
        for (name, o) in owners {
            for (shortcut, id) in store.table(for: o.commands) where table[shortcut] == nil { table[shortcut] = (name, id) }
        }
        if (!owners.isEmpty || recorder != nil) { startTap() } else { stopTap() }
    }

    /// The command a key press is bound to, if any. Pure, for tests.
    static func lookup(_ table: [Shortcut: String], key: Int, flags: CGEventFlags) -> String? {
        table[Shortcut(key: key, flags: flags)]
    }

    // ── Recording ───────────────────────────────────────────────────────────

    /// Capture the next key combination, and say what it was. The key is swallowed, so a combination the
    /// system would act on (or no app would normally see) can still be chosen.
    func record(_ completion: @escaping (Recording) -> Void) {
        recorder = completion
        startTap()
        if tap == nil {
            recorder = nil
            completion(.unavailable)
        }
    }

    func cancelRecording() {
        guard let r = recorder else { return }
        recorder = nil
        r(.cancelled)
        rebuild()
    }

    var isRecording: Bool { recorder != nil }

    // ── The tap ─────────────────────────────────────────────────────────────

    private func startTap() {
        guard tap == nil, AccessibilityAccess.isTrusted else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: keybindTapCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        tapSource = source
    }

    private func stopTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        swallowed = []
    }

    /// Runs on the main thread inside the tap, so it only decides, and hands the work on.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .keyUp:
            let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
            return swallowed.remove(key) != nil ? nil : pass
        case .keyDown:
            let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if let recorder {
                swallowed.insert(key)
                if repeating { return nil }
                let shortcut = Shortcut(key: key, flags: flags)
                let result: Recording = key == kVK_Escape && shortcut.modifiers == 0 ? .cancelled
                    : (shortcut.isUsable ? .shortcut(shortcut) : .needsModifier)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if result != .needsModifier { self.recorder = nil; self.rebuild() }
                    recorder(result)
                }
                return nil
            }
            guard let hit = table[Shortcut(key: key, flags: flags)], let owner = owners[hit.owner] else { return pass }
            swallowed.insert(key)
            // Held down it repeats; the command runs once, and the rest are swallowed too.
            if !repeating { DispatchQueue.main.async { owner.handler(hit.command) } }
            return nil
        default:
            return pass
        }
    }
}

private func keybindTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<KeybindCenter>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}

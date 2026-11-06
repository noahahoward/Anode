import AppKit
import ApplicationServices
import PowerKit

// ── Keyboard & Screen Cleaner (Beta Features) ───────────────────────────────
//
// Turns every display pure black and swallows all keyboard, mouse and trackpad input so the keyboard and the screen can
// be wiped. The combination that ends it is printed in the bottom-left corner of each display.
//
// This file is the session: start, end, and everything that must be undone when it ends. The tap that swallows input
// (`CleanerInputTap`), the black windows (`CleanerWindows`) and the hold that keeps the Mac awake are behind protocols,
// so the whole state machine is tested with fakes and nothing in a test touches the real keyboard or screen.
//
// Safety, in order of importance:
//  - It needs Accessibility. Without a tap a black window would still let keystrokes through to the app underneath, which
//    is worse than showing nothing, so without Accessibility there is no session at all.
//  - If the system disables the tap, the session ENDS; it never carries on with input flowing behind a black screen.
//  - There is always a way out: a cleared exit shortcut falls back to the default.
//  - Process death takes the tap, the windows and the power assertion with it; nothing is left behind to recover.
//
// Nothing runs until a session starts, except (only while the setting is on) a listener for the start shortcut. Main thread.

/// The thing that swallows input while a session runs.
protocol CleanerInputTapping: AnyObject {
    /// Begin swallowing. `onExit` is called (on the main thread) when the exit combination is pressed, `onDisabled` when the
    /// system switched the tap off. False if the tap could not be made.
    func start(filter: CleanerInputFilter, onExit: @escaping () -> Void, onDisabled: @escaping () -> Void) -> Bool
    func stop()
}

/// The black windows, one per display.
protocol CleanerWindowPresenting: AnyObject {
    /// Cover exactly `screens` (replacing whatever was covered before) and print `hint` in the bottom-left corner.
    func show(hint: String, on screens: [NSScreen])
    func hide()
    var isShowing: Bool { get }
}

/// How the start shortcut is listened for.
protocol CleanerKeybinding: AnyObject {
    func register(_ command: ShortcutCommand, handler: @escaping () -> Void)
    func unregister()
}

final class KeybindCenterBinding: CleanerKeybinding {
    private static let owner = "keyboardCleaner"
    func register(_ command: ShortcutCommand, handler: @escaping () -> Void) {
        KeybindCenter.shared.register(owner: Self.owner, commands: [command]) { _ in handler() }
    }
    func unregister() { KeybindCenter.shared.unregister(owner: Self.owner) }
}

final class KeyboardCleaner {

    enum StartResult: Equatable {
        case started
        case alreadyRunning
        case needsAccessibility
        case tapUnavailable
    }

    /// The running controller, for the Beta Features section to read.
    static weak var current: KeyboardCleaner?

    /// Called whenever what the section shows may have changed.
    var onChange: (() -> Void)?
    /// Where the starts, ends and failures go: keyboardcleaner.log in Anode's support folder.
    var log: (String) -> Void = { FeatureLog.append("keyboardcleaner.log", $0) }

    private(set) var isActive = false

    private let settings: Settings
    private let store: ShortcutStore
    private let tap: CleanerInputTapping
    private let windows: CleanerWindowPresenting
    private let assertions: SleepAssertions
    private let keybinds: CleanerKeybinding
    private let isTrusted: () -> Bool
    private let screens: () -> [NSScreen]
    private let keysDown: () -> Set<Int>

    private var settingToken: AnyObject?
    private var screenToken: NSObjectProtocol?
    private var wakeToken: NSObjectProtocol?
    private var timer: Timer?
    private var holdingAssertion = false

    init(settings: Settings = .shared, store: ShortcutStore = .shared,
         tap: CleanerInputTapping, windows: CleanerWindowPresenting,
         assertions: SleepAssertions = IOKitSleepAssertions(),
         keybinds: CleanerKeybinding = KeybindCenterBinding(),
         isTrusted: @escaping () -> Bool = { AccessibilityAccess.isTrusted },
         screens: @escaping () -> [NSScreen] = { NSScreen.screens },
         keysDown: @escaping () -> Set<Int> = { KeyboardCleaner.currentKeysDown() }) {
        self.settings = settings
        self.store = store
        self.tap = tap
        self.windows = windows
        self.assertions = assertions
        self.keybinds = keybinds
        self.isTrusted = isTrusted
        self.screens = screens
        self.keysDown = keysDown
        settingToken = settings.observe(Settings.Key.keyboardCleanerShortcutEnabled) { [weak self] in
            DispatchQueue.main.async { self?.applyShortcutSetting() }
        }
        screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screensChanged() }
        wakeToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screensChanged() }
        applyShortcutSetting()
    }

    deinit {
        if let t = screenToken { NotificationCenter.default.removeObserver(t) }
        if let t = wakeToken { NSWorkspace.shared.notificationCenter.removeObserver(t) }
        timer?.invalidate()
    }

    // ── Start and end ───────────────────────────────────────────────────────

    /// Every key that is down right now, by key code: the 128 virtual key codes include the modifiers (54-63).
    static func currentKeysDown() -> Set<Int> {
        Set((0..<128).filter { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) })
    }

    /// The shortcut that ends a session: the user's choice, or the default if they cleared it (a session must always be
    /// endable from the keyboard).
    var exitShortcut: Shortcut {
        store.shortcut(for: ShortcutCommands.cleanerExit) ?? ShortcutCommands.cleanerExit.defaultShortcut
    }

    private var hint: String { "Press \(exitShortcut.label) to finish" }

    @discardableResult
    func start() -> StartResult {
        guard !isActive else { return .alreadyRunning }
        guard isTrusted() else {
            log("start refused: no Accessibility")
            return .needsAccessibility
        }
        let filter = CleanerInputFilter(exit: exitShortcut, keysDownAtStart: keysDown())
        // The tap goes first: if it cannot be made nothing has appeared on screen yet, so a refusal is invisible.
        let made = tap.start(filter: filter,
                             onExit: { [weak self] in self?.end(reason: "exit combination") },
                             onDisabled: { [weak self] in self?.end(reason: "the system disabled the input tap") })
        guard made else {
            log("start failed: the input tap could not be made")
            return .tapUnavailable
        }
        windows.show(hint: hint, on: screens())
        holdingAssertion = assertions.hold(reason: "Anode keyboard cleaner")
        isActive = true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        log("started")
        onChange?()
        return .started
    }

    func stop() { end(reason: "stopped") }

    private func end(reason: String) {
        guard isActive else { return }
        isActive = false
        timer?.invalidate()
        timer = nil
        tap.stop()
        windows.hide()
        if holdingAssertion { assertions.release(); holdingAssertion = false }
        log("ended: \(reason)")
        onChange?()
    }

    // ── Events while a session runs ─────────────────────────────────────────

    /// A display came, went or moved (or the Mac woke): cover exactly the displays that exist now. The tap is untouched.
    func screensChanged() {
        guard isActive else { return }
        windows.show(hint: hint, on: screens())
    }

    /// Once a second while a session runs: if Accessibility was taken away the tap is dead, so end rather than sit behind
    /// a black screen that no longer blocks anything.
    func tick() {
        guard isActive else { return }
        if !isTrusted() { end(reason: "Accessibility was revoked") }
    }

    // ── The start shortcut ──────────────────────────────────────────────────

    private func applyShortcutSetting() {
        if settings.keyboardCleanerShortcutEnabled {
            keybinds.register(ShortcutCommands.cleanerStart) { [weak self] in self?.start() }
        } else {
            keybinds.unregister()
        }
    }
}

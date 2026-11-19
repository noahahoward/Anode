import AppKit
import PowerKit

// ── Clipboard History: the controller ───────────────────────────────────────
//
// Decides when anything runs. With the setting off nothing does: no timer, no key listener, no window; the one thing alive is the
// observer of the settings. With it on, the shortcut is listened for, and the pasteboard is watched, except while recording is
// paused, the screens are asleep or the session is locked (nobody is copying then, and a timer would only keep the Mac awake).
//
// Everything that touches the Mac is a closure, so the lifecycle and the paste are tested with fakes and no clipboard.

/// The panel, as the controller needs it.
protocol ClipboardPresenting: AnyObject {
    var isOpen: Bool { get }
    func show(controller: ClipboardHistoryController)
    /// What is listed changed while the panel is open (something was copied, deleted or pinned).
    func refresh()
    /// Puts the panel away (it fades), and says when it is gone: what must wait for that (putting the app that was in front back,
    /// and pasting into it) waits on `completion`. Called at once when it was not open.
    func hide(completion: @escaping () -> Void)
}

extension ClipboardPresenting {
    func hide() { hide(completion: {}) }
}

final class ClipboardHistoryController {

    enum PasteMode: Equatable {
        /// Back on the pasteboard as copied, and ⌘V into the app that was in front.
        case paste
        /// The same as plain text.
        case plainText
        /// Back on the pasteboard, and nothing more.
        case copyOnly
    }

    /// The cap on one entry, and on all of them: a screenshot is a few megabytes, and a history of two hundred is plenty.
    static let maxEntryBytes = 10 * 1024 * 1024
    static let maxTotalBytes = 200 * 1024 * 1024
    /// How often the pasteboard's counter is looked at, and how far from that the system may move it to join other wake-ups.
    static let pollInterval: TimeInterval = 1
    static let pollTolerance: TimeInterval = 0.5
    /// Entries past their time are dropped every this many polls (ten minutes), as well as whenever the panel opens.
    static let pollsPerPrune = 600
    /// ⌘V is sent this long after the panel is gone, so the app in front is front again and has the focus.
    static let pasteDelay: TimeInterval = 0.12

    let store: ClipboardStore
    private let settings: Settings
    private let watcher: ClipboardWatcher
    private let presenter: ClipboardPresenting
    private let writePasteboard: ([ClipboardRepresentation], Bool) -> Int
    private let sendPaste: () -> Bool
    private let accessibility: () -> Bool
    private let frontApp: () -> (bundleID: String?, name: String?)
    private let restoreFront: (String?) -> Void
    private let startTimer: (_ interval: TimeInterval, _ tolerance: TimeInterval, _ tick: @escaping () -> Void) -> () -> Void
    private let registerShortcut: (@escaping () -> Void) -> Void
    private let unregisterShortcut: () -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let accessDescription: () -> String
    private let log: (String) -> Void

    private var tokens: [AnyObject] = []
    private var stopTimer: (() -> Void)?
    private var shortcutRegistered = false
    private var screensAsleep = false
    private var locked = false
    private var pollsSincePrune = 0
    private var frontBeforeOpen: String?
    private var finished = false
    /// Whether Accessibility was granted at the last look: the shortcut's key listener cannot start without it, and it is
    /// granted after the switch was turned on, in System Settings, with nothing here told.
    private var wasTrusted = true

    /// Something the section or the panel shows changed (an entry was recorded, the state moved).
    var onChange: (() -> Void)?

    static weak var current: ClipboardHistoryController?

    init(settings: Settings = .shared, store: ClipboardStore, presenter: ClipboardPresenting,
         changeCount: @escaping () -> Int, types: @escaping () -> [String],
         read: @escaping (Int) -> [ClipboardRepresentation]?,
         writePasteboard: @escaping ([ClipboardRepresentation], Bool) -> Int, sendPaste: @escaping () -> Bool,
         accessibility: @escaping () -> Bool, frontApp: @escaping () -> (bundleID: String?, name: String?),
         restoreFront: @escaping (String?) -> Void,
         startTimer: @escaping (TimeInterval, TimeInterval, @escaping () -> Void) -> () -> Void,
         registerShortcut: @escaping (@escaping () -> Void) -> Void, unregisterShortcut: @escaping () -> Void,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
         accessDescription: @escaping () -> String = { "unknown" },
         log: @escaping (String) -> Void = { FeatureLog.append("clipboard.log", $0) }) {
        self.settings = settings
        self.store = store
        self.presenter = presenter
        self.writePasteboard = writePasteboard
        self.sendPaste = sendPaste
        self.accessibility = accessibility
        self.frontApp = frontApp
        self.restoreFront = restoreFront
        self.startTimer = startTimer
        self.registerShortcut = registerShortcut
        self.unregisterShortcut = unregisterShortcut
        self.schedule = schedule
        self.accessDescription = accessDescription
        self.log = log
        watcher = ClipboardWatcher(
            changeCount: changeCount, types: types, read: read, frontApp: frontApp, store: store,
            policy: { [settings] in
                ClipboardStore.Policy(ignoredApps: Set(settings.clipboardHistoryIgnoredApps), keepImages: settings.clipboardHistoryKeepImages)
            }, log: log)
        store.limits = Self.limits(from: settings)
        for key in [Settings.Key.clipboardHistoryEnabled, Settings.Key.clipboardHistoryPaused, Settings.Key.clipboardHistoryKeepMinutes,
                    Settings.Key.clipboardHistoryMaxEntries, Settings.Key.clipboardHistoryKeepImages] {
            tokens.append(settings.observe(key) { [weak self] in self?.settingsChanged() })
        }
        if settings.clipboardHistoryEnabled { apply(starting: true) }
    }

    /// What the settings ask the store to keep.
    static func limits(from settings: Settings) -> ClipboardStore.Limits {
        let minutes = settings.clipboardHistoryKeepMinutes
        return ClipboardStore.Limits(maxEntries: settings.clipboardHistoryMaxEntries, maxEntryBytes: maxEntryBytes,
                                     maxTotalBytes: maxTotalBytes, maxAge: minutes == 0 ? nil : TimeInterval(minutes) * 60)
    }

    // ── What is running ─────────────────────────────────────────────────────

    var isEnabled: Bool { settings.clipboardHistoryEnabled }
    var isPaused: Bool { settings.clipboardHistoryPaused }
    /// The pasteboard is being watched now.
    var isWatching: Bool { stopTimer != nil }
    var isListeningForShortcut: Bool { shortcutRegistered }
    var needsAccessibility: Bool { isEnabled && !accessibility() }

    /// One line for the section: what it is doing, in plain words.
    func statusLine() -> String {
        guard isEnabled else { return "Off" }
        let n = store.entries.count
        let kept = "\(n) \(n == 1 ? "entry" : "entries") kept"
        let base: String
        if isPaused { base = "Paused: nothing new is recorded, \(kept)" }
        else if screensAsleep || locked { base = "Waiting: the screen is asleep or locked, \(kept)" }
        else { base = "Recording: \(kept)" }
        // Recording needs nothing; the shortcut and the paste need Accessibility.
        return needsAccessibility ? base + ". The shortcut and pasting need Accessibility" : base
    }

    private func settingsChanged() {
        guard !finished else { return }
        store.limits = Self.limits(from: settings)
        apply(starting: false)
        onChange?()
    }

    private func apply(starting: Bool) {
        guard !finished else { return }
        if settings.clipboardHistoryEnabled {
            if starting { log("on; the pasteboard lets Anode read it: \(accessDescription())") }
            wasTrusted = accessibility()
            if !shortcutRegistered {
                shortcutRegistered = true
                registerShortcut { [weak self] in self?.toggle() }
            }
            let shouldWatch = !settings.clipboardHistoryPaused && !screensAsleep && !locked
            if shouldWatch, stopTimer == nil {
                // What was copied while nobody watched is not recorded.
                watcher.resync()
                stopTimer = startTimer(Self.pollInterval, Self.pollTolerance) { [weak self] in self?.tick() }
            } else if !shouldWatch, let stop = stopTimer {
                stop()
                stopTimer = nil
            }
        } else {
            stopEverything()
        }
    }

    private func stopEverything() {
        stopTimer?()
        stopTimer = nil
        if shortcutRegistered { unregisterShortcut(); shortcutRegistered = false }
        if presenter.isOpen { presenter.hide() }
    }

    func setScreensAsleep(_ asleep: Bool) {
        guard screensAsleep != asleep else { return }
        screensAsleep = asleep
        apply(starting: false)
        onChange?()
    }

    func setLocked(_ isLocked: Bool) {
        guard locked != isLocked else { return }
        locked = isLocked
        apply(starting: false)
        onChange?()
    }

    func shutdown() {
        finished = true
        tokens.removeAll()
        stopEverything()
    }

    // ── Watching ────────────────────────────────────────────────────────────

    /// One look at the pasteboard's counter; what is new is recorded.
    func tick(now: Date = Date()) {
        guard !finished else { return }
        noticeAccessibility()
        guard !settings.clipboardHistoryPaused else { return }
        pollsSincePrune += 1
        if pollsSincePrune >= Self.pollsPerPrune { pollsSincePrune = 0; store.prune() }
        switch watcher.poll(now: now) {
        case .recorded(let result):
            if case .skipped = result { return }
            onChange?()
            if presenter.isOpen { presenter.refresh() }
        default:
            break
        }
    }

    /// When Accessibility has just been granted, the shortcut is asked for again: the key listener that could not start before
    /// can now.
    private func noticeAccessibility() {
        let trusted = accessibility()
        defer { wasTrusted = trusted }
        guard trusted, !wasTrusted, shortcutRegistered else { return }
        registerShortcut { [weak self] in self?.toggle() }
        onChange?()
    }

    // ── The panel ───────────────────────────────────────────────────────────

    func toggle() {
        if presenter.isOpen { dismiss(); return }
        open()
    }

    func open() {
        guard !finished, settings.clipboardHistoryEnabled else { return }
        // Whatever was copied in the last second is in the list.
        if !settings.clipboardHistoryPaused, !screensAsleep, !locked { tick() }
        store.prune()
        frontBeforeOpen = frontApp().bundleID
        presenter.show(controller: self)
    }

    /// The person closed the panel (Escape, a click elsewhere, the key going to another window): it goes, and the app that was in
    /// front is front again, which a window that was key and was ordered out does not always leave true.
    func dismiss() {
        guard presenter.isOpen else { return }
        let front = frontBeforeOpen
        presenter.hide { [weak self] in self?.restoreFront(front) }
    }

    /// The entries to list for what was typed.
    func results(for query: String) -> [ClipboardEntry] {
        ClipboardSearch.results(store.entries, query: query)
    }

    /// An entry was chosen. It goes back on the pasteboard (and to the top of the list); the panel goes; then, for a paste, ⌘V
    /// is sent to the app that was in front, once it has the focus again.
    func choose(_ id: UUID, mode: PasteMode) {
        guard let reps = store.payload(for: id) else {
            log("an entry could not be read back; it is removed")
            store.delete(id)
            presenter.refresh()
            return
        }
        let count = writePasteboard(reps, mode == .plainText)
        watcher.noteOwnWrite(changeCount: count)
        store.touch(id)
        let front = frontBeforeOpen
        onChange?()
        // The panel fades; only when it is gone is the app that was in front put back, and then ⌘V sent to it.
        presenter.hide { [weak self] in
            guard let self else { return }
            self.restoreFront(front)
            guard mode != .copyOnly else { return }
            self.schedule(Self.pasteDelay) { [weak self] in
                guard let self else { return }
                if !self.sendPaste() { self.log("could not paste: Anode has no Accessibility; the entry is on the clipboard") }
            }
        }
    }

    func delete(_ id: UUID) {
        store.delete(id)
        onChange?()
        presenter.refresh()
    }

    func togglePin(_ id: UUID) {
        guard let entry = store.entry(id) else { return }
        store.setPinned(id, !entry.pinned)
        onChange?()
        presenter.refresh()
    }

    /// Forget everything kept, pinned too.
    func forgetEverything() {
        store.clear(keepPinned: false)
        log("everything was forgotten")
        onChange?()
        presenter.refresh()
    }
}

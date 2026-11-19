import AppKit
import PowerKit

// ── Clipboard History (Beta Features) ───────────────────────────────────────
//
// The switch, how long and how many, what is never kept, and the way to forget it all. Every control writes straight to
// `Settings`; the controller observes it.

/// How long an entry is kept, in the choices the popup offers. 0 is for ever.
enum ClipboardKeepChoices {
    static let all: [(minutes: Int, title: String)] = [
        (30, "30 minutes"), (60, "1 hour"), (480, "8 hours"), (1440, "1 day"), (10_080, "1 week"), (43_200, "30 days"),
        (129_600, "90 days"), (0, "Forever"),
    ]

    /// The row for a stored number of minutes: its own, or the nearest when it is one the popup does not offer (set by hand).
    static func index(forMinutes minutes: Int) -> Int {
        if let exact = all.firstIndex(where: { $0.minutes == minutes }) { return exact }
        if minutes == 0 { return all.count - 1 }
        let finite = all.enumerated().filter { $0.element.minutes != 0 }
        return finite.min { abs($0.element.minutes - minutes) < abs($1.element.minutes - minutes) }?.offset ?? 3
    }
}

/// An app's name for the list of apps to ignore: its own, or the bundle id when it cannot be found.
enum ClipboardAppNames {
    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

final class ClipboardHistoryFeature: BetaFeature {

    let title = "Clipboard History"
    let summary = "Remembers what you copy, and lists it in a search panel that opens over whatever you are doing: type to find "
                + "something, \u{21A9} pastes it into the app you were in. Everything stays on this Mac, in a folder only your account can "
                + "read, for as long as you choose. Copies an app marks as private, copies from password managers and from apps on "
                + "your list are never kept. Needs Accessibility, to listen for its shortcut and to paste. "
                + PrivacyIndicatorNote.text(while: "this is on", watching: "the keyboard for its shortcut")
    var layoutChanged: (() -> Void)?

    private let settings: Settings
    private let accessibility: () -> Bool
    private var tokens: [AnyObject] = []

    let enableCheckbox = NSButton(checkboxWithTitle: "Keep a history of what I copy", target: nil, action: nil)
    let statusLabel = BetaFeaturesWindowController.wrapping("", color: .secondaryLabelColor)
    let shortcutLabel = BetaFeaturesWindowController.wrapping("", color: .secondaryLabelColor)
    let shortcutButton = NSButton(title: "Change Shortcut\u{2026}", target: nil, action: nil)
    let keepPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let maxLabel = NSTextField(labelWithString: "")
    let maxStepper = NSStepper()
    let imagesCheckbox = NSButton(checkboxWithTitle: "Keep copied images", target: nil, action: nil)
    let pauseCheckbox = NSButton(checkboxWithTitle: "Pause recording", target: nil, action: nil)
    let ignoredPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let addAppButton = NSButton(title: "Add App\u{2026}", target: nil, action: nil)
    let removeAppButton = NSButton(title: "Remove", target: nil, action: nil)
    let openButton = NSButton(title: "Open Clipboard History", target: nil, action: nil)
    let forgetButton = NSButton(title: "Forget Everything\u{2026}", target: nil, action: nil)
    let accessibilityLabel = BetaFeaturesWindowController.wrapping("", color: .secondaryLabelColor)
    let accessibilityButton = NSButton(title: "Open Accessibility settings", target: nil, action: nil)
    private var content: NSView?

    init(settings: Settings = .shared, accessibility: @escaping () -> Bool = { AccessibilityAccess.isTrusted }) {
        self.settings = settings
        self.accessibility = accessibility
    }

    func makeView() -> NSView {
        enableCheckbox.target = self
        enableCheckbox.action = #selector(enableToggled)
        shortcutButton.target = self
        shortcutButton.action = #selector(changeShortcut)
        shortcutButton.bezelStyle = .rounded
        shortcutButton.controlSize = .small
        for c in ClipboardKeepChoices.all { keepPopup.addItem(withTitle: c.title) }
        keepPopup.target = self
        keepPopup.action = #selector(keepPicked)
        maxStepper.minValue = Double(Settings.clipboardHistoryMaxEntriesRange.lowerBound)
        maxStepper.maxValue = Double(Settings.clipboardHistoryMaxEntriesRange.upperBound)
        maxStepper.increment = 50
        maxStepper.valueWraps = false
        maxStepper.target = self
        maxStepper.action = #selector(maxStepped)
        imagesCheckbox.target = self
        imagesCheckbox.action = #selector(imagesToggled)
        pauseCheckbox.target = self
        pauseCheckbox.action = #selector(pauseToggled)
        addAppButton.target = self
        addAppButton.action = #selector(addApp)
        removeAppButton.target = self
        removeAppButton.action = #selector(removeApp)
        for b in [addAppButton, removeAppButton, openButton, forgetButton, accessibilityButton] {
            b.bezelStyle = .rounded
            b.controlSize = .small
        }
        openButton.target = self
        openButton.action = #selector(openPanel)
        forgetButton.target = self
        forgetButton.action = #selector(forget)
        accessibilityButton.target = self
        accessibilityButton.action = #selector(openAccessibility)

        keepPopup.setAccessibilityLabel("How long entries are kept")
        maxStepper.setAccessibilityLabel("How many entries are kept")
        ignoredPopup.setAccessibilityLabel("Apps whose copies are never recorded")

        let keepRow = row([NSTextField(labelWithString: "Keep entries for:"), keepPopup])
        let maxRow = row([NSTextField(labelWithString: "Keep at most:"), maxLabel, maxStepper])
        let ignoredRow = row([NSTextField(labelWithString: "Never record copies from:"), ignoredPopup])
        let ignoredButtons = row([addAppButton, removeAppButton])
        let shortcutRow = row([shortcutLabel, shortcutButton])
        let buttons = row([openButton, forgetButton])
        let column = NSStackView(views: [enableCheckbox, statusLabel, shortcutRow, keepRow, maxRow, imagesCheckbox, pauseCheckbox,
                                         ignoredRow, ignoredButtons, buttons, accessibilityLabel, accessibilityButton])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        content = column

        for key in [Settings.Key.clipboardHistoryEnabled, Settings.Key.clipboardHistoryPaused, Settings.Key.clipboardHistoryKeepMinutes,
                    Settings.Key.clipboardHistoryMaxEntries, Settings.Key.clipboardHistoryKeepImages,
                    Settings.Key.clipboardHistoryIgnoredApps] {
            tokens.append(settings.observe(key) { [weak self] in DispatchQueue.main.async { self?.refresh() } })
        }
        ClipboardHistoryController.current?.onChange = { [weak self] in self?.refresh() }
        refresh()
        return column
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let r = NSStackView(views: views)
        r.spacing = 8
        return r
    }

    // ── Actions ─────────────────────────────────────────────────────────────

    @objc private func enableToggled() {
        let on = enableCheckbox.state == .on
        settings.clipboardHistoryEnabled = on
        // The shortcut and the paste both need it: ask when the switch goes on, as the other key features do.
        if on, !accessibility() { AccessibilityAccess.request() }
    }

    @objc private func keepPicked() {
        let i = max(0, keepPopup.indexOfSelectedItem)
        settings.clipboardHistoryKeepMinutes = ClipboardKeepChoices.all[i].minutes
    }

    @objc private func maxStepped() { settings.clipboardHistoryMaxEntries = maxStepper.integerValue }
    @objc private func imagesToggled() { settings.clipboardHistoryKeepImages = imagesCheckbox.state == .on }
    @objc private func pauseToggled() { settings.clipboardHistoryPaused = pauseCheckbox.state == .on }
    @objc private func openAccessibility() { AccessibilityAccess.openSettings() }
    @objc private func changeShortcut() { ShortcutsWindowController.shared.show(selecting: ShortcutCommands.clipboardOpen.id) }
    @objc private func openPanel() { ClipboardHistoryController.current?.open() }

    @objc private func addApp() {
        let panel = NSOpenPanel()
        panel.message = "Choose an app whose copies are never recorded"
        panel.prompt = "Add"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        var list = settings.clipboardHistoryIgnoredApps
        if !list.contains(id) { list.append(id) }
        settings.clipboardHistoryIgnoredApps = list
    }

    @objc private func removeApp() {
        let list = settings.clipboardHistoryIgnoredApps
        let i = ignoredPopup.indexOfSelectedItem
        guard list.indices.contains(i) else { return }
        settings.clipboardHistoryIgnoredApps = list.enumerated().filter { $0.offset != i }.map(\.element)
    }

    @objc private func forget() {
        let alert = NSAlert()
        alert.messageText = "Forget everything Clipboard History has kept?"
        alert.informativeText = "Every entry is deleted from this Mac, pinned ones too. This cannot be undone. What is on the clipboard now is not touched."
        alert.addButton(withTitle: "Forget Everything")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let done: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { ClipboardHistoryController.current?.forgetEverything() }
        }
        if let window = content?.window { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
    }

    // ── What is shown ───────────────────────────────────────────────────────

    func refresh() {
        let on = settings.clipboardHistoryEnabled
        enableCheckbox.state = on ? .on : .off
        let controller = ClipboardHistoryController.current
        statusLabel.stringValue = controller?.statusLine() ?? (on ? "On" : "Off")
        let shortcut = ShortcutStore.shared.shortcut(for: ShortcutCommands.clipboardOpen)
        shortcutLabel.stringValue = "Opens with " + (shortcut?.label ?? "no shortcut")
        keepPopup.selectItem(at: ClipboardKeepChoices.index(forMinutes: settings.clipboardHistoryKeepMinutes))
        maxStepper.integerValue = settings.clipboardHistoryMaxEntries
        maxLabel.stringValue = "\(settings.clipboardHistoryMaxEntries) entries"
        imagesCheckbox.state = settings.clipboardHistoryKeepImages ? .on : .off
        pauseCheckbox.state = settings.clipboardHistoryPaused ? .on : .off

        let ignored = settings.clipboardHistoryIgnoredApps
        ignoredPopup.removeAllItems()
        if ignored.isEmpty {
            ignoredPopup.addItem(withTitle: "None added (password managers always)")
        } else {
            for id in ignored { ignoredPopup.addItem(withTitle: ClipboardAppNames.name(for: id)) }
        }
        removeAppButton.isEnabled = on && !ignored.isEmpty
        ignoredPopup.isEnabled = !ignored.isEmpty

        for control in [shortcutButton, keepPopup, maxStepper, imagesCheckbox, pauseCheckbox, addAppButton, openButton] as [NSControl] {
            control.isEnabled = on
        }
        forgetButton.isEnabled = !(controller?.store.entries.isEmpty ?? true)
        openButton.isEnabled = on

        let missing = on && !accessibility()
        accessibilityLabel.isHidden = !missing
        accessibilityButton.isHidden = !missing
        accessibilityLabel.stringValue = "Clipboard History needs Accessibility to listen for its shortcut and to paste. "
            + "Without it copies are still recorded, the Open button works, and a chosen entry is put on the clipboard for you to paste."
        layoutChanged?()
    }
}

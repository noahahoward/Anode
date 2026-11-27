import AppKit
import PowerKit

// ── Possible memory leaks (Beta Features) ───────────────────────────────────
//
// Two switches (leak detection, and a warning when the Mac's memory is running low) share one status line (whether macOS lets
// Anode show a banner, with the way to the place where that is changed), one list of the last findings (a button on each opens
// its window) and the list of apps the person asked not to be warned about.
//
// Everything shown is read back from the settings and the controller each time (`refresh`), and the section builds and reads
// nothing from the Mac until a switch is on: while both are off the controller does not exist to be asked.

final class MemoryWatchFeature: BetaFeature {

    let title = "Possible memory leaks"
    let summary = "Looks for apps and tools whose memory keeps growing for a minute or more, and shows a notification that says "
                + "there may be a memory leak. Click it for a window with the graph, the numbers and the reason. It rides the "
                + "sampling Anode already does: no extra timer, no disk writes, and a small fixed amount of memory (a few "
                + "dozen processes are followed at a time). It needs permission to show notifications. It never quits "
                + "anything by itself: Quit and Force Quit are buttons you press."
    var layoutChanged: (() -> Void)?

    /// What the second box says it does, in plain sentences: what it watches, what it sends, what it never does and costs.
    static let pressureSummary = "Watches how much of the Mac's memory is left (the RAM minus Memory Used in Activity Monitor). "
        + "When 2.5 GB or less is left it sends a warning, and when 0.5 GB or less is left it sends a critical one that repeats "
        + "every two minutes until memory is freed, naming the biggest app so you can quit it before the Mac stalls. "
        + "On a Mac with little RAM the two lines are smaller. For a critical alert that stays on screen, set Anode's "
        + "notification style to Alerts in System Settings. It never quits anything by itself. It reads memory sizes only, uses "
        + "no administrator privileges and runs no commands. While it is on it costs one small system reading each time "
        + "Anode samples; nothing of it exists while it is off. It needs permission to show notifications."

    static let allowedText = "Notifications: allowed"
    static let deniedText = "Notifications are off for Anode"
    static let notAskedText = "Not asked yet"
    static let checkingText = "Notifications: checking\u{2026}"
    static let openSettingsTitle = "Open Notification Settings"
    static let noFindingsText = "None yet."
    static let permissionHint = "The question macOS asks for permission did not appear in testing. If none appeared, open "
        + "Notification Settings, find Anode in the list and switch it on there."
    static let limitationsText = "Possible leaks only: Anode cannot see inside an app. It catches fast growth (about 50 MB a "
        + "minute or more) within a few minutes, and slow growth (about 6 MB a minute or more) after about two hours. "
        + "Growth slower than that is not caught, and a restart of Anode starts the two hours again. Only your own apps "
        + "and processes can be read."
    static let uninstallText = "After uninstalling Anode the Anode entry stays in System Settings > Notifications."
    /// The pane for notifications, then the one older macOS versions have.
    static let settingsURLs = ["x-apple.systempreferences:com.apple.Notifications-Settings.extension",
                               "x-apple.systempreferences:com.apple.preference.notifications"]

    private let settings: Settings
    private let controller: () -> MemoryWatchController?
    private let openURL: (URL) -> Bool
    private let now: () -> Date
    private var tokens: [AnyObject] = []
    private var changeObserver: NSObjectProtocol?

    // Internal, so the tests can drive them as a click would.
    let enableCheckbox = NSButton(checkboxWithTitle: "Warn me about possible memory leaks", target: nil, action: nil)
    let pressureCheckbox = NSButton(checkboxWithTitle: "Warn when memory is running low", target: nil, action: nil)
    let pressureLabel = BetaFeaturesWindowController.wrapping(MemoryWatchFeature.pressureSummary, color: .secondaryLabelColor)
    let statusLabel = BetaFeaturesWindowController.wrapping("", color: .secondaryLabelColor)
    let openSettingsButton = NSButton(title: MemoryWatchFeature.openSettingsTitle, target: nil, action: nil)
    let hintLabel = BetaFeaturesWindowController.wrapping(MemoryWatchFeature.permissionHint, color: .secondaryLabelColor)
    let findingsCaption = NSTextField(labelWithString: "Recent findings")
    let findingsStack = NSStackView()
    let ignoredCaption = NSTextField(labelWithString: "Not warned about")
    let ignoredStack = NSStackView()
    let limitationsLabel = BetaFeaturesWindowController.wrapping(MemoryWatchFeature.limitationsText, color: .secondaryLabelColor)
    let uninstallLabel = BetaFeaturesWindowController.wrapping(MemoryWatchFeature.uninstallText, color: .secondaryLabelColor)

    /// Reads and builds nothing of the Mac's here: `controller` is looked at only when the switch is on, and is nil in a
    /// test, or before the app has launched.
    init(settings: Settings = .shared,
         controller: @escaping () -> MemoryWatchController? = { MemoryWatchController.current },
         openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.controller = controller
        self.openURL = openURL
        self.now = now
        // Follows the settings and the controller, so a finding that arrives, or a permission given in System Settings,
        // shows without the window being brought forward.
        for key in [Settings.Key.memoryWatchEnabled, Settings.Key.memoryWatchPressureWarning,
                    Settings.Key.memoryWatchIgnoredApps] {
            tokens.append(settings.observe(key) { [weak self] in self?.refresh() })
        }
        changeObserver = NotificationCenter.default.addObserver(forName: MemoryWatchController.didChange, object: nil,
                                                                queue: .main) { [weak self] _ in self?.refresh() }
    }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    // ── Words ───────────────────────────────────────────────────────────────

    /// The line about notifications. nil: not read yet.
    static func statusText(for status: LeakAuthorization?) -> String {
        switch status {
        case .some(.authorized): return allowedText
        case .some(.denied): return deniedText
        case .some(.notDetermined): return notAskedText
        case .none: return checkingText
        }
    }

    /// How long ago, in the few words the list has room for.
    static func ago(from date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) h ago" }
        return "\(Int(seconds / 86400)) d ago"
    }

    /// One row of the findings list: the app (a tool is told apart by its process number), what kind when it is not a leak,
    /// and when.
    static func rowTitle(for finding: Finding, now: Date) -> String {
        let who = finding.isApp ? finding.name : "\(finding.name) (process \(finding.pid))"
        let kind = finding.tier == .pressure ? ", memory low" : ""
        return "\(who)\(kind), \(ago(from: finding.flaggedAtWall, now: now))"
    }

    // ── View ────────────────────────────────────────────────────────────────

    func makeView() -> NSView {
        enableCheckbox.target = self
        enableCheckbox.action = #selector(enableToggled)
        pressureCheckbox.target = self
        pressureCheckbox.action = #selector(pressureToggled)
        openSettingsButton.target = self
        openSettingsButton.action = #selector(openNotificationSettings)
        openSettingsButton.bezelStyle = .rounded
        openSettingsButton.controlSize = .small
        for caption in [findingsCaption, ignoredCaption] {
            caption.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        }
        for list in [findingsStack, ignoredStack] {
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 4
        }
        let column = NSStackView(views: [enableCheckbox, pressureCheckbox, pressureLabel, statusLabel, openSettingsButton, hintLabel, findingsCaption, findingsStack,
                                         ignoredCaption, ignoredStack, limitationsLabel, uninstallLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        refresh()
        return column
    }

    @objc private func enableToggled() {
        let on = enableCheckbox.state == .on
        settings.memoryWatchEnabled = on      // the controller follows it
        // The box was ticked in a window of Anode, so macOS can show its question; never in the install-test copy (the
        // controller refuses there) and never when off.
        if on { controller()?.requestAuthorization() }
        refresh()
    }

    @objc private func pressureToggled() {
        let on = pressureCheckbox.state == .on
        settings.memoryWatchPressureWarning = on      // the controller follows it
        // As for the first box: asked here, where a window of Anode is open; never in the test copy, never when unticked.
        if on { controller()?.requestAuthorization() }
        refresh()
    }

    @objc private func openNotificationSettings() {
        for text in Self.settingsURLs {
            if let url = URL(string: text), openURL(url) { return }
        }
    }

    @objc private func openPressed(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        open(windowKey: key)
    }

    @objc private func removePressed(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        removeIgnored(identityKey: key)
    }

    /// What the Open button of a finding does.
    func open(windowKey: String) {
        controller()?.open(windowKey: windowKey)
    }

    /// What the Remove button of an ignored app does: it is warned about again.
    func removeIgnored(identityKey: String) {
        if let controller = controller() {
            controller.removeIgnored(identityKey: identityKey)
        } else {
            settings.memoryWatchIgnoredApps = settings.memoryWatchIgnoredApps.filter { $0 != identityKey }
        }
        refresh()
    }

    func refresh() {
        let leaks = settings.memoryWatchEnabled
        let pressure = settings.memoryWatchPressureWarning
        let on = leaks || pressure      // the status line and the list are shared: shown while either box is ticked
        enableCheckbox.state = leaks ? .on : .off
        pressureCheckbox.state = pressure ? .on : .off
        let live = on ? controller() : nil
        // Asks macOS again (the answer arrives later, and a change is announced only if it differs, so this does not loop).
        live?.refreshAuthorization()
        let status = live?.authorization

        statusLabel.isHidden = !on
        statusLabel.stringValue = Self.statusText(for: status)
        let needsPermission = on && status != .authorized
        openSettingsButton.isHidden = !needsPermission || status == nil
        hintLabel.isHidden = openSettingsButton.isHidden

        findingsCaption.isHidden = !on
        findingsStack.isHidden = !on
        redrawFindings(live?.findings ?? [], showing: on)

        let ignored = settings.memoryWatchIgnoredApps
        ignoredCaption.isHidden = ignored.isEmpty
        ignoredStack.isHidden = ignored.isEmpty
        redrawIgnored(ignored)
        layoutChanged?()
    }

    private func clear(_ stack: NSStackView) {
        for row in stack.arrangedSubviews {
            stack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
    }

    private func row(title: String, buttonTitle: String, id: String, action: Selector, accessibility: String) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let button = NSButton(title: buttonTitle, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.setAccessibilityLabel(accessibility)
        let stack = NSStackView(views: [label, button])
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    private func redrawFindings(_ findings: [Finding], showing: Bool) {
        clear(findingsStack)
        guard showing else { return }
        guard !findings.isEmpty else {
            let none = NSTextField(labelWithString: Self.noFindingsText)
            none.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            none.textColor = .secondaryLabelColor
            findingsStack.addArrangedSubview(none)
            return
        }
        let current = now()
        for finding in findings {
            let title = Self.rowTitle(for: finding, now: current)
            findingsStack.addArrangedSubview(row(title: title, buttonTitle: "Open", id: finding.windowKey,
                                                 action: #selector(openPressed(_:)),
                                                 accessibility: "Open the window for \(title)"))
        }
    }

    private func redrawIgnored(_ keys: [String]) {
        clear(ignoredStack)
        for key in keys {
            let name = IdentityKey.name(forKey: key)
            ignoredStack.addArrangedSubview(row(title: name, buttonTitle: "Remove", id: key,
                                                action: #selector(removePressed(_:)),
                                                accessibility: "Warn about \(name) again"))
        }
    }

    // ── For tests ───────────────────────────────────────────────────────────

    /// The first text of each row of a list, top to bottom.
    static func rowTitles(of stack: NSStackView) -> [String] {
        stack.arrangedSubviews.compactMap { (view: NSView) -> String? in
            if let field = view as? NSTextField { return field.stringValue }
            return (view as? NSStackView)?.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }.first
        }
    }

    /// The button of each row of a list, top to bottom.
    static func rowButtons(of stack: NSStackView) -> [NSButton] {
        stack.arrangedSubviews.compactMap { ($0 as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSButton }.first }
    }
}

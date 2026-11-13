import AppKit
import PowerKit

// ── Ultra Low Power Mode: what the owner sees and touches ───────────────────
//
// The menu that turns the mode off and brings single apps back (`UltraMenu`), the small icon that carries that menu when no
// reading is on the menu bar (`UltraIcon`), and the section in Beta Features. The confirm box is in `UltraConfirmPanel.swift`.
//
// Nothing here creates the controller: the section, the menu builder and the app menu's entry are given what they need (a
// closure for the controller, closures for what a menu item does), so they are tested with fakes and wired up by the app.
//
// The words are plain and say only what was measured (`docs/superpowers/plans/2026-11-12-ultra-low-power-mode-results.md`).

// ── The menu and the confirm box's words ────────────────────────────────────

enum UltraMenu {

    static let startTitle = "Ultra Low Power Mode…"
    static let turnOffTitle = "Turn off"
    static let frozenHeader = "Frozen (click to bring back):"
    static let nothingFrozenTitle = "Nothing is frozen now."
    static let openBetaTitle = "Open Beta Features…"
    /// The app menu's entry, once the mode is on.
    static let appTurnOffTitle = "Turn Off Ultra Low Power Mode"
    /// How the app menu finds its entry again when the menu is about to open.
    static let appEntryID = NSUserInterfaceItemIdentifier("anode.ultraLowPower")

    /// Keeps the closure alive for as long as its item is: a menu item does not retain its target (`BarChevron` does the same).
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    /// Off: the one way in. Waiting for a Confirm: the same item, switched off. On: turn it off, then every group still
    /// frozen (choosing one brings it back), then the apps that are running whole, then the way to the settings.
    ///
    /// `leftRunning`, `releasedForLoad` and `names` say which apps were never frozen or were let go, and why (see
    /// `UltraLowPowerFeature.leftRunningLines`); they only show while the mode is on.
    static func build(state: UltraLowPowerController.State, frozen: [FreezeGroup], leftRunning: [FreezeGroup] = [],
                      releasedForLoad: [String] = [], names: [String: String] = [:], onStart: @escaping () -> Void,
                      onTurnOff: @escaping () -> Void, onRelease: @escaping (String) -> Void,
                      onOpenBeta: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        // An item with a target and an action is switched back on by the menu as it opens; this one is switched off on purpose.
        menu.autoenablesItems = false
        @discardableResult
        func add(_ title: String, _ run: (() -> Void)?) -> NSMenuItem {
            let item: NSMenuItem
            if let run {
                let action = Action(run)
                item = NSMenuItem(title: title, action: #selector(Action.fire), keyEquivalent: "")
                item.target = action
                item.representedObject = action
            } else {
                // A line to read, not to press.
                item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
            }
            menu.addItem(item)
            return item
        }

        switch state {
        case .off:
            add(startTitle, onStart)
        case .confirming:
            add(startTitle, onStart).isEnabled = false
        case .on:
            add(turnOffTitle, onTurnOff)
            menu.addItem(.separator())
            add(frozen.isEmpty ? nothingFrozenTitle : frozenHeader, nil)
            for group in frozen {
                let id = group.id
                add(group.name.isEmpty ? id : group.name) { onRelease(id) }
            }
            for line in UltraLowPowerFeature.leftRunningLines(leftRunning: leftRunning, releasedForLoad: releasedForLoad, names: names) {
                add(line, nil)
            }
            menu.addItem(.separator())
            add(openBetaTitle, onOpenBeta)
        }
        return menu
    }

    /// The box's headline: what is kept, then what freezes. "Keeps Editor and Meetings. Freezes 9 apps and tools until you
    /// turn this off."
    static func confirmText(kept: [String], frozenCount: Int) -> String {
        let keeps = kept.isEmpty ? "Keeps nothing in particular." : "Keeps \(plainList(kept))."
        let freezes: String
        switch frozenCount {
        case ..<1: freezes = "Nothing else is running that can be frozen."
        case 1: freezes = "Freezes 1 app or tool until you turn this off."
        default: freezes = "Freezes \(frozenCount) apps and tools until you turn this off."
        }
        return keeps + " " + freezes
    }

    /// "A", "A and B", "A, B and C".
    private static func plainList(_ names: [String]) -> String {
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    // ── What a press does ───────────────────────────────────────────────────

    enum Press: Equatable { case start, turnOff }

    /// The section's button, the app menu's entry and the shortcut all mean the same: start when off, turn off when on, and
    /// nothing while the box is up (a second press must not ask again).
    static func press(for state: UltraLowPowerController.State) -> Press? {
        switch state {
        case .off: return .start
        case .on: return .turnOff
        case .confirming: return nil
        }
    }

    static func toggle(_ controller: UltraLowPowerController) {
        switch press(for: controller.state) {
        case .start?: controller.request()
        case .turnOff?: controller.turnOff()
        case nil: break
        }
    }

    // ── The app menu's entry ────────────────────────────────────────────────

    struct AppEntry: Equatable {
        var title: String
        var isHidden: Bool
        var isEnabled: Bool
    }

    /// How the entry in the app menu looks. It is there only while the box in Beta Features is ticked, and a mode that is
    /// running keeps its entry even if the box is unticked since: the way out is never taken away. With no controller (the
    /// app has not made one) or while the box is up there is nothing to press.
    static func appEntry(ticked: Bool, state: UltraLowPowerController.State?) -> AppEntry {
        AppEntry(title: state == .on ? appTurnOffTitle : startTitle,
                 isHidden: !ticked && state != .on,
                 isEnabled: state == .off || state == .on)
    }
}

// ── The icon ────────────────────────────────────────────────────────────────

/// The one small status item the mode adds when no reading is on the menu bar to carry its menu. It exists only between
/// `install()` and `remove()`.
protocol UltraIconPresenting: AnyObject {
    func install()
    func remove()
}

final class UltraIcon: NSObject, UltraIconPresenting {

    static let autosaveName = "AnodeUltraLowPowerIcon"
    static let symbolName = "moon.zzz"
    static let accessibilityLabel = "Ultra Low Power Mode"

    /// A click, with the button it was on: the owner of the icon opens the menu there.
    var onClick: ((NSStatusBarButton) -> Void)?

    private var item: NSStatusItem?

    /// A status item can be refused (a dying WindowServer connection hands back one with no button): then there is no icon and
    /// the owner reaches the mode through its shortcut and the readings' menus.
    func install() {
        guard item == nil else { return }
        let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = created.button else {
            NSStatusBar.system.removeStatusItem(created)
            return
        }
        created.autosaveName = Self.autosaveName
        // Explicitly visible, every time: macOS saves `isVisible` per autosave name (see `MenuBarWidgetController.rebuild`).
        created.isVisible = true
        let image = NSImage(systemSymbolName: Self.symbolName, accessibilityDescription: Self.accessibilityLabel)
        image?.isTemplate = true
        button.image = image
        button.setAccessibilityLabel(Self.accessibilityLabel)
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item = created
    }

    /// Destroyed, not hidden: a hidden item still holds its place on a bar with no room to spare.
    func remove() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    @objc private func clicked(_ sender: NSStatusBarButton) { onClick?(sender) }
}

// ── The section (Beta Features) ─────────────────────────────────────────────

/// Top to bottom: the box that makes the mode available, the Start / Turn Off button, the list of what is always kept, a line
/// for every part this Mac could not do, a line for the apps left running, the way to install the helper when that is what
/// is missing, and the note on what was measured.
///
/// The box and the list write straight to `Settings`; the button presses the controller, which `controller` hands over (nil
/// until the app makes one). What is shown is read back from both in `redraw`, which runs when either changes.
final class UltraLowPowerFeature: BetaFeature {

    let title = "Ultra Low Power Mode"
    /// Read once, when the window is built, so it names the key the owner has chosen at that time, and no key at all when
    /// they have cleared it.
    var summary: String {
        let key = shortcutLabel().map { ", or press \($0)" } ?? ""
        return "Freezes the apps and tools you are not using, and holds the screen at half brightness or lower, until you turn "
            + "it off. Ticking the box only makes it available: it starts when you press Start (or choose it from a menu\(key)) "
            + "and confirm the list of what is kept and what is frozen."
    }
    var layoutChanged: (() -> Void)?

    static let startTitle = "Start…"
    static let turnOffTitle = "Turn Off"
    static let addTitle = "Add…"
    static let nothingToAddTitle = "Nothing else is running"

    private let settings: Settings
    private let controller: () -> UltraLowPowerController?
    private let candidates: (@escaping ([FreezeGroup]) -> Void) -> Void
    private let appName: (String) -> String?
    /// The key that asks for the mode; nil when the owner has cleared it.
    private let shortcutLabel: () -> String?
    private let installHelper: (@escaping (String) -> Void) -> Void
    private var tokens: [AnyObject] = []
    private var changeObserver: NSObjectProtocol?
    /// The running groups the picker was last told about, and every name seen so far (by group id): the names of what is on
    /// the always-keep list, and of a group the guard let go (it is no longer in the controller's list when it is named).
    private var offered: [FreezeGroup] = []
    private var seenNames: [String: String] = [:]
    /// What the install said last. Kept while the line that points at it is showing.
    private var installNote: String?

    // Internal, so the tests can drive them as a click would.
    let enableCheckbox = NSButton(checkboxWithTitle: "Allow Ultra Low Power Mode", target: nil, action: nil)
    let efficiencyCheckbox = NSButton(checkboxWithTitle: "Keep everything on the efficiency cores (slower)", target: nil, action: nil)
    let backdropCheckbox = NSButton(checkboxWithTitle: "Black out the desktop behind your windows", target: nil, action: nil)
    let startButton = NSButton(title: UltraLowPowerFeature.startTitle, target: nil, action: nil)
    let keepList = NSStackView()
    let addPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    let skippedLabel = BetaFeaturesWindowController.wrapping("", color: .secondaryLabelColor)
    let leftRunningLabel = BetaFeaturesWindowController.wrapping("", color: .secondaryLabelColor)
    let installButton = NSButton(title: "Install Helper\u{2026}", target: nil, action: nil)
    let installNoteLabel = BetaFeaturesWindowController.wrapping("", color: .secondaryLabelColor)
    let noteLabel = BetaFeaturesWindowController.wrapping(UltraLowPowerFeature.note, color: .secondaryLabelColor)
    private let emptyKeepLabel = NSTextField(labelWithString: "No apps added yet.")

    init(settings: Settings = .shared,
         controller: @escaping () -> UltraLowPowerController? = { UltraLowPowerController.current },
         candidates: @escaping (@escaping ([FreezeGroup]) -> Void) -> Void = { $0([]) },
         appName: @escaping (String) -> String? = { UltraLowPowerFeature.runningAppName(bundleID: $0) },
         shortcutLabel: @escaping () -> String? = { UltraLowPowerFeature.keyLabel(in: .shared) },
         installHelper: @escaping (@escaping (String) -> Void) -> Void = { report in
             (NSApplication.shared.delegate as? AppDelegate)?.fansPane.control.installHelper(report: report,
                                                                                              from: .ultraLowPower)
         }) {
        self.settings = settings
        self.controller = controller
        self.candidates = candidates
        self.appName = appName
        self.shortcutLabel = shortcutLabel
        self.installHelper = installHelper
    }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    // ── Words ───────────────────────────────────────────────────────────────

    /// The key the store holds for the mode: the default until the owner changes it, nil once they have cleared it (a
    /// cleared key does nothing, so the default must not be put back in its place).
    static func keyLabel(in store: ShortcutStore) -> String? {
        store.shortcut(for: ShortcutCommands.ultraToggle)?.label
    }

    /// What was measured, on the owner's 14-inch MacBook Pro (10.4, 4.3 and 2.8 W, rounded), and what was not. The mode
    /// keeps the Mac at rest; it does not lower the draw at rest, and nothing here says it does.
    static let note = "Dimming the screen is what saves the most. On the 14-inch MacBook Pro this was measured on, the whole Mac "
        + "drew about 10 W with the brightness slider at full, about 4 W at half and about 3 W at a quarter. With the Mac at "
        + "rest, the lower refresh rate, Low Power Mode and freezing apps saved little or nothing. What they do is keep the "
        + "Mac at rest. Freezing stops the frozen apps from starting a burst of work in the background, and Low Power Mode "
        + "limits heavy work (what that saves under a heavy load was not measured). Frozen apps stop keeping their network "
        + "connections going, so some may drop. An app with a part Anode cannot freeze is left running. How long the "
        + "battery lasts depends on what you do, so no running time is promised."

    /// The parts a Mac may not do, in the order the controller's enum declares them.
    private static let skippedOrder: [UltraSkipped] = [.lowPowerNoHelper, .lowPowerOldHelper, .oneRefreshRate, .keyboardLight,
                                                       .lowPowerRefused, .rateRefused, .ceilingRefused, .noEfficiencyCores]

    /// One plain sentence for each part that was not done, in the enum's order and without repeats. A missing or old helper
    /// points at the button the section shows with the line, the route Charge Control uses.
    static func describe(_ skipped: [UltraSkipped]) -> [String] {
        skippedOrder.filter { skipped.contains($0) }.map { part in
            switch part {
            case .lowPowerNoHelper:
                return "Low Power Mode was not switched on: it needs the Anode helper, which is not installed. Press Install "
                    + "Helper\u{2026} below to add it, and it will be used the next time you start."
            case .lowPowerOldHelper:
                return "Low Power Mode was not switched on: the Anode helper installed here is an older one. Press Install "
                    + "Helper\u{2026} below to update it, and it will be used the next time you start."
            case .lowPowerRefused:
                return "The Anode helper could not switch Low Power Mode on, so it was left as it was."
            case .oneRefreshRate:
                return "The screen's refresh rate was left as it was: it offers only one, or this Mac has no built-in screen."
            case .rateRefused:
                return "The screen would not take the lower refresh rate, so it was left as it was."
            case .ceilingRefused:
                return "The screen's brightness could not be held at half, so it was left as it was."
            case .keyboardLight:
                return "This Mac's keyboard light could not be read or switched off, so it was left as it was."
            case .noEfficiencyCores:
                return "This Mac has no efficiency cores, so work was left on the cores it has."
            }
        }
    }

    /// The apps that are running whole: first those with a part Anode cannot freeze, then those the guard let go because
    /// something started burning after they were stopped. `names` gives the name of a group by its id, for the ones that are
    /// no longer in any list; an id with no name is read as it is (`displayName`).
    static func leftRunningLines(leftRunning: [FreezeGroup], releasedForLoad: [String], names: [String: String]) -> [String] {
        var lines: [String] = []
        let cannot = leftRunning.map(\.name)
        if !cannot.isEmpty {
            lines.append("Left running: \(cannot.joined(separator: ", ")) (\(cannot.count == 1 ? "it has" : "each has") a part Anode cannot freeze).")
        }
        let badly = releasedForLoad.map { names[$0] ?? displayName(forGroupID: $0, appName: { _ in nil }) }
        if !badly.isEmpty {
            lines.append("Left running: \(badly.joined(separator: ", ")) (\(badly.count == 1 ? "it" : "each") reacted badly to being frozen).")
        }
        return lines
    }

    /// What the always-keep list shows for a stored id: an app by its name when that is known, a launchd job or an
    /// executable by the label or name that follows its prefix, and anything else as it is.
    static func displayName(forGroupID id: String, appName: (String) -> String?) -> String {
        for prefix in ["job:", "exe:"] where id.hasPrefix(prefix) {
            let rest = String(id.dropFirst(prefix.count))
            return rest.isEmpty ? id : rest
        }
        return appName(id) ?? id
    }

    /// The running apps, by name, as far as the process already holds them. A call into another process is not made from
    /// here, so an app that is not running is shown by its id until the picker has seen it.
    static func runningAppName(bundleID: String) -> String? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }?.localizedName
    }

    /// The groups the picker offers: those not on the list already.
    static func addable(_ groups: [FreezeGroup], keeping kept: [String]) -> [FreezeGroup] {
        groups.filter { !kept.contains($0.id) }
    }

    struct ButtonLook: Equatable {
        var title: String
        var isEnabled: Bool
    }

    /// The Start / Turn Off button. Start waits for the box to be ticked, a controller to exist and no box to be up. Turn Off is
    /// always there while the mode runs, ticked or not.
    static func buttonLook(ticked: Bool, state: UltraLowPowerController.State?) -> ButtonLook {
        switch state {
        case .on?: return ButtonLook(title: turnOffTitle, isEnabled: true)
        case .off?: return ButtonLook(title: startTitle, isEnabled: ticked)
        case .confirming?, nil: return ButtonLook(title: startTitle, isEnabled: false)
        }
    }

    /// Whether the choices under the box can be changed. They are read when the mode starts, so they stay as they were chosen
    /// from the question until the mode is off again: the box lists what is about to happen, and a session is not changed
    /// under itself.
    static func optionsEnabled(state: UltraLowPowerController.State?) -> Bool {
        state == nil || state == .off
    }

    // ── View ────────────────────────────────────────────────────────────────

    func makeView() -> NSView {
        enableCheckbox.target = self
        enableCheckbox.action = #selector(toggled)
        efficiencyCheckbox.target = self
        efficiencyCheckbox.action = #selector(efficiencyToggled)
        backdropCheckbox.target = self
        backdropCheckbox.action = #selector(backdropToggled)
        startButton.target = self
        startButton.action = #selector(startPressed)
        installButton.target = self
        installButton.action = #selector(installPressed)
        for button in [startButton, installButton] { button.bezelStyle = .rounded }
        installButton.controlSize = .small
        addPopup.controlSize = .small
        addPopup.autoenablesItems = false
        addPopup.setAccessibilityLabel("Add an app to always keep running")
        emptyKeepLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyKeepLabel.textColor = .secondaryLabelColor
        keepList.orientation = .vertical
        keepList.alignment = .leading
        keepList.spacing = 4

        let keepCaption = NSTextField(labelWithString: "Always keep running")
        keepCaption.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let column = NSStackView(views: [enableCheckbox, efficiencyCheckbox, backdropCheckbox, startButton, keepCaption, keepList, addPopup, skippedLabel,
                                         leftRunningLabel, installButton, installNoteLabel, noteLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8

        // Listening starts with the view: a section that was never shown has nothing to keep up to date.
        if tokens.isEmpty {
            tokens = [Settings.Key.ultraLowPowerEnabled, Settings.Key.ultraLowPowerAlwaysKeep,
                      Settings.Key.ultraLowPowerEfficiencyCores, Settings.Key.ultraLowPowerBlackBackdrop].map { key in
                settings.observe(key) { [weak self] in self?.redraw() }
            }
        }
        if changeObserver == nil {
            changeObserver = NotificationCenter.default.addObserver(forName: UltraLowPowerController.didChange, object: nil,
                                                                    queue: .main) { [weak self] _ in self?.redraw() }
        }
        refresh()
        return column
    }

    // ── Actions ─────────────────────────────────────────────────────────────

    @objc private func toggled() { settings.ultraLowPowerEnabled = enableCheckbox.state == .on }

    @objc private func efficiencyToggled() { settings.ultraLowPowerEfficiencyCores = efficiencyCheckbox.state == .on }

    @objc private func backdropToggled() { settings.ultraLowPowerBlackBackdrop = backdropCheckbox.state == .on }

    @objc private func startPressed() {
        guard let c = controller() else { return }
        UltraMenu.toggle(c)
    }

    /// The install says how it is going here, as it goes. It is Charge Control's route: the same confirmation and the same
    /// authorisation, run from the Fans tab's panel.
    @objc private func installPressed() {
        installNote = nil
        redraw()
        installHelper { [weak self] text in
            let show = {
                self?.installNote = text
                self?.redraw()
            }
            if Thread.isMainThread { show() } else { DispatchQueue.main.async(execute: show) }
        }
    }

    @objc private func removePressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        remove(groupID: id)
    }

    @objc private func candidateChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        add(groupID: id, name: sender.title)
    }

    /// Put a group on the list. One already there changes nothing.
    func add(groupID id: String, name: String) {
        seenNames[id] = name
        let kept = settings.ultraLowPowerAlwaysKeep
        guard !kept.contains(id) else { return }
        settings.ultraLowPowerAlwaysKeep = kept + [id]
    }

    func remove(groupID id: String) {
        settings.ultraLowPowerAlwaysKeep = settings.ultraLowPowerAlwaysKeep.filter { $0 != id }
    }

    // ── Showing ─────────────────────────────────────────────────────────────

    /// The window came forward: the picker asks for the running groups again, and everything is read back. A change to the
    /// settings or to the controller redraws without asking, so the process list is not read again at each of them.
    func refresh() {
        candidates { [weak self] groups in
            let apply = {
                guard let self else { return }
                self.offered = groups
                for group in groups { self.seenNames[group.id] = group.name }
                self.redraw()
            }
            if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
        }
        redraw()
    }

    /// The names on the always-keep list, as the rows show them.
    var keptNames: [String] { settings.ultraLowPowerAlwaysKeep.map(name(forGroupID:)) }

    var removeButtons: [NSButton] {
        keepList.arrangedSubviews.compactMap { ($0 as? NSStackView)?.arrangedSubviews.last as? NSButton }
    }

    /// What the pop-up offers, by name (not its own title, nor its "nothing to add" line).
    var addChoices: [String] {
        (addPopup.menu?.items ?? []).filter { $0.representedObject is String }.map(\.title)
    }

    private func name(forGroupID id: String) -> String {
        seenNames[id] ?? Self.displayName(forGroupID: id, appName: appName)
    }

    private func redraw() {
        let ticked = settings.ultraLowPowerEnabled
        let c = controller()
        enableCheckbox.state = ticked ? .on : .off
        efficiencyCheckbox.state = settings.ultraLowPowerEfficiencyCores ? .on : .off
        backdropCheckbox.state = settings.ultraLowPowerBlackBackdrop ? .on : .off
        for choice in [efficiencyCheckbox, backdropCheckbox] { choice.isEnabled = Self.optionsEnabled(state: c?.state) }
        let look = Self.buttonLook(ticked: ticked, state: c?.state)
        startButton.title = look.title
        startButton.isEnabled = look.isEnabled

        redrawKeepList()
        redrawAddPopup()

        let skipped = c?.skipped ?? []
        let skippedLines = Self.describe(skipped)
        skippedLabel.stringValue = skippedLines.joined(separator: "\n")
        skippedLabel.isHidden = skippedLines.isEmpty

        for group in (c?.frozen ?? []) + (c?.leftRunning ?? []) { seenNames[group.id] = group.name }
        let running = Self.leftRunningLines(leftRunning: c?.leftRunning ?? [], releasedForLoad: c?.releasedForLoad ?? [],
                                            names: seenNames)
        leftRunningLabel.stringValue = running.joined(separator: "\n")
        leftRunningLabel.isHidden = running.isEmpty

        // The button is there with the line that points at it, and the install's own words go when the line does.
        let needsHelper = skipped.contains(.lowPowerNoHelper) || skipped.contains(.lowPowerOldHelper)
        installButton.isHidden = !needsHelper
        if !needsHelper { installNote = nil }
        installNoteLabel.stringValue = installNote ?? ""
        installNoteLabel.isHidden = installNote == nil
        layoutChanged?()
    }

    private func redrawKeepList() {
        for row in keepList.arrangedSubviews {
            keepList.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        let ids = settings.ultraLowPowerAlwaysKeep
        guard !ids.isEmpty else {
            keepList.addArrangedSubview(emptyKeepLabel)
            return
        }
        for id in ids {
            let shown = name(forGroupID: id)
            let label = NSTextField(labelWithString: shown)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 280).isActive = true
            let remove = NSButton(title: "Remove", target: self, action: #selector(removePressed(_:)))
            remove.bezelStyle = .rounded
            remove.controlSize = .small
            remove.identifier = NSUserInterfaceItemIdentifier(id)
            remove.setAccessibilityLabel("Stop always keeping \(shown) running")
            let row = NSStackView(views: [label, remove])
            row.orientation = .horizontal
            row.spacing = 8
            keepList.addArrangedSubview(row)
        }
    }

    private func redrawAddPopup() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // A pull-down shows its first item as its own title.
        menu.addItem(NSMenuItem(title: Self.addTitle, action: nil, keyEquivalent: ""))
        let choices = Self.addable(offered, keeping: settings.ultraLowPowerAlwaysKeep)
        if choices.isEmpty {
            let none = NSMenuItem(title: Self.nothingToAddTitle, action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for group in choices {
            let item = NSMenuItem(title: group.name.isEmpty ? group.id : group.name, action: #selector(candidateChosen(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = group.id
            menu.addItem(item)
        }
        addPopup.menu = menu
    }
}

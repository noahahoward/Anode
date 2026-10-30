import AppKit
import PowerKit

// ── Beta Features ───────────────────────────────────────────────────────────
//
// One window, Settings → Beta Features…, for things worth having in Anode that are
// not worth a separate app. Each feature is a section in it, with its own controls.
//
// It is a window of its own, not part of the Settings window: these are not
// preferences of the app, they are experiments, and they should be findable in one
// place and removable without touching the real settings. It replaced a dropdown
// submenu, which was fine for one feature and wrong for a list that is going to grow.
//
// Adding a feature is writing a `BetaFeature` and adding it to the list in
// `BetaFeaturesWindowController.init`; nothing else changes.

/// One section of the Beta Features window.
protocol BetaFeature: AnyObject {
    var title: String { get }
    /// One or two sentences: what it is, and anything it asks of the user.
    var summary: String { get }
    /// Called when what the feature shows has changed size (a row appeared), so the
    /// window can resize to fit.
    var layoutChanged: (() -> Void)? { get set }
    /// The controls, built once.
    func makeView() -> NSView
    /// Re-read everything shown from the stored truth. Cheap, and called whenever the
    /// window comes forward, because a setting or a system permission may have
    /// changed behind it.
    func refresh()
}

final class BetaFeaturesWindowController: NSWindowController {

    static let emptyText = "No beta features yet."
    static let contentWidth: CGFloat = 480

    let features: [BetaFeature]
    private let stack = NSStackView()
    private var activeToken: NSObjectProtocol?

    init(features: [BetaFeature] = [BackdropFeature(), WindowSwitcherFeature(), DesktopSwitcherFeature(),
                                    DockPreviewFeature()]) {
        self.features = features
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Beta Features"
        // Closing must not deallocate it: the controller outlives the window.
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildLayout()
        window.center()
        for feature in features { feature.layoutChanged = { [weak self] in self?.fit() } }
        // A permission can be granted or taken away in System Settings while this
        // window is open, so it is re-read whenever the app comes forward.
        activeToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { if let t = activeToken { NotificationCenter.default.removeObserver(t) } }

    func show() {
        refresh()
        showWindow(nil)
        window?.bringForward()
    }

    private func refresh() {
        features.forEach { $0.refresh() }
        fit()
    }

    // ── Layout ──────────────────────────────────────────────────────────────

    private func buildLayout() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        if features.isEmpty {
            stack.addArrangedSubview(NSTextField(labelWithString: Self.emptyText))
        }
        for (i, feature) in features.enumerated() {
            if i > 0 {
                let rule = NSBox(); rule.boxType = .separator
                stack.addArrangedSubview(rule)
                rule.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
            }
            let title = NSTextField(labelWithString: feature.title)
            title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
            let summary = Self.wrapping(feature.summary, color: .secondaryLabelColor)
            let view = feature.makeView()
            for v in [title, summary, view] { stack.addArrangedSubview(v) }
            view.widthAnchor.constraint(lessThanOrEqualToConstant: Self.contentWidth - 40).isActive = true
        }

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.contentWidth),
        ])
        window?.contentView = container
        fit()
    }

    /// Resize the window to what is in it, keeping its top edge where it was.
    private func fit() {
        guard let window, let container = window.contentView else { return }
        container.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.contentWidth, height: ceil(stack.fittingSize.height))
        let top = window.frame.maxY
        window.setContentSize(size)
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
    }

    /// A wrapped label that does not grow the window sideways.
    static func wrapping(_ text: String, color: NSColor = .labelColor, size: CGFloat = NSFont.smallSystemFontSize)
        -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        label.preferredMaxLayoutWidth = contentWidth - 40
        return label
    }
}

// ── Menu Bar Backdrop ───────────────────────────────────────────────────────

/// What sits behind the menu bar (see `MenuBarBackdrop`): which mode, how see-through
/// the blur is, and — in the follow mode — whether macOS has allowed Anode to read the
/// screen, with a way to the pane where that is taken back.
///
/// Every control writes straight to `Settings` and the backdrop observes it, so a
/// choice shows on the bar at once. What the section shows is read back from
/// `Settings` and the permission each time (`refresh`), so a change made elsewhere —
/// `defaults write`, or the permission revoked in System Settings — cannot leave it
/// stale.
final class BackdropFeature: BetaFeature {

    let title = "Menu Bar Backdrop"
    let summary = "Puts a bar behind the menu bar so the wallpaper stops showing through it. "
                + "The system picks the menu text colour from the wallpaper, so a dark "
                + "wallpaper is what keeps the text white."
    var layoutChanged: (() -> Void)?

    private let settings: Settings
    private let access: () -> Bool
    private var tokens: [AnyObject] = []

    // Internal, so the tests can drive them as a click would.
    let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    let desktopCheckbox = NSButton(checkboxWithTitle: "Show on the desktop", target: nil, action: nil)
    let desktopNote = BetaFeaturesWindowController.wrapping(
        "Off hides the bar on a display while no app window is on it, and brings it back with the first window.",
        color: .secondaryLabelColor)
    let seeThroughLabel = NSTextField(labelWithString: "See-through")
    let maxBlurLabel = NSTextField(labelWithString: "Max blur")
    let sliderRow = NSStackView()
    let modeNote = BetaFeaturesWindowController.wrapping("")
    let accessStatus = BetaFeaturesWindowController.wrapping("")
    let accessButton = NSButton(title: "Open Screen Recording Settings…", target: nil, action: nil)

    init(settings: Settings = .shared,
         screenRecordingAllowed: @escaping () -> Bool = { ScreenRecordingAccess.isGranted }) {
        self.settings = settings
        self.access = screenRecordingAllowed
    }

    func makeView() -> NSView {
        modePopup.addItems(withTitles: MenuBarBackdropMode.allCases.map(\.title))
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        let modeLabel = NSTextField(labelWithString: "Mode:")
        let modeRow = NSStackView(views: [modeLabel, modePopup])
        modeRow.spacing = 8

        slider.target = self
        slider.action = #selector(slid)
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        // The left end is the least blur (the wallpaper plainly there), the right the most.
        sliderRow.setViews([seeThroughLabel, slider, maxBlurLabel], in: .leading)
        sliderRow.spacing = 8

        accessButton.target = self
        accessButton.action = #selector(openScreenRecording)
        accessButton.bezelStyle = .rounded
        accessButton.controlSize = .small

        desktopCheckbox.target = self
        desktopCheckbox.action = #selector(desktopToggled)

        let column = NSStackView(views: [modeRow, modeNote, sliderRow, desktopCheckbox, desktopNote,
                                         accessStatus, accessButton])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8

        tokens = [Settings.Key.menuBarBackdropMode, Settings.Key.menuBarBackdropBlur,
                  Settings.Key.menuBarBackdropShowOnDesktop].map { key in
            settings.observe(key) { [weak self] in self?.refresh() }
        }
        refresh()
        return column
    }

    // ── Actions ─────────────────────────────────────────────────────────────

    @objc private func modeChanged() {
        let modes = MenuBarBackdropMode.allCases
        let i = modePopup.indexOfSelectedItem
        guard modes.indices.contains(i) else { return }
        settings.menuBarBackdropMode = modes[i]
    }

    @objc private func desktopToggled() {
        settings.menuBarBackdropShowOnDesktop = desktopCheckbox.state == .on
    }

    @objc private func slid() {
        settings.menuBarBackdropBlur = slider.doubleValue
    }

    @objc private func openScreenRecording() {
        ScreenRecordingAccess.openSettings()
    }

    // ── What it says ────────────────────────────────────────────────────────

    func refresh() {
        let mode = settings.menuBarBackdropMode
        if let i = MenuBarBackdropMode.allCases.firstIndex(of: mode) { modePopup.selectItem(at: i) }
        modeNote.stringValue = Self.note(for: mode)

        // The slider is the blur amount, and belongs to the blur alone. In any other mode
        // it would move nothing, so it is greyed out rather than hidden.
        slider.doubleValue = settings.menuBarBackdropBlur
        slider.isEnabled = mode == .blur
        sliderRow.views.compactMap { $0 as? NSTextField }.forEach {
            $0.textColor = mode == .blur ? .labelColor : .disabledControlTextColor
        }

        // Nothing to show or hide when there is no bar.
        desktopCheckbox.state = settings.menuBarBackdropShowOnDesktop ? .on : .off
        desktopCheckbox.isEnabled = mode != .off
        desktopNote.textColor = mode == .off ? .disabledControlTextColor : .secondaryLabelColor

        let follow = mode == .solidFollow
        let allowed = access()
        accessStatus.isHidden = !follow
        accessButton.isHidden = !follow
        accessStatus.stringValue = allowed
            ? "Screen Recording: allowed. Only a thin row of pixels just under the menu bar is "
              + "read, and never stored. Pick another mode to stop it at once."
            : "Screen Recording: not allowed, so only Anode's own windows are matched; other apps "
              + "keep the plain block."
        accessStatus.textColor = allowed ? .secondaryLabelColor : .systemOrange
        layoutChanged?()
    }

    static func note(for mode: MenuBarBackdropMode) -> String {
        switch mode {
        case .off: return "The menu bar is left as macOS draws it, over the wallpaper."
        case .blur: return "A blur of the wallpaper under the bar. Slide toward See-through for the least blur, "
                         + "toward Max blur for the most. A plain-colour wallpaper has nothing to blur."
        case .solid: return "A solid block, so the wallpaper never shows behind the menu bar."
        case .solidFollow:
            return "A solid block that fades into the colour of the window under it. Other apps' "
                 + "windows are read from the screen, which needs Screen Recording permission."
        }
    }
}

// ── Window Switcher ─────────────────────────────────────────────────────────

/// Command-Tab through windows with previews (see `WindowSwitcher`): one switch, and what
/// it needs from macOS. Off until the user turns it on, because it takes over a system
/// shortcut.
final class WindowSwitcherFeature: BetaFeature {

    let title = "Window Switcher"
    let summary = "Replaces ⌘Tab with a switcher of windows, each with a preview. Hold ⌘ and press Tab "
                + "to move (⇧ to go back, arrows work too), let go of ⌘ to switch, Esc to cancel. "
                + "If Anode quits or crashes, ⌘Tab goes back to the system's at once."
    var layoutChanged: (() -> Void)?

    private let settings: Settings
    private let accessibility: () -> Bool
    private let screenRecording: () -> Bool
    private var token: AnyObject?

    // Internal, so the tests can drive them as a click would.
    let enableCheckbox = NSButton(checkboxWithTitle: "Use Anode's window switcher for ⌘Tab", target: nil, action: nil)
    let accessStatus = BetaFeaturesWindowController.wrapping("")
    let accessButton = NSButton(title: "Open Accessibility Settings…", target: nil, action: nil)
    let previewNote = BetaFeaturesWindowController.wrapping("", color: .secondaryLabelColor)

    init(settings: Settings = .shared,
         accessibilityAllowed: @escaping () -> Bool = { AccessibilityAccess.isTrusted },
         screenRecordingAllowed: @escaping () -> Bool = { ScreenRecordingAccess.isGranted }) {
        self.settings = settings
        self.accessibility = accessibilityAllowed
        self.screenRecording = screenRecordingAllowed
    }

    func makeView() -> NSView {
        enableCheckbox.target = self
        enableCheckbox.action = #selector(toggled)
        accessButton.target = self
        accessButton.action = #selector(openAccessibility)
        accessButton.bezelStyle = .rounded
        accessButton.controlSize = .small

        let column = NSStackView(views: [enableCheckbox, accessStatus, accessButton, previewNote])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        token = settings.observe(Settings.Key.windowSwitcherEnabled) { [weak self] in self?.refresh() }
        refresh()
        return column
    }

    @objc private func toggled() {
        let on = enableCheckbox.state == .on
        // Ask at the moment it is wanted, not before: the system dialog explains itself
        // best right after the user has asked for the thing that needs it.
        if on && !accessibility() { AccessibilityAccess.request() }
        settings.windowSwitcherEnabled = on
    }

    @objc private func openAccessibility() {
        AccessibilityAccess.openSettings()
    }

    func refresh() {
        let on = settings.windowSwitcherEnabled
        let allowed = accessibility()
        enableCheckbox.state = on ? .on : .off
        accessStatus.isHidden = !on
        accessButton.isHidden = !on || allowed
        accessStatus.stringValue = allowed
            ? "Accessibility: allowed. Only ⌘Tab, and Tab, the arrows and Esc while the switcher is open, "
              + "are taken; every other key goes on untouched."
            : "Accessibility: not allowed yet, so ⌘Tab is still the system's. Allow Anode in "
              + "Accessibility and it takes over within a couple of seconds."
        accessStatus.textColor = allowed ? .secondaryLabelColor : .systemOrange
        previewNote.isHidden = !on
        previewNote.stringValue = screenRecording()
            ? "Previews use the Screen Recording permission the menu bar backdrop already has."
            : "Without Screen Recording permission each window shows its app's icon instead of a preview."
        layoutChanged?()
    }
}

// ── Dock Previews ───────────────────────────────────────────────────────────

/// Resting on a Dock icon shows that app's windows (see `DockPreviews`).
final class DockPreviewFeature: BetaFeature {

    let title = "Dock Previews"
    let summary = "Rest the pointer on a running app's Dock icon to see its windows, minimized ones "
                + "included. Click one to bring it forward, or close it with its ✕."
    var layoutChanged: (() -> Void)?

    private let settings: Settings
    private let accessibility: () -> Bool
    private var token: AnyObject?
    private var holdToken: AnyObject?
    private var groupToken: AnyObject?

    // Internal, so the tests can drive them as a click would.
    let enableCheckbox = NSButton(checkboxWithTitle: "Show window previews on the Dock", target: nil, action: nil)
    let holdCheckbox = NSButton(checkboxWithTitle: "Keep an auto-hiding Dock up while a preview is open",
                                target: nil, action: nil)
    let groupCheckbox = NSButton(checkboxWithTitle: "Clicking an icon brings back the layout its window is tiled in",
                                 target: nil, action: nil)
    let holdNote = BetaFeaturesWindowController.wrapping(
        "Turns auto-hide off while a preview is open and back on when it closes. If Anode quits "
        + "unexpectedly while holding, auto-hide is turned back on at the next launch.",
        color: .secondaryLabelColor)
    let accessStatus = BetaFeaturesWindowController.wrapping("")
    let accessButton = NSButton(title: "Open Accessibility Settings…", target: nil, action: nil)

    init(settings: Settings = .shared,
         accessibilityAllowed: @escaping () -> Bool = { AccessibilityAccess.isTrusted }) {
        self.settings = settings
        self.accessibility = accessibilityAllowed
    }

    func makeView() -> NSView {
        enableCheckbox.target = self
        enableCheckbox.action = #selector(toggled)
        accessButton.target = self
        accessButton.action = #selector(openAccessibility)
        accessButton.bezelStyle = .rounded
        accessButton.controlSize = .small
        holdCheckbox.target = self
        holdCheckbox.action = #selector(holdToggled)
        groupCheckbox.target = self
        groupCheckbox.action = #selector(groupToggled)
        let column = NSStackView(views: [enableCheckbox, holdCheckbox, holdNote, groupCheckbox,
                                         accessStatus, accessButton])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        token = settings.observe(Settings.Key.dockPreviewsEnabled) { [weak self] in self?.refresh() }
        holdToken = settings.observe(Settings.Key.dockPreviewsHoldDock) { [weak self] in self?.refresh() }
        groupToken = settings.observe(Settings.Key.dockRaisesTileGroup) { [weak self] in self?.refresh() }
        refresh()
        return column
    }

    @objc private func toggled() {
        let on = enableCheckbox.state == .on
        if on && !accessibility() { AccessibilityAccess.request() }
        settings.dockPreviewsEnabled = on
    }

    @objc private func groupToggled() {
        settings.dockRaisesTileGroup = groupCheckbox.state == .on
    }

    @objc private func holdToggled() {
        settings.dockPreviewsHoldDock = holdCheckbox.state == .on
    }

    @objc private func openAccessibility() {
        AccessibilityAccess.openSettings()
    }

    func refresh() {
        let on = settings.dockPreviewsEnabled
        holdCheckbox.state = settings.dockPreviewsHoldDock ? .on : .off
        holdCheckbox.isEnabled = on
        groupCheckbox.state = settings.dockRaisesTileGroup ? .on : .off
        groupCheckbox.isEnabled = on
        holdNote.textColor = on ? .secondaryLabelColor : .disabledControlTextColor
        let allowed = accessibility()
        enableCheckbox.state = on ? .on : .off
        accessStatus.isHidden = !on
        accessButton.isHidden = !on || allowed
        accessStatus.stringValue = allowed
            ? "Accessibility: allowed. Anode is told which Dock icon the pointer is on; it watches the "
              + "pointer only while a preview is open."
            : "Accessibility: not allowed yet. Allow Anode in Accessibility and previews start within a "
              + "couple of seconds."
        accessStatus.textColor = allowed ? .secondaryLabelColor : .systemOrange
        layoutChanged?()
    }
}

// ── Desktop Switcher ────────────────────────────────────────────────────────

/// Option-Tab through desktops (see `DesktopSwitcher`): one switch and what it needs from macOS.
final class DesktopSwitcherFeature: BetaFeature {

    let title = "Desktop Switcher"
    let summary = "Option-Tab opens a row of your desktops, the one you used last first: hold ⌥ and press "
                + "Tab to move (⇧ to go back, arrows work too, and the number keys 1–9 pick Desktop N), let go "
                + "of ⌥ to go there, Esc to cancel. It goes to any desktop in one slide, however far away."
    var layoutChanged: (() -> Void)?

    private let settings: Settings
    private let accessibility: () -> Bool
    private var token: AnyObject?

    // Internal, so the tests can drive them as a click would.
    let enableCheckbox = NSButton(checkboxWithTitle: "Use Option-Tab to switch desktops", target: nil, action: nil)
    let accessStatus = BetaFeaturesWindowController.wrapping("")
    let accessButton = NSButton(title: "Open Accessibility Settings…", target: nil, action: nil)

    init(settings: Settings = .shared,
         accessibilityAllowed: @escaping () -> Bool = { AccessibilityAccess.isTrusted }) {
        self.settings = settings
        self.accessibility = accessibilityAllowed
    }

    func makeView() -> NSView {
        enableCheckbox.target = self
        enableCheckbox.action = #selector(toggled)
        accessButton.target = self
        accessButton.action = #selector(openAccessibility)
        accessButton.bezelStyle = .rounded
        accessButton.controlSize = .small
        let column = NSStackView(views: [enableCheckbox, accessStatus, accessButton])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        token = settings.observe(Settings.Key.desktopSwitcherEnabled) { [weak self] in self?.refresh() }
        refresh()
        return column
    }

    @objc private func toggled() {
        let on = enableCheckbox.state == .on
        if on && !accessibility() { AccessibilityAccess.request() }
        settings.desktopSwitcherEnabled = on
    }

    @objc private func openAccessibility() {
        AccessibilityAccess.openSettings()
    }

    func refresh() {
        let on = settings.desktopSwitcherEnabled
        let allowed = accessibility()
        enableCheckbox.state = on ? .on : .off
        accessStatus.isHidden = !on
        accessButton.isHidden = !on || allowed
        accessStatus.stringValue = !SpaceCatalog.isAvailable
            ? "This version of macOS does not offer what the desktop switcher needs, so Option-Tab is left alone."
            : !SpaceCatalog.keyboardSteppingEnabled()
            ? "It moves between desktops with the system's Control-Arrow shortcuts, which are turned off. Turn on "
              + "“Move left a space” and “Move right a space” in System Settings → Keyboard → Keyboard Shortcuts "
              + "→ Mission Control."
            : allowed
                ? "Accessibility: allowed. Only Option-Tab, and Tab, the arrows, the number keys and Esc while "
                  + "it is open, are taken; with a single desktop Option-Tab is left alone."
                : "Accessibility: not allowed yet, so Option-Tab does nothing. Allow Anode in Accessibility "
                  + "and it starts within a couple of seconds."
        accessStatus.textColor = allowed && SpaceCatalog.canSwitch ? .secondaryLabelColor : .systemOrange
        layoutChanged?()
    }
}

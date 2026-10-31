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
    /// One column of sections. The window is as many columns wide as it takes to fit the screen's
    /// height (it used to be one column, and with six features it was taller than the screen).
    static let columnWidth: CGFloat = 440
    static let columnGap: CGFloat = 28
    static let inset: CGFloat = 20
    static let maxColumns = 3

    let features: [BetaFeature]
    private var sections: [NSStackView] = []
    private var columns: [NSStackView] = []
    private let content = FlippedView()
    private let scroll = NSScrollView()
    private var activeToken: NSObjectProtocol?

    init(features: [BetaFeature] = [BackdropFeature(), WindowSwitcherFeature(), DesktopSwitcherFeature(),
                                    DockPreviewFeature(), WindowActionsFeature(), WindowGroupsFeature()]) {
        self.features = features
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.columnWidth + 2 * Self.inset, height: 200),
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

    /// Split `heights` (in order) into `count` runs of neighbours so that the tallest run is as short as
    /// it can be: the sections stay in the order they were listed, read down each column and then
    /// across. Pure, for tests.
    static func partition(heights: [CGFloat], into count: Int, spacing: CGFloat) -> [[Int]] {
        let n = heights.count
        guard n > 0 else { return [] }
        let k = max(1, min(count, n))
        func run(_ from: Int, _ to: Int) -> CGFloat {   // sections [from, to)
            heights[from..<to].reduce(0, +) + spacing * CGFloat(max(0, to - from - 1))
        }
        // best[j][i]: the smallest possible tallest run when the first i sections go into j columns.
        var best = Array(repeating: Array(repeating: CGFloat.infinity, count: n + 1), count: k + 1)
        var cut = Array(repeating: Array(repeating: 0, count: n + 1), count: k + 1)
        best[0][0] = 0
        for j in 1...k {
            for i in j...n {
                for m in (j - 1)..<i {
                    let candidate = max(best[j - 1][m], run(m, i))
                    if candidate < best[j][i] { best[j][i] = candidate; cut[j][i] = m }
                }
            }
        }
        var groups: [[Int]] = []
        var i = n
        for j in stride(from: k, through: 1, by: -1) {
            let m = cut[j][i]
            groups.insert(Array(m..<i), at: 0)
            i = m
        }
        return groups
    }

    /// How many columns the window needs: the fewest that make the tallest fit `available`, as long as
    /// the width fits `maxWidth`; otherwise as many as the width allows.
    static func columnCount(heights: [CGFloat], available: CGFloat, maxWidth: CGFloat, spacing: CGFloat) -> Int {
        let widthAllows = max(1, min(maxColumns, Int((maxWidth - 2 * inset + columnGap) / (columnWidth + columnGap))))
        for count in 1...widthAllows {
            let groups = partition(heights: heights, into: count, spacing: spacing)
            let tallest = groups.map { g in g.map { heights[$0] }.reduce(0, +) + spacing * CGFloat(max(0, g.count - 1)) }.max() ?? 0
            if tallest + 2 * inset <= available { return count }
        }
        return widthAllows
    }

    private func buildLayout() {
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = content
        window?.contentView = scroll

        if features.isEmpty {
            let label = NSTextField(labelWithString: Self.emptyText)
            label.frame.origin = NSPoint(x: Self.inset, y: Self.inset)
            label.sizeToFit()
            content.addSubview(label)
            fit()
            return
        }

        // Each feature is a section: its title, what it is, and its controls, one column wide.
        sections = features.map { feature in
            let title = NSTextField(labelWithString: feature.title)
            title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
            let summary = Self.wrapping(feature.summary, color: .secondaryLabelColor)
            let view = feature.makeView()
            let section = NSStackView(views: [title, summary, view])
            section.orientation = .vertical
            section.alignment = .leading
            section.spacing = 8
            section.translatesAutoresizingMaskIntoConstraints = false
            section.widthAnchor.constraint(equalToConstant: Self.columnWidth).isActive = true
            view.widthAnchor.constraint(lessThanOrEqualToConstant: Self.columnWidth).isActive = true
            return section
        }
        let heights = sections.map { section -> CGFloat in
            section.layoutSubtreeIfNeeded()
            return ceil(section.fittingSize.height)
        }
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let count = Self.columnCount(heights: heights, available: screen.height - 60, maxWidth: screen.width - 40, spacing: 22)
        let groups = Self.partition(heights: heights, into: count, spacing: 22)

        columns = groups.map { indices in
            let column = NSStackView()
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 22
            column.translatesAutoresizingMaskIntoConstraints = false
            // As tall as its sections and no taller, even beside a taller column.
            column.setHuggingPriority(.required, for: .vertical)
            for (n, i) in indices.enumerated() {
                if n > 0 {
                    let rule = NSBox(); rule.boxType = .separator
                    // A divider is a line, not a spring: left flexible it took all the spare height of a
                    // shorter column and pushed its last section to the bottom.
                    rule.setContentHuggingPriority(.required, for: .vertical)
                    rule.setContentCompressionResistancePriority(.required, for: .vertical)
                    column.addArrangedSubview(rule)
                    rule.widthAnchor.constraint(equalToConstant: Self.columnWidth).isActive = true
                }
                column.addArrangedSubview(sections[i])
            }
            return column
        }
        // Each column sits in a plain holder pinned to its top. The side-by-side stack makes its items as
        // tall as the tallest, and a column stretched like that spread its sections apart (a 671 pt column
        // drawn 827 pt tall); in a holder it keeps the height its sections need.
        let holders = columns.map { column -> NSView in
            let holder = NSView()
            holder.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(column)
            NSLayoutConstraint.activate([
                column.topAnchor.constraint(equalTo: holder.topAnchor),
                column.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                column.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
                column.bottomAnchor.constraint(lessThanOrEqualTo: holder.bottomAnchor),
                holder.widthAnchor.constraint(equalToConstant: Self.columnWidth),
            ])
            return holder
        }
        let row = NSStackView(views: holders)
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = Self.columnGap
        row.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.inset),
            row.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.inset),
        ])
        rowView = row
        fit()
    }

    private var rowView: NSStackView?

    /// Resize the window to what is in it (as tall as the screen allows, then it scrolls), keeping its top
    /// edge where it was.
    private func fit() {
        guard let window else { return }
        let contentSize: NSSize
        if let rowView {
            rowView.layoutSubtreeIfNeeded()
            let fit = rowView.fittingSize
            contentSize = NSSize(width: ceil(fit.width) + 2 * Self.inset, height: ceil(fit.height) + 2 * Self.inset)
        } else {
            contentSize = NSSize(width: Self.columnWidth + 2 * Self.inset, height: 80)
        }
        content.frame = NSRect(origin: .zero, size: contentSize)
        let limit = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let shown = NSSize(width: contentSize.width, height: min(contentSize.height, limit - 60))
        let top = window.frame.maxY
        window.setContentSize(shown)
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
    }

    /// A wrapped label that does not grow the window sideways.
    static func wrapping(_ text: String, color: NSColor = .labelColor, size: CGFloat = NSFont.smallSystemFontSize)
        -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        label.preferredMaxLayoutWidth = columnWidth
        return label
    }
}

/// A view whose origin is at the top, so a scroll view shows its content from the top down.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
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
    let summary = "A switcher of windows, each with a preview. Hold the keys and press Tab to move (⇧ to go back, "
                + "arrows work too), let go to switch, Esc to cancel. By default it opens on ⌘⌥Tab and the system's "
                + "⌘Tab is left alone. If Anode quits or crashes, the keys go back to the system at once."
    var layoutChanged: (() -> Void)?

    private let settings: Settings
    private let accessibility: () -> Bool
    private let screenRecording: () -> Bool
    private var token: AnyObject?
    private var triggerToken: AnyObject?

    // Internal, so the tests can drive them as a click would.
    let enableCheckbox = NSButton(checkboxWithTitle: "Use Anode's window switcher", target: nil, action: nil)
    let triggerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let triggerLabel = NSTextField(labelWithString: "Open with:")
    let accessStatus = BetaFeaturesWindowController.wrapping("")
    let accessButton = NSButton(title: "Open Accessibility Settings…", target: nil, action: nil)
    let previewNote = BetaFeaturesWindowController.wrapping("", color: .secondaryLabelColor)
    let previewButton = NSButton(title: "Open Screen Recording Settings…", target: nil, action: nil)
    private let previewsFailing: () -> Bool

    init(settings: Settings = .shared,
         accessibilityAllowed: @escaping () -> Bool = { AccessibilityAccess.isTrusted },
         screenRecordingAllowed: @escaping () -> Bool = { ScreenRecordingAccess.isGranted },
         previewsFailing: @escaping () -> Bool = { WindowThumbnails.grantedButFailing }) {
        self.settings = settings
        self.accessibility = accessibilityAllowed
        self.screenRecording = screenRecordingAllowed
        self.previewsFailing = previewsFailing
    }

    func makeView() -> NSView {
        enableCheckbox.target = self
        enableCheckbox.action = #selector(toggled)
        accessButton.target = self
        accessButton.action = #selector(openAccessibility)
        accessButton.bezelStyle = .rounded
        accessButton.controlSize = .small

        previewButton.target = self
        previewButton.action = #selector(openScreenRecording)
        previewButton.bezelStyle = .rounded
        previewButton.controlSize = .small
        triggerPopup.addItems(withTitles: WindowSwitcherTrigger.allCases.map(\.title))
        triggerPopup.target = self
        triggerPopup.action = #selector(triggerChanged)
        let triggerRow = NSStackView(views: [triggerLabel, triggerPopup])
        triggerRow.spacing = 8
        let column = NSStackView(views: [enableCheckbox, triggerRow, accessStatus, accessButton, previewNote, previewButton])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        token = settings.observe(Settings.Key.windowSwitcherEnabled) { [weak self] in self?.refresh() }
        triggerToken = settings.observe(Settings.Key.windowSwitcherTrigger) { [weak self] in self?.refresh() }
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

    @objc private func triggerChanged() {
        let all = WindowSwitcherTrigger.allCases, i = triggerPopup.indexOfSelectedItem
        guard all.indices.contains(i) else { return }
        settings.windowSwitcherTrigger = all[i]
    }

    @objc private func openScreenRecording() {
        ScreenRecordingAccess.request()
        ScreenRecordingAccess.openSettings()
    }

    func refresh() {
        let on = settings.windowSwitcherEnabled
        let allowed = accessibility()
        enableCheckbox.state = on ? .on : .off
        let trigger = settings.windowSwitcherTrigger
        if let i = WindowSwitcherTrigger.allCases.firstIndex(of: trigger) { triggerPopup.selectItem(at: i) }
        triggerPopup.isEnabled = on
        accessStatus.isHidden = !on
        accessButton.isHidden = !on || allowed
        accessStatus.stringValue = allowed
            ? "Accessibility: allowed. Only \(trigger.label), and Tab, the arrows and Esc while the switcher is open, "
              + "are taken; every other key goes on untouched"
              + (trigger == .commandOption ? ", and ⌘Tab is still the system's." : ".")
            : "Accessibility: not allowed yet, so \(trigger.label) does nothing. Allow Anode in "
              + "Accessibility and it starts within a couple of seconds."
        accessStatus.textColor = allowed ? .secondaryLabelColor : .systemOrange
        previewNote.isHidden = !on
        let granted = screenRecording(), failing = granted && previewsFailing()
        previewNote.stringValue = failing
            ? "Screen Recording looks allowed, but macOS returned no window pictures, so tiles show app icons. "
              + "That is what a stale approval looks like after an update: in System Settings → Privacy & Security → "
              + "Screen Recording, switch Anode off and on again (or remove it with − and add it back), then reopen Anode."
            : granted
                ? "Previews use the Screen Recording permission the menu bar backdrop already has."
                : "Without Screen Recording permission each window shows its app's icon instead of a preview. "
                  + "Allow Anode under Privacy & Security → Screen Recording, then reopen Anode."
        previewNote.textColor = granted && !failing ? .secondaryLabelColor : .systemOrange
        previewButton.isHidden = !on || (granted && !failing)
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
    let groupCheckbox = NSButton(checkboxWithTitle: "Clicking an icon brings back its tiled layout",
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
        groupCheckbox.toolTip = "Guesses the layout from where windows sit. Off while Window Groups is on, which uses the groups you made instead."
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

// ── Window Actions ──────────────────────────────────────────────────────────

/// Halves, thirds, quarters, maximize, center and display moves from the keyboard (see `WindowSnapper`).
final class WindowActionsFeature: BetaFeature {

    let title = "Window Actions"
    let summary = "Put the front window in a half, third or quarter of the screen, maximize or center it, "
                + "or send it to the next display, with the same Control-Option shortcuts Rectangle uses. "
                + "Windows are sized for a Dock that hides, even while Anode is holding the Dock up for a preview."
    var layoutChanged: (() -> Void)?

    private let settings: Settings
    private let accessibility: () -> Bool
    private var token: AnyObject?
    private var dragToken: AnyObject?

    let enableCheckbox = NSButton(checkboxWithTitle: "Use Anode's window actions", target: nil, action: nil)
    let dragCheckbox = NSButton(checkboxWithTitle: "Snap windows by dragging them to a screen edge or corner",
                                target: nil, action: nil)
    let dragNote = BetaFeaturesWindowController.wrapping("", color: .secondaryLabelColor)
    private let nativeTiling: () -> Bool
    let status = BetaFeaturesWindowController.wrapping("")
    let accessButton = NSButton(title: "Open Accessibility Settings…", target: nil, action: nil)
    let shortcuts = BetaFeaturesWindowController.wrapping("", color: .secondaryLabelColor)
    let customizeButton = NSButton(title: "Customize shortcuts…", target: nil, action: nil)

    init(settings: Settings = .shared,
         accessibilityAllowed: @escaping () -> Bool = { AccessibilityAccess.isTrusted },
         nativeEdgeTiling: @escaping () -> Bool = { WindowActionsFeature.macOSEdgeTilingIsOn() }) {
        self.settings = settings
        self.accessibility = accessibilityAllowed
        self.nativeTiling = nativeEdgeTiling
    }

    /// Is macOS's own "tile by dragging to a screen edge" on? Then both it and this would act on one drag.
    static func macOSEdgeTilingIsOn() -> Bool {
        let d = UserDefaults(suiteName: "com.apple.WindowManager")
        return d?.bool(forKey: "EnableTilingByEdgeDrag") == true || d?.bool(forKey: "EnableTopTilingByEdgeDrag") == true
    }

    func makeView() -> NSView {
        enableCheckbox.target = self
        enableCheckbox.action = #selector(toggled)
        accessButton.target = self
        accessButton.action = #selector(openAccessibility)
        accessButton.bezelStyle = .rounded
        accessButton.controlSize = .small
        dragCheckbox.target = self
        dragCheckbox.action = #selector(dragToggled)
        customizeButton.target = self
        customizeButton.action = #selector(customize)
        customizeButton.bezelStyle = .rounded
        customizeButton.controlSize = .small
        let column = NSStackView(views: [enableCheckbox, status, accessButton, dragCheckbox, dragNote, shortcuts, customizeButton])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        token = settings.observe(Settings.Key.windowSnapperEnabled) { [weak self] in self?.refresh() }
        dragToken = settings.observe(Settings.Key.windowDragSnapEnabled) { [weak self] in self?.refresh() }
        refresh()
        return column
    }

    @objc private func toggled() {
        let on = enableCheckbox.state == .on
        if on && !accessibility() { AccessibilityAccess.request() }
        settings.windowSnapperEnabled = on
        // The hot keys are registered as the setting changes; what they said is read a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.refresh() }
    }

    @objc private func customize() { ShortcutsWindowController.shared.show() }

    @objc private func dragToggled() {
        let on = dragCheckbox.state == .on
        if on && !accessibility() { AccessibilityAccess.request() }
        settings.windowDragSnapEnabled = on
    }

    @objc private func openAccessibility() { AccessibilityAccess.openSettings() }

    /// The shortcuts as text, in the order they are listed.
    static func shortcutList(store: ShortcutStore = .shared) -> String {
        WindowAction.allCases.map { "\($0.title) \(store.shortcut(for: $0.command)?.label ?? "—")" }.joined(separator: "   ·   ")
    }

    func refresh() {
        let on = settings.windowSnapperEnabled
        let allowed = accessibility()
        enableCheckbox.state = on ? .on : .off
        status.isHidden = !on
        accessButton.isHidden = !on || allowed
        shortcuts.isHidden = !on
        customizeButton.isHidden = !on
        shortcuts.stringValue = Self.shortcutList()
        dragCheckbox.state = settings.windowDragSnapEnabled ? .on : .off
        let nativeOn = settings.windowDragSnapEnabled && nativeTiling()
        dragNote.stringValue = nativeOn
            ? "macOS's own edge tiling is on, so both would act on the same drag. Turn it off in System Settings → "
              + "Desktop & Dock → Windows → “Tile by dragging windows to screen edges”."
            : "Drag by the title bar to an edge or corner: left/right edges halves, corners quarters, the menu bar "
              + "maximizes, and the bottom edge thirds (left, middle or right of the screen). Edges shared with "
              + "another display are skipped. Esc while dragging cancels."
        dragNote.textColor = nativeOn ? .systemOrange : .secondaryLabelColor
        if !allowed {
            status.stringValue = "Accessibility: not allowed yet, so windows cannot be moved. Allow Anode in Accessibility."
            status.textColor = .systemOrange
        } else {
            status.stringValue = "Accessibility: allowed. These shortcuts are yours to change, and they win over macOS's "
                + "and other apps' shortcuts while this is on."
            status.textColor = .secondaryLabelColor
        }
        layoutChanged?()
    }
}

// ── Window Groups ───────────────────────────────────────────────────────────

/// Windows that come forward together (see `WindowGroupController`).
final class WindowGroupsFeature: BetaFeature {

    let title = "Window Groups"
    let summary = "Put windows from any apps in a group, and when one comes forward by any route — a click, ⌘Tab, "
                + "the Dock — the others come forward right behind it. A group remembers where each window sat, "
                + "so one shortcut puts the layout back. Groups last until Anode quits or the windows close."
    var layoutChanged: (() -> Void)?

    private let settings: Settings
    private let accessibility: () -> Bool
    private let controller: () -> WindowGroupController?
    private var token: AnyObject?

    let enableCheckbox = NSButton(checkboxWithTitle: "Use window groups", target: nil, action: nil)
    let status = BetaFeaturesWindowController.wrapping("")
    let accessButton = NSButton(title: "Open Accessibility Settings…", target: nil, action: nil)
    let groupList = BetaFeaturesWindowController.wrapping("")
    let tiledButton = NSButton(title: "Group the tiled windows", target: nil, action: nil)
    let addButton = NSButton(title: "Add window to current group", target: nil, action: nil)
    let removeButton = NSButton(title: "Take window out", target: nil, action: nil)
    let restoreButton = NSButton(title: "Restore layout", target: nil, action: nil)
    let rememberButton = NSButton(title: "Remember layout", target: nil, action: nil)
    let dissolveButton = NSButton(title: "Dissolve all", target: nil, action: nil)
    let shortcuts = BetaFeaturesWindowController.wrapping("", color: .secondaryLabelColor)
    let customizeButton = NSButton(title: "Customize shortcuts…", target: nil, action: nil)
    private let buttons: NSStackView

    init(settings: Settings = .shared,
         accessibilityAllowed: @escaping () -> Bool = { AccessibilityAccess.isTrusted },
         controller: @escaping () -> WindowGroupController? = { (NSApp.delegate as? AppDelegate)?.windowGroups }) {
        self.settings = settings
        self.accessibility = accessibilityAllowed
        self.controller = controller
        buttons = NSStackView(views: [tiledButton, addButton, removeButton, restoreButton, rememberButton, dissolveButton])
    }

    func makeView() -> NSView {
        enableCheckbox.target = self
        enableCheckbox.action = #selector(toggled)
        accessButton.target = self
        accessButton.action = #selector(openAccessibility)
        for (button, action) in [(tiledButton, #selector(group)), (addButton, #selector(add)), (removeButton, #selector(remove)),
                                 (restoreButton, #selector(restore)), (rememberButton, #selector(remember)),
                                 (dissolveButton, #selector(dissolve))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        accessButton.bezelStyle = .rounded
        accessButton.controlSize = .small
        buttons.orientation = .vertical
        buttons.alignment = .leading
        buttons.spacing = 4
        customizeButton.target = self
        customizeButton.action = #selector(customize)
        customizeButton.bezelStyle = .rounded
        customizeButton.controlSize = .small
        let column = NSStackView(views: [enableCheckbox, status, accessButton, groupList, buttons, shortcuts, customizeButton])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        token = settings.observe(Settings.Key.windowGroupsEnabled) { [weak self] in self?.refresh() }
        refresh()
        return column
    }

    @objc private func toggled() {
        let on = enableCheckbox.state == .on
        if on && !accessibility() { AccessibilityAccess.request() }
        settings.windowGroupsEnabled = on
        controller()?.onChange = { [weak self] in self?.refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.refresh() }
    }

    @objc private func openAccessibility() { AccessibilityAccess.openSettings() }
    @objc private func customize() { ShortcutsWindowController.shared.show() }
    @objc private func group() { controller()?.toggleGroup(); refresh() }
    @objc private func add() { controller()?.addToCurrentGroup(); refresh() }
    @objc private func remove() { controller()?.removeFromGroup(); refresh() }
    @objc private func restore() { controller()?.restoreLayout() }
    @objc private func remember() { controller()?.rememberLayout(); refresh() }
    @objc private func dissolve() { controller()?.dissolveAll(); refresh() }

    static func shortcutList(store: ShortcutStore = .shared) -> String {
        GroupAction.allCases.map { "\($0.title) \(store.shortcut(for: $0.command)?.label ?? "—")" }.joined(separator: "   ·   ")
    }

    func refresh() {
        let on = settings.windowGroupsEnabled
        let allowed = accessibility()
        let c = controller()
        c?.onChange = { [weak self] in self?.refresh() }
        enableCheckbox.state = on ? .on : .off
        status.isHidden = !on
        accessButton.isHidden = !on || allowed
        groupList.isHidden = !on
        buttons.isHidden = !on
        shortcuts.isHidden = !on
        customizeButton.isHidden = !on
        shortcuts.stringValue = Self.shortcutList()
        if !allowed {
            status.stringValue = "Accessibility: not allowed yet, so windows cannot be raised. Allow Anode in Accessibility."
            status.textColor = .systemOrange
        } else {
            status.stringValue = "The buttons act on the last window you were in outside Anode."
            status.textColor = .secondaryLabelColor
        }
        let lines = c?.summary() ?? []
        groupList.stringValue = lines.isEmpty ? "No groups yet." : lines.joined(separator: "\n")
        layoutChanged?()
    }
}

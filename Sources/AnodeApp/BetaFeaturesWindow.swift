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

    /// The sections this Mac gets, in order. Lid Glass is left out where there is no lid-angle sensor
    /// (a MacBook Neo, a desktop Mac): a section whose only message is "not supported on this Mac" is
    /// clutter, and its Screen Recording request would be for an effect that can never run.
    static func defaultFeatures(hasLidSensor: Bool = LidGlassFeature.isSupportedHere) -> [BetaFeature] {
        var list: [BetaFeature] = [BackdropFeature(), WindowSwitcherFeature(), DesktopSwitcherFeature(),
                                   DockPreviewFeature(), WindowActionsFeature(), WindowGroupsFeature()]
        if hasLidSensor { list.append(LidGlassFeature()) }
        list += [KeepAwakeFeature(), KeyboardCleanerFeature(), LiveWallpaperFeature(), GameModeFeature(), MenuBarHiderFeature(),
                 ChargeControlFeature()]
        return list
    }

    init(features: [BetaFeature] = BetaFeaturesWindowController.defaultFeatures()) {
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
            // A loop with typed steps, not one expression: older Swift compilers gave up on the single
            // `groups.map { ... reduce(0, +) + spacing * CGFloat(...) }.max() ?? 0` ("unable to type-check this
            // expression in reasonable time"), and the install failed on a Mac with one.
            var tallest: CGFloat = 0
            for group in groups {
                let stacked: CGFloat = group.reduce(CGFloat(0)) { $0 + heights[$1] }
                let gaps: CGFloat = spacing * CGFloat(max(0, group.count - 1))
                tallest = max(tallest, stacked + gaps)
            }
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
    let resetButton = NSButton(title: "Already on? Reset Anode's approval and ask again", target: nil, action: nil)
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
        resetButton.target = self
        resetButton.action = #selector(resetAccessibility)
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small

        previewButton.target = self
        previewButton.action = #selector(openScreenRecording)
        previewButton.bezelStyle = .rounded
        previewButton.controlSize = .small
        triggerPopup.addItems(withTitles: WindowSwitcherTrigger.allCases.map(\.title))
        triggerPopup.target = self
        triggerPopup.action = #selector(triggerChanged)
        let triggerRow = NSStackView(views: [triggerLabel, triggerPopup])
        triggerRow.spacing = 8
        let column = NSStackView(views: [enableCheckbox, triggerRow, accessStatus, accessButton, resetButton, previewNote, previewButton])
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

    @objc private func resetAccessibility() { AccessibilityAccess.resetAndAsk() }

    @objc private func triggerChanged() {
        let all = WindowSwitcherTrigger.allCases, i = triggerPopup.indexOfSelectedItem
        guard all.indices.contains(i) else { return }
        settings.windowSwitcherTrigger = all[i]
    }

    /// The button is shown only while the permission is refused (or granted but returning nothing), so there is
    /// no good approval to lose by clearing a dead one first: Settings opened on a switch that is lit but
    /// ignored, with nothing to press, was what the Neo's owner was left with.
    @objc private func openScreenRecording() {
        ApprovalRepair.reset(.screenRecording) {
            ScreenRecordingAccess.request()
            ScreenRecordingAccess.openSettings()
        }
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
        resetButton.isHidden = !on || allowed
        accessStatus.stringValue = allowed
            ? "Accessibility: allowed. Only \(trigger.label), and Tab, the arrows and Esc while the switcher is open, "
              + "are taken; every other key goes on untouched"
              + (trigger == .commandOption ? ", and ⌘Tab is still the system's." : ".")
            : "Accessibility: not allowed yet, so \(trigger.label) does nothing. Allow Anode in "
              + "Accessibility and it starts within a couple of seconds. If Anode is already switched on there, "
              + "that approval belongs to an older build of it: Reset below clears it so macOS asks afresh."
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
    let resetButton = NSButton(title: "Already on? Reset Anode's approval and ask again", target: nil, action: nil)

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
        resetButton.target = self
        resetButton.action = #selector(resetAccessibility)
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        let column = NSStackView(views: [enableCheckbox, accessStatus, accessButton, resetButton])
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

    @objc private func resetAccessibility() { AccessibilityAccess.resetAndAsk() }

    func refresh() {
        let on = settings.desktopSwitcherEnabled
        let allowed = accessibility()
        enableCheckbox.state = on ? .on : .off
        accessStatus.isHidden = !on
        accessButton.isHidden = !on || allowed
        resetButton.isHidden = !on || allowed
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
                  + "and it starts within a couple of seconds. If Anode is already switched on there, that approval "
                  + "belongs to an older build of it: Reset below clears it so macOS asks afresh."
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
    let customizeButton = NSButton(title: "Customize actions & shortcuts…", target: nil, action: nil)

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
              + "maximizes, and the bottom edge thirds (left, middle or right of the screen). Which edge does what, "
              + "a gap around windows and a key to hold are in Customize. Edges shared with another display are "
              + "skipped. Esc while dragging cancels."
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
    @objc private func customize() { ShortcutsWindowController.shared.show(selecting: GroupAction.toggleGroup.commandID) }
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

// ── Lid Glass ───────────────────────────────────────────────────────────────

/// The iPhone Duo fold as the lid closes, and unfolding as it opens again (see `LidGlass`).
final class LidGlassFeature: BetaFeature {

    let title = "Lid Glass"
    let summary = "The iPhone Duo fold for your MacBook: as you close the lid the screen holds still in the room "
                + "while the glass tips away from it like a lens, the far edge softening into the dark; open the lid "
                + "and it unfolds again. Built-in screen only, and it needs Screen Recording to take the picture it folds."
    var layoutChanged: (() -> Void)?

    /// Does this Mac have the lid-angle sensor the effect is driven by? Asked once: hardware does not appear
    /// or vanish while the app runs.
    static let isSupportedHere: Bool = LidAngleSensor().isAvailable

    private let settings: Settings
    private let screenRecording: () -> Bool
    private let status: () -> LidGlassStatus
    private let macOS14: Bool
    private var tokens: [AnyObject] = []

    // Internal, so the tests can drive them as a click would.
    let enableCheckbox = NSButton(checkboxWithTitle: "Frost the screen as the lid closes", target: nil, action: nil)
    let idleRateLabel = NSTextField(labelWithString: "")
    let idleRateSlider = NSSlider(value: 8, minValue: 4, maxValue: 30, target: nil, action: nil)
    let triggerLabel = NSTextField(labelWithString: "")
    let triggerSlider = NSSlider(value: 110, minValue: 60, maxValue: 150, target: nil, action: nil)
    let accessStatus = BetaFeaturesWindowController.wrapping("")
    let accessButton = NSButton(title: "Open Screen Recording Settings…", target: nil, action: nil)

    init(settings: Settings = .shared,
         screenRecordingAllowed: @escaping () -> Bool = { ScreenRecordingAccess.isGranted },
         status: @escaping () -> LidGlassStatus = { LidGlass.current?.status ?? .off },
         macOS14: Bool = { if #available(macOS 14.0, *) { return true } else { return false } }()) {
        self.settings = settings
        self.screenRecording = screenRecordingAllowed
        self.status = status
        self.macOS14 = macOS14
    }

    func makeView() -> NSView {
        enableCheckbox.target = self
        enableCheckbox.action = #selector(toggled)
        idleRateSlider.target = self
        idleRateSlider.action = #selector(idleRateMoved)
        triggerSlider.target = self
        triggerSlider.action = #selector(triggerMoved)
        for slider in [idleRateSlider, triggerSlider] {
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        }
        accessButton.target = self
        accessButton.action = #selector(openScreenRecording)
        accessButton.bezelStyle = .rounded
        accessButton.controlSize = .small
        let idleRow = NSStackView(views: [idleRateLabel, idleRateSlider])
        idleRow.spacing = 8
        let triggerRow = NSStackView(views: [triggerLabel, triggerSlider])
        triggerRow.spacing = 8
        let column = NSStackView(views: [enableCheckbox, idleRow, triggerRow, accessStatus, accessButton])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        tokens = [Settings.Key.lidGlassEnabled, Settings.Key.lidGlassIdleHz, Settings.Key.lidGlassTriggerAngle].map { key in
            settings.observe(key) { [weak self] in self?.refresh() }
        }
        LidGlass.current?.onStatusChange = { [weak self] in self?.refresh() }
        refresh()
        return column
    }

    @objc private func toggled() {
        let on = enableCheckbox.state == .on
        // Ask at the moment it is wanted, as the other Screen Recording features do.
        if on && !screenRecording() { ScreenRecordingAccess.request() }
        settings.lidGlassEnabled = on
    }

    @objc private func idleRateMoved() { settings.lidGlassIdleHz = idleRateSlider.doubleValue.rounded() }

    @objc private func triggerMoved() { settings.lidGlassTriggerAngle = triggerSlider.doubleValue.rounded() }

    @objc private func openScreenRecording() {
        ScreenRecordingAccess.request()
        ScreenRecordingAccess.openSettings()
    }

    func refresh() {
        let on = settings.lidGlassEnabled && macOS14
        enableCheckbox.state = settings.lidGlassEnabled ? .on : .off
        enableCheckbox.isEnabled = macOS14
        let hz = Int(settings.lidGlassIdleHz.rounded()), angle = Int(settings.lidGlassTriggerAngle.rounded())
        idleRateSlider.doubleValue = settings.lidGlassIdleHz
        triggerSlider.doubleValue = settings.lidGlassTriggerAngle
        idleRateLabel.stringValue = hz < 10
            ? "Lid check rate when wide open: \(hz) Hz (10 Hz near closing)"
            : "Lid check rate while open: \(hz) Hz"
        triggerLabel.stringValue = "Starts frosting at: \(angle)°"
        idleRateSlider.isHidden = !on; idleRateLabel.isHidden = !on
        triggerSlider.isHidden = !on; triggerLabel.isHidden = !on

        let granted = screenRecording()
        let state = status()
        accessStatus.isHidden = !(on || !macOS14)
        accessButton.isHidden = !on || granted
        if !macOS14 {
            accessStatus.stringValue = "Lid Glass needs macOS 14 or later."
            accessStatus.textColor = .systemOrange
        } else if state == .unsupported {
            accessStatus.stringValue = "Lid Glass is not supported on this Mac: it has no lid-angle sensor."
            accessStatus.textColor = .systemOrange
        } else if state == .sensorLost {
            accessStatus.stringValue = "The lid sensor stopped responding, so Lid Glass is paused. Turn it off and on to try again."
            accessStatus.textColor = .systemOrange
        } else if !granted {
            accessStatus.stringValue = "Screen Recording: not allowed yet, so there is no picture to frost and nothing happens. "
                + "Allow Anode under Privacy & Security → Screen Recording, then reopen Anode."
            accessStatus.textColor = .systemOrange
        } else {
            accessStatus.stringValue = "Screen Recording: allowed. The lid is read \(hz) times a second while it is open (never slower than "
                + "10 near closing, which is how often the sensor itself updates), faster while it closes; nothing is recorded or kept."
            accessStatus.textColor = .secondaryLabelColor
        }
        layoutChanged?()
    }
}

// ── Keep Awake ──────────────────────────────────────────────────────────────

/// A Caffeine-style icon in the menu bar: Never Sleep, and Always Stay Awake with the lid closed (see `KeepAwake`).
final class KeepAwakeFeature: BetaFeature {

    let title = "Keep Awake"
    let summary = "An icon in the menu bar, like Caffeine, that each click moves along: off (dark laptop) → Never Sleep "
                + "(lit laptop) → Always Stay Awake (shut laptop) → off. Never Sleep keeps the Mac and its screen awake while the lid "
                + "is open. Always Stay Awake also keeps the Mac running with the lid closed and nothing attached: the "
                + "screen goes fully dark while the lid is shut and comes back to its old brightness when it opens. "
                + "It needs a one-time admin permission, and turns itself off if the battery gets low. Right-click the "
                + "icon for the menu."
    var layoutChanged: (() -> Void)?

    private let settings: Settings
    private let isAuthorised: () -> Bool
    private var token: AnyObject?

    let enableCheckbox = NSButton(checkboxWithTitle: "Show the Keep Awake icon in the menu bar", target: nil, action: nil)
    let stateLabel = BetaFeaturesWindowController.wrapping("")
    let permissionLabel = BetaFeaturesWindowController.wrapping("")
    let permissionButton = NSButton(title: "", target: nil, action: nil)
    let modePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let durationPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let switchButton = NSButton(title: "", target: nil, action: nil)

    init(settings: Settings = .shared,
         isAuthorised: @escaping () -> Bool = { PmsetClosedLidSleep().isAuthorised() }) {
        self.settings = settings
        self.isAuthorised = isAuthorised
    }

    func makeView() -> NSView {
        enableCheckbox.target = self
        enableCheckbox.action = #selector(toggled)
        permissionButton.target = self
        permissionButton.action = #selector(permissionClicked)
        permissionButton.bezelStyle = .rounded
        permissionButton.controlSize = .small
        for m in KeepAwakeMode.allCases { modePopUp.addItem(withTitle: "\(m.title) — \(m.detail)") }
        modePopUp.target = self
        modePopUp.action = #selector(modePicked)
        for d in KeepAwakeDuration.allCases { durationPopUp.addItem(withTitle: d.title) }
        durationPopUp.target = self
        durationPopUp.action = #selector(durationPicked)
        switchButton.target = self
        switchButton.action = #selector(switchClicked)
        switchButton.bezelStyle = .rounded
        let modeRow = NSStackView(views: [NSTextField(labelWithString: "Mode:"), modePopUp])
        modeRow.spacing = 8
        let durationRow = NSStackView(views: [NSTextField(labelWithString: "For:"), durationPopUp])
        durationRow.spacing = 8
        let column = NSStackView(views: [enableCheckbox, stateLabel, modeRow, durationRow, switchButton,
                                         permissionLabel, permissionButton])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        token = settings.observe(Settings.Key.keepAwakeEnabled) { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
        KeepAwakeController.current?.onChange = { [weak self] in self?.refresh() }
        refresh()
        return column
    }

    @objc private func toggled() { settings.keepAwakeEnabled = enableCheckbox.state == .on }

    /// Changing the mode switches to it at once if Keep Awake is running, as the menu does; otherwise it is the
    /// mode the next click on the icon starts.
    @objc private func modePicked() {
        guard let c = KeepAwakeController.current else { return }
        let m = KeepAwakeMode.allCases[max(0, modePopUp.indexOfSelectedItem)]
        if c.core.isActive { c.begin(m) } else { c.mode = m }
    }

    @objc private func durationPicked() {
        guard let c = KeepAwakeController.current else { return }
        c.duration = KeepAwakeDuration.allCases[max(0, durationPopUp.indexOfSelectedItem)]
        if let s = c.core.session { c.begin(s.mode) }
    }

    @objc private func switchClicked() { KeepAwakeController.current?.toggle() }

    @objc private func permissionClicked() {
        guard let c = KeepAwakeController.current else { return }
        if isAuthorised() {
            c.revokeAuthorisation { [weak self] _ in self?.refresh() }
        } else {
            c.authorise { [weak self] _ in self?.refresh() }
        }
    }

    func refresh() {
        let on = settings.keepAwakeEnabled
        enableCheckbox.state = on ? .on : .off
        stateLabel.isHidden = !on
        stateLabel.stringValue = "Now: " + (KeepAwakeController.current?.statusLine() ?? "Off")
        stateLabel.textColor = .secondaryLabelColor
        let allowed = isAuthorised()
        permissionLabel.isHidden = !on
        permissionButton.isHidden = !on
        for v in [modePopUp, durationPopUp, switchButton] as [NSView] { v.isHidden = !on }
        modePopUp.superview?.isHidden = !on
        durationPopUp.superview?.isHidden = !on
        if let c = KeepAwakeController.current {
            modePopUp.selectItem(at: KeepAwakeMode.allCases.firstIndex(of: c.core.session?.mode ?? c.mode) ?? 0)
            durationPopUp.selectItem(at: KeepAwakeDuration.allCases.firstIndex(of: c.duration) ?? 0)
            switchButton.title = c.core.isActive ? "Turn Off" : "Turn On"
        }
        if allowed {
            permissionLabel.stringValue = "Always Stay Awake is allowed: Anode may run exactly “pmset -a disablesleep 1” "
                + "and “0” without a password (the rule is in \(KeepAwakeAuthorisation.path)). Anode switches it off "
                + "when you turn it off, when you quit, and at launch if a crash left it on."
            permissionButton.title = "Remove Always Stay Awake permission…"
        } else {
            permissionLabel.stringValue = "Always Stay Awake is not allowed yet. Never Sleep works without it."
            permissionButton.title = "Allow Always Stay Awake…"
        }
        permissionLabel.textColor = .secondaryLabelColor
        layoutChanged?()
    }
}

// ── Keyboard & Screen Cleaner ───────────────────────────────────────────────

/// Turns every screen black and ignores the keyboard, mouse and trackpad (see `KeyboardCleaner`).
final class KeyboardCleanerFeature: BetaFeature {

    let title = "Keyboard & Screen Cleaner"
    let summary = "Turns every screen pure black and ignores the keyboard, mouse and trackpad, so you can wipe them without "
                + "typing into anything. The combination printed in the bottom-left corner of the screen ends it. "
                + "It needs Accessibility, and the Mac stays awake while it is up."
    var layoutChanged: (() -> Void)?

    private let settings: Settings
    private let store: ShortcutStore
    private let cleaner: () -> KeyboardCleaner?
    private let accessibility: () -> Bool
    private let requestAccessibility: () -> Void

    let startButton = NSButton(title: "Clean now", target: nil, action: nil)
    let statusLabel = BetaFeaturesWindowController.wrapping("")
    let accessButton = NSButton(title: "Open Accessibility Settings…", target: nil, action: nil)
    let shortcutCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let exitNote = BetaFeaturesWindowController.wrapping("", color: .secondaryLabelColor)
    let customizeButton = NSButton(title: "Customize shortcuts…", target: nil, action: nil)

    init(settings: Settings = .shared, store: ShortcutStore = .shared,
         cleaner: @escaping () -> KeyboardCleaner? = { KeyboardCleaner.current },
         accessibilityAllowed: @escaping () -> Bool = { AccessibilityAccess.isTrusted },
         requestAccessibility: @escaping () -> Void = { AccessibilityAccess.request() }) {
        self.settings = settings
        self.store = store
        self.cleaner = cleaner
        self.accessibility = accessibilityAllowed
        self.requestAccessibility = requestAccessibility
    }

    func makeView() -> NSView {
        startButton.target = self
        startButton.action = #selector(startClicked)
        startButton.bezelStyle = .rounded
        accessButton.target = self
        accessButton.action = #selector(openAccessibility)
        accessButton.bezelStyle = .rounded
        accessButton.controlSize = .small
        shortcutCheckbox.target = self
        shortcutCheckbox.action = #selector(shortcutToggled)
        customizeButton.target = self
        customizeButton.action = #selector(customize)
        customizeButton.bezelStyle = .rounded
        customizeButton.controlSize = .small
        let column = NSStackView(views: [startButton, statusLabel, accessButton, shortcutCheckbox, exitNote, customizeButton])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        cleaner()?.onChange = { [weak self] in DispatchQueue.main.async { self?.refresh() } }
        refresh()
        return column
    }

    @objc private func startClicked() {
        guard accessibility() else {
            requestAccessibility()
            refresh()
            return
        }
        cleaner()?.start()
        refresh()
    }

    @objc private func shortcutToggled() {
        let on = shortcutCheckbox.state == .on
        if on && !accessibility() { requestAccessibility() }
        settings.keyboardCleanerShortcutEnabled = on
    }

    @objc private func openAccessibility() { AccessibilityAccess.openSettings() }
    @objc private func customize() { ShortcutsWindowController.shared.show() }

    func refresh() {
        let allowed = accessibility()
        let active = cleaner()?.isActive ?? false
        let start = store.shortcut(for: ShortcutCommands.cleanerStart)?.label ?? "no shortcut"
        let exit = store.shortcut(for: ShortcutCommands.cleanerExit) ?? ShortcutCommands.cleanerExit.defaultShortcut
        startButton.isEnabled = !active
        shortcutCheckbox.title = "Also start it with \(start)"
        shortcutCheckbox.state = settings.keyboardCleanerShortcutEnabled ? .on : .off
        exitNote.stringValue = "Ends with \(exit.label), which is also printed in the corner while it runs. "
            + "Both combinations can be changed in Customize."
        accessButton.isHidden = allowed
        if !allowed {
            statusLabel.stringValue = "Accessibility: not allowed yet. Without it the cleaner cannot ignore the keyboard, "
                + "so it will not start. Allow Anode in Accessibility."
            statusLabel.textColor = .systemOrange
        } else if active {
            statusLabel.stringValue = "A cleaning session is running."
            statusLabel.textColor = .secondaryLabelColor
        } else {
            statusLabel.stringValue = "Accessibility: allowed."
            statusLabel.textColor = .secondaryLabelColor
        }
        layoutChanged?()
    }
}

// ── Game Mode ───────────────────────────────────────────────────────────────

final class GameModeFeature: BetaFeature {

    let title = "Game Mode"
    let summary = "Shows CPU and GPU temperature and use, memory use and battery charge and drain in a thin strip over a "
                + "fullscreen game. Any app in the Games category counts as a game; add others below. The strip is "
                + "click-through and only shows while the game is in front."
    var layoutChanged: (() -> Void)?

    private let settings: Settings
    private let controller: () -> GameModeController?
    private let displayName: (String) -> String

    let enableCheckbox = NSButton(checkboxWithTitle: "Show the readout over games", target: nil, action: nil)
    let hotCornerCheckbox = NSButton(checkboxWithTitle: "Also show it for a few seconds when the pointer touches the corner, in any app",
                                     target: nil, action: nil)
    let cornerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let previewButton = NSButton(title: "Show it for 5 seconds", target: nil, action: nil)
    let appsList = NSPopUpButton(frame: .zero, pullsDown: false)
    let addButton = NSButton(title: "Add an app…", target: nil, action: nil)
    let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    let statusLabel = BetaFeaturesWindowController.wrapping("", color: .secondaryLabelColor)
    let hotCornerNote = BetaFeaturesWindowController.wrapping(
        "While the corner option is on, a small square in that corner catches the pointer, so a click on the very corner "
        + "pixels (the last menu bar item, say) lands on it instead of what is underneath.", color: .secondaryLabelColor)

    private static let cornerTitles: [HUDCorner: String] = [
        .topRight: "Top right", .topLeft: "Top left", .bottomRight: "Bottom right", .bottomLeft: "Bottom left"]

    init(settings: Settings = .shared, controller: @escaping () -> GameModeController? = { GameModeController.current },
         displayName: @escaping (String) -> String = GameModeFeature.appName(for:)) {
        self.settings = settings
        self.controller = controller
        self.displayName = displayName
    }

    /// The name the Finder shows for an installed app, or the bundle id if it cannot be found.
    static func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    func makeView() -> NSView {
        enableCheckbox.target = self
        enableCheckbox.action = #selector(enableToggled)
        hotCornerCheckbox.target = self
        hotCornerCheckbox.action = #selector(hotCornerToggled)
        cornerPopup.removeAllItems()
        cornerPopup.addItems(withTitles: HUDCorner.allCases.map { Self.cornerTitles[$0] ?? $0.rawValue })
        cornerPopup.target = self
        cornerPopup.action = #selector(cornerChosen)
        previewButton.target = self
        previewButton.action = #selector(previewClicked)
        previewButton.bezelStyle = .rounded
        previewButton.controlSize = .small
        addButton.target = self
        addButton.action = #selector(addClicked)
        addButton.bezelStyle = .rounded
        addButton.controlSize = .small
        removeButton.target = self
        removeButton.action = #selector(removeClicked)
        removeButton.bezelStyle = .rounded
        removeButton.controlSize = .small
        let cornerRow = NSStackView(views: [NSTextField(labelWithString: "Corner"), cornerPopup, previewButton])
        cornerRow.spacing = 8
        let appsRow = NSStackView(views: [appsList, addButton, removeButton])
        appsRow.spacing = 8
        let column = NSStackView(views: [enableCheckbox, hotCornerCheckbox, hotCornerNote, cornerRow, NSTextField(labelWithString: "Also treat these as games:"),
                                         appsRow, statusLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        refresh()
        return column
    }

    @objc private func enableToggled() { settings.gameHUDEnabled = enableCheckbox.state == .on }
    @objc private func hotCornerToggled() { settings.gameHUDHotCorner = hotCornerCheckbox.state == .on }

    @objc private func cornerChosen() {
        let index = cornerPopup.indexOfSelectedItem
        guard HUDCorner.allCases.indices.contains(index) else { return }
        settings.gameHUDCorner = HUDCorner.allCases[index]
    }

    @objc private func previewClicked() { controller()?.preview() }

    @objc private func addClicked() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let id = Bundle(url: url)?.bundleIdentifier else {
            statusLabel.stringValue = "That app has no identifier, so it cannot be added."
            layoutChanged?()
            return
        }
        add(bundleID: id)
    }

    @objc private func removeClicked() { removeSelected() }

    /// Treat the app with this bundle id as a game. Adding one already in the list changes nothing.
    func add(bundleID: String) {
        guard !settings.gameHUDExtraApps.contains(bundleID) else { return }
        settings.gameHUDExtraApps += [bundleID]
        refresh()
    }

    /// Stop treating the app chosen in the list as a game. With nothing chosen, nothing happens.
    func removeSelected() {
        let apps = settings.gameHUDExtraApps
        let index = appsList.indexOfSelectedItem
        guard apps.indices.contains(index) else { return }
        settings.gameHUDExtraApps = apps.enumerated().filter { $0.offset != index }.map { $0.element }
        refresh()
    }

    func refresh() {
        enableCheckbox.state = settings.gameHUDEnabled ? .on : .off
        hotCornerCheckbox.state = settings.gameHUDHotCorner ? .on : .off
        cornerPopup.selectItem(at: HUDCorner.allCases.firstIndex(of: settings.gameHUDCorner) ?? 0)
        let apps = settings.gameHUDExtraApps
        let kept = appsList.indexOfSelectedItem
        appsList.removeAllItems()
        appsList.addItems(withTitles: apps.map(displayName))
        if apps.indices.contains(kept) { appsList.selectItem(at: kept) }
        appsList.isHidden = apps.isEmpty
        removeButton.isEnabled = !apps.isEmpty
        if !settings.gameHUDEnabled {
            statusLabel.stringValue = "Off."
        } else if controller()?.isShowing ?? false {
            statusLabel.stringValue = "On, and showing now."
        } else {
            statusLabel.stringValue = "On. It appears when a game is the app in front."
        }
        layoutChanged?()
    }
}

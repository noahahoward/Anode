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

    init(features: [BetaFeature] = [BackdropFeature()]) {
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

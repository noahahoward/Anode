import AppKit
import PowerKit

// ── Hardware View: the pane ─────────────────────────────────────────────────
//
// The Hardware tab's whole-machine pane: one `HardwareStageView` pinned to this view's bounds. The main window installs it in
// its pane container (as it does the other whole-machine panes), so there is no window, close button or delegate here. It
// creates NO timer, thread or observer: the controller feeds it, and what it costs while nobody can see it is the cost of
// storing the newest reading. The stage and the canvas do the gating (`isDrawableNow`, which is `isDrawable` here): a reading
// that arrives while the pane is hidden, covered or minimised is kept and nothing is drawn for it.

/// What the controller drives. A protocol so a test needs no window server.
protocol HardwareViewHosting: AnyObject {
    /// A fan slider moved (the fan's index; the rpm, or nil when it was let go).
    var onFanSlider: ((Int, Double?) -> Void)? { get set }
    /// The person asked to install the helper from the view's install prompt.
    var onInstallHelper: (() -> Void)? { get set }
    /// True while the pane is on screen and nobody covers it (the drawable rule, injectable for tests).
    var isDrawingNow: Bool { get }
    func update(layout: HardwareLayout, readings: HardwareReadings?, history: HardwareHistory,
                chargeHistory: [Double?], menuBarWidgets: [MenuBarWidgetText])
    /// Forget a pinned card and stop anything running; called when the tab is left.
    func reset()
}

final class HardwarePane: NSView, HardwareViewHosting {

    let stage: HardwareStageView

    /// Whether anyone can see the pane right now: it is in a visible, unoccluded, unminimised window, nothing above it is
    /// hidden (the tab is on), and the window is on a screen somebody is watching. A property so a test can say so without a
    /// window server.
    var isDrawable: () -> Bool = { false }

    /// Forwarded to the stage (and so to the canvas's fan sliders and install prompt).
    var onFanSlider: ((Int, Double?) -> Void)? {
        get { stage.onFanSlider }
        set { stage.onFanSlider = newValue }
    }
    var onInstallHelper: (() -> Void)? {
        get { stage.onInstallHelper }
        set { stage.onInstallHelper = newValue }
    }

    var isDrawingNow: Bool { isDrawable() }

    // The newest data, kept whether or not it was drawn: the canvas holds it.
    var hardwareLayout: HardwareLayout { stage.canvas.hardwareLayout }
    var readings: HardwareReadings? { stage.canvas.readings }
    var history: HardwareHistory? { stage.canvas.history }
    var chargeHistory: [Double?] { stage.canvas.chargeHistory }
    var menuBarWidgets: [MenuBarWidgetText] { stage.canvas.menuBarWidgets }

    override init(frame: NSRect) {
        stage = HardwareStageView(layout: HardwareLayout.layout(for: .generic))
        super.init(frame: frame)
        stage.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stage)
        // Constraints, not a frame: the container this is installed in is Auto Layout driven, so its bounds are still zero at
        // install time.
        NSLayoutConstraint.activate([
            stage.leadingAnchor.constraint(equalTo: leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: trailingAnchor),
            stage.topAnchor.constraint(equalTo: topAnchor),
            stage.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isDrawable = { [weak self] in
            guard let self, let w = self.window else { return false }
            return w.isVisible && w.occlusionState.contains(.visible) && !w.isMiniaturized
                && !self.isHiddenOrHasHiddenAncestor && ScreenWatch.shared.isWatched
        }
        stage.isDrawableNow = { [weak self] in self?.isDrawable() ?? false }
    }

    required init?(coder: NSCoder) { fatalError("HardwarePane is code-only") }

    // MARK: HardwareViewHosting

    func update(layout: HardwareLayout, readings: HardwareReadings?, history: HardwareHistory,
                chargeHistory: [Double?], menuBarWidgets: [MenuBarWidgetText]) {
        // Kept either way; the stage draws only when `isDrawable` says somebody can see it.
        stage.update(layout: layout, readings: readings, history: history,
                     chargeHistory: chargeHistory, menuBarWidgets: menuBarWidgets)
    }

    /// The tab was left: the pinned card closes and what was kept is dropped, so nothing of the last visit shows (or turns)
    /// when the tab is opened again. The blades' animation ends itself at its next frame; refreshing it here ends it at once.
    func reset() {
        stage.reset()
        let canvas = stage.canvas
        canvas.readings = nil
        canvas.history = nil
        canvas.chargeHistory = []
        canvas.menuBarWidgets = []
        canvas.refreshFanAnimation()
    }
}

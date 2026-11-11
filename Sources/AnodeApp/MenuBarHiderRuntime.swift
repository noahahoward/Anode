import AppKit
import PowerKit

/// Joins the Menu Bar Hider to the app: owns the controller and everything it needs, and turns the pieces on and off with
/// the setting. With the setting off nothing exists: no chevron, no cover, no pill, no event observers, no shortcut listener,
/// no timer; the only thing alive is the observer of the settings themselves.
final class MenuBarHiderRuntime {

    let controller: MenuBarHiderController
    private let settings: Settings
    private let events: BarEventing
    private let registerShortcut: (@escaping () -> Void) -> Void
    private let unregisterShortcut: () -> Void
    private let pillTick: () -> Void
    private var tokens: [AnyObject] = []
    private var rebuildObserver: NSObjectProtocol?
    private var timer: Timer?
    private var settleWork: DispatchWorkItem?
    private var rebuildWork: DispatchWorkItem?
    private var lastDisplayChange = Date.distantPast
    private var shortcutRegistered = false
    private var finished = false

    var isTimerRunning: Bool { timer != nil }

    init(settings: Settings = .shared, reader: BarReading, covers: CoverPresenting, pill: PillPresenting,
         chevron: ChevronPresenting, widgets: WidgetFolding,
         makeEvents: (@escaping (_ displayChanged: Bool) -> Void, @escaping () -> Void) -> BarEventing,
         environment: @escaping (_ secondsSinceDisplayChange: TimeInterval) -> HiderEnvironment,
         registerShortcut: @escaping (@escaping () -> Void) -> Void, unregisterShortcut: @escaping () -> Void,
         openBetaFeatures: @escaping () -> Void, pillTick: @escaping () -> Void,
         log: @escaping (String) -> Void = { FeatureLog.append("menubarhider.log", $0) },
         schedule: ((TimeInterval, @escaping () -> Void) -> Void)? = nil) {
        self.settings = settings
        self.registerShortcut = registerShortcut
        self.unregisterShortcut = unregisterShortcut
        self.pillTick = pillTick

        // The controller reads the clock through `environment`; the runtime is what knows when the display last changed.
        final class Box { weak var runtime: MenuBarHiderRuntime? }
        let box = Box()
        controller = MenuBarHiderController(
            settings: settings, reader: reader, covers: covers, pill: pill, chevron: chevron, widgets: widgets,
            environment: { environment(Date().timeIntervalSince(box.runtime?.lastDisplayChange ?? .distantPast)) },
            log: log,
            schedule: schedule ?? { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) })
        events = makeEvents({ [weak box] displayChanged in box?.runtime?.eventFired(displayChanged: displayChanged) },
                            { [weak box] in box?.runtime?.controller.invalidateCovers() })
        box.runtime = self

        (chevron as? BarChevron)?.menuProvider = { [weak self] in
            guard let self else { return NSMenu() }
            return BarChevron.buildMenu(isOpen: self.controller.isPillOpen, autoClose: settings.menuBarHiderAutoCloseSeconds,
                                        onToggle: { self.controller.togglePill() },
                                        onAutoClose: { settings.menuBarHiderAutoCloseSeconds = $0 }, onOpenBeta: openBetaFeatures)
        }
        controller.onChange = { [weak self] in self?.controllerChanged() }

        for key in [Settings.Key.menuBarHiderEnabled, Settings.Key.menuBarHiderArrangement, Settings.Key.menuBarHiderAutoCloseSeconds] {
            tokens.append(settings.observe(key) { [weak self] in self?.apply() })
        }
        // Anode's own widgets are rebuilt when the hider folds or unfolds them, and macOS lays the bar out a moment later.
        rebuildObserver = NotificationCenter.default.addObserver(forName: MenuBarWidgetController.itemsDidRebuild, object: nil,
                                                                 queue: .main) { [weak self] _ in self?.widgetsRebuilt() }
        if settings.menuBarHiderEnabled { apply() }
    }

    /// The real thing, for the app.
    static func live(widgets: MenuBarWidgetController, openBetaFeatures: @escaping () -> Void) -> MenuBarHiderRuntime {
        let pill = BarPillWindow()
        pill.anodeImage = { [weak widgets] in widgets?.pillImage(forMetricID: $0) }
        let runtime = MenuBarHiderRuntime(
            reader: AXBarReader(), covers: BarCoverWindows(), pill: pill, chevron: BarChevron(), widgets: widgets,
            makeEvents: { onChange, onInvalidate in BarEvents(onChange: onChange, onInvalidate: onInvalidate) },
            environment: Self.liveEnvironment,
            registerShortcut: { fire in
                KeybindCenter.shared.register(owner: "menuBarHider", commands: ShortcutCommands.hider) { _ in fire() }
            },
            unregisterShortcut: { KeybindCenter.shared.unregister(owner: "menuBarHider") },
            openBetaFeatures: openBetaFeatures, pillTick: { [weak pill] in pill?.refreshAnodeCells() })
        pill.onDismiss = { [weak runtime] in runtime?.controller.dismissPill() }
        MenuBarHiderController.current = runtime.controller
        return runtime
    }

    /// The screen that carries the status items: the one with the menu bar.
    static func liveEnvironment(secondsSinceDisplayChange: TimeInterval) -> HiderEnvironment {
        let screen = NSScreen.screens.first
        let frame = screen?.frame ?? .zero
        var notch: CGRect?
        if let left = screen?.auxiliaryTopLeftArea, let right = screen?.auxiliaryTopRightArea, right.minX > left.maxX {
            notch = CGRect(x: left.maxX, y: 0, width: right.minX - left.maxX, height: screen?.safeAreaInsets.top ?? 0)
        }
        let bar = max(screen?.safeAreaInsets.top ?? 0, screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 0)
        return HiderEnvironment(trusted: AXIsProcessTrusted(),
                                fullScreen: RealFrontmost.isFullscreen(presentationOptions: NSApp.currentSystemPresentationOptions),
                                secondsSinceChange: secondsSinceDisplayChange,
                                screen: CGRect(x: 0, y: 0, width: frame.width, height: frame.height),
                                notch: notch, menuBarHeight: bar > 0 ? bar : 24)
    }

    func shutdown() {
        finished = true
        tokens.removeAll()
        if let rebuildObserver { NotificationCenter.default.removeObserver(rebuildObserver) }
        rebuildObserver = nil
        settleWork?.cancel(); rebuildWork?.cancel()
        events.urgent = false
        events.stop()
        controller.shutdown()
        MenuBarHiderController.current = MenuBarHiderController.current === controller ? nil : MenuBarHiderController.current
        controllerChanged()
    }

    // ── Reactions ───────────────────────────────────────────────────────────

    private func apply() {
        guard !finished else { return }
        if settings.menuBarHiderEnabled { events.start() } else { events.stop() }
        controller.reevaluate()
        controllerChanged()
    }

    private func eventFired(displayChanged: Bool) {
        guard !finished, settings.menuBarHiderEnabled else { return }
        if displayChanged { lastDisplayChange = Date() }
        controller.layoutMayHaveChanged(screenChanged: displayChanged)
        controllerChanged()
    }

    private func widgetsRebuilt() {
        guard !finished, settings.menuBarHiderEnabled else { return }
        // The bar is about to be laid out afresh: whatever is covered now was drawn for the layout before the rebuild.
        controller.invalidateCovers()
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.finished else { return }
            self.controller.layoutMayHaveChanged()
            self.controllerChanged()
        }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// The decision or the pill changed: the shortcut is listened for only while the pill can be opened, the timer runs only while the
    /// pill is open, the bar is watched closely only while something is covered, and a "settling" refusal is retried when the
    /// settle window has passed.
    private func controllerChanged() {
        // A cover over a bar that has moved is worse than none: while covers are up the bar is re-read every few seconds, in
        // case it moved without an event saying so. With nothing covered there is nothing to go stale.
        let watch = !finished && controller.isCovering
        if events.urgent != watch { events.urgent = watch }

        if controller.canTogglePill && !finished {
            if !shortcutRegistered {
                shortcutRegistered = true
                registerShortcut { [weak self] in self?.controller.togglePill() }
            }
        } else if shortcutRegistered {
            shortcutRegistered = false
            unregisterShortcut()
        }

        if controller.isPillOpen && !finished {
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    self?.controller.tick()
                    self?.pillTick()
                }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }

        if controller.decision == .standDown(.settling), settleWork == nil || settleWork?.isCancelled == true {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.finished else { return }
                self.settleWork = nil
                self.controller.reevaluate()
                self.controllerChanged()
            }
            settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + HiderPolicy.settleSeconds + 0.1, execute: work)
        }
    }
}

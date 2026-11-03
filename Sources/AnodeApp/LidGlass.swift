import AppKit
import PowerKit

// ── Lid Glass ───────────────────────────────────────────────────────────────
//
// As the lid closes the screen stays where it is and frosts over like glass; after the next unlock the desktop
// clears from a frosted state. This is the part that decides when: it reads the lid angle, notices a close,
// asks for one picture of the screen, shows the overlay and feeds it the frost, and takes it all away again.
//
// The sensor, the picture, the overlay and the "is an external display attached" question are all handed in, so
// every sequence of angles can be played in a test without a lid. Everything here runs on the main thread; the
// sensor's own queue only hands samples over.
//
// While the feature is off nothing runs: no polling, no timers, no windows.

enum LidGlassStatus: Equatable {
    case off
    /// Watching the lid at the idle rate.
    case idle
    /// A close is under way (polling at the fast rate).
    case active
    /// This Mac has no lid-angle sensor, or the system is too old.
    case unsupported
    /// The sensor stopped answering mid-session; polling has stopped.
    case sensorLost
}

final class LidGlass {

    private(set) var status: LidGlassStatus = .off {
        didSet { if status != oldValue { onStatusChange?() } }
    }
    /// Called on the main thread whenever `status` changes, so Settings can say what is going on.
    var onStatusChange: (() -> Void)?

    /// How long the frost takes to clear after unlock, and when a lid is reopened mid-close.
    static let openingClear: TimeInterval = 0.5
    static let reopenClear: TimeInterval = 0.25

    private let settings: Settings
    private let sensor: LidAngleSource
    private let makeOverlay: () -> LidGlassOverlaying?
    private let capture: () async -> CGImage?
    private let externalDisplayPresent: () -> Bool
    private let log: (String) -> Void

    private var detector: LidCloseDetector
    /// Bumped whenever the effect is torn down, so a picture that arrives late finds its moment gone.
    private var generation = 0
    private var overlay: LidGlassOverlaying?
    private var showingOpeningEffect = false
    /// Set when a close began and not yet undone or followed by an unlock: the next unlock plays the opening.
    private var closeSeen = false
    private var lastAngle = 180.0

    private var settingTokens: [AnyObject] = []
    private var systemObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var inputMonitor: Any?

    init(settings: Settings = .shared,
         sensor: LidAngleSource = LidAngleSensor(),
         makeOverlay: @escaping () -> LidGlassOverlaying? = LidGlass.realOverlay,
         capture: @escaping () async -> CGImage? = LidGlass.realCapture,
         externalDisplayPresent: @escaping () -> Bool = { LidGlassCapture.hasExternalDisplay() },
         log: @escaping (String) -> Void = { FeatureLog.append("lidglass.log", $0) }) {
        self.settings = settings
        self.sensor = sensor
        self.makeOverlay = makeOverlay
        self.capture = capture
        self.externalDisplayPresent = externalDisplayPresent
        self.log = log
        self.detector = LidCloseDetector(trigger: settings.lidGlassTriggerAngle)

        for key in [Settings.Key.lidGlassEnabled, Settings.Key.lidGlassIdleHz, Settings.Key.lidGlassTriggerAngle] {
            settingTokens.append(settings.observe(key) { [weak self] in Self.onMain { self?.settingsChanged() } })
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) { $0.systemWillSleep() }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.displayConfigurationChanged() }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) { $0.screenUnlocked() }
        settingsChanged()
    }

    deinit {
        for (center, token) in systemObservers { center.removeObserver(token) }
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        sensor.stop()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping (LidGlass) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            Self.onMain { if let self { handler(self) } }
        }
        systemObservers.append((center, token))
    }

    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // ── Settings ──

    private func settingsChanged() {
        detector.trigger = settings.lidGlassTriggerAngle
        if settings.lidGlassEnabled {
            switch status {
            case .off: start()
            case .idle: sensor.setRate(hz: idleHz)
            case .active, .unsupported, .sensorLost: break
            }
        } else if status != .off {
            stopAll()
        }
    }

    private var idleHz: Double { LidPollPolicy.idleHz(settings.lidGlassIdleHz) }

    private func start() {
        guard #available(macOS 14.0, *), sensor.isAvailable else {
            status = .unsupported
            log("not supported on this Mac")
            return
        }
        status = .idle
        sensor.start(hz: idleHz,
                     onSample: { [weak self] degrees, time in
                         DispatchQueue.main.async { self?.handle(angle: degrees, time: time) }
                     },
                     onLost: { [weak self] in DispatchQueue.main.async { self?.sensorLost() } })
        log("on, idle \(idleHz) Hz")
    }

    private func stopAll() {
        teardown()
        sensor.stop()
        closeSeen = false
        status = .off
        log("off")
    }

    private func sensorLost() {
        guard status == .idle || status == .active else { return }
        teardown()
        sensor.stop()
        closeSeen = false
        status = .sensorLost
        log("sensor stopped answering")
    }

    // ── Angles ──

    func handle(angle: Double, time: TimeInterval) {
        guard status == .idle || status == .active else { return }
        lastAngle = angle
        switch detector.feed(angle: angle, time: time) {
        case .closing:
            closingBegan()
        case .reopened:
            reopened()
        case .none:
            if status == .active, let overlay, let from = detector.armedFrom {
                overlay.setBlur(LidBlurCurve(trigger: from).amount(at: angle))
            }
        }
    }

    private func closingBegan() {
        guard !externalDisplayPresent() else { return }
        closeSeen = true
        status = .active
        sensor.setRate(hz: LidPollPolicy.activeHz)
        log(String(format: "closing at %.0f", lastAngle))
        let mine = generation
        Task { [weak self] in
            guard let capture = self?.capture else { return }
            let image = await capture()
            DispatchQueue.main.async { self?.pictureArrived(image, generation: mine) }
        }
    }

    private func pictureArrived(_ image: CGImage?, generation mine: Int) {
        guard mine == generation, status == .active else { return }
        guard let image, let overlay = makeOverlay() else {
            log("no picture; no effect")
            backToIdle()
            return
        }
        self.overlay = overlay
        let from = detector.armedFrom ?? detector.trigger
        overlay.show(image: image, blur: LidBlurCurve(trigger: from).amount(at: lastAngle))
    }

    private func reopened() {
        closeSeen = false
        guard status == .active else { return }
        generation += 1
        let leaving = overlay
        overlay = nil
        status = .idle
        sensor.setRate(hz: idleHz)
        log("lid reopened")
        if let leaving {
            leaving.animateClear(duration: Self.reopenClear) { leaving.hide() }
        }
    }

    private func backToIdle() {
        generation += 1
        detector.reset()
        status = .idle
        sensor.setRate(hz: idleHz)
    }

    // ── Things that end an effect ──

    /// Remove whatever is on screen, forget any picture still on its way, and go back to the idle rate.
    private func teardown() {
        generation += 1
        removeInputMonitor()
        overlay?.hide()
        overlay = nil
        showingOpeningEffect = false
        detector.reset()
        if status == .active {
            status = .idle
            sensor.setRate(hz: idleHz)
        }
    }

    func systemWillSleep() { teardown() }

    func displayConfigurationChanged() { teardown() }

    /// A key, click or scroll cancels the opening effect. A close in progress ignores input.
    func userInput() {
        guard showingOpeningEffect else { return }
        teardown()
    }

    // ── After unlock ──

    func screenUnlocked() {
        guard settings.lidGlassEnabled, status == .idle || status == .active, closeSeen else { return }
        closeSeen = false
        teardown()
        let mine = generation
        Task { [weak self] in
            guard let capture = self?.capture else { return }
            let image = await capture()
            DispatchQueue.main.async { self?.openingPictureArrived(image, generation: mine) }
        }
    }

    private func openingPictureArrived(_ image: CGImage?, generation mine: Int) {
        guard mine == generation, status == .idle, let image, let overlay = makeOverlay() else { return }
        self.overlay = overlay
        showingOpeningEffect = true
        installInputMonitor()
        overlay.show(image: image, blur: 1)
        overlay.animateClear(duration: Self.openingClear) { [weak self, weak overlay] in
            guard let self, let overlay, self.overlay === overlay else { return }
            self.removeInputMonitor()
            overlay.hide()
            self.overlay = nil
            self.showingOpeningEffect = false
        }
    }

    private func installInputMonitor() {
        guard inputMonitor == nil else { return }
        inputMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] _ in
            DispatchQueue.main.async { self?.userInput() }
        }
    }

    private func removeInputMonitor() {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
    }

    // ── The real parts ──

    static func realOverlay() -> LidGlassOverlaying? {
        guard #available(macOS 14.0, *), let id = LidGlassCapture.builtInDisplayID(),
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
              }) else { return nil }
        return LidGlassOverlay(screen: screen)
    }

    static func realCapture() async -> CGImage? {
        guard #available(macOS 14.0, *), let id = LidGlassCapture.builtInDisplayID() else { return nil }
        return await LidGlassCapture.capture(displayID: id, excludingWindowIDs: [])?.image
    }
}

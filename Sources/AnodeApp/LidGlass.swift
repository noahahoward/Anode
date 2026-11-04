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

    /// The running controller, for Settings to read its status from.
    static weak var current: LidGlass?

    private(set) var status: LidGlassStatus = .off {
        didSet { if status != oldValue { onStatusChange?() } }
    }
    /// Called on the main thread whenever `status` changes, so Settings can say what is going on.
    var onStatusChange: (() -> Void)?

    /// How long the frost takes to clear after unlock, and when a lid is reopened mid-close.
    static let openingClear: TimeInterval = 0.5
    static let reopenClear: TimeInterval = 0.2
    /// A lid whose angle has stayed within `stillTolerance` degrees for `stillSettle` seconds has stopped; the
    /// frozen picture must not stay over a live screen the owner is working on. The tolerance covers the sensor's
    /// whole-degree steps and a hand that has not quite let go.
    static let stillTolerance = 3.0
    static let stillSettle: TimeInterval = 0.4
    /// A fold shallower than this (degrees below where the picture was frozen) is a nudge, not a close: if the lid
    /// rests there the fold is cleared. A deeper one waits for the lid to be opened again, as the iPhone Duo does,
    /// and opening plays it backwards.
    static let slightFold = 12.0
    /// Degrees past the angle the picture was frozen at the lid must rise to before the fold lets go: above it the
    /// fold is flat, so there is nothing to show, and a few degrees of sensor noise must not end a close.
    static let releaseMargin = 3.0
    /// Below this the lid is shut, or as near as makes no difference; it sits there until the Mac sleeps.
    static let shutAngle = 5.0
    /// The sensor's own update rate. Reading more slowly than this while a close could begin makes the effect start
    /// late: at 4 Hz the lid is noticed up to a quarter of a second after it started to move.
    static let nativeSensorHz = 10.0
    /// How far above the trigger angle a close can still be about to begin. Higher than this the slider's rate applies.
    static let closingZone = 30.0
    /// How long the picture takes to appear after a close is confirmed: the screenshot (about 45 ms) and preparing it
    /// (about 40 ms), and a frame. The fold is placed ahead of the lid by the travel in that time, so the picture
    /// appears flat just as the lid reaches its start and the fold begins in step with it, instead of appearing
    /// flat behind a lid that has already moved on and catching up.
    static let startLatency: TimeInterval = 0.1
    /// The most the fold is placed ahead of the lid, in degrees: a flick must not put its start far below it.
    static let maxStartLead = 15.0
    /// With the picture already prepared, only a frame is left between the close being confirmed and the fold showing.
    static let warmStartLatency: TimeInterval = 0.03
    /// A picture warmed for a close that never came is thrown away after this long.
    static let warmLife: TimeInterval = 1.5

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
    /// The angle the fold is flat at: ahead of the lid by the travel while the picture appears (`startLatency`).
    private var startAngle = 0.0
    /// The lid angle when the close was confirmed. The fold lets go once the lid is back above this.
    private var closedAt = 0.0
    /// Estimates how fast the lid is moving, for the lead.
    private var speed = LidAngleTracker()
    /// The start angle of the last close that was seen, for the opening effect after unlock.
    private var lastCloseStart: Double?
    private var recent: [(time: TimeInterval, angle: Double)] = []

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
            case .idle: setRestingRate()
            case .active, .unsupported, .sensorLost: break
            }
        } else if status != .off {
            stopAll()
        }
    }

    private var idleHz: Double { LidPollPolicy.idleHz(settings.lidGlassIdleHz) }

    /// The rate the sensor is read at while nothing is happening: the slider's, but no slower than the sensor itself
    /// while the lid is low enough for a close to begin.
    private var restingHz: Double {
        lastAngle <= settings.lidGlassTriggerAngle + Self.closingZone ? max(idleHz, Self.nativeSensorHz) : idleHz
    }
    private var restingRate: Double?

    /// Put the sensor on the resting rate (always).
    private func setRestingRate() {
        let wanted = restingHz
        restingRate = wanted
        sensor.setRate(hz: wanted)
    }

    /// Follow the lid between the slider's rate and the sensor's own, touching the sensor only when it changes.
    private func adjustRestingRate() {
        guard restingRate != restingHz else { return }
        setRestingRate()
    }

    private func start() {
        guard #available(macOS 14.0, *), sensor.isAvailable else {
            status = .unsupported
            log("not supported on this Mac")
            return
        }
        status = .idle
        restingRate = idleHz
        sensor.start(hz: idleHz,
                     onSample: { [weak self] degrees, time in
                         DispatchQueue.main.async { self?.noteLag(sampleTime: time); self?.handle(angle: degrees, time: time) }
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

    private var lastLagLog = 0.0

    /// A picture taken and prepared when a descent was first seen, before it was confirmed as a close. It is shown
    /// at once if the close is confirmed, and thrown away if not. Nothing runs for a lid that is not descending.
    private struct Warm {
        var armedAt: TimeInterval
        var overlay: LidGlassOverlaying?
        var ready = false
        var failed = false
        /// The close was confirmed while the picture was still on its way.
        var wantsPresent = false
    }
    private var warm: Warm?
    /// While a close is active, each change in the sensor's reading is logged (capped), so the real cadence of the
    /// readings can be read back from the log.
    private var tracedAngle: Double?
    private var traced = 0
    private static let traceLimit = 400

    /// Samples should reach the main thread within a frame or two. When they do not, the main thread is busy
    /// (drawing, most likely), and a late stop or a frozen fold is the result; leave a line to say so.
    private func noteLag(sampleTime: TimeInterval) {
        guard status == .active else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let lag = now - sampleTime
        guard lag > 0.25, now - lastLagLog > 1 else { return }
        lastLagLog = now
        log(String(format: "lid samples are arriving %.0f ms late: the main thread is busy", lag * 1000))
    }

    func handle(angle: Double, time: TimeInterval) {
        guard status == .idle || status == .active else { return }
        lastAngle = angle
        speed.ingest(angle, at: time)
        if let w = warm, status == .idle, time - w.armedAt > Self.warmLife {
            log("warmed picture not used")
            discardWarm()
        }
        if status == .idle { adjustRestingRate() }
        switch detector.feed(angle: angle, time: time) {
        case .closing:
            closingBegan()
        case .armed:
            warmUp(at: time)
        case .reopened:
            reopened()
        case .none:
            guard status == .active else { return }
            overlay?.setAngle(angle)
            if angle != tracedAngle, traced < Self.traceLimit {
                tracedAngle = angle; traced += 1
                log(String(format: "angle %.0f at %.3f", angle, time))
            }
            if angle >= closedAt + Self.releaseMargin {
                detector.reset()
                closeSeen = false
                leaveTheEffect(why: "lid back above where the close began")
            } else {
                watchForStillness(angle: angle, time: time)
            }
        }
    }

    private func closingBegan() {
        guard !externalDisplayPresent() else { return }
        closeSeen = true
        recent = []
        tracedAngle = nil
        traced = 0
        closedAt = lastAngle
        let usable = warm.map { !$0.failed } ?? false
        let latency = (warm?.ready ?? false) ? Self.warmStartLatency : Self.startLatency
        let lead = min(max(-speed.velocity, 0) * latency, Self.maxStartLead)
        startAngle = lastAngle - lead
        lastCloseStart = startAngle
        status = .active
        sensor.setRate(hz: LidPollPolicy.activeHz)
        log(String(format: "closing at %.0f (%@)", lastAngle, usable ? "picture warmed" : "taking the picture now"))
        if usable {
            if warm?.ready == true { presentWarm() } else { warm?.wantsPresent = true }
            return
        }
        let mine = generation
        Task { [weak self] in
            guard let capture = self?.capture else { return }
            let image = await capture()
            DispatchQueue.main.async { self?.pictureArrived(image, generation: mine) }
        }
    }

    // ── Warming ──

    private func warmUp(at time: TimeInterval) {
        guard status == .idle, warm == nil, !externalDisplayPresent() else { return }
        warm = Warm(armedAt: time)
        let mine = generation
        log("descent seen: warming the picture")
        Task { [weak self] in
            guard let capture = self?.capture else { return }
            let image = await capture()
            DispatchQueue.main.async { self?.warmPictureArrived(image, generation: mine) }
        }
    }

    private func warmPictureArrived(_ image: CGImage?, generation mine: Int) {
        guard mine == generation, warm != nil else { return }
        guard let image, let overlay = makeOverlay() else {
            warm?.failed = true
            if warm?.wantsPresent == true {
                log("no picture; no effect")
                warm = nil
                backToIdle()
            }
            return
        }
        overlay.prepare(image: image)
        warm?.overlay = overlay
        warm?.ready = true
        if warm?.wantsPresent == true { presentWarm() }
    }

    private func presentWarm() {
        guard let overlay = warm?.overlay else { return }
        warm = nil
        self.overlay = overlay
        overlay.present(startAngle: startAngle, from: startAngle, to: lastAngle)
    }

    private func discardWarm() {
        warm?.overlay?.hide()
        warm = nil
    }

    private func pictureArrived(_ image: CGImage?, generation mine: Int) {
        guard mine == generation, status == .active else { return }
        guard let image, let overlay = makeOverlay() else {
            log("no picture; no effect")
            backToIdle()
            return
        }
        self.overlay = overlay
        overlay.show(image: image, startAngle: startAngle, from: startAngle, to: lastAngle)
    }

    private func reopened() {
        closeSeen = false
        guard status == .active else { return }
        leaveTheEffect(why: "lid reopened")
    }

    /// The lid has been left a slight way below where the picture was frozen. A deep fold is not a pause to clear
    /// for, and neither is a shut lid, which sits near 0° until the Mac sleeps.
    private func watchForStillness(angle: Double, time: TimeInterval) {
        guard angle > Self.shutAngle, startAngle - angle < Self.slightFold else { recent = []; return }
        recent.append((time, angle))
        recent.removeAll { time - $0.time > Self.stillSettle + 0.1 }
        guard let oldest = recent.first, time - oldest.time >= Self.stillSettle - 1e-6 else { return }
        let window = recent.filter { time - $0.time <= Self.stillSettle + 1e-6 }.map(\.angle)
        guard let low = window.min(), let high = window.max(), high - low <= Self.stillTolerance else { return }
        detector.reset()
        closeSeen = false
        leaveTheEffect(why: "lid stopped")
    }

    /// Clear the frost away and go back to watching at the idle rate.
    private func leaveTheEffect(why: String) {
        generation += 1
        recent = []
        let leaving = overlay
        overlay = nil
        status = .idle
        setRestingRate()
        log(why)
        if let leaving {
            leaving.animateClear(duration: Self.reopenClear) { leaving.hide() }
        }
    }

    private func backToIdle() {
        generation += 1
        recent = []
        detector.reset()
        status = .idle
        setRestingRate()
    }

    // ── Things that end an effect ──

    /// Remove whatever is on screen, forget any picture still on its way, and go back to the idle rate.
    private func teardown() {
        generation += 1
        discardWarm()
        recent = []
        removeInputMonitor()
        overlay?.hide()
        overlay = nil
        showingOpeningEffect = false
        detector.reset()
        if status == .active {
            status = .idle
            setRestingRate()
        }
    }

    func systemWillSleep() {
        if status == .active || overlay != nil { log("going to sleep with the fold up") }
        teardown()
    }

    func displayConfigurationChanged() {
        if status == .active || overlay != nil { log("screens changed with the fold up") }
        teardown()
    }

    /// A key, click or scroll cancels the opening effect. A close in progress ignores input.
    func userInput() {
        guard showingOpeningEffect else { return }
        teardown()
    }

    // ── After unlock ──

    func screenUnlocked() {
        if settings.lidGlassEnabled { log("unlocked (a close was seen: \(closeSeen))") }
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
        guard mine == generation, status == .idle, let image, let overlay = makeOverlay() else {
            log("opening effect skipped: no picture or no overlay")
            return
        }
        log("opening effect")
        self.overlay = overlay
        showingOpeningEffect = true
        installInputMonitor()
        let start = lastCloseStart ?? settings.lidGlassTriggerAngle
        let folded = start - LidFoldLook(startAngle: start).span
        overlay.show(image: image, startAngle: start, from: folded, to: folded)
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
        let overlay = LidGlassOverlay(screen: screen)
        overlay.log = { FeatureLog.append("lidglass.log", $0) }
        return overlay
    }

    static func realCapture() async -> CGImage? {
        guard #available(macOS 14.0, *), let id = LidGlassCapture.builtInDisplayID() else { return nil }
        return await LidGlassCapture.capture(displayID: id, excludingWindowIDs: [])?.image
    }
}

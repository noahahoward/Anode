import AppKit
import PowerKit

// ── Keep Awake (Beta Features) ──────────────────────────────────────────────
//
// An icon in the menu bar that works the way Caffeine's does, with a third state: each click moves to the next of
// off → Never Sleep → Always Stay Awake → off; right-click (or Control-click) for the menu — which mode, for how
// long. An open laptop with a dark screen when off, a lit screen while Never Sleep is holding the Mac awake, and a shut laptop with a pulse while Always Stay Awake is
// also keeping it running with the lid shut. In Always Stay Awake the screen's backlight goes to zero while the lid
// is shut and comes back as it was when the lid opens (`LidDimmer`).
//
// What each mode does, and the safety rules around the one that needs root, are in `KeepAwake.swift`. This file
// is the icon, the menu, the timer that notices a session has run out or the battery has run down, and the
// explaining when Always Stay Awake is asked for before its permission exists.
//
// While the feature is off there is no menu bar item and no timer. Main thread throughout.

final class KeepAwakeController: NSObject {

    /// The running controller, for the Beta Features section to read.
    static weak var current: KeepAwakeController?

    static let modeKey = "keepAwake.mode"
    static let durationKey = "keepAwake.duration"
    /// One-shot: set (to a mode's raw value) by whatever is about to replace this app with a new build while it runs
    /// in a mode that must not lapse, such as Always Stay Awake with the lid shut. The next launch resumes that mode
    /// instead of treating what it finds as the leftovers of a crash, and clears the key.
    static let handoffKey = "keepAwake.handoff"

    let core: KeepAwake
    /// Called whenever the state shown anywhere (icon, Beta Features text) may have changed.
    var onChange: (() -> Void)?

    /// Where the clicks and results go: keepawake.log in Anode's support folder.
    var log: (String) -> Void = { FeatureLog.append("keepawake.log", $0) }

    private let settings: Settings
    private let defaults: UserDefaults
    private var token: AnyObject?
    private var item: NSStatusItem?
    private var timer: Timer?
    private var wakeToken: NSObjectProtocol?
    private var rightClickMonitor: Any?
    private var menuShownAt = Date.distantPast
    private var lidTimer: Timer?
    let dimmer: LidDimmer

    init(settings: Settings = .shared, defaults: UserDefaults = .standard, core: KeepAwake? = nil,
         dimmer: LidDimmer? = nil) {
        self.settings = settings
        self.defaults = defaults
        self.core = core ?? KeepAwake(assertions: IOKitSleepAssertions(), lid: PmsetClosedLidSleep(), defaults: defaults)
        self.dimmer = dimmer ?? LidDimmer(lid: IOKitLidState(), backlight: DisplayServicesBacklight(), defaults: defaults,
                                          log: { FeatureLog.append("keepawake.log", $0) })
        super.init()
        let handoff = defaults.string(forKey: Self.handoffKey).flatMap(KeepAwakeMode.init(rawValue:))
        defaults.removeObject(forKey: Self.handoffKey)
        if handoff == nil || !settings.keepAwakeEnabled {
            // A previous run may have died holding the lid open, or with the screen dimmed.
            self.core.reconcileAtLaunch()
            self.dimmer.release()
        }
        self.core.onChange = { [weak self] in self?.stateChanged() }
        token = settings.observe(Settings.Key.keepAwakeEnabled) { [weak self] in
            DispatchQueue.main.async { self?.applyEnabled() }
        }
        wakeToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.tick() }
        applyEnabled()
        if let mode = handoff, settings.keepAwakeEnabled { resume(mode) }
    }

    /// Carry on a mode the previous build was running when it was replaced (see `handoffKey`).
    private func resume(_ mode: KeepAwakeMode) {
        self.mode = mode
        do {
            try core.start(mode, for: duration.seconds)
            log("resumed \(mode.rawValue) after a relaunch")
        } catch {
            log("could not resume \(mode.rawValue) after a relaunch (\(error)); restoring normal sleep")
            core.reconcileAtLaunch()
            dimmer.release()
        }
    }

    deinit { if let w = wakeToken { NSWorkspace.shared.notificationCenter.removeObserver(w) } }

    // ── Choices, remembered ─────────────────────────────────────────────────

    var mode: KeepAwakeMode {
        get { defaults.string(forKey: Self.modeKey).flatMap(KeepAwakeMode.init(rawValue:)) ?? .neverSleep }
        set { defaults.set(newValue.rawValue, forKey: Self.modeKey); stateChanged() }
    }

    var duration: KeepAwakeDuration {
        get { KeepAwakeDuration(rawValue: defaults.integer(forKey: Self.durationKey)) ?? .forever }
        set { defaults.set(newValue.rawValue, forKey: Self.durationKey); stateChanged() }
    }

    // ── Lifecycle ───────────────────────────────────────────────────────────

    private func applyEnabled() {
        if settings.keepAwakeEnabled {
            guard item == nil else { return }
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            it.autosaveName = "dev.anode.keepawake"
            it.button?.target = self
            it.button?.action = #selector(clicked(_:))
            it.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item = it
            // On this macOS a right click on a status item was measured not to reach the button's action at all
            // (the log shows left clicks only). A monitor sees it whatever the button does; whichever of the two
            // arrives first opens the menu and the other is ignored for a moment.
            rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .rightMouseUp]) { [weak self] e in
                guard let self, let button = self.item?.button, e.window === button.window else { return e }
                self.log("right click seen (monitor) type=\(e.type.rawValue)")
                if e.type == .rightMouseUp { self.showMenu(from: button) }
                return nil
            }
            stateChanged()
        } else {
            if let m = rightClickMonitor { NSEvent.removeMonitor(m); rightClickMonitor = nil }
            core.stop()
            if let it = item { NSStatusBar.system.removeStatusItem(it) }
            item = nil
            stateChanged()
        }
    }

    /// Quitting is a stop: the one place a held-open lid must never outlive the app.
    func shutdown() {
        timer?.invalidate()
        lidTimer?.invalidate()
        core.stop()
        dimmer.release()
    }

    private func stateChanged() {
        log("state: \(core.session.map { $0.mode.rawValue } ?? "off") lastStop=\(core.lastStop.map { "\($0)" } ?? "-")")
        updateIcon()
        scheduleTick()
        updateLidWatch()
        onChange?()
    }

    /// While Always Stay Awake runs, look at the lid once a second so the panel goes dark when it shuts and comes
    /// back when it opens. Any other state (or none) puts the brightness back and stops looking.
    private func updateLidWatch() {
        if core.session?.mode == .alwaysAwake {
            guard lidTimer == nil else { return }
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.dimmer.poll() }
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
            lidTimer = t
            dimmer.poll()
        } else {
            lidTimer?.invalidate()
            lidTimer = nil
            dimmer.release()
        }
    }

    // ── Clicks ──────────────────────────────────────────────────────────────

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        // A right click can arrive as either half of the click, a two-finger tap as button 1, and Control-click as a
        // left click with Control held; all of them mean "the menu".
        let wantsMenu = e.map { [.rightMouseUp, .rightMouseDown].contains($0.type) || $0.buttonNumber == 1
            || $0.modifierFlags.contains(.control) } ?? false
        log("click event=\(e.map { "\($0.type.rawValue)" } ?? "none") button=\(e?.buttonNumber ?? -1) → "
            + (wantsMenu ? "menu" : "cycle"))
        if wantsMenu { showMenu(from: sender) } else { cycle() }
    }

    /// The icon's click: off → Never Sleep → Always Stay Awake → off. If Always Stay Awake is declined (no permission
    /// and the owner says no) the click lands on off, so the next one starts the round again.
    func cycle() {
        switch core.session?.mode {
        case nil:             begin(.neverSleep)
        case .neverSleep?:    begin(.alwaysAwake, onDeclined: { [weak self] in self?.core.stop() })
        case .alwaysAwake?:   core.stop()
        }
    }

    /// The Turn On / Turn Off button and menu item: running → stop; stopped → start the remembered mode.
    func toggle() {
        if core.isActive { core.stop(); return }
        begin(mode)
    }

    /// Start `mode` for the remembered duration. Always Stay Awake without its permission explains and offers to set it up.
    func begin(_ mode: KeepAwakeMode, onDeclined: (() -> Void)? = nil) {
        self.mode = mode
        do {
            try core.start(mode, for: duration.seconds)
            log("started \(mode.rawValue) for \(duration.title)")
        } catch KeepAwakeError.notAuthorised {
            log("\(mode.rawValue) refused: permission not installed")
            offerPermission(thenStart: mode, onDeclined: onDeclined)
        } catch {
            log("\(mode.rawValue) failed: \(error)")
            onDeclined?()
            alert("Could not turn on \(mode.title)",
                  "macOS refused the request (\(error)). Nothing was changed.")
        }
    }

    /// Asks whether to go ahead and ask macOS for admin rights; true for "Allow…". A property so a test can answer.
    var confirmPermission: () -> Bool = {
        let a = NSAlert()
        a.messageText = "Allow Always Stay Awake?"
        a.informativeText = "Keeping a Mac running with its lid closed needs administrator rights. macOS will ask for "
            + "your password (or Touch ID) once. Anode then adds a rule that lets your account run exactly "
            + "“pmset -a disablesleep 1” and “… 0” without a password, and nothing else. You can remove it any time "
            + "from Settings → Beta Features."
        a.addButton(withTitle: "Allow…")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }

    private func offerPermission(thenStart mode: KeepAwakeMode, onDeclined: (() -> Void)? = nil) {
        guard confirmPermission() else { onDeclined?(); return }
        authorise { [weak self] ok in
            if ok { self?.begin(mode) } else { onDeclined?() }
        }
    }

    /// Run the one-time admin prompt; `completion` gets whether the rule is now in place.
    func authorise(completion: @escaping (Bool) -> Void) {
        KeepAwakeAuthorisation.install { [weak self] ok in
            self?.log("permission install \(ok ? "succeeded" : "FAILED")")
            if !ok {
                self?.alert("Permission not added", "Always Stay Awake needs it, so it stays off. Nothing was changed.")
            }
            self?.onChange?()
            completion(ok)
        }
    }

    /// Remove the rule (and stop any session that relies on it first).
    func revokeAuthorisation(completion: @escaping (Bool) -> Void) {
        if core.session?.mode == .alwaysAwake { core.stop() }
        KeepAwakeAuthorisation.remove { [weak self] ok in
            self?.log("permission removal \(ok ? "succeeded" : "FAILED")")
            self?.onChange?()
            completion(ok)
        }
    }

    // ── Menu ────────────────────────────────────────────────────────────────

    private func showMenu(from button: NSStatusBarButton) {
        guard Date().timeIntervalSince(menuShownAt) > 0.4 else { return }
        menuShownAt = Date()
        log("menu opened")
        let menu = NSMenu()
        menu.autoenablesItems = false

        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        for m in KeepAwakeMode.allCases {
            let mi = NSMenuItem(title: "\(m.title) — \(m.detail)", action: #selector(pickMode(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = m.rawValue
            mi.state = (core.session?.mode ?? mode) == m ? .on : .off
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Keep awake for", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for d in KeepAwakeDuration.allCases {
            let di = NSMenuItem(title: d.title, action: #selector(pickDuration(_:)), keyEquivalent: "")
            di.target = self
            di.representedObject = d.rawValue
            di.state = duration == d ? .on : .off
            di.indentationLevel = 1
            menu.addItem(di)
        }
        menu.addItem(.separator())
        if core.isActive {
            let off = NSMenuItem(title: "Turn Off", action: #selector(turnOff), keyEquivalent: "")
            off.target = self
            menu.addItem(off)
        } else {
            let on = NSMenuItem(title: "Turn On — \(mode.title)", action: #selector(turnOn), keyEquivalent: "")
            on.target = self
            menu.addItem(on)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    /// Choosing a mode switches to it now, and remembers it for the next plain click.
    @objc private func pickMode(_ sender: NSMenuItem) {
        guard let m = (sender.representedObject as? String).flatMap(KeepAwakeMode.init(rawValue:)) else { return }
        log("menu: picked \(m.rawValue)")
        begin(m)
    }

    /// Choosing a duration applies it from now if a session is running.
    @objc private func pickDuration(_ sender: NSMenuItem) {
        guard let d = (sender.representedObject as? Int).flatMap(KeepAwakeDuration.init(rawValue:)) else { return }
        duration = d
        if let s = core.session { begin(s.mode) }
    }

    @objc private func turnOff() { log("menu: turn off"); core.stop() }
    @objc private func turnOn() { begin(mode) }

    func statusLine() -> String {
        guard let s = core.session else {
            switch core.lastStop {
            case .expired?:               return "Off — the time you set ran out"
            case .lowBattery(let p)?:     return "Off — battery reached \(p)%, so Always Stay Awake stopped"
            case .couldNotRestoreSleep?:  return "Off — could not restore normal sleep; will retry at next launch"
            default:                      return "Off"
            }
        }
        var line = s.mode == .alwaysAwake ? "Always Stay Awake — keeps running with the lid shut" : "Never Sleep — until the lid closes"
        if let r = core.remaining() { line += " · \(Self.format(remaining: r)) left" }
        return line
    }

    static func format(remaining r: TimeInterval) -> String {
        let m = Int((r / 60).rounded(.up))
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }

    // ── Icon ────────────────────────────────────────────────────────────────

    private func updateIcon() {
        guard let button = item?.button else { return }
        button.image = Self.icon(for: core.session?.mode)
        button.toolTip = "Keep Awake: " + statusLine()
            + "\nClick: Off → Never Sleep → Always Stay Awake · Right-click: menu"
        button.setAccessibilityLabel("Keep Awake")
        button.setAccessibilityValue(statusLine())
    }

    /// A laptop that shows what each state does (drawn here, not an SF Symbol, so it matches nothing else in the
    /// menu bar): open with a dark screen (off), open with a lit screen (Never Sleep), shut with a pulse above it,
    /// still running (Always Stay Awake). Template images, so the menu bar inks them for light, dark and the wallpaper.
    static func icon(for mode: KeepAwakeMode?) -> NSImage? {
        let size = NSSize(width: 22, height: 15)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            switch mode {
            case nil, .neverSleep?:
                // Screen, then the base. Off is the outline, Never Sleep the same screen filled in.
                let screen = NSBezierPath(roundedRect: NSRect(x: 5, y: 5, width: 12, height: 8.5), xRadius: 1.4, yRadius: 1.4)
                if mode == nil {
                    let outline = NSBezierPath(roundedRect: NSRect(x: 5.6, y: 5.6, width: 10.8, height: 7.3), xRadius: 1, yRadius: 1)
                    outline.lineWidth = 1.2
                    outline.stroke()
                } else {
                    screen.fill()
                }
                NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 18, height: 2), xRadius: 1, yRadius: 1).fill()
            case .alwaysAwake?:
                // Lid shut: a flat slab, with a dot and a ring floating above it for "still running".
                NSBezierPath(roundedRect: NSRect(x: 2, y: 1, width: 18, height: 3), xRadius: 1.4, yRadius: 1.4).fill()
                NSBezierPath(ovalIn: NSRect(x: 9.5, y: 8.5, width: 3, height: 3)).fill()
                let ring = NSBezierPath(ovalIn: NSRect(x: 7, y: 6, width: 8, height: 8))
                ring.lineWidth = 1.2
                ring.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Keep Awake"
        return image
    }

    // ── Watching a running session ──────────────────────────────────────────

    /// One timer, aimed at whichever comes first: the next battery look (every 20 s) or the moment the session ends.
    private func scheduleTick() {
        timer?.invalidate()
        timer = nil
        guard core.isActive else { return }
        let wait = min(20, max(0.5, core.remaining() ?? 20))
        timer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        guard core.isActive else { return }
        // The battery only matters to Always Stay Awake; a plain Never Sleep session just waits for its end.
        let b = core.session?.mode == .alwaysAwake ? Battery.state() : nil
        core.tick(batteryPercent: b?.percent, onAC: b?.onAC ?? true)
        if core.isActive { scheduleTick() }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

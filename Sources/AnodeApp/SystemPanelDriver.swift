import AppKit
import ApplicationServices
import PowerKit
import ScreenCaptureKit

// ── Using macOS's own Sound and Battery panels, unseen ──────────────────────
//
// The order of the steps and what they report is `SystemPanelPress` (PowerKit, tested). This file carries the steps out
// through Accessibility and nothing else: it finds macOS's menu bar item, presses it, moves the panel that opens to the left
// of the screen the moment it exists, reads or presses a row, closes the panel, and keeps a still picture of the idle icon
// over macOS's icon while all that goes on (macOS lights the icon while its panel is open).
//
// Facts it relies on, all measured on macOS 27:
//   • macOS's menu bar items belong to `com.apple.MenuBarAgent` (`AXExtrasMenuBar`); their panels are windows of
//     `com.apple.controlcenter` with subrole `AXSystemDialog`, 522 x 1102 pt, mostly transparent.
//   • The window's position can be set, and the change holds; pressing a row works while it is off the screen.
//   • A refusal is a separate window of Control Center, subrole `AXDialog`, with an OK button.
//   • Pressing a row and closing the panel at once still applies the change.

/// What the controller needs from the live driver; tests give it a fake.
protocol SystemPanelDriving: AnyObject {
    /// Runs one job and reports once. Jobs run one at a time, in the order they were given.
    func run(_ kind: SystemPanelKind, job: SystemPanelPress.Job, done: @escaping (SystemPanelOutcome) -> Void)
    /// Forgets every job waiting, and ends the one running: macOS's panel is closed and the cover over its icon comes down.
    func cancelAll()
}

/// A still picture of part of the screen, shown over the live thing it is a picture of. Over macOS's icon it hides the lit look
/// the icon takes while macOS's panel is open; over the place macOS's panel first appears it hides that panel's first frames
/// (it opens where the person's own menu is about to be, and is moved off the screen a moment later).
final class IconCover {

    private let level: Int
    private let tag: String

    /// `level` is the window level it is shown at.
    init(level: Int, tag: String = "") { self.level = level; self.tag = tag }

    private var window: NSWindow?
    private var image: NSImage?
    private var imageFrame = CGRect.zero
    private var takenAt = Date.distantPast

    /// The rect, in whole points (top-left global), the picture covers: the icon with a little room each side, the height
    /// of the bar. Whole points, because a cover placed between pixels shows an edge.
    static func rect(for frame: CGRect) -> CGRect {
        CGRect(x: CGFloat(Int(frame.minX) - 6), y: CGFloat(Int(frame.minY)),
               width: CGFloat(Int(frame.width) + 12), height: CGFloat(Int(max(frame.height, 33))))
    }

    /// Takes the idle picture, unless one of the same place is under `maxAge` seconds old. Needs Screen Recording; without
    /// it there is no picture and no cover, and the icon shows its lit look for a moment.
    func prepare(frame: CGRect, maxAge: TimeInterval = 5, exact: Bool = false, leavingOut: Set<CGWindowID> = []) async {
        let cover = exact ? frame : Self.rect(for: frame)
        if imageFrame == cover, Date().timeIntervalSince(takenAt) < maxAge, image != nil { return }
        guard ScreenRecordingAccess.isGranted, #available(macOS 14.0, *) else { image = nil; return }
        guard let (band, origin, scale) = await BarPictures.captureBand(of: cover, height: cover.maxY + 2, leavingOut: leavingOut) else {
            image = nil; return
        }
        let crop = CGRect(x: (cover.minX - origin.x) * scale, y: (cover.minY - origin.y) * scale,
                          width: cover.width * scale, height: cover.height * scale)
        guard let cut = band.cropping(to: crop) else { image = nil; return }
        image = NSImage(cgImage: cut, size: cover.size)
        imageFrame = cover
        takenAt = Date()
    }

    func show() {
        guard let image, imageFrame != .zero, let screen = NSScreen.screens.first else { return }
        let r = NSRect(x: imageFrame.minX, y: screen.frame.height - imageFrame.minY - imageFrame.height,
                       width: imageFrame.width, height: imageFrame.height)
        let w = window ?? NSWindow(contentRect: r, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none   // a window that zooms in is a visible change in itself
        // Over macOS's own menu bar items (measured): one level under the shielding level.
        w.level = NSWindow.Level(rawValue: level)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let view = NSImageView(frame: NSRect(origin: .zero, size: r.size))
        view.image = image
        view.imageScaling = .scaleAxesIndependently
        w.contentView = view
        w.setFrame(r, display: false)
        w.orderFrontRegardless()
        // Drawn and sent to the window server NOW: the next thing the driver does is a call into another process that blocks
        // this thread, and a picture that only appears after it is no cover at all.
        w.displayIfNeeded()
        CATransaction.flush()
        window = w
    }

    func hide() { window?.orderOut(nil) }
}

final class SystemPanelDriver: SystemPanelDriving {

    private struct Queued { let kind: SystemPanelKind; let job: SystemPanelPress.Job; let done: (SystemPanelOutcome) -> Void }

    static let menuBarAgent = "com.apple.MenuBarAgent"
    static let controlCenter = "com.apple.controlcenter"
    static let offScreenX: CGFloat = -4000

    private var queue: [Queued] = []
    private var busy = false
    /// Over macOS's menu bar icon: above everything of the menu bar (measured).
    private let cover = IconCover(level: Int(CGShieldingWindowLevel()) - 1)
    /// Over the place macOS's panel appears: above that panel (level 101), below Anode's own menu.
    private let panelCover = IconCover(level: SoundMenuPanel.level - 1, tag: "panel")
    private let log: (String) -> Void

    // The job in flight.
    private var machine: SystemPanelPress?
    private var current: Queued?
    private var item: AXUIElement?
    private var itemFrame = CGRect.zero
    private var route = SystemPanelRoute.menuExtra
    private var observer: AXObserver?
    private var ccElement: AXUIElement?
    /// Alert windows already answered in this job, by identity: the OK press is not instant, and the same window must not be
    /// reported (or answered) twice.
    private var answeredAlerts = Set<CFHashCode>()

    init(log: @escaping (String) -> Void = { _ in }) { self.log = log }

    // ── Queue ───────────────────────────────────────────────────────────────

    func run(_ kind: SystemPanelKind, job: SystemPanelPress.Job, done: @escaping (SystemPanelOutcome) -> Void) {
        queue.append(Queued(kind: kind, job: job, done: done))
        startNext()
    }

    private func startNext() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let next = queue.removeFirst()
        current = next
        Task { @MainActor in await self.begin(next) }
    }

    private func finishJob(_ outcome: SystemPanelOutcome) {
        removeObserver()
        panelCover.hide()
        answeredAlerts.removeAll()
        let done = current?.done
        current = nil; machine = nil; busy = false
        done?(outcome)
        startNext()
    }

    func cancelAll() {
        queue.removeAll()
        guard busy else { return }
        if panelWindow() != nil, let item { AXUIElementPerformAction(item, kAXPressAction as CFString) }
        cover.hide()
        finishJob(.failed(.panelDidNotOpen))
        queue.removeAll()
    }

    // ── Starting a job ──────────────────────────────────────────────────────

    @MainActor private func begin(_ job: Queued) async {
        guard AXIsProcessTrusted() else { machineStart(job, accessibility: false, personHasPanelOpen: false); return }
        guard let found = locate(job.kind) else { finishJob(.failed(.noMenuExtra)); return }
        item = found.item; itemFrame = found.frame; route = found.route
        ccElement = Self.application(Self.controlCenter)
        await cover.prepare(frame: itemFrame)
        // The first frames of macOS's panel are hidden too. When Anode's own menu is already up the cover goes under it, and the
        // picture is taken without that menu: the menu's glass blurs what is under it, so a bright panel there (even for two frames,
        // measured at 120 fps) lightens the menu.
        await panelCover.prepare(frame: Self.panelRegion(for: itemFrame), maxAge: 0, exact: true, leavingOut: ownMenuWindowIDs())
        machineStart(job, accessibility: true, personHasPanelOpen: panelOnScreen())
    }

    @MainActor private func machineStart(_ job: Queued, accessibility: Bool, personHasPanelOpen: Bool) {
        var m = SystemPanelPress(job: job.job, route: accessibility ? route : .menuExtra,
                                 personHasPanelOpen: personHasPanelOpen, accessibility: accessibility)
        let actions = m.start()
        machine = m
        perform(actions)
    }

    private func feed(_ event: SystemPanelPress.Event) {
        guard var m = machine else { return }
        let actions = m.handle(event)
        machine = m
        perform(actions)
    }

    // ── Carrying out the steps ──────────────────────────────────────────────

    private func perform(_ actions: [SystemPanelPress.Action]) {
        for action in actions {
            switch action {
            case .coverIcon:
                cover.show()
                panelCover.show()
            case .openPanel: openPanel()
            case .openSection(let id): openSection(id)
            case .movePanelOffScreen: movePanel()
            case .readTree: readTree()
            case .pressRow(let row): pressRow(row)
            case .dismissAlert: pressAlertButtons()
            case .closePanel: closePanel()
            case .waitForAlert(let seconds):
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    self?.answerAlerts()
                    self?.feed(.alertWindowElapsed)
                }
            case .uncoverIcon(let delay):
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.cover.hide() }
            case .finish(let outcome): finishJob(outcome)
            }
        }
    }

    private func openPanel() {
        installObserver()
        guard let item else { feed(.openTimedOut); return }
        // A beat after the covers went up, so they are on the screen before macOS's panel is.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self, self.machine != nil else { return }
            AXUIElementPerformAction(item, kAXPressAction as CFString)
            self.poll(timeout: SystemPanelTiming.openTimeout, until: { self.panelWindow() != nil },
                      then: { ok in self.feed(ok ? .opened : .openTimedOut) })
        }
    }

    private func openSection(_ id: String) {
        guard let window = panelWindow(), let button = find(in: window, where: { Self.string($0, "AXIdentifier") == id }) else {
            feed(.openTimedOut); return
        }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
        // The rows of the section replace Control Center's modules: wait for one that is not a module.
        poll(timeout: SystemPanelTiming.openTimeout,
             until: { self.panelWindow().map { w in self.find(in: w, where: { Self.string($0, "AXIdentifier").hasPrefix("sound-device-")
                                                    || Self.string($0, "AXIdentifier").hasPrefix("energy-mode-") }) != nil } ?? false },
             then: { ok in self.feed(ok ? .sectionOpened : .openTimedOut) })
    }

    private func movePanel() {
        guard let window = panelWindow() else { return }
        Self.moveOffScreen(window)
    }

    private func readTree() {
        guard let window = panelWindow() else { feed(.rowMissing); return }
        feed(.treeRead(Self.tree(of: window, depth: 0)))
    }

    private func pressRow(_ row: SystemPanelRow) {
        guard let window = panelWindow(),
              let element = find(in: window, where: {
                  // Only a row that can be pressed: a button, or a toggle row (macOS's own Settings buttons have no id).
                  let role = Self.string($0, kAXRoleAttribute)
                  guard role == "AXCheckBox" || role == "AXButton" else { return false }
                  return Self.string($0, "AXIdentifier") == row.identifier && Self.string($0, kAXDescriptionAttribute) == row.description
              }) else { feed(.rowMissing); return }
        AXUIElementPerformAction(element, kAXPressAction as CFString)
        feed(.rowPressed)
    }

    private func closePanel() {
        guard let target = closingItem() else { feed(.closed); return }
        AXUIElementPerformAction(target, kAXPressAction as CFString)
        poll(timeout: 1.0, until: { self.panelWindow() == nil }, then: { ok in
            if !ok, let again = self.closingItem() { AXUIElementPerformAction(again, kAXPressAction as CFString) }
            self.feed(.closed)
        })
    }

    /// The item that closes the panel: pressing the icon again, which for the Control Center route is Control Center's own.
    private func closingItem() -> AXUIElement? { item }

    // ── Alerts ──────────────────────────────────────────────────────────────

    /// macOS's refusal is its own window ("Failed to set listening mode"). It is answered only when it has exactly one button
    /// (an acknowledgement: there is no choice to make for the person) and only while a job of Anode's is running; any other
    /// dialog of Control Center is left alone, where the person can see it. Each window is answered and reported once.
    private func answerAlerts() {
        guard machine != nil, let cc = ccElement else { return }
        for window in windows(of: cc) where Self.string(window, kAXSubroleAttribute) == "AXDialog" {
            let key = CFHash(window)
            guard !answeredAlerts.contains(key) else { continue }
            let kids = children(of: window)
            let buttons = kids.filter { Self.string($0, kAXRoleAttribute) == "AXButton" }
            guard buttons.count == 1 else { continue }
            answeredAlerts.insert(key)
            let texts = kids.filter { Self.string($0, kAXRoleAttribute) == "AXStaticText" }.map { Self.string($0, kAXValueAttribute) }
            AXUIElementPerformAction(buttons[0], kAXPressAction as CFString)
            if !texts.isEmpty { feed(.alert(texts.joined(separator: " / "))) }
        }
    }

    /// The step the state machine asks for after an alert: the OK was already pressed by `answerAlerts`; press any single
    /// button of an alert still showing, without reporting again.
    private func pressAlertButtons() {
        guard machine != nil, let cc = ccElement else { return }
        for window in windows(of: cc) where Self.string(window, kAXSubroleAttribute) == "AXDialog" {
            let buttons = children(of: window).filter { Self.string($0, kAXRoleAttribute) == "AXButton" }
            if buttons.count == 1 { AXUIElementPerformAction(buttons[0], kAXPressAction as CFString) }
        }
    }

    private func installObserver() {
        removeObserver()
        guard let cc = ccElement, let pid = Self.pid(of: Self.controlCenter) else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            // The panel is moved off the screen the moment it exists; an alert is answered. Nothing else is touched, and
            // nothing at all outside a job.
            guard let refcon else { return }
            let driver = Unmanaged<SystemPanelDriver>.fromOpaque(refcon).takeUnretainedValue()
            guard driver.machine != nil else { return }
            switch SystemPanelDriver.string(element, kAXSubroleAttribute) {
            case "AXSystemDialog": SystemPanelDriver.moveOffScreen(element)
            case "AXDialog": driver.answerAlerts()
            default: break
            }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let obs = created else { return }
        AXObserverAddNotification(obs, cc, kAXWindowCreatedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
    }

    private func removeObserver() {
        if let obs = observer {
            if let cc = ccElement { AXObserverRemoveNotification(obs, cc, kAXWindowCreatedNotification as CFString) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
    }

    deinit { removeObserver() }

    // ── Finding things ──────────────────────────────────────────────────────

    private func locate(_ kind: SystemPanelKind) -> (item: AXUIElement, frame: CGRect, route: SystemPanelRoute)? {
        guard let agent = Self.application(Self.menuBarAgent),
              let bar = Self.element(Self.attribute(agent, "AXExtrasMenuBar")) else { return nil }
        let items = children(of: bar).flatMap { children(of: $0) }
        func item(_ id: String) -> (AXUIElement, CGRect)? {
            items.first { Self.string($0, "AXIdentifier") == id }.map { ($0, Self.frame(of: $0)) }
        }
        let own = kind == .sound ? "com.apple.menuextra.sound" : "com.apple.menuextra.battery"
        if let (e, f) = item(own) { return (e, f, .menuExtra) }
        let section = kind == .sound ? "controlcenter-volume" : "controlcenter-battery"
        if let (e, f) = item("com.apple.menuextra.controlcenter") { return (e, f, .controlCenter(section: section)) }
        return nil
    }

    /// Control Center's panel window, wherever it is.
    private func panelWindow() -> AXUIElement? {
        guard let cc = ccElement ?? Self.application(Self.controlCenter) else { return nil }
        return windows(of: cc).first { Self.string($0, kAXSubroleAttribute) == "AXSystemDialog" }
    }

    /// True when a panel of Control Center is on the screen at its own place: the person opened it.
    /// Fails closed: when the window list cannot be read, the person is assumed to have it open and nothing is touched.
    /// Where macOS's panel first appears for an icon at `item`: its right edge 10.5 pt past the icon's, 2 pt under the menu bar, with
    /// room around it for the shadow. The panel is at most 560 pt tall.
    static func panelRegion(for item: CGRect) -> CGRect {
        CGRect(x: CGFloat(Int(item.maxX + 10.5 - 309) - 28), y: 0, width: 309 + 56, height: 640)
    }

    /// The window of Anode's own Sound menu, when it is on the screen.
    private func ownMenuWindowIDs() -> Set<CGWindowID> {
        let me = ProcessInfo.processInfo.processIdentifier
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        return Set(list.compactMap { w in
            guard (w[kCGWindowOwnerPID as String] as? Int32) == me, (w[kCGWindowLayer as String] as? Int) == SoundMenuPanel.level else { return nil }
            return (w[kCGWindowNumber as String] as? Int).map { CGWindowID($0) }
        })
    }

    private func panelOnScreen() -> Bool {
        guard let pid = Self.pid(of: Self.controlCenter) else { return false }   // no Control Center: nothing to be open
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return true }
        return list.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid, (w[kCGWindowLayer as String] as? Int) == 101 else { return false }
            guard let b = w[kCGWindowBounds as String] as? [String: Any], let x = b["X"] as? Double else { return true }
            return x > -1000
        }
    }

    private func find(in root: AXUIElement, where match: (AXUIElement) -> Bool, depth: Int = 0) -> AXUIElement? {
        if match(root) { return root }
        guard depth < 16 else { return nil }
        for child in children(of: root) { if let hit = find(in: child, where: match, depth: depth + 1) { return hit } }
        return nil
    }

    private func poll(timeout: TimeInterval, until condition: @escaping () -> Bool, then finish: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func step() {
            if condition() { finish(true); return }
            if Date() >= deadline { finish(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.004) { step() }
        }
        step()
    }

    // ── Accessibility helpers ───────────────────────────────────────────────

    private static func pid(of bundle: String) -> pid_t? { NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier }

    private static func application(_ bundle: String) -> AXUIElement? {
        guard let pid = pid(of: bundle) else { return nil }
        let e = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(e, 0.5)
        return e
    }

    private static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    private static func string(_ e: AXUIElement, _ name: String) -> String { attribute(e, name).map { "\($0)" } ?? "" }

    private func children(of e: AXUIElement) -> [AXUIElement] { (Self.attribute(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

    private func windows(of app: AXUIElement) -> [AXUIElement] { (Self.attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }

    private static func frame(of e: AXUIElement) -> CGRect {
        var r = CGRect.zero
        if let ref = attribute(e, "AXFrame"), CFGetTypeID(ref) == AXValueGetTypeID() {
            let v = ref as! AXValue   // checked by type id just above
            if AXValueGetType(v) == .cgRect { AXValueGetValue(v, .cgRect, &r) }
        }
        return r
    }

    /// An `AXUIElement` out of an attribute, or nil when the value is anything else.
    private static func element(_ ref: CFTypeRef?) -> AXUIElement? {
        guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)   // checked by type id just above
    }

    private static func moveOffScreen(_ window: AXUIElement) {
        var p = CGPoint(x: offScreenX, y: frame(of: window).minY)
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v) }
    }

    private static func tree(of e: AXUIElement, depth: Int) -> AXNode {
        let kids = depth < 16 ? (attribute(e, kAXChildrenAttribute) as? [AXUIElement] ?? []).map { tree(of: $0, depth: depth + 1) } : []
        return AXNode(role: string(e, kAXRoleAttribute), subrole: string(e, kAXSubroleAttribute), identifier: string(e, "AXIdentifier"),
                      description: string(e, kAXDescriptionAttribute), value: string(e, kAXValueAttribute),
                      enabled: string(e, kAXEnabledAttribute) != "0", frame: frame(of: e), children: kids)
    }
}

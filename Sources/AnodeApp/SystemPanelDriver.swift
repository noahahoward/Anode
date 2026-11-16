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
}

/// A still picture of a menu bar icon in its idle state, shown over the live icon.
final class IconCover {

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
    func prepare(frame: CGRect, maxAge: TimeInterval = 5) async {
        let cover = Self.rect(for: frame)
        if imageFrame == cover, Date().timeIntervalSince(takenAt) < maxAge, image != nil { return }
        guard ScreenRecordingAccess.isGranted, #available(macOS 14.0, *) else { image = nil; return }
        guard let (band, origin, scale) = await BarPictures.captureBand(of: cover, height: cover.maxY + 2, leavingOut: []) else {
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
        // Over macOS's own menu bar items (measured): one level under the shielding level.
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let view = NSImageView(frame: NSRect(origin: .zero, size: r.size))
        view.image = image
        view.imageScaling = .scaleAxesIndependently
        w.contentView = view
        w.setFrame(r, display: false)
        w.orderFrontRegardless()
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
    private let cover = IconCover()
    private let log: (String) -> Void

    // The job in flight.
    private var machine: SystemPanelPress?
    private var current: Queued?
    private var item: AXUIElement?
    private var itemFrame = CGRect.zero
    private var route = SystemPanelRoute.menuExtra
    private var observer: AXObserver?
    private var ccElement: AXUIElement?

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
        let done = current?.done
        current = nil; machine = nil; busy = false
        done?(outcome)
        startNext()
    }

    // ── Starting a job ──────────────────────────────────────────────────────

    @MainActor private func begin(_ job: Queued) async {
        guard AXIsProcessTrusted() else { machineStart(job, accessibility: false, personHasPanelOpen: false); return }
        guard let found = locate(job.kind) else { finishJob(.failed(.noMenuExtra)); return }
        item = found.item; itemFrame = found.frame; route = found.route
        ccElement = Self.application(Self.controlCenter)
        await cover.prepare(frame: itemFrame)
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
            case .coverIcon: cover.show()
            case .openPanel: openPanel()
            case .openSection(let id): openSection(id)
            case .movePanelOffScreen: movePanel()
            case .readTree: readTree()
            case .pressRow(let row): pressRow(row)
            case .dismissAlert: dismissAlerts()
            case .closePanel: closePanel()
            case .waitForAlert(let seconds):
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    self?.dismissAlerts(reporting: true)
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
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        poll(timeout: SystemPanelTiming.openTimeout, until: { self.panelWindow() != nil },
             then: { ok in self.feed(ok ? .opened : .openTimedOut) })
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
                  Self.string($0, "AXIdentifier") == row.identifier && Self.string($0, kAXDescriptionAttribute) == row.description
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

    /// macOS's refusal is its own window ("Failed to set listening mode"). Pressing OK ends it; its words are reported once.
    private func dismissAlerts(reporting: Bool = false) {
        guard let cc = ccElement else { return }
        for window in windows(of: cc) where Self.string(window, kAXSubroleAttribute) == "AXDialog" {
            let texts = children(of: window).filter { Self.string($0, kAXRoleAttribute) == "AXStaticText" }.map { Self.string($0, kAXValueAttribute) }
            if let ok = children(of: window).first(where: { Self.string($0, kAXRoleAttribute) == "AXButton" }) {
                AXUIElementPerformAction(ok, kAXPressAction as CFString)
            }
            if !texts.isEmpty { feed(.alert(texts.joined(separator: " / "))) }
        }
    }

    private func installObserver() {
        removeObserver()
        guard let cc = ccElement, let pid = Self.pid(of: Self.controlCenter) else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            // Every new window of Control Center is moved off the screen the moment it exists; an alert is also answered.
            SystemPanelDriver.moveOffScreen(element)
            guard let refcon else { return }
            let driver = Unmanaged<SystemPanelDriver>.fromOpaque(refcon).takeUnretainedValue()
            if SystemPanelDriver.string(element, kAXSubroleAttribute) == "AXDialog" { driver.dismissAlerts() }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let obs = created else { return }
        AXObserverAddNotification(obs, cc, kAXWindowCreatedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
    }

    private func removeObserver() {
        if let obs = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode) }
        observer = nil
    }

    // ── Finding things ──────────────────────────────────────────────────────

    private func locate(_ kind: SystemPanelKind) -> (item: AXUIElement, frame: CGRect, route: SystemPanelRoute)? {
        guard let agent = Self.application(Self.menuBarAgent), let bar = Self.attribute(agent, "AXExtrasMenuBar") else { return nil }
        let items = children(of: bar as! AXUIElement).flatMap { children(of: $0) }
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
    private func panelOnScreen() -> Bool {
        guard let pid = Self.pid(of: Self.controlCenter) else { return false }
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid, (w[kCGWindowLayer as String] as? Int) == 101,
                  let b = w[kCGWindowBounds as String] as? [String: Any], let x = b["X"] as? Double else { return false }
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
        if let v = attribute(e, "AXFrame") { AXValueGetValue(v as! AXValue, .cgRect, &r) }
        return r
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

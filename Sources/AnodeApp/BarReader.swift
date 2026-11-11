import AppKit
import ApplicationServices
import PowerKit

// ── Reading and pressing the menu bar items (Menu Bar Hider) ────────────────
//
// Status items are not windows on this macOS (not in CGWindowList, not in ScreenCaptureKit), so the only list of them is
// each app's Accessibility "extras menu bar". Measured on 2026-11-10 and 2026-11-11:
//  - every item has a position, a size and `AXPress`; Needs Accessibility, which Anode already asks for; reading is passive;
//  - the system's items are all owned by `com.apple.MenuBarAgent`, each a hosting group whose FIRST CHILD carries the
//    identifier (`com.apple.menuextra.wifi`, `.sound`, `.battery`, `.controlcenter`, `.clock`, `.focusmode`);
//  - a third-party item has no identifier, title or description at all: it is told apart by its order among its app's items;
//  - macOS parks the items that do not fit at x -1...7, y 1157, off the bar.
//
// Every call into another app's accessibility tree has a short messaging timeout and runs off the main thread: those calls
// have frozen Anode before (memory `anode-freeze-root-cause`).

final class AXBarReader: BarReading {

    /// What one extras-menu-bar child says about itself, already flattened out of the accessibility tree.
    struct Child: Equatable {
        var identifier: String?
        var title: String?
        var description: String?
        var frame: CGRect
        var hasPress: Bool
        /// A position, size or identifier that should have been there could not be read.
        var readFailed = false
    }

    private struct Found {
        var item: BarItem
        var press: AXUIElement
    }

    private let queue = DispatchQueue(label: "dev.anode.barreader", qos: .userInitiated)
    private let pressQueue = DispatchQueue(label: "dev.anode.barreader.press", qos: .userInteractive)
    /// The owners of the system's own items: when THEIR read fails the read as a whole has failed.
    private static let systemOwners: Set<String> = ["com.apple.MenuBarAgent", "com.apple.controlcenter"]
    /// The longest a whole read may take. Past it the bar is "unreadable" and nothing stays covered on the strength of it.
    static let budget: TimeInterval = 1.5
    static let perAppTimeout: Float = 0.4

    // ── Pure part ───────────────────────────────────────────────────────────

    /// The items of one app, left to right. The ordinal in each key counts among the items sharing a name (or among the
    /// unnamed ones), so one app's two items called the same, or with no name at all, still get different keys.
    /// The indices of `children` left to right. Ties (parked items stack at the same x) keep their original order, so this is
    /// the one ordering that keys and elements are both put in.
    static func order(of children: [Child]) -> [Int] {
        children.indices.sorted { a, b in
            children[a].frame.minX != children[b].frame.minX ? children[a].frame.minX < children[b].frame.minX : a < b
        }
    }

    /// False when any item could not be read in full. The whole read then fails: an item left out of it would not split a run
    /// of hidden ones, and a cover would be drawn over it.
    static func isComplete(_ children: [Child]) -> Bool { !children.contains { $0.readFailed } }

    static func parse(app: (bundleID: String?, name: String, pid: pid_t), children: [Child]) -> [BarItem] {
        var seen: [String: Int] = [:]
        return order(of: children).map { children[$0] }.map { c in
            func clean(_ s: String?) -> String? {
                guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
                return t
            }
            let name = clean(c.identifier) ?? clean(c.title) ?? clean(c.description) ?? ""
            let ordinal = seen[name, default: 0]
            seen[name] = ordinal + 1
            let key = BarItemKey.make(bundleID: app.bundleID, appName: app.name, identifier: c.identifier, title: c.title,
                                      description: c.description, ordinal: ordinal)
            return BarItem(key: key, bundleID: app.bundleID, appName: app.name, title: clean(c.title) ?? clean(c.description) ?? clean(c.identifier) ?? "",
                           frame: c.frame, isLocked: BarItem.isLockedItem(identifier: c.identifier, title: c.title ?? c.description),
                           hasPress: c.hasPress, pid: app.pid)
        }
    }

    // ── BarReading ──────────────────────────────────────────────────────────

    func read(completion: @escaping ([BarItem]?) -> Void) {
        guard AXIsProcessTrusted() else { DispatchQueue.main.async { completion(nil) }; return }
        // The app list is read here, on the main thread; the accessibility work happens on the queue.
        let apps = NSWorkspace.shared.runningApplications.map { (bundleID: $0.bundleIdentifier, name: $0.localizedName ?? "?", pid: $0.processIdentifier) }
        // The deadline is kept on THIS side: a scan stuck on a hung app cannot be cut short, but its answer can be refused.
        let once = OnceCompletion(completion)
        let deadline = DispatchWorkItem { _ = once.complete(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.budget, execute: deadline)
        queue.async {
            let found = Self.scan(apps: apps)
            DispatchQueue.main.async {
                deadline.cancel()
                _ = once.complete(found?.map(\.item))
            }
        }
    }

    /// `AXPress` on the item. The target is found again by process and key, since an element does not outlive a read. On a
    /// queue of its own: a click must not wait behind a slow read.
    func press(_ item: BarItem) {
        guard AXIsProcessTrusted(), let pid = item.pid,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        let entry = (bundleID: app.bundleIdentifier, name: app.localizedName ?? "?", pid: pid)
        pressQueue.async {
            guard let hit = Self.scan(apps: [entry])?.first(where: { $0.item.key == item.key }) else { return }
            _ = AXUIElementPerformAction(hit.press, kAXPressAction as CFString)
        }
    }

    // ── Accessibility ───────────────────────────────────────────────────────

    /// nil when the bar could not be read in full.
    private static func scan(apps: [(bundleID: String?, name: String, pid: pid_t)]) -> [Found]? {
        let lock = NSLock()
        var all: [Found] = []
        var failed = false
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            guard let found = scan(app: apps[i]) else {
                lock.lock(); failed = true; lock.unlock()
                return
            }
            guard !found.isEmpty else { return }
            lock.lock(); all += found; lock.unlock()
        }
        return failed ? nil : all
    }

    private static func scan(app: (bundleID: String?, name: String, pid: pid_t)) -> [Found]? {
        let root = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(root, perAppTimeout)
        var barValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(root, "AXExtrasMenuBar" as CFString, &barValue)
        guard status == .success, let bar = barValue else {
            // Most apps have no extras menu bar, and say so. The system's own items are the exception: an error there is a read
            // that failed, not an app with nothing to show.
            let none = status == .noValue || status == .attributeUnsupported || status == .notImplemented
            return none || !(app.bundleID.map(systemOwners.contains) ?? false) ? [] : nil
        }
        AXUIElementSetMessagingTimeout(bar as! AXUIElement, perAppTimeout)
        guard let kids = attribute(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement], !kids.isEmpty else { return [] }

        var children: [Child] = []
        var targets: [AXUIElement] = []
        for kid in kids {
            AXUIElementSetMessagingTimeout(kid, perAppTimeout)
            // The system's items are hosting groups; the item proper, with its identifier, is the first child.
            let inner = (attribute(kid, kAXChildrenAttribute) as? [AXUIElement])?.first
            if let inner { AXUIElementSetMessagingTimeout(inner, perAppTimeout) }
            let outerPress = hasPress(kid)
            let innerPress = inner.map(hasPress) ?? false
            let (box, framed) = frame(of: kid)
            let hosting = string(kid, kAXSubroleAttribute) == "AXHostingView"
            let identifier = string(kid, kAXIdentifierAttribute) ?? inner.flatMap { string($0, kAXIdentifierAttribute) }
            children.append(Child(identifier: identifier,
                                  title: string(kid, kAXTitleAttribute),
                                  description: string(kid, kAXDescriptionAttribute) ?? inner.flatMap { string($0, kAXDescriptionAttribute) },
                                  frame: box, hasPress: outerPress || innerPress,
                                  readFailed: !framed || (hosting && identifier == nil)))
            targets.append(outerPress ? kid : (innerPress ? inner! : kid))
        }
        guard isComplete(children) else { return nil }
        // Keys and elements are put in the same order, by the same function.
        let order = Self.order(of: children)
        let items = parse(app: app, children: children)
        return zip(items, order).map { Found(item: $0.0, press: targets[$0.1]) }
    }

    private static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }

    private static func string(_ e: AXUIElement, _ name: String) -> String? { attribute(e, name) as? String }

    private static func hasPress(_ e: AXUIElement) -> Bool {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(e, &actions) == .success else { return false }
        return (actions as? [String])?.contains(kAXPressAction as String) ?? false
    }

    /// The frame, and whether both the position and the size could be read.
    private static func frame(of e: AXUIElement) -> (CGRect, Bool) {
        var p = CGPoint.zero, s = CGSize.zero
        var ok = true
        if let pv = attribute(e, kAXPositionAttribute) { ok = ok && AXValueGetValue(pv as! AXValue, .cgPoint, &p) } else { ok = false }
        if let sv = attribute(e, kAXSizeAttribute) { ok = ok && AXValueGetValue(sv as! AXValue, .cgSize, &s) } else { ok = false }
        return (CGRect(origin: p, size: s), ok)
    }
}

/// Delivers a result once. The read's deadline and its late answer race; whichever is second is dropped.
final class OnceCompletion {
    private let deliver: ([BarItem]?) -> Void
    private var done = false
    init(_ deliver: @escaping ([BarItem]?) -> Void) { self.deliver = deliver }
    /// True if this call was the one delivered.
    @discardableResult
    func complete(_ result: [BarItem]?) -> Bool {
        guard !done else { return false }
        done = true
        deliver(result)
        return true
    }
}

// ── What makes the layout worth reading again ───────────────────────────────

protocol BarEventing: AnyObject {
    var isRunning: Bool { get }
    /// True while covers are on screen: the layout is then re-read often, because a cover over a moved bar is worse than none.
    var urgent: Bool { get set }
    func start()
    func stop()
}

/// Calls `onChange` when something that moves the menu bar happens: an app starts or quits, the Space or a screen changes
/// (`displayChanged` is true for the last two: the layout is still moving and the pill was placed for the old one).
/// There is also a slow fallback timer, because an item can come and go without any of those. Nothing runs until `start()`
/// and everything is removed by `stop()`. Bursts are coalesced into one call.
final class BarEvents: BarEventing {

    private let onChange: (_ displayChanged: Bool) -> Void
    /// Called AT ONCE (not debounced) when the display changes, so covers drawn for the old layout come down before anything is
    /// read again.
    private let onInvalidate: () -> Void
    private let fallbackSeconds: TimeInterval
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var pendingScreenChange = false
    private(set) var isRunning = false
    var urgent = false

    init(fallbackSeconds: TimeInterval = 30, onChange: @escaping (_ displayChanged: Bool) -> Void,
         onInvalidate: @escaping () -> Void = {}) {
        self.onInvalidate = onInvalidate
        self.fallbackSeconds = fallbackSeconds
        self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append((ws, ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.fire(screen: false) }))
        }
        tokens.append((ws, ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) {
            [weak self] _ in self?.fire(screen: true)
        }))
        let nc = NotificationCenter.default
        tokens.append((nc, nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) {
            [weak self] _ in self?.fire(screen: true)
        }))
        timer = Timer.scheduledTimer(withTimeInterval: fallbackSeconds, repeats: true) { [weak self] _ in self?.fire(screen: false) }
        timer?.tolerance = fallbackSeconds / 4
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
        timer?.invalidate(); timer = nil
        pending?.cancel(); pending = nil
    }

    private func fire(screen: Bool) {
        if screen { onInvalidate() }
        pendingScreenChange = pendingScreenChange || screen
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            let screen = self.pendingScreenChange
            self.pendingScreenChange = false
            self.onChange(screen)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}

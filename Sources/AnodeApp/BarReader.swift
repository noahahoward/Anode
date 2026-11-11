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
    }

    private struct Found {
        var item: BarItem
        var press: AXUIElement
    }

    private let queue = DispatchQueue(label: "dev.anode.barreader", qos: .userInitiated)
    /// The longest a whole read may take. Past it the bar is "unreadable" and nothing stays covered on the strength of it.
    static let budget: TimeInterval = 1.5
    static let perAppTimeout: Float = 0.4

    // ── Pure part ───────────────────────────────────────────────────────────

    /// The items of one app, left to right. The ordinal in each key counts among the items sharing a name (or among the
    /// unnamed ones), so one app's two items called the same, or with no name at all, still get different keys.
    static func parse(app: (bundleID: String?, name: String, pid: pid_t), children: [Child]) -> [BarItem] {
        var seen: [String: Int] = [:]
        return children.sorted { $0.frame.minX < $1.frame.minX }.map { c in
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
        queue.async {
            let started = Date()
            let found = Self.scan(apps: apps)
            let ok = Date().timeIntervalSince(started) <= Self.budget
            DispatchQueue.main.async { completion(ok ? found.map(\.item) : nil) }
        }
    }

    /// `AXPress` on the item. The target is found again by process and key, since an element does not outlive a read.
    func press(_ item: BarItem) {
        guard AXIsProcessTrusted(), let pid = item.pid,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        let entry = (bundleID: app.bundleIdentifier, name: app.localizedName ?? "?", pid: pid)
        queue.async {
            guard let hit = Self.scan(apps: [entry]).first(where: { $0.item.key == item.key }) else { return }
            _ = AXUIElementPerformAction(hit.press, kAXPressAction as CFString)
        }
    }

    // ── Accessibility ───────────────────────────────────────────────────────

    private static func scan(apps: [(bundleID: String?, name: String, pid: pid_t)]) -> [Found] {
        let lock = NSLock()
        var all: [Found] = []
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let found = scan(app: apps[i])
            guard !found.isEmpty else { return }
            lock.lock(); all += found; lock.unlock()
        }
        return all
    }

    private static func scan(app: (bundleID: String?, name: String, pid: pid_t)) -> [Found] {
        let root = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(root, perAppTimeout)
        guard let bar = attribute(root, "AXExtrasMenuBar"),
              let kids = attribute(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement], !kids.isEmpty else { return [] }

        var children: [Child] = []
        var targets: [AXUIElement] = []
        for kid in kids {
            AXUIElementSetMessagingTimeout(kid, perAppTimeout)
            // The system's items are hosting groups; the item proper, with its identifier, is the first child.
            let inner = (attribute(kid, kAXChildrenAttribute) as? [AXUIElement])?.first
            if let inner { AXUIElementSetMessagingTimeout(inner, perAppTimeout) }
            let outerPress = hasPress(kid)
            let innerPress = inner.map(hasPress) ?? false
            children.append(Child(identifier: string(kid, kAXIdentifierAttribute) ?? inner.flatMap { string($0, kAXIdentifierAttribute) },
                                  title: string(kid, kAXTitleAttribute),
                                  description: string(kid, kAXDescriptionAttribute) ?? inner.flatMap { string($0, kAXDescriptionAttribute) },
                                  frame: frame(of: kid), hasPress: outerPress || innerPress))
            targets.append(outerPress ? kid : (innerPress ? inner! : kid))
        }
        // `parse` sorts left to right; keep each element with its child through the same order.
        let order = children.indices.sorted { children[$0].frame.minX < children[$1].frame.minX }
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

    private static func frame(of e: AXUIElement) -> CGRect {
        var p = CGPoint.zero, s = CGSize.zero
        if let pv = attribute(e, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
        if let sv = attribute(e, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
        return CGRect(origin: p, size: s)
    }
}

// ── What makes the layout worth reading again ───────────────────────────────

protocol BarEventing: AnyObject {
    var isRunning: Bool { get }
    func start()
    func stop()
}

/// Calls `onChange` when something that moves the menu bar happens: an app starts or quits, the Space or a screen changes
/// (`displayChanged` is true for the last two: the layout is still moving and the pill was placed for the old one).
/// There is also a slow fallback timer, because an item can come and go without any of those. Nothing runs until `start()`
/// and everything is removed by `stop()`. Bursts are coalesced into one call.
final class BarEvents: BarEventing {

    private let onChange: (_ displayChanged: Bool) -> Void
    private let fallbackSeconds: TimeInterval
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var pendingScreenChange = false
    private(set) var isRunning = false

    init(fallbackSeconds: TimeInterval = 30, onChange: @escaping (_ displayChanged: Bool) -> Void) {
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

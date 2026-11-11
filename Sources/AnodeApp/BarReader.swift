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

    /// Left to right on the bar; items at the same x (parked ones stack) by key, then process. Apps are read in parallel and
    /// answer in any order, and two reads of an unchanged bar must come out equal.
    static func precedes(_ a: BarItem, _ b: BarItem) -> Bool {
        if a.frame.minX != b.frame.minX { return a.frame.minX < b.frame.minX }
        if a.key != b.key { return a.key < b.key }
        return (a.pid ?? 0) < (b.pid ?? 0)
    }

    static func inBarOrder(_ items: [BarItem]) -> [BarItem] { items.sorted(by: precedes) }

    /// Which of `now` (a fresh read of the target's app) a press on `target` (from an earlier read) goes to, or nil for none.
    /// Unnamed items are keyed by their order, so when a sibling parks, comes or goes the keys shift and the key alone would
    /// open the other icon's menu. The item must also still be where it was, within `tolerance` points (x and y, so a parked
    /// item stays parked). If the key's item has moved, the one sibling now where the target was is the target; with none,
    /// or several (parked items stack), nothing is pressed.
    static func pressTarget(for target: BarItem, among now: [BarItem], tolerance: CGFloat = 4) -> Int? {
        func isWhereTargetWas(_ item: BarItem) -> Bool {
            abs(item.frame.midX - target.frame.midX) <= tolerance && abs(item.frame.midY - target.frame.midY) <= tolerance
        }
        let siblings = now.indices.filter { now[$0].pid == target.pid }
        if let keyed = siblings.first(where: { now[$0].key == target.key }), isWhereTargetWas(now[keyed]) { return keyed }
        let there = siblings.filter { isWhereTargetWas(now[$0]) }
        return there.count == 1 ? there[0] : nil
    }

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

    // ── What another app's answer means ────────────────────────────────────

    /// What an error from another app's accessibility tree means.
    enum Missing: Equatable {
        /// The app said so: there is nothing of that kind there.
        case nothingThere
        /// No answer that can be trusted (a timeout, a busy or quitting app, anything else). The read as a whole has failed:
        /// an app left out of it would let a cover span its items.
        case failed
    }

    static func classify(_ status: AXError) -> Missing {
        switch status {
        case .noValue, .attributeUnsupported, .notImplemented: return .nothingThere
        default: return .failed
        }
    }

    enum BarLookup: Equatable {
        case bar(AXUIElement)
        case nothingThere
        case failed
    }

    /// An app's extras menu bar, from what `AXExtrasMenuBar` answered.
    static func bar(status: AXError, value: CFTypeRef?) -> BarLookup {
        guard status == .success else { return classify(status) == .nothingThere ? .nothingThere : .failed }
        return element(value).map { .bar($0) } ?? .failed
    }

    /// A list of elements (children) from what was answered; nil when the read failed or anything in it is not an element.
    /// "No value" is an empty list.
    static func elements(status: AXError, value: CFTypeRef?) -> [AXUIElement]? {
        guard status == .success else { return classify(status) == .nothingThere ? [] : nil }
        guard let value, CFGetTypeID(value) == CFArrayGetTypeID(), let list = value as? [AnyObject] else { return nil }
        let found = list.compactMap(element)
        return found.count == list.count ? found : nil
    }

    // ── BarReading ──────────────────────────────────────────────────────────

    typealias App = (bundleID: String?, name: String, pid: pid_t)

    private let log: (String) -> Void
    /// The last failure logged, so an app that keeps failing is written down once, not on every read. Touched on `queue` only.
    private var lastFailure: String?
    /// The apps that said they have no extras menu bar, not asked again for a while. Touched on `queue` only; a press asks
    /// its app whatever this says.
    private var noBar = NoBarCache(neverSkipped: AXBarReader.systemOwners)

    init(log: @escaping (String) -> Void = { FeatureLog.append("menubarhider.log", $0) }) {
        self.log = log
    }

    func read(completion: @escaping ([BarItem]?) -> Void) {
        guard AXIsProcessTrusted() else { DispatchQueue.main.async { completion(nil) }; return }
        // The app list is read here, on the main thread; the accessibility work happens on the queue.
        let apps = NSWorkspace.shared.runningApplications.map { (bundleID: $0.bundleIdentifier, name: $0.localizedName ?? "?", pid: $0.processIdentifier) }
        // The deadline is kept on THIS side: a scan stuck on a hung app cannot be cut short, but its answer can be refused.
        let once = OnceCompletion(completion)
        let deadline = DispatchWorkItem { _ = once.complete(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.budget, execute: deadline)
        queue.async { [self] in
            noBar.sync(running: Set(apps.map(\.pid)), now: Date())
            let asked = apps.filter { !noBar.skips($0.pid) }
            let results = Self.scan(apps: asked)
            for (app, result) in zip(asked, results) {
                if case .nothingThere = result { noBar.record(pid: app.pid, bundleID: app.bundleID, answer: .nothingThere) }
            }
            let found = Self.combine(results)
            noteFailure(apps: asked, results: results)
            DispatchQueue.main.async {
                deadline.cancel()
                _ = once.complete(found?.map(\.item))
            }
        }
    }

    /// `AXPress` on the item. The target is found again by process, key and place (`pressTarget`), since an element does not
    /// outlive a read. On a queue of its own: a click must not wait behind a slow read.
    func press(_ item: BarItem) {
        guard AXIsProcessTrusted(), let pid = item.pid,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        let entry = (bundleID: app.bundleIdentifier, name: app.localizedName ?? "?", pid: pid)
        let log = self.log
        pressQueue.async {
            guard let found = Self.combine(Self.scan(apps: [entry])) else {
                log("press: \(item.key) not pressed, its app could not be read")
                return
            }
            guard let i = Self.pressTarget(for: item, among: found.map(\.item)) else {
                log("press: \(item.key) not pressed, nothing of its app is where it was (\(Int(item.frame.minX)),\(Int(item.frame.minY)))")
                return
            }
            _ = AXUIElementPerformAction(found[i].press, kAXPressAction as CFString)
        }
    }

    /// Writes down which app failed a read, and how, when that is not what was written down last.
    private func noteFailure(apps: [App], results: [AppScan]) {
        guard let i = results.firstIndex(where: { if case .failed = $0 { return true } else { return false } }),
              case .failed(let why) = results[i] else { lastFailure = nil; return }
        let line = "read failed: \(apps[i].bundleID ?? apps[i].name) (pid \(apps[i].pid)): \(why)"
        guard line != lastFailure else { return }
        lastFailure = line
        log(line)
    }

    // ── Accessibility ───────────────────────────────────────────────────────

    /// What one app's extras menu bar held.
    private enum AppScan {
        case items([Found])
        /// The app said it has no extras menu bar.
        case nothingThere
        /// The app did not answer in a way that can be trusted; the text says where and how.
        case failed(String)
    }

    /// Every app's items in bar order, or nil when any app's could not be read in full.
    private static func combine(_ results: [AppScan]) -> [Found]? {
        var all: [Found] = []
        for result in results {
            switch result {
            case .items(let found): all += found
            case .nothingThere: continue
            case .failed: return nil
            }
        }
        return all.sorted { precedes($0.item, $1.item) }
    }

    private static func scan(apps: [App]) -> [AppScan] {
        let lock = NSLock()
        var results = [AppScan](repeating: .nothingThere, count: apps.count)
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let result = scan(app: apps[i])
            lock.lock(); results[i] = result; lock.unlock()
        }
        return results
    }

    private static func scan(app: App) -> AppScan {
        let root = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(root, perAppTimeout)
        var barValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(root, "AXExtrasMenuBar" as CFString, &barValue)
        let bar: AXUIElement
        switch Self.bar(status: status, value: barValue) {
        case .bar(let found): bar = found
        // Most apps have no extras menu bar, and say so.
        case .nothingThere: return .nothingThere
        case .failed: return .failed("extras menu bar: AXError \(status.rawValue)")
        }
        AXUIElementSetMessagingTimeout(bar, perAppTimeout)
        var kidsValue: CFTypeRef?
        let kidsStatus = AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &kidsValue)
        guard let kids = elements(status: kidsStatus, value: kidsValue) else { return .failed("children: AXError \(kidsStatus.rawValue)") }
        // An empty bar is not "no bar": the app has one and may fill it, so it is not remembered as having none.
        guard !kids.isEmpty else { return .items([]) }

        var children: [Child] = []
        var targets: [AXUIElement] = []
        for kid in kids {
            AXUIElementSetMessagingTimeout(kid, perAppTimeout)
            // Any attribute that timed out (rather than being absent) loses the item: its name, and so its key, is not known.
            var lost = false
            // The system's items are hosting groups; the item proper, with its identifier, is the first child.
            var innerValue: CFTypeRef?
            let innerStatus = AXUIElementCopyAttributeValue(kid, kAXChildrenAttribute as CFString, &innerValue)
            let innerKids = elements(status: innerStatus, value: innerValue)
            if innerKids == nil { lost = true }
            let inner = innerKids?.first
            if let inner { AXUIElementSetMessagingTimeout(inner, perAppTimeout) }
            let outerPress = hasPress(kid, lost: &lost)
            let innerPress = inner.map { hasPress($0, lost: &lost) } ?? false
            let box = frame(of: kid, lost: &lost)
            let hosting = string(kid, kAXSubroleAttribute, lost: &lost) == "AXHostingView"
            let identifier = string(kid, kAXIdentifierAttribute, lost: &lost)
                ?? inner.flatMap { string($0, kAXIdentifierAttribute, lost: &lost) }
            let title = string(kid, kAXTitleAttribute, lost: &lost)
            let description = string(kid, kAXDescriptionAttribute, lost: &lost)
                ?? inner.flatMap { string($0, kAXDescriptionAttribute, lost: &lost) }
            children.append(Child(identifier: identifier, title: title, description: description,
                                  frame: box ?? .zero, hasPress: outerPress || innerPress,
                                  readFailed: lost || box == nil || (hosting && identifier == nil)))
            targets.append(outerPress ? kid : (innerPress ? inner! : kid))
        }
        guard isComplete(children) else { return .failed("an item's position, size, name or actions") }
        // Keys and elements are put in the same order, by the same function.
        let order = Self.order(of: children)
        let items = parse(app: app, children: children)
        return .items(zip(items, order).map { Found(item: $0.0, press: targets[$0.1]) })
    }

    /// The value, or nil when there is none. `lost` is set when the app did not say there is none but failed to answer.
    private static func attribute(_ e: AXUIElement, _ name: String, lost: inout Bool) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(e, name as CFString, &value)
        guard status == .success else {
            if classify(status) == .failed { lost = true }
            return nil
        }
        return value
    }

    private static func string(_ e: AXUIElement, _ name: String, lost: inout Bool) -> String? {
        attribute(e, name, lost: &lost) as? String
    }

    private static func hasPress(_ e: AXUIElement, lost: inout Bool) -> Bool {
        var actions: CFArray?
        let status = AXUIElementCopyActionNames(e, &actions)
        guard status == .success else {
            if classify(status) == .failed { lost = true }
            return false
        }
        return (actions as? [String])?.contains(kAXPressAction as String) ?? false
    }

    /// The frame; nil unless both the position and the size could be read.
    private static func frame(of e: AXUIElement, lost: inout Bool) -> CGRect? {
        frame(position: attribute(e, kAXPositionAttribute, lost: &lost), size: attribute(e, kAXSizeAttribute, lost: &lost))
    }

    // ── Values from another app, type-checked ──────────────────────────────
    // Another app answers with whatever it likes: nothing it returns is force-cast.

    /// The value as an element, or nil when it is anything else.
    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    /// A position and a size, each an `AXValue` of its own kind, as a frame; nil when either is missing or not that.
    static func frame(position: CFTypeRef?, size: CFTypeRef?) -> CGRect? {
        var origin = CGPoint.zero, extent = CGSize.zero
        guard let p = axValue(position, .cgPoint), AXValueGetValue(p, .cgPoint, &origin),
              let s = axValue(size, .cgSize), AXValueGetValue(s, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// The value as an `AXValue` holding `type`, or nil when it is anything else.
    private static func axValue(_ value: CFTypeRef?, _ type: AXValueType) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = unsafeBitCast(value, to: AXValue.self)
        return AXValueGetType(ax) == type ? ax : nil
    }
}

/// The processes that said they have no extras menu bar, so a read does not message (and wake) them again. A process is
/// asked again once it quits (its pid is forgotten), when anything launches, and every `maxAge`: an app that adds a status
/// item later is found within that. Only a definite "no" is kept, never a timeout, and never for Anode itself or the
/// system's own items (a passing "no value" there would drop battery, Wi-Fi, sound or the chevron from every read).
/// Not thread-safe: the reader keeps it on its serial queue.
struct NoBarCache {
    let maxAge: TimeInterval
    let ownPID: pid_t
    let neverSkipped: Set<String>
    private var skipped: Set<pid_t> = []
    /// The processes running at the last `sync`, and when the cache was last emptied.
    private var running: Set<pid_t> = []
    private var since = Date.distantPast

    init(maxAge: TimeInterval = 300, ownPID: pid_t = getpid(), neverSkipped: Set<String>) {
        self.maxAge = maxAge
        self.ownPID = ownPID
        self.neverSkipped = neverSkipped
    }

    func skips(_ pid: pid_t) -> Bool { skipped.contains(pid) }

    /// Before each read, with the processes about to be read.
    mutating func sync(running now: Set<pid_t>, now date: Date) {
        if !now.isSubset(of: running) || date.timeIntervalSince(since) >= maxAge {
            skipped = []
            since = date
        } else {
            skipped.formIntersection(now)
        }
        running = now
    }

    mutating func record(pid: pid_t, bundleID: String?, answer: AXBarReader.Missing) {
        guard answer == .nothingThere, pid != ownPID, !(bundleID.map(neverSkipped.contains) ?? false) else { return }
        skipped.insert(pid)
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

/// Calls `onChange` when something that moves the menu bar happens: an app starts, quits or comes forward, the Space or a
/// screen changes, or the Mac, its screens or the session wake (`displayChanged` is true for the last ones: the layout is
/// still moving and the pill was placed for the old one). There is also a timer, because an item can come and go without any
/// of those: every 3 s while `urgent` (covers are up), else a slow fallback, and none at all while the screens sleep or the
/// session is locked. Nothing runs until `start()` and everything is removed by `stop()`. Bursts are coalesced into one call.
final class BarEvents: BarEventing {

    private let onChange: (_ displayChanged: Bool) -> Void
    /// Called AT ONCE (not debounced) when the display changes, so covers drawn for the old layout come down before anything is
    /// read again.
    private let onInvalidate: () -> Void
    private let fallbackSeconds: TimeInterval
    private let urgentSeconds: TimeInterval
    private let workspaceCenter: NotificationCenter
    private let appCenter: NotificationCenter
    private let sessionCenter: NotificationCenter
    private let makeTimer: (_ interval: TimeInterval, _ fire: @escaping () -> Void) -> BarEventTimer
    private let after: (_ delay: TimeInterval, _ work: DispatchWorkItem) -> Void
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: BarEventTimer?
    private var pending: DispatchWorkItem?
    private var pendingScreenChange = false
    private(set) var isRunning = false
    /// The displays are asleep, or the session is locked: no timer then. Both are forgotten by `stop()`.
    private var asleep = false
    private var locked = false
    /// Setting it to a new value restarts the timer at the new interval (if running and not paused); setting the same value
    /// again leaves the timer alone, so being told on every pass does not put the next read off.
    var urgent = false {
        didSet { if urgent != oldValue { reschedule() } }
    }

    /// The centres, the timer and the debounce are parameters so a test can run all of it by hand; the defaults are the real
    /// ones. `sessionCenter` carries the session's lock and unlock (a distributed notification).
    init(fallbackSeconds: TimeInterval = 30, urgentSeconds: TimeInterval = 3,
         onChange: @escaping (_ displayChanged: Bool) -> Void, onInvalidate: @escaping () -> Void = {},
         workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         appCenter: NotificationCenter = .default,
         sessionCenter: NotificationCenter = DistributedNotificationCenter.default(),
         makeTimer: @escaping (_ interval: TimeInterval, _ fire: @escaping () -> Void) -> BarEventTimer = BarEvents.repeatingTimer,
         after: @escaping (_ delay: TimeInterval, _ work: DispatchWorkItem) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) }) {
        self.onInvalidate = onInvalidate
        self.fallbackSeconds = fallbackSeconds
        self.urgentSeconds = urgentSeconds
        self.onChange = onChange
        self.workspaceCenter = workspaceCenter
        self.appCenter = appCenter
        self.sessionCenter = sessionCenter
        self.makeTimer = makeTimer
        self.after = after
    }

    /// A main-run-loop repeating timer, with a quarter of its interval as tolerance so the system can batch its wake-ups.
    static func repeatingTimer(interval: TimeInterval, fire: @escaping () -> Void) -> BarEventTimer {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in fire() }
        timer.tolerance = interval / 4
        return timer
    }

    deinit { stop() }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let ws = workspaceCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append((ws, ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.fire(screen: false) }))
        }
        tokens.append((ws, ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) {
            [weak self] _ in self?.fire(screen: true)
        }))
        // An app with wide menus coming forward makes macOS drop status items on a notched Mac.
        observe(ws, NSWorkspace.didActivateApplicationNotification) { $0.fire(screen: false) }
        // Waking is a display change: the layout may have moved while nobody was looking.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observe(ws, name) { $0.asleep = false; $0.reschedule(); $0.fire(screen: true) }
        }
        observe(ws, NSWorkspace.screensDidSleepNotification) { $0.asleep = true; $0.reschedule() }
        observe(sessionCenter, Self.sessionLocked) { $0.locked = true; $0.reschedule() }
        observe(sessionCenter, Self.sessionUnlocked) { $0.locked = false; $0.reschedule(); $0.fire(screen: true) }
        let nc = appCenter
        tokens.append((nc, nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) {
            [weak self] _ in self?.fire(screen: true)
        }))
        reschedule()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
        asleep = false
        locked = false
        reschedule()
        pending?.cancel(); pending = nil
    }

    static let sessionLocked = Notification.Name("com.apple.screenIsLocked")
    static let sessionUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handle: @escaping (BarEvents) -> Void) {
        tokens.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            if let self { handle(self) }
        }))
    }

    /// The timer exists only while running with the screens awake and the session unlocked: nobody sees a cover otherwise, and
    /// every read wakes every running app. Its interval is short while covers are up.
    private func reschedule() {
        timer?.invalidate(); timer = nil
        guard isRunning, !asleep, !locked else { return }
        timer = makeTimer(urgent ? urgentSeconds : fallbackSeconds) { [weak self] in self?.fire(screen: false) }
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
        after(0.3, work)
    }
}

/// A repeating timer `BarEvents` can stop.
protocol BarEventTimer: AnyObject {
    func invalidate()
}

extension Timer: BarEventTimer {}

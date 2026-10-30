import AppKit
import ApplicationServices
import Carbon.HIToolbox
import PowerKit

// ── Window groups (Beta Features) ───────────────────────────────────────────
//
// A group is a set of windows, from any apps, that you put together on purpose. Bring any one of
// them forward, by any route (a click, Command-Tab, the Dock icon or its preview, Mission Control),
// and the others come forward right behind it. A group also remembers where each member sat, so one
// shortcut puts the whole layout back after the windows have been moved.
//
// This replaces GUESSING. The Dock click used to find a "layout" by looking for windows that happen
// to tile a screen (`TileGroups`); that stays as one way to START a group from what is on screen, but
// the group itself is now a fact you assigned, so it survives windows being moved, overlapped, or
// resized, and it can hold windows that are nowhere near each other.
//
// How members are raised: `AXRaise` on a window of an app that is not frontmost puts it just under
// the frontmost app's front window (measured), which is exactly where a group member belongs, and
// it does not take focus. Minimized windows and windows on other Spaces are left alone.
//
// A group lives for the session. Window numbers do not survive a window being closed or an app
// relaunching, so there is nothing stable to save; a member that goes away is dropped, and a group
// left with fewer than two windows dissolves.

struct GroupMember: Equatable {
    let id: CGWindowID
    let pid: pid_t
    var appName: String
    var title: String
    /// Where it was when the group was made or the layout last remembered, window-server coordinates.
    var frame: CGRect
}

struct WindowGroup: Equatable {
    let id: Int
    var name: String
    var members: [GroupMember]
}

/// The groups and the rules for changing them. Pure, for tests.
struct WindowGroupStore: Equatable {
    private(set) var groups: [WindowGroup] = []
    private var nextNumber = 1

    func group(containing window: CGWindowID) -> WindowGroup? {
        groups.first { $0.members.contains { $0.id == window } }
    }

    func group(withID id: Int) -> WindowGroup? { groups.first { $0.id == id } }

    /// Start a group of `members` (two or more distinct windows). A window is in at most one group, so
    /// these leave any group they were in, and a group that leaves behind fewer than two dissolves.
    @discardableResult
    mutating func create(from members: [GroupMember]) -> WindowGroup? {
        var seen = Set<CGWindowID>()
        let unique = members.filter { seen.insert($0.id).inserted }
        guard unique.count >= 2 else { return nil }
        for m in unique { removeFromGroups(m.id) }
        let group = WindowGroup(id: nextNumber, name: "Group \(nextNumber)", members: unique)
        nextNumber += 1
        groups.append(group)
        return group
    }

    /// Put `member` in group `id`, leaving whichever group it was in. False when there is no such group.
    @discardableResult
    mutating func add(_ member: GroupMember, to id: Int) -> Bool {
        guard group(withID: id) != nil else { return false }
        removeFromGroups(member.id, except: id)
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return false }
        if let j = groups[i].members.firstIndex(where: { $0.id == member.id }) {
            groups[i].members[j] = member
        } else {
            groups[i].members.append(member)
        }
        return true
    }

    /// Take a window out of its group; the group dissolves if fewer than two remain.
    mutating func remove(_ window: CGWindowID) { removeFromGroups(window) }

    mutating func dissolve(_ id: Int) { groups.removeAll { $0.id == id } }

    mutating func dissolveAll() { groups = [] }

    /// Forget windows that no longer exist anywhere. `alive` is every window number the system still has.
    mutating func prune(alive: Set<CGWindowID>) {
        for i in groups.indices { groups[i].members.removeAll { !alive.contains($0.id) } }
        groups.removeAll { $0.members.count < 2 }
    }

    /// Update the remembered position of members, from where they are now.
    mutating func remember(frames: [CGWindowID: CGRect], in id: Int) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        for j in groups[i].members.indices {
            if let f = frames[groups[i].members[j].id] { groups[i].members[j].frame = f }
        }
    }

    private mutating func removeFromGroups(_ window: CGWindowID, except keep: Int? = nil) {
        for i in groups.indices where groups[i].id != keep {
            groups[i].members.removeAll { $0.id == window }
        }
        groups.removeAll { $0.id != keep && $0.members.count < 2 }
    }

    /// The members to raise when `front` comes forward, in the order to raise them: the others that
    /// are on screen, last first, so each lands over the ones before it and the group keeps its order.
    static func raiseOrder(front: CGWindowID, group: WindowGroup, onScreen: Set<CGWindowID>) -> [GroupMember] {
        group.members.filter { $0.id != front && onScreen.contains($0.id) }.reversed()
    }
}

/// What the keyboard can do to groups.
enum GroupAction: CaseIterable {
    case toggleGroup, addToGroup, removeFromGroup, restoreLayout

    var title: String {
        switch self {
        case .toggleGroup: return "Group the tiled windows (again: ungroup)"
        case .addToGroup: return "Add this window to the current group"
        case .removeFromGroup: return "Take this window out of its group"
        case .restoreLayout: return "Put the group's windows back where they were"
        }
    }

    var shortcut: (key: Int, modifiers: Int, label: String) {
        let m = controlKey | optionKey | cmdKey
        switch self {
        case .toggleGroup: return (kVK_ANSI_G, m, "⌃⌥⌘G")
        case .addToGroup: return (kVK_ANSI_A, m, "⌃⌥⌘A")
        case .removeFromGroup: return (kVK_ANSI_X, m, "⌃⌥⌘X")
        case .restoreLayout: return (kVK_ANSI_L, m, "⌃⌥⌘L")
        }
    }
}

/// A window as the controller keeps track of it.
struct TrackedWindow: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let frame: CGRect

    var member: GroupMember { GroupMember(id: id, pid: pid, appName: appName, title: title, frame: frame) }
}

extension AccessibleWindow {

    /// The window with this number in the app `pid`, if accessibility can see it.
    static func find(id: CGWindowID, pid: pid_t) -> AccessibleWindow? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.map { AccessibleWindow(element: $0, pid: pid) }.first { $0.windowID == id }
    }

    var title: String {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &v)
        return v as? String ?? ""
    }
}

/// Watches which window is in front and raises its group; carries out the group commands.
final class WindowGroupController {

    private let settings: Settings
    private var settingToken: AnyObject?
    private var activationToken: NSObjectProtocol?
    private var clickMonitor: Any?
    private lazy var keys = HotKeyRegistrar(signature: 0x414E5347 /* "ANSG" */) { [weak self] index in
        guard let self, GroupAction.allCases.indices.contains(index) else { return }
        self.perform(GroupAction.allCases[index])
    }

    private(set) var store = WindowGroupStore()
    private var lastFront: CGWindowID?
    /// The last window in front that was not Anode's own: what the Beta Features buttons act on, since
    /// pressing one makes Anode's window the front one.
    private(set) var lastOutsideFront: TrackedWindow?
    /// The group most recently made or brought forward: where "add to the current group" adds.
    private(set) var currentGroupID: Int?
    private(set) var unavailable: [GroupAction] = []
    /// Called when the groups change, so the Beta Features section can show them.
    var onChange: (() -> Void)?

    /// How long after a click or an app switch the front window is read: long enough for it to have
    /// settled, short enough that the group follows without a visible lag.
    static let settleDelay: TimeInterval = 0.12

    init(settings: Settings = .shared) {
        self.settings = settings
        settingToken = settings.observe(Settings.Key.windowGroupsEnabled) { [weak self] in self?.apply() }
        apply()
    }

    deinit { stop() }

    var isRunning: Bool { keys.isRegistered }

    func apply() {
        if settings.windowGroupsEnabled { start() } else { stop() }
    }

    private func start() {
        guard !keys.isRegistered else { return }
        let failed = keys.register(GroupAction.allCases.map { .init(key: $0.shortcut.key, modifiers: $0.shortcut.modifiers) })
        unavailable = failed.map { GroupAction.allCases[$0] }
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.checkFrontSoon() }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.checkFrontSoon() }
        checkFrontSoon()
    }

    private func stop() {
        keys.unregister()
        unavailable = []
        if let activationToken { NSWorkspace.shared.notificationCenter.removeObserver(activationToken) }
        activationToken = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        store.dissolveAll()
        lastFront = nil
        currentGroupID = nil
        onChange?()
    }

    // ── Following the front window ──────────────────────────────────────────

    func checkFrontSoon() {
        guard settings.windowGroupsEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in self?.checkFront() }
    }

    /// Read the front window; when it is new and in a group, bring the rest of the group up behind it.
    func checkFront() {
        guard settings.windowGroupsEnabled, AccessibilityAccess.isTrusted, let window = AccessibleWindow.front(),
              let id = window.windowID else { return }
        if window.pid != ProcessInfo.processInfo.processIdentifier, let frame = window.frame {
            let name = NSRunningApplication(processIdentifier: window.pid)?.localizedName ?? ""
            lastOutsideFront = TrackedWindow(id: id, pid: window.pid, appName: name, title: window.title, frame: frame)
        }
        guard id != lastFront else { return }
        lastFront = id
        store.prune(alive: Self.allWindowNumbers())
        guard let group = store.group(containing: id) else { return }
        currentGroupID = group.id
        let onScreen = Set(WindowCatalog.current().map(\.id))
        for m in WindowGroupStore.raiseOrder(front: id, group: group, onScreen: onScreen) {
            if let w = AccessibleWindow.find(id: m.id, pid: m.pid) {
                AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
            }
        }
    }

    /// Every window number the system still has, on any Space, minimized or not.
    static func allWindowNumbers() -> Set<CGWindowID> {
        let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(all.compactMap { ($0[kCGWindowNumber as String] as? Int).map { CGWindowID($0) } })
    }

    // ── Commands ────────────────────────────────────────────────────────────

    /// The window a command acts on: the front window if it is somebody else's, otherwise the last one that was.
    private func target() -> TrackedWindow? {
        if let w = AccessibleWindow.front(), w.pid != ProcessInfo.processInfo.processIdentifier,
           let id = w.windowID, let frame = w.frame {
            let name = NSRunningApplication(processIdentifier: w.pid)?.localizedName ?? ""
            return TrackedWindow(id: id, pid: w.pid, appName: name, title: w.title, frame: frame)
        }
        return lastOutsideFront
    }

    func perform(_ action: GroupAction) {
        switch action {
        case .toggleGroup: toggleGroup()
        case .addToGroup: addToCurrentGroup()
        case .removeFromGroup: removeFromGroup()
        case .restoreLayout: restoreLayout()
        }
    }

    /// Start a group from the windows tiled together around the front window; if that window is already
    /// in a group, break the group up instead.
    @discardableResult
    func toggleGroup() -> Bool {
        guard let window = target() else { NSSound.beep(); return false }
        if let existing = store.group(containing: window.id) {
            store.dissolve(existing.id)
            if currentGroupID == existing.id { currentGroupID = nil }
            onChange?()
            return true
        }
        let shown = WindowCatalog.current()
        guard let tiled = TileGroups.group(containing: window.id, windows: shown, screens: TileGroups.usableAreas()) else {
            NSSound.beep()
            return false
        }
        let members = tiled.map { w in
            GroupMember(id: w.id, pid: w.pid, appName: w.appName, title: w.title, frame: w.bounds)
        }
        guard let group = store.create(from: members) else { return false }
        currentGroupID = group.id
        lastFront = window.id          // already in front: do not raise the others over their own layout
        onChange?()
        return true
    }

    @discardableResult
    func addToCurrentGroup() -> Bool {
        guard let window = target(), let id = currentGroupID, store.add(window.member, to: id) else {
            NSSound.beep()
            return false
        }
        onChange?()
        return true
    }

    @discardableResult
    func removeFromGroup() -> Bool {
        guard let window = target(), store.group(containing: window.id) != nil else { NSSound.beep(); return false }
        store.remove(window.id)
        onChange?()
        return true
    }

    /// Put every member of the front window's group (or the current group) back where it was remembered.
    @discardableResult
    func restoreLayout() -> Bool {
        guard let group = (target().flatMap { store.group(containing: $0.id) }) ?? currentGroupID.flatMap({ store.group(withID: $0) })
        else { NSSound.beep(); return false }
        let place = { [group] in
            for m in group.members {
                if let w = AccessibleWindow.find(id: m.id, pid: m.pid) { w.setFrame(m.frame) }
            }
        }
        if let previews = (NSApp.delegate as? AppDelegate)?.dockPreviews {
            previews.runWithDockReleased(place)
        } else {
            place()
        }
        return true
    }

    /// Remember the group's windows where they are now.
    func rememberLayout() {
        guard let id = (target().flatMap { store.group(containing: $0.id)?.id }) ?? currentGroupID else { NSSound.beep(); return }
        var frames: [CGWindowID: CGRect] = [:]
        for m in store.group(withID: id)?.members ?? [] {
            if let f = AccessibleWindow.find(id: m.id, pid: m.pid)?.frame { frames[m.id] = f }
        }
        store.remember(frames: frames, in: id)
        onChange?()
    }

    func dissolveAll() {
        store.dissolveAll()
        currentGroupID = nil
        onChange?()
    }

    /// The groups as lines of text, for the Beta Features section.
    func summary() -> [String] {
        store.groups.map { g in
            let members = g.members.map { m in m.title.isEmpty ? m.appName : "\(m.appName) (\(m.title.prefix(28)))" }
            return "\(g.name)\(g.id == currentGroupID ? " · current" : ""): " + members.joined(separator: ", ")
        }
    }
}

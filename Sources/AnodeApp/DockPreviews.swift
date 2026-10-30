import AppKit
import ApplicationServices
import PowerKit

// ── Dock window previews (Beta Features) ────────────────────────────────────
//
// Rest the pointer on a running app's Dock icon and a small panel of its windows appears
// above the icon, Windows-taskbar style: click a window to bring it forward, or close it
// from its own button. DockDoor was the reference for behaviour (GPL-3.0; no code taken).
//
// How the hover is known, measured before writing this: the Dock's icon list posts
// `AXSelectedChildrenChanged` as the pointer moves onto an icon, about 5 ms after the move,
// so nothing polls while the pointer is elsewhere. That notification is not enough on its
// own: after the pointer left the Dock it still named the last icon, so every show is
// checked against where the pointer actually is.
//
// Each Dock icon reports its frame, its app's bundle URL and whether it is running, which is
// all that is needed to anchor the panel and list the windows. Needs Accessibility (the same
// grant the window switcher uses); previews need Screen Recording.

/// Which edge of the screen the Dock is on.
enum DockEdge: String {
    case bottom, left, right

    static var current: DockEdge {
        DockEdge(rawValue: UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "") ?? .bottom
    }
}

/// How a row of window previews is laid out: each tile as tall as `previewHeight` and as wide as
/// its window's shape asks (within limits), so a tall window is a narrow tile and a wide one a
/// wide tile, never a fixed square with empty sides. Shared by the Dock popup and the ⌘Tab
/// switcher, which differ only in these numbers.
struct PreviewLayout {
    var previewHeight: CGFloat
    var minPreviewWidth: CGFloat
    var maxPreviewWidth: CGFloat
    /// Around the preview, and the title row under it.
    var tileInset: CGFloat
    var labelHeight: CGFloat
    var spacing: CGFloat
    var padding: CGFloat
    /// How small tiles may get to fit a long list, before it simply wraps further.
    var minScale: CGFloat

    var tileHeight: CGFloat { previewHeight + labelHeight + 2 * tileInset }

    /// Each tile's frame (origin top-left within the panel) and the panel's size, for windows
    /// of the given width/height `aspects`: one row while it fits, then every tile smaller (down
    /// to `minScale`), then more rows, shrinking again if the rows are taller than `limit`.
    /// Pure, for tests.
    func layout(aspects: [CGFloat], limit: CGSize) -> (frames: [CGRect], size: CGSize) {
        guard !aspects.isEmpty else { return ([], .zero) }
        let base = aspects.map { a -> CGFloat in
            let width = previewHeight * (a.isFinite && a > 0 ? a : 1)
            return min(max(width, minPreviewWidth), maxPreviewWidth) + 2 * tileInset
        }
        let room = limit.width - 2 * padding
        let total = base.reduce(0, +)
        let gaps = spacing * CGFloat(base.count - 1)

        func place(_ scale: CGFloat) -> (frames: [CGRect], size: CGSize) {
            let tileH = tileHeight * scale
            var frames: [CGRect] = []
            var x = padding, y = padding, widest: CGFloat = 0
            for w in base.map({ $0 * scale }) {
                if x > padding, x + w > padding + room {      // no room left in this row
                    x = padding
                    y += tileH + spacing
                }
                frames.append(CGRect(x: x, y: y, width: w, height: tileH))
                x += w + spacing
                widest = max(widest, x - spacing)
            }
            return (frames, CGSize(width: widest + padding, height: y + tileH + padding))
        }

        var scale: CGFloat = total + gaps > room ? max(minScale, (room - gaps) / total) : 1
        var placed = place(scale)
        // Whole steps of 5%: subtracting 0.05 repeatedly lands just under the floor.
        var steps = 0
        while placed.size.height > limit.height, scale > minScale, steps < 40 {
            steps += 1
            scale = max(minScale, scale - 0.05)
            placed = place(scale)
        }
        return placed
    }
}

/// The Dock's auto-hide switch, through the private CoreDock calls (looked up by name; absent
/// means nothing is ever changed). Measured on macOS 27: switching it takes ~4 ms, needs no
/// Dock restart and no permission, the Dock slides up and stays, and no window moved or
/// resized either way. It IS the user's stored preference (`com.apple.dock autohide` read 0
/// while off), which is why `DockHold` records every change it makes.
enum DockAutoHide {
    private typealias Set = @convention(c) (Bool) -> Void
    private typealias Get = @convention(c) () -> Bool
    private static let framework = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW)
    private static let setter: Set? = dlsym(framework, "CoreDockSetAutoHideEnabled").map { unsafeBitCast($0, to: Set.self) }
    private static let getter: Get? = dlsym(framework, "CoreDockGetAutoHideEnabled").map { unsafeBitCast($0, to: Get.self) }

    /// nil when the calls are not there.
    static var isEnabled: Bool? { getter?() }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        guard let setter else { return false }
        setter(on)
        return true
    }
}

/// Keeps an auto-hiding Dock up while a preview is open, so the preview is not left floating
/// over the space the Dock slid out of. Turns auto-hide off on open and back on on close —
/// only ever undoing its own change, and only for someone who uses auto-hide at all.
///
/// Because the switch is the user's stored preference, a crash while holding would leave
/// their Dock pinned up. So the hold is written down BEFORE auto-hide is turned off, cleared
/// after it is turned back on, and a hold still written down at launch is undone then.
final class DockHold {
    static let recordKey = "anode.dockHeldUp"

    private let defaults: UserDefaults
    private let isEnabled: () -> Bool?
    private let setEnabled: (Bool) -> Bool
    private let isDockClear: () -> Bool
    private var releaseTimer: Timer?
    private var settleTimer: Timer?
    private(set) var isHolding = false

    /// How long `releaseThen` waits for the Dock to be gone before going ahead anyway, so a
    /// stuck state can never turn a click into nothing.
    static let settleTimeout: TimeInterval = 3
    static let settlePoll: TimeInterval = 0.02

    init(defaults: UserDefaults = .standard,
         isEnabled: @escaping () -> Bool? = { DockAutoHide.isEnabled },
         setEnabled: @escaping (Bool) -> Bool = { DockAutoHide.set($0) },
         isDockClear: @escaping () -> Bool = { DockHold.dockIsGone() }) {
        self.defaults = defaults
        self.isEnabled = isEnabled
        self.setEnabled = setEnabled
        self.isDockClear = isDockClear
    }

    /// Has the Dock stopped taking room from every screen? This, not the auto-hide flag, is what a
    /// window manager reads when it sizes a window: `visibleFrame` shrinks by the Dock's height
    /// while the Dock is up (measured: 1130 -> 1023 pt) and returns when it has slid away, a moment
    /// after auto-hide is switched back on. A few points are allowed for the strip that stays to
    /// summon the Dock.
    static func screensHaveNoDockInset(tolerance: CGFloat = 6) -> Bool {
        NSScreen.screens.allSatisfy { s in
            let f = s.frame, v = s.visibleFrame
            return v.minX - f.minX <= tolerance && f.maxX - v.maxX <= tolerance && v.minY - f.minY <= tolerance
        }
    }

    /// Is the Dock gone, by both of the two things that can say so: the screens' usable area has
    /// its room back, and the Dock's own icon strip has left the screens. The second is there
    /// because the first is only as current as the app asking (a plain command-line probe never
    /// saw it change even with the Dock pinned up), while the strip's position is read from the
    /// Dock itself. When the strip cannot be read, only the first is used.
    static func dockIsGone() -> Bool {
        screensHaveNoDockInset() && !dockStripOnScreen()
    }

    /// Is the Dock's icon strip (its list, from accessibility) showing on any screen? In the
    /// window server's coordinates, where a hidden Dock's list sits below, or beside, the screen.
    static func dockStripOnScreen(tolerance: CGFloat = 6) -> Bool {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return false }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success,
              let list = (children as? [AXUIElement])?.first(where: {
                  var role: CFTypeRef?
                  AXUIElementCopyAttributeValue($0, kAXRoleAttribute as CFString, &role)
                  return (role as? String) == kAXListRole
              }) else { return false }
        var position: CFTypeRef?, size: CFTypeRef?
        AXUIElementCopyAttributeValue(list, kAXPositionAttribute as CFString, &position)
        AXUIElementCopyAttributeValue(list, kAXSizeAttribute as CFString, &size)
        var origin = CGPoint.zero, extent = CGSize.zero
        guard let position, let size,
              AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return false }
        let strip = CGRect(origin: origin, size: extent)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.contains { s in
            let frame = ScreenState.cgFrame(of: s, primaryHeight: primaryHeight)
            let overlap = frame.intersection(strip)
            return !overlap.isNull && overlap.width > tolerance && overlap.height > tolerance
        }
    }

    /// Do `action` once the Dock is really gone. With no hold in force there is nothing to wait
    /// for and it runs at once. Otherwise auto-hide is switched back on FIRST, and `action` waits
    /// until the screens' usable area is back to full size (or `settleTimeout`): a window manager
    /// that sizes windows from the usable area at the moment of the switch — Rectangle, as it was
    /// reported — then sees the same area it would with the Dock hidden all along.
    func releaseThen(_ action: @escaping () -> Void) {
        settleTimer?.invalidate()
        settleTimer = nil
        guard isHolding else { return action() }
        releaseNow()
        let deadline = Date().addingTimeInterval(Self.settleTimeout)
        func poll() {
            if isDockClear() || Date() >= deadline {
                settleTimer = nil
                action()
            } else {
                settleTimer = Timer.scheduledTimer(withTimeInterval: Self.settlePoll, repeats: false) { _ in poll() }
            }
        }
        poll()
    }

    /// Undo a hold a crash (or a force-quit) left behind. Call once at launch.
    func recover() {
        guard defaults.bool(forKey: Self.recordKey) else { return }
        _ = setEnabled(true)
        defaults.removeObject(forKey: Self.recordKey)
    }

    func hold() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        guard !isHolding, isEnabled() == true else { return }
        defaults.set(true, forKey: Self.recordKey)
        defaults.synchronize()
        guard setEnabled(false) else {
            defaults.removeObject(forKey: Self.recordKey)
            return
        }
        isHolding = true
    }

    /// Let go — after a moment, so moving from one app's icon to the next (the panel closes,
    /// then the next opens) does not flip the preference twice.
    func release(after delay: TimeInterval = 0.4) {
        guard isHolding else { return }
        releaseTimer?.invalidate()
        if delay <= 0 { return releaseNow() }
        releaseTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.releaseNow()
        }
    }

    func releaseNow() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        guard isHolding else { return }
        _ = setEnabled(true)
        isHolding = false
        defaults.removeObject(forKey: Self.recordKey)
    }
}

final class DockPreviews {

    /// How long the pointer rests on an icon before its panel opens — every icon, every time:
    /// moving to another app closes the open panel and waits again (asked for; it used to
    /// switch at once).
    static let hoverDelay: TimeInterval = 0.25
    /// How long the pointer may be off the icon, the panel and the gap between them before
    /// the panel closes. The gap counts as inside on its own (`keepsPanelOpen`), so this only
    /// absorbs jitter; at 0.25 s the panel lingered ~335 ms after the pointer left (measured),
    /// which read as not going away.
    static let leaveGrace: TimeInterval = 0.08
    /// How often the pointer is checked while a panel is open (and only then).
    static let trackInterval: TimeInterval = 0.03
    /// The pointer counts as on an icon this far outside its frame.
    static let slack: CGFloat = 4

    private struct Hover: Equatable {
        let pid: pid_t
        /// The icon, in the window server's coordinates (origin top-left).
        let icon: CGRect
    }

    private let settings: Settings
    private var settingToken: AnyObject?
    private var holdToken: AnyObject?
    private var launchToken: NSObjectProtocol?
    private var retryTimer: Timer?
    private var observer: AXObserver?
    private var dockList: AXUIElement?

    private var pending: Hover?
    private var shown: Hover?
    private var showTimer: Timer?
    private var trackTimer: Timer?
    private var outsideSince: Date?
    /// The panel's outline before a close made it smaller. The panel re-centres on the icon
    /// with fewer tiles, which left the pointer — still where the ✕ was — outside it, and the
    /// panel closed itself. The old outline counts as inside until the pointer leaves it.
    private var formerOutline: CGRect?
    /// Where the pointer was last seen on the shown app's icon, and when: the apex of the
    /// "menu aim" triangle (`isAiming`).
    private var lastOnIcon: (point: CGPoint, at: Date)?
    /// How long after leaving the icon a pointer inside the aim triangle still counts as on
    /// its way to the panel.
    static let aimWindow: TimeInterval = 0.5
    private var clickMonitor: Any?
    /// Every left click while attached, to see Dock icon clicks (`iconClicked`). A global
    /// monitor only observes; the click goes on to the Dock untouched.
    private var iconClickMonitor: Any?
    private let panel = DockPreviewPanel()
    private let dockHold = DockHold()
    private var terminateToken: NSObjectProtocol?

    var isRunning: Bool { observer != nil }

    init(settings: Settings = .shared) {
        self.settings = settings
        dockHold.recover()
        terminateToken = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.dockHold.releaseNow() }
        panel.onOpen = { [weak self] window in
            guard let self else { return }
            self.hide()
            // Order of operations: auto-hide back on, the Dock gone, THEN the window — so what
            // sizes the window on the switch sees an auto-hidden Dock, as without this feature.
            self.dockHold.releaseThen { WindowActivator.bringForward(window) }
        }
        panel.onClose = { [weak self] window in
            WindowActivator.close(window)
            // The app may ask about unsaved changes first; look again once it has had a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.reshow() }
        }
        settingToken = settings.observe(Settings.Key.dockPreviewsEnabled) { [weak self] in self?.apply() }
        holdToken = settings.observe(Settings.Key.dockPreviewsHoldDock) { [weak self] in
            guard let self, !self.settings.dockPreviewsHoldDock else { return }
            self.dockHold.releaseNow()
        }
        // The Dock is a process like any other and is restarted (by `killall Dock`, or a crash);
        // the observer dies with the old one.
        launchToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.dock" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self?.detach()
                self?.apply()
            }
        }
        apply()
    }

    deinit {
        detach()
        dockHold.releaseNow()
        if let t = launchToken { NSWorkspace.shared.notificationCenter.removeObserver(t) }
        if let t = terminateToken { NotificationCenter.default.removeObserver(t) }
    }

    /// Attach or detach to match the setting; retry every two seconds while it is on but
    /// cannot attach yet (Accessibility not granted), so a grant works without a relaunch.
    func apply() {
        guard settings.dockPreviewsEnabled else {
            detach()
            return
        }
        if observer == nil { attach() }
        if observer == nil {
            guard retryTimer == nil else { return }
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.apply() }
        } else {
            retryTimer?.invalidate()
            retryTimer = nil
        }
    }

    private func attach() {
        guard AccessibilityAccess.isTrusted,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success,
              let list = (children as? [AXUIElement])?.first(where: { Self.role(of: $0) == kAXListRole })
        else { return }
        var made: AXObserver?
        guard AXObserverCreate(dock.processIdentifier, dockObserverCallback, &made) == .success, let made,
              AXObserverAddNotification(made, list, kAXSelectedChildrenChangedNotification as CFString,
                                        Unmanaged.passUnretained(self).toOpaque()) == .success
        else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(made), .defaultMode)
        observer = made
        dockList = list
        iconClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            self?.iconClicked()
        }
    }

    private func detach() {
        retryTimer?.invalidate()
        retryTimer = nil
        hide()
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        dockList = nil
        if let iconClickMonitor { NSEvent.removeMonitor(iconClickMonitor) }
        iconClickMonitor = nil
    }

    // ── Clicking an icon: bring back the tiled layout ───────────────────────

    /// How long after the click the layout is raised: the Dock has to have brought the app
    /// forward first, so its window is on top and the others land just under it.
    static let groupRaiseDelay: TimeInterval = 0.3

    private func iconClicked() {
        guard settings.dockRaisesTileGroup, let hover = currentHover(requirePointer: true) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.groupRaiseDelay) {
            Self.raiseTileGroup(of: hover.pid)
        }
    }

    /// The clicked app's front window, and every window tiled with it, raised (others under it,
    /// keeping their order). The app itself the Dock has already brought forward.
    static func raiseTileGroup(of pid: pid_t) {
        let windows = WindowCatalog.current()
        guard let front = windows.first(where: { $0.pid == pid }),
              let group = TileGroups.group(containing: front.id, windows: windows,
                                           screens: TileGroups.usableAreas()) else { return }
        // Back to front, so each raise lands over the ones before it and the order holds.
        for member in group.dropFirst().reversed() where member.pid != pid {
            WindowActivator.raiseWithoutActivating(member)
        }
    }

    // ── Hover ───────────────────────────────────────────────────────────────

    fileprivate func selectionChanged() {
        // Which app, NOT whether the pointer is on its icon yet. With an auto-hiding Dock this
        // arrives at the first touch of the screen edge, while the Dock still reports its icons
        // below the screen (measured: icon top 1174, pointer 1167), and no second notification
        // follows because the selected icon does not change. The pointer is checked when the
        // delay is up instead (`confirm`).
        guard let hover = currentHover(requirePointer: false) else {
            // Off the apps (a gap, a folder, the Trash, or off the Dock): nothing to open. An open
            // panel is left to the tracking, which gives the pointer time to reach it.
            pending = nil
            showTimer?.invalidate()
            return
        }
        guard hover.pid != shown?.pid else { return }
        // Already waiting on this icon: a repeat must not restart the wait.
        if hover.pid == pending?.pid, showTimer?.isValid == true { return }
        // Crossing a neighbouring icon on the way up to the open panel (a diagonal) is not a
        // switch: keep the panel, and switch only if the pointer is still on the new icon when
        // the delay is up. Anything else closes the panel at once.
        if shown != nil, !aimingAtPanel() { hide() }
        pending = hover
        confirm(after: Self.hoverDelay, triesLeft: Self.confirmTries)
    }

    /// How many more times, 0.1 s apart, to wait for a sliding Dock to settle under the pointer.
    static let confirmTries = 6

    private func confirm(after delay: TimeInterval, triesLeft: Int) {
        showTimer?.invalidate()
        showTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, let pending = self.pending else { return }
            if let fresh = self.currentHover(requirePointer: true), fresh.pid == pending.pid {
                if self.shown != nil { self.hide() }
                self.show(fresh)
            } else if triesLeft > 0, self.currentHover(requirePointer: false)?.pid == pending.pid {
                self.confirm(after: 0.1, triesLeft: triesLeft - 1)
            }
        }
    }

    /// The running app the Dock has selected, and its icon's frame read now. With
    /// `requirePointer`, only if the pointer is actually on that icon: after the pointer leaves
    /// the Dock, the Dock still names the last icon it was on.
    private func currentHover(requirePointer: Bool = true) -> Hover? {
        guard let dockList else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dockList, kAXSelectedChildrenAttribute as CFString, &selected) == .success,
              let item = (selected as? [AXUIElement])?.first,
              Self.subrole(of: item) == "AXApplicationDockItem" else { return nil }
        var url: CFTypeRef?
        AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &url)
        guard let bundle = (url as? URL)?.standardizedFileURL,
              let app = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleURL?.standardizedFileURL == bundle
              }) else { return nil }
        let icon = Self.frame(of: item)
        guard !requirePointer || pointerIsOn(icon) else { return nil }
        return Hover(pid: app.processIdentifier, icon: icon)
    }

    private func pointerIsOn(_ icon: CGRect) -> Bool {
        icon.insetBy(dx: -Self.slack, dy: -Self.slack).contains(Self.pointerInWindowServerCoordinates())
    }

    // ── The panel ───────────────────────────────────────────────────────────

    private func show(_ hover: Hover) {
        guard let app = NSRunningApplication(processIdentifier: hover.pid) else { return hide() }
        let windows = WindowCatalog.windows(of: app)
        guard !windows.isEmpty else { return hide() }
        shown = hover
        if settings.dockPreviewsHoldDock { dockHold.hold() }
        panel.present(windows, iconInWindowServer: hover.icon, edge: DockEdge.current)
        // Fresh pictures of what is on screen; minimized windows keep their last one.
        WindowPreviews.shared.refresh(windows.filter { !$0.isOffScreen }.map(\.id)) { [weak self] id, image in
            self?.panel.setThumbnail(image, for: id)
        }
        startTracking()
    }

    /// After a close: list the app's windows again, or go when there are none left.
    private func reshow() {
        guard let shown, let app = NSRunningApplication(processIdentifier: shown.pid) else { return }
        let windows = WindowCatalog.windows(of: app)
        if windows.isEmpty { hide() } else {
            formerOutline = panel.frameInWindowServer
            panel.present(windows, iconInWindowServer: shown.icon, edge: DockEdge.current)
        }
    }

    private func hide() {
        showTimer?.invalidate()
        showTimer = nil
        trackTimer?.invalidate()
        trackTimer = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        outsideSince = nil
        formerOutline = nil
        lastOnIcon = nil
        pending = nil
        shown = nil
        panel.dismiss()
        dockHold.release()
    }

    /// While the panel is up — and only then — follow the pointer, and close on a click
    /// anywhere that is not the panel (an icon click opens the app; a right-click opens the
    /// Dock's menu, which the panel must not cover).
    private func startTracking() {
        outsideSince = nil
        if trackTimer == nil {
            trackTimer = Timer.scheduledTimer(withTimeInterval: Self.trackInterval, repeats: true) { [weak self] _ in
                self?.track()
            }
        }
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in self?.hide() }
        }
    }

    private func track() {
        guard let shown else { return hide() }
        let pointer = Self.pointerInWindowServerCoordinates()
        if shown.icon.insetBy(dx: -Self.slack, dy: -Self.slack).contains(pointer) { lastOnIcon = (pointer, Date()) }
        var inside = Self.keepsPanelOpen(pointer: pointer, icon: shown.icon,
                                         panel: panel.frameInWindowServer, slack: Self.slack)
            || aimingAtPanel()
        if let former = formerOutline {
            if former.contains(pointer) { inside = true } else { formerOutline = nil }
        }
        // The icon may have moved since (the Dock finishing its slide, or magnifying): ask the
        // Dock before counting the pointer as gone. Only on this path, so it costs nothing
        // while the pointer is over the panel.
        if !inside, let fresh = currentHover(), fresh.pid == shown.pid {
            self.shown = fresh
            inside = true
        }
        if inside {
            outsideSince = nil
        } else if let since = outsideSince {
            if Date().timeIntervalSince(since) >= Self.leaveGrace { hide() }
        } else {
            outsideSince = Date()
        }
    }

    /// Is the pointer somewhere that keeps the panel open: the icon, the panel, or the gap
    /// between them (the band spanning both)? Window-server coordinates. Pure, for tests.
    static func keepsPanelOpen(pointer: CGPoint, icon: CGRect, panel: CGRect?, slack: CGFloat) -> Bool {
        let iconZone = icon.insetBy(dx: -slack, dy: -slack)
        if iconZone.contains(pointer) { return true }
        guard let panel, !panel.isEmpty else { return false }
        if panel.insetBy(dx: -slack, dy: -slack).contains(pointer) { return true }
        // The corridor between them: where the two overlap side to side, the whole span from
        // one to the other (a panel above a bottom Dock), or the same turned for a side Dock.
        let across = CGRect(x: max(iconZone.minX, panel.minX), y: min(iconZone.minY, panel.minY),
                            width: min(iconZone.maxX, panel.maxX) - max(iconZone.minX, panel.minX),
                            height: max(iconZone.maxY, panel.maxY) - min(iconZone.minY, panel.minY))
        let along = CGRect(x: min(iconZone.minX, panel.minX), y: max(iconZone.minY, panel.minY),
                           width: max(iconZone.maxX, panel.maxX) - min(iconZone.minX, panel.minX),
                           height: min(iconZone.maxY, panel.maxY) - max(iconZone.minY, panel.minY))
        return (across.width > 0 && across.contains(pointer)) || (along.height > 0 && along.contains(pointer))
    }

    private func aimingAtPanel() -> Bool {
        guard let last = lastOnIcon, Date().timeIntervalSince(last.at) < Self.aimWindow,
              let frame = panel.frameInWindowServer else { return false }
        return Self.isAiming(pointer: Self.pointerInWindowServerCoordinates(), from: last.point,
                             panel: frame, edge: DockEdge.current)
    }

    /// Is the pointer inside the triangle from where it left the icon (`from`) to the panel's
    /// near edge — on its way to the panel, whatever it crosses? Window-server coordinates
    /// (y down). Pure, for tests.
    static func isAiming(pointer: CGPoint, from apex: CGPoint, panel: CGRect, edge: DockEdge) -> Bool {
        let (a, b): (CGPoint, CGPoint)
        switch edge {
        case .bottom: (a, b) = (CGPoint(x: panel.minX, y: panel.maxY), CGPoint(x: panel.maxX, y: panel.maxY))
        case .left: (a, b) = (CGPoint(x: panel.minX, y: panel.minY), CGPoint(x: panel.minX, y: panel.maxY))
        case .right: (a, b) = (CGPoint(x: panel.maxX, y: panel.minY), CGPoint(x: panel.maxX, y: panel.maxY))
        }
        func side(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat {
            (p.x - r.x) * (q.y - r.y) - (q.x - r.x) * (p.y - r.y)
        }
        let d1 = side(pointer, apex, a), d2 = side(pointer, a, b), d3 = side(pointer, b, apex)
        let negative = d1 < 0 || d2 < 0 || d3 < 0, positive = d1 > 0 || d2 > 0 || d3 > 0
        return !(negative && positive)
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    static func pointerInWindowServerCoordinates() -> CGPoint {
        let p = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    private static func role(of e: AXUIElement) -> String? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &v)
        return v as? String
    }

    private static func subrole(of e: AXUIElement) -> String? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(e, kAXSubroleAttribute as CFString, &v)
        return v as? String
    }

    private static func frame(of e: AXUIElement) -> CGRect {
        var position: CFTypeRef?, size: CFTypeRef?
        AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &position)
        AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &size)
        var origin = CGPoint.zero, extent = CGSize.zero
        if let position { AXValueGetValue(position as! AXValue, .cgPoint, &origin) }
        if let size { AXValueGetValue(size as! AXValue, .cgSize, &extent) }
        return CGRect(origin: origin, size: extent)
    }
}

private func dockObserverCallback(observer: AXObserver, element: AXUIElement, notification: CFString,
                                  refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<DockPreviews>.fromOpaque(refcon).takeUnretainedValue().selectionChanged()
}

// ── The panel ───────────────────────────────────────────────────────────────

final class DockPreviewPanel {

    /// Every preview is this tall; its width follows its window's shape, so a portrait window
    /// is a narrow tile rather than a wide box with empty sides.
    static let previewHeight: CGFloat = 120
    static let minPreviewWidth: CGFloat = 48
    static let maxPreviewWidth: CGFloat = 300
    /// Around the preview, and the title row under it (as `DockPreviewTile` lays them out).
    static let tileInset: CGFloat = 3
    static let labelHeight: CGFloat = 18
    static var tileHeight: CGFloat { previewHeight + labelHeight + 2 * tileInset }
    static let spacing: CGFloat = 3
    static let padding: CGFloat = 4
    /// Between the icon and the panel.
    static let gap: CGFloat = 6
    static let screenMargin: CGFloat = 8

    var onOpen: ((SwitchableWindow) -> Void)?
    var onClose: ((SwitchableWindow) -> Void)?

    private var window: NSPanel?
    private var tiles: [DockPreviewTile] = []

    /// The panel's frame in the window server's coordinates, while it is on screen.
    var frameInWindowServer: CGRect? {
        guard let window, window.isVisible else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let f = window.frame
        return CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
    }

    /// The Dock popup's tile shape, as the shared layout takes it.
    static var shape: PreviewLayout {
        PreviewLayout(previewHeight: previewHeight, minPreviewWidth: minPreviewWidth,
                      maxPreviewWidth: maxPreviewWidth, tileInset: tileInset, labelHeight: labelHeight,
                      spacing: spacing, padding: padding, minScale: 0.5)
    }

    static func layout(aspects: [CGFloat], limit: CGSize) -> (frames: [CGRect], size: CGSize) {
        shape.layout(aspects: aspects, limit: limit)
    }

    /// Where the panel goes: beside the icon on the Dock's side, centred on it, and kept on
    /// `screen` (all in Cocoa coordinates, origin bottom-left). Pure, for tests.
    static func placement(size: CGSize, icon: CGRect, edge: DockEdge, screen: CGRect) -> CGRect {
        var origin: CGPoint
        switch edge {
        case .bottom: origin = CGPoint(x: icon.midX - size.width / 2, y: icon.maxY + gap)
        case .left: origin = CGPoint(x: icon.maxX + gap, y: icon.midY - size.height / 2)
        case .right: origin = CGPoint(x: icon.minX - gap - size.width, y: icon.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, screen.minX + screenMargin), screen.maxX - screenMargin - size.width)
        origin.y = min(max(origin.y, screen.minY + screenMargin), screen.maxY - screenMargin - size.height)
        return CGRect(origin: origin, size: size)
    }

    func present(_ windows: [SwitchableWindow], iconInWindowServer icon: CGRect, edge: DockEdge) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let iconRect = CGRect(x: icon.minX, y: primaryHeight - icon.maxY, width: icon.width, height: icon.height)
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: iconRect.midX, y: iconRect.midY)) }
            ?? NSScreen.main
        guard let screen else { return }
        let area = screen.frame
        let limit = edge == .bottom
            ? CGSize(width: area.width - 2 * Self.screenMargin, height: area.height * 0.5)
            : CGSize(width: area.width * 0.5, height: area.height - 2 * Self.screenMargin)
        let (frames, size) = Self.layout(aspects: windows.map { $0.bounds.width / max(1, $0.bounds.height) },
                                         limit: limit)

        let panel = window ?? makePanel()
        window = panel
        let content = panel.contentView!
        tiles.forEach { $0.removeFromSuperview() }
        tiles = zip(windows, frames).map { w, f in
            // Flipped: the layout counts rows down from the top.
            let frame = NSRect(x: f.minX, y: size.height - f.maxY, width: f.width, height: f.height)
            let tile = DockPreviewTile(frame: frame, window: w, icon: SwitcherPanel.appIcon(for: w.pid))
            if let image = WindowPreviews.shared.image(for: w.id) { tile.setThumbnail(image) }
            tile.onOpen = { [weak self] in self?.onOpen?(w) }
            tile.onClose = { [weak self] in self?.onClose?(w) }
            content.addSubview(tile)
            return tile
        }
        panel.setFrame(Self.placement(size: size, icon: iconRect, edge: edge, screen: area), display: true)
        panel.invalidateShadow()
        panel.orderFrontRegardless()
    }

    func setThumbnail(_ image: CGImage, for id: CGWindowID) {
        tiles.first { $0.target.id == id }?.setThumbnail(image)
    }

    func dismiss() {
        window?.orderOut(nil)
        tiles.forEach { $0.removeFromSuperview() }
        tiles = []
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        // Above the Dock (which sits at its own level, 20) so the panel is never under it.
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = RoundedMask.image(radius: 10)
        panel.contentView = background
        return panel
    }
}

/// One window in the Dock panel: its preview, its title, and a close button that shows on hover.
final class DockPreviewTile: NSView {

    let target: SwitchableWindow
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    private let preview = NSImageView()
    private let label: NSTextField
    let closeButton: NSButton
    /// Asked once, on the first hover: only a window with a close button of its own gets an ✕.
    private lazy var closable = WindowActivator.canClose(target)
    private var hovering = false { didSet { closeButton.isHidden = !(hovering && closable); needsDisplay = true } }

    init(frame: NSRect, window: SwitchableWindow, icon: NSImage?) {
        target = window
        let title = window.title.isEmpty ? window.appName : window.title
        label = NSTextField(labelWithString: window.isOffScreen ? "\(title) — not on screen" : title)
        closeButton = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill",
                                              accessibilityDescription: "Close window") ?? NSImage(),
                               target: nil, action: nil)
        super.init(frame: frame)
        let labelHeight = DockPreviewPanel.labelHeight, inset = DockPreviewPanel.tileInset

        preview.frame = NSRect(x: inset, y: labelHeight + inset, width: frame.width - 2 * inset,
                               height: frame.height - labelHeight - 2 * inset)
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.image = icon
        preview.alphaValue = window.isOffScreen ? 0.6 : 1
        addSubview(preview)

        label.frame = NSRect(x: inset, y: 2, width: frame.width - 2 * inset, height: labelHeight - 2)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        closeButton.frame = NSRect(x: frame.width - 24, y: frame.height - 24, width: 20, height: 20)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        closeButton.toolTip = "Close window (or middle-click the preview)"
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setThumbnail(_ image: CGImage) {
        preview.image = NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Taken here so the click's mouse-up comes back to this tile.
    override func mouseDown(with event: NSEvent) {}

    /// A middle click closes the window without switching to it, as on the Windows taskbar.
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, closable,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClose?()
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen?()
    }

    @objc private func closeClicked() { onClose?() }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        NSColor.white.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }
}

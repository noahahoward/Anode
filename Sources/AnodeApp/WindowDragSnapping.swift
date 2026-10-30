import AppKit
import ApplicationServices
import PowerKit

// ── Snapping by dragging (Beta Features) ────────────────────────────────────
//
// Drag a window by its title bar to a screen edge or corner and let go: it takes that half, quarter
// or third, with an outline showing where it will land. Rectangle (MIT) was read for how it tells a
// window drag from any other drag: the system stamps every mouse-down with the window under the
// pointer, and the drag counts as a window drag once THAT window's frame moves without resizing.
//
// Where this differs from Rectangle, on purpose:
// - the Dock's edge is a zone like any other (measured: dragging a window to the bottom edge does not
//   make an auto-hiding Dock appear), so the bottom edge gives thirds on a Mac with a bottom Dock;
// - an edge shared with another display is not a zone, so carrying a window across never snaps it;
// - the top edge (maximize) needs the pointer to rest there for a moment, so a window dragged up to
//   the menu bar on the way somewhere else is not maximized;
// - a zone, once active, stays active until the pointer is clearly out of it (hysteresis), so the
//   outline does not flicker on a boundary;
// - the outline is drawn from the same geometry that places the window (`WindowGeometry`, which
//   knows about the Dock), so what is shown is what you get.
// Needs Accessibility (to place the window). macOS's own edge tiling must be off, or both would act.

/// Where on a screen the pointer can ask for a snap.
enum SnapZone: Equatable {
    case topLeft, topRight, bottomLeft, bottomRight
    case left, right, top
    case bottomFirst, bottomCenter, bottomLast

    var action: WindowAction {
        switch self {
        case .topLeft: return .topLeft
        case .topRight: return .topRight
        case .bottomLeft: return .bottomLeft
        case .bottomRight: return .bottomRight
        case .left: return .leftHalf
        case .right: return .rightHalf
        case .top: return .maximize
        case .bottomFirst: return .firstThird
        case .bottomCenter: return .centerThird
        case .bottomLast: return .lastThird
        }
    }
}

enum SnapZones {

    struct Config: Equatable {
        /// How close to an edge the pointer must be, in points.
        var edge: CGFloat = 14
        /// How close to a corner (to BOTH of its edges) for a quarter.
        var corner: CGFloat = 64
        /// How much further out an active zone reaches, so it does not flicker at its boundary.
        var hysteresis: CGFloat = 18
        /// How long the pointer rests at the top before it means "maximize". Short: the zone is the whole
        /// menu bar, and this only keeps a pointer passing through it from flashing the outline.
        var topDwell: TimeInterval = 0.1
    }

    /// The zone the pointer is in, or nil. `point` and the screen `frames` are in the window server's
    /// coordinates (y down). `previous` is the zone that was active (for hysteresis); `topDwelt` says the pointer has rested at the top long enough. Pure, for tests.
    ///
    /// `topDepths` is how deep the top zone is on each screen, in step with `frames`: the height of its
    /// menu bar, so maximizing engages as soon as the pointer reaches the menu bar rather than only in its
    /// top few points. nil (or a screen with no menu bar, which reads 0) uses the ordinary edge depth.
    static func zone(at point: CGPoint, screens frames: [CGRect], previous: SnapZone?,
                     topDwelt: Bool, config: Config = Config(), topDepths: [CGFloat]? = nil) -> SnapZone? {
        // The screen the pointer is on; a point on the far edge counts (CGRect.contains leaves it out).
        guard let at = frames.firstIndex(where: { $0.insetBy(dx: -0.5, dy: -0.5).contains(point) }) else { return nil }
        let f = frames[at]
        let grow = previous == nil ? 0 : config.hysteresis
        let t = config.edge + grow, c = config.corner + grow
        let topT = max(config.edge, topDepths.flatMap { $0.indices.contains(at) ? $0[at] : nil } ?? 0) + grow

        // An edge another display touches (over the pointer's span) is a seam, not an edge.
        func shared(_ side: Int) -> Bool {
            frames.contains { o in
                guard o != f else { return false }
                switch side {
                case 0: return abs(o.maxX - f.minX) <= 1 && point.y >= o.minY && point.y <= o.maxY   // left
                case 1: return abs(o.minX - f.maxX) <= 1 && point.y >= o.minY && point.y <= o.maxY   // right
                case 2: return abs(o.maxY - f.minY) <= 1 && point.x >= o.minX && point.x <= o.maxX   // top
                default: return abs(o.minY - f.maxY) <= 1 && point.x >= o.minX && point.x <= o.maxX  // bottom
                }
            }
        }
        let leftOK = !shared(0), rightOK = !shared(1), topOK = !shared(2), bottomOK = !shared(3)

        let nearLeft = point.x - f.minX < c, nearRight = f.maxX - point.x < c
        let nearTop = point.y - f.minY < c, nearBottom = f.maxY - point.y < c
        // Corners: close to two edges at once, and neither of them a seam.
        if nearLeft && nearTop && leftOK && topOK { return .topLeft }
        if nearRight && nearTop && rightOK && topOK { return .topRight }
        if nearLeft && nearBottom && leftOK && bottomOK { return .bottomLeft }
        if nearRight && nearBottom && rightOK && bottomOK { return .bottomRight }

        // Edges. The Dock's own edge is a zone like any other: a window being dragged does not make an
        // auto-hiding Dock appear (so the pointer can rest on the bottom edge), and the outline is drawn
        // above a Dock that is showing, from the usable area.
        if point.x - f.minX < t && leftOK { return .left }
        if f.maxX - point.x < t && rightOK { return .right }
        if point.y - f.minY < topT && topOK { return topDwelt || previous == .top ? .top : nil }
        if f.maxY - point.y < t && bottomOK {
            let share = (point.x - f.minX) / f.width
            return share < 1.0 / 3 ? .bottomFirst : (share < 2.0 / 3 ? .bottomCenter : .bottomLast)
        }
        return nil
    }

    /// Is the pointer in the top zone, whatever the dwell? The controller starts its dwell timer on this.
    static func inTopEdge(_ point: CGPoint, screens frames: [CGRect], config: Config = Config(),
                          topDepths: [CGFloat]? = nil) -> Bool {
        guard let at = frames.firstIndex(where: { $0.insetBy(dx: -0.5, dy: -0.5).contains(point) }) else { return false }
        let depth = max(config.edge, topDepths.flatMap { $0.indices.contains(at) ? $0[at] : nil } ?? 0)
        return point.y - frames[at].minY < depth
    }

    /// The menu bar's height on each screen, which is how deep its top zone is.
    static func menuBarDepths() -> [CGFloat] {
        NSScreen.screens.map { max(0, $0.frame.maxY - $0.visibleFrame.maxY) }
    }

    /// The window a drag started on, restored to the size it had before it was snapped: the same width
    /// and height as before, placed so the pointer keeps its place along the title bar.
    static func unsnapped(snapped: CGRect, original: CGSize, pointer: CGPoint) -> CGRect {
        guard snapped.width > 0 else { return CGRect(origin: snapped.origin, size: original) }
        let share = min(max((pointer.x - snapped.minX) / snapped.width, 0), 1)
        let x = pointer.x - original.width * share
        let y = pointer.y - min(max(pointer.y - snapped.minY, 0), original.height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: original.width, height: original.height)
    }
}

/// The outline showing where a window will land.
final class SnapFootprint {

    private var window: NSPanel?

    /// Show (or move) the outline to `rect`, in the window server's coordinates.
    func show(_ rect: CGRect) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        let panel = window ?? makePanel()
        window = panel
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard let window, window.isVisible else { return }
        window.orderOut(nil)
    }

    var isShowing: Bool { window?.isVisible ?? false }

    /// The outline's frame in the window server's coordinates, for tests.
    var frameInWindowServer: CGRect? {
        guard let window, window.isVisible else { return nil }
        let h = NSScreen.screens.first?.frame.height ?? 0
        let f = window.frame
        return CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.borderWidth = 2
        view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        panel.contentView = view
        return panel
    }
}

/// Watches the mouse for window drags and snaps on release.
final class WindowDragSnapper {

    private let settings: Settings
    private weak var snapper: WindowSnapper?
    private var settingToken: AnyObject?
    // The mouse is watched with an event tap, not NSEvent monitors: a global monitor never sees events
    // meant for the app's OWN windows, so dragging one of Anode's windows did nothing at all.
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private let footprint = SnapFootprint()
    private let config = SnapZones.Config()

    // The drag in progress.
    private var window: AccessibleWindow?
    private var windowID: CGWindowID?
    private var startFrame: CGRect?
    private var moving = false
    private var cancelled = false
    private var zone: SnapZone?
    private var topSince: Date?
    private var lastPoll = Date.distantPast
    private var lastFrame: CGRect?

    /// What a window was before a drag snapped it, and where it was put, so that dragging it away
    /// gives it its old size back.
    private var snappedWindows: [CGWindowID: (original: CGSize, placed: CGRect)] = [:]

    var isRunning: Bool { tap != nil }

    init(settings: Settings = .shared, snapper: WindowSnapper?) {
        self.settings = settings
        self.snapper = snapper
        settingToken = settings.observe(Settings.Key.windowDragSnapEnabled) { [weak self] in self?.apply() }
        apply()
    }

    deinit { stop() }

    func apply() {
        if settings.windowDragSnapEnabled { start() } else { stop() }
    }

    private func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue) | (1 << CGEventType.keyDown.rawValue)
        // An active tap that passes everything on untouched: it needs only Accessibility, which listening
        // to keys would otherwise want a second permission for.
        // The session tap, not the HID one: by then the system has worked out which window each mouse event is
        // for, and stamped it on the event, which is how the dragged window is found.
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: dragTapCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        tapSource = source
    }

    private func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        footprint.hide()
        reset()
    }

    /// Called from the tap, which must return at once: it only notes what happened and handles it a
    /// moment later, so the mouse is never held up.
    fileprivate func tapped(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            let sample = Sample(type: type, point: event.location,
                                windowUnder: CGWindowID(max(0, event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent))),
                                keyCode: 0)
            DispatchQueue.main.async { [weak self] in self?.handle(sample) }
        case .keyDown:
            let sample = Sample(type: type, point: .zero, windowUnder: 0, keyCode: event.getIntegerValueField(.keyboardEventKeycode))
            DispatchQueue.main.async { [weak self] in self?.handle(sample) }
        default:
            break
        }
    }

    /// What the tap saw, cut down to what is used.
    struct Sample {
        let type: CGEventType
        let point: CGPoint
        let windowUnder: CGWindowID
        let keyCode: Int64
    }

    private func reset() {
        window = nil; windowID = nil; startFrame = nil
        moving = false; cancelled = false; zone = nil; topSince = nil; lastFrame = nil
    }

    // ── Events ──────────────────────────────────────────────────────────────

    private func handle(_ event: Sample) {
        switch event.type {
        case .leftMouseDown: began(event)
        case .leftMouseDragged: dragged(event)
        case .leftMouseUp: ended(event)
        case .keyDown:
            // Escape while dragging: no snap for this drag.
            if event.keyCode == 53, window != nil { cancelled = true; zone = nil; footprint.hide() }
        default: break
        }
    }

    private func began(_ event: Sample) {
        reset()
        footprint.hide()
        guard AccessibilityAccess.isTrusted else { return }
        let p = event.point
        // The window the system says is under the pointer: stamped on the event, so it is the window
        // that was there at the click, however long this handler is delayed.
        var id = event.windowUnder
        if id == 0 { id = Self.windowID(at: p) ?? 0 }
        guard id != 0, let info = Self.windowInfo(id), info.layer == 0 else { return }
        guard let w = AccessibleWindow.find(id: id, pid: info.pid), w.isResizable, w.frame != nil else { return }
        window = w
        windowID = id
        startFrame = info.bounds
        lastFrame = info.bounds
    }

    private func dragged(_ event: Sample) {
        guard let window, !cancelled, let id = windowID, let start = startFrame else { return }
        // Throttled: a drag produces events far faster than the outline needs to follow.
        guard Date().timeIntervalSince(lastPoll) > 0.02 else { return }
        lastPoll = Date()
        let p = event.point

        if !moving {
            guard let now = Self.windowInfo(id)?.bounds else { return }
            let moved = abs(now.minX - start.minX) > 4 || abs(now.minY - start.minY) > 4
            let resized = abs(now.width - start.width) > 2 || abs(now.height - start.height) > 2
            guard moved && !resized else { return }
            moving = true
            // A snapped window dragged away gets its old size back, under the pointer.
            if let snapped = snappedWindows[id], abs(start.width - snapped.placed.width) < 3,
               abs(start.height - snapped.placed.height) < 3 {
                window.setFrame(SnapZones.unsnapped(snapped: now, original: snapped.original, pointer: p))
                snappedWindows[id] = nil
            }
        }

        let screens = Self.screenFrames()
        let depths = SnapZones.menuBarDepths()
        if SnapZones.inTopEdge(p, screens: screens, config: config, topDepths: depths) {
            if topSince == nil { topSince = Date() }
        } else {
            topSince = nil
        }
        let dwelt = topSince.map { Date().timeIntervalSince($0) >= config.topDwell } ?? false
        let found = SnapZones.zone(at: p, screens: screens, previous: zone, topDwelt: dwelt,
                                   config: config, topDepths: depths)
        if found != zone {
            zone = found
            if let found, let target = target(for: found, pointer: p) { footprint.show(target) } else { footprint.hide() }
        }
        // The dwell is up with the pointer still: the zone appears without waiting for another move.
        if zone == nil, topSince != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + config.topDwell + 0.02) { [weak self] in
                guard let self, self.moving, !self.cancelled, self.topSince != nil else { return }
                self.dragged(event)
            }
        }
    }

    private func ended(_ event: Sample) {
        defer { footprint.hide(); reset() }
        guard moving, !cancelled, let window, let id = windowID, let start = startFrame else { return }
        // The last drag event may have been coalesced: decide from where the pointer is now.
        let p = event.point
        let screens = Self.screenFrames()
        let dwelt = topSince.map { Date().timeIntervalSince($0) >= config.topDwell } ?? false
        guard let finalZone = SnapZones.zone(at: p, screens: screens, previous: zone,
                                             topDwelt: dwelt, config: config, topDepths: SnapZones.menuBarDepths()),
              let target = target(for: finalZone, pointer: p) else { return }
        let original = snappedWindows[id]?.original ?? start.size
        snapper?.placeDragged(finalZone.action, on: window, restoreFrame: start, pointer: p)
        snappedWindows[id] = (original, target)
        if snappedWindows.count > 50 { snappedWindows.removeValue(forKey: snappedWindows.keys.first!) }
    }

    /// Where `zone` puts the dragged window, on the screen the pointer is on.
    private func target(for zone: SnapZone, pointer: CGPoint) -> CGRect? {
        let areas = WindowSnapper.usableAreas(), frames = Self.screenFrames()
        guard let index = frames.firstIndex(where: { $0.insetBy(dx: -0.5, dy: -0.5).contains(pointer) }),
              areas.indices.contains(index),
              let current = lastFrame ?? startFrame else { return nil }
        return WindowGeometry.frame(for: zone.action, from: current, in: areas[index])
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    static func screenFrames() -> [CGRect] {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.map { ScreenState.cgFrame(of: $0, primaryHeight: h) }
    }

    static func windowInfo(_ id: CGWindowID) -> (pid: pid_t, layer: Int, bounds: CGRect)? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]], let e = list.first,
              let pid = e[kCGWindowOwnerPID as String] as? Int32, let layer = e[kCGWindowLayer as String] as? Int,
              let dict = e[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: dict)
        else { return nil }
        return (pid, layer, bounds)
    }

    /// The window under a point, from the window list, for events that carry no window number.
    static func windowID(at point: CGPoint) -> CGWindowID? {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for e in info where (e[kCGWindowLayer as String] as? Int) == 0 {
            if let d = e[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: d), b.contains(point),
               let n = e[kCGWindowNumber as String] as? Int { return CGWindowID(n) }
        }
        return nil
    }
}

private func dragTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                             refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon { Unmanaged<WindowDragSnapper>.fromOpaque(refcon).takeUnretainedValue().tapped(type: type, event: event) }
    return Unmanaged.passUnretained(event)
}

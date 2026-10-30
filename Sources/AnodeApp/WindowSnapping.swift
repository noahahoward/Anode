import AppKit
import ApplicationServices
import Carbon.HIToolbox
import PowerKit

// ── Window actions (Beta Features) ──────────────────────────────────────────
//
// Put the front window in a half, a third, a quarter, the whole screen, the middle, or on the
// next display, from the keyboard. Rectangle (MIT, Ryan Hanson, itself based on Spectacle) was
// read for how this is done and what it gets right; this is written for Anode, with the same
// default shortcuts so a hand that knows Rectangle already knows this.
//
// What Rectangle does, and what is kept:
// - the window is moved through accessibility: size, then position, then size again (the first size
//   lets a window that would not fit at its old position be placed; the last corrects a window that
//   clamped the first), with the app's "enhanced user interface" switched off for the moment, because
//   an app that animates its own resizes (Terminal, some Electron apps) otherwise lands short;
// - a window that cannot be that size (a minimum size, or fixed) ends up as close as it can and is
//   kept on screen;
// - the size a window had before its first action is remembered, so Restore puts it back.
//
// What is different, and is the reason for writing it:
// - the usable area of a screen. Rectangle derives it from the Dock's auto-hide PREFERENCE and the
//   Dock's icon strip, so whenever the Dock is pinned up (which Anode's Dock previews do while a
//   preview is open) it takes the Dock's height off every window: measured 1130 -> 1027 pt, and the
//   window stays short once the Dock goes. Here the area is the screen below the menu bar whenever
//   the USER'S setting is auto-hide, which Anode knows even while it is holding the Dock up.
//
// The shortcuts are registered with the system's hot key service (Carbon `RegisterEventHotKey`),
// which needs no permission and is exclusive: if Rectangle already owns a shortcut, registering it
// fails, and the Beta Features section says so. Moving another app's window needs Accessibility.

/// What can be done to a window.
enum WindowAction: String, CaseIterable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case firstThird, centerThird, lastThird, firstTwoThirds, lastTwoThirds
    case maximize, maximizeHeight, center, restore
    case nextDisplay, previousDisplay

    var title: String {
        switch self {
        case .leftHalf: return "Left half"
        case .rightHalf: return "Right half"
        case .topHalf: return "Top half"
        case .bottomHalf: return "Bottom half"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        case .firstThird: return "First third"
        case .centerThird: return "Center third"
        case .lastThird: return "Last third"
        case .firstTwoThirds: return "First two thirds"
        case .lastTwoThirds: return "Last two thirds"
        case .maximize: return "Maximize"
        case .maximizeHeight: return "Maximize height"
        case .center: return "Center"
        case .restore: return "Restore"
        case .nextDisplay: return "Next display"
        case .previousDisplay: return "Previous display"
        }
    }

    /// Rectangle's own defaults (Control-Option), so the shortcuts you know still work.
    var shortcut: (key: Int, modifiers: Int, label: String) {
        let co = controlKey | optionKey, cos = controlKey | optionKey | shiftKey, coc = controlKey | optionKey | cmdKey
        switch self {
        case .leftHalf: return (kVK_LeftArrow, co, "⌃⌥←")
        case .rightHalf: return (kVK_RightArrow, co, "⌃⌥→")
        case .topHalf: return (kVK_UpArrow, co, "⌃⌥↑")
        case .bottomHalf: return (kVK_DownArrow, co, "⌃⌥↓")
        case .topLeft: return (kVK_ANSI_U, co, "⌃⌥U")
        case .topRight: return (kVK_ANSI_I, co, "⌃⌥I")
        case .bottomLeft: return (kVK_ANSI_J, co, "⌃⌥J")
        case .bottomRight: return (kVK_ANSI_K, co, "⌃⌥K")
        case .firstThird: return (kVK_ANSI_D, co, "⌃⌥D")
        case .centerThird: return (kVK_ANSI_F, co, "⌃⌥F")
        case .lastThird: return (kVK_ANSI_G, co, "⌃⌥G")
        case .firstTwoThirds: return (kVK_ANSI_E, co, "⌃⌥E")
        case .lastTwoThirds: return (kVK_ANSI_T, co, "⌃⌥T")
        case .maximize: return (kVK_Return, co, "⌃⌥↩")
        case .maximizeHeight: return (kVK_UpArrow, cos, "⌃⌥⇧↑")
        case .center: return (kVK_ANSI_C, co, "⌃⌥C")
        case .restore: return (kVK_Delete, co, "⌃⌥⌫")
        case .nextDisplay: return (kVK_RightArrow, coc, "⌃⌥⌘→")
        case .previousDisplay: return (kVK_LeftArrow, coc, "⌃⌥⌘←")
        }
    }
}

/// Where a window goes. All pure, in the window server's coordinates (origin top-left, y down), the
/// same ones accessibility uses, so nothing is flipped on the way to a window.
enum WindowGeometry {

    /// The part of a screen windows are placed in, as a rectangle in the window server's coordinates.
    ///
    /// With auto-hide the Dock takes no room, so this is the screen below the menu bar, WHATEVER
    /// `visibleFrame` says: it shrinks while the Dock is up, and while Anode holds the Dock up for a
    /// preview, which would put every window the height of the Dock short. Without auto-hide the Dock
    /// is part of the user's layout and `visibleFrame` is right.
    ///
    /// `screenFrame` and `visibleFrame` are AppKit's (origin bottom-left); `primaryHeight` flips them.
    static func usableArea(screenFrame: CGRect, visibleFrame: CGRect, userAutoHidesDock: Bool,
                           primaryHeight: CGFloat) -> CGRect {
        let area: CGRect
        if userAutoHidesDock {
            let menuBar = max(0, screenFrame.maxY - visibleFrame.maxY)
            area = CGRect(x: screenFrame.minX, y: screenFrame.minY, width: screenFrame.width,
                          height: screenFrame.height - menuBar)
        } else {
            area = visibleFrame
        }
        return CGRect(x: area.minX, y: primaryHeight - area.maxY, width: area.width, height: area.height)
    }

    /// The frame `action` gives a window currently at `frame`, within `area`. nil for the actions that
    /// are not a rectangle on one screen (restore, display moves). Whole points, with the last part
    /// taking the remainder, so two halves or three thirds always meet and never leave a gap.
    static func frame(for action: WindowAction, from frame: CGRect, in area: CGRect) -> CGRect? {
        let x = area.minX, y = area.minY, w = area.width, h = area.height
        let halfW = (w / 2).rounded(.down), halfH = (h / 2).rounded(.down)
        let third = (w / 3).rounded(.down), twoThirds = (w * 2 / 3).rounded(.down)
        switch action {
        case .leftHalf: return CGRect(x: x, y: y, width: halfW, height: h)
        case .rightHalf: return CGRect(x: x + halfW, y: y, width: w - halfW, height: h)
        case .topHalf: return CGRect(x: x, y: y, width: w, height: halfH)
        case .bottomHalf: return CGRect(x: x, y: y + halfH, width: w, height: h - halfH)
        case .topLeft: return CGRect(x: x, y: y, width: halfW, height: halfH)
        case .topRight: return CGRect(x: x + halfW, y: y, width: w - halfW, height: halfH)
        case .bottomLeft: return CGRect(x: x, y: y + halfH, width: halfW, height: h - halfH)
        case .bottomRight: return CGRect(x: x + halfW, y: y + halfH, width: w - halfW, height: h - halfH)
        case .firstThird: return CGRect(x: x, y: y, width: third, height: h)
        case .centerThird: return CGRect(x: x + third, y: y, width: third, height: h)
        case .lastThird: return CGRect(x: x + 2 * third, y: y, width: w - 2 * third, height: h)
        case .firstTwoThirds: return CGRect(x: x, y: y, width: twoThirds, height: h)
        case .lastTwoThirds: return CGRect(x: x + w - twoThirds, y: y, width: twoThirds, height: h)
        case .maximize: return area
        case .maximizeHeight: return CGRect(x: frame.minX, y: y, width: frame.width, height: h)
        case .center:
            let size = CGSize(width: min(frame.width, w), height: min(frame.height, h))
            return CGRect(x: x + ((w - size.width) / 2).rounded(.down), y: y + ((h - size.height) / 2).rounded(.down),
                          width: size.width, height: size.height)
        case .restore, .nextDisplay, .previousDisplay: return nil
        }
    }

    /// `frame` carried from one screen's usable area to another's, keeping where it sits and how much of
    /// the screen it takes, so a window half the height of one display is half the height of the next.
    static func carried(_ frame: CGRect, from source: CGRect, to destination: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return frame }
        let sx = destination.width / source.width, sy = destination.height / source.height
        var r = CGRect(x: destination.minX + (frame.minX - source.minX) * sx,
                       y: destination.minY + (frame.minY - source.minY) * sy,
                       width: min(frame.width * sx, destination.width), height: min(frame.height * sy, destination.height))
        r.origin.x = min(max(r.minX, destination.minX), destination.maxX - r.width)
        r.origin.y = min(max(r.minY, destination.minY), destination.maxY - r.height)
        return CGRect(x: r.minX.rounded(), y: r.minY.rounded(), width: r.width.rounded(), height: r.height.rounded())
    }

    /// A window that could not be made `wanted` (it has a minimum size) ends up `actual`; keep it inside
    /// `area`, with the edge the action was aimed at kept where it was meant to be.
    static func kept(_ actual: CGRect, wanted: CGRect, in area: CGRect) -> CGRect {
        var r = actual
        // Aim for the same side: a window placed at the right edge that came out wider grows leftward.
        if wanted.maxX >= area.maxX - 0.5 { r.origin.x = wanted.maxX - r.width }
        if wanted.maxY >= area.maxY - 0.5 { r.origin.y = wanted.maxY - r.height }
        r.origin.x = min(max(r.minX, area.minX), max(area.minX, area.maxX - r.width))
        r.origin.y = min(max(r.minY, area.minY), max(area.minY, area.maxY - r.height))
        return r
    }

    /// The screen a window is mostly on: the one its frame overlaps most, or the one nearest its centre.
    static func screenIndex(for frame: CGRect, in areas: [CGRect]) -> Int? {
        guard !areas.isEmpty else { return nil }
        let overlaps = areas.map { a -> CGFloat in
            let i = a.intersection(frame)
            return i.isNull ? 0 : i.width * i.height
        }
        if let best = overlaps.max(), best > 0 { return overlaps.firstIndex(of: best) }
        let c = CGPoint(x: frame.midX, y: frame.midY)
        return areas.indices.min { distance(c, areas[$0]) < distance(c, areas[$1]) }
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }
}

/// One window, through accessibility.
struct AccessibleWindow {
    let element: AXUIElement
    let pid: pid_t

    /// The window with keyboard focus in the front app, if it is one that can be moved.
    static func front() -> AccessibleWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let window = focused, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let w = AccessibleWindow(element: window as! AXUIElement, pid: app.processIdentifier)
        // A sheet or a full-screen window is not something to place.
        if w.string(kAXSubroleAttribute) == kAXSheetRole as String { return nil }
        if w.bool("AXFullScreen") == true { return nil }
        return w
    }

    var frame: CGRect? {
        guard let p = point(kAXPositionAttribute), let s = size(kAXSizeAttribute) else { return nil }
        return CGRect(origin: p, size: s)
    }

    var isResizable: Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success && settable.boolValue
    }

    var windowID: CGWindowID? {
        typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "_AXUIElementGetWindow") else { return nil }
        var id: CGWindowID = 0
        return unsafeBitCast(sym, to: GetWindow.self)(element, &id) == .success && id != 0 ? id : nil
    }

    /// Place the window and return the frame it actually took. Size, then position, then size, with the
    /// app's enhanced user interface off for the duration (see the header).
    @discardableResult
    func setFrame(_ frame: CGRect) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        var enhanced: CFTypeRef?
        let hadEnhanced = AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &enhanced) == .success
            && (enhanced as? Bool) == true
        if hadEnhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer { if hadEnhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }
        if isResizable { setSize(frame.size) }
        setPosition(frame.origin)
        if isResizable { setSize(frame.size) }
        return self.frame
    }

    private func setSize(_ s: CGSize) {
        var v = s
        if let value = AXValueCreate(.cgSize, &v) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) }
    }

    private func setPosition(_ p: CGPoint) {
        var v = p
        if let value = AXValueCreate(.cgPoint, &v) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) }
    }

    private func point(_ attribute: String) -> CGPoint? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &v) == .success, let v else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    private func size(_ attribute: String) -> CGSize? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &v) == .success, let v else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    private func string(_ attribute: String) -> String? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &v)
        return v as? String
    }

    private func bool(_ attribute: String) -> Bool? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &v)
        return v as? Bool
    }
}

/// Does the user keep the Dock hidden? The setting they chose, not what the Dock is doing at this
/// moment: while Anode holds the Dock up for a preview the stored preference reads "off", and a window
/// placed then must still be sized for the Dock they actually want.
enum DockIntent {
    static func userAutoHidesDock(isEnabled: Bool? = DockAutoHide.isEnabled,
                                  heldByAnode: Bool = UserDefaults.standard.bool(forKey: DockHold.recordKey)) -> Bool {
        heldByAnode ? true : (isEnabled ?? false)
    }
}

/// Carries out the actions and owns the hot keys.
final class WindowSnapper {

    private let settings: Settings
    private var settingToken: AnyObject?
    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var actions: [UInt32: WindowAction] = [:]
    /// The frame a window had before its first action here, for Restore. Keyed by window number.
    private var restoreFrames: [CGWindowID: CGRect] = [:]
    /// What this machine's registration said: shortcuts another app already owns.
    private(set) var unavailable: [WindowAction] = []

    private static let signature: OSType = 0x414E5352   // "ANSR"

    init(settings: Settings = .shared) {
        self.settings = settings
        settingToken = settings.observe(Settings.Key.windowSnapperEnabled) { [weak self] in self?.apply() }
        apply()
    }

    deinit { unregister() }

    var isRunning: Bool { handler != nil }

    func apply() {
        if settings.windowSnapperEnabled { if handler == nil { register() } } else { unregister() }
    }

    // ── Hot keys ────────────────────────────────────────────────────────────

    private func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, refcon in
            guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            Unmanaged<WindowSnapper>.fromOpaque(refcon).takeUnretainedValue().pressed(id.id)
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { handler = nil; return }

        unavailable = []
        for (i, action) in WindowAction.allCases.enumerated() {
            let id = UInt32(i + 1)
            var ref: EventHotKeyRef?
            let s = RegisterEventHotKey(UInt32(action.shortcut.key), UInt32(action.shortcut.modifiers),
                                        EventHotKeyID(signature: Self.signature, id: id),
                                        GetApplicationEventTarget(), 0, &ref)
            if s == noErr { refs.append(ref); actions[id] = action } else { unavailable.append(action) }
        }
    }

    private func unregister() {
        refs.forEach { if let r = $0 { UnregisterEventHotKey(r) } }
        refs = []
        actions = [:]
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func pressed(_ id: UInt32) {
        guard let action = actions[id] else { return }
        DispatchQueue.main.async { [weak self] in self?.perform(action) }
    }

    // ── Doing it ────────────────────────────────────────────────────────────

    /// The usable area of every screen, in the order macOS lists them, for the user's Dock setting.
    static func usableAreas() -> [CGRect] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let autoHide = DockIntent.userAutoHidesDock()
        return NSScreen.screens.map {
            WindowGeometry.usableArea(screenFrame: $0.frame, visibleFrame: $0.visibleFrame,
                                      userAutoHidesDock: autoHide, primaryHeight: primaryHeight)
        }
    }

    /// Screens left to right, then top to bottom: the order "next display" goes in.
    static func displayOrder(_ areas: [CGRect]) -> [Int] {
        areas.indices.sorted { (areas[$0].minX, areas[$0].minY) < (areas[$1].minX, areas[$1].minY) }
    }

    func perform(_ action: WindowAction) {
        // A preview holding the Dock up would make macOS cut the window short; let go of it first.
        if let previews = (NSApp.delegate as? AppDelegate)?.dockPreviews {
            previews.runWithDockReleased { [weak self] in self?.place(action) }
        } else {
            place(action)
        }
    }

    private func place(_ action: WindowAction) {
        guard AccessibilityAccess.isTrusted, let window = AccessibleWindow.front(), let current = window.frame else {
            NSSound.beep()
            return
        }
        let id = window.windowID
        let areas = Self.usableAreas()
        guard let here = WindowGeometry.screenIndex(for: current, in: areas) else { return }

        var target: CGRect?
        switch action {
        case .restore:
            guard let id, let saved = restoreFrames[id] else { NSSound.beep(); return }
            target = saved
            restoreFrames[id] = nil
        case .nextDisplay, .previousDisplay:
            let order = Self.displayOrder(areas)
            guard order.count > 1, let at = order.firstIndex(of: here) else { NSSound.beep(); return }
            let step = action == .nextDisplay ? 1 : order.count - 1
            let there = order[(at + step) % order.count]
            remember(id, current)
            target = WindowGeometry.carried(current, from: areas[here], to: areas[there])
            apply(target!, to: window, in: areas[there])
            return
        default:
            target = WindowGeometry.frame(for: action, from: current, in: areas[here])
            remember(id, current)
        }
        if let target { apply(target, to: window, in: areas[here]) }
    }

    /// The first frame seen for a window is what Restore returns to; later actions do not overwrite it.
    private func remember(_ id: CGWindowID?, _ frame: CGRect) {
        guard let id, restoreFrames[id] == nil else { return }
        restoreFrames[id] = frame
        if restoreFrames.count > 200 { restoreFrames.removeValue(forKey: restoreFrames.keys.first!) }
    }

    private func apply(_ target: CGRect, to window: AccessibleWindow, in area: CGRect) {
        guard let actual = window.setFrame(target) else { return }
        // A window with a minimum size came out bigger than asked: keep it inside, aimed at its edge.
        if abs(actual.width - target.width) > 1 || abs(actual.height - target.height) > 1 {
            let kept = WindowGeometry.kept(actual, wanted: target, in: area)
            if kept != actual { window.setFrame(CGRect(origin: kept.origin, size: actual.size)) }
        }
    }
}

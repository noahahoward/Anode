import AppKit
import ApplicationServices
import PowerKit

// ── One of macOS's own menu bar icons (Sound, Battery), taken over ──────────
//
// With the option on, the menu bar keeps just macOS's own icon, exactly as it is, and a click on it opens Anode's menu.
// Anode finds the icon through Accessibility (its identifier, `com.apple.menuextra.sound`, among MenuBarAgent's items) and swallows the mouse
// press and release that land on it, with an event tap on the shared tap thread. `NativeIconClickGate` decides which clicks;
// this file only carries the decision out.
//
// The tap never holds the mouse up for long: it looks at a cached frame, and only inside that frame asks Accessibility what
// is under the pointer (measured under a millisecond, 25 ms the first time; anything that fails is passed on untouched).
// Anode's own use of macOS's panel presses its items with Accessibility, not with mouse events, so the tap never sees it.

/// What a tap's callback is handed. One per icon identifier, kept for the whole process, and it only holds the icon weakly, so a
/// callback that is still running when the icon goes away finds nothing instead of a freed object.
private final class NativeIconTapBox {
    private static let lock = NSLock()
    private static var boxes: [String: NativeIconTapBox] = [:]
    static func box(for identifier: String) -> NativeIconTapBox {
        lock.lock(); defer { lock.unlock() }
        if let box = boxes[identifier] { return box }
        let box = NativeIconTapBox(); boxes[identifier] = box
        return box
    }
    private let lock = NSLock()
    private weak var _icon: NativeMenuExtraIcon?
    var icon: NativeMenuExtraIcon? {
        get { lock.lock(); defer { lock.unlock() }; return _icon }
        set { lock.lock(); _icon = newValue; lock.unlock() }
    }
}

final class NativeMenuExtraIcon: NativeIconHosting {

    static let soundIdentifier = "com.apple.menuextra.sound"
    static let batteryIdentifier = "com.apple.menuextra.battery"

    /// The item's `AXIdentifier` in macOS's menu bar.
    let identifier: String
    /// The feature log the lines about this icon go to.
    private let logName: String

    init(identifier: String, logName: String) { self.identifier = identifier; self.logName = logName }

    static func sound() -> NativeMenuExtraIcon { NativeMenuExtraIcon(identifier: soundIdentifier, logName: "sound-menu.log") }
    static func battery() -> NativeMenuExtraIcon { NativeMenuExtraIcon(identifier: batteryIdentifier, logName: "battery-menu.log") }

    var onClick: ((CGRect) -> Void)?

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private let tapPort = TapPortBox()
    private let lock = NSLock()
    private var cachedFrame: CGRect?
    /// The item the icon sits in, as tall as the bar: the icon is a small square in its middle, and a click above or below the
    /// square (at the very top of the screen, say) is still a click on the item.
    private var cachedBar: CGRect?
    /// The process that owns macOS's menu bar items: only an element of this one counts as the icon.
    private var trustedPid: pid_t = 0
    private lazy var tapBox = NativeIconTapBox.box(for: identifier)
    private var gate = NativeIconClickGate()   // touched only on the tap thread
    private let systemWide: AXUIElement = {
        let e = AXUIElementCreateSystemWide()
        // The tap waits for this answer, so it is short: a click that cannot be confirmed in time is passed on to macOS.
        AXUIElementSetMessagingTimeout(e, 0.05)
        return e
    }()

    deinit { stop() }

    private func remember(_ frame: CGRect?, pid: pid_t, bar: CGRect? = nil) -> CGRect? {
        lock.lock(); cachedFrame = frame; cachedBar = frame == nil ? nil : bar; trustedPid = pid; lock.unlock()
        return frame
    }

    // ── The icon ────────────────────────────────────────────────────────────

    func currentFrame() -> CGRect? {
        guard AXIsProcessTrusted(),
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first?.processIdentifier
        else { return remember(nil, pid: 0) }
        let agent = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(agent, 0.3)
        guard let bar = Self.attribute(agent, "AXExtrasMenuBar"), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return remember(nil, pid: 0) }
        let groups = (Self.attribute(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]) ?? []   // type checked above
        for group in groups {
            for item in (Self.attribute(group, kAXChildrenAttribute) as? [AXUIElement]) ?? [] where Self.identifier(of: item) == identifier {
                var r = CGRect.zero
                if let v = Self.attribute(item, "AXFrame"), CFGetTypeID(v) == AXValueGetTypeID() { AXValueGetValue(v as! AXValue, .cgRect, &r) }   // type checked
                var itemFrame = CGRect.zero
                if let v = Self.attribute(group, "AXFrame"), CFGetTypeID(v) == AXValueGetTypeID() { AXValueGetValue(v as! AXValue, .cgRect, &itemFrame) }   // type checked
                return remember(r.isEmpty ? nil : r, pid: pid, bar: itemFrame.isEmpty ? nil : itemFrame)
            }
        }
        return remember(nil, pid: 0)
    }

    private static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    private static func identifier(of e: AXUIElement) -> String { attribute(e, "AXIdentifier").map { "\($0)" } ?? "" }

    // ── The tap ─────────────────────────────────────────────────────────────

    func start() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else { FeatureLog.append(logName, "macOS icon: no Accessibility, the tap cannot start"); return }
        if let frame = currentFrame() { _ = underPointerIsTheIcon(CGPoint(x: frame.midX, y: frame.midY)) }
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        // The session tap, an active one: only Accessibility is needed, which Anode already asks for.
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: nativeIconTapCallback,
                                        userInfo: Unmanaged.passUnretained(tapBox).toOpaque()) else {
            FeatureLog.append(logName, "macOS icon: the event tap could not be made")
            return
        }
        FeatureLog.append(logName, "macOS icon: tap started, icon frame \(String(describing: cachedFrame))")
        tapBox.icon = self
        guard let source = CFMachPortCreateRunLoopSource(nil, t, 0) else { return }
        EventTapThread.shared.add(source)
        CGEvent.tapEnable(tap: t, enable: true)
        tapPort.value = t
        tap = t
        tapSource = source
    }

    func stop() {
        if tapBox.icon === self { tapBox.icon = nil }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource { EventTapThread.shared.remove(tapSource) }
        tapPort.value = nil
        tap = nil
        tapSource = nil
    }

    /// Runs on the tap thread. True means "pass the event on"; false swallows it.
    fileprivate func tapped(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port = tapPort.value { CGEvent.tapEnable(tap: port, enable: true) }
            return true
        case .leftMouseDown, .leftMouseUp:
            lock.lock(); let icon = cachedFrame; let bar = cachedBar; lock.unlock()
            let held = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl])
            let point = event.location
            // Command-drag is how icons are rearranged: when the mouse lets go in the bar the icon may be somewhere else, and the next
            // click on it must find it there (the bar settles for a moment, so the look is taken twice).
            if type == .leftMouseUp, point.y < Self.barHeightForRearranging { lookAgainSoon() }
            var liveFrame: CGRect?
            let verdict = gate.decide(type == .leftMouseDown ? .down : .up, at: point, modifiers: !held.isEmpty, icon: icon, bar: bar) {
                liveFrame = iconUnderPointer(point)
                return liveFrame != nil
            }
            // A line for a click near the icon that Anode took, or declined: a press that was passed on is the one worth knowing
            // about (macOS's own panel opens instead). Written off the tap thread: the tap must not wait for a disk.
            if let icon, NativeIconClickGate.isNear(point, icon, bar: bar), verdict != .pass || !held.isEmpty || type == .leftMouseDown {
                let line = "macOS icon: press near the icon: \(verdict), live look: \(liveFrame.map { "icon at x \(Int($0.minX))" } ?? "not the icon"), "
                    + "last known icon x \(Int(icon.minX)), modifiers held: \(!held.isEmpty)"
                let log = logName
                DispatchQueue.global(qos: .utility).async { FeatureLog.append(log, line) }
            }
            switch verdict {
            case .pass: return true
            case .swallow: return false
            case .swallowAndOpen:
                // Where the icon really is now, from the look just taken, not where it was a few seconds ago.
                if let shown = liveFrame ?? icon {
                    lock.lock(); cachedFrame = shown; lock.unlock()
                    DispatchQueue.main.async { [weak self] in self?.onClick?(shown) }
                }
                return false
            }
        default:
            return true
        }
    }

    /// A mouse let go above this row is a let go in the menu bar (the bar is 24 to 38 pt tall).
    private static let barHeightForRearranging: CGFloat = 40

    /// A fresh look at where the icon is, in a moment and again a while after (the other items slide into place). One set of looks
    /// at a time: a run of clicks in the bar asks for one.
    private func lookAgainSoon() {
        lock.lock(); let busy = lookPending; lookPending = true; lock.unlock()
        guard !busy else { return }
        for delay in [0.35, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                _ = self.currentFrame()
                if delay > 1 { self.lock.lock(); self.lookPending = false; self.lock.unlock() }
            }
        }
    }
    private var lookPending = false

    /// The icon's frame when what is under the pointer is this macOS icon, else nil.
    private func iconUnderPointer(_ point: CGPoint) -> CGRect? {
        // While Anode's own picture of the icon is over it (macOS's panel is being read), that picture is what is under the pointer.
        // It is the icon, for this purpose: the click must not fall through to macOS's own panel.
        if CoverPresence.shared.isCovered {
            lock.lock(); let known = cachedFrame; let bar = cachedBar; lock.unlock()
            if let known, NativeIconClickGate.isOnCover(point, of: known, bar: bar) { return known }
        }
        var hit: AXUIElement?
        // On the screen's very top row Accessibility answers with the whole menu bar, not the item under the pointer: ask about the
        // row below, which is the same item (measured: y 0 is the bar, y 0.5 and down the item).
        let probeY = max(point.y, 1)
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(probeY), &hit) == .success, let hit else { return nil }
        // The right id is not enough: any app can name an element anything. It must also belong to the process that draws macOS's bar.
        lock.lock(); let expected = trustedPid; lock.unlock()
        var owner: pid_t = 0
        guard expected != 0, AXUIElementGetPid(hit, &owner) == .success, owner == expected else { return nil }
        // Above or below the icon's square the pointer is over the item that holds it (an unnamed group as tall as the bar, whose
        // one child is the icon): that is a click on the icon too.
        var icon = hit
        if Self.identifier(of: hit) != identifier {
            let children = (Self.attribute(hit, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            guard children.count == 1, let child = children.first, Self.identifier(of: child) == identifier else { return nil }
            icon = child
        }
        var r = CGRect.zero
        if let v = Self.attribute(icon, "AXFrame"), CFGetTypeID(v) == AXValueGetTypeID() { AXValueGetValue(v as! AXValue, .cgRect, &r) }   // type checked
        return r.isEmpty ? nil : r
    }

    private func underPointerIsTheIcon(_ point: CGPoint) -> Bool { iconUnderPointer(point) != nil }
}

private func nativeIconTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                   refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon, let icon = Unmanaged<NativeIconTapBox>.fromOpaque(refcon).takeUnretainedValue().icon else {
        return Unmanaged.passUnretained(event)
    }
    return icon.tapped(type: type, event: event) ? Unmanaged.passUnretained(event) : nil
}

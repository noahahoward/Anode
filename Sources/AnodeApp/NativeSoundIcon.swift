import AppKit
import ApplicationServices
import PowerKit

// ── macOS's own Sound icon, taken over ──────────────────────────────────────
//
// With the option on, the menu bar keeps just macOS's Sound icon, exactly as it is, and a click on it opens Anode's menu.
// Anode finds the icon through Accessibility (`com.apple.menuextra.sound` among MenuBarAgent's items) and swallows the mouse
// press and release that land on it, with an event tap on the shared tap thread. `NativeIconClickGate` decides which clicks;
// this file only carries the decision out.
//
// The tap never holds the mouse up for long: it looks at a cached frame, and only inside that frame asks Accessibility what
// is under the pointer (measured under a millisecond, 25 ms the first time; anything that fails is passed on untouched).
// Anode's own use of macOS's panel presses its items with Accessibility, not with mouse events, so the tap never sees it.

/// What the tap's callback is handed. It lives for the whole process and only holds the icon weakly, so a callback that is still
/// running when the icon goes away finds nothing instead of a freed object.
private final class NativeIconTapBox {
    static let shared = NativeIconTapBox()
    private let lock = NSLock()
    private weak var _icon: NativeSoundIcon?
    var icon: NativeSoundIcon? {
        get { lock.lock(); defer { lock.unlock() }; return _icon }
        set { lock.lock(); _icon = newValue; lock.unlock() }
    }
}

final class NativeSoundIcon: NativeIconHosting {

    static let identifier = "com.apple.menuextra.sound"

    var onClick: ((CGRect) -> Void)?

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private let tapPort = TapPortBox()
    private let lock = NSLock()
    private var cachedFrame: CGRect?
    /// The process that owns macOS's menu bar items: only an element of this one counts as the icon.
    private var trustedPid: pid_t = 0
    private var gate = NativeIconClickGate()   // touched only on the tap thread
    private let systemWide: AXUIElement = {
        let e = AXUIElementCreateSystemWide()
        // The tap waits for this answer, so it is short: a click that cannot be confirmed in time is passed on to macOS.
        AXUIElementSetMessagingTimeout(e, 0.05)
        return e
    }()

    deinit { stop() }

    private func remember(_ frame: CGRect?, pid: pid_t) -> CGRect? {
        lock.lock(); cachedFrame = frame; trustedPid = pid; lock.unlock()
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
            for item in (Self.attribute(group, kAXChildrenAttribute) as? [AXUIElement]) ?? [] where Self.identifier(of: item) == Self.identifier {
                var r = CGRect.zero
                if let v = Self.attribute(item, "AXFrame"), CFGetTypeID(v) == AXValueGetTypeID() { AXValueGetValue(v as! AXValue, .cgRect, &r) }   // type checked
                return remember(r.isEmpty ? nil : r, pid: pid)
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
        guard tap == nil, AXIsProcessTrusted() else { return }
        if let frame = currentFrame() { _ = underPointerIsTheIcon(CGPoint(x: frame.midX, y: frame.midY)) }
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        // The session tap, an active one: only Accessibility is needed, which Anode already asks for.
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: nativeIconTapCallback,
                                        userInfo: Unmanaged.passUnretained(NativeIconTapBox.shared).toOpaque()) else { return }
        NativeIconTapBox.shared.icon = self
        guard let source = CFMachPortCreateRunLoopSource(nil, t, 0) else { return }
        EventTapThread.shared.add(source)
        CGEvent.tapEnable(tap: t, enable: true)
        tapPort.value = t
        tap = t
        tapSource = source
    }

    func stop() {
        if NativeIconTapBox.shared.icon === self { NativeIconTapBox.shared.icon = nil }
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
            lock.lock(); let icon = cachedFrame; lock.unlock()
            let held = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl])
            let point = event.location
            let verdict = gate.decide(type == .leftMouseDown ? .down : .up, at: point, modifiers: !held.isEmpty, icon: icon) {
                underPointerIsTheIcon(point)
            }
            switch verdict {
            case .pass: return true
            case .swallow: return false
            case .swallowAndOpen:
                if let icon { DispatchQueue.main.async { [weak self] in self?.onClick?(icon) } }
                return false
            }
        default:
            return true
        }
    }

    private func underPointerIsTheIcon(_ point: CGPoint) -> Bool {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success, let hit else { return false }
        // The right id is not enough: any app can name an element anything. It must also belong to the process that draws macOS's bar.
        lock.lock(); let expected = trustedPid; lock.unlock()
        var owner: pid_t = 0
        guard expected != 0, AXUIElementGetPid(hit, &owner) == .success, owner == expected else { return false }
        return Self.identifier(of: hit) == Self.identifier
    }
}

private func nativeIconTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                   refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon, let icon = Unmanaged<NativeIconTapBox>.fromOpaque(refcon).takeUnretainedValue().icon else {
        return Unmanaged.passUnretained(event)
    }
    return icon.tapped(type: type, event: event) ? Unmanaged.passUnretained(event) : nil
}

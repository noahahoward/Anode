import AppKit
import CoreGraphics

// ── The tap that swallows all input during a cleaning session ───────────────
//
// An ACTIVE event tap at the head of the HID event stream that asks for every event type (keyboard, mouse, scroll,
// trackpad gestures, media keys) and drops them all, except what `CleanerInputFilter` lets through. It sees an event
// before the system or any app does, so a swallowed key never reaches anything, and with the mouse-moved events dropped the
// pointer cannot move (so hot corners and the Dock cannot be reached either). It runs on `EventTapThread`, never the main
// thread, so a busy main thread cannot hold up the keyboard of the whole Mac.
//
// TWO RULES THAT MATTER MORE THAN THE REST:
//  1. The tap thread switches the tap OFF ITSELF, in the callback, the moment it sees the exit combination. Only then does it
//     tell the main thread. If the main thread were hung, waiting for it would leave every key on the Mac swallowed with no
//     way out.
//  2. If the system disables the tap (it does so to a tap that is too slow) the session is reported as ended. The tap is
//     never re-enabled: a cleaning session that quietly lets input through again behind a black screen is worse than none.

/// The per-session decision, apart from the real tap so it can be tested. Used from the tap thread only.
final class CleanerTapSession {
    enum Notice { case exit, disabled }

    struct Outcome: Equatable {
        var swallow: Bool
        /// Switch the tap off right now, on the tap thread.
        var disableTap: Bool
        /// Tell the main thread (once per session).
        var notice: Notice?
    }

    private let filter: CleanerInputFilter
    private var ending = false

    init(filter: CleanerInputFilter) { self.filter = filter }

    func outcome(for event: CleanerEvent) -> Outcome {
        switch filter.verdict(for: event) {
        case .pass:    return Outcome(swallow: false, disableTap: false, notice: nil)
        case .swallow: return Outcome(swallow: true, disableTap: false, notice: nil)
        case .exit:
            if ending { return Outcome(swallow: true, disableTap: false, notice: nil) }
            ending = true
            return Outcome(swallow: true, disableTap: true, notice: .exit)
        }
    }

    /// The system switched the tap off. Reported once, and not at all if the session is already ending.
    func outcome(forDisabledTap disabled: Bool) -> Outcome {
        guard disabled, !ending else { return Outcome(swallow: false, disableTap: false, notice: nil) }
        ending = true
        return Outcome(swallow: false, disableTap: false, notice: .disabled)
    }
}

final class CleanerInputTap: CleanerInputTapping {

    private let lock = NSLock()
    private var session: CleanerTapSession?
    private var onExit: (() -> Void)?
    private var onDisabled: (() -> Void)?
    private let port = TapPortBox()
    private var source: CFRunLoopSource?

    /// A CGEvent as the filter sees it. Pure given its inputs, for tests.
    static func event(from type: CGEventType, _ cg: CGEvent) -> CleanerEvent {
        switch type {
        case .keyDown, .keyUp, .flagsChanged:
            let kind: CleanerEvent.Kind = type == .keyDown ? .keyDown : (type == .keyUp ? .keyUp : .flagsChanged)
            return CleanerEvent(kind: kind, key: Int(cg.getIntegerValueField(.keyboardEventKeycode)), flags: cg.flags)
        default:
            return CleanerEvent(kind: .other, key: 0, flags: cg.flags)
        }
    }

    func start(filter: CleanerInputFilter, onExit: @escaping () -> Void, onDisabled: @escaping () -> Void) -> Bool {
        stop()
        // Every event type: a mask of all ones. The system's own tap-disabled notices arrive whatever the mask says.
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask.max, callback: cleanerTapCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let s = CFMachPortCreateRunLoopSource(nil, t, 0) else { return false }
        lock.lock()
        session = CleanerTapSession(filter: filter)
        self.onExit = onExit
        self.onDisabled = onDisabled
        lock.unlock()
        port.value = t
        source = s
        EventTapThread.shared.add(s)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func stop() {
        if let t = port.value {
            CGEvent.tapEnable(tap: t, enable: false)
            CFMachPortInvalidate(t)
        }
        if let s = source { EventTapThread.shared.remove(s) }
        port.value = nil
        source = nil
        lock.lock(); session = nil; onExit = nil; onDisabled = nil; lock.unlock()
    }

    deinit { stop() }

    /// Runs on the tap thread: decide, switch the tap off if it was the exit, hand the news to the main thread.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        lock.lock()
        let session = self.session
        let onExit = self.onExit, onDisabled = self.onDisabled
        lock.unlock()
        guard let session else { return pass }

        let outcome: CleanerTapSession.Outcome
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            outcome = session.outcome(forDisabledTap: true)
        } else {
            outcome = session.outcome(for: Self.event(from: type, event))
        }
        if outcome.disableTap, let t = port.value { CGEvent.tapEnable(tap: t, enable: false) }
        switch outcome.notice {
        case .exit?:     if let onExit { DispatchQueue.main.async(execute: onExit) }
        case .disabled?: if let onDisabled { DispatchQueue.main.async(execute: onDisabled) }
        case nil:        break
        }
        return outcome.swallow ? nil : pass
    }
}

private func cleanerTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<CleanerInputTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}

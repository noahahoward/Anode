import AppKit
import ApplicationServices
import PowerKit

// ── The volume keys, while Anode's Sound menu is open ───────────────────────
//
// macOS answers a volume key with its own bubble. With Anode's menu open the menu is the volume control, so the bubble beside it
// is wrong: this takes the three volume keys (and only those) for as long as the menu is open and hands them to the menu. It is
// an event tap on the shared tap thread, made when the menu opens and gone when it closes, so nothing watches the keyboard the
// rest of the time. It looks at the key, never at anything typed.

private let mediaKeyTapCallback: CGEventTapCallBack = { _, type, event, info in
    guard let info else { return Unmanaged.passUnretained(event) }
    let box = Unmanaged<MediaKeyTap.Box>.fromOpaque(info).takeUnretainedValue()
    return box.handle(type: type, event: event) ? Unmanaged.passUnretained(event) : nil
}

final class MediaKeyTap {

    /// What the callback is handed: it holds the handler weakly-enough by being cleared on stop.
    final class Box {
        private let lock = NSLock()
        private var _handler: ((MediaKeyEvent) -> Void)?
        var port: CFMachPort?
        var handler: ((MediaKeyEvent) -> Void)? {
            get { lock.lock(); defer { lock.unlock() }; return _handler }
            set { lock.lock(); _handler = newValue; lock.unlock() }
        }

        /// True: pass the event on. False: it was a volume key and is taken.
        func handle(type: CGEventType, event: CGEvent) -> Bool {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let port { CGEvent.tapEnable(tap: port, enable: true) }
                return true
            }
            guard type.rawValue == 14 /* NX_SYSDEFINED */, let handler,
                  let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8,   // the media keys
                  let key = MediaKeyEvent(data1: ns.data1) else { return true }
            if key.isDown { DispatchQueue.main.async { handler(key) } }
            return false   // the press, the repeats and the release: macOS sees none of them
        }
    }

    private let box = Box()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    /// Without Accessibility there is no tap: the keys then do what macOS does with them.
    func start(_ handler: @escaping (MediaKeyEvent) -> Void) {
        guard tap == nil, AXIsProcessTrusted() else { return }
        box.handler = handler
        let mask = CGEventMask(1 << 14)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                        callback: mediaKeyTapCallback, userInfo: Unmanaged.passUnretained(box).toOpaque()),
              let s = CFMachPortCreateRunLoopSource(nil, t, 0) else { box.handler = nil; return }
        box.port = t
        EventTapThread.shared.add(s)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t; source = s
    }

    func stop() {
        box.handler = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { EventTapThread.shared.remove(source) }
        box.port = nil
        tap = nil; source = nil
    }

    deinit { stop() }
}

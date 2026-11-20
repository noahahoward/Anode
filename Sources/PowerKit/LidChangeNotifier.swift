import Foundation
import IOKit

// ── Lid change notification ─────────────────────────────────────────────────
//
// Always Stay Awake needs to know the moment the lid shuts or opens. Looking once a second wakes the process 60 times
// a minute for as long as the mode runs; the power-management root domain sends a message on every lid change, so the
// process can sleep until one arrives. The watch is only on while Always Stay Awake runs; stopping tears all of it down.

/// Something that calls back, on the main thread, each time the lid shuts or opens.
public protocol LidChangeNotifying: AnyObject {
    /// True between `start` and `stop`.
    var isRunning: Bool { get }
    /// Begin watching; `onChange` is called on the main thread for each lid change. A second `start` while running
    /// does nothing.
    func start(onChange: @escaping () -> Void)
    /// Stop watching and release everything `start` took. Safe to call when not running.
    func stop()
}

/// The real one: a general-interest notification on `IOPMrootDomain`, delivered through a run-loop source on the main
/// run loop (the same registration `ScreenWatch` makes, with the lid message picked out).
public final class IOKitLidChangeNotifier: LidChangeNotifying {

    /// `kIOPMMessageClamshellStateChange` from IOKit/pwr_mgt/IOPM.h: `iokit_family_msg(sub_iokit_powermanagement, 0x100)`
    /// = sys_iokit (0x38 << 26 = 0xE0000000) | sub_iokit_powermanagement (13 << 14 = 0x34000) | 0x100 = 0xE0034100
    /// (checked by compiling the header's macro in C, which prints 0xE0034100).
    /// The header defines it with a function-like macro, which Swift does not import, so the value is written out.
    /// Sent when the lid state (or whether closing it sleeps the Mac) changes.
    static let clamshellStateChange: UInt32 = 0xE003_4100

    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var onChange: (() -> Void)?

    public init() {}

    deinit { stop() }

    public var isRunning: Bool { port != nil }

    public func start(onChange: @escaping () -> Void) {
        guard port == nil else { return }
        guard let newPort = IONotificationPortCreate(kIOMainPortDefault) else { return }
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else {
            IONotificationPortDestroy(newPort)
            return
        }
        defer { IOObjectRelease(root) }
        self.onChange = onChange
        var token: io_object_t = 0
        let status = IOServiceAddInterestNotification(newPort, root, kIOGeneralInterest, { refcon, _, messageType, _ in
            guard messageType == IOKitLidChangeNotifier.clamshellStateChange, let refcon else { return }
            Unmanaged<IOKitLidChangeNotifier>.fromOpaque(refcon).takeUnretainedValue().onChange?()
        }, Unmanaged.passUnretained(self).toOpaque(), &token)
        guard status == KERN_SUCCESS else {
            // No notification: the caller's slow safety poll is then the only watch, which is why it exists.
            self.onChange = nil
            IONotificationPortDestroy(newPort)
            return
        }
        notifier = token
        port = newPort
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(newPort).takeUnretainedValue(), .commonModes)
    }

    public func stop() {
        if notifier != 0 { IOObjectRelease(notifier); notifier = 0 }
        if let port {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
            IONotificationPortDestroy(port)
            self.port = nil
        }
        onChange = nil
    }
}

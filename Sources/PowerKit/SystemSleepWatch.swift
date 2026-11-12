import Foundation
import IOKit
import IOKit.pwr_mgt

/// The Mac's sleep and wake, as two callbacks: a thin wrapper over
/// `IORegisterForSystemPower` with no policy in it. What to do before sleep is
/// the caller's business.
///
/// It NEVER VETOES SLEEP, and it answers every notice that wants an answer,
/// whatever its callbacks do: "may the system sleep?" is answered yes at once,
/// and "the system will sleep" is answered as soon as `willSleep` returns. A
/// `willSleep` that has to wait for something must bound that wait itself —
/// macOS holds sleep until this answer arrives.
///
/// Notices arrive on a private serial queue, never on a run loop. The root
/// helper's main thread sits in `poll` for its whole life and runs no run loop,
/// so a run-loop source on it would never fire.
public final class SystemSleepWatch {

    /// `iokit_common_msg(0x270)`, `(0x280)` and `(0x300)` from
    /// <IOKit/IOMessage.h>. Swift does not import them (they are function-like
    /// macros), so the values are printed from the SDK header and written here.
    static let canSystemSleep: UInt32 = 0xE000_0270
    static let systemWillSleep: UInt32 = 0xE000_0280
    static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private let willSleep: () -> Void
    private let didWake: () -> Void
    private let queue = DispatchQueue(label: "dev.anode.helper.sleep-watch")
    private let onQueue = DispatchSpecificKey<Bool>()

    // Set once in `init`, cleared once in `stop()`, both before or on `queue`.
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    /// Register for the system's sleep and wake. nil when the system will not
    /// register this process.
    public init?(willSleep: @escaping () -> Void, didWake: @escaping () -> Void) {
        self.willSleep = willSleep
        self.didWake = didWake
        queue.setSpecific(key: onQueue, value: true)

        // Unretained: the watch's owner keeps it alive, and `stop()` (run by
        // `deinit` at the latest) deregisters before the pointer can dangle.
        var port: IONotificationPortRef?
        var notifierObject: io_object_t = 0
        let root = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(), &port,
            { refcon, _, message, argument in
                guard let refcon else { return }
                Unmanaged<SystemSleepWatch>.fromOpaque(refcon).takeUnretainedValue()
                    .receive(message, argument)
            },
            &notifierObject)
        // On failure IOKit has already released what it made.
        guard root != MACH_PORT_NULL, let port else { return nil }
        rootPort = root
        notifyPort = port
        notifier = notifierObject
        // Nothing is delivered before this: the notices wait in the port.
        IONotificationPortSetDispatchQueue(port, queue)
    }

    deinit { stop() }

    /// Is this watch registered with the system right now?
    var isRegistered: Bool { onTheQueue { notifyPort != nil } }

    /// Deregister. Safe to call more than once, and from a callback.
    public func stop() {
        onTheQueue {
            guard let port = notifyPort else { return }
            IODeregisterForSystemPower(&notifier)
            // `IORegisterForSystemPower` opened the root power domain; close it.
            IOServiceClose(rootPort)
            IONotificationPortDestroy(port)
            notifyPort = nil
            rootPort = 0
            notifier = 0
        }
    }

    /// On `queue`, so a teardown never overlaps a notice being handled.
    private func onTheQueue<T>(_ body: () -> T) -> T {
        DispatchQueue.getSpecific(key: onQueue) == true ? body() : queue.sync(execute: body)
    }

    private func receive(_ message: UInt32, _ argument: UnsafeMutableRawPointer?) {
        switch message {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.systemWillSleep:
            defer { IOAllowPowerChange(rootPort, Int(bitPattern: argument)) }
            willSleep()
        case Self.systemHasPoweredOn:
            didWake()
        default:
            break
        }
    }
}

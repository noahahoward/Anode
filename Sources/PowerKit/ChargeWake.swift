import Foundation
import IOKit
import IOKit.pwr_mgt

// What the root helper needs to wake the Mac at a time it is given, and to notice that the time has come, behind
// protocols so that the helper's whole control flow can be tested against fakes. Nothing here decides anything.

/// A charge limit to write at a moment, and the wake that was scheduled for it: what the helper holds for
/// `FanCommand.scheduleChargeLimit`.
struct ChargePlan: Equatable {
    /// 20…100.
    var limit: Int
    /// The moment the app gave: when the limit is to be raised.
    var at: Date
    /// The wake as it was handed to the system, whole seconds (the system keeps no fractions). Cancelling needs the
    /// same date again, so it is kept exactly.
    var wakeAt: Date
}

/// The system's scheduled power events, as far as this helper uses them: a wake, under the helper's own name.
public protocol PowerEventScheduler: AnyObject {
    /// Ask the system to wake the Mac at `date`. True when it took the event.
    func scheduleWake(at date: Date) -> Bool
    /// Remove the wake this scheduler made for exactly `date`. True when it is gone: removed, or never there.
    func cancelWake(at date: Date) -> Bool
}

/// The real one: `IOPMSchedulePowerEvent` and `IOPMCancelScheduledPowerEvent`, which need root and put an event in the
/// system's own list, kept on disk, under the helper's name. Only the helper's `main` builds one, and no test calls it.
public final class SystemPowerEventScheduler: PowerEventScheduler {

    /// The name the events carry, so that cancelling takes away only this helper's and never one the person made.
    public static let owner = "dev.anode.app.chargelimit"
    /// "wake": the Mac comes out of sleep; it does not power on from off.
    private static let type = kIOPMAutoWake as CFString

    public init() {}

    public func scheduleWake(at date: Date) -> Bool {
        IOPMSchedulePowerEvent(date as CFDate, Self.owner as CFString, Self.type) == kIOReturnSuccess
    }

    public func cancelWake(at date: Date) -> Bool {
        let r = IOPMCancelScheduledPowerEvent(date as CFDate, Self.owner as CFString, Self.type)
        // An event that is not there is as cancelled as one that was removed.
        return r == kIOReturnSuccess || r == kIOReturnNotFound
    }
}

/// A one-shot timer that goes by the wall clock: it fires when the clock reaches the moment, including when the Mac
/// slept through it (on waking), which a timeout counted in the machine's own running time does not. No polling: it
/// is one event, and `fire` runs on a queue of its own and must only hand the news to the helper's loop.
public protocol WallClockTimer: AnyObject {
    /// Fire `fire` once, when the wall clock reaches `date`; at once if it already has. Replaces an earlier arming.
    func arm(at date: Date, _ fire: @escaping () -> Void)
    /// Stop it, if it has not fired.
    func disarm()
}

/// The real one, on a dispatch timer with a wall-clock deadline.
public final class DispatchWallClockTimer: WallClockTimer {
    private let queue = DispatchQueue(label: "dev.anode.helper.plan-timer")
    private let lock = NSLock()
    private var source: DispatchSourceTimer?

    public init() {}

    public func arm(at date: Date, _ fire: @escaping () -> Void) {
        let seconds = date.timeIntervalSince1970
        let whole = seconds.rounded(.down)
        let deadline = DispatchWallTime(timespec: timespec(tv_sec: Int(whole),
                                                           tv_nsec: Int((seconds - whole) * 1_000_000_000)))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(wallDeadline: deadline, leeway: .milliseconds(100))
        timer.setEventHandler(handler: fire)
        lock.lock()
        let old = source
        source = timer
        lock.unlock()
        old?.cancel()
        timer.resume()
    }

    public func disarm() {
        lock.lock()
        let old = source
        source = nil
        lock.unlock()
        old?.cancel()
    }
}

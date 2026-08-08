import Foundation
import IOKit
import IOKit.usb

/// Attributes power to attached USB devices by measuring the step they cause.
///
/// There is no USB power rail on this hardware. Every SMC rail was compared
/// across an attach/detach transition and the largest port-family mover was
/// `PP0b` at +0.90 W against an actual draw of 11.55 W — 8%. The power appears
/// only in the totals, which all step together.
///
/// But "no rail" is not "not measurable". Attaching a device produces a clean,
/// repeatable step in whole-system power:
///
///     nothing attached    PSTR 10.04 W
///     iPhone attached     PSTR 21.59 W     +11.55 W
///
/// and CPU and GPU moved DOWN across that same transition, so the step is not
/// compute. Measuring it is the same discriminator that identified the CPU, GPU,
/// memory and storage rails — drive one thing, watch what moves — with the
/// attach event supplying the stimulus instead of a deliberate experiment.
///
/// WHAT THIS CAN AND CANNOT KNOW, because the difference must reach the UI:
///
///  * A device that attaches WHILE THE APP IS WATCHING gets a measured cost: the
///    difference between settled power before and settled power after.
///  * A device already attached at launch has no observable step, so its cost is
///    UNKNOWN. It is reported as attached-but-unmeasured, never as zero and never
///    as a guess. Unplugging it later supplies the step and the answer.
///
/// The measurement is deliberately conservative. A step is only accepted when the
/// machine is otherwise quiet enough for the step to be attributable, because a
/// build kicking off at the same moment as a plug would otherwise be credited to
/// the phone.
public final class USBPowerTracker {

    public struct Device: Equatable {
        public let id: UInt64
        public let name: String
        /// Watts this device drew, measured from the step it caused when it
        /// attached. Nil when it was already present at launch — genuinely
        /// unknown, and shown as such.
        public let watts: Double?
        public var isMeasured: Bool { watts != nil }
    }

    /// Seconds to let power settle either side of a transition. A charger
    /// negotiates and ramps; sampling immediately catches the ramp, not the level.
    private let settle: TimeInterval = 4
    /// A step smaller than this is not distinguishable from ordinary variation in
    /// PSTR, which swings several watts on its own.
    private let minimumStep = 0.8
    /// Above this, something other than the plug happened.
    private let maximumStep = 100.0

    private let lock = NSLock()
    private var devices: [UInt64: Device] = [:]
    /// Power sampled just before a pending attach, awaiting its settled pair.
    private var pending: [UInt64: (name: String, before: Double, at: Date)] = [:]

    public init() {}

    /// Currently attached devices, newest first.
    public var attached: [Device] {
        lock.lock(); defer { lock.unlock() }
        return Array(devices.values).sorted { ($0.watts ?? -1) > ($1.watts ?? -1) }
    }

    /// Total measured USB draw. Devices whose cost is unknown contribute NOTHING
    /// rather than an assumed value — the ledger may not carry a number nobody
    /// measured.
    public var measuredWatts: Double {
        attached.compactMap(\.watts).reduce(0, +)
    }

    /// True when something is attached whose cost was never observed, so the UI
    /// can say the figure is a floor rather than a total.
    public var hasUnmeasuredDevices: Bool {
        attached.contains { !$0.isMeasured }
    }

    // ── Enumeration ─────────────────────────────────────────────────────────

    /// Names and registry ids of attached USB devices. Unprivileged.
    public static func enumerate() -> [(id: UInt64, name: String)] {
        var out: [(UInt64, String)] = []
        var it: io_iterator_t = 0
        guard let match = IOServiceMatching(kIOUSBDeviceClassName) else { return [] }
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(it) }

        while case let svc = IOIteratorNext(it), svc != 0 {
            defer { IOObjectRelease(svc) }
            var eid: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(svc, &eid) == KERN_SUCCESS else { continue }
            let name = (IORegistryEntryCreateCFProperty(
                svc, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String) ?? "USB device"
            out.append((eid, name))
        }
        return out
    }

    // ── Step measurement ────────────────────────────────────────────────────

    /// Feed the current whole-system watts every tick. Detects attach and detach
    /// by diffing the enumeration, and closes out a pending measurement once
    /// power has settled.
    ///
    /// `systemQuiet` should be false when the machine is doing something that
    /// could itself move power by watts — a step measured through a compile is
    /// not a measurement of the device.
    public func update(systemWatts: Double, systemQuiet: Bool, now: Date = Date()) {
        let present = Dictionary(uniqueKeysWithValues: Self.enumerate().map { ($0.id, $0.name) })

        lock.lock(); defer { lock.unlock() }

        // Close out any pending attach whose settle window has elapsed.
        for (id, p) in pending where now.timeIntervalSince(p.at) >= settle {
            pending.removeValue(forKey: id)
            guard present[id] != nil else { continue }   // unplugged again mid-window
            let step = systemWatts - p.before
            let credible = systemQuiet && step >= minimumStep && step <= maximumStep
            devices[id] = Device(id: id, name: p.name, watts: credible ? step : nil)
        }

        // New arrivals: record the pre-attach level and wait for it to settle.
        for (id, name) in present where devices[id] == nil && pending[id] == nil {
            // `systemWatts` here is the level BEFORE this device ramps up, which
            // is what makes the step meaningful. A device that appears in the same
            // tick it draws power would bias the baseline upward and under-report.
            pending[id] = (name, systemWatts, now)
        }

        // Departures.
        for id in devices.keys where present[id] == nil { devices.removeValue(forKey: id) }
        for id in pending.keys where present[id] == nil { pending.removeValue(forKey: id) }
    }
}

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

    /// Where a device's cost came from. This reaches the UI, because "measured a
    /// moment ago" and "measured last Tuesday" are different claims.
    public enum Provenance: String, Equatable {
        /// Step observed on this attach, in this session.
        case measured
        /// Step observed on a PREVIOUS attach or detach and remembered. Charge
        /// state changes, so this is a prior figure, not a current one.
        case remembered
        /// Attached before the app started and never seen before, so no step has
        /// ever been observed for it.
        case unknown
    }

    public struct Device: Equatable {
        public let id: UInt64
        public let name: String
        /// Watts. Nil only when provenance is `.unknown`.
        public let watts: Double?
        public let provenance: Provenance
        public var isMeasured: Bool { provenance == .measured }
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
    /// A departure whose settled after-level is still being waited for.
    private var departing: [(name: String, before: Double, at: Date)] = []

    /// What each device cost last time a step was observed for it, by name.
    ///
    /// This is what makes the common case work at all. A device plugged in
    /// before the app launched produces no attach step, so without memory its
    /// cost is permanently unknowable — which is the state the user actually
    /// finds themselves in, since phones tend to already be charging.
    ///
    /// Keyed by NAME, not registry id: the id is assigned per enumeration and
    /// changes between plugs, so it cannot carry knowledge across them.
    private var remembered: [String: Double] = [:]
    private let defaults: UserDefaults
    private static let storeKey = "com.anode.usb.deviceWatts.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let d = defaults.dictionary(forKey: Self.storeKey) as? [String: Double] {
            remembered = d
        }
    }

    private func remember(_ name: String, _ watts: Double) {
        // Averaged with what is already known rather than overwritten. A phone's
        // draw tapers as it fills — 11.55 W measured at one charge level, 8.7 W an
        // hour later on the same device — so any single observation is a snapshot
        // of a moving quantity, and the running mean is a better prior than the
        // most recent accident of timing.
        remembered[name] = remembered[name].map { ($0 + watts) / 2 } ?? watts
        defaults.set(remembered, forKey: Self.storeKey)
    }

    /// Currently attached devices, newest first.
    public var attached: [Device] {
        lock.lock(); defer { lock.unlock() }
        return Array(devices.values).sorted { ($0.watts ?? -1) > ($1.watts ?? -1) }
    }

    /// Total attributable USB draw, including remembered figures.
    ///
    /// Devices with `.unknown` provenance contribute nothing — the ledger may
    /// not carry a number nobody has ever measured.
    public var measuredWatts: Double {
        attached.compactMap(\.watts).reduce(0, +)
    }

    /// True when something attached has never had a step observed, so the total
    /// is a floor rather than a complete figure.
    public var hasUnmeasuredDevices: Bool {
        attached.contains { $0.provenance == .unknown }
    }

    /// True when any contributing figure is remembered rather than measured now.
    public var hasRememberedDevices: Bool {
        attached.contains { $0.provenance == .remembered }
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

        // ── close out attaches whose settle window has elapsed ──────────────
        for (id, p) in pending where now.timeIntervalSince(p.at) >= settle {
            pending.removeValue(forKey: id)
            guard present[id] != nil else { continue }        // unplugged mid-window
            let step = systemWatts - p.before
            if systemQuiet, step >= minimumStep, step <= maximumStep {
                remember(p.name, step)
                devices[id] = Device(id: id, name: p.name, watts: step, provenance: .measured)
            } else if let known = remembered[p.name] {
                devices[id] = Device(id: id, name: p.name, watts: known, provenance: .remembered)
            } else {
                devices[id] = Device(id: id, name: p.name, watts: nil, provenance: .unknown)
            }
        }

        // ── close out detaches: the step DOWN is what the device HAD cost ───
        //
        // This is what rescues the common case. A device already attached when
        // the app launched produces no attach step, so its cost would otherwise
        // be permanently unknowable — and a phone is usually already charging by
        // the time anyone opens a battery monitor. Unplugging it finally supplies
        // the step, and remembering that means the NEXT time it appears the app
        // can say what it costs immediately.
        var stillDeparting: [(name: String, before: Double, at: Date)] = []
        for d in departing {
            guard now.timeIntervalSince(d.at) >= settle else { stillDeparting.append(d); continue }
            let drop = d.before - systemWatts        // power fell when it left
            if systemQuiet, drop >= minimumStep, drop <= maximumStep {
                remember(d.name, drop)
            }
        }
        departing = stillDeparting

        // ── new arrivals ───────────────────────────────────────────────────
        for (id, name) in present where devices[id] == nil && pending[id] == nil {
            pending[id] = (name, systemWatts, now)
        }

        // ── departures ─────────────────────────────────────────────────────
        for (id, dev) in devices where present[id] == nil {
            devices.removeValue(forKey: id)
            departing.append((dev.name, systemWatts, now))
        }
        for id in pending.keys where present[id] == nil { pending.removeValue(forKey: id) }
    }

    /// Adopt devices that were already attached when the tracker started, using
    /// whatever was remembered about them. Called once, before the first update.
    ///
    /// Without this the first session after a launch shows nothing for a phone
    /// that is plainly charging, which reads as a broken feature rather than an
    /// honest absence of evidence.
    public func adoptExisting() {
        lock.lock(); defer { lock.unlock() }
        for (id, name) in Self.enumerate() where devices[id] == nil {
            if let known = remembered[name] {
                devices[id] = Device(id: id, name: name, watts: known, provenance: .remembered)
            } else {
                devices[id] = Device(id: id, name: name, watts: nil, provenance: .unknown)
            }
        }
    }
}

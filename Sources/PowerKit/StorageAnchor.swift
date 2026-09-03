import Darwin
import Foundation

/// The two storage inputs that are NOT the NVMe log page.
///
/// `NVMeHealth` reads hardware state and needs no memory to do it. These two do:
/// swap is a sysctl no other file in PowerKit reads, and a write RATE only exists
/// relative to a remembered starting point. Neither is a power measurement, but
/// both are registry inputs, and the registry lives here.

// ── Swap ────────────────────────────────────────────────────────────────────

/// Backing-store usage, from `vm.swapusage`.
///
/// Moved down from `MachineInfo` — which lives in the app, because none of it is a
/// power measurement — so that `MetricRegistry`, and therefore the menu bar and the
/// CLI, can read it too.
///
/// NOT YET THE ONLY READER: `MachineInfo.swap()` in `Sources/AnodeApp/SystemInventory.swift`
/// still carries its own copy of this sysctl, because that file was owned by another
/// change when this landed. Collapsing it to `typealias Swap = SwapUsage.Sample` plus
/// `static func swap() -> Swap? { SwapUsage.read() }` is the follow-up, and it is
/// worth doing: two readers of one kernel struct is exactly the desync this
/// project's tests exist to catch.
public enum SwapUsage {

    public struct Sample: Equatable {
        public let totalBytes: UInt64
        public let usedBytes: UInt64
        public let isEncrypted: Bool

        public init(totalBytes: UInt64, usedBytes: UInt64, isEncrypted: Bool) {
            self.totalBytes = totalBytes
            self.usedBytes = usedBytes
            self.isEncrypted = isEncrypted
        }
    }

    /// A machine that has never swapped reports a total of zero, which is a
    /// measurement rather than a missing one. nil is reserved for the sysctl
    /// itself failing — the only case that means "we could not look".
    ///
    /// MEASURED: 0.97 µs per call (20,000 calls in 19 ms, `-O`). That is why the
    /// metric provider reads it live on every widget refresh instead of carrying a
    /// cached copy that could be a tick stale.
    public static func read() -> Sample? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return Sample(totalBytes: usage.xsu_total,
                      usedBytes: usage.xsu_used,
                      isEncrypted: usage.xsu_encrypted != 0)
    }
}

// ── The first-launch write anchor ───────────────────────────────────────────

/// Where this machine's write rate is measured FROM.
///
/// `dataUnitsWritten` is a lifetime counter: it answers "how much has ever been
/// written", and dividing it by anything the drive reports gives a rate over a
/// period nobody chose. By `powerOnHours` least of all — that field is controller
/// ACTIVE-STATE residency, 4.6 % of calendar time on this machine, so a per-hour
/// figure built on it is wrong by ~22x. A rate needs two readings and the wall-clock
/// interval between them, and the first reading has to come from somewhere: the
/// first launch that ever saw this drive.
///
/// WHY 30 DAYS, measured:
///
///   * Short windows run high and converge slowly. This machine's this-boot rate
///     stood at 2.14x its lifetime rate after 29.8 h of uptime, and was still
///     1.64x it at 51.7 h. A day of history does not describe a day.
///   * The events that dominate a month of writes arrive on a week/month cadence:
///     one OS update accounted for 23 % of an entire boot's writes. A window
///     shorter than that cadence reports whether you happened to catch one, not
///     what the machine does.
///
/// Persistence is one plist value in UserDefaults — the shape `ChargeLimitLearner`
/// uses for the learned charge limit, and `USBPowerTracker` for its remembered
/// watts. NOT `HistoryStore`: this is a setting-sized fact about the machine, two
/// scalars written once, and the SQLite store's schema, retention and fold have
/// nothing to offer it.
///
/// Thread-safe. `observe` runs once at launch off the main thread while `rate` is
/// read by a metric provider on the main thread on every widget refresh.
public final class SSDWriteAnchor {

    /// The app's anchor. Tests inject their own `UserDefaults` instead.
    public static let shared = SSDWriteAnchor()

    /// BOTH halves under ONE key. Written as two keys, a crash between the two
    /// `set` calls leaves a byte count paired with the previous date — a plausible
    /// anchor describing nothing. One dictionary is one plist write.
    static let storeKey = "com.anode.storage.writeAnchor.v1"

    /// The gate. Nothing is published until the anchor is at least this old.
    public static let minimumSpan: TimeInterval = 30 * 24 * 3600

    public struct Anchor: Equatable {
        public let bytesWritten: UInt64
        public let startedAt: Date
    }

    private let lock = NSLock()
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func anchor() -> Anchor? {
        lock.lock(); defer { lock.unlock() }
        return stored()
    }

    /// Establish the anchor, or re-establish it on a different device.
    ///
    /// Called ONCE PER LAUNCH, and deliberately not from the metric provider:
    /// "first launch" is something the app does, not something a renderer does, and
    /// a provider that wrote would anchor this machine merely because something
    /// drew a menu — including a menu drawn by the test suite.
    ///
    /// A lifetime counter that FELL is not this drive. The counter is monotonic for
    /// a given controller, so a smaller reading means the hardware underneath
    /// changed: a replaced SSD, a logic-board swap, or this preferences file
    /// restored onto another machine. The stored anchor describes a drive that is
    /// not here, and the delta against it is negative. Re-anchoring restarts the
    /// 30-day window on the drive that IS here, which is the honest cost of a new
    /// device — a negative write rate would be the dishonest one.
    ///
    /// A backwards CLOCK does not re-anchor. A boot before NTP settles reads
    /// minutes or hours in the past, and paying 30 days of window for that would be
    /// absurd; `rate` already withholds everything while the span is negative. Only
    /// a stored date a FULL GATE ahead of `now` — a wrong year, not a skew — is
    /// treated as unusable.
    @discardableResult
    public func observe(bytesWritten: UInt64, now: Date = Date()) -> Anchor {
        lock.lock(); defer { lock.unlock() }
        if let a = stored(),
           bytesWritten >= a.bytesWritten,
           now >= a.startedAt.addingTimeInterval(-Self.minimumSpan) {
            return a
        }
        defaults.set(["bytes": Int(clamping: bytesWritten), "startedAt": now],
                     forKey: Self.storeKey)
        return Anchor(bytesWritten: bytesWritten, startedAt: now)
    }

    /// Bytes per day, or nil.
    ///
    /// nil means "no honest figure yet", never zero: no anchor, an anchor younger
    /// than the gate, or a counter that has gone backwards since it was set. A
    /// genuine 0 — thirty days in which nothing was written — IS published, because
    /// that is a measurement.
    ///
    /// Reads never write. See `observe`.
    public func rate(bytesWritten: UInt64, now: Date = Date()) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let a = stored(), bytesWritten >= a.bytesWritten else { return nil }
        let span = now.timeIntervalSince(a.startedAt)
        guard span >= Self.minimumSpan else { return nil }
        return Double(bytesWritten - a.bytesWritten) / (span / 86_400)
    }

    /// How much longer the gate has to run, or nil once it has opened (or when
    /// there is no anchor to wait on). The storage pane says this in words —
    /// "measuring since 4 August" — rather than showing a dash nobody can explain.
    public func gateRemaining(now: Date = Date()) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard let a = stored() else { return nil }
        let left = Self.minimumSpan - now.timeIntervalSince(a.startedAt)
        return left > 0 ? left : nil
    }

    /// Both halves or neither: a dictionary missing one is a half-written anchor,
    /// and a half-written anchor is no anchor.
    ///
    /// The byte count is stored as `Int`, which is exact to 9.2 × 10¹⁸ — nine
    /// exabytes, against the 7.31 × 10¹² this drive has written. (A `Double` would
    /// have been exact only to 9 PB; still ample, but there is no reason to spend
    /// the headroom.)
    private func stored() -> Anchor? {
        guard let d = defaults.dictionary(forKey: Self.storeKey),
              let bytes = d["bytes"] as? Int, bytes >= 0,
              let started = d["startedAt"] as? Date else { return nil }
        return Anchor(bytesWritten: UInt64(bytes), startedAt: started)
    }
}

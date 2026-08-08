import Foundation

/// A time-bounded cache over one full temperature sweep.
///
/// `Sensors.temperatures()` re-reads every classified SMC key through the
/// AppleSMC user client. MEASURED on this machine (MacBook Pro, M5 Pro, macOS
/// 27): 256 readings, 90 ms of wall clock and 10 ms of CPU per call, because
/// each key costs two IOKit round trips and the connection is serialized. The
/// Sensors pane called it inline on the main thread on every UI tick — 2 s by
/// default — so having that pane open blocked the UI for 90 ms out of every
/// 2 s and burned 0.5% of a core, in an app whose whole-process idle cost with
/// the window closed is 0.19% of a core.
///
/// `SystemMetrics` already refuses to touch the SMC more than once every 5 s,
/// but its cache holds only the CPU mean, the GPU mean and the fans — not the
/// per-key list the pane draws. This is the same rule for that list, and
/// `interval` defaults to the same 5 s so the two surfaces cannot disagree
/// about how old a temperature is.
///
/// The clock and the sweep are injectable so the caching rule can be tested
/// without an SMC: whether a sweep is issued must not depend on what hardware
/// the test happens to run on.
///
/// Shaped like `NetworkAttribution` on purpose — `latest`, `age`, and a refresh
/// the caller drives off the main thread — because it is the same problem: an
/// expensive sampler that a view wants to read on every tick.
public final class SensorCache: @unchecked Sendable {

    /// Guards the cached list. Held only for the assignment and the reads, never
    /// across a sweep.
    private let state = NSLock()
    /// Serializes sweeps. Separate from `state` so that a second caller waiting
    /// its turn does not also block anything trying to draw the previous list.
    private let gate = NSLock()

    private let interval: TimeInterval
    private let now: () -> Date
    private let sweep: () -> [SensorReading]

    private var readings: [SensorReading]?
    private var readAt: Date?

    public init(interval: TimeInterval = 5,
                now: @escaping () -> Date = Date.init,
                sweep: @escaping () -> [SensorReading] = Sensors.temperatures) {
        self.interval = interval
        self.now = now
        self.sweep = sweep
    }

    /// The last sweep, or nil before the first one has landed.
    ///
    /// nil is NOT an empty reading list: "we have not read the SMC yet" and
    /// "this machine reports no readable sensors" are different facts, and a
    /// caller that renders them the same way is asserting something it has not
    /// measured.
    public var latest: [SensorReading]? {
        state.lock(); defer { state.unlock() }
        return readings
    }

    /// How old the cached list is, or nil when there is no list yet.
    public var age: TimeInterval? {
        state.lock(); defer { state.unlock() }
        return readAt.map { now().timeIntervalSince($0) }
    }

    /// True when a sweep is due — no reading yet, or one older than `interval`.
    public var isStale: Bool {
        state.lock(); defer { state.unlock() }
        return staleLocked()
    }

    /// Sweep unless the cache is still fresh, and return what it holds afterwards.
    ///
    /// NEVER call this on the main thread: a sweep is 90 ms of blocked IOKit.
    @discardableResult
    public func refreshIfStale() -> [SensorReading]? {
        guard isStale else { return latest }

        gate.lock(); defer { gate.unlock() }
        // Re-checked after taking the gate: two callers can both see a stale
        // cache, and the second must not issue a second sweep of a key set the
        // first has just re-read.
        guard isStale else { return latest }

        let fresh = sweep()
        let at = now()
        state.lock()
        readings = fresh
        readAt = at
        state.unlock()
        return fresh
    }

    private func staleLocked() -> Bool {
        guard let readAt else { return true }
        return now().timeIntervalSince(readAt) >= interval
    }
}

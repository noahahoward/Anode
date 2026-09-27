import Foundation

/// How the load right now compares with what this machine usually draws.
public enum LoadBand: String, Codable, CaseIterable, Sendable {
    case quiet, normal, elevated, heavy

    /// Ratio of the current draw to the baseline.
    static func of(ratio r: Double) -> LoadBand {
        switch r {
        case ..<0.7: return .quiet
        case ..<1.3: return .normal
        case ...2.0: return .elevated
        default:     return .heavy
        }
    }

    var isHigh: Bool { self == .elevated || self == .heavy }
}

/// A learned typical duration. A plain mean while there are few samples, then an
/// exponentially weighted one, so an old habit gives way to a new one without
/// one odd session rewriting it.
public struct DurationStat: Codable, Equatable, Sendable {
    public private(set) var mean_s: Double = 0
    public private(set) var count: Int = 0

    mutating func add(_ seconds: Double) {
        count += 1
        mean_s = count <= 5 ? mean_s + (seconds - mean_s) / Double(count)
                            : 0.8 * mean_s + 0.2 * seconds
    }
}

/// What the lifetime model says about the next few hours: the draw this machine
/// usually settles at, the draw now, and how long the difference is expected to
/// last. Fed to `DrainEstimate.forecastTimeToEmpty`.
public struct DrainPrior: Equatable, Sendable {
    public let baseline_W: Double
    public let current_W: Double
    /// Seconds for the current departure from baseline to fade. `.infinity` when
    /// there is no history to say it will — the current load is then assumed to
    /// continue, which is exactly what the app did before this model existed.
    public let tau_s: Double
    public let band: LoadBand
    /// The app that dominated when this stretch began, if one did.
    public let appName: String?
}

/// Learns, over the machine's whole life on battery, two things the last hour of
/// drain cannot know:
///
/// 1. **What this machine usually draws.** A time-weighted mean of battery watts
///    while awake and unplugged. In WATTS, not %/hr, because the pack loses
///    capacity with age and the same afternoon costs more percent each year —
///    the conversion happens at display time against today's capacity.
///    Old data fades with a 30-day half-life, and every macOS update starts a
///    new baseline (an OS can change idle draw by more than any habit does);
///    the previous one answers until the new one has two hours behind it.
///
/// 2. **How long a departure from that usually lasts** — per band, and per app
///    when one app dominated. This is what keeps a render on battery from being
///    averaged away: while the heavy load runs, the forecast holds it for as
///    long as such loads usually last here, and longer if this one already has.
///
/// Value type, owned by the sampling queue; persisted as JSON beside the history
/// database. Transient state (the rolling window, the open excursion) is not
/// persisted — after a relaunch it is simply re-observed.
public struct LifetimeDrainModel: Codable {

    // ── tuning ──────────────────────────────────────────────────────────────
    public static let halfLife: TimeInterval = 30 * 86_400
    /// Awake battery seconds before a baseline is trusted.
    public static let warmSeconds: TimeInterval = 2 * 3600
    /// Ignored after unplugging: the draw then belongs to whatever was running
    /// on AC, and every estimator in this app already distrusts it.
    public static let settleAfterUnplug: TimeInterval = 120
    public static let windowSpan: TimeInterval = 300
    /// A normal-band wobble fades fast, so in ordinary use the forecast is the
    /// baseline — the point of the whole model.
    public static let normalTau: TimeInterval = 600
    public static let endHold: TimeInterval = 120
    public static let minExcursion: TimeInterval = 180
    public static let minSamples = 3
    public static let appShare = 0.4
    public static let appFreshness: TimeInterval = 90
    public static let maxApps = 32
    /// How fast this session's own level earns a say in where the load is
    /// expected to settle: after this long it counts as much as the lifetime.
    public static let sessionPull: TimeInterval = 3600
    /// A tick longer than this is a gap, not a measurement.
    static let maxInterval: TimeInterval = 60

    public struct TopApp: Equatable, Sendable {
        public let key: String, name: String, share: Double
        public init(key: String, name: String, share: Double) {
            self.key = key; self.name = name; self.share = share
        }
    }

    struct AppStat: Codable, Equatable {
        var stat = DurationStat()
        var name: String
        var lastUsed: Date
    }

    struct Excursion {
        var band: LoadBand
        let start: TimeInterval
        var appKey: String?
        var appName: String?
        var endingSince: TimeInterval?
    }

    // ── persisted ───────────────────────────────────────────────────────────
    public static let currentVersion = 1
    var version = LifetimeDrainModel.currentVersion
    public let machineModel: String
    public let designCapacity_mAh: Double
    public private(set) var osBuild: String
    var weightedJoules = 0.0
    var weightSeconds = 0.0
    /// Undecayed awake seconds under this OS build — whether the baseline is
    /// learned, as opposed to how much each part of it counts.
    var totalSeconds = 0.0
    var lastDecay: Date?
    var previousBaseline_W: Double?
    /// Keyed "high" / "quiet" — see `excursionStat(high:)`.
    var bands: [String: DurationStat] = [:]
    var apps: [String: AppStat] = [:]
    /// Every display-on second on battery since the model first ran, and the
    /// joules drawn in them. Unlike the baseline: no half-life, and no restart on
    /// a macOS update. Optional so a file saved before these existed still loads;
    /// such a file seeds them from its baseline, which is the same data barely
    /// decayed.
    var allTimeJoules: Double?
    var allTimeSeconds: Double?

    // ── transient ───────────────────────────────────────────────────────────
    private var ring: [(awake: TimeInterval, watts: Double)] = []
    private var excursion: Excursion?
    private var unplugAwake: TimeInterval?
    private var lastTopApp: (app: TopApp, seen: TimeInterval)?
    /// This session's draw outside heavy stretches — see `sessionPull`.
    private var sessionJoules = 0.0
    private var sessionSeconds = 0.0

    enum CodingKeys: String, CodingKey {
        case version, machineModel, designCapacity_mAh, osBuild, weightedJoules,
             weightSeconds, totalSeconds, lastDecay, previousBaseline_W, bands, apps,
             allTimeJoules, allTimeSeconds
    }

    public init(machineModel: String, designCapacity_mAh: Double, osBuild: String) {
        self.machineModel = machineModel
        self.designCapacity_mAh = designCapacity_mAh
        self.osBuild = osBuild
    }

    // ── reading ─────────────────────────────────────────────────────────────

    /// This build's learned mean, warm or not. nil before any data.
    public var baseline_W: Double? {
        weightSeconds > 0 ? weightedJoules / weightSeconds : nil
    }

    /// Mean battery watts over all the display-on time on battery the app has
    /// ever recorded — what time left is divided by. nil until there are
    /// `warmSeconds` of it, when one session would still be most of the mean.
    public var allTimeMean_W: Double? {
        guard let s = allTimeSeconds, s >= Self.warmSeconds,
              let j = allTimeJoules, j > 0 else { return nil }
        return j / s
    }

    /// The lifetime baseline to forecast against: this build's once warm, else
    /// the one before the last OS update, else none.
    public var lifetimeBaseline_W: Double? {
        if totalSeconds >= Self.warmSeconds, let b = baseline_W { return b }
        return previousBaseline_W
    }

    /// How long stretches above (or below) normal usually last. One figure per
    /// side, not per band: the baseline moves as heavy use is folded into it, so
    /// the same render can start out "heavy" and later read as "elevated", and
    /// splitting its history between the two would leave neither with enough.
    public func excursionStat(high: Bool) -> DurationStat? { bands[Self.side(high)] }
    static func side(_ high: Bool) -> String { high ? "high" : "quiet" }
    public func appStat(_ key: String) -> DurationStat? { apps[key]?.stat }
    public var appCount: Int { apps.count }

    public func prior(awake: TimeInterval) -> DrainPrior? {
        guard let b = lifetimeBaseline_W, b > 0 else { return nil }
        guard !ring.isEmpty else {
            let target = (b * Self.sessionPull + sessionJoules) / (Self.sessionPull + sessionSeconds)
            return DrainPrior(baseline_W: target, current_W: target, tau_s: Self.normalTau,
                              band: .normal, appName: nil)
        }
        let current = ring.reduce(0) { $0 + $1.watts } / Double(ring.count)
        let band = LoadBand.of(ratio: median / b)
        // Where the load is expected to settle: the lifetime baseline, shrunk
        // toward this session's own non-heavy level as the session lengthens.
        // A fresh session is the lifetime's to call; five hours of reading at
        // 6 W when the lifetime says 9 are evidence the lifetime must yield to.
        let target = (b * Self.sessionPull + sessionJoules) / (Self.sessionPull + sessionSeconds)
        let age = excursion.map { max(0, awake - $0.start) } ?? 0
        let appName = excursion?.appName
        let tau: Double
        switch band {
        case .normal:
            tau = Self.normalTau
        case .quiet:
            tau = max(learned(high: false) ?? Self.normalTau, age)
        case .elevated, .heavy:
            let byApp = excursion?.appKey.flatMap { apps[$0] }.flatMap {
                $0.stat.count >= Self.minSamples ? $0.stat.mean_s : nil
            }
            tau = max(byApp ?? learned(high: true) ?? .infinity, age)
        }
        return DrainPrior(baseline_W: target, current_W: current, tau_s: tau,
                          band: band, appName: appName)
    }

    private func learned(high: Bool) -> Double? {
        guard let s = bands[Self.side(high)], s.count >= Self.minSamples else { return nil }
        return s.mean_s
    }

    /// Median of the window: which band the load is in. A median, not a mean,
    /// so a twenty-second spike cannot hold the window above a threshold for the
    /// five minutes it takes to scroll out and be learned as a heavy stretch.
    private var median: Double {
        let sorted = ring.map(\.watts).sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    // ── learning ────────────────────────────────────────────────────────────

    /// Start a new baseline when macOS has changed underneath it. Excursion
    /// lengths are kept: they describe how this person works, not the OS.
    public mutating func adopt(osBuild build: String) {
        guard build != osBuild else { return }
        if totalSeconds >= Self.warmSeconds, let b = baseline_W { previousBaseline_W = b }
        weightedJoules = 0; weightSeconds = 0; totalSeconds = 0; lastDecay = nil
        osBuild = build
    }

    /// One tick. `interval` is the tick's own span (0 after a gap), `awake` the
    /// awake clock, `now` the calendar clock the half-life runs on.
    ///
    /// `displayOn` false is treated as a gap. The awake clock runs through dark
    /// wakes — the display off, the machine doing maintenance, hundreds of times
    /// a night — and a watt or two of that is not anyone using the Mac. Measured
    /// on this machine: 292 dark wakes on battery in one day, 2.4 h of them,
    /// against 68 min of real use.
    public mutating func observe(batteryWatts watts: Double, onBattery: Bool,
                                 displayOn: Bool = true,
                                 interval: TimeInterval, awake: TimeInterval,
                                 now: Date, topApp: TopApp?) {
        guard onBattery else { resetTransient(); unplugAwake = nil; return }
        guard displayOn else { resetTransient(); return }
        guard interval > 0, interval <= Self.maxInterval, watts.isFinite, watts > 0 else {
            resetTransient(); return
        }
        if unplugAwake == nil { unplugAwake = awake }
        if let app = topApp, app.share >= Self.appShare { lastTopApp = (app, awake) }
        guard let unplug = unplugAwake, awake - unplug >= Self.settleAfterUnplug else { return }

        if allTimeSeconds == nil {
            allTimeJoules = weightedJoules
            allTimeSeconds = weightSeconds
        }
        allTimeJoules! += watts * interval
        allTimeSeconds! += interval

        decay(to: now)
        weightedJoules += watts * interval
        weightSeconds += interval
        totalSeconds += interval

        ring.append((awake, watts))
        ring.removeAll { $0.awake <= awake - Self.windowSpan }
        track(awake: awake, now: now)
        if !(excursion?.band.isHigh ?? false) {
            sessionJoules += watts * interval
            sessionSeconds += interval
        }
    }

    private mutating func decay(to now: Date) {
        if let last = lastDecay {
            let gap = now.timeIntervalSince(last)
            // Backwards means the clock was set back; weight is not invented.
            if gap > 0 {
                let f = pow(0.5, gap / Self.halfLife)
                weightedJoules *= f
                weightSeconds *= f
            }
        }
        lastDecay = now
    }

    private mutating func track(awake: TimeInterval, now: Date) {
        guard let b = lifetimeBaseline_W, b > 0 else { return }
        let ratio = median / b
        let band = LoadBand.of(ratio: ratio)

        if var e = excursion {
            // Straight across to the other side: that stretch is over.
            if e.band.isHigh != band.isHigh && band != .normal {
                finish(e, at: awake, now: now)
                excursion = nil
            } else {
                if band.isHigh, e.band == .elevated, band == .heavy { e.band = .heavy }
                if e.appKey == nil, let fresh = freshApp(near: e.start) {
                    e.appKey = fresh.key; e.appName = fresh.name
                }
                let back = e.band.isHigh ? ratio < 1.15 : ratio > 0.85
                if back {
                    let since = e.endingSince ?? awake
                    e.endingSince = since
                    if awake - since >= Self.endHold {
                        finish(e, at: since, now: now)
                        excursion = nil
                        return
                    }
                } else {
                    e.endingSince = nil
                }
                excursion = e
                return
            }
        }
        guard band != .normal else { return }
        let app = freshApp(near: awake)
        excursion = Excursion(band: band, start: awake, appKey: app?.key,
                              appName: app?.name, endingSince: nil)
    }

    private func freshApp(near t: TimeInterval) -> TopApp? {
        guard let last = lastTopApp, abs(last.seen - t) <= Self.appFreshness else { return nil }
        return last.app
    }

    private mutating func finish(_ e: Excursion, at end: TimeInterval, now: Date) {
        let length = end - e.start
        guard length >= Self.minExcursion else { return }
        bands[Self.side(e.band.isHigh), default: DurationStat()].add(length)
        guard let key = e.appKey else { return }
        var s = apps[key] ?? AppStat(name: e.appName ?? key, lastUsed: now)
        s.stat.add(length)
        s.lastUsed = now
        apps[key] = s
        if apps.count > Self.maxApps,
           let oldest = apps.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            apps[oldest] = nil
        }
    }

    private mutating func resetTransient() {
        ring.removeAll()
        excursion = nil
        sessionJoules = 0
        sessionSeconds = 0
    }
}

// ── persistence ─────────────────────────────────────────────────────────────

extension LifetimeDrainModel {

    /// Beside the history database and the discharge trend, which are the same
    /// kind of thing: what this machine's battery has done, outliving the process.
    public static func fileURL(fileManager fm: FileManager = .default) -> URL? {
        guard let base = fm.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("Anode/lifetime-drain.json")
    }

    /// nil — a cold start — when nothing is saved, it cannot be read, it is a
    /// format this build does not know, or it was learned on a different Mac.
    /// The last one matters because Migration Assistant copies Application
    /// Support wholesale, and another machine's watts are not this one's.
    public static func load(from url: URL, machineModel: String,
                            designCapacity_mAh: Double) -> LifetimeDrainModel? {
        guard let data = try? Data(contentsOf: url),
              let m = try? JSONDecoder().decode(LifetimeDrainModel.self, from: data),
              m.version == currentVersion,
              m.machineModel == machineModel,
              abs(m.designCapacity_mAh - designCapacity_mAh) < 1 else { return nil }
        return m
    }

    /// Atomic, and only as often as the discharge trend is saved — see
    /// `BatteryDischargeTrend.Persisted.save` for why never per tick.
    @discardableResult
    public func save(to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(self) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// This Mac's identity as the model records it.
    public static func hostModel() -> String { sysctlString("hw.model") ?? "unknown" }
    public static func hostOSBuild() -> String { sysctlString("kern.osversion") ?? "unknown" }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}

// ── what the sampling tick feeds it ─────────────────────────────────────────

extension LifetimeDrainModel {

    /// Watts leaving the pack. Battery-side first — current × voltage from the
    /// gauge, the same quantity the discharge tier measures — so the baseline
    /// and the rates it is compared with share a basis; the system-side figures
    /// only when the gauge reports no discharge current.
    public static func batteryWatts(state: Battery.State?, measured_W: Double?,
                                    smoothed_W: Double) -> Double {
        if let s = state, s.amperage_mA < 0, s.voltage_mV > 0 {
            return Double(-s.amperage_mA) * Double(s.voltage_mV) / 1e6
        }
        return measured_W ?? smoothed_W
    }
}

extension LifetimeDrainModel.TopApp {
    /// The app drawing the largest share of attributed power on this sweep,
    /// keyed the way `app_energy` keys it. Only full ticks carry apps, so this
    /// is opportunistic — see `LifetimeDrainModel.appFreshness`.
    public static func dominant(in apps: [AppDrain]) -> LifetimeDrainModel.TopApp? {
        let total = apps.reduce(0) { $0 + max($1.watts, 0) }
        guard total > 0, let top = apps.max(by: { $0.watts < $1.watts }) else { return nil }
        return .init(key: top.identity.bundleID ?? top.name, name: top.name,
                     share: top.watts / total)
    }
}

import Foundation

/// Widget-bindable metrics.
///
/// Stats (the app this replaces) hardcodes its menu bar widgets per module, so every
/// new reading needs new widget code. Here the coupling is inverted: anything that
/// can produce a number registers a `MetricDescriptor` plus a provider closure under
/// a stable string ID, and every widget renderer automatically gains it with zero new
/// code. Widgets persist the ID string across relaunches, which makes raw values API:
/// NEVER rename an ID that has shipped — retire it and the widget bound to it will
/// degrade to a placeholder instead of crashing.
///
/// PRODUCT RULE: watts are never user-visible. `MetricUnit` deliberately has no
/// `.watts` case, so a watts metric cannot even be *described* here, let alone
/// rendered. Internal watts must be divided by `BatteryScale.joulesPerPercent`
/// (×3600) into %/hr before they reach this layer — `PowerMonitor.Snapshot` already
/// exposes those conversions.

/// Stable identity for a displayable metric. Hash/equality is the raw string, so IDs
/// survive round-trips through UserDefaults and across app versions.
public struct MetricID: Hashable, RawRepresentable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

extension MetricID {
    // Built-in battery metrics. The strings are the persistence format — frozen.
    public static let batteryDrain       = MetricID("battery.drain.pctHr")
    public static let batteryPercent     = MetricID("battery.percent")
    public static let batteryTimeLeft    = MetricID("battery.timeRemaining.min")
    public static let gpuDrain           = MetricID("battery.gpu.pctHr")
    public static let unattributedShare  = MetricID("battery.unattributed.share")
    public static let processCoverage    = MetricID("battery.coverage")

    // System utilisation. Named for what they measure: "how busy", never "how much
    // battery" — only the joule path answers that.
    public static let cpuUsage           = MetricID("system.cpu.percent")
    public static let memoryUsage        = MetricID("system.memory.percent")
    public static let gpuUsage           = MetricID("system.gpu.percent")
    public static let networkThroughput  = MetricID("system.network.bytesPerSec")
    public static let networkDown        = MetricID("system.network.down")
    public static let networkUp          = MetricID("system.network.up")
    /// Disk is bytes per second, not a percentage, and the IDs say so. There is no
    /// honest read%/write% on this hardware — the full measurement is in the
    /// `DiskActivity` doc comment, and the short version is that the only
    /// read/write-split timer IOKit offers sums concurrent requests and was
    /// measured at 1394% on a 16-deep queue.
    public static let diskActivity       = MetricID("system.disk.bytesPerSec")
    public static let diskRead           = MetricID("system.disk.read")
    public static let diskWrite          = MetricID("system.disk.write")
    public static let cpuTemperature     = MetricID("sensors.cpu.celsius")
    public static let gpuTemperature     = MetricID("sensors.gpu.celsius")
    public static let fanSpeed           = MetricID("sensors.fan.rpm")

    /// Health of the sampling loop itself, not of the machine. A tick dropped
    /// because the previous one was still running is time this app measured
    /// nothing over, and that has to be visible somewhere.
    public static let samplerDrops       = MetricID("sampler.dropped.count")

    /// The collapsible group widget binds to no single metric — it shows them all.
    /// It still needs an ID so widget configs stay uniformly addressable.
    public static let groupPlaceholder   = MetricID("widget.group")
}

/// Display units. Formatting lives here so every surface (menu bar, table, tooltip)
/// prints a given unit identically. Non-finite input always formats as "—": every
/// upstream signal is undocumented and can hand us NaN, and a menu bar that says
/// "nan %/hr" is exactly the startup breakage this app exists to avoid.
public enum MetricUnit: CaseIterable {
    case percentPerHour, percent, minutes, celsius, rpm, count, ratio, bytes, bytesPerSecond

    public func format(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        switch self {
        case .percentPerHour:
            // One decimal below 10 ("4.1%/hr"), none above — menu bar space is scarce
            // and a tenth of a %/hr is noise once the drain is in double digits.
            // No space before the unit: it reads as one quantity, not two tokens,
            // and it buys back a pixel column in the menu bar.
            return String(format: abs(value) >= 10 ? "%.0f%%/hr" : "%.1f%%/hr", value)
        case .percent:
            // Takes 0–100. (For 0–1 fractions use .ratio.)
            return String(format: "%.0f%%", value)
        case .minutes:
            // Deliberately NOT quantised. A coarser display (15 min buckets past
            // 4 h) was tried and reverted: it does nothing for the failure that
            // actually reached a user — a 25 h reading replaced by 5 h one second
            // later — because that is the ESTIMATE moving, not the rendering. And
            // it costs the property that has caught several real bugs here, that
            // charge / rate and the displayed time can be checked against each
            // other by hand. Fix the estimate, not the digits.
            let sign = value < 0 ? "-" : ""
            let m = Int(abs(value).rounded())
            return m >= 60 ? String(format: "%@%dh %02dm", sign, m / 60, m % 60)
                           : "\(sign)\(m)m"
        case .celsius:
            return String(format: "%.0f°C", value)
        case .rpm:
            return String(format: "%.0f rpm", value)
        case .count:
            return String(format: "%.0f", value)
        case .ratio:
            // Takes a 0–1 fraction and displays it as a percentage. Kept distinct from
            // .percent so providers never have to guess which scale a consumer wants.
            return String(format: "%.0f%%", value * 100)
        case .bytesPerSecond:
            // Menu bar width is scarce: no space before the unit, no decimal above
            // 100 — "1.2MB/s", "340KB/s", "12MB/s".
            var bps = abs(value)
            if bps < 1024 { return String(format: "%.0fB/s", bps) }
            let bpsUnits = ["KB", "MB", "GB", "TB"]
            var bi = -1
            repeat { bps /= 1024; bi += 1 } while bps >= 1024 && bi < bpsUnits.count - 1
            return String(format: bps >= 100 ? "%.0f%@/s" : "%.1f%@/s", bps, bpsUnits[bi])
        case .bytes:
            let sign = value < 0 ? "-" : ""
            var v = abs(value)
            if v < 1024 { return sign + String(format: "%.0f B", v) }
            let units = ["KB", "MB", "GB", "TB", "PB"]
            var i = -1
            repeat { v /= 1024; i += 1 } while v >= 1024 && i < units.count - 1
            return sign + String(format: v >= 100 ? "%.0f %@" : "%.1f %@", v, units[i])
        }
    }
}

/// One reading. `text` is pre-formatted by the provider (normally via
/// `MetricUnit.format`) so renderers never re-derive display strings. `isEstimate`
/// marks the estimate-vs-measurement boundary — renderers surface it as the same "*"
/// the app already uses for an uncalibrated total. Never hide it.
public struct MetricValue {
    public let value: Double
    public let text: String
    public let isEstimate: Bool
    /// Overrides the descriptor's short title for this reading only. A metric whose
    /// MEANING changes with state needs a label that changes with it: "Drain" is
    /// wrong while the pack is charging or sitting on AC, and a stale label beside a
    /// correct number is worse than no label.
    public let label: String?

    public init(value: Double, text: String, isEstimate: Bool, label: String? = nil) {
        self.label = label
        self.value = value
        self.text = text
        self.isEstimate = isEstimate
    }

    /// Convenience: format `text` from the unit so value and text cannot disagree.
    public init(_ value: Double, unit: MetricUnit, isEstimate: Bool, label: String? = nil) {
        self.init(value: value, text: unit.format(value), isEstimate: isEstimate, label: label)
    }
}

public struct MetricDescriptor {
    public let id: MetricID
    public let title: String            // "Battery drain"
    public let shortTitle: String       // "Drain" — for a cramped menu bar
    public let unit: MetricUnit
    public let category: String         // "Battery", later "CPU", "Sensors"
    /// Higher is worse (drain) vs higher is better (time remaining) — drives colour.
    public let higherIsWorse: Bool

    /// May a menu bar widget bind to this?
    ///
    /// Almost everything can, and that generality is the point of the registry:
    /// every metric the app gains is automatically available to every widget.
    /// The exception is a metric that exists to fill a spot in the WINDOW and
    /// would only duplicate other widgets in the menu bar — `system.disk.bytesPerSec`
    /// packs read and write into one string for the sidebar row, and offering it
    /// beside the separate Read and Write widgets gave three ways to say two
    /// numbers, the combined one being the worst formatted of them.
    public let bindable: Bool

    public init(id: MetricID, title: String, shortTitle: String, unit: MetricUnit,
                category: String, higherIsWorse: Bool, bindable: Bool = true) {
        self.id = id
        self.title = title
        self.shortTitle = shortTitle
        self.unit = unit
        self.category = category
        self.higherIsWorse = higherIsWorse
        self.bindable = bindable
    }
}

/// Registry of everything a widget can bind to.
///
/// Threading: `update(with:)` arrives from the sampling queue; `value(for:)` /
/// `descriptors()` are read on the main thread every widget refresh. All state is
/// behind one non-recursive lock, and providers are ALWAYS invoked outside it —
/// every built-in provider re-enters the registry to read the latest snapshot, and
/// holding the lock across that call would deadlock. Consequence: a provider that is
/// being replaced concurrently may run its old closure one last time. Harmless.
public final class MetricRegistry {

    public static let shared: MetricRegistry = {
        let r = MetricRegistry()
        r.registerBatteryMetrics()
        r.registerSystemMetrics()
        r.registerSamplerMetrics()
        return r
    }()

    private let lock = NSLock()
    /// Registration order, preserved so a widget-config UI lists metrics stably.
    private var order: [MetricID] = []
    private var entries: [MetricID: (descriptor: MetricDescriptor,
                                     provider: () -> MetricValue?)] = [:]
    private var snapshot: PowerMonitor.Snapshot?
    private var system: SystemMetrics.Snapshot?

    public init() {}

    /// Registering an already-present ID replaces descriptor and provider in place
    /// (keeping its position) — a richer module may take over a metric later.
    public func register(_ d: MetricDescriptor, provider: @escaping () -> MetricValue?) {
        lock.lock()
        defer { lock.unlock() }
        if entries[d.id] == nil { order.append(d.id) }
        entries[d.id] = (d, provider)
    }

    /// Everything a menu bar widget may bind to, in registration order.
    ///
    /// This is the widget picker's list, and it deliberately EXCLUDES metrics
    /// marked `bindable: false` — see `MetricDescriptor.bindable`. `value(for:)`
    /// still serves them, so a window surface that wants one is unaffected;
    /// only the offer to put it in the menu bar is withdrawn.
    public func descriptors() -> [MetricDescriptor] {
        allDescriptors().filter(\.bindable)
    }

    /// Every registered metric, bindable or not. For diagnostics that need to
    /// enumerate the whole registry rather than the menu of choices.
    public func allDescriptors() -> [MetricDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { entries[$0]?.descriptor }
    }

    public func descriptor(for id: MetricID) -> MetricDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        return entries[id]?.descriptor
    }

    /// nil for an unknown ID *and* for a known metric with no data yet (first tick
    /// hasn't landed, or on AC for time-remaining). Renderers must treat nil as
    /// "placeholder", never as an error.
    public func value(for id: MetricID) -> MetricValue? {
        lock.lock()
        let provider = entries[id]?.provider
        lock.unlock()
        return provider?()   // outside the lock — see class doc
    }

    /// Push a new snapshot; providers registered against it recompute lazily on the
    /// next `value(for:)`. Snapshot is a value type, so readers on other threads see
    /// either the old or the new one whole, never a torn mix.
    public func update(with snapshot: PowerMonitor.Snapshot) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
    }

    /// Push the latest utilisation readings. Kept separate from the power snapshot
    /// because the two come from different samplers on different cadences — and
    /// because utilisation is not power.
    public func update(system: SystemMetrics.Snapshot) {
        lock.lock()
        self.system = system
        lock.unlock()
    }

    public func latestSystem() -> SystemMetrics.Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return system
    }

    public func latestSnapshot() -> PowerMonitor.Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    // ── Built-in battery metrics ────────────────────────────────────────────────

    /// Everything the battery pipeline can honestly display today. All providers are
    /// nil until the first `update(with:)` — widgets show a placeholder for the first
    /// couple of seconds rather than a stale or invented number.
    /// Utilisation and sensor metrics. Each is nil until its first reading, so a
    /// widget bound to something this machine lacks (no fans, no discrete GPU)
    /// renders a placeholder rather than a zero that looks like a measurement.
    public func registerSystemMetrics() {
        func pct(_ id: MetricID, _ title: String, _ short: String, _ cat: String,
                 _ get: @escaping (SystemMetrics.Snapshot) -> Double?) {
            register(MetricDescriptor(id: id, title: title, shortTitle: short,
                                      unit: .percent, category: cat, higherIsWorse: true)) { [weak self] in
                guard let s = self?.latestSystem(), let v = get(s) else { return nil }
                return MetricValue(v, unit: .percent, isEstimate: false)
            }
        }
        pct(.cpuUsage, "CPU usage", "CPU", "CPU") { $0.cpu?.total }
        pct(.memoryUsage, "Memory used", "RAM", "Memory") { $0.memory?.usedPercent }
        pct(.gpuUsage, "GPU usage", "GPU", "GPU") { $0.gpu?.utilization }

        func net(_ id: MetricID, _ title: String, _ short: String,
                 _ get: @escaping (NetworkThroughput.Sample) -> Double) {
            register(MetricDescriptor(id: id, title: title, shortTitle: short,
                                      unit: .bytesPerSecond, category: "Network",
                                      higherIsWorse: false)) { [weak self] in
                guard let n = self?.latestSystem()?.network else { return nil }
                return MetricValue(get(n), unit: .bytesPerSecond, isEstimate: false)
            }
        }
        net(.networkThroughput, "Network throughput", "Net") { $0.totalPerSec }
        net(.networkDown, "Network down", "Down") { $0.bytesInPerSec }
        net(.networkUp, "Network up", "Up") { $0.bytesOutPerSec }

        func disk(_ id: MetricID, _ title: String, _ short: String,
                  _ get: @escaping (DiskActivity.Sample) -> Double) {
            register(MetricDescriptor(id: id, title: title, shortTitle: short,
                                      unit: .bytesPerSecond, category: "Disk",
                                      higherIsWorse: false)) { [weak self] in
                guard let d = self?.latestSystem()?.disk else { return nil }
                return MetricValue(get(d), unit: .bytesPerSecond, isEstimate: false)
            }
        }
        disk(.diskRead, "Disk read", "Read") { $0.bytesReadPerSec }
        disk(.diskWrite, "Disk write", "Write") { $0.bytesWrittenPerSec }

        register(MetricDescriptor(
            id: .diskActivity, title: "Disk activity", shortTitle: "Disk",
            unit: .bytesPerSecond, category: "Disk", higherIsWorse: false,
            // Sidebar row only. As a widget it duplicated the Read and Write
            // widgets and read worse than either.
            bindable: false
        )) { [weak self] in
            guard let d = self?.latestSystem()?.disk else { return nil }
            // Read and write in one string, because which direction the traffic is
            // going is most of what you want to know from a disk row — a machine
            // reading 500 MB/s and a machine writing it are doing different things.
            // Both halves go through `MetricUnit.bytesPerSecond` rather than a
            // second formatter, so this can never disagree with the `.diskRead` and
            // `.diskWrite` widgets about how a given rate is spelled.
            // The per-second suffix is dropped from BOTH halves and the slash is
            // the only one in the string. Spelled in full this read
            // "1.5MB/s/340KB/s" — three slashes, two of which are part of a unit
            // and one of which is the divider, and nothing tells them apart at a
            // glance. The row is labelled "Disk" and sits beside Network, which is
            // also a rate; per-second is the assumption a reader already has, and
            // spending three separators to restate it costs more than it says.
            let unit = MetricUnit.bytesPerSecond
            func rate(_ v: Double) -> String {
                let s = unit.format(v)
                return s.hasSuffix("/s") ? String(s.dropLast(2)) : s
            }
            return MetricValue(value: d.totalPerSec,
                               text: rate(d.bytesReadPerSec) + "/" + rate(d.bytesWrittenPerSec),
                               isEstimate: false)
        }

        func temp(_ id: MetricID, _ title: String, _ short: String,
                  _ get: @escaping (SystemMetrics.Snapshot) -> Double?) {
            register(MetricDescriptor(id: id, title: title, shortTitle: short,
                                      unit: .celsius, category: "Sensors",
                                      higherIsWorse: true)) { [weak self] in
                guard let s = self?.latestSystem(), let v = get(s) else { return nil }
                return MetricValue(v, unit: .celsius, isEstimate: false)
            }
        }
        // "CPU°", not "Temp". The pair has to be read side by side in a menu bar,
        // and a tester's screenshot showed exactly why the asymmetry fails:
        //
        //     CPU 14%   RAM 54%   GPU 25%   Temp 49°C   GPU° 44°C
        //
        // "Temp" next to "GPU°" does not read as the CPU's temperature — it reads
        // as some other, unlabelled temperature, and the obvious conclusion is
        // that CPU temperature is missing. It was never missing; it was the one
        // widget whose label did not say whose reading it was. Every other short
        // title in this registry names its subject, and this was the exception.
        temp(.cpuTemperature, "CPU temperature", "CPU\u{00B0}") { $0.cpuTemperature }
        temp(.gpuTemperature, "GPU temperature", "GPU\u{00B0}") { $0.gpuTemperature }

        register(MetricDescriptor(
            id: .fanSpeed, title: "Fan speed", shortTitle: "Fan",
            unit: .rpm, category: "Sensors", higherIsWorse: true
        )) { [weak self] in
            // Fastest fan, since that is the one you can hear. A fanless machine
            // returns nil rather than 0 — absent and idle are different claims.
            guard let fans = self?.latestSystem()?.fans, !fans.isEmpty else { return nil }
            return MetricValue(fans.map(\.currentRPM).max() ?? 0, unit: .rpm, isEstimate: false)
        }
    }

    /// The displayed drain rate, the time remaining, and where they came from,
    /// pushed in by whoever owns the DrainRateEstimator.
    ///
    /// Without this the menu bar computed its own figures from instantaneous
    /// power while the window computed different ones from observed discharge,
    /// and the two disagreed on screen — reported by the user as a widget and a
    /// card three inches apart showing different drain and different time left.
    /// They are answers to the same question and there is only one right one, so
    /// there is now one source.
    ///
    /// `source` rides along because a figure measured from the pack's own discharge
    /// integral and a figure inferred from this instant's power draw are not the
    /// same claim, and the renderer is where that difference has to become visible.
    public private(set) var displayedRate: (pctHr: Double, timeRemaining_hr: Double?,
                                            source: DrainEstimate.Source)?

    public func update(displayedRate: (pctHr: Double, timeRemaining_hr: Double?,
                                       source: DrainEstimate.Source)?) {
        lock.lock(); defer { lock.unlock() }
        self.displayedRate = displayedRate
    }

    public func registerBatteryMetrics() {
        register(MetricDescriptor(
            id: .batteryDrain, title: "Battery rate", shortTitle: "Drain",
            unit: .percentPerHour, category: "Battery", higherIsWorse: true
        )) { [weak self] in
            guard let s = self?.latestSnapshot() else { return nil }
            // Charging is not negative drain, it is gain, and the label changes with
            // it. Reporting "drain" while the pack is filling is just wrong — and
            // macOS itself often has no estimate here (verified: pmset reported
            // "(no estimate)" at 73% while charging), so we compute it.
            if s.direction == .charging, let rate = s.batteryRate_pctHr {
                return MetricValue(value: rate,
                                   text: "+" + MetricUnit.percentPerHour.format(rate),
                                   isEstimate: false, label: "Charge")
            }
            if s.direction == .acIdle {
                return MetricValue(value: 0, text: "AC", isEstimate: false, label: "Power")
            }
            // The SHARED figure when one has been published — the same number the
            // window shows — falling back to instantaneous power only before the
            // first one arrives.
            let shared = self?.displayedRate
            let rate = shared?.pctHr ?? s.smoothed_pctHr
            // The "*" means "this is inferred, not measured". A rate that came from
            // the battery's own discharge accumulator is measured end to end, and
            // no SMC gain enters it, so the marker drops. Everything else here is
            // modelled from power draw and keeps it — including a calibrated SMC
            // total, which is a well-calibrated MODEL of what the pack is losing
            // and not a reading of it.
            return MetricValue(rate, unit: .percentPerHour,
                               isEstimate: shared?.source != .discharge)
        }

        register(MetricDescriptor(
            id: .batteryPercent, title: "Battery charge", shortTitle: "Batt",
            unit: .percent, category: "Battery", higherIsWorse: false
        )) { [weak self] in
            guard let st = self?.latestSnapshot()?.state else { return nil }
            return MetricValue(Double(st.percent), unit: .percent, isEstimate: false)
        }

        register(MetricDescriptor(
            id: .batteryTimeLeft, title: "Time remaining", shortTitle: "Left",
            unit: .minutes, category: "Battery", higherIsWorse: false
        )) { [weak self] in
            guard let s = self?.latestSnapshot() else { return nil }
            // Our projection beats macOS's SBS figure (which is nil on AC anyway —
            // sentinel 65535 is already scrubbed by Battery.state()). On AC there is
            // no honest number: return nil and let the widget show "—". Shared
            // first, so the widget and the card cannot disagree about how long the
            // battery has left.
            //
            // EVERY line below is a projection, and all of them are marked as one.
            //
            // The first branch used to drop the "*" when the rate came from the
            // discharge accumulator, on the grounds that such a rate is measured
            // end to end. The rate is. The TIME is not: it extrapolates that rate
            // across a future nobody has measured, and the future is where all the
            // error lives — the same 30-minute window that makes this figure
            // stable is exactly what makes it lag a real change by minutes.
            //
            // So an unmarked time-to-empty asserted, in the one place this app has
            // to say it, that a prediction was a measurement. Nobody reads a
            // missing asterisk as "the rate behind this was measured"; they read
            // it as "this is a fact". Under this project's own rule — unmeasured
            // must never be presented as measured — that was the sharpest defect
            // on screen.
            //
            // The provenance distinction is NOT lost. It moves to where there is
            // room to state it in words rather than punctuation: the glance card
            // prints "measured drain" / "estimated from draw" / "no estimate yet"
            // beneath the headline. `battery.drain` still drops the marker when
            // its rate is measured, because a rate genuinely is.
            if let shared = self?.displayedRate, let hr = shared.timeRemaining_hr,
               hr.isFinite, hr > 0 {
                return MetricValue(hr * 60, unit: .minutes, isEstimate: true)
            }
            if let hr = s.projectedRuntime_hr() {
                return MetricValue(hr * 60, unit: .minutes, isEstimate: true)
            }
            if let m = s.state?.timeRemaining_min {
                return MetricValue(Double(m), unit: .minutes, isEstimate: true)
            }
            return nil
        }

        register(MetricDescriptor(
            id: .gpuDrain, title: "GPU drain", shortTitle: "GPU",
            unit: .percentPerHour, category: "Battery", higherIsWorse: true
        )) { [weak self] in
            // Measured: the one live IOReport energy rail on this hardware. nil when
            // IOReport is unavailable — do not fall back to a guess.
            guard let p = self?.latestSnapshot()?.gpu_pctHr else { return nil }
            return MetricValue(p, unit: .percentPerHour, isEstimate: false)
        }

        register(MetricDescriptor(
            id: .unattributedShare, title: "Unattributed power", shortTitle: "Unattr",
            unit: .ratio, category: "Battery", higherIsWorse: true
        )) { [weak self] in
            // Ledger honesty surfaced as a metric: the residual is printed, never
            // redistributed. Derived from the smoothed total, so always an estimate.
            //
            // Nil — "—" — on a light tick, where no attribution was attempted at
            // all. This read exactly 1.0 on every tick the window spent hidden:
            // "100% of your battery is unexplained", from the one number whose job
            // is to say how much of it we can explain, and marked an estimate as
            // though the 1.0 were a rounding of something measured. Calling it an
            // estimate does not make an unasked question an answer.
            //
            // `residualShare` is already nil there; the guard is restated here so
            // this provider cannot be re-pointed at some other residual without
            // the question being asked again.
            guard let s = self?.latestSnapshot(), s.isFullSample,
                  let share = s.residualShare else { return nil }
            return MetricValue(share, unit: .ratio, isEstimate: true)
        }

        register(MetricDescriptor(
            id: .processCoverage, title: "Process coverage", shortTitle: "Cov",
            unit: .ratio, category: "Battery", higherIsWorse: false
        )) { [weak self] in
            // Fraction of pids whose rusage we could actually read (~63% unprivileged;
            // the rest are root-owned EPERM). Measured, not estimated.
            //
            // A light tick sweeps no processes, so the snapshot carries 0 because
            // nothing was ATTEMPTED — and rendered bare that says "we can see 0% of
            // your processes", which is a claim about our own honesty that we never
            // measured. Nil is the only true answer for a tick that did not look.
            guard let s = self?.latestSnapshot(), s.isFullSample else { return nil }
            return MetricValue(s.coverage, unit: .ratio, isEstimate: false)
        }
    }

    /// How the sampler itself is doing.
    ///
    /// Not a reading of the machine, which is why it lives apart from the battery
    /// and utilisation families — but it is the context every other number needs:
    /// a tick that was dropped is a span of time this app measured nothing over,
    /// and it must be countable rather than inferred from a gap in the graph.
    public func registerSamplerMetrics() {
        register(MetricDescriptor(
            id: .samplerDrops, title: "Dropped samples", shortTitle: "Drops",
            unit: .count, category: "Sampler", higherIsWorse: true
        )) { [weak self] in
            // Nil until the sampler has reported once, like every other metric —
            // "not running yet" is not "running cleanly". After that a genuine 0
            // is displayed as 0, because zero drops IS the measurement.
            guard let n = self?.droppedSamples else { return nil }
            return MetricValue(Double(n), unit: .count, isEstimate: false)
        }
    }

    /// Ticks the sampling gate turned away because the previous one was still in
    /// flight. Pushed by whoever owns the gate, on the same cadence as the samples
    /// themselves, so the count a widget shows is never older than the last tick.
    public private(set) var droppedSamples: Int?

    public func update(droppedSamples: Int) {
        lock.lock(); defer { lock.unlock() }
        self.droppedSamples = droppedSamples
    }
}

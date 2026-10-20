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
    /// The drain of the last few minutes, as its own metric. `batteryDrain` is the
    /// rate the time left is divided by; this is what the machine is doing NOW.
    public static let batteryDrainNow    = MetricID("battery.drainNow.pctHr")
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

    // Storage. Swap is under Memory because that is the question it answers —
    // swap is where memory pressure spills, not a property of the disk it lands
    // on — and the rest come off the NVMe health log page.
    //
    // These strings are the persistence format, exactly like the ones above. A
    // widget config and a saved panel order both store the raw string, so
    // renaming a shipped one silently unbinds every widget bound to it.
    public static let swapUsed           = MetricID("storage.swap.used")
    public static let writePerDay        = MetricID("storage.write.perDay")
    public static let ssdHealth          = MetricID("storage.ssd.health")
    public static let ssdLifeUsed        = MetricID("storage.ssd.lifeUsed")
    public static let ssdWritten         = MetricID("storage.ssd.written")
    public static let ssdRead            = MetricID("storage.ssd.read")
    public static let ssdSpare           = MetricID("storage.ssd.spare")

    // THERE IS NO POWER-ON HOURS METRIC, and that is deliberate. The NVMe field
    // is controller ACTIVE-STATE residency, measured at 4.6 % of calendar time
    // on this machine — the obvious use for it, dividing a lifetime total to get
    // a rate, is wrong by ~22x. A metric makes that division available to every
    // present and future surface with nothing to stop it, so the figure stays in
    // the storage pane as a row LABELLED for what it is. Do not add it here.

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
    case percentPerHour, percent, minutes, celsius, rpm, count, ratio, bytes,
         bytesPerSecond, bytesPerDay

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
        case .bytesPerDay:
            // DECIMAL divisors — the opposite of `.bytes` directly above, and
            // this is the paragraph to read before "fixing" that.
            //
            // The numerator of this rate comes from exactly one place:
            // `NVMeHealth.Sample.bytesWritten`, which is DATA_UNITS_WRITTEN times
            // 512,000 — decimal units, by the NVMe spec. The storage pane prints
            // that same counter through the same decimal formatter and captions
            // the block "TB above are decimal". A binary rate beside a decimal
            // total is a 1024⁴/1000⁴ = 9.95 % contradiction between two figures a
            // reader divides into each other: "7.31 TB written" spread over the
            // days since the anchor has to come out as the number in the menu
            // bar, or one of them is wrong. It was caught in review once.
            //
            // `.bytes` stays binary and must: it prints memory, caches and volume
            // capacities, where 1024 is what macOS itself shows. The rule is that
            // THE BASIS FOLLOWS THE SOURCE, not the app — and the only source
            // that feeds this unit counts in thousands.
            //
            // One decimal below 10, none above: the `.percentPerHour` rule, not
            // `.bytesPerSecond`'s 100. This figure is a mean over thirty days or
            // more, and "50.0GB/d" spends two of the menu bar's scarce columns
            // asserting a tenth of a gigabyte the measurement does not have.
            //
            // The sign is KEPT (`.bytes` keeps it; `.bytesPerSecond` formats the
            // absolute value). `SSDWriteAnchor` can never publish a negative rate
            // — it re-anchors instead — so a negative arriving here means a
            // caller bypassed it, and printing that as a positive would hide the
            // bug behind a plausible number.
            let sign = value < 0 ? "-" : ""
            var v = abs(value)
            if v < 1000 { return sign + String(format: "%.0fB/d", v) }
            let units = ["KB", "MB", "GB", "TB", "PB"]
            var i = -1
            repeat { v /= 1000; i += 1 } while v >= 1000 && i < units.count - 1
            return sign + String(format: v >= 10 ? "%.0f%@/d" : "%.1f%@/d", v, units[i])
        }
    }
}

extension MetricUnit {

    /// Decimal bytes, for the one source that counts them that way.
    ///
    /// A STATIC FUNCTION AND NOT A CASE: a `MetricUnit` case is offerable to a
    /// menu bar widget, and this is not a display unit anyone chooses — it is the
    /// unit ONE source uses, and only that source's two counters go through it.
    /// (`.bytesPerDay` IS a case, because a per-day rate is something a user picks
    /// off a list; it carries this same basis for the same reason, and the two sit
    /// next to each other so they cannot drift apart.)
    ///
    /// It lives here rather than in the storage pane so that the pane's row, the
    /// `storage.ssd.written` / `storage.ssd.read` metrics and the `anode --metrics`
    /// dump are ONE implementation. Two decimal formatters is the same desync as
    /// one decimal and one binary, only harder to see.
    ///
    /// Two decimals at TB so 7.31 and 14.00 line up in a right-aligned column, and
    /// so the hundredth of a terabyte the drive actually reports survives.
    public static func siBytes(_ bytes: UInt64) -> String {
        let v = Double(bytes)
        if v >= 1e12 { return String(format: "%.2f TB", v / 1e12) }
        if v >= 1e9  { return String(format: "%.1f GB", v / 1e9) }
        if v >= 1e6  { return String(format: "%.1f MB", v / 1e6) }
        return String(format: "%.0f B", v)
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
    /// How bad the reading is, 0 (fine) … 1 (bad), when the metric knows better
    /// than a scale applied to `value` — memory PRESSURE behind a used-percent,
    /// a fan against its own maximum rather than a guessed one. Renderers use it
    /// in place of `WidgetRenderer.normalizedFraction` for colour.
    public var severity: Double? = nil

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
        r.registerStorageMetrics()
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
        // Probed once per call rather than once per descriptor. `NVMeHealth.read()`
        // is cached, so the difference is small, but the answer cannot change
        // halfway down a list either.
        let smart = NVMeHealth.read() != nil
        return allDescriptors().filter(\.bindable)
            .filter { Self.offered($0.id, smart: smart) }
    }

    /// Metrics this MACHINE can answer at all.
    ///
    /// A fanless Mac has no fan speed, and the app should say nothing about fans
    /// rather than say "—" about them. Hiding the Fans tab already followed that
    /// rule; the panel, the widget picker and the panel editor all read
    /// `descriptors()`, so filtering here is what makes them follow it too —
    /// "Fan speed  —" in a list of live figures is still a claim that this machine
    /// has a fan whose speed is currently unknown.
    ///
    /// Same asymmetry as `FanPresence.showsFanTab`, and for the same reason:
    /// `.unknown` KEEPS the row. Withdrawing a real reading on a machine that has
    /// fans is the worse error, and only `.fanless` is evidence.
    static func offered(_ id: MetricID, fans: FanPresence.State = FanPresence.onThisMac,
                        smart: Bool = NVMeHealth.read() != nil) -> Bool {
        if id == .fanSpeed { return FanPresence.showsFanTab(fans) }
        // The same rule as the fan, about drives. No device vends the NVMe SMART
        // user client on an Intel Mac, in a VM, or behind an external bridge, so
        // both of these are permanently unanswerable there — two dashes in a
        // column of live figures, each one a claim that this machine has a drive
        // whose wear is currently unknown.
        //
        // Only the two BINDABLE storage metrics are listed. The four lifetime
        // readings never reach `descriptors()` anyway, and naming them here would
        // make `FanlessSilenceTests.testNoOtherMetricIsWithheldOnAFanlessMachine`
        // — which walks `allDescriptors()` — fail on such a machine for nothing.
        //
        // `storage.swap.used` is NOT here: it is a sysctl every Mac answers.
        if id == .writePerDay || id == .ssdHealth { return smart }
        return true
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
        // The figure is occupancy; the COLOUR is the kernel's pressure verdict —
        // see `MemoryUsage.Sample.pressureSeverity`.
        register(MetricDescriptor(id: .memoryUsage, title: "Memory used", shortTitle: "RAM",
                                  unit: .percent, category: "Memory",
                                  higherIsWorse: true)) { [weak self] in
            guard let m = self?.latestSystem()?.memory else { return nil }
            var v = MetricValue(m.usedPercent, unit: .percent, isEstimate: false)
            v.severity = m.pressureSeverity
            return v
        }
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
        // and this menu bar reading shows exactly why the asymmetry fails:
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
            // THE AVERAGE, which is what the app itself shows largest.
            //
            // This took the fastest fan, on the reasoning that it is the one you
            // can hear. That is a fair argument on its own and it lost to a better
            // one: the window's fan card sets the average in its headline, the
            // bar captions it, and the graph plots it — so a widget reporting the
            // maximum disagreed with every other place the app says "fan speed".
            // On this machine the two fans sit at 2318 and 2500 rpm, so the widget
            // read as though it were simply the second fan.
            //
            // A fanless machine returns nil rather than 0 — absent and idle are
            // different claims.
            guard let fans = self?.latestSystem()?.fans, !fans.isEmpty else { return nil }
            let mean = fans.averageRPM
            var v = MetricValue(mean, unit: .rpm, isEstimate: false)
            // Coloured against the fans' OWN top speed, not a guessed 6000 rpm
            // that is 7826 on one model and something else on the next.
            let load = fans.averageLoad
            if load.isFinite, load > 0 { v.severity = min(1, load) }
            return v
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
    /// `windowSpan` is how much measured history stands behind the figure, and it
    /// is carried so the TIME can be withheld while the RATE is still shown. See
    /// `DrainEstimate.canQuoteTime`: `source` alone cannot tell "the trend was
    /// reset ten seconds ago" from "this machine's history is simply flat", and
    /// only the first should read as still measuring.
    ///
    /// An ANCHOR rather than a finished time: it carries the charge and the
    /// instant that charge was read, so a renderer reading it thirty seconds
    /// later gets thirty seconds less. Held as a scalar it could not move
    /// between gauge publishes — about once a minute — and the headline was
    /// reported stuck at "7h 03m". See `DisplayedRate`.
    public private(set) var displayedRate: DisplayedRate?

    /// `displayedRate` read under the lock, for callers off the main thread.
    public func lockedDisplayedRate() -> DisplayedRate? {
        lock.lock(); defer { lock.unlock() }
        return displayedRate
    }

    public func update(displayedRate: DisplayedRate?) {
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
            if s.isDischargingOnAC, let r = s.batteryRate_pctHr, r < 0 {
                // Measured straight off the pack's current, so no marker.
                return MetricValue(-r, unit: .percentPerHour, isEstimate: false,
                                   label: "Drain")
            }
            if s.direction == .acIdle {
                return MetricValue(value: 0, text: s.state?.acPowerText ?? "AC",
                                   isEstimate: false, label: "Power")
            }
            // The SHARED figure when one has been published — the same number the
            // window shows — falling back to instantaneous power only before the
            // first one arrives.
            //
            // The rate the TIME LEFT is divided by (`pctHr`), not the last few
            // minutes' (`shownPctHr`). This used to show the recent rate beside a
            // time divided from the all-time average, and the pair did not
            // multiply out: "5.4 %/hr" beside "5h 42m" at 92 % charge, which is
            // 17 hours at that rate. The recent rate is `batteryDrainNow`.
            let shared = self?.displayedRate
            let rate = shared?.pctHr ?? s.smoothedLive_pctHr
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
            id: .batteryDrainNow, title: "Battery rate, recent", shortTitle: "Now",
            unit: .percentPerHour, category: "Battery", higherIsWorse: true
        )) { [weak self] in
            // Only while draining: on AC there is no "recent drain" to speak of,
            // and `batteryDrain` already says what is happening there.
            guard let s = self?.latestSnapshot(), s.direction == .draining,
                  let shared = self?.displayedRate else { return nil }
            return MetricValue(shared.shownPctHr, unit: .percentPerHour, isEstimate: true)
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
            // On AC, SAY SO. There is no honest number here — time-to-empty is
            // meaningless while plugged in, which is why the SBS gauge returns its
            // 65535 sentinel — but "—" is the placeholder for a reading that is
            // missing, and this one is not missing. It is inapplicable, and the
            // machine knows exactly why. `batteryRate` already draws this
            // distinction the same way a few lines up.
            //
            // NaN rather than that metric's 0, and the difference is not cosmetic:
            // a sparkline history skips non-finite values (see `render`), while 0
            // would plot as "no time remaining" — alarming, and false. 0 %/hr on AC
            // is TRUE and belongs in a graph; 0 minutes left is not.
            if let st = s.state, st.onAC {
                return MetricValue(value: .nan, text: st.acPowerText ?? "AC",
                                   isEstimate: false, label: "Power")
            }
            // Shared first, so the widget and the card cannot disagree about how
            // long the battery has left.
            //
            // EVERY line below is a projection, and all of them are marked as one.
            //
            // The first branch used to drop the "*" when the rate came from the
            // discharge accumulator, on the grounds that such a rate is measured
            // end to end. The rate is. The TIME is not: it extrapolates that rate
            // across a future nobody has measured, and the future is where all the
            // error lives — the session-long window that makes this figure
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
            // Nothing quoted until there is history behind it. A time extrapolated
            // from the first seconds after an unplug is a claim about the next ten
            // hours built on whatever the machine was doing in one of them — see
            // `DrainEstimate.canQuoteTime`. Unless the lifetime model has learned
            // this machine, in which case the history IS there — see
            // `DisplayedRate.canQuoteTime`.
            if let shared = self?.displayedRate, !shared.canQuoteTime {
                return nil
            }
            // Projected to NOW, not held. The rate below is the anchor's and does
            // not move; the charge it divides has been decremented by the awake
            // seconds since the gauge last spoke. That is the anchor's own
            // arithmetic — `t(tau) = t0 - tau` exactly — so this adds no claim
            // and is a no-op at the anchor itself.
            if let shared = self?.displayedRate, let hr = shared.timeRemaining_hr(),
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

    // ── Storage ─────────────────────────────────────────────────────────────────

    /// Swap, SSD wear, lifetime traffic, and the write rate.
    ///
    /// PULLED, not pushed, which is the one place this family departs from the
    /// battery and utilisation metrics. Those read a snapshot a sampler pushed in,
    /// because they change every tick and cost real work to produce. These do not:
    /// `NVMeHealth.read()` is cached and re-reads at most once an hour by contract,
    /// and `SwapUsage.read()` was measured at 0.97 µs. Pushing them would mean a
    /// snapshot type, an `update(storage:)` and a sampler wired into three
    /// executables, to move two readings that are already as fresh as they get.
    ///
    /// Every input is injected, so tests never touch this machine's drive and the
    /// storage pane can be exercised against a drive nobody owns.
    ///
    /// NO POWER-ON HOURS — see the note beside the IDs at the top of this file.
    public func registerStorageMetrics(
        anchor: SSDWriteAnchor = .shared,
        readHealth: @escaping () -> NVMeHealth.Sample? = { NVMeHealth.read() },
        readSwap: @escaping () -> SwapUsage.Sample? = { SwapUsage.read() }
    ) {
        // ── Swap ────────────────────────────────────────────────────────────
        // The one storage figure that genuinely moves within a session, and the
        // menu-bar reading that was asked for by name. Filed under Memory, not
        // Storage: swap is what memory pressure spills into, and the Resources
        // pane already prints it inside the Memory detail.
        register(MetricDescriptor(
            id: .swapUsed, title: "Swap used", shortTitle: "Swap",
            unit: .bytes, category: "Memory", higherIsWorse: true
        )) {
            // A machine that has never swapped reports 0, and 0 is the
            // measurement. nil is the sysctl failing — the only case that means
            // we could not look.
            guard let s = readSwap() else { return nil }
            return MetricValue(Double(s.usedBytes), unit: .bytes, isEstimate: false)
        }

        // ── Drive health ────────────────────────────────────────────────────
        register(MetricDescriptor(
            id: .ssdHealth, title: "Drive health", shortTitle: "SSD",
            unit: .ratio, category: "Storage",
            // 1.0 IS HEALTHY AND HIGHER IS BETTER. Do not invert this.
            //
            // The first draft ran the other way — 0.0 healthy, `higherIsWorse:
            // true` — which reads naturally as "zero alarms" right up until
            // something renders the VALUE. `MetricUnit.ratio.format(0.0)` is
            // "0%", and "Drive health  0%" is the exact opposite of the truth,
            // printed under a title that makes it sound authoritative.
            //
            // "But `text` is always overridden" is NOT a safety net. It is a
            // property of the two providers below, not of the descriptor, and
            // nothing stops the next consumer — a graph axis, a tooltip, a
            // future pane row, a CSV export — from formatting `value` through
            // `unit` the way every other metric here is formatted. This app's
            // rule is that a renderer must never be able to invert a meaning,
            // and the only way to hold that is for the number itself to be
            // right side up.
            //
            // The dot is unchanged by the flip. `severityColor` computes
            // `badness = higherIsWorse ? f : 1 - f`, so healthy 1.0 gives
            // badness 0.0 (green) exactly as healthy 0.0 did under the old
            // polarity, and every alarm below lands on the same badness it had.
            higherIsWorse: false
        )) {
            // MEASURED TRANSITIONS ONLY. This does not model remaining life and
            // does not extrapolate a wear curve from an integrator that has never
            // left 0. It reports things that have happened, and 1.0 with the text
            // "OK" when none have — a fact about the drive, not a missing
            // reading, so it draws a green dot rather than a grey one.
            //
            // `text` is a free string rather than `MetricUnit.ratio`'s formatting
            // of the value, because the dot has to say WHICH alarm. "40%" beside
            // a yellow dot says nothing anyone can act on.
            guard let s = readHealth() else { return nil }
            // Wear is only an alarm once it is late in the drive's own rating.
            // It used to go yellow at 1 % and, since the counter only climbs,
            // stay yellow for the rest of the machine's life — on every M1/M2
            // past its first year, and soon on a 256 GB Mac that swaps — while
            // the Resources pane called the same drive "Healthy". The percentage
            // is the DRIVE's statement of its rated life used, not this app's
            // model; a drive at 5 % is working exactly as designed.
            let alarms = NVMeHealth.alarms(for: s).filter {
                if case .wearStarted(let used) = $0 { return used >= Self.wearWarnPercent }
                return true
            }
            guard let worst = alarms.first else {
                return MetricValue(value: 1, text: "OK", isEstimate: false)
            }
            return MetricValue(value: Self.alarmHealth(worst),
                               text: Self.alarmText(worst), isEstimate: false)
        }

        // ── Writes per day ──────────────────────────────────────────────────
        register(MetricDescriptor(
            id: .writePerDay, title: "Writes per day", shortTitle: "Writes",
            unit: .bytesPerDay, category: "Storage", higherIsWorse: true
        )) {
            // nil for the first 30 days after the anchor is set — see
            // `SSDWriteAnchor` for the measurements behind that gate. A
            // placeholder for a month is the correct behaviour: the alternative
            // is a number that is 2.14x wrong on day one and converges over weeks
            // while looking exactly as confident throughout.
            //
            // NOT an estimate. It is a difference of two measured counters over a
            // measured interval, never extrapolated beyond the window it was
            // measured over. Contrast `battery.timeRemaining.min`, which IS
            // marked, because it projects a rate across a future nobody measured.
            guard let s = readHealth(),
                  let perDay = anchor.rate(bytesWritten: s.bytesWritten) else { return nil }
            return MetricValue(perDay, unit: .bytesPerDay, isEstimate: false)
        }

        // ── Not bindable: the lifetime readings ─────────────────────────────
        register(MetricDescriptor(
            id: .ssdLifeUsed, title: "Drive life used", shortTitle: "Life",
            unit: .percent, category: "Storage", higherIsWorse: true,
            // Pane and CLI only, for the same reason as `system.disk.bytesPerSec`
            // above: a widget that cannot say anything. PERCENTAGE_USED is the
            // vendor's wear integrator and it reads 0 — at 7.31 TB written it has
            // not yet reached 1 — so all four widget styles are degenerate at
            // once. Text is a constant "0%", the bar is empty, the dot is green,
            // the sparkline is flat: four ways to render a constant. In the pane
            // it is a row, where "0%" is an answer.
            bindable: false
        )) {
            guard let s = readHealth() else { return nil }
            return MetricValue(Double(s.percentageUsed), unit: .percent, isEstimate: false)
        }

        // Lifetime totals. Real readings and the pane's headline figures — but a
        // menu bar redraws every second and these move by about a percent a
        // month. Withdrawn from the picker for moving too slowly to watch, not
        // for being uninteresting.
        func lifetime(_ id: MetricID, _ title: String, _ short: String,
                      worse: Bool, _ get: @escaping (NVMeHealth.Sample) -> UInt64) {
            register(MetricDescriptor(id: id, title: title, shortTitle: short,
                                      unit: .bytes, category: "Storage",
                                      higherIsWorse: worse, bindable: false)) {
                guard let s = readHealth() else { return nil }
                let bytes = get(s)
                // `value` is raw bytes; `text` is DECIMAL, through the shared
                // `MetricUnit.siBytes` and never through `.bytes`, because this
                // counter is DATA_UNITS × 512,000. The pane prints the same
                // field, and "7.31 TB" there against "6.6 TB" in the CLI dump is
                // the same quantity in the same glyphs 10 % apart.
                //
                // The descriptor still says `.bytes`. The unit governs the
                // severity scale (nil for bytes either way) and nothing
                // re-formats a value whose text is already set — the same shape
                // as `system.disk.bytesPerSec`, whose text is composed rather
                // than taken from its unit.
                return MetricValue(value: Double(bytes),
                                   text: MetricUnit.siBytes(bytes), isEstimate: false)
            }
        }
        // Writes wear the drive; reads do not, and the two must not carry the
        // same badness direction just because they carry the same unit.
        lifetime(.ssdWritten, "Lifetime written", "Written", worse: true) { $0.bytesWritten }
        lifetime(.ssdRead, "Lifetime read", "Read", worse: false) { $0.bytesRead }

        register(MetricDescriptor(
            id: .ssdSpare, title: "Spare blocks", shortTitle: "Spare",
            unit: .percent, category: "Storage",
            // The one lifetime reading where higher is BETTER: this is the reserve
            // the drive has left to retire failing blocks into, and falling below
            // `availableSpareThreshold` is end of life. That crossing is what
            // `storage.ssd.health` alarms on; this is the level behind it.
            higherIsWorse: false, bindable: false
        )) {
            guard let s = readHealth() else { return nil }
            return MetricValue(Double(s.availableSpare), unit: .percent, isEstimate: false)
        }
    }

    /// Where an alarm lands on the 0…1 HEALTH scale — 1.0 healthy, 0.0 worst.
    ///
    /// `WidgetRenderer.severityColor` reads it as `badness = 1 - health` (the
    /// descriptor says `higherIsWorse: false`), then green below 0.5, yellow below
    /// 0.8, red at or above.
    ///
    /// Wear leaving 0 is a real transition and worth a yellow dot, but it is not a
    /// fault — a drive at 1 % used is working exactly as designed — so it sits at
    /// 0.4, which is badness 0.6. The other three are states the drive itself
    /// calls wrong, and they go to 0.0.
    /// Rated life used at which wear becomes worth a coloured dot. At 100 the
    /// drive says its rated endurance is spent, which is a fault-level fact.
    static let wearWarnPercent: UInt8 = 80

    static func alarmHealth(_ alarm: NVMeHealth.Alarm) -> Double {
        switch alarm {
        case .wearStarted(let used): return used >= 100 ? 0 : 0.4
        case .criticalWarning,
             .spareBelowThreshold,
             .mediaErrors:          return 0
        }
    }

    /// Menu-bar width, so: what happened, and the one number saying how much.
    static func alarmText(_ alarm: NVMeHealth.Alarm) -> String {
        switch alarm {
        case .criticalWarning(let bits):         return String(format: "WARN 0x%02X", bits)
        case .spareBelowThreshold(let spare, _): return "SPARE \(spare)%"
        case .mediaErrors(let count):            return "\(count) ERRORS"
        case .wearStarted(let used):             return used >= 100 ? "WORN \(used)%"
                                                                    : "WEAR \(used)%"
        }
    }
}

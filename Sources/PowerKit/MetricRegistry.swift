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
}

/// Display units. Formatting lives here so every surface (menu bar, table, tooltip)
/// prints a given unit identically. Non-finite input always formats as "—": every
/// upstream signal is undocumented and can hand us NaN, and a menu bar that says
/// "nan %/hr" is exactly the startup breakage this app exists to avoid.
public enum MetricUnit: CaseIterable {
    case percentPerHour, percent, minutes, celsius, rpm, count, ratio, bytes

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

    public init(id: MetricID, title: String, shortTitle: String, unit: MetricUnit,
                category: String, higherIsWorse: Bool) {
        self.id = id
        self.title = title
        self.shortTitle = shortTitle
        self.unit = unit
        self.category = category
        self.higherIsWorse = higherIsWorse
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
        return r
    }()

    private let lock = NSLock()
    /// Registration order, preserved so a widget-config UI lists metrics stably.
    private var order: [MetricID] = []
    private var entries: [MetricID: (descriptor: MetricDescriptor,
                                     provider: () -> MetricValue?)] = [:]
    private var snapshot: PowerMonitor.Snapshot?

    public init() {}

    /// Registering an already-present ID replaces descriptor and provider in place
    /// (keeping its position) — a richer module may take over a metric later.
    public func register(_ d: MetricDescriptor, provider: @escaping () -> MetricValue?) {
        lock.lock()
        defer { lock.unlock() }
        if entries[d.id] == nil { order.append(d.id) }
        entries[d.id] = (d, provider)
    }

    public func descriptors() -> [MetricDescriptor] {
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

    public func latestSnapshot() -> PowerMonitor.Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    // ── Built-in battery metrics ────────────────────────────────────────────────

    /// Everything the battery pipeline can honestly display today. All providers are
    /// nil until the first `update(with:)` — widgets show a placeholder for the first
    /// couple of seconds rather than a stale or invented number.
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
            // Estimate until the SMC/gas-gauge gain has converged — same "*" rule the
            // app's own status item uses.
            return MetricValue(s.smoothed_pctHr, unit: .percentPerHour,
                               isEstimate: !s.isCalibrated)
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
            // Our projection at the current smoothed draw beats macOS's SBS figure
            // (which is nil on AC anyway — sentinel 65535 is already scrubbed by
            // Battery.state()). Both are projections, so both are estimates. On AC
            // there is no honest number: return nil and let the widget show "—".
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
            guard let share = self?.latestSnapshot()?.residualShare else { return nil }
            return MetricValue(share, unit: .ratio, isEstimate: true)
        }

        register(MetricDescriptor(
            id: .processCoverage, title: "Process coverage", shortTitle: "Cov",
            unit: .ratio, category: "Battery", higherIsWorse: false
        )) { [weak self] in
            // Fraction of pids whose rusage we could actually read (~63% unprivileged;
            // the rest are root-owned EPERM). Measured, not estimated.
            guard let s = self?.latestSnapshot() else { return nil }
            return MetricValue(s.coverage, unit: .ratio, isEstimate: false)
        }
    }
}

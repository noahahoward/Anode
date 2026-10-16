import AppKit
import PowerKit

/// One line the ledger screen's bottom graph (the battery view) can draw.
///
/// The user picks them in Settings → Graph, and `Settings.ledgerGraphLines` holds
/// the raw strings below. THE STRINGS ARE THE PERSISTENCE FORMAT: renaming one
/// that has shipped silently unticks it for everyone who had it ticked. Where a
/// line is the same reading as a menu bar metric it reuses that metric's ID.
///
/// Every line is a percentage or a %/hr, so all of them live on the one 0-100
/// scale the battery graph already shares between its two axes. Battery stays on
/// the right axis because only that axis paints the charging spans green; the rest
/// are drawn on the left, which is the same scale and the same gridlines, so a
/// line reads identically from either side.
enum LedgerGraphLine: String, CaseIterable {
    case drain        = "graph.drain"
    case mean         = "graph.mean"
    case battery      = "battery.percent"
    case cpu          = "system.cpu.percent"
    case memory       = "system.memory.percent"
    case gpu          = "system.gpu.percent"
    case fan          = "graph.fan.percent"
    case unattributed = "battery.unattributed.share"
    case coverage     = "battery.coverage"

    /// Picker label.
    var title: String {
        switch self {
        case .drain:        return "Actual drain (%/hr)"
        case .mean:         return "Average drain since lid opened (%/hr)"
        case .battery:      return "Battery level (%)"
        case .cpu:          return "CPU used (%)"
        case .memory:       return "Memory used (%)"
        case .gpu:          return "GPU used (%)"
        case .fan:          return "Fan speed (%)"
        case .unattributed: return "Unattributed power (%)"
        case .coverage:     return "Process coverage (%)"
        }
    }

    /// Legend and hover name.
    var legendName: String {
        switch self {
        case .drain:        return AppDelegate.drainSeriesName
        case .mean:         return AppDelegate.drainTrendSeriesName
        case .battery:      return "battery"
        case .cpu:          return "cpu"
        case .memory:       return "memory"
        case .gpu:          return "gpu"
        case .fan:          return "fan speed"
        case .unattributed: return "unattributed"
        case .coverage:     return "coverage"
        }
    }

    /// Nothing in the store holds it, so it exists only for what this run of the
    /// app has watched: it draws on the live hour and is blank on 6H, 24H and 7D.
    var sessionOnly: Bool {
        switch self {
        case .fan, .unattributed, .coverage: return true
        default: return false
        }
    }

    var color: NSColor {
        switch self {
        case .drain:        return Palette.accent
        case .mean:         return Palette.drainTrendLine
        case .battery:      return Palette.chargeLine
        case .cpu:          return Palette.blue
        case .memory:       return Palette.violet
        case .gpu:          return Palette.teal
        case .fan:          return Palette.warn
        case .unattributed: return Palette.critical
        case .coverage:     return Palette.accentDim
        }
    }

    /// The ticked lines. Unknown IDs (from a build that is not this one) are ignored
    /// here and kept in the setting.
    static func selected() -> Set<LedgerGraphLine> {
        Set(Settings.shared.ledgerGraphLines.compactMap(LedgerGraphLine.init(rawValue:)))
    }

    /// A percentage point whose hover says what it is — without `detail` the readout
    /// prints "42.37" beside the "%/hr" values, which reads as a different unit.
    static func percentPoint(_ time: Date, _ value: Double) -> HistoryGraphView.Point {
        .init(time: time, value: value, detail: String(format: "%.0f%%", value))
    }

    // ── One builder, two callers ────────────────────────────────────────────
    //
    // The live hour and the store-backed ranges both draw this graph, and they
    // have drifted before — the charge line was the wrong colour on one of them for
    // a whole release. Both build through here, so what is drawn can only differ
    // in the data it is given.

    struct Drawn {
        var series: [HistoryGraphView.Series]
        var right: HistoryGraphView.Series?
        var axisLabel: String
        var rightAxisLabel: String
    }

    /// `extras` holds the points for every selected line that is neither drain,
    /// mean nor battery. A line with no points is simply not drawn.
    static func build(selected: Set<LedgerGraphLine>,
                      drain: [HistoryGraphView.Point],
                      mean: [HistoryGraphView.Point],
                      charge: [HistoryGraphView.Point],
                      extras: [LedgerGraphLine: [HistoryGraphView.Point]],
                      drainFilled: Bool) -> Drawn {
        var series: [HistoryGraphView.Series] = []
        if selected.contains(.drain) {
            series.append(.init(name: LedgerGraphLine.drain.legendName,
                                color: LedgerGraphLine.drain.color,
                                points: drain, filled: drainFilled))
        }
        if selected.contains(.mean) {
            series += AppDelegate.trendOverlay(mean)
        }
        // Declaration order, so the legend does not reshuffle between ticks.
        var extraCount = 0
        for line in allCases where ![.drain, .mean, .battery].contains(line) {
            guard selected.contains(line), let pts = extras[line], !pts.isEmpty else { continue }
            series.append(.init(name: line.legendName, color: line.color,
                                points: pts, filled: false))
            extraCount += 1
        }

        var right: HistoryGraphView.Series?
        if selected.contains(.battery), !charge.isEmpty {
            right = .init(name: LedgerGraphLine.battery.legendName,
                          color: LedgerGraphLine.battery.color,
                          points: charge, filled: true)
        }

        // The axis is %/hr when only drain lines are on it, % when only percentages
        // are, and both when they share it.
        let hasRate = selected.contains(.drain) || selected.contains(.mean)
        let label = hasRate ? (extraCount > 0 ? "%/hr \u{00B7} %" : "%/hr") : "%"
        return Drawn(series: series, right: right, axisLabel: label,
                     rightAxisLabel: charge.count >= 2 && right != nil ? "battery" : "")
    }
}

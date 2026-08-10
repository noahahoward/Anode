import AppKit
import PowerKit

/// The Resources tab: everything the app measures about the MACHINE, in one place.
///
/// The old rail answered "how busy is the CPU" and "how hot is it" from two
/// different tabs, and neither showed a trend — the only graph in the window plots
/// battery drain. This tab is the whole-machine view: a strip of live graphs across
/// the top, and every current reading beneath, including the temperature summary
/// merged in from the old Sensors lens.
///
/// COST. This is the only tab that needs every subsystem at once, and it gets them
/// only while it is on screen: `SidebarView.Lens.needs` declares `.all` for this
/// case and `AppDelegate.visibleNeeds` unions that with whatever the menu bar is
/// bound to. Leaving the window open on Processes no longer costs a GPU property
/// dump or an SMC sweep, which it did before this tab existed.
final class ResourcesPane: SystemPane {

    /// How much history the strip keeps. Fifteen minutes at the 2 s cadence is 450
    /// points per card across a ~200 pt plot, which the graph's own decimation
    /// reduces to one bucket per pixel — so a longer window would cost memory and
    /// draw exactly the same picture.
    private let historySpan: TimeInterval = 15 * 60

    private let strip = NSStackView()
    private let cpuCard: MiniGraph
    private let gpuCard: MiniGraph
    private let memoryCard: MiniGraph
    private let networkCard: MiniGraph
    private let diskCard: MiniGraph

    override init(frame: NSRect) {
        cpuCard = MiniGraph(title: "CPU", unit: "%", color: Palette.accent)
        gpuCard = MiniGraph(title: "GPU", unit: "%", color: Palette.blue)
        memoryCard = MiniGraph(title: "Memory", unit: "%", color: Palette.warn)
        networkCard = MiniGraph(title: "Network", unit: "MB/s", color: Palette.chargeLine)
        diskCard = MiniGraph(title: "Disk", unit: "MB/s", color: Palette.accentDim)
        super.init(frame: frame)

        strip.orientation = .horizontal
        strip.distribution = .fillEqually
        strip.spacing = 10
        for card in cards {
            strip.addArrangedSubview(card)
            // A horizontal NSStackView centres its arranged views vertically and
            // these have no intrinsic height — a graph is whatever size it is given
            // — so without this the cards lay out at zero height and the strip is
            // empty.
            card.heightAnchor.constraint(equalTo: strip.heightAnchor).isActive = true
        }
        setAccessory(strip, height: 108)
        titleLabel.stringValue = "Resources"
    }
    required init?(coder: NSCoder) { fatalError() }

    private var cards: [MiniGraph] {
        [cpuCard, gpuCard, memoryCard, networkCard, diskCard]
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        cards.forEach { $0.restyle() }
    }

    /// One tick's worth of everything.
    ///
    /// `sys` is nil before the first sample lands. `power` carries the battery-side
    /// figures, which are the only numbers here that are not a utilisation.
    func update(_ sys: SystemMetrics.Snapshot?, power: PowerMonitor.Snapshot?) {
        let now = Date()
        guard let sys else {
            captionLabel.stringValue = "Waiting for the first sample."
            setBody([.row("Sampling", "—", dim: true)])
            return
        }

        push(now, sys)
        captionLabel.stringValue = summaryLine()
        setBody(bodyItems(sys, power: power))
    }

    /// Append this tick to every series and drop what has aged out.
    ///
    /// A missing reading appends NOTHING rather than a zero. The graph bridges gaps
    /// with a grey dashed line of its own, so an unsampled stretch reads as
    /// unsampled instead of as a subsystem that went quiet.
    private func push(_ now: Date, _ sys: SystemMetrics.Snapshot) {
        let cutoff = now.addingTimeInterval(-historySpan)
        cpuCard.push(sys.cpu?.total, at: now, before: cutoff,
                     text: sys.cpu.map { String(format: "%.0f%%", $0.total) })
        gpuCard.push(sys.gpu?.utilization, at: now, before: cutoff,
                     text: sys.gpu.map { String(format: "%.0f%%", $0.utilization) })
        memoryCard.push(sys.memory?.usedPercent, at: now, before: cutoff,
                        text: sys.memory.map { String(format: "%.0f%%", $0.usedPercent) })
        // Megabytes per second, not bytes: the graph labels its axis with "%g", so a
        // raw byte rate would print "5e+07" up the side of a 200 pt card.
        networkCard.push(sys.network.map { $0.totalPerSec / 1e6 }, at: now, before: cutoff,
                         text: sys.network.map { MetricUnit.bytesPerSecond.format($0.totalPerSec) })
        diskCard.push(sys.disk.map { $0.totalPerSec / 1e6 }, at: now, before: cutoff,
                      text: sys.disk.map { MetricUnit.bytesPerSecond.format($0.totalPerSec) })
    }

    private func summaryLine() -> String {
        let f = MachineInfo.facts
        var parts = [f.model, f.chip]
        if let p = f.performanceCores, let e = f.efficiencyCores {
            parts.append("\(p)P + \(e)E cores")
        } else {
            parts.append("\(f.logicalCores) cores")
        }
        parts.append(MetricUnit.bytes.format(Double(f.memoryBytes)))
        if let up = MachineInfo.uptime { parts.append("up \(MachineInfo.formatDuration(up))") }
        return parts.joined(separator: " · ")
    }

    // ── Body ────────────────────────────────────────────────────────────────

    private func bodyItems(_ sys: SystemMetrics.Snapshot,
                           power: PowerMonitor.Snapshot?) -> [BodyItem] {
        var items: [BodyItem] = []

        items.append(.heading("CPU"))
        if let c = sys.cpu {
            items.append(.row("Utilisation", String(format: "%.1f%%", c.total),
                              fill: c.total / 100, color: tint(c.total)))
            items.append(.row("User", String(format: "%.1f%%", c.user), dim: true))
            items.append(.row("System", String(format: "%.1f%%", c.system), dim: true))
            items.append(.row("Idle", String(format: "%.1f%%", c.idle), dim: true))
        } else {
            items.append(.row("Not sampled this tick", "—", dim: true))
        }
        if let t = sys.cpuTemperature {
            items.append(.row("Temperature", String(format: "%.1f °C", t),
                              fill: heatBar(t), color: heatTint(t)))
        }

        items.append(.heading("GPU"))
        if let g = sys.gpu {
            items.append(.row("Utilisation", String(format: "%.1f%%", g.utilization),
                              fill: g.utilization / 100, color: Palette.blue))
            if let r = g.rendererUtilization {
                items.append(.row("Renderer", String(format: "%.1f%%", r), dim: true))
            }
            if let m = g.inUseMemory {
                items.append(.row("Memory in use", MetricUnit.bytes.format(Double(m)), dim: true))
            }
        } else {
            items.append(.row("No accelerator reported statistics", "—", dim: true))
        }
        if let t = sys.gpuTemperature {
            items.append(.row("Temperature", String(format: "%.1f °C", t),
                              fill: heatBar(t), color: heatTint(t)))
        }
        // The one per-app GPU figure that exists, and it is apportioned — said here
        // rather than left for the user to infer from the Processes tab's "*".
        if let p = power, let gpuW = p.gpu_W {
            items.append(.row("Rail power", String(format: "%.2f W", gpuW), dim: true))
        }

        items.append(.heading("Memory"))
        if let m = sys.memory {
            items.append(.row("Used", String(format: "%@ of %@  (%.0f%%)",
                                             MetricUnit.bytes.format(Double(m.used)),
                                             MetricUnit.bytes.format(Double(m.total)),
                                             m.usedPercent),
                              fill: m.usedPercent / 100, color: tint(m.usedPercent)))
            items.append(.row("App", MetricUnit.bytes.format(Double(m.app)), dim: true))
            items.append(.row("Wired", MetricUnit.bytes.format(Double(m.wired)), dim: true))
            items.append(.row("Compressed", MetricUnit.bytes.format(Double(m.compressed)), dim: true))
            items.append(.row("Free", MetricUnit.bytes.format(Double(m.free)), dim: true))
        } else {
            items.append(.row("Not sampled this tick", "—", dim: true))
        }

        items.append(.heading("Network"))
        if let n = sys.network {
            items.append(.row("Download", MetricUnit.bytesPerSecond.format(n.bytesInPerSec)))
            items.append(.row("Upload", MetricUnit.bytesPerSecond.format(n.bytesOutPerSec)))
            let peak = n.interfaces.first?.totalPerSec ?? 0
            for i in n.interfaces.prefix(4) {
                items.append(.row(i.name,
                                  String(format: "%@ ↓  %@ ↑",
                                         MetricUnit.bytesPerSecond.format(i.inPerSec),
                                         MetricUnit.bytesPerSecond.format(i.outPerSec)),
                                  fill: peak > 0 ? i.totalPerSec / peak : 0,
                                  color: Palette.chargeLine, dim: true))
            }
        } else {
            // Throughput only exists between two reads, and this pane may have just
            // been opened. "0 B/s" would be a claim of silence.
            items.append(.row("Waiting for a second reading", "—", dim: true))
        }

        items.append(.heading("Disk activity"))
        if let d = sys.disk {
            items.append(.row("Read", MetricUnit.bytesPerSecond.format(d.bytesReadPerSec)))
            items.append(.row("Write", MetricUnit.bytesPerSecond.format(d.bytesWrittenPerSec)))
        } else {
            items.append(.row("Waiting for a second reading", "—", dim: true))
        }

        items.append(.heading("Storage"))
        let volumes = StorageInfo.volumes()
        if volumes.isEmpty {
            items.append(.row("No browsable volume reported a capacity", "—", dim: true))
        } else {
            for v in volumes {
                guard let used = v.usedBytes, let fraction = v.usedFraction else {
                    // A volume that will not report free space still gets its size
                    // stated; inventing a "used" figure for it would not.
                    items.append(.row(v.name,
                                      MetricUnit.bytes.format(Double(v.totalBytes)), dim: true))
                    continue
                }
                items.append(.row(v.name,
                                  String(format: "%@ of %@",
                                         MetricUnit.bytes.format(Double(used)),
                                         MetricUnit.bytes.format(Double(v.totalBytes))),
                                  fill: fraction,
                                  color: fraction >= 0.9 ? Palette.critical
                                       : (fraction >= 0.75 ? Palette.warn : Palette.accent)))
            }
        }

        items.append(.heading("Sensors"))
        if !sys.sensorsSampled {
            // NOT MEASURED is not the same as NONE — the same distinction the Fans
            // pane makes, for the same reason: this tab can be opened on a tick that
            // skipped the SMC.
            items.append(.row("Reading the sensors…", "—", dim: true))
        } else {
            items.append(.row("CPU", sys.cpuTemperature.map { String(format: "%.1f °C", $0) } ?? "—",
                              dim: sys.cpuTemperature == nil))
            items.append(.row("GPU", sys.gpuTemperature.map { String(format: "%.1f °C", $0) } ?? "—",
                              dim: sys.gpuTemperature == nil))
            if sys.fans.isEmpty {
                items.append(.row("Fans", "none reported", dim: true))
            } else {
                for f in sys.fans {
                    items.append(.row("Fan \(f.index + 1)",
                                      String(format: "%.0f rpm", f.currentRPM),
                                      fill: f.load,
                                      color: f.load > 0.75 ? Palette.warn : Palette.accent,
                                      dim: true))
                }
            }
            items.append(.row("Every sensor on this machine", "Sensors tab", dim: true))
        }

        items.append(.heading("Machine"))
        let f = MachineInfo.facts
        items.append(.row("Model", f.model, dim: true))
        items.append(.row("Chip", f.chip, dim: true))
        items.append(.row("Cores", f.performanceCores.flatMap { p in
            f.efficiencyCores.map { e in "\(p) performance · \(e) efficiency" }
        } ?? "\(f.logicalCores)", dim: true))
        items.append(.row("Memory", MetricUnit.bytes.format(Double(f.memoryBytes)), dim: true))
        items.append(.row("macOS", f.osVersion, dim: true))
        if let up = MachineInfo.uptime {
            items.append(.row("Uptime", MachineInfo.formatDuration(up), dim: true))
        }
        return items
    }

    private func tint(_ percent: Double) -> NSColor {
        percent >= 90 ? Palette.critical : (percent >= 70 ? Palette.warn : Palette.accent)
    }
    /// 30 °C idle to 100 °C throttle, the same scale the Sensors pane uses.
    private func heatBar(_ c: Double) -> Double { min(max((c - 30) / 70, 0), 1) }
    private func heatTint(_ c: Double) -> NSColor {
        c >= 90 ? Palette.critical : (c >= 75 ? Palette.warn : Palette.accent)
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// One card of the graph strip: a name, the current reading, and the trend.
///
/// The graph itself is `HistoryGraphView` — the same view the battery history uses,
/// with its zoom, pan, hover crosshair, decimation whiskers and gap bridging. There
/// is no second, simpler graph in this app, which is the point: a sparkline that
/// hides a spike would be a different class of object wearing the same colours.
final class MiniGraph: NSView {

    /// The full graph with its axis rewriting switched off.
    ///
    /// A card holds fifteen minutes of in-memory points and has no store behind it,
    /// so there is nothing to zoom into and nothing to pan to — and because a card
    /// carries no range picker, an accidental scroll would pin it to a stale window
    /// with no way back. Hover and the crosshair are left alone: reading a value off
    /// the line is the interaction that pays here.
    private final class StripGraphView: HistoryGraphView {
        override func scrollWheel(with event: NSEvent) {
            nextResponder?.scrollWheel(with: event)
        }
        override func mouseDown(with event: NSEvent) {}
        override func mouseDragged(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {}
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let graph = StripGraphView(frame: .zero)
    private let unit: String
    private let color: NSColor
    private var points: [HistoryGraphView.Point] = []

    init(title: String, unit: String, color: NSColor) {
        self.unit = unit
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Palette.Radius.inner
        layer?.masksToBounds = true

        titleLabel.stringValue = title
        titleLabel.font = Palette.Font.mono(9, .medium)
        valueLabel.font = Palette.Font.mono(12, .semibold)
        valueLabel.alignment = .right
        graph.showsGrid = false
        // The card's own header already names the series, so the graph's built-in
        // label would say it twice in a 200 pt box.
        graph.yAxisLabel = ""

        let header = NSStackView(views: [titleLabel, valueLabel])
        header.orientation = .horizontal
        header.distribution = .fill
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        for v in [header, graph] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 7),

            graph.leadingAnchor.constraint(equalTo: leadingAnchor),
            graph.trailingAnchor.constraint(equalTo: trailingAnchor),
            graph.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            graph.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    func restyle() {
        // The SAME ground the graph paints. `HistoryGraphView` fills
        // `controlBackgroundColor` — semantic, so light and dark stay automatic —
        // and the graph runs to the card's bottom edge, so anything else here would
        // split the card into two tones at the header's baseline.
        //
        // Resolved inside the view's OWN appearance: a dynamic NSColor flattened to
        // a CGColor takes whatever appearance is current at that moment, and this
        // runs from `viewDidChangeEffectiveAppearance`, where the current one is
        // still the outgoing theme.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
        titleLabel.textColor = Palette.faint
        valueLabel.textColor = Palette.text
    }
    override func viewDidChangeEffectiveAppearance() { restyle() }

    /// Record one reading. A nil value appends nothing — see `ResourcesPane.push`.
    func push(_ value: Double?, at time: Date, before cutoff: Date, text: String?) {
        // Only on a change: assigning `stringValue` invalidates an NSTextField's
        // intrinsic size and re-solves the enclosing stack, every tick, for a
        // string that usually did not move.
        let shown = text ?? "—"
        if valueLabel.stringValue != shown { valueLabel.stringValue = shown }
        if let value, value.isFinite {
            points.append(.init(time: time, value: value))
        }
        if let first = points.first, first.time < cutoff {
            points.removeAll { $0.time < cutoff }
        }
        graph.series = [.init(name: unit, color: color, points: points, filled: true)]
    }
}

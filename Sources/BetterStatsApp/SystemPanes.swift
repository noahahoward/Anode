import AppKit
import PowerKit

/// The whole-machine panes: Network, Sensors, Fans.
///
/// These are not lenses over the process table. There is no unprivileged
/// per-process network attribution on macOS, and a fan does not belong to a
/// process — so rather than showing a process list with an empty column, each gets
/// a view built for what it actually measures.

// ─────────────────────────────────────────────────────────────────────────────

/// Shared chrome: a title, an optional caption, and a vertical list of rows. Keeps
/// the three panes visually identical to each other and to the rest of the app.
class SystemPane: NSView {

    let titleLabel = NSTextField(labelWithString: "")
    let captionLabel = NSTextField(labelWithString: "")
    let body = NSStackView()
    private let scroll = NSScrollView()

    private final class FlippedClipView: NSClipView {
        override var isFlipped: Bool { true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildChrome()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Palette.background.setFill()
        dirtyRect.fill()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true; restyle() }

    private func buildChrome() {
        titleLabel.font = Palette.Font.sans(15, .semibold)
        captionLabel.font = Palette.Font.mono(10.5)
        captionLabel.maximumNumberOfLines = 2

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 6
        body.translatesAutoresizingMaskIntoConstraints = false

        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView = FlippedClipView()
        scroll.documentView = body

        for v in [titleLabel, captionLabel, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            captionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            captionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            body.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            body.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            body.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        restyle()
    }

    func restyle() {
        titleLabel.textColor = Palette.text
        captionLabel.textColor = Palette.dim
    }

    func clearBody() {
        body.arrangedSubviews.forEach {
            body.removeArrangedSubview($0); $0.removeFromSuperview()
        }
    }

    /// label · value, with an optional proportional bar behind it.
    func addRow(_ label: String, _ value: String,
                fill: Double? = nil, color: NSColor? = nil, dim: Bool = false) {
        let row = BarRow(label: label, value: value, fill: fill,
                         color: color ?? Palette.accent, dim: dim)
        body.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        row.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    func addHeading(_ text: String) {
        let l = NSTextField(labelWithString: text.uppercased())
        l.font = Palette.Font.mono(9, .medium)
        l.textColor = Palette.faint
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        l.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            l.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            l.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
        ])
        body.addArrangedSubview(box)
        box.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    }

    /// One row, optionally with a proportional fill behind it. The bar is drawn
    /// rather than composed from views so it can sit *behind* the text without a
    /// container per row — these lists can be 250 rows long.
    final class BarRow: NSView {
        private let label: String, value: String
        private let fill: Double?
        private let color: NSColor
        private let dim: Bool

        init(label: String, value: String, fill: Double?, color: NSColor, dim: Bool) {
            self.label = label; self.value = value
            self.fill = fill; self.color = color; self.dim = dim
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
        }
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            if let f = fill, f > 0 {
                let w = bounds.width * CGFloat(min(max(f, 0), 1))
                color.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: 2, width: w, height: bounds.height - 4),
                             xRadius: Palette.Radius.chip,
                             yRadius: Palette.Radius.chip).fill()
            }
            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: Palette.Font.sans(11.5),
                .foregroundColor: dim ? Palette.dim : Palette.text,
            ]
            let valAttrs: [NSAttributedString.Key: Any] = [
                .font: Palette.Font.mono(11.5, .medium),
                .foregroundColor: dim ? Palette.dim : Palette.text,
            ]
            let ns = label as NSString, vs = value as NSString
            let nsz = ns.size(withAttributes: nameAttrs), vsz = vs.size(withAttributes: valAttrs)
            ns.draw(at: NSPoint(x: 8, y: (bounds.height - nsz.height) / 2), withAttributes: nameAttrs)
            vs.draw(at: NSPoint(x: bounds.width - vsz.width - 10,
                                y: (bounds.height - vsz.height) / 2), withAttributes: valAttrs)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Network

final class NetworkPane: SystemPane {

    func update(_ s: NetworkThroughput.Sample?) {
        titleLabel.stringValue = "Network"
        guard let n = s else {
            captionLabel.stringValue = "Waiting for a second sample — throughput only exists between two reads."
            clearBody()
            return
        }
        captionLabel.stringValue = String(
            format: "%@ down · %@ up · loopback excluded",
            MetricUnit.bytesPerSecond.format(n.bytesInPerSec),
            MetricUnit.bytesPerSecond.format(n.bytesOutPerSec))

        clearBody()
        addHeading("Total")
        addRow("Download", MetricUnit.bytesPerSecond.format(n.bytesInPerSec))
        addRow("Upload", MetricUnit.bytesPerSecond.format(n.bytesOutPerSec))

        addHeading("Interfaces")
        if n.interfaces.isEmpty {
            addRow("No traffic on any interface", "—", dim: true)
        } else {
            let peak = n.interfaces.first?.totalPerSec ?? 1
            for i in n.interfaces {
                addRow(i.name,
                       String(format: "%@ ↓  %@ ↑",
                              MetricUnit.bytesPerSecond.format(i.inPerSec),
                              MetricUnit.bytesPerSecond.format(i.outPerSec)),
                       fill: peak > 0 ? i.totalPerSec / peak : 0,
                       color: Palette.blue)
            }
        }

        // Per-process network is genuinely unavailable, and saying so is better than
        // an empty column the user assumes is a bug.
        addHeading("Per process")
        addRow("Not available without elevated privileges", "—", dim: true)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Sensors

final class SensorsPane: SystemPane {

    func update(cpu: Double?, gpu: Double?) {
        titleLabel.stringValue = "Sensors"

        let all = Sensors.temperatures()
        let hottest = all.max { $0.value < $1.value }
        captionLabel.stringValue = String(
            format: "%d temperature sensors · CPU %@ · GPU %@ · hottest %@",
            all.count,
            cpu.map { String(format: "%.0f°C", $0) } ?? "—",
            gpu.map { String(format: "%.0f°C", $0) } ?? "—",
            hottest.map { String(format: "%.0f°C (%@)", $0.value, $0.name) } ?? "—")

        clearBody()
        guard !all.isEmpty else {
            addRow("No readable temperature sensors", "—", dim: true)
            return
        }

        addHeading("Summary")
        if let c = cpu { addRow("CPU", String(format: "%.1f °C", c), fill: bar(c), color: tint(c)) }
        if let g = gpu { addRow("GPU", String(format: "%.1f °C", g), fill: bar(g), color: tint(g)) }

        addHeading("All sensors, hottest first")
        for t in all.sorted(by: { $0.value > $1.value }) {
            // Named families first-class; everything else keeps its raw SMC key,
            // because a guessed label is worse than an honest four-character code.
            let named = t.name != t.key
            addRow(named ? t.name : t.key,
                   String(format: "%.1f °C", t.value),
                   fill: bar(t.value), color: tint(t.value), dim: !named)
        }
    }

    /// 30 °C idle to 100 °C throttle.
    private func bar(_ c: Double) -> Double { min(max((c - 30) / 70, 0), 1) }
    private func tint(_ c: Double) -> NSColor {
        c >= 90 ? Palette.critical : (c >= 75 ? Palette.warn : Palette.accent)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Fans

final class FansPane: SystemPane {

    func update(_ fans: [FanInfo]) {
        titleLabel.stringValue = "Fans"
        clearBody()

        guard !fans.isEmpty else {
            captionLabel.stringValue = "No fans reported by the SMC."
            // A fanless Mac and a failure to read are different facts, and the user
            // deserves to know which one this is.
            addRow("This machine reports no fans", "—", dim: true)
            addRow("Either it is fanless, or the SMC keys differ on this model", "", dim: true)
            return
        }

        captionLabel.stringValue = fans.count == 1
            ? "1 fan · parked at 0 rpm when cool, which is normal"
            : "\(fans.count) fans · parked at 0 rpm when cool, which is normal"

        for f in fans {
            addHeading("Fan \(f.index + 1)")
            addRow("Current", String(format: "%.0f rpm", f.currentRPM),
                   fill: f.load, color: f.load > 0.75 ? Palette.warn : Palette.accent)
            if let t = f.targetRPM {
                // Target leads actual while spinning up; showing both makes that
                // visible instead of looking like a stale reading.
                addRow("Target", String(format: "%.0f rpm", t), dim: true)
            }
            addRow("Range", String(format: "%.0f – %.0f rpm", f.minRPM, f.maxRPM), dim: true)
            addRow("Load", String(format: "%.0f%% of range", f.load * 100), dim: true)
        }

        addHeading("Control")
        addRow("Read-only — fan control is not enabled", "—", dim: true)
    }
}

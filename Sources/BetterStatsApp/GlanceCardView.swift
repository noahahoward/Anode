import AppKit
import PowerKit

/// Battery status at a glance: what it is doing right now, not what to do about it.
///
/// The process table already answers "what should I quit". This answers "what is the
/// battery actually doing" — charge, source, rate, draw, energy left, health. It
/// replaces the old header strip, because those numbers describe the battery and so
/// belong with the battery rather than floating above a list of processes.
///
/// The card swaps WHOLESALE with the power source rather than blanking fields: on AC
/// "time remaining" is not a question with an answer, and macOS itself returns its
/// unknown sentinel there.
final class GlanceCardView: NSView {

    struct Model {
        enum Source { case battery, charging, ac }
        let source: Source
        /// Headline: time remaining, time to full, or "On AC".
        let headline: String
        /// "73% · on battery"
        let percent: Int
        let sourceLabel: String
        /// Ordered label/value rows. Value may carry a second, equally weighted
        /// component (the projected clock time).
        let rows: [(label: String, value: String, trailing: String?)]
    }

    var model: Model? { didSet { rebuild() } }

    private let headline = NSTextField(labelWithString: "—")
    private let sub = NSTextField(labelWithString: "")
    private let rowStack = NSStackView()
    private let root = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); build() }

    override func viewDidChangeEffectiveAppearance() { rebuild() }

    private func build() {
        headline.font = Palette.Font.mono(30, .semibold)
        headline.textColor = Palette.text

        sub.font = Palette.Font.mono(11)
        sub.textColor = Palette.dim

        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 5
        rowStack.setHuggingPriority(.defaultHigh, for: .vertical)

        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 9
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(headline)
        root.addArrangedSubview(sub)
        root.setCustomSpacing(5, after: headline)
        root.addArrangedSubview(rowStack)
        addSubview(root)
        rowStack.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            // Bottom-pinned so the card reports a real height; the graph beside it
            // matches that height, which is what makes their baselines agree.
            root.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    private func rebuild() {
        guard let m = model else { return }

        headline.stringValue = m.headline
        headline.textColor = Palette.text

        // Charge rides with the source line rather than competing with the headline:
        // it is context for the estimate, not the answer itself.
        let line = NSMutableAttributedString(
            string: "\(m.percent)%",
            attributes: [.font: Palette.Font.mono(11, .bold), .foregroundColor: Palette.text])
        line.append(NSAttributedString(
            string: " · \(m.sourceLabel)",
            attributes: [.font: Palette.Font.mono(11), .foregroundColor: Palette.dim]))
        sub.attributedStringValue = line

        rowStack.arrangedSubviews.forEach {
            rowStack.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        for r in m.rows {
            let row = makeRow(r)
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
    }

    private func makeRow(_ r: (label: String, value: String, trailing: String?)) -> NSView {
        let name = NSTextField(labelWithString: r.label)
        name.font = Palette.Font.sans(11.5)
        name.textColor = Palette.dim

        let value = NSTextField(labelWithString: "")
        // The trailing component (a projected clock time) is drawn at FULL weight,
        // not dimmed: "when it dies" is the more actionable half of the row, so it
        // is not subordinate to the energy figure. It is still a projection and
        // inherits the estimate's error.
        let s = NSMutableAttributedString(
            string: r.value,
            attributes: [.font: Palette.Font.mono(11.5, .semibold), .foregroundColor: Palette.text])
        if let t = r.trailing {
            s.append(NSAttributedString(
                string: " · \(t)",
                attributes: [.font: Palette.Font.mono(11.5, .semibold),
                             .foregroundColor: Palette.text]))
        }
        value.attributedStringValue = s

        let row = NSStackView(views: [name, value])
        row.orientation = .horizontal
        row.distribution = .fill
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        value.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        // The width constraint is activated by the caller AFTER insertion: anchors
        // need a common ancestor, and this view has no superview yet.
        return row
    }

    // ── Building the model from a snapshot ──────────────────────────────────

    /// Formats a wall-clock projection: "when", which is the form people plan around.
    /// Follows the system 12/24-hour setting rather than hardcoding a format.
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    static func model(from s: PowerMonitor.Snapshot,
                      drain: DrainEstimate?) -> Model? {
        guard let st = s.state else { return nil }
        let full_Wh = s.scale.energyFull_Wh
        let remaining_Wh = full_Wh * Double(st.percent) / 100

        switch s.direction {
        case .charging:
            let hrs = s.timeToFull_hr
            return Model(
                source: .charging,
                headline: hrs.map(hm) ?? "Charging",
                percent: st.percent,
                sourceLabel: "charging",
                rows: [
                    ("Charge", String(format: "+%.1f %%/hr", s.batteryRate_pctHr ?? 0), nil),
                    ("Input", String(format: "%.1f W", chargeWatts(s)), nil),
                    ("Remaining", String(format: "%.1f of %.1f Wh", remaining_Wh, full_Wh),
                     hrs.flatMap { at($0) }),
                    ("Health", health(s), nil),
                ])

        case .acIdle:
            return Model(
                source: .ac,
                headline: "On AC",
                percent: st.percent,
                sourceLabel: st.percent >= 99 ? "fully charged" : "not charging",
                rows: [
                    ("Draw", String(format: "%.1f W", s.smoothed_W), nil),
                    ("Capacity", String(format: "%.1f Wh", full_Wh), nil),
                    ("Health", health(s), nil),
                ])

        case .draining:
            // Prefer the observed-discharge rate: it is measured from charge actually
            // leaving the pack rather than inferred from power draw.
            let rate = drain?.percentPerHour ?? s.smoothed_pctHr

            // Time remaining is derived from THAT SAME rate, not read from the
            // estimator separately. The estimator's own timeRemaining is computed
            // from a differently-weighted rate, so the two disagreed on screen —
            // 80% at 11.2 %/hr was showing 3h46m when the arithmetic says 7h08m.
            // A card whose own numbers contradict each other is worse than one that
            // is slightly stale.
            let hrs: Double? = rate > 0.01 ? Double(st.percent) / rate : nil

            return Model(
                source: .battery,
                headline: hrs.map(hm) ?? "—",
                percent: st.percent,
                sourceLabel: "on battery",
                rows: [
                    ("Drain", String(format: "%.1f %%/hr", rate), nil),
                    ("Draw", String(format: "%.1f W", s.smoothed_W), nil),
                    ("Remaining", String(format: "%.1f Wh", remaining_Wh), hrs.flatMap { at($0) }),
                    ("Health", health(s), nil),
                ])
        }
    }

    private static func hm(_ hours: Double) -> String {
        guard hours.isFinite, hours >= 0, hours < 240 else { return "—" }
        let total = Int((hours * 60).rounded())
        return String(format: "%dh %02dm", total / 60, total % 60)
    }

    private static func at(_ hours: Double) -> String? {
        guard hours.isFinite, hours >= 0, hours < 240 else { return nil }
        return clock.string(from: Date().addingTimeInterval(hours * 3600))
    }

    private static func health(_ s: PowerMonitor.Snapshot) -> String {
        let cycles = s.state?.cycleCount ?? 0
        return String(format: "%.0f%% · %d cyc", s.scale.health * 100, cycles)
    }

    /// Charge current times pack voltage. Distinct from system draw — the adapter
    /// supplies both at once, so collapsing them into one figure would be wrong.
    private static func chargeWatts(_ s: PowerMonitor.Snapshot) -> Double {
        guard let st = s.state else { return 0 }
        return abs(Double(st.amperage_mA) * Double(st.voltage_mV)) / 1_000_000
    }
}

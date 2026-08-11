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
        /// The bold figure ahead of `sourceLabel` — "73% · on battery".
        ///
        /// A STRING, and optional. It used to be an `Int` with the "%" written into
        /// the view, which quietly assumed every subject this card can describe is
        /// a percentage. Disk is not: it is a rate, and the honest thing beside
        /// "4.2MB/s" is nothing at all rather than a number ending in a unit it
        /// does not have. nil leaves the caption as just the label.
        let pill: String?
        let sourceLabel: String
        /// Ordered label/value rows. Value may carry a second, equally weighted
        /// component (the projected clock time).
        let rows: [(label: String, value: String, trailing: String?)]
    }

    var model: Model? { didSet { rebuild() } }

    /// The card, for a subject that is not the battery. See `BottomContext`.
    ///
    /// The same `Model` rather than a second type: it is already a headline, a
    /// caption and a list of label/value rows, which is exactly the shape of "16.4
    /// %" over "Apple M5 Pro / 15 cores / 3002 threads". What changes is what
    /// those strings say, so nothing about the view has to know which subject it
    /// is drawing.
    ///
    /// `percent` drives the small charge pill beside the caption, so a utilisation
    /// passes its own percentage there — the pill then reads as the same figure
    /// the headline states rather than as a battery level under a CPU heading.
    static func model(for context: BottomContext,
                      system sys: SystemMetrics.Snapshot,
                      facts: MachineInfo.Facts,
                      census: MachineInfo.Census?) -> Model? {
        func card(_ headline: String, _ pill: String?, _ label: String,
                  _ rows: [(String, String, String?)]) -> Model {
            Model(source: .ac, headline: headline, pill: pill,
                  sourceLabel: label, rows: rows)
        }

        switch context {
        case .battery:
            return nil

        case .cpu:
            guard let cpu = sys.cpu else { return nil }
            var rows: [(String, String, String?)] = [
                ("Chip", facts.chip, nil),
                ("Cores", "\(facts.coreSummary)", nil),
            ]
            // Threads only when they were counted. The sweep can only read the
            // processes this app owns, so a partial count says how partial it is
            // rather than presenting itself as the machine's total.
            if let c = census {
                rows.append(("Threads", "\(c.threads)",
                             c.isComplete ? nil : "of \(c.processesRead)/\(c.processes) procs"))
            }
            rows.append(("User", String(format: "%.1f%%", cpu.user), nil))
            rows.append(("System", String(format: "%.1f%%", cpu.system), nil))
            return card(String(format: "%.1f%%", cpu.total),
                        String(format: "%.0f%%", cpu.total.rounded()),
                        "CPU · measured", rows)

        case .gpu:
            guard let gpu = sys.gpu else { return nil }
            return card(String(format: "%.1f%%", gpu.utilization),
                        String(format: "%.0f%%", gpu.utilization.rounded()),
                        "GPU · measured",
                        [("Chip", facts.chip, nil)])

        case .memory:
            guard let m = sys.memory, m.total > 0 else { return nil }
            func gb(_ b: UInt64) -> String {
                String(format: "%.1f GB", Double(b) / 1_073_741_824)
            }
            return card(String(format: "%.0f%%", m.usedPercent),
                        String(format: "%.0f%%", m.usedPercent.rounded()),
                        "Memory · measured",
                        [("App", gb(m.app), nil),
                         ("Wired", gb(m.wired), nil),
                         ("Compressed", gb(m.compressed), nil),
                         ("Installed", gb(m.total), nil)])

        case .disk:
            guard let d = sys.disk else { return nil }
            let bps = MetricUnit.bytesPerSecond
            var rows: [(String, String, String?)] = [
                ("Read", bps.format(d.bytesReadPerSec), nil),
                ("Write", bps.format(d.bytesWrittenPerSec), nil),
            ]
            // The boot volume, when there is one. `StorageInfo` caches for 30 s, so
            // asking on every tick costs a dictionary lookup rather than a stat of
            // every mount. Free space is `...ForImportantUsage` — what the Finder
            // shows, and what you would actually get — not raw free bytes.
            if let v = StorageInfo.volumes().first {
                func gb(_ b: Int64) -> String {
                    String(format: "%.0f GB", Double(b) / 1_073_741_824)
                }
                if let free = v.availableBytes { rows.append(("Free", gb(free), nil)) }
                rows.append(("Capacity", gb(v.totalBytes), nil))
            }
            // NO pill: there is no honest disk-busy percentage to put there. The
            // IOKit counter that looks like one is not one — see `DiskActivity`.
            return card(bps.format(d.totalPerSec), nil, "Disk · measured", rows)
        }
    }

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
        // A WORD is not a duration and must not be set like one.
        //
        // This slot is tuned for "9h 41m": six monospace characters, all digits,
        // none of which has a descender. Putting "measuring…" in it at the same
        // size overflowed the width AND — because the card's height comes from the
        // graph beside it, so the stack is compressed rather than grown — clipped
        // the bottom off every letter, `g` worst of all.
        //
        // So a non-numeric headline gets a proportional face at a size that fits.
        // Detected from the string rather than carried as a flag, because every
        // caller that ever puts a word here needs this and none of them should
        // have to remember to say so.
        let isNumeric = m.headline.contains { $0.isNumber }
        headline.font = isNumeric ? Palette.Font.mono(30, .semibold)
                                  : Palette.Font.sans(21, .semibold)
        headline.lineBreakMode = .byTruncatingTail

        // Charge rides with the source line rather than competing with the headline:
        // it is context for the estimate, not the answer itself.
        let line = NSMutableAttributedString()
        if let pill = m.pill {
            line.append(NSAttributedString(
                string: pill + " · ",
                attributes: [.font: Palette.Font.mono(11, .bold),
                             .foregroundColor: Palette.text]))
        }
        line.append(NSAttributedString(
            string: m.sourceLabel,
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
        // mAh basis, like every other projection in the app — see
        // `BatteryScale.chargePercent`. The integer percent shown beside this reads
        // 1-2 points higher and is the gauge's own rounding, not a second opinion
        // worth propagating into an energy figure.
        let remaining_Wh = full_Wh * s.scale.chargePercent(st) / 100

        switch s.direction {
        case .charging:
            let est = s.chargeEstimate
            let hrs = est?.hours
            return Model(
                source: .charging,
                headline: hrs.map(hm) ?? "Charging",
                pill: "\(st.percent)%",
                // Says what it is counting DOWN TO, because on this machine that is
                // 80% and not full, and a bare "charging" left the countdown looking
                // like it was heading somewhere it was never going to arrive.
                // Marked estimated for the same reason time-to-empty is: the charge
                // current is measured, the time it will still be flowing is not.
                sourceLabel: chargingLabel(est, gaugeRatio: Self.gaugeRatio(s, st)),
                rows: [
                    ("Charge", String(format: "+%.1f %%/hr", s.batteryRate_pctHr ?? 0), nil),
                    ("Input", String(format: "%.1f W", chargeWatts(s)), nil),
                    ("Remaining", String(format: "%.1f of %.1f Wh", remaining_Wh, full_Wh),
                     hrs.flatMap { at($0) }),
                    ("Health", health(s), nil),
                ])

        case .acIdle:
            // "Held at 80%" is a different fact from "not charging": the machine
            // has finished, at the level it was asked to finish at. Saying only
            // "not charging" at 80% reads as a fault.
            // The GAUGE percent, not the target's.
            //
            // `ChargeTarget.Level.percent` is on the mAh basis, which is right for
            // the arithmetic and wrong for this sentence: at an 80% limit it reads
            // 76, and the card prints "76% limit" three inches under a charge
            // reading of "80%". Two bases in one card is the defect this project
            // keeps finding, and here it needs no conversion to fix — HELD means
            // the machine has stopped AT the limit, so the level being shown right
            // now IS the limit, in whatever basis it is being shown in.
            let held = s.isHeldAtChargeLimit ? Double(st.percent) : nil
            return Model(
                source: .ac,
                headline: "On AC",
                pill: "\(st.percent)%",
                sourceLabel: held.map { String(format: "held at %.0f%% limit", $0) }
                    ?? (st.percent >= 99 ? "fully charged" : "not charging"),
                rows: [
                    ("Draw", String(format: "%.1f W", s.smoothed_W), nil),
                    ("Capacity", String(format: "%.1f Wh", full_Wh), nil),
                    ("Health", health(s), nil),
                ])

        case .draining:
            // Rate AND time come from the one published pair — the same two numbers
            // the menu bar shows, neither of them recomputed here. They used to be
            // computed twice and disagreed on screen: 80% at 11.2 %/hr was showing
            // 3h46m when the arithmetic says 7h08m.
            //
            // They still multiply out, but against the mAh charge rather than the
            // integer percent printed below them: `reconciledRate` divides
            // `BatteryScale.chargePercent`, which on this machine reads 59.2 % where
            // `CurrentCapacity` says 61 %. That gap is the deliberate basis change —
            // the integer field is optimistic by ~5 % and the pack's own
            // `TimeRemaining` agrees with the mAh figure — so "61 % ÷ 5.6 %/hr"
            // no longer lands exactly on the headline. It is off by the same 1-2
            // points the gauge is off by, and rounding the projection to agree with
            // the rounder of the two inputs would be the wrong repair.
            let shared = AppDelegate.reconciledRate(s, drain)
            // Withheld until there is history behind it — the same rule the menu
            // bar metric follows, so the two cannot print different answers to one
            // question three inches apart. See `DrainEstimate.canQuoteTime`.
            let settled = DrainEstimate.canQuoteTime(source: shared.source,
                                                     windowSpan: shared.windowSpan)
            let hrs = settled ? shared.timeRemaining_hr : nil

            return Model(
                source: .battery,
                // "estimating…" while nothing is known yet, never a placeholder
                // number. "—" is for a figure that is unknowABLE rather than
                // not-yet-known.
                headline: hrs.map(hm) ?? (settled ? "—" : "measuring…"),
                pill: "\(st.percent)%",
                sourceLabel: "on battery · " + provenance(shared.source, settled: settled),
                rows: [
                    ("Drain", String(format: "%.1f %%/hr", shared.pctHr), nil),
                    ("Draw", String(format: "%.1f W", s.smoothed_W), nil),
                    ("Remaining", String(format: "%.1f Wh", remaining_Wh), hrs.flatMap { at($0) }),
                    ("Health", health(s), nil),
                ])
        }
    }

    /// What the countdown above is counting down TO, and how much to trust it.
    ///
    /// The target is the honest half: this machine stops at 80%, so "charging to
    /// 80%" is a claim that can come true and "charging" — beside a figure that
    /// was silently projecting to 100% — was one that could not. When no limit has
    /// been learned yet the target is the pack's own full charge and it says so
    /// rather than naming a percentage nobody has observed.
    ///
    /// "estimated" is the other half, and it is not optional. `ChargeCurve` fits
    /// the final taper from two recorded charge sessions; a fit rendered without a
    /// word saying so is a prediction wearing a measurement's clothes, which is
    /// the defect the time-to-empty marker exists to prevent.
    /// `gaugeRatio` converts the target from the mAh basis it is learned on to the
    /// basis the percentage BESIDE it is printed in.
    ///
    /// Both are "charge over capacity" and differ only in which capacity fields
    /// they read, so the conversion is a single ratio taken at the current level:
    /// measured here, an 80% limit is 76% on the mAh basis, and printing the raw
    /// 76 put two bases in one card — "charging to 76%" directly under "80%".
    ///
    /// Applied to the LABEL only. Every projection underneath still runs on the
    /// mAh basis, which is the accurate one and the reason it is used at all.
    static func chargingLabel(_ e: ChargeTarget.Estimate?, gaugeRatio: Double) -> String {
        guard let e else { return "charging" }
        guard e.target.isLearnedLimit else { return "charging to full · estimated" }
        let shown = (e.target.percent * gaugeRatio).rounded()
        return String(format: "charging to %.0f%% · estimated", shown)
    }

    /// Gauge percent over mAh percent at this instant. 1.0 when either is
    /// unavailable — an unconverted number is better than a number multiplied by
    /// something meaningless.
    static func gaugeRatio(_ s: PowerMonitor.Snapshot, _ st: Battery.State) -> Double {
        let mAh = s.scale.chargePercent(st)
        guard mAh > 1, st.percent > 0 else { return 1 }
        return Double(st.percent) / mAh
    }

    /// Where the headline came from, in the user's words rather than the enum's.
    ///
    /// The distinction is not decoration: "measured drain" is charge integrated out
    /// of the pack by the battery itself over the last half hour, while the others
    /// are inferred from what the machine is drawing at this instant and will move
    /// with it. A user deciding whether to trust "3h 40m" needs to know which they
    /// are looking at.
    /// `settled` is false in the first couple of minutes after an unplug or a
    /// wake, when the trend has been reset and there is a rate but no history to
    /// project it across. Said in words here because this is where there is room
    /// for words — the menu bar just shows nothing.
    private static func provenance(_ source: DrainEstimate.Source,
                                   settled: Bool = true) -> String {
        // One word. The sub line is a fixed-width strip and already carries the
        // charge and the power source; "measuring — not enough history yet" ran
        // off the end of it, which says even less than the short version.
        guard settled else { return "measuring" }
        return provenanceWord(source)
    }

    private static func provenanceWord(_ source: DrainEstimate.Source) -> String {
        switch source {
        case .discharge:    return "measured drain"
        case .observed:     return "observed drain"
        case .blended:      return "estimated drain"
        case .power:        return "estimated from draw"
        case .insufficient: return "no estimate yet"
        }
    }

    /// The headline duration, formatted by the SAME code the menu bar uses.
    ///
    /// This used to format independently as `"%dh %02dm"`, which meant the two
    /// surfaces disagreed below an hour: the card said "0h 45m" and the widget
    /// said "45m", for one number that is deliberately published once so they
    /// cannot disagree. Cosmetic at 45 minutes, but it is the same duplicated
    /// arithmetic that produced the drain/time-left mismatch this app already
    /// got a bug report about — two formatters is two places to change and one
    /// place to forget.
    ///
    /// The range guard stays here rather than moving into the unit: 240 hours is
    /// a statement about what a battery projection may plausibly claim, not
    /// about how minutes are written.
    private static func hm(_ hours: Double) -> String {
        guard hours.isFinite, hours >= 0, hours < 240 else { return "—" }
        return MetricUnit.minutes.format((hours * 60).rounded())
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

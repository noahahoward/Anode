import AppKit
import PowerKit

/// The whole-machine panes: Network, Sensors, Fans.
///
/// These are not lenses over the process table. There is no unprivileged
/// per-process network attribution on macOS, and a fan does not belong to a
/// process — so rather than showing a process list with an empty column, each gets
/// a view built for what it actually measures.

// ─────────────────────────────────────────────────────────────────────────────

/// One line of a pane's body: a section heading, or a label · value row.
///
/// Declared rather than appended because these panes are refreshed on every tick
/// and the rows almost never change shape — only their text. Handing the chrome
/// the whole list lets it update the views already on screen instead of tearing
/// the stack down, which is where the cost was. See `SystemPane.setBody`.
struct BodyItem {
    enum Kind { case heading, row }
    let kind: Kind
    let label: String
    let value: String
    let fill: Double?
    let color: NSColor?
    let dim: Bool

    static func heading(_ text: String) -> BodyItem {
        BodyItem(kind: .heading, label: text, value: "", fill: nil, color: nil, dim: false)
    }

    static func row(_ label: String, _ value: String, fill: Double? = nil,
                    color: NSColor? = nil, dim: Bool = false) -> BodyItem {
        BodyItem(kind: .row, label: label, value: value, fill: fill, color: color, dim: dim)
    }
}

/// A body view that can take a new `BodyItem` without being replaced, and can be
/// told the appearance changed under it.
private protocol PaneBodyView: AnyObject {
    func apply(_ item: BodyItem)
    func restyle()
}

/// Shared chrome: a title, an optional caption, and a vertical list of rows. Keeps
/// the three panes visually identical to each other and to the rest of the app.
class SystemPane: NSView {

    let titleLabel = NSTextField(labelWithString: "")
    let captionLabel = NSTextField(labelWithString: "")
    let body = NSStackView()
    private let scroll = NSScrollView()
    /// Held so an accessory can be spliced in between the caption and the list
    /// without rebuilding the chrome. See `setAccessory`.
    private var scrollTop: NSLayoutConstraint!

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
        // bounds, NOT dirtyRect. Filling the dirty rect painted over the sidebar:
        // the rect AppKit hands you is not guaranteed to lie inside this view, and
        // this pane is the only thing in the window that filled it directly.
        Palette.background.setFill()
        bounds.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        needsDisplay = true
        restyle()
        // The body's rows resolve `Palette` at draw time, and a reused row is only
        // repainted when its own content changes — so a theme flip has to say so
        // explicitly or the list keeps the old appearance's ink until a value moves.
        body.arrangedSubviews.forEach { ($0 as? PaneBodyView)?.restyle() }
    }

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
        scrollTop = scroll.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 12)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            captionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            captionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scrollTop,
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            body.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            body.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            body.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        restyle()
    }

    /// Park a fixed-height view between the caption and the scrolling list.
    ///
    /// Exists for the Resources tab's graph strip, which has to sit ABOVE the
    /// readings rather than scroll with them — a graph you have to scroll back to
    /// is not a glance. Called once at construction; the accessory is then updated
    /// in place like everything else in these panes.
    func setAccessory(_ view: NSView, height: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        scrollTop.isActive = false
        accessoryHeight = view.heightAnchor.constraint(equalToConstant: height)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            view.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 12),
            accessoryHeight!,
            scroll.topAnchor.constraint(equalTo: view.bottomAnchor, constant: 14),
        ])
    }

    /// Held so an accessory whose content changes shape can grow and shrink.
    ///
    /// The Fans tab's control strip is one row per fan plus a status line, and it
    /// does not know how many fans exist until the first SMC sweep lands — a
    /// height fixed at construction would either clip the second fan or leave a
    /// band of empty pane above the readings on a machine with one.
    private var accessoryHeight: NSLayoutConstraint?

    func setAccessoryHeight(_ height: CGFloat) {
        guard let accessoryHeight, accessoryHeight.constant != height else { return }
        accessoryHeight.constant = height
    }

    func restyle() {
        titleLabel.textColor = Palette.text
        captionLabel.textColor = Palette.dim
    }

    /// Install `items` as the body, reusing the views already there when the shape
    /// has not changed.
    ///
    /// Every pane is re-rendered on every tick and the Sensors pane is ~260 rows.
    /// MEASURED (M5 Pro, 258 rows, offscreen harness): clearing the stack and
    /// rebuilding it costs 36 ms of CPU per tick — 8 ms creating views, the rest
    /// Auto Layout re-solving a stack whose arranged subviews all changed identity.
    /// Re-texting the same views costs 0.12 ms, because nothing touches a
    /// constraint. Rows whose content is unchanged are not even repainted.
    func setBody(_ items: [BodyItem]) {
        let existing = body.arrangedSubviews
        // Reuse only when the shapes line up exactly. A different count, or a
        // heading where a row was, means the constraint set has to change anyway.
        let reusable = existing.count == items.count
            && zip(existing, items).allSatisfy { view, item in
                switch item.kind {
                case .row:     return view is BarRow
                case .heading: return view is HeadingView
                }
            }
        guard reusable else { rebuildBody(items); return }
        for (view, item) in zip(existing, items) {
            (view as? PaneBodyView)?.apply(item)
        }
    }

    private func rebuildBody(_ items: [BodyItem]) {
        body.arrangedSubviews.forEach {
            body.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        for item in items {
            switch item.kind {
            case .row:
                let row = BarRow(item)
                body.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
                row.heightAnchor.constraint(equalToConstant: 22).isActive = true
            case .heading:
                let head = HeadingView(item)
                body.addArrangedSubview(head)
                head.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            }
        }
    }

    /// One row, optionally with a proportional fill behind it. The bar is drawn
    /// rather than composed from views so it can sit *behind* the text without a
    /// container per row — these lists can be 250 rows long.
    final class BarRow: NSView, PaneBodyView {
        private var label: String, value: String
        private var fill: Double?
        private var color: NSColor
        private var dim: Bool

        init(_ item: BodyItem) {
            label = item.label; value = item.value
            fill = item.fill; color = item.color ?? Palette.accent; dim = item.dim
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
        }
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }

        /// Repaint only on a real change. At 260 rows a tick, an unconditional
        /// `needsDisplay` would hand AppKit a full-height invalidation every 2 s
        /// for a list that mostly did not move.
        func apply(_ item: BodyItem) {
            let newColor = item.color ?? Palette.accent
            guard label != item.label || value != item.value || fill != item.fill
                    || dim != item.dim || color != newColor else { return }
            label = item.label; value = item.value
            fill = item.fill; color = newColor; dim = item.dim
            needsDisplay = true
        }

        func restyle() { needsDisplay = true }

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

    /// A section heading. A real type rather than an anonymous box so a rebuild can
    /// tell a heading from a row when deciding whether the body can be reused.
    final class HeadingView: NSView, PaneBodyView {
        private let label = NSTextField(labelWithString: "")

        init(_ item: BodyItem) {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            label.font = Palette.Font.mono(9, .medium)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor),
                label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            ])
            apply(item)
            restyle()
        }
        required init?(coder: NSCoder) { fatalError() }

        func apply(_ item: BodyItem) {
            let text = item.label.uppercased()
            // NSTextField invalidates its intrinsic size on every assignment, which
            // is a layout pass for a string that is the same one as last tick.
            guard label.stringValue != text else { return }
            label.stringValue = text
        }

        func restyle() { label.textColor = Palette.faint }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Network

final class NetworkPane: SystemPane {

    func update(_ s: NetworkThroughput.Sample?,
                perProcess: [NetworkAttribution.Row] = [],
                age: TimeInterval? = nil) {
        titleLabel.stringValue = "Network"
        self.perProcess = perProcess
        self.perProcessAge = age
        guard let n = s else {
            captionLabel.stringValue = "Waiting for a second sample — throughput only exists between two reads."
            setBody([])
            return
        }
        captionLabel.stringValue = String(
            format: "%@ down · %@ up · loopback excluded",
            MetricUnit.bytesPerSecond.format(n.bytesInPerSec),
            MetricUnit.bytesPerSecond.format(n.bytesOutPerSec))

        var items: [BodyItem] = [
            .heading("Total"),
            .row("Download", MetricUnit.bytesPerSecond.format(n.bytesInPerSec)),
            .row("Upload", MetricUnit.bytesPerSecond.format(n.bytesOutPerSec)),
            .heading("Interfaces"),
        ]
        if n.interfaces.isEmpty {
            items.append(.row("No traffic on any interface", "—", dim: true))
        } else {
            let peak = n.interfaces.first?.totalPerSec ?? 1
            for i in n.interfaces {
                items.append(.row(i.name,
                                  String(format: "%@ ↓  %@ ↑",
                                         MetricUnit.bytesPerSecond.format(i.inPerSec),
                                         MetricUnit.bytesPerSecond.format(i.outPerSec)),
                                  fill: peak > 0 ? i.totalPerSec / peak : 0,
                                  color: Palette.blue))
            }
        }

        // This used to say per-process network was unavailable without elevated
        // privileges. It isn't: nettop is not setuid and needs no entitlement.
        items.append(.heading("Per process"))
        if perProcess.isEmpty {
            // Two genuinely different states. "Still sampling" is not "nothing is
            // using the network", and a rate needs two samples ~15 s apart.
            items.append(.row(perProcessAge == nil
                                  ? "Sampling — a rate needs two readings"
                                  : "No process moved traffic in the last window",
                              "—", dim: true))
        } else {
            let peak = perProcess.first?.totalPerSec ?? 1
            for p in perProcess.prefix(25) {
                items.append(.row("\(p.name)  ·  \(p.pid)",
                                  String(format: "%@ ↓  %@ ↑",
                                         MetricUnit.bytesPerSecond.format(p.bytesInPerSec),
                                         MetricUnit.bytesPerSecond.format(p.bytesOutPerSec)),
                                  fill: peak > 0 ? p.totalPerSec / peak : 0,
                                  color: Palette.blue))
            }
        }
        setBody(items)
    }

    private var perProcess: [NetworkAttribution.Row] = []
    private var perProcessAge: TimeInterval?
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Sensors

final class SensorsPane: SystemPane {

    /// The per-key temperature list, swept off the main thread and cached for the
    /// same 5 s `SystemMetrics` uses for its own SMC reads.
    ///
    /// MEASURED (M5 Pro, 256 readings): one sweep is 90 ms of wall clock and 10 ms
    /// of CPU. This pane used to call `Sensors.temperatures()` inline on every
    /// tick, so simply having it open put 90 ms of blocked IOKit and 10 ms of CPU
    /// on the main thread every 2 s.
    private let sensors = SensorCache()
    private let queue = DispatchQueue(label: "com.betterstats.sensorspane", qos: .utility)
    private var sweeping = false

    /// Held so a sweep landing between ticks can repaint the whole pane without
    /// waiting for the caller to hand these over again.
    private var cpuTemp: Double?
    private var gpuTemp: Double?

    func update(cpu: Double?, gpu: Double?) {
        cpuTemp = cpu
        gpuTemp = gpu
        sweepIfNeeded()
        render()
    }

    /// One sweep in flight at a time, and its result painted the moment it lands
    /// rather than at the next tick — otherwise the pane would sit on its
    /// placeholder for a whole sample interval the first time it was opened.
    private func sweepIfNeeded() {
        guard sensors.isStale, !sweeping else { return }
        sweeping = true
        queue.async { [weak self] in
            self?.sensors.refreshIfStale()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sweeping = false
                self.render()
            }
        }
    }

    private func render() {
        titleLabel.stringValue = "Sensors"

        guard let all = sensors.latest else {
            // Before the first sweep lands there is no list. Drawing the empty
            // state here would claim this machine has no readable sensors, which
            // is a measurement nobody has made yet — it lasts the ~90 ms of one
            // sweep, once, the first time the pane is opened.
            captionLabel.stringValue = "Reading the sensor set from the SMC…"
            setBody([.row("Reading sensors", "—", dim: true)])
            return
        }

        let hottest = all.max { $0.value < $1.value }
        captionLabel.stringValue = String(
            format: "%d temperature sensors · CPU %@ · GPU %@ · hottest %@",
            all.count,
            cpuTemp.map { String(format: "%.0f°C", $0) } ?? "—",
            gpuTemp.map { String(format: "%.0f°C", $0) } ?? "—",
            // qualifiedName, not name. The hottest sensor on this machine is
            // `TVDc`/`TCMb`, both UNIDENTIFIED — so `name` reads "Thermal sensor 37",
            // a bucket ordinal rendered in exactly the same voice as a real claim
            // like "GPU sensor 37". qualifiedName appends the raw key for anything
            // hedged, which is the only identity those 140 sensors actually have.
            hottest.map { String(format: "%.0f°C (%@)", $0.value, $0.qualifiedName) } ?? "—")

        guard !all.isEmpty else {
            setBody([.row("No readable temperature sensors", "—", dim: true)])
            return
        }

        var items: [BodyItem] = [.heading("Summary")]
        if let c = cpuTemp {
            items.append(.row("CPU", String(format: "%.1f °C", c), fill: bar(c), color: tint(c)))
        }
        if let g = gpuTemp {
            items.append(.row("GPU", String(format: "%.1f °C", g), fill: bar(g), color: tint(g)))
        }

        items.append(.heading("All sensors, hottest first"))
        for t in all.sorted(by: { $0.value > $1.value }) {
            // Named families first-class; everything else keeps its raw SMC key,
            // because a guessed label is worse than an honest four-character code.
            // `name != key` is NOT the test for "we know what this is". All 140
            // hedged temperatures have a name ("Thermal sensor 37") that differs
            // from their key, so this dimmed the wrong rows: it rendered every
            // guess as a confident name and dimmed only the raw-key ones.
            // `isIdentified` is the flag the naming layer actually publishes.
            let named = t.isIdentified
            items.append(.row(t.qualifiedName,
                              String(format: "%.1f °C", t.value),
                              fill: bar(t.value), color: tint(t.value), dim: !named))
        }
        setBody(items)
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

    /// The control strip, above the readings.
    ///
    /// Owned by the pane rather than wired through the app delegate, for the same
    /// reason `SensorsPane` owns its `SensorCache`: it is the only thing that uses
    /// it, and threading four closures through a view to reach a socket would put
    /// the feature in three files instead of one.
    let control = FanControlPanel(frame: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessory(control, height: control.preferredHeight)
        control.onLayoutChanged = { [weak self] in
            guard let self else { return }
            self.setAccessoryHeight(self.control.preferredHeight)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The app is quitting. See `FanControlPanel.teardown` — closing the socket
    /// is what hands the fans back.
    func teardown() { control.teardown() }

    func update(_ fans: [FanInfo], sampled: Bool = true) {
        titleLabel.stringValue = "Fans"
        control.update(fans: sampled ? fans : [])

        // NOT MEASURED is not the same as NONE. The SMC sweep is skipped while
        // the window is hidden, so a snapshot taken then carries an empty fan
        // list by design. Rendering that as "this machine reports no fans" told
        // a two-fan machine it had none — observed live after closing the window
        // and reopening it on this pane, and it corrected itself a tick later,
        // which is worse than being wrong consistently: it looks like a flaky
        // sensor rather than a stale frame.
        guard sampled else {
            captionLabel.stringValue = "Reading the fan sensors…"
            setBody([.row("Waiting for the first SMC sweep", "—", dim: true)])
            return
        }

        guard !fans.isEmpty else {
            captionLabel.stringValue = "No fans reported by the SMC."
            // A fanless Mac and a failure to read are different facts, and the user
            // deserves to know which one this is.
            setBody([
                .row("This machine reports no fans", "—", dim: true),
                .row("Either it is fanless, or the SMC keys differ on this model", "", dim: true),
            ])
            return
        }

        captionLabel.stringValue = fans.count == 1
            ? "1 fan · parked at 0 rpm when cool, which is normal"
            : "\(fans.count) fans · parked at 0 rpm when cool, which is normal"

        var items: [BodyItem] = []
        for f in fans {
            items.append(.heading("Fan \(f.index + 1)"))
            items.append(.row("Current", String(format: "%.0f rpm", f.currentRPM),
                              fill: f.load, color: f.load > 0.75 ? Palette.warn : Palette.accent))
            if let t = f.targetRPM {
                // Target leads actual while spinning up; showing both makes that
                // visible instead of looking like a stale reading.
                items.append(.row("Target", String(format: "%.0f rpm", t), dim: true))
            }
            items.append(.row("Range", String(format: "%.0f – %.0f rpm", f.minRPM, f.maxRPM), dim: true))
            items.append(.row("Load", String(format: "%.0f%% of range", f.load * 100), dim: true))
        }

        // The live state of fan control is in the strip above; these are the two
        // rules that hold whatever state it is in, and they are worth stating
        // where someone deciding whether to turn it on will read them.
        items.append(.heading("Control"))
        items.append(.row("Slider", "drag to hold a fan; faded means macOS is deciding", dim: true))
        items.append(.row("❄︎", "that fan flat out, at its own reported maximum", dim: true))
        items.append(.row("✕", "every fan back to automatic control", dim: true))
        items.append(.row("Safety floor", "each fan's own reported minimum", dim: true))
        items.append(.row("If BetterStats quits or crashes",
                          "fans return to automatic", dim: true))
        setBody(items)
    }
}

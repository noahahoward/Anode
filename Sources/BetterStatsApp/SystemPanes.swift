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
    /// `.figure` is a label above a LARGE value rather than a label-value pair.
    ///
    /// It exists because the Resources detail separates the numbers that move from
    /// the facts that do not — the live readings are set big and grouped together,
    /// the hardware specs stay small label/value pairs beside them. That separation
    /// is most of what makes the layout readable, and it maps onto the distinction
    /// this project already cares most about: measured now, versus known all along.
    ///
    /// `.group` is a heading you can COLLAPSE. It exists because this machine
    /// reports 256 temperatures and a flat list of them is not a list anyone
    /// reads — the sensor you want is somewhere in 140 called "Thermal sensor N".
    enum Kind { case heading, row, figure, group }
    let kind: Kind
    let label: String
    let value: String
    let fill: Double?
    let color: NSColor?
    let dim: Bool
    /// Only meaningful for `.group`: which way the chevron points.
    let expanded: Bool

    /// A collapsible heading. `value` is the summary that stays visible when the
    /// group is shut — a group you have to open to find out whether it matters is
    /// a group you open every time.
    static func group(_ text: String, _ summary: String, expanded: Bool) -> BodyItem {
        BodyItem(kind: .group, label: text, value: summary, fill: nil, color: nil,
                 dim: false, expanded: expanded)
    }

    static func heading(_ text: String) -> BodyItem {
        BodyItem(kind: .heading, label: text, value: "", fill: nil, color: nil,
                 dim: false, expanded: false)
    }

    static func row(_ label: String, _ value: String, fill: Double? = nil,
                    color: NSColor? = nil, dim: Bool = false) -> BodyItem {
        BodyItem(kind: .row, label: label, value: value, fill: fill, color: color,
                 dim: dim, expanded: false)
    }

    static func figure(_ label: String, _ value: String, color: NSColor? = nil) -> BodyItem {
        BodyItem(kind: .figure, label: label, value: value, fill: nil, color: color,
                 dim: false, expanded: false)
    }
}

/// A body view that can take a new `BodyItem` without being replaced, and can be
/// told the appearance changed under it.
protocol PaneBodyView: AnyObject {
    func apply(_ item: BodyItem)
    func restyle()
}

extension SystemPane {

    /// A collapsible group header: a chevron, a name, and the summary that stays
    /// visible when the group is shut.
    ///
    /// The summary is the point. A group you have to open to find out whether it
    /// matters is a group you open every time, and with eight of them that is
    /// worse than the flat list this replaced.
    final class GroupHeaderView: NSView, PaneBodyView {
        private let name = NSTextField(labelWithString: "")
        private let summary = NSTextField(labelWithString: "")
        private var expanded = false
        private var hovered = false
        var onToggle: (() -> Void)?

        init(_ item: BodyItem) {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            for f in [name, summary] {
                f.translatesAutoresizingMaskIntoConstraints = false
                addSubview(f)
            }
            NSLayoutConstraint.activate([
                // Left inset leaves room for the chevron this view draws itself.
                name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                name.centerYAnchor.constraint(equalTo: centerYAnchor),
                summary.trailingAnchor.constraint(equalTo: trailingAnchor),
                summary.centerYAnchor.constraint(equalTo: centerYAnchor),
                summary.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor,
                                                 constant: 8),
            ])
            apply(item)
        }
        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }

        func apply(_ item: BodyItem) {
            expanded = item.expanded
            name.attributedStringValue = NSAttributedString(
                string: item.label.uppercased(),
                attributes: Palette.labelAttributes(Palette.dim))
            summary.attributedStringValue = NSAttributedString(
                string: item.value,
                attributes: [.font: Palette.Font.mono(11), .foregroundColor: Palette.faint])
            needsDisplay = true
        }

        func restyle() { needsDisplay = true }
        override func viewDidChangeEffectiveAppearance() { restyle() }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                owner: self))
        }
        override func mouseEntered(with e: NSEvent) { hovered = true; needsDisplay = true }
        override func mouseExited(with e: NSEvent) { hovered = false; needsDisplay = true }
        override func mouseDown(with e: NSEvent) { onToggle?() }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }

        override func draw(_ dirtyRect: NSRect) {
            if hovered {
                Palette.surfaceAlt.setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: -4, dy: 1),
                             xRadius: Palette.Radius.row,
                             yRadius: Palette.Radius.row).fill()
            }
            // The SAME chevron the table header draws for the sorted column, at the
            // same size and in the same ink. It means the same thing in both places
            // — "this is the one, and this is which way" — and two chevrons that
            // looked different would be two ideas.
            let w: CGFloat = 8, h: CGFloat = 5
            let r = NSRect(x: 1, y: bounds.midY - h / 2, width: w, height: h)
            // Flipped, so minY is the top. Down when open, right-ish when shut is
            // the usual disclosure idiom; here shut points down-left to stay one
            // shape rather than two.
            let path = NSBezierPath()
            if expanded {
                path.move(to: NSPoint(x: r.minX, y: r.minY))
                path.line(to: NSPoint(x: r.midX, y: r.maxY))
                path.line(to: NSPoint(x: r.maxX, y: r.minY))
            } else {
                path.move(to: NSPoint(x: r.minX, y: r.minY))
                path.line(to: NSPoint(x: r.maxX, y: r.midY))
                path.line(to: NSPoint(x: r.minX, y: r.maxY))
            }
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            Palette.accent.setStroke()
            path.stroke()
        }
    }
}

/// A vertical list of `BodyItem`s that updates in place.
///
/// Split out of `SystemPane` so the Resources detail can have THREE of these — the
/// live figures, the hardware specs, and the per-instance rows — without any of
/// them re-implementing the reconcile. The reconcile is the whole point: see
/// `setItems` for the 36 ms → 0.12 ms measurement that produced it.
final class BodyStack: NSStackView {

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Install `items`, reusing the views already there when the shape has not
    /// changed.
    ///
    /// Every pane is re-rendered on every tick and the Sensors pane is ~260 rows.
    /// MEASURED (M5 Pro, 258 rows, offscreen harness): clearing the stack and
    /// rebuilding it costs 36 ms of CPU per tick — 8 ms creating views, the rest
    /// Auto Layout re-solving a stack whose arranged subviews all changed identity.
    /// Re-texting the same views costs 0.12 ms, because nothing touches a
    /// constraint. Rows whose content is unchanged are not even repainted.
    func setItems(_ items: [BodyItem]) {
        let existing = arrangedSubviews
        // Reuse only when the shapes line up exactly. A different count, or a
        // heading where a row was, means the constraint set has to change anyway.
        let reusable = existing.count == items.count
            && zip(existing, items).allSatisfy { view, item in
                switch item.kind {
                case .row:     return view is SystemPane.BarRow
                case .heading: return view is SystemPane.HeadingView
                case .figure:  return view is SystemPane.FigureView
                case .group:   return view is SystemPane.GroupHeaderView
                }
            }
        guard reusable else { return rebuild(items) }
        for (view, item) in zip(existing, items) {
            (view as? PaneBodyView)?.apply(item)
        }
    }

    /// Told which group header was clicked. The stack does not own the expanded
    /// state — the pane does, because the pane is what rebuilds the list from it.
    var onToggleGroup: ((String) -> Void)?

    func restyleRows() {
        arrangedSubviews.forEach { ($0 as? PaneBodyView)?.restyle() }
    }

    private func rebuild(_ items: [BodyItem]) {
        arrangedSubviews.forEach { removeArrangedSubview($0); $0.removeFromSuperview() }
        for item in items {
            let view: NSView
            var height: CGFloat?
            switch item.kind {
            case .row:     view = SystemPane.BarRow(item);      height = 22
            case .figure:  view = SystemPane.FigureView(item);  height = 42
            case .heading: view = SystemPane.HeadingView(item); height = nil
            case .group:
                let header = SystemPane.GroupHeaderView(item)
                header.onToggle = { [weak self] in self?.onToggleGroup?(item.label) }
                view = header
                height = 26
            }
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            if let height {
                view.heightAnchor.constraint(equalToConstant: height).isActive = true
            }
        }
    }
}

/// Shared chrome: a title, an optional caption, and a vertical list of rows. Keeps
/// the three panes visually identical to each other and to the rest of the app.
class SystemPane: NSView {

    let titleLabel = NSTextField(labelWithString: "")
    let captionLabel = NSTextField(labelWithString: "")
    let body = BodyStack()
    private let scroll = NSScrollView()
    /// Held so an accessory can be spliced in between the caption and the list
    /// without rebuilding the chrome. See `setAccessory`.
    private var scrollTop: NSLayoutConstraint!

    private final class FlippedClipView: NSClipView {
        override var isFlipped: Bool { true }

        /// A fresh clip view draws its OWN background, and `drawsBackground` on
        /// the scroll view only reaches the clip view that exists when it is set —
        /// every caller here assigns this one AFTERWARDS, so all four scrollers
        /// were painting an unstyled grey rectangle behind their content, with
        /// square corners, in an app whose own surfaces are rounded and black.
        ///
        /// Cleared here rather than at each call site so the order of two lines
        /// cannot bring it back.
        override var drawsBackground: Bool {
            get { false }
            set { }
        }
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
        body.restyleRows()
        customContent?.restyleForAppearanceChange()
    }

    private func buildChrome() {
        titleLabel.font = Palette.Font.sans(15, .semibold)
        captionLabel.font = Palette.Font.mono(10.5)
        captionLabel.maximumNumberOfLines = 2

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

    /// A pane whose content is not a list of rows.
    ///
    /// The Resources tab is two columns — a rail of live cards and a detail column
    /// for the selected one — which no arrangement of `BodyItem`s can express. It
    /// keeps the shared title and caption so it still reads as one of this family,
    /// and takes the whole area beneath them for itself. Removing the scroll view
    /// takes its constraints with it, which is why `scrollTop` needs no unwinding.
    func setContent(_ view: NSView & PaneContentView) {
        scroll.removeFromSuperview()
        customContent = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            view.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 12),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    private weak var customContent: (NSView & PaneContentView)?

    func restyle() {
        titleLabel.textColor = Palette.text
        captionLabel.textColor = Palette.dim
    }

    /// Install `items` as the body. See `BodyStack.setItems`, which owns the
    /// reconcile and the measurement behind it.
    func setBody(_ items: [BodyItem]) { body.setItems(items) }
    /// The list itself, for a pane that needs to hear about clicks in it.
    var bodyStack: BodyStack { body }

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

    /// A LIVE reading: its name small and quiet above it, the number itself set
    /// large. The counterpart to `BarRow`, which is what a fact that does not move
    /// looks like.
    ///
    /// Drawn rather than composed from two text fields, for the same reason `BarRow`
    /// is: these are re-texted on every tick, and an NSTextField invalidates its
    /// intrinsic size on every assignment.
    final class FigureView: NSView, PaneBodyView {
        private var label: String, value: String
        private var color: NSColor?

        init(_ item: BodyItem) {
            label = item.label; value = item.value; color = item.color
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
        }
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }

        func apply(_ item: BodyItem) {
            guard label != item.label || value != item.value || color != item.color
            else { return }
            label = item.label; value = item.value; color = item.color
            needsDisplay = true
        }

        func restyle() { needsDisplay = true }

        override func draw(_ dirtyRect: NSRect) {
            let nameAttrs = Palette.labelAttributes(Palette.faint, size: 9)
            let valueAttrs: [NSAttributedString.Key: Any] = [
                .font: Palette.Font.mono(19, .regular),
                .foregroundColor: color ?? Palette.text,
            ]
            (label.uppercased() as NSString).draw(at: NSPoint(x: 0, y: 2),
                                                  withAttributes: nameAttrs)
            (value as NSString).draw(at: NSPoint(x: 0, y: 15), withAttributes: valueAttrs)
        }
    }
}

/// The content view of a pane that has replaced the row list with its own layout.
///
/// One method, and it is the one thing the chrome cannot do for it: `Palette`
/// resolves at draw time and is not observed, so a theme flip has to be passed
/// down or the content keeps the outgoing appearance's ink until something moves.
protocol PaneContentView: AnyObject {
    func restyleForAppearanceChange()
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Network

final class NetworkPane: SystemPane {

    /// Owned by the pane, like the Fans tab's control strip and for the same
    /// reason: it is the only thing that uses it.
    let speedTest = SpeedTestStrip(frame: .zero)

    /// True while a speed test is transferring.
    ///
    /// The throughput readings below are about to show a spike this app caused,
    /// so the caption says so while it is happening. A monitor that makes a mess
    /// of its own readings without mentioning it is the quiet kind of dishonesty
    /// this project is meant to be the opposite of.
    private var testingNow = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessory(speedTest, height: speedTest.preferredHeight)
        speedTest.onLayoutChanged = { [weak self] in
            guard let self else { return }
            self.setAccessoryHeight(self.speedTest.preferredHeight)
        }
        speedTest.onActivity = { [weak self] running in
            self?.testingNow = running
        }
    }
    required init?(coder: NSCoder) { fatalError() }

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
            format: "%@ down · %@ up · loopback excluded%@",
            MetricUnit.bytesPerSecond.format(n.bytesInPerSec),
            MetricUnit.bytesPerSecond.format(n.bytesOutPerSec),
            // Said while it is happening, not afterwards. The spike below is ours.
            testingNow ? " · BETTERSTATS IS RUNNING A SPEED TEST — this traffic is its own"
                       : "")

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

    /// Wires the header clicks the first time the pane renders. The stack is
    /// rebuilt whenever the shape of the list changes, and `onToggleGroup` lives
    /// on the stack rather than on each header, so one hookup covers every
    /// rebuild.
    private func hookGroupToggles() {
        guard bodyStack.onToggleGroup == nil else { return }
        bodyStack.onToggleGroup = { [weak self] name in
            guard let self else { return }
            if expandedGroups.contains(name) { expandedGroups.remove(name) }
            else { expandedGroups.insert(name) }
            render()
        }
    }

    /// Which groups are open. Starts EMPTY — all shut — because the point of
    /// grouping 256 readings is that the pane opens as eight lines you can scan,
    /// not as 256 with headings sprinkled through them. Each header states its
    /// own count and hottest reading, so nothing has to be opened to be read.
    private var expandedGroups: Set<String> = []

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
        hookGroupToggles()

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

        // BY PURPOSE, not one flat column. This machine reports 256 temperatures
        // and 140 of them are called "Thermal sensor N"; hottest-first put four
        // unidentifiable keys above the CPU on a warm day, and finding the GPU
        // meant reading the list. Grouping is honest here because the naming layer
        // already establishes these families with cross-generation consensus and
        // measured behaviour — see `SensorNaming.Group`, which refuses to invent
        // any group the evidence does not support and keeps the 140 together.
        //
        // Each group states its own hottest and its count while shut, so a closed
        // group is still an answer rather than a thing to open.
        let grouped = Dictionary(grouping: all) { SensorNaming.group(forKey: $0.key) }
        for group in grouped.keys.sorted(by: { $0.order < $1.order }) {
            let readings = grouped[group]!.sorted { $0.value > $1.value }
            let hottest = readings.first?.value ?? 0
            let open = expandedGroups.contains(group.rawValue)
            items.append(.group(group.rawValue,
                                String(format: "%d · %.1f °C max", readings.count, hottest),
                                expanded: open))
            guard open else { continue }
            for t in readings {
                // Named families first-class; everything else keeps its raw SMC
                // key, because a guessed label is worse than an honest
                // four-character code. `name != key` is NOT the test for "we know
                // what this is": all 140 hedged temperatures have a name that
                // differs from their key. `isIdentified` is the flag the naming
                // layer actually publishes.
                items.append(.row(t.qualifiedName,
                                  String(format: "%.1f °C", t.value),
                                  fill: bar(t.value), color: tint(t.value),
                                  dim: !t.isIdentified))
            }
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

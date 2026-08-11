import AppKit
import PowerKit

/// The Resources tab: everything the app measures about the MACHINE, in one place.
///
/// SHAPE. A rail of small live graphs down the left, one per resource, and the
/// selected one opened out on the right as a large graph over a dense block of
/// figures. Borrowed from Windows' Task Manager Performance tab, which solves a
/// problem this tab had: a strip of five cards over one long scrolling list made
/// every resource compete for the same column of rows, so nothing got the room to
/// say anything. Here the rail answers "how is the machine" at a glance and the
/// detail answers "what about this one" without leaving the tab.
///
/// The rail's sparkline and the big graph are THE SAME SERIES. Selecting a card
/// makes that line big; it never shows you a different measurement than the one
/// you clicked.
///
/// The two halves of the detail are split on purpose. Numbers that MOVE are set
/// large and grouped together; facts that do not are small label/value pairs
/// beside them. That is the layout's main idea, and it happens to be the
/// distinction this project already cares most about — measured just now, versus
/// known since boot.
///
/// COST. This is the only tab that needs every subsystem at once, and it gets them
/// only while it is on screen: `SidebarView.Lens.needs` declares `.all` for this
/// case and `AppDelegate.visibleNeeds` unions that with whatever the menu bar is
/// bound to. That is unchanged by the rail — all six sparklines are on screen
/// together, so all six subsystems have to be live, and the tab costs exactly what
/// it did before. What IS gated is the detail's own extra reads: the per-process
/// thread sweep, the volume list and the interface addresses are paid for only by
/// the resource currently selected.
final class ResourcesPane: SystemPane {

    /// How much history the graphs keep. Fifteen minutes at the 2 s cadence is 450
    /// points per series across a ~700 pt plot, which the graph's own decimation
    /// reduces to one bucket per pixel — so a longer window would cost memory and
    /// draw exactly the same picture.
    ///
    /// IN MEMORY ONLY. There is no store behind these and nothing is written
    /// anywhere: close the app and the history is gone, which is what a live
    /// utilisation graph should do. It is also why these graphs do not mark their
    /// gaps — see `HistoryGraphView.bridgesGaps`.
    private let historySpan: TimeInterval = 15 * 60

    private let layout = ResourcesContent()

    /// Which card the rail has selected.
    ///
    /// Exposed because the bottom of the window follows it: the tab alone is not
    /// enough when six resources sit behind one tab, and answering all six with
    /// one subject is the same mistake as answering five tabs with one sort.
    var selectedResource: Resource { layout.selectedResource }

    /// Fired when the rail's selection changes, so the bottom can retarget at
    /// once rather than on the next tick — the lesson this pane taught in the
    /// first place.
    var onSelectResource: (() -> Void)? {
        get { layout.onSelectResource }
        set { layout.onSelectResource = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setContent(layout)
        titleLabel.stringValue = "Resources"
    }
    required init?(coder: NSCoder) { fatalError() }

    /// One tick's worth of everything.
    ///
    /// `sys` is nil before the first sample lands. `power` carries the battery-side
    /// figures, which are the only numbers here that are not a utilisation.
    func update(_ sys: SystemMetrics.Snapshot?, power: PowerMonitor.Snapshot?) {
        captionLabel.stringValue = summaryLine()
        guard let sys else {
            layout.waitForFirstSample()
            return
        }
        layout.update(sys, power: power, span: historySpan)
    }

    private func summaryLine() -> String {
        let f = MachineInfo.facts
        var parts = [f.model, f.chip, "\(f.coreSummary) cores"]
        parts.append(MetricUnit.bytes.format(Double(f.memoryBytes)))
        if let up = MachineInfo.uptime { parts.append("up \(MachineInfo.formatDuration(up))") }
        return parts.joined(separator: " · ")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Resources

/// The things the rail can show. Order is the rail's order, top to bottom.
enum Resource: CaseIterable {
    case cpu, memory, gpu, network, disk, sensors

    // NO PER-RESOURCE COLOUR ANY MORE, and this is the note rather than the
    // property.
    //
    // Each resource used to own an ink — CPU green, memory amber, GPU blue — on
    // the argument that one resource means one colour, so the rail and the detail
    // agree about what is being looked at. The argument holds for a chart with
    // several lines on it. It does not hold here, where the rail is six cards each
    // showing ONE line, and the detail shows ONE resource at a time: the colour
    // never distinguished anything from anything, because the name is already
    // beside the number.
    //
    // What it did instead was make the app change colour as you moved through it —
    // the same figure amber on one tab and blue on the next, six stacked cards
    // reading as six unrelated widgets. Reported as "some colours change from
    // resource tab to resource tab", which was exactly right.
    //
    // Everything here is `Palette.accent` now. The palette still has the other
    // hues and the ledger still uses them, where they DO separate things drawn
    // together.

    /// The y-axis NAME on the big graph. Named, never assumed: "%" and "MB/s" and
    /// "°C" are not interchangeable and a chart that does not say which it is
    /// invites the reader to supply the wrong one.
    var axisLabel: String {
        switch self {
        case .cpu:     return "% utilisation"
        case .memory:  return "GB in use"
        case .gpu:     return "% utilisation"
        case .network: return "MB/s"
        case .disk:    return "MB/s"
        case .sensors: return "°C"
        }
    }

    /// Pinned axis top, or nil to autoscale. A percentage means nothing unless 100
    /// is where 100 is, and a memory graph that rescaled itself would turn a
    /// hundred megabytes into a cliff.
    var axisMax: Double? {
        switch self {
        case .cpu, .gpu: return 100
        case .memory:    return Double(MachineInfo.facts.memoryBytes) / 1_073_741_824
        case .network, .disk, .sensors: return nil
        }
    }
}

/// One resource's live buffer and the strings describing it right now.
final class ResourceTrack {
    let resource: Resource
    /// Renamed at run time for the network, which titles itself after whatever link
    /// macOS is actually routing through — "Ethernet" with a cable in, "Wi-Fi"
    /// without. Everything else keeps a fixed name.
    var title: String
    /// The line under the title on the card: this resource in one phrase.
    var summary: String = "—"
    /// The hardware behind it, shown right-aligned beside the detail's heading.
    var hardware: String = ""
    var points: [HistoryGraphView.Point] = []
    /// A second quantity on the RIGHT axis, where one genuinely explains the
    /// first. Load and heat is the pairing worth having — a CPU graph that shows
    /// the temperature it produced answers "did that spike cost anything" without
    /// a second tab — and it is the same shape the fan graph uses for speed
    /// against temperature.
    ///
    /// Empty for the resources where there is no honest second axis. Memory
    /// against nothing, disk bytes against nothing: a second line invented to fill
    /// an axis is worse than an empty one.
    var companion: [HistoryGraphView.Point] = []
    var companionName = ""
    var companionUnit = "%"

    init(_ resource: Resource, title: String) {
        self.resource = resource
        self.title = title
    }

    /// Record one reading.
    ///
    /// A missing value appends NOTHING rather than a zero — a subsystem that was
    /// not sampled did not report zero. The graph draws the resulting hole as a
    /// break in the line and, unlike the battery history, does not mark it.
    func push(_ value: Double?, at now: Date, before cutoff: Date,
              companion second: Double? = nil, detail: ((Double) -> String)? = nil) {
        if let value, value.isFinite {
            points.append(.init(time: now, value: value,
                                detail: detail.map { $0(value) }))
        }
        if let second, second.isFinite {
            companion.append(.init(time: now, value: second,
                                   detail: String(format: "%.1f %@", second, companionUnit)))
        }
        if let first = points.first, first.time < cutoff {
            points.removeAll { $0.time < cutoff }
        }
        if let first = companion.first, first.time < cutoff {
            companion.removeAll { $0.time < cutoff }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Content — rail + detail

/// Internal, not private, so a test can render the panel itself: rendering the
/// whole pane instead measured its INSET rather than its corner radius, and
/// passed against a square panel.
final class ResourcesContent: NSView, PaneContentView {

    /// Wide enough for a 78 pt sparkline, the gutters, and a two-line label that
    /// can hold "Peer-to-peer Wi-Fi" without truncating.
    private static let railWidth: CGFloat = 214
    /// Card height and spacing, and the height the rail therefore is.
    ///
    /// Stated once because three things need it: the scroll's height, the panel
    /// drawn behind it, and where the live figures start underneath. Derived from
    /// the card count rather than typed as 378, so adding a resource moves all
    /// three together.
    static let cardHeight: CGFloat = 58
    private static let cardGap: CGFloat = 6
    private static var railContentHeight: CGFloat {
        CGFloat(Resource.allCases.count) * cardHeight
            + CGFloat(Resource.allCases.count - 1) * cardGap
    }

    private var tracks: [Resource: ResourceTrack] = [:]
    private var cards: [Resource: ResourceCard] = [:]
    private var selected: Resource = .cpu
    var selectedResource: Resource { selected }
    var onSelectResource: (() -> Void)?

    private let railStack = NSStackView()
    private let railScroll = NSScrollView()
    /// The live figures. Owned here rather than by the detail because they
    /// live in the rail's column now, under the cards.
    private let liveColumn = BodyStack()
    /// Rail cards and live figures in ONE scrolling document, so they cannot
    /// fight over a column too short for both.
    private let leftColumn = NSStackView()
    private let railGround = RailGround()
    private let detail = ResourceDetailView()

    /// Held so the CPU detail's census is only paid for while the CPU detail is
    /// what is on screen. See the cost note on `ResourcesPane`.
    private var census: MachineInfo.Census?

    /// The last tick's readings, kept so a CLICK can redraw from them.
    ///
    /// Selecting a card changed the highlight at once and left the readings
    /// underneath showing the previous resource until the next sample landed — up
    /// to two seconds of a tab that had visibly switched and was still describing
    /// the thing you clicked away from. The data was never missing; this view
    /// simply threw away the only copy it had after drawing it once.
    private var lastSample: (sys: SystemMetrics.Snapshot,
                             power: PowerMonitor.Snapshot?,
                             net: NetworkInventory.Snapshot,
                             span: TimeInterval)?

    /// What `renderDetail` last put in the two columns. A test seam: the rows
    /// themselves are views inside a stack, and reaching through them to ask what
    /// a click did would test AppKit rather than this.
    private(set) var lastLiveItems: [BodyItem] = []
    private(set) var lastSpecItems: [BodyItem] = []

    /// The panel this content sits on.
    ///
    /// It had none. `SystemPane` fills the pane with `Palette.background`, this
    /// view drew nothing, and the detail column drew nothing either — so the
    /// readings sat on whatever AppKit put behind them, with square corners in an
    /// app where every card, chip and graph is rounded. Reported as "doesn't look
    /// rounded to me", and the reason is that it was not the app's surface at all.
    ///
    /// Drawn here rather than with a layer so it uses the same `Palette` and the
    /// same `Radius.card` as the rest, and repaints on a theme flip like
    /// everything else.
    override func draw(_ dirtyRect: NSRect) {
        // TWO grounds, because there are two things here.
        //
        // The readings are on BLACK: they are the content, and content sits on the
        // app's own ground with the rounding as its only edge. A lighter card
        // under them was one surface more than the pane needs.
        //
        // The rail is on `surface`, because it is a CHOOSER. Without a ground
        // behind them the six cards read as six loose graphs rather than as a list
        // you pick from — the panel is what says these are tabs. That is also why
        // it is the whole column rather than a box per card: the group is the
        // thing being drawn.
        Palette.background.setFill()
        NSBezierPath(roundedRect: bounds,
                     xRadius: Palette.Radius.card,
                     yRadius: Palette.Radius.card).fill()

        // The rail's own ground is NOT drawn here any more — `RailGround` draws it,
        // inside the scroll view and behind the cards.
        //
        // It used to be painted here at the card stack's FITTING height while the
        // scroll view was free to be a different height entirely, and on a short
        // window those two disagreed badly: the scroll collapsed to one card and
        // the panel kept its full six-card height, so the panel covered the live
        // readings underneath. Drawing it in the same view as the cards makes the
        // disagreement impossible rather than unlikely, and it scrolls with them.
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        for resource in Resource.allCases {
            let track = ResourceTrack(resource, title: Self.defaultTitle(resource))
            switch resource {
            case .cpu, .gpu:
                track.companionName = "temp"
                track.companionUnit = "°C"
            case .sensors:
                track.companionName = "fans"
                track.companionUnit = "%"
            case .memory, .network, .disk:
                break   // no second quantity that explains the first
            }
            tracks[resource] = track
        }

        railStack.orientation = .vertical
        railStack.alignment = .leading
        railStack.spacing = Self.cardGap
        railStack.translatesAutoresizingMaskIntoConstraints = false
        for resource in Resource.allCases {
            let card = ResourceCard(resource: resource) { [weak self] in self?.select($0) }
            cards[resource] = card
            railStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: railStack.widthAnchor).isActive = true
        }
        cards[selected]?.isSelected = true

        // A scroller rather than a fixed column: six cards need ~390 pt and a short
        // window has less. Clipping the last card would hide a whole resource with
        // nothing saying it was there.
        //
        // The LIVE FIGURES SCROLL WITH IT, in one document rather than as a
        // sibling pinned under it. As siblings they competed for a column that
        // could not hold both — six cards and eleven readings want ~650 pt and a
        // short window offers ~520 — and the loser was the rail, which collapsed
        // to a single card while the panel behind it kept its full height and
        // covered the readings. Reported as "why is the graph tabs basically
        // inside the info". One document means they cannot overlap: it is taller
        // than the viewport and you scroll, which is what the scroll view was
        // added for in the first place.
        railGround.addSubview(railStack)
        leftColumn.orientation = .vertical
        leftColumn.alignment = .leading
        leftColumn.spacing = 18
        leftColumn.translatesAutoresizingMaskIntoConstraints = false
        leftColumn.addArrangedSubview(railGround)
        leftColumn.addArrangedSubview(liveColumn)

        railScroll.hasVerticalScroller = true
        railScroll.borderType = .noBorder
        railScroll.drawsBackground = false
        railScroll.contentView = FlippedClipView()
        railScroll.documentView = leftColumn
        railScroll.translatesAutoresizingMaskIntoConstraints = false

        for v in [railScroll, detail] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            // FILLS the column now, rather than hugging its cards. What it holds
            // is taller than it, which is the normal state of a scroll view.
            railScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            railScroll.topAnchor.constraint(equalTo: topAnchor),
            railScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            railScroll.widthAnchor.constraint(equalToConstant: Self.railWidth),

            leftColumn.leadingAnchor.constraint(equalTo: railScroll.contentView.leadingAnchor),
            leftColumn.topAnchor.constraint(equalTo: railScroll.contentView.topAnchor),
            leftColumn.widthAnchor.constraint(equalTo: railScroll.contentView.widthAnchor),

            // The ground hugs the cards exactly — it IS the group, so it ends at
            // the last card and never at the floor.
            railGround.widthAnchor.constraint(equalTo: leftColumn.widthAnchor),
            railStack.leadingAnchor.constraint(equalTo: railGround.leadingAnchor),
            railStack.trailingAnchor.constraint(equalTo: railGround.trailingAnchor),
            railStack.topAnchor.constraint(equalTo: railGround.topAnchor),
            railStack.bottomAnchor.constraint(equalTo: railGround.bottomAnchor),

            liveColumn.widthAnchor.constraint(equalTo: leftColumn.widthAnchor),

            detail.leadingAnchor.constraint(equalTo: railScroll.trailingAnchor, constant: 18),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor),
            detail.topAnchor.constraint(equalTo: topAnchor),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

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

    override var isFlipped: Bool { true }

    func restyleForAppearanceChange() {
        cards.values.forEach { $0.restyle() }
        // The live figures moved here from the detail, so their restyle has to
        // move with them — a reused row only repaints when its own content
        // changes, so a theme flip keeps the old appearance's ink until a value
        // happens to move.
        liveColumn.restyleRows()
        detail.restyle()
        needsDisplay = true
    }

    private static func defaultTitle(_ r: Resource) -> String {
        switch r {
        case .cpu:     return "CPU"
        case .memory:  return "Memory"
        case .gpu:     return "GPU"
        case .network: return "Network"
        case .disk:    return "Disk"
        case .sensors: return "Temperature"
        }
    }

    /// Internal rather than private so a test can click without a mouse.
    func select(_ resource: Resource) {
        guard resource != selected else { return }
        cards[selected]?.isSelected = false
        selected = resource
        cards[resource]?.isSelected = true
        onSelectResource?()

        // Redrawn from the LAST TICK'S readings, not from nothing.
        //
        // This used to pass nil, on the reasoning that the rows would be rebuilt
        // by the next tick — so the graph and heading switched instantly and the
        // numbers under them went on describing the resource you had just clicked
        // away from, for as long as two seconds. The readings were never
        // unavailable; they were simply not kept.
        //
        // The census is per-selection and is recomputed here for the same reason:
        // it is only gathered for CPU, so selecting CPU would otherwise show no
        // process or thread counts until the next sample. 0.48 ms, once, on a
        // click a person just made.
        census = resource == .cpu ? MachineInfo.census() : nil
        if let s = lastSample {
            renderDetail(s.sys, power: s.power, network: s.net, span: s.span)
        } else {
            renderDetail(nil, power: nil)
        }
    }

    func waitForFirstSample() {
        detail.showPlaceholder()
        liveColumn.setItems([.row("Waiting for the first sample.", "—", dim: true)])
    }

    // ── Tick ────────────────────────────────────────────────────────────────

    func update(_ sys: SystemMetrics.Snapshot, power: PowerMonitor.Snapshot?,
                span: TimeInterval) {
        let now = Date()
        let cutoff = now.addingTimeInterval(-span)
        let net = NetworkInventory.snapshot(now: now)

        push(sys, network: net, now: now, cutoff: cutoff)

        // Only the selected resource pays for its own extra reads. The census is
        // 0.48 ms of CPU across ~900 processes, which is affordable once a tick and
        // not worth paying on the five ticks where nothing displays it.
        census = selected == .cpu ? MachineInfo.census() : nil

        for (resource, track) in tracks {
            cards[resource]?.apply(track)
        }
        lastSample = (sys, power, net, span)
        renderDetail(sys, power: power, network: net, now: now, span: span)
    }

    private func push(_ sys: SystemMetrics.Snapshot, network net: NetworkInventory.Snapshot,
                      now: Date, cutoff: Date) {
        func track(_ r: Resource) -> ResourceTrack { tracks[r]! }

        let cpu = track(.cpu)
        // Load on the left, the heat it produced on the right.
        cpu.push(sys.cpu?.total, at: now, before: cutoff, companion: sys.cpuTemperature)
        cpu.summary = [sys.cpu.map { String(format: "%.0f%%", $0.total) },
                       sys.cpuTemperature.map { String(format: "%.0f °C", $0) }]
            .compactMap { $0 }.joined(separator: " · ")
        cpu.hardware = MachineInfo.facts.chip
        if cpu.summary.isEmpty { cpu.summary = "—" }

        let memory = track(.memory)
        // GIGABYTES, not a percentage. The axis is pinned to the machine's own RAM,
        // so the line's height is how much memory is in use rather than a fraction
        // whose denominator is off screen.
        memory.push(sys.memory.map { Double($0.used) / 1_073_741_824 }, at: now, before: cutoff)
        memory.summary = sys.memory.map {
            String(format: "%@ / %@ (%.0f%%)",
                   MetricUnit.bytes.format(Double($0.used)),
                   MetricUnit.bytes.format(Double($0.total)), $0.usedPercent)
        } ?? "—"
        memory.hardware = MetricUnit.bytes.format(Double(MachineInfo.facts.memoryBytes))

        let gpu = track(.gpu)
        gpu.push(sys.gpu?.utilization, at: now, before: cutoff,
                 companion: sys.gpuTemperature)
        gpu.summary = [sys.gpu.map { String(format: "%.0f%%", $0.utilization) },
                       sys.gpuTemperature.map { String(format: "%.0f °C", $0) }]
            .compactMap { $0 }.joined(separator: " · ")
        if gpu.summary.isEmpty { gpu.summary = "—" }
        gpu.hardware = GPUInfo.facts.model ?? ""

        // THE RENAME. Titled after the link macOS is actually routing through, the
        // way Task Manager's row says "Ethernet" with a cable in and "Wi-Fi"
        // without. Falls back to the generic name when nothing is primary, which is
        // what an offline machine honestly is.
        let network = track(.network)
        let primary = net.primary
        network.title = primary.map { $0.kind.title } ?? Self.defaultTitle(.network)
        network.hardware = primary?.displayName ?? primary?.bsdName ?? ""
        // The PRIMARY link's own throughput, not the machine's total, so the graph
        // and the title are about the same thing. `rate(for:)` returns nil rather
        // than zero for a link that had no baseline this tick — see
        // `NetworkThroughput.Sample.measured`.
        let primaryRate = primary.flatMap { iface in sys.network?.rate(for: iface.bsdName) }
        network.push(primaryRate.map { ($0.inPerSec + $0.outPerSec) / 1e6 },
                     at: now, before: cutoff)
        network.summary = primaryRate.map {
            String(format: "↓ %@  ↑ %@",
                   MetricUnit.bytesPerSecond.format($0.inPerSec),
                   MetricUnit.bytesPerSecond.format($0.outPerSec))
        } ?? "—"

        let disk = track(.disk)
        // Megabytes per second, not bytes: the graph labels its axis with "%g", so a
        // raw byte rate would print "5e+07" up the side of the plot.
        disk.push(sys.disk.map { $0.totalPerSec / 1e6 }, at: now, before: cutoff)
        disk.summary = sys.disk.map {
            String(format: "R %@  W %@",
                   MetricUnit.bytesPerSecond.format($0.bytesReadPerSec),
                   MetricUnit.bytesPerSecond.format($0.bytesWrittenPerSec))
        } ?? "—"
        disk.hardware = sys.disk?.devices.first(where: { $0.identity.isInternal })?
            .identity.product ?? ""

        let sensors = track(.sensors)
        // The other way round for temperature: the heat is the subject, and what
        // the machine is DOING about it is the second line.
        sensors.push(sys.cpuTemperature, at: now, before: cutoff,
                     companion: sys.fans.isEmpty ? nil
                        : sys.fans.averageLoad * 100)
        sensors.summary = sys.sensorsSampled
            ? [sys.cpuTemperature.map { String(format: "CPU %.0f °C", $0) },
               sys.gpuTemperature.map { String(format: "GPU %.0f °C", $0) }]
                .compactMap { $0 }.joined(separator: " · ")
            : "reading…"
        if sensors.summary.isEmpty { sensors.summary = "—" }
        sensors.hardware = sys.fans.isEmpty ? "" : "\(sys.fans.count) fans"
    }

    // ── Detail ──────────────────────────────────────────────────────────────

    private func renderDetail(_ sys: SystemMetrics.Snapshot?,
                              power: PowerMonitor.Snapshot?,
                              network: NetworkInventory.Snapshot? = nil,
                              now: Date = Date(),
                              span: TimeInterval = 15 * 60) {
        guard let track = tracks[selected] else { return }
        detail.show(track: track, now: now, span: span)
        guard let sys else { return }
        let net = network ?? NetworkInventory.snapshot(now: now)
        let (live, specs) = build(selected, sys: sys, power: power, network: net)
        lastLiveItems = live
        lastSpecItems = specs
        liveColumn.setItems(live)
        detail.setSpecs(specs)
    }

    /// The two columns for one resource: what is moving, and what is fixed.
    private func build(_ resource: Resource, sys: SystemMetrics.Snapshot,
                       power: PowerMonitor.Snapshot?,
                       network net: NetworkInventory.Snapshot)
        -> (live: [BodyItem], specs: [BodyItem]) {
        switch resource {
        case .cpu:     return cpuDetail(sys)
        case .memory:  return memoryDetail(sys)
        case .gpu:     return gpuDetail(sys, power: power)
        case .network: return networkDetail(sys, net: net)
        case .disk:    return diskDetail(sys)
        case .sensors: return sensorsDetail(sys)
        }
    }

    private func cpuDetail(_ sys: SystemMetrics.Snapshot)
        -> (live: [BodyItem], specs: [BodyItem]) {
        var live: [BodyItem] = [.heading("Now")]
        if let c = sys.cpu {
            live.append(.figure("Utilisation", String(format: "%.1f%%", c.total),
                                color: Palette.accent))
        } else {
            live.append(.figure("Utilisation", "—"))
        }
        if let census {
            live.append(.figure("Processes", Self.grouped(census.processes)))
            live.append(.figure("Threads", Self.grouped(census.threads)))
            if !census.isComplete {
                // The shortfall is stated, not hidden. See `MachineInfo.census`:
                // an unprivileged process is refused the thread count of anything
                // it does not own, and this machine can read ~560 of ~900.
                live.append(.row("counted in",
                                 "\(census.processesRead) of \(census.processes) processes",
                                 dim: true))
            }
        }
        if let up = MachineInfo.uptime {
            live.append(.figure("Up time", MachineInfo.formatDuration(up)))
        }
        if let t = sys.cpuTemperature {
            live.append(.figure("Temperature", String(format: "%.0f °C", t),
                                color: Self.heatTint(t)))
        }
        if let c = sys.cpu {
            live.append(.heading("This interval"))
            live.append(.row("User", String(format: "%.1f%%", c.user), dim: true))
            live.append(.row("System", String(format: "%.1f%%", c.system), dim: true))
            live.append(.row("Idle", String(format: "%.1f%%", c.idle), dim: true))
        }

        let f = MachineInfo.facts
        var specs: [BodyItem] = [.heading("Processor")]
        specs.append(.row("Chip", f.chip, dim: true))
        specs.append(.row("Model identifier", f.model, dim: true))
        specs.append(.row("Cores", "\(f.physicalCores) physical · \(f.logicalCores) logical",
                          dim: true))
        // The kernel's OWN names for the clusters — this machine calls them "Super"
        // and "Performance", not "performance" and "efficiency". See
        // `MachineInfo.CoreLevel`.
        for level in f.coreLevels {
            var parts = ["\(level.physical) cores"]
            if let l1 = level.l1dCacheBytes {
                parts.append("L1d \(MetricUnit.bytes.format(Double(l1)))")
            }
            if let l2 = level.l2CacheBytes {
                parts.append("L2 \(MetricUnit.bytes.format(Double(l2)))")
            }
            specs.append(.row(level.name, parts.joined(separator: " · "), dim: true))
        }
        specs.append(.heading("System"))
        specs.append(.row("Memory", MetricUnit.bytes.format(Double(f.memoryBytes)), dim: true))
        specs.append(.row("macOS", f.osVersion, dim: true))
        return (live, specs)
    }

    private func memoryDetail(_ sys: SystemMetrics.Snapshot)
        -> (live: [BodyItem], specs: [BodyItem]) {
        var live: [BodyItem] = [.heading("Now")]
        if let m = sys.memory {
            live.append(.figure("In use",
                                String(format: "%@  (%.0f%%)",
                                       MetricUnit.bytes.format(Double(m.used)), m.usedPercent),
                                color: Palette.accent))
            live.append(.figure("Free", MetricUnit.bytes.format(Double(m.free))))
            live.append(.heading("Breakdown"))
            // The same split the app already computes, and the same one Activity
            // Monitor shows — app + wired + compressed IS "used", so these three
            // add up to the figure above rather than being a second opinion on it.
            live.append(.row("App", MetricUnit.bytes.format(Double(m.app)), dim: true))
            live.append(.row("Wired", MetricUnit.bytes.format(Double(m.wired)), dim: true))
            live.append(.row("Compressed", MetricUnit.bytes.format(Double(m.compressed)),
                             dim: true))
        } else {
            live.append(.figure("In use", "—"))
        }
        if let swap = MachineInfo.swap() {
            live.append(.heading("Swap"))
            live.append(.row("Used", MetricUnit.bytes.format(Double(swap.usedBytes)), dim: true))
            live.append(.row("Backing store",
                             MetricUnit.bytes.format(Double(swap.totalBytes)), dim: true))
            live.append(.row("Encrypted", swap.isEncrypted ? "yes" : "no", dim: true))
        }

        let f = MachineInfo.facts
        var specs: [BodyItem] = [.heading("Memory")]
        specs.append(.row("Installed", MetricUnit.bytes.format(Double(f.memoryBytes)), dim: true))
        if let usable = f.usableMemoryBytes, usable < f.memoryBytes {
            // What the kernel will hand out, against what is physically fitted. The
            // difference is firmware and carve-outs, and it is ~0.9 GB here.
            specs.append(.row("Available to macOS", MetricUnit.bytes.format(Double(usable)),
                              dim: true))
        }
        if let page = f.pageSizeBytes {
            specs.append(.row("Page size", MetricUnit.bytes.format(Double(page)), dim: true))
        }
        // NO SPEED, SLOT OR FORM-FACTOR ROW. There is no DIMM and no SPD to read
        // one from; see `MachineInfo.memoryModuleSpeed` for what was searched.
        specs.append(.heading("Chip"))
        specs.append(.row("Unified with", f.chip, dim: true))
        specs.append(.row("Shared with the GPU", "yes — one pool, no VRAM of its own",
                          dim: true))
        return (live, specs)
    }

    private func gpuDetail(_ sys: SystemMetrics.Snapshot, power: PowerMonitor.Snapshot?)
        -> (live: [BodyItem], specs: [BodyItem]) {
        var live: [BodyItem] = [.heading("Now")]
        if let g = sys.gpu {
            live.append(.figure("Utilisation", String(format: "%.1f%%", g.utilization),
                                color: Palette.accent))
            if let r = g.rendererUtilization {
                live.append(.figure("Renderer", String(format: "%.1f%%", r)))
            }
            if let m = g.inUseMemory {
                live.append(.figure("Memory in use", MetricUnit.bytes.format(Double(m))))
            }
            if let a = g.allocatedMemory {
                live.append(.row("Allocated", MetricUnit.bytes.format(Double(a)), dim: true))
            }
        } else {
            live.append(.figure("Utilisation", "—"))
            live.append(.row("No accelerator reported statistics", "—", dim: true))
        }
        if let t = sys.gpuTemperature {
            live.append(.figure("Temperature", String(format: "%.0f °C", t),
                                color: Self.heatTint(t)))
        }
        // The one per-app GPU figure that exists, and it is apportioned — said here
        // rather than left for the user to infer from the Processes tab's "*".
        if let gpuW = power?.gpu_W {
            live.append(.row("Rail power", String(format: "%.2f W", gpuW), dim: true))
        }

        var specs: [BodyItem] = [.heading("Graphics")]
        if let model = GPUInfo.facts.model { specs.append(.row("Chip", model, dim: true)) }
        if let cores = GPUInfo.facts.coreCount {
            specs.append(.row("GPU cores", "\(cores)", dim: true))
        }
        specs.append(.row("Memory", "unified — shares the machine's "
                          + MetricUnit.bytes.format(Double(MachineInfo.facts.memoryBytes)),
                          dim: true))
        specs.append(.heading("Note"))
        specs.append(.row("Utilisation is not power",
                          "a GPU at 100% and at 20% can draw similar watts", dim: true))
        return (live, specs)
    }

    private func networkDetail(_ sys: SystemMetrics.Snapshot, net: NetworkInventory.Snapshot)
        -> (live: [BodyItem], specs: [BodyItem]) {
        var live: [BodyItem] = [.heading("Now")]
        let primary = net.primary
        let rate = primary.flatMap { sys.network?.rate(for: $0.bsdName) }
        if let rate {
            live.append(.figure("Receive", MetricUnit.bytesPerSecond.format(rate.inPerSec),
                                color: Palette.accent))
            live.append(.figure("Send", MetricUnit.bytesPerSecond.format(rate.outPerSec)))
        } else {
            // Throughput only exists between two reads, and this pane may have just
            // been opened. "0 B/s" would be a claim of silence.
            live.append(.figure("Receive", "—"))
            live.append(.figure("Send", "—"))
        }
        if let n = sys.network {
            live.append(.heading("Whole machine"))
            live.append(.row("Download", MetricUnit.bytesPerSecond.format(n.bytesInPerSec),
                             dim: true))
            live.append(.row("Upload", MetricUnit.bytesPerSecond.format(n.bytesOutPerSec),
                             dim: true))
            // Every OTHER link carrying traffic. The primary one is the two figures
            // above; repeating it here would double-count it to the eye.
            let others = n.interfaces.filter { $0.name != primary?.bsdName }
            if !others.isEmpty {
                live.append(.heading("Other links"))
                let peak = others.first?.totalPerSec ?? 0
                for i in others.prefix(6) {
                    live.append(.row(Self.label(for: i.name, in: net),
                                     String(format: "%@ ↓  %@ ↑",
                                            MetricUnit.bytesPerSecond.format(i.inPerSec),
                                            MetricUnit.bytesPerSecond.format(i.outPerSec)),
                                     fill: peak > 0 ? i.totalPerSec / peak : 0,
                                     color: Palette.accent, dim: true))
                }
            }
        }

        var specs: [BodyItem] = [.heading("Adapter")]
        guard let primary else {
            specs.append(.row("No primary interface",
                              "macOS is not routing through any link", dim: true))
            return (live, specs)
        }
        // The name, only when it SAYS something the next row does not.
        //
        // macOS calls the Wi-Fi interface "Wi-Fi", so this printed "Name: Wi-Fi"
        // directly above "Connection type: Wi-Fi" — two rows carrying one fact.
        //
        // The obvious improvement is the network's name, and it is not available:
        // on macOS 27 the SSID is location data and every fast path is redacted
        // without Location Services permission. Measured here, associated with a
        // network at the time: CoreWLAN's `ssid()` returned nil, `ipconfig
        // getsummary` printed "<redacted>", and SCDynamicStore's `SSID_STR` was an
        // empty string. `system_profiler SPAirPortDataType` does return it and
        // takes 14.3 SECONDS, which is not a thing to do on a pane refresh.
        //
        // So this asks for a permission BetterStats does not otherwise need, and
        // the row is dropped instead of a location prompt being added to a system
        // monitor. On Ethernet and Thunderbolt the name is a real port name and
        // still earns its place.
        if let name = primary.displayName,
           name.caseInsensitiveCompare(primary.kind.title) != .orderedSame {
            specs.append(.row("Name", name, dim: true))
        }
        specs.append(.row("Connection type", primary.kind.title, dim: true))
        specs.append(.row("Interface", primary.bsdName, dim: true))
        if let speed = primary.linkSpeedBitsPerSec {
            specs.append(.row("Link speed", Self.bitRate(speed), dim: true))
        }
        if let mtu = primary.mtu { specs.append(.row("MTU", "\(mtu) bytes", dim: true)) }
        if let mac = primary.macAddress {
            specs.append(.row("Hardware address", mac, dim: true))
        }
        specs.append(.heading("Addresses"))
        if primary.ipv4.isEmpty && primary.ipv6.isEmpty {
            specs.append(.row("None assigned", "—", dim: true))
        }
        for address in primary.ipv4 { specs.append(.row("IPv4", address, dim: true)) }
        for address in primary.ipv6 { specs.append(.row("IPv6", address, dim: true)) }
        if !net.dnsServers.isEmpty || !net.searchDomains.isEmpty {
            specs.append(.heading("Resolver"))
            for server in net.dnsServers { specs.append(.row("DNS server", server, dim: true)) }
            for domain in net.searchDomains {
                specs.append(.row("Search domain", domain, dim: true))
            }
        }
        return (live, specs)
    }

    private func diskDetail(_ sys: SystemMetrics.Snapshot)
        -> (live: [BodyItem], specs: [BodyItem]) {
        var live: [BodyItem] = [.heading("Now")]
        if let d = sys.disk {
            live.append(.figure("Read", MetricUnit.bytesPerSecond.format(d.bytesReadPerSec),
                                color: Palette.accent))
            live.append(.figure("Write", MetricUnit.bytesPerSecond.format(d.bytesWrittenPerSec)))
            if !d.devices.isEmpty {
                live.append(.heading("By device"))
                let peak = d.devices.first?.totalPerSec ?? 0
                for device in d.devices {
                    live.append(.row(device.identity.product,
                                     String(format: "%@ read  %@ write",
                                            MetricUnit.bytesPerSecond.format(device.bytesReadPerSec),
                                            MetricUnit.bytesPerSecond.format(device.bytesWrittenPerSec)),
                                     fill: peak > 0 ? device.totalPerSec / peak : 0,
                                     color: Palette.accent, dim: true))
                }
            }
        } else {
            live.append(.figure("Read", "—"))
            live.append(.figure("Write", "—"))
            live.append(.row("Waiting for a second reading", "—", dim: true))
        }

        var specs: [BodyItem] = [.heading("Volumes")]
        let volumes = StorageInfo.volumes()
        if volumes.isEmpty {
            specs.append(.row("No browsable volume reported a capacity", "—", dim: true))
        }
        for v in volumes {
            guard let used = v.usedBytes, let fraction = v.usedFraction else {
                // A volume that will not report free space still gets its size
                // stated; inventing a "used" figure for it would not.
                specs.append(.row(v.name, MetricUnit.bytes.format(Double(v.totalBytes)),
                                  dim: true))
                continue
            }
            specs.append(.row(v.name,
                              String(format: "%@ of %@",
                                     MetricUnit.bytes.format(Double(used)),
                                     MetricUnit.bytes.format(Double(v.totalBytes))),
                              fill: fraction,
                              color: fraction >= 0.9 ? Palette.critical
                                   : (fraction >= 0.75 ? Palette.warn : Palette.accent)))
        }
        if let devices = sys.disk?.devices, !devices.isEmpty {
            specs.append(.heading("Devices"))
            for device in devices {
                var parts: [String] = []
                if let bus = device.identity.interconnect { parts.append(bus) }
                parts.append(device.identity.isInternal ? "internal" : "external")
                specs.append(.row(device.identity.product, parts.joined(separator: " · "),
                                  dim: true))
            }
        }
        specs.append(.heading("Note"))
        // The long-form evidence is on `DiskActivity`; this is the one-line version,
        // said where someone looking for a percentage will look for it.
        specs.append(.row("Why bytes and not a percentage",
                          "queue depth, not occupancy — it reaches 1394%", dim: true))
        return (live, specs)
    }

    private func sensorsDetail(_ sys: SystemMetrics.Snapshot)
        -> (live: [BodyItem], specs: [BodyItem]) {
        var live: [BodyItem] = [.heading("Now")]
        guard sys.sensorsSampled else {
            // NOT MEASURED is not the same as NONE — the same distinction the Fans
            // pane makes, for the same reason: this tab can be opened on a tick
            // that skipped the SMC.
            live.append(.figure("CPU", "—"))
            live.append(.row("Reading the sensors…", "—", dim: true))
            return (live, [.heading("Sensors"), .row("Waiting for the first SMC sweep", "—",
                                                     dim: true)])
        }
        live.append(.figure("CPU", sys.cpuTemperature.map { String(format: "%.0f °C", $0) } ?? "—",
                            color: sys.cpuTemperature.map(Self.heatTint)))
        live.append(.figure("GPU", sys.gpuTemperature.map { String(format: "%.0f °C", $0) } ?? "—",
                            color: sys.gpuTemperature.map(Self.heatTint)))
        if sys.fans.isEmpty {
            live.append(.row("Fans", "none reported", dim: true))
        } else {
            live.append(.heading("Fans"))
            for f in sys.fans {
                live.append(.row("Fan \(f.index + 1)", String(format: "%.0f rpm", f.currentRPM),
                                 fill: f.load,
                                 color: f.load > 0.75 ? Palette.warn : Palette.accent,
                                 dim: true))
            }
        }

        var specs: [BodyItem] = [.heading("Sensors")]
        specs.append(.row("CPU temperature", "mean of the Tp/Te core diodes", dim: true))
        specs.append(.row("GPU temperature", "mean of the Tg cluster sensors", dim: true))
        specs.append(.row("Every sensor on this machine", "Sensors tab", dim: true))
        specs.append(.row("Fan control", "Fans tab", dim: true))
        specs.append(.heading("Graph"))
        specs.append(.row("Plotted here", "CPU temperature", dim: true))
        return (live, specs)
    }

    // ── Formatting ──────────────────────────────────────────────────────────

    /// A link's name for a list: its display name where SystemConfiguration has
    /// one, and its BSD name otherwise — which is every `utun*`, and is exactly
    /// what a WireGuard tunnel should be called rather than a guess.
    private static func label(for bsdName: String, in net: NetworkInventory.Snapshot) -> String {
        guard let iface = net.interface(bsdName) else { return bsdName }
        guard let name = iface.displayName else { return "\(bsdName) · \(iface.kind.title)" }
        return "\(name) (\(bsdName))"
    }

    /// Internal rather than private: the bottom card states the same link speed,
    /// and two formatters for one number is how "1.0 Gb/s" and "1000 Mb/s" end up
    /// on one screen.
    static func bitRate(_ bits: UInt64) -> String {
        let v = Double(bits)
        if v >= 1e9 { return String(format: v >= 1e10 ? "%.0f Gb/s" : "%.1f Gb/s", v / 1e9) }
        if v >= 1e6 { return String(format: "%.0f Mb/s", v / 1e6) }
        return String(format: "%.0f Kb/s", v / 1e3)
    }

    private static let counter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    /// Cached, because building a NumberFormatter is expensive and this runs on
    /// every tick the CPU detail is open.
    private static func grouped(_ n: Int) -> String {
        counter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// 75 °C warm, 90 °C hot — the same scale the Sensors pane uses.
    private static func heatTint(_ c: Double) -> NSColor {
        c >= 90 ? Palette.critical : (c >= 75 ? Palette.warn : Palette.accent)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Graph variants

/// The full graph with its zoom and pan switched off.
///
/// These hold fifteen minutes of in-memory points and have no store behind them,
/// so there is nothing to zoom into and nothing to pan to — and because there is
/// no range picker here, an accidental scroll would pin the view to a stale window
/// with no way back. Hover and the crosshair are left alone: reading a value off
/// the line is the interaction that pays.
class FixedWindowGraphView: HistoryGraphView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
}

/// The same graph, in a box too small for an axis. See `HistoryGraphView.showsAxes`.
final class SparkGraphView: FixedWindowGraphView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        showsAxes = false
        showsGrid = false
        bridgesGaps = false
        // A thumbnail has nowhere to show a reading, and the card around it is a
        // button: a hover here competed with the click it exists to invite.
        respondsToHover = false
    }
    required init?(coder: NSCoder) { fatalError() }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: The rail card

/// One row of the rail: a sparkline, the resource's name, and its current reading.
///
/// The sparkline is `HistoryGraphView` with its axes off, not a second simpler
/// chart — the same decimation and the same min/max whiskers, so a spike that
/// shows in the big graph shows here too. A sparkline that quietly smoothed one
/// away would be a different class of object wearing the same colours.
final class ResourceCard: NSView {

    private let spark = SparkGraphView(frame: .zero)
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let resource: Resource
    private let onClick: (Resource) -> Void

    var isSelected = false { didSet { needsDisplay = true } }

    /// Pointer is over this card.
    ///
    /// The rail is a list of buttons and had nothing saying so under the pointer —
    /// only the cursor changed, which is the weakest possible signal and the one
    /// that disappears the moment someone is using a trackpad without looking at
    /// the arrow.
    private var isHovered = false { didSet { needsDisplay = true } }
    private var trackingAreaRef: NSTrackingArea?

    init(resource: Resource, onClick: @escaping (Resource) -> Void) {
        self.resource = resource
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = Palette.Font.sans(12, .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        valueLabel.font = Palette.Font.mono(10)
        valueLabel.lineBreakMode = .byTruncatingTail

        spark.translatesAutoresizingMaskIntoConstraints = false
        spark.wantsLayer = true
        spark.layer?.cornerRadius = Palette.Radius.chip
        spark.layer?.masksToBounds = true

        let text = NSStackView(views: [nameLabel, valueLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false

        addSubview(spark)
        addSubview(text)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 58),
            spark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            spark.centerYAnchor.constraint(equalTo: centerYAnchor),
            spark.widthAnchor.constraint(equalToConstant: 74),
            spark.heightAnchor.constraint(equalToConstant: 36),
            text.leadingAnchor.constraint(equalTo: spark.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Without this the rail is invisible to VoiceOver and to any automation: a
        // plain NSView with a mouseDown override is a button to a sighted user and
        // nothing at all to anyone else. Same bargain `SidebarView.RowView` makes.
        setAccessibilityRole(.button)
        setAccessibilityElement(true)
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityPerformPress() -> Bool {
        onClick(resource)
        return true
    }
    override func mouseDown(with event: NSEvent) { onClick(resource) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func viewDidChangeEffectiveAppearance() { restyle() }

    func restyle() {
        nameLabel.textColor = Palette.text
        valueLabel.textColor = Palette.dim
        needsDisplay = true
    }

    /// Take this tick's title, reading and points. Assignments are guarded because
    /// setting an NSTextField's `stringValue` invalidates its intrinsic size and
    /// re-solves the enclosing stack — six cards a tick, for strings that usually
    /// did not move.
    func apply(_ track: ResourceTrack) {
        if nameLabel.stringValue != track.title {
            nameLabel.stringValue = track.title
            setAccessibilityLabel(track.title)
        }
        if valueLabel.stringValue != track.summary { valueLabel.stringValue = track.summary }
        spark.yMax = resource.axisMax
        // ONE colour for every card, not one per resource.
        //
        // `Resource.color` still identifies a resource in the DETAIL view, where a
        // single line is being read. In the rail it made six cards six different
        // colours stacked on top of each other, which reads as six unrelated
        // widgets rather than one list — and the colour was never carrying
        // information there, since the card's own name is right beside it.
        spark.series = [.init(name: track.title, color: Palette.accent,
                              points: track.points, filled: true)]
    }

    /// The selected card: a wash, and nothing else.
    ///
    /// It used to carry a hard edge down its leading side in the RESOURCE's colour,
    /// borrowed from the process table's selected row. Two things were wrong with
    /// it here. The edge was a different colour on every card, so the one mark that
    /// should mean "this is the selected one" was also the mark that made six cards
    /// look like six unrelated widgets. And the rail is six items where the table
    /// is hundreds: a wash is unambiguous among six, which is what the edge was
    /// there to rescue in a long list.
    ///
    /// `Palette.selection` is one colour for every card, so selection reads the
    /// same wherever it lands.
    override func draw(_ dirtyRect: NSRect) {
        guard isSelected || isHovered else { return }
        // The SAME two weights the process table's rows use — full for selected,
        // 0.45 for hovered — in the same shape. A hover that looked different here
        // would be a second visual language for one idea, on a screen the table is
        // one click away from.
        //
        // Selection wins: a hovered selected card stays at full strength rather
        // than lightening under the pointer, which would read as losing state at
        // the moment of touching it.
        (isSelected ? Palette.selection
                    : Palette.selection.withAlphaComponent(0.45)).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1),
                     xRadius: Palette.Radius.inner,
                     yRadius: Palette.Radius.inner).fill()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: The detail column

/// The right-hand half: heading, one large graph, and the two property groups.
final class ResourceDetailView: NSView {

    private let heading = NSTextField(labelWithString: "")
    private let hardware = NSTextField(labelWithString: "")
    let graph = FixedWindowGraphView(frame: .zero)
    let specs = BodyStack()
    private let scroll = NSScrollView()

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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        heading.font = Palette.Font.sans(17, .semibold)
        hardware.font = Palette.Font.mono(11)
        hardware.alignment = .right
        hardware.lineBreakMode = .byTruncatingHead

        // GRID ON, unlike every other graph in this app. The others plot a rate
        // whose absolute level is read off the endpoint marker; this one is a
        // utilisation against a pinned axis, where the question is "how close to
        // the top" and the ruling is what answers it.
        graph.showsGrid = true
        // The departure this tab exists to make: a session-scoped live buffer marks
        // no gaps. See `HistoryGraphView.bridgesGaps`.
        graph.bridgesGaps = false
        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.wantsLayer = true
        graph.layer?.cornerRadius = Palette.Radius.inner
        graph.layer?.masksToBounds = true

        let columns = NSStackView(views: [specs])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.distribution = .fill
        columns.spacing = 24
        columns.translatesAutoresizingMaskIntoConstraints = false

        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView = FlippedClipView()
        scroll.documentView = columns
        scroll.translatesAutoresizingMaskIntoConstraints = false

        for v in [heading, hardware, graph, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        // The graph takes 42% of the column, which on a 640 pt pane is ~270 pt and
        // leaves the properties block the rest. Clamped so a short window still
        // gets a readable chart and a tall one does not spend two thirds of itself
        // on one line.
        let graphHeight = graph.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.42)
        graphHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: leadingAnchor),
            heading.topAnchor.constraint(equalTo: topAnchor),
            hardware.leadingAnchor.constraint(greaterThanOrEqualTo: heading.trailingAnchor,
                                              constant: 12),
            hardware.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            hardware.lastBaselineAnchor.constraint(equalTo: heading.lastBaselineAnchor),

            graph.leadingAnchor.constraint(equalTo: leadingAnchor),
            graph.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            graph.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            graphHeight,
            graph.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: graph.bottomAnchor, constant: 14),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            columns.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            columns.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            columns.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            specs.widthAnchor.constraint(equalTo: columns.widthAnchor),
        ])
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() { restyle() }

    func restyle() {
        heading.textColor = Palette.text
        hardware.textColor = Palette.dim
        specs.restyleRows()
    }

    /// Point the graph at a resource's buffer.
    ///
    /// The time domain is set EXPLICITLY to the whole retained window rather than
    /// left to follow the data, so the x axis holds still while the tab is open and
    /// a resource with two minutes of history draws two minutes of line in a fifteen
    /// minute frame instead of stretching it across the whole plot.
    func show(track: ResourceTrack, now: Date, span: TimeInterval) {
        if heading.stringValue != track.title { heading.stringValue = track.title }
        if hardware.stringValue != track.hardware { hardware.stringValue = track.hardware }
        graph.yAxisLabel = track.resource.axisLabel
        graph.yMax = track.resource.axisMax
        graph.timeDomain = (now.addingTimeInterval(-span), now)
        graph.series = [.init(name: track.resource.axisLabel, color: Palette.accent,
                              points: track.points, filled: true)]
        // The right axis, for the resources that have an honest second quantity.
        // The hover reads both, which is the whole point of putting them on one
        // chart rather than two.
        graph.rightAxisUnit = track.companionUnit
        graph.rightAxisLabel = track.companionName
        graph.rightSeries = track.companion.count >= 2
            ? .init(name: track.companionName, color: Palette.warn,
                    points: track.companion, filled: false)
            : nil
    }

    /// The specs only. The live figures moved to the rail's column — see
    /// `ResourcesContent.liveColumn` — so this view is the graph and the hardware
    /// facts, and the specs get the whole width instead of 58 % of it.
    func setSpecs(_ specItems: [BodyItem]) {
        specs.setItems(specItems)
    }

    /// Specs only, like `setSpecs`. The live column is the content view's now, so
    /// the caller places its half of the placeholder — leaving it here would have
    /// written into a stack that is no longer on screen, which is a placeholder
    /// that silently never appears.
    func showPlaceholder() {
        specs.setItems([])
    }
}


/// The rail's ground: the thing that says the six cards are a chooser rather than
/// six loose graphs.
///
/// Its own view, inside the scroll and behind the cards, because it used to be
/// painted by the parent at the card stack's fitting height while the scroll view
/// was free to be a different height entirely. On a short window those disagreed —
/// the scroll collapsed to one card, the panel kept six cards' worth, and the
/// panel covered the readings below. A ground that IS a sibling of the cards
/// cannot disagree with them about how tall they are, and it scrolls with them.
///
/// `surfaceAlt`, not `surface`: `surface` is 0x0A0E12 against a 0x000000 ground,
/// a difference of ten values that nobody can see. This is the token the table
/// header already uses for the same job.
final class RailGround: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Palette.surfaceAlt.setFill()
        NSBezierPath(roundedRect: bounds,
                     xRadius: Palette.Radius.card,
                     yRadius: Palette.Radius.card).fill()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

import AppKit
import PowerKit

/// Category rail.
///
/// Five destinations, and the grouping says what kind each is:
///
///   PER PROCESS   — the process table. One tab, not five: the old rail spent a row
///                   each on Battery, CPU, Memory, Disk and GPU, and every one of
///                   them drew the SAME table with two columns swapped. They are
///                   columns, so they are columns now, and the tab is sortable by
///                   any of them.
///   WHOLE MACHINE — their own panes. There is no unprivileged per-process network
///                   attribution on macOS, and a fan does not belong to a process.
///                   Pretending otherwise would be the same dishonesty as
///                   normalising a ledger to 100%.
///
/// ICONS, not words. The rail was 168 pt wide to hold "Whole machine" and a live
/// value beside every label; that is 18% of a 940 pt window spent on navigation for
/// a window whose job is fitting a wide table on screen. Each row is now a glyph
/// with the title — and the live value where one is being sampled — in its tooltip.
final class SidebarView: NSView {

    enum Lens: String, CaseIterable {
        case processes, resources, network, sensors, fans

        var title: String {
            switch self {
            case .processes: return "Processes"
            case .resources: return "Resources"
            case .network:   return "Network"
            case .sensors:   return "Sensors"
            case .fans:      return "Fans"
            }
        }

        /// True when this shows the process table rather than replacing it.
        var isPerProcess: Bool {
            switch self {
            case .processes: return true
            case .resources, .network, .sensors, .fans: return false
            }
        }

        /// SF Symbol drawn in the rail.
        ///
        /// Every one of these shipped in SF Symbols 1 or 2 (macOS 11), below this
        /// app's macOS 13 floor, so none of them can resolve to nil on a supported
        /// system — asserted in `SidebarIconTests` rather than assumed, because a
        /// missing symbol is a rail row that renders as nothing at all and the rail
        /// is now the only way to navigate.
        var symbolName: String {
            switch self {
            // NOT `list.bullet`, which is a checklist — a row of ticks reads as
            // things to do rather than things running. A stack of rectangles is
            // what this tab actually shows: many of something, one per row.
            case .processes: return "rectangle.stack"
            // NOT `speedometer`, which on a rail next to a network icon reads as a
            // speed test. A line chart with axes is what the tab is — the same
            // thing Task Manager puts on its Performance tab, for the same reason.
            case .resources: return "chart.line.uptrend.xyaxis"
            case .network:   return "network"
            case .sensors:   return "thermometer"
            // NOT `wind`, which is moving air rather than the thing moving it.
            // Blades also give the icon somewhere to turn — see `FanIconSpin`.
            case .fans:      return "fanblades"
            }
        }

        /// Whether this machine has anything to put in this tab.
        ///
        /// Only Fans can answer no, and only on a machine the SMC says has no
        /// fans — a MacBook Air, or a fanless desktop. `FanPresence` is where the
        /// evidence rule lives: a machine whose SMC could not be read is
        /// `.unknown` and keeps the tab, because "not measured" has never been
        /// allowed to mean "none" anywhere else in this app either.
        ///
        /// Exhaustive rather than defaulted, so a lens added later has to say
        /// whether it is conditional instead of inheriting an answer.
        func isOffered(whenFans fans: FanPresence.State) -> Bool {
            switch self {
            case .processes, .resources, .network, .sensors: return true
            case .fans: return FanPresence.showsFanTab(fans)
            }
        }

        /// The rail top to bottom: the per-process tab, then the whole-machine
        /// ones — the same two groups `build()` draws, split by the same predicate.
        ///
        /// Takes the machine as an argument so both answers can be tested on one
        /// Mac; `displayOrder` below is this applied to the Mac we are on.
        static func order(whenFans fans: FanPresence.State) -> [Lens] {
            let offered = allCases.filter { $0.isOffered(whenFans: fans) }
            return offered.filter(\.isPerProcess) + offered.filter { !$0.isPerProcess }
        }

        /// `build()` and the View menu both read this, so a lens added to
        /// `allCases` reaches the rail and ⌘1…⌘5 together or not at all, and a
        /// lens this machine cannot show is missing from both. The menu used to be
        /// the kind of thing that silently desynced from the sidebar; there is
        /// still no second list to forget.
        ///
        /// Resolved once, at first use: `FanPresence.onThisMac` reads the SMC and
        /// a Mac does not grow a fan while it is running.
        static let displayOrder: [Lens] = order(whenFans: FanPresence.onThisMac)

        /// The metric whose current value is appended to the tooltip.
        ///
        /// nil for Processes: the table is a hundred numbers, and no single one of
        /// them summarises it.
        var metric: MetricID? {
            switch self {
            case .processes: return nil
            case .resources: return .cpuUsage
            case .network:   return .networkThroughput
            case .sensors:   return .cpuTemperature
            case .fans:      return .fanSpeed
            }
        }

        /// One line saying what the tab contains, shown under the title on hover.
        /// A glyph alone is a guess; this is what makes an icon rail navigable by
        /// someone who has not learned it yet.
        var summary: String {
            switch self {
            case .processes:
                return "Every process, by battery, CPU, memory, disk and GPU."
            case .resources:
                return "Whole-machine graphs and readings: CPU, GPU, memory, "
                     + "network, disk, storage and temperatures."
            case .network:
                return "Throughput by interface and by process."
            case .sensors:
                return "Every temperature the SMC will report."
            case .fans:
                return "Fan speeds and their range."
            }
        }

        /// Which subsystems this tab is actually reading.
        ///
        /// The sampler asks for exactly this while the tab is on screen and nothing
        /// more — see `AppDelegate.visibleNeeds`. Resources is the tab that wants
        /// everything, which is precisely why the others must not.
        var needs: SystemMetrics.Needs {
            switch self {
            // The table comes from the per-process sweep, not from SystemMetrics.
            case .processes: return []
            case .resources: return .all
            case .network:   return .network
            // Both read temperatures or fan speeds, which is one SMC sweep.
            case .sensors, .fans: return .sensors
            }
        }
    }

    var onSelect: ((Lens) -> Void)?
    private(set) var selected: Lens = .processes

    /// Wide enough for a 30 pt icon well plus the 8 pt gutters, and no wider. The
    /// rail was 168.
    static let width: CGFloat = 52

    private let stack = NSStackView()
    private var rows: [Lens: RowView] = [:]
    /// The tabs this rail draws. Normally `Lens.displayOrder`, which is what this
    /// machine offers.
    private let lenses: [Lens]

    override init(frame: NSRect) {
        lenses = Lens.displayOrder
        super.init(frame: frame)
        build()
    }

    /// A rail for a named set of tabs.
    ///
    /// Exists so the fanless rail can be built and inspected on a machine that
    /// has fans — otherwise the only way to test that hiding a tab actually works
    /// is to own a MacBook Air.
    init(frame: NSRect, lenses: [Lens]) {
        self.lenses = lenses
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        lenses = Lens.displayOrder
        super.init(coder: coder)
        build()
    }

    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Palette.sidebar.setFill()
        dirtyRect.fill()
        Palette.line.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }
    override func viewDidChangeEffectiveAppearance() { redraw() }

    /// Force the rail and every row to repaint.
    func redraw() {
        needsDisplay = true
        rows.values.forEach { $0.needsDisplay = true }
    }

    private func build() {
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        // The system titlebar owns the space above, so no clearance is needed here.
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 6, bottom: 12, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            stack.topAnchor.constraint(equalTo: topAnchor),
        ])

        // The two groups the rail has always drawn, now separated by a rule rather
        // than by a caption — "PER PROCESS" does not fit beside a 52 pt icon well,
        // and the split is still worth showing.
        var previousWasPerProcess = true
        for (index, lens) in lenses.enumerated() {
            if index > 0, lens.isPerProcess != previousWasPerProcess {
                stack.addArrangedSubview(divider())
                previousWasPerProcess = lens.isPerProcess
            }
            add(lens)
        }

        rows[selected]?.isSelected = true
    }

    private func divider() -> NSView {
        let rule = RuleView()
        rule.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rule.heightAnchor.constraint(equalToConstant: 9),
            rule.widthAnchor.constraint(equalToConstant: 22),
        ])
        return rule
    }

    /// A hairline that resolves `Palette` at draw time, so it follows a theme
    /// switch like everything else rather than freezing the colour it was built
    /// with.
    private final class RuleView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            Palette.line.setFill()
            NSRect(x: 0, y: bounds.midY, width: bounds.width, height: 1).fill()
        }
        override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    }

    private func add(_ lens: Lens) {
        let row = RowView(lens: lens) { [weak self] l in self?.select(l) }
        rows[lens] = row
        stack.addArrangedSubview(row)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: 38),
            row.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    func select(_ lens: Lens) {
        // A lens this machine does not offer has no row, so selecting it would
        // light nothing while the content changed underneath — the rail and the
        // pane would disagree with no way to see which was right. The callers
        // that could reach one (a menu bar widget bound to a fan speed on a
        // fanless Mac) handle the refusal themselves; see `openFromWidget`.
        guard lens != selected, rows[lens] != nil else { return }
        rows[selected]?.isSelected = false
        selected = lens
        rows[lens]?.isSelected = true
        onSelect?(lens)
    }

    /// Refresh the tooltip's live value from the registry.
    ///
    /// The value used to sit beside the label in the rail. With icons there is
    /// nowhere to put it, so it rides in the tooltip — and it is APPENDED rather
    /// than substituted, so a subsystem this tab is not sampling shows the title
    /// and summary with no number instead of a stale one.
    func refreshValues() {
        for (lens, row) in rows {
            row.value = lens.metric.flatMap { MetricRegistry.shared.value(for: $0)?.text }
        }
    }

    /// Turn the fan glyph at the speed the fans are actually turning, or stop it.
    ///
    /// Called from the sampling tick, so it follows the machine rather than a
    /// clock. Zero rpm stops it: a parked fan is a reading worth being able to see
    /// at a glance, and a glyph that spins regardless would be decoration.
    /// How long one turn of the fan glyph takes, for a fan at `rpm`.
    ///
    /// PROPORTIONAL, and that is the property rather than the constant: the glyph
    /// turns `slowdown` times slower than the fan, so twice the rpm is always
    /// exactly twice the glyph speed. The ratio between any two readings is the
    /// ratio between the fans that produced them.
    ///
    /// It cannot be 1:1. These fans idle near 2300 rpm — 38 turns a second — and
    /// a glyph at that speed is a grey disc; at their 7800 rpm ceiling it is a
    /// grey disc that has been a grey disc for a while. The slowdown is what makes
    /// the difference between "idling" and "working hard" something you can see,
    /// which is the entire job.
    ///
    /// The clamps sit OUTSIDE the real operating range on purpose — they bite
    /// below 960 rpm and above 12 000, so a real fan is always in the proportional
    /// part. They exist for the readings that are not speeds: a fan reporting
    /// 1 rpm took twenty-four minutes a turn before the ceiling existed, which a
    /// test caught.
    static let glyphSlowdown: Double = 40
    static func glyphTurnSeconds(rpm: Double) -> TimeInterval {
        min(2.5, max(0.2, glyphSlowdown * 60 / max(rpm, 1)))
    }

    func setFanSpin(rpm: Double) {
        rows[.fans]?.setSpinning(rpm > 0, rpm: rpm)
    }

    /// Colour the Sensors glyph by the hottest thing on the machine, and pulse it
    /// once that is genuinely hot.
    func setTemperature(_ celsius: Double?) {
        rows[.sensors]?.setTemperature(celsius)
    }

    /// Point the Network glyph at the link actually carrying the traffic.
    func setNetworkKind(_ kind: NetworkInventory.Kind?) {
        rows[.network]?.setSymbol(kind?.symbolName ?? Lens.network.symbolName)
    }

    /// Test seams for the two glyphs that change.
    var isTemperatureAlarming: Bool { rows[.sensors]?.alarmAnimation != nil }
    var networkSymbolName: String? { rows[.network]?.symbolName }

    /// Whether the fan glyph is turning, and how fast. Test seams: the animation
    /// lives on the render server, so there is nothing to observe from here
    /// without asking the layer what it was given.
    var isFanGlyphSpinning: Bool { rows[.fans]?.spinAnimation != nil }
    var fanGlyphTurnSeconds: TimeInterval? { rows[.fans]?.spinAnimation?.duration }

    // ── Row ─────────────────────────────────────────────────────────────────

    private final class RowView: NSView {
        private let lens: Lens
        private let onClick: (Lens) -> Void
        private let icon = NSImageView()

        var isSelected = false { didSet { restyle(); needsDisplay = true } }
        var value: String? {
            didSet {
                guard value != oldValue else { return }   // toolTip assignment is not free
                updateTooltip()
            }
        }

        /// Turn the fan glyph while the machine's fans are turning.
        ///
        /// CORE ANIMATION, not the app's own driver. This is the one motion in the
        /// app that is not a response to the user, so it is the one that must not
        /// cost the app anything to keep going: a `CABasicAnimation` runs on the
        /// window server, which turns the layer without waking this process at
        /// all. The alternative — ticking a redraw at 60 Hz for as long as the
        /// window is open — is exactly the heartbeat `Motion` exists to avoid.
        ///
        /// It stops when the fans stop, so a machine sitting with its fans parked
        /// is still and the icon means something: motion here is a reading, not
        /// decoration.
        var spinAnimation: CABasicAnimation? {
            icon.layer?.animation(forKey: "spin") as? CABasicAnimation
        }

        var alarmAnimation: CABasicAnimation? {
            icon.layer?.animation(forKey: "alarm") as? CABasicAnimation
        }

        /// Colour the thermometer by what it is reading, and make it pulse once
        /// the machine is genuinely hot.
        ///
        /// The same scale everything else in the app uses — see
        /// `LedgerBarView.temperatureInk`, which the Sensors rows, the Resources
        /// rows and the spread bar all read. A tab that went red at a different
        /// temperature from the rows inside it would be two opinions.
        ///
        /// The PULSE is reserved for critical, and it is the second exception to
        /// this app not animating on its own. It earns that the way the fan glyph
        /// does — Core Animation, so the window server pulses it and this process
        /// never wakes — and unlike the fan it is a state nobody should be in for
        /// long. A colour alone is easy to miss on a rail you are not looking at.
        func setTemperature(_ celsius: Double?) {
            guard lens == .sensors else { return }
            temperature = celsius
            restyle()
            icon.wantsLayer = true
            guard let layer = icon.layer else { return }
            let critical = (celsius ?? 0) >= 90
            guard critical else { return layer.removeAnimation(forKey: "alarm") }
            guard layer.animation(forKey: "alarm") == nil else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.35
            pulse.duration = 0.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            layer.add(pulse, forKey: "alarm")
        }

        /// The last reading, so `restyle` can re-apply the tint after a theme
        /// change or a selection without being handed it again.
        private var temperature: Double?

        /// Swap the glyph, keeping the symbol configuration the rail was built
        /// with — a resized image blurs where a reconfigured symbol does not.
        private(set) var symbolName: String = ""

        func setSymbol(_ name: String) {
            guard name != symbolName else { return }   // NSImage lookup is not free
            symbolName = name
            icon.image = NSImage(systemSymbolName: name, accessibilityDescription: lens.title)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        }

        func setSpinning(_ spinning: Bool, rpm: Double = 0) {
            guard lens == .fans else { return }
            icon.wantsLayer = true
            guard let layer = icon.layer else { return }
            let key = "spin"
            guard spinning else { return layer.removeAnimation(forKey: key) }

            let seconds = SidebarView.glyphTurnSeconds(rpm: rpm)
            if let existing = layer.animation(forKey: key) as? CABasicAnimation,
               abs(existing.duration - seconds) < 0.05 { return }   // already right

            // NOTHING TO CENTRE. A layer-backed NSView already has its anchor in
            // the middle and its position set from its frame, so
            // `transform.rotation.z` turns about the centre for free.
            //
            // An earlier version set both by hand and moved the glyph 17 pt left,
            // because `position` is in the SUPERLAYER's coordinate space and it
            // was being given `icon.bounds.midX` — the icon's own. The icon sits
            // 17 pt into the rail, so that is exactly how far it slid. Reported as
            // the fan not being centred, and it was centred before this feature
            // touched it.
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = -Double.pi * 2   // clockwise on screen
            turn.duration = seconds
            turn.repeatCount = .infinity
            // Linear: a fan does not ease.
            turn.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(turn, forKey: key)
        }

        init(lens: Lens, onClick: @escaping (Lens) -> Void) {
            self.lens = lens
            self.onClick = onClick
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false

            // A symbol configuration rather than a resized image: SF Symbols are
            // vector glyphs with their own optical weights, and scaling a rendered
            // one blurs the strokes at 17 pt.
            icon.image = NSImage(systemSymbolName: lens.symbolName,
                                 accessibilityDescription: lens.title)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
            icon.imageScaling = .scaleNone
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            NSLayoutConstraint.activate([
                icon.centerXAnchor.constraint(equalTo: centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])

            // Without this the rail is invisible to VoiceOver and to any automation:
            // a plain NSView with a mouseDown override is a button to a sighted user
            // and nothing at all to anyone else. The label is the lens TITLE, which
            // is also what the menu-consistency test reads back — an icon rail must
            // not cost the name of the thing it navigates to.
            setAccessibilityRole(.button)
            setAccessibilityLabel(lens.title)
            setAccessibilityElement(true)
            updateTooltip()
            restyle()
        }
        required init?(coder: NSCoder) { fatalError() }

        override func accessibilityPerformPress() -> Bool {
            onClick(lens)
            return true
        }

        /// Title, what the tab holds, and the current reading if one is being
        /// sampled. This is the entire label for an icon rail, so it carries what
        /// the removed text row carried.
        private func updateTooltip() {
            var text = lens.title
            if let value { text += " — \(value)" }
            toolTip = text + "\n" + lens.summary
        }

        private func restyle() {
            // A hot machine outranks selection. The rail's accent says "this is
            // the tab you are on", which is a fact the user already knows; the
            // temperature ink says something they may not.
            if let t = temperature, t >= 75 {
                icon.contentTintColor = LedgerBarView.temperatureInk(t)
                return
            }
            icon.contentTintColor = isSelected ? Palette.accent : Palette.dim
        }

        override func draw(_ dirtyRect: NSRect) {
            guard isSelected else { return }
            Palette.selection.setFill()
            NSBezierPath(roundedRect: bounds,
                         xRadius: Palette.Radius.inner,
                         yRadius: Palette.Radius.inner).fill()
        }

        override func mouseDown(with event: NSEvent) { onClick(lens) }
        override func viewDidChangeEffectiveAppearance() { restyle(); needsDisplay = true }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}

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
    static func glyphTurnSeconds(rpm: Double, limits: FanPolicy.Limits? = nil) -> TimeInterval {
        // Across the fan's OWN range when we know it, and that is the difference
        // between a reading you can see and one you cannot.
        //
        // Strictly proportional to rpm, the glyph was right and useless: these
        // fans idle at 2318 and 2500 rpm, an eight percent spread, so the whole
        // visible difference between "resting" and "resting a bit harder" was
        // eight percent of a rotation rate. Reported as not noticeably speeding
        // up. Proportional to ABSOLUTE rpm is the wrong quantity — nobody is
        // comparing this machine's fans to another machine's; they are asking
        // where in its own range this one is sitting.
        //
        // Normalised, idle is a slow turn and flat out is a fast one, and the
        // journey between them uses the whole range. Still monotonic and still
        // linear, so faster is always visibly faster.
        let slow = 2.0, fast = 0.25
        guard let limits, limits.maxRPM > limits.minRPM else {
            // No range to normalise against: fall back to something proportional,
            // which is honest if less legible.
            return min(2.5, max(0.25, 40 * 60 / max(rpm, 1)))
        }
        let f = min(1, max(0, (rpm - limits.minRPM) / (limits.maxRPM - limits.minRPM)))
        return slow - (slow - fast) * f
    }

    func setFanSpin(rpm: Double, limits: FanPolicy.Limits? = nil) {
        rows[.fans]?.setSpinning(rpm > 0, rpm: rpm, limits: limits)
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

    /// Stop the two animations that run on their own.
    ///
    /// Everything else in this app moves because the pointer moved, and stops on
    /// its own within ~120 ms — see `Motion`. These two do not: the fan glyph
    /// turns for as long as the fans turn, and the sensors glyph pulses for as
    /// long as something is hot. Both are installed on a layer and keep running
    /// until removed, so a window that stops being drawn has to say so.
    ///
    /// Closing the window used to be enough on its own, because the layer tree
    /// went with it. A COVERED window still has its layers, so this is the case
    /// that needed saying out loud.
    ///
    /// There is no matching resume: the next `apply` sets both from live
    /// readings, and revealing the window refreshes immediately.
    func pauseSelfRunningAnimations() {
        rows[.fans]?.setSpinning(false)
        rows[.sensors]?.setTemperature(nil)
    }

    /// Test seams for the two glyphs that change.
    var isTemperatureAlarming: Bool { rows[.sensors]?.alarmAnimation != nil }

    /// Is there a fan glyph on screen at all? Spinning or still, SOMETHING has to
    /// be drawing it — the view's own image, or the layer that took it over.
    var hasVisibleFanGlyph: Bool { rows[.fans]?.hasVisibleGlyph ?? false }
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
        /// Something is drawing this row's glyph: either the image view still
        /// holds it, or the blade layer has taken it and is visible.
        var hasVisibleGlyph: Bool {
            if !icon.isHidden, icon.image != nil { return true }
            return !blades.isHidden && blades.contents != nil
        }

        var spinAnimation: CABasicAnimation? {
            blades.animation(forKey: "spin") as? CABasicAnimation
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
            glyphImage = NSImage(systemSymbolName: name, accessibilityDescription: lens.title)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
            // Not while the blades are carrying it — see `setSpinning`.
            if blades.isHidden || blades.superlayer == nil { icon.image = glyphImage }
            layoutBlades()
        }

        /// The turning glyph, on a layer this row OWNS.
        ///
        /// Not the image view's own backing layer, which is where two attempts
        /// went wrong. AppKit manages that layer's geometry and its anchor is NOT
        /// in the middle — the glyph turned about its top-right corner — while
        /// setting `anchorPoint` and `position` by hand fought AppKit's layout and
        /// slid the icon 17 pt sideways, because a view layer's `position` lives
        /// in its SUPERLAYER's coordinate space and it was being handed the icon's
        /// own.
        ///
        /// A sublayer has neither problem. Its position is in the icon's
        /// coordinate space, which is where the centre obviously is; nothing else
        /// writes to it; and it turns about whatever anchor it is given. The image
        /// view still draws every other tab's glyph — for this one it hands over.
        private let blades = CALayer()

        /// The glyph itself, kept aside because the image view stops holding it
        /// while the blades are turning. `tintedGlyph` bakes from this, so the
        /// blades still have something to draw once the view has let go.
        private var glyphImage: NSImage?

        func setSpinning(_ spinning: Bool, rpm: Double = 0,
                         limits: FanPolicy.Limits? = nil) {
            guard lens == .fans else { return }
            let key = "spin"
            guard spinning else {
                blades.removeAnimation(forKey: key)
                blades.isHidden = true
                icon.image = glyphImage   // the view takes the glyph back
                return
            }
            icon.wantsLayer = true
            guard let host = icon.layer else { return }
            if blades.superlayer == nil { host.addSublayer(blades) }
            // GEOMETRY needs bounds; the animation does not. An earlier version
            // guarded the whole function on non-zero bounds and returned, so a
            // spin asked for before the first layout never started and was never
            // retried — `layout` re-runs the geometry, and the animation is
            // already on the layer waiting for it.
            layoutBlades()
            blades.isHidden = false
            // The VIEW lets go of its image — and ONLY once the blades have taken
            // it. Not hidden: hiding it took the blades with it, since they are
            // its sublayer and a hidden view hides its whole layer tree, so the
            // tab went blank the moment the fans started turning.
            //
            // The guard matters because the blades bake their contents from the
            // icon's bounds, which are zero until the rail has laid out. Letting
            // go first leaves nothing drawing at all for a layout pass, and on the
            // very first spin that pass may never have happened. `layout` re-runs
            // `layoutBlades`, so the hand-off completes on its own.
            if blades.contents != nil { icon.image = nil }

            let seconds = SidebarView.glyphTurnSeconds(rpm: rpm, limits: limits)
            if let existing = blades.animation(forKey: key) as? CABasicAnimation,
               abs(existing.duration - seconds) < 0.05 { return }   // already right
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = -Double.pi * 2   // clockwise on screen
            turn.duration = seconds
            turn.repeatCount = .infinity
            turn.timingFunction = CAMediaTimingFunction(name: .linear)  // a fan does not ease
            blades.add(turn, forKey: key)
        }

        /// Keep the blade layer over the icon, centred, and in the current ink.
        ///
        /// On every layout, because it is derived from the icon's bounds and a
        /// one-time setup drifts the moment the rail changes size.
        private func layoutBlades() {
            guard lens == .fans, icon.bounds.width > 0,
                  let glyph = glyphImage else { return }
            // The GLYPH's size inside the icon's box, so the contents draw at their
            // natural scale rather than being stretched to fill a 22 pt square.
            blades.bounds = NSRect(origin: .zero, size: glyph.size)
            blades.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            blades.position = CGPoint(x: icon.bounds.midX, y: icon.bounds.midY)
            blades.contentsScale = window?.backingScaleFactor ?? 2
            blades.contents = tintedGlyph()
        }

        /// The symbol, rendered in the ink the rail would have drawn it in.
        ///
        /// A raw layer's `contents` is an image, and an image does not pick up
        /// `contentTintColor` the way a template does inside an NSImageView — so
        /// the tint is baked in here, and re-baked whenever `restyle` runs.
        private func tintedGlyph() -> NSImage? {
            guard let base = glyphImage else { return nil }
            let colour = icon.contentTintColor ?? Palette.dim
            return NSImage(size: base.size, flipped: false) { rect in
                base.draw(in: rect)
                colour.set()
                rect.fill(using: .sourceAtop)
                return true
            }
        }

        override func layout() {
            super.layout()
            layoutBlades()
        }

        init(lens: Lens, onClick: @escaping (Lens) -> Void) {
            self.lens = lens
            self.onClick = onClick
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false

            // Through `setSymbol`, so the glyph is recorded in one place. Set
            // straight onto the image view here, it was invisible to the blade
            // layer, which bakes its contents from that record — a fan that had
            // never had its symbol swapped would have had nothing to draw.
            setSymbol(lens.symbolName)
            icon.imageScaling = .scaleNone
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            NSLayoutConstraint.activate([
                icon.centerXAnchor.constraint(equalTo: centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                // A FIXED BOX, not the image's own size.
                //
                // Sized by its content, the view collapses to nothing the moment
                // its image is cleared — which is exactly what the spinning fan
                // does when it hands the glyph to its blade layer. The layer kept
                // its bounds while its parent shrank out from under it, so it drew
                // half a glyph up and left of centre: the fan sitting outside its
                // own tab, which is how it was reported.
                //
                // 22 pt holds a 15 pt symbol with room for its optical bounds, and
                // it is the same box whichever tab and whatever it is drawing.
                icon.widthAnchor.constraint(equalToConstant: 22),
                icon.heightAnchor.constraint(equalToConstant: 22),
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
            defer { layoutBlades() }   // the blades carry a baked-in tint
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

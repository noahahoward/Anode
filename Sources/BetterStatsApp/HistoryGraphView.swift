import AppKit

// HistoryGraphView — a self-contained drain-history graph.
//
// WHY THIS EXISTS: an instantaneous %/hr number jitters, and a jittery number
// reads as alarming. The same data as a line reads as a trend. This view is the
// "make it more consistent" answer: it shows the last N minutes so one noisy
// sample is seen in context instead of in isolation.
//
// DESIGN RULES (each one is load-bearing):
//  - Takes plain data in. No PowerMonitor, no singletons — the integrator owns
//    the wiring. That keeps it testable offscreen and reusable in any window.
//  - Semantic NSColors ONLY for chrome (background, grid, text) so light/dark
//    mode is automatic. Series colors are the caller's choice — color follows
//    the entity, and the entity is named by the caller, not by us. One
//    exception: the charging spans of `rightSeries` (see `drawRightSeries`).
//    That is a STATE of the caller's entity rather than a second entity, and
//    only this view knows where in the line the state changes, so the colour
//    comes from Palette here and is resolved at draw time like the rest of it.
//    TYPE and RADIUS do come from Palette, everywhere: a chart whose axis is
//    named in a different typeface from every other label in the window reads as
//    a chart someone dropped in. That is not a colour, and the rule above is
//    about colour.
//  - The y-axis autoscales to a *nice* 1/2/5×10ⁿ maximum WITH hysteresis. A
//    graph whose axis rescales every frame is exactly as jittery as the number
//    it replaced, which would defeat the whole point.
//  - Smoothing is GEOMETRIC ONLY. We decimate to ~one bucket per horizontal
//    point and draw the per-bucket mean as the line — but every bucket's true
//    min…max is drawn as a vertical whisker in the same color. A single-sample
//    spike therefore ALWAYS renders at full amplitude; it just renders as a
//    thin tick instead of yanking the line around. No EWMA, no median filter,
//    nothing that could hide a real event: the data is measured, and measured
//    data is never quietly edited for looks.
//  - Fail soft on every input: non-finite values are skipped, out-of-order
//    points are sorted, empty/one-point/flat series draw something sensible.
//    Every upstream source here is undocumented; the graph must never be the
//    thing that crashes.
//  - Zoom and pan are OVERRIDABLE, not final, so a caller that has nothing to
//    zoom into can switch them off without a second graph existing. The Resources
//    strip does exactly that: its cards hold fifteen minutes of in-memory points
//    and no store behind them, so a scroll that rewrote the axis would pin the
//    card to a stale window with nothing to put it back.
public class HistoryGraphView: NSView {

    // MARK: - Public data types

    public struct Point {
        public let time: Date
        public let value: Double
        /// Was the machine on the wall adapter at this instant? Carried on the
        /// POINT rather than as a parallel mask because `drawRightSeries`
        /// filters and re-sorts before drawing, and a parallel array silently
        /// desyncs from the points the moment one is dropped.
        ///
        /// nil means the caller does not know, which draws in the ordinary
        /// colour — an unknown must never render as a claim either way.
        public let onPower: Bool?
        /// What the hover readout says for this point, when the plotted number is
        /// not the whole story.
        ///
        /// The fan graph plots a PERCENTAGE — it has to, since it shares an axis
        /// with nothing and a second fan — but "48%" is not what anyone wants to
        /// read off a fan; "48% · 3760 rpm" is. Rather than teach the view about
        /// fans, the point carries the sentence its caller would write.
        ///
        /// On the POINT rather than as a parallel array, for exactly the reason
        /// `onPower` is: the drawing filters and re-sorts, and a parallel array
        /// desyncs the moment one point is dropped.
        public let detail: String?
        public init(time: Date, value: Double, onPower: Bool? = nil,
                    detail: String? = nil) {
            self.time = time
            self.value = value
            self.detail = detail
            self.onPower = onPower
        }

        // ── Two callers, two opposite words for one fact ─────────────────────
        //
        // The live buffer knows `onAC`; the store knows `on_battery`. Both used
        // to build the flag inline, and they disagreed: the live path negated
        // `onAC` to match the SHAPE of the store path's `!onBattery`, which is a
        // double negative. The 1H graph drew the machine as charging while it ran
        // the battery down, and the comment beside it asserted the two could not
        // disagree.
        //
        // So neither caller writes the sign any more. Naming the input is the
        // whole point: `charge(…, onAC:)` and `charge(…, onBattery:)` cannot be
        // confused for each other at a call site, and there is one place left
        // where the meaning of "charging" lives.

        /// A battery-percentage point whose source knows it is on the adapter.
        public static func charge(time: Date, percent: Double, onAC: Bool) -> Point {
            Point(time: time, value: percent, onPower: onAC)
        }

        /// A battery-percentage point whose source knows it is on battery.
        public static func charge(time: Date, percent: Double, onBattery: Bool) -> Point {
            Point(time: time, value: percent, onPower: !onBattery)
        }
    }

    public struct Series {
        public let name: String
        public let color: NSColor
        public let points: [Point]
        public let filled: Bool
        public init(name: String, color: NSColor, points: [Point], filled: Bool = false) {
            self.name = name
            self.color = color
            self.points = points
            self.filled = filled
        }
    }

    // MARK: - Public API

    /// The data. Setting it sanitizes once (filter non-finite, sort by time) so
    /// draw(_:) never has to defend itself, then schedules a redraw.
    public var series: [Series] = [] {
        didSet {
            sanitized = series.map {
                CleanSeries(name: $0.name, color: $0.color, filled: $0.filled,
                            points: Self.sanitize($0.points))
            }
            needsDisplay = true
        }
    }

    /// Drawn top-left, e.g. "%/hr". Text, not a unit conversion — this view
    /// draws whatever numbers it is handed and never re-units them.
    /// The points a series will actually draw, after sorting and dropping the
    /// non-finite ones. A test seam: the sanitise is where a per-point annotation
    /// would get separated from its value if it were held anywhere else.
    public func sanitizedPoints(inSeries index: Int) -> [Point] {
        guard sanitized.indices.contains(index) else { return [] }
        return sanitized[index].points
    }

    public var yAxisLabel: String = "" {
        didSet { needsDisplay = true }
    }

    /// nil = autoscale (nice-rounded, with hysteresis). Non-nil pins the top of
    /// the axis; data above it is clipped to the plot rect, not rescaled.
    /// The gridlines the right axis draws, and the ones the left copies when
    /// `sharesRightAxisScale` is set. One list, so "the same steps" is a fact
    /// rather than a coincidence maintained in two places.
    static let sharedAxisTicks: [Double] = [0, 25, 50, 75, 100]

    /// Height of a legend swatch. The two legends — the header strip and the
    /// hover card — drew the same mark from two copies of the same numbers.
    static let swatchH: CGFloat = 2.5

    public var yMax: Double? {
        didSet { needsDisplay = true }
    }

    /// A second series plotted against its OWN axis on the right, fixed to 0-100%.
    ///
    /// Exists so charge level and drain rate can be read together: the whole point
    /// is watching the battery fall faster when the rate spikes, and two series on
    /// one axis cannot show that — %/hr and % of charge are not the same quantity
    /// and sharing a scale would imply they are.
    ///
    /// The axis is pinned to 0-100 rather than autoscaled, so the line's HEIGHT
    /// always means charge level. An autoscaled charge axis would turn a 3% drop
    /// into a dramatic cliff.
    public var rightSeries: Series? {
        didSet { needsDisplay = true }
    }
    /// Put the left axis on the SAME 0-100 scale and the same gridlines as the
    /// right one.
    ///
    /// The two axes measure different things — %/hr against % — and that is
    /// exactly why sharing the scale is worth doing on the battery chart. A drain
    /// line drawn level with the 50 % gridline means "at this rate, half the
    /// battery in an hour", read straight off the picture with no arithmetic. The
    /// two quantities are commensurable in the only way that matters to someone
    /// looking at a battery: one is the rate at which the other is spent.
    ///
    /// THE COST IS RESOLUTION, and it is real. Ordinary drains sit between 5 and
    /// 20 %/hr, so the line lives in the bottom fifth of the plot and small
    /// changes are harder to see. That is the trade: legibility of the SHAPE for
    /// legibility of the MEANING.
    public var sharesRightAxisScale = false {
        didSet { if sharesRightAxisScale != oldValue { needsDisplay = true } }
    }

    /// The unit the RIGHT axis is counted in.
    ///
    /// It was "%" and nothing else, because the right axis was built for one
    /// caller: battery charge, which is a percentage. The fan graph puts a
    /// TEMPERATURE there — see `BottomContext.fans` — and inherited an axis whose
    /// ticks read "0%, 25%, 50%, 100%" beside a line that was degrees. A 51 °C
    /// reading drawn at the 50% gridline looks plausible, which is the worst kind
    /// of wrong: reported as "why are both sides percentages? I thought one side
    /// was going to be temps".
    ///
    /// 0-100 remains the range, and for a temperature that is honest rather than
    /// convenient — this hardware throttles well inside it, and a fixed scale lets
    /// two sessions be compared by eye.
    /// Every area already filled on this pass, so a fill drawn LATER can be cut
    /// by the ones under it.
    ///
    /// The rule the user set: where two gradients would overlap, the lower one
    /// wins and the higher one stops at it. Two translucent washes stacked read
    /// as a third value at the overlap — a number nobody measured — which is the
    /// same objection that kept multi-line graphs unfilled entirely.
    ///
    /// A CLIP rather than rebuilt bands, and that is what makes it correct when
    /// the lines cross: geometry decides what is on top at each x, so nothing
    /// depends on one series being "above" another for the whole span.
    private var filledSoFar = NSBezierPath()

    public var rightAxisUnit: String = "%" {
        didSet { if rightAxisUnit != oldValue { needsDisplay = true } }
    }

    public var rightAxisLabel: String = "" {
        didSet { needsDisplay = true }
    }

    /// Explicit time axis. When nil the axis is derived from the data, which is
    /// the right default for a live strip chart. Setting it is what makes zoom and
    /// pan possible at all: without an independent domain there is nothing to zoom
    /// — the axis would just snap back to whatever the data happened to span.
    public var timeDomain: (start: Date, end: Date)? {
        didSet { needsDisplay = true }
    }

    /// Called when the user zooms or pans, so the owner can re-query history at
    /// the new range instead of scaling up whatever is already in memory.
    public var onDomainChanged: ((Date, Date) -> Void)?

    /// Oldest data that exists. Panning stops here rather than scrolling off into
    /// an empty past the store could never fill.
    public var earliestAvailable: Date?

    /// Shortest and longest spans the axis may take.
    private let minSpan: TimeInterval = 60
    private let maxSpan: TimeInterval = 7 * 86400

    /// Whether this graph answers the pointer at all.
    ///
    /// A readout under the cursor needs somewhere to put the readout. The rail's
    /// sparklines are 74x36 with no axes and no room for a crosshair, and they
    /// sit inside a card that is itself a button — so a hover there fought the
    /// click it was meant to invite and reported a value nobody could read.
    ///
    /// Off means no tracking area is installed at all, rather than a handler that
    /// returns early: an unused tracking area still makes AppKit deliver
    /// mouse-moved events to a view for every pixel the pointer crosses.
    public var respondsToHover = true {
        didSet {
            if respondsToHover != oldValue {
                hoverPoint = nil
                needsDisplay = true
                updateTrackingAreas()
            }
        }
    }

    private var hoverPoint: NSPoint?
    private var trackingAreaRef: NSTrackingArea?
    private var panAnchor: (mouse: NSPoint, start: Date, end: Date)?

    /// Horizontal space reserved at the top-right for a control drawn over the
    /// graph by its owner. The legend stops short of it.
    public var headerTrailingInset: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    public var showsGrid: Bool = true {
        didSet { needsDisplay = true }
    }

    /// Draw a grey dashed line across a gap in the data.
    ///
    /// TRUE for the battery history, which is the caller this was built for. That
    /// series comes out of a persisted store, so a gap means THE MACHINE WAS OFF —
    /// hours that exist and were not measured. A bare hole there reads as a
    /// rendering fault, so the gap is stated explicitly, in grey, dashed, never in
    /// the series colour.
    ///
    /// FALSE for the Resources graphs, and the difference is the point. Those are
    /// session-scoped live buffers: no store behind them, nothing persisted,
    /// nothing to reconcile across a sleep. A gap there is a tick this process did
    /// not take — a dropped sample, a tab that was not on screen — and there is no
    /// span of absent history to account for, because the buffer only ever held
    /// this session. Marking it would be annotating the absence of an event rather
    /// than the presence of one. So the line simply stops and picks up again where
    /// sampling resumed.
    ///
    /// What does NOT change with this flag is the run splitting itself. Neither
    /// mode draws a straight line across unmeasured time; the only question here is
    /// whether the hole gets a label.
    public var bridgesGaps: Bool = true {
        didSet { needsDisplay = true }
    }

    /// Draw the axes — value ladder, time labels, gutters, header band.
    ///
    /// FALSE makes the view a sparkline: the same decimation, the same min/max
    /// whiskers, the same run splitting, drawn edge to edge with no room spent on
    /// chrome. It is not a second, simpler graph class — that is exactly what this
    /// file's header rules out — it is this graph in a box too small to name its
    /// own scale, which is why the caller must print the reading beside it.
    public var showsAxes: Bool = true {
        didSet { needsDisplay = true }
    }

    /// Optional band drawn behind the lines — e.g. the unattributed residual,
    /// shown as context rather than smeared into any series (rows must sum to a
    /// measured total; the residual is *printed*, and here it is *shown*).
    /// Pass empty arrays to clear.
    public func setBand(lower: [Point], upper: [Point], color: NSColor) {
        let lo = Self.sanitize(lower)
        let hi = Self.sanitize(upper)
        if lo.isEmpty || hi.isEmpty {
            band = nil
        } else {
            // Fail soft if the integrator passes an opaque color: an opaque
            // band would bury the lines it is meant to contextualize.
            let c = color.alphaComponent > 0.5 ? color.withAlphaComponent(0.15) : color
            band = BandData(lower: lo, upper: hi, color: c)
        }
        needsDisplay = true
    }

    // MARK: - Private state

    private struct CleanSeries {
        let name: String
        let color: NSColor
        let filled: Bool
        let points: [Point]  // finite values only, ascending time
    }

    private struct BandData {
        let lower: [Point]
        let upper: [Point]
        let color: NSColor
    }

    private var sanitized: [CleanSeries] = []
    private var band: BandData?

    /// The plot rect the last `draw(_:)` actually used, in view coordinates.
    ///
    /// Interaction has to invert exactly the mapping the drawing used. The left
    /// gutter is measured per frame from the widest y tick label, so it cannot be
    /// restated as a constant on the interaction side without drifting from it —
    /// and it did: hover reported a time from a rect ~10 pt narrower on each
    /// edge, which on a 7-day range is about two hours of lie in the tooltip, and
    /// scroll-zoom anchored on that wrong time slid the point out from under the
    /// cursor. So the rect is RECORDED, never recomputed. `.zero` until the first
    /// draw; `interactionPlot` supplies a nominal rect for that one frame.
    /// Readable (not writable) outside the class so an offscreen test can assert
    /// the geometry a real frame produced, rather than a second copy of the sums.
    private(set) var lastPlot: NSRect = .zero
    /// The time range the last `draw` mapped across `lastPlot`.
    ///
    /// Hover used to invert its own guess instead: `effectiveDomain` returned the
    /// explicit `timeDomain` when one was set, and otherwise assumed a flat
    /// "one hour ending now". But `draw` derives its range from the DATA's own
    /// extent when no domain is set, and those two are only equal by accident.
    /// When they differed, the x under the cursor was translated through the
    /// wrong range, so the sample dot landed nowhere near the crosshair — pinned
    /// to one end of the series while the cursor was at the other.
    ///
    /// Nil until the first draw, which is the only honest answer before there is
    /// a mapping to invert.
    private var lastDomain: (start: Date, end: Date)?

    // Axis hysteresis. `stableTop`/`stableBottom` are the currently displayed
    // axis limits. We grow immediately (data must never be silently clipped in
    // autoscale mode) but shrink only when the data has fallen below 45% of the
    // displayed top — otherwise a value oscillating around a nice boundary
    // (4.9 ↔ 5.1) would flip the axis every frame.
    private var stableTop: Double = 1.0
    private var stableBottom: Double = 0.0

    // MARK: - Init / view plumbing

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    // Opaque because draw(_:) fills the whole bounds — lets AppKit skip
    // compositing what's behind us on every 2 s redraw.
    public override var isOpaque: Bool { true }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true  // layout metrics depend on bounds
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true  // semantic colors resolve at draw time; force one
    }

    // MARK: - Sanitizing

    /// Drop NaN/infinite values, then sort by time. Done once at set time, not
    /// per frame. Sorting also repairs interleaved appends from the caller.
    private static func sanitize(_ points: [Point]) -> [Point] {
        var clean = points.filter { $0.value.isFinite }
        // Only sort if actually needed — the common case (append-only history)
        // is already ordered and this keeps the 2 s refresh cheap.
        if !clean.isEmpty {
            var ordered = true
            for i in 1..<clean.count where clean[i].time < clean[i - 1].time {
                ordered = false
                break
            }
            if !ordered { clean.sort { $0.time < $1.time } }
        }
        return clean
    }

    // MARK: - Nice numbers

    /// Smallest 1/2/5 × 10ⁿ ≥ v. The axis max snaps to these so it moves in
    /// deliberate steps, never continuously.
    private static func niceCeil(_ v: Double) -> Double {
        guard v > 0, v.isFinite else { return 1 }
        let exp = floor(log10(v))
        let base = pow(10, exp)
        let f = v / base  // 1…10
        let nice: Double = f <= 1 ? 1 : (f <= 2 ? 2 : (f <= 5 ? 5 : 10))
        return nice * base
    }

    /// How many steps the value ladder is allowed, for a plot this tall.
    ///
    /// Was a flat 5, which is a reasonable number for a chart that fills a window
    /// and a bad one for a chart 55 pt high: six 11 pt labels down a 55 pt axis
    /// touch each other, and a ladder whose rungs touch reads as a smear rather
    /// than as a scale. Even the battery graph's 95 pt axis was setting labels
    /// 16 pt apart. ~30 pt of air per rung is where a ladder reads as a ladder.
    ///
    /// The floor of 2 matters: one tick is not a scale, and zero ticks would take
    /// the left gutter to its 24 pt minimum with nothing in it.
    static func yTickTarget(forPlotHeight h: CGFloat) -> Int {
        guard h.isFinite, h > 0 else { return 2 }
        return max(2, min(5, Int(h / 30)))
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        // Cleared per pass: this records what has been filled during THIS draw,
        // and a path kept across frames would clip against last frame's shapes.
        filledSoFar = NSBezierPath()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldAntialias(true)

        // Background first — semantic, so aqua/darkAqua both come out right.
        Palette.background.setFill()
        bounds.fill()

        let tickFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let tickAttrs: [NSAttributedString.Key: Any] = [
            .font: tickFont,
            .foregroundColor: Palette.dim,
        ]
        // The axis NAME is a label, not a reading, so it wears the app's
        // small-label voice — the same uppercase kerned mono the table header and
        // the Resources cards use. Only the TYPE comes from Palette; the ink stays
        // semantic like the rest of this view's chrome.
        let axisNameAttrs = Palette.labelAttributes(Palette.dim)

        // ── Scales ──────────────────────────────────────────────────────────
        var dataMin = Double.infinity
        var dataMax = -Double.infinity
        var tMinD = Date.distantFuture
        var tMaxD = Date.distantPast
        func fold(_ pts: [Point]) {
            for p in pts {
                if p.value < dataMin { dataMin = p.value }
                if p.value > dataMax { dataMax = p.value }
                if p.time < tMinD { tMinD = p.time }
                if p.time > tMaxD { tMaxD = p.time }
            }
        }
        for s in sanitized { fold(s.points) }
        if let b = band { fold(b.lower); fold(b.upper) }
        let haveData = dataMax >= dataMin  // false when everything was empty/NaN

        // Vertical scale. yMax pins; otherwise nice-round with hysteresis.
        var top: Double
        var bottom: Double
        if sharesRightAxisScale {
            // The right axis is 0-100 and fixed; matching it is the whole point.
            top = 100
            bottom = 0
        } else if let pinned = yMax, pinned.isFinite, pinned > 0 {
            top = pinned
            bottom = 0
        } else {
            if haveData {
                // The grow test is against the DATA, not the candidate: testing
                // the candidate would flap the axis when dataMax oscillates just
                // under a ladder boundary (the 1.05 headroom moves the boundary,
                // so niceCeil(19.1*1.05)=50 but niceCeil(18.9*1.05)=20). Data
                // strictly inside the current top never triggers a grow.
                // The 5% headroom keeps a series riding exactly on a nice
                // number (flat 5.0) off the top border when we do rescale.
                let m = max(dataMax, 0)
                if m > stableTop || m < stableTop * 0.45 {
                    stableTop = Self.niceCeil(m * 1.05)  // niceCeil(0) = 1, so empty-ish data keeps a sane axis
                }
                // Negative values (charging shows as negative drain) extend the
                // bottom the same way; the common all-positive case pins at 0.
                let neg = max(-dataMin, 0)
                if neg > -stableBottom {
                    stableBottom = -Self.niceCeil(neg * 1.05)
                } else if neg < -stableBottom * 0.45 {
                    stableBottom = neg == 0 ? 0 : -Self.niceCeil(neg * 1.05)
                }
            }
            top = stableTop
            bottom = stableBottom
        }
        if !(top > bottom) { top = bottom + 1 }  // never a zero-height range

        // ── Layout ──────────────────────────────────────────────────────────
        // Vertical padding is settled FIRST, because how densely the value ladder
        // can be ruled depends on how much height there is to spend on it.
        //
        // A view with nothing in its header band should not reserve one. A
        // Resources card has no axis name (its own title carries the unit) and one
        // series (so no legend), and 18 pt of reserved air out of an 88 pt card is
        // a fifth of the plot. The battery graph names its axis and keeps the band.
        let headerIsEmpty = yAxisLabel.isEmpty && sanitized.count < 2 && headerTrailingInset == 0
        // A sparkline spends nothing on chrome: no header band, no time labels.
        let padTop: CGFloat = !showsAxes ? 2 : (headerIsEmpty ? 8 : 18)  // yAxisLabel + legend row
        let padBottom: CGFloat = showsAxes ? 15 : 2                      // time labels
        let plotHeight = bounds.height - padTop - padBottom

        // Left gutter sized to the widest y tick label so labels never collide
        // with the plot; recomputed per frame because the labels change with
        // the scale (cheap: ≤ 6 strings).
        var yTicks: [Double] = []
        if sharesRightAxisScale {
            // The right axis's own steps, verbatim. Computing "quarters of 100"
            // separately here would be two places that have to agree about what
            // the gridlines are, and the entire feature is that they do.
            yTicks = Self.sharedAxisTicks
        } else {
            let yTickStep = Self.niceCeil(
                (top - bottom) / Double(Self.yTickTarget(forPlotHeight: plotHeight)))
            var yTick = (bottom / yTickStep).rounded(.up) * yTickStep
            while yTick <= top + yTickStep * 0.001 {
                yTicks.append(yTick)
                yTick += yTickStep
            }
        }
        var maxYLabelW: CGFloat = 0
        for v in yTicks {
            let w = (Self.yLabel(v) as NSString).size(withAttributes: tickAttrs).width
            if w > maxYLabelW { maxYLabelW = w }
        }
        let padLeft: CGFloat = showsAxes ? max(maxYLabelW + 10, 24) : 2
        // Room for the right-hand 0-100 axis labels when a second series is present.
        let padRight: CGFloat = !showsAxes ? 2 : (rightSeries == nil ? 10 : 34)
        let plot = NSRect(x: padLeft, y: padBottom,
                          width: bounds.width - padLeft - padRight,
                          height: plotHeight)
        // Too small to be honest — an axis nobody can read is worse than no chart.
        // A sparkline has no axis to read, so the floor is only "is there room for a
        // line at all"; the number it accompanies is printed beside it in full.
        let minPlot: CGFloat = showsAxes ? 20 : 8
        guard plot.width > minPlot, plot.height > minPlot else { return }
        lastEndpointMarkers.removeAll(keepingCapacity: true)
        // Publish the geometry the rest of this frame draws with, so hover, the
        // sample dot and the zoom anchor all read the same rect the lines do.
        // Set after the size guard: a degenerate rect must never become the
        // interaction mapping.
        lastPlot = plot

        // Horizontal scale. Right edge = newest sample ("now" from the data's
        // point of view — this view has no clock of its own). A single point or
        // identical timestamps get a synthetic 60 s window so the axis still
        // means something.
        var tMax = tMaxD
        var span = haveData ? tMaxD.timeIntervalSince(tMinD) : 60
        if !haveData { tMax = Date() }
        // An explicit domain wins over the data's own extent, so an empty stretch
        // of history stays empty on screen instead of silently rescaling the axis
        // to whatever few points happen to exist.
        if let d = timeDomain, d.end > d.start {
            tMax = d.end
            span = d.end.timeIntervalSince(d.start)
        }
        // Is the right edge still "now"? Tolerance scales with the span, because
        // a live 7-day chart whose newest sample is four minutes old is still
        // live, while four minutes off the edge of a 60 s chart plainly is not.
        // Floored at 5 s so a 1 h view does not flip labels on ordinary tick
        // jitter.
        let liveEdge = abs(tMax.timeIntervalSinceNow) <= max(5, span * 0.02)
        if span < 1 { span = 60 }
        let tMin = tMax.addingTimeInterval(-span)
        // Publish the domain this frame actually drew, for the same reason
        // `lastPlot` is published: hover has to invert the EXACT mapping the
        // lines used. See `drawnDomain`.
        lastDomain = (tMin, tMax)

        func xFor(_ t: Date) -> CGFloat {
            plot.minX + CGFloat(t.timeIntervalSince(tMin) / span) * plot.width
        }
        func yFor(_ v: Double) -> CGFloat {
            plot.minY + CGFloat((v - bottom) / (top - bottom)) * plot.height
        }
        // Half-point snapping keeps 1 pt hairlines crisp at 1x and clean at 2x.
        func snap(_ v: CGFloat) -> CGFloat { floor(v) + 0.5 }

        /// Right axis is always 0-100, never autoscaled — see `rightSeries`.
        func yForRight(_ v: Double) -> CGFloat {
            plot.minY + CGFloat(min(max(v, 0), 100) / 100) * plot.height
        }

        // ── Grid, baseline, y labels ────────────────────────────────────────
        // Grid is recessive by construction: separatorColor is designed by the
        // system to sit just above the background in both appearances.
        //
        // `zeroY` is where the value axis reads zero, or the plot floor when the
        // axis never gets there. It is hoisted because three things need the same
        // line: the baseline below, the area fills, and the grid — which skips it
        // so the two rules do not stack into one double-weight hairline.
        let zeroY = snap(yFor(min(max(0, bottom), top)))
        if showsGrid {
            // lineSoft, not line. `separatorColor` — what this was — is far more
            // reserved than a solid rule, and swapping it for one turned the grid
            // from something the eye passes over into something it reads. The grid
            // is the thing you measure AGAINST; it is not a thing to look at.
            Palette.lineSoft.setStroke()
            let gridPath = NSBezierPath()
            gridPath.lineWidth = 1
            for v in yTicks {
                let y = snap(yFor(v))
                guard abs(y - zeroY) > 0.5 else { continue }
                gridPath.move(to: NSPoint(x: plot.minX, y: y))
                gridPath.line(to: NSPoint(x: plot.maxX, y: y))
            }
            gridPath.stroke()
        }
        // The one horizontal rule that is not decoration, and so the only one
        // drawn whether or not the grid is on — which matters, because every
        // caller in this app currently has the grid off.
        //
        // On the battery graph the axis goes NEGATIVE while the pack is filling,
        // and without this there is nothing on screen saying which side of zero
        // the machine is on: the line just wanders across an unmarked field. When
        // the axis does not reach zero this is the plot floor instead, which is
        // the same statement — it is where the measurement bottoms out.
        if showsAxes {
            Palette.line.setStroke()
            let baseline = NSBezierPath()
            baseline.lineWidth = 1
            baseline.move(to: NSPoint(x: plot.minX, y: zeroY))
            baseline.line(to: NSPoint(x: plot.maxX, y: zeroY))
            baseline.stroke()
            for v in yTicks {
                let s = Self.yLabel(v) as NSString
                let size = s.size(withAttributes: tickAttrs)
                var y = yFor(v) - size.height / 2
                y = min(max(y, 0), bounds.height - size.height)
                s.draw(at: NSPoint(x: padLeft - 6 - size.width, y: y), withAttributes: tickAttrs)
            }
        }

        // ── Time ticks ──────────────────────────────────────────────────────
        // Ladder of human steps; pick the smallest giving ≤ 6 ticks so labels
        // never crowd. Ticks count back from the newest sample.
        let ladder: [Double] = [5, 10, 15, 30, 60, 120, 300, 600, 900, 1800,
                                3600, 7200, 14400, 21600, 43200, 86400]
        let tStep = ladder.first { span / $0 <= 6 } ?? (86400 * (span / (6 * 86400)).rounded(.up))
        // One path for the whole time grid, stroked once. Per-tick strokes were
        // up to seven state changes a frame for seven hairlines, and the colour
        // was being re-set on every one of them.
        let timeGrid = NSBezierPath()
        timeGrid.lineWidth = 1
        var back: Double = 0
        while showsAxes {
            let x = xFor(tMax.addingTimeInterval(-back))
            if x < plot.minX - 0.5 { break }
            if showsGrid {
                timeGrid.move(to: NSPoint(x: snap(x), y: plot.minY))
                timeGrid.line(to: NSPoint(x: snap(x), y: plot.maxY))
            }
            // Relative ("-20s") only while the right edge really is now.
            //
            // Counting back from `tMax` is right for a live chart and WRONG the
            // moment the view is panned: the right edge moves with the pan, so
            // every label keeps reading "now, -20s, -40s" no matter where in
            // history you are. The data slides underneath and the axis says the
            // same thing — reported as "the bottom doesn't move with it", and
            // that is exactly what it does.
            //
            // Once the edge is not now, the labels become absolute clock times,
            // which move with the data because they name instants rather than
            // offsets from a moving origin.
            let s = (liveEdge ? Self.timeLabel(back)
                              : Self.clockLabel(tMax.addingTimeInterval(-back),
                                                span: span)) as NSString
            let size = s.size(withAttributes: tickAttrs)
            // "now" hugs the right edge; earlier ticks are centered.
            var lx = back == 0 ? x - size.width : x - size.width / 2
            lx = min(max(lx, 0), bounds.width - size.width)
            s.draw(at: NSPoint(x: lx, y: 1), withAttributes: tickAttrs)
            back += tStep
        }
        // Lighter than the value ladder. Time is the axis you read ALONG; the
        // value ladder is the one you read AGAINST, so ruling both at the same
        // weight makes a cross-hatch out of what should be a background.
        if !timeGrid.isEmpty {
            Palette.lineSoft.withAlphaComponent(0.55).setStroke()
            timeGrid.stroke()
        }

        guard haveData else {
            // Empty state: axes and a quiet message, never a blank rectangle —
            // a blank rectangle looks like a bug, an empty chart looks like
            // "not enough history yet", which is the truth.
            //
            // A sparkline is the one place that sentence is skipped: an 11 pt
            // string clipped by a 36 pt box says nothing legible, and the card that
            // owns the sparkline is already printing "—" as its reading.
            if showsAxes {
                let s = "no history yet" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: Palette.faint,
                ]
                let size = s.size(withAttributes: attrs)
                s.draw(at: NSPoint(x: plot.midX - size.width / 2, y: plot.midY - size.height / 2),
                       withAttributes: attrs)
            }
            // `haveData` is folded from the left series and band only, so a
            // charge line with no rate line behind it still belongs on screen —
            // it is the one thing this view can show when the rate is missing.
            if let r = rightSeries {
                drawRightSeries(r, plot: plot, xFor: xFor, yForRight: yForRight,
                                tickAttrs: tickAttrs)
            }
            if showsAxes { drawHeader(nameAttrs: axisNameAttrs, legendAttrs: tickAttrs) }
            return
        }

        // ── Band (behind everything data-colored) ───────────────────────────
        if let b = band {
            ctx.saveGState()
            plot.clip()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: xFor(b.upper[0].time), y: yFor(b.upper[0].value)))
            for p in b.upper.dropFirst() {
                path.line(to: NSPoint(x: xFor(p.time), y: yFor(p.value)))
            }
            for p in b.lower.reversed() {
                path.line(to: NSPoint(x: xFor(p.time), y: yFor(p.value)))
            }
            path.close()
            b.color.setFill()
            path.fill()
            ctx.restoreGState()
        }

        // ── Series ──────────────────────────────────────────────────────────
        ctx.saveGState()
        plot.clip()  // pinned yMax may put data above the top; clip, don't rescale
        for s in sanitized {
            drawSeries(s, plot: plot, xFor: xFor, yFor: yFor, zeroY: zeroY,
                       isOnlySeries: sanitized.count == 1)
        }
        ctx.restoreGState()

        // ── Secondary series: battery charge on the right axis ──────────────
        if let r = rightSeries {
            drawRightSeries(r, plot: plot, xFor: xFor, yForRight: yForRight,
                            tickAttrs: tickAttrs)
        }

        // Last, so the crosshair and its readout sit above the lines they report.
        drawHover(in: plot, xFor: xFor, yFor: yFor, yForRight: yForRight)
        if showsAxes { drawHeader(nameAttrs: axisNameAttrs, legendAttrs: tickAttrs) }
    }

    /// One series: decimate → mean line + min/max whiskers (see header comment
    /// for why this is the only smoothing that is honest).
    private func drawSeries(_ s: CleanSeries, plot: NSRect,
                            xFor: (Date) -> CGFloat, yFor: (Double) -> CGFloat,
                            zeroY: CGFloat, isOnlySeries: Bool) {
        let pts = s.points
        guard !pts.isEmpty else { return }

        if pts.count == 1 {
            // A line needs two points; one measurement is a dot, not a trend.
            let c = NSPoint(x: xFor(pts[0].time), y: yFor(pts[0].value))
            let dot = NSBezierPath(ovalIn: NSRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5))
            s.color.setFill()
            dot.fill()
            return
        }

        // Decimate to ~one bucket per horizontal point when the data is denser
        // than the pixels. 1800 samples across a ~700 pt plot → ~2.6 samples
        // per bucket; the mean line is therefore only *lightly* smoothed, and
        // the whiskers below guarantee no excursion is lost either way.
        let bucketCount = max(Int(plot.width), 2)
        struct Bucket {
            var minV = Double.infinity
            var maxV = -Double.infinity
            var sum = 0.0
            var n = 0
        }

        // Nodes are grouped into RUNS separated by gaps in the data.
        //
        // A straight line between two samples an hour apart asserts a trend that
        // was never measured. Reported on a 6 h view after the machine had been
        // off: a clean rising line from 10 to 24 %/hr across four hours in which
        // nothing was sampled at all. The store is already honest here — the
        // sleep-gap work makes it DROP those intervals rather than fabricate
        // them — and then this view drew the fabrication anyway by connecting
        // the survivors.
        //
        // A gap is therefore a break in the path, not a segment. Nothing is
        // drawn where nothing is known.
        var runs: [[(x: CGFloat, y: CGFloat)]] = [[]]
        var whiskers: [(x: CGFloat, y0: CGFloat, y1: CGFloat)] = []

        if pts.count > bucketCount + bucketCount / 2 {
            var buckets = [Bucket](repeating: Bucket(), count: bucketCount)
            let t0 = pts[0].time
            let spanS = max(pts[pts.count - 1].time.timeIntervalSince(t0), 0.001)
            for p in pts {
                var i = Int(p.time.timeIntervalSince(t0) / spanS * Double(bucketCount))
                i = min(max(i, 0), bucketCount - 1)
                buckets[i].minV = min(buckets[i].minV, p.value)
                buckets[i].maxV = max(buckets[i].maxV, p.value)
                buckets[i].sum += p.value
                buckets[i].n += 1
            }
            // A hole is measured in TIME, not in empty buckets.
            //
            // This used to break the line at any gap of one bucket, on the
            // argument that the branch only runs when samples outnumber buckets
            // by 1.5x, so an empty bucket must mean missing data. That is true of
            // the AVERAGE density and the average is not what decides it: this app
            // samples every ~2 s with the window open and every ~63 s with it
            // closed, so an hour holding both is dense enough to reach this branch
            // while its older half legitimately leaves ~17 buckets empty between
            // consecutive samples.
            //
            // The result was an hour that drew as a solid line where it was
            // watched and a row of isolated dots where it was not — the same
            // measurements, rendered as if half of them had failed.
            //
            // So: the same rule the sparse path below uses, four times the data's
            // own median spacing with a 90 s floor, applied to the time between
            // filled buckets. One definition of "a hole" for both paths.
            // HOISTED. This was `Self.gapLimit(for: pts)` INSIDE the loop below,
            // so a 700-bucket draw sorted 700 deltas 700 times — on every frame,
            // in an app whose premise is not costing what it measures.
            let gaps = Self.gapSpans(in: pts)
            var lastFilled = -1
            var lastFilledTime = t0
            for (i, b) in buckets.enumerated() where b.n > 0 {
                let time = t0.addingTimeInterval((Double(i) + 0.5) / Double(bucketCount) * spanS)
                let bx = xFor(time)
                let mean = b.sum / Double(b.n)
                if lastFilled >= 0,
                   gaps.contains(where: { $0.start >= lastFilledTime && $0.start < time }),
                   !runs[runs.count - 1].isEmpty {
                    runs.append([])
                }
                lastFilledTime = time
                lastFilled = i
                runs[runs.count - 1].append((bx, yFor(mean)))
                // Whisker only when the bucket's true range visibly exceeds the
                // stroke itself (> ~2.5 pt) — below that the line already
                // covers it and extra ink is just noise.
                if abs(yFor(b.maxV) - yFor(b.minV)) > 2.5 {
                    whiskers.append((bx, yFor(b.minV), yFor(b.maxV)))
                }
            }
        } else {
            // Sparser than the pixels: draw the actual samples, no decimation.
            //
            // The gap threshold is derived from the data's OWN median spacing
            // rather than a constant, because this view is handed anything from
            // 2 s live ticks to 1 min stored buckets and a fixed number would be
            // either blind on one and trigger-happy on the other. Four times the
            // median tolerates ordinary jitter and a dropped tick; the 90 s floor
            // stops a dense live series breaking on a single slow frame.
            let breaks = Self.breaks(in: pts)
            for (i, p) in pts.enumerated() {
                if i > 0, breaks[i - 1], !runs[runs.count - 1].isEmpty {
                    runs.append([])
                }
                runs[runs.count - 1].append((xFor(p.time), yFor(p.value)))
            }
        }
        runs = runs.filter { !$0.isEmpty }
        let lineNodes = runs.flatMap { $0 }
        guard lineNodes.count >= 2 else {
            if let n = lineNodes.first {
                let dot = NSBezierPath(ovalIn: NSRect(x: n.x - 2.5, y: n.y - 2.5, width: 5, height: 5))
                s.color.setFill()
                dot.fill()
            }
            return
        }

        // BRIDGE the gaps, greyed and dashed.
        //
        // A solid line across hours nobody sampled asserts a trend that was never
        // measured, which is why the runs below are drawn separately. But a bare
        // hole reads as a rendering fault rather than as "the machine was off",
        // and the user asked to see something there. So the gap is bridged in
        // grey, dashed, and thin — deliberately not the series colour, because
        // the one thing it must never look like is data.
        //
        // Drawn FIRST so the real line strokes over it, and clipped to the plot
        // like everything else.
        //
        // Off for a session-scoped live buffer; see `bridgesGaps` for why the two
        // kinds of gap are not the same fact.
        if bridgesGaps, runs.count > 1 {
            let bridge = NSBezierPath()
            bridge.lineWidth = 1
            bridge.setLineDash([3, 3], count: 2, phase: 0)
            for i in 1..<runs.count {
                guard let from = runs[i - 1].last, let to = runs[i].first else { continue }
                bridge.move(to: NSPoint(x: from.x, y: from.y))
                bridge.line(to: NSPoint(x: to.x, y: to.y))
            }
            Palette.faint.setStroke()
            bridge.stroke()
        }

        // One path PER RUN. A single path with a `move` between runs would stroke
        // identically, but the fill below must close each run against the zero
        // line separately — closing across a gap would shade the empty hours as
        // though they held data.
        let line = NSBezierPath()
        line.lineWidth = 1.5
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        for run in runs {
            guard let head = run.first else { continue }
            line.move(to: NSPoint(x: head.x, y: head.y))
            for n in run.dropFirst() { line.line(to: NSPoint(x: n.x, y: n.y)) }
            // A run of one sample would stroke nothing; give it a visible dot so
            // an isolated measurement between two gaps is not silently dropped.
            if run.count == 1 {
                s.color.setFill()
                NSBezierPath(ovalIn: NSRect(x: head.x - 2, y: head.y - 2,
                                            width: 4, height: 4)).fill()
            }
        }

        if s.filled {
            // Fill down to the zero line (or the plot floor if 0 is offscreen),
            // translucent so the grid and band remain visible through it.
            //
            // A GRADIENT rather than the flat 13% wash this used to be. The two
            // carry identical information and average out to the same ink, but a
            // flat block of colour under the line reads as a second, paler series
            // with its own bottom edge, while a fade reads as depth belonging to
            // the line above it. Densest at the line, effectively gone by the
            // baseline, so it never competes with the band drawn behind it.
            let gradient = NSGradient(starting: s.color.withAlphaComponent(0.24),
                                      ending: s.color.withAlphaComponent(0.02))
            for run in runs where run.count >= 2 {
                let fill = NSBezierPath()
                fill.move(to: NSPoint(x: run[0].x, y: run[0].y))
                for n in run.dropFirst() { fill.line(to: NSPoint(x: n.x, y: n.y)) }
                fill.line(to: NSPoint(x: run[run.count - 1].x, y: zeroY))
                fill.line(to: NSPoint(x: run[0].x, y: zeroY))
                fill.close()
                filledSoFar.append(fill)
                guard let gradient else {
                    // Fail soft: a series colour that will not convert to a
                    // gradient's colour space still gets its area, flat.
                    s.color.withAlphaComponent(0.13).setFill()
                    fill.fill()
                    continue
                }
                // Which way the fade runs depends on which side of zero the run
                // is. A charging span hangs BELOW the baseline, and a gradient
                // that always ran dark-at-the-top would put its dense end on the
                // baseline there and its faint end on the line.
                let box = fill.bounds
                let above = (box.maxY - zeroY) >= (zeroY - box.minY)
                gradient.draw(in: fill, angle: above ? 270 : 90)
            }
        }

        if !whiskers.isEmpty {
            let w = NSBezierPath()
            w.lineWidth = 1
            for t in whiskers {
                w.move(to: NSPoint(x: t.x, y: t.y0))
                w.line(to: NSPoint(x: t.x, y: t.y1))
            }
            s.color.withAlphaComponent(0.45).setStroke()
            w.stroke()
        }

        s.color.setStroke()
        line.stroke()

        // The head of the line — the reading this view is reporting right now,
        // which on a live strip is the one number the user came for. Drawn only
        // when this is the SOLE series: with eight drilled-in lines it would be
        // eight dots in the same 20 pt of edge, and there the legend is what
        // tells the lines apart anyway.
        //
        // FROM THE DATA, not from the drawn nodes. When there are more samples
        // than pixels the line above is BUCKETED, and each node sits at its
        // bucket's MEAN — so taking the last node put this marker on the average
        // of the final bucket rather than on the latest reading, which is the one
        // thing it claims to be. Wherever a bucket held a spike, the dot sat
        // visibly off the end of its own line.
        //
        // It looked correct on sparse graphs, which draw real samples and have no
        // buckets, and wrong on dense ones — which is most of them. The
        // right-hand series never had this because it always used `pts.last`.
        if isOnlySeries, let last = pts.last {
            drawEndpointMarker(at: NSPoint(x: xFor(last.time), y: yFor(last.value)),
                               in: plot, color: s.color)
        }
    }

    /// The "latest reading" marker: a filled dot inside a disc of the graph's own
    /// ground, so it separates from the line it caps and from the area fill under
    /// it instead of dissolving into either.
    ///
    /// `x` is nudged to keep the whole marker inside the plot. The newest sample
    /// sits at the right edge by definition, and a marker sliced in half by the
    /// clip reads as a rendering fault rather than as a value. The nudge is at
    /// most 3 pt and moves only the MARKER — the line, and the marker's HEIGHT
    /// (which is the value it is reporting), still sit exactly where the data is.
    /// Where the endpoint markers were drawn on the last frame, in view points.
    ///
    /// Published for the same reason `lastPlot` is: this is geometry the drawing
    /// already computed, and a test that has to rediscover it from pixels ends up
    /// measuring whatever else is nearby. Two attempts at this one measured a
    /// whisker instead, and both passed against the bug.
    private(set) var lastEndpointMarkers: [NSPoint] = []

    /// Where the line breaks: one flag per interval between consecutive points.
    ///
    /// LOCAL cadence, not one threshold for the whole series, and that is the
    /// entire point. This used to take the median spacing of every point on
    /// screen and compare every interval to it — which works only if the series
    /// has ONE cadence, and an hour of this app's history routinely has two: the
    /// sampler ticks about every 2 s while the window is open and about every
    /// 64 s while it is shut. The dense stretch supplies most of the points, so
    /// the median landed at 2 s, the limit at its 90 s floor, and every ordinary
    /// spacing in the sparse stretch was reported as the machine having slept.
    ///
    /// What made that visible was a beat frequency, and it is worth naming
    /// because nothing about it is a fault: samples arrive every ~64 s and
    /// compaction folds them into 60 s buckets, so every fifteenth sample skips a
    /// bucket entirely (64 × 15 = 960 = exactly one empty minute every 16). The
    /// store had 25 of these overnight, each a 120 s hole between two rows whose
    /// own `dur` shows the machine measuring the whole time. A machine that never
    /// slept was drawn as sleeping 25 times.
    ///
    /// Judged against a window of neighbouring intervals, each stretch is
    /// measured against its own cadence: 90 s in the dense one (the floor), ~240 s
    /// in the sparse one. A real absence — the 9540 s in that same night's data —
    /// is far outside either.
    ///
    /// The cost of the local rule is that a sleep SHORTER than a few missed
    /// samples no longer draws a break. At 64 s sampling that is a couple of
    /// minutes, which the line now interpolates across. That is the right trade:
    /// two minutes is one missing sample at that resolution, and drawing a chasm
    /// for it is what was wrong.
    static func breaks(in pts: [Point]) -> [Bool] {
        guard pts.count > 1 else { return [] }
        var deltas: [TimeInterval] = []
        deltas.reserveCapacity(pts.count - 1)
        for i in 1..<pts.count { deltas.append(pts[i].time.timeIntervalSince(pts[i - 1].time)) }

        // Wide enough to span a stretch of one cadence, narrow enough that a
        // change of cadence is local. At a boundary the window straddles both and
        // the median is one of them — either way the 4x factor keeps an ordinary
        // spacing on the slower side under the limit.
        let half = 15
        var out = [Bool](repeating: false, count: deltas.count)
        var window: [TimeInterval] = []
        window.reserveCapacity(2 * half + 1)
        for i in deltas.indices {
            let lo = max(0, i - half), hi = min(deltas.count - 1, i + half)
            window.removeAll(keepingCapacity: true)
            window.append(contentsOf: deltas[lo...hi])
            window.sort()
            out[i] = deltas[i] > max(window[window.count / 2] * 4, 90)
        }
        return out
    }

    /// The same breaks as spans, for the path that draws buckets rather than
    /// points and so has to ask "was there a hole between these two times".
    static func gapSpans(in pts: [Point]) -> [(start: Date, end: Date)] {
        breaks(in: pts).enumerated().compactMap { i, isBreak in
            isBreak ? (pts[i].time, pts[i + 1].time) : nil
        }
    }

    private func drawEndpointMarker(at p: NSPoint, in plot: NSRect, color: NSColor) {
        // Clamped to the VIEW, not to the plot.
        //
        // The latest sample sits at the plot's right edge by definition, and
        // clamping to `plot.maxX - 3.5` therefore dragged this dot one radius back
        // inside on every graph — reported as "the dots need to move right", and
        // it was the same 3.5 pt everywhere because it was always the clamp
        // binding rather than anything about the data.
        //
        // Nothing is lost by letting it sit at the edge: this is drawn after the
        // plot clip is restored, and the right gutter is 10 pt with no second axis
        // and 34 pt with one, so a 3.5 pt radius has room either way. The bounds
        // clamp remains for the degenerate case of a plot flush to the view.
        let x = min(max(p.x, bounds.minX + 3.5), bounds.maxX - 3.5)
        lastEndpointMarkers.append(NSPoint(x: x, y: p.y))
        Palette.background.setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 3.5, y: p.y - 3.5, width: 7, height: 7)).fill()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 2.25, y: p.y - 2.25, width: 4.5, height: 4.5)).fill()
    }

    /// The right-axis series (battery charge), plus its 0-100 tick labels.
    ///
    /// Drawn in two colours: `Palette.chargingLine` across the spans where the
    /// pack was gaining charge, the caller's colour everywhere else. The point is
    /// that a glance answers "when was it plugged in?" — on a week of history
    /// that is the shape of the whole chart, and it used to take reading the
    /// slope of a thin blue line to find it.
    ///
    /// The spans are MEASURED, not inferred. `Point.onPower` comes from the
    /// store's `on_battery` column, which is `!onAC` recorded per interval and
    /// therefore already knows the answer exactly.
    ///
    /// An earlier version inferred the spans from the shape of the charge curve,
    /// with hysteresis to survive the gauge's whole-percent quantisation. It was
    /// careful and it was unnecessary, and it was also wrong in the most common
    /// case a laptop is in: parked on the adapter at 100%, where the line is
    /// dead flat and a rise-detector sees nothing to detect. A machine plugged in
    /// all night rendered as if it had been on battery all night. Inference
    /// cannot beat a recorded fact.
    ///
    /// A point whose `onPower` is nil draws in the ordinary colour rather than
    /// guessing — an unknown is not a claim of "on battery".
    ///
    /// Unlike `drawSeries` this does not decimate: charge is a slow signal with
    /// no excursions to lose, and the series is small either way — 700 points
    /// bucketed by the store, or one per 2 s tick across the live hour.
    private func drawRightSeries(_ r: Series, plot: NSRect,
                                 xFor: (Date) -> CGFloat, yForRight: (Double) -> CGFloat,
                                 tickAttrs: [NSAttributedString.Key: Any]) {
        let pts = r.points
            .filter { $0.value.isFinite }
            .sorted { $0.time < $1.time }
        if pts.count >= 2 {
            let charging = pts.map { $0.onPower == true }
            // One path per RUN of like-coloured segments, not per segment: a
            // stroke per segment would round-join nothing and show a seam at
            // every sample. Runs meet on a shared vertex, so the colour changes
            // exactly where the state does with no gap.
            // Same gap rule as the left-hand series: a charge line drawn across
            // hours the machine was off asserts a discharge that was never
            // observed. The threshold is derived from this series' own median
            // spacing for the same reason.
            // The same function, not a third copy of the arithmetic. This one had
            // its own inline version of the old global-median rule, so the charge
            // line broke wherever the rate line did — including at all 25 of the
            // phantom holes.
            let breaks = Self.breaks(in: pts)

            // The gradient, before the line so the stroke sits on top of its own
            // wash — and in the SAME ink as the segment above it, which is why
            // this is per-span rather than one area for the series.
            //
            // The charge line is drawn green across the spans where the pack was
            // filling. Filling the whole series in `r.color` put a deep blue wash
            // under a green line, and at 0.24 alpha on a black ground that is
            // very nearly invisible: measured, it lifted the region's luminance by
            // 0.054, which a test can see and an eye reasonably cannot. Reported
            // twice as "still no gradient" — it was drawing, in a colour chosen to
            // disappear.
            //
            // Clipped to the plot MINUS everything already filled this pass: an
            // even-odd path of the plot rect plus the earlier areas leaves exactly
            // the region no lower fill has claimed. That is "the bottom one cuts
            // the top one off", done geometrically, so crossing lines resolve per
            // pixel instead of by an assumed ordering.
            if r.filled {
                NSGraphicsContext.saveGraphicsState()
                let mask = NSBezierPath(rect: plot)
                mask.append(filledSoFar)
                mask.windingRule = .evenOdd
                mask.addClip()

                var span: [NSPoint] = []
                var spanCharging = false
                let drawn = NSBezierPath()

                /// Close the run to the floor, fill it in its own ink, and keep it
                /// so later fills are cut by it too.
                func flush() {
                    defer { span.removeAll() }
                    guard span.count >= 2 else { return }
                    let area = NSBezierPath()
                    area.move(to: span[0])
                    for pt in span.dropFirst() { area.line(to: pt) }
                    area.line(to: NSPoint(x: span[span.count - 1].x, y: plot.minY))
                    area.line(to: NSPoint(x: span[0].x, y: plot.minY))
                    area.close()
                    let ink = spanCharging ? Palette.chargingLine : r.color
                    if let g = NSGradient(starting: ink.withAlphaComponent(0.28),
                                          ending: ink.withAlphaComponent(0.02)) {
                        g.draw(in: area, angle: 90)
                    } else {
                        ink.withAlphaComponent(0.16).setFill()
                        area.fill()
                    }
                    drawn.append(area)
                }

                for i in 0..<(pts.count - 1) {
                    // A break is a span the machine was not observed across, and a
                    // wash drawn over it claims a level nobody measured — the same
                    // reason the line itself stops there.
                    if breaks[i] { flush(); continue }
                    let isCharging = charging[i] && charging[i + 1]
                    if span.isEmpty {
                        spanCharging = isCharging
                        span.append(NSPoint(x: xFor(pts[i].time),
                                            y: yForRight(pts[i].value)))
                    } else if isCharging != spanCharging {
                        // Hand the boundary vertex to both spans so their washes
                        // meet exactly where the line changes colour.
                        span.append(NSPoint(x: xFor(pts[i].time),
                                            y: yForRight(pts[i].value)))
                        flush()
                        spanCharging = isCharging
                        span.append(NSPoint(x: xFor(pts[i].time),
                                            y: yForRight(pts[i].value)))
                    }
                    span.append(NSPoint(x: xFor(pts[i + 1].time),
                                        y: yForRight(pts[i + 1].value)))
                }
                flush()
                NSGraphicsContext.restoreGraphicsState()
                filledSoFar.append(drawn)
            }

            var runs: [(charging: Bool, path: NSBezierPath)] = []
            var gapBridges: [(from: NSPoint, to: NSPoint)] = []
            for i in 0..<(pts.count - 1) {
                // Skip the segment entirely across a gap, and force the next
                // segment to start a fresh path rather than continuing this one.
                if breaks[i] {
                    gapBridges.append((
                        NSPoint(x: xFor(pts[i].time), y: yForRight(pts[i].value)),
                        NSPoint(x: xFor(pts[i + 1].time), y: yForRight(pts[i + 1].value))))
                    runs.append((false, NSBezierPath()))   // sentinel: empty, never stroked
                    continue
                }
                // A segment is charging only when BOTH its ends are, so the two
                // samples straddling a plug event resolve to the state the
                // machine was actually in for most of that segment.
                let isCharging = charging[i] && charging[i + 1]
                if runs.last?.charging != isCharging || runs.last?.path.isEmpty == true {
                    let path = NSBezierPath()
                    path.lineWidth = 1.6
                    path.lineJoinStyle = .round
                    path.move(to: NSPoint(x: xFor(pts[i].time), y: yForRight(pts[i].value)))
                    runs.append((isCharging, path))
                }
                runs[runs.count - 1].path.line(
                    to: NSPoint(x: xFor(pts[i + 1].time), y: yForRight(pts[i + 1].value)))
            }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: plot).addClip()
            // Grey dashed bridge across the gaps, for the same reason as the
            // left-hand series: a hole reads as breakage, a grey dash reads as
            // "nothing was measured here". Never the series colour.
            if bridgesGaps, !gapBridges.isEmpty {
                let bridge = NSBezierPath()
                bridge.lineWidth = 1
                bridge.setLineDash([3, 3], count: 2, phase: 0)
                for g in gapBridges {
                    bridge.move(to: g.from)
                    bridge.line(to: g.to)
                }
                Palette.faint.setStroke()
                bridge.stroke()
            }
            for run in runs where !run.path.isEmpty {
                (run.charging ? Palette.chargingLine : r.color).setStroke()
                run.path.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()

            // Endpoint dot: the current charge, which is the value people read.
            // Wears the last segment's colour so the head of the line can never
            // disagree with the line about whether it is still filling.
            //
            // Same marker the left-hand series' head uses, so "this is the latest
            // reading" is one shape on this chart rather than two.
            if let last = pts.last {
                drawEndpointMarker(
                    at: NSPoint(x: xFor(last.time), y: yForRight(last.value)),
                    in: plot,
                    color: runs.last?.charging == true ? Palette.chargingLine : r.color)
            }
        }

        // Right-hand tick labels, in the series colour so it is unambiguous
        // which line the axis belongs to. The series colour, not the charging
        // one: the axis belongs to the line, not to what it was doing.
        var rightAttrs = tickAttrs
        rightAttrs[.foregroundColor] = r.color
        for v in Self.sharedAxisTicks {
            let label = "\(Int(v))\(rightAxisUnit)" as NSString
            let sz = label.size(withAttributes: rightAttrs)
            label.draw(at: NSPoint(x: plot.maxX + 5,
                                   y: yForRight(v) - sz.height / 2),
                       withAttributes: rightAttrs)
        }
    }

    /// Top row: y-axis name on the left, legend on the right. Text wears text
    /// colors — the colored swatch alone carries series identity.
    ///
    /// The axis name is UPPERCASED here rather than by the caller: callers set it
    /// as prose ("%/hr · Safari") and this is the one place that knows it is being
    /// drawn as a label. Series names are not shouted — those are the names of
    /// real things, and a process is not a column heading.
    private func drawHeader(nameAttrs: [NSAttributedString.Key: Any],
                            legendAttrs: [NSAttributedString.Key: Any]) {
        let y = bounds.height - 13.0
        let axisName = yAxisLabel.uppercased() as NSString
        if !yAxisLabel.isEmpty {
            axisName.draw(at: NSPoint(x: 6, y: y), withAttributes: nameAttrs)
        }
        // One series needs no legend (the axis label / context names it).
        guard sanitized.count >= 2 else { return }
        // Start left of anything overlaid on the header. The range picker lives
        // there, and with eight drilled-in series the legend ran straight under
        // it and buried the control.
        var x = bounds.width - 8 - headerTrailingInset
        // Stop before the axis label rather than overrunning it. Names are
        // dropped from the LEFT, so the biggest contributors — drawn last and
        // therefore right-most — are the ones that survive.
        let leftLimit = axisName.size(withAttributes: nameAttrs).width + 14
        // A LINE swatch rather than a dot. This legend names lines; a dot is the
        // mark for a scatter, and at 6 pt across it also carried more colour than
        // eight of them should on a 13 pt header band.
        let swatchW: CGFloat = 9, swatchGap: CGFloat = 6, entryGap: CGFloat = 12
        for s in sanitized.reversed() {
            let name = s.name as NSString
            let size = name.size(withAttributes: legendAttrs)
            guard x - size.width - swatchW - swatchGap - entryGap > leftLimit else {
                // Say that names were dropped instead of silently showing a
                // partial legend that reads as the complete set.
                ("…" as NSString).draw(at: NSPoint(x: max(x - 10, leftLimit), y: y),
                                       withAttributes: legendAttrs)
                break
            }
            x -= size.width
            name.draw(at: NSPoint(x: x, y: y), withAttributes: legendAttrs)
            x -= swatchGap + swatchW
            s.color.setFill()
            // A CAPSULE: radius is half the height, written as the relationship
            // rather than as 1.25 — the same number today and the wrong one the
            // moment the swatch is resized.
            NSBezierPath(roundedRect: NSRect(x: x, y: y + size.height / 2 - Self.swatchH / 2,
                                             width: swatchW, height: Self.swatchH),
                         xRadius: Self.swatchH / 2, yRadius: Self.swatchH / 2).fill()
            x -= entryGap
        }
    }

    // MARK: - Label formatting

    private static func yLabel(_ v: Double) -> String {
        // %g trims trailing zeros: 2.5 → "2.5", 10 → "10".
        String(format: "%g", v)
    }

    /// An absolute time for a panned axis, at a resolution the span can support.
    ///
    /// Formatters are cached because `draw` runs on every tick while the window
    /// is open, and building a DateFormatter is famously expensive — the whole
    /// point of this view is to not cost what it measures.
    private static let hhmm: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let hhmmss: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    private static let dayHour: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"; return f
    }()

    private static func clockLabel(_ t: Date, span: Double) -> String {
        // Seconds only matter when the whole view is minutes wide; days only
        // matter when the view crosses one. In between, HH:mm is what a person
        // reads a chart with.
        if span <= 300 { return hhmmss.string(from: t) }
        if span <= 86_400 { return hhmm.string(from: t) }
        return dayHour.string(from: t)
    }

    private static func timeLabel(_ secondsBack: Double) -> String {
        let i = Int(secondsBack.rounded())
        if i == 0 { return "now" }
        if i < 60 { return "-\(i)s" }
        if i < 3600 {
            return i % 60 == 0 ? "-\(i / 60)m" : String(format: "-%dm%02ds", i / 60, i % 60)
        }
        return i % 3600 == 0 ? "-\(i / 3600)h"
                             : String(format: "-%dh%02dm", i / 3600, (i % 3600) / 60)
    }
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: Zoom, pan, hover

extension HistoryGraphView {

    /// The domain the interaction acts on. Falls back to the last hour so the
    /// first scroll has something concrete to scale rather than doing nothing.
    private var effectiveDomain: (start: Date, end: Date) {
        if let d = timeDomain, d.end > d.start { return d }
        let end = Date()
        return (end.addingTimeInterval(-3600), end)
    }

    /// Clamp a proposed domain to what actually exists: never shorter than a
    /// minute, never longer than the retention horizon, never scrolled past the
    /// oldest sample, and never into the future — panning into blank space on
    /// either side reads as the graph being broken.
    private func clamped(start: Date, end: Date) -> (start: Date, end: Date) {
        var span = min(max(end.timeIntervalSince(start), minSpan), maxSpan)
        let floorDate = earliestAvailable
        let ceilDate = Date()
        if let f = floorDate { span = min(span, max(minSpan, ceilDate.timeIntervalSince(f))) }

        var e = min(end, ceilDate)
        var st = e.addingTimeInterval(-span)
        if let f = floorDate, st < f {
            st = f
            e = min(ceilDate, st.addingTimeInterval(span))
        }
        return (st, e)
    }

    private func apply(_ d: (start: Date, end: Date)) {
        let c = clamped(start: d.start, end: d.end)
        timeDomain = c
        onDomainChanged?(c.start, c.end)
    }

    /// Horizontal extent the interaction maps time across: whatever the last
    /// draw used, or a nominal rect matching the old constants before there has
    /// been a draw to record one (a scroll can only arrive that early if the view
    /// is in a window but has never been displayed — one frame, then it is real).
    private var interactionPlot: (left: CGFloat, width: CGFloat) {
        if lastPlot.width > 0 { return (lastPlot.minX, lastPlot.width) }
        return (34, max(bounds.width - 76, 1))
    }

    /// Time under a given x, inverting the mapping the last draw actually used.
    private func time(atX x: CGFloat) -> Date {
        let d = lastDomain ?? effectiveDomain
        let p = interactionPlot
        let w = max(p.width, 1)
        let f = min(max((x - p.left) / w, 0), 1)
        return d.start.addingTimeInterval(Double(f) * d.end.timeIntervalSince(d.start))
    }

    public override func scrollWheel(with event: NSEvent) {
        // A two-finger swipe LEFT or RIGHT is a pan gesture, not a zoom gesture.
        // Testing `deltaY > 0 ? in : out` made every horizontal swipe fall into
        // the else branch and zoom in, so brushing sideways across the chart
        // rewrote the axis. Require a real vertical component, and require it to
        // dominate, so a diagonal still zooms but a sideways flick does nothing.
        let dy = event.scrollingDeltaY
        guard abs(dy) > 0, abs(dy) >= abs(event.scrollingDeltaX) else { return }
        // Zoom about the POINTER, not the centre or the right edge. Anchoring
        // elsewhere makes the thing under the cursor slide away as you zoom, which
        // is the single most disorienting thing a zoomable chart can do.
        let d = effectiveDomain
        let anchor = time(atX: convert(event.locationInWindow, from: nil).x)
        let factor = dy > 0 ? 0.85 : 1.0 / 0.85
        let span = d.end.timeIntervalSince(d.start) * factor
        let leftShare = anchor.timeIntervalSince(d.start) / max(d.end.timeIntervalSince(d.start), 0.001)
        let start = anchor.addingTimeInterval(-span * leftShare)
        apply((start, start.addingTimeInterval(span)))
    }

    public override func mouseDown(with event: NSEvent) {
        let d = effectiveDomain
        panAnchor = (convert(event.locationInWindow, from: nil), d.start, d.end)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let a = panAnchor else { return }
        let d = effectiveDomain
        // Same recorded rect the drawing used: a pan of one plot width must move
        // the axis by exactly one domain, or content lags or leads the pointer.
        let plotWidth = max(interactionPlot.width, 1)
        let perPixel = d.end.timeIntervalSince(d.start) / Double(plotWidth)
        let dx = convert(event.locationInWindow, from: nil).x - a.mouse.x
        // Drag right moves the window BACK in time: the content follows the
        // pointer, the axis does not.
        let shift = -Double(dx) * perPixel
        apply((a.start.addingTimeInterval(shift), a.end.addingTimeInterval(shift)))
    }

    public override func mouseUp(with event: NSEvent) { panAnchor = nil }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t); trackingAreaRef = nil }
        guard respondsToHover else { return }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    public override func mouseMoved(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    public override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        needsDisplay = true
    }

    /// Crosshair plus a readout of every series at the hovered instant. Drawn
    /// after the plot so it sits on top of the lines it is reading.
    func drawHover(in plot: NSRect, xFor: (Date) -> CGFloat, yFor: (Double) -> CGFloat,
                   yForRight: (Double) -> CGFloat) {
        guard let h = hoverPoint, plot.contains(h), panAnchor == nil else { return }
        let t = time(atX: h.x)

        Palette.dim.withAlphaComponent(0.55).setStroke()
        let line = NSBezierPath()
        line.lineWidth = 1
        line.move(to: NSPoint(x: h.x, y: plot.minY))
        line.line(to: NSPoint(x: h.x, y: plot.maxY))
        line.stroke()

        // Nearest sample per series, not interpolation: these are bucketed
        // averages, and inventing a value between two buckets would report a
        // number that was never measured.
        var lines: [(String, NSColor, String)] = []
        /// Nearest sample to the crosshair, or nothing when the nearest is too far
        /// to be describing this instant.
        func nearest(_ points: [Point]) -> Point? {
            guard let near = points.min(by: {
                abs($0.time.timeIntervalSince(t)) < abs($1.time.timeIntervalSince(t))
            }), abs(near.time.timeIntervalSince(t)) < max(60, currentSpan / 40) else { return nil }
            return near
        }
        func mark(_ p: Point, _ y: (Double) -> CGFloat, _ color: NSColor) {
            let at = NSPoint(x: xFor(p.time), y: y(p.value))
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: at.x - 3, y: at.y - 3, width: 6, height: 6)).fill()
        }
        for s in sanitized {
            guard let near = nearest(s.points) else { continue }
            lines.append((s.name, s.color,
                          near.detail ?? String(format: "%.2f", near.value)))
            mark(near, yFor, s.color)
        }
        // THE RIGHT-HAND SERIES TOO. It was left out, which was survivable while
        // it was only ever the battery charge line — a number you read off the
        // axis. On the fan graph it is the temperature, and "what was the temp
        // when the fans spun up" is the entire reason the two share a chart.
        if let r = rightSeries, let near = nearest(Self.sanitize(r.points)) {
            // THE COLOUR OF THE SEGMENT UNDER THE CROSSHAIR, not of the series.
            //
            // The charge line is drawn per-segment: green across the spans where
            // the pack was filling, the series ink everywhere else, because "was
            // it plugged in" is the one thing people scan a charge history for.
            // The readout took the series colour regardless, so hovering a green
            // stretch produced a blue swatch beside it — the box says one thing
            // and the line under it says another.
            //
            // The axis TICKS keep the series colour on purpose (see
            // `drawRightSeries`): they label the whole axis, which belongs to the
            // line rather than to what it was doing at one instant. This box is
            // reporting that instant, so it follows the instant.
            let ink = near.onPower == true ? Palette.chargingLine : r.color
            lines.append((r.name, ink,
                          near.detail ?? String(format: "%.2f", near.value)))
            mark(near, yForRight, ink)
        }
        guard !lines.isEmpty else { return }

        // The cached formatters, not a fresh DateFormatter per frame. This runs on
        // every mouseMoved — up to the display's refresh rate while the pointer is
        // travelling — and building a DateFormatter is the one allocation this
        // file already documents as expensive enough to hoist.
        let stamp = (currentSpan > 86400 ? Self.dayHour.string(from: t)
                                         : Self.hhmmss.string(from: t)) as NSString

        // Three inks, because the box holds three different things. The instant is
        // context, the series name is a label, the value is the answer — flattened
        // into one string at one weight, as it was, the answer was the hardest of
        // the three to find. And with up to eight lines under the crosshair the
        // readout carried NO colour at all, so nothing tied a row to its line.
        let stampAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: Palette.dim,
        ]
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: Palette.dim,
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: Palette.text,
        ]

        let entries = lines.map { (name: $0.0 as NSString, color: $0.1,
                                  value: $0.2 as NSString) }
        let swatchW: CGFloat = 9, swatchGap: CGFloat = 6, colGap: CGFloat = 14
        let padX: CGFloat = 8, padY: CGFloat = 6, stampGap: CGFloat = 4
        var nameW: CGFloat = 0, valueW: CGFloat = 0, rowH: CGFloat = 0
        for e in entries {
            let n = e.name.size(withAttributes: nameAttrs)
            let v = e.value.size(withAttributes: valueAttrs)
            nameW = max(nameW, n.width)
            valueW = max(valueW, v.width)
            rowH = max(rowH, ceil(max(n.height, v.height)))
        }
        let stampSize = stamp.size(withAttributes: stampAttrs)
        let boxW = max(stampSize.width, swatchW + swatchGap + nameW + colGap + valueW) + padX * 2
        let boxH = padY * 2 + ceil(stampSize.height) + stampGap + rowH * CGFloat(entries.count)

        // Flip the box to the other side of the crosshair near the right edge so
        // it never gets clipped by the plot bounds.
        let left = h.x + 12 + boxW > plot.maxX ? h.x - 12 - boxW : h.x + 12
        let bottom = min(max(h.y - boxH / 2, plot.minY), plot.maxY - boxH)
        let box = NSRect(x: left, y: bottom, width: boxW, height: boxH)

        Palette.background.withAlphaComponent(0.96).setFill()
        let bp = NSBezierPath(roundedRect: box,
                              xRadius: Palette.Radius.chip, yRadius: Palette.Radius.chip)
        bp.fill()
        Palette.line.setStroke()
        bp.stroke()

        var y = box.maxY - padY - ceil(stampSize.height)
        stamp.draw(at: NSPoint(x: box.minX + padX, y: y), withAttributes: stampAttrs)
        y -= stampGap
        for e in entries {
            y -= rowH
            e.color.setFill()
            NSBezierPath(roundedRect: NSRect(x: box.minX + padX,
                                             y: y + rowH / 2 - Self.swatchH / 2,
                                             width: swatchW, height: Self.swatchH),
                         xRadius: Self.swatchH / 2, yRadius: Self.swatchH / 2).fill()
            let n = e.name.size(withAttributes: nameAttrs)
            e.name.draw(at: NSPoint(x: box.minX + padX + swatchW + swatchGap,
                                    y: y + (rowH - n.height) / 2),
                        withAttributes: nameAttrs)
            // Values right-aligned to a common edge: this is a column of numbers,
            // and a ragged one cannot be compared down its own length.
            let v = e.value.size(withAttributes: valueAttrs)
            e.value.draw(at: NSPoint(x: box.maxX - padX - v.width,
                                     y: y + (rowH - v.height) / 2),
                         withAttributes: valueAttrs)
        }
    }

    private var currentSpan: TimeInterval {
        let d = effectiveDomain
        return d.end.timeIntervalSince(d.start)
    }
}

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
public final class HistoryGraphView: NSView {

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
        public init(time: Date, value: Double, onPower: Bool? = nil) {
            self.time = time
            self.value = value
            self.onPower = onPower
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
    public var yAxisLabel: String = "" {
        didSet { needsDisplay = true }
    }

    /// nil = autoscale (nice-rounded, with hysteresis). Non-nil pins the top of
    /// the axis; data above it is clipped to the plot rect, not rescaled.
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
    private var lastPlot: NSRect = .zero
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

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldAntialias(true)

        // Background first — semantic, so aqua/darkAqua both come out right.
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        let tickFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let tickAttrs: [NSAttributedString.Key: Any] = [
            .font: tickFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

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
        if let pinned = yMax, pinned.isFinite, pinned > 0 {
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
        // Left gutter sized to the widest y tick label so labels never collide
        // with the plot; recomputed per frame because the labels change with
        // the scale (cheap: ≤ 6 strings).
        let yTickStep = Self.niceCeil((top - bottom) / 5.0)
        var yTicks: [Double] = []
        var yTick = (bottom / yTickStep).rounded(.up) * yTickStep
        while yTick <= top + yTickStep * 0.001 {
            yTicks.append(yTick)
            yTick += yTickStep
        }
        var maxYLabelW: CGFloat = 0
        for v in yTicks {
            let w = (Self.yLabel(v) as NSString).size(withAttributes: tickAttrs).width
            if w > maxYLabelW { maxYLabelW = w }
        }
        let padLeft = max(maxYLabelW + 10, 24)
        // Room for the right-hand 0-100 axis labels when a second series is present.
        let padRight: CGFloat = rightSeries == nil ? 10 : 34
        let padTop: CGFloat = 18     // yAxisLabel + legend row
        let padBottom: CGFloat = 15  // time labels
        let plot = NSRect(x: padLeft, y: padBottom,
                          width: bounds.width - padLeft - padRight,
                          height: bounds.height - padTop - padBottom)
        guard plot.width > 20, plot.height > 20 else { return }  // too small to be honest
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

        // ── Grid + y labels ─────────────────────────────────────────────────
        // Grid is recessive by construction: separatorColor is designed by the
        // system to sit just above the background in both appearances.
        if showsGrid {
            NSColor.separatorColor.setStroke()
            let gridPath = NSBezierPath()
            gridPath.lineWidth = 1
            for v in yTicks {
                let y = snap(yFor(v))
                gridPath.move(to: NSPoint(x: plot.minX, y: y))
                gridPath.line(to: NSPoint(x: plot.maxX, y: y))
            }
            gridPath.stroke()
        }
        for v in yTicks {
            let s = Self.yLabel(v) as NSString
            let size = s.size(withAttributes: tickAttrs)
            var y = yFor(v) - size.height / 2
            y = min(max(y, 0), bounds.height - size.height)
            s.draw(at: NSPoint(x: padLeft - 6 - size.width, y: y), withAttributes: tickAttrs)
        }

        // ── Time ticks ──────────────────────────────────────────────────────
        // Ladder of human steps; pick the smallest giving ≤ 6 ticks so labels
        // never crowd. Ticks count back from the newest sample.
        let ladder: [Double] = [5, 10, 15, 30, 60, 120, 300, 600, 900, 1800,
                                3600, 7200, 14400, 21600, 43200, 86400]
        let tStep = ladder.first { span / $0 <= 6 } ?? (86400 * (span / (6 * 86400)).rounded(.up))
        var back: Double = 0
        while true {
            let x = xFor(tMax.addingTimeInterval(-back))
            if x < plot.minX - 0.5 { break }
            if showsGrid {
                NSColor.separatorColor.setStroke()
                let p = NSBezierPath()
                p.lineWidth = 1
                p.move(to: NSPoint(x: snap(x), y: plot.minY))
                p.line(to: NSPoint(x: snap(x), y: plot.maxY))
                p.stroke()
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

        guard haveData else {
            // Empty state: axes and a quiet message, never a blank rectangle —
            // a blank rectangle looks like a bug, an empty chart looks like
            // "not enough history yet", which is the truth.
            let s = "no history yet" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: plot.midX - size.width / 2, y: plot.midY - size.height / 2),
                   withAttributes: attrs)
            // `haveData` is folded from the left series and band only, so a
            // charge line with no rate line behind it still belongs on screen —
            // it is the one thing this view can show when the rate is missing.
            if let r = rightSeries {
                drawRightSeries(r, plot: plot, xFor: xFor, yForRight: yForRight,
                                tickAttrs: tickAttrs)
            }
            drawHeader(plotTop: plot.maxY, tickAttrs: tickAttrs)
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
            drawSeries(s, plot: plot, xFor: xFor, yFor: yFor,
                       zeroY: yFor(min(max(0, bottom), top)))
        }
        ctx.restoreGState()

        // ── Secondary series: battery charge on the right axis ──────────────
        if let r = rightSeries {
            drawRightSeries(r, plot: plot, xFor: xFor, yForRight: yForRight,
                            tickAttrs: tickAttrs)
        }

        // Last, so the crosshair and its readout sit above the lines they report.
        drawHover(in: plot, xFor: xFor, yFor: yFor)
        drawHeader(plotTop: plot.maxY, tickAttrs: tickAttrs)
    }

    /// One series: decimate → mean line + min/max whiskers (see header comment
    /// for why this is the only smoothing that is honest).
    private func drawSeries(_ s: CleanSeries, plot: NSRect,
                            xFor: (Date) -> CGFloat, yFor: (Double) -> CGFloat,
                            zeroY: CGFloat) {
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
            // An EMPTY bucket between two full ones is a real hole: this branch
            // only runs when the samples outnumber the buckets by 1.5x, so a
            // bucket with nothing in it means the data is missing, not sparse.
            var lastFilled = -1
            for (i, b) in buckets.enumerated() where b.n > 0 {
                let bx = xFor(t0.addingTimeInterval((Double(i) + 0.5) / Double(bucketCount) * spanS))
                let mean = b.sum / Double(b.n)
                if lastFilled >= 0, i - lastFilled > 1, !runs[runs.count - 1].isEmpty {
                    runs.append([])
                }
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
            var deltas: [TimeInterval] = []
            deltas.reserveCapacity(pts.count)
            for i in 1..<pts.count { deltas.append(pts[i].time.timeIntervalSince(pts[i - 1].time)) }
            deltas.sort()
            let median = deltas.isEmpty ? 0 : deltas[deltas.count / 2]
            let gapLimit = max(median * 4, 90)
            var previous: Date?
            for p in pts {
                if let prev = previous, p.time.timeIntervalSince(prev) > gapLimit,
                   !runs[runs.count - 1].isEmpty {
                    runs.append([])
                }
                previous = p.time
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
            s.color.withAlphaComponent(0.13).setFill()
            for run in runs where run.count >= 2 {
                let fill = NSBezierPath()
                fill.move(to: NSPoint(x: run[0].x, y: run[0].y))
                for n in run.dropFirst() { fill.line(to: NSPoint(x: n.x, y: n.y)) }
                fill.line(to: NSPoint(x: run[run.count - 1].x, y: zeroY))
                fill.line(to: NSPoint(x: run[0].x, y: zeroY))
                fill.close()
                fill.fill()
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
            var deltas: [TimeInterval] = []
            for i in 1..<pts.count { deltas.append(pts[i].time.timeIntervalSince(pts[i - 1].time)) }
            deltas.sort()
            let gapLimit = max((deltas.isEmpty ? 0 : deltas[deltas.count / 2]) * 4, 90)

            var runs: [(charging: Bool, path: NSBezierPath)] = []
            for i in 0..<(pts.count - 1) {
                // Skip the segment entirely across a gap, and force the next
                // segment to start a fresh path rather than continuing this one.
                if pts[i + 1].time.timeIntervalSince(pts[i].time) > gapLimit {
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
            for run in runs where !run.path.isEmpty {
                (run.charging ? Palette.chargingLine : r.color).setStroke()
                run.path.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()

            // Endpoint dot: the current charge, which is the value people read.
            // Wears the last segment's colour so the head of the line can never
            // disagree with the line about whether it is still filling.
            if let last = pts.last {
                (runs.last?.charging == true ? Palette.chargingLine : r.color).setFill()
                let c = NSPoint(x: xFor(last.time), y: yForRight(last.value))
                NSBezierPath(ovalIn: NSRect(x: c.x - 2.6, y: c.y - 2.6,
                                            width: 5.2, height: 5.2)).fill()
            }
        }

        // Right-hand tick labels, in the series colour so it is unambiguous
        // which line the axis belongs to. The series colour, not the charging
        // one: the axis belongs to the line, not to what it was doing.
        var rightAttrs = tickAttrs
        rightAttrs[.foregroundColor] = r.color
        for v in stride(from: 0.0, through: 100.0, by: 25.0) {
            let label = "\(Int(v))%" as NSString
            let sz = label.size(withAttributes: rightAttrs)
            label.draw(at: NSPoint(x: plot.maxX + 5,
                                   y: yForRight(v) - sz.height / 2),
                       withAttributes: rightAttrs)
        }
    }

    /// Top row: y-axis label on the left, legend on the right. Text wears text
    /// colors — the colored dot alone carries series identity.
    private func drawHeader(plotTop: CGFloat, tickAttrs: [NSAttributedString.Key: Any]) {
        let y = bounds.height - 13.0
        if !yAxisLabel.isEmpty {
            (yAxisLabel as NSString).draw(at: NSPoint(x: 6, y: y), withAttributes: tickAttrs)
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
        let leftLimit = (yAxisLabel as NSString)
            .size(withAttributes: tickAttrs).width + 14
        for s in sanitized.reversed() {
            let name = s.name as NSString
            let size = name.size(withAttributes: tickAttrs)
            guard x - size.width - 21 > leftLimit else {
                // Say that names were dropped instead of silently showing a
                // partial legend that reads as the complete set.
                ("…" as NSString).draw(at: NSPoint(x: max(x - 10, leftLimit), y: y),
                                       withAttributes: tickAttrs)
                break
            }
            x -= size.width
            name.draw(at: NSPoint(x: x, y: y), withAttributes: tickAttrs)
            x -= 9
            let dot = NSBezierPath(ovalIn: NSRect(x: x, y: y + size.height / 2 - 2.5, width: 6, height: 6))
            s.color.setFill()
            dot.fill()
            x -= 12
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
        if let t = trackingAreaRef { removeTrackingArea(t) }
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
    func drawHover(in plot: NSRect, xFor: (Date) -> CGFloat, yFor: (Double) -> CGFloat) {
        guard let h = hoverPoint, plot.contains(h), panAnchor == nil else { return }
        let t = time(atX: h.x)

        NSColor.secondaryLabelColor.withAlphaComponent(0.55).setStroke()
        let line = NSBezierPath()
        line.lineWidth = 1
        line.move(to: NSPoint(x: h.x, y: plot.minY))
        line.line(to: NSPoint(x: h.x, y: plot.maxY))
        line.stroke()

        // Nearest sample per series, not interpolation: these are bucketed
        // averages, and inventing a value between two buckets would report a
        // number that was never measured.
        var lines: [(String, NSColor, Double)] = []
        for s in sanitized {
            guard let near = s.points.min(by: {
                abs($0.time.timeIntervalSince(t)) < abs($1.time.timeIntervalSince(t))
            }) else { continue }
            guard abs(near.time.timeIntervalSince(t)) < max(60, currentSpan / 40) else { continue }
            lines.append((s.name, s.color, near.value))
            let p = NSPoint(x: xFor(near.time), y: yFor(near.value))
            s.color.setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
        }
        guard !lines.isEmpty else { return }

        let df = DateFormatter()
        df.dateFormat = currentSpan > 86400 ? "d MMM HH:mm" : "HH:mm:ss"
        var text = df.string(from: t)
        for l in lines { text += String(format: "\n%@  %.2f", l.0, l.2) }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        // Flip the box to the other side of the crosshair near the right edge so
        // it never gets clipped by the plot bounds.
        let boxW = size.width + 14, boxH = size.height + 10
        let left = h.x + 12 + boxW > plot.maxX ? h.x - 12 - boxW : h.x + 12
        let bottom = min(max(h.y - boxH / 2, plot.minY), plot.maxY - boxH)
        let box = NSRect(x: left, y: bottom, width: boxW, height: boxH)

        NSColor.controlBackgroundColor.withAlphaComponent(0.96).setFill()
        let bp = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        bp.fill()
        NSColor.separatorColor.setStroke()
        bp.stroke()
        (text as NSString).draw(at: NSPoint(x: box.minX + 7, y: box.minY + 5), withAttributes: attrs)
    }

    private var currentSpan: TimeInterval {
        let d = effectiveDomain
        return d.end.timeIntervalSince(d.start)
    }
}

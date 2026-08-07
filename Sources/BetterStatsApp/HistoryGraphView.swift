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
//    the entity, and the entity is named by the caller, not by us.
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
        public init(time: Date, value: Double) {
            self.time = time
            self.value = value
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

        // Horizontal scale. Right edge = newest sample ("now" from the data's
        // point of view — this view has no clock of its own). A single point or
        // identical timestamps get a synthetic 60 s window so the axis still
        // means something.
        var tMax = tMaxD
        var span = haveData ? tMaxD.timeIntervalSince(tMinD) : 60
        if !haveData { tMax = Date() }
        if span < 1 { span = 60 }
        let tMin = tMax.addingTimeInterval(-span)

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
            let s = Self.timeLabel(back) as NSString
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
            // ── Secondary series: battery charge on the right axis ──────────────
        if let r = rightSeries {
            let pts = r.points
                .filter { $0.value.isFinite }
                .sorted { $0.time < $1.time }
            if pts.count >= 2 {
                let path = NSBezierPath()
                path.lineWidth = 1.6
                path.lineJoinStyle = .round
                var started = false
                for p in pts {
                    let pt = NSPoint(x: xFor(p.time), y: yForRight(p.value))
                    if started { path.line(to: pt) } else { path.move(to: pt); started = true }
                }
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: plot).addClip()
                r.color.setStroke()
                path.stroke()
                NSGraphicsContext.restoreGraphicsState()

                // Endpoint dot: the current charge, which is the value people read.
                if let last = pts.last {
                    r.color.setFill()
                    let c = NSPoint(x: xFor(last.time), y: yForRight(last.value))
                    NSBezierPath(ovalIn: NSRect(x: c.x - 2.6, y: c.y - 2.6,
                                                width: 5.2, height: 5.2)).fill()
                }
            }

            // Right-hand tick labels, in the series colour so it is unambiguous
            // which line the axis belongs to.
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
            let pts = r.points
                .filter { $0.value.isFinite }
                .sorted { $0.time < $1.time }
            if pts.count >= 2 {
                let path = NSBezierPath()
                path.lineWidth = 1.6
                path.lineJoinStyle = .round
                var started = false
                for p in pts {
                    let pt = NSPoint(x: xFor(p.time), y: yForRight(p.value))
                    if started { path.line(to: pt) } else { path.move(to: pt); started = true }
                }
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: plot).addClip()
                r.color.setStroke()
                path.stroke()
                NSGraphicsContext.restoreGraphicsState()

                // Endpoint dot: the current charge, which is the value people read.
                if let last = pts.last {
                    r.color.setFill()
                    let c = NSPoint(x: xFor(last.time), y: yForRight(last.value))
                    NSBezierPath(ovalIn: NSRect(x: c.x - 2.6, y: c.y - 2.6,
                                                width: 5.2, height: 5.2)).fill()
                }
            }

            // Right-hand tick labels, in the series colour so it is unambiguous
            // which line the axis belongs to.
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

        var lineNodes: [(x: CGFloat, y: CGFloat)] = []
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
            for (i, b) in buckets.enumerated() where b.n > 0 {
                let bx = xFor(t0.addingTimeInterval((Double(i) + 0.5) / Double(bucketCount) * spanS))
                let mean = b.sum / Double(b.n)
                lineNodes.append((bx, yFor(mean)))
                // Whisker only when the bucket's true range visibly exceeds the
                // stroke itself (> ~2.5 pt) — below that the line already
                // covers it and extra ink is just noise.
                if abs(yFor(b.maxV) - yFor(b.minV)) > 2.5 {
                    whiskers.append((bx, yFor(b.minV), yFor(b.maxV)))
                }
            }
        } else {
            // Sparser than the pixels: draw the actual samples, no decimation.
            for p in pts { lineNodes.append((xFor(p.time), yFor(p.value))) }
        }
        guard lineNodes.count >= 2 else {
            if let n = lineNodes.first {
                let dot = NSBezierPath(ovalIn: NSRect(x: n.x - 2.5, y: n.y - 2.5, width: 5, height: 5))
                s.color.setFill()
                dot.fill()
            }
            return
        }

        let line = NSBezierPath()
        line.lineWidth = 1.5
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        line.move(to: NSPoint(x: lineNodes[0].x, y: lineNodes[0].y))
        for n in lineNodes.dropFirst() { line.line(to: NSPoint(x: n.x, y: n.y)) }

        if s.filled {
            // Fill down to the zero line (or the plot floor if 0 is offscreen),
            // translucent so the grid and band remain visible through it.
            let fill = line.copy() as! NSBezierPath
            fill.line(to: NSPoint(x: lineNodes[lineNodes.count - 1].x, y: zeroY))
            fill.line(to: NSPoint(x: lineNodes[0].x, y: zeroY))
            fill.close()
            s.color.withAlphaComponent(0.13).setFill()
            fill.fill()
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

    /// Top row: y-axis label on the left, legend on the right. Text wears text
    /// colors — the colored dot alone carries series identity.
    private func drawHeader(plotTop: CGFloat, tickAttrs: [NSAttributedString.Key: Any]) {
        let y = bounds.height - 13.0
        if !yAxisLabel.isEmpty {
            (yAxisLabel as NSString).draw(at: NSPoint(x: 6, y: y), withAttributes: tickAttrs)
        }
        // One series needs no legend (the axis label / context names it).
        guard sanitized.count >= 2 else { return }
        var x = bounds.width - 8
        for s in sanitized.reversed() {
            let name = s.name as NSString
            let size = name.size(withAttributes: tickAttrs)
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

import AppKit
import XCTest
@testable import AnodeApp
@testable import PowerKit

// Offscreen rendering of the chrome — the graph, the table header, the row
// background, a Resources card.
//
// These exist because the visual layer is the one part of this app with no other
// witness: a plot that lays out to nothing, a mark drawn in an ink that matches
// its own ground, or an axis that maps values upside down all compile, all pass
// every other test, and all show up only on a screen someone happens to be
// looking at. Rendering one real frame into a bitmap and reading the pixels back
// is the cheapest way to have an opinion about that.
//
// The views are hosted in a REAL NSWindow. `layoutSubtreeIfNeeded` on a view with
// no window does not settle an Auto Layout tree the way it does in one, and a test
// built on the difference measures a layout that never happens in the app.

/// `.prohibited` before anything else — the test binary needs AppKit's objects,
/// not a Dock tile, and certainly not to steal focus from whoever is at the
/// machine. Palette also force-unwraps `NSApp`, so this has to exist before any
/// view is styled.
private let appKitForTests: NSApplication = {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    return app
}()

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Harness

/// One rendered frame, with the pixels addressable in the VIEW's coordinates.
///
/// The bitmap runs top-down and may be 2x on a Retina backing store; the view
/// runs bottom-up in points. Every reader below goes through here so that
/// conversion is written once — getting it wrong silently turns "is there a line
/// at the bottom" into "is there a line at the top", and both answers look
/// plausible.
private struct Frame {
    let rep: NSBitmapImageRep
    let viewSize: NSSize
    /// Set from the view. A flipped view counts y DOWN from the top, which is the
    /// same direction the bitmap runs — so the conversion below is a no-op for it
    /// and an inversion for everything else. The ledger bar is flipped and the
    /// graph is not; a single convention here would silently read one of them
    /// upside down.
    var flipped: Bool = false

    var scaleX: CGFloat { CGFloat(rep.pixelsWide) / viewSize.width }
    var scaleY: CGFloat { CGFloat(rep.pixelsHigh) / viewSize.height }

    private func forEachPixel(in r: NSRect, _ body: (NSColor) -> Void) {
        let x0 = max(0, Int((r.minX * scaleX).rounded(.down)))
        let x1 = min(rep.pixelsWide, Int((r.maxX * scaleX).rounded(.up)))
        // View y counts up from the bottom; bitmap rows count down from the top.
        let top = flipped ? r.minY : viewSize.height - r.maxY
        let bot = flipped ? r.maxY : viewSize.height - r.minY
        let y0 = max(0, Int((top * scaleY).rounded(.down)))
        let y1 = min(rep.pixelsHigh, Int((bot * scaleY).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return }
        for y in y0..<y1 {
            for x in x0..<x1 {
                if let c = rep.colorAt(x: x, y: y) { body(c) }
            }
        }
    }

    /// Perceived brightness, 0…1, of the brightest pixel in a region.
    func maxLuminance(in r: NSRect) -> CGFloat {
        var best: CGFloat = 0
        forEachPixel(in: r) { c in
            guard let s = c.usingColorSpace(.sRGB) else { return }
            let l = 0.2126 * s.redComponent + 0.7152 * s.greenComponent
                  + 0.0722 * s.blueComponent
            if l > best { best = l }
        }
        return best
    }

    /// Average perceived brightness over a region, weighted by coverage.
    ///
    /// The measure for LAYERING. `maxLuminance` finds the single brightest pixel,
    /// which in a region containing any exposed ground is that ground rather than
    /// the wash being tested; `maxAlpha` saturates at 1 the moment anything opaque
    /// is drawn, so every layer above it becomes invisible. Both were tried here
    /// first, and both reported "no change" for washes that were plainly stacking.
    func meanLuminance(in r: NSRect) -> CGFloat {
        var total: CGFloat = 0, n = 0
        forEachPixel(in: r) { c in
            guard let s = c.usingColorSpace(.sRGB) else { return }
            // Premultiplied by alpha, so a translucent wash over nothing counts as
            // the little light it actually adds.
            let l = 0.2126 * s.redComponent + 0.7152 * s.greenComponent
                  + 0.0722 * s.blueComponent
            total += l * s.alphaComponent
            n += 1
        }
        return n == 0 ? 0 : total / CGFloat(n)
    }

    func maxAlpha(in r: NSRect) -> CGFloat {
        var best: CGFloat = 0
        forEachPixel(in: r) { c in if c.alphaComponent > best { best = c.alphaComponent } }
        return best
    }

    /// How many pixels in a region are NOT the view's own ground. "Something was
    /// drawn here" without naming the ink, which keeps these tests indifferent to
    /// the display's colour space.
    func ink(in r: NSRect, ground: NSColor, tolerance: CGFloat = 0.06) -> Int {
        guard let g = ground.usingColorSpace(.sRGB) else { return 0 }
        var n = 0
        forEachPixel(in: r) { c in
            guard let s = c.usingColorSpace(.sRGB) else { return }
            let d = max(abs(s.redComponent - g.redComponent),
                        max(abs(s.greenComponent - g.greenComponent),
                            abs(s.blueComponent - g.blueComponent)))
            if d > tolerance || abs(s.alphaComponent - g.alphaComponent) > tolerance { n += 1 }
        }
        return n
    }

    /// One pixel, in view coordinates.
    ///
    /// Reference inks are sampled FROM THE FRAME rather than named, because the
    /// backing store is the display's colour space: a Palette colour defined in
    /// sRGB, rendered into a P3 buffer and read back as sRGB, comes out with a
    /// red component of 0.47 where the token says 0. Comparing rendered pixels to
    /// each other is exact; comparing them to a token is a test of the display.
    func color(atViewPoint p: NSPoint) -> NSColor? {
        let y = flipped ? p.y : viewSize.height - p.y
        return rep.colorAt(x: Int(p.x * scaleX), y: Int(y * scaleY))?
            .usingColorSpace(.sRGB)
    }

    /// Pixels in a region that are (close to) one specific ink, and opaque. Used
    /// where the question really is "how much of this colour is on screen".
    func count(in r: NSRect, near target: NSColor, tolerance: CGFloat = 0.12) -> Int {
        guard let t = target.usingColorSpace(.sRGB) else { return 0 }
        var n = 0
        forEachPixel(in: r) { c in
            guard let s = c.usingColorSpace(.sRGB), s.alphaComponent > 0.5 else { return }
            let d = max(abs(s.redComponent - t.redComponent),
                        max(abs(s.greenComponent - t.greenComponent),
                            abs(s.blueComponent - t.blueComponent)))
            if d <= tolerance { n += 1 }
        }
        return n
    }

    /// The vertical middle of whatever ink is in a vertical slab, in view points.
    /// nil when the slab is empty.
    func inkCentroidY(inColumn x: CGFloat, width: CGFloat, ground: NSColor) -> CGFloat? {
        guard let g = ground.usingColorSpace(.sRGB) else { return nil }
        var sum: CGFloat = 0, n: CGFloat = 0
        let x0 = max(0, Int(x * scaleX)), x1 = min(rep.pixelsWide, Int((x + width) * scaleX))
        guard x1 > x0 else { return nil }
        for py in 0..<rep.pixelsHigh {
            for px in x0..<x1 {
                guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                let d = max(abs(c.redComponent - g.redComponent),
                            max(abs(c.greenComponent - g.greenComponent),
                                abs(c.blueComponent - g.blueComponent)))
                guard d > 0.10 else { continue }
                sum += viewSize.height - CGFloat(py) / scaleY
                n += 1
            }
        }
        return n > 0 ? sum / n : nil
    }
}

/// Host `view` in a window, lay it out, and render one frame.
@discardableResult
private func render(_ view: NSView, size: NSSize) -> Frame {
    _ = appKitForTests
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let content = NSView(frame: NSRect(origin: .zero, size: size))
    window.contentView = content
    if view.translatesAutoresizingMaskIntoConstraints {
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
    } else {
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }
    content.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        return Frame(rep: NSBitmapImageRep(), viewSize: size)
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    return Frame(rep: rep, viewSize: view.bounds.size, flipped: view.isFlipped)
}

/// A ramp of `n` points ending now.
private func ramp(_ values: [Double], over seconds: TimeInterval) -> [HistoryGraphView.Point] {
    let end = Date()
    let step = seconds / Double(max(values.count - 1, 1))
    return values.enumerated().map {
        .init(time: end.addingTimeInterval(-seconds + Double($0.offset) * step),
              value: $0.element)
    }
}

/// Run a block with the app pinned to one appearance, then put it back.
/// Palette resolves from `NSApp.effectiveAppearance`, so a test that asserts on
/// its inks has to say which theme it means.
private func inTheme(_ name: NSAppearance.Name, _ body: () -> Void) {
    _ = appKitForTests
    let saved = NSApp.appearance
    NSApp.appearance = NSAppearance(named: name)
    defer { NSApp.appearance = saved }
    body()
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: The graph

final class GraphRenderTests: XCTestCase {

    /// `Palette` force-unwraps `NSApp`, and a Swift global is lazy: something has
    /// to touch the application object before the first colour is asked for.
    override func setUp() { _ = appKitForTests }


    private func graph(label: String, series: [HistoryGraphView.Series])
        -> HistoryGraphView {
        let g = HistoryGraphView(frame: .zero)
        g.showsGrid = false           // as every caller in this app has it
        g.yAxisLabel = label
        g.series = series
        return g
    }

    /// The whole harness in one assertion: real data goes in, a line comes out,
    /// and it goes DOWN as the data goes down. An inverted y axis is the one
    /// drawing bug that looks completely fine until you read it.
    func testTheLineFollowsTheDataDownwards() {
        let falling = (0..<60).map { 10.0 - Double($0) * (9.0 / 59.0) }
        let g = graph(label: "%/hr",
                      series: [.init(name: "total", color: Palette.accent,
                                     points: ramp(falling, over: 3600))])
        let frame = render(g, size: NSSize(width: 420, height: 140))
        let plot = g.lastPlot
        XCTAssertGreaterThan(plot.width, 200, "the plot laid out to nothing")
        XCTAssertGreaterThan(plot.height, 60, "the plot laid out to nothing")

        // The view's OWN ground. This named `controlBackgroundColor`, which was
        // never what the graph painted — it only worked while every other ink in
        // the plot happened to sit far from it.
        let ground = Palette.background
        guard let left = frame.inkCentroidY(inColumn: plot.minX + plot.width * 0.10,
                                            width: 4, ground: ground),
              let right = frame.inkCentroidY(inColumn: plot.minX + plot.width * 0.85,
                                             width: 4, ground: ground) else {
            return XCTFail("no line was drawn in the plot at all")
        }
        XCTAssertGreaterThan(left, right + 15,
                             "a falling series did not render as a falling line")
    }

    /// A card has no axis name and no legend, so it has nothing to put in the
    /// header band — and 18 pt of reserved air is a fifth of an 88 pt card. The
    /// band is given back to the plot, and only when it really is empty.
    func testAnEmptyHeaderBandIsGivenBackToThePlot() {
        let points = ramp([1, 4, 2, 6, 3], over: 900)
        let size = NSSize(width: 220, height: 96)

        let bare = graph(label: "", series: [.init(name: "%", color: Palette.accent,
                                                   points: points)])
        render(bare, size: size)

        let named = graph(label: "%/hr", series: [.init(name: "%", color: Palette.accent,
                                                        points: points)])
        render(named, size: size)

        XCTAssertEqual(bare.lastPlot.height - named.lastPlot.height, 10, accuracy: 0.01,
                       "the card's plot did not get the empty header band back")
        XCTAssertEqual(bare.lastPlot.minY, named.lastPlot.minY, accuracy: 0.01,
                       "the time axis moved; only the top should have")
    }

    /// A view whose header is overlaid by a control its owner drew keeps the band
    /// even with nothing of its own in it — the range picker lives there.
    func testAReservedHeaderIsNotGivenBack() {
        let points = ramp([1, 4, 2], over: 900)
        let size = NSSize(width: 220, height: 96)
        let g = graph(label: "", series: [.init(name: "%", color: Palette.accent,
                                                points: points)])
        g.headerTrailingInset = 190
        render(g, size: size)

        let named = graph(label: "%/hr", series: [.init(name: "%", color: Palette.accent,
                                                        points: points)])
        render(named, size: size)
        XCTAssertEqual(g.lastPlot.height, named.lastPlot.height, accuracy: 0.01,
                       "the band an owner is drawing into was given away")
    }

    /// Six 11 pt labels down a 55 pt axis touch each other, and a ladder whose
    /// rungs touch is not a scale. ~30 pt of air per rung.
    func testAShortPlotThinsItsValueLadder() {
        XCTAssertEqual(HistoryGraphView.yTickTarget(forPlotHeight: 55), 2)
        XCTAssertEqual(HistoryGraphView.yTickTarget(forPlotHeight: 95), 3)
        XCTAssertEqual(HistoryGraphView.yTickTarget(forPlotHeight: 400), 5,
                       "a tall plot is still capped: a ladder is not a grid")
        XCTAssertEqual(HistoryGraphView.yTickTarget(forPlotHeight: 0), 2,
                       "a degenerate height must not ask for zero rungs")
        XCTAssertEqual(HistoryGraphView.yTickTarget(forPlotHeight: .nan), 2)
    }

    /// Every caller in this app draws with the grid OFF, so the value axis had
    /// nothing on it at all — the line wandered across an unmarked field. The
    /// baseline is where the axis reads zero, and it is not part of the grid.
    func testTheBaselineIsDrawnWithTheGridOff() {
        // Deliberately unfilled: an area fill would put ink on the floor for a
        // completely different reason and the assertion would prove nothing.
        let g = graph(label: "%/hr",
                      series: [.init(name: "total", color: Palette.accent,
                                     points: ramp([5, 5.2, 4.8, 5.1, 5], over: 3600),
                                     filled: false)])
        let frame = render(g, size: NSSize(width: 420, height: 140))
        let plot = g.lastPlot
        XCTAssertGreaterThan(plot.height, 60)

        // A 3 pt band on the plot floor, well away from the line at ~5 of a ~6
        // axis, and above the time labels which sit below the plot entirely.
        let floorBand = NSRect(x: plot.midX - 60, y: plot.minY - 1, width: 120, height: 3)
        XCTAssertGreaterThan(frame.ink(in: floorBand, ground: NSColor.controlBackgroundColor),
                             40, "the value axis has no baseline on it")
    }

    /// The gap bridges, the whiskers and the empty state are load-bearing honesty
    /// features; a restyle must not have quietly dropped one. The bridge is grey
    /// and dashed and the only thing between two runs, so ink in the hole means
    /// it survived.
    func testAGapIsStillBridgedRatherThanLeftAsAHole() {
        let end = Date()
        var pts: [HistoryGraphView.Point] = []
        for i in 0..<20 {   // first run: 20 minutes of samples, one a minute
            pts.append(.init(time: end.addingTimeInterval(-3600 + Double(i) * 60), value: 4))
        }
        for i in 0..<20 {   // second run, after a 20 minute hole
            pts.append(.init(time: end.addingTimeInterval(-1200 + Double(i) * 60), value: 4))
        }
        let g = graph(label: "%/hr",
                      series: [.init(name: "total", color: Palette.accent, points: pts)])
        let frame = render(g, size: NSSize(width: 420, height: 140))
        let plot = g.lastPlot
        // The hole spans roughly the middle third of the hour.
        let hole = NSRect(x: plot.minX + plot.width * 0.48, y: plot.minY,
                          width: plot.width * 0.08, height: plot.height)
        XCTAssertGreaterThan(frame.ink(in: hole, ground: NSColor.controlBackgroundColor),
                             5, "the gap reads as a rendering fault, not as a gap")
    }

    /// Empty data draws axes and a sentence, never a blank rectangle — a blank
    /// rectangle looks like a bug and "not enough history yet" is the truth.
    func testAnEmptyGraphStillSaysSomething() {
        let g = graph(label: "%/hr", series: [])
        let frame = render(g, size: NSSize(width: 420, height: 140))
        XCTAssertGreaterThan(
            frame.ink(in: NSRect(x: 0, y: 0, width: 420, height: 140),
                      ground: NSColor.controlBackgroundColor),
            200, "an empty graph rendered as an empty rectangle")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Table chrome

final class TableChromeRenderTests: XCTestCase {

    /// `Palette` force-unwraps `NSApp`, and a Swift global is lazy: something has
    /// to touch the application object before the first colour is asked for.
    override func setUp() { _ = appKitForTests }


    /// Draw a header cell on its own bitmap. NSCell needs a control view to draw
    /// into; it does not need that view to be the real table.
    private func headerFrame(title: String, size: NSSize) -> Frame {
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let cell = AnodeHeaderCell(textCell: title)
        cell.draw(withFrame: NSRect(origin: .zero, size: size), in: host)
        NSGraphicsContext.restoreGraphicsState()
        return Frame(rep: rep, viewSize: size)
    }

    /// A header cell drawn the way the real one is: through a FLIPPED view's own
    /// draw path.
    ///
    /// `cacheDisplay(in:to:)` rather than a hand-made `NSGraphicsContext`, which is
    /// what `headerFrame` above does and what this started as. A context built
    /// straight from a bitmap rep is NOT flipped whatever view you hand alongside
    /// it — `isFlipped` only reaches the CTM through the view's own display
    /// machinery. So the first version of this drew bottom-up while telling `Frame`
    /// the image was top-down, and every up/down assertion read exactly inverted.
    /// `NSTableHeaderView` is flipped, and the chevron's direction is the whole
    /// point here, so the test has to render through the same path.
    private final class FlippedHost: NSView {
        var cell: AnodeHeaderCell?
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) { cell?.draw(withFrame: bounds, in: self) }
    }

    private func sortedHeader(title: String, size: NSSize,
                              _ indicator: AnodeHeaderCell.SortIndicator,
                              alignment: NSTextAlignment = .right)
        -> (frame: Frame, cell: AnodeHeaderCell) {
        let host = FlippedHost(frame: NSRect(origin: .zero, size: size))
        let cell = AnodeHeaderCell(textCell: title)
        cell.alignment = alignment
        cell.sortIndicator = indicator
        host.cell = cell
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return (Frame(rep: rep, viewSize: size, flipped: host.isFlipped), cell)
    }

    /// A view that colours a label from `Palette` repaints when the theme flips.
    ///
    /// `Palette` resolves at DRAW time, so anything drawn in `draw(_:)` corrects
    /// itself. A label's `textColor` does not — it is set once and keeps whatever
    /// the appearance was at that moment, so a pane could sit in the previous
    /// theme's ink beside panes that had already changed. The detail pane did.
    ///
    /// Asserted on the rendered result rather than on the presence of an override,
    /// because the override existing says nothing about it re-inking everything.
    func testTheDetailPaneReInksItselfWhenTheThemeChanges() {
        let view = AppDetailView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        // Built under one appearance...
        inTheme(.darkAqua) { _ = render(view, size: NSSize(width: 420, height: 300)) }
        // ...then shown under the other. Its inks must follow.
        inTheme(.aqua) {
            view.viewDidChangeEffectiveAppearance()
            let light = render(view, size: NSSize(width: 420, height: 300))
                .maxLuminance(in: NSRect(x: 0, y: 0, width: 420, height: 300))
            XCTAssertGreaterThan(light, 0.5,
                                 "the detail pane kept the dark theme's ground after a switch")
        }
    }

    /// A sideways chevron is the rotation of a downward one, not a flatter
    /// version of it.
    ///
    /// At a fixed 8x5 the right-pointing form has 8.4 pt legs against the
    /// down-pointing form's 6.4, which reads as two different marks — reported
    /// once as the collapsed chevrons looking too long. Swapping the axes is what
    /// makes them the same mark, and asserting on the LEG LENGTH says that
    /// directly rather than restating the sizes.
    func testEveryChevronIsTheSameMarkWhicheverWayItPoints() {
        func leg(_ d: Palette.Chevron) -> CGFloat {
            let s = d.size
            // Half the long axis, and the full short axis, is one leg.
            return (pow(s.width, 2) + pow(s.height, 2)).squareRoot()
        }
        let lengths = [Palette.Chevron.up, .down, .left, .right].map { leg($0) }
        for l in lengths {
            XCTAssertEqual(l, lengths[0], accuracy: 0.001,
                           "one direction draws a longer mark than the others")
        }
    }

    /// Only the sorted column is marked.
    ///
    /// This is the whole defect the chevron fixes: the table sorted correctly and
    /// said nothing about it, because `draw(withFrame:in:)` replaces the
    /// superclass's draw — and the superclass's draw is what would have called
    /// `drawSortIndicator`.
    func testOnlyTheSortedColumnDrawsAChevron() {
        inTheme(.darkAqua) {
            let size = NSSize(width: 90, height: 24)
            XCTAssertNil(sortedHeader(title: "% CPU", size: size, .none).cell.lastIndicatorRect,
                         "an unsorted column drew a sort marker")
            XCTAssertNotNil(sortedHeader(title: "% CPU", size: size, .descending)
                                .cell.lastIndicatorRect,
                            "the sorted column drew nothing to say so")
        }
    }

    /// The chevron points UP for ascending, and the two directions are told apart
    /// by where the ink is — not by a flag the drawing could ignore.
    ///
    /// Measured at the indicator's own top-left corner: a chevron with its apex up
    /// starts that corner empty and puts ink at the middle-top, and one pointing
    /// down does the reverse. Asserting on the rendered pixels rather than on the
    /// enum is the point, since the enum was always right and the drawing is what
    /// did not exist.
    func testTheChevronFlipsWithTheDirection() {
        inTheme(.darkAqua) {
            let size = NSSize(width: 90, height: 24)
            let up = sortedHeader(title: "% CPU", size: size, .ascending)
            let down = sortedHeader(title: "% CPU", size: size, .descending)
            let r = try! XCTUnwrap(up.cell.lastIndicatorRect)
            XCTAssertEqual(r, try! XCTUnwrap(down.cell.lastIndicatorRect),
                           "the two directions must occupy the same box")

            // Flipped: minY is the TOP edge on screen. Probe the APEX position —
            // the middle of the top edge. An up-pointing chevron puts its point
            // there; a down-pointing one has its two ends at the top corners and
            // nothing between them. The corners are a bad probe at this size: both
            // shapes have a stroke passing near them.
            let apex = NSRect(x: r.midX - 1, y: r.minY - 0.5, width: 2, height: 1.5)
            XCTAssertGreaterThan(up.frame.maxLuminance(in: apex),
                                 down.frame.maxLuminance(in: apex) + 0.1,
                                 "ascending should point up: ink at the top middle, and none for descending")
        }
    }

    /// The chevron stays inside its own column.
    ///
    /// Sized the way `autosizeColumns` sizes a header-bound column — the title,
    /// plus the 12 pt it reserves for exactly this marker, plus the 16 pt padding
    /// every non-name column gets. The reserve predates the drawing: it was added
    /// for an AppKit indicator that never appeared, so nothing had ever checked it
    /// was actually enough.
    func testTheChevronFitsInsideTheWidthTheSizerReserves() {
        inTheme(.darkAqua) {
            let title = "% CPU"
            let titleW = (title.uppercased() as NSString)
                .size(withAttributes: [.font: AnodeHeaderCell.font, .kern: 0.4]).width
            let size = NSSize(width: ceil(titleW + 12) + 16, height: 24)
            let h = sortedHeader(title: title, size: size, .descending)
            let r = try! XCTUnwrap(h.cell.lastIndicatorRect)
            XCTAssertGreaterThanOrEqual(r.minX, 0,
                                        "the chevron hangs off the leading edge into the column before it")
            XCTAssertLessThanOrEqual(r.maxX, size.width)
        }
    }

    /// The "*" is the whole difference between a measured column and an
    /// apportioned one, and in the header's own grey at 9.5 pt it was the least
    /// visible thing in the row. It is drawn in a brighter ink than the heading,
    /// which is a fact about pixels: nothing antialiased from `faint` onto the
    /// header ground can be brighter than `faint` itself.
    func testTheEstimateMarkIsBrighterThanTheHeadingItMarks() {
        inTheme(.darkAqua) {
            let size = NSSize(width: 90, height: 24)
            // Rendered against rendered: nothing antialiased from the heading's
            // own ink onto the header ground can be brighter than that ink, so a
            // marked header being brighter than an unmarked one is exactly the
            // claim "the mark is not drawn in the heading's colour".
            let plain = headerFrame(title: "GPU %", size: size)
                .maxLuminance(in: NSRect(origin: .zero, size: size))
            let marked = headerFrame(title: "GPU %*", size: size)
                .maxLuminance(in: NSRect(origin: .zero, size: size))

            XCTAssertGreaterThan(plain, 0.1, "the heading did not draw at all")
            XCTAssertGreaterThan(marked, plain + 0.05,
                                 "the estimate mark is drawn in the same ink as the heading")
        }
    }

    /// A header still says its column's name. Guards the split-run drawing from
    /// losing the heading while keeping the mark.
    func testAMarkedHeaderStillDrawsItsHeading() {
        inTheme(.darkAqua) {
            let size = NSSize(width: 90, height: 24)
            let blank = headerFrame(title: "", size: size)
                .ink(in: NSRect(origin: .zero, size: size), ground: Palette.surfaceAlt)
            let marked = headerFrame(title: "GPU %*", size: size)
                .ink(in: NSRect(origin: .zero, size: size), ground: Palette.surfaceAlt)
            XCTAssertGreaterThan(marked, blank + 60, "the heading itself went missing")
        }
    }

    /// Hover STACKS on selection: the row under the pointer is always the
    /// brightest thing on screen.
    ///
    /// This reverses an earlier decision. Selection used to win outright and carry
    /// a hard accent edge down its leading side, on the reasoning that hover and
    /// selection should be categorically different marks rather than one mark at
    /// two strengths. That bought a distinction nobody needs — you cannot look at
    /// a hovered row and a selected row as separate questions, because the pointer
    /// is on one of them — and it cost the obvious behaviour.
    ///
    /// Asserted as an ORDER rather than as three numbers, so it survives any
    /// future change to the wash strengths as long as the layering is kept.
    func testHoverStacksOnTopOfSelection() {
        inTheme(.darkAqua) {
            let size = NSSize(width: 320, height: 20)
            let sample = NSRect(x: 120, y: 2, width: 80, height: 16)

            func brightness(selected: Bool, hovered: Bool, alternate: Bool) -> CGFloat {
                let row = AnodeRowView(frame: NSRect(origin: .zero, size: size))
                row.isSelected = selected
                row.hoverForTesting = hovered
                row.alternateForTesting = alternate
                // MEAN luminance. Alpha saturates once the stripe is opaque, and
                // the brightest single pixel is whatever ground shows through —
                // both were tried and both reported "no change" for washes that
                // were visibly stacking.
                return render(row, size: size).meanLuminance(in: sample)
            }

            // BOTH stripe states. The alternating ground is the newest layer under
            // all of this, and a selection that vanished on the striped rows would
            // be a selection that works half the time.
            for alternate in [false, true] {
                let plain = brightness(selected: false, hovered: false, alternate: alternate)
                let selected = brightness(selected: true, hovered: false, alternate: alternate)
                let both = brightness(selected: true, hovered: true, alternate: alternate)

                XCTAssertGreaterThan(selected, plain + 0.02,
                                     "a selected row is not washed (alternate: \(alternate))")
                XCTAssertGreaterThan(both, selected + 0.02,
                                     "hovering a selected row did not brighten it — hover is "
                                     + "replacing the selection rather than stacking on it "
                                     + "(alternate: \(alternate))")
            }

            // And the stripe itself is actually visible. It was `surfaceAlt` at
            // 0.45 over a true black ground, which resolves to about (9, 12, 14) —
            // reported as "can barely see it".
            XCTAssertGreaterThan(brightness(selected: false, hovered: false, alternate: true),
                                 brightness(selected: false, hovered: false, alternate: false)
                                     + 0.02,
                                 "the alternating stripe is invisible")

            // THE WHOLE LADDER, IN ORDER, which is what was missing.
            //
            // Every assertion above compares a state against the SAME stripe
            // state, so all of them held while the stripe was brighter than the
            // hover that lands on top of it: measured 0.130 against 0.059, so a
            // hovered striped row was visibly DARKER than an untouched one and a
            // selected one barely moved. A ground brighter than its own signals is
            // not a ground, and no test said so.
            let ground = brightness(selected: false, hovered: false, alternate: false)
            let stripe = brightness(selected: false, hovered: false, alternate: true)
            let hover = brightness(selected: false, hovered: true, alternate: false)
            let sel = brightness(selected: true, hovered: false, alternate: false)
            let both = brightness(selected: true, hovered: true, alternate: false)
            for (lo, hi, what) in [(ground, stripe, "ground → stripe"),
                                   (stripe, hover, "stripe → hover"),
                                   (hover, sel, "hover → selected"),
                                   (sel, both, "selected → hovered-selected")] {
                XCTAssertGreaterThan(hi, lo + 0.02,
                                     "\(what) is not a step up — the row states must be "
                                     + "ordered, and the stripe must be quieter than every "
                                     + "signal that lands on it")
            }
        }
    }

    /// A HOVERED ROW LOOKS THE SAME WHATEVER IT IS SITTING ON.
    ///
    /// THE REPORTED CASE. Hover and selection were `selection` at two alphas,
    /// painted over whatever ground the row had — and a tint of two different
    /// grounds is two different colours, so the same hover read one way on a
    /// striped row and another on a plain one.
    ///
    /// They are finished colours now, which is what makes the claim testable at
    /// all: "the same" is a measurable thing to say about two opaque fills and a
    /// vague one about two translucent ones.
    func testAStateLooksTheSameOnBothGrounds() {
        inTheme(.darkAqua) {
            let size = NSSize(width: 320, height: 20)
            let sample = NSRect(x: 120, y: 2, width: 80, height: 16)
            func shade(selected: Bool, hovered: Bool, alternate: Bool) -> CGFloat {
                let v = AnodeRowView(frame: NSRect(origin: .zero, size: size))
                v.isSelected = selected
                v.hoverForTesting = hovered
                v.alternateForTesting = alternate
                return render(v, size: size).meanLuminance(in: sample)
            }
            for (name, selected, hovered) in [
                ("hovered", false, true),
                ("selected", true, false),
                ("selected and hovered", true, true),
            ] {
                XCTAssertEqual(shade(selected: selected, hovered: hovered, alternate: false),
                               shade(selected: selected, hovered: hovered, alternate: true),
                               accuracy: 0.002,
                               "a \(name) row looks different on the striped ground")
            }
            // And the plain rows still differ, or the stripe would be pointless.
            XCTAssertNotEqual(shade(selected: false, hovered: false, alternate: false),
                              shade(selected: false, hovered: false, alternate: true),
                              accuracy: 0.002)
        }
    }

    /// The stripe reaches the row's own top and bottom edge.
    ///
    /// It was drawn with the selection pill's geometry, which insets a point
    /// vertically — right for a mark that sits ON a row, wrong for the row's
    /// ground. That left a sliver of window between the stripe and the separator
    /// above it, and two rows apart the sliver is 2 pt, which is why it was
    /// visible: reported as a gap between the ledger line and the top of the
    /// highlight.
    ///
    /// Measured at the very first and last row of pixels, well inside the
    /// horizontal inset so the corner radius cannot be what is being sampled.
    func testTheAlternatingStripeFillsTheWholeRowHeight() {
        inTheme(.darkAqua) {
            let size = NSSize(width: 320, height: 20)
            func row(_ alternate: Bool) -> Frame {
                let v = AnodeRowView(frame: NSRect(origin: .zero, size: size))
                v.alternateForTesting = alternate
                return render(v, size: size)
            }
            let mid = NSRect(x: 140, y: 0, width: 40, height: 1)          // top edge
            let bottom = NSRect(x: 140, y: size.height - 1, width: 40, height: 1)
            let striped = row(true), plain = row(false)
            XCTAssertGreaterThan(striped.meanLuminance(in: mid),
                                 plain.meanLuminance(in: mid) + 0.01,
                                 "the stripe stops short of the row's top edge")
            XCTAssertGreaterThan(striped.meanLuminance(in: bottom),
                                 plain.meanLuminance(in: bottom) + 0.01,
                                 "the stripe stops short of the row's bottom edge")
        }
    }

    /// Every ground reaches both edges of the row.
    ///
    /// They were pills inset 6 pt with an 8 pt radius, so a highlight stopped
    /// 14 pt short at each end — reported as the ledger lines not reaching the
    /// front or the back. Twelve columns is a long way for the eye to hold one
    /// row across, and the highlight is the only line it has to follow.
    ///
    /// Sampled in the outermost column of pixels, which a pill of any radius
    /// cannot reach.
    func testTheRowGroundsReachBothEdges() {
        inTheme(.darkAqua) {
            let size = NSSize(width: 320, height: 20)
            func edges(_ configure: (AnodeRowView) -> Void) -> (CGFloat, CGFloat) {
                let v = AnodeRowView(frame: NSRect(origin: .zero, size: size))
                configure(v)
                let f = render(v, size: size)
                let mid = NSRect(x: 0, y: 8, width: 1, height: 4)
                let far = NSRect(x: size.width - 1, y: 8, width: 1, height: 4)
                return (f.meanLuminance(in: mid), f.meanLuminance(in: far))
            }
            let plain = edges { _ in }
            for (name, configure) in [
                ("stripe", { (v: AnodeRowView) in v.alternateForTesting = true }),
                ("selection", { (v: AnodeRowView) in v.isSelected = true }),
                ("hover", { (v: AnodeRowView) in v.hoverForTesting = true }),
            ] {
                let (leading, trailing) = edges(configure)
                XCTAssertGreaterThan(leading, plain.0 + 0.01,
                                     "the \(name) does not reach the leading edge")
                XCTAssertGreaterThan(trailing, plain.1 + 0.01,
                                     "the \(name) does not reach the trailing edge")
            }
        }
    }

    /// And the separator is ruled on every row, including the ones with a ground.
    ///
    /// It was suppressed wherever the row had a shape of its own, because a rule
    /// across the bottom of a rounded pill clips its corners. Once every other row
    /// gained a stripe, that quietly removed the line from half the table.
    func testTheSeparatorIsRuledOnEveryRow() {
        inTheme(.darkAqua) {
            let size = NSSize(width: 320, height: 20)
            func hasRule(_ configure: (AnodeRowView) -> Void) -> CGFloat {
                let v = AnodeRowView(frame: NSRect(origin: .zero, size: size))
                configure(v)
                let f = render(v, size: size)
                // The last row of pixels against the row just above it.
                return f.meanLuminance(in: NSRect(x: 40, y: size.height - 1,
                                                  width: 240, height: 1))
                     - f.meanLuminance(in: NSRect(x: 40, y: size.height - 5,
                                                  width: 240, height: 1))
            }
            XCTAssertGreaterThan(hasRule { _ in }, 0.01, "a plain row lost its rule")
            XCTAssertGreaterThan(hasRule { $0.alternateForTesting = true }, 0.01,
                                 "a striped row has no separator under it")
        }
    }

    /// And nothing paints a hard accent edge any more. It was the mark that said
    /// "selected" categorically, and it is gone by request; a stray one would read
    /// as a second selection idiom.
    func testNoRowDrawsALeadingAccentEdge() {
        inTheme(.darkAqua) {
            let row = AnodeRowView(frame: .zero)
            row.isSelected = true
            let size = NSSize(width: 320, height: 20)
            let frame = render(row, size: size)
            let edge = frame.maxAlpha(in: NSRect(x: 6, y: 2, width: 3, height: 16))
            let wash = frame.maxAlpha(in: NSRect(x: 120, y: 2, width: 80, height: 16))
            XCTAssertLessThan(edge, wash + 0.2,
                              "the leading edge is still marked harder than the wash")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Resources cards

final class ResourcesCardRenderTests: XCTestCase {

    /// `Palette` force-unwraps `NSApp`, and a Swift global is lazy: something has
    /// to touch the application object before the first colour is asked for.
    override func setUp() { _ = appKitForTests }


    /// ONE ink across the whole Resources tab, which reverses what this test used
    /// to assert.
    ///
    /// It required every resource to have its OWN colour, on the argument that a
    /// glance at the rail and a glance at the detail should agree about what is
    /// being looked at. That argument is for a chart with several lines on it.
    /// Here the rail is six cards each showing one line and the detail shows one
    /// resource at a time, so the colour separated nothing — the name is already
    /// beside the number — while making the app change colour as you moved
    /// through it. Reported as "some colours change from resource tab to resource
    /// tab".
    ///
    /// The other hues are still in the palette and the ledger still uses them,
    /// where they do separate things drawn together.
    func testTheResourcesTabUsesOneInkThroughout() throws {
        let sources = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AnodeApp/ResourcesPane.swift"),
            encoding: .utf8)
        for line in sources.split(separator: "\n") {
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//") else { continue }
            XCTAssertFalse(code.contains(".color") && code.contains("Resource"),
                           "a per-resource colour came back: \(code)")
        }
    }

    /// Selection on a card is a WASH, and only a wash.
    ///
    /// This used to require an opaque edge down the leading side as well —
    /// borrowed from the process table's selected row, where a wash alone is easy
    /// to lose among hundreds. The rail is six items, where a wash is
    /// unmistakable, and the edge was drawn in the resource's own colour: the one
    /// mark meaning "this is selected" was also the mark that made six cards look
    /// like six unrelated widgets.
    ///
    /// The table keeps its edge. `testASelectedRowIsMarkedAndNotJustWashed` above
    /// is the one that still asserts it, and it is a different question about a
    /// different list.
    func testASelectedCardIsWashedAndCarriesNoEdge() {
        inTheme(.darkAqua) {
            let card = ResourceCard(resource: .cpu, onClick: { _ in })
            card.isSelected = true
            let size = NSSize(width: 210, height: 58)
            let frame = render(card, size: size)

            let edge = frame.maxAlpha(in: NSRect(x: 0, y: 6, width: 2, height: 46))
            let wash = frame.maxAlpha(in: NSRect(x: 120, y: 6, width: 60, height: 46))
            XCTAssertGreaterThan(wash, 0.05, "the selection wash disappeared")
            XCTAssertLessThan(edge, wash + 0.15,
                              "the card still draws a hard edge beside its wash")
        }
    }

    /// An unselected card is not marked. The edge has to mean selection, or it
    /// means nothing.
    func testAnUnselectedCardHasNoEdgeMark() {
        inTheme(.darkAqua) {
            let card = ResourceCard(resource: .cpu, onClick: { _ in })
            let size = NSSize(width: 210, height: 58)
            let frame = render(card, size: size)
            XCTAssertLessThan(frame.maxAlpha(in: NSRect(x: 0, y: 6, width: 2, height: 46)),
                              0.6, "an unselected card drew a selection mark")
        }
    }

    /// The rail's card is a thumbnail by design — the plot is a fixed 74×36 next
    /// to the reading, not the card. The chart you actually read is the detail
    /// column's, and that one has to get a real share of the height: the graph is
    /// pinned to 42% of the column, so a layout change that starves it is caught
    /// here rather than on a screen.
    func testTheDetailGraphGetsALargeShareOfTheColumn() {
        let detail = ResourceDetailView(frame: .zero)
        let height: CGFloat = 640
        render(detail, size: NSSize(width: 620, height: height))

        XCTAssertGreaterThan(detail.graph.bounds.height, height * 0.30,
                             "the detail column spends too little of itself on the chart")
        XCTAssertLessThan(detail.graph.bounds.height, height * 0.55,
                          "the chart crowded out the properties block")
        XCTAssertGreaterThan(detail.graph.bounds.width, 400)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Palette

final class PaletteThemeTests: XCTestCase {

    /// `Palette` force-unwraps `NSApp`, and a Swift global is lazy: something has
    /// to touch the application object before the first colour is asked for.
    override func setUp() { _ = appKitForTests }


    private var tokens: [(String, NSColor)] {
        [("background", Palette.background), ("surface", Palette.surface),
         ("surfaceAlt", Palette.surfaceAlt), ("sidebar", Palette.sidebar),
         ("text", Palette.text), ("dim", Palette.dim), ("faint", Palette.faint),
         ("line", Palette.line), ("lineSoft", Palette.lineSoft),
         ("accent", Palette.accent), ("blue", Palette.blue),
         ("accentDim", Palette.accentDim), ("chargeLine", Palette.chargeLine),
         ("chargingLine", Palette.chargingLine), ("warn", Palette.warn),
         ("critical", Palette.critical), ("selection", Palette.selection),
         ("hatch", Palette.hatch), ("onAccent", Palette.onAccent),
         ("onBlue", Palette.onBlue)]
    }

    private func luma(_ c: NSColor) -> CGFloat {
        guard let s = c.usingColorSpace(.sRGB) else { return -1 }
        return 0.2126 * s.redComponent + 0.7152 * s.greenComponent + 0.0722 * s.blueComponent
    }

    /// Every token resolves in both appearances. A token that cannot convert to a
    /// concrete colour space is one that will draw as black, or not at all.
    func testEveryTokenResolvesInBothThemes() {
        for theme: NSAppearance.Name in [.aqua, .darkAqua] {
            inTheme(theme) {
                for (name, c) in tokens {
                    XCTAssertNotNil(c.usingColorSpace(.sRGB), "\(name) in \(theme.rawValue)")
                    XCTAssertGreaterThan(c.alphaComponent, 0, "\(name) in \(theme.rawValue)")
                }
            }
        }
    }

    /// Ink has to be legible on the ground it is drawn on, in BOTH themes. The
    /// failure this catches is a token defined for one appearance and left to sit
    /// on its own colour in the other.
    func testInkSeparatesFromItsGroundInBothThemes() {
        for theme: NSAppearance.Name in [.aqua, .darkAqua] {
            inTheme(theme) {
                let ground = luma(Palette.background)
                for (name, ink) in [("text", Palette.text), ("dim", Palette.dim),
                                    ("faint", Palette.faint), ("accent", Palette.accent)] {
                    XCTAssertGreaterThan(abs(luma(ink) - ground), 0.15,
                                         "\(name) is invisible on the ground in \(theme.rawValue)")
                }
                // The header's mark has to separate from the header's own text,
                // which is the whole point of using a second ink for it.
                XCTAssertGreaterThan(abs(luma(Palette.dim) - luma(Palette.faint)), 0.08,
                                     "the estimate mark is the same brightness as the heading")
            }
        }
    }

    /// The row rule was softened for the 20 pt pitch. Softened, not deleted: a
    /// hairline the eye cannot find is the same as no hairline, and twelve
    /// columns is a long way to track one row across.
    func testTheRowRuleIsStillVisibleAfterBeingSoftened() {
        for theme: NSAppearance.Name in [.aqua, .darkAqua] {
            inTheme(theme) {
                XCTAssertGreaterThan(Palette.lineSoft.alphaComponent, 0.25,
                                     "the row rule faded out entirely in \(theme.rawValue)")
                XCTAssertLessThan(Palette.lineSoft.alphaComponent,
                                  Palette.line.alphaComponent,
                                  "a row rule must sit lighter than a structural one")
            }
        }
    }

    /// The small-label voice is one font in one place. Three surfaces draw with
    /// it — the table header, the graph's axis name, the Resources card titles —
    /// and the header's autosizing measures with it, so a drift here silently
    /// sizes columns to a string nobody renders.
    func testTheSmallLabelVoiceIsShared() {
        let attrs = Palette.labelAttributes(Palette.faint)
        XCTAssertEqual(attrs[.font] as? NSFont, Palette.Font.label())
        XCTAssertEqual(attrs[.kern] as? CGFloat, Palette.Font.labelKern)
        XCTAssertEqual(AnodeHeaderCell.font, Palette.Font.label(),
                       "the table header stopped sharing the label voice")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: The ledger bar

final class LedgerBarRenderTests: XCTestCase {

    override func setUp() { _ = appKitForTests }

    /// Everything but the apps segment at zero, so the bar's layout is the only
    /// thing under test.
    private func model(apps: Double, total: Double, span: Double?)
        -> LedgerBarView.Model {
        LedgerBarView.Model(
            apps_pctHr: apps, systemProcesses_pctHr: 0, gpu_pctHr: 0,
            display_pctHr: 0, displayIsMeasured: true,
            memory_pctHr: 0, storage_pctHr: 0, usb_pctHr: 0, usbUnmeasured: false,
            unattributed_pctHr: max(0, total - apps),
            total_pctHr: total, span_pctHr: span,
            source: "test", readable: 1, attempted: 1, overflow: false)
    }

    private func appsPixels(_ m: LedgerBarView.Model) -> Int {
        let bar = LedgerBarView(frame: .zero)
        bar.model = m
        let size = NSSize(width: 400, height: 46)
        let frame = render(bar, size: size)
        // The apps segment always starts at the bar's left edge, so its own ink
        // is the reference — see `Frame.color(atViewPoint:)` for why it is not
        // taken from Palette.
        guard let ink = frame.color(atViewPoint: NSPoint(x: 3, y: 11)) else { return 0 }
        // The bar itself is the top 22 pt; the legend below it also draws an
        // accent swatch, and counting that would blunt the whole assertion.
        return frame.count(in: NSRect(x: 0, y: 0, width: size.width, height: 22),
                           near: ink, tolerance: 0.03)
    }

    /// `attributed_W` is instantaneous and `smoothed_W` is a 60 s mean, so under a
    /// sudden load the parts can genuinely outrun the headline for a few seconds.
    /// Laying out against the headline then drew "apps = 100% of the machine",
    /// which is a claim about the denominator rather than about the machine. The
    /// bar spans the SPAN; the legend still prints the headline.
    func testTheBarIsLaidOutAcrossTheSpanAndNotTheHeadline() {
        inTheme(.darkAqua) {
            let full = appsPixels(model(apps: 6, total: 6, span: nil))
            XCTAssertGreaterThan(full, 2000, "the apps segment did not render at all")

            let halved = appsPixels(model(apps: 6, total: 6, span: 12))
            XCTAssertGreaterThan(Double(halved), Double(full) * 0.35)
            XCTAssertLessThan(Double(halved), Double(full) * 0.65,
                              "a stated span did not change the layout")
        }
    }

    /// No span stated is the behaviour this view had before the field existed:
    /// lay out across the headline. A caller that has not been taught the new
    /// field must not get a differently-scaled bar out of it.
    func testAnUnstatedSpanFallsBackToTheHeadline() {
        inTheme(.darkAqua) {
            XCTAssertEqual(appsPixels(model(apps: 3, total: 6, span: nil)),
                           appsPixels(model(apps: 3, total: 6, span: 6)),
                           "nil span is not the same as span == total")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// The two ways a caller can say "the adapter is attached".
///
/// These shipped disagreeing. The 1H buffer knows `onAC` and the store knows
/// `on_battery`; both built the flag inline, and the live path negated `onAC` to
/// match the SHAPE of the store path's `!onBattery` — a double negative. The 1H
/// graph drew charging while the machine ran the battery down, and only 1H was
/// wrong, because only 1H comes from that buffer.
final class ChargePointPolarityTests: XCTestCase {

    /// One physical state, two vocabularies, one answer.
    func testBothWaysOfSayingItAgree() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        for onAC in [true, false] {
            let fromAC = HistoryGraphView.Point.charge(time: t, percent: 80, onAC: onAC)
            let fromBattery = HistoryGraphView.Point.charge(time: t, percent: 80,
                                                            onBattery: !onAC)
            XCTAssertEqual(fromAC.onPower, fromBattery.onPower,
                           "the two constructors disagree when onAC = \(onAC)")
        }
    }

    /// And the sign itself, stated once so a future "simplification" that flips
    /// it has something to fail against. `onPower` is what the renderer colours
    /// green, so true must mean ON THE ADAPTER.
    func testOnPowerMeansOnTheAdapter() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(HistoryGraphView.Point.charge(time: t, percent: 80, onAC: true).onPower,
                       true, "a machine on the adapter must draw as charging")
        XCTAssertEqual(HistoryGraphView.Point.charge(time: t, percent: 80, onAC: false).onPower,
                       false, "a machine on battery must not draw as charging")
        XCTAssertEqual(HistoryGraphView.Point.charge(time: t, percent: 80,
                                                     onBattery: true).onPower, false)
        XCTAssertEqual(HistoryGraphView.Point.charge(time: t, percent: 80,
                                                     onBattery: false).onPower, true)
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// The glance card's headline slot, which is sized for a duration.
///
/// It shipped clipped: "measuring…" in a slot tuned for "9h 41m" overflowed the
/// width and lost the bottom of every glyph, because the card's height comes from
/// the graph beside it and the stack is compressed rather than grown. Descenders
/// are the tell — a `g` that stops at the baseline is a frame that is too short —
/// so the test asks the font itself whether the line box can hold one.
final class GlanceHeadlineFitTests: XCTestCase {

    override func setUp() { _ = appKitForTests }

    /// A word must be set in a face whose line height fits the same slot a
    /// duration does, descenders included.
    func testAWordFitsTheSlotADurationFits() {
        let duration = Palette.Font.mono(30, .semibold)
        let word = Palette.Font.sans(21, .semibold)
        // Line height including the descent, which is the part that was cut.
        let durationLine = duration.ascender - duration.descender
        let wordLine = word.ascender - word.descender
        XCTAssertLessThanOrEqual(wordLine, durationLine,
                                 "a word is set taller than the slot a duration gets")
        XCTAssertLessThan(word.descender, 0, "this face has no descent to fit")
    }

    /// And it must be narrower, since the slot is a fixed strip.
    func testTheLongestWordUsedIsNoWiderThanTheLongestDuration() {
        let word = NSAttributedString(
            string: "measuring…",
            attributes: [.font: Palette.Font.sans(21, .semibold)]).size().width
        let duration = NSAttributedString(
            string: "10h 41m",
            attributes: [.font: Palette.Font.mono(30, .semibold)]).size().width
        XCTAssertLessThanOrEqual(word, duration * 1.05,
                                 "the word headline is wider than the slot it shares")
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// The battery chart's two axes, and the rail sparkline's lack of a pointer.
final class GraphAxisAndHoverTests: XCTestCase {

    override func setUp() { _ = appKitForTests }

    /// The whole point of the shared scale: a drain of 50 %/hr must sit at the
    /// same height as 50 % charge, so "half the battery in an hour" is legible
    /// without arithmetic. Read off the RENDERED frame, because a scale that
    /// agrees in the code and not on screen is the failure being prevented.
    func testFiftyPerHourLandsLevelWithFiftyPercent() {
        let g = HistoryGraphView(frame: .zero)
        g.sharesRightAxisScale = true
        let now = Date()
        let times = (0..<20).map { now.addingTimeInterval(-Double(19 - $0) * 60) }
        g.series = [.init(name: "total", color: Palette.accent,
                          points: times.map { .init(time: $0, value: 50) })]
        g.rightSeries = .init(name: "battery", color: Palette.chargeLine,
                              points: times.map { .init(time: $0, value: 50) })
        let size = NSSize(width: 520, height: 200)
        let frame = render(g, size: size)

        // Both lines are flat at 50; if the axes share a scale they are the same
        // line, so the ink in a mid column has ONE centre, not two.
        let mid = NSRect(x: 200, y: 0, width: 40, height: size.height)
        let centre = frame.inkCentroidY(inColumn: mid.minX, width: mid.width,
                                        ground: Palette.background)
        let c = try? XCTUnwrap(centre)
        XCTAssertNotNil(c)
        if let c {
            // Within a few points of the plot's vertical middle.
            XCTAssertEqual(c, size.height / 2, accuracy: 26,
                           "50 %/hr does not sit level with 50 % charge")
        }
    }

    /// And the scale is not shared by default — the other charts still fit their
    /// own data, which is what makes a rate legible when it is small.
    func testTheSharedScaleIsOptIn() {
        XCTAssertFalse(HistoryGraphView(frame: .zero).sharesRightAxisScale)
    }

    /// A thumbnail installs NO tracking area, rather than a handler that returns
    /// early: an unused one still makes AppKit deliver a mouse-moved event for
    /// every pixel the pointer crosses.
    func testARailSparklineTakesNoPointerEvents() {
        let spark = SparkGraphView(frame: NSRect(x: 0, y: 0, width: 74, height: 36))
        XCTAssertFalse(spark.respondsToHover)
        spark.updateTrackingAreas()
        XCTAssertTrue(spark.trackingAreas.isEmpty,
                      "the rail sparkline is still listening for the pointer")
    }

    /// The full-size graphs still are hoverable — the readout is the reason they
    /// exist at that size.
    func testAFullGraphStillAnswersThePointer() {
        let g = HistoryGraphView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        XCTAssertTrue(g.respondsToHover)
        g.updateTrackingAreas()
        XCTAssertFalse(g.trackingAreas.isEmpty)
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// The endpoint marker — the dot at the head of the line.
///
/// It shipped on the wrong value. When a graph holds more samples than pixels the
/// line is BUCKETED and each node is drawn at its bucket's mean, and the marker
/// was taken from the last drawn node — so it sat on the average of the final
/// bucket rather than on the latest reading, which is the only thing it claims to
/// be. Sparse graphs draw real samples and looked right; dense ones, which is
/// most of them, did not.
final class EndpointMarkerTests: XCTestCase {

    override func setUp() { _ = appKitForTests }

    /// Both facts about the dot, as GEOMETRY rather than pixels.
    ///
    /// Four pixel-based attempts preceded this and three of them passed against
    /// the bug: they measured the bucket's whisker, then the plot's own
    /// background, then an sRGB token that a P3 buffer does not return unchanged.
    /// The view already computes this point; asking it what it drew is both
    /// exact and honest, and it is the same reason `lastPlot` is published.
    func testTheMarkerIsAtTheLatestReadingAndAtTheEdge() {
        let g = HistoryGraphView(frame: .zero)
        g.yMax = 100
        let now = Date()
        // More samples than pixels, so the line is BUCKETED — the case where the
        // marker used to land on the final bucket's mean.
        var pts: [HistoryGraphView.Point] = (0..<1199).map {
            .init(time: now.addingTimeInterval(-1200 + Double($0)), value: 10)
        }
        pts.append(.init(time: now, value: 90))
        g.series = [.init(name: "v", color: Palette.accent, points: pts)]

        let size = NSSize(width: 400, height: 200)
        render(g, size: size)

        guard let marker = g.lastEndpointMarkers.first else {
            return XCTFail("no endpoint marker was drawn")
        }
        let plot = g.lastPlot

        // THE VALUE: at 90 of 100, near the top of the plot — not at the final
        // bucket's mean, which is a hair over 10.
        let expectedY = plot.minY + plot.height * 0.9
        XCTAssertEqual(marker.y, expectedY, accuracy: 2,
                       "the marker is on the bucket mean, not the latest reading")

        // THE EDGE: the newest sample is the right edge of the plot by
        // definition, and the marker sits on it rather than one radius back
        // inside — which is what "the dots need to move right" was.
        XCTAssertEqual(marker.x, plot.maxX, accuracy: 0.51,
                       "the marker is pulled back inside the plot edge")
    }

    /// A sparse graph draws real samples and never had buckets; it must still
    /// mark its last one, in the same place.
    func testASparseGraphMarksItsLastSampleAtTheEdge() {
        let g = HistoryGraphView(frame: .zero)
        g.yMax = 100
        let now = Date()
        g.series = [.init(name: "v", color: Palette.accent,
                          points: (0..<8).map {
                              .init(time: now.addingTimeInterval(-480 + Double($0) * 60),
                                    value: $0 == 7 ? 90 : 10)
                          })]
        render(g, size: NSSize(width: 400, height: 200))
        guard let marker = g.lastEndpointMarkers.first else {
            return XCTFail("no endpoint marker was drawn")
        }
        let plot = g.lastPlot
        XCTAssertEqual(marker.y, plot.minY + plot.height * 0.9, accuracy: 2)
        XCTAssertEqual(marker.x, plot.maxX, accuracy: 0.51)
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// One palette, one set of radii — enforced by reading the source.
///
/// Consistency is the kind of property that decays silently: every individual
/// `NSColor.secondaryLabelColor` looks right in the file it is in, and the drift
/// only shows up when two panes are open at once. Found by eye at the point where
/// the ledger's memory and storage segments were macOS system colours, one pane's
/// grey was a different grey from the next, and a bar was drawn in whatever
/// accent colour the user had picked for macOS.
///
/// So this scans the sources rather than the pixels. It is the only test here
/// that reads code, and it earns that by checking something no rendered frame
/// can: not "does this frame look right" but "will the next one still match".
final class PaletteConsistencyTests: XCTestCase {

    /// The app's own view layer. `MenuBarWidgets` is deliberately absent — a
    /// status item sits in the menu bar, whose tint follows the wallpaper and
    /// inverts independently of this app, so macOS's semantic inks are the
    /// correct ones there and Palette's would be wrong.
    private static let windowSources = [
        "HistoryGraphView.swift", "AppDetailView.swift", "AppMenu.swift",
        "LedgerBarView.swift", "ResourcesPane.swift", "SystemPanes.swift",
        "SidebarView.swift", "ProcessTable.swift", "GlanceCardView.swift",
        "InspectorView.swift", "FanControlPanel.swift", "SpeedometerView.swift",
        "SpeedTestStrip.swift",
    ]

    /// Inks that must come from `Palette`, with what to use instead.
    ///
    /// Matched WITHOUT the `NSColor` prefix, because Swift infers it: the ledger
    /// wrote `return .systemPurple`, and a first version of this test looked for
    /// `NSColor.systemPurple` and sailed straight past the exact line that
    /// prompted it.
    private static let banned = [
        ".labelColor":            "Palette.text",
        ".secondaryLabelColor":   "Palette.dim",
        ".tertiaryLabelColor":    "Palette.faint",
        ".quaternaryLabelColor":  "Palette.lineSoft",
        ".separatorColor":        "Palette.line or Palette.lineSoft",
        ".windowBackgroundColor": "Palette.background",
        ".controlBackgroundColor": "Palette.background",
        // The user's macOS accent, not this app's. It made one bar turn pink on
        // machines where that was the system setting.
        ".controlAccentColor":    "Palette.accent",
        ".systemPurple":          "Palette.violet",
        ".systemTeal":            "Palette.teal",
    ]

    private func source(_ name: String) throws -> String {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PowerKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
        let url = dir.appendingPathComponent("Sources/AnodeApp/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testWindowViewsTakeTheirInksFromThePalette() throws {
        var offences: [String] = []
        for name in Self.windowSources {
            let text = try source(name)
            for (bad, good) in Self.banned where text.contains(bad) {
                // A mention inside a comment is a record of why, not a use.
                let used = text.split(separator: "\n").contains { line in
                    line.contains(bad) && !line.trimmingCharacters(in: .whitespaces)
                        .hasPrefix("//")
                }
                if used { offences.append("\(name): \(bad) — use \(good)") }
            }
        }
        XCTAssertEqual(offences, [], "system colours leaked back into window views:\n"
                                   + offences.joined(separator: "\n"))
    }

    /// And the menu bar is left alone, which this states so a future sweep does
    /// not "fix" it into looking wrong on a light wallpaper.
    func testTheMenuBarKeepsTheSystemInks() throws {
        let text = try source("MenuBarWidgets.swift")
        XCTAssertTrue(text.contains(".labelColor"),
                      "the menu bar was moved onto Palette — it must follow the "
                    + "system menu bar tint, which Palette does not track")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//
// NO TEST FOR THE RESOURCES PANEL'S CORNER RADIUS, and this note is here instead
// of one because the absence is a decision.
//
// The panel had no background at all — `SystemPane` fills the pane, the content
// view drew nothing, so the readings sat on whatever AppKit put behind them, with
// square corners in an app where every other surface is rounded. That is fixed in
// `ResourcesContent.draw`. What is not here is proof.
//
// Six attempts, each of which passed against a deliberately squared panel:
//
//   * corner pixel vs interior, rendering the PANE — the corner sample landed in
//     the pane's inset, outside the view under test;
//   * the same, rendering the content view — the corner landed on the panel's own
//     border STROKE, which differs from the fill either way;
//   * alpha at the extreme corner — `cacheDisplay` returns an opaque bitmap, so
//     an unpainted pixel is not transparent;
//   * corner vs the middle of the left edge, which is on the stroke in both
//     variants — correctly failed the square panel and also failed the round one.
//
// Every one of those measured something real; none measured the radius. A
// rendering test that has not been run against the broken version is not
// evidence, and one that cannot be is worse than none: it reads as coverage.
// `PaletteConsistencyTests` covers what IS mechanically checkable here — that the
// inks come from one place — and the shape of a corner is currently a thing a
// person has to look at.


// ─────────────────────────────────────────────────────────────────────────────

/// Hover on a rail card, in the same two weights the table's rows use.
final class ResourceCardHoverTests: XCTestCase {

    override func setUp() { _ = appKitForTests }

    private func card(selected: Bool, hovered: Bool) -> ResourceCard {
        let c = ResourceCard(resource: .cpu, onClick: { _ in })
        c.isSelected = selected
        if hovered {
            c.frame = NSRect(x: 0, y: 0, width: 210, height: 58)
            c.updateTrackingAreas()
            c.mouseEntered(with: NSEvent())
        }
        return c
    }

    /// A hovered card is washed where an idle one is not — the rail is a list of
    /// buttons and had nothing under the pointer but a cursor change.
    func testHoverWashesTheCard() {
        inTheme(.darkAqua) {
            let size = NSSize(width: 210, height: 58)
            let box = NSRect(x: 120, y: 6, width: 60, height: 46)
            let idle = render(card(selected: false, hovered: false), size: size)
                .maxAlpha(in: box)
            let hovered = render(card(selected: false, hovered: true), size: size)
                .maxAlpha(in: box)
            XCTAssertGreaterThan(hovered, idle + 0.02,
                                 "hovering a card changes nothing on screen")
        }
    }

    /// And selection outranks it: a hovered selected card stays at full strength
    /// rather than lightening under the pointer, which would read as losing state
    /// at the moment of touching it.
    func testSelectionOutranksHover() {
        inTheme(.darkAqua) {
            let size = NSSize(width: 210, height: 58)
            let box = NSRect(x: 120, y: 6, width: 60, height: 46)
            let selected = render(card(selected: true, hovered: false), size: size)
                .maxAlpha(in: box)
            let both = render(card(selected: true, hovered: true), size: size)
                .maxAlpha(in: box)
            XCTAssertEqual(both, selected, accuracy: 0.01,
                           "a selected card changed weight when hovered")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Clicking a resource card changes what is under the graph, immediately.
///
/// It did not. Selection changed the highlight and the graph at once and left the
/// readings describing the resource you had just clicked away from until the next
/// sample landed — up to two seconds of a tab that had visibly switched and was
/// still showing the wrong thing. The data was never missing: this view drew it
/// once and kept no copy, so a click had nothing to redraw from.
final class ResourceSelectionTests: XCTestCase {

    override func setUp() { _ = appKitForTests }

    private func sample() -> SystemMetrics.Snapshot {
        SystemMetrics.Snapshot(
            cpu: CPUUsage.Sample(total: 16.4, user: 12.4, system: 4.1, idle: 83.6,
                                 interval: 2),
            memory: MemoryUsage.Sample(total: 24_000_000_000, used: 12_000_000_000,
                                       wired: 3_000_000_000, compressed: 1_000_000_000,
                                       app: 8_000_000_000, free: 12_000_000_000),
            gpu: nil, network: nil, disk: nil,
            cpuTemperature: 39, gpuTemperature: nil, fans: [])
    }

    /// One update, then a click. The rows must change with no second update.
    func testSelectingRedrawsTheReadingsWithoutWaitingForASample() {
        let content = ResourcesContent(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        content.update(sample(), power: nil, span: 900)

        let beforeLabels = content.lastLiveItems.map(\.label)
        XCTAssertFalse(beforeLabels.isEmpty, "nothing was rendered for the first tick")

        // No `update` between these two lines. That is the whole test.
        content.select(.memory)
        let afterLabels = content.lastLiveItems.map(\.label)

        XCTAssertNotEqual(afterLabels, beforeLabels,
                          "the readings did not change when the tab did")
        XCTAssertFalse(afterLabels.isEmpty,
                       "selecting emptied the readings instead of rebuilding them")
    }

    /// And the specs column too — it is built from the same sample and was left
    /// behind by the same nil.
    func testTheSpecsColumnAlsoFollowsTheClick() {
        let content = ResourcesContent(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        content.update(sample(), power: nil, span: 900)
        let before = content.lastSpecItems.map(\.label)
        content.select(.memory)
        XCTAssertNotEqual(content.lastSpecItems.map(\.label), before,
                          "the hardware column still describes the previous resource")
    }

    /// Before any sample there is nothing to redraw from, and a click must not
    /// invent one — it leaves the placeholder rather than emptying the pane.
    func testAClickBeforeTheFirstSampleIsHarmless() {
        let content = ResourcesContent(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        content.select(.gpu)
        XCTAssertTrue(content.lastLiveItems.isEmpty)
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// One definition of "a hole", whichever way the line is drawn.
///
/// The two paths disagreed. The sparse one asked whether the TIME between
/// samples exceeded four times their median; the bucketed one broke the line at
/// any empty bucket, on the argument that its own branch condition guaranteed the
/// data was dense. That is true of the AVERAGE density, and the average is not
/// what decides it — this app samples every ~2 s with the window open and every
/// ~63 s with it closed, so an hour holding both is dense enough to take the
/// bucketed path while its older half leaves ~17 buckets empty between
/// consecutive samples.
///
/// Reported as a "weird bug in the bottom left corner": an hour that drew as a
/// line where it was watched and as isolated dots where it was not.
final class GraphGapRuleTests: XCTestCase {

    override func setUp() { _ = appKitForTests }

    private func pts(_ spacings: [(count: Int, seconds: Double)]) -> [HistoryGraphView.Point] {
        var out: [HistoryGraphView.Point] = []
        var t = Date(timeIntervalSince1970: 1_000_000)
        for s in spacings {
            for _ in 0..<s.count {
                out.append(.init(time: t, value: 10))
                t = t.addingTimeInterval(s.seconds)
            }
        }
        return out
    }

    /// A steady 63 s cadence is sampling, not absence — the floor is 90 s.
    func testTheSlowCadenceIsNotAHole() {
        XCTAssertFalse(HistoryGraphView.breaks(in: pts([(60, 63)])).contains(true))
    }

    /// A mixed hour judges each stretch by its OWN cadence.
    ///
    /// The rule used to take one median across every point on screen. The dense
    /// stretch supplies almost all of them, so the median sat at 2 s, the limit
    /// at its 90 s floor, and the slow stretch survived only because 63 < 90 —
    /// by a margin of 27 seconds, with nothing holding it there.
    func testAMixedCadenceJudgesEachStretchByItsOwn() {
        let mixed = pts([(40, 63), (1200, 2)])
        XCTAssertFalse(HistoryGraphView.breaks(in: mixed).contains(true),
                       "an ordinary spacing was read as an absence")
    }

    /// THE REPORTED BUG. A 120 s hole inside the slow stretch is not sleep.
    ///
    /// It is a beat frequency: samples arrive every ~64 s and compaction folds
    /// them into 60 s buckets, so every fifteenth sample skips a bucket and
    /// leaves exactly one empty minute every sixteen. The store held 25 of these
    /// in one night, each between two rows whose own `dur` shows the machine
    /// measuring the whole span — and the graph drew every one of them as the
    /// machine having slept, with the user watching it not sleep.
    ///
    /// Under the old global median this fails: 2 s median, 90 s limit, 120 > 90.
    func testTheSixteenMinuteBucketHoleIsNotSleep() {
        var mixed = pts([(40, 64), (1200, 2)])
        // One skipped bucket, a third of the way into the slow stretch.
        let hole = 120.0 - 64.0
        for i in 14..<mixed.count {
            mixed[i] = .init(time: mixed[i].time.addingTimeInterval(hole),
                             value: mixed[i].value)
        }
        let breaks = HistoryGraphView.breaks(in: mixed)
        XCTAssertEqual(mixed[14].time.timeIntervalSince(mixed[13].time), 120, accuracy: 0.001)
        XCTAssertFalse(breaks[13],
                       "a skipped 60 s bucket at a 64 s cadence is arithmetic, not sleep")
        XCTAssertFalse(breaks.contains(true), "nothing else in this hour is a hole either")
    }

    /// The cadence ladder does not move under ordinary jitter.
    ///
    /// This is what stops the gap verdict flickering: the threshold is derived
    /// from the sampling cadence, so if that number wanders every frame the
    /// threshold wanders with it. Scaling by the RAW median made the flicker
    /// worse, which is what the second report said. Snapped to a ladder, an
    /// ordinary shuffle in the window changes nothing at all.
    func testTheCadenceLadderIgnoresOrdinaryJitter() {
        // A bucketed hour lands around 5.1 s and wobbles as bucket edges shift.
        for spacing in [5.0, 5.14, 6.0, 8.9, 9.99] {
            XCTAssertEqual(HistoryGraphView.cadenceStep(spacing), 5, "\(spacing)")
        }
        // And it still moves when the cadence genuinely changes regime — the
        // 2 s visible tick against the ~64 s hidden one.
        XCTAssertEqual(HistoryGraphView.cadenceStep(2.1), 2)
        XCTAssertEqual(HistoryGraphView.cadenceStep(64), 60)
        // Never returns zero: a threshold of zero would call every sample a gap.
        XCTAssertEqual(HistoryGraphView.cadenceStep(0.001), 1)
    }

    /// A gap near the threshold does not flicker as the graph re-buckets.
    ///
    /// THE REPORTED CASE, with its real numbers: an 85.4 s gap against a 90 s
    /// limit, in a series bucketed at ~5.1 s. The graph re-buckets against a
    /// moving `now`, so the measured delta wobbles by up to a bucket width — and
    /// 85.4 plus or minus 5.1 straddles 90, which is why the dotted line went
    /// solid every few redraws. The solid version was the correct one.
    ///
    /// Simulated by nudging the gap across the range that jitter covers: every
    /// one of those must give the SAME verdict, or the line changes under a
    /// stationary pointer.
    func testAGapNearTheThresholdDoesNotFlickerAsBucketsShift() {
        for nudge in stride(from: -6.0, through: 6.0, by: 1.0) {
            var series = pts([(40, 5.1)])
            for i in 20..<series.count {
                series[i] = .init(time: series[i].time.addingTimeInterval(85.4 - 5.1 + nudge),
                                  value: series[i].value)
            }
            XCTAssertFalse(HistoryGraphView.breaks(in: series).contains(true),
                           "an 85 s gap at \(nudge) s of bucket jitter was called an absence")
        }
    }

    /// A real absence still breaks the line, in either stretch. Ten minutes is
    /// far outside both cadences, and the night this was diagnosed from held a
    /// genuine 9540 s one.
    func testARealAbsenceIsStillAHole() {
        for cadence in [2.0, 64.0] {
            var series = pts([(40, cadence)])
            for i in 20..<series.count {
                series[i] = .init(time: series[i].time.addingTimeInterval(600),
                                  value: series[i].value)
            }
            let breaks = HistoryGraphView.breaks(in: series)
            XCTAssertTrue(breaks[19],
                          "a ten-minute silence at \(cadence) s sampling must read as a hole")
            XCTAssertEqual(breaks.filter { $0 }.count, 1,
                           "only the silence is a hole")
        }
    }
}


// ─────────────────────────────────────────────────────────────────────────────

/// The right-hand series' gradient.
///
/// Written because two commits claimed to add it and neither did — the edit
/// no-matched, both builds were clean, both suites passed, and nothing changed
/// on screen. A clean compile says a change is VALID, never that it happened.
/// This asks the pixels.
final class RightSeriesFillTests: XCTestCase {

    override func setUp() { _ = appKitForTests }

    /// A flat left series low on the plot and a flat right series high on it.
    /// The band BETWEEN them belongs to the right series' wash and to nothing
    /// else, so it is the one place that answers "did the fill draw".
    private func graph(rightFilled: Bool, shared: Bool = false) -> Frame {
        let g = HistoryGraphView(frame: .zero)
        g.translatesAutoresizingMaskIntoConstraints = true
        g.sharesRightAxisScale = shared
        g.yMax = shared ? nil : 100
        g.series = [.init(name: "drain", color: Palette.accent,
                          points: ramp([10, 10, 10, 10], over: 600), filled: true)]
        // `onPower` true: the pack was FILLING, so the line is green and its wash
        // must be too. A blue wash under a green line is what made this invisible.
        let charge = ramp([80, 80, 80, 80], over: 600).map {
            HistoryGraphView.Point(time: $0.time, value: $0.value, onPower: true)
        }
        g.rightSeries = .init(name: "charge", color: Palette.chargeLine,
                              points: charge, filled: rightFilled)
        return render(g, size: NSSize(width: 420, height: 220))
    }

    /// The leftmost time label survives a buffer that is a few seconds short.
    ///
    /// THE REPORTED CASE. A live chart's span is its buffer's extent, and that
    /// wobbles by a second or two every tick as the oldest points age past the
    /// cutoff. The tick loop stops as soon as a label falls left of the plot, so
    /// at a span of 3592 s the "-1h" mark lands 2.4 pt outside and vanishes; at
    /// 3601 it is back. Two seconds in an hour, and plainly visible.
    ///
    /// Rendered rather than reasoned about: the claim is that a label is on
    /// screen, so the test looks for ink in the corner where it belongs.
    func testTheLeftmostTimeLabelDoesNotFlickerWithTheBuffer() {
        inTheme(.darkAqua) {
            let size = NSSize(width: 460, height: 200)
            func leftLabelInk(spanSeconds: Double) -> CGFloat {
                let end = Date()
                let pts = stride(from: 0.0, through: spanSeconds, by: 20).map {
                    HistoryGraphView.Point(time: end.addingTimeInterval(-spanSeconds + $0),
                                           value: 40)
                }
                let g = HistoryGraphView(frame: .zero)
                g.translatesAutoresizingMaskIntoConstraints = true
                g.yMax = 100
                g.series = [.init(name: "x", color: Palette.accent, points: pts)]
                // Bottom-left, where the earliest tick label is drawn.
                return render(g, size: size)
                    .meanLuminance(in: NSRect(x: 0, y: size.height - 14, width: 46, height: 13))
            }
            // A hair under an hour, a hair over, and exactly on it: all three have
            // to draw the same leftmost label.
            let short = leftLabelInk(spanSeconds: 3592)
            let exact = leftLabelInk(spanSeconds: 3600)
            let over = leftLabelInk(spanSeconds: 3608)
            // IDENTICAL, not merely similar. Losing one label out of a 46x13 pt
            // corner moves the mean by about 3 % — measured, 0.0556 against
            // 0.0572 — so a loose threshold passes with the label missing, which
            // is exactly what the first version of this test did. Three axes over
            // the same hour must draw the same thing.
            XCTAssertGreaterThan(exact, 0.01, "no label was drawn at all")
            XCTAssertEqual(short, exact, accuracy: 0.0005,
                           "a buffer eight seconds short drew a different axis")
            XCTAssertEqual(over, exact, accuracy: 0.0005,
                           "a buffer eight seconds long drew a different axis")
        }
    }

    /// And a genuinely short buffer is NOT stretched to a span it does not have.
    /// Six minutes of history must draw as six minutes, not as a quarter hour
    /// with ten empty minutes on the left.
    func testAShortBufferIsNotStretchedToTheNextRung() {
        let g = HistoryGraphView(frame: NSRect(x: 0, y: 0, width: 460, height: 200))
        let end = Date()
        g.series = [.init(name: "x", color: Palette.accent,
                          points: stride(from: 0.0, through: 360, by: 20).map {
                              .init(time: end.addingTimeInterval(-360 + $0), value: 40)
                          })]
        g.translatesAutoresizingMaskIntoConstraints = true
        _ = render(g, size: NSSize(width: 460, height: 200))
        XCTAssertEqual(g.lastDrawnSpan ?? 0, 360, accuracy: 30,
                       "six minutes of history was stretched to a rung it has no data for")
    }

    /// TWO SERIES, ONE ANSWER ABOUT WHEN THE MACHINE WAS AWAKE.
    ///
    /// THE REPORTED CASE, with the user's own diagnosis: the dashed line
    /// occasionally turned green, and it never happened to the battery level —
    /// only to the drain.
    ///
    /// The reason is that the drain line has the patchier record. It is dropped
    /// whenever a reading is missing, where the charge level is there on every
    /// tick that happens at all. Deciding gaps per series, the drain found breaks
    /// the charge did not, split into short runs between them, and those runs
    /// drew in the series colour — green segments in the middle of a span that
    /// was supposed to read as unobserved.
    ///
    /// A gap is a fact about the MACHINE. Both lines come from one sampler on one
    /// tick, so they are absent together, and the decision is taken once from
    /// every sample either of them has.
    func testBothSeriesBreakInTheSamePlaces() {
        let end = Date()
        // The charge line: sampled steadily right across the window.
        let charge = (0..<60).map {
            HistoryGraphView.Point(time: end.addingTimeInterval(-3600 + Double($0) * 60),
                                   value: 80, onPower: true)
        }
        // The drain line: the same window, but missing a stretch in the middle —
        // readings it could not produce, not time the machine was away.
        let drain = charge.enumerated()
            .filter { $0.offset < 20 || $0.offset > 32 }
            .map { HistoryGraphView.Point(time: $0.element.time, value: 30) }

        let g = HistoryGraphView(frame: NSRect(x: 0, y: 0, width: 420, height: 220))
        g.yMax = 100
        g.series = [.init(name: "drain", color: Palette.accent, points: drain, filled: true)]
        g.rightSeries = .init(name: "charge", color: Palette.chargeLine,
                              points: charge, filled: true)

        // The union says the machine was observed throughout — the charge line
        // covers the drain's missing stretch — so NOTHING breaks.
        XCTAssertTrue(g.observedGapsForTesting.isEmpty,
                      "a stretch one series covered was still called an absence")

        // And when the machine really is away, both lose the same span.
        let asleep = charge.filter { $0.time < end.addingTimeInterval(-1800)
                                  || $0.time > end.addingTimeInterval(-600) }
        g.series = [.init(name: "drain", color: Palette.accent,
                          points: asleep.map { .init(time: $0.time, value: 30) }, filled: true)]
        g.rightSeries = .init(name: "charge", color: Palette.chargeLine,
                              points: asleep, filled: true)
        XCTAssertEqual(g.observedGapsForTesting.count, 1,
                       "a real twenty-minute absence was not found")
    }

    /// The BATTERY's exact configuration: a shared 0-100 scale and an autoscaled
    /// left axis. The plain case above passes, so if this one does not, the
    /// difference is in how a shared-scale graph reaches its right series.
    func testTheChargeLineFillsOnTheBatteryConfiguration() {
        inTheme(.darkAqua) {
            let band = NSRect(x: 180, y: 90, width: 60, height: 40)
            let off = graph(rightFilled: false, shared: true).maxLuminance(in: band)
            let on = graph(rightFilled: true, shared: true).maxLuminance(in: band)
            // 0.08, not "greater than zero". The first version of this fill DID
            // draw and measured 0.054 — a deep blue wash under a green charging
            // line, which a test can see and an eye reasonably cannot. "Something
            // was painted" is not the property worth asserting; "you can tell"
            // is. In the line's own ink it measures ~0.104.
            XCTAssertGreaterThan(on, off + 0.08,
                                 "the charge wash is too faint to see — check it is "
                                 + "using the segment's own ink, not the series colour")
        }
    }

    func testTheRightSeriesFillsUnderItsOwnLine() {
        inTheme(.darkAqua) {
            // Mid-plot horizontally, and vertically between the two lines: above
            // the drain line at 10 and below the charge line at 80.
            let band = NSRect(x: 180, y: 90, width: 60, height: 40)
            let off = graph(rightFilled: false).maxLuminance(in: band)
            let on = graph(rightFilled: true).maxLuminance(in: band)
            XCTAssertGreaterThan(on, off + 0.03,
                                 "the right series drew no wash under its line")
        }
    }
}

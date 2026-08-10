import AppKit
import XCTest
@testable import BetterStatsApp
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

        let ground = NSColor.controlBackgroundColor
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
        let cell = BetterStatsHeaderCell(textCell: title)
        cell.draw(withFrame: NSRect(origin: .zero, size: size), in: host)
        NSGraphicsContext.restoreGraphicsState()
        return Frame(rep: rep, viewSize: size)
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

    /// Selection and hover were one shape in one colour at two strengths, which
    /// is a difference you can only judge with both on screen — and they never
    /// are, because the pointer is on the hovered row. The selected row is MARKED
    /// down its leading edge: opaque ink where the wash is 16%.
    func testASelectedRowIsMarkedAndNotJustWashed() {
        inTheme(.darkAqua) {
            let row = BetterStatsRowView(frame: .zero)
            row.isSelected = true
            let size = NSSize(width: 320, height: 20)
            let frame = render(row, size: size)

            let edge = frame.maxAlpha(in: NSRect(x: 6, y: 2, width: 3, height: 16))
            let wash = frame.maxAlpha(in: NSRect(x: 120, y: 2, width: 80, height: 16))
            XCTAssertGreaterThan(wash, 0.05, "the selection wash disappeared")
            XCTAssertGreaterThan(edge, wash + 0.3,
                                 "the selected row has no edge mark, only a wash")
        }
    }

    /// An unselected row is not marked. The edge has to mean selection, or it
    /// means nothing.
    func testAnUnselectedRowHasNoEdgeMark() {
        inTheme(.darkAqua) {
            let row = BetterStatsRowView(frame: .zero)
            let size = NSSize(width: 320, height: 20)
            let frame = render(row, size: size)
            XCTAssertLessThan(frame.maxAlpha(in: NSRect(x: 6, y: 2, width: 3, height: 16)),
                              0.6, "an unselected row drew a selection mark")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Resources cards

final class ResourcesCardRenderTests: XCTestCase {

    /// `Palette` force-unwraps `NSApp`, and a Swift global is lazy: something has
    /// to touch the application object before the first colour is asked for.
    override func setUp() { _ = appKitForTests }


    /// The rail is one card per resource and the colour is what tells them apart
    /// at a glance — in the sparkline, in the selected card's edge, and in the
    /// detail column's line. Two resources sharing an ink would make the rail and
    /// the detail agree about the wrong thing, silently.
    func testEveryResourceHasItsOwnColour() {
        let inks = Resource.allCases.compactMap {
            ($0, $0.color.usingColorSpace(.sRGB))
        }
        XCTAssertEqual(inks.count, Resource.allCases.count, "a resource colour did not resolve")
        for (a, i) in inks.enumerated() {
            for j in inks[(a + 1)...] {
                guard let x = i.1, let y = j.1 else { continue }
                let d = max(abs(x.redComponent - y.redComponent),
                            max(abs(x.greenComponent - y.greenComponent),
                                abs(x.blueComponent - y.blueComponent)))
                XCTAssertGreaterThan(d, 0.05, "\(i.0) and \(j.0) are the same colour")
            }
        }
    }

    /// Selection on a card is the same two-part mark the process table's rows
    /// wear: a wash across the card, plus an opaque edge down its leading side in
    /// the resource's own colour. The wash alone is a difference you can only
    /// judge with an unselected card beside it.
    func testASelectedCardIsMarkedAndNotJustWashed() {
        inTheme(.darkAqua) {
            let card = ResourceCard(resource: .cpu, onClick: { _ in })
            card.isSelected = true
            let size = NSSize(width: 210, height: 58)
            let frame = render(card, size: size)

            let edge = frame.maxAlpha(in: NSRect(x: 0, y: 6, width: 2, height: 46))
            let wash = frame.maxAlpha(in: NSRect(x: 120, y: 6, width: 60, height: 46))
            XCTAssertGreaterThan(wash, 0.05, "the selection wash disappeared")
            XCTAssertGreaterThan(edge, wash + 0.3,
                                 "the selected card has no edge mark, only a wash")
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
        XCTAssertEqual(BetterStatsHeaderCell.font, Palette.Font.label(),
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

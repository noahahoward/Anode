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
                .appendingPathComponent("Sources/BetterStatsApp/ResourcesPane.swift"),
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
        let url = dir.appendingPathComponent("Sources/BetterStatsApp/\(name)")
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

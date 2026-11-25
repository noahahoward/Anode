import AppKit
import XCTest
@testable import AnodeApp
@testable import PowerKit

/// The drawn layouts' board, SoC, power supply, antenna strip, speakers, trackpad and notes: that each paints in its own place on
/// every family, that an inferred part is dashed, that a missing power reading writes a dash and never a number, and the words the
/// 16-inch and generic layouts carry.
final class HardwareChassisDrawingTests: XCTestCase {

    private let allFamilies: [MacFamily] = [.macBookPro14ProMax, .macBookPro16ProMax, .macBookPro14Base, .macBookNeo, .macMiniM4, .generic]
    private let drawnFamilies: [MacFamily] = [.macBookPro14Base, .macBookNeo, .macMiniM4, .generic]
    private let chassisKinds: [HardwareComponentKind] = [.board, .soc, .psu, .antenna, .speaker, .trackpad, .note]

    // MARK: - Readings and canvases

    private func fullReadings() -> HardwareReadings {
        HardwareFixtures.make(
            system: HardwareFixtures.system(fans: [HardwareFixtures.fan(0, rpm: 2500), HardwareFixtures.fan(1, rpm: 2600)],
                                            memory: HardwareFixtures.memory()),
            power: HardwareFixtures.power(state: HardwareFixtures.battery()),
            swapBytes: 8_000_000_000,
            brightness: 0.6,
            nvme: HardwareFixtures.nvme(),
            helperInstalled: true)
    }

    private func canvas(_ family: MacFamily, readings: HardwareReadings?) -> HardwareCanvasView {
        let v = HardwareCanvasView(layout: HardwareLayout.layout(for: family))
        v.frame = NSRect(x: 0, y: 0, width: 1100, height: 1205)
        v.readings = readings
        return v
    }

    private func drawOne(_ v: HardwareCanvasView, _ ctx: CGContext, _ c: HardwareComponent) {
        switch c.kind {
        case .board: v.drawBoard(in: ctx, scale: 1, component: c)
        case .soc: v.drawSoC(in: ctx, scale: 1, component: c)
        case .psu: v.drawPSU(in: ctx, scale: 1, component: c)
        case .antenna: v.drawAntenna(in: ctx, scale: 1, component: c)
        case .speaker: v.drawSpeaker(in: ctx, scale: 1, component: c)
        case .trackpad: v.drawTrackpad(in: ctx, scale: 1, component: c)
        case .note: v.drawNote(in: ctx, scale: 1, component: c)
        default: break
        }
    }

    // MARK: - Bitmap helpers

    /// A 1100 x 1205 bitmap, mid grey, with the drawing run in a context whose y runs down (as the canvas's does) so a layout unit
    /// is a pixel and layout row y is pixel row y.
    private func paint(_ draw: (CGContext) -> Void) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1100, pixelsHigh: 1205,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let base = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        let cg = base.cgContext
        cg.setFillColor(CGColor(gray: 0.5, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: 1100, height: 1205))
        cg.translateBy(x: 0, y: 1205)
        cg.scaleBy(x: 1, y: -1)
        let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = flipped
        draw(cg)
        NSGraphicsContext.current = saved
        return rep
    }

    private func isChanged(_ rep: NSBitmapImageRep, x: Int, y: Int) -> Bool {
        guard let data = rep.bitmapData, x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return false }
        let reference = (data[0], data[1], data[2])
        let p = data + y * rep.bytesPerRow + x * 4
        return abs(Int(p[0]) - Int(reference.0)) > 3 || abs(Int(p[1]) - Int(reference.1)) > 3 || abs(Int(p[2]) - Int(reference.2)) > 3
    }

    /// How many pixels in `rect` (grown by `margin`) differ from the grey the bitmap started as (pixel 0, 0 is never drawn on).
    private func changedPixels(_ rep: NSBitmapImageRep, in rect: HWRect, margin: Double = 8) -> Int {
        let x0 = max(0, Int(rect.x - margin)), x1 = min(rep.pixelsWide, Int(rect.x + rect.w + margin))
        let y0 = max(0, Int(rect.y - margin)), y1 = min(rep.pixelsHigh, Int(rect.y + rect.h + margin))
        guard x0 < x1, y0 < y1 else { return 0 }
        var count = 0
        for y in y0..<y1 {
            for x in x0..<x1 where isChanged(rep, x: x, y: y) { count += 1 }
        }
        return count
    }

    /// How many pixels in `rect` differ from the colour at `reference`: for ink drawn on a part's own opaque fill, where the grey
    /// ground is not the background.
    private func inkPixels(_ rep: NSBitmapImageRep, in rect: HWRect, reference: (x: Int, y: Int)) -> Int {
        guard let data = rep.bitmapData else { return 0 }
        let ref = data + reference.y * rep.bytesPerRow + reference.x * 4
        let (r0, g0, b0) = (Int(ref[0]), Int(ref[1]), Int(ref[2]))
        var count = 0
        for y in Int(rect.y)..<Int(rect.y + rect.h) {
            for x in Int(rect.x)..<Int(rect.x + rect.w) {
                let p = data + y * rep.bytesPerRow + x * 4
                if abs(Int(p[0]) - r0) > 6 || abs(Int(p[1]) - g0) > 6 || abs(Int(p[2]) - b0) > 6 { count += 1 }
            }
        }
        return count
    }

    private func changedInRow(_ rep: NSBitmapImageRep, y: Int, from x0: Int, to x1: Int) -> Int {
        var count = 0
        for x in x0..<x1 where isChanged(rep, x: x, y: y) { count += 1 }
        return count
    }

    private func pixel(_ rep: NSBitmapImageRep, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        guard let data = rep.bitmapData else { return (0, 0, 0) }
        let p = data + y * rep.bytesPerRow + x * 4
        return (Int(p[0]), Int(p[1]), Int(p[2]))
    }

    /// Where to look for a component's own marks: its rectangle, or for a note (a point) the band of text that starts there.
    private func region(of c: HardwareComponent) -> HWRect? {
        guard let r = c.rect else { return nil }
        guard c.kind == .note else { return r }
        let centred = c.flags.contains("centered")
        return HWRect(x: centred ? r.x - 150 : r.x, y: r.y - 14, w: 300, h: 20)
    }

    // MARK: - Each part paints in its own place

    func testEveryChassisPartPaintsAloneInItsOwnPlaceOnEveryFamily() throws {
        var seen = Set<String>()
        for family in allFamilies {
            let v = canvas(family, readings: fullReadings())
            for c in v.hardwareLayout.components where chassisKinds.contains(c.kind) {
                let area = try XCTUnwrap(region(of: c), "\(family) \(c.id) has no rectangle")
                let rep = try paint { ctx in self.drawOne(v, ctx, c) }
                XCTAssertGreaterThan(changedPixels(rep, in: area), 0, "\(family) \(c.id) painted nothing")
                seen.insert("\(c.kind)")
            }
        }
        // Every kind this task draws is on some layout, so the loop above really covered each one.
        for kind in chassisKinds { XCTAssertTrue(seen.contains("\(kind)"), "no layout has a \(kind)") }
    }

    func testTheSamePartsPaintWithNoReadingsAtAll() throws {
        for readings in [HardwareReadings(), nil] as [HardwareReadings?] {
            for family in allFamilies {
                let v = canvas(family, readings: readings)
                for c in v.hardwareLayout.components where chassisKinds.contains(c.kind) {
                    let area = try XCTUnwrap(region(of: c))
                    let rep = try paint { ctx in self.drawOne(v, ctx, c) }
                    XCTAssertGreaterThan(changedPixels(rep, in: area), 0, "\(family) \(c.id) with no reading")
                }
            }
        }
    }

    func testTheWholeDrawnLayoutPaintsThroughTheCanvasDispatchWithEveryReadingShape() throws {
        let shapes: [HardwareReadings?] = [nil, HardwareReadings(), fullReadings()]
        for family in allFamilies {
            for readings in shapes {
                let v = canvas(family, readings: readings)
                let rep = try paint { ctx in
                    v.drawChassis(in: ctx)
                    v.drawRings(in: ctx)
                    v.drawComponents(in: ctx, scale: 1)
                }
                // Something is drawn inside the layout's own box.
                let size = v.hardwareLayout.size
                XCTAssertGreaterThan(changedPixels(rep, in: size, margin: 0), 0, "\(family)")
            }
        }
    }

    func testTheBoardIsAPlateWithAGridAndTheGenericBoardIsADashedFrame() throws {
        let base = canvas(.macBookPro14Base, readings: nil)
        let board = try XCTUnwrap(base.hardwareLayout.components.first { $0.kind == .board })
        let rep = try paint { ctx in base.drawBoard(in: ctx, scale: 1, component: board) }
        // The plate is 300, 498 to 800, 872 and its grid lines run at x = 7 + 14k and y = 7 + 14k (x = 399, 413, ... are lines; the
        // row y = 504 is between two horizontal lines). Between lines the colour is the plate's dark fill, not the grey ground.
        let between = [406, 420, 434, 448, 462].map { pixel(rep, x: $0, y: 504) }
        let onLines = [399, 413, 427, 441, 455].map { pixel(rep, x: $0, y: 504) }
        for p in between { XCTAssertLessThan(p.r, 40) }
        // On a grid line the plate is a touch lighter: compare the means, not one pixel.
        let betweenBlue = Double(between.map { $0.b }.reduce(0, +)) / Double(between.count)
        let onLineBlue = Double(onLines.map { $0.b }.reduce(0, +)) / Double(onLines.count)
        XCTAssertGreaterThanOrEqual(onLineBlue - betweenBlue, 1.5)

        // The generic frame is a dashed outline: some pixels of its top edge (half of it falls on row 39) are drawn, some are not.
        // Its faint fill is not asserted.
        let generic = canvas(.generic, readings: nil)
        let frame = try XCTUnwrap(generic.hardwareLayout.components.first { $0.kind == .board })
        let frameRep = try paint { ctx in generic.drawBoard(in: ctx, scale: 1, component: frame) }
        let edge = changedInRow(frameRep, y: 39, from: 120, to: 980)
        XCTAssertGreaterThan(edge, 0)
        XCTAssertLessThan(edge, 860, "a dashed frame has gaps")
    }

    func testAnInferredOutlineIsDashedAndAVerifiedOneIsSolid() throws {
        // The generic SoC is inferred, the 14-inch base chip's is verified. Row y - 1 holds half of the top outline.
        let generic = canvas(.generic, readings: nil)
        let guessed = try XCTUnwrap(generic.hardwareLayout.components.first { $0.kind == .soc })
        XCTAssertEqual(guessed.confidence, .inferred)
        let guessedRect = try XCTUnwrap(guessed.rect)
        let dashedRep = try paint { ctx in generic.drawSoC(in: ctx, scale: 1, component: guessed) }
        let x0 = Int(guessedRect.x) + 30, x1 = Int(guessedRect.x + guessedRect.w) - 30
        let dashedRow = changedInRow(dashedRep, y: Int(guessedRect.y) - 1, from: x0, to: x1)

        let base = canvas(.macBookPro14Base, readings: nil)
        let known = try XCTUnwrap(base.hardwareLayout.components.first { $0.kind == .soc })
        XCTAssertEqual(known.confidence, .verified)
        let knownRect = try XCTUnwrap(known.rect)
        let solidRep = try paint { ctx in base.drawSoC(in: ctx, scale: 1, component: known) }
        let solidRow = changedInRow(solidRep, y: Int(knownRect.y) - 1, from: Int(knownRect.x) + 30, to: Int(knownRect.x + knownRect.w) - 30)

        let length = x1 - x0
        XCTAssertGreaterThan(Double(solidRow), 0.95 * Double(length), "a solid outline has no gaps")
        XCTAssertGreaterThan(dashedRow, 0)
        XCTAssertLessThan(Double(dashedRow), 0.8 * Double(length), "a dashed outline has gaps")
    }

    func testTheSpeakerRibsAreLighterThanTheGrille() throws {
        let v = canvas(.macBookPro14Base, readings: nil)
        let speaker = try XCTUnwrap(v.hardwareLayout.components.first { $0.id == "spkL" })
        let r = try XCTUnwrap(speaker.rect)
        let rep = try paint { ctx in v.drawSpeaker(in: ctx, scale: 1, component: speaker) }
        // The first rib is the 3 units from y + 14; the row above it is the grille's own colour.
        let rib = pixel(rep, x: Int(r.x) + 20, y: Int(r.y) + 15)
        let grille = pixel(rep, x: Int(r.x) + 20, y: Int(r.y) + 8)
        XCTAssertGreaterThan(rib.b, grille.b)
    }

    func testTheAntennaLabelPlateSitsOnTheDashedBand() throws {
        let v = canvas(.macMiniM4, readings: nil)
        let antenna = try XCTUnwrap(v.hardwareLayout.components.first { $0.kind == .antenna })
        let r = try XCTUnwrap(antenna.rect)
        let rep = try paint { ctx in v.drawAntenna(in: ctx, scale: 1, component: antenna) }
        // Just under the plate's top edge and clear of the text the plate is nearly black; out on the band only the faint tint shows.
        let plate = pixel(rep, x: Int(r.x + r.w / 2), y: Int(r.y) + 1)
        XCTAssertLessThan(plate.r, 60)
        // Out on the band (clear of the plate) the outline is dashed: half of the top edge falls on the row above the rectangle,
        // so some of its pixels differ from the ground and some do not.
        let from = Int(r.x) + 20, to = from + 100
        let edge = changedInRow(rep, y: Int(r.y) - 1, from: from, to: to)
        XCTAssertGreaterThan(edge, 0)
        XCTAssertLessThan(edge, to - from, "a dashed band has gaps")
        // Its geometry is inferred and the layout says so in its own words.
        XCTAssertEqual(antenna.confidence, .inferred)
        XCTAssertTrue(antenna.text.joined().lowercased().contains("approx"))
    }

    // MARK: - The power supply

    private func supplyReadoutArea(_ v: HardwareCanvasView) throws -> HWRect {
        let psu = try XCTUnwrap(v.hardwareLayout.components.first { $0.kind == .psu })
        let r = try XCTUnwrap(psu.rect)
        // Under the label, left of the vents: where the number is written.
        return HWRect(x: r.x + 22, y: r.y + 40, w: 230, h: 42)
    }

    func testAMissingSystemDrawWritesADashAndNotANumber() throws {
        let area = try supplyReadoutArea(canvas(.macMiniM4, readings: nil))
        let withValue = canvas(.macMiniM4, readings: HardwareReadings(systemW: .real(41.5)))
        let without = canvas(.macMiniM4, readings: HardwareReadings())
        let psuValue = try XCTUnwrap(withValue.hardwareLayout.components.first { $0.kind == .psu })
        let psuNone = try XCTUnwrap(without.hardwareLayout.components.first { $0.kind == .psu })
        let a = try paint { ctx in withValue.drawPSU(in: ctx, scale: 1, component: psuValue) }
        let b = try paint { ctx in without.drawPSU(in: ctx, scale: 1, component: psuNone) }
        // The area is inside the housing's opaque fill, so ink is whatever differs from the housing colour, sampled just inside its
        // left edge and clear of the text.
        let psuRect = try XCTUnwrap(psuValue.rect)
        let housing = (x: Int(psuRect.x) + 10, y: Int(psuRect.y) + 50)
        let numberInk = inkPixels(a, in: area, reference: housing)
        let dashInk = inkPixels(b, in: area, reference: housing)
        XCTAssertGreaterThan(dashInk, 0, "the dash and the words still mark the supply")
        XCTAssertGreaterThan(numberInk, dashInk, "a number takes more ink than a dash")
    }

    func testThePowerSupplyNumberText() {
        XCTAssertEqual(HardwareCanvasView.psuValueText(.real(41.46)), "41.5")
        XCTAssertEqual(HardwareCanvasView.psuValueText(.estimate(41.46)), "≈ 41.5")
        XCTAssertEqual(HardwareCanvasView.psuValueText(.real(1234.5)), "1,234.5")
        XCTAssertEqual(HardwareCanvasView.psuValueText(.real(0)), "0.0", "a real zero is a reading")
        XCTAssertEqual(HardwareCanvasView.psuValueText(nil), "—")
        XCTAssertEqual(HardwareCanvasView.psuValueText(.real(nil)), "—")
        XCTAssertEqual(HardwareCanvasView.psuValueText(.estimate(nil)), "—")
        XCTAssertEqual(HardwareCanvasView.psuValueText(.real(Double.nan)), "—")
        XCTAssertEqual(HardwareCanvasView.psuValueText(.real(-3)), "—")
    }

    func testOnlyTheMiniHasAPowerSupply() {
        for family in allFamilies {
            let has = HardwareLayout.layout(for: family).components.contains { $0.kind == .psu }
            XCTAssertEqual(has, family == .macMiniM4, "\(family)")
        }
    }

    // MARK: - The chip's name on the die

    func testTheDieLabelIsTheChipInUpperCase() {
        XCTAssertEqual(HardwareCanvasView.socDieLabel(chip: "Apple M4 Pro"), "APPLE M4 PRO")
        XCTAssertEqual(HardwareCanvasView.socDieLabel(chip: "  Apple A18 Pro \n"), "APPLE A18 PRO")
        XCTAssertEqual(HardwareCanvasView.socDieLabel(chip: ""), "")
        XCTAssertEqual(HardwareCanvasView.socDieLabel(chip: "   "), "")
        let long = HardwareCanvasView.socDieLabel(chip: String(repeating: "a", count: 40))
        XCTAssertEqual(long.count, 24)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    // MARK: - Words on the layouts

    func testTheSixteenInchLayoutSaysItReusesTheFourteenInchData() throws {
        let fourteen = HardwareLayout.layout(for: .macBookPro14ProMax)
        let sixteen = HardwareLayout.layout(for: .macBookPro16ProMax)
        XCTAssertFalse(fourteen.components.contains { $0.kind == .note })
        let note = try XCTUnwrap(sixteen.components.first { $0.kind == .note })
        let words = note.text.joined(separator: " ")
        XCTAssertTrue(words.contains("16″"), words)
        XCTAssertTrue(words.contains("14″"), words)
        XCTAssertTrue(words.lowercased().contains("reuses"), words)
        // The note is the only difference: same photo, same size, same parts.
        XCTAssertEqual(sixteen.photoResource, fourteen.photoResource)
        XCTAssertEqual(sixteen.photoFrame, fourteen.photoFrame)
        XCTAssertEqual(sixteen.size, fourteen.size)
        XCTAssertEqual(sixteen.components.filter { $0.kind != .note }, fourteen.components)
        // It sits on the hinge strip (y 440 to 462), inside the layout.
        let at = try XCTUnwrap(note.rect)
        XCTAssertGreaterThan(at.y, 440)
        XCTAssertLessThan(at.y, 462)
    }

    func testTheGenericSchematicIsPlainlyLabelledAndItsSentenceIsFinished() throws {
        let generic = HardwareLayout.layout(for: .generic)
        let note = try XCTUnwrap(generic.components.first { $0.kind == .note })
        XCTAssertEqual(note.text.first, "Generic schematic.")
        XCTAssertFalse(note.text.isEmpty)
        for line in note.text {
            XCTAssertFalse(line.hasSuffix(","), "a line ends mid-sentence: \(line)")
        }
        XCTAssertTrue(note.text.last?.hasSuffix(".") == true, "the last line ends the sentence")
        XCTAssertEqual(note.confidence, .inferred)
        // Everything on the generic schematic is a guess, and the frame is not photographed.
        XCTAssertNil(generic.photoResource)
        for c in generic.components where c.kind != .note {
            if case .display = c.kind { continue }
            XCTAssertEqual(c.confidence, .inferred, c.id)
        }
    }

    func testTheNeoSaysItIsFanlessAndHasASpreaderInsteadOfFans() throws {
        let neo = HardwareLayout.layout(for: .macBookNeo)
        let note = try XCTUnwrap(neo.components.first { $0.kind == .note })
        XCTAssertEqual(note.text.first, "Fanless.")
        let pipe = try XCTUnwrap(neo.components.first { $0.kind == .heatPipe })
        XCTAssertTrue(pipe.flags.contains("spreader"))
        XCTAssertFalse(neo.components.contains { if case .fan = $0.kind { return true } else { return false } })
    }

    func testAnEmptyOrRectlessNoteDrawsNothingAndDoesNotCrash() throws {
        let v = canvas(.generic, readings: nil)
        let empty = HardwareComponent(id: "n", kind: .note, rect: HWRect(x: 100, y: 100, w: 0, h: 0), confidence: .verified, text: [])
        let noRect = HardwareComponent(id: "n2", kind: .note, rect: nil, confidence: .verified, text: ["x"])
        let rep = try paint { ctx in
            v.drawNote(in: ctx, scale: 1, component: empty)
            v.drawNote(in: ctx, scale: 1, component: noRect)
        }
        XCTAssertEqual(changedPixels(rep, in: HWRect(x: 0, y: 0, w: 1100, h: 1205), margin: 0), 0)
    }
}

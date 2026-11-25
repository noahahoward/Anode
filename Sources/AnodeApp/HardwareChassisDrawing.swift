import AppKit
import PowerKit

// ── Hardware View: the drawn layouts' board, SoC, power supply, antenna, speakers, trackpad and notes ──
//
// Transcribed from the approved mockup (docs/superpowers/hardware-view-assets/mockup-source.html): `DRAW.board`, `DRAW.gframe`,
// `DRAW.soc`, `DRAW.psu`, `DRAW.antenna`, `DRAW.speaker`, `DRAW.trackpad`, `DRAW.note`. The lid, hinge and base plates are
// `drawChassis` (HardwareCanvasDrawing.swift); the fans, heat pipe and spreader, memory, storage, Wi-Fi, power in and battery are in
// HardwareFanPipeDrawing.swift and HardwareComponentDrawing.swift.
//
// Everything is drawn in layout units (`HardwareCanvasView.draw` has already moved and scaled the context). Nothing here owns a
// timer, a thread or an observer. Outlines that depend on guessed positions are dashed: a part the layout calls `inferred` is
// drawn with the same 5-on 4-off dash the memory, storage and Wi-Fi outlines use, and the antenna strip, whose geometry is
// always inferred, says "approx." in its label. The one part here with a reading, the power supply, writes "—" when the Mac did
// not report one, never a zero.

/// The colours that belong to this file alone (the shared ones are in `HardwareStyle`).
private enum ChassisStyle {
    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }
    private static func white(_ alpha: CGFloat) -> NSColor { NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }

    // Board and the generic schematic's frame
    static let boardGrid = NSColor(srgbRed: 120.0 / 255, green: 160.0 / 255, blue: 190.0 / 255, alpha: 0.05)
    static let frameFill = white(0.015)
    static let frameStroke = white(0.14)

    // SoC package and die
    static let socFill = rgb(0x151B24)
    static let socStroke = rgb(0x2A3441)
    static let dieFill = rgb(0x0B0F14)
    static let dieStroke = rgb(0x33414F)
    static let dieLabelColor = rgb(0x3C4A5A)

    // Power supply
    static let psuFill = rgb(0x0F141B)
    static let psuStroke = rgb(0x2A3441)
    static let psuVent = rgb(0x141B24)

    // Antenna strip
    static let antennaFill = HardwareStyle.cyan.withAlphaComponent(0.04)
    static let antennaStroke = HardwareStyle.cyan.withAlphaComponent(0.35)
    static let antennaPlateStroke = HardwareStyle.cyan.withAlphaComponent(0.4)
    static let antennaPlateFill = rgb(0x07090C, 0.86)
    static let antennaLabel = rgb(0x8FCFDE)

    // Speakers and trackpad
    static let speakerFill = rgb(0x0D1116)
    static let speakerStroke = rgb(0x1D2530)
    static let speakerSlot = rgb(0x1C242F)
    static let trackpadStroke = white(0.12)
    static let trackpadLabel = rgb(0x3E4A59)
}

extension HardwareCanvasView {

    // MARK: - Pure text helpers

    /// The chip's name for the SoC die ("APPLE M4 PRO"): upper case, trimmed, cut with "…" past 24 characters; empty when the
    /// chip is not known (the die is then drawn without a label).
    static func socDieLabel(chip: String) -> String {
        let trimmed = chip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let upper = trimmed.uppercased()
        return upper.count > 24 ? String(upper.prefix(23)) + "…" : upper
    }

    /// The power supply's number: "41.5", "≈ 41.5" for an estimate, or "—" when there is no reading (a missing, non-finite or
    /// negative value is no reading; a zero is never made up).
    static func psuValueText(_ reading: Tagged<Double>?) -> String {
        guard let reading = reading, let watts = reading.value, watts.isFinite, watts >= 0 else { return "—" }
        return estimatePrefix(reading.provenance) + readoutNumber(watts, digits: 1)
    }

    // MARK: - Caches (main thread only: they are only used from draw)

    /// Paths built from a layout's fixed rectangles (the board's grid, the speakers' slots, the supply's vents), kept so a redraw
    /// does not rebuild them. A layout has a handful of parts, so this stays tiny.
    private static var chassisPaths: [String: CGPath] = [:]
    /// The measured width of an antenna label's text.
    private static var antennaLabelWidths: [String: CGFloat] = [:]
    /// The die label of this Mac's chip, worked out once.
    private static let dieLabelText = socDieLabel(chip: MachineInfo.facts.chip)

    private static func cachedPath(_ key: String, _ build: () -> CGPath) -> CGPath {
        if let path = chassisPaths[key] { return path }
        let path = build()
        chassisPaths[key] = path
        return path
    }

    private static func antennaLabelWidth(_ text: String, kern: CGFloat) -> CGFloat {
        if let width = antennaLabelWidths[text] { return width }
        let width = NSAttributedString(string: text,
                                       attributes: [.font: HardwareStyle.label(8.5), .kern: kern]).size().width
        antennaLabelWidths[text] = width
        return width
    }

    // MARK: - Small drawing helpers

    private static func chassisRect(_ r: HWRect) -> CGRect {
        CGRect(x: r.x, y: r.y, width: r.w, height: r.h)
    }

    /// A rounded rectangle with an optional flat fill and an optional 1-unit outline, dashed when `dash` is given.
    private static func chassisBox(in ctx: CGContext, rect: CGRect, radius: CGFloat,
                                   fill: NSColor?, stroke: NSColor?, dash: [CGFloat]? = nil) {
        ctx.saveGState()
        let path = roundedPath(rect, radius: radius)
        if let fill = fill {
            ctx.addPath(path)
            ctx.setFillColor(fill.cgColor)
            ctx.fillPath()
        }
        if let stroke = stroke {
            ctx.addPath(path)
            ctx.setStrokeColor(stroke.cgColor)
            ctx.setLineWidth(1)
            if let dash = dash { ctx.setLineDash(phase: 0, lengths: dash) }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// Several styled pieces of text side by side on one baseline, left aligned.
    private static func chassisRuns(_ runs: [(text: String, font: NSFont, color: NSColor)], x: CGFloat, baseline: CGFloat) {
        var left = x
        for run in runs {
            let string = NSAttributedString(string: run.text,
                                            attributes: [.font: run.font, .foregroundColor: run.color])
            string.draw(at: NSPoint(x: left, y: baseline - run.font.ascender))
            left += string.size().width
        }
    }

    /// The dash a part's outline takes: the layout's `inferred` cue.
    private static func inferredDash(_ c: HardwareComponent) -> [CGFloat]? {
        c.confidence == .inferred ? [5, 4] : nil
    }

    // MARK: - Board

    /// The logic board: a dark plate with a faint grid (the mockup's `pcb` pattern, lines every 14 units on a fixed origin so the
    /// grid does not shift between boards). The generic schematic's board is its dashed frame instead: nothing in it is known.
    func drawBoard(in ctx: CGContext, scale: CGFloat, component c: HardwareComponent) {
        guard let r = c.rect, r.w > 0, r.h > 0 else { return }
        let rect = Self.chassisRect(r)

        if hardwareLayout.family == .generic {
            Self.chassisBox(in: ctx, rect: rect, radius: 28,
                            fill: ChassisStyle.frameFill, stroke: ChassisStyle.frameStroke, dash: [8, 7])
            return
        }

        Self.chassisBox(in: ctx, rect: rect, radius: 22,
                        fill: HardwareStyle.deskPlate, stroke: HardwareStyle.deskPlateStroke, dash: Self.inferredDash(c))
        let grid = Self.cachedPath("grid \(r.x) \(r.y) \(r.w) \(r.h)") {
            let path = CGMutablePath()
            let step: CGFloat = 14
            let offset: CGFloat = 7
            var x = (((rect.minX - offset) / step).rounded(.up) * step) + offset
            while x < rect.maxX {
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                x += step
            }
            var y = (((rect.minY - offset) / step).rounded(.up) * step) + offset
            while y < rect.maxY {
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
                y += step
            }
            return path
        }
        ctx.saveGState()
        ctx.addPath(Self.roundedPath(rect, radius: 22))
        ctx.clip()
        ctx.addPath(grid)
        ctx.setStrokeColor(ChassisStyle.boardGrid.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - SoC

    /// The chip package with its die, and the chip's name on the die (the memory and the heat pipe draw over it where they
    /// overlap, as in the mockup). An inferred package and die are dashed.
    func drawSoC(in ctx: CGContext, scale: CGFloat, component c: HardwareComponent) {
        guard let r = c.rect, r.w > 0, r.h > 0 else { return }
        let dash = Self.inferredDash(c)
        Self.chassisBox(in: ctx, rect: Self.chassisRect(r), radius: 12,
                        fill: ChassisStyle.socFill, stroke: ChassisStyle.socStroke, dash: dash)
        guard let die = c.parts.first(where: { $0.name == "die" }) else { return }
        let d = Self.chassisRect(die.rect)
        guard d.width > 0, d.height > 0 else { return }
        Self.chassisBox(in: ctx, rect: d, radius: 6,
                        fill: ChassisStyle.dieFill, stroke: ChassisStyle.dieStroke, dash: dash)
        let label = Self.dieLabelText
        if !label.isEmpty, d.width >= 60 {
            Self.drawText(label, x: d.midX, baseline: d.minY + 16, font: HardwareStyle.label(9),
                          color: ChassisStyle.dieLabelColor, align: .center, kern: 1.26)
        }
    }

    // MARK: - Power supply (Mac mini)

    /// The mini's power supply: a housing with vent slots, the label, and the whole-Mac draw from the supply. With no reading the
    /// number is "—" and the unit is not written.
    func drawPSU(in ctx: CGContext, scale: CGFloat, component c: HardwareComponent) {
        guard let r = c.rect, r.w > 0, r.h > 0 else { return }
        let rect = Self.chassisRect(r)
        Self.chassisBox(in: ctx, rect: rect, radius: 12,
                        fill: ChassisStyle.psuFill, stroke: ChassisStyle.psuStroke, dash: Self.inferredDash(c))

        if rect.width > 280, rect.height > 32 {
            let vents = Self.cachedPath("vents \(r.x) \(r.y) \(r.w) \(r.h)") {
                let path = CGMutablePath()
                for i in 0..<9 {
                    path.addRoundedRect(in: CGRect(x: rect.maxX - 250 + CGFloat(i) * 26, y: rect.minY + 16,
                                                   width: 14, height: rect.height - 32),
                                        cornerWidth: 3, cornerHeight: 3)
                }
                return path
            }
            ctx.saveGState()
            ctx.addPath(vents)
            ctx.setFillColor(ChassisStyle.psuVent.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }

        Self.drawText("POWER SUPPLY · WALL POWER", x: rect.minX + 22, baseline: rect.minY + 30,
                      font: HardwareStyle.label(10.5), color: HardwareStyle.dim, kern: 1.47)
        let value = Self.psuValueText(readings?.systemW)
        let hasValue = value != "—"
        var runs: [(text: String, font: NSFont, color: NSColor)] = [
            (value, Palette.Font.mono(38, .semibold), HardwareStyle.ink)
        ]
        if hasValue { runs.append((" W", Palette.Font.sans(18, .regular), HardwareStyle.dim)) }
        runs.append(("   whole-Mac draw", Palette.Font.sans(13, .regular), HardwareStyle.dim))
        Self.chassisRuns(runs, x: rect.minX + 22, baseline: rect.minY + 74)
    }

    // MARK: - Antenna

    /// The antenna strip: a dashed band with a label plate on it. Where the antennas sit is a guess (iFixit and teardown
    /// photographs show the Wi-Fi module, not the aerials), so the band is dashed and the label says "approx."; a layout can
    /// replace the label with its own words (the mini's bottom plate).
    func drawAntenna(in ctx: CGContext, scale: CGFloat, component c: HardwareComponent) {
        guard let r = c.rect, r.w > 0, r.h > 0 else { return }
        let rect = Self.chassisRect(r)
        Self.chassisBox(in: ctx, rect: rect, radius: 9, fill: ChassisStyle.antennaFill,
                        stroke: ChassisStyle.antennaStroke, dash: c.confidence == .inferred ? [6, 5] : nil)

        let label = (c.text.first ?? "Antennas · approx. position").uppercased()
        let kern: CGFloat = 1.19
        let plateWidth = Self.antennaLabelWidth(label, kern: kern) + 20
        let plate = CGRect(x: rect.midX - plateWidth / 2, y: rect.minY - 1, width: plateWidth, height: rect.height + 2)
        Self.chassisBox(in: ctx, rect: plate, radius: 6,
                        fill: ChassisStyle.antennaPlateFill, stroke: ChassisStyle.antennaPlateStroke)
        Self.drawText(label, x: rect.midX, baseline: rect.midY + 3.5, font: HardwareStyle.label(8.5),
                      color: ChassisStyle.antennaLabel, align: .center, kern: kern)
    }

    // MARK: - Speakers and trackpad (context, no readings)

    /// A speaker grille: a dark slot with 14 horizontal ribs.
    func drawSpeaker(in ctx: CGContext, scale: CGFloat, component c: HardwareComponent) {
        guard let r = c.rect, r.w > 16, r.h > 28 else { return }
        let rect = Self.chassisRect(r)
        Self.chassisBox(in: ctx, rect: rect, radius: 10,
                        fill: ChassisStyle.speakerFill, stroke: ChassisStyle.speakerStroke, dash: Self.inferredDash(c))
        let slots = Self.cachedPath("slots \(r.x) \(r.y) \(r.w) \(r.h)") {
            let path = CGMutablePath()
            for i in 0..<14 {
                let y = rect.minY + 14 + CGFloat(i) * (rect.height - 28) / 13
                path.addRoundedRect(in: CGRect(x: rect.minX + 8, y: y, width: rect.width - 16, height: 3),
                                    cornerWidth: 1.5, cornerHeight: 1.5)
            }
            return path
        }
        ctx.saveGState()
        ctx.addPath(slots)
        ctx.setFillColor(ChassisStyle.speakerSlot.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// The trackpad: a dotted outline with its name under it, so the battery cells around it have something to be around.
    func drawTrackpad(in ctx: CGContext, scale: CGFloat, component c: HardwareComponent) {
        guard let r = c.rect, r.w > 0, r.h > 0 else { return }
        let rect = Self.chassisRect(r)
        Self.chassisBox(in: ctx, rect: rect, radius: 14, fill: nil, stroke: ChassisStyle.trackpadStroke, dash: [2, 5])
        Self.drawText("TRACKPAD", x: rect.midX, baseline: rect.maxY + 14, font: HardwareStyle.label(9),
                      color: ChassisStyle.trackpadLabel, align: .center, kern: 1.26)
    }

    // MARK: - Notes

    /// Words on the drawing: the Neo's "Fanless.", the generic schematic's label, the 16-inch layout's line on its hinge. The
    /// rectangle's origin is where the first line starts (its centre, for a note flagged "centered"). The first line is the
    /// heading, the rest are fainter.
    func drawNote(in ctx: CGContext, scale: CGFloat, component c: HardwareComponent) {
        guard let r = c.rect, !c.text.isEmpty else { return }
        let x = CGFloat(r.x)
        let y = CGFloat(r.y)
        if c.flags.contains("centered") {
            for (i, line) in c.text.enumerated() {
                Self.drawText(line, x: x, baseline: y + CGFloat(i) * 16, font: Palette.Font.sans(11.5, .medium),
                              color: HardwareStyle.dim, align: .center)
            }
            return
        }
        for (i, line) in c.text.enumerated() {
            let heading = i == 0
            Self.drawText(line, x: x, baseline: y + CGFloat(i) * 20,
                          font: Palette.Font.sans(heading ? 15 : 13, heading ? .semibold : .regular),
                          color: heading ? HardwareStyle.dim : HardwareStyle.faint)
        }
    }
}

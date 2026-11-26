import AppKit
import PowerKit

// ── Hardware View: the heat pipe and the fans ───────────────────────────────
//
// Transcribed from the approved mockup (docs/superpowers/hardware-view-assets/mockup-source.html): `heat()` and STOPS,
// `pill()`, `DRAW.ppipe` (the photo's pipe), `DRAW.pipe` (the drawn straight pipe and the Neo's passive spreader),
// `DRAW.pfan` (the photo's fans), `DRAW.fan` (the drawn fans) and `sliderBlock()` (the fan speed control under each fan).
//
// Everything is drawn in layout units (`HardwareCanvasView.draw` has already moved and scaled the context). The fan speed
// control's mouse handling also lives here (`fanControlMouseDown/Dragged/Up`); HardwareCanvasView.swift only calls it, ahead
// of its own hit testing. Nothing here owns a timer: the impeller's angle is read from `fanAngles`, which whoever animates the
// fans keeps up to date.

/// The colours and sizes that belong to this file alone (the shared ones are in `HardwareStyle`).
private enum FanPipeStyle {
    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }
    private static func white(_ alpha: CGFloat) -> NSColor { NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }

    /// A pipe half with no temperature: neither cold nor hot.
    static let unknownHeat = rgb(0x6E7683)

    // DRAW.pipe
    static let spreaderFill = rgb(0x1A212B)
    static let spreaderStroke = rgb(0x2C3744)
    static let pipeHighlight = white(0.22)
    static let pipeSplit = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28)
    static let halo = NSColor(srgbRed: 4.0 / 255, green: 5.0 / 255, blue: 7.0 / 255, alpha: 0.9)

    // DRAW.fan and DRAW.pfan
    static let housingFill = rgb(0x0D1218)
    static let housingStroke = rgb(0x222C38)
    static let disc = rgb(0x090C10)
    static let discStroke = rgb(0x2A3441)
    static let hubFill = rgb(0x0B0F14)
    static let hubIdleStroke = rgb(0x2F3A47)
    static let hubPlate = rgb(0x07090C, 0.82)
    static let bladeLight = rgb(0x39414C)
    static let bladeDark = rgb(0x1D232B)
    static let shine = white(0.10)
    static let shineEnd = white(0)

    // sliderBlock()
    static let track = white(0.18)
    static let thumb = rgb(0xF4F7FB)
    static let thumbStroke = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45)
    static let chipAutoFill = rgb(0x4FC8E6, 0.16)
    static let chipManualFill = rgb(0xFF9A3D, 0.18)
    static let promptFill = white(0.06)
    static let promptStroke = white(0.20)
    static let lock = rgb(0x9AA5B4)

    /// The heat stops: (degrees C, r, g, b). The mockup's STOPS.
    static let stops: [(Double, Double, Double, Double)] = [
        (30, 58, 118, 240),
        (50, 79, 172, 236),
        (65, 242, 178, 74),
        (80, 255, 122, 61),
        (95, 255, 77, 58),
    ]
}

/// Where one fan's speed control sits, in layout units. Shared by the drawing and the mouse so they cannot disagree.
struct FanSliderGeometry {
    let index: Int
    /// The track starts here and runs `trackWidth` to the right.
    let trackX: CGFloat
    /// The mockup's `sy`: the block's baseline row.
    let sy: CGFloat
    /// The photo layouts put the block on a glass plate.
    let plated: Bool
    let centerX: CGFloat

    static let trackWidth: CGFloat = 160

    init(index: Int, centerX: CGFloat, sy: CGFloat, plated: Bool) {
        self.index = index
        self.centerX = centerX
        self.trackX = centerX - 80
        self.sy = sy
        self.plated = plated
    }

    var trackY: CGFloat { sy + 8 }
    /// Where a press starts a drag (the mockup's transparent rect around the track).
    var trackHit: CGRect { CGRect(x: trackX - 14, y: sy - 6, width: Self.trackWidth + 28, height: 30) }
    /// The AUTO / MANUAL chip.
    var chip: CGRect { CGRect(x: trackX + Self.trackWidth - 56, y: sy - 28, width: 56, height: 19) }
    /// The install prompt that replaces the slider when the helper is not installed.
    var prompt: CGRect { CGRect(x: trackX - 4, y: sy - 4, width: Self.trackWidth + 8, height: 30) }
    var plate: CGRect { CGRect(x: centerX - 98, y: sy - 32, width: 196, height: 66) }

    /// The speed a pointer at `x` (layout units) asks for: the track's fraction between the fan's own minimum and maximum.
    func rpm(atLayoutX x: CGFloat, minRPM: Double, maxRPM: Double) -> Double {
        let k = max(0, min(1, Double((x - trackX) / Self.trackWidth)))
        return (minRPM + k * (maxRPM - minRPM)).rounded()
    }
}

extension HardwareCanvasView {

    // MARK: - Heat colour and text

    /// The mockup's `heat()`: a temperature to a colour, linear between the STOPS and clamped at both ends.
    static func heatColor(_ celsius: Double) -> NSColor {
        let stops = FanPipeStyle.stops
        let t = max(stops[0].0, min(stops[stops.count - 1].0, celsius))
        for i in 1..<stops.count where t <= stops[i].0 {
            let a = stops[i - 1], b = stops[i]
            let k = (t - a.0) / (b.0 - a.0)
            func mix(_ from: Double, _ to: Double) -> CGFloat {
                CGFloat((from + (to - from) * k).rounded()) / 255
            }
            return NSColor(srgbRed: mix(a.1, b.1), green: mix(a.2, b.2), blue: mix(a.3, b.3), alpha: 1)
        }
        let last = stops[stops.count - 1]
        return NSColor(srgbRed: CGFloat(last.1) / 255, green: CGFloat(last.2) / 255, blue: CGFloat(last.3) / 255, alpha: 1)
    }

    /// A pipe half's colour: the heat colour, or neutral grey when there is no temperature.
    static func pipeColor(_ celsius: Double?) -> NSColor {
        celsius.map { heatColor($0) } ?? FanPipeStyle.unknownHeat
    }

    /// "41°" for a temperature in whole degrees; "—" for none.
    static func temperatureText(_ celsius: Double?) -> String {
        guard let c = celsius, c.isFinite else { return "—" }
        return "\(Int(c.rounded()))°"
    }

    private static let groupedFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.usesGroupingSeparator = true
        f.maximumFractionDigits = 0
        return f
    }()

    /// A speed with thousands separators ("4,380"), the way the mockup writes it.
    static func rpmText(_ rpm: Double) -> String {
        guard rpm.isFinite else { return "—" }
        return groupedFormatter.string(from: NSNumber(value: rpm.rounded())) ?? "\(Int(rpm.rounded()))"
    }

    // MARK: - Heat pipe

    /// The heat pipe: each half takes the heat colour of the part on its side, a pill names each reading.
    func drawHeatPipe(in ctx: CGContext, scale: CGFloat, component c: HardwareComponent) {
        let cpu = readings?.cpuTemp.value
        let gpu = readings?.gpuTemp.value
        let cpuLeft = c.flags.contains("cpuSideLeft")
        let leftTemp = cpuLeft ? cpu : gpu
        let rightTemp = cpuLeft ? gpu : cpu
        let leftName = cpuLeft ? "CPU" : "GPU"
        let rightName = cpuLeft ? "GPU" : "CPU"
        let leftColor = Self.pipeColor(leftTemp)
        let rightColor = Self.pipeColor(rightTemp)

        if c.points.count > 2 {
            drawPhotoPipe(in: ctx, component: c, leftColor: leftColor, rightColor: rightColor)
            // The pills' centres are the left and right ends of the pipe's two halves.
            if let left = c.anchors["cpu"] {
                Self.pill(in: ctx, center: CGPoint(x: left.x, y: left.y), name: leftName,
                          value: Self.temperatureText(leftTemp), color: leftColor)
            }
            if let right = c.anchors["gpu"] {
                Self.pill(in: ctx, center: CGPoint(x: right.x, y: right.y), name: rightName,
                          value: Self.temperatureText(rightTemp), color: rightColor)
            }
        } else if let rect = c.rect {
            drawStraightPipe(in: ctx, component: c, rect: rect,
                             left: (leftName, leftTemp, leftColor), right: (rightName, rightTemp, rightColor))
        }
    }

    /// The photograph's pipe: one continuous symmetric stroke of round caps and joins, filled across its length with the
    /// left colour then the right, blended over a short span in the middle, at 66 % opacity (the photo shows through).
    private func drawPhotoPipe(in ctx: CGContext, component c: HardwareComponent, leftColor: NSColor, rightColor: NSColor) {
        guard let first = c.points.first, let last = c.points.last, last.x > first.x else { return }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: first.x, y: first.y))
        for p in c.points.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }

        let span = last.x - first.x
        // The mockup blends over 52 photo pixels each side of the middle.
        let half = 52 * PhotoWarp.straightened.frameScale / span
        let a = max(0, 0.5 - half), b = min(1, 0.5 + half)
        guard let gradient = Self.gradient([(leftColor, 0), (leftColor, CGFloat(a)),
                                            (rightColor, CGFloat(b)), (rightColor, 1)]) else { return }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineWidth(CGFloat(PhotoWarp.straightened.drawingLength(86)))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.setAlpha(0.66)
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: first.x, y: first.y),
                               end: CGPoint(x: last.x, y: first.y),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// The drawn layouts' straight pipe (and the Neo's passive spreader): a pill-shaped bar with the two colours meeting at
    /// the split, a highlight along its top, and each half's name and temperature on it.
    private func drawStraightPipe(in ctx: CGContext, component c: HardwareComponent, rect: HWRect,
                                  left: (String, Double?, NSColor), right: (String, Double?, NSColor)) {
        let x0 = CGFloat(rect.x), w = CGFloat(rect.w), h = CGFloat(rect.h)
        let ry = CGFloat(rect.y)
        let y = ry + h / 2
        let x1 = x0 + w
        let split = CGFloat(c.values["split"] ?? (rect.x + rect.w / 2))
        let spreader = c.flags.contains("spreader")

        if spreader {
            Self.fillRounded(in: ctx, rect: CGRect(x: x0, y: ry - 6, width: w, height: h + 12), radius: 10,
                             fill: FanPipeStyle.spreaderFill, stroke: FanPipeStyle.spreaderStroke)
        }

        let bar = CGRect(x: x0, y: ry, width: w, height: h)
        let a = max(0, min(1, (split - 24 - x0) / w)), b = max(a, min(1, (split + 24 - x0) / w))
        if let gradient = Self.gradient([(left.2, 0), (left.2, a), (right.2, b), (right.2, 1)]) {
            ctx.saveGState()
            ctx.addPath(Self.roundedPath(bar, radius: spreader ? 6 : h / 2))
            ctx.clip()
            ctx.setAlpha(0.96)
            ctx.drawLinearGradient(gradient, start: CGPoint(x: x0, y: y), end: CGPoint(x: x1, y: y),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }
        Self.fillRounded(in: ctx, rect: CGRect(x: x0 + 6, y: ry + 3, width: w - 12, height: 3), radius: 1.5,
                         fill: FanPipeStyle.pipeHighlight, stroke: nil)

        ctx.saveGState()
        ctx.setStrokeColor(FanPipeStyle.pipeSplit.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [2, 3])
        ctx.move(to: CGPoint(x: split, y: ry + 4))
        ctx.addLine(to: CGPoint(x: split, y: ry + h - 4))
        ctx.strokePath()
        ctx.restoreGState()

        let baseline = y + 5.5
        Self.drawHaloLabel(name: left.0, value: Self.temperatureText(left.1), centerX: (x0 + split) / 2 - 6, baseline: baseline)
        Self.drawHaloLabel(name: right.0, value: Self.temperatureText(right.1), centerX: (split + x1) / 2 + 6, baseline: baseline)

        if spreader {
            Self.drawText("PASSIVE SPREADER", x: x0, baseline: ry - 14,
                          font: HardwareStyle.label(10.5), color: HardwareStyle.dim, kern: 1.47)
        }
    }

    /// A small name and a large number, centred as one line, on a dark halo so it reads over any colour (the mockup's
    /// `.halo` text: a 3.5-unit outline painted under the fill).
    private static func drawHaloLabel(name: String, value: String, centerX: CGFloat, baseline: CGFloat) {
        let nameFont = HardwareStyle.label(10.5)
        let valueFont = HardwareStyle.number(16)
        let nameKern: CGFloat = 1.26
        let gap: CGFloat = 7
        func attributes(_ font: NSFont, kern: CGFloat, halo: Bool) -> [NSAttributedString.Key: Any] {
            var a: [NSAttributedString.Key: Any] = [.font: font]
            if kern != 0 { a[.kern] = kern }
            if halo {
                // A positive stroke width paints the outline only; it is a percentage of the point size.
                a[.strokeColor] = FanPipeStyle.halo
                a[.strokeWidth] = 3.5 / font.pointSize * 100
                a[.foregroundColor] = FanPipeStyle.halo
            } else {
                a[.foregroundColor] = HardwareStyle.ink
            }
            return a
        }
        let nameWidth = NSAttributedString(string: name, attributes: attributes(nameFont, kern: nameKern, halo: false)).size().width
        let valueWidth = NSAttributedString(string: value, attributes: attributes(valueFont, kern: 0, halo: false)).size().width
        let left = centerX - (nameWidth + gap + valueWidth) / 2
        for halo in [true, false] {
            NSAttributedString(string: name, attributes: attributes(nameFont, kern: nameKern, halo: halo))
                .draw(at: NSPoint(x: left, y: baseline - nameFont.ascender))
            NSAttributedString(string: value, attributes: attributes(valueFont, kern: 0, halo: halo))
                .draw(at: NSPoint(x: left + nameWidth + gap, y: baseline - valueFont.ascender))
        }
    }

    // MARK: - Fans

    /// The fan's index, or nil for any other kind.
    private func fanIndex(of component: HardwareComponent) -> Int? {
        if case .fan(let index) = component.kind { return index }
        return nil
    }

    /// Where a fan's speed control sits: under the fan. The photo layouts put it on a plate at the mockup's fixed row below the
    /// fans (P(0, 735) + 32); the drawn layouts under the fan's housing.
    func fanSliderGeometry(for component: HardwareComponent) -> FanSliderGeometry? {
        guard let index = fanIndex(of: component), let centre = component.points.first, let rect = component.rect else { return nil }
        if hardwareLayout.photoResource != nil {
            // P(0, 735): 735 is a row of the original photo, so it goes through the warp (not a plain scale).
            let sy = PhotoWarp.straightened.drawingPoint(photoX: 0, photoY: 735).y + 32
            return FanSliderGeometry(index: index, centerX: CGFloat(centre.x), sy: CGFloat(sy), plated: true)
        }
        let housing = CGFloat(rect.w) / 2 + 16
        return FanSliderGeometry(index: index, centerX: CGFloat(centre.x), sy: CGFloat(centre.y) + housing + 42, plated: false)
    }

    /// One fan: its hub readout, the impeller, and the speed control under it.
    func drawFan(in ctx: CGContext, scale: CGFloat, component c: HardwareComponent) {
        guard let index = fanIndex(of: c), let centre = c.points.first, let rect = c.rect else { return }
        let measured = readings?.fansMeasured ?? false
        let reading = readings?.fans.first { $0.index == index }
        // A fan that was measured and is not in the list does not exist on this Mac; nothing is drawn for it. When the sensors
        // were not read this tick the fan is drawn with "—" (never "PARKED") and no control.
        if measured && reading == nil { return }
        let rpm: Double? = measured ? reading?.rpm : nil
        let spinning = (rpm ?? 0) > 0
        let angle = CGFloat(index < fanAngles.count ? fanAngles[index] : 0)
        let cx = CGFloat(centre.x), cy = CGFloat(centre.y)
        let r = CGFloat(rect.w) / 2
        let photo = hardwareLayout.photoResource != nil
        let center = CGPoint(x: cx, y: cy)

        if photo {
            if spinning {
                drawImpeller(in: ctx, center: center, radius: r,
                             innerRadius: CGFloat(PhotoWarp.straightened.drawingLength(80)), angle: angle)
            }
            let ring = (spinning ? HardwareStyle.cyan : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12))
            ctx.saveGState()
            ctx.setStrokeColor(ring.withAlphaComponent(ring.alphaComponent * 0.5).cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
            ctx.restoreGState()
            drawFanHub(in: ctx, center: center, hubRadius: 33, rpm: rpm, spinning: spinning,
                       numberSize: (rpm ?? 0) >= 1000 ? 18 : 22, numberDY: spinning ? 3 : 2,
                       labelSize: 8, labelDY: 19, kern: 1.12, plate: true)
        } else {
            let housing = r + 16
            Self.fillRounded(in: ctx, rect: CGRect(x: cx - housing, y: cy - housing, width: housing * 2, height: housing * 2),
                             radius: 30, fill: FanPipeStyle.housingFill, stroke: FanPipeStyle.housingStroke)
            Self.fillRounded(in: ctx, rect: CGRect(x: cx - r - 4, y: cy - r - 4, width: 2 * r + 8, height: 2 * r + 8),
                             radius: r + 4, fill: FanPipeStyle.disc, stroke: FanPipeStyle.discStroke)
            drawImpeller(in: ctx, center: center, radius: r, innerRadius: 36, angle: angle)
            drawFanHub(in: ctx, center: center, hubRadius: 36, rpm: rpm, spinning: spinning,
                       numberSize: (rpm ?? 0) >= 1000 ? 19 : 22, numberDY: spinning ? 4 : 2,
                       labelSize: 8.5, labelDY: spinning ? 20 : 19, kern: 1.19, plate: false)
        }

        if let reading = reading, measured, let geometry = fanSliderGeometry(for: c) {
            drawFanSlider(in: ctx, geometry: geometry, reading: reading)
        }
    }

    /// The hub: a small dark plate with the speed over its unit, "PARKED" at rest, "—" when the speed was not read.
    private func drawFanHub(in ctx: CGContext, center: CGPoint, hubRadius: CGFloat, rpm: Double?, spinning: Bool,
                            numberSize: CGFloat, numberDY: CGFloat, labelSize: CGFloat, labelDY: CGFloat,
                            kern: CGFloat, plate: Bool) {
        ctx.saveGState()
        let hub = CGRect(x: center.x - hubRadius, y: center.y - hubRadius, width: hubRadius * 2, height: hubRadius * 2)
        ctx.setFillColor((plate ? FanPipeStyle.hubPlate : FanPipeStyle.hubFill).cgColor)
        ctx.fillEllipse(in: hub)
        let idle = plate ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.2) : FanPipeStyle.hubIdleStroke
        ctx.setStrokeColor((spinning ? HardwareStyle.cyan : idle).cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: hub)
        ctx.restoreGState()

        let number: String
        let unit: String
        if let rpm = rpm, rpm.isFinite {
            number = spinning ? Self.rpmText(rpm) : "0"
            unit = spinning ? "RPM" : "PARKED"
        } else {
            number = "—"
            unit = "RPM"
        }
        Self.drawText(number, x: center.x, baseline: center.y + numberDY,
                      font: HardwareStyle.number(numberSize), color: HardwareStyle.ink, align: .center)
        Self.drawText(unit, x: center.x, baseline: center.y + labelDY,
                      font: HardwareStyle.label(labelSize), color: HardwareStyle.dim, align: .center, kern: kern)
    }

    // MARK: - Impeller

    /// The fan's impeller drawn flat from scratch (so no photo perspective or lighting turns with it): a dark disc, 33 thin
    /// curved blades from `innerRadius` out to `radius`, turned by `angle` radians, and one fixed, non-rotating highlight
    /// over the whole disc.
    func drawImpeller(in ctx: CGContext, center: CGPoint, radius: CGFloat, innerRadius: CGFloat, angle: CGFloat) {
        let n = 33
        let r = radius, r0 = innerRadius
        ctx.saveGState()
        ctx.setFillColor(FanPipeStyle.disc.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))

        // One blade, pointing along +x: a quadratic curve that sweeps a little to the side as it goes out.
        let end = CGPoint(x: r * 0.97 * CGFloat(cos(-0.5)), y: r * 0.97 * CGFloat(sin(-0.5)))
        let blade = CGMutablePath()
        blade.move(to: CGPoint(x: r0, y: 0))
        blade.addQuadCurve(to: end, control: CGPoint(x: (r0 + r) / 2, y: -r * 0.07))

        let light = CGMutablePath()
        let dark = CGMutablePath()
        let step = 2 * CGFloat.pi / CGFloat(n)
        let offset = CGFloat(1.1) * CGFloat.pi / 180
        for i in 0..<n {
            let a = angle + CGFloat(i) * step
            light.addPath(blade, transform: CGAffineTransform(rotationAngle: a))
            dark.addPath(blade, transform: CGAffineTransform(rotationAngle: a + offset))
        }
        ctx.translateBy(x: center.x, y: center.y)
        ctx.setLineCap(.round)
        ctx.setLineWidth(1.5)
        ctx.setStrokeColor(FanPipeStyle.bladeLight.cgColor)
        ctx.addPath(light)
        ctx.strokePath()
        ctx.setLineWidth(1)
        ctx.setStrokeColor(FanPipeStyle.bladeDark.cgColor)
        ctx.addPath(dark)
        ctx.strokePath()
        ctx.translateBy(x: -center.x, y: -center.y)

        // The highlight: a radial glow centred up and to the left (35 %, 30 % of the disc's box), over the disc only.
        if let shine = Self.gradient([(FanPipeStyle.shine, 0), (FanPipeStyle.shineEnd, 1)]) {
            ctx.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            ctx.clip()
            let origin = CGPoint(x: center.x - 0.3 * r, y: center.y - 0.4 * r)
            ctx.drawRadialGradient(shine, startCenter: origin, startRadius: 0, endCenter: origin, endRadius: 1.5 * r, options: [])
        }
        ctx.restoreGState()
    }

    // MARK: - Speed control

    /// The mockup's `sliderBlock()`: "FAN n", the AUTO / MANUAL chip, the track and its thumb with the fan's own minimum and
    /// maximum under it; or, when the helper is not installed, the prompt to install it.
    private func drawFanSlider(in ctx: CGContext, geometry g: FanSliderGeometry, reading f: FanReading) {
        let sx = g.trackX
        let sw = FanSliderGeometry.trackWidth
        if g.plated {
            Self.plate(in: ctx, rect: g.plate, radius: 10, alpha: 0.8)
        }
        Self.drawText("FAN \(g.index + 1)", x: sx, baseline: g.sy - 14,
                      font: HardwareStyle.label(10.5), color: HardwareStyle.dim, kern: 1.47)

        guard readings?.helperInstalled == true else {
            drawInstallPrompt(in: ctx, geometry: g)
            return
        }

        let dragging = dragFanIndex == g.index && dragRPM != nil
        let shownRPM = (dragging ? dragRPM : nil) ?? f.rpm
        let span = f.maxRPM - f.minRPM
        let k = span > 0 ? CGFloat(max(0, min(1, (shownRPM - f.minRPM) / span))) : 0
        let tx = sx + sw * k
        let manual = f.isManual || dragging
        let color = manual ? HardwareStyle.warm : HardwareStyle.cyan

        // The chip.
        Self.fillRounded(in: ctx, rect: g.chip, radius: 6,
                         fill: manual ? FanPipeStyle.chipManualFill : FanPipeStyle.chipAutoFill,
                         stroke: color.withAlphaComponent(0.6))
        Self.drawText(manual ? "MANUAL" : "AUTO", x: g.chip.midX, baseline: g.sy - 14.5,
                      font: Palette.Font.mono(10, .semibold), color: color, align: .center, kern: 1)

        // The track, the filled part of it, and the thumb.
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineWidth(5)
        ctx.setStrokeColor(FanPipeStyle.track.cgColor)
        ctx.move(to: CGPoint(x: sx, y: g.trackY))
        ctx.addLine(to: CGPoint(x: sx + sw, y: g.trackY))
        ctx.strokePath()
        ctx.setStrokeColor(color.cgColor)
        ctx.move(to: CGPoint(x: sx, y: g.trackY))
        ctx.addLine(to: CGPoint(x: tx, y: g.trackY))
        ctx.strokePath()
        let thumb = CGRect(x: tx - 9, y: g.trackY - 9, width: 18, height: 18)
        ctx.setFillColor(FanPipeStyle.thumb.cgColor)
        ctx.fillEllipse(in: thumb)
        ctx.setLineWidth(1)
        ctx.setStrokeColor(FanPipeStyle.thumbStroke.cgColor)
        ctx.strokeEllipse(in: thumb)
        ctx.restoreGState()

        Self.drawText(Self.rpmText(f.minRPM), x: sx, baseline: g.sy + 30,
                      font: Palette.Font.mono(10, .regular), color: HardwareStyle.faint)
        Self.drawText(Self.rpmText(f.maxRPM), x: sx + sw, baseline: g.sy + 30,
                      font: Palette.Font.mono(10, .regular), color: HardwareStyle.faint, align: .right)
    }

    private func drawInstallPrompt(in ctx: CGContext, geometry g: FanSliderGeometry) {
        let sx = g.trackX
        Self.fillRounded(in: ctx, rect: g.prompt, radius: 8, fill: FanPipeStyle.promptFill, stroke: FanPipeStyle.promptStroke)
        // A small padlock: the shackle (a half circle on two short legs), then the body.
        ctx.saveGState()
        ctx.setStrokeColor(FanPipeStyle.lock.cgColor)
        ctx.setLineWidth(1.4)
        let shackle = CGMutablePath()
        shackle.move(to: CGPoint(x: sx + 8, y: g.sy + 12))
        shackle.addLine(to: CGPoint(x: sx + 8, y: g.sy + 8.5))
        let arcCentre = CGPoint(x: sx + 11.5, y: g.sy + 8.5)
        for i in 1...12 {
            let a = CGFloat.pi + CGFloat.pi * CGFloat(i) / 12
            shackle.addLine(to: CGPoint(x: arcCentre.x + 3.5 * cos(a), y: arcCentre.y + 3.5 * sin(a)))
        }
        shackle.addLine(to: CGPoint(x: sx + 15, y: g.sy + 12))
        ctx.addPath(shackle)
        ctx.strokePath()
        ctx.stroke(CGRect(x: sx + 6, y: g.sy + 12, width: 11, height: 7))
        ctx.restoreGState()
        Self.drawText("Install helper to set speed", x: sx + 26, baseline: g.sy + 16,
                      font: Palette.Font.sans(11.5), color: HardwareStyle.dim)
    }

    // MARK: - Speed control: the mouse

    /// What a press at a point in layout units landed on, among the fan speed controls.
    private enum FanControlHit {
        case track(FanSliderGeometry, FanReading)
        case chip(Int)
        case installPrompt
    }

    private func fanControlHit(atLayoutPoint p: HWPoint) -> FanControlHit? {
        guard let readings = readings, readings.fansMeasured else { return nil }
        let point = CGPoint(x: p.x, y: p.y)
        for component in hardwareLayout.components {
            guard let index = fanIndex(of: component),
                  let reading = readings.fans.first(where: { $0.index == index }),
                  let g = fanSliderGeometry(for: component) else { continue }
            if readings.helperInstalled {
                if g.chip.contains(point) { return .chip(index) }
                if g.trackHit.contains(point) { return .track(g, reading) }
            } else if g.prompt.contains(point) {
                return .installPrompt
            }
        }
        return nil
    }

    /// A press on a fan's speed control. Returns true when it was one (the canvas then does nothing else with the click): a press
    /// on the track starts a drag, a press on the chip releases that fan to automatic, a press on the install prompt asks for the
    /// helper. Nothing is sent while a drag is going on.
    func fanControlMouseDown(atLayoutPoint p: HWPoint) -> Bool {
        // A press starts from nothing: a drag left over from a button-up that never arrived must not carry into this one.
        dragFanIndex = nil
        dragRPM = nil
        guard let hit = fanControlHit(atLayoutPoint: p) else { return false }
        switch hit {
        case .track(let g, let reading):
            dragFanIndex = g.index
            dragRPM = g.rpm(atLayoutX: CGFloat(p.x), minRPM: reading.minRPM, maxRPM: reading.maxRPM)
            needsDisplay = true
        case .chip(let index):
            onFanSlider?(index, nil)
        case .installPrompt:
            onInstallHelper?()
        }
        return true
    }

    /// The pointer moved with the button down. True while a speed drag is going: the thumb follows, clamped to the track.
    func fanControlMouseDragged(atLayoutPoint p: HWPoint) -> Bool {
        guard let index = dragFanIndex else { return false }
        guard let reading = readings?.fans.first(where: { $0.index == index }),
              let component = hardwareLayout.components.first(where: { fanIndex(of: $0) == index }),
              let g = fanSliderGeometry(for: component) else {
            cancelFanDrag()
            return true
        }
        dragRPM = g.rpm(atLayoutX: CGFloat(p.x), minRPM: reading.minRPM, maxRPM: reading.maxRPM)
        needsDisplay = true
        return true
    }

    /// The button came up. True when a speed drag ends: the one speed it chose is sent, once.
    func fanControlMouseUp() -> Bool {
        guard let index = dragFanIndex else { return false }
        let rpm = dragRPM
        cancelFanDrag()
        if let rpm = rpm { onFanSlider?(index, rpm) }
        return true
    }

    private func cancelFanDrag() {
        dragFanIndex = nil
        dragRPM = nil
        needsDisplay = true
    }
}

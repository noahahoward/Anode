import AppKit
import PowerKit

// ── Hardware View: the display, drawn as a macOS desktop ────────────────────
//
// The display component is not a box with a number: it is a small macOS desktop. A wallpaper (radial gradients, no blur),
// the menu bar with the notch and camera, Anode's own menu bar widgets beside the notch, the system items (Wi-Fi, battery,
// clock), and Anode's display readout as a glass widget at the bottom right. Brightness really dims the picture.
//
// Everything is transcribed from the approved mockup (docs/superpowers/hardware-view-assets/mockup-source.html:
// `DRAW.display`, `menuWidget()`, `#wallpaper`) in the layout's own units (y down), relative to the display component's
// rectangle, so the picture follows the rectangle wherever a layout puts it (every layout has it at 58, 26, 984 x 398).

/// What one of Anode's real menu bar widgets shows: the small label above the value (a widget with no label shows the value
/// alone). Task 9's controller fills `HardwareCanvasView.menuBarWidgets` with these from the owner's configured set.
struct MenuBarWidgetText: Equatable {
    var label: String?
    var value: String
}

/// The desktop's colours that have no twin in `HardwareStyle`. Literals from the mockup (a fixed picture of a screen, not
/// something that follows the app's appearance).
private enum DesktopStyle {
    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }
    static func white(_ alpha: CGFloat = 1) -> NSColor { NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }
    static func black(_ alpha: CGFloat) -> NSColor { NSColor(srgbRed: 0, green: 0, blue: 0, alpha: alpha) }

    // #wallpaper
    static let wallpaperBase: [(NSColor, CGFloat)] = [(rgb(0x0A1030), 0), (rgb(0x16256A), 0.55), (rgb(0x34196B), 1)]
    /// The four glows: centre x, centre y, radius x, radius y (in the mockup's absolute units for a screen at 58, 26),
    /// colour, and the opacity at the centre (it fades to nothing at the edge).
    static let glows: [(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, color: UInt32, alpha: CGFloat)] = [
        (170, 400, 380, 220, 0x2F7DFF, 0.85),
        (760, 90, 420, 190, 0xA24BFF, 0.75),
        (520, 330, 320, 140, 0x00C8D6, 0.50),
        (980, 360, 280, 180, 0xFF5FA8, 0.55)
    ]
    static let ribbonStops: [(NSColor, CGFloat)] = [(rgb(0x7FD6FF, 0), 0), (rgb(0x9FB4FF, 0.55), 0.45), (rgb(0xFF8AD0, 0.1), 1)]

    static let menuBarTint = rgb(0x0C0E16, 0.42)
    static let notch = rgb(0x020304)
    static let cameraFill = rgb(0x12171D)
    static let cameraStroke = white(0.12)

    // the glass widget
    static let glassStroke = white(0.20)
    static let sliderTrack = white(0.20)
    static let sliderFill = rgb(0xF1F4F8)
    static let sliderKnob = rgb(0xF4F7FB)
    static let sliderKnobStroke = black(0.4)
    static let exampleChip = rgb(0x9FB0C8)
    static let exampleInk = rgb(0x101826)
}

// ── Drawing ─────────────────────────────────────────────────────────────────

extension HardwareCanvasView {

    /// The menu bar's height in layout units.
    private static let menuBarHeight: CGFloat = 24

    /// Cached: building a DateFormatter is expensive, and the canvas repaints on every reading. Main thread only (draw).
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE h:mm a"
        // Follow the Mac's own language, region and time zone, including a change made while Anode runs.
        f.locale = .autoupdatingCurrent
        f.timeZone = .autoupdatingCurrent
        return f
    }()

    /// The clock as the macOS menu bar writes it, for example "Sun 2:41 PM". With no `locale` and no `timeZone` (what the app
    /// passes) it uses the cached formatter, which follows the Mac's settings; a test passes both to get a fixed answer.
    static func clockText(_ date: Date = Date(), locale: Locale? = nil, timeZone: TimeZone? = nil) -> String {
        if locale == nil && timeZone == nil { return clockFormatter.string(from: date) }
        let f = DateFormatter()
        f.dateFormat = "EEE h:mm a"
        f.locale = locale ?? .autoupdatingCurrent
        f.timeZone = timeZone ?? .autoupdatingCurrent
        return f.string(from: date)
    }

    /// How wide the mockup makes a menu bar widget: at least 24, otherwise the wider of the label (4.0 per character) and the
    /// value (5.9 per character) plus 5.
    static func menuWidgetWidth(_ widget: MenuBarWidgetText) -> CGFloat {
        let labelWidth = CGFloat(widget.label?.count ?? 0) * 4.0
        let valueWidth = CGFloat(widget.value.count) * 5.9
        return max(24, max(labelWidth, valueWidth) + 5)
    }

    /// The display component: wallpaper, menu bar, notch, Anode's widgets and the system items, and (when there is a display
    /// reading) the glass readout widget. Called by the component drawers for the `.display` component. A missing display
    /// reading draws the screen without the widget and without a power figure, never a zero.
    func drawDesktop(in ctx: CGContext, scale: CGFloat, component: HardwareComponent) {
        guard let r = component.rect, r.w > 0, r.h > 0 else { return }
        let screen = CGRect(x: r.x, y: r.y, width: r.w, height: r.h)
        let display = readings?.display

        // Picture: wallpaper, then the brightness dimming, then the menu bar's tint, all clipped to the screen's rounded corners.
        ctx.saveGState()
        ctx.addPath(Self.roundedPath(screen, radius: 10))
        ctx.clip()
        Self.drawWallpaper(in: ctx, screen: screen)
        if let brightness = display?.brightness, brightness.isFinite {
            let dim = (1 - CGFloat(min(max(brightness, 0), 1))) * 0.5
            if dim > 0 {
                ctx.setFillColor(DesktopStyle.black(dim).cgColor)
                ctx.fill(screen)
            }
        }
        ctx.setFillColor(DesktopStyle.menuBarTint.cgColor)
        ctx.fill(CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: Self.menuBarHeight))
        ctx.restoreGState()

        Self.drawNotch(in: ctx, screen: screen)
        drawMenuBar(in: ctx, screen: screen)
        if let display = display {
            drawGlassWidget(in: ctx, screen: screen, display: display)
        }
    }

    // MARK: - Wallpaper

    /// The mockup's `#wallpaper`: a diagonal base, four radial glows and two soft ribbons. Positions are the mockup's, moved
    /// by however far this screen sits from its 58, 26.
    private static func drawWallpaper(in ctx: CGContext, screen: CGRect) {
        let ox = screen.minX - 58
        let oy = screen.minY - 26

        // The base runs corner to corner of the screen's box (SVG objectBoundingBox: 0,0 to 1,1 in the box's own units).
        if let g = gradient(DesktopStyle.wallpaperBase) {
            ctx.saveGState()
            ctx.translateBy(x: screen.minX, y: screen.minY)
            ctx.scaleBy(x: screen.width, y: screen.height)
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 1, y: 1),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }

        // Each glow is an ellipse filled by a radial gradient that fades to nothing at its edge.
        for glow in DesktopStyle.glows {
            let colour = DesktopStyle.rgb(glow.color)
            guard let g = gradient([(colour.withAlphaComponent(glow.alpha), 0), (colour.withAlphaComponent(0), 1)]) else { continue }
            ctx.saveGState()
            ctx.translateBy(x: glow.cx + ox, y: glow.cy + oy)
            ctx.scaleBy(x: glow.rx, y: glow.ry)
            ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
            ctx.restoreGState()
        }

        // Two ribbons: wide round strokes filled by a gradient that runs left to right along each ribbon's own extent.
        let ribbon1 = CGMutablePath()
        ribbon1.move(to: CGPoint(x: 40 + ox, y: 330 + oy))
        ribbon1.addCurve(to: CGPoint(x: 640 + ox, y: 250 + oy),
                         control1: CGPoint(x: 260 + ox, y: 190 + oy), control2: CGPoint(x: 430 + ox, y: 410 + oy))
        // "S 960 120, 1060 210": the first control point is the previous one reflected through the join (850, 90).
        ribbon1.addCurve(to: CGPoint(x: 1060 + ox, y: 210 + oy),
                         control1: CGPoint(x: 850 + ox, y: 90 + oy), control2: CGPoint(x: 960 + ox, y: 120 + oy))
        drawRibbon(in: ctx, path: ribbon1, width: 64, opacity: 0.4, fromX: 40 + ox, toX: 1060 + ox)

        let ribbon2 = CGMutablePath()
        ribbon2.move(to: CGPoint(x: 40 + ox, y: 410 + oy))
        ribbon2.addCurve(to: CGPoint(x: 700 + ox, y: 340 + oy),
                         control1: CGPoint(x: 300 + ox, y: 300 + oy), control2: CGPoint(x: 480 + ox, y: 470 + oy))
        // "S 990 250, 1070 320": reflected first control point (920, 210).
        ribbon2.addCurve(to: CGPoint(x: 1070 + ox, y: 320 + oy),
                         control1: CGPoint(x: 920 + ox, y: 210 + oy), control2: CGPoint(x: 990 + ox, y: 250 + oy))
        drawRibbon(in: ctx, path: ribbon2, width: 36, opacity: 0.35, fromX: 40 + ox, toX: 1070 + ox)
    }

    private static func drawRibbon(in ctx: CGContext, path: CGPath, width: CGFloat, opacity: CGFloat, fromX: CGFloat, toX: CGFloat) {
        guard let g = gradient(DesktopStyle.ribbonStops) else { return }
        ctx.saveGState()
        ctx.setAlpha(opacity)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.addPath(path)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(g, start: CGPoint(x: fromX, y: 0), end: CGPoint(x: toX, y: 0),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    // MARK: - Notch

    /// The notch (160 wide, 24 tall, rounded at the bottom corners, centred on the screen) and the camera in it.
    private static func drawNotch(in ctx: CGContext, screen: CGRect) {
        let left = screen.midX - 80
        let right = screen.midX + 80
        let top = screen.minY
        let path = CGMutablePath()
        path.move(to: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: top + 10))
        path.addArc(tangent1End: CGPoint(x: right, y: top + 24), tangent2End: CGPoint(x: right - 14, y: top + 24), radius: 14)
        path.addLine(to: CGPoint(x: left + 14, y: top + 24))
        path.addArc(tangent1End: CGPoint(x: left, y: top + 24), tangent2End: CGPoint(x: left, y: top + 10), radius: 14)
        path.closeSubpath()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(DesktopStyle.notch.cgColor)
        ctx.fillPath()
        let camera = CGRect(x: screen.midX - 3.4, y: top + 12 - 3.4, width: 6.8, height: 6.8)
        ctx.setFillColor(DesktopStyle.cameraFill.cgColor)
        ctx.fillEllipse(in: camera)
        ctx.setStrokeColor(DesktopStyle.cameraStroke.cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: camera)
        ctx.restoreGState()
    }

    // MARK: - Menu bar

    /// Left of the notch: the Apple logo, "Anode" in bold and its menus. Right of it: Anode's widgets, Anode's glyph, then
    /// the system items (Wi-Fi, battery when there is one, the clock).
    private func drawMenuBar(in ctx: CGContext, screen: CGRect) {
        let x = screen.minX
        let w = screen.width
        let mb = screen.minY
        let white = DesktopStyle.white()
        let menuFont = Palette.Font.sans(10.5, .medium)

        // Apple logo: the 24-unit glyph scaled to .55.
        if let logo = HardwareStyle.appleLogo {
            ctx.saveGState()
            ctx.translateBy(x: x + 14, y: mb + 5.5)
            ctx.scaleBy(x: 0.55, y: 0.55)
            ctx.addPath(Self.cgPath(from: logo))
            ctx.setFillColor(white.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        Self.drawText("Anode", x: x + 36, baseline: mb + 16, font: Palette.Font.sans(10.5, .bold), color: white)
        for (name, dx) in [("File", 84), ("Edit", 112), ("View", 140), ("Window", 172), ("Help", 216)] as [(String, CGFloat)] {
            Self.drawText(name, x: x + dx, baseline: mb + 16, font: menuFont, color: DesktopStyle.white(0.9))
        }

        // Anode's widgets, from the notch's right edge plus 12 (the mockup's x 642).
        var wx = screen.midX + 92
        for widget in menuBarWidgets {
            let ww = Self.menuWidgetWidth(widget)
            // The system items own the right end, and Anode's own glyph (about 20 units) follows the last widget: a widget that
            // would reach them is not drawn (nor any after it).
            if wx + ww > x + w - 170 { break }
            drawMenuWidget(widget, centreX: wx + ww / 2, top: mb)
            wx += ww + 3
        }
        drawAnodeGlyph(in: ctx, x: wx + 4, top: mb)

        // System items, right-aligned. The clock is the real time.
        Self.drawText(Self.clockText(), x: x + w - 14, baseline: mb + 16, font: menuFont, color: white, align: .right)
        if let battery = readings?.battery {
            drawBatteryIcon(in: ctx, x: x + w - 108, top: mb, percent: battery.percent)
        }
        drawWiFiIcon(in: ctx, x: x + w - 138, top: mb)
    }

    /// One widget as `WidgetRenderer.textImage` draws it: the label small above, the value in 10.5 semibold digits; a widget
    /// with no label is the value alone in 12. White, because the menu bar is dark here.
    private func drawMenuWidget(_ widget: MenuBarWidgetText, centreX: CGFloat, top: CGFloat) {
        if let label = widget.label {
            Self.drawText(label, x: centreX, baseline: top + 10, font: Palette.Font.sans(8, .medium),
                          color: DesktopStyle.white(0.72), align: .center, kern: 0.16)
            Self.drawText(widget.value, x: centreX, baseline: top + 20.5, font: Palette.Font.mono(10.5, .semibold),
                          color: DesktopStyle.white(), align: .center)
        } else {
            Self.drawText(widget.value, x: centreX, baseline: top + 16, font: Palette.Font.mono(12, .semibold),
                          color: DesktopStyle.white(), align: .center)
        }
    }

    /// Anode's own mark: three ascending bars on a plinth (as `WidgetRenderer.groupImage`, small).
    private func drawAnodeGlyph(in ctx: CGContext, x gx: CGFloat, top mb: CGFloat) {
        ctx.saveGState()
        ctx.setFillColor(DesktopStyle.white().cgColor)
        ctx.fill(CGRect(x: gx, y: mb + 14, width: 2.6, height: 5))
        ctx.fill(CGRect(x: gx + 4, y: mb + 11, width: 2.6, height: 8))
        ctx.fill(CGRect(x: gx + 8, y: mb + 7.5, width: 2.6, height: 11.5))
        ctx.addPath(Self.roundedPath(CGRect(x: gx - 1, y: mb + 19.5, width: 13.5, height: 1.6), radius: 0.6))
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// The battery icon: an outline, a fill 16 wide at 100 %, and the cap.
    private func drawBatteryIcon(in ctx: CGContext, x bx: CGFloat, top mb: CGFloat, percent: Int) {
        let fraction = CGFloat(min(max(percent, 0), 100)) / 100
        ctx.saveGState()
        ctx.addPath(Self.roundedPath(CGRect(x: bx, y: mb + 8.5, width: 18, height: 8.5), radius: 2.4))
        ctx.setStrokeColor(DesktopStyle.white(0.85).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        if fraction > 0 {
            ctx.addPath(Self.roundedPath(CGRect(x: bx + 1.5, y: mb + 10, width: 16 * fraction, height: 5.5), radius: 1.2))
            ctx.setFillColor(DesktopStyle.white().cgColor)
            ctx.fillPath()
        }
        ctx.addPath(Self.roundedPath(CGRect(x: bx + 18.8, y: mb + 11, width: 1.6, height: 3.5), radius: 0.7))
        ctx.setFillColor(DesktopStyle.white(0.85).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// The Wi-Fi mark: two arcs over a dot.
    private func drawWiFiIcon(in ctx: CGContext, x wx: CGFloat, top mb: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(DesktopStyle.white().cgColor)
        ctx.setLineWidth(1.3)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        // The mockup's SVG arcs "a7 7 0 0 1 11 0" and "a3.7 3.7 0 0 1 6.6 0": the short way over the top between two points
        // on one level, left to right.
        Self.strokeRainbow(in: ctx, startX: wx, y: mb + 10.5, chord: 11, radius: 7)
        Self.strokeRainbow(in: ctx, startX: wx + 2.2, y: mb + 13.2, chord: 6.6, radius: 3.7)
        ctx.setFillColor(DesktopStyle.white().cgColor)
        ctx.fillEllipse(in: CGRect(x: wx + 5.5 - 1.1, y: mb + 16 - 1.1, width: 2.2, height: 2.2))
        ctx.restoreGState()
    }

    /// An arc through (startX, y) and (startX + chord, y) that bulges upward (smaller y). Drawn as a polyline of short steps,
    /// so it does not depend on how a flipped context reads "clockwise".
    private static func strokeRainbow(in ctx: CGContext, startX: CGFloat, y: CGFloat, chord: CGFloat, radius: CGFloat) {
        let half = chord / 2
        let drop = max(radius * radius - half * half, 0).squareRoot()
        let centre = CGPoint(x: startX + half, y: y + drop)
        let a0 = atan2(y - centre.y, -half)
        let a1 = atan2(y - centre.y, half)
        let steps = 24
        let path = CGMutablePath()
        for i in 0...steps {
            let a = a0 + (a1 - a0) * CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: centre.x + radius * cos(a), y: centre.y + radius * sin(a))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        ctx.addPath(path)
        ctx.strokePath()
    }

    // MARK: - Glass widget

    /// Anode's display readout as a glass desktop widget at the screen's bottom right: the power, a brightness slider, and the
    /// power graph since the window opened. Not dimmed by the brightness.
    private func drawGlassWidget(in ctx: CGContext, screen: CGRect, display: DisplayReading) {
        let hx = screen.minX + screen.width - 436
        let hy = screen.minY + screen.height - 206
        let hw: CGFloat = 424
        let hh: CGFloat = 194
        Self.plate(in: ctx, rect: CGRect(x: hx, y: hy, width: hw, height: hh), radius: 16, alpha: 0.62,
                   stroke: DesktopStyle.glassStroke)

        let labelFont = HardwareStyle.label(10.5)
        let labelKern: CGFloat = 1.47   // .14em of 10.5
        Self.drawText("DISPLAY", x: hx + 20, baseline: hy + 26, font: labelFont, color: HardwareStyle.dim, kern: labelKern)

        // Power: a big number and its unit, with where it came from under it. A missing reading is "—", with no unit.
        let numberFont = Palette.Font.mono(42, .semibold)
        if let watts = display.watts.value {
            let text = String(format: "%.2f", watts)
            Self.drawText(text, x: hx + 20, baseline: hy + 74, font: numberFont, color: HardwareStyle.ink)
            let width = NSAttributedString(string: text, attributes: [.font: numberFont]).size().width
            Self.drawText("W", x: hx + 20 + width + 4, baseline: hy + 74, font: Palette.Font.sans(17), color: HardwareStyle.dim)
        } else {
            Self.drawText("—", x: hx + 20, baseline: hy + 74, font: numberFont, color: HardwareStyle.ink)
        }
        // Where the number came from goes under it; with no number there is nothing to say a source for.
        if display.watts.value != nil {
            let provenance: String
            switch display.watts.provenance {
            case .real: provenance = "measured"
            case .estimate: provenance = "≈ estimated"
            case .example: provenance = "example"
            }
            Self.drawText(provenance, x: hx + 20, baseline: hy + 94, font: Palette.Font.sans(12), color: HardwareStyle.dim)
        }

        // Brightness: a slider and the percentage. No reading draws the empty track and "—".
        let sx = hx + 20
        let sy = hy + 138
        let sw: CGFloat = 150
        Self.drawText("BRIGHTNESS", x: sx, baseline: sy - 14, font: labelFont, color: HardwareStyle.dim, kern: labelKern)
        var level: CGFloat? = nil
        if let b = display.brightness, b.isFinite { level = CGFloat(min(max(b, 0), 1)) }
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineWidth(5)
        ctx.setStrokeColor(DesktopStyle.sliderTrack.cgColor)
        ctx.move(to: CGPoint(x: sx, y: sy))
        ctx.addLine(to: CGPoint(x: sx + sw, y: sy))
        ctx.strokePath()
        if let level = level {
            ctx.setStrokeColor(DesktopStyle.sliderFill.cgColor)
            ctx.move(to: CGPoint(x: sx, y: sy))
            ctx.addLine(to: CGPoint(x: sx + sw * level, y: sy))
            ctx.strokePath()
            let knob = CGRect(x: sx + sw * level - 8, y: sy - 8, width: 16, height: 16)
            ctx.setFillColor(DesktopStyle.sliderKnob.cgColor)
            ctx.fillEllipse(in: knob)
            ctx.setStrokeColor(DesktopStyle.sliderKnobStroke.cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: knob)
        }
        ctx.restoreGState()
        let percentText = level.map { "\(Int(($0 * 100).rounded())) %" } ?? "—"
        Self.drawText(percentText, x: sx + sw + 16, baseline: sy + 5, font: Palette.Font.mono(14, .semibold), color: HardwareStyle.ink)
        if display.watts.provenance == .example {
            let chip = CGRect(x: sx, y: sy + 16, width: 58, height: 15)
            Self.fillRounded(in: ctx, rect: chip, radius: 4, fill: DesktopStyle.exampleChip, stroke: nil)
            Self.drawText("EXAMPLE", x: sx + 29, baseline: sy + 27, font: Palette.Font.mono(8.5, .semibold),
                          color: DesktopStyle.exampleInk, align: .center, kern: 0.68)
        }

        // Power since the window opened.
        let gx = hx + 230
        let gy = hy + 40
        let gw: CGFloat = 176
        let gh: CGFloat = 112
        Self.drawText("POWER · SINCE OPENED", x: gx, baseline: hy + 26, font: labelFont, color: HardwareStyle.dim, kern: labelKern)
        let series = history?.series(.displayWatts) ?? []
        let top = (series.compactMap { $0 }.max() ?? 0) * 1.25
        if series.contains(where: { $0 != nil }) {
            Self.drawSpark(in: ctx, rect: CGRect(x: gx, y: gy, width: gw, height: gh), values: series,
                           color: HardwareStyle.cyan, low: 0, high: top, lineWidth: 1.8)
            Self.drawText(String(format: "%.2f", top) + " W max", x: gx + gw, baseline: gy + gh + 16,
                          font: HardwareStyle.label(10), color: HardwareStyle.faint, align: .right)
        }
    }

    /// The mockup's `spark(...)` with the grid on: three faint horizontal lines, the line with its soft area under it (a break
    /// where a reading was missing), and a dot with a halo on the last value.
    private static func drawSpark(in ctx: CGContext, rect: CGRect, values: [Double?], color: NSColor,
                                  low: Double, high: Double, lineWidth: CGFloat) {
        guard values.contains(where: { $0 != nil }) else { return }
        let range = (high - low) != 0 ? (high - low) : 1
        let steps = CGFloat(max(values.count - 1, 1))
        func px(_ i: Int) -> CGFloat { rect.minX + CGFloat(i) / steps * rect.width }
        func py(_ v: Double) -> CGFloat { rect.minY + rect.height - CGFloat((v - low) / range) * rect.height }

        ctx.saveGState()
        ctx.setStrokeColor(DesktopStyle.white(0.07).cgColor)
        ctx.setLineWidth(1)
        for k in [0.0, 0.5, 1.0] {
            let y = rect.minY + rect.height * CGFloat(k)
            ctx.move(to: CGPoint(x: rect.minX, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
            ctx.strokePath()
        }

        // Runs of consecutive readings.
        var runs: [[CGPoint]] = []
        var current: [CGPoint] = []
        for (i, value) in values.enumerated() {
            if let v = value, v.isFinite {
                current.append(CGPoint(x: px(i), y: py(v)))
            } else {
                if !current.isEmpty { runs.append(current) }
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }

        for run in runs where run.count > 1 {
            let area = CGMutablePath()
            area.move(to: run[0])
            for p in run.dropFirst() { area.addLine(to: p) }
            area.addLine(to: CGPoint(x: run[run.count - 1].x, y: rect.maxY))
            area.addLine(to: CGPoint(x: run[0].x, y: rect.maxY))
            area.closeSubpath()
            ctx.addPath(area)
            ctx.setFillColor(color.withAlphaComponent(0.16).cgColor)
            ctx.fillPath()

            let line = CGMutablePath()
            line.move(to: run[0])
            for p in run.dropFirst() { line.addLine(to: p) }
            ctx.addPath(line)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(lineWidth)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.strokePath()
        }

        if let last = runs.last?.last {
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6))
            ctx.setFillColor(color.withAlphaComponent(0.25).cgColor)
            ctx.fillEllipse(in: CGRect(x: last.x - 6, y: last.y - 6, width: 12, height: 12))
        }
        ctx.restoreGState()
    }

    // MARK: - Helpers

    /// A CGPath from an NSBezierPath, built by hand: `NSBezierPath.cgPath` needs macOS 14 and the package targets 13.
    private static func cgPath(from bezier: NSBezierPath) -> CGPath {
        let path = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<bezier.elementCount {
            switch bezier.element(at: i, associatedPoints: &points) {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath:
                path.closeSubpath()
            @unknown default:
                break
            }
        }
        return path
    }
}

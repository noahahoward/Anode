import AppKit
import PowerKit

// ── Hardware View: what the canvas paints ───────────────────────────────────
//
// Everything here draws in the layout's own units: `HardwareCanvasView.draw` has already moved and scaled the context so
// that one unit is one unit of `hardwareLayout.size`. The shapes and numbers are transcribed from the approved mockup
// (docs/superpowers/hardware-view-assets/mockup-source.html: `chassis()`, `DRAW.photo`, `plate()`, `pill()`).
//
// COLOURS. The mockup is one dark palette by choice (a glass-over-photograph look). `Palette` follows the app's light or
// dark appearance, which would turn the ink black on this fixed dark stage, so the stage's colours are literals in the one
// block below, taken from the mockup's CSS tokens. The few that have a Palette twin are noted.

/// The mockup's colours and type, in one place. Internal so the per-component drawers (kept in this same extension) share it.
enum HardwareStyle {
    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }
    private static func white(_ alpha: CGFloat) -> NSColor { NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }

    // CSS tokens (:root)
    static let stageCentre = rgb(0x10141B)
    static let stageEdge = rgb(0x090B0F)
    /// `--ink`. Palette.text is pure white and flips to black in a light appearance, so it is not used here.
    static let ink = rgb(0xE8ECF2)
    /// `--dim` (Palette.dim is a different blue-grey).
    static let dim = rgb(0x8A94A4)
    /// `--faint`.
    static let faint = rgb(0x566070)
    /// `--edge`.
    static let edge = white(0.10)
    /// `--accent` (the same green as Palette.accent in a dark appearance).
    static let accent = rgb(0x00E5A0)
    /// `--cyan`, the hover and pinned ring.
    static let cyan = rgb(0x4FC8E6)
    static let warm = rgb(0xFF9A3D)
    static let hot = rgb(0xFF5A44)

    // chassis()
    static let lidTop = rgb(0x1A1E25)
    static let lidBottom = rgb(0x0D1015)
    static let screen = rgb(0x040506)
    static let hingeTop = rgb(0x2A313B)
    static let hingeBottom = rgb(0x12161C)
    static let baseTop = rgb(0x171B22)
    static let baseBottom = rgb(0x0C0F13)
    static let inner = rgb(0x090B0E)
    static let innerStroke = white(0.05)
    static let deskPlate = rgb(0x0E1218)
    static let deskPlateStroke = rgb(0x1E2733)

    // plate() and the photo
    static let plateFill = rgb(0x07090C)
    static let plateStroke = white(0.14)
    static let photoScrim = rgb(0x030508, 0.30)

    // type
    static func label(_ size: CGFloat) -> NSFont { Palette.Font.mono(size, .medium) }
    static func number(_ size: CGFloat) -> NSFont { Palette.Font.sans(size, .semibold) }

    /// The mockup's Apple menu glyph (a 24 x 24 box). Parsed once; nil only if the string stopped parsing.
    static let appleLogoData = "M12.152 6.896c-.948 0-2.415-1.078-3.96-1.04-2.04.027-3.91 1.183-4.961 3.014-2.117 3.675-.546 9.103 1.519 12.09 1.013 1.454 2.208 3.09 3.792 3.039 1.52-.065 2.09-.987 3.935-.987 1.831 0 2.35.987 3.96.948 1.637-.026 2.676-1.48 3.676-2.948 1.156-1.688 1.636-3.325 1.662-3.415-.039-.013-3.182-1.221-3.22-4.857-.026-3.04 2.48-4.494 2.597-4.559-1.429-2.09-3.623-2.324-4.39-2.376-2-.156-3.675 1.09-4.61 1.09zM15.53 3.83c.843-1.012 1.4-2.427 1.245-3.83-1.207.052-2.662.805-3.532 1.818-.78.896-1.454 2.338-1.273 3.714 1.338.104 2.715-.688 3.559-1.701"
    static let appleLogo: NSBezierPath? = SVGPath.bezier(appleLogoData)

    /// The photo's credit line (drawn under the picture, whenever a picture is).
    static let photoCaption = "STAND-IN PHOTO: INTEL-BASED 16″ MACBOOK PRO (2019) · CC0 · NETHA HUSSAIN, WIKIMEDIA COMMONS · NOT AN APPLE SILICON BOARD"
}

// ── The bundled teardown photo ──────────────────────────────────────────────

/// Finds and holds the teardown photo. Loaded on first use and kept, so a redraw never touches the disk again; a miss is
/// kept too, so a build without the file does not look for it on every frame. Main thread only (it is only called from draw).
enum HardwarePhoto {

    private static var loaded: [String: NSImage] = [:]
    private static var missing: Set<String> = []

    static func image(named name: String) -> NSImage? {
        if let image = loaded[name] { return image }
        if missing.contains(name) { return nil }
        guard let url = url(named: name), let image = NSImage(contentsOf: url) else {
            missing.insert(name)
            return nil
        }
        loaded[name] = image
        return image
    }

    /// The installed bundle's Resources first; a `swift build` binary has none, so walk up from it to the source checkout the
    /// way the Help menu finds its documents.
    static func url(named name: String, bundle: Bundle = .main, fileManager: FileManager = .default) -> URL? {
        if let url = bundle.url(forResource: name, withExtension: "jpg") { return url }
        return Documentation.checkoutURL(for: "Resources/HardwareView/\(name).jpg",
                                         near: bundle.bundleURL,
                                         fileManager: fileManager)
    }
}

// ── Drawing ─────────────────────────────────────────────────────────────────

extension HardwareCanvasView {

    /// The dark ground behind everything: the mockup's `.stage`, an ellipse of lighter blue-black fading to near black.
    /// Drawn in view points, before the layout's transform.
    func drawStage(in ctx: CGContext) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        ctx.setFillColor(HardwareStyle.stageEdge.cgColor)
        ctx.fill(bounds)
        guard let gradient = Self.gradient([(HardwareStyle.stageCentre, 0), (HardwareStyle.stageEdge, 0.7), (HardwareStyle.stageEdge, 1)]) else { return }
        ctx.saveGState()
        ctx.clip(to: bounds)
        ctx.translateBy(x: bounds.midX, y: bounds.minY + bounds.height * 0.4)
        ctx.scaleBy(x: max(bounds.width * 0.75, 1), y: max(bounds.height * 0.55, 1))
        ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
        ctx.restoreGState()
    }

    /// The lid, screen and hinge (and for the drawn laptops and the mini, the base), from the mockup's `chassis()`.
    func drawChassis(in ctx: CGContext) {
        let edge = HardwareStyle.edge
        let inner = HardwareStyle.innerStroke
        func lidAndHinge() {
            Self.fillRounded(in: ctx, rect: CGRect(x: 40, y: 10, width: 1020, height: 430), radius: 26,
                             top: HardwareStyle.lidTop, bottom: HardwareStyle.lidBottom, stroke: edge)
            Self.fillRounded(in: ctx, rect: CGRect(x: 58, y: 26, width: 984, height: 398), radius: 10,
                             fill: HardwareStyle.screen, stroke: inner)
            Self.fillRounded(in: ctx, rect: CGRect(x: 90, y: 440, width: 920, height: 22), radius: 6,
                             top: HardwareStyle.hingeTop, bottom: HardwareStyle.hingeBottom, stroke: nil)
        }
        if hardwareLayout.photoResource != nil {
            lidAndHinge()
            return
        }
        switch hardwareLayout.family {
        case .macBookPro14Base, .macBookNeo:
            lidAndHinge()
            Self.fillRounded(in: ctx, rect: CGRect(x: 40, y: 462, width: 1020, height: 650), radius: 30,
                             top: HardwareStyle.baseTop, bottom: HardwareStyle.baseBottom, stroke: edge)
            Self.fillRounded(in: ctx, rect: CGRect(x: 56, y: 476, width: 988, height: 620), radius: 20,
                             fill: HardwareStyle.inner, stroke: inner)
        case .macMiniM4:
            Self.fillRounded(in: ctx, rect: CGRect(x: 190, y: 30, width: 720, height: 730), radius: 46,
                             top: HardwareStyle.baseTop, bottom: HardwareStyle.baseBottom, stroke: edge)
            Self.fillRounded(in: ctx, rect: CGRect(x: 206, y: 46, width: 688, height: 698), radius: 34,
                             fill: HardwareStyle.inner, stroke: inner)
            Self.fillRounded(in: ctx, rect: CGRect(x: 250, y: 190, width: 600, height: 360), radius: 22,
                             fill: HardwareStyle.deskPlate, stroke: HardwareStyle.deskPlateStroke)
        case .macBookPro14ProMax, .macBookPro16ProMax, .generic:
            // The photo families returned above; an unknown Mac is drawn on the bare stage inside its own dashed frame.
            break
        }
    }

    /// The teardown photograph at `hardwareLayout.photoFrame`, dimmed by the mockup's 30 % scrim and clipped to its rounded corners,
    /// with the credit line under it. With no picture to be found, the frame is a plain dark base and there is no caption.
    func drawPhoto(in ctx: CGContext) {
        guard let name = hardwareLayout.photoResource, let frame = hardwareLayout.photoFrame else { return }
        let rect = CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h)
        guard let image = HardwarePhoto.image(named: name) else {
            Self.fillRounded(in: ctx, rect: rect, radius: 26,
                             top: HardwareStyle.baseTop, bottom: HardwareStyle.baseBottom, stroke: HardwareStyle.edge)
            return
        }
        ctx.saveGState()
        ctx.addPath(Self.roundedPath(rect, radius: 26))
        ctx.clip()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        ctx.setFillColor(HardwareStyle.photoScrim.cgColor)
        ctx.fill(rect)
        ctx.restoreGState()
        ctx.addPath(Self.roundedPath(rect, radius: 26))
        ctx.setStrokeColor(HardwareStyle.edge.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        Self.drawText(HardwareStyle.photoCaption, x: rect.midX, baseline: rect.maxY + 22,
                      font: HardwareStyle.label(10.5), color: HardwareStyle.faint, align: .center, kern: 0.525)
    }

    /// What the narrow window says under the picture of a photo layout: the credit line belongs to the whole drawing and is
    /// not in the part of it a narrow window shows, so the stand-in is named here, in view points, on a small plate at the
    /// bottom of the view. Nothing unless the window is narrow and the photo was found.
    static let narrowPhotoCaption = "STAND-IN PHOTO \u{00B7} NOT AN APPLE SILICON BOARD"

    private static let narrowCaptionFont = HardwareStyle.label(10)
    private static let narrowCaptionKern: CGFloat = 0.5

    /// Where the narrow window's caption plate goes, in view points at the bottom of the bounds; nil when it is not drawn (the
    /// window is not narrow, the layout has no photo, or the photo was not found).
    func narrowPhotoCaptionPlate() -> CGRect? {
        guard isNarrow, let name = hardwareLayout.photoResource, HardwarePhoto.image(named: name) != nil,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let textWidth = NSAttributedString(string: Self.narrowPhotoCaption,
                                           attributes: [.font: Self.narrowCaptionFont, .kern: Self.narrowCaptionKern])
            .size().width
        let width = min(textWidth + 20, max(bounds.width - 8, 0))
        return CGRect(x: bounds.midX - width / 2, y: bounds.maxY - 28, width: width, height: 20)
    }

    func drawNarrowPhotoCaption(in ctx: CGContext) {
        guard let plateRect = narrowPhotoCaptionPlate() else { return }
        Self.plate(in: ctx, rect: plateRect, radius: 10, alpha: 0.84)
        Self.drawText(Self.narrowPhotoCaption, x: plateRect.midX, baseline: plateRect.midY + 3.5,
                      font: Self.narrowCaptionFont, color: HardwareStyle.faint, align: .center, kern: Self.narrowCaptionKern)
    }

    /// The hover and pinned outline, under the component's own drawing like the mockup's `.ring`.
    func drawRings(in ctx: CGContext) {
        for component in hardwareLayout.components {
            let pinned = component.id == pinnedID
            guard pinned || component.id == hoveredID else { continue }
            ctx.saveGState()
            ctx.setStrokeColor(HardwareStyle.cyan.withAlphaComponent(pinned ? 1 : 0.65).cgColor)
            ctx.setLineWidth(pinned ? 2 : 1.5)
            if component.points.count > 2 {
                // A heat pipe: a wide faint stroke along its path.
                let path = CGMutablePath()
                path.move(to: CGPoint(x: component.points[0].x, y: component.points[0].y))
                for p in component.points.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
                ctx.setStrokeColor(HardwareStyle.cyan.withAlphaComponent(pinned ? 0.6 : 0.4).cgColor)
                ctx.setLineWidth(PhotoWarp.straightened.drawingLength(110))
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.addPath(path)
                ctx.strokePath()
            } else if let box = hitRect(of: component) {
                switch component.kind {
                case .fan:
                    ctx.strokeEllipse(in: box)
                default:
                    ctx.addPath(Self.roundedPath(box, radius: 14))
                    ctx.strokePath()
                }
            }
            ctx.restoreGState()
        }
    }

    /// Where the per-kind drawers paint: every component's readout, on top of the chassis, photo and rings, in the layout's
    /// order. A component whose reading is nil draws "—", never a zero. The parts with no reading of their own (board, SoC, speakers,
    /// trackpad, antenna strip, notes) and the power supply are in HardwareChassisDrawing.swift.
    ///
    /// Painted in `drawOrder` (stable, by `drawRank`), so the heat pipe lies over the memory, storage, Wi-Fi, power and battery
    /// cells as in the mockup whatever order the layout lists them in. With `dirty` (the part being repainted, in layout
    /// units) a component whose `cullBox` does not touch it is skipped: a fan-blade frame repaints only the fan rectangles and
    /// runs none of the other drawers. `nil` paints everything.
    func drawComponents(in ctx: CGContext, scale: CGFloat, dirty: CGRect? = nil) {
        for component in drawOrder {
            if let dirty = dirty, let box = cullBox(of: component), !box.intersects(dirty) { continue }
            switch component.kind {
            case .display:
                drawDesktop(in: ctx, scale: scale, component: component)
            case .heatPipe:
                drawHeatPipe(in: ctx, scale: scale, component: component)
            case .fan:
                drawFan(in: ctx, scale: scale, component: component)
            case .memory:
                drawMemory(in: ctx, scale: scale, component: component)
            case .storage:
                drawStorage(in: ctx, scale: scale, component: component)
            case .wifi:
                drawWifi(in: ctx, scale: scale, component: component)
            case .powerIn:
                drawPowerIn(in: ctx, scale: scale, component: component)
            case .battery:
                drawBattery(in: ctx, scale: scale, component: component)
            case .antenna:
                drawAntenna(in: ctx, scale: scale, component: component)
            case .speaker:
                drawSpeaker(in: ctx, scale: scale, component: component)
            case .trackpad:
                drawTrackpad(in: ctx, scale: scale, component: component)
            case .board:
                drawBoard(in: ctx, scale: scale, component: component)
            case .soc:
                drawSoC(in: ctx, scale: scale, component: component)
            case .psu:
                drawPSU(in: ctx, scale: scale, component: component)
            case .note:
                drawNote(in: ctx, scale: scale, component: component)
            }
        }
    }

    /// How far past its own shapes a part's drawing may reach (labels, halos, pills), in layout units.
    static let cullOutset: CGFloat = 40

    /// Everything a component can paint, in layout units: its rectangle, its jump rectangle, its parts and the box around its
    /// points, plus a fan's speed control plate, all pushed out by `cullOutset`. nil for a note, and for a component with no
    /// area at all, which are therefore always painted: a note's rectangle has no size (its words run far outside it), so
    /// its box says nothing about where it paints.
    func cullBox(of component: HardwareComponent) -> CGRect? {
        if case .note = component.kind { return nil }
        var box: CGRect?
        func add(_ r: CGRect) { box = box.map { $0.union(r) } ?? r }
        func addLayout(_ r: HWRect) { add(CGRect(x: r.x, y: r.y, width: r.w, height: r.h)) }
        if let r = component.rect { addLayout(r) }
        if let j = component.jump { addLayout(j) }
        for part in component.parts { addLayout(part.rect) }
        if let first = component.points.first {
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in component.points {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            add(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        }
        if case .fan = component.kind, let geometry = fanSliderGeometry(for: component) { add(geometry.plate) }
        return box?.insetBy(dx: -Self.cullOutset, dy: -Self.cullOutset)
    }

    // MARK: - Shared helpers (used by every per-kind drawer)

    /// The mockup's `plate()`: a dark glass rectangle that lets the picture show through.
    static func plate(in ctx: CGContext,
                      rect: CGRect,
                      radius: CGFloat = 10,
                      alpha: CGFloat = 0.78,
                      stroke: NSColor = HardwareStyle.plateStroke,
                      dash: [CGFloat]? = nil) {
        ctx.saveGState()
        ctx.addPath(roundedPath(rect, radius: radius))
        ctx.setFillColor(HardwareStyle.plateFill.withAlphaComponent(alpha).cgColor)
        ctx.fillPath()
        ctx.addPath(roundedPath(rect, radius: radius))
        ctx.setStrokeColor(stroke.cgColor)
        ctx.setLineWidth(1)
        if let dash = dash { ctx.setLineDash(phase: 0, lengths: dash) }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The mockup's `pill()`: a 96 x 28 plate with a coloured dot, a small name, and the value at the right. `value` is the
    /// text to show; pass "—" for a missing reading.
    static func pill(in ctx: CGContext, center: CGPoint, name: String, value: String, color: NSColor) {
        let w: CGFloat = 96, h: CGFloat = 28
        plate(in: ctx, rect: CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h), radius: 14, alpha: 0.84)
        ctx.saveGState()
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - w / 2 + 14 - 5, y: center.y - 5, width: 10, height: 10))
        ctx.restoreGState()
        drawText(name, x: center.x - w / 2 + 25, baseline: center.y + 3.5,
                 font: HardwareStyle.label(10), color: HardwareStyle.dim, kern: 1.4)
        drawText(value, x: center.x + w / 2 - 12, baseline: center.y + 6,
                 font: HardwareStyle.number(17), color: HardwareStyle.ink, align: .right)
    }

    /// One line of text with its baseline at `baseline` (the mockup's SVG `y`), in a flipped (y down) context.
    static func drawText(_ text: String,
                         x: CGFloat,
                         baseline: CGFloat,
                         font: NSFont,
                         color: NSColor,
                         align: NSTextAlignment = .left,
                         kern: CGFloat = 0) {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if kern != 0 { attributes[.kern] = kern }
        let string = NSAttributedString(string: text, attributes: attributes)
        let width = string.size().width
        let left: CGFloat
        switch align {
        case .center: left = x - width / 2
        case .right: left = x - width
        default: left = x
        }
        string.draw(at: NSPoint(x: left, y: baseline - font.ascender))
    }

    static func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    static func gradient(_ stops: [(NSColor, CGFloat)]) -> CGGradient? {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                   colors: stops.map { $0.0.cgColor } as CFArray,
                   locations: stops.map { $0.1 })
    }

    /// A rounded rectangle filled flat (or top to bottom) with an optional 1-unit outline.
    static func fillRounded(in ctx: CGContext, rect: CGRect, radius: CGFloat,
                            fill: NSColor, stroke: NSColor?) {
        ctx.saveGState()
        ctx.addPath(roundedPath(rect, radius: radius))
        ctx.setFillColor(fill.cgColor)
        ctx.fillPath()
        if let stroke = stroke {
            ctx.addPath(roundedPath(rect, radius: radius))
            ctx.setStrokeColor(stroke.cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    static func fillRounded(in ctx: CGContext, rect: CGRect, radius: CGFloat,
                            top: NSColor, bottom: NSColor, stroke: NSColor?) {
        ctx.saveGState()
        ctx.addPath(roundedPath(rect, radius: radius))
        ctx.clip()
        if let g = gradient([(top, 0), (bottom, 1)]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.minY),
                                   end: CGPoint(x: rect.minX, y: rect.maxY), options: [])
        }
        ctx.restoreGState()
        if let stroke = stroke {
            ctx.saveGState()
            ctx.addPath(roundedPath(rect, radius: radius))
            ctx.setStrokeColor(stroke.cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }
}

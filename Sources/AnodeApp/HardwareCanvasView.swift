import AppKit
import PowerKit

// ── Hardware View: the canvas ───────────────────────────────────────────────
//
// One custom-drawn view for the inside of a Mac. It paints a `HardwareLayout` (drawing units) scaled to fit its bounds,
// answers "which part is under the pointer?", and reports hover and clicks to whoever owns it. It owns no timer and no
// observer: it repaints only when its owner changes something or calls `readingsChanged()`, and then only if the owner says
// it is worth drawing now (`isDrawableNow`, so a hidden or minimised window costs nothing).
//
// What is drawn lives in HardwareCanvasDrawing.swift; this file is the geometry and the mouse.

final class HardwareCanvasView: NSView {

    /// Named `hardwareLayout`, not `layout`: NSView already has a `layout()` method and a property of that name would collide with it.
    var hardwareLayout: HardwareLayout {
        didSet {
            guard hardwareLayout != oldValue else { return }
            drawOrder = Self.drawOrdered(hardwareLayout.components)
            hoveredID = nil
            needsDisplay = true
        }
    }

    /// The layout's components in the order they are painted (see `drawRank`), worked out when the layout changes and not on
    /// every frame. The layout's own data order is not touched: the fans stay where the chips and the tests expect them.
    private(set) var drawOrder: [HardwareComponent] = []

    /// The latest reading. The owner sets it, then calls `readingsChanged()`.
    var readings: HardwareReadings?
    /// The recent series the detail graphs read. Held for the drawers; the canvas itself does not use it.
    var history: HardwareHistory?

    /// What Anode's own menu bar widgets show right now, drawn in the display's menu bar (label above value). The owner of the
    /// canvas fills it; empty draws only Anode's glyph.
    var menuBarWidgets: [MenuBarWidgetText] = [] {
        didSet { if menuBarWidgets != oldValue, isDrawableNow() { needsDisplay = true } }
    }

    /// The battery's charge in percent over the last 24 hours, oldest first (nil = no sample then), for the battery cell that
    /// shows the chart. The owner fills it; empty draws the cell's name only. The scale is fixed at 0...100.
    var chargeHistory: [Double?] = [] {
        didSet { if chargeHistory != oldValue, isDrawableNow() { needsDisplay = true } }
    }

    /// A narrow window shows one part at a time: while `focusRect` is set the canvas shows that part of the layout, at the
    /// window's full width, instead of the whole layout.
    var isNarrow = false {
        didSet { if isNarrow != oldValue { needsDisplay = true } }
    }
    var focusRect: HWRect? {
        didSet { if focusRect != oldValue { needsDisplay = true } }
    }

    /// The id of the part whose detail card is open (it keeps its outline).
    var pinnedID: String? {
        didSet { if pinnedID != oldValue { needsDisplay = true } }
    }
    private(set) var hoveredID: String? {
        didSet { if hoveredID != oldValue { needsDisplay = true } }
    }

    /// The part under the pointer (nil over nothing), and the pointer in this view's coordinates.
    var onHover: ((HardwareComponent?, NSPoint) -> Void)?
    /// A click: the part (nil over nothing), the battery cell's role when the click landed on a battery cell, and the point.
    var onClick: ((HardwareComponent?, String?, NSPoint) -> Void)?

    /// A fan's speed was chosen: the fan's index and the target in rpm, sent once when a drag on its slider ends; nil rpm means
    /// release that fan to automatic (the AUTO / MANUAL chip was clicked).
    var onFanSlider: ((Int, Double?) -> Void)?
    /// The install prompt that replaces the fan sliders (while the helper is not installed) was clicked.
    var onInstallHelper: (() -> Void)?
    /// How far each fan's impeller is turned, in radians, by fan index (a missing entry is 0). The canvas only reads it; whoever
    /// animates the fans sets it and repaints.
    var fanAngles: [Double] = []
    /// A fan speed drag in progress (see HardwareFanPipeDrawing.swift, which owns these two): the fan and the speed under the pointer.
    /// Nothing is sent until the button comes up.
    var dragFanIndex: Int?
    var dragRPM: Double?

    /// The window answers false while it is hidden, minimised or covered, so a reading that arrives then repaints nothing.
    var isDrawableNow: () -> Bool = { true }

    /// The fan animation's state (see HardwareFanBlades.swift, which owns it; stored here because an extension cannot hold
    /// stored properties). `fanClock` is the view `Motion` is given as its client: `Motion` marks its client for a full redraw
    /// on every frame, which would repaint the whole canvas, so the client is this view-less stand-in and the fan areas are
    /// invalidated by hand. `fanAnimationLive` is true while the closure registered with `Motion` is still moving;
    /// `fanAccumulated` is the time gathered towards the next 50 ms step.
    let fanClock = NSView(frame: .zero)
    var fanAnimationLive = false
    var fanAccumulated: TimeInterval = 0

    private var trackingArea: NSTrackingArea?

    init(layout: HardwareLayout) {
        self.hardwareLayout = layout
        self.drawOrder = Self.drawOrdered(layout.components)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("HardwareCanvasView is code-only") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Repaint for a new reading, but only when the owner says the picture can be seen.
    func readingsChanged() {
        refreshFanAnimation()
        if isDrawableNow() { needsDisplay = true }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshFanAnimation()
    }

    // MARK: - Geometry

    /// The part of the layout that fills the view: all of it, or in a narrow window the focused part.
    var visibleLayoutRect: HWRect {
        if isNarrow, let focus = focusRect, focus.w > 0, focus.h > 0 { return focus }
        return hardwareLayout.size
    }

    /// View points per layout unit: the layout fits inside the bounds with its proportions kept.
    var layoutScale: CGFloat {
        let r = visibleLayoutRect
        guard r.w > 0, r.h > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(bounds.width / CGFloat(r.w), bounds.height / CGFloat(r.h))
    }

    /// Where the top left of `visibleLayoutRect` lands in the view (the picture is centred).
    var layoutOffset: NSPoint {
        let r = visibleLayoutRect
        let s = layoutScale
        return NSPoint(x: bounds.minX + (bounds.width - CGFloat(r.w) * s) / 2,
                       y: bounds.minY + (bounds.height - CGFloat(r.h) * s) / 2)
    }

    func layoutPoint(fromView p: NSPoint) -> HWPoint {
        let r = visibleLayoutRect
        let s = layoutScale
        let o = layoutOffset
        return HWPoint(x: r.x + Double((p.x - o.x) / s), y: r.y + Double((p.y - o.y) / s))
    }

    func viewPoint(fromLayout p: HWPoint) -> NSPoint {
        let r = visibleLayoutRect
        let s = layoutScale
        let o = layoutOffset
        return NSPoint(x: o.x + CGFloat(p.x - r.x) * s, y: o.y + CGFloat(p.y - r.y) * s)
    }

    func viewRect(fromLayout rect: HWRect) -> NSRect {
        let origin = viewPoint(fromLayout: HWPoint(x: rect.x, y: rect.y))
        let s = layoutScale
        return NSRect(x: origin.x, y: origin.y, width: CGFloat(rect.w) * s, height: CGFloat(rect.h) * s)
    }

    // MARK: - Hit testing

    /// How far a part's clickable area reaches past its box (the mockup's outline sits 6 units out).
    private static let hitPadding: Double = 6

    /// The part's clickable box in layout units: its own rectangle, padded. Nil for a part with no area (a note).
    func hitRect(of component: HardwareComponent) -> CGRect? {
        guard let r = component.rect, r.w > 0, r.h > 0 else { return nil }
        let pad = Self.hitPadding
        return CGRect(x: r.x - pad, y: r.y - pad, width: r.w + 2 * pad, height: r.h + 2 * pad)
    }

    /// Later draws on top, as the mockup orders its kinds: the board, then the antenna, speakers and trackpad, the SoC, the
    /// fans, every other part, and last the heat pipe and the notes. A click goes to the topmost part.
    static func drawRank(_ kind: HardwareComponentKind) -> Int {
        switch kind {
        case .board: return 1
        case .antenna, .speaker, .trackpad: return 2
        case .soc: return 3
        case .fan: return 4
        case .heatPipe, .note: return 6
        default: return 5
        }
    }

    /// The components sorted by `drawRank`, parts of one rank keeping the layout's order between them.
    static func drawOrdered(_ components: [HardwareComponent]) -> [HardwareComponent] {
        components.enumerated()
            .sorted { a, b in
                let ra = drawRank(a.element.kind), rb = drawRank(b.element.kind)
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map { $0.element }
    }

    private func hitRank(_ kind: HardwareComponentKind) -> Int { Self.drawRank(kind) }

    /// Whether a point in layout units is on the part.
    func contains(_ component: HardwareComponent, layoutPoint p: HWPoint) -> Bool {
        switch component.kind {
        case .board, .note:
            // The generic schematic's frame and a note's words are not something to point at.
            return false
        case .heatPipe where component.points.count > 2:
            let reach = PhotoWarp.straightened.drawingLength(55)
            let pts = component.points
            for i in 1..<pts.count where Self.distance(from: p, toSegment: pts[i - 1], pts[i]) <= reach {
                return true
            }
            return false
        case .fan:
            guard let centre = component.points.first, let r = component.rect else { return false }
            let dx = p.x - centre.x, dy = p.y - centre.y
            let reach = r.w / 2 + Self.hitPadding
            return dx * dx + dy * dy <= reach * reach
        default:
            guard let box = hitRect(of: component) else { return false }
            return box.contains(CGPoint(x: p.x, y: p.y))
        }
    }

    /// The topmost part under a point in layout units; of equal rank, the smaller one (a chip on a board).
    func component(atLayoutPoint p: HWPoint) -> HardwareComponent? {
        var best: HardwareComponent?
        var bestRank = -1
        var bestArea = Double.infinity
        for component in hardwareLayout.components where contains(component, layoutPoint: p) {
            let rank = hitRank(component.kind)
            let area = (component.rect?.w ?? 0) * (component.rect?.h ?? 0)
            if rank > bestRank || (rank == bestRank && area < bestArea) {
                best = component
                bestRank = rank
                bestArea = area
            }
        }
        return best
    }

    func component(atViewPoint p: NSPoint) -> HardwareComponent? {
        component(atLayoutPoint: layoutPoint(fromView: p))
    }

    /// The reading a click on a battery cell asks for. A cell with several readings stacks them top to bottom in the
    /// mockup's proportions (40 %, 28 %, 32 %); a cell with one is that reading.
    func batteryRole(atLayoutPoint p: HWPoint, in component: HardwareComponent) -> String? {
        guard case .battery = component.kind else { return nil }
        for part in component.parts where !part.roles.isEmpty {
            let r = part.rect
            guard p.x >= r.x, p.x <= r.x + r.w, p.y >= r.y, p.y <= r.y + r.h else { continue }
            if part.roles.count == 1 { return part.roles[0] }
            let fractions: [Double] = [0.40, 0.28, 0.32]
            var top = r.y
            for (i, role) in part.roles.enumerated() {
                let height = r.h * (i < fractions.count ? fractions[i] : 0)
                if p.y < top + height || i == part.roles.count - 1 { return role }
                top += height
            }
        }
        return nil
    }

    private static func distance(from p: HWPoint, toSegment a: HWPoint, _ b: HWPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        var t = lengthSquared > 0 ? ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared : 0
        t = max(0, min(1, t))
        let cx = a.x + t * dx, cy = a.y + t * dy
        return ((p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy)).squareRoot()
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let hit = component(atViewPoint: p)
        hoveredID = hit?.id
        onHover?(hit, p)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredID = nil
        onHover?(nil, convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let lp = layoutPoint(fromView: p)
        // A fan's speed control (slider, AUTO / MANUAL chip, install prompt) takes the press before any part does.
        if fanControlMouseDown(atLayoutPoint: lp) {
            onHover?(nil, p)
            return
        }
        let hit = component(atLayoutPoint: lp)
        let role = hit.flatMap { batteryRole(atLayoutPoint: lp, in: $0) }
        onClick?(hit, role, p)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        _ = fanControlMouseDragged(atLayoutPoint: layoutPoint(fromView: p))
    }

    override func mouseUp(with event: NSEvent) {
        _ = fanControlMouseUp()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawStage(in: ctx)
        let r = visibleLayoutRect
        let s = layoutScale
        let o = layoutOffset
        // The part of the view being repainted, in layout units: a repaint of one fan's frame draws only what touches it.
        let cornerA = layoutPoint(fromView: NSPoint(x: dirtyRect.minX, y: dirtyRect.minY))
        let cornerB = layoutPoint(fromView: NSPoint(x: dirtyRect.maxX, y: dirtyRect.maxY))
        let dirty = CGRect(x: min(cornerA.x, cornerB.x), y: min(cornerA.y, cornerB.y),
                           width: abs(cornerB.x - cornerA.x), height: abs(cornerB.y - cornerA.y))
        ctx.saveGState()
        ctx.clip(to: bounds)
        ctx.translateBy(x: o.x, y: o.y)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: CGFloat(-r.x), y: CGFloat(-r.y))
        drawChassis(in: ctx)
        drawPhoto(in: ctx)
        drawRings(in: ctx)
        drawComponents(in: ctx, scale: s, dirty: dirty)
        ctx.restoreGState()
        drawNarrowPhotoCaption(in: ctx)
    }
}

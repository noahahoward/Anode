import AppKit
import ImageIO
import PowerKit

// ── Clipboard History: the panel ────────────────────────────────────────────
//
// Drawn as macOS 27's own ⌘Space panel is (measured on this Mac, 2026-11-19, from window captures of it, a screenshot of it over a
// light and a dark backdrop, and its window's opacity read every few milliseconds): a bar and, under it with a gap, a separate card.
// Both are liquid glass with a black tint over it. The bar's tint is black at the top and half that at the bottom; the card's is
// about half and a fifth. The card's list has chips at the top (here the kinds in the history), then rows 62 points apart with a 36 point
// icon, a 17 point title and a capsule for the selection.
//
// It must not take the front app's place. The panel is a non-activating one, ordered front without Anode becoming the active app
// (`orderFrontRegardless`, never `NSApp.activate`), so the app being pasted into stays in front. It becomes the KEY window, so that
// typing reaches the search field (`canBecomeKey`); and a key window that is ordered out hands "key" on to another window of
// Anode's, which would bring it forward over the app being pasted into, so the controller puts the app in front back (`restoreFront`)
// each time the panel goes.
//
// The keys are taken in `sendEvent`, before the field sees them, so ↑ ↓ ↩ Tab and the ⌘ and ⌥ combinations are not the field's.

/// Every measure in one place, in points. The numbers that say "measured" are read from macOS 27.3's own panel.
enum ClipboardPanelMetrics {
    // The panel
    static let width: CGFloat = 520                  // measured
    static let pillHeight: CGFloat = 87              // measured: the search bar
    static let gap: CGFloat = 10                     // measured: between the bar and the card
    static let cardMaxHeight: CGFloat = 410          // measured
    static let pillRadius: CGFloat = 34              // the bar's corners are nearly, not quite, a capsule
    static let cardRadius: CGFloat = 30
    /// The bar's top edge sits this fraction of the visible screen's height down from its top (measured: 380 of 1169 points on a
    /// screen whose menu bar is 39 points).
    static let topFraction: CGFloat = 0.30

    // The bar
    static let searchFontSize: CGFloat = 21
    static let searchLeft: CGFloat = 39              // measured
    /// A line's box is centred in the bar, and the letters in it sit a little above that: this brings them to the bar's middle.
    static let searchTextDrop: CGFloat = 3
    static let accessorySize: CGFloat = 33           // measured: the picture at the bar's right
    static let accessoryCentreFromRight: CGFloat = 46.5
    /// How far the glass reaches past the shape above and below, where the shape's own clip cuts it off: the glass draws a bright rim
    /// at its edge, and the system's panel has its rims only where the tint puts them. Not at the sides: there the glass bends what
    /// is behind it into a dark band that the system's panel shows as well (measured).
    static let glassBleed: CGFloat = 6

    // The chips
    static let chipsTop: CGFloat = 21                // measured, from the card's top
    static let chipHeight: CGFloat = 25
    static let chipLeft: CGFloat = 20
    static let chipGap: CGFloat = 8.5
    static let chipPadding: CGFloat = 10.5
    static let chipFontSize: CGFloat = 14.5

    // The rows
    static let rowsTop: CGFloat = 61                 // from the card's top: after the chips
    static let rowHeight: CGFloat = 62               // measured
    static let rowInset: CGFloat = 14.5              // measured: the selection's distance from the card's sides
    static let iconSize: CGFloat = 36
    static let iconLeft: CGFloat = 26
    static let titleLeft: CGFloat = 79.5
    static let trailingRight: CGFloat = 26
    static let titleFontSize: CGFloat = 17
    static let detailFontSize: CGFloat = 12
    static let selectionAlpha: CGFloat = 0.07
    static let emptyCardHeight: CGFloat = 96
    static let bottomPadding: CGFloat = 8

    // The shadow, drawn here and not by the window server, whose own is much lighter than the system panel's (measured: beside the
    // bar the backdrop is dimmed by 20% at the edge, beside the card 30%, and the gap between them to 40%).
    static let shadowMargin: CGFloat = 48
    static let shadowOpacity: Float = 0.55
    static let shadowRadius: CGFloat = 24
    static let shadowDrop: CGFloat = 6

    // Appearing and going: the panel's opacity, read every few milliseconds, rose in about 0.11 s and fell in about 0.11 s, evenly.
    static let fadeInDuration: TimeInterval = 0.11
    static let fadeOutDuration: TimeInterval = 0.11

    /// What is laid over the glass, from the top down: (how far down in points, a negative one from the bottom; the grey; the opacity).
    /// MEASURED over a black and white striped backdrop: the clear glass passes about 88% of what is behind it and adds 12% light;
    /// these are what bring the bar to the system's 0% passing at its top and 31% at its bottom, and the card's 36% to 55%, with the
    /// system's added light, plus the rims (the bar's is at its bottom edge only; the card's at both).
    static func tintStops(card: Bool, height: CGFloat) -> [(y: CGFloat, gray: CGFloat, alpha: CGFloat)] {
        if !card {
            let h = max(height, 1)
            let a = { (y: CGFloat) in 1.0 - 0.38 * y / h }       // 1.0 at the top, 0.62 at the bottom
            // the bar's rim is its bottom edge only: a light grey line that reads 0.29 over black and 0.9 over white
            return [(0, 0, a(0)), (-3, 0, a(h - 3)), (-1.2, 0, a(h - 1.2)), (-1.0, 0.75, 0.27), (h, 0.75, 0.27)]
        }
        let h = max(height, 1)
        let along = { (y: CGFloat) in min(1, y / 410) }            // the curve is drawn for the full 410 and cut off where the card ends
        let gray = { (y: CGFloat) in 0.07 + 0.03 * along(y) }
        let alpha = { (y: CGFloat) in 0.60 - 0.23 * along(y) }
        // the top rim: a bright first point (0.43 over black, 0.74 over white), a dimmer second, then the glass
        return [(0, 0.5, 0.55), (1.0, 0.5, 0.55), (1.0, 0.12, 0.45), (2.0, 0.12, 0.45),
                (2.0, gray(2), alpha(2)), (h - 3, gray(h - 3), alpha(h - 3)), (h - 1.2, gray(h - 1.2), alpha(h - 1.2)),
                (h - 1.0, 0.75, 0.27), (h, 0.75, 0.27)]
    }

    /// The card's height for `rows` rows (nil: no card). Pure, for tests.
    static func cardHeight(rows: Int, hasQuery: Bool) -> CGFloat? {
        if rows > 0 { return min(cardMaxHeight, rowsTop + CGFloat(rows) * rowHeight + bottomPadding) }
        return hasQuery ? emptyCardHeight : nil
    }

    /// The whole panel's height: the bar, and under it the card when there is one. Pure, for tests.
    static func panelHeight(card: CGFloat?) -> CGFloat { pillHeight + (card.map { gap + $0 } ?? 0) }
}

/// What a row shows, worked out once when the list is built.
struct ClipboardRowModel {
    let entry: ClipboardEntry
    let title: String
    let subtitle: String
    /// "⌘1" … "⌘9" for the first nine.
    let hint: String?

    static func make(_ entry: ClipboardEntry, index: Int, now: Date = Date()) -> ClipboardRowModel {
        let title = entry.preview.isEmpty ? entry.kind.title : entry.preview
        let subtitle = [entry.detail, entry.sourceName, ClipboardSearch.ago(from: entry.date, to: now)]
            .compactMap { $0 }.joined(separator: " · ")
        return ClipboardRowModel(entry: entry, title: title, subtitle: subtitle, hint: index < 9 ? "⌘\(index + 1)" : nil)
    }
}

// ── The window ──────────────────────────────────────────────────────────────

final class ClipboardPanel: NSPanel, ClipboardPresenting, NSWindowDelegate {

    private weak var controller: ClipboardHistoryController?
    private let content = ClipboardContentView()
    private lazy var host = ClipboardShadowHost(content: content)
    private var monitors: [Any] = []
    private let editor = ClipboardFieldEditor()
    private(set) var shown = false

    var isOpen: Bool { shown }

    init() {
        let m = ClipboardPanelMetrics.shadowMargin
        super.init(contentRect: NSRect(x: 0, y: 0, width: ClipboardPanelMetrics.width + 2 * m, height: ClipboardPanelMetrics.pillHeight + 2 * m),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false          // the shadow is drawn in the window's margin (`ClipboardShadowHost`)
        level = .popUpMenu
        isReleasedWhenClosed = false
        animationBehavior = .none
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        // Always the dark glass, as the system's own panel is: the black tint is part of how it looks.
        appearance = NSAppearance(named: .darkAqua)
        delegate = self
        contentView = host
        content.onLayout = { [weak host] in host?.updateShadow() }
        setAccessibilityIdentifier("dev.anode.clipboardHistory")
        setAccessibilityLabel("Clipboard History")
        content.onResize = { [weak self] height in self?.setHeight(height) }
    }

    /// Typing has to reach the search field.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The search field is edited in a field editor that draws the system panel's caret: a thicker white bar with a glow.
    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        if let field = object as? NSTextField, field === content.field { return editor }
        return super.fieldEditor(createFlag, for: object)
    }

    // ── Showing ─────────────────────────────────────────────────────────────

    func show(controller: ClipboardHistoryController) {
        self.controller = controller
        content.controller = controller
        content.applyLab()
        host.applyLab()
        content.reset()
        place()
        let animated = DisplayAccessibility.current.animates
        let reopened = isVisible        // it was still fading out
        shown = true
        if !reopened { alphaValue = animated ? 0 : 1 }
        orderFrontRegardless()
        makeKey()
        makeFirstResponder(content.field)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = ClipboardPanelMetrics.fadeInDuration
                context.timingFunction = CAMediaTimingFunction(name: .linear)
                animator().alphaValue = 1
            }
        } else {
            alphaValue = 1
        }
        // A click on anything else, in any other app, closes it; so does another window taking the key.
        if let click = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            self?.dismissFromPanel()
        }) { monitors.append(click) }
    }

    func refresh() {
        guard shown else { return }
        content.reload(keepingSelection: true)
    }

    func hide(completion: @escaping () -> Void) {
        guard shown else { completion(); return }
        shown = false
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        guard DisplayAccessibility.current.animates else {
            orderOut(nil)
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = ClipboardPanelMetrics.fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .linear)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Opened again while it faded: it stays, and the fade-in has taken over.
            if let self, !self.shown { self.orderOut(nil); self.alphaValue = 1 }
            completion()
        })
    }

    private func dismissFromPanel() {
        guard shown else { return }
        controller?.dismiss()
    }

    func windowDidResignKey(_ notification: Notification) {
        // The paste itself puts the panel away first; this is the panel losing the key to something else.
        dismissFromPanel()
    }

    // ── Where it sits ───────────────────────────────────────────────────────

    /// The screen the pointer is on, or the main one.
    private func targetScreen() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Horizontally centred on the screen, the top edge a third of the way down. Pure, for tests.
    static func frame(height: CGFloat, in visible: NSRect) -> NSRect {
        let top = visible.maxY - visible.height * ClipboardPanelMetrics.topFraction
        return NSRect(x: visible.midX - ClipboardPanelMetrics.width / 2, y: top - height, width: ClipboardPanelMetrics.width, height: height)
    }

    /// The window is the panel and a margin all round for its shadow: the panel's own rectangle is `frame(height:in:)`.
    static func windowFrame(forPanel panel: NSRect) -> NSRect {
        let m = ClipboardPanelMetrics.shadowMargin
        return panel.insetBy(dx: -m, dy: -m)
    }

    private func place() {
        guard let screen = targetScreen() else { return }
        let height = frame.height - 2 * ClipboardPanelMetrics.shadowMargin
        setFrame(Self.windowFrame(forPanel: Self.frame(height: height, in: screen.visibleFrame)), display: false)
    }

    /// The panel's top edge stays where it is when the list grows or shrinks.
    private func setHeight(_ height: CGFloat) {
        let m = ClipboardPanelMetrics.shadowMargin
        guard abs(frame.height - 2 * m - height) > 0.5 else { return }
        let top = frame.maxY - m
        setFrame(Self.windowFrame(forPanel: NSRect(x: frame.minX + m, y: top - height, width: frame.width - 2 * m, height: height)), display: true)
    }

    // ── Keys ────────────────────────────────────────────────────────────────

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handle(event) { return }
        super.sendEvent(event)
    }

    /// What a key does, or nil when it is for the search field. Pure, for tests.
    enum KeyAction: Equatable {
        case move(Int)
        case choose(ClipboardHistoryController.PasteMode)
        case chooseRow(Int)
        case delete
        case pin
        case cycleFilter(Int)
        case escape
    }

    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) -> KeyAction? {
        let mods = modifiers.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        switch keyCode {
        case 126 where mods.isEmpty: return .move(-1)
        case 125 where mods.isEmpty: return .move(1)
        case 116 where mods.isEmpty: return .move(-5)
        case 121 where mods.isEmpty: return .move(5)
        case 48 where mods.isEmpty: return .cycleFilter(1)
        case 48 where mods == .shift: return .cycleFilter(-1)
        case 36, 76:
            if mods.isEmpty { return .choose(.paste) }
            if mods == .command { return .choose(.copyOnly) }
            if mods == .option || mods == .shift { return .choose(.plainText) }
            return nil
        case 53 where mods.isEmpty: return .escape
        case 51 where mods == .command: return .delete
        case 35 where mods == .command: return .pin
        default:
            if mods == .command, let c = characters, c.count == 1, let n = Int(c), (1...9).contains(n) { return .chooseRow(n - 1) }
            return nil
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        // A word being composed (an input method) is the field's: its keys are not ours.
        if let editor = firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        guard let action = Self.action(keyCode: event.keyCode, modifiers: event.modifierFlags, characters: event.charactersIgnoringModifiers)
        else { return false }
        switch action {
        case .move(let by): content.moveSelection(by)
        case .choose(let mode): if let id = content.selectedEntry?.id { controller?.choose(id, mode: mode) }
        case .chooseRow(let row): if let id = content.entry(atRow: row)?.id { controller?.choose(id, mode: .paste) }
        case .delete: if let id = content.selectedEntry?.id { controller?.delete(id) }
        case .pin: if let id = content.selectedEntry?.id { controller?.togglePin(id) }
        case .cycleFilter(let by): content.cycleFilter(by)
        case .escape:
            // The first Escape clears what was typed (or the chip), the second closes: as Spotlight does.
            if content.hasQuery || content.filter != nil { content.clearQuery() } else { controller?.dismiss() }
        }
        return true
    }
}

// ── The shadow ──────────────────────────────────────────────────────────────

/// The window's contents: the panel in the middle, and round it a margin that holds its shadow. The shadow is cut away under the two
/// shapes (they are glass: a shadow under them would show through) and falls only outside them.
final class ClipboardShadowHost: NSView {

    let content: ClipboardContentView
    private let shadowLayer = CALayer()
    private let cut = CAShapeLayer()
    private var labShadow: (opacity: Float, radius: CGFloat, drop: CGFloat)?

    init(content: ClipboardContentView) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        shadowLayer.shadowColor = NSColor.black.cgColor
        cut.fillRule = .evenOdd
        shadowLayer.mask = cut
        layer?.addSublayer(shadowLayer)         // before the content, so under it
        content.autoresizingMask = []
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// CALIBRATION (temporary), from the same JSON: `"shadow":[opacity, radius, drop]`.
    func applyLab() {
        guard let text = UserDefaults(suiteName: "com.anode.settings")?.string(forKey: "anode.debug.clipboardGlass"),
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let s = json["shadow"] as? [Double], s.count == 3 else { return }
        labShadow = (Float(s[0]), CGFloat(s[1]), CGFloat(s[2]))
        updateShadow()
    }

    override func layout() {
        super.layout()
        let m = ClipboardPanelMetrics.shadowMargin
        content.frame = NSRect(x: m, y: m, width: bounds.width - 2 * m, height: max(0, bounds.height - 2 * m))
        updateShadow()
    }

    func updateShadow() {
        let m = ClipboardPanelMetrics.shadowMargin
        let contentHeight = bounds.height - 2 * m
        guard contentHeight > 0 else { return }
        // The shapes are in the content's flipped coordinates; this view is not flipped.
        func inHost(_ r: NSRect) -> NSRect { NSRect(x: m + r.minX, y: m + contentHeight - r.maxY, width: r.width, height: r.height) }
        let shapes = content.shapeFrames().map { (inHost($0.rect), $0.radius) }
        let all = CGMutablePath(), hole = CGMutablePath()
        hole.addRect(bounds)
        for (rect, radius) in shapes {
            all.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            hole.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        }
        let lab = labShadow ?? (ClipboardPanelMetrics.shadowOpacity, ClipboardPanelMetrics.shadowRadius, ClipboardPanelMetrics.shadowDrop)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.frame = bounds
        shadowLayer.shadowPath = all
        shadowLayer.shadowOpacity = lab.opacity
        shadowLayer.shadowRadius = lab.radius
        shadowLayer.shadowOffset = CGSize(width: 0, height: -lab.drop)
        cut.frame = bounds
        cut.path = hole
        CATransaction.commit()
    }
}

// ── The caret ───────────────────────────────────────────────────────────────

/// The field editor of the search field. The system panel's caret is a white bar about two and a half points wide, as tall as the
/// line, with a glow round it; it blinks at the rate the system sets, which `NSTextView` follows.
final class ClipboardFieldEditor: NSTextView {

    static let caretWidth: CGFloat = 2.5
    static let glowRadius: CGFloat = 6

    // Both designated initialisers are overridden: `NSTextView(frame:)` makes its text system and then calls
    // `init(frame:textContainer:)` on the subclass, and a subclass that has only an `init()` of its own traps there.
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        setUp()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func setUp() {
        isFieldEditor = true
        isRichText = false
        drawsBackground = false
        insertionPointColor = .white
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        let margin = Self.glowRadius + 3
        guard flag else {
            // Off: the bar and its glow are drawn over by the text and the background again.
            setNeedsDisplay(rect.insetBy(dx: -margin, dy: -margin / 2), avoidAdditionalLayout: true)
            return
        }
        var bar = rect
        bar.size.width = Self.caretWidth
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = NSColor(calibratedRed: 1, green: 0.96, blue: 0.82, alpha: 0.75)
        glow.shadowBlurRadius = Self.glowRadius
        glow.shadowOffset = .zero
        glow.set()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: bar, xRadius: Self.caretWidth / 2, yRadius: Self.caretWidth / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        // The glow reaches past the caret: what is drawn again has to as well.
        super.setNeedsDisplay(rect.insetBy(dx: -(Self.glowRadius + 3), dy: -3), avoidAdditionalLayout: flag)
    }
}

// ── The shapes ──────────────────────────────────────────────────────────────

/// One of the two glass shapes: the glass, the black over it that fades from top to bottom, and a hairline round the edge. What it
/// holds is added to `body`, which is flipped (its origin is its top-left).
final class ClipboardShapeView: NSView {

    enum Kind { case pill, card }

    let kind: Kind
    let body = FlippedView()
    private let material: NSView
    /// Views, not bare layers: the glass is drawn over a layer of its parent's, and under a view added after it.
    private let tint = ClipboardTintView()
    private let edge = EdgeView()
    private var labBleed: CGFloat?

    init(kind: Kind) {
        self.kind = kind
        let r = kind == .pill ? ClipboardPanelMetrics.pillRadius : ClipboardPanelMetrics.cardRadius
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = r
            glass.style = .clear
            material = glass
        } else {
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.blendingMode = .behindWindow
            v.state = .active
            material = v
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = r
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true       // nothing square shows at the corners, and the window's shadow follows this shape
        addSubview(material)

        tint.stops = { [kind] h in ClipboardPanelMetrics.tintStops(card: kind == .card, height: h) }
        addSubview(tint)

        addSubview(body)

        edge.wantsLayer = true
        edge.layer?.cornerRadius = r
        edge.layer?.cornerCurve = .continuous
        edge.layer?.borderWidth = 0          // the rims are in the tint's stops, where the system's panel has them
        addSubview(edge)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// CALIBRATION (temporary): `anode.debug.clipboardGlass` in the settings domain, JSON
    /// `{"style":"clear|regular","pill":[[0,0,1],[1,0,0.54]],"card":[[0,0,0.5],[1,0,0.2]]}`, each stop (how far down, grey, opacity).
    /// Read each time the panel opens, so the glass can be tuned against the system's without restarting.
    func applyLab() {
        guard let text = UserDefaults(suiteName: "com.anode.settings")?.string(forKey: "anode.debug.clipboardGlass"),
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView, let style = json["style"] as? String {
            glass.style = style == "clear" ? .clear : .regular
        }
        if let bleed = json["bleed"] as? Double { labBleed = CGFloat(bleed); needsLayout = true }
        if let raw = json[kind == .pill ? "pill" : "card"] as? [[Double]] {
            let stops = raw.filter { $0.count == 3 }.map { (y: CGFloat($0[0]), gray: CGFloat($0[1]), alpha: CGFloat($0[2])) }
            if stops.count >= 2 { tint.stops = { _ in stops } }
        }
    }

    override func layout() {
        super.layout()
        // The glass is taller than the shape; the shape's clip (rounded corners, `masksToBounds`) cuts the rest off.
        let bleed = labBleed ?? ClipboardPanelMetrics.glassBleed
        material.frame = NSRect(x: 0, y: -bleed, width: bounds.width, height: bounds.height + 2 * bleed)
        body.frame = bounds
        tint.frame = bounds
        edge.frame = bounds
    }
}

/// Black over the glass, `top` opaque at the top edge and `bottom` at the bottom edge. It takes no clicks.
final class ClipboardTintView: NSView {
    override func makeBackingLayer() -> CALayer { CAGradientLayer() }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Stops in points from the top (a negative one is from the bottom): (how far down; the grey, 0 black...1 white; the opacity).
    /// Worked out against the view's height each time it is laid out.
    var stops: ((_ height: CGFloat) -> [(y: CGFloat, gray: CGFloat, alpha: CGFloat)])? { didSet { needsLayout = true } }

    override func layout() {
        super.layout()
        guard let gradient = layer as? CAGradientLayer, let stops, bounds.height > 1 else { return }
        gradient.startPoint = CGPoint(x: 0.5, y: 1)      // the view is not flipped: y up, so 1 is the top
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        let h = bounds.height
        let placed = stops(h).map { (loc: min(1, max(0, ($0.y < 0 ? h + $0.y : $0.y) / h)), gray: $0.gray, alpha: $0.alpha) }
            .sorted { $0.loc < $1.loc }
        gradient.colors = placed.map { NSColor(white: $0.gray, alpha: $0.alpha).cgColor }
        gradient.locations = placed.map { NSNumber(value: Double($0.loc)) }
    }
}

// ── The content ─────────────────────────────────────────────────────────────

final class ClipboardContentView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {

    weak var controller: ClipboardHistoryController?
    /// The height the panel should be, whenever the list changes it.
    var onResize: ((CGFloat) -> Void)?
    /// The chip that is on, if any.
    private(set) var filter: ClipboardFilter?

    typealias M = ClipboardPanelMetrics

    private let pill = ClipboardShapeView(kind: .pill)
    private let card = ClipboardShapeView(kind: .card)
    let field = NSTextField()
    private let accessory = NSImageView()
    private let chips = FlippedView()
    private var chipViews: [ClipboardChipView] = []
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var rows: [ClipboardRowModel] = []
    private var cardHeight: CGFloat?

    private static let cellID = NSUserInterfaceItemIdentifier("clipboardRow")

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: M.width, height: M.pillHeight))
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        addSubview(pill)
        addSubview(card)

        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: M.searchFontSize, weight: .regular)
        field.textColor = NSColor(white: 0.96, alpha: 1)
        field.placeholderAttributedString = NSAttributedString(
            string: "Search Clipboard History",
            attributes: [.font: NSFont.systemFont(ofSize: M.searchFontSize, weight: .regular), .foregroundColor: NSColor(white: 0.56, alpha: 1)])
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        field.setAccessibilityLabel("Search Clipboard History")
        pill.body.addSubview(field)

        accessory.imageScaling = .scaleProportionallyUpOrDown
        accessory.contentTintColor = NSColor(white: 0.6, alpha: 1)
        pill.body.addSubview(accessory)

        card.body.addSubview(chips)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = M.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.focusRingType = .none
        table.style = .plain          // no inset of its own: the rows start where the list does
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        scroll.documentView = table
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        card.body.addSubview(scroll)

        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textColor = NSColor(white: 0.62, alpha: 1)
        emptyLabel.alignment = .center
        card.body.addSubview(emptyLabel)
    }

    func applyLab() { pill.applyLab(); card.applyLab() }

    /// Called after each layout, so the shadow follows the shapes.
    var onLayout: (() -> Void)?

    /// Where the two shapes are, in this view's coordinates, with their corner radii (the card only when it is showing).
    func shapeFrames() -> [(rect: NSRect, radius: CGFloat)] {
        var out = [(rect: pill.frame, radius: M.pillRadius)]
        if cardHeight != nil, !card.isHidden { out.append((card.frame, M.cardRadius)) }
        return out
    }

    // ── What is listed ──────────────────────────────────────────────────────

    var hasQuery: Bool { !field.stringValue.isEmpty }
    var selectedEntry: ClipboardEntry? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].entry : nil }
    func entry(atRow row: Int) -> ClipboardEntry? { rows.indices.contains(row) ? rows[row].entry : nil }

    /// A fresh start: nothing typed, no chip, the first row chosen.
    func reset() {
        field.stringValue = ""
        filter = nil
        reload(keepingSelection: false)
    }

    func clearQuery() {
        field.stringValue = ""
        filter = nil
        reload(keepingSelection: false)
    }

    func reload(keepingSelection: Bool) {
        let keep = keepingSelection ? selectedEntry?.id : nil
        let now = Date()
        let query = field.stringValue
        let available = controller?.filters(for: query) ?? []
        if let f = filter, !available.contains(f) { filter = nil }
        let found = controller?.results(for: query, filter: filter) ?? []
        rows = found.enumerated().map { ClipboardRowModel.make($0.element, index: $0.offset, now: now) }
        rebuildChips(available)
        table.reloadData()
        if !rows.isEmpty {
            let row = keep.flatMap { id in rows.firstIndex { $0.entry.id == id } } ?? 0
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        updateSelectionLook()
        let empty = (controller?.store.entries.isEmpty ?? true)
        field.placeholderAttributedString = NSAttributedString(
            string: empty ? "Nothing copied yet" : "Search Clipboard History",
            attributes: [.font: NSFont.systemFont(ofSize: M.searchFontSize, weight: .regular), .foregroundColor: NSColor(white: 0.56, alpha: 1)])
        emptyLabel.stringValue = "No matches for \u{201C}\(query)\u{201D}"
        cardHeight = M.cardHeight(rows: rows.count, hasQuery: hasQuery || filter != nil)
        updateAccessory()
        needsLayout = true
        onResize?(M.panelHeight(card: cardHeight))
        layoutSubtreeIfNeeded()
    }

    func moveSelection(_ by: Int) {
        guard !rows.isEmpty else { return }
        let row = min(rows.count - 1, max(0, (table.selectedRow < 0 ? 0 : table.selectedRow) + by))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        updateSelectionLook()
        updateAccessory()
    }

    /// Tab: on to the next chip (and round to none), Shift-Tab back.
    func cycleFilter(_ by: Int) {
        let order: [ClipboardFilter?] = [nil] + (controller?.filters(for: field.stringValue) ?? []).map { Optional($0) }
        guard order.count > 1 else { return }
        let at = order.firstIndex { $0 == filter } ?? 0
        filter = order[(at + by + order.count) % order.count]
        reload(keepingSelection: false)
    }

    @objc private func rowClicked() {
        guard let id = entry(atRow: table.clickedRow)?.id else { return }
        controller?.choose(id, mode: .paste)
    }

    func controlTextDidChange(_ obj: Notification) { reload(keepingSelection: false) }

    /// The picture at the bar's right: the chosen entry's own, or the clipboard.
    private func updateAccessory() {
        if let entry = selectedEntry, let image = ClipboardIcons.icon(for: entry, store: controller?.store) {
            accessory.image = image
            accessory.contentTintColor = nil
        } else {
            accessory.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
            accessory.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 19, weight: .regular)
            accessory.contentTintColor = NSColor(white: 0.6, alpha: 1)
        }
    }

    // ── Chips ───────────────────────────────────────────────────────────────

    private func rebuildChips(_ available: [ClipboardFilter]) {
        chipViews.forEach { $0.removeFromSuperview() }
        chipViews = available.map { f in
            let chip = ClipboardChipView(title: f.title, active: f == filter)
            chip.onClick = { [weak self] in
                guard let self else { return }
                self.filter = self.filter == f ? nil : f
                self.reload(keepingSelection: false)
            }
            chips.addSubview(chip)
            return chip
        }
        var x = M.chipLeft
        for chip in chipViews {
            chip.frame = NSRect(x: x, y: 0, width: chip.fittingWidth, height: M.chipHeight)
            x += chip.fittingWidth + M.chipGap
        }
    }

    // ── Layout ──────────────────────────────────────────────────────────────

    override func layout() {
        super.layout()
        let w = bounds.width
        pill.frame = NSRect(x: 0, y: 0, width: w, height: M.pillHeight)
        // An editable field draws its text at the top of its frame, so the frame is as tall as the line and sits at the bar's middle.
        let font = NSFont.systemFont(ofSize: M.searchFontSize, weight: .regular)
        let fieldHeight = ceil(font.ascender - font.descender + font.leading)
        let rightSpace = M.accessoryCentreFromRight + M.accessorySize / 2 + 12
        field.frame = NSRect(x: M.searchLeft - 4, y: (M.pillHeight - fieldHeight) / 2 + M.searchTextDrop, width: w - M.searchLeft - rightSpace,
                             height: fieldHeight)
        accessory.frame = NSRect(x: w - M.accessoryCentreFromRight - M.accessorySize / 2, y: (M.pillHeight - M.accessorySize) / 2,
                                 width: M.accessorySize, height: M.accessorySize)

        if let h = cardHeight {
            card.isHidden = false
            card.frame = NSRect(x: 0, y: M.pillHeight + M.gap, width: w, height: h)
            chips.frame = NSRect(x: 0, y: M.chipsTop, width: w, height: M.chipHeight)
            chips.isHidden = chipViews.isEmpty
            scroll.frame = NSRect(x: 0, y: M.rowsTop, width: w, height: max(0, h - M.rowsTop))
            table.tableColumns.first?.width = w
            emptyLabel.frame = NSRect(x: M.iconLeft, y: M.chipsTop + (h - M.chipsTop - 20) / 2 - 6, width: w - 2 * M.iconLeft, height: 20)
            scroll.isHidden = rows.isEmpty
            emptyLabel.isHidden = !rows.isEmpty
        } else {
            card.isHidden = true
        }
        onLayout?()
    }

    // ── The table ───────────────────────────────────────────────────────────

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let cell = (tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? ClipboardRowCellView) ?? {
            let c = ClipboardRowCellView()
            c.identifier = Self.cellID
            return c
        }()
        cell.configure(rows[row], icon: ClipboardIcons.icon(for: rows[row].entry, store: controller?.store))
        cell.setSelected(row == table.selectedRow)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ClipboardRowView() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectionLook()
        updateAccessory()
    }

    private func updateSelectionLook() {
        table.enumerateAvailableRowViews { rowView, row in
            (rowView.view(atColumn: 0) as? ClipboardRowCellView)?.setSelected(row == self.table.selectedRow)
        }
    }
}

// ── Chips ───────────────────────────────────────────────────────────────────

/// A filter chip: a capsule of a light veil with the kind in it, lighter while it is on.
final class ClipboardChipView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let active: Bool
    var onClick: (() -> Void)?

    init(title: String, active: Bool) {
        self.active = active
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = ClipboardPanelMetrics.chipHeight / 2
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(active ? 0.22 : 0.09).cgColor
        label.stringValue = title
        label.font = .systemFont(ofSize: ClipboardPanelMetrics.chipFontSize)
        label.textColor = active ? .white : NSColor(white: 0.6, alpha: 1)
        label.sizeToFit()
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var fittingWidth: CGFloat { label.frame.width + 2 * ClipboardPanelMetrics.chipPadding }
    var isActive: Bool { active }

    override func layout() {
        super.layout()
        label.frame.origin = NSPoint(x: ClipboardPanelMetrics.chipPadding, y: (bounds.height - label.frame.height) / 2)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

// ── Rows ────────────────────────────────────────────────────────────────────

/// The selection: a capsule of a light veil, inset from the card's sides, as the system panel draws it.
final class ClipboardRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: ClipboardPanelMetrics.rowInset, dy: 0)
        NSColor.white.withAlphaComponent(ClipboardPanelMetrics.selectionAlpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
    }
    override var isEmphasized: Bool { get { true } set {} }
}

final class ClipboardRowCellView: NSView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let hintField = NSTextField(labelWithString: "")
    private let pinView = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        titleField.font = .systemFont(ofSize: ClipboardPanelMetrics.titleFontSize)
        titleField.textColor = .white
        titleField.lineBreakMode = .byTruncatingTail
        subtitleField.font = .systemFont(ofSize: ClipboardPanelMetrics.detailFontSize)
        subtitleField.lineBreakMode = .byTruncatingTail
        hintField.font = .systemFont(ofSize: ClipboardPanelMetrics.titleFontSize)
        hintField.alignment = .right
        pinView.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
        pinView.contentTintColor = NSColor(white: 0.7, alpha: 1)
        for v in [iconView, titleField, subtitleField, hintField, pinView] as [NSView] { addSubview(v) }
        setSelected(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ row: ClipboardRowModel, icon: NSImage?) {
        iconView.image = icon
        titleField.stringValue = row.title
        subtitleField.stringValue = row.subtitle
        hintField.stringValue = row.hint ?? ""
        pinView.isHidden = !row.entry.pinned
        setAccessibilityLabel("\(row.title), \(row.subtitle)\(row.entry.pinned ? ", pinned" : "")")
        needsLayout = true
    }

    func setSelected(_ on: Bool) {
        subtitleField.textColor = NSColor(white: on ? 0.72 : 0.58, alpha: 1)
        hintField.textColor = NSColor(white: on ? 0.82 : 0.66, alpha: 1)
    }

    override func layout() {
        super.layout()
        let m = ClipboardPanelMetrics.self
        iconView.frame = NSRect(x: m.iconLeft, y: (bounds.height - m.iconSize) / 2, width: m.iconSize, height: m.iconSize)
        let hintWidth: CGFloat = 40
        hintField.frame = NSRect(x: bounds.width - m.trailingRight - hintWidth, y: (bounds.height - 22) / 2, width: hintWidth, height: 22)
        let pinWidth: CGFloat = pinView.isHidden ? 0 : 16
        pinView.frame = NSRect(x: hintField.frame.minX - 8 - pinWidth, y: (bounds.height - 14) / 2, width: pinWidth, height: 14)
        let right = (pinView.isHidden ? hintField.frame.minX : pinView.frame.minX) - 10
        let width = max(0, right - m.titleLeft)
        let hasSubtitle = !subtitleField.stringValue.isEmpty
        titleField.frame = NSRect(x: m.titleLeft, y: hasSubtitle ? bounds.height / 2 - 1 : (bounds.height - 22) / 2, width: width, height: 22)
        subtitleField.frame = NSRect(x: m.titleLeft, y: bounds.height / 2 - 21, width: width, height: 16)
    }
}

// ── Pictures ────────────────────────────────────────────────────────────────

/// The picture on a row: an image's own, a file's icon, or the icon of the app the copy came from.
enum ClipboardIcons {
    private static let thumbnails = NSCache<NSString, NSImage>()
    private static var appIcons: [String: NSImage] = [:]

    static func icon(for entry: ClipboardEntry, store: ClipboardStore?) -> NSImage? {
        switch entry.kind {
        case .image:
            if let cached = thumbnails.object(forKey: entry.fingerprint as NSString) { return cached }
            if let store, let data = store.data(for: entry.id, ofType: ClipboardTypes.images), let image = thumbnail(data) {
                thumbnails.setObject(image, forKey: entry.fingerprint as NSString)
                return image
            }
        case .file:
            if let path = entry.text.split(separator: "\n").first.map(String.init), FileManager.default.fileExists(atPath: path) {
                return NSWorkspace.shared.icon(forFile: path)
            }
        case .text, .link:
            break
        }
        if let id = entry.sourceBundleID, let icon = appIcon(id) { return icon }
        let symbol = entry.kind == .link ? "link" : entry.kind == .image ? "photo" : entry.kind == .file ? "doc" : "text.alignleft"
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    private static func appIcon(_ bundleID: String) -> NSImage? {
        if let cached = appIcons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        appIcons[bundleID] = icon
        return icon
    }

    /// A small picture of an image, made without decoding all of it.
    static func thumbnail(_ data: Data, maxPixels: Int = 96) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }
}

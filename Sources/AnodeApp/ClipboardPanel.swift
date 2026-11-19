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
    static let pillRadius: CGFloat = 43.5            // measured: the bar is a capsule (half its height)
    static let cardRadius: CGFloat = 38              // measured from the card's top corners
    // Where it opens and how it is dragged: `ClipboardPlacement`.

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
    /// The blur of what is behind each shape (a gaussian's sigma in points): the system's card is frosted (a hard edge behind it fades over
    /// about 20 points: a sigma of 8), its bar only a little (about 3.4 points: 1.5). See `BackdropBlurView`.
    static let cardBlur: CGFloat = 8
    static let pillBlur: CGFloat = 1.5
    /// The card's frost (see `BackdropBlurView.Frost`), fitted per depth above its bottom edge to what fine stripes of three spacings (10, 20 and
    /// 40 points) and a thin line show behind the system's card (2026-11-19): the kernel is about 0.4 of a narrow blur and 0.6 of a wide one
    /// (sigma about 12, the same at every depth). The narrow one's sigma is 3 at the rim, under 1 from 8 to 16 points in (where the lens
    /// shows what is behind the glass nearly sharp), and rises to 3.5 by 70; tuned against the measurements to within about 10%. A single gaussian, however it was varied with depth, could not
    /// give the stripes' contrast at all three spacings.
    static let cardFrost = BackdropBlurView.Frost(
        narrow: .init(cornerRadius: cardRadius, profile: [(0, 3.4), (3, 3.1), (5, 2.4), (6.5, 1.7), (8, 1.1), (10, 0.9), (13, 0.7), (16, 0.8), (20, 1.3),
                                                           (25, 2.0), (30, 2.5), (40, 3.0), (50, 3.3), (70, 3.5), (200, 3.5)]
            .map { .init(depth: CGFloat($0.0), sigma: CGFloat($0.1)) }, radius: 4),
        wideSigma: 11.7,
        wideWeight: [(0, 0.57), (10, 0.55), (20, 0.56), (30, 0.6), (45, 0.65), (60, 0.71), (200, 0.72)]
            .map { .init(depth: CGFloat($0.0), sigma: CGFloat($0.1)) })

    /// The card's glass is not extended past its bottom: its own edge shows there, which bends what is behind it. (The system's card has
    /// none; this is a choice, for a thicker look at the bottom.)
    static let cardBottomBleed: CGFloat = 0
    /// The list's own words and icons bend where the card's bottom edge is, as what is behind the glass does: a lens along that edge,
    /// reaching this far up (points), pinching the rows toward the edge. A linear bump distortion leaves things alone at a scale of 1;
    /// below 1 it magnifies round the line (and cuts the last points of a row off, which is what the first try looked like: words
    /// cut short while a picture ran on), above 1 it pinches. Measured against rows numbered by height: at 2 and 20 points, what is 4
    /// points from the edge shows what lies 8 points in, and 12 shows 16; from 3 up the mapping folds over itself (the words came out
    /// doubled, half of each letter upside down).
    static let edgeLensDepth: CGFloat = 20
    static let edgeLensScale: Double = 2.0

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
    static let rowInset: CGFloat = 12                // measured (2026-11-19, from the difference of two pictures of the system's card, the
                                                     // first row selected and then the second): the selection's distance from the card's sides
    /// The selection is a rounded rectangle, not a capsule: its corners are circles of 24 points (the offsets of its edge from the side,
    /// 10, 20 and 30 pixels down from the top, fit a circle of 48 pixels at 2 to the point: 18, 9 and 4 against 18.7, 9 and 3.5).
    static let selectionRadius: CGFloat = 24
    static let iconSize: CGFloat = 36
    static let iconLeft: CGFloat = 26
    static let titleLeft: CGFloat = 79.5
    static let trailingRight: CGFloat = 26
    static let titleFontSize: CGFloat = 17
    static let detailFontSize: CGFloat = 12
    static let selectionAlpha: CGFloat = 0.058         // the lift of the system's highlight over the same dark page is 0.062 against 0.076 at 0.07
    static let emptyCardHeight: CGFloat = 96
    static let bottomPadding: CGFloat = 8

    // The shadow, drawn here and not by the window server, whose own is much lighter than the system panel's (measured: beside the
    // bar the backdrop is dimmed by 20% at the edge, beside the card 30%, and the gap between them to 40%).
    static let shadowMargin: CGFloat = 48
    static let shadowOpacity: Float = 0.72
    static let shadowRadius: CGFloat = 22
    static let shadowDrop: CGFloat = 16

    // Appearing and going: the panel's opacity, read every few milliseconds, rose in about 0.11 s and fell in about 0.11 s, evenly.
    static let fadeInDuration: TimeInterval = 0.11
    static let fadeOutDuration: TimeInterval = 0.11
    /// Appearing is a drop in, measured from frames of the system's panel (2026-11-19) over a white backdrop: it starts about 13% larger,
    /// scaled about the middle of its 137 point window, and settles on a spring (period 0.3 s, damping 0.72, a dip of 0.6% under its
    /// size on the way) while its opacity rises evenly. Going is a fade over about 0.11 s in which it grows to about 7% larger.
    /// (Times taken from the frames' own presentation times; the system's were read with the delivery times, about 6% slow, and
    /// corrected by its window's opacity ramp, read every 4 ms.)
    static let appearScale: CGFloat = 1.13
    static let springFrequency: Double = 22.5          // rad/s: a period of 0.28 s
    static let springDamping: Double = 0.72            // the damping ratio
    static let springSettle: TimeInterval = 0.6
    /// The panel's scale `t` seconds after it starts to appear: a damped spring from `appearScale` to 1 (fitted to the system's own,
    /// frame by frame). Core Animation's own spring takes the same numbers and runs about 40% slow, so the curve is sampled instead.
    static func appearScale(at t: Double) -> CGFloat {
        let w = springFrequency, z = springDamping
        let wd = w * (1 - z * z).squareRoot()
        let x0 = Double(appearScale) - 1
        let decay = exp(-z * w * t)
        return CGFloat(1 + decay * (x0 * cos(wd * t) + (z * w * x0 / wd) * sin(wd * t)))
    }
    static let disappearScale: CGFloat = 1.07

    /// The tint's opacity down the bar (`y` points from its top, of `height`) and down the card (`y` from its top): measured with solid
    /// white, grey and black behind the system's panel and this one (2026-11-19). Over the clear glass, which passes the backdrop's
    /// brightness B as 0.875 B + 0.125 (a little more than that for greys), a black tint of opacity a leaves (1 - a) of it. The bar's a
    /// is 1.0 at the top and 0.61 at the bottom; the card's 0.55 at its top and 0.30 at 410 points down. (Fitted to stripes, which
    /// the glass blurs and leaks light into from far off, it read as 0.46 to 0.37 and a lighter grey: the large flat areas of a real
    /// backdrop then came out too dark.)
    static func barTintAlpha(_ y: CGFloat, height h: CGFloat) -> CGFloat { 1.0 - 0.39 * y / max(h, 1) }
    static func cardTintAlpha(_ y: CGFloat) -> CGFloat { 0.55 - 0.252 * min(1, y / 410) }

    /// The system's rims, pixel by pixel (2 to the point) over white and black, as (points from the edge to the middle of the pixel,
    /// the grey that fits, the opacity that fits). Each shape has them where the system's does: the bar at its bottom edge only, the
    /// card at both. The last two pixels are a hard step; before them a gradual brightening of 4 or 5 points.
    static let barBottomRim: [(from: CGFloat, gray: CGFloat, alpha: CGFloat)] = [
        (4.75, 0.021, 0.623), (4.25, 0.037, 0.623), (3.75, 0.035, 0.611), (3.25, 0.051, 0.611), (2.75, 0.068, 0.611),
        (2.25, 0.066, 0.589), (1.75, 0.100, 0.589), (1.25, 0.134, 0.566)]
    /// The card's top rim: its first four half-point rows are hard bands (as they are in the system's), then it ramps off over 3 points.
    static let cardTopBands: [(gray: CGFloat, alpha: CGFloat)] = [(0.75, 0.634), (0.55, 0.486), (0.17, 0.51), (0.135, 0.52)]
    static let cardTopRim: [(from: CGFloat, gray: CGFloat, alpha: CGFloat)] = [
        (2.25, 0.097, 0.53), (2.75, 0.078, 0.535), (3.25, 0.059, 0.54), (3.75, 0.05, 0.545), (4.25, 0.042, 0.545), (4.75, 0.03, 0.55),
        (5.25, 0.02, 0.55)]
    /// The card's bottom rim, refitted (2026-11-19) from clean pictures of the system's card over solid white, grey and black, one pixel row at
    /// a time: past the last pixel or two it is black of opacity 0.26 to 0.31, with none of the light grey the first fit (against stripes of a
    /// different kind) gave it.
    static let cardBottomRim: [(from: CGFloat, gray: CGFloat, alpha: CGFloat)] = [
        (5.75, 0, 0.31), (5.25, 0, 0.30), (4.75, 0, 0.30), (4.25, 0, 0.276), (3.75, 0, 0.276), (3.25, 0, 0.268), (2.75, 0, 0.256),
        (2.25, 0, 0.264), (1.75, 0, 0.305), (1.25, 0, 0.319)]
    /// What is laid over the glass, from the top down: (how far down in points, a negative one from the bottom; the grey; the opacity).
    static func tintStops(card: Bool, height: CGFloat) -> [(y: CGFloat, gray: CGFloat, alpha: CGFloat)] {
        let h = max(height, 1)
        if !card {
            var stops: [(y: CGFloat, gray: CGFloat, alpha: CGFloat)] = [(0, 0, barTintAlpha(0, height: h)), (h - 6, 0, barTintAlpha(h - 6, height: h))]
            stops += barBottomRim.map { (-$0.from, $0.gray, $0.alpha) }
            // the last two pixels: a hard step
            stops += [(-1.0, 0.5, 0.463), (-0.5, 0.5, 0.463), (-0.5, 1.0, 0.394), (h, 1.0, 0.394)]
            return stops
        }
        var stops: [(y: CGFloat, gray: CGFloat, alpha: CGFloat)] = []
        for (i, band) in cardTopBands.enumerated() {
            stops += [(CGFloat(i) * 0.5, band.gray, band.alpha), (CGFloat(i + 1) * 0.5, band.gray, band.alpha)]
        }
        stops += cardTopRim.map { ($0.from, $0.gray, $0.alpha) }
        stops += [(6, 0, cardTintAlpha(6)), (h - 6, 0, cardTintAlpha(h - 6))]
        stops += cardBottomRim.map { (-$0.from, $0.gray, $0.alpha) }
        stops += [(-1.0, 1.0, 0.214), (-0.5, 1.0, 0.214), (-0.5, 1.0, 0.622), (h, 1.0, 0.622)]
        return stops
    }

    typealias TintStop = (y: CGFloat, gray: CGFloat, alpha: CGFloat)
    /// How far from an edge the light of a rim reaches: the rim's stops are all this near the shape's top or bottom.
    static let rimDepth: CGFloat = 6

    /// `tintStops` in two layers: `base`, the black that fades down the middle, which goes under what the shape holds, and `rim`, the light
    /// along its edges, which goes over it (the rims are the glass's own light at its edge, so what is in the glass, a word or a picture
    /// at the card's bottom, is under it, not over it). Over the glass the two put on what `tintStops` does as one layer: where one has
    /// the tint the other has none.
    static func splitTint(card: Bool, height: CGFloat) -> (base: [TintStop], rim: [TintStop]) {
        let h = max(height, 1)
        let all = tintStops(card: card, height: h)
        func place(_ s: TintStop) -> CGFloat { s.y < 0 ? h + s.y : s.y }
        func isTop(_ s: TintStop) -> Bool { card && place(s) < rimDepth }
        func isBottom(_ s: TintStop) -> Bool { place(s) > h - rimDepth }
        let topRim = all.filter(isTop)
        let bottomRim = all.filter(isBottom)
        let interior = all.filter { !isTop($0) && !isBottom($0) }
        let topEnd = topRim.map(place).max() ?? 0
        let bottomStart = bottomRim.map(place).min() ?? h
        var base: [TintStop] = []
        if card { base += [(0, 0, 0), (topEnd, 0, 0)] }
        base += interior
        base += [(bottomStart, 0, 0), (h, 0, 0)]
        var rim: [TintStop] = []
        if card, let last = topRim.last {
            rim += topRim
            rim += [(rimDepth, last.gray, 0)]
        } else {
            rim += [(0, bottomRim.first?.gray ?? 0, 0)]
        }
        if let first = bottomRim.first { rim += [(h - rimDepth, first.gray, 0)] + bottomRim }
        return (base, rim)
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
    private let stage = NSView()
    private var monitors: [Any] = []
    /// Looks every quarter of a second, while the panel is open, for the system's search opening over it.
    private var spotlightWatch: Timer?
    private let editor = ClipboardFieldEditor()
    private(set) var shown = false
    /// Where it was last left, as how far it is from the default place: it opens there again.
    private var remembered = CGSize.zero
    private var drag: ClipboardPlacement.Drag?

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
        // The drop in is a transform of the host's layer, so the host sits in a plain view that fills the window.
        stage.wantsLayer = true
        stage.frame = NSRect(x: 0, y: 0, width: ClipboardPanelMetrics.width + 2 * m, height: ClipboardPanelMetrics.pillHeight + 2 * m)
        host.frame = stage.bounds
        host.autoresizingMask = [.width, .height]
        stage.addSubview(host)
        contentView = stage
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
        content.reset()
        place()
        let animated = DisplayAccessibility.current.animates
        let reopened = isVisible        // it was still fading out
        shown = true
        if !reopened { alphaValue = animated ? 0 : 1 }
        orderFrontRegardless()
        makeKey()
        makeFirstResponder(content.field)
        host.layer?.removeAnimation(forKey: "going")
        if animated {
            drop(in: true)
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
        watchForSpotlight()
    }

    /// The system's search opening over this panel does not take the key from it (neither is an app that is in front), so nothing says so:
    /// it is looked for. Only an opening that is seen counts: when this panel opened with the search still on screen (and being closed),
    /// that one is not it.
    private func watchForSpotlight() {
        spotlightWatch?.invalidate()
        var seenClosed = false
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.shown else { return }
            if SystemSpotlight.openHost() == nil { seenClosed = true } else if seenClosed { self.dismissFromPanel() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        spotlightWatch = timer
    }

    private func stopWatchingForSpotlight() {
        spotlightWatch?.invalidate()
        spotlightWatch = nil
    }

    func refresh() {
        guard shown else { return }
        content.reload(keepingSelection: true)
    }

    func hide(completion: @escaping () -> Void) {
        guard shown else { completion(); return }
        shown = false
        stopWatchingForSpotlight()
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        guard DisplayAccessibility.current.animates else {
            orderOut(nil)
            completion()
            return
        }
        drop(in: false)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = ClipboardPanelMetrics.fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .linear)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Opened again while it faded: it stays, and the fade-in has taken over.
            if let self, !self.shown { self.orderOut(nil); self.alphaValue = 1; self.host.layer?.removeAnimation(forKey: "going") }
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

    // ── The drop in ─────────────────────────────────────────────────────────

    /// The host's layer scaled by `scale` about the middle of a 137 point window at the panel's top: the point the system's panel
    /// scales about (measured). Pure arithmetic on the layer's own anchor, so it holds whatever the anchor point is.
    func dropTransform(scale: CGFloat) -> CATransform3D {
        guard let layer = host.layer else { return CATransform3DIdentity }
        let size = host.bounds.size
        let m = ClipboardPanelMetrics.shadowMargin
        let about = CGPoint(x: size.width / 2, y: size.height - m - ClipboardPlacement.referenceHeight / 2)
        let anchor = CGPoint(x: layer.anchorPoint.x * size.width, y: layer.anchorPoint.y * size.height)
        var t = CATransform3DIdentity
        t.m11 = scale
        t.m22 = scale
        t.m41 = (about.x - anchor.x) * (1 - scale)
        t.m42 = (about.y - anchor.y) * (1 - scale)
        return t
    }

    /// Coming in: from larger, on a spring. Going: growing a little as it fades.
    private func drop(in appearing: Bool) {
        guard let layer = host.layer else { return }
        if appearing {
            // sampled every 1/120 s, so it follows the spring however the screen's own rate runs
            let step = 1.0 / 120.0
            let times = Array(stride(from: 0.0, through: ClipboardPanelMetrics.springSettle, by: step))
            let frames = CAKeyframeAnimation(keyPath: "transform")
            frames.values = times.map { NSValue(caTransform3D: dropTransform(scale: ClipboardPanelMetrics.appearScale(at: $0))) }
            frames.keyTimes = times.map { NSNumber(value: $0 / ClipboardPanelMetrics.springSettle) }
            frames.calculationMode = .linear
            frames.duration = ClipboardPanelMetrics.springSettle
            layer.add(frames, forKey: "drop")
        } else {
            layer.removeAnimation(forKey: "drop")
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
            grow.toValue = NSValue(caTransform3D: dropTransform(scale: ClipboardPanelMetrics.disappearScale))
            grow.duration = ClipboardPanelMetrics.fadeOutDuration
            grow.timingFunction = CAMediaTimingFunction(name: .linear)
            grow.fillMode = .forwards
            grow.isRemovedOnCompletion = false
            layer.add(grow, forKey: "going")
        }
    }

    // ── Where it sits ───────────────────────────────────────────────────────

    /// The screen the pointer is on, or the main one.
    private func targetScreen() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The window is the panel and a margin all round for its shadow: the panel's own rectangle is `frame(height:in:)`.
    static func windowFrame(forPanel panel: NSRect) -> NSRect {
        let m = ClipboardPanelMetrics.shadowMargin
        return panel.insetBy(dx: -m, dy: -m)
    }

    private func place() {
        guard let screen = targetScreen() else { return }
        let height = frame.height - 2 * ClipboardPanelMetrics.shadowMargin
        let panel = ClipboardPlacement.opening(height: height, screen: screen.frame, visible: screen.visibleFrame, remembered: remembered)
        setFrame(Self.windowFrame(forPanel: panel), display: false)
    }

    /// The panel's top edge stays where it is when the list grows or shrinks; a card that would run off the bottom of the screen is
    /// lifted to fit.
    private func setHeight(_ height: CGFloat) {
        let m = ClipboardPanelMetrics.shadowMargin
        guard abs(frame.height - 2 * m - height) > 0.5 else { return }
        let top = frame.maxY - m
        var panel = NSRect(x: frame.minX + m, y: top - height, width: frame.width - 2 * m, height: height)
        if let screen = self.screen ?? NSScreen.main { panel = ClipboardPlacement.clamp(panel, screen: screen.frame, visible: screen.visibleFrame) }
        setFrame(Self.windowFrame(forPanel: panel), display: true)
    }

    // ── Dragging ────────────────────────────────────────────────────────────

    /// A press on the bar or the card moves it, as the system's panel does, unless it is on something that takes the press itself: the
    /// search field, the chips, the list.
    private func startsADrag(at point: NSPoint) -> Bool {
        guard let host = contentView, let superview = host.superview else { return false }
        var view = host.hitTest(superview.convert(point, from: nil))
        while let v = view {
            if v is NSControl || v is NSTextView || v is NSTableView || v is ClipboardChipView { return false }
            view = v.superview
        }
        return true
    }

    /// Returns whether the event was part of a drag.
    private func handleDrag(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            guard event.window === self, startsADrag(at: event.locationInWindow), let screen = self.screen ?? NSScreen.main else { return false }
            let m = ClipboardPanelMetrics.shadowMargin
            drag = ClipboardPlacement.Drag(panel: frame.insetBy(dx: m, dy: m), pointer: NSEvent.mouseLocation,
                                           screen: screen.frame, visible: screen.visibleFrame)
            return true
        case .leftMouseDragged:
            guard var d = drag else { return false }
            let caught = d.moved(to: NSEvent.mouseLocation)
            drag = d
            setFrame(Self.windowFrame(forPanel: d.frame), display: true)
            // The tick from the trackpad when it catches on the middle or on its usual height, as the system's does.
            if caught { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            return true
        case .leftMouseUp:
            guard let d = drag else { return false }
            drag = nil
            if let screen = self.screen ?? NSScreen.main { remembered = ClipboardPlacement.offset(of: d.frame, on: screen.frame) }
            return true
        default:
            return false
        }
    }

    // ── Keys ────────────────────────────────────────────────────────────────

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handle(event) { return }
        // The window is bigger than the panel (a margin holds the shadow): a click in the margin or in the gap between the bar and the
        // card is a click away from it, and closes it, as the system's panel does, and is not swallowed as a click on the panel.
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type), event.window === self,
           !host.isOnAShape(host.convert(event.locationInWindow, from: nil)) {
            dismissFromPanel()
            return
        }
        if handleDrag(event) { return }
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

    override func layout() {
        super.layout()
        let m = ClipboardPanelMetrics.shadowMargin
        content.frame = NSRect(x: m, y: m, width: bounds.width - 2 * m, height: max(0, bounds.height - 2 * m))
        updateShadow()
    }

    /// The two shapes (the card only when it is showing), in this view's coordinates.
    func shapeRectsInHost() -> [(rect: NSRect, radius: CGFloat)] {
        let m = ClipboardPanelMetrics.shadowMargin
        let contentHeight = bounds.height - 2 * m
        guard contentHeight > 0 else { return [] }
        // The shapes are in the content's flipped coordinates; this view is not flipped.
        return content.shapeFrames().map { (NSRect(x: m + $0.rect.minX, y: m + contentHeight - $0.rect.maxY, width: $0.rect.width, height: $0.rect.height), $0.radius) }
    }

    /// Whether `point` (in this view's coordinates) is on the bar or the card. Anywhere else in the window (the margin for the shadow, and
    /// the gap between the two) is not the panel: a click there is a click away from it.
    func isOnAShape(_ point: NSPoint) -> Bool { shapeRectsInHost().contains { $0.rect.contains(point) } }

    func updateShadow() {
        let m = ClipboardPanelMetrics.shadowMargin
        guard bounds.height - 2 * m > 0 else { return }
        let shapes = shapeRectsInHost()
        let all = CGMutablePath(), hole = CGMutablePath()
        hole.addRect(bounds)
        for (rect, radius) in shapes {
            all.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            hole.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        }
        let lab = (opacity: ClipboardPanelMetrics.shadowOpacity, radius: ClipboardPanelMetrics.shadowRadius, drop: ClipboardPanelMetrics.shadowDrop)
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
    /// The frosting, under the glass: a blur of what is behind the window.
    private let frost: BackdropBlurView
    /// Views, not bare layers: the glass is drawn over a layer of its parent's, and under a view added after it. The black is under what
    /// the shape holds and the rim's light over it.
    private let tint = ClipboardTintView()
    private let rim = ClipboardTintView()
    private let edge = EdgeView()
    /// How far the glass reaches below the shape before the shape's clip cuts it off. Where it is 0 the glass's own edge shows at the
    /// bottom: the lens that bends what is behind it, and its light along the edge.
    var bottomBleed: CGFloat = ClipboardPanelMetrics.glassBleed {
        didSet { needsLayout = true }
    }

    init(kind: Kind) {
        self.kind = kind
        self.bottomBleed = kind == .card ? ClipboardPanelMetrics.cardBottomBleed : ClipboardPanelMetrics.glassBleed
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
        if kind == .card {
            frost = BackdropBlurView(sigma: ClipboardPanelMetrics.cardBlur, frost: ClipboardPanelMetrics.cardFrost)
        } else {
            frost = BackdropBlurView(sigma: ClipboardPanelMetrics.pillBlur)
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = r
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true       // nothing square shows at the corners, and the window's shadow follows this shape
        // The card's frost is over its glass, so that the glass's lens bends the backdrop before it is blurred (see `cardFrostProfile`); the
        // bar's, which is slight, is under it.
        if kind != .card { addSubview(frost) }
        addSubview(material)
        if kind == .card { addSubview(frost) }

        tint.stops = { [kind] h in ClipboardPanelMetrics.splitTint(card: kind == .card, height: h).base }
        addSubview(tint)

        addSubview(body)

        rim.stops = { [kind] h in ClipboardPanelMetrics.splitTint(card: kind == .card, height: h).rim }
        addSubview(rim)

        edge.wantsLayer = true
        edge.layer?.cornerRadius = r
        edge.layer?.cornerCurve = .continuous
        edge.layer?.borderWidth = 0          // the rims are in the tint's stops, where the system's panel has them
        addSubview(edge)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func refreshFrost() { frost.refreshMask(); needsLayout = true }

    override func layout() {
        super.layout()
        // The glass is taller than the shape; the shape's clip (rounded corners, `masksToBounds`) cuts the rest off.
        let bleed = ClipboardPanelMetrics.glassBleed
        material.frame = NSRect(x: 0, y: -bottomBleed, width: bounds.width, height: bounds.height + bleed + bottomBleed)
        frost.overhangTop = bleed
        frost.overhangBottom = bottomBleed
        frost.frame = material.frame
        body.frame = bounds
        tint.frame = bounds
        rim.frame = bounds
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
        card.refreshFrost()
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
            updateEdgeLens(width: w)
        } else {
            card.isHidden = true
        }
        onLayout?()
    }

    // ── The lens along the card's bottom edge ───────────────────────────────

    private var lensWidth: CGFloat = 0

    /// The list's layer, for tests.
    var listLayer: CALayer? { scroll.layer }

    /// A Core Image filter on the list's layer: a distortion along a line at the card's bottom edge, so the rows' words and icons bend
    /// the way the backdrop does where the glass's edge is. It acts on the list only, not on the glass or the chips.
    func updateEdgeLens(width: CGFloat? = nil) {
        let w = width ?? lensWidth
        lensWidth = w
        scroll.wantsLayer = true
        scroll.layerUsesCoreImageFilters = true
        guard let layer = scroll.layer, let filter = CIFilter(name: "CIBumpDistortionLinear") else { return }
        // The list is a flipped view (its origin is at the top), and Core Image takes that origin: the card's bottom edge is y = height.
        filter.setValue(CIVector(x: w / 2, y: scroll.isFlipped ? scroll.bounds.height : 0), forKey: "inputCenter")
        filter.setValue(NSNumber(value: Double(M.edgeLensDepth)), forKey: "inputRadius")
        filter.setValue(NSNumber(value: 0), forKey: "inputAngle")          // a horizontal line
        filter.setValue(NSNumber(value: M.edgeLensScale), forKey: "inputScale")
        layer.filters = [filter]
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
        NSBezierPath(roundedRect: rect, xRadius: ClipboardPanelMetrics.selectionRadius, yRadius: ClipboardPanelMetrics.selectionRadius).fill()
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

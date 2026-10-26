import AppKit
import PowerKit

// ── Menu bar backdrop ───────────────────────────────────────────────────────
//
// A solid black strip behind the menu bar on every display, so the wallpaper
// stops showing through it.
//
// The menu bar is transparent: the system draws its items over whatever is
// behind it, and there is no switch to put a fill there. What an app CAN do is
// own a window in that strip, one level under the menu bar, which is what this
// is. The menu bar's own items, and Anode's widgets (status windows, above the
// menu bar), draw over it untouched.
//
// Costs nothing while idle: it is built once and rebuilt only when the screens
// or the Space change. No timer, nothing on the tick.

/// Where the strip goes. Pure so the arithmetic is testable without a display.
enum MenuBarBackdropGeometry {

    /// The wedge radius, in points: a little ABOVE macOS 27's window corner radius.
    ///
    /// Fits of the real curve kept coming out low, because a window's own dark
    /// outline sits just outside its edge and reads as part of the wallpaper. A
    /// wedge that is too small leaves that outline showing as a thin dark arc beside
    /// the curve (measured on a grey bar: 14 left a purple fringe, 15 left the arc
    /// exactly along the wedge's own edge), while one a little too big only hides a
    /// fraction of a point of the window's corner. A BIGGER radius is a bigger
    /// wedge, so it errs the safe way.
    static let cornerRadius: CGFloat = 17

    /// How far the strip reaches over a window's top edge, in points. ZERO: the bar
    /// ends exactly where the window begins. It was 1 pt, to hide the window's lighter
    /// top highlight row, and was reported as sitting 1–2 px too far down — a point
    /// is two physical pixels. The rim code in `shape` stays, for the day a value
    /// between the two is wanted.
    static let rimCover: CGFloat = 0

    /// How far the rim runs into each corner zone, so it overlaps the wedge. See `shape`.
    static let rimCornerOverlap: CGFloat = 5

    /// The strip, the seam under it, the rim and its two corner wedges as one outline,
    /// in a window of `size` whose origin is bottom-left.
    ///
    /// One plain full-width bar, with no allowance for the notch: the strip's
    /// bottom edge sits a point or two below the notch's, and that is accepted. An
    /// earlier version carved a flat black foot out under the notch to keep the
    /// two flush, and it never stopped looking wrong — wider than the notch's
    /// rounded corners, then narrower, with a wallpaper hairline whenever it
    /// missed.
    ///
    /// From the top: the bar (the notch's height); the SEAM, the 1 pt margin macOS
    /// leaves between the bar and a maximised window, which shows the wallpaper as a
    /// hairline unless something covers it; the RIM, the top `rim` points of the
    /// window itself, whose lighter highlight row reads as a gap if the bar stops
    /// just above it; and, hanging from the window-top line, the two wedges that
    /// fill what a window's rounded corners leave open.
    ///
    /// The rim is only the STRAIGHT part of the top edge, between the two wedges. In
    /// the corner zones the window's own edge curves away below the line, and a rim
    /// run across them painted a flat stripe over the top of the curve.
    ///
    /// Built by hand because `NSBezierPath.cgPath` needs macOS 14 and the package
    /// targets 13.
    static func shape(in size: CGSize, seam: CGFloat = 0, rim: CGFloat = 0) -> CGPath {
        let r = cornerRadius, w = size.width
        let path = CGMutablePath()
        // `r` is where a window's top edge sits: the seam is above it, the bar above that.
        path.addRect(CGRect(x: 0, y: r, width: w, height: size.height - r))
        // Overlapping the wedges by `rimCornerOverlap` on each side, not just meeting them:
        // where a wedge begins it is thinner than the rim is tall (0.5 pt thick 4 pt along),
        // so a rim that stopped at the tangent point left a sliver of the window's own
        // top highlight showing — one or two lighter pixels at x ≈ 15–18 and ≈ 1785.
        if rim > 0 {
            let inset = max(0, r - rimCornerOverlap)
            path.addRect(CGRect(x: inset, y: r - rim, width: max(0, w - 2 * inset), height: rim))
        }
        // Left wedge: the square under the window-top line's left end minus the
        // quarter-disc the window's own corner occupies. Two anti-aliased edges that
        // meet exactly leave a dotted fringe of wallpaper between them (seen, zoomed
        // in, along the whole curve), which is why `cornerRadius` rounds up.
        let rw = r
        path.move(to: CGPoint(x: 0, y: r))
        path.addLine(to: CGPoint(x: rw, y: r))
        path.addArc(center: CGPoint(x: rw, y: r - rw), radius: rw,
                    startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        path.closeSubpath()
        // Right wedge, mirrored.
        path.move(to: CGPoint(x: w, y: r))
        path.addLine(to: CGPoint(x: w - rw, y: r))
        path.addArc(center: CGPoint(x: w - rw, y: r - rw), radius: rw,
                    startAngle: .pi / 2, endAngle: 0, clockwise: true)
        path.closeSubpath()
        return path
    }

    /// How much of the strip is tint. The solid modes are fully opaque, so the
    /// wallpaper cannot show at all; the blur mode uses a constant light tint, and its
    /// slider controls the BLUR, not this (see `blurRadius`).
    ///
    /// The slider used to set this tint's opacity over a fixed-strength blur, which
    /// meant its far end was just black: the blur view has no adjustable strength, and
    /// its dark glass material darkened whatever it covered (measured: 0.24 under a
    /// 40% tint, against 0.47 for the wallpaper itself).
    static func tintAlpha(mode: MenuBarBackdropMode) -> CGFloat {
        switch mode {
        case .off: return 0
        case .solid, .solidFollow: return 1
        case .blur: return blurTintAlpha
        }
    }

    /// Just enough tint to keep the menu text readable over a busy wallpaper.
    static let blurTintAlpha: CGFloat = 0.30

    /// The strongest blur, as the backdrop filter's radius. Measured over 24 pt stripes,
    /// contrast fell 1.00 → 0.89 → 0.61 → 0.25 → 0.10 at radius 3, 8, 12, 20, 40, with the
    /// average brightness unchanged — a real blur, not a darkening — so 45 is well into
    /// "the stripes are gone".
    static let blurMaxRadius: CGFloat = 45

    /// The window server's blur radius for a blur `amount` of 0 (see-through: none)
    /// to 1 (the strongest). Zero for every other mode.
    static func blurRadius(mode: MenuBarBackdropMode, amount: Double) -> CGFloat {
        guard mode == .blur else { return 0 }
        return blurMaxRadius * CGFloat(min(max(amount, 0), 1))
    }

    /// How far the blur — and the tint over it — reach below the bar and its seam, in
    /// points: a full point, two physical pixels. A window's top edge carries a lighter
    /// highlight exactly that tall (rows reading 0.39 and 0.38 against a 0.29 bar and a
    /// 0.25 window), and the blur stopping half way, one row short, left half of it
    /// showing as a thin light line — "a 1 px gap". It was half a point, and its extra
    /// row had no tint, so it also came out brighter than the bar around it.
    static let blurExtra: CGFloat = 1.0

    /// How far the strip reaches over a window's top edge in `mode`: the blur mode, whose
    /// soft edge must meet the window with no line between, and nothing for the solid
    /// modes, whose bar was reported 1–2 px too far down at a full point.
    static func rim(for mode: MenuBarBackdropMode) -> CGFloat {
        mode == .blur ? blurExtra : rimCover
    }

    /// The tint for a bar whose text is white (`darkBar`) or black, optionally
    /// pulled toward the colour of the window under it.
    ///
    /// The system picks the text colour from the wallpaper and will not be told
    /// otherwise, so a window colour is only used as far as the text still reads on
    /// it: a dark bar goes up to 0.40 luminance, a light one down to 0.60. A colour
    /// past the limit is moved TO the limit, keeping its hue — it used to be thrown
    /// away for plain black, and a translucent titlebar with bright content showing
    /// through (Messages) then came out as black blotches inside a grey bar.
    static func tint(darkBar: Bool, windowTop: NSColor?, alpha: CGFloat) -> NSColor {
        let base = fill(darkBar: darkBar)
        guard let c = windowTop?.usingColorSpace(.sRGB) else {
            return base.withAlphaComponent(alpha)
        }
        return limited(c, darkBar: darkBar).withAlphaComponent(alpha)
    }

    static let darkBarLimit: CGFloat = 0.40
    static let lightBarLimit: CGFloat = 0.60

    private static func luminance(_ c: NSColor) -> CGFloat {
        0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    }

    /// `c` moved, if it must be, to the nearest colour the text can be read on.
    static func limited(_ c: NSColor, darkBar: Bool) -> NSColor {
        let l = luminance(c)
        if darkBar {
            guard l > darkBarLimit else { return c }
            let k = darkBarLimit / l                       // scale down: same hue, less light
            return NSColor(srgbRed: c.redComponent * k, green: c.greenComponent * k,
                           blue: c.blueComponent * k, alpha: 1)
        }
        guard l < lightBarLimit else { return c }
        let k = (lightBarLimit - l) / max(1 - l, 0.0001)   // mix toward white
        return NSColor(srgbRed: c.redComponent + (1 - c.redComponent) * k,
                       green: c.greenComponent + (1 - c.greenComponent) * k,
                       blue: c.blueComponent + (1 - c.blueComponent) * k, alpha: 1)
    }

    /// A captured row with every column that no window sits under put back to the
    /// plain bar colour. The capture reads whatever is at the strip — a window's top
    /// edge, or the wallpaper where there is no window — and the wallpaper is exactly
    /// what the bar exists to hide. `spans` are the windows' horizontal extents in the
    /// bar's own x; the row's columns are spread evenly across `width - 2 * inset`.
    static func masked(_ row: [NSColor], spans: [ClosedRange<CGFloat>], inset: CGFloat,
                       width: CGFloat, base: NSColor) -> [NSColor] {
        guard !row.isEmpty else { return row }
        let step = (width - 2 * inset) / CGFloat(row.count)
        return row.enumerated().map { i, colour in
            let centre = inset + (CGFloat(i) + 0.5) * step
            return spans.contains { $0.contains(centre) } ? colour : base
        }
    }

    /// A row softened sideways: two passes of a 1-2-1 kernel, ends held. A window's
    /// top edge is not smooth — a sidebar, a tab, a bubble showing through — and a bar
    /// that followed every column exactly showed each of those as a hard vertical
    /// edge. This is the "diffusion", and costs the match only a few dozen points.
    static func smoothed(_ row: [NSColor]) -> [NSColor] {
        guard row.count > 2 else { return row }
        func pass(_ r: [NSColor]) -> [NSColor] {
            r.indices.map { i in
                let a = r[max(0, i - 1)].usingColorSpace(.sRGB)!, b = r[i].usingColorSpace(.sRGB)!,
                    c = r[min(r.count - 1, i + 1)].usingColorSpace(.sRGB)!
                func m(_ f: (NSColor) -> CGFloat) -> CGFloat { (f(a) + 2 * f(b) + f(c)) / 4 }
                return NSColor(srgbRed: m(\.redComponent), green: m(\.greenComponent),
                               blue: m(\.blueComponent), alpha: 1)
            }
        }
        return pass(pass(row))
    }

    /// `tint` for each colour in a row, left to right: what a window's top edge
    /// turns into across the bar. Each stop is clamped on its own, so a window
    /// that is dark on the left and bright on the right fades in where the text
    /// would still read and stays plain where it would not.
    static func tints(darkBar: Bool, windowTop: [NSColor]?, alpha: CGFloat) -> [NSColor] {
        guard let row = windowTop, !row.isEmpty else {
            return [tint(darkBar: darkBar, windowTop: nil, alpha: alpha)]
        }
        return smoothed(row).map { tint(darkBar: darkBar, windowTop: $0, alpha: alpha) }
    }

    /// Is a window with these bounds meeting the bar — top edge at the bar's
    /// bottom, spanning nearly the screen's width? Same coordinate space for all
    /// three arguments (the window server's: origin top-left, y down).
    static func meetsBar(bounds: CGRect, barBottom: CGFloat, screenWidth: CGFloat) -> Bool {
        abs(bounds.minY - barBottom) <= 3 && bounds.width >= screenWidth * 0.95
    }

    /// The strip's window: the strip, the seam under it, and room below that for
    /// the corner wedges. The extra height is transparent and click-through.
    static func windowFrame(forStrip strip: NSRect, seam: CGFloat = 0) -> NSRect {
        NSRect(x: strip.minX, y: strip.minY - seam - cornerRadius,
               width: strip.width, height: strip.height + seam + cornerRadius)
    }

    /// The margin between the bar's bottom and the top of the visible frame: 1 pt
    /// on the notched panel measured here (38 pt bar, visible frame ending 39 pt
    /// down). Zero when there is no such gap.
    static func seam(strip: NSRect, screenFrame: NSRect, visibleFrame: NSRect) -> CGFloat {
        max(0, (screenFrame.maxY - visibleFrame.maxY) - strip.height)
    }

    /// The strip for a screen, or nil when there is no menu bar to hide.
    ///
    /// The bar's height is the notch's where there is one (`safeAreaTop`, which
    /// matches the screen's auxiliary top areas exactly: 38 pt on a 1169 pt panel),
    /// so the strip's bottom edge is flush with the notch's. It was the gap between
    /// the screen's top and its visible frame before, and that is one point TALLER:
    /// macOS leaves a 1 pt margin under the bar, so the strip stuck out 1–2 px
    /// below the notch. Without a notch the gap is all there is to go on.
    ///
    /// Zero means the bar is hidden (auto-hide, or a full-screen Space), and a strip
    /// then would sit on top of the content with no bar to justify it.
    static func strip(screenFrame: NSRect, visibleFrame: NSRect, safeAreaTop: CGFloat) -> NSRect? {
        let height = safeAreaTop > 0 ? safeAreaTop : screenFrame.maxY - visibleFrame.maxY
        // A notched screen in a full-screen Space still reports its inset but has no
        // bar to cover; the visible frame says so by reaching the top.
        guard height > 0, visibleFrame.maxY < screenFrame.maxY else { return nil }
        return NSRect(x: screenFrame.minX, y: screenFrame.maxY - height,
                      width: screenFrame.width, height: height)
    }

    /// What to fill the strip with so the bar's text stays readable.
    ///
    /// The system chooses the menu bar's text colour from the brightness of the
    /// WALLPAPER behind it and ignores every window, this one included. Measured
    /// with a probe on a wallpaper that shuffles every minute: a bright photo flipped
    /// the text to black, and black text on a black strip is invisible. So the strip
    /// follows the text rather than the other way round.
    static func fill(darkBar: Bool) -> NSColor { darkBar ? .black : .white }
}

/// A layer-backed view whose fill is a row of colours blended left to right,
/// cut to the strip's shape.
private final class TintView: NSView {
    override func makeBackingLayer() -> CALayer { CAGradientLayer() }
    private var gradient: CAGradientLayer { layer as! CAGradientLayer }
    private(set) var applied: [NSColor] = []

    init(frame: NSRect, seam: CGFloat, rim: CGFloat) {
        super.init(frame: frame)
        wantsLayer = true
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        let mask = CAShapeLayer()
        mask.path = MenuBarBackdropGeometry.shape(in: frame.size, seam: seam, rim: rim)
        gradient.mask = mask
    }
    required init?(coder: NSCoder) { fatalError() }

    func setFill(_ colors: [NSColor], animated: Bool) {
        guard !Self.same(colors, applied) else { return }
        applied = colors
        // A gradient needs two stops; one colour is the same colour twice.
        let cg = (colors.count == 1 ? colors + colors : colors).map { $0.cgColor }
        if animated {
            let fade = CABasicAnimation(keyPath: "colors")
            fade.fromValue = gradient.presentation()?.colors ?? gradient.colors
            fade.toValue = cg
            fade.duration = 0.4
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // A changed stop COUNT cannot be interpolated; the animation then
            // snaps, which is the right fallback and not worth a special case.
            gradient.add(fade, forKey: "colors")
        }
        gradient.colors = cg
    }

    /// Within a hair is the same: a capture's noise must not restart the fade.
    static func same(_ a: [NSColor], _ b: [NSColor]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { x, y in
            guard let x = x.usingColorSpace(.sRGB), let y = y.usingColorSpace(.sRGB) else { return false }
            return abs(x.redComponent - y.redComponent) < 0.012
                && abs(x.greenComponent - y.greenComponent) < 0.012
                && abs(x.blueComponent - y.blueComponent) < 0.012
                && abs(x.alphaComponent - y.alphaComponent) < 0.012
        }
    }
}

/// A blur of what is behind the window, with a radius of our choosing, cut to a shape.
///
/// PRIVATE API, and the only way to get all three at once. `NSVisualEffectView` has no
/// adjustable strength and its dark material darkened everything under it; the window
/// server's `CGSSetWindowBackgroundBlurRadius` has a radius but blurs a window's whole
/// rectangle whatever it draws (measured: a half-drawn window blurred both halves) and
/// only blurs what is inside its own bounds (three narrow windows showed seams). A
/// `CABackdropLayer` with a Gaussian `CAFilter` — what `NSVisualEffectView` is built on —
/// takes a radius AND a shape mask (measured: the masked half blurred to contrast 0.02,
/// the rest stayed at 1.00).
///
/// Both classes are looked up by name, so if a future macOS removes either the blur is
/// simply absent and the tint stays: the bar never breaks.
enum BackdropBlur {
    /// nil when the private classes are not there.
    static func makeLayer(frame: CGRect, mask: CGPath) -> CALayer? {
        guard let layerClass = NSClassFromString("CABackdropLayer") as? CALayer.Type else { return nil }
        let layer = layerClass.init()
        layer.frame = frame
        layer.setValue(true, forKey: "windowServerAware")
        layer.setValue("anode.menubar.backdrop", forKey: "groupName")
        layer.setValue(1.0, forKey: "scale")
        layer.setValue(0.0, forKey: "bleedAmount")
        let shape = CAShapeLayer()
        shape.path = mask
        shape.fillColor = NSColor.black.cgColor
        layer.mask = shape
        return layer
    }

    /// A NEW filter each time: reassigning the same filter object after changing its radius
    /// is not seen as a change (measured: the blur stayed at its first radius).
    @discardableResult
    static func set(radius: CGFloat, on layer: CALayer) -> Bool {
        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else { return false }
        let selector = NSSelectorFromString("filterWithType:")
        guard filterClass.responds(to: selector),
              let filter = filterClass.perform(selector, with: "gaussianBlur")?.takeUnretainedValue() as? NSObject
        else { return false }
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        layer.setValue([filter], forKey: "filters")
        return true
    }
}

/// The strip's face: the blur (blur mode only) and the tint over it, both cut to the
/// strip's shape.
///
/// A maximised window's top corners are curved, so just below a straight-edged
/// strip a sliver of wallpaper shows in each corner; the shape's two wedges fill
/// it (see `MenuBarBackdropGeometry.shape`). The blur has the SAME shape as the tint,
/// so the wedges are blurred too and match the bar, not a lighter patch beside it.
fileprivate final class BackdropView: NSView {
    private let tint: TintView
    private let blur: CALayer?

    init(size: CGSize, seam: CGFloat, rim: CGFloat, tints: [NSColor]) {
        let frame = CGRect(origin: .zero, size: size)
        tint = TintView(frame: frame, seam: seam, rim: rim)
        blur = BackdropBlur.makeLayer(frame: frame,
                                      mask: MenuBarBackdropGeometry.shape(in: size, seam: seam, rim: rim))
        super.init(frame: frame)
        wantsLayer = true
        if let blur { layer?.addSublayer(blur); blur.isHidden = true }
        addSubview(tint)
        tint.setFill(tints, animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(tints: [NSColor]) {
        tint.setFill(tints, animated: true)
    }

    /// Show the blur at `radius`, or hide it. Cheap — a slider drag does only this.
    func setBlur(radius: CGFloat, visible: Bool) {
        guard let blur else { return }
        blur.isHidden = !visible
        if visible { BackdropBlur.set(radius: radius, on: blur) }
    }
}

/// Borderless and inert. A window is clamped below the menu bar unless it says
/// otherwise, and this one has to sit in it.
fileprivate final class BackdropWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// This bar in the window server's coordinates (origin top-left, y down), for
    /// asking what window is under it.
    let screenLeft: CGFloat
    let screenTop: CGFloat
    let barBottom: CGFloat
    let barHeight: CGFloat
    let screenWidth: CGFloat
    let displayID: CGDirectDisplayID
    let view: BackdropView
    /// A capture is in flight; the next tick waits rather than stacking another.
    var capturing = false
    /// What was last read off Anode's own window, so a tick re-draws it only when
    /// the window has moved.
    var ownKey = ""

    fileprivate init(frame: NSRect, strip: NSRect, seam: CGFloat, rim: CGFloat, screen: NSScreen,
                     primaryHeight: CGFloat, tints: [NSColor]) {
        screenLeft = screen.frame.minX
        screenTop = primaryHeight - screen.frame.maxY
        barBottom = primaryHeight - strip.minY
        barHeight = strip.height
        screenWidth = screen.frame.width
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                     as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        view = BackdropView(size: frame.size, seam: seam, rim: rim, tints: tints)
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    }
}

final class MenuBarBackdrop {

    fileprivate var windows: [BackdropWindow] = []
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var settingsTokens: [AnyObject] = []
    /// Zero-width, so nothing shows in the bar. It exists for its button: a status
    /// item's `effectiveAppearance` is the one place an app can read the menu bar's
    /// light/dark choice — `NSApp.effectiveAppearance` stays on the system setting.
    private let probe = NSStatusBar.system.statusItem(withLength: 0)
    private var appearanceWatch: NSKeyValueObservation?
    private var darkBar = true
    private var pendingRetint: DispatchWorkItem?
    private var poll: Timer?
    private let settings = Settings.shared

    init() {
        appearanceWatch = probe.button?.observe(\.effectiveAppearance, options: [.initial, .new]) {
            [weak self] button, _ in
            let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua
            DispatchQueue.main.async { self?.setDarkBar(dark) }
        }
        refresh()
        let center = NotificationCenter.default
        // Posted on every wake and on changes that move no screen, so `refresh`
        // does its own comparing and a redundant call is a no-op.
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                WindowEdgeSampler.forgetDisplays()
                self?.refresh()
            })
        // Anode's OWN windows announce themselves, so they are read on the event.
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didChangeScreenNotification,
                     NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] note in
                // The strip's own windows and the status items' are in this stream
                // too; none of them is what is being looked for.
                guard let self, let w = note.object as? NSWindow, w.styleMask.contains(.titled)
                else { return }
                self.scheduleRetint()
            })
        }
        let ws = NSWorkspace.shared.notificationCenter
        // A full-screen Space has no menu bar, and the visible frame says so only
        // once that Space is the one being looked at.
        workspaceObservers.append(ws.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        workspaceObservers.append(ws.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in self?.scheduleRetint() })
        // The mode is live: leaving the follow mode stops every read at once, and
        // Off takes the strip away without a relaunch.
        settingsTokens.append(settings.observe(Settings.Key.menuBarBackdropMode) { [weak self] in
            self?.syncPolling()
            self?.refresh(force: true)
        })
        // The blur amount only changes a radius, so it must not rebuild the windows:
        // dragging the slider would then flicker the bar on every step.
        settingsTokens.append(settings.observe(Settings.Key.menuBarBackdropBlur) { [weak self] in
            self?.applyBlurRadius()
        })
        syncPolling()
    }

    deinit {
        poll?.invalidate()
        NSStatusBar.system.removeStatusItem(probe)
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    private var mode: MenuBarBackdropMode { settings.menuBarBackdropMode }
    private var follows: Bool { mode == .solidFollow }
    private var alpha: CGFloat { MenuBarBackdropGeometry.tintAlpha(mode: mode) }
    private var blurRadius: CGFloat {
        MenuBarBackdropGeometry.blurRadius(mode: mode, amount: settings.menuBarBackdropBlur)
    }

    /// Push the current blur amount to the bars. Cheap, and the only thing a slider drag does.
    private func applyBlurRadius() {
        let radius = blurRadius, visible = mode == .blur
        windows.forEach { $0.view.setBlur(radius: radius, visible: visible) }
    }
    private func plain() -> [NSColor] {
        MenuBarBackdropGeometry.tints(darkBar: darkBar, windowTop: nil, alpha: alpha)
    }

    private func setDarkBar(_ dark: Bool) {
        guard dark != darkBar else { return }
        darkBar = dark
        NSLog("anode.backdrop darkBar=\(dark)")
        retint(force: true)
    }

    // ── Reading ─────────────────────────────────────────────────────────────

    /// Another app's window moving or changing its top edge is announced to
    /// nobody, so while the setting is on the bar looks once a second. Cheap: the
    /// window list is a system call that returns bounds and owners, and nothing is
    /// captured unless another app's window is actually sitting under the bar.
    private func syncPolling() {
        poll?.invalidate()
        poll = nil
        guard follows else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.retint(force: false) }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    /// A drag posts a move per frame; one read after it settles is enough.
    private func scheduleRetint() {
        pendingRetint?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.retint(force: true) }
        pendingRetint = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private struct Under {
        enum Kind {
            case nothing
            /// `fullWidth`: spans the screen, so the off-screen estimate is fair for it.
            case ownWindow(NSWindow, key: String, fullWidth: Bool)
            case otherApp
        }
        var kind: Kind
        /// The horizontal extent, in the bar's own x, of EVERY window whose top edge
        /// meets the bar — a snapped half-width window counts, which the first version
        /// (one window, at least 95% of the width) ignored.
        var spans: [ClosedRange<CGFloat>]
        static let none = Under(kind: .nothing, spans: [])
    }

    private func retint(force: Bool) {
        for bar in windows {
            guard follows else {
                bar.ownKey = ""
                bar.view.update(tints: plain())
                continue
            }
            switch under(bar).kind {
            case .nothing:
                bar.ownKey = ""
                apply(nil, to: bar)
            case .ownWindow(let window, let key, let fullWidth):
                // With Screen Recording allowed, read Anode's own titlebar off the
                // screen like any other window's: that is the colour actually shown.
                // The off-screen drawing below is only an estimate and runs darker
                // (measured on a titled window: 0.16 drawn against 0.22 on screen),
                // which left the bar a visible shade off the titlebar it meets.
                if ScreenRecordingAccess.isGranted {
                    bar.ownKey = ""
                    readOtherApp(under: bar)
                    continue
                }
                // Without it, only a window the width of the screen can be estimated.
                guard fullWidth else { bar.ownKey = ""; apply(nil, to: bar); continue }
                // Anode's titlebar is the same until the window moves or the
                // appearance flips, and drawing it is not free.
                guard force || key != bar.ownKey else { continue }
                bar.ownKey = key
                apply(Self.topEdgeColor(of: window).map { [$0] }, to: bar)
            case .otherApp:
                bar.ownKey = ""
                readOtherApp(under: bar)
            }
        }
    }

    private func apply(_ row: [NSColor]?, to bar: BackdropWindow) {
        bar.view.update(tints: MenuBarBackdropGeometry.tints(darkBar: darkBar, windowTop: row, alpha: alpha))
    }

    /// Read the edge of the window under the bar off the screen. Used for another
    /// app's window, and for Anode's own once Screen Recording is allowed. Asks for
    /// the permission the first time another app's window is found under the bar,
    /// once; until it is granted the bar stays plain.
    private func readOtherApp(under bar: BackdropWindow) {
        guard ScreenRecordingAccess.isGranted else {
            if !settings.screenCaptureAsked {
                settings.screenCaptureAsked = true
                ScreenRecordingAccess.request()
            }
            apply(nil, to: bar)
            return
        }
        guard !bar.capturing else { return }
        bar.capturing = true
        let r = MenuBarBackdropGeometry.cornerRadius
        // Just under the bar, clear of the corner wedges drawn over the ends.
        let rect = CGRect(x: r, y: bar.barHeight + 3, width: bar.screenWidth - 2 * r, height: 6)
        let id = bar.displayID
        Task { [weak self, weak bar] in
            let row = await WindowEdgeSampler.colors(onDisplay: id, rect: rect, columns: 48)
            await MainActor.run {
                guard let self, let bar else { return }
                bar.capturing = false
                // The window may have gone while the capture ran; a stale row
                // would tint the bar to something no longer there.
                guard self.follows else { return }
                let u = self.under(bar)
                if case .nothing = u.kind { return }
                self.apply(row.map {
                    MenuBarBackdropGeometry.masked($0, spans: u.spans, inset: r, width: bar.screenWidth,
                                                   base: MenuBarBackdropGeometry.fill(darkBar: self.darkBar))
                }, to: bar)
            }
        }
    }

    private func refresh(force: Bool = false) {
        guard mode != .off else {
            windows.forEach { $0.orderOut(nil) }
            windows = []
            return
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let planned: [Plan] = NSScreen.screens.compactMap {
            guard let strip = MenuBarBackdropGeometry.strip(
                screenFrame: $0.frame, visibleFrame: $0.visibleFrame,
                safeAreaTop: $0.safeAreaInsets.top) else { return nil }
            let seam = MenuBarBackdropGeometry.seam(strip: strip, screenFrame: $0.frame,
                                                    visibleFrame: $0.visibleFrame)
            return Plan(frame: MenuBarBackdropGeometry.windowFrame(forStrip: strip, seam: seam),
                        strip: strip, seam: seam, screen: $0)
        }
        // Same strips as already shown: leave the windows alone rather than
        // reordering them on every wake.
        guard force || planned.map(\.frame) != windows.map(\.frame) else { return }
        windows.forEach { $0.orderOut(nil) }
        windows = planned.map { makeWindow($0, primaryHeight: primaryHeight) }
        windows.forEach { $0.orderFrontRegardless() }
        applyBlurRadius()
        retint(force: true)
    }

    private struct Plan {
        let frame: NSRect, strip: NSRect, seam: CGFloat
        let screen: NSScreen
    }

    private func makeWindow(_ plan: Plan, primaryHeight: CGFloat) -> BackdropWindow {
        let frame = plan.frame
        let w = BackdropWindow(frame: frame, strip: plan.strip, seam: plan.seam,
                               rim: MenuBarBackdropGeometry.rim(for: mode),
                               screen: plan.screen, primaryHeight: primaryHeight, tints: plain())
        w.contentView = w.view
        // Clear, because the glass is the view's own and the rest is nothing.
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        // Click-through, and never part of the app's window bookkeeping — it must
        // not show in the Window menu or count as an open window.
        w.ignoresMouseEvents = true
        w.isExcludedFromWindowsMenu = true
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        // Just above ordinary windows (level 0) and well UNDER everything the system
        // draws on top of the screen. It was one under the menu bar (23), which put
        // it above Mission Control, App Exposé and the Apps overlay — they sit at 14
        // to 20 — and the strip covered their top rows, Spaces bar included. At 3
        // those overlays simply draw over it, with nothing to detect and no polling,
        // and the menu bar (24) still draws over it too.
        w.level = .floating
        // On every Space, but not full-screen ones (no `.fullScreenAuxiliary`):
        // the bar is hidden there and the strip would be a black band over the
        // content. `.stationary` keeps it out of Mission Control's shuffling.
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.setFrame(frame, display: false)
        return w
    }

    // ── What is under the bar ───────────────────────────────────────────────

    /// The windows meeting this bar, and whose the frontmost one is.
    ///
    /// The window server's list (front to back, with bounds and owner, none of
    /// which is gated) answers it. A window meets the bar when its top edge is within
    /// 3 pt of the bar's bottom, whatever its width.
    private func under(_ bar: BackdropWindow) -> Under {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return .none }
        var result = Under.none
        for entry in info {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let dict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  abs(bounds.minY - bar.barBottom) <= 3,
                  bounds.maxX > bar.screenLeft, bounds.minX < bar.screenLeft + bar.screenWidth
            else { continue }
            let lo = max(0, bounds.minX - bar.screenLeft), hi = min(bar.screenWidth, bounds.maxX - bar.screenLeft)
            result.spans.append(lo...hi)
            // The first one found is the frontmost, and decides whose it is.
            guard case .nothing = result.kind else { continue }
            if (entry[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier {
                if let number = entry[kCGWindowNumber as String] as? Int,
                   let own = NSApp.windows.first(where: { $0.windowNumber == number }) {
                    result.kind = .ownWindow(own, key: "\(number) \(bounds) \(darkBar)",
                                             fullWidth: MenuBarBackdropGeometry.meetsBar(
                                                bounds: bounds, barBottom: bar.barBottom,
                                                screenWidth: bar.screenWidth))
                }
            } else {
                result.kind = .otherApp
            }
        }
        return result
    }

    /// A few points below the window's top edge, clear of the rim highlight and of
    /// the traffic lights and title — the bar should pick up the titlebar, not the
    /// text on it. Needs no permission: a window drawing itself is its own business.
    static func topEdgeColor(of window: NSWindow) -> NSColor? {
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let scale = Double(rep.pixelsWide) / Double(frameView.bounds.width)
        return rep.colorAt(x: Int(Double(frameView.bounds.width) * 0.35 * scale), y: Int(4 * scale))
    }
}

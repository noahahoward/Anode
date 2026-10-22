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

    /// The wedge radius, in points: macOS 27's window corner radius, rounded UP.
    ///
    /// Two fits of the real curve disagreed — 14 against a flat backdrop, about 13
    /// from this screen's own pixels — and a wedge that is too small leaves a dotted
    /// fringe of wallpaper along the curve, while one that is a little too big only
    /// hides a fraction of a point of the window's corner. A BIGGER radius is a
    /// bigger wedge, so it errs the safe way; 14 left the fringe and 13 (tried, as
    /// "overlap") made it worse.
    static let cornerRadius: CGFloat = 15

    /// The strip, the seam under it and its two corner wedges as one outline, in a
    /// window of `size` whose origin is bottom-left.
    ///
    /// From the top: the bar (the notch's height), then the SEAM — the 1 pt margin
    /// macOS leaves between the bar and the top of a maximised window, which shows
    /// the wallpaper as a hairline unless something covers it — then, hanging from
    /// the window-top line, the two wedges. The seam is left open under the notch
    /// (`notch`, in the window's own x) so the strip's bottom edge stays flush with
    /// the notch's there, which is where it was seen sticking out.
    ///
    /// Built by hand because `NSBezierPath.cgPath` needs macOS 14 and the package
    /// targets 13.
    static func shape(in size: CGSize, seam: CGFloat = 0,
                      notch: ClosedRange<CGFloat>? = nil) -> CGPath {
        let r = cornerRadius, w = size.width
        let path = CGMutablePath()
        // `r` is where a window's top edge sits: the seam is above it, the bar above that.
        path.addRect(CGRect(x: 0, y: r + seam, width: w, height: size.height - r - seam))
        if seam > 0 {
            if let n = notch {
                path.addRect(CGRect(x: 0, y: r, width: n.lowerBound, height: seam))
                path.addRect(CGRect(x: n.upperBound, y: r, width: w - n.upperBound, height: seam))
            } else {
                path.addRect(CGRect(x: 0, y: r, width: w, height: seam))
            }
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

    /// How much of the strip is tint; the rest is the blur of what is behind it.
    ///
    /// The solid modes are fully opaque, so the wallpaper cannot show at all. Blur
    /// runs from 0.95 (a smear) down to 0.40 (the wallpaper plainly there, softened)
    /// as `translucency` goes 0 → 1; its default 0.3 is 0.785, which is what the
    /// glass was tuned at before it was adjustable.
    static func tintAlpha(mode: MenuBarBackdropMode, translucency: Double) -> CGFloat {
        switch mode {
        case .off: return 0
        case .solid, .solidFollow: return 1
        case .blur: return 0.95 - 0.55 * CGFloat(min(max(translucency, 0), 1))
        }
    }

    /// The tint for a bar whose text is white (`darkBar`) or black, optionally
    /// pulled toward the colour of the window under it.
    ///
    /// The system picks the text colour from the wallpaper and will not be told
    /// otherwise, so a window colour is taken only if the text would still read on
    /// it: a dark bar accepts a colour up to 0.40 luminance, a light one from 0.60.
    /// A bright page under white text would be unreadable, so it is refused and the
    /// plain fill stands.
    static func tint(darkBar: Bool, windowTop: NSColor?, alpha: CGFloat) -> NSColor {
        let base = fill(darkBar: darkBar)
        guard let c = windowTop?.usingColorSpace(.sRGB) else {
            return base.withAlphaComponent(alpha)
        }
        let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        let readable = darkBar ? luminance <= 0.40 : luminance >= 0.60
        return (readable ? c : base).withAlphaComponent(alpha)
    }

    /// `tint` for each colour in a row, left to right: what a window's top edge
    /// turns into across the bar. Each stop is clamped on its own, so a window
    /// that is dark on the left and bright on the right fades in where the text
    /// would still read and stays plain where it would not.
    static func tints(darkBar: Bool, windowTop: [NSColor]?, alpha: CGFloat) -> [NSColor] {
        guard let row = windowTop, !row.isEmpty else {
            return [tint(darkBar: darkBar, windowTop: nil, alpha: alpha)]
        }
        return row.map { tint(darkBar: darkBar, windowTop: $0, alpha: alpha) }
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

    /// How far the notch's black bottom edge reaches past the gap macOS reports
    /// between the two auxiliary top areas, on each side. MEASURED on the 1800 pt
    /// panel: the auxiliary gap is 790…1010 but the black on screen is 762…1037 at
    /// its lowest row, because the notch flares and rounds its corners. A cover
    /// sized to the gap alone sat under the notch as a narrow dangling strip.
    static let notchFlare: CGFloat = 27

    /// The notch's horizontal extent at its bottom edge, in a window starting at the
    /// screen's left edge, from the screen's two auxiliary top areas, or nil
    /// without a notch.
    static func notchSpan(left: NSRect?, right: NSRect?, screenFrame: NSRect) -> ClosedRange<CGFloat>? {
        guard let l = left, let r = right, !l.isEmpty, !r.isEmpty else { return nil }
        let lo = l.maxX - screenFrame.minX - notchFlare, hi = r.minX - screenFrame.minX + notchFlare
        return lo < hi ? lo...hi : nil
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

    init(frame: NSRect, seam: CGFloat, notch: ClosedRange<CGFloat>?) {
        super.init(frame: frame)
        wantsLayer = true
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        let mask = CAShapeLayer()
        mask.path = MenuBarBackdropGeometry.shape(in: frame.size, seam: seam, notch: notch)
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

/// The glass: a blur of whatever is behind the window, cut to the strip's shape,
/// with a tint over it.
///
/// A maximised window's top corners are curved, so just below a straight-edged
/// strip a sliver of wallpaper shows in each corner; the shape's two wedges fill
/// it (see `MenuBarBackdropGeometry.shape`). A window NOT at the screen's edge
/// gets the same wedges, which then read as the screen's own rounded corners.
fileprivate final class BackdropView: NSVisualEffectView {
    private let tint: TintView

    init(size: CGSize, seam: CGFloat, notch: ClosedRange<CGFloat>?, darkBar: Bool, tints: [NSColor]) {
        tint = TintView(frame: CGRect(origin: .zero, size: size), seam: seam, notch: notch)
        super.init(frame: CGRect(origin: .zero, size: size))
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: darkBar ? .darkAqua : .aqua)
        // The blur's mask has NO notch gap: it clips the view's subviews too, and
        // with the gap in it the black cover below was cut off one pixel row short,
        // leaving a hairline of wallpaper under the notch (measured: 0.49 0.35 0.24
        // at 38.0 pt). The tint keeps the gap; the cover fills it.
        let outline = MenuBarBackdropGeometry.shape(in: size, seam: seam, notch: nil)
        maskImage = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(outline)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            return true
        }
        addSubview(tint)
        tint.setFill(tints, animated: false)
        // The margin under the notch is filled with the notch's own black, not the
        // tint: left open it showed the wallpaper as a hairline exactly as wide as the
        // notch, and tinted it would read as a lip hanging below the notch. Black on
        // black is neither, and the bar stays flush with the notch's bottom edge.
        if seam > 0, let n = notch {
            let cover = NSView(frame: CGRect(x: n.lowerBound, y: MenuBarBackdropGeometry.cornerRadius,
                                             width: n.upperBound - n.lowerBound, height: seam))
            cover.wantsLayer = true
            cover.layer?.backgroundColor = NSColor.black.cgColor
            addSubview(cover)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(darkBar: Bool, tints: [NSColor]) {
        appearance = NSAppearance(named: darkBar ? .darkAqua : .aqua)
        tint.setFill(tints, animated: true)
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

    fileprivate init(frame: NSRect, strip: NSRect, seam: CGFloat, notch: ClosedRange<CGFloat>?,
                     screen: NSScreen, primaryHeight: CGFloat, darkBar: Bool, tints: [NSColor]) {
        screenLeft = screen.frame.minX
        screenTop = primaryHeight - screen.frame.maxY
        barBottom = primaryHeight - strip.minY
        barHeight = strip.height
        screenWidth = screen.frame.width
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                     as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        view = BackdropView(size: frame.size, seam: seam, notch: notch, darkBar: darkBar, tints: tints)
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
        for key in [Settings.Key.menuBarBackdropMode, Settings.Key.menuBarBackdropTranslucency] {
            settingsTokens.append(settings.observe(key) { [weak self] in
                self?.syncPolling()
                self?.refresh(force: true)
            })
        }
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
    private var alpha: CGFloat {
        MenuBarBackdropGeometry.tintAlpha(mode: mode, translucency: settings.menuBarBackdropTranslucency)
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

    private enum Under {
        case nothing
        case ownWindow(NSWindow, key: String)
        case otherApp
    }

    private func retint(force: Bool) {
        for bar in windows {
            guard follows else {
                bar.ownKey = ""
                bar.view.update(darkBar: darkBar, tints: plain())
                continue
            }
            switch under(bar) {
            case .nothing:
                bar.ownKey = ""
                apply(nil, to: bar)
            case .ownWindow(let window, let key):
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
        bar.view.update(darkBar: darkBar,
                        tints: MenuBarBackdropGeometry.tints(darkBar: darkBar, windowTop: row, alpha: alpha))
    }

    /// Ask for Screen Recording the first time another app's window is found
    /// under the bar, once, and read the edge only if it has been granted. Until
    /// then the bar stays on the plain glass.
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
                guard self.follows,
                      case .otherApp = self.under(bar) else { return }
                self.apply(row, to: bar)
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
            let notch = MenuBarBackdropGeometry.notchSpan(
                left: $0.auxiliaryTopLeftArea, right: $0.auxiliaryTopRightArea, screenFrame: $0.frame)
            return Plan(frame: MenuBarBackdropGeometry.windowFrame(forStrip: strip, seam: seam),
                        strip: strip, seam: seam, notch: notch, screen: $0)
        }
        // Same strips as already shown: leave the windows alone rather than
        // reordering them on every wake.
        guard force || planned.map(\.frame) != windows.map(\.frame) else { return }
        windows.forEach { $0.orderOut(nil) }
        windows = planned.map { makeWindow($0, primaryHeight: primaryHeight) }
        windows.forEach { $0.orderFrontRegardless() }
        retint(force: true)
    }

    private struct Plan {
        let frame: NSRect, strip: NSRect, seam: CGFloat
        let notch: ClosedRange<CGFloat>?
        let screen: NSScreen
    }

    private func makeWindow(_ plan: Plan, primaryHeight: CGFloat) -> BackdropWindow {
        let frame = plan.frame
        let w = BackdropWindow(frame: frame, strip: plan.strip, seam: plan.seam, notch: plan.notch,
                               screen: plan.screen, primaryHeight: primaryHeight,
                               darkBar: darkBar, tints: plain())
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

    /// The window meeting this bar, if any, and whose it is.
    ///
    /// The window server's list (front to back, with bounds and owner, none of
    /// which is gated) answers "which window is under the middle of the bar".
    private func under(_ bar: BackdropWindow) -> Under {
        let point = CGPoint(x: bar.screenLeft + bar.screenWidth / 2, y: bar.barBottom + 2)
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return .nothing }
        for entry in info {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let dict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.contains(point) else { continue }
            // The first window containing the point is the one in front there.
            guard MenuBarBackdropGeometry.meetsBar(bounds: bounds, barBottom: bar.barBottom,
                                                   screenWidth: bar.screenWidth) else { return .nothing }
            guard (entry[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier
            else { return .otherApp }
            guard let number = entry[kCGWindowNumber as String] as? Int,
                  let own = NSApp.windows.first(where: { $0.windowNumber == number }) else { return .nothing }
            return .ownWindow(own, key: "\(number) \(bounds) \(darkBar)")
        }
        return .nothing
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

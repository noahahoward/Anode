import AppKit

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

    /// macOS 27's window corner radius, in points. MEASURED rather than assumed:
    /// a titled window and a unified-toolbar window were drawn over a solid
    /// backdrop and the curve read off a screenshot; 14 fits every sample.
    static let cornerRadius: CGFloat = 14

    /// The strip and its two corner wedges as one outline, in a window of `size`
    /// whose origin is bottom-left. The bar occupies everything above the bottom
    /// `cornerRadius`; the wedges hang beneath its two ends.
    ///
    /// Built by hand because `NSBezierPath.cgPath` needs macOS 14 and the package
    /// targets 13.
    static func shape(in size: CGSize) -> CGPath {
        let r = cornerRadius, w = size.width
        let path = CGMutablePath()
        path.addRect(CGRect(x: 0, y: r, width: w, height: size.height - r))
        // Left wedge: the square under the bar's left end minus the quarter-disc
        // the window's own corner occupies (centre (r, 0)).
        path.move(to: CGPoint(x: 0, y: r))
        path.addLine(to: CGPoint(x: r, y: r))
        path.addArc(center: CGPoint(x: r, y: 0), radius: r,
                    startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        path.closeSubpath()
        // Right wedge, mirrored.
        path.move(to: CGPoint(x: w, y: r))
        path.addLine(to: CGPoint(x: w - r, y: r))
        path.addArc(center: CGPoint(x: w - r, y: 0), radius: r,
                    startAngle: .pi / 2, endAngle: 0, clockwise: true)
        path.closeSubpath()
        return path
    }

    /// How much of the glass is tint. The rest is the blur of what is behind it, so
    /// the bar reads as frosted rather than painted while the wallpaper stays an
    /// unrecognisable smear — the bar exists to stop it being a distraction.
    static let tintAlpha: CGFloat = 0.78

    /// The tint for a bar whose text is white (`darkBar`) or black, optionally
    /// pulled toward the colour of the window under it.
    ///
    /// The system picks the text colour from the wallpaper and will not be told
    /// otherwise, so a window colour is taken only if the text would still read on
    /// it: a dark bar accepts a colour up to 0.40 luminance, a light one from 0.60.
    /// A bright page under white text would be unreadable, so it is refused and the
    /// plain fill stands.
    static func tint(darkBar: Bool, windowTop: NSColor?) -> NSColor {
        let base = fill(darkBar: darkBar)
        guard let c = windowTop?.usingColorSpace(.sRGB) else {
            return base.withAlphaComponent(tintAlpha)
        }
        let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        let readable = darkBar ? luminance <= 0.40 : luminance >= 0.60
        return (readable ? c : base).withAlphaComponent(tintAlpha)
    }

    /// Is a window with these bounds meeting the bar — top edge at the bar's
    /// bottom, spanning nearly the screen's width? Same coordinate space for all
    /// three arguments (the window server's: origin top-left, y down).
    static func meetsBar(bounds: CGRect, barBottom: CGFloat, screenWidth: CGFloat) -> Bool {
        abs(bounds.minY - barBottom) <= 3 && bounds.width >= screenWidth * 0.95
    }

    /// The strip's window: the strip itself plus room below it for the corner
    /// fillets. The extra height is transparent and click-through.
    static func windowFrame(forStrip strip: NSRect) -> NSRect {
        NSRect(x: strip.minX, y: strip.minY - cornerRadius,
               width: strip.width, height: strip.height + cornerRadius)
    }

    /// The strip for a screen, or nil when there is no menu bar to hide.
    ///
    /// The bar's height is the gap between the screen's top and the top of its
    /// visible frame — what the system reports as taken by the menu bar — and on a
    /// notched display never less than the notch's safe-area inset, which is the
    /// bar's real height there. Zero means the bar is hidden (auto-hide, or a
    /// full-screen Space), and a strip then would sit on top of the content with no
    /// bar to justify it.
    static func strip(screenFrame: NSRect, visibleFrame: NSRect, safeAreaTop: CGFloat) -> NSRect? {
        let height = max(screenFrame.maxY - visibleFrame.maxY, safeAreaTop)
        guard height > 0 else { return nil }
        return NSRect(x: screenFrame.minX, y: screenFrame.maxY - height,
                      width: screenFrame.width, height: height)
    }
}

extension MenuBarBackdropGeometry {
    /// What to fill the strip with so the bar's text stays readable.
    ///
    /// The system chooses the menu bar's text colour from the brightness of the
    /// WALLPAPER behind it and ignores every window, this one included. Measured
    /// with a probe on a wallpaper that shuffles every minute: a bright photo flipped
    /// the text to black, and black text on a black strip is invisible. So the strip
    /// follows the text rather than the other way round.
    static func fill(darkBar: Bool) -> NSColor { darkBar ? .black : .white }
}

/// A layer-backed view whose fill is one animatable shape.
private final class TintView: NSView {
    override func makeBackingLayer() -> CALayer { CAShapeLayer() }
    private var shapeLayer: CAShapeLayer { layer as! CAShapeLayer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shapeLayer.path = MenuBarBackdropGeometry.shape(in: frame.size)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setFill(_ color: NSColor, animated: Bool) {
        let new = color.cgColor
        if animated {
            let fade = CABasicAnimation(keyPath: "fillColor")
            fade.fromValue = shapeLayer.presentation()?.fillColor ?? shapeLayer.fillColor
            fade.toValue = new
            fade.duration = 0.25
            shapeLayer.add(fade, forKey: "fillColor")
        }
        shapeLayer.fillColor = new
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

    init(size: CGSize, darkBar: Bool, tint color: NSColor) {
        tint = TintView(frame: CGRect(origin: .zero, size: size))
        super.init(frame: CGRect(origin: .zero, size: size))
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: darkBar ? .darkAqua : .aqua)
        let outline = MenuBarBackdropGeometry.shape(in: size)
        maskImage = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(outline)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            return true
        }
        addSubview(tint)
        tint.setFill(color, animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(darkBar: Bool, tint color: NSColor) {
        appearance = NSAppearance(named: darkBar ? .darkAqua : .aqua)
        tint.setFill(color, animated: true)
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
    let barBottom: CGFloat
    let screenWidth: CGFloat
    let view: BackdropView

    fileprivate init(frame: NSRect, strip: NSRect, screenFrame: NSRect, primaryHeight: CGFloat,
                     darkBar: Bool, tint: NSColor) {
        screenLeft = screenFrame.minX
        barBottom = primaryHeight - strip.minY
        screenWidth = screenFrame.width
        view = BackdropView(size: frame.size, darkBar: darkBar, tint: tint)
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    }
}

final class MenuBarBackdrop {

    fileprivate var windows: [BackdropWindow] = []
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Zero-width, so nothing shows in the bar. It exists for its button: a status
    /// item's `effectiveAppearance` is the one place an app can read the menu bar's
    /// light/dark choice — `NSApp.effectiveAppearance` stays on the system setting.
    private let probe = NSStatusBar.system.statusItem(withLength: 0)
    private var appearanceWatch: NSKeyValueObservation?
    private var darkBar = true
    private var pendingRetint: DispatchWorkItem?

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
            object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        // What is under the bar changes when one of OUR windows moves, resizes,
        // appears or goes, so those are the only events that re-read it. Nothing
        // polls: a window of another app moving is not announced to us, and Phase 2
        // will have to decide how to notice that.
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
        // Another app coming forward can cover our window's top edge.
        workspaceObservers.append(ws.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in self?.scheduleRetint() })
    }

    deinit {
        NSStatusBar.system.removeStatusItem(probe)
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    private func setDarkBar(_ dark: Bool) {
        guard dark != darkBar else { return }
        darkBar = dark
        NSLog("anode.backdrop darkBar=\(dark)")
        retint()
    }

    /// A drag posts a move per frame; one read after it settles is enough.
    private func scheduleRetint() {
        pendingRetint?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.retint() }
        pendingRetint = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func retint() {
        for w in windows {
            w.view.update(darkBar: darkBar,
                          tint: MenuBarBackdropGeometry.tint(darkBar: darkBar,
                                                             windowTop: windowTopColor(under: w)))
        }
    }

    private func refresh() {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let planned: [(frame: NSRect, strip: NSRect, screen: NSRect)] = NSScreen.screens.compactMap {
            guard let strip = MenuBarBackdropGeometry.strip(
                screenFrame: $0.frame, visibleFrame: $0.visibleFrame,
                safeAreaTop: $0.safeAreaInsets.top) else { return nil }
            return (MenuBarBackdropGeometry.windowFrame(forStrip: strip), strip, $0.frame)
        }
        // Same strips as already shown: leave the windows alone rather than
        // reordering them on every wake.
        guard planned.map(\.frame) != windows.map(\.frame) else { return }
        windows.forEach { $0.orderOut(nil) }
        windows = planned.map { makeWindow(frame: $0.frame, strip: $0.strip, screen: $0.screen,
                                           primaryHeight: primaryHeight) }
        windows.forEach { $0.orderFrontRegardless() }
        retint()
    }

    private func makeWindow(frame: NSRect, strip: NSRect, screen: NSRect,
                            primaryHeight: CGFloat) -> BackdropWindow {
        let w = BackdropWindow(frame: frame, strip: strip, screenFrame: screen,
                               primaryHeight: primaryHeight, darkBar: darkBar,
                               tint: MenuBarBackdropGeometry.tint(darkBar: darkBar, windowTop: nil))
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
        // One level under the menu bar: over every app window, under the bar's
        // own items.
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)
        // On every Space, but not full-screen ones (no `.fullScreenAuxiliary`):
        // the bar is hidden there and the strip would be a black band over the
        // content. `.stationary` keeps it out of Mission Control's shuffling.
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.setFrame(frame, display: false)
        return w
    }

    // ── What is under the bar ───────────────────────────────────────────────

    /// The colour of the top edge of the window meeting this bar, when it is one of
    /// Anode's own. nil for anything else — another app's pixels cannot be read
    /// without Screen Recording permission, and this phase does not ask for it.
    ///
    /// The window server's list (front to back, with bounds and owner, none of
    /// which is gated) answers "which window is under the middle of the bar". Its
    /// colour then comes from asking that window to draw itself, which an app is
    /// always allowed to do to its own windows.
    private func windowTopColor(under bar: BackdropWindow) -> NSColor? {
        let point = CGPoint(x: bar.screenLeft + bar.screenWidth / 2, y: bar.barBottom + 2)
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        for entry in info {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let dict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.contains(point) else { continue }
            // The first window containing the point is the one in front there.
            guard MenuBarBackdropGeometry.meetsBar(bounds: bounds, barBottom: bar.barBottom,
                                                   screenWidth: bar.screenWidth),
                  (entry[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier,
                  let number = entry[kCGWindowNumber as String] as? Int,
                  let own = NSApp.windows.first(where: { $0.windowNumber == number })
            else { return nil }
            return Self.topEdgeColor(of: own)
        }
        return nil
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

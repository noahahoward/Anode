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

/// Draws the strip and, under its two ends, the little wedges a window's rounded
/// top corners would otherwise leave open.
///
/// A maximised window's top corners are curved, so just below a straight-edged
/// strip a sliver of wallpaper shows in each corner. The wedge is the square of
/// side `r` under the strip's end, minus the quarter-disc the window occupies; it
/// takes the strip's colour, so the window reads as rounded against the bar the
/// same way it does against the rest of the screen. A window that is NOT at the
/// screen's edge gets the same two wedges, which then read as the screen's own
/// rounded corners.
private final class BackdropView: NSView {
    var fill: NSColor = .black { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let r = MenuBarBackdropGeometry.cornerRadius
        let w = bounds.width
        fill.setFill()
        NSRect(x: 0, y: r, width: w, height: bounds.height - r).fill()

        let left = NSBezierPath()
        left.move(to: NSPoint(x: 0, y: r))
        left.line(to: NSPoint(x: r, y: r))
        left.appendArc(withCenter: NSPoint(x: r, y: 0), radius: r,
                       startAngle: 90, endAngle: 180, clockwise: false)
        left.close()
        left.fill()

        let right = NSBezierPath()
        right.move(to: NSPoint(x: w, y: r))
        right.line(to: NSPoint(x: w - r, y: r))
        right.appendArc(withCenter: NSPoint(x: w - r, y: 0), radius: r,
                        startAngle: 90, endAngle: 0, clockwise: true)
        right.close()
        right.fill()
    }
}

/// Borderless and inert. A window is clamped below the menu bar unless it says
/// otherwise, and this one has to sit in it.
private final class BackdropWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
    let view = BackdropView()
}

final class MenuBarBackdrop {

    private var windows: [BackdropWindow] = []
    private var observers: [NSObjectProtocol] = []
    /// Zero-width, so nothing shows in the bar. It exists for its button: a status
    /// item's `effectiveAppearance` is the one place an app can read the menu bar's
    /// light/dark choice — `NSApp.effectiveAppearance` stays on the system setting.
    private let probe = NSStatusBar.system.statusItem(withLength: 0)
    private var appearanceWatch: NSKeyValueObservation?
    private var darkBar = true

    init() {
        appearanceWatch = probe.button?.observe(\.effectiveAppearance, options: [.initial, .new]) {
            [weak self] button, _ in
            let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua
            DispatchQueue.main.async { self?.setDarkBar(dark) }
        }
        refresh()
        // Posted on every wake and on changes that move no screen, so `refresh`
        // does its own comparing and a redundant call is a no-op.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        // A full-screen Space has no menu bar, and the visible frame says so only
        // once that Space is the one being looked at.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.refresh() })
    }

    private func setDarkBar(_ dark: Bool) {
        guard dark != darkBar else { return }
        darkBar = dark
        NSLog("anode.backdrop darkBar=\(dark)")
        windows.forEach { $0.view.fill = MenuBarBackdropGeometry.fill(darkBar: dark) }
    }

    deinit {
        NSStatusBar.system.removeStatusItem(probe)
        for o in observers {
            NotificationCenter.default.removeObserver(o)
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
    }

    private func refresh() {
        let strips = NSScreen.screens.compactMap {
            MenuBarBackdropGeometry.strip(screenFrame: $0.frame, visibleFrame: $0.visibleFrame,
                                          safeAreaTop: $0.safeAreaInsets.top)
        }.map(MenuBarBackdropGeometry.windowFrame(forStrip:))
        // Same strips as already shown: leave the windows alone rather than
        // reordering them on every wake.
        guard strips != windows.map(\.frame) else { return }
        windows.forEach { $0.orderOut(nil) }
        windows = strips.map(makeWindow)
        windows.forEach { $0.orderFrontRegardless() }
    }

    private func makeWindow(_ frame: NSRect) -> BackdropWindow {
        let w = BackdropWindow(contentRect: frame, styleMask: .borderless,
                               backing: .buffered, defer: false)
        w.view.fill = MenuBarBackdropGeometry.fill(darkBar: darkBar)
        w.contentView = w.view
        // Clear, because the part below the strip is wedges and nothing else.
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
}

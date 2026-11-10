import AppKit
import PowerKit

// ── The hot corner (Beta Features, Game Mode) ───────────────────────────────
//
// A 6 pt panel in the chosen corner of every screen. The pointer touching it shows the strip for a few seconds, in any app.
// The panel is the strip's recipe (a non-activating panel at `.screenSaver` level that joins every Space, so it exists over a
// fullscreen game) with one difference: it does NOT ignore the mouse, because noticing the pointer is its whole job.
// It is event-driven: a tracking area, no polling and no global mouse monitor, so it costs nothing while the pointer is
// elsewhere. Its alpha is not zero (0.01), because a window with no pixels at all lets the pointer through unnoticed.

final class HotSpotView: NSView {
    var onEnter: () -> Void = {}
    override func mouseEntered(with event: NSEvent) { onEnter() }
}

final class HotCornerWindows: HotCornerPresenting {

    private var windows: [NSWindow] = []
    private var corner: HUDCorner?
    private var onEnter: ((FrontmostApp) -> Void)?
    private var screenToken: NSObjectProtocol?

    var windowCount: Int { windows.count }

    /// One frame per screen, flush to `corner`.
    static func frames(corner: HUDCorner, screens: [CGRect]) -> [CGRect] {
        screens.map { HotCornerGeometry.frame(corner: corner, screenFrame: $0) }
    }

    /// One panel, not yet on screen.
    func makeWindow(frame: CGRect, onEnter: @escaping () -> Void) -> NSWindow {
        let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.hidesOnDeactivate = false
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.isOpaque = false
        w.backgroundColor = NSColor.black.withAlphaComponent(0.01)
        w.hasShadow = false
        w.ignoresMouseEvents = false
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        let view = HotSpotView(frame: NSRect(origin: .zero, size: frame.size))
        view.onEnter = onEnter
        view.addTrackingArea(NSTrackingArea(rect: view.bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                            owner: view, userInfo: nil))
        w.contentView = view
        return w
    }

    func show(corner: HUDCorner, onEnter: @escaping (FrontmostApp) -> Void) {
        self.corner = corner
        self.onEnter = onEnter
        rebuild()
        if screenToken == nil {
            screenToken = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.rebuild() }
        }
    }

    func hide() {
        corner = nil
        onEnter = nil
        if let t = screenToken { NotificationCenter.default.removeObserver(t); screenToken = nil }
        tearDown()
    }

    private func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    /// Cover exactly the screens that exist now.
    private func rebuild() {
        tearDown()
        guard let corner, let onEnter else { return }
        for screen in NSScreen.screens {
            let w = makeWindow(frame: HotCornerGeometry.frame(corner: corner, screenFrame: screen.frame)) { [weak screen] in
                guard let screen else { return }
                onEnter(RealFrontmost.target(for: screen))
            }
            w.orderFrontRegardless()
            windows.append(w)
        }
    }

    deinit { hide() }
}

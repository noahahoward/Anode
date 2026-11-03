import AppKit
import MetalKit
import PowerKit

// ── Lid Glass: the window the frost is drawn in ─────────────────────────────

/// What the controller needs from the overlay, so it can be tested without a window.
protocol LidGlassOverlaying: AnyObject {
    var windowID: CGWindowID { get }
    /// Cover the screen with `image`, frosted by `blur` (0...1) to begin with.
    func show(image: CGImage, blur: Double)
    /// Move toward this much frost; the overlay smooths the steps.
    func setBlur(_ amount: Double)
    /// Take the frost off over `duration` seconds, then call `completion`.
    func animateClear(duration: TimeInterval, completion: @escaping () -> Void)
    func hide()
}

extension LidGlassOverlaying {
    func show(image: CGImage) { show(image: image, blur: 0) }
}

/// A borderless window over the whole built-in screen, above everything, that does not take clicks.
///
/// It draws only while it is shown, and only on the screen's own refresh (a display link that exists just for
/// that time). Between closes it is hidden and costs nothing.
@available(macOS 14.0, *)
final class LidGlassOverlay: LidGlassOverlaying {

    let window: NSWindow
    private let view: MTKView
    private let renderer: LidGlassRenderer?
    private var link: CADisplayLink?
    private var spring = LidSpring()
    private var target = 0.0
    private var clear: (from: Double, start: CFTimeInterval, duration: TimeInterval, done: () -> Void)?

    init(screen: NSScreen, makeRenderer: () -> LidGlassRenderer? = { LidGlassRenderer() }) {
        renderer = makeRenderer()
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.level = .screenSaver
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        view = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: renderer?.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        window.contentView = view
    }

    var windowID: CGWindowID { CGWindowID(window.windowNumber) }
    var isDisplayLinkRunning: Bool { link != nil }

    func show(image: CGImage, blur: Double) {
        guard let renderer else { return }
        renderer.setImage(image)
        guard renderer.hasImage else { return }
        spring.reset(to: blur)
        target = blur
        clear = nil
        window.setFrame(window.screen?.frame ?? window.frame, display: false)
        window.orderFrontRegardless()
        drawFrame()
        startLink()
    }

    func setBlur(_ amount: Double) {
        clear = nil
        target = amount
    }

    func animateClear(duration: TimeInterval, completion: @escaping () -> Void) {
        guard link != nil else { completion(); return }
        clear = (spring.value, CACurrentMediaTime(), max(duration, 0.01), completion)
    }

    func hide() {
        stopLink()
        clear = nil
        window.orderOut(nil)
        renderer?.clearImage()
    }

    private func startLink() {
        guard link == nil else { return }
        let l = view.displayLink(target: self, selector: #selector(step(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ l: CADisplayLink) {
        if let c = clear {
            let t = min(max((CACurrentMediaTime() - c.start) / c.duration, 0), 1)
            let eased = t * t * (3 - 2 * t)
            spring.reset(to: c.from * (1 - eased))
            target = spring.value
            drawFrame()
            if t >= 1 {
                clear = nil
                c.done()
            }
            return
        }
        spring.advance(to: target, dt: l.targetTimestamp - l.timestamp)
        drawFrame()
    }

    private func drawFrame() {
        guard let renderer, let drawable = view.currentDrawable else { return }
        renderer.draw(blur: spring.value, into: drawable)
    }
}

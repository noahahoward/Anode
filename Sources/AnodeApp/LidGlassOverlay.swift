import AppKit
import MetalKit
import PowerKit

// ── Lid Glass: the window the fold is drawn in ──────────────────────────────

/// What the controller needs from the overlay, so it can be tested without a window.
protocol LidGlassOverlaying: AnyObject {
    var windowID: CGWindowID { get }
    /// Cover the screen with `image`, which was taken with the lid at `startAngle`: the fold is flat at that
    /// angle and recedes as the lid closes past it. The picture is drawn as if the lid were at `from`, and the
    /// overlay follows `to` from there: a close starts at `startAngle` (flat) and chases the lid, an opening
    /// starts fully folded and is cleared with `animateClear`.
    func show(image: CGImage, startAngle: Double, from: Double, to: Double)
    /// Follow the lid to this angle; the overlay smooths the sensor's steps.
    func setAngle(_ angle: Double)
    /// Unfold back to flat over `duration` seconds, then call `completion`.
    func animateClear(duration: TimeInterval, completion: @escaping () -> Void)
    func hide()
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
    private var look = LidFoldLook(startAngle: 90)
    private var spring = LidSpring()
    private var target = 0.0
    private var clear: (from: Double, start: CFTimeInterval, duration: TimeInterval, done: () -> Void)?
    /// Bumped by every `show` and `hide`, so a picture that finishes preparing after the overlay was dismissed
    /// finds its moment gone.
    private var showToken = 0
    private var isPreparing = false
    private var pendingClear: (duration: TimeInterval, done: () -> Void)?
    /// False in tests: everything else runs, but the window is never put on the screen.
    var showsWindow = true

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
        view = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: renderer?.metalDevice)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: LidGlassRenderer.colourSpaceName)
        window.contentView = view
    }

    var windowID: CGWindowID { CGWindowID(window.windowNumber) }
    var isDisplayLinkRunning: Bool { link != nil }

    /// The picture is prepared (drawn onto its margin, mipmapped) off the main thread, which takes about 50 ms at
    /// full size; the window appears when it is ready, drawing the lid's latest angle from the flat start.
    func show(image: CGImage, startAngle: Double, from: Double, to: Double) {
        guard let renderer else { return }
        showToken += 1
        let mine = showToken
        look = LidFoldLook(startAngle: startAngle)
        spring.reset(to: from)
        target = to
        clear = nil
        pendingClear = nil
        isPreparing = true
        let scale = window.screen?.backingScaleFactor ?? 2
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let picture = renderer.makePicture(from: image, scale: scale)
            DispatchQueue.main.async { self?.pictureReady(picture, token: mine) }
        }
    }

    private func pictureReady(_ picture: LidGlassRenderer.Picture?, token: Int) {
        guard token == showToken else { return }
        isPreparing = false
        guard let renderer, let picture else {
            let waiting = pendingClear
            pendingClear = nil
            waiting?.done()
            return
        }
        renderer.adopt(picture)
        if showsWindow {
            window.setFrame(window.screen?.frame ?? window.frame, display: false)
            window.orderFrontRegardless()
        }
        drawFrame()
        startLink()
        if let waiting = pendingClear {
            pendingClear = nil
            beginClear(duration: waiting.duration, done: waiting.done)
        }
    }

    func setAngle(_ angle: Double) {
        clear = nil
        target = angle
    }

    func animateClear(duration: TimeInterval, completion: @escaping () -> Void) {
        if isPreparing {
            pendingClear = (duration, completion)
        } else if link != nil {
            beginClear(duration: duration, done: completion)
        } else {
            completion()
        }
    }

    private func beginClear(duration: TimeInterval, done: @escaping () -> Void) {
        clear = (spring.value, CACurrentMediaTime(), max(duration, 0.01), done)
    }

    func hide() {
        showToken += 1
        isPreparing = false
        pendingClear = nil
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
        advance(dt: l.targetTimestamp - l.timestamp, now: CACurrentMediaTime())
    }

    /// One frame's worth of motion, then draw. Separate from the display link so tests can step it.
    func advance(dt: TimeInterval, now: CFTimeInterval) {
        if let c = clear {
            let t = min(max((now - c.start) / c.duration, 0), 1)
            let eased = t * t * (3 - 2 * t)
            // From where it was to flat: the start angle, or above it if it began higher.
            let flat = max(look.startAngle, c.from)
            spring.reset(to: c.from + (flat - c.from) * eased)
            target = spring.value
            drawFrame()
            if t >= 1 {
                clear = nil
                c.done()
            }
            return
        }
        spring.advance(to: target, dt: dt)
        drawFrame()
    }

    private func drawFrame() {
        guard let renderer, let drawable = view.currentDrawable else { return }
        let frame = LidFoldFrame.make(look: look, screen: window.frame.size, angle: spring.value)
        renderer.draw(frame, into: drawable)
    }
}

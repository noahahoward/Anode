import AppKit
import Metal
import PowerKit
import QuartzCore

// ── Lid Glass: the window the fold is drawn in ──────────────────────────────

/// What the controller needs from the overlay, so it can be tested without a window.
protocol LidGlassOverlaying: AnyObject {
    var windowID: CGWindowID { get }
    /// Start preparing `image` (drawn onto its margin and mipmapped, off the main thread). Nothing is shown.
    func prepare(image: CGImage)
    /// Put the prepared picture on screen, now if it is ready and as soon as it is if not. The picture was taken
    /// with the lid at `startAngle`: the fold is flat at that angle and recedes as the lid closes past it. It is
    /// drawn as if the lid were at `from`, and follows `to` from there: a close starts at `startAngle` (flat) and
    /// chases the lid, an opening starts fully folded and is cleared with `animateClear`.
    func present(startAngle: Double, from: Double, to: Double)
    /// Follow the lid to this angle; the overlay smooths the sensor's steps.
    func setAngle(_ angle: Double)
    /// Unfold back to flat over `duration` seconds, then call `completion`.
    func animateClear(duration: TimeInterval, completion: @escaping () -> Void)
    /// Take the overlay off the screen and drop the picture, prepared or not.
    func hide()
}

extension LidGlassOverlaying {
    /// Prepare and present in one go.
    func show(image: CGImage, startAngle: Double, from: Double, to: Double) {
        prepare(image: image)
        present(startAngle: startAngle, from: from, to: to)
    }
}

/// A borderless window over the whole built-in screen, above everything, that does not take clicks.
///
/// It draws only while it is shown, and only on the screen's own refresh (a display link that exists just for
/// that time). Between closes it is hidden and costs nothing.
@available(macOS 14.0, *)
final class LidGlassOverlay: LidGlassOverlaying {

    let window: NSWindow
    private let view: MetalLayerView
    private let renderer: LidGlassRenderer?
    private var link: CADisplayLink?
    private var look = LidFoldLook(startAngle: 90)
    private var spring = LidSpring()
    /// The sensor's readings arrive about ten a second; the tracker carries the lid's last movement forward between
    /// them so the target moves on every frame.
    private var tracker = LidAngleTracker()
    private var target = 0.0
    private var clear: (from: Double, start: CFTimeInterval, duration: TimeInterval, done: () -> Void)?
    /// Bumped by every `show` and `hide`, so a picture that finishes preparing after the overlay was dismissed
    /// finds its moment gone.
    private var prepareToken = 0
    private var isPreparing = false
    private var pictureIsReady = false
    /// A present was asked for; it happens when the picture is ready.
    private var wantsPresent = false
    private var pendingClear: (duration: TimeInterval, done: () -> Void)?
    /// False in tests: everything else runs, but the window is never put on the screen.
    var showsWindow = true
    /// Where a once-a-second summary of the drawing goes while the overlay is up (frames, skips, worst times).
    var log: (String) -> Void = { _ in }
    /// Called with the angle each frame is drawn at, and the time; for tests that watch the motion.
    var onFrame: ((Double, CFTimeInterval) -> Void)?

    /// What drawing did since the last summary. The GPU time arrives from another thread.
    private struct Stats {
        var ticks = 0, drawn = 0, skipped = 0, noDrawable = 0
        var worstStep = 0.0, worstInterval = 0.0, slowIntervals = 0
    }
    private var stats = Stats()
    private let gpuLock = NSLock()
    private var gpuWorst = 0.0
    private var lastSummary: CFTimeInterval = 0
    /// The display link asks for the screen's best rate (120 Hz on a ProMotion display; it is a ceiling, not a
    /// promise), and a tick that finds the GPU still busy is skipped rather than waited for.
    static let frameRate: Float = 120
    /// Intervals between ticks longer than this (seconds) are counted as late in the log summary.
    private static let lateInterval = 0.022
    private var lastTick: CFTimeInterval = 0

    init(screen: NSScreen, makeRenderer: () -> LidGlassRenderer? = { LidGlassRenderer() }) {
        renderer = makeRenderer()
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        // Above the menu bar and everything else. Not opaque: an opaque full-screen window makes the window
        // server treat everything under it as hidden, and the layer's frames then stop completing (measured: a few
        // frames drew, then every later one stayed in flight and the main thread blocked waiting for a drawable).
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        // No system ordering-in/out animation: it fades and scales a window over ~150 ms, which showed as a flicker
        // against the identical live screen (measured with a 60 fps screen stream across the transition).
        window.animationBehavior = .none
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        view = MetalLayerView(frame: CGRect(origin: .zero, size: screen.frame.size))
        let layer = view.metalLayer
        layer.device = renderer?.metalDevice
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.framebufferOnly = true
        layer.colorspace = CGColorSpace(name: LidGlassRenderer.colourSpaceName)
        // The shader writes alpha 1 everywhere, so blending gives the same picture as an opaque layer.
        layer.isOpaque = false
        // The display link paces frames; waiting on the drawable would block the main thread.
        layer.displaySyncEnabled = false
        layer.contentsScale = screen.backingScaleFactor
        layer.drawableSize = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                                    height: screen.frame.height * screen.backingScaleFactor)
        window.contentView = view
    }

    var windowID: CGWindowID { CGWindowID(window.windowNumber) }
    var isDisplayLinkRunning: Bool { link != nil }

    /// The picture is prepared off the main thread, which takes about 50 ms at full size.
    func prepare(image: CGImage) {
        guard let renderer else { return }
        prepareToken += 1
        let mine = prepareToken
        isPreparing = true
        pictureIsReady = false
        let scale = window.screen?.backingScaleFactor ?? 2
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let picture = renderer.makePicture(from: image, scale: scale)
            DispatchQueue.main.async { self?.pictureReady(picture, token: mine) }
        }
    }

    func present(startAngle: Double, from: Double, to: Double) {
        look = LidFoldLook(startAngle: startAngle)
        spring.reset(to: from)
        tracker.reset(to: to, at: CACurrentMediaTime())
        target = to
        clear = nil
        pendingClear = nil
        wantsPresent = true
        if pictureIsReady { display() }
    }

    private func pictureReady(_ picture: LidGlassRenderer.Picture?, token: Int) {
        guard token == prepareToken else { return }
        isPreparing = false
        guard let renderer, let picture else {
            let waiting = pendingClear
            pendingClear = nil
            wantsPresent = false
            waiting?.done()
            return
        }
        renderer.adopt(picture)
        pictureIsReady = true
        if wantsPresent { display() }
    }

    /// The window goes up with the first frame drawn.
    private func display() {
        guard link == nil else { return }
        lastDrawnAngle = nil
        view.matchDrawable(to: window.screen?.backingScaleFactor ?? 2)
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
        tracker.ingest(angle, at: CACurrentMediaTime())
    }

    func animateClear(duration: TimeInterval, completion: @escaping () -> Void) {
        if wantsPresent, link == nil {
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
        prepareToken += 1
        isPreparing = false
        pictureIsReady = false
        wantsPresent = false
        pendingClear = nil
        stopLink()
        clear = nil
        window.orderOut(nil)
        renderer?.clearImage()
    }

    private func startLink() {
        guard link == nil else { return }
        let l = view.displayLink(target: self, selector: #selector(step(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: Self.frameRate, preferred: Self.frameRate)
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
        let began = ProcessInfo.processInfo.systemUptime
        defer { noteTick(took: ProcessInfo.processInfo.systemUptime - began, now: now) }
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
        target = tracker.extrapolated(at: now)
        spring.advance(to: target, dt: dt)
        drawFrame()
    }

    /// The angle the last frame was drawn at. A frame that would draw the same picture again is not drawn: a lid held
    /// still costs no GPU.
    private var lastDrawnAngle: Double?

    private func drawFrame() {
        guard let renderer else { return }
        if clear == nil, let last = lastDrawnAngle, abs(last - spring.value) < 0.01 { return }
        // Never wait for a drawable: when the GPU is behind, skip this tick and draw the next one.
        guard renderer.framesInFlight < 2 else { stats.skipped += 1; return }
        // A fresh drawable from the layer every frame. (MTKView's `currentDrawable` is only replaced when the view
        // runs its own draw cycle, so drawing through it re-presented the first frame: measured on screen, 7 visible
        // changes in a 1.6 s sweep while the GPU drew every frame.)
        guard let drawable = view.metalLayer.nextDrawable() else { stats.noDrawable += 1; return }
        // The shader maps by pixel position, so a drawable that is not exactly the screen's size would draw the picture
        // mis-scaled. Say so rather than flash it silently.
        let scale = window.screen?.backingScaleFactor ?? 2
        let expected = (w: Int((window.frame.width * scale).rounded()), h: Int((window.frame.height * scale).rounded()))
        if drawable.texture.width != expected.w || drawable.texture.height != expected.h {
            log("drawable is \(drawable.texture.width)x\(drawable.texture.height), expected \(expected.w)x\(expected.h)")
        }
        let frame = LidFoldFrame.make(look: look, screen: window.frame.size, angle: spring.value)
        stats.drawn += 1
        lastDrawnAngle = spring.value
        onFrame?(spring.value, CACurrentMediaTime())
        renderer.draw(frame, into: drawable) { [weak self] seconds in
            guard let self else { return }
            self.gpuLock.lock(); self.gpuWorst = max(self.gpuWorst, seconds); self.gpuLock.unlock()
        }
    }

    private func noteTick(took: TimeInterval, now: CFTimeInterval) {
        stats.ticks += 1
        stats.worstStep = max(stats.worstStep, took)
        if lastTick != 0 {
            let gap = now - lastTick
            stats.worstInterval = max(stats.worstInterval, gap)
            if gap > Self.lateInterval { stats.slowIntervals += 1 }
        }
        lastTick = now
        if lastSummary == 0 { lastSummary = now }
        guard now - lastSummary >= 1 else { return }
        gpuLock.lock(); let gpu = gpuWorst; gpuWorst = 0; gpuLock.unlock()
        log(String(format: "frames: %d ticks (%d later than %.0f ms, worst gap %.0f ms), %d drawn, %d skipped (gpu busy), %d no drawable; worst main step %.0f ms, worst gpu %.0f ms",
                   stats.ticks, stats.slowIntervals, Self.lateInterval * 1000, stats.worstInterval * 1000, stats.drawn,
                   stats.skipped, stats.noDrawable, stats.worstStep * 1000, gpu * 1000))
        stats = Stats()
        lastSummary = now
    }
}

/// A plain view whose backing layer is a `CAMetalLayer` the overlay draws into directly.
final class MetalLayerView: NSView {
    let metalLayer = CAMetalLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer { metalLayer }

    /// Keep the drawable exactly the screen's size in pixels; the shader maps by pixel position.
    func matchDrawable(to scale: CGFloat) {
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        matchDrawable(to: window?.backingScaleFactor ?? metalLayer.contentsScale)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        matchDrawable(to: window?.backingScaleFactor ?? metalLayer.contentsScale)
    }
}

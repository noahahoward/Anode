import AppKit
import PowerKit

// ── The panel's fade as it closes ───────────────────────────────────────────
//
// macOS's panels fade out (measured at 120 fps: a straight line over about 240 ms, begun a few milliseconds after the click). Anode's
// glass cannot be faded: it drops out as soon as its window or anything above it is translucent, which shows the text alone for a
// moment. So the fade is of a picture: the panel as it is on the screen is taken, the panel is put away, and the picture, in a
// window of its own that takes no click, goes from fully opaque to nothing over what is live behind it. Over a still backdrop that is
// the panel fading; there is no picture (and no fade) without Screen Recording, and the panel then closes at once.

final class PanelFade {

    /// Fades that are running: each is its own, so one panel fading out while the other opens (the Sound and Battery menus close each
    /// other) is the two things at once, as on macOS.
    private static var running: [PanelFade] = []

    private var window: NSWindow?
    private var timer: Timer?
    private var started: CFTimeInterval = 0
    private let seconds: TimeInterval

    private init(window: NSWindow, seconds: TimeInterval) { self.window = window; self.seconds = seconds }

    /// Takes the picture of `panel` (it must still be on the screen), puts the panel away, and fades the picture out.
    static func close(_ panel: NSWindow, seconds: TimeInterval = BatteryMenuMotion.fadeOutSeconds, then orderOut: () -> Void) {
        // The count starts at the click, not when the picture is ready: taking it costs a frame or two.
        let clicked = CACurrentMediaTime()
        guard panel.isVisible, ScreenRecordingAccess.isGranted, let screen = NSScreen.screens.first else { orderOut(); return }
        // The panel and its shadow: more below it than above, and nothing above the top of the screen.
        let f = panel.frame
        let top = screen.frame.height - f.maxY
        var rect = CGRect(x: f.minX - 24, y: max(0, top - 6), width: f.width + 48, height: f.height + 6 + 40)
        rect = rect.intersection(CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height))
        guard let shot = IconCover.displayImage(of: rect) else { orderOut(); return }

        let r = NSRect(x: rect.minX, y: screen.frame.height - rect.maxY, width: rect.width, height: rect.height)
        let w = NSWindow(contentRect: r, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        w.level = panel.level
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let view = NSImageView(frame: NSRect(origin: .zero, size: r.size))
        view.image = NSImage(cgImage: shot, size: r.size)
        view.imageScaling = .scaleAxesIndependently
        // Only the panel itself fades: what is round it is live, and a click that brought another window forward would otherwise show the
        // old picture of it for a quarter of a second. (The shadow is not in the picture, and goes at once.)
        view.wantsLayer = true
        let mask = CAShapeLayer()
        let panelInPicture = CGRect(x: f.minX - r.minX, y: f.minY - r.minY, width: f.width, height: f.height)
        mask.path = CGPath(roundedRect: panelInPicture, cornerWidth: 17, cornerHeight: 17, transform: nil)
        view.layer?.mask = mask
        w.contentView = view
        w.alphaValue = 1
        w.orderFrontRegardless()
        w.displayIfNeeded()
        CATransaction.flush()
        // Under the picture nothing changes on the screen: the panel goes now.
        orderOut()
        let fade = PanelFade(window: w, seconds: seconds)
        running.append(fade)
        fade.started = clicked
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak fade] _ in fade?.step() }
        RunLoop.main.add(t, forMode: .common)
        fade.timer = t
    }

    private func step() {
        let elapsed = CACurrentMediaTime() - started
        if elapsed >= seconds { finish(); return }
        // Linear in time over `seconds`, whatever it is.
        window?.alphaValue = CGFloat(1 - elapsed / seconds)
    }

    private func finish() {
        timer?.invalidate(); timer = nil
        window?.orderOut(nil)
        window = nil
        Self.running.removeAll { $0 === self }
    }
}

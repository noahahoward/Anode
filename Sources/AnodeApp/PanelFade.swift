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

    static let shared = PanelFade()

    private var window: NSWindow?
    private var timer: Timer?
    private var started: CFTimeInterval = 0
    private var seconds: TimeInterval = BatteryMenuMotion.fadeOutSeconds

    /// Takes the picture of `panel` (it must still be on the screen), puts the panel away, and fades the picture out.
    func close(_ panel: NSWindow, seconds: TimeInterval = BatteryMenuMotion.fadeOutSeconds, then orderOut: () -> Void) {
        cancel()
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
        w.contentView = view
        w.alphaValue = 1
        w.orderFrontRegardless()
        w.displayIfNeeded()
        CATransaction.flush()
        window = w
        // Under the picture nothing changes on the screen: the panel goes now.
        orderOut()
        self.seconds = seconds
        started = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func step() {
        let elapsed = CACurrentMediaTime() - started
        if elapsed >= seconds { cancel(); return }
        // Linear in time over `seconds`, whatever it is.
        window?.alphaValue = CGFloat(1 - elapsed / seconds)
    }

    /// The fade is over, or the menu is opening again: the picture goes at once.
    func cancel() {
        timer?.invalidate(); timer = nil
        window?.orderOut(nil)
        window = nil
    }
}

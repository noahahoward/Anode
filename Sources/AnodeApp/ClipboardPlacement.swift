import AppKit

// ── Clipboard History: where the panel sits, and how it is dragged ──────────
//
// All measured on this Mac (macOS 27.3) by logging the system's own ⌘Space panel's window every ten milliseconds while it was opened,
// dragged and opened again:
//
// - It opens centred, and its top edge is where a window 137 points tall (the bar and 50 points) would be centred at 30% of the
//   screen's height: 282 on a 1169 point screen. It grows downwards from there; the top edge does not move.
// - It can be dragged by the bar. It follows the pointer one for one, except that it sticks to the horizontal middle of the screen
//   and to that default height: it jumps there when it comes within about 5 points, and stays until the pointer has pulled it about
//   24 points away sideways, or 16 up or down. (There is a tick from the trackpad each time it catches.)
// - It stops at the screen's edges, and under the menu bar. The pointer can go on past an edge; the window comes back only when the
//   pointer does.
// - It opens again where it was left, not at the default.

enum ClipboardPlacement {

    /// Where the middle of a window `referenceHeight` tall sits, as a fraction of the screen's height from its top.
    static let centreFraction: CGFloat = 0.30
    /// The system panel's window when nothing is typed: the bar and 50 points.
    static let referenceHeight: CGFloat = 137
    /// How near the pointer takes the panel to the middle, and how far it has to pull to get away again.
    static let captureX: CGFloat = 5
    static let releaseX: CGFloat = 24
    static let captureY: CGFloat = 5
    static let releaseY: CGFloat = 16

    /// The panel's frame (the bar and card, not the window with its shadow margin) at the default place on `screen`.
    static func defaultFrame(height: CGFloat, on screen: NSRect) -> NSRect {
        // whole points, as the system's is (282 on a 1169 point screen)
        let topFromScreenTop = (screen.height * centreFraction - referenceHeight / 2).rounded()
        return NSRect(x: screen.midX - ClipboardPanelMetrics.width / 2, y: screen.maxY - topFromScreenTop - height,
                      width: ClipboardPanelMetrics.width, height: height)
    }

    /// `frame` brought inside the screen: the top edge no higher than the visible area's (under the menu bar), the bottom no lower than
    /// the screen's, the sides inside it. The top wins when the panel is taller than the screen.
    static func clamp(_ frame: NSRect, screen: NSRect, visible: NSRect) -> NSRect {
        var f = frame
        f.origin.x = min(max(f.origin.x, screen.minX), max(screen.minX, screen.maxX - f.width))
        f.origin.y = max(f.origin.y, screen.minY)                // bottom edge on the screen
        if f.maxY > visible.maxY { f.origin.y = visible.maxY - f.height }
        return f
    }

    /// Where the panel opens: the default, moved by what it was last dragged away from the default by, and kept on the screen.
    static func opening(height: CGFloat, screen: NSRect, visible: NSRect, remembered: CGSize) -> NSRect {
        var f = defaultFrame(height: height, on: screen)
        f.origin.x += remembered.width
        f.origin.y += remembered.height
        return clamp(f, screen: screen, visible: visible)
    }

    /// How far `frame` is from the default place (x and the top edge), to be put back by `opening`.
    static func offset(of frame: NSRect, on screen: NSRect) -> CGSize {
        let d = defaultFrame(height: frame.height, on: screen)
        return CGSize(width: frame.minX - d.minX, height: frame.maxY - d.maxY)
    }

    /// One direction of the stickiness: nothing, then caught when the value comes within `capture` of the point, then held until it is
    /// more than `release` away.
    struct SnapAxis {
        let capture: CGFloat
        let release: CGFloat
        private(set) var held = false

        init(capture: CGFloat, release: CGFloat) {
            self.capture = capture
            self.release = release
        }

        /// The value to use, and whether it was caught just now.
        mutating func resolve(_ value: CGFloat, to point: CGFloat) -> (value: CGFloat, caught: Bool) {
            let distance = abs(value - point)
            if held {
                if distance > release { held = false; return (value, false) }
                return (point, false)
            }
            if distance <= capture { held = true; return (point, true) }
            return (value, false)
        }
    }

    /// A drag of the panel: where it started, where the pointer did, and the stickiness. The pointer may go on past an edge; the panel
    /// is only kept inside it, so it follows again when the pointer comes back.
    struct Drag {
        private let start: NSRect
        private let pointerStart: NSPoint
        private let screen: NSRect
        private let visible: NSRect
        private var x = SnapAxis(capture: ClipboardPlacement.captureX, release: ClipboardPlacement.releaseX)
        private var y = SnapAxis(capture: ClipboardPlacement.captureY, release: ClipboardPlacement.releaseY)
        /// Where the panel is now.
        private(set) var frame: NSRect

        init(panel: NSRect, pointer: NSPoint, screen: NSRect, visible: NSRect) {
            self.start = panel
            self.frame = panel
            self.pointerStart = pointer
            self.screen = screen
            self.visible = visible
        }

        /// The pointer moved. Returns whether the panel caught on the middle or the default height just now (for the tick).
        @discardableResult
        mutating func moved(to pointer: NSPoint) -> Bool {
            let target = ClipboardPlacement.defaultFrame(height: start.height, on: screen)
            let wantedX = start.minX + (pointer.x - pointerStart.x)
            let wantedTop = start.maxY + (pointer.y - pointerStart.y)
            let sx = x.resolve(wantedX, to: target.minX)
            let sy = y.resolve(wantedTop, to: target.maxY)
            // whole points, so the hard rims of the glass stay on the pixels
            frame = ClipboardPlacement.clamp(NSRect(x: sx.value.rounded(), y: sy.value.rounded() - start.height, width: start.width, height: start.height),
                                             screen: screen, visible: visible)
            return sx.caught || sy.caught
        }
    }
}

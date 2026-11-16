import AppKit

/// The three listening-mode icons of macOS's Sound panel (a person with a ring of dots, with sparkles, inside an open ring).
/// macOS draws them from art that is not in the symbol catalogue, so these are drawn here, as template images the menu tints.
enum ListeningGlyphs {

    /// The icon for a listening-mode row, or nil for any other title.
    static func image(for title: String) -> NSImage? {
        switch title {
        case "Transparency": return make { transparency() }
        case "Adaptive": return make { adaptive() }
        case "Noise Cancellation": return make { noiseCancellation() }
        default: return nil
        }
    }

    private static func make(_ draw: @escaping () -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.black.setFill(); NSColor.black.setStroke()
            // Drawn a little smaller than the canvas and a half point to the right, as macOS's are.
            let t = NSAffineTransform()
            t.translateX(by: 10.5, yBy: 10); t.scale(by: 0.9); t.translateX(by: -10, yBy: -10)
            t.concat()
            draw()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// A head and a pair of shoulders, centred on `cx`; the shoulders are `width` wide from `bottom` to `top`.
    private static func person(cx: CGFloat, headY: CGFloat, headRadius: CGFloat, width: CGFloat, bottom: CGFloat, top: CGFloat) {
        NSBezierPath(ovalIn: NSRect(x: cx - headRadius, y: headY - headRadius, width: headRadius * 2, height: headRadius * 2)).fill()
        let x0 = cx - width / 2, x1 = cx + width / 2
        let p = NSBezierPath()
        p.move(to: NSPoint(x: x0, y: bottom))
        p.curve(to: NSPoint(x: cx, y: top), controlPoint1: NSPoint(x: x0, y: top), controlPoint2: NSPoint(x: cx - width * 0.2, y: top))
        p.curve(to: NSPoint(x: x1, y: bottom), controlPoint1: NSPoint(x: cx + width * 0.2, y: top), controlPoint2: NSPoint(x: x1, y: top))
        p.close()
        p.fill()
    }

    private static func sparkle(at c: NSPoint, radius r: CGFloat) {
        let p = NSBezierPath()
        let inner = r * 0.22
        p.move(to: NSPoint(x: c.x, y: c.y + r))
        p.curve(to: NSPoint(x: c.x + r, y: c.y), controlPoint1: NSPoint(x: c.x + inner, y: c.y + inner), controlPoint2: NSPoint(x: c.x + inner, y: c.y + inner))
        p.curve(to: NSPoint(x: c.x, y: c.y - r), controlPoint1: NSPoint(x: c.x + inner, y: c.y - inner), controlPoint2: NSPoint(x: c.x + inner, y: c.y - inner))
        p.curve(to: NSPoint(x: c.x - r, y: c.y), controlPoint1: NSPoint(x: c.x - inner, y: c.y - inner), controlPoint2: NSPoint(x: c.x - inner, y: c.y - inner))
        p.curve(to: NSPoint(x: c.x, y: c.y + r), controlPoint1: NSPoint(x: c.x - inner, y: c.y + inner), controlPoint2: NSPoint(x: c.x - inner, y: c.y + inner))
        p.fill()
    }

    private static func transparency() {
        let head = NSPoint(x: 10, y: 10.4)
        person(cx: head.x, headY: head.y, headRadius: 3.0, width: 12, bottom: 2, top: 6.6)
        // A ring of small dots round the head, open at the bottom.
        let count = 9
        for i in 0..<count {
            let angle = (200.0 - 220.0 * Double(i) / Double(count - 1)) * .pi / 180
            let c = NSPoint(x: head.x + 6.3 * CGFloat(cos(angle)), y: head.y + 6.3 * CGFloat(sin(angle)))
            NSBezierPath(ovalIn: NSRect(x: c.x - 0.75, y: c.y - 0.75, width: 1.5, height: 1.5)).fill()
        }
    }

    private static func adaptive() {
        person(cx: 7.6, headY: 10.2, headRadius: 3.0, width: 11.5, bottom: 2, top: 6.4)
        sparkle(at: NSPoint(x: 14.9, y: 12.4), radius: 2.7)
        sparkle(at: NSPoint(x: 12.1, y: 16.7), radius: 1.5)
    }

    private static func noiseCancellation() {
        let centre = NSPoint(x: 10, y: 10.8)
        let ring = NSBezierPath()
        ring.appendArc(withCenter: centre, radius: 6.2, startAngle: -50, endAngle: 230, clockwise: false)
        ring.lineWidth = 1.2
        ring.lineCapStyle = .round
        ring.stroke()
        person(cx: centre.x, headY: centre.y - 0.2, headRadius: 2.4, width: 9.5, bottom: 2.2, top: 6.2)
    }
}

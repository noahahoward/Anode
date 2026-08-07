import AppKit
import PowerKit

/// The honest ledger: a stacked bar whose segments sum to the MEASURED total, with
/// the unattributable remainder drawn as diagonal hatching.
///
/// This is the app's central visual argument. Activity Monitor renders its energy
/// figures as though apps explain your battery; measured here, apps are often under
/// a tenth of actual draw. The hatch is the part we measured but cannot attribute —
/// display backlight, radios, SSD, kernel, and every root-owned process. It is never
/// redistributed to make the bar look full, and on an idle machine it correctly
/// dominates.
final class LedgerBarView: NSView {

    struct Model {
        let apps_pctHr: Double
        /// Measured CPU power belonging to processes we cannot read (root-owned).
        /// Real process energy, just anonymous — a different claim from "unknown".
        let systemProcesses_pctHr: Double
        let gpu_pctHr: Double
        /// Belongs to no process: display, radios, storage, kernel.
        let unattributed_pctHr: Double
        let total_pctHr: Double
        let source: String            // e.g. "PSTR ×0.89"
        let readable: Int
        let attempted: Int
        /// Set when attribution exceeded measurement — physically impossible, so a
        /// double-counting bug rather than a value to render.
        let overflow: Bool
    }

    var model: Model? { didSet { needsDisplay = true } }

    private let barHeight: CGFloat = 22
    private let legendHeight: CGFloat = 16
    private let gap: CGFloat = 7

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: barHeight + gap + legendHeight)
    }

    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() { redrawOnAppearanceChange() }

    override func draw(_ dirtyRect: NSRect) {
        guard let m = model else { return }
        let barRect = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)

        // Segments are laid out by share of the measured total, so the bar always
        // spans exactly the thing it claims to describe.
        let total = max(m.total_pctHr, 0.0001)
        var widths = [m.apps_pctHr, m.systemProcesses_pctHr, m.gpu_pctHr, m.unattributed_pctHr]
            .map { CGFloat(max(0, $0) / total) * barRect.width }

        // The final segment takes whatever width is left rather than its own share.
        // Each bucket is clamped at zero independently, so in edge cases they need
        // not sum to the total — and a bar that stops short of its own end reads as
        // a rendering fault rather than as data. Any rounding lands in the honest
        // bucket, which is the one already labelled as not precisely known.
        let used = widths[0] + widths[1] + widths[2]
        widths[3] = max(0, barRect.width - used)

        let clip = NSBezierPath(roundedRect: barRect,
                                xRadius: Palette.Radius.chip, yRadius: Palette.Radius.chip)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()

        var x: CGFloat = 0
        // 1. apps
        if widths[0] > 0 {
            Palette.accent.setFill()
            NSRect(x: x, y: 0, width: widths[0], height: barHeight).fill()
            drawLabel(String(format: "apps %.1f", m.apps_pctHr),
                      in: NSRect(x: x, y: 0, width: widths[0], height: barHeight),
                      color: Palette.onAccent)
            x += widths[0]
        }
        // 2. system processes — solid but dimmer: measured process energy we simply
        //    cannot put a name to. Not hatched, because it is not unknown.
        if widths[1] > 0 {
            Palette.accentDim.setFill()
            NSRect(x: x, y: 0, width: widths[1], height: barHeight).fill()
            drawLabel(String(format: "system %.1f", m.systemProcesses_pctHr),
                      in: NSRect(x: x, y: 0, width: widths[1], height: barHeight),
                      color: Palette.onAccent)
            x += widths[1]
        }
        // 3. GPU
        if widths[2] > 0 {
            Palette.blue.setFill()
            NSRect(x: x, y: 0, width: widths[2], height: barHeight).fill()
            x += widths[2]
        }
        // 4. platform — hatched, never solid. This is the only genuinely
        //    unattributable part, and it is display, radios and storage.
        if widths[3] > 0 {
            let r = NSRect(x: x, y: 0, width: widths[3], height: barHeight)
            drawHatch(in: r)
            drawLabel(String(format: "display, radios, storage %.1f %%/hr", m.unattributed_pctHr),
                      in: r, color: Palette.dim)
        }
        NSGraphicsContext.restoreGraphicsState()

        Palette.line.setStroke()
        clip.lineWidth = 1
        clip.stroke()

        drawLegend(m, y: barHeight + gap)
    }

    /// 45° hatch. Drawn by hand rather than with a pattern image so it stays crisp
    /// at any scale factor and follows the appearance without a cache to invalidate.
    private func drawHatch(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        Palette.hatch.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 3
        let spacing: CGFloat = 10
        var start = rect.minX - rect.height
        while start < rect.maxX {
            path.move(to: NSPoint(x: start, y: rect.maxY))
            path.line(to: NSPoint(x: start + rect.height, y: rect.minY))
            start += spacing
        }
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawLabel(_ text: String, in rect: NSRect, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Palette.Font.mono(9.5, .bold),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        // Only label a segment wide enough to hold the text without clipping;
        // a truncated label is worse than none.
        guard size.width + 12 <= rect.width else { return }
        (text as NSString).draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attrs)
    }

    private func drawLegend(_ m: Model, y: CGFloat) {
        var x: CGFloat = 0
        func swatch(_ draw: (NSRect) -> Void, _ label: String) {
            let box = NSRect(x: x, y: y + 4, width: 8, height: 8)
            draw(box)
            x += 13
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Palette.Font.sans(10),
                .foregroundColor: Palette.faint,
            ]
            (label as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            x += (label as NSString).size(withAttributes: attrs).width + 14
        }

        swatch({ r in
            Palette.accent.setFill()
            NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
        }, "apps")
        swatch({ r in
            Palette.accentDim.setFill()
            NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
        }, "system processes")
        swatch({ r in
            Palette.blue.setFill()
            NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
        }, "GPU")
        swatch({ r in
            drawHatch(in: r)
            Palette.line.setStroke()
            NSBezierPath(rect: r).stroke()
        }, "display · radios · storage")

        // Provenance, right-aligned: coverage belongs here rather than in a header
        // because it states how much of the draw we could attribute — which is what
        // this bar is about.
        var right = String(format: "%d of %d readable · total %.1f %%/hr · %@",
                           m.readable, m.attempted, m.total_pctHr, m.source)
        if m.overflow { right = "⚠︎ attribution overflow · " + right }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Palette.Font.mono(10),
            .foregroundColor: m.overflow ? Palette.warn : Palette.faint,
        ]
        let size = (right as NSString).size(withAttributes: attrs)
        if size.width < bounds.width - x - 8 {
            (right as NSString).draw(at: NSPoint(x: bounds.width - size.width, y: y),
                                     withAttributes: attrs)
        }
    }
}

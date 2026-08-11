import AppKit
import PowerKit
import os

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
        /// Carved out of the platform bucket. MEASURED when the backlight rail
        /// is readable, modeled from brightness otherwise — and the label says
        /// which, because this app does not call an estimate a measurement.
        let display_pctHr: Double
        let displayIsMeasured: Bool
        /// Own rails, measured. Zero when the rail is unreadable on this machine.
        let memory_pctHr: Double
        let storage_pctHr: Double
        /// Measured from the step each device caused when it attached. Zero both
        /// when nothing is attached and when everything attached predates the
        /// app — so a zero here is NOT a claim that USB costs nothing, and the
        /// segment is simply absent rather than drawn at 0.0.
        let usb_pctHr: Double
        /// Something is attached whose cost was never observed. The figure above
        /// is then a floor, and the UI must not present it as a total.
        let usbUnmeasured: Bool
        /// Belongs to no process: display, radios, storage, kernel.
        let unattributed_pctHr: Double
        let total_pctHr: Double
        /// The width the segments are laid out ACROSS, which is not always the
        /// number printed beside them.
        ///
        /// `attributed_W` is instantaneous rusage energy; `smoothed_W` is anchored
        /// to the gauge's 60 s mean. Under a sudden load the first can genuinely
        /// exceed the second for a few seconds, and dividing by the headline then
        /// drew "apps = 100% of the machine" — a claim about the layout, not about
        /// the measurement. `Snapshot.ledgerSpan_W` is `max(smoothed_W, claimed_W)`
        /// and is bit-for-bit `smoothed_W` on any non-overflow tick, so nothing
        /// moves at idle.
        ///
        /// nil means the caller has not stated one, and the headline is used —
        /// which is exactly what this view did before the field existed. Nothing
        /// is clamped, the remainder is still drawn, and the overflow ALARM is
        /// untouched: the bar not lying about its own width is not the same thing
        /// as the discrepancy being hidden.
        var span_pctHr: Double? = nil
        let source: String            // e.g. "PSTR ×0.89"
        let readable: Int
        let attempted: Int
        /// Set when attribution exceeded measurement — physically impossible, so a
        /// double-counting bug rather than a value to render.
        let overflow: Bool
    }

    var model: Model? {
        didSet {
            needsDisplay = true
            // The provenance line is the first thing the legend drops when the
            // window is narrow, so give it a second home no layout can take away.
            toolTip = model.map { Self.provenance(for: $0) }
            noteOverflow(model)
        }
    }

    /// How much of the draw we could attribute, and what measured it. Written once
    /// so the legend and the tooltip cannot drift apart.
    private static func coverage(for m: Model) -> String {
        String(format: "%d of %d readable · total %.1f %%/hr · %@",
               m.readable, m.attempted, m.total_pctHr, m.source)
    }

    /// The whole provenance sentence, badge included: what the tooltip carries when
    /// the legend has had to drop part of it.
    private static func provenance(for m: Model) -> String {
        m.overflow ? "⚠︎ attribution overflow · " + coverage(for: m) : coverage(for: m)
    }

    // ── Overflow reporting ──────────────────────────────────────────────────
    //
    // Overflow means attributed power exceeded measured power: physically
    // impossible, so somewhere a watt is being counted twice. The bar cannot show
    // it — the platform bucket is clamped at zero upstream, so every row still
    // looks plausible and the segments still sum to the total. A badge in the
    // legend is therefore the only visible trace, and a badge is only observable
    // by someone who happens to be looking at the window at the time. Log it too.
    private static let log = Logger(subsystem: "dev.noah.betterstats", category: "ledger")

    /// True while the current model is in overflow, so the log fires once per
    /// ENTRY rather than once per sample. The model is replaced on every tick; an
    /// unconditional line here would be a line a second, which is noise, not a
    /// signal.
    private var isOverflowing = false

    private func noteOverflow(_ m: Model?) {
        guard let m, m.overflow else { isOverflowing = false; return }
        guard !isOverflowing else { return }
        isOverflowing = true

        // Everything an author needs to find the double count: each attributed
        // bucket, their sum, the measurement they overran, and by how much. The
        // platform figure is included precisely because it is the clamped one —
        // seeing it at 0.0 alongside a positive excess is the signature.
        let attributed = m.apps_pctHr + m.systemProcesses_pctHr + m.gpu_pctHr + m.display_pctHr
        let detail = String(
            format: "attributed %.3f %%/hr (apps %.3f + system %.3f + gpu %.3f + display %.3f) "
                  + "exceeds measured total %.3f by %.3f; platform bucket shown as %.3f; "
                  + "%d of %d processes readable; source %@",
            attributed, m.apps_pctHr, m.systemProcesses_pctHr, m.gpu_pctHr, m.display_pctHr,
            m.total_pctHr, attributed - m.total_pctHr, m.unattributed_pctHr,
            m.readable, m.attempted, m.source)
        Self.log.error("attribution overflow — \(detail, privacy: .public)")
    }

    /// Which bucket the user clicked, so the graph can drill into it.
    enum Segment: String, CaseIterable {
        case apps, systemProcesses, gpu, memory, storage, usb, display, platform

        var title: String {
            switch self {
            case .apps: return "apps"
            case .systemProcesses: return "system processes"
            case .gpu: return "GPU"
            case .memory: return "memory"
            case .storage: return "storage"
            case .usb: return "USB devices"
            case .display: return "display"
            // Renamed on evidence. Two independent studies found radios are not
            // measurable here at all, and memory and storage are now their own
            // segments — so the old name listed three things that are mostly no
            // longer in this bucket. What IS in it is a ~2.15 W always-on floor
            // that correlates with nothing measurable.
            case .platform: return "always-on & unidentified"
            }
        }
    }

    /// Nil means "show everything again". Clicking the active segment toggles it
    /// off, so the bar is its own way back out — a drill-down you cannot leave by
    /// the control you entered it with is a trap.
    var onSelectSegment: ((Segment?) -> Void)?
    var selectedSegment: Segment? { didSet { needsDisplay = true } }

    /// Where each segment ended up on the last draw, so a click can be resolved
    /// against what is actually on screen rather than against a recomputed guess
    /// that could disagree with it.
    private var segmentRects: [(Segment, NSRect)] = []

    // A bar you can click is a control, and a control that says nothing about
    // itself is invisible to VoiceOver and to every automation tool. Each segment
    // is exposed as a button carrying its own share, so "apps, 12 percent per
    // hour" is readable without seeing the colours at all.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? {
        // A warning drawn as a glyph is invisible to VoiceOver, which is the one
        // audience that never sees the legend at all.
        guard model?.overflow == true else { return "Power ledger" }
        return "Power ledger, attribution overflow: the parts add up to more than the measured total"
    }
    override func accessibilityChildren() -> [Any]? { axCells }

    private lazy var axCells: [NSAccessibilityElement] = Segment.allCases.map { seg in
        let e = SegmentCell(bar: self, segment: seg)
        e.setAccessibilityRole(.button)
        e.setAccessibilityParent(self)
        return e
    }

    fileprivate func rect(for segment: Segment) -> NSRect? {
        segmentRects.first { $0.0 == segment }?.1
    }

    func share(of segment: Segment) -> Double {
        guard let m = model else { return 0 }
        switch segment {
        case .apps: return m.apps_pctHr
        case .systemProcesses: return m.systemProcesses_pctHr
        case .gpu: return m.gpu_pctHr
        case .memory: return m.memory_pctHr
        case .storage: return m.storage_pctHr
        case .usb: return m.usb_pctHr
        case .display: return m.display_pctHr
        case .platform: return m.unattributed_pctHr
        }
    }

    final class SegmentCell: NSAccessibilityElement {
        weak var bar: LedgerBarView?
        let segment: Segment
        init(bar: LedgerBarView, segment: Segment) {
            self.bar = bar
            self.segment = segment
            super.init()
        }
        override func accessibilityLabel() -> String? {
            guard let bar else { return segment.title }
            return String(format: "%@, %.2f percent per hour",
                          segment.title, bar.share(of: segment))
        }
        override func accessibilityValue() -> Any? { bar?.selectedSegment == segment }
        override func accessibilityPerformPress() -> Bool {
            guard let bar else { return false }
            bar.selectedSegment = (bar.selectedSegment == segment) ? nil : segment
            bar.onSelectSegment?(bar.selectedSegment)
            return true
        }
        override func accessibilityFrame() -> NSRect {
            guard let bar, let win = bar.window, let r = bar.rect(for: segment) else { return .zero }
            return win.convertToScreen(bar.convert(r, to: nil))
        }
    }

    /// Act on the first click even when the window was not focused. A one-click
    /// target that silently eats the click that focused the window reads as
    /// broken, and this bar is now the entry point to the whole drill-down.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = segmentRects.first(where: { $0.1.contains(p) })?.0 else { return }
        selectedSegment = (selectedSegment == hit) ? nil : hit
        onSelectSegment?(selectedSegment)
    }

    override func resetCursorRects() {
        // The bar does not look clickable, so say so with the pointer.
        for (_, r) in segmentRects { addCursorRect(r, cursor: .pointingHand) }
    }

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

        // Segments are laid out by share of the ledger SPAN, so the bar always
        // spans exactly the thing it claims to describe — see `Model.span_pctHr`
        // for why that is not always the headline figure printed in the legend.
        let span = max(m.span_pctHr ?? m.total_pctHr, 0.0001)
        var widths = [m.apps_pctHr, m.systemProcesses_pctHr, m.gpu_pctHr,
                      m.memory_pctHr, m.storage_pctHr, m.usb_pctHr,
                      m.display_pctHr, m.unattributed_pctHr]
            .map { CGFloat(max(0, $0) / span) * barRect.width }

        // The final segment takes whatever width is left rather than its own share.
        // Each bucket is clamped at zero independently, so in edge cases they need
        // not sum to the total — and a bar that stops short of its own end reads as
        // a rendering fault rather than as data. Any rounding lands in the honest
        // bucket, which is the one already labelled as not precisely known.
        let used = widths[0] + widths[1] + widths[2] + widths[3] + widths[4] + widths[5] + widths[6]
        widths[7] = max(0, barRect.width - used)

        let clip = NSBezierPath(roundedRect: barRect,
                                xRadius: Palette.Radius.chip, yRadius: Palette.Radius.chip)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()

        var x: CGFloat = 0
        segmentRects.removeAll(keepingCapacity: true)
        // Everything except the chosen segment fades back, so the bar shows what
        // the graph below is currently about.
        func alpha(_ seg: Segment) -> CGFloat {
            guard let sel = selectedSegment else { return 1 }
            return seg == sel ? 1 : 0.28
        }
        // 1. apps
        if widths[0] > 0 {
            Palette.accent.withAlphaComponent(alpha(.apps)).setFill()
            let r0 = NSRect(x: x, y: 0, width: widths[0], height: barHeight)
            r0.fill()
            segmentRects.append((.apps, r0))
            drawLabel(String(format: "apps %.1f", m.apps_pctHr),
                      in: NSRect(x: x, y: 0, width: widths[0], height: barHeight),
                      color: Palette.onAccent)
            x += widths[0]
        }
        // 2. system processes — solid but dimmer: measured process energy we simply
        //    cannot put a name to. Not hatched, because it is not unknown.
        if widths[1] > 0 {
            Palette.accentDim.withAlphaComponent(alpha(.systemProcesses)).setFill()
            let r1 = NSRect(x: x, y: 0, width: widths[1], height: barHeight)
            r1.fill()
            segmentRects.append((.systemProcesses, r1))
            drawLabel(String(format: "system %.1f", m.systemProcesses_pctHr),
                      in: NSRect(x: x, y: 0, width: widths[1], height: barHeight),
                      color: Palette.onAccent)
            x += widths[1]
        }
        // 3. GPU
        if widths[2] > 0 {
            Palette.blue.withAlphaComponent(alpha(.gpu)).setFill()
            let r2 = NSRect(x: x, y: 0, width: widths[2], height: barHeight)
            r2.fill()
            segmentRects.append((.gpu, r2))
            x += widths[2]
        }
        // 4. memory and storage — own rails, measured.
        for (i, seg) in [(3, Segment.memory), (4, Segment.storage), (5, Segment.usb)] {
            guard widths[i] > 0 else { continue }
            Self.color(for: seg).withAlphaComponent(alpha(seg)).setFill()
            let r = NSRect(x: x, y: 0, width: widths[i], height: barHeight)
            r.fill()
            segmentRects.append((seg, r))
            drawLabel(String(format: "%@ %.1f", seg.title,
                             seg == .memory ? m.memory_pctHr
                             : seg == .storage ? m.storage_pctHr : m.usb_pctHr),
                      in: r, color: Palette.onAccent)
            x += widths[i]
        }

        // 5. display — solid and named. Modeled from brightness rather than
        //    measured on a rail, but a calibrated response curve is a far better
        //    answer than leaving several watts in a bucket labelled "unknown".
        if widths[6] > 0 {
            Palette.warn.withAlphaComponent(alpha(.display)).setFill()
            let r3 = NSRect(x: x, y: 0, width: widths[6], height: barHeight)
            r3.fill()
            segmentRects.append((.display, r3))
            drawLabel(String(format: m.displayIsMeasured ? "display %.1f" : "display ~%.1f",
                             m.display_pctHr),
                      in: r3, color: Palette.onAccent)
            x += widths[6]
        }

        // 6. platform — hatched, never solid. This is the only genuinely
        //    unattributable part, and it is display, radios and storage.
        if widths[7] > 0 {
            let r = NSRect(x: x, y: 0, width: widths[7], height: barHeight)
            segmentRects.append((.platform, r))
            drawHatch(in: r)
            drawLabel(String(format: "always-on & unidentified %.1f %%/hr", m.unattributed_pctHr),
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

    /// One place both the bar and its key read from, so a segment can never be
    /// drawn in one colour and described in another.
    static func color(for seg: Segment) -> NSColor {
        switch seg {
        case .apps:           return Palette.accent
        case .systemProcesses: return Palette.accentDim
        case .gpu:            return Palette.blue
        case .memory:         return Palette.violet
        case .storage:        return Palette.teal
        case .usb:            return Palette.critical
        case .display:        return Palette.warn
        case .platform:       return Palette.line
        }
    }

    private func drawLegend(_ m: Model, y: CGFloat) {
        func modelShare(_ seg: Segment) -> Double {
            switch seg {
            case .apps: return m.apps_pctHr
            case .systemProcesses: return m.systemProcesses_pctHr
            case .gpu: return m.gpu_pctHr
            case .memory: return m.memory_pctHr
            case .storage: return m.storage_pctHr
            case .usb: return m.usb_pctHr
            case .display: return m.display_pctHr
            case .platform: return m.unattributed_pctHr
            }
        }
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

        // Every solid segment gets a key. Segments the bar is not drawing are
        // skipped rather than listed at zero — a key for a colour that is not on
        // screen is as confusing as a colour with no key, which is the bug this
        // replaced: memory, storage and USB were drawn and never explained.
        for seg in [Segment.apps, .systemProcesses, .gpu, .memory, .storage, .usb, .display]
        where modelShare(seg) > 0 {
            swatch({ r in
                Self.color(for: seg).setFill()
                NSBezierPath(roundedRect: r, xRadius: Palette.Radius.bar,
                             yRadius: Palette.Radius.bar).fill()
            }, seg.title)
        }
        swatch({ r in
            drawHatch(in: r)
            Palette.line.setStroke()
            NSBezierPath(rect: r).stroke()
        }, "always-on · unidentified")

        // The overflow badge, right-aligned and drawn UNCONDITIONALLY. It used to be
        // a prefix on the provenance string below, which made the warning the
        // longest thing in the row and therefore the first thing dropped — the alarm
        // vanished exactly as the window got tight enough to make it likely. It
        // costs about ten points; there is no width at which it is not affordable.
        var rightEdge = bounds.width
        if m.overflow {
            let badge = "⚠︎" as NSString
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: Palette.Font.mono(10, .bold),
                .foregroundColor: Palette.warn,
            ]
            let badgeWidth = badge.size(withAttributes: badgeAttrs).width
            badge.draw(at: NSPoint(x: rightEdge - badgeWidth, y: y), withAttributes: badgeAttrs)
            rightEdge -= badgeWidth + 5
        }

        // Provenance, right-aligned in what is left: coverage belongs here rather
        // than in a header because it states how much of the draw we could
        // attribute — which is what this bar is about. This is the only part that
        // may be dropped, and the view's tooltip carries it verbatim when it is, so
        // narrowing the window hides nothing outright.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Palette.Font.mono(10),
            .foregroundColor: m.overflow ? Palette.warn : Palette.faint,
        ]
        // In overflow, the words get a short form so they survive one step further
        // in than the coverage figures do.
        let detail = Self.coverage(for: m)
        let candidates = m.overflow
            ? ["attribution overflow · " + detail, "attribution overflow"]
            : [detail]
        let room = rightEdge - x - 8
        for candidate in candidates {
            let text = candidate as NSString
            let size = text.size(withAttributes: attrs)
            guard size.width <= room else { continue }
            text.draw(at: NSPoint(x: rightEdge - size.width, y: y), withAttributes: attrs)
            break
        }
    }
}

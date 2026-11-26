import AppKit
import PowerKit

// ── Hardware View: the hover tooltip and the pinned detail card ─────────────
//
// Both cards present a `HardwareDetail` (the model decides every word; nothing here reads a sensor) and sit on the fixed
// dark stage, so they use `HardwareStyle` literals for ink and fills, not appearance-dependent Palette colours. Both draw
// their content directly in `draw(_:)`: no label or table subviews, so showing a new reading allocates no views. They own no
// timer and no observer.
//
// The look is the approved mockup's `.tip`, `.pin`, `.rows`, `.tag` and `.note`: a 12-point rounded card in rgba(14,17,22,.98)
// with a hairline edge, a title, a small uppercase confidence line, rows (label left in the dim colour, value right with
// tabular digits, a REAL / EST / EXAMPLE chip after the value), and an optional note. Mismatches with the mockup are
// listed in the task 7 report (no drop shadow, system fonts, a sparkline caption in the brief's wording).

/// The colours, sizes and fonts the cards share.
enum HardwareCardStyle {
    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    /// `.tip`, `.pin` background.
    static let background = rgb(0x0E1116, 0.98)
    static let cornerRadius: CGFloat = 12
    /// `.tag.real` (dark ink on `--accent`), `.tag.est` (on `--warm`), `.tag.ex` (on #9fb0c8).
    static let tagRealInk = rgb(0x06281C)
    static let tagEstimateInk = rgb(0x2B1D00)
    static let tagExampleInk = rgb(0x101826)
    static let tagExampleFill = rgb(0x9FB0C8)

    static let titleFont = Palette.Font.sans(13.5, .semibold)
    static let confidenceFont = Palette.Font.mono(10, .medium)
    static let labelFont = Palette.Font.sans(12.5)
    /// A tabular-digit face (`Palette.Font.mono`), so a column of numbers does not jitter as the digits change.
    static let valueFont = Palette.Font.mono(12.5, .medium)
    static let tagFont = Palette.Font.mono(9, .medium)
    static let noteFont = Palette.Font.sans(12)
    static let captionFont = Palette.Font.mono(9.5, .medium)
    static let statFont = Palette.Font.sans(11)
}

/// What a card draws: the detail, the graph values (pinned card only), and the wording that goes with them.
struct HardwareCardContent {
    var detail: HardwareDetail
    /// nil: no graph. An array (even an empty one): a graph box is reserved and drawn.
    var series: [Double?]? = nil
    /// "SINCE YOU OPENED THIS VIEW" or "LAST 24 HOURS".
    var caption: String = ""
    var unit: String = ""
    var isRate = false
    var fractionDigits = 1
    /// `estimate` when the graph follows an estimated reading: its now / range line then says "est.".
    var seriesProvenance: Provenance = .real
    /// A fixed graph scale (the battery's 0...100); nil scales to the values.
    var fixedRange: ClosedRange<Double>? = nil
    var graphColor: NSColor = HardwareStyle.cyan
    /// The tooltip's last line.
    var showsHint = false
    var padding = CGSize(width: 13, height: 11)
    /// Room kept free at the right of the title (the pinned card's close button).
    var titleInset: CGFloat = 0
}

/// Measures and paints a card. One routine does both, so what is measured is what is drawn.
enum HardwareCardRenderer {

    static let hint = "Click to pin details"
    static let sparklineHeight: CGFloat = 52
    private static let textOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    /// REAL, EST or EXAMPLE for a row's provenance; nil (no chip) when the value has none.
    static func tagText(_ p: Provenance?) -> String? {
        switch p {
        case .real?: return "REAL"
        case .estimate?: return "EST"
        case .example?: return "EXAMPLE"
        case nil: return nil
        }
    }

    private static func tagColors(_ p: Provenance?) -> (fill: NSColor, ink: NSColor)? {
        switch p {
        case .real?: return (HardwareStyle.accent, HardwareCardStyle.tagRealInk)
        case .estimate?: return (HardwareStyle.warm, HardwareCardStyle.tagEstimateInk)
        case .example?: return (HardwareCardStyle.tagExampleFill, HardwareCardStyle.tagExampleInk)
        case nil: return nil
        }
    }

    /// A graph value in the series' own unit ("4,380 rpm", "41.2 °C", "38.4 MB/s").
    static func valueText(_ v: Double, unit: String, isRate: Bool, fractionDigits: Int) -> String {
        guard v.isFinite else { return HardwareDetail.missing }
        if isRate {
            if v >= 1e9 { return String(format: "%.2f GB/s", v / 1e9) }
            if v >= 1e6 { return String(format: "%.1f MB/s", v / 1e6) }
            return String(format: "%.1f KB/s", v / 1e3)
        }
        return groupedNumber(v, digits: fractionDigits) + unit
    }

    private static var numberFormatters: [Int: NumberFormatter] = [:]

    /// en_US digits with thousands separators, like the detail rows ("4,380"), whatever the Mac's locale. Main thread only.
    private static func groupedNumber(_ v: Double, digits: Int) -> String {
        let d = max(0, digits)
        let f: NumberFormatter
        if let cached = numberFormatters[d] {
            f = cached
        } else {
            f = NumberFormatter()
            f.locale = Locale(identifier: "en_US")
            f.numberStyle = .decimal
            f.usesGroupingSeparator = true
            f.minimumFractionDigits = d
            f.maximumFractionDigits = d
            numberFormatters[d] = f
        }
        return f.string(from: NSNumber(value: v)) ?? String(format: "%.\(d)f", v)
    }

    /// The pinned graph's now / range line; "est." leads it when the numbers are estimated, not read.
    static func statText(now: String, low: String, high: String, provenance: Provenance) -> String {
        (provenance == .estimate ? "est. " : "") + "now \(now) · range \(low) – \(high)"
    }

    /// The text a screen reader gets for a card (the drawn text itself is not an accessibility element).
    static func summary(_ d: HardwareDetail) -> String {
        var parts = [d.title, d.confidenceNote]
        for r in d.rows {
            parts.append(r.label + " " + r.value + (tagText(r.provenance).map { " " + $0 } ?? ""))
        }
        if let n = d.note { parts.append(n) }
        return parts.filter { !$0.isEmpty }.joined(separator: ". ")
    }

    // MARK: Measure and paint

    /// The height the content needs at a width.
    static func height(of content: HardwareCardContent, width: CGFloat) -> CGFloat {
        run(content, width: width, paint: false)
    }

    /// Paints the content into the current (flipped) graphics context, from the card's top left.
    static func paint(_ content: HardwareCardContent, width: CGFloat) {
        _ = run(content, width: width, paint: true)
    }

    /// The card's rounded background and edge.
    static func paintBackground(in bounds: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: HardwareCardStyle.cornerRadius, yRadius: HardwareCardStyle.cornerRadius)
        HardwareCardStyle.background.setFill()
        path.fill()
        HardwareStyle.edge.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private static func attributed(_ s: String, font: NSFont, color: NSColor, kern: CGFloat = 0,
                                   alignment: NSTextAlignment = .left, lineHeight: CGFloat = 0) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byWordWrapping
        if lineHeight > 0 {
            style.minimumLineHeight = lineHeight
            style.maximumLineHeight = lineHeight
        }
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        if kern != 0 { attrs[.kern] = kern }
        return NSAttributedString(string: s, attributes: attrs)
    }

    private static func measure(_ s: NSAttributedString, width: CGFloat) -> CGSize {
        guard s.length > 0 else { return .zero }
        let r = s.boundingRect(with: NSSize(width: max(1, width), height: 10_000), options: textOptions)
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    private static func draw(_ s: NSAttributedString, in rect: CGRect) {
        guard s.length > 0 else { return }
        s.draw(with: rect, options: textOptions)
    }

    private static func run(_ c: HardwareCardContent, width: CGFloat, paint: Bool) -> CGFloat {
        let d = c.detail
        let padX = c.padding.width
        let contentW = max(40, width - 2 * padX)
        var y = c.padding.height

        // Title and the small uppercase confidence line.
        let title = attributed(d.title, font: HardwareCardStyle.titleFont, color: HardwareStyle.ink)
        let titleW = max(40, contentW - c.titleInset)
        let titleH = measure(title, width: titleW).height
        if paint { draw(title, in: CGRect(x: padX, y: y, width: titleW, height: titleH)) }
        y += titleH + 2

        let conf = attributed(d.confidenceNote.uppercased(), font: HardwareCardStyle.confidenceFont,
                              color: HardwareStyle.faint, kern: 1.0)
        let confH = measure(conf, width: titleW).height
        if paint { draw(conf, in: CGRect(x: padX, y: y, width: titleW, height: confH)) }
        y += confH + 8

        // Rows: label left, value right, the chip after the value.
        let columnGap: CGFloat = 14
        let rowGap: CGFloat = 5
        for row in d.rows {
            let tag = tagText(row.provenance)
            let tagAttr = attributed(tag ?? "", font: HardwareCardStyle.tagFont, color: .black, kern: 0.72)
            let tagSize = measure(tagAttr, width: 400)
            let chipW = tag == nil ? 0 : tagSize.width + 10
            let chipBlock = tag == nil ? 0 : chipW + 6

            let label = attributed(row.label, font: HardwareCardStyle.labelFont, color: HardwareStyle.dim)
            let value = attributed(row.value, font: HardwareCardStyle.valueFont, color: HardwareStyle.ink,
                                   alignment: .right)
            let natural = measure(value, width: 10_000).width
            let valueColumn = min(natural + chipBlock, contentW * 0.6)
            let valueW = max(20, valueColumn - chipBlock)
            let labelW = max(40, contentW - valueColumn - columnGap)
            let valueH = max(measure(value, width: valueW).height, 16)
            let labelH = measure(label, width: labelW).height
            let rowH = max(labelH, valueH)

            if paint {
                draw(label, in: CGRect(x: padX, y: y, width: labelW, height: rowH))
                let valueX = padX + contentW - valueColumn
                draw(value, in: CGRect(x: valueX, y: y, width: valueW, height: rowH))
                if let colors = tagColors(row.provenance), tag != nil {
                    let chipH = tagSize.height + 2
                    let chip = CGRect(x: padX + contentW - chipW, y: y + (16 - chipH) / 2 + 1, width: chipW, height: chipH)
                    let path = NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4)
                    colors.fill.setFill()
                    path.fill()
                    let ink = attributed(tag ?? "", font: HardwareCardStyle.tagFont, color: colors.ink, kern: 0.72)
                    draw(ink, in: CGRect(x: chip.minX + 5, y: chip.minY + 1, width: tagSize.width + 2, height: tagSize.height))
                }
            }
            y += rowH + rowGap
        }
        if !d.rows.isEmpty { y -= rowGap }

        // The graph (pinned card): a 300 x 52 box, its caption, and the latest value and range.
        if let values = c.series {
            y += 10
            let box = CGRect(x: padX, y: y, width: contentW, height: sparklineHeight)
            if paint { paintSparkline(values, in: box, color: c.graphColor, fixedRange: c.fixedRange) }
            y += sparklineHeight + 4

            let caption = attributed(c.caption, font: HardwareCardStyle.captionFont, color: HardwareStyle.faint, kern: 0.95)
            let captionH = measure(caption, width: contentW).height
            if paint { draw(caption, in: CGRect(x: padX, y: y, width: contentW, height: captionH)) }
            y += captionH

            let present = values.compactMap { $0 }
            if let last = present.last, let lo = present.min(), let hi = present.max() {
                func text(_ v: Double) -> String {
                    valueText(v, unit: c.unit, isRate: c.isRate, fractionDigits: c.fractionDigits)
                }
                let stat = attributed(statText(now: text(last), low: text(lo), high: text(hi),
                                               provenance: c.seriesProvenance),
                                      font: HardwareCardStyle.statFont, color: HardwareStyle.dim)
                let statH = measure(stat, width: contentW).height
                y += 2
                if paint { draw(stat, in: CGRect(x: padX, y: y, width: contentW, height: statH)) }
                y += statH
            }
        }

        // The note, then (tooltip only) the hint.
        if let n = d.note, !n.isEmpty {
            y += 9
            let note = attributed(n, font: HardwareCardStyle.noteFont, color: HardwareStyle.dim, lineHeight: 17.4)
            let noteH = measure(note, width: contentW).height
            if paint { draw(note, in: CGRect(x: padX, y: y, width: contentW, height: noteH)) }
            y += noteH
        }
        if c.showsHint {
            y += 6
            let hintText = attributed(hint, font: HardwareCardStyle.noteFont, color: HardwareStyle.faint, lineHeight: 17.4)
            let hintH = measure(hintText, width: contentW).height
            if paint { draw(hintText, in: CGRect(x: padX, y: y, width: contentW, height: hintH)) }
            y += hintH
        }
        return ceil(y + c.padding.height)
    }

    // MARK: Sparkline

    /// The mockup's `spark()`: three faint grid lines, an area at 16 %, the line (gaps break it), and a dot with a halo at the
    /// last value. Drawn into a flipped context; a single value is a dot at the right edge, a flat series runs through the middle.
    static func paintSparkline(_ values: [Double?], in box: CGRect, color: NSColor, fixedRange: ClosedRange<Double>?) {
        let plot = box.insetBy(dx: 6, dy: 6)

        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07).setStroke()
        for k in [0.0, 0.5, 1.0] {
            let line = NSBezierPath()
            let ly = (box.minY + 6 + plot.height * CGFloat(k)).rounded() + 0.5
            line.move(to: NSPoint(x: box.minX, y: ly))
            line.line(to: NSPoint(x: box.maxX, y: ly))
            line.lineWidth = 1
            line.stroke()
        }

        let present = values.compactMap { $0 }
        guard !present.isEmpty else { return }
        let lo = fixedRange?.lowerBound ?? present.min() ?? 0
        let hi = fixedRange?.upperBound ?? present.max() ?? 1
        let range = hi - lo
        let n = values.count

        func px(_ i: Int) -> CGFloat {
            n > 1 ? plot.minX + CGFloat(i) / CGFloat(n - 1) * plot.width : plot.maxX
        }
        func py(_ a: Double) -> CGFloat {
            guard range > 0 else { return plot.midY }
            let t = max(0, min(1, (a - lo) / range))
            return plot.maxY - CGFloat(t) * plot.height
        }

        var segments: [[NSPoint]] = []
        var current: [NSPoint] = []
        for (i, v) in values.enumerated() {
            if let a = v {
                current.append(NSPoint(x: px(i), y: py(a)))
            } else {
                if !current.isEmpty { segments.append(current) }
                current = []
            }
        }
        if !current.isEmpty { segments.append(current) }

        for seg in segments where seg.count > 1 {
            let line = NSBezierPath()
            line.move(to: seg[0])
            for p in seg.dropFirst() { line.line(to: p) }
            let area = line.copy() as? NSBezierPath ?? line
            area.line(to: NSPoint(x: seg[seg.count - 1].x, y: plot.maxY))
            area.line(to: NSPoint(x: seg[0].x, y: plot.maxY))
            area.close()
            color.withAlphaComponent(0.16).setFill()
            area.fill()
            color.setStroke()
            line.lineWidth = 1.8
            line.lineJoinStyle = .round
            line.lineCapStyle = .round
            line.stroke()
        }

        if let end = segments.last?.last {
            color.withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: CGRect(x: end.x - 6, y: end.y - 6, width: 12, height: 12)).fill()
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6)).fill()
        }
    }
}

// ── The hover tooltip ───────────────────────────────────────────────────────

/// The card that follows the pointer over a part. It takes no mouse events at all (`hitTest` is nil), so it can never get
/// between the pointer and the canvas.
final class HardwareTooltipCard: NSView {

    static let maxWidth: CGFloat = 300

    /// The room the stage has for it; the card is `min(maxWidth, availableWidth)` wide. Set before `show`.
    var availableWidth: CGFloat = HardwareTooltipCard.maxWidth

    private var content: HardwareCardContent?

    init() {
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("HardwareTooltipCard is code-only") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    /// It only repeats what the canvas already offers; a screen reader reads the canvas and the pinned card.
    override func isAccessibilityElement() -> Bool { false }

    /// REAL, EST or EXAMPLE (see `HardwareCardRenderer.tagText`).
    static func tagText(_ p: Provenance?) -> String? { HardwareCardRenderer.tagText(p) }

    /// Sets the content and resizes the card to fit it (the origin is the caller's).
    func show(detail: HardwareDetail) {
        var c = HardwareCardContent(detail: detail)
        c.padding = CGSize(width: 13, height: 11)
        content = c
        let width = min(Self.maxWidth, max(160, availableWidth))
        setFrameSize(NSSize(width: width, height: HardwareCardRenderer.height(of: c, width: width)))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = content else { return }
        HardwareCardRenderer.paintBackground(in: bounds)
        HardwareCardRenderer.paint(c, width: bounds.width)
    }
}

// ── The pinned detail card ──────────────────────────────────────────────────

/// The card a click leaves open: the same rows, a close button, the note, and, when the part has a graph, a sparkline.
final class HardwarePinnedCard: NSView {

    static let maxWidth: CGFloat = 330

    /// The close button was pressed.
    var onClose: (() -> Void)?

    /// The room the stage has for it; the card is `min(maxWidth, availableWidth)` wide. Set before `show`.
    var availableWidth: CGFloat = HardwarePinnedCard.maxWidth

    private var content: HardwareCardContent?
    private let closeButton = NSButton()

    init() {
        super.init(frame: .zero)
        closeButton.isBordered = false
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 6
        closeButton.layer?.backgroundColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06).cgColor
        closeButton.attributedTitle = NSAttributedString(
            string: "✕",
            attributes: [.font: Palette.Font.sans(14), .foregroundColor: HardwareStyle.dim])
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.setAccessibilityLabel("Close detail")
        closeButton.setAccessibilityRole(.button)
        closeButton.focusRingType = .exterior
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError("HardwarePinnedCard is code-only") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// A press on the card's own text is not a press on the canvas under it.
    override func mouseDown(with event: NSEvent) {}

    /// The close button, for tests and for the stage's focus order.
    var closeControl: NSButton { closeButton }

    @objc private func closeTapped() {
        onClose?()
    }

    /// REAL, EST or EXAMPLE (see `HardwareCardRenderer.tagText`).
    static func tagText(_ p: Provenance?) -> String? { HardwareCardRenderer.tagText(p) }

    /// "LAST 24 HOURS" for a graph that is the battery's charge history (the detail carries no series of its own for it, or
    /// names the 24 hours); "SINCE YOU OPENED THIS VIEW" for the in-memory buffer every other graph reads.
    static func sparklineCaption(for detail: HardwareDetail) -> String {
        if let ref = detail.series {
            return ref.name.contains("24") ? "LAST 24 HOURS" : "SINCE YOU OPENED THIS VIEW"
        }
        return "LAST 24 HOURS"
    }

    /// Sets the content and resizes the card to fit it (the origin is the caller's). `series` is the graph's values, oldest
    /// first (nil = no graph); for a part whose detail carries its own series (`detail.series`) that series' unit, scale and
    /// wording apply, otherwise the values are a 0...100 percentage (the battery's 24 hours).
    func show(detail: HardwareDetail, series: [Double?]?) {
        var c = HardwareCardContent(detail: detail)
        c.padding = CGSize(width: 15, height: 14)
        c.titleInset = 28
        c.series = series
        c.caption = Self.sparklineCaption(for: detail)
        if let ref = detail.series {
            c.unit = ref.unit
            c.isRate = ref.isRate
            c.fractionDigits = ref.fractionDigits
            c.seriesProvenance = ref.provenance
            c.graphColor = HardwareStyle.cyan
            c.fixedRange = nil
        } else {
            c.unit = " %"
            c.isRate = false
            c.fractionDigits = 0
            c.graphColor = HardwareStyle.accent
            c.fixedRange = 0...100
        }
        content = c
        let width = min(Self.maxWidth, max(200, availableWidth))
        setFrameSize(NSSize(width: width, height: HardwareCardRenderer.height(of: c, width: width)))
        closeButton.frame = NSRect(x: width - 8 - 24, y: 8, width: 24, height: 24)
        setAccessibilityRole(.group)
        setAccessibilityLabel(HardwareCardRenderer.summary(detail))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = content else { return }
        HardwareCardRenderer.paintBackground(in: bounds)
        HardwareCardRenderer.paint(c, width: bounds.width)
    }
}

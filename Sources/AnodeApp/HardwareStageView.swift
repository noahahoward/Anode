import AppKit
import PowerKit

// ── Hardware View: the composed content view ────────────────────────────────
//
// The canvas, the narrow-window chips bar, the hover tooltip and the pinned detail card, as one view the Hardware pane hosts.
// It owns no timer and no observer. The only motion is the chip jump (the canvas easing to a part's `jump` rectangle), which
// a chip click starts and `Motion` ends when it arrives, so a stage nobody touches is as quiet as one that is closed.

// ── Chips ───────────────────────────────────────────────────────────────────

/// One pill in the chips bar (the mockup's `.chips button`).
final class HardwareChipButton: NSButton {

    let chipID: String

    init(label: String, id: String) {
        chipID = id
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        focusRingType = .exterior
        setAccessibilityLabel(label)
        apply(label: label, selected: false)
    }

    required init?(coder: NSCoder) { fatalError("HardwareChipButton is code-only") }

    /// `--cyan` border and a faint cyan fill with the ink colour while selected; dim on a faint white pill otherwise.
    func apply(label: String, selected: Bool) {
        layer?.backgroundColor = (selected
            ? NSColor(srgbRed: 79 / 255, green: 200 / 255, blue: 230 / 255, alpha: 0.12)
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.04)).cgColor
        layer?.borderColor = (selected
            ? HardwareStyle.cyan
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10)).cgColor
        attributedTitle = NSAttributedString(
            string: label,
            attributes: [.font: Palette.Font.sans(12, .medium),
                         .foregroundColor: selected ? HardwareStyle.ink : HardwareStyle.dim])
    }

    /// The pill's width: the text plus 12 points either side.
    var fittingWidth: CGFloat { ceil(attributedTitle.size().width) + 24 }
}

/// The row of component pills a narrow window shows across its top. Scrolls sideways when the pills do not fit.
final class HardwareChipsBar: NSView {

    static let height: CGFloat = 40
    private static let pillHeight: CGFloat = 28

    /// A pill was chosen (by click or from the keyboard): the component id.
    var onSelect: ((String) -> Void)?

    private(set) var chips: [(label: String, id: String)] = []
    private(set) var selectedID: String?
    private let scroll = NSScrollView()
    private let row = NSView()
    private var buttons: [HardwareChipButton] = []

    init() {
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.documentView = row
        addSubview(scroll)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Jump to a part")
    }

    required init?(coder: NSCoder) { fatalError("HardwareChipsBar is code-only") }

    override var isFlipped: Bool { true }

    /// Replaces the pills, but only when they differ from the ones shown (so a reading that arrives builds nothing). The
    /// selection stays if its part is still there, otherwise it becomes the first pill.
    func setChips(_ new: [(label: String, id: String)]) {
        let same = new.count == chips.count && zip(new, chips).allSatisfy { pair in pair.0.label == pair.1.label && pair.0.id == pair.1.id }
        if same { return }
        chips = new
        for b in buttons { b.removeFromSuperview() }
        buttons = new.map { chip in
            let b = HardwareChipButton(label: chip.label, id: chip.id)
            b.target = self
            b.action = #selector(chipPressed(_:))
            row.addSubview(b)
            return b
        }
        let stillThere = selectedID.map { s in new.contains(where: { $0.id == s }) } ?? false
        if !stillThere { selectedID = new.first?.id }
        refreshStyles()
        layoutChips()
    }

    /// Selects a pill without telling `onSelect`.
    func select(_ id: String) {
        guard chips.contains(where: { $0.id == id }) else { return }
        selectedID = id
        refreshStyles()
        if let b = buttons.first(where: { $0.chipID == id }) { row.scrollToVisible(b.frame) }
    }

    private func refreshStyles() {
        for (b, chip) in zip(buttons, chips) {
            b.apply(label: chip.label, selected: chip.id == selectedID)
        }
    }

    @objc private func chipPressed(_ sender: NSButton) {
        guard let b = sender as? HardwareChipButton else { return }
        select(b.chipID)
        onSelect?(b.chipID)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutChips()
    }

    override func layout() {
        super.layout()
        layoutChips()
    }

    private func layoutChips() {
        scroll.frame = bounds
        var x: CGFloat = 12
        let y = (Self.height - Self.pillHeight) / 2
        for b in buttons {
            let w = b.fittingWidth
            b.frame = NSRect(x: x, y: y, width: w, height: Self.pillHeight)
            x += w + 6
        }
        row.frame = NSRect(x: 0, y: 0, width: max(bounds.width, x + 6), height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 13 / 255, green: 16 / 255, blue: 21 / 255, alpha: 1).setFill()
        bounds.fill()
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

// ── The stage ───────────────────────────────────────────────────────────────

final class HardwareStageView: NSView {

    /// A stage narrower than this shows the chips bar and one part at a time.
    static let narrowThreshold: CGFloat = 640
    /// How long the canvas takes to ease to a chip's part (`Eased` settles in `Motion.duration`; the time is scaled to this).
    static let focusDuration: TimeInterval = 0.25

    static func isNarrow(width: CGFloat) -> Bool { width < narrowThreshold }

    /// One chip per part that has a jump rectangle and a label, in layout order, a repeated label kept once (its first part).
    static func chipLabels(for layout: HardwareLayout) -> [(label: String, id: String)] {
        var seen = Set<String>()
        var out: [(label: String, id: String)] = []
        for c in layout.components {
            guard c.jump != nil, let label = c.jumpLabel, !label.isEmpty, !seen.contains(label) else { continue }
            seen.insert(label)
            out.append((label: label, id: c.id))
        }
        return out
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(v, lo), max(lo, hi))
    }

    /// Where the tooltip goes: beside the pointer, flipped to its other side when it would leave the stage, then clamped inside.
    static func tooltipOrigin(size: CGSize, pointer p: NSPoint, stage: CGSize,
                              pad: CGFloat = 16, topInset: CGFloat = 8) -> NSPoint {
        var x = p.x + pad
        var y = p.y + pad
        if x + size.width > stage.width - 8 { x = p.x - size.width - pad }
        if y + size.height > stage.height - 8 { y = p.y - size.height - pad }
        return NSPoint(x: clamp(x, 8, stage.width - size.width - 8),
                       y: clamp(y, topInset, stage.height - size.height - 8))
    }

    /// Where the pinned card docks: right of the part in a wide stage (left of it when there is no room), below it in a narrow
    /// one (above it when there is no room), then clamped inside the stage.
    static func dockOrigin(size: CGSize, around r: CGRect, stage: CGSize, narrow: Bool,
                           gap: CGFloat = 12, topInset: CGFloat = 8) -> NSPoint {
        var x: CGFloat
        var y: CGFloat
        if narrow {
            x = r.minX
            y = r.maxY + gap
            if y + size.height > stage.height - 8 { y = r.minY - size.height - gap }
        } else {
            x = r.maxX + gap
            if x + size.width > stage.width - 8 { x = r.minX - size.width - gap }
            y = r.minY
        }
        return NSPoint(x: clamp(x, 8, stage.width - size.width - 8),
                       y: clamp(y, topInset, stage.height - size.height - 8))
    }

    private static func lerp(_ a: HWRect, _ b: HWRect, _ t: CGFloat) -> HWRect {
        let k = Double(t)
        return HWRect(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k,
                      w: a.w + (b.w - a.w) * k, h: a.h + (b.h - a.h) * k)
    }

    // MARK: Parts of the view

    let canvas: HardwareCanvasView
    let chipsBar = HardwareChipsBar()
    let tooltipCard = HardwareTooltipCard()
    let pinnedCard = HardwarePinnedCard()

    /// Forwarded to the canvas.
    var isDrawableNow: () -> Bool {
        get { canvas.isDrawableNow }
        set { canvas.isDrawableNow = newValue }
    }
    var onFanSlider: ((Int, Double?) -> Void)? {
        get { canvas.onFanSlider }
        set { canvas.onFanSlider = newValue }
    }
    var onInstallHelper: (() -> Void)? {
        get { canvas.onInstallHelper }
        set { canvas.onInstallHelper = newValue }
    }

    /// The part whose card is pinned, and which battery reading it shows.
    private(set) var pinnedID: String?
    private var pinnedRole: String?
    /// Where the click was (stage coordinates), for a part with no box of its own.
    private var pinPoint = NSPoint.zero
    private var tipKey: String?
    private let emptyHistory = HardwareHistory()

    private var wasNarrow = false
    private var ease = Eased()
    private var isEasing = false
    private var focusFrom = HWRect(x: 0, y: 0, w: 1, h: 1)
    private var focusTarget = HWRect(x: 0, y: 0, w: 1, h: 1)

    init(layout: HardwareLayout) {
        canvas = HardwareCanvasView(layout: layout)
        super.init(frame: .zero)
        addSubview(canvas)
        addSubview(chipsBar)
        addSubview(pinnedCard)
        addSubview(tooltipCard)
        chipsBar.isHidden = true
        tooltipCard.isHidden = true
        pinnedCard.isHidden = true
        chipsBar.setChips(Self.chipLabels(for: layout))

        canvas.onHover = { [weak self] component, point in self?.handleHover(component, point) }
        canvas.onClick = { [weak self] component, role, point in self?.handleClick(component, role, point) }
        chipsBar.onSelect = { [weak self] _ in self?.applyFocus(animated: true) }
        pinnedCard.onClose = { [weak self] in self?.unpin() }
    }

    required init?(coder: NSCoder) { fatalError("HardwareStageView is code-only") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Data

    /// Hands the stage a new reading. Builds no views: the canvas repaints (if the owner says it is worth it) and any open
    /// card is rewritten from the new data.
    func update(layout: HardwareLayout,
                readings: HardwareReadings?,
                history: HardwareHistory,
                chargeHistory: [Double?],
                menuBarWidgets: [MenuBarWidgetText]) {
        canvas.hardwareLayout = layout
        canvas.readings = readings
        canvas.history = history
        canvas.chargeHistory = chargeHistory
        canvas.menuBarWidgets = menuBarWidgets

        chipsBar.setChips(Self.chipLabels(for: layout))
        if let id = pinnedID, component(id: id) == nil { unpin() }
        if canvas.isNarrow, !isEasing, canvas.focusRect != selectedJump() { applyFocus(animated: false) }

        if canvas.isDrawableNow() {
            refreshPinned()
            refreshTip()
        }
        canvas.readingsChanged()
    }

    private func component(id: String) -> HardwareComponent? {
        canvas.hardwareLayout.components.first { $0.id == id }
    }

    private func detail(for component: HardwareComponent, role: String?) -> HardwareDetail? {
        guard let readings = canvas.readings else { return nil }
        return HardwareDetail.make(component: component, readings: readings,
                                   history: canvas.history ?? emptyHistory, role: role)
    }

    private func selectedJump() -> HWRect? {
        guard let id = chipsBar.selectedID else { return nil }
        return component(id: id)?.jump
    }

    // MARK: Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyLayout()
    }

    override func layout() {
        super.layout()
        applyLayout()
    }

    /// Re-evaluated whenever the size changes: chips and one-part-at-a-time zoom below the threshold, the whole layout above it.
    private func applyLayout() {
        let narrow = Self.isNarrow(width: bounds.width)
        chipsBar.isHidden = !narrow
        let barHeight = narrow ? HardwareChipsBar.height : 0
        let barFrame = NSRect(x: 0, y: 0, width: bounds.width, height: HardwareChipsBar.height)
        if chipsBar.frame != barFrame { chipsBar.frame = barFrame }
        let canvasFrame = NSRect(x: 0, y: barHeight, width: bounds.width, height: max(0, bounds.height - barHeight))
        if canvas.frame != canvasFrame { canvas.frame = canvasFrame }

        if narrow != wasNarrow {
            wasNarrow = narrow
            canvas.isNarrow = narrow
            hideTip()
            if narrow {
                applyFocus(animated: false)
            } else {
                isEasing = false
                canvas.focusRect = nil
            }
        }

        tooltipCard.availableWidth = min(HardwareTooltipCard.maxWidth, bounds.width - 20)
        pinnedCard.availableWidth = min(HardwarePinnedCard.maxWidth, bounds.width - 20)
        if pinnedID != nil {
            refreshPinned()
        }
    }

    // MARK: Chip jump

    /// Points the canvas at the selected chip's part: at once, or eased over about 250 ms (never with Reduce Motion on).
    private func applyFocus(animated: Bool) {
        guard canvas.isNarrow, let target = selectedJump() else {
            if canvas.isNarrow { canvas.focusRect = nil }
            return
        }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated, !reduce else {
            isEasing = false
            canvas.focusRect = target
            placePinned()
            return
        }
        focusFrom = canvas.focusRect ?? canvas.hardwareLayout.size
        focusTarget = target
        ease.set(0)
        ease.aim(1)
        isEasing = true
        Motion.shared.start(self) { [weak self] dt in
            guard let self = self, self.isEasing else { return false }
            let moving = self.ease.advance(dt * Motion.duration / HardwareStageView.focusDuration)
            self.canvas.focusRect = HardwareStageView.lerp(self.focusFrom, self.focusTarget, self.ease.value)
            self.placePinned()
            if !moving { self.isEasing = false }
            return moving
        }
    }

    // MARK: Hover

    private func handleHover(_ component: HardwareComponent?, _ canvasPoint: NSPoint) {
        guard let component = component, canvas.readings != nil else { hideTip(); return }
        let lp = canvas.layoutPoint(fromView: canvasPoint)
        let role = canvas.batteryRole(atLayoutPoint: lp, in: component)
        // Nothing pops up for the pinned part (any of its readings), nor on top of the pinned card.
        let p = convert(canvasPoint, from: canvas)
        if component.id == pinnedID { hideTip(); return }
        if !pinnedCard.isHidden && pinnedCard.frame.contains(p) { hideTip(); return }
        let key = component.id + "|" + (role ?? "")
        if key != tipKey || tooltipCard.isHidden {
            guard let d = detail(for: component, role: role), !d.rows.isEmpty else { hideTip(); return }
            tipKey = key
            tooltipCard.availableWidth = min(HardwareTooltipCard.maxWidth, bounds.width - 20)
            tooltipCard.show(detail: d)
        }
        tooltipCard.setFrameOrigin(Self.tooltipOrigin(size: tooltipCard.frame.size, pointer: p, stage: bounds.size,
                                                      topInset: canvas.isNarrow ? HardwareChipsBar.height + 8 : 8))
        tooltipCard.isHidden = false
    }

    private func hideTip() {
        tipKey = nil
        tooltipCard.isHidden = true
    }

    /// Rewrites a visible tooltip from the newest reading (its part and reading are remembered in `tipKey`).
    private func refreshTip() {
        guard !tooltipCard.isHidden, let key = tipKey else { return }
        let pieces = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard let id = pieces.first.map(String.init), let c = component(id: id) else { hideTip(); return }
        let role: String? = pieces.count > 1 && !pieces[1].isEmpty ? String(pieces[1]) : nil
        guard let d = detail(for: c, role: role), !d.rows.isEmpty else { hideTip(); return }
        let origin = tooltipCard.frame.origin
        tooltipCard.show(detail: d)
        tooltipCard.setFrameOrigin(origin)
    }

    // MARK: Pin

    private func handleClick(_ component: HardwareComponent?, _ role: String?, _ canvasPoint: NSPoint) {
        hideTip()
        window?.makeFirstResponder(self)
        guard let component = component,
              let d = detail(for: component, role: role), !d.rows.isEmpty else {
            unpin()
            return
        }
        pinnedID = component.id
        pinnedRole = role
        pinPoint = convert(canvasPoint, from: canvas)
        canvas.pinnedID = component.id
        pinnedCard.isHidden = false
        refreshPinned()
    }

    /// The tab was left: the pinned card closes and the hover tooltip goes.
    func reset() {
        unpin()
        hideTip()
    }

    /// Closes the pinned card (empty space was clicked, Escape was pressed, or its close button was).
    func unpin() {
        pinnedID = nil
        pinnedRole = nil
        canvas.pinnedID = nil
        pinnedCard.isHidden = true
    }

    /// Rewrites the pinned card from the newest reading and puts it back beside its part.
    private func refreshPinned() {
        guard let id = pinnedID else { return }
        // No reading at all for a moment: keep what the card shows rather than closing it.
        guard canvas.readings != nil else { return }
        guard let c = component(id: id), let d = detail(for: c, role: pinnedRole), !d.rows.isEmpty else {
            unpin()
            return
        }
        let series: [Double?]?
        if c.kind == .battery && pinnedRole == "graph" {
            series = canvas.chargeHistory.contains { $0 != nil } ? canvas.chargeHistory : nil
        } else {
            series = d.series?.values
        }
        pinnedCard.show(detail: d, series: series)
        placePinned()
    }

    private func stageRect(of c: HardwareComponent) -> CGRect? {
        var box: HWRect?
        if let r = c.rect, r.w > 0, r.h > 0 {
            box = r
        } else if let first = c.points.first {
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in c.points {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            box = HWRect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
        }
        guard let b = box else { return nil }
        return canvas.convert(canvas.viewRect(fromLayout: b), to: self)
    }

    private func placePinned() {
        guard let id = pinnedID, !pinnedCard.isHidden else { return }
        let around: CGRect
        if let c = component(id: id), let r = stageRect(of: c) {
            around = r
        } else {
            around = CGRect(x: pinPoint.x, y: pinPoint.y, width: 1, height: 1)
        }
        pinnedCard.setFrameOrigin(Self.dockOrigin(size: pinnedCard.frame.size, around: around, stage: bounds.size,
                                                  narrow: canvas.isNarrow,
                                                  topInset: canvas.isNarrow ? HardwareChipsBar.height + 8 : 8))
    }

    // MARK: Keyboard

    /// Escape reaching the stage from a focused chip or the close button.
    override func cancelOperation(_ sender: Any?) {
        if pinnedID != nil {
            unpin()
        } else {
            super.cancelOperation(sender)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, pinnedID != nil {   // Escape
            unpin()
            return
        }
        super.keyDown(with: event)
    }
}

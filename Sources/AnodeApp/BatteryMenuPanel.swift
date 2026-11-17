import AppKit
import PowerKit

// ── Anode's Battery menu, drawn ─────────────────────────────────────────────
//
// The same glass and the same row looks as the Sound menu (macOS's two panels share them), laid out by `BatteryMenuLayout`
// from the numbers measured on macOS's own Battery panel. The panel is a window of its own that never takes focus, opens where
// macOS's would (right edge 10.5 pt past the icon's, or the left edge 10.5 pt before it for an icon far to the left; 1 pt under the bar) and closes on a click anywhere else or on Esc.

/// The glyph on an Energy Mode's badge. Automatic and Low Power are SF Symbols; High Power's (a battery with three triangles in
/// it) is not one the system gives out by name, so it is drawn, in the same outline.
enum BatteryGlyphs {
    static func image(for modeID: String, pointSize: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        func symbol(_ name: String) -> NSImage? {
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        }
        switch modeID {
        case "low": return symbol("battery.25percent")
        case BatteryMenuController.ultraID: return symbol("moon.zzz.fill")
        case "high": return highPower(outline: symbol("battery.0percent"))
        default: return symbol("battery.100percent")
        }
    }

    /// The outline of an empty battery, half as strong as the rest, with three solid triangles pointing right inside it (measured on
    /// macOS's badge, as fractions of the whole symbol: the triangles start 0.143 in from the left and end 0.74, each 0.18 wide,
    /// half the height of the symbol and on its middle).
    private static func highPower(outline: NSImage?) -> NSImage? {
        guard let outline, let bounds = opaqueBounds(of: outline) else { return nil }
        let image = NSImage(size: outline.size, flipped: false) { rect in
            outline.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.5)
            NSColor.black.setFill()
            let h = bounds.height * 0.47
            let midY = bounds.midY
            for i in 0..<3 {
                let x = bounds.minX + bounds.width * (0.143 + 0.2 * CGFloat(i))
                let w = bounds.width * 0.18
                let t = NSBezierPath()
                t.move(to: NSPoint(x: x, y: midY - h / 2))
                t.line(to: NSPoint(x: x, y: midY + h / 2))
                t.line(to: NSPoint(x: x + w, y: midY))
                t.close()
                t.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Where the symbol's own drawing is inside its image, in points (the image is a little larger than what is drawn).
    private static func opaqueBounds(of image: NSImage) -> NSRect? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let w = cg.width, h = cg.height, bpp = cg.bitsPerPixel / 8
        var x0 = w, x1 = -1, y0 = h, y1 = -1
        for y in 0..<h { for x in 0..<w where bytes[y * cg.bytesPerRow + x * bpp + bpp - 1] > 40 || bytes[y * cg.bytesPerRow + x * bpp] > 40 {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        } }
        guard x1 >= x0, y1 >= y0 else { return nil }
        let sx = image.size.width / CGFloat(w), sy = image.size.height / CGFloat(h)
        // The image's y runs up, the bitmap's down.
        return NSRect(x: CGFloat(x0) * sx, y: image.size.height - CGFloat(y1 + 1) * sy, width: CGFloat(x1 - x0 + 1) * sx, height: CGFloat(y1 - y0 + 1) * sy)
    }
}

/// The panel that holds the menu. It does not take focus from the app in front.
final class BatteryMenuPanel: NSPanel, BatteryMenuPresenting {

    weak var controller: BatteryMenuController? { didSet { content.controller = controller } }

    private let content = BatteryMenuContentView()
    private var monitors: [Any] = []
    private var anchor = CGRect.zero

    var isOpen: Bool { isVisible }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // The level of the Sound menu: macOS's own panel opens for a moment where this one is about to be, under a still picture
        // of that place, and this menu is above both.
        level = NSWindow.Level(rawValue: SoundMenuPanel.level)
        isReleasedWhenClosed = false
        animationBehavior = .none   // macOS's own menu appears at once, without the window zoom
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = content
        setAccessibilityIdentifier("dev.anode.batteryMenu")
        sideObserver = NotificationCenter.default.addObserver(forName: PanelSides.changed, object: nil, queue: .main) { [weak self] _ in
            self?.relocate()
        }
    }

    private var sideObserver: NSObjectProtocol?
    deinit { if let sideObserver { NotificationCenter.default.removeObserver(sideObserver) } }

    /// macOS opened its panel on the other side of the icon than was assumed: this menu goes to that side, where it is.
    private func relocate() {
        guard isVisible, let screen = NSScreen.screens.first else { return }
        setFrameOrigin(NSPoint(x: PanelSides.menuMinX(anchor: anchor, width: frame.width, in: screen), y: frame.minY))
    }

    /// Never key and never main (see `SoundMenuPanel`): Esc is heard by a global monitor instead.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ model: BatteryMenuModel, below frame: CGRect) {
        anchor = frame
        content.apply(model)
        place()
        orderFrontRegardless()
        // A click anywhere else closes the menu.
        if let click = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            self?.closeUnlessOnItem()
        }) { monitors.append(click) }
        // Esc closes it, as it does macOS's own. Reads nothing but the key code and keeps nothing.
        if let esc = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            if event.keyCode == 53 { self?.controller?.closeMenu() }
        }) { monitors.append(esc) }
    }

    func update(_ model: BatteryMenuModel) {
        guard isVisible else { return }
        content.apply(model)
        place()
    }

    /// The menu drew something it had been holding back (a drag ended): fit the window to it.
    func contentChanged() { place(); invalidateShadow() }

    override func close() { close(fade: true) }

    func close(fade: Bool) {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        // macOS's fades out, except when another icon's panel takes its place; so does this, as a picture of itself (see `PanelFade`).
        if fade { PanelFade.close(self) { orderOut(nil) } } else { orderOut(nil) }
    }

    /// A click anywhere else closes the menu; a click on the icon is the icon's own toggle.
    private func closeUnlessOnItem() {
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first else { return }
        let top = CGPoint(x: p.x, y: screen.frame.height - p.y)
        if !anchor.contains(top) && !frame.contains(p) {
            // Another icon of the menu bar takes the panel's place at once, as macOS's does; anywhere else the panel fades.
            controller?.closeMenu(fade: ClickAway.fades(whenClickLandsOn: MenuBarHit.role(at: top)))
        }
    }

    /// Right edge a little past the icon's, top just under the menu bar, like macOS's.
    private func place() {
        guard let screen = NSScreen.screens.first else { return }
        let size = content.fittingSize
        let bar = max(NSStatusBar.system.thickness, screen.frame.height - screen.visibleFrame.maxY)
        let x = PanelSides.menuMinX(anchor: anchor, width: size.width, in: screen)
        // macOS's panel is 277.5 pt (a half point more with each further app) and its top edge is on a half point (40.5 pt down), so it
        // ends on a whole one. A window is whole points: it starts at 40, a half point above the picture, and the picture is pinned to
        // its bottom, whatever the window did. Left to the window, the picture came out half a point higher or lower depending on
        // whether the window's frame had changed since the last opening.
        let top = screen.frame.height - bar - BatteryMenuMetrics.gapBelowBar
        let h = (size.height + BatteryMenuMetrics.pictureDrop).rounded(.up)
        setFrame(NSRect(x: x, y: top - h, width: size.width, height: h), display: true)
        content.frame = NSRect(x: 0, y: h - BatteryMenuMetrics.pictureDrop - size.height, width: size.width, height: size.height)
        // The shadow follows what is drawn; worked out before the rounded glass had drawn it comes out square at the corners.
        DispatchQueue.main.async { [weak self] in self?.invalidateShadow() }
    }
}

// ── The drawing ─────────────────────────────────────────────────────────────

final class BatteryMenuContentView: NSView {

    weak var controller: BatteryMenuController?
    private var model: BatteryMenuModel?
    private var size = NSSize(width: BatteryMenuMetrics.width, height: 100)
    private let material: NSView = {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 17
            return glass
        }
        let v = NSVisualEffectView()
        v.material = .menu
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 17
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }()
    private let edge = EdgeView()
    /// macOS's glass measures a little lighter than the same glass drawn here (the Sound menu's measurement): added over the panel.
    private let baseLift = NSView()

    override var isFlipped: Bool { true }
    override var fittingSize: NSSize { size }

    /// A dynamic colour as a layer colour, for the appearance this menu is in.
    private func cg(_ color: NSColor) -> CGColor {
        var out = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { out = color.cgColor }
        return out
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 17
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        addSubview(material)
        if #available(macOS 26.0, *), SoundText.isDark {
            baseLift.wantsLayer = true
            baseLift.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.016).cgColor
            baseLift.layer?.compositingFilter = "plusL"
            addSubview(baseLift)
        } else if !SoundText.isDark {
            baseLift.wantsLayer = true
            baseLift.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
            addSubview(baseLift)
        }
        edge.wantsLayer = true
        edge.layer?.cornerRadius = 17
        edge.layer?.cornerCurve = .continuous
        edge.layer?.borderWidth = 0.5
        edge.layer?.borderColor = NSColor.white.withAlphaComponent(0.05).cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The mode rows now drawn, so a change of the mode in force turns their badges instead of drawing the menu again.
    private var modeRows: [String: ModeRow] = [:]
    private var appRows: [String: EnergyAppRow] = [:]
    /// The "Charge Limit: 80%" heading, which follows the slider while it is dragged.
    private var chargeHeading: NSTextField?
    private var deferred: BatteryMenuModel?
    private var dragObserver: NSObjectProtocol?

    func apply(_ model: BatteryMenuModel) {
        if dragObserver == nil {
            dragObserver = NotificationCenter.default.addObserver(forName: .menuSliderDragEnded, object: nil, queue: .main) { [weak self] _ in
                guard let self, let pending = self.deferred else { return }
                self.deferred = nil
                self.apply(pending)
                (self.window as? BatteryMenuPanel)?.contentChanged()
            }
        }
        // A slider is held: drawing the menu again would replace it under the pointer. What changed is drawn when it is let go.
        if MenuSlider.activeDrags > 0, self.model != nil { deferred = model; return }
        deferred = nil
        if self.model == model { return }
        // Only which mode is in force changed: the badges turn, nothing is drawn again.
        // Only which mode is in force, or a figure beside an app, changed: those are changed where they are, so that a measurement coming
        // in never draws the menu again under a badge that is turning.
        if let old = self.model, old.modes.map(\.id) == model.modes.map(\.id), old.energyApps.map(\.name) == model.energyApps.map(\.name),
           !modeRows.isEmpty {
            var same = old
            same.modes = model.modes; same.energyApps = model.energyApps
            if same == model {
                self.model = model
                for m in model.modes { modeRows[m.id]?.setSelected(m.isSelected, animated: true) }
                for a in model.energyApps { appRows[a.name]?.update(stats: a.stats) }
                return
            }
        }
        modeRows = [:]; appRows = [:]; chargeHeading = nil
        self.model = model
        for v in subviews where v !== material && v !== baseLift { v.removeFromSuperview() }
        let layout = BatteryMenuLayout.frames(for: model)
        size = NSSize(width: BatteryMenuMetrics.width, height: layout.height)
        frame.size = size
        material.frame = bounds
        baseLift.frame = bounds
        edge.frame = bounds
        for row in layout.rows { add(row, model) }
        addSubview(edge)   // last, so it is drawn over everything
        invalidateIntrinsicContentSize()
    }

    private func add(_ row: BatteryMenuLayout.LaidOutRow, _ model: BatteryMenuModel) {
        // Everything but the lines sits half a point lower than the measured frames say, on macOS's pixels (the highlight under the
        // pointer, the text, the badges).
        var f = row.frame
        if row.kind != .divider { f = f.offsetBy(dx: 0, dy: BatteryMenuMetrics.contentDrop) }
        switch row.kind {
        case .title:
            addSubview(label("Battery", f, size: 13, weight: .semibold, color: SoundText.primary))
        case .powerSource:
            addSubview(label(AppleBatteryPanel.powerSourcePrefix + model.powerSource, f, size: 12, weight: .regular, color: Self.secondary))
        case .statusLine:
            addSubview(label(model.statusLine ?? "", f, size: 12, weight: .regular, color: Self.secondary))
        case .divider:
            let d = NSView(frame: f)
            d.wantsLayer = true
            d.layer?.backgroundColor = cg(SoundText.ink(0.15))
            addSubview(d)
        case .heading(let title):
            let l = label(title, f, size: 12, weight: .semibold, color: Self.secondary)
            if title.hasPrefix(BatteryMenuLayout.chargeLimitHeading) { chargeHeading = l }
            addSubview(l)
        case .mode(let i):
            guard model.modes.indices.contains(i) else { return }
            let mode = model.modes[i]
            let v = ModeRow(frame: f.insetBy(dx: -BatteryRow.lead, dy: 0), mode: mode)
            v.onPick = { [weak self] in self?.controller?.pickMode(mode.id) }
            modeRows[mode.id] = v
            addSubview(v)
        case .app(let i):
            guard model.energyApps.indices.contains(i) else { return }
            let app = model.energyApps[i]
            let v = EnergyAppRow(frame: f.insetBy(dx: -BatteryRow.lead, dy: 0), name: app.name, stats: app.stats)
            appRows[app.name] = v
            addSubview(v)
        case .gear:
            addSubview(IconButton(symbol: "gearshape", size: 13, weight: .regular, tint: 0.42, added: true, frame: f) { [weak self] in
                self?.controller?.pressGear()
            })
        case .chargeLimit:
            guard let charge = model.chargeLimit else { return }
            let v = ChargeLimitRowView(frame: f, charge: charge)
            // The heading above carries the number: it follows the knob while it is dragged.
            v.onDrag = { [weak self] value in self?.chargeHeading?.stringValue = BatteryMenuLayout.chargeLimitTitle(value) }
            v.onCommit = { [weak self] value in self?.controller?.commitChargeLimit(value) }
            v.onPressTopUp = { [weak self] in self?.controller?.pressTopUp() }
            v.onPressDrain = { [weak self] in self?.controller?.pressMinus() }
            v.onHoldDrain = { [weak self] in self?.controller?.holdMinus() }
            addSubview(v)
        case .footer:
            let b = FooterRow(frame: f.insetBy(dx: -BatteryRow.lead, dy: 0), title: Self.settingsTitle)
            b.onPick = { [weak self] in self?.controller?.pressSettings() }
            addSubview(b)
        }
    }

    static let settingsTitle = "Battery Settings…"

    /// The dimmer text (the power source, the headings): white at 0.40 over the glass in the dark appearance (measured: 131 on a
    /// 55 backdrop, where the system's secondary label colour gave 161); black at 0.42 in the light one (143 on 246).
    static let secondary = SoundText.ink(dark: 0.40, light: 0.42)

    private func label(_ text: String, _ frame: CGRect, size: CGFloat, weight: NSFont.Weight, color: NSColor, dy: CGFloat = 0) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        // A text field draws its text 2 pt in from its frame: the layout's x is where the text itself starts (measured).
        l.frame = frame.offsetBy(dx: -2, dy: dy)
        l.lineBreakMode = .byTruncatingTail
        return l
    }
}

/// What the rows of the Battery menu share: the highlight under the pointer reaches 7 pt in from each edge of the panel (measured:
/// 294 wide, 10 pt corners, as tall as the row, as bright on every row), while the content starts at the 14 pt inset.
enum BatteryRow {
    static let lead: CGFloat = 7
}

/// The charge limit: a slider for the limit (its percentage is in the heading above, which follows the drag) and, to the right of it,
/// the two buttons: Top Up (charge to 100% this once) and Drain (a press is Soft Drain to Limit, a hold of three seconds asks about
/// Hard Drain). The limit is written when the slider is let go.
final class ChargeLimitRowView: NSView {

    var onDrag: ((Int) -> Void)?
    var onCommit: ((Int) -> Void)?
    var onPressTopUp: (() -> Void)?
    var onPressDrain: (() -> Void)?
    var onHoldDrain: (() -> Void)?

    /// The gap between the slider and the first button, and between the buttons.
    static let sliderGap: CGFloat = 10
    static let buttonGap: CGFloat = 6

    private let range: ClosedRange<Int>

    override var isFlipped: Bool { true }

    private func limit(at position: Double) -> Int {
        range.lowerBound + Int((position * Double(range.upperBound - range.lowerBound)).rounded())
    }

    init(frame: NSRect, charge: BatteryMenuModel.ChargeLimit) {
        range = charge.range
        super.init(frame: frame)
        let drain = PillButton(title: charge.hardDrainRunning ? "Hard Drain" : "Drain", running: charge.softDrainRunning || charge.hardDrainRunning,
                               holdable: true)
        drain.toolTip = "Soft Drain to Limit. Hold for three seconds for Hard Drain."
        drain.onPress = { [weak self] in self?.onPressDrain?() }
        drain.onHold = { [weak self] in self?.onHoldDrain?() }
        let topUp = PillButton(title: "Top Up", running: charge.topUpRunning, holdable: false)
        topUp.isEnabled = charge.canTopUp
        topUp.toolTip = charge.topUpRunning ? "Charging to 100% this once. Press to cancel."
            : charge.canTopUp ? ChargeControlFeature.fullChargeTip : ChargeControlFeature.fullChargeBlockedTip
        topUp.onPress = { [weak self] in self?.onPressTopUp?() }
        // From the right: Drain, Top Up, then the slider takes the rest.
        let y = (frame.height - PillButton.height) / 2
        drain.frame.origin = NSPoint(x: frame.width - drain.frame.width, y: y)
        topUp.frame.origin = NSPoint(x: drain.frame.minX - Self.buttonGap - topUp.frame.width, y: y)

        let slider = MenuSlider(frame: NSRect(x: 0, y: 4, width: topUp.frame.minX - Self.sliderGap, height: 24))   // room round the knob for its shadow
        slider.compact = true
        slider.value = Double(charge.limit - range.lowerBound) / Double(range.upperBound - range.lowerBound)
        slider.onChange = { [weak self] v in
            guard let self else { return }
            self.onDrag?(self.limit(at: v))
        }
        slider.onEnd = { [weak self] v in
            guard let self else { return }
            self.onCommit?(self.limit(at: v))
        }
        addSubview(slider)
        addSubview(topUp)
        addSubview(drain)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// A small capsule button with its name inside. Grey while idle, blue with the name in white while what it starts is running, and
/// dim when there is nothing for it to do. Pressing dims it as macOS's rows dim. `holdable` ones tell a press from a hold of three
/// seconds (`HoldPress`); the others act on the let go.
final class PillButton: NSView {

    static let height: CGFloat = 26
    static let padding: CGFloat = 11
    static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    /// Three seconds held.
    static let holdSeconds: TimeInterval = 3

    var onPress: (() -> Void)? { didSet { hold.onPress = onPress } }
    var onHold: (() -> Void)? { didSet { hold.onHold = onHold } }
    var isEnabled = true { didSet { subviews.forEach { $0.alphaValue = isEnabled ? 1 : 0.4 } } }

    static func width(for title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: font]).width) + 2 * padding
    }

    private let holdable: Bool
    private let hold = HoldPress(seconds: PillButton.holdSeconds) { after, run in
        let item = DispatchWorkItem(block: run)
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: item)
        return { item.cancel() }
    }

    init(title: String, running: Bool, holdable: Bool) {
        self.holdable = holdable
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width(for: title), height: Self.height))
        let badge = BadgeView(frame: bounds, fill: running ? NSColor.systemBlue : SoundText.ink(dark: 0.16, light: 0.08))
        let text = NSTextField(labelWithString: title)
        text.font = Self.font
        text.textColor = running ? .white : SoundText.primary
        text.alignment = .center
        text.sizeToFit()
        text.frame = NSRect(x: 0, y: (bounds.height - text.frame.height) / 2, width: bounds.width, height: text.frame.height)
        badge.addSubview(text)
        addSubview(badge)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        subviews.forEach { $0.alphaValue = HoverRow.pressedAlpha }
        if holdable { hold.pressDown() }
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        subviews.forEach { $0.alphaValue = 1 }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if holdable { hold.release(inside: inside) } else if inside { onPress?() }
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { hold.abandon() }   // the menu went away mid-press: nothing fires
        super.viewWillMove(toSuperview: newSuperview)
    }
}

/// One Energy Mode: a round badge with a battery in it (blue while it is the one in force), and its name. When the mode in force
/// changes the badge's colour does not jump: the blue fades in over the grey (the grey back in, for the mode that was left) on a
/// critically damped spring, as macOS's does (`BatteryMenuMotion`). It is a Core Animation spring, so it goes on running smoothly while
/// the main thread is held up by the call into macOS's panel that makes the change.
final class ModeRow: HoverRow {

    private let badge: BadgeView
    private let blue = CALayer()
    private let greyGlyph: NSImageView
    private let whiteGlyph: NSImageView
    private var selected: Bool

    init(frame: NSRect, mode: BatteryMenuModel.EnergyMode) {
        selected = mode.isSelected
        badge = BadgeView(frame: NSRect(x: BatteryRow.lead, y: 3, width: 26, height: 26),
                          fill: SoundText.ink(dark: 0.16, light: 0.08))
        func glyphView(_ tint: NSColor) -> NSImageView {
            let v = NSImageView(frame: NSRect(x: 0, y: 0, width: 26, height: 26).offsetBy(dx: 0, dy: -1))
            v.image = BatteryGlyphs.image(for: mode.id, pointSize: 13)
            v.imageScaling = .scaleNone
            v.imageAlignment = .alignCenter
            v.contentTintColor = tint
            v.wantsLayer = true
            return v
        }
        greyGlyph = glyphView(SoundText.ink(0.42))
        whiteGlyph = glyphView(.white)
        super.init(frame: frame)
        cornerRadius = 10
        dimsWhenPressed = true
        badge.addSubview(greyGlyph)
        // The blue badge lies over the grey one, and the white glyph over the grey glyph; each fades in as the mode is chosen.
        let blueView = NSView(frame: badge.bounds)
        blueView.wantsLayer = true
        blueView.layer?.cornerRadius = 13
        blueView.layer?.backgroundColor = NSColor.systemBlue.cgColor
        badge.addSubview(blueView)
        badge.addSubview(whiteGlyph)
        blueLayer = blueView.layer
        addSubview(badge)
        setOpacity(mode.isSelected ? 1 : 0)
        let name = NSTextField(labelWithString: mode.title)
        name.font = .systemFont(ofSize: 13)
        name.textColor = SoundText.primary
        name.lineBreakMode = .byTruncatingTail
        name.frame = NSRect(x: BatteryRow.lead + 32, y: 8, width: 240, height: 18)
        addSubview(name)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var blueLayer: CALayer?

    /// The layers that turn, each with the opacity it has when the mode is in force (the grey glyph goes as the white comes).
    private func turning() -> [(CALayer, Bool)] {
        [blueLayer.map { ($0, true) }, whiteGlyph.layer.map { ($0, true) }, greyGlyph.layer.map { ($0, false) }].compactMap { $0 }
    }

    private func setOpacity(_ value: Float) {
        for (l, up) in turning() { l.removeAnimation(forKey: "turn"); l.opacity = up ? value : 1 - value }
    }

    /// The mode in force changed: the badge turns to its new look (or at once, when `animated` is false).
    func setSelected(_ on: Bool, animated: Bool) {
        guard on != selected else { return }
        selected = on
        let target: Float = on ? 1 : 0
        guard animated, window != nil else { setOpacity(target); return }
        for (layer, up) in turning() {
            let target = up ? target : 1 - target
            // From wherever it is on the screen now, so a second choice mid-turn carries on from there.
            let from = layer.presentation()?.opacity ?? layer.opacity
            let spring = CASpringAnimation(keyPath: "opacity")
            spring.mass = 1
            spring.stiffness = CGFloat(BatteryMenuMotion.badgeOmega * BatteryMenuMotion.badgeOmega)
            spring.damping = CGFloat(2 * BatteryMenuMotion.badgeOmega)   // critically damped: no overshoot
            spring.initialVelocity = 0
            spring.fromValue = from
            spring.toValue = target
            spring.duration = BatteryMenuMotion.badgeSettleSeconds
            layer.opacity = target
            layer.add(spring, forKey: "turn")
        }
    }

    /// How blue the badge is now, 0 to 1, as it is on the screen (what the animation has got to).
    var blueness: Float { blueLayer?.presentation()?.opacity ?? blueLayer?.opacity ?? 0 }
}

/// "Battery Settings…".
final class FooterRow: HoverRow {
    init(frame: NSRect, title: String) {
        super.init(frame: frame)
        cornerRadius = 10
        dimsWhenPressed = true
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 13)
        l.textColor = SoundText.primary
        // A text field draws its text 2 pt in from its frame.
        l.frame = NSRect(x: BatteryRow.lead - 2, y: 2 + 1, width: frame.width, height: 18)
        addSubview(l)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// An app listed under "Using Significant Energy": its icon and its name, and on the right Anode's figures for it.
final class EnergyAppRow: HoverRow {

    private let name = NSTextField(labelWithString: "")
    private let figures = NSTextField(labelWithString: "")

    init(frame: NSRect, name appName: String, stats: EnergyStats? = nil) {
        super.init(frame: frame)
        cornerRadius = 10
        dimsWhenPressed = true
        highlightable = true   // lit under the pointer; what pressing it does is not measured yet
        let icon = NSImageView(frame: NSRect(x: BatteryRow.lead - 1, y: 2, width: 18, height: 18))
        icon.image = Self.icon(forAppNamed: appName)
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        name.stringValue = appName
        name.font = .systemFont(ofSize: 13)
        name.textColor = SoundText.primary
        name.lineBreakMode = .byTruncatingTail
        addSubview(name)
        figures.font = .systemFont(ofSize: 11)
        figures.textColor = BatteryMenuContentView.secondary
        figures.alignment = .right
        addSubview(figures)
        update(stats: stats)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Anode's figures for the app, on the right of the row, as dim as the power source line; the name gives way to them. Changed in
    /// place when a measurement comes in, so that nothing else of the menu is drawn again.
    func update(stats: EnergyStats?) {
        var nameWidth: CGFloat = 250
        if let stats {
            figures.stringValue = stats.rowText
            figures.sizeToFit()
            // A text field draws its text 2 pt in from its frame.
            let width = ceil(figures.frame.width)
            figures.frame = NSRect(x: frame.width - BatteryRow.lead - width + 2, y: 4, width: width, height: figures.frame.height)
            figures.isHidden = false
            nameWidth = frame.width - BatteryRow.lead - width - (BatteryRow.lead + 22) - 8
            toolTip = stats.tooltip
        } else {
            figures.isHidden = true
            toolTip = nil
        }
        name.frame = NSRect(x: BatteryRow.lead + 22, y: 3, width: nameWidth, height: 18)
    }

    /// The icon of the running app with this name, else the generic application icon.
    private static func icon(forAppNamed name: String) -> NSImage? {
        // macOS names an app as its bundle does ("Visual Studio Code"); the running app's own name can be shorter ("Code"), so the
        // bundle's name and its file's name count too.
        let running = NSWorkspace.shared.runningApplications.first { app in
            if app.localizedName == name { return true }
            guard let url = app.bundleURL else { return false }
            let info = Bundle(url: url)?.infoDictionary
            return url.deletingPathExtension().lastPathComponent == name || info?["CFBundleDisplayName"] as? String == name
                || info?["CFBundleName"] as? String == name
        }
        return running?.icon ?? NSImage(named: NSImage.applicationIconName)
    }
}

/// How the app builds the Battery menu. Nothing of it runs until its setting is on (Beta Features).
enum BatteryMenuRuntime {

    /// The menu over the real Mac. `driver` is shared with the Sound menu: both use macOS's Control Center one job at a time.
    static func live(settings: Settings = .shared, driver: SystemPanelDriving = SystemPanelDriver(),
                     openBetaFeatures: @escaping () -> Void = {}, ultra: UltraModeControlling? = nil, charge: ChargeLimiting? = nil,
                     energyApps: @escaping () -> [SignificantEnergy.Candidate] = { [] }, onOpenChanged: @escaping (Bool) -> Void = { _ in }) -> BatteryMenuController {
        let panel = BatteryMenuPanel()
        let controller = BatteryMenuController(settings: settings, driver: driver, accessibility: { AXIsProcessTrusted() },
                                               presenter: panel, native: NativeMenuExtraIcon.battery(),
                                               openBetaFeatures: openBetaFeatures, ultra: ultra, charge: charge,
                                               hardDrainPrompt: HardDrainAlert(), energyApps: energyApps,
                                               onOpenChanged: onOpenChanged, statsInterval: 2)
        panel.controller = controller
        controller.start()
        return controller
    }
}

import AppKit
import PowerKit

// ── Anode's Battery menu, drawn ─────────────────────────────────────────────
//
// The same glass and the same row looks as the Sound menu (macOS's two panels share them), laid out by `BatteryMenuLayout`
// from the numbers measured on macOS's own Battery panel. The panel is a window of its own that never takes focus, opens where
// macOS's would (right edge 10.5 pt past the icon's, 1 pt under the bar) and closes on a click anywhere else or on Esc.

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
        case "high": return highPower(outline: symbol("battery.0percent"))
        default: return symbol("battery.100percent")
        }
    }

    /// The outline of an empty battery, half as strong as the rest, with three solid triangles pointing right inside it (measured on
    /// macOS's badge, as fractions of the whole symbol: the triangles start 0.143 in from the left and end 0.74, each 0.18 wide,
    /// half the height of the symbol and a little below its middle).
    private static func highPower(outline: NSImage?) -> NSImage? {
        guard let outline, let bounds = opaqueBounds(of: outline) else { return nil }
        let image = NSImage(size: outline.size, flipped: false) { rect in
            outline.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.5)
            NSColor.black.setFill()
            let h = bounds.height * 0.47
            let midY = bounds.midY - bounds.height * 0.05
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

    override func close() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        orderOut(nil)
    }

    /// A click anywhere else closes the menu; a click on the icon is the icon's own toggle.
    private func closeUnlessOnItem() {
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first else { return }
        let top = CGPoint(x: p.x, y: screen.frame.height - p.y)
        if !anchor.contains(top) && !frame.contains(p) { controller?.closeMenu() }
    }

    /// Right edge a little past the icon's, top just under the menu bar, like macOS's.
    private func place() {
        guard let screen = NSScreen.screens.first else { return }
        let size = content.fittingSize
        let bar = max(NSStatusBar.system.thickness, screen.frame.height - screen.visibleFrame.maxY)
        var x = anchor.maxX + 10.5 - size.width
        x = min(max(8, x), screen.frame.width - size.width - 8)
        setFrame(NSRect(x: x, y: screen.frame.height - bar - BatteryMenuMetrics.gapBelowBar - size.height, width: size.width, height: size.height), display: true)
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

    func apply(_ model: BatteryMenuModel) {
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
        let f = row.frame
        switch row.kind {
        case .title:
            addSubview(label("Battery", f, size: 13, weight: .semibold, color: .labelColor, dy: BatteryMenuMetrics.contentDrop))
        case .powerSource:
            addSubview(label(AppleBatteryPanel.powerSourcePrefix + model.powerSource, f, size: 12, weight: .regular, color: Self.secondary, dy: BatteryMenuMetrics.contentDrop))
        case .divider:
            let d = NSView(frame: f)
            d.wantsLayer = true
            d.layer?.backgroundColor = cg(SoundText.ink(0.15))
            addSubview(d)
        case .heading(let title):
            addSubview(label(title, f, size: 12, weight: .semibold, color: Self.secondary, dy: BatteryMenuMetrics.contentDrop))
        case .mode(let i):
            guard model.modes.indices.contains(i) else { return }
            let mode = model.modes[i]
            let v = ModeRow(frame: f, mode: mode)
            v.onPick = { [weak self] in self?.controller?.pickMode(mode.id) }
            addSubview(v)
        case .app(let i):
            guard model.energyApps.indices.contains(i) else { return }
            addSubview(EnergyAppRow(frame: f, name: model.energyApps[i].name))
        case .footer:
            let b = TextButton(frame: f, title: Self.settingsTitle, textOffset: CGPoint(x: -2, y: 2 + BatteryMenuMetrics.contentDrop)) { [weak self] in self?.controller?.pressSettings() }
            addSubview(b)
        }
    }

    static let settingsTitle = "Battery Settings…"

    /// The dimmer text (the power source, the headings): white at 0.40 over the glass in the dark appearance (measured: 131 on a
    /// 55 backdrop, where the system's secondary label colour gave 161).
    static let secondary = SoundText.ink(dark: 0.40, light: 0.5)

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

/// One Energy Mode: a round badge with a battery in it (blue while it is the one in force), and its name.
final class ModeRow: HoverRow {
    init(frame: NSRect, mode: BatteryMenuModel.EnergyMode) {
        super.init(frame: frame)
        let badge = BadgeView(frame: NSRect(x: 0, y: 3 + BatteryMenuMetrics.contentDrop, width: 26, height: 26),
                              fill: mode.isSelected ? NSColor.systemBlue : SoundText.ink(dark: 0.16, light: 0.07))
        // Centred in the badge at its own size (macOS's glyph is about 19 by 9 pt).
        let glyph = NSImageView(frame: badge.bounds)
        glyph.image = BatteryGlyphs.image(for: mode.id, pointSize: 14.8)
        glyph.imageScaling = .scaleNone
        glyph.imageAlignment = .alignCenter
        glyph.contentTintColor = mode.isSelected ? .white : SoundText.ink(0.42)
        badge.addSubview(glyph)
        addSubview(badge)
        let name = NSTextField(labelWithString: mode.title)
        name.font = .systemFont(ofSize: 13)
        name.textColor = SoundText.primary
        name.lineBreakMode = .byTruncatingTail
        name.frame = NSRect(x: 32, y: 8 + BatteryMenuMetrics.contentDrop, width: 240, height: 18)
        addSubview(name)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// An app listed under "Using Significant Energy": its icon and its name.
final class EnergyAppRow: HoverRow {
    init(frame: NSRect, name: String) {
        super.init(frame: frame)
        highlightable = false   // what pressing it does is not measured yet
        let icon = NSImageView(frame: NSRect(x: 0, y: 2 + BatteryMenuMetrics.contentDrop, width: 18, height: 18))
        icon.image = Self.icon(forAppNamed: name)
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        let l = NSTextField(labelWithString: name)
        l.font = .systemFont(ofSize: 13)
        l.textColor = SoundText.primary
        l.lineBreakMode = .byTruncatingTail
        l.frame = NSRect(x: 22, y: 3 + BatteryMenuMetrics.contentDrop, width: 250, height: 18)
        addSubview(l)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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
    static func live(settings: Settings = .shared, driver: SystemPanelDriving = SystemPanelDriver()) -> BatteryMenuController {
        let panel = BatteryMenuPanel()
        let controller = BatteryMenuController(settings: settings, driver: driver, accessibility: { AXIsProcessTrusted() },
                                               presenter: panel, native: NativeMenuExtraIcon.battery())
        panel.controller = controller
        controller.start()
        return controller
    }
}

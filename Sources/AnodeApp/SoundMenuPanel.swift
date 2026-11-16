import AppKit
import PowerKit

// ── Anode's Sound menu: what it looks like ──────────────────────────────────
//
// A copy of macOS 27's Sound menu, drawn from `SoundMenuLayout` (where everything goes) and `SoundMenuMetrics` (how big).
// The look is matched by overlaying a capture of this panel on one of macOS's own and changing what differs; the glyphs
// named here are the closest SF Symbols until that is done, and each is a one-line change.

/// The menu bar icon: a plain `NSStatusItem` showing an SF Symbol.
final class SystemStatusItemHandle: NSObject, StatusItemHandle {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    var onClick: (() -> Void)?

    var symbolName: String = "" {
        didSet {
            guard symbolName != oldValue else { return }
            item.button?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Sound")
        }
    }

    override init() {
        super.init()
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.setAccessibilityLabel("Sound (Anode)")
        item.autosaveName = "dev.anode.soundMenu"
    }

    @objc private func clicked() { onClick?() }

    /// Top-left global points.
    var frame: CGRect {
        guard let window = item.button?.window, let screen = NSScreen.screens.first else { return .zero }
        let f = window.frame
        return CGRect(x: f.minX, y: screen.frame.height - f.maxY, width: f.width, height: f.height)
    }

    func remove() { NSStatusBar.system.removeStatusItem(item) }
}

final class SystemStatusBarHost: StatusItemHosting {
    func makeItem() -> StatusItemHandle { SystemStatusItemHandle() }
}

/// The glyph for a kind of output.
enum SoundGlyphs {
    static func output(_ kind: OutputKind) -> String {
        switch kind {
        case .speakers: return "laptopcomputer"
        case .airpodsPro: return "airpods.pro"
        case .airpods: return "airpods"
        case .headphones: return "headphones"
        case .hifi: return "hifispeaker.fill"
        case .display: return "tv.and.mediabox"
        case .airplay, .other: return "airplayaudio"
        }
    }

    static func choice(_ title: String) -> String {
        switch title {
        case "Transparency": return "person.wave.2.fill"
        case "Adaptive": return "person.fill.badge.plus"
        case "Noise Cancellation": return "person.crop.circle.fill"
        case "Not Available", "On", "Off": return "person.line.dotted.person.fill"
        default: return "circle"
        }
    }
}

private func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
}

/// The panel that holds the menu. It does not take focus from the app in front.
final class SoundMenuPanel: NSPanel, SoundMenuPresenting {

    weak var controller: SoundMenuController? { didSet { content.controller = controller } }

    private let content = SoundMenuContentView()
    private var monitors: [Any] = []
    private var anchor = CGRect.zero

    var isOpen: Bool { isVisible }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = content
        setAccessibilityIdentifier("dev.anode.soundMenu")
    }

    override var canBecomeKey: Bool { true }

    func show(_ model: SoundMenuModel, below frame: CGRect) {
        anchor = frame
        content.apply(model)
        place()
        orderFrontRegardless()
        makeKey()
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.closeUnlessOnItem()
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { self?.close(); return nil }   // Esc
            return event
        } as Any)
    }

    func update(_ model: SoundMenuModel) {
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
        if !anchor.contains(top) && !frame.contains(p) { close() }
    }

    /// Right edge a little past the icon's, top just under the menu bar, like macOS's.
    private func place() {
        guard let screen = NSScreen.screens.first else { return }
        let size = content.fittingSize
        let bar = NSStatusBar.system.thickness
        var x = anchor.maxX + 10.5 - size.width
        x = min(max(8, x), screen.frame.width - size.width - 8)
        setFrame(NSRect(x: x, y: screen.frame.height - bar - 2 - size.height, width: size.width, height: size.height), display: true)
    }
}

// ── The drawing ─────────────────────────────────────────────────────────────

final class SoundMenuContentView: NSView {

    weak var controller: SoundMenuController?
    private var model: SoundMenuModel?
    private var size = NSSize(width: SoundMenuMetrics.width, height: 100)
    private let material = NSVisualEffectView()

    override var isFlipped: Bool { true }
    override var fittingSize: NSSize { size }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        material.material = .menu
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 18
        material.layer?.masksToBounds = true
        addSubview(material)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ model: SoundMenuModel) {
        self.model = model
        for v in subviews where v !== material { v.removeFromSuperview() }
        let layout = SoundMenuLayout.frames(for: model)
        size = NSSize(width: SoundMenuMetrics.width, height: layout.height)
        frame.size = size
        material.frame = bounds
        for row in layout.rows { add(row, model) }
        invalidateIntrinsicContentSize()
    }

    private func add(_ row: SoundMenuLayout.LaidOutRow, _ model: SoundMenuModel) {
        let f = row.frame
        switch row.kind {
        case .title:
            addSubview(label("Sound", f, size: 14, weight: .bold, color: .labelColor))
        case .volumeSlider:
            let slider = MenuSlider(frame: f)
            slider.value = model.muted ? 0 : model.volume
            slider.onChange = { [weak self] v in self?.controller?.setVolume(v) }
            addSubview(slider)
            let down = IconButton(symbol: "speaker.fill", frame: NSRect(x: 12, y: f.minY - 1, width: 18, height: 18)) { [weak self] in
                guard let self, let m = self.model else { return }
                self.controller?.setVolume(max(0, m.volume - 1 / 16))
            }
            let up = IconButton(symbol: "speaker.wave.3.fill", frame: NSRect(x: f.maxX + 6, y: f.minY - 1, width: 26, height: 18)) { [weak self] in
                guard let self, let m = self.model else { return }
                self.controller?.setVolume(min(1, m.volume + 1 / 16))
            }
            addSubview(down); addSubview(up)
        case .divider:
            let d = NSView(frame: f)
            d.wantsLayer = true
            d.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
            addSubview(d)
        case .heading(let title):
            addSubview(label(title, f, size: 13, weight: .semibold, color: .secondaryLabelColor))
        case .block:
            let b = NSView(frame: f)
            b.wantsLayer = true
            b.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.075).cgColor
            addSubview(b, positioned: .above, relativeTo: material)
        case .device(let i):
            guard model.devices.indices.contains(i) else { return }
            let d = model.devices[i]
            let rowView = DeviceRow(frame: f, device: d, expanded: d.name == model.expandedDevice,
                                    expandable: !(model.listening.isEmpty && model.spatial.isEmpty && model.conversation.isEmpty && d.name != model.expandedDevice) && (d.kind == .airpods || d.kind == .airpodsPro))
            rowView.onPick = { [weak self] in self?.controller?.pickOutput(d) }
            rowView.onToggle = { [weak self] in self?.controller?.toggleExpanded(d.name) }
            addSubview(rowView)
        case .choice(let section, let index):
            let rows = rows(of: section, in: model)
            guard rows.indices.contains(index) else { return }
            let c = rows[index]
            let v = ChoiceRow(frame: f, choice: c)
            v.onPick = { [weak self] in self?.controller?.pickChoice(c) }
            addSubview(v)
        case .notice:
            addSubview(label(model.notice ?? "", f, size: 12, weight: .regular, color: .systemOrange, wraps: true))
        case .footer(let i):
            let titles = model.footerTitles
            guard titles.indices.contains(i) else { return }
            let b = TextButton(frame: f, title: titles[i]) { [weak self] in self?.controller?.pressSettings(i) }
            addSubview(b)
        }
    }

    private func rows(of section: String, in model: SoundMenuModel) -> [AppleChoiceRow] {
        switch section {
        case AppleSoundPanel.listeningHeading: return model.listening
        case AppleSoundPanel.spatialHeading: return model.spatial
        default: return model.conversation
        }
    }

    private func label(_ text: String, _ frame: CGRect, size: CGFloat, weight: NSFont.Weight, color: NSColor, wraps: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.frame = frame
        l.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        l.maximumNumberOfLines = wraps ? 2 : 1
        return l
    }
}

/// A row that lights up under the pointer and reports a click.
class HoverRow: NSView {
    var onPick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    var highlightable = true

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = highlightable }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) { if highlightable, bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?() } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        NSColor.white.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}

final class DeviceRow: HoverRow {
    var onToggle: (() -> Void)?
    private let expanded: Bool

    init(frame: NSRect, device: SoundMenuModel.Device, expanded: Bool, expandable: Bool) {
        self.expanded = expanded
        super.init(frame: frame)
        let circle = NSView(frame: NSRect(x: 9, y: 3, width: 26, height: 26))
        circle.wantsLayer = true
        circle.layer?.cornerRadius = 13
        circle.layer?.backgroundColor = (device.isSelected ? NSColor.systemBlue : NSColor.white.withAlphaComponent(0.16)).cgColor
        let glyph = NSImageView(frame: NSRect(x: 4, y: 4, width: 18, height: 18))
        glyph.image = symbol(SoundGlyphs.output(device.kind), size: 13, weight: .medium)
        glyph.contentTintColor = device.isSelected ? .white : NSColor.white.withAlphaComponent(0.55)
        circle.addSubview(glyph)
        addSubview(circle)

        let name = NSTextField(labelWithString: device.name)
        name.font = .systemFont(ofSize: 15)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        let hasBattery = device.battery != nil
        name.frame = NSRect(x: 43, y: hasBattery ? 1 : 6, width: 220, height: 18)
        addSubview(name)
        if let b = device.battery {
            let text = [b.left.map { "\($0)%" }, b.right.map { "\($0)%" }, b.case_.map { "\($0)%" }].compactMap { $0 }.joined(separator: "   ")
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: 12)
            l.textColor = .secondaryLabelColor
            l.frame = NSRect(x: 43, y: 17, width: 220, height: 14)
            addSubview(l)
        }
        if expandable {
            let chev = IconButton(symbol: expanded ? "chevron.up" : "chevron.down", frame: NSRect(x: 268, y: 3, width: 26, height: 26)) { [weak self] in self?.onToggle?() }
            addSubview(chev)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

final class ChoiceRow: HoverRow {
    init(frame: NSRect, choice: AppleChoiceRow) {
        super.init(frame: frame)
        highlightable = choice.enabled
        if choice.isOn {
            let check = NSImageView(frame: NSRect(x: 9, y: 4, width: 18, height: 18))
            check.image = symbol("checkmark", size: 13, weight: .semibold)
            check.contentTintColor = .labelColor
            addSubview(check)
        }
        let glyph = NSImageView(frame: NSRect(x: 36, y: 3, width: 20, height: 20))
        glyph.image = symbol(SoundGlyphs.choice(choice.title), size: 14)
        glyph.contentTintColor = choice.enabled ? NSColor.white.withAlphaComponent(0.6) : NSColor.white.withAlphaComponent(0.25)
        addSubview(glyph)
        let l = NSTextField(labelWithString: choice.title)
        l.font = .systemFont(ofSize: 15)
        l.textColor = choice.enabled ? .labelColor : NSColor.white.withAlphaComponent(0.3)
        l.frame = NSRect(x: 63, y: 4, width: 220, height: 18)
        addSubview(l)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

final class TextButton: HoverRow {
    init(frame: NSRect, title: String, action: @escaping () -> Void) {
        super.init(frame: frame)
        onPick = action
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 15)
        l.textColor = .labelColor
        l.frame = NSRect(x: 0, y: 1, width: frame.width, height: 18)
        addSubview(l)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

final class IconButton: NSView {
    private let action: () -> Void

    init(symbol name: String, frame: NSRect, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: frame)
        let v = NSImageView(frame: bounds)
        v.image = symbol(name, size: 12, weight: .semibold)
        v.contentTintColor = NSColor.white.withAlphaComponent(0.6)
        v.imageScaling = .scaleProportionallyDown
        addSubview(v)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override func mouseDown(with event: NSEvent) { action() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The volume slider: a rounded track filled up to a round handle.
final class MenuSlider: NSView {
    var value: Double = 0 { didSet { needsDisplay = true } }
    var onChange: ((Double) -> Void)?
    private static let thumb: CGFloat = 20

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: bounds.midY - 3, width: bounds.width, height: 6)
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        let x = CGFloat(value) * (bounds.width - Self.thumb)
        var filled = track; filled.size.width = x + Self.thumb / 2
        NSColor.white.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: filled, xRadius: 3, yRadius: 3).fill()
        NSColor(white: 0.87, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: bounds.midY - Self.thumb / 2, width: Self.thumb, height: Self.thumb)).fill()
    }

    override func mouseDown(with event: NSEvent) { move(to: event) }
    override func mouseDragged(with event: NSEvent) { move(to: event) }

    private func move(to event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        value = min(1, max(0, Double((x - Self.thumb / 2) / (bounds.width - Self.thumb))))
        onChange?(value)
    }
}

/// How the app builds the Sound menu. Nothing of it runs until its setting is on (Beta Features).
enum SoundMenuRuntime {

    /// The menu over the real Mac.
    static func live(settings: Settings = .shared) -> SoundMenuController {
        make(settings: settings, outputs: CoreAudioOutputs(), driver: SystemPanelDriver(), statusBar: SystemStatusBarHost(),
             panel: SoundMenuPanel())
    }

    static func make(settings: Settings, outputs: AudioOutputs, driver: SystemPanelDriving, statusBar: StatusItemHosting,
                     panel: SoundMenuPanel) -> SoundMenuController {
        let controller = SoundMenuController(settings: settings, outputs: outputs, driver: driver,
                                             batteries: currentAccessoryBatteries, accessibility: { AXIsProcessTrusted() },
                                             statusBar: statusBar, presenter: panel)
        panel.controller = controller
        controller.start()
        return controller
    }
}

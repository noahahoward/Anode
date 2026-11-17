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

/// The text colour of the rows: macOS's is a little brighter than the system label colour on its dark glass (measured).
enum SoundText {
    /// Whether the system is in the dark appearance. The added ("plus lighter") drawing is macOS's look on dark glass only.
    static var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    /// White at `alpha` on dark glass, black at `alpha` on light glass: the low-contrast fills and tints are drawn this way so they
    /// stay visible in either appearance. (Measured against macOS's own panel in the dark appearance only.)
    static func ink(_ alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.white.withAlphaComponent(alpha) : NSColor.black.withAlphaComponent(alpha)
        }
    }

    static let primary = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.white.withAlphaComponent(0.885) : NSColor.labelColor
    }
}

/// The glyph for a kind of output.
enum SoundGlyphs {
    static func output(_ kind: OutputKind) -> String {
        switch kind {
        case .speakers: return "laptopcomputer"
        case .airpodsPro: return "airpods.pro"
        case .airpods: return "airpods"
        case .airpodsMax: return "airpods.max"
        case .headphones: return "headphones"
        case .hifi: return "hifispeaker.fill"
        case .display: return "tv.and.mediabox"
        case .airplay: return "airplayaudio"
        case .other: return "hifispeaker.fill"
        }
    }

    static func choice(_ title: String) -> String {
        switch title {
        case "Transparency": return "person.and.background.dotted"
        case "Adaptive": return "person.fill.badge.plus"
        case "Noise Cancellation": return "person.crop.circle.fill"
        case "Not Available": return "person.spatialaudio.fill"
        case "On", "Off": return "person.wave.2.fill"
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

    /// Two above macOS's own menus (101): its Sound panel opens for a moment where this one is about to be, and a still picture of
    /// that place (one level up from macOS's) hides it; this menu is above both.
    static let level = Int(NSWindow.Level.popUpMenu.rawValue) + 2

    private let content = SoundMenuContentView()
    private var monitors: [Any] = []
    private let volumeKeys = MediaKeyTap()
    private var anchor = CGRect.zero

    var isOpen: Bool { isVisible }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // One above macOS's own menus: its Sound panel opens for a moment, off the screen but drawn first where it would be, behind this.
        level = NSWindow.Level(rawValue: Self.level)
        isReleasedWhenClosed = false
        animationBehavior = .none   // macOS's own menu appears at once, without the window zoom
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = content
        setAccessibilityIdentifier("dev.anode.soundMenu")
    }

    /// Never key and never main. A key window that is ordered out hands "key" to another window of the same app and brings
    /// it forward: the ledger came up behind the menu each time it closed. Esc is heard by a global monitor instead.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private var glideTimer: Timer?
    private var glideStart: CFTimeInterval = 0

    func show(_ model: SoundMenuModel, below frame: CGRect) {
        anchor = frame
        stopGlide()
        content.apply(model)
        place()
        orderFrontRegardless()
        // The volume keys go to the menu while it is open, so macOS does not draw its own bubble beside it.
        volumeKeys.start { [weak self] key in self?.controller?.volumeKey(key.key) }
        // A click anywhere else closes the menu.
        if let click = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            self?.closeUnlessOnItem()
        }) { monitors.append(click) }
        // Esc closes it, as it does macOS's own. The menu is never the key window (see `canBecomeKey`), so keys do not come to it;
        // this listens for the key only while the menu is open, reads nothing but the key code (never the characters typed) and
        // keeps nothing. Without Accessibility macOS delivers no keys to it and Esc simply does nothing.
        if let esc = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            if event.keyCode == 53 { self?.close() }
        }) { monitors.append(esc) }
    }

    func update(_ model: SoundMenuModel) {
        guard isVisible else { return }
        if content.apply(model, animated: true) {
            startGlide()
        } else {
            place()
        }
    }

    /// The menu drew something it had been holding back (a drag ended): fit the window to it.
    func contentChanged() { place(); invalidateShadow() }

    /// The bottom edge, and the rows under what changed, glide to their new places as macOS's do (see `SoundMenuMotion`).
    private func startGlide() {
        glideTimer?.invalidate()
        glideStart = CACurrentMediaTime()
        place()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.glideTick() }
        RunLoop.main.add(timer, forMode: .common)
        glideTimer = timer
    }

    private func glideTick() {
        let t = CACurrentMediaTime() - glideStart
        if t >= SoundMenuMotion.settleSeconds { stopGlide(); place(); return }
        content.step(CGFloat(SoundMenuMotion.progress(at: t)))
        place()
        invalidateShadow()
    }

    private func stopGlide() {
        guard glideTimer != nil || content.isGliding else { return }
        glideTimer?.invalidate(); glideTimer = nil
        content.finishGlide()
    }

    /// Closes at once. (macOS's fades out in about 70 ms, but its glass cannot be faded from outside: it drops out as soon as the
    /// window or anything above it is translucent, so a fade here would show the text alone for a moment, which is worse.)
    override func close() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        volumeKeys.stop()
        stopGlide()
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
        let bar = max(NSStatusBar.system.thickness, screen.frame.height - screen.visibleFrame.maxY)
        var x = anchor.maxX + 10.5 - size.width
        x = min(max(8, x), screen.frame.width - size.width - 8)
        setFrame(NSRect(x: x, y: screen.frame.height - bar - 2 - size.height, width: size.width, height: size.height), display: true)
        // The shadow follows what is drawn; worked out before the rounded glass had drawn it comes out square at the corners.
        DispatchQueue.main.async { [weak self] in self?.invalidateShadow() }
    }
}

// ── The drawing ─────────────────────────────────────────────────────────────

final class SoundMenuContentView: NSView {

    weak var controller: SoundMenuController?
    private var model: SoundMenuModel?
    private var size = NSSize(width: SoundMenuMetrics.width, height: 100)
    /// macOS 26 and later draw their menus in the system glass; before that, the menu material.
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
    /// macOS's glass measures about 4 levels lighter than the same glass drawn here, on dark and light backdrops alike, so
    /// that much is added over the whole panel (added, as the block lift below is: the difference does not scale).
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
        layer?.masksToBounds = true   // nothing square can show at the corners, and the shadow follows this shape
        addSubview(material)
        if #available(macOS 26.0, *), SoundText.isDark {
            baseLift.wantsLayer = true
            baseLift.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.016).cgColor
            baseLift.layer?.compositingFilter = "plusL"
            addSubview(baseLift)
        }
        edge.wantsLayer = true
        edge.layer?.cornerRadius = 17
        edge.layer?.cornerCurve = .continuous
        edge.layer?.borderWidth = 0.5
        edge.layer?.borderColor = NSColor.white.withAlphaComponent(0.05).cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // ── Gliding between two layouts ─────────────────────────────────────────

    /// One laid-out row and the views drawn for it.
    private struct RowGroup {
        var key: String
        var views: [NSView]
        var finalFrames: [CGRect]
        var finalRow: CGRect
        var fromRow: CGRect?   // where the row was shown before; nil for a row that is new
    }
    private var groups: [RowGroup] = []
    private var shownRows: [String: CGRect] = [:]
    /// What the last drawing made, by row key, so a row that has gone can be kept on screen while the footer slides over it.
    private var shownViews: [String: [NSView]] = [:]
    /// Holds the rows that are appearing or leaving: macOS's footer band (the divider and what is under it) slides over them, so
    /// they are cut off at the footer's top edge as it moves. Nothing in it takes a click of its own.
    private let clip = ClipView()
    private var leaving: [(key: String, views: [NSView], frames: [CGRect])] = []
    /// The app rows now drawn, so a change to one app (mute, a slider) is shown on its row without drawing the whole menu again.
    private(set) var appRows: [String: AppVolumeRowView] = [:]
    /// The volume slider at the top, kept so a change of volume moves its knob without drawing the menu again.
    private(set) var mainSlider: MenuSlider?
    /// A change that came while a slider was being dragged, drawn when the drag ends.
    private var deferred: SoundMenuModel?
    private var dragObserver: NSObjectProtocol?
    private var glide: (fromHeight: CGFloat, toHeight: CGFloat)?
    var isGliding: Bool { glide != nil }

    /// Draws `model`. With `animated`, when the shape changed and something was already shown, nothing jumps: it sets up a glide
    /// (driven by `step`) and returns true; the caller steps it and calls `finishGlide` at the end.
    @discardableResult
    func apply(_ model: SoundMenuModel, animated: Bool = false) -> Bool {
        if dragObserver == nil {
            dragObserver = NotificationCenter.default.addObserver(forName: .menuSliderDragEnded, object: nil, queue: .main) { [weak self] _ in
                guard let self, let pending = self.deferred else { return }
                self.deferred = nil
                self.apply(pending)
                (self.window as? SoundMenuPanel)?.contentChanged()
            }
        }
        // Only the volume or the mute changed: the knob moves (gliding when the mute did it), and nothing is drawn again.
        if let old = self.model, let slider = mainSlider {
            var same = old; same.volume = model.volume; same.muted = model.muted
            if same == model {
                self.model = model
                let position = model.muted ? 0 : model.volume
                if abs(slider.value - position) > 0.0005 {
                    if old.muted != model.muted { slider.glide(to: position) } else { slider.value = position }
                }
                return false
            }
        }
        // Something else changed while a slider is held: it is drawn when the pointer is let go.
        if MenuSlider.activeDrags > 0, let current = self.model {
            var asApps = current; asApps.apps = model.apps
            if asApps != model {
                deferred = model
                return false
            }
        }
        // Only the apps changed (and they are the same apps): show it on their rows, where a slider can glide.
        if let old = self.model, !model.apps.isEmpty, old.apps.map(\.bundleID) == model.apps.map(\.bundleID) {
            var same = old; same.apps = model.apps
            if same == model, model.apps.allSatisfy({ appRows[$0.bundleID] != nil }) {
                self.model = model
                for app in model.apps { appRows[app.bundleID]?.update(app, animated: true) }
                return false
            }
        }
        self.model = model
        appRows = [:]
        mainSlider = nil
        let oldHeight = size.height
        let before = shownRows
        let beforeViews = shownViews
        finishLeaving()
        clip.subviews.forEach { $0.removeFromSuperview() }
        for v in subviews where v !== material && v !== baseLift { v.removeFromSuperview() }   // the edge is added again at the end
        let layout = SoundMenuLayout.frames(for: model)
        size = NSSize(width: SoundMenuMetrics.width, height: layout.height)
        frame.size = size
        material.frame = bounds
        baseLift.frame = bounds
        edge.frame = bounds
        groups = []
        var dividers = 0
        for row in layout.rows {
            let first = subviews.count
            add(row, model)
            let made = Array(subviews[first...])
            var key = Self.key(of: row.kind, model: model)
            if row.kind == .divider { key += "#\(dividers)"; dividers += 1 }
            groups.append(RowGroup(key: key, views: made, finalFrames: made.map(\.frame), finalRow: row.frame, fromRow: before[key]))
        }
        // The footer's own divider is told apart from the others (the one under the last row).
        if let last = groups.lastIndex(where: { $0.key.hasPrefix("divider#") }), last > 0 { groups[last].key = "footerDivider"; groups[last].fromRow = before["footerDivider"] }
        shownRows = Dictionary(groups.map { ($0.key, $0.finalRow) }, uniquingKeysWith: { a, _ in a })
        shownViews = Dictionary(groups.map { ($0.key, $0.views) }, uniquingKeysWith: { a, _ in a })
        // Rows that were there and are not now stay for the glide, cut off by the footer.
        let nowKeys = Set(groups.map(\.key))
        leaving = beforeViews.filter { !nowKeys.contains($0.key) }.map { (key: $0.key, views: $0.value, frames: $0.value.map(\.frame)) }
        addSubview(clip)
        clip.frame = bounds
        addSubview(edge)   // last, so it is drawn over everything
        invalidateIntrinsicContentSize()
        let changed = abs(oldHeight - size.height) > 0.5 || groups.contains { g in g.fromRow.map { $0 != g.finalRow } ?? true }
        guard animated, !before.isEmpty, changed, oldHeight > 0 else { glide = nil; finishLeaving(); return false }
        glide = (oldHeight, size.height)
        // Rows that are new or leaving go under the clip (same coordinates), so the footer's edge cuts them off.
        for g in groups where g.fromRow == nil { for v in g.views { clip.addSubview(v) } }
        for l in leaving { for (v, f) in zip(l.views, l.frames) { v.frame = f; clip.addSubview(v) } }
        step(0)
        return true
    }

    /// What identifies a row from one drawing to the next.
    private static func key(of kind: SoundMenuLayout.RowKind, model: SoundMenuModel) -> String {
        switch kind {
        case .title: return "title"
        case .volumeSlider: return "slider"
        case .divider: return "divider"
        case .heading(let t): return "heading:\(t)"
        case .device(let i): return "device:" + (model.devices.indices.contains(i) ? model.devices[i].name : "\(i)")
        case .choice(let section, let index):
            let rows = section == AppleSoundPanel.listeningHeading ? model.listening
                : section == AppleSoundPanel.spatialHeading ? model.spatial : model.conversation
            return "choice:\(section):" + (rows.indices.contains(index) ? rows[index].title : "\(index)")
        case .app(let i): return "app:" + (model.apps.indices.contains(i) ? model.apps[i].bundleID : "\(i)")
        case .block: return "block"
        case .footer(let i): return "footer:" + (model.footerTitles.indices.contains(i) ? model.footerTitles[i] : "\(i)")
        case .notice: return "notice"
        }
    }

    /// Shows the glide `p` of the way (0 to 1): the height, the rows that were there moving from where they were, new rows fading in.
    func step(_ p: CGFloat) {
        guard let glide else { return }
        let h = glide.fromHeight + (glide.toHeight - glide.fromHeight) * p
        size = NSSize(width: SoundMenuMetrics.width, height: h)
        frame.size = size
        material.frame = bounds; baseLift.frame = bounds; edge.frame = bounds
        for g in groups {
            guard let from = g.fromRow else { continue }   // a new row stands where it will end up; the footer uncovers it
            let r = CGRect(x: from.minX + (g.finalRow.minX - from.minX) * p, y: from.minY + (g.finalRow.minY - from.minY) * p,
                           width: from.width + (g.finalRow.width - from.width) * p, height: from.height + (g.finalRow.height - from.height) * p)
            for (v, f) in zip(g.views, g.finalFrames) {
                if g.key == "block" { v.frame = r } else { v.frame = f.offsetBy(dx: r.minX - g.finalRow.minX, dy: r.minY - g.finalRow.minY) }
            }
        }
        // Where the footer's top edge is now: what is appearing or leaving is drawn only above it.
        if let foot = groups.first(where: { $0.key == "footerDivider" }) {
            let from = foot.fromRow ?? foot.finalRow
            let edgeY = from.minY + (foot.finalRow.minY - from.minY) * p
            clip.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, edgeY))
        } else {
            clip.frame = bounds
        }
    }

    private func finishLeaving() {
        for l in leaving { l.views.forEach { $0.removeFromSuperview() } }
        leaving = []
    }

    /// Puts everything where the last drawing left it.
    func finishGlide() {
        guard glide != nil else { return }
        if var g = glide { g.fromHeight = g.toHeight; glide = g }
        step(1)
        finishLeaving()
        clip.frame = bounds
        glide = nil
        invalidateIntrinsicContentSize()
    }

    private func add(_ row: SoundMenuLayout.LaidOutRow, _ model: SoundMenuModel) {
        let f = row.frame
        switch row.kind {
        case .title:
            addSubview(label("Sound", f, size: 13, weight: .bold, color: .labelColor))
        case .volumeSlider:
            let slider = MenuSlider(frame: f)
            slider.value = model.muted ? 0 : model.volume
            slider.onChange = { [weak self] v in self?.controller?.setVolume(v) }
            mainSlider = slider
            addSubview(slider)
            let down = IconButton(symbol: "speaker.fill", size: 14.5, tint: 0.49, added: true, frame: NSRect(x: 12, y: f.minY - 1, width: 18, height: 18)) { [weak self] in
                guard let self, let m = self.model else { return }
                self.controller?.setVolume(max(0, m.volume - 1 / 16))
            }
            let up = IconButton(symbol: "speaker.wave.3.fill", size: 14, tint: 0.49, added: true, frame: NSRect(x: f.maxX + 4, y: f.minY - 1, width: 28, height: 18)) { [weak self] in
                guard let self, let m = self.model else { return }
                self.controller?.setVolume(min(1, m.volume + 1 / 16))
            }
            addSubview(down); addSubview(up)
        case .divider:
            let d = NSView(frame: f)
            d.wantsLayer = true
            d.layer?.backgroundColor = cg(SoundText.ink(0.15))
            addSubview(d)
        case .heading(let title):
            addSubview(label(title, f, size: 12, weight: .semibold, color: .secondaryLabelColor))
        case .block:
            let b = NSView(frame: f)
            b.wantsLayer = true
            // macOS lifts the block by about 20 levels whatever is behind it, so it is added, not laid over.
            b.layer?.backgroundColor = (SoundText.isDark ? NSColor.white.withAlphaComponent(0.078) : NSColor.black.withAlphaComponent(0.05)).cgColor
            if SoundText.isDark { b.layer?.compositingFilter = "plusL" }
            addSubview(b, positioned: .above, relativeTo: baseLift.superview == nil ? material : baseLift)
        case .device(let i):
            guard model.devices.indices.contains(i) else { return }
            let d = model.devices[i]
            let rowView = DeviceRow(frame: f, device: d, expanded: d.name == model.expandedDevice,
                                    expandable: !(model.listening.isEmpty && model.spatial.isEmpty && model.conversation.isEmpty && d.name != model.expandedDevice) && d.kind.isAirPods)
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
        case .app(let i):
            guard model.apps.indices.contains(i) else { return }
            let app = model.apps[i]
            let v = AppVolumeRowView(frame: f, app: app)
            v.onVolume = { [weak self] value in self?.controller?.setAppVolume(bundleID: app.bundleID, value) }
            v.onToggleMute = { [weak self] in self?.controller?.toggleAppMute(bundleID: app.bundleID) }
            appRows[app.bundleID] = v
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
    /// How much white the hovered row gets.
    var hoverAlpha: CGFloat = 0.09

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
        SoundText.ink(hoverAlpha).setFill()
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
        circle.layer?.backgroundColor = (device.isSelected ? NSColor.systemBlue : SoundText.ink(0.16)).cgColor
        let glyph = NSImageView(frame: NSRect(x: 4, y: 4, width: 18, height: 18))
        glyph.image = symbol(SoundGlyphs.output(device.kind), size: 13, weight: .medium)
        glyph.contentTintColor = device.isSelected ? .white : SoundText.ink(0.55)
        circle.addSubview(glyph)
        addSubview(circle)

        let name = NSTextField(labelWithString: device.name)
        name.font = .systemFont(ofSize: 13)
        name.textColor = SoundText.primary
        name.lineBreakMode = .byTruncatingTail
        let hasBattery = device.battery != nil
        name.frame = NSRect(x: 41, y: hasBattery ? 1.5 : 8.5, width: 220, height: 18)
        addSubview(name)
        if let b = device.battery {
            var x: CGFloat = 41
            // One reading for both buds when they agree, or when macOS lists them as one: the pair of buds drawn together.
            let pair = b.left != nil && (b.right == nil || b.left == b.right)
            // (symbol, point size, drawn width, where the percentage starts): macOS's glyphs are larger than a text-sized one.
            let readings: [(String, CGFloat, CGFloat, CGFloat, CGFloat, Int?)] = device.kind == .airpodsMax
                ? [("airpods.max", 12, 17, 1, 19, b.left ?? b.right)]   // one battery, and no case
                : pair
                ? [("airpods.pro", 12, 17, 2.85, 20.9, b.left), ("airpods.pro.gen3.chargingcase.wireless.fill", 11.5, 14, 0.4, 16.4, b.case_)]
                : [("airpods.pro.left", 11, 8, 2, 12, b.left), ("airpods.pro.right", 11, 8, 2, 12, b.right),
                   ("airpods.pro.gen3.chargingcase.wireless.fill", 11.5, 14, 0.4, 16.4, b.case_)]
            for (glyph, size, width, dx, textAt, level) in readings {
                guard let level else { continue }
                let icon = NSImageView(frame: NSRect(x: x + dx, y: 18.5, width: width, height: 14))
                icon.image = symbol(glyph, size: size)
                icon.imageScaling = .scaleNone
                icon.contentTintColor = SoundText.ink(0.5)
                addSubview(icon)
                let l = NSTextField(labelWithString: "\(level)%")
                l.font = .systemFont(ofSize: 11)
                l.textColor = .secondaryLabelColor
                l.sizeToFit()
                l.frame.origin = NSPoint(x: x + textAt, y: 17.5)
                addSubview(l)
                x += textAt + l.frame.width + 6
            }
        }
        if expandable {
            let chev = IconButton(symbol: "chevron.down", size: 11, weight: .regular, tint: 0.4, frame: NSRect(x: 268, y: 3, width: 26, height: 26)) { [weak self] in self?.onToggle?() }
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
            let check = NSImageView(frame: NSRect(x: 13.35, y: 3.9, width: 18, height: 18))
            check.image = symbol("checkmark", size: 13, weight: .semibold)
            check.contentTintColor = .labelColor
            addSubview(check)
        }
        let glyph = NSImageView(frame: NSRect(x: 42, y: 4, width: 20, height: 20))
        glyph.image = ListeningGlyphs.image(for: choice.title) ?? symbol(SoundGlyphs.choice(choice.title), size: 14)
        glyph.imageScaling = .scaleNone
        if SoundText.isDark { glyph.wantsLayer = true; glyph.layer?.compositingFilter = "plusL" }   // added to what is behind, as macOS's are
        glyph.contentTintColor = NSColor.white.withAlphaComponent(choice.enabled ? 0.30 : 0.16)
        addSubview(glyph)
        let l = NSTextField(labelWithString: choice.title)
        l.font = .systemFont(ofSize: 13)
        l.textColor = choice.enabled ? SoundText.primary : SoundText.ink(0.3)
        l.frame = NSRect(x: 67, y: 5.5, width: 220, height: 18)
        addSubview(l)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

final class TextButton: HoverRow {
    /// macOS's highlight on these rows reaches to 6 pt from the panel's edges (the text stays where it is), is 2 pt taller than
    /// the row, and is brighter than the one on the output rows (all measured).
    init(frame: NSRect, title: String, action: @escaping () -> Void) {
        super.init(frame: frame.insetBy(dx: -6, dy: -1))
        onPick = action
        hoverAlpha = 0.16
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 13)
        l.textColor = SoundText.primary
        l.frame = NSRect(x: 6, y: 2, width: frame.width, height: 18)
        addSubview(l)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The mute button of an app row: the speaker with its level in thirds, like the one in the menu bar, or slashed while muted.
final class MuteButton: NSView {
    private let image = NSImageView()
    var onPress: (() -> Void)?
    init(frame: NSRect, symbol: String, tint: CGFloat) {
        super.init(frame: frame)
        image.frame = bounds
        image.imageScaling = .scaleProportionallyDown
        addSubview(image)
        set(symbol: symbol, tint: tint)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    func set(symbol name: String, tint: CGFloat) {
        image.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        image.contentTintColor = SoundText.ink(tint)
    }
    override func mouseDown(with event: NSEvent) { onPress?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One app of the "Apps" section, on one line as tall as an output row: its icon (hover for its name), a mute button showing the
/// level, a slider from 0 to 100 %, and the percentage. The icon and the sound line share one centre.
final class AppVolumeRowView: NSView {
    var onVolume: ((Double) -> Void)?
    var onToggleMute: (() -> Void)?
    let bundleID: String
    private let icon: NSImageView
    private let muteButton: MuteButton
    private let slider: MenuSlider
    private let percent: NSTextField

    override var isFlipped: Bool { true }

    init(frame: NSRect, app: AppVolumeRow) {
        bundleID = app.bundleID
        icon = NSImageView(frame: NSRect(x: 9, y: 3, width: 26, height: 26))
        muteButton = MuteButton(frame: NSRect(x: 41, y: 7, width: 20, height: 18), symbol: app.muteSymbol, tint: 0.5)
        slider = MenuSlider(frame: NSRect(x: 65, y: 8, width: frame.width - 65 - 46, height: 16))
        percent = NSTextField(labelWithString: "")
        super.init(frame: frame)
        icon.image = Self.icon(for: app.bundleID)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.toolTip = app.name   // the name is only the tooltip: the row has no room, and the icon says which app it is
        addSubview(icon)
        muteButton.onPress = { [weak self] in self?.onToggleMute?() }
        addSubview(muteButton)
        slider.compact = true
        slider.onChange = { [weak self] v in
            self?.onVolume?(v)
            self?.percent.stringValue = AppVolumeRow(bundleID: "", name: "", volume: v, muted: false).percentText
        }
        addSubview(slider)
        percent.font = .systemFont(ofSize: 11)
        percent.alignment = .right
        percent.frame = NSRect(x: frame.width - 46 + 4, y: 9, width: 38, height: 14)
        addSubview(percent)
        update(app, animated: false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `app`'s state. Muting glides the knob to zero and unmuting glides it back, rather than jumping.
    func update(_ app: AppVolumeRow, animated: Bool) {
        icon.alphaValue = app.muted ? 0.55 : 1
        icon.toolTip = app.name
        muteButton.set(symbol: app.muteSymbol, tint: app.muted ? 0.8 : 0.5)
        slider.dimmed = app.muted
        if abs(slider.value - app.sliderPosition) > 0.0005 {
            if animated { slider.glide(to: app.sliderPosition) } else { slider.value = app.sliderPosition }
        }
        percent.stringValue = app.muted ? "Muted" : app.percentText
        percent.textColor = SoundText.ink(app.muted ? 0.4 : 0.55)
    }

    /// The app's own icon, or the generic one when it cannot be found.
    private static func icon(for bundleID: String) -> NSImage {
        // An app that is a bare executable is named by its path: its icon is its running app's.
        if let path = LooseApp.executablePath(from: bundleID),
           let icon = NSWorkspace.shared.runningApplications.first(where: { $0.executableURL?.path == path })?.icon { return icon }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}

final class IconButton: NSView {
    private let action: () -> Void

    /// `added`: drawn added to what is behind it, as macOS draws its secondary icons (about the same lift on any backdrop).
    init(symbol name: String, size: CGFloat = 12, weight: NSFont.Weight = .semibold, tint: CGFloat = 0.6, added: Bool = false,
         frame: NSRect, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: frame)
        let v = NSImageView(frame: bounds)
        v.image = symbol(name, size: size, weight: weight)
        v.contentTintColor = SoundText.ink(tint)
        v.imageScaling = .scaleProportionallyDown
        if added, SoundText.isDark { v.wantsLayer = true; v.layer?.compositingFilter = "plusL" }
        addSubview(v)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override func mouseDown(with event: NSEvent) { action() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The volume slider: a rounded track filled up to a round handle.
extension Notification.Name { static let menuSliderDragEnded = Notification.Name("dev.anode.menuSliderDragEnded") }

final class MenuSlider: NSView {
    /// Where the knob is meant to be. It is drawn at `shown`, which follows it at once, or glides after it (`glide(to:)`).
    var value: Double = 0 { didSet { if glideTimer == nil { shown = value }; needsDisplay = true } }
    private var shown: Double = 0
    private var glideFrom = 0.0
    private var glideStart: CFTimeInterval = 0
    private var glideTimer: Timer?

    /// Moves the knob to `target` the way macOS's things move (the curve of `SoundMenuMotion`), instead of jumping.
    func glide(to target: Double) {
        glideTimer?.invalidate()
        glideFrom = shown
        glideStart = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let elapsed = CACurrentMediaTime() - self.glideStart
            if elapsed >= SoundMenuMotion.settleSeconds {
                t.invalidate(); self.glideTimer = nil; self.shown = self.value
            } else {
                self.shown = self.glideFrom + (self.value - self.glideFrom) * SoundMenuMotion.progress(at: elapsed)
            }
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        glideTimer = timer
        value = target
    }

    private func stopGlide() { glideTimer?.invalidate(); glideTimer = nil; shown = value }
    var onChange: ((Double) -> Void)?
    /// The slider of an app row: the same drawing as the volume slider, smaller, and dimmed while that app is muted.
    var compact = false { didSet { needsDisplay = true } }
    var dimmed = false { didSet { needsDisplay = true } }
    private var thumb: CGFloat { compact ? 14 : 20 }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let trackH: CGFloat = compact ? 4 : 6, knobH: CGFloat = compact ? 12 : 16
        let track = NSRect(x: 0, y: bounds.midY - trackH / 2, width: bounds.width, height: trackH)
        SoundText.ink(dimmed ? 0.08 : 0.13).setFill()
        NSBezierPath(roundedRect: track, xRadius: trackH / 2, yRadius: trackH / 2).fill()
        let x = CGFloat(shown) * (bounds.width - thumb)
        var filled = track; filled.size.width = x + thumb / 2
        SoundText.ink(dimmed ? 0.16 : 0.33).setFill()
        NSBezierPath(roundedRect: filled, xRadius: trackH / 2, yRadius: trackH / 2).fill()
        // macOS's knob is a rounded shape (20 wide and 16 tall for the main slider), not a circle.
        NSColor(white: dimmed ? 0.62 : 0.89, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: bounds.midY - knobH / 2, width: thumb, height: knobH),
                     xRadius: knobH * 0.47, yRadius: knobH * 0.47).fill()
    }

    /// How many sliders are being dragged. While any is, the menu is not drawn again (that would replace the slider under the
    /// pointer and end the drag); what changed is drawn when the pointer is let go.
    private(set) static var activeDrags = 0
    static func dragBegan() { activeDrags += 1 }
    static func dragEnded() {
        activeDrags = max(0, activeDrags - 1)
        if activeDrags == 0 { NotificationCenter.default.post(name: .menuSliderDragEnded, object: nil) }
    }
    private var dragging = false

    override func mouseDown(with event: NSEvent) {
        stopGlide()
        dragging = true
        Self.dragBegan()
        move(to: event)
    }
    override func mouseDragged(with event: NSEvent) { move(to: event) }
    override func mouseUp(with event: NSEvent) { endDrag() }
    private func endDrag() { if dragging { dragging = false; Self.dragEnded() } }
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { endDrag() }   // taken out mid-drag: the drag is over
        super.viewWillMove(toSuperview: newSuperview)
    }

    private func move(to event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        value = min(1, max(0, Double((x - thumb / 2) / (bounds.width - thumb))))
        onChange?(value)
    }
}

/// How the app builds the Sound menu. Nothing of it runs until its setting is on (Beta Features).
enum SoundMenuRuntime {

    /// The menu over the real Mac.
    static func live(settings: Settings = .shared) -> SoundMenuController {
        make(settings: settings, outputs: CoreAudioOutputs(), driver: SystemPanelDriver(), statusBar: SystemStatusBarHost(),
             native: NativeSoundIcon(), panel: SoundMenuPanel())
    }

    static func make(settings: Settings, outputs: AudioOutputs, driver: SystemPanelDriving, statusBar: StatusItemHosting,
                     native: NativeIconHosting, panel: SoundMenuPanel) -> SoundMenuController {
        let controller = SoundMenuController(settings: settings, outputs: outputs, driver: driver,
                                             batteries: currentAccessoryBatteries, accessibility: { AXIsProcessTrusted() },
                                             statusBar: statusBar, presenter: panel, native: native)
        panel.controller = controller
        controller.start()
        return controller
    }
}

/// A view that only cuts off what is in it: it answers no click itself, and passes them to what is under it.
final class ClipView: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.masksToBounds = true }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { let v = super.hitTest(point); return v === self ? nil : v }
}

/// The hairline around the panel. It draws and answers no clicks.
final class EdgeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

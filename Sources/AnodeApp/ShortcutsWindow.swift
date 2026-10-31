import AppKit
import PowerKit

// ── The window actions and shortcuts window ─────────────────────────────────
//
// A list of every command on the left; on the right, the one picked, in three parts: where it puts the
// window (a screen drawn as a grid, the part it takes lit), its shortcut, and which edges and corners of
// the screen trigger it when a window is dragged there. The layout (list, then size, shortcut and
// activation area for the selected action) follows what other window managers have settled on; the
// drawing and the code are this app's.
//
// Click a shortcut, press the combination you want; it is captured by the same tap that will act on it
// (`KeybindCenter.record`), so a combination macOS would normally take for itself can be chosen, and the
// card says when it replaces one of macOS's. A shortcut another of Anode's commands had is moved to this
// one, and the card says which lost it. Click an edge or corner in the activation area to give it to the
// action, or click one it already has to turn it off.

/// A button that records a shortcut when clicked.
final class ShortcutRecorderButton: NSButton {
    var onChange: ((Shortcut?) -> Void)?
    private(set) var shortcut: Shortcut?
    private(set) var isRecording = false
    private let center: KeybindCenter

    init(center: KeybindCenter = .shared, width: CGFloat = 118) {
        self.center = center
        super.init(frame: .zero)
        bezelStyle = .rounded
        controlSize = .regular
        target = self
        action = #selector(clicked)
        setContentHuggingPriority(.required, for: .horizontal)
        widthAnchor.constraint(equalToConstant: width).isActive = true
        show(nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ shortcut: Shortcut?) {
        self.shortcut = shortcut
        isRecording = false
        title = shortcut?.label ?? "—"
    }

    @objc private func clicked() {
        if isRecording { center.cancelRecording(); return }
        isRecording = true
        title = "Type shortcut…"
        center.record { [weak self] result in
            guard let self else { return }
            switch result {
            case .shortcut(let s): self.show(s); self.onChange?(s)
            case .cancelled: self.show(self.shortcut)
            case .needsModifier: self.title = "Hold a modifier…"
            case .unavailable:
                self.show(self.shortcut)
                self.title = "Needs Accessibility"
            }
        }
    }
}

// ── Drawing ─────────────────────────────────────────────────────────────────

/// A mock screen: a rounded outline with a menu bar strip, drawn inside a view. Both pictures below sit on one.
class MockScreenView: NSView {
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 170) }

    /// The screen, 16:10, as large as fits and centred.
    var screenRect: CGRect {
        let inset = bounds.insetBy(dx: 4, dy: 4)
        let h = min(inset.height, inset.width / 1.6), w = h * 1.6
        return CGRect(x: inset.midX - w / 2, y: inset.minY, width: w, height: h)
    }

    func drawScreen() {
        let r = screenRect
        let body = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        body.fill()
        NSColor.labelColor.withAlphaComponent(0.35).setStroke()
        body.lineWidth = 1.5
        body.stroke()
        // The menu bar.
        let bar = NSBezierPath(rect: CGRect(x: r.minX + 1, y: r.minY + 1, width: r.width - 2, height: max(5, r.height * 0.045)))
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        bar.fill()
    }
}

/// Where an action puts a window, on a mock screen: the window is the lit rectangle.
final class ScreenPreviewView: MockScreenView {
    /// The window's share of the screen (0...1, origin top-left); nil draws an empty screen.
    var lit: CGRect? { didSet { needsDisplay = true } }

    /// The part of an empty screen `action` takes, as shares of it: the same geometry that places real windows.
    static func region(for action: WindowAction) -> CGRect? {
        let area = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        guard let f = WindowGeometry.frame(for: action, from: CGRect(x: 500, y: 300, width: 600, height: 400), in: area) else { return nil }
        return CGRect(x: f.minX / area.width, y: f.minY / area.height, width: f.width / area.width, height: f.height / area.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawScreen()
        guard let lit else { return }
        let s = screenRect
        let bar = max(5, s.height * 0.045)
        let usable = CGRect(x: s.minX, y: s.minY + bar, width: s.width, height: s.height - bar)
        let w = CGRect(x: usable.minX + lit.minX * usable.width, y: usable.minY + lit.minY * usable.height,
                       width: lit.width * usable.width, height: lit.height * usable.height).insetBy(dx: 3, dy: 3)
        let path = NSBezierPath(roundedRect: w, xRadius: 5, yRadius: 5)
        NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
        path.fill()
        // The window's title bar.
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: CGRect(x: w.minX + 6, y: w.minY + 5, width: min(28, w.width - 12), height: 3), xRadius: 1.5, yRadius: 1.5).fill()
    }
}

/// Where the edges and corners of a screen are, as shapes. Pure, for tests and for the picture.
enum ZoneShapes {
    /// The ten zones as rectangles inside `screen` (origin top-left): corners as squares, the left, right
    /// and top edges between them, the bottom edge in three equal parts.
    static func rects(in screen: CGRect, edge: CGFloat = 12, corner: CGFloat = 28) -> [(zone: SnapZone, rect: CGRect)] {
        let inner = screen.insetBy(dx: 0, dy: 0)
        let spanW = inner.width - 2 * corner, spanH = inner.height - 2 * corner
        let third = spanW / 3
        return [
            (.topLeft, CGRect(x: inner.minX, y: inner.minY, width: corner, height: corner)),
            (.topRight, CGRect(x: inner.maxX - corner, y: inner.minY, width: corner, height: corner)),
            (.bottomLeft, CGRect(x: inner.minX, y: inner.maxY - corner, width: corner, height: corner)),
            (.bottomRight, CGRect(x: inner.maxX - corner, y: inner.maxY - corner, width: corner, height: corner)),
            (.top, CGRect(x: inner.minX + corner, y: inner.minY, width: spanW, height: edge)),
            (.left, CGRect(x: inner.minX, y: inner.minY + corner, width: edge, height: spanH)),
            (.right, CGRect(x: inner.maxX - edge, y: inner.minY + corner, width: edge, height: spanH)),
            (.bottomFirst, CGRect(x: inner.minX + corner, y: inner.maxY - edge, width: third, height: edge)),
            (.bottomCenter, CGRect(x: inner.minX + corner + third, y: inner.maxY - edge, width: third, height: edge)),
            (.bottomLast, CGRect(x: inner.minX + corner + 2 * third, y: inner.maxY - edge, width: third, height: edge)),
        ]
    }

    /// The zone under `point`; a little slack so the thin edges are easy to hit.
    static func zone(at point: CGPoint, in screen: CGRect, slack: CGFloat = 4) -> SnapZone? {
        let shapes = rects(in: screen)
        // Corners first: they are the biggest targets and the edges stop short of them.
        for (zone, rect) in shapes where rect.insetBy(dx: -slack, dy: -slack).contains(point) { return zone }
        return nil
    }
}

/// A mock screen with its edges and corners drawn as shapes: the ones that give the action being edited
/// are lit, the ones that give another action are grey, the rest are dim. Click one to give it to the
/// action, or take it away.
final class ZonePickerView: MockScreenView {
    var action: WindowAction? { didSet { needsDisplay = true } }
    var map = SnapZoneMap() { didSet { needsDisplay = true } }
    var onClick: ((SnapZone) -> Void)?
    private var hovered: SnapZone? { didSet { if hovered != oldValue { needsDisplay = true; updateTip() } } }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 190) }

    override func draw(_ dirtyRect: NSRect) {
        drawScreen()
        for (zone, rect) in ZoneShapes.rects(in: screenRect) {
            let owner = map.action(for: zone)
            var color: NSColor
            if let action, owner == action { color = .controlAccentColor }
            else if owner != nil { color = NSColor.labelColor.withAlphaComponent(0.35) }
            else { color = NSColor.labelColor.withAlphaComponent(0.12) }
            if zone == hovered { color = color.blended(withFraction: 0.3, of: .white) ?? color }
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    func zone(at point: NSPoint) -> SnapZone? { ZoneShapes.zone(at: point, in: screenRect) }

    override func mouseMoved(with event: NSEvent) { hovered = zone(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseDown(with event: NSEvent) {
        if let zone = zone(at: convert(event.locationInWindow, from: nil)) { onClick?(zone) }
    }

    private func updateTip() {
        guard let zone = hovered else { toolTip = nil; return }
        let owner = map.action(for: zone)?.title ?? "nothing"
        toolTip = "\(zone.title.prefix(1).uppercased() + zone.title.dropFirst()): \(owner)"
    }
}

// ── The window ──────────────────────────────────────────────────────────────

final class ShortcutsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    static let shared = ShortcutsWindowController()

    private enum Item {
        case header(String)
        case options
        case command(ShortcutCommand)
    }

    private let store: ShortcutStore
    private let prefs: WindowPrefs
    private let commands: [ShortcutCommand]
    private var items: [Item] = []
    private let table = NSTableView()
    private let detailHolder = NSView()
    private var tokens: [NSObjectProtocol] = []

    // The selected command's controls, so a change elsewhere can be shown without rebuilding them.
    private var recorder: ShortcutRecorderButton?
    private var note: NSTextField?
    private var zoneGrid: ZonePickerView?
    private(set) var selectedID: String?

    init(store: ShortcutStore = .shared, prefs: WindowPrefs = .shared, commands: [ShortcutCommand] = ShortcutCommands.all) {
        self.store = store
        self.prefs = prefs
        self.commands = commands
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: min(760, (NSScreen.main?.visibleFrame.height ?? 800) - 60)),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Window Actions & Shortcuts"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 480)
        super.init(window: window)
        items = [.header("Options"), .options]
        var section = ""
        for command in commands {
            if command.section != section { section = command.section; items.append(.header(section)) }
            items.append(.command(command))
        }
        build()
        if let first = commands.first { select(commandID: first.id) }
        tokens.append(NotificationCenter.default.addObserver(forName: ShortcutStore.didChange, object: store, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        tokens.append(NotificationCenter.default.addObserver(forName: WindowPrefs.didChange, object: prefs, queue: .main) { [weak self] _ in
            self?.refresh()
        })
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { for t in tokens { NotificationCenter.default.removeObserver(t) } }

    /// Show the window, on `commandID` if given.
    func show(selecting commandID: String? = nil) {
        if let commandID { select(commandID: commandID) }
        refresh()
        showWindow(nil)
        window?.bringForward()
    }

    // ── The list ────────────────────────────────────────────────────────────

    private func build() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowSizeStyle = .default
        table.dataSource = self
        table.delegate = self
        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false

        let resetAll = NSButton(title: "Reset all to defaults", target: nil, action: nil)
        resetAll.bezelStyle = .rounded
        resetAll.controlSize = .small
        let resetHandler = ActionTarget { [weak self] in
            self?.store.resetAll()
            self?.prefs.zoneMap = SnapZoneMap()
            self?.prefs.gap = 0
            self?.prefs.cycles = true
            self?.prefs.snapModifier = .none
        }
        resetAll.target = resetHandler; resetAll.action = #selector(ActionTarget.fire)
        objc_setAssociatedObject(resetAll, &Self.handlerKey, resetHandler, .OBJC_ASSOCIATION_RETAIN)

        let sidebar = NSView()
        for v in [listScroll, resetAll] { v.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(v) }
        NSLayoutConstraint.activate([
            listScroll.topAnchor.constraint(equalTo: sidebar.topAnchor),
            listScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: resetAll.topAnchor, constant: -8),
            resetAll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            resetAll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -12),
        ])

        let divider = NSBox()
        divider.boxType = .separator
        let root = NSView()
        for v in [sidebar, divider, detailHolder] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 220),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            detailHolder.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            detailHolder.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detailHolder.topAnchor.constraint(equalTo: root.topAnchor),
            detailHolder.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window?.contentView = root
        window?.center()
    }

    private static var handlerKey = 0

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = items[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        let trailing = NSTextField(labelWithString: "")
        trailing.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        trailing.textColor = .secondaryLabelColor
        trailing.alignment = .right
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        switch items[row] {
        case .header(let title):
            label.stringValue = title
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        case .options:
            label.stringValue = "Spacing & snapping"
        case .command(let command):
            label.stringValue = command.title
            trailing.stringValue = store.shortcut(for: command)?.label ?? ""
        }
        let cell = NSStackView(views: [label, NSView(), trailing])
        cell.spacing = 4
        cell.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard items.indices.contains(row) else { return }
        switch items[row] {
        case .command(let c): if selectedID != c.id { selectedID = c.id; showDetail(for: c) }
        case .options: if selectedID != "options" { selectedID = "options"; showOptions() }
        case .header: break
        }
    }

    /// Select the command with this id (or "options") in the list and show it.
    func select(commandID: String) {
        let row = items.firstIndex { item in
            switch item {
            case .command(let c): return c.id == commandID
            case .options: return commandID == "options"
            case .header: return false
            }
        }
        guard let row else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
    }

    // ── The detail ──────────────────────────────────────────────────────────

    private func setDetail(_ content: NSView) {
        recorder = nil; note = nil; zoneGrid = nil
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let document = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        scroll.documentView = document
        detailHolder.subviews.forEach { $0.removeFromSuperview() }
        scroll.translatesAutoresizingMaskIntoConstraints = false
        detailHolder.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: detailHolder.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: detailHolder.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: detailHolder.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: detailHolder.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        document.translatesAutoresizingMaskIntoConstraints = false
        document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor).isActive = true
        document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor).isActive = true
        document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true
    }

    private func column(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 22, right: 22)
        for v in views where v is CardView { v.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -22).isActive = true }
        return stack
    }

    private func heading(_ text: String) -> NSTextField {
        let h = NSTextField(labelWithString: text)
        h.font = .systemFont(ofSize: 20, weight: .semibold)
        return h
    }

    private func caption(_ text: String, color: NSColor = .secondaryLabelColor) -> NSTextField {
        BetaFeaturesWindowController.wrapping(text, color: color)
    }

    private func showDetail(for command: ShortcutCommand) {
        var views: [NSView] = [heading(command.title)]
        let action = WindowAction.allCases.first { $0.commandID == command.id }

        if let action {
            let grid = ScreenPreviewView()
            if let region = ScreenPreviewView.region(for: action) { grid.lit = region }
            var text = Self.describe(action)
            if prefs.cycles, let chain = WindowGeometry.cycle(for: action) {
                text += " Press it again to step through " + chain.dropFirst().map { $0.title.lowercased() }.joined(separator: ", then ") + "."
            }
            views.append(CardView(title: "Intended window size and position", content: [grid, caption(text)]))
        }

        let recorder = ShortcutRecorderButton(width: 190)
        let note = NSTextField(wrappingLabelWithString: "")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let clear = NSButton(title: "Clear", target: nil, action: nil)
        let reset = NSButton(title: "Reset to default", target: nil, action: nil)
        for b in [clear, reset] { b.bezelStyle = .rounded; b.controlSize = .small }
        let clearHandler = ActionTarget { [weak self] in self?.assign(nil, to: command) }
        let resetHandler = ActionTarget { [weak self] in self?.store.reset(command) }
        clear.target = clearHandler; clear.action = #selector(ActionTarget.fire)
        reset.target = resetHandler; reset.action = #selector(ActionTarget.fire)
        objc_setAssociatedObject(clear, &Self.handlerKey, clearHandler, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(reset, &Self.handlerKey, resetHandler, .OBJC_ASSOCIATION_RETAIN)
        recorder.onChange = { [weak self] new in self?.assign(new, to: command) }
        let buttons = NSStackView(views: [recorder, clear, reset])
        buttons.spacing = 8
        views.append(CardView(title: "Keyboard shortcut", content: [buttons, note]))

        var newZoneGrid: ZonePickerView?
        if let action, action.hasRegion {
            let grid = ZonePickerView()
            grid.action = action
            grid.map = prefs.zoneMap
            grid.onClick = { [weak self] zone in
                guard let self else { return }
                var map = self.prefs.zoneMap
                map.toggle(zone, for: action)
                self.prefs.zoneMap = map
            }
            let hint = caption("Click the edges and corners of the screen that should do this when a window is dragged "
                               + "there. Grey ones belong to other actions; clicking one takes it.")
            let off = caption("Snapping by dragging is switched off in Beta Features.", color: .systemOrange)
            off.isHidden = Settings.shared.windowDragSnapEnabled
            views.append(CardView(title: "Activation area for dragging", content: [grid, hint, off]))
            newZoneGrid = grid
        }

        setDetail(column(views))
        self.recorder = recorder
        self.note = note
        zoneGrid = newZoneGrid
        refresh()
    }

    private func showOptions() {
        let gap = NSSlider(value: Double(prefs.gap), minValue: 0, maxValue: Double(WindowPrefs.maxGap), target: nil, action: nil)
        gap.numberOfTickMarks = 5
        gap.allowsTickMarkValuesOnly = false
        let gapValue = NSTextField(labelWithString: "\(prefs.gap) pt")
        gapValue.setContentHuggingPriority(.required, for: .horizontal)
        let gapHandler = ActionTarget { [weak self, weak gap, weak gapValue] in
            guard let self, let gap else { return }
            self.prefs.gap = Int(gap.doubleValue.rounded())
            gapValue?.stringValue = "\(self.prefs.gap) pt"
        }
        gap.target = gapHandler; gap.action = #selector(ActionTarget.fire)
        objc_setAssociatedObject(gap, &Self.handlerKey, gapHandler, .OBJC_ASSOCIATION_RETAIN)
        let gapRow = NSStackView(views: [gap, gapValue])
        gapRow.spacing = 10
        gap.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let cycle = NSButton(checkboxWithTitle: "Press a half again to step through two thirds, then a third", target: nil, action: nil)
        cycle.state = prefs.cycles ? .on : .off
        let cycleHandler = ActionTarget { [weak self, weak cycle] in self?.prefs.cycles = cycle?.state == .on }
        cycle.target = cycleHandler; cycle.action = #selector(ActionTarget.fire)
        objc_setAssociatedObject(cycle, &Self.handlerKey, cycleHandler, .OBJC_ASSOCIATION_RETAIN)

        let modifier = NSPopUpButton(frame: .zero, pullsDown: false)
        for m in SnapModifier.allCases { modifier.addItem(withTitle: m.title) }
        modifier.selectItem(at: SnapModifier.allCases.firstIndex(of: prefs.snapModifier) ?? 0)
        let modifierHandler = ActionTarget { [weak self, weak modifier] in
            guard let self, let i = modifier?.indexOfSelectedItem, SnapModifier.allCases.indices.contains(i) else { return }
            self.prefs.snapModifier = SnapModifier.allCases[i]
        }
        modifier.target = modifierHandler; modifier.action = #selector(ActionTarget.fire)
        objc_setAssociatedObject(modifier, &Self.handlerKey, modifierHandler, .OBJC_ASSOCIATION_RETAIN)

        let views: [NSView] = [
            heading("Spacing & snapping"),
            CardView(title: "Gap around windows", content: [
                gapRow,
                caption("Left between a placed window and the screen's edge, and (the two halves together) between two placed windows."),
            ]),
            CardView(title: "Repeating an action", content: [cycle]),
            CardView(title: "Hold to snap", content: [
                modifier,
                caption("With a key chosen, dragging a window to an edge only snaps while that key is held, so a window can "
                        + "still be parked at the edge without snapping."),
            ]),
        ]
        setDetail(column(views))
    }

    private static func describe(_ action: WindowAction) -> String {
        switch action {
        case .restore: return "Puts the window back at the size and place it had before Anode first moved it."
        case .nextDisplay: return "Sends the window to the next display, keeping its place and share of the screen."
        case .previousDisplay: return "Sends the window to the previous display, keeping its place and share of the screen."
        case .center: return "Centers the window, keeping its size."
        case .maximizeHeight: return "Stretches the window to the full height of the screen, keeping its width."
        default: return "The lit window is the part of the screen it takes."
        }
    }

    private func assign(_ new: Shortcut?, to command: ShortcutCommand) {
        let stolen = store.assign(new, to: command, among: commands)
        refresh()
        if let stolen, let note {
            note.stringValue = "Taken from “\(stolen.title)”, which now has none."
            note.textColor = .systemOrange
        }
    }

    /// Show the current shortcut, what it replaces, and the zones, after anything changed.
    func refresh() {
        table.reloadData()
        if let selectedID, let row = items.firstIndex(where: { if case .command(let c) = $0 { return c.id == selectedID } else { return false } }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if selectedID == "options", let row = items.firstIndex(where: { if case .options = $0 { return true } else { return false } }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        guard let selectedID, let command = commands.first(where: { $0.id == selectedID }) else { return }
        let s = store.shortcut(for: command)
        if let recorder, !recorder.isRecording { recorder.show(s) }
        if let note {
            if let s, let clash = SystemShortcuts.clash(for: s) {
                note.stringValue = "Replaces macOS's “\(clash)”."
                note.textColor = .systemOrange
            } else {
                note.stringValue = s == nil ? "No shortcut." : "Wins over macOS's and other apps' shortcuts."
                note.textColor = .secondaryLabelColor
            }
        }
        zoneGrid?.map = prefs.zoneMap
    }
}

/// A rounded panel with a title, holding a column of views.
final class CardView: NSView {
    init(title: String, content: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let stack = NSStackView(views: [heading] + content)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        // Wide things (the grids, the captions) fill the card.
        for v in content where v is MockScreenView || v is NSTextField {
            v.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14).isActive = true
        }
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() { updateColors() }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        }
    }
}

/// A target that runs a closure, for buttons made in a loop.
final class ActionTarget: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

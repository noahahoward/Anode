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

/// A screen drawn as a grid of cells, with the part a window will take lit.
final class RegionGridView: NSView {
    static let cols = 18, rows = 12
    /// The lit part, in cells (origin top-left); nil lights nothing.
    var lit: CGRect? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 190) }

    /// The cells `action` takes on an empty screen of `cols` x `rows`: the same geometry that places real windows.
    static func region(for action: WindowAction) -> CGRect? {
        let area = CGRect(x: 0, y: 0, width: cols, height: rows)
        return WindowGeometry.frame(for: action, from: CGRect(x: 6, y: 3, width: 6, height: 6), in: area)
    }

    override func draw(_ dirtyRect: NSRect) {
        let gap: CGFloat = 3
        let cell = min((bounds.width - gap * CGFloat(Self.cols - 1)) / CGFloat(Self.cols),
                       (bounds.height - gap * CGFloat(Self.rows - 1)) / CGFloat(Self.rows))
        guard cell > 1 else { return }
        let width = cell * CGFloat(Self.cols) + gap * CGFloat(Self.cols - 1)
        let originX = (bounds.width - width) / 2
        for r in 0..<Self.rows {
            for c in 0..<Self.cols {
                let on = lit.map { $0.contains(CGPoint(x: CGFloat(c) + 0.5, y: CGFloat(r) + 0.5)) } ?? false
                (on ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.16)).setFill()
                let rect = NSRect(x: originX + CGFloat(c) * (cell + gap), y: CGFloat(r) * (cell + gap), width: cell, height: cell)
                NSBezierPath(roundedRect: rect, xRadius: cell * 0.25, yRadius: cell * 0.25).fill()
            }
        }
    }
}

/// Where a cell of the activation area's ring belongs. Pure, for tests.
enum ZoneLayout {
    static let cols = 18, rows = 10

    /// The zone the ring cell at `col`, `row` belongs to; nil for a cell inside the ring.
    static func zone(col: Int, row: Int, cols: Int = ZoneLayout.cols, rows: Int = ZoneLayout.rows) -> SnapZone? {
        guard col >= 0, col < cols, row >= 0, row < rows else { return nil }
        let edgeCol = col == 0 || col == cols - 1, edgeRow = row == 0 || row == rows - 1
        guard edgeCol || edgeRow else { return nil }
        let nearL = col < 2, nearR = col >= cols - 2, nearT = row < 2, nearB = row >= rows - 2
        if nearL && nearT { return .topLeft }
        if nearR && nearT { return .topRight }
        if nearL && nearB { return .bottomLeft }
        if nearR && nearB { return .bottomRight }
        if col == 0 { return .left }
        if col == cols - 1 { return .right }
        if row == 0 { return .top }
        let third = col * 3 / cols
        return third == 0 ? .bottomFirst : (third == 1 ? .bottomCenter : .bottomLast)
    }
}

/// The edges and corners of a screen, drawn as a ring of cells around dots: the ones that give the action
/// being edited are lit, the ones that give another action are grey, the rest are dim. Click one to give it
/// to the action, or take it away.
final class ZoneGridView: NSView {
    var action: WindowAction? { didSet { needsDisplay = true } }
    var map = SnapZoneMap() { didSet { needsDisplay = true } }
    var onClick: ((SnapZone) -> Void)?
    private var hovered: SnapZone? { didSet { if hovered != oldValue { needsDisplay = true; updateTip() } } }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 150) }

    private struct Metrics { let cell: CGFloat, gap: CGFloat, originX: CGFloat }

    private var metrics: Metrics {
        let gap: CGFloat = 3
        let cell = min((bounds.width - gap * CGFloat(ZoneLayout.cols - 1)) / CGFloat(ZoneLayout.cols),
                       (bounds.height - gap * CGFloat(ZoneLayout.rows - 1)) / CGFloat(ZoneLayout.rows))
        let width = cell * CGFloat(ZoneLayout.cols) + gap * CGFloat(ZoneLayout.cols - 1)
        return Metrics(cell: cell, gap: gap, originX: (bounds.width - width) / 2)
    }

    private func rect(_ c: Int, _ r: Int, _ m: Metrics) -> NSRect {
        NSRect(x: m.originX + CGFloat(c) * (m.cell + m.gap), y: CGFloat(r) * (m.cell + m.gap), width: m.cell, height: m.cell)
    }

    /// The zone at a point of the view, or nil.
    func zone(at point: NSPoint) -> SnapZone? {
        let m = metrics
        guard m.cell > 1 else { return nil }
        for r in 0..<ZoneLayout.rows {
            for c in 0..<ZoneLayout.cols where rect(c, r, m).insetBy(dx: -m.gap / 2, dy: -m.gap / 2).contains(point) {
                return ZoneLayout.zone(col: c, row: r)
            }
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let m = metrics
        guard m.cell > 1 else { return }
        for r in 0..<ZoneLayout.rows {
            for c in 0..<ZoneLayout.cols {
                let box = rect(c, r, m)
                guard let zone = ZoneLayout.zone(col: c, row: r) else {
                    NSColor.labelColor.withAlphaComponent(0.35).setFill()
                    NSBezierPath(ovalIn: NSRect(x: box.midX - 1.2, y: box.midY - 1.2, width: 2.4, height: 2.4)).fill()
                    continue
                }
                let owner = map.action(for: zone)
                let color: NSColor
                if let action, owner == action { color = .controlAccentColor }
                else if owner != nil { color = NSColor.labelColor.withAlphaComponent(0.30) }
                else { color = NSColor.labelColor.withAlphaComponent(0.12) }
                (zone == hovered ? color.blended(withFraction: 0.25, of: .white) ?? color : color).setFill()
                NSBezierPath(roundedRect: box, xRadius: m.cell * 0.3, yRadius: m.cell * 0.3).fill()
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

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
    private var zoneGrid: ZoneGridView?
    private(set) var selectedID: String?

    init(store: ShortcutStore = .shared, prefs: WindowPrefs = .shared, commands: [ShortcutCommand] = ShortcutCommands.all) {
        self.store = store
        self.prefs = prefs
        self.commands = commands
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
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
            let grid = RegionGridView()
            if let region = RegionGridView.region(for: action) { grid.lit = region }
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

        var newZoneGrid: ZoneGridView?
        if let action, action.hasRegion {
            let grid = ZoneGridView()
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
        default: return "The lit part of the screen is what the window takes."
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
        for v in content where v is RegionGridView || v is ZoneGridView || v is NSTextField {
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

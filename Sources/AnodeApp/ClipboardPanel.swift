import AppKit
import ImageIO
import PowerKit

// ── Clipboard History: the panel ────────────────────────────────────────────
//
// A search bar over a list, in the middle of the upper part of the screen, in the system glass, as Spotlight looks. Type to
// search, ↑ ↓ to move, ↩ to paste into the app that was in front.
//
// It must not take that app's place. The panel is a non-activating one, ordered front without Anode becoming the active app
// (`orderFrontRegardless`, never `NSApp.activate`), so the app being pasted into stays in front. It becomes the KEY window, so
// that typing reaches the search field (`canBecomeKey`); and a key window that is ordered out hands "key" on to another window
// of Anode's, which would bring it forward over the app being pasted into, so the controller puts the app in front back
// (`restoreFront`) every time the panel goes.
//
// The keys are taken in `sendEvent`, before the field sees them, so ↑ ↓ ↩ and the ⌘ and ⌥ combinations are not the field's.

/// Every measure in one place. They are ESTIMATES of macOS's Spotlight panel (this Mac has none to measure): to be compared
/// side by side with it and changed here.
enum ClipboardPanelMetrics {
    static let width: CGFloat = 680
    static let searchHeight: CGFloat = 60
    static let rowHeight: CGFloat = 48
    static let maxVisibleRows = 8
    static let listPadding: CGFloat = 6
    static let footerHeight: CGFloat = 30
    static let emptyHeight: CGFloat = 84
    static let cornerRadius: CGFloat = 26
    /// How far down from the top of the visible screen the panel's top edge is, as a fraction of its height.
    static let topFraction: CGFloat = 0.2
    static let searchFontSize: CGFloat = 22
    static let iconSize: CGFloat = 28
    static let sideInset: CGFloat = 22
    static let rowInset: CGFloat = 8
    static let selectionRadius: CGFloat = 10
    /// How long the panel takes to fade in and out (estimates of Spotlight's, to be compared with it; none when Reduce Motion is on).
    static let fadeInDuration: TimeInterval = 0.18
    static let fadeOutDuration: TimeInterval = 0.12
    /// Spotlight's look: black at the top, around the search bar, fading down into the glass of the list. How far down it
    /// reaches, and how dark it is at the top in a dark and in a light appearance (a light one is only a hint of it, so the
    /// search text stays readable).
    static let fadeHeight: CGFloat = 170
    static let fadeAlphaDark: CGFloat = 0.6
    static let fadeAlphaLight: CGFloat = 0.2
}

/// What a row shows, worked out once when the list is built.
struct ClipboardRowModel {
    let entry: ClipboardEntry
    let title: String
    let subtitle: String
    /// "⌘1" … "⌘9" for the first nine.
    let hint: String?

    static func make(_ entry: ClipboardEntry, index: Int, now: Date = Date()) -> ClipboardRowModel {
        let title = entry.preview.isEmpty ? entry.kind.title : entry.preview
        let subtitle = [entry.detail, entry.sourceName, ClipboardSearch.ago(from: entry.date, to: now)]
            .compactMap { $0 }.joined(separator: " · ")
        return ClipboardRowModel(entry: entry, title: title, subtitle: subtitle, hint: index < 9 ? "⌘\(index + 1)" : nil)
    }
}

// ── The window ──────────────────────────────────────────────────────────────

final class ClipboardPanel: NSPanel, ClipboardPresenting, NSWindowDelegate {

    private weak var controller: ClipboardHistoryController?
    private let content = ClipboardContentView()
    private var monitors: [Any] = []
    private(set) var shown = false

    var isOpen: Bool { shown }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: ClipboardPanelMetrics.width, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isReleasedWhenClosed = false
        animationBehavior = .none
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        delegate = self
        contentView = content
        setAccessibilityIdentifier("dev.anode.clipboardHistory")
        setAccessibilityLabel("Clipboard History")
        content.onResize = { [weak self] height in self?.setHeight(height) }
    }

    /// Typing has to reach the search field.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // ── Showing ─────────────────────────────────────────────────────────────

    func show(controller: ClipboardHistoryController) {
        self.controller = controller
        content.controller = controller
        content.reset()
        place()
        let animated = DisplayAccessibility.current.animates
        let reopened = isVisible        // it was still fading out
        shown = true
        if !reopened { alphaValue = animated ? 0 : 1 }
        orderFrontRegardless()
        makeKey()
        makeFirstResponder(content.field)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = ClipboardPanelMetrics.fadeInDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        } else {
            alphaValue = 1
        }
        // A click on anything else, in any other app, closes it; so does another window taking the key.
        if let click = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            self?.dismissFromPanel()
        }) { monitors.append(click) }
    }

    func refresh() {
        guard shown else { return }
        content.reload(keepingSelection: true)
    }

    func hide(completion: @escaping () -> Void) {
        guard shown else { completion(); return }
        shown = false
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        guard DisplayAccessibility.current.animates else {
            orderOut(nil)
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = ClipboardPanelMetrics.fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Opened again while it faded: it stays, and the fade-in has taken over.
            if let self, !self.shown { self.orderOut(nil); self.alphaValue = 1 }
            completion()
        })
    }

    private func dismissFromPanel() {
        guard shown else { return }
        controller?.dismiss()
    }

    func windowDidResignKey(_ notification: Notification) {
        // The paste itself puts the panel away first; this is the panel losing the key to something else.
        dismissFromPanel()
    }

    // ── Where it sits ───────────────────────────────────────────────────────

    /// The screen the pointer is on, or the main one.
    private func targetScreen() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Horizontally centred on the screen, the top edge a fifth of the way down. Pure, for tests.
    static func frame(height: CGFloat, in visible: NSRect) -> NSRect {
        let top = visible.maxY - visible.height * ClipboardPanelMetrics.topFraction
        return NSRect(x: visible.midX - ClipboardPanelMetrics.width / 2, y: top - height, width: ClipboardPanelMetrics.width, height: height)
    }

    private func place() {
        guard let screen = targetScreen() else { return }
        setFrame(Self.frame(height: frame.height, in: screen.visibleFrame), display: false)
    }

    /// The top edge stays where it is when the list grows or shrinks.
    private func setHeight(_ height: CGFloat) {
        guard abs(frame.height - height) > 0.5 else { return }
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - height, width: frame.width, height: height), display: true)
    }

    // ── Keys ────────────────────────────────────────────────────────────────

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handle(event) { return }
        super.sendEvent(event)
    }

    /// What a key does, or nil when it is for the search field. Pure, for tests.
    enum KeyAction: Equatable {
        case move(Int)
        case choose(ClipboardHistoryController.PasteMode)
        case chooseRow(Int)
        case delete
        case pin
        case escape
    }

    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) -> KeyAction? {
        let mods = modifiers.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        switch keyCode {
        case 126 where mods.isEmpty: return .move(-1)
        case 125 where mods.isEmpty: return .move(1)
        case 116 where mods.isEmpty: return .move(-5)
        case 121 where mods.isEmpty: return .move(5)
        case 36, 76:
            if mods.isEmpty { return .choose(.paste) }
            if mods == .command { return .choose(.copyOnly) }
            if mods == .option || mods == .shift { return .choose(.plainText) }
            return nil
        case 53 where mods.isEmpty: return .escape
        case 51 where mods == .command: return .delete
        case 35 where mods == .command: return .pin
        default:
            if mods == .command, let c = characters, c.count == 1, let n = Int(c), (1...9).contains(n) { return .chooseRow(n - 1) }
            return nil
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        // A word being composed (an input method) is the field's: its keys are not ours.
        if let editor = firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        guard let action = Self.action(keyCode: event.keyCode, modifiers: event.modifierFlags, characters: event.charactersIgnoringModifiers)
        else { return false }
        switch action {
        case .move(let by): content.moveSelection(by)
        case .choose(let mode): if let id = content.selectedEntry?.id { controller?.choose(id, mode: mode) }
        case .chooseRow(let row): if let id = content.entry(atRow: row)?.id { controller?.choose(id, mode: .paste) }
        case .delete: if let id = content.selectedEntry?.id { controller?.delete(id) }
        case .pin: if let id = content.selectedEntry?.id { controller?.togglePin(id) }
        case .escape:
            // The first Escape clears what was typed, the second closes: as Spotlight does.
            if content.hasQuery { content.clearQuery() } else { controller?.dismiss() }
        }
        return true
    }
}

// ── The black fade ──────────────────────────────────────────────────────────

/// Black at the top, clear at the bottom, clipped to the panel's rounded top corners. Drawn over the glass and under everything
/// else; it takes no clicks.
final class ClipboardFadeView: NSView {
    private let gradient = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = ClipboardPanelMetrics.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]   // the top two, in a layer's own (y up) coordinates
        layer?.masksToBounds = true
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.locations = [0, 0.5, 1]
        layer?.addSublayer(gradient)
        recolor()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        gradient.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolor()
    }

    /// The alpha at the top for an appearance. Pure, for tests.
    static func topAlpha(dark: Bool) -> CGFloat {
        dark ? ClipboardPanelMetrics.fadeAlphaDark : ClipboardPanelMetrics.fadeAlphaLight
    }

    private func recolor() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let top = Self.topAlpha(dark: dark)
        gradient.colors = [NSColor.black.withAlphaComponent(top).cgColor,
                           NSColor.black.withAlphaComponent(top * 0.4).cgColor,
                           NSColor.black.withAlphaComponent(0).cgColor]
    }
}

// ── The content ─────────────────────────────────────────────────────────────

final class ClipboardContentView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {

    weak var controller: ClipboardHistoryController?
    /// The height the panel should be, whenever the list changes it.
    var onResize: ((CGFloat) -> Void)?

    typealias M = ClipboardPanelMetrics

    /// The system glass on macOS 26 and later; before that, the menu material.
    private let material: NSView = {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = M.cornerRadius
            return glass
        }
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = M.cornerRadius
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }()
    /// The black that fades down from the top of the panel into the glass.
    private let fade = ClipboardFadeView()
    /// The hairline round the panel, and the plain fill that takes the glass's place under Reduce Transparency.
    private let edge = EdgeView()
    private let solid = SolidPanelView()
    let field = NSTextField()
    private let searchIcon = NSImageView()
    private let divider = NSBox()
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let footer = NSTextField(labelWithString: "↩ Paste    ⌥↩ Plain text    ⌘↩ Copy    ⌘⌫ Delete    ⌘P Pin    esc Close")
    private var rows: [ClipboardRowModel] = []

    private static let cellID = NSUserInterfaceItemIdentifier("clipboardRow")

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: M.width, height: 200))
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        // Clipped to the panel's rounded shape, as the Sound menu is: nothing square can show at the corners (it was a black box
        // behind the glass), and the window's shadow follows this shape.
        wantsLayer = true
        layer?.cornerRadius = M.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        material.frame = bounds
        material.autoresizingMask = [.width, .height]
        addSubview(material)
        solid.wantsLayer = true
        solid.frame = bounds
        solid.autoresizingMask = [.width, .height]
        solid.isHidden = true
        addSubview(solid)
        addSubview(fade)
        edge.wantsLayer = true
        edge.layer?.cornerRadius = M.cornerRadius
        edge.layer?.cornerCurve = .continuous
        edge.layer?.borderWidth = 0.5
        edge.frame = bounds
        edge.autoresizingMask = [.width, .height]

        searchIcon.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: M.searchFontSize - 2, weight: .regular)
        addSubview(searchIcon)

        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: M.searchFontSize, weight: .light)
        field.placeholderString = "Search Clipboard History"
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        field.setAccessibilityLabel("Search Clipboard History")
        addSubview(field)

        divider.boxType = .separator
        addSubview(divider)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = M.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.style = .plain          // no inset of its own: the rows start where the list does
        scroll.documentView = table
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        addSubview(scroll)

        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        addSubview(emptyLabel)

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        footer.alignment = .center
        footer.lineBreakMode = .byTruncatingTail
        addSubview(footer)
        addSubview(edge)   // last, over everything, and never takes a click
        updateMaterial()
    }

    /// Glass, or a plain panel when Reduce Transparency is on; a stronger edge under Increase Contrast.
    private func updateMaterial() {
        let a = DisplayAccessibility.current
        material.isHidden = a.glassIsSolid
        fade.isHidden = a.glassIsSolid
        solid.isHidden = !a.glassIsSolid
        solid.needsDisplay = true
        edge.layer?.borderColor = NSColor.white.withAlphaComponent(a.increaseContrast ? 0.35 : 0.05).cgColor
    }

    // ── What is listed ──────────────────────────────────────────────────────

    var hasQuery: Bool { !field.stringValue.isEmpty }
    var selectedEntry: ClipboardEntry? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].entry : nil }
    func entry(atRow row: Int) -> ClipboardEntry? { rows.indices.contains(row) ? rows[row].entry : nil }

    /// A fresh start: nothing typed, the first row chosen.
    func reset() {
        updateMaterial()
        field.stringValue = ""
        reload(keepingSelection: false)
    }

    func clearQuery() {
        field.stringValue = ""
        reload(keepingSelection: false)
    }

    func reload(keepingSelection: Bool) {
        let keep = keepingSelection ? selectedEntry?.id : nil
        let now = Date()
        let found = controller?.results(for: field.stringValue) ?? []
        rows = found.enumerated().map { ClipboardRowModel.make($0.element, index: $0.offset, now: now) }
        table.reloadData()
        if !rows.isEmpty {
            let row = keep.flatMap { id in rows.firstIndex { $0.entry.id == id } } ?? 0
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        updateSelectionLook()
        emptyLabel.stringValue = hasQuery ? "No matches for \u{201C}\(field.stringValue)\u{201D}" : "Nothing copied yet"
        needsLayout = true
        onResize?(height(forRows: rows.count))
        layoutNow()
    }

    func moveSelection(_ by: Int) {
        guard !rows.isEmpty else { return }
        let row = min(rows.count - 1, max(0, (table.selectedRow < 0 ? 0 : table.selectedRow) + by))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        updateSelectionLook()
    }

    @objc private func rowClicked() {
        guard let id = entry(atRow: table.clickedRow)?.id else { return }
        controller?.choose(id, mode: .paste)
    }

    func controlTextDidChange(_ obj: Notification) { reload(keepingSelection: false) }

    // ── Layout ──────────────────────────────────────────────────────────────

    private func height(forRows count: Int) -> CGFloat {
        let list = count == 0 ? M.emptyHeight : CGFloat(min(count, M.maxVisibleRows)) * M.rowHeight + 2 * M.listPadding
        return M.searchHeight + 1 + list + M.footerHeight
    }

    private func layoutNow() { layoutSubtreeIfNeeded(); layout() }

    override func layout() {
        super.layout()
        let w = bounds.width
        searchIcon.frame = NSRect(x: M.sideInset, y: (M.searchHeight - 28) / 2, width: 28, height: 28)
        let fieldHeight: CGFloat = 32
        field.frame = NSRect(x: M.sideInset + 28 + 12, y: (M.searchHeight - fieldHeight) / 2,
                             width: w - 2 * M.sideInset - 28 - 12, height: fieldHeight)
        // Flipped, so the top is y 0; the fade view itself is not, and its own origin is its bottom-left.
        let fadeHeight = min(bounds.height, M.fadeHeight)
        fade.frame = NSRect(x: 0, y: 0, width: w, height: fadeHeight)
        divider.frame = NSRect(x: 0, y: M.searchHeight, width: w, height: 1)
        let listTop = M.searchHeight + 1
        let listHeight = bounds.height - listTop - M.footerHeight
        scroll.frame = NSRect(x: 0, y: listTop + M.listPadding, width: w, height: max(0, listHeight - 2 * M.listPadding))
        table.tableColumns.first?.width = w
        emptyLabel.frame = NSRect(x: M.sideInset, y: listTop + (listHeight - 20) / 2, width: w - 2 * M.sideInset, height: 20)
        footer.frame = NSRect(x: M.sideInset, y: bounds.height - M.footerHeight + 7, width: w - 2 * M.sideInset, height: 16)
        let empty = rows.isEmpty
        scroll.isHidden = empty
        emptyLabel.isHidden = !empty
    }

    // ── The table ───────────────────────────────────────────────────────────

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let cell = (tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? ClipboardRowCellView) ?? {
            let c = ClipboardRowCellView()
            c.identifier = Self.cellID
            return c
        }()
        cell.configure(rows[row], icon: ClipboardIcons.icon(for: rows[row].entry, store: controller?.store), selected: row == table.selectedRow)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ClipboardRowView() }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelectionLook() }

    private func updateSelectionLook() {
        table.enumerateAvailableRowViews { rowView, row in
            (rowView.view(atColumn: 0) as? ClipboardRowCellView)?.setSelected(row == self.table.selectedRow)
        }
    }
}

/// The selection: a rounded accent bar inset from the sides, as Spotlight draws it.
final class ClipboardRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: ClipboardPanelMetrics.rowInset, dy: 1)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: ClipboardPanelMetrics.selectionRadius, yRadius: ClipboardPanelMetrics.selectionRadius).fill()
    }
    override var isEmphasized: Bool { get { true } set {} }
}

final class ClipboardRowCellView: NSView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let hintField = NSTextField(labelWithString: "")
    private let pinView = NSImageView()
    private var selected = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        titleField.font = .systemFont(ofSize: 14)
        titleField.lineBreakMode = .byTruncatingTail
        subtitleField.font = .systemFont(ofSize: 11.5)
        subtitleField.lineBreakMode = .byTruncatingTail
        hintField.font = .systemFont(ofSize: 12)
        hintField.alignment = .right
        pinView.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
        for v in [iconView, titleField, subtitleField, hintField, pinView] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ row: ClipboardRowModel, icon: NSImage?, selected: Bool) {
        iconView.image = icon
        titleField.stringValue = row.title
        subtitleField.stringValue = row.subtitle
        hintField.stringValue = row.hint ?? ""
        pinView.isHidden = !row.entry.pinned
        setAccessibilityLabel("\(row.title), \(row.subtitle)\(row.entry.pinned ? ", pinned" : "")")
        setSelected(selected)
        needsLayout = true
    }

    func setSelected(_ on: Bool) {
        selected = on
        titleField.textColor = on ? .white : .labelColor
        subtitleField.textColor = on ? NSColor.white.withAlphaComponent(0.75) : .secondaryLabelColor
        hintField.textColor = on ? NSColor.white.withAlphaComponent(0.75) : .tertiaryLabelColor
        pinView.contentTintColor = on ? .white : .secondaryLabelColor
    }

    override func layout() {
        super.layout()
        let m = ClipboardPanelMetrics.self
        let inset = m.rowInset + 12
        iconView.frame = NSRect(x: inset, y: (bounds.height - m.iconSize) / 2, width: m.iconSize, height: m.iconSize)
        let hintWidth: CGFloat = 36
        hintField.frame = NSRect(x: bounds.width - inset - hintWidth, y: (bounds.height - 16) / 2, width: hintWidth, height: 16)
        let pinWidth: CGFloat = pinView.isHidden ? 0 : 16
        pinView.frame = NSRect(x: hintField.frame.minX - 6 - pinWidth, y: (bounds.height - 14) / 2, width: pinWidth, height: 14)
        let textX = iconView.frame.maxX + 12
        let textRight = (pinView.isHidden ? hintField.frame.minX : pinView.frame.minX) - 8
        titleField.frame = NSRect(x: textX, y: bounds.height / 2 - 1, width: max(0, textRight - textX), height: 19)
        subtitleField.frame = NSRect(x: textX, y: bounds.height / 2 - 18, width: max(0, textRight - textX), height: 16)
    }
}

// ── Pictures ────────────────────────────────────────────────────────────────

/// The picture on a row: an image's own, a file's icon, or the icon of the app the copy came from.
enum ClipboardIcons {
    private static let thumbnails = NSCache<NSString, NSImage>()
    private static var appIcons: [String: NSImage] = [:]

    static func icon(for entry: ClipboardEntry, store: ClipboardStore?) -> NSImage? {
        switch entry.kind {
        case .image:
            if let cached = thumbnails.object(forKey: entry.fingerprint as NSString) { return cached }
            if let store, let data = store.data(for: entry.id, ofType: ClipboardTypes.images), let image = thumbnail(data) {
                thumbnails.setObject(image, forKey: entry.fingerprint as NSString)
                return image
            }
        case .file:
            if let path = entry.text.split(separator: "\n").first.map(String.init), FileManager.default.fileExists(atPath: path) {
                return NSWorkspace.shared.icon(forFile: path)
            }
        case .text, .link:
            break
        }
        if let id = entry.sourceBundleID, let icon = appIcon(id) { return icon }
        let symbol = entry.kind == .link ? "link" : entry.kind == .image ? "photo" : entry.kind == .file ? "doc" : "text.alignleft"
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    private static func appIcon(_ bundleID: String) -> NSImage? {
        if let cached = appIcons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        appIcons[bundleID] = icon
        return icon
    }

    /// A small picture of an image, made without decoding all of it.
    static func thumbnail(_ data: Data, maxPixels: Int = 96) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }
}

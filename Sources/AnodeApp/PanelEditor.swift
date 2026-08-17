import AppKit
import PowerKit

/// The editor behind "All metrics (expandable group)": which rows that panel
/// shows, and in what order.
///
/// A sheet rather than another pane, because it edits ONE widget's contents and
/// belongs beside that widget's checkbox — the pane lists what goes in the menu
/// bar, and this is what goes inside one of those things.
///
/// Writes straight to `Settings` on every change, with no OK/Cancel: the panel
/// rebuilds itself on open (`menuNeedsUpdate`), so an edit is visible the next
/// time the menu is pulled down, and a live edit the user can watch beats a
/// modal transaction they have to commit. "Restore defaults" is the undo.
final class PanelEditorController: NSWindowController {

    private let settings: Settings
    private let table = NSTableView()
    /// Working copy: every metric this build offers, in editing order, hidden
    /// rows included and in place.
    private var rows: [(id: String, title: String)] = []

    /// ONE column, each row a stack of [checkbox, label] aligned on centreY.
    ///
    /// Two earlier shapes were wrong in opposite directions, and the pair of
    /// them is why this comment exists:
    ///
    ///   * TWO COLUMNS — a narrow box column beside a label column — cannot be
    ///     aligned at all. Each cell view centres within its OWN column, so the
    ///     box and its text sit on independent baselines and visibly drift.
    ///   * ONE CHECKBOX CARRYING ITS TITLE fixes the alignment (AppKit aligns a
    ///     control against its own text) and breaks the DRAG: the cell view is
    ///     then an `NSControl` spanning the row, `NSControl` swallows
    ///     `mouseDown`, and the table never receives the event that begins a
    ///     drag session. Reordering only worked in the slivers the button did
    ///     not cover.
    ///
    /// A stack view is both: `.centerY` alignment holds the box against its
    /// label by construction, and `NSStackView` is a plain `NSView`, so
    /// mouse-down falls through to the table and the whole row stays draggable.
    /// The cost is that clicking the LABEL no longer toggles — only the box
    /// does — which is the correct trade when the alternative is a list that
    /// cannot be reordered.
    private static let rowColumn = NSUserInterfaceItemIdentifier("row")
    /// Our own drag type — the pasteboard carries the row INDEX, not the id, so
    /// a drag cannot be confused with anything else on the pasteboard.
    private static let dragType = NSPasteboard.PasteboardType("com.anode.panelRow")

    init(settings: Settings = .shared) {
        self.settings = settings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "All metrics (expandable group)"
        super.init(window: window)
        reload()
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    // ── Model ───────────────────────────────────────────────────────────────

    private func reload() {
        let registry = MetricRegistry.shared
        let byID = Dictionary(registry.descriptors().map { ($0.id.rawValue, $0.title) },
                              uniquingKeysWith: { a, _ in a })
        rows = PanelOrder.fullOrder(saved: settings.panelOrder,
                                    available: registry.descriptors().map(\.id))
            // An id this build cannot render has no row to show and no title to
            // put on it. It stays in `panelOrder` untouched (see `commit`), so a
            // module that comes back finds its place waiting.
            .compactMap { id in byID[id].map { (id, $0) } }
    }

    private func isHidden(_ id: String) -> Bool { settings.panelHidden.contains(id) }

    /// Persist the working copy. The saved order carries ids this build cannot
    /// render, preserved at their existing positions — dropping them would let
    /// opening this sheet on a build with a module unloaded quietly delete that
    /// module's rows from the user's arrangement.
    private func commit() {
        let known = Set(rows.map(\.id))
        var out: [String] = []
        var remaining = rows.makeIterator()
        for id in PanelOrder.fullOrder(saved: settings.panelOrder,
                                       available: MetricRegistry.shared
                                        .descriptors().map(\.id)) {
            if known.contains(id) {
                if let next = remaining.next() { out.append(next.id) }
            } else {
                out.append(id)          // unrenderable, but not ours to discard
            }
        }
        settings.panelOrder = out
    }

    // ── Layout ──────────────────────────────────────────────────────────────

    private func buildContent() {
        let column = NSTableColumn(identifier: Self.rowColumn)
        column.width = 300
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 24
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.dragType])

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(wrappingLabelWithString:
            "Drag to reorder. Uncheck to hide a row — it keeps its place here, "
            + "so showing it again puts it back where it was.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let restore = NSButton(title: "Restore Defaults", target: self,
                               action: #selector(restoreDefaults))
        let done = NSButton(title: "Done", target: self, action: #selector(close_))
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [restore, NSView(), done])
        buttons.orientation = .horizontal
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        for v in [scroll, hint, buttons] { content.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        window?.contentView = content
    }

    // ── Actions ─────────────────────────────────────────────────────────────

    @objc private func toggled(_ sender: NSButton) {
        let row = sender.tag
        guard rows.indices.contains(row) else { return }
        let id = rows[row].id
        var hidden = settings.panelHidden
        if sender.state == .on { hidden.removeAll { $0 == id } }
        else if !hidden.contains(id) { hidden.append(id) }
        settings.panelHidden = hidden
    }

    /// Both keys cleared, not rewritten to today's default: an empty
    /// arrangement is how `PanelOrder` knows to speak for itself, so a user who
    /// restores defaults keeps tracking future improvements to them.
    @objc private func restoreDefaults() {
        settings.panelOrder = []
        settings.panelHidden = []
        reload()
        table.reloadData()
    }

    @objc private func close_() {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }

    // ── Test seams ──────────────────────────────────────────────────────────
    //
    // Internal, not private, so the tests can drive the REAL table through the
    // real data-source and delegate methods. The alternative — reimplementing
    // drag arithmetic in the test — would prove only that two copies of the
    // same off-by-one agree with each other.

    var testTable: NSTableView { table }
    var testRowTitles: [String] { rows.map(\.title) }
    static var testDragType: NSPasteboard.PasteboardType { dragType }
    func testCommit() { commit() }
    func testRestoreDefaults() { restoreDefaults() }
}

// ─────────────────────────────────────────────────────────────────────────────

extension PanelEditorController: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation)
        -> NSDragOperation {
        // Between rows only: dropping ON a row would mean "put it inside", and
        // this list has no nesting.
        guard op == .above else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        guard let raw = info.draggingPasteboard.string(forType: Self.dragType),
              let from = Int(raw) else { return false }
        return move(fromRow: from, toGap: row)
    }

    /// The move itself, split from the pasteboard plumbing above so it can be
    /// driven directly — by a drop, and by the tests, through the SAME
    /// arithmetic. (`NSDraggingInfo` is a wide protocol whose stub would be all
    /// transport and no behaviour; the index arithmetic is the part that has
    /// ever been wrong.)
    ///
    /// `gap` is an index in the PRE-move list, so a downward move has to account
    /// for the row that is about to leave from above it.
    @discardableResult
    func move(fromRow from: Int, toGap gap: Int) -> Bool {
        guard rows.indices.contains(from), (0...rows.count).contains(gap) else { return false }
        let to = from < gap ? gap - 1 : gap
        guard to != from else { return false }
        let moved = rows.remove(at: from)
        rows.insert(moved, at: to)
        table.reloadData()
        commit()
        return true
    }
}

extension PanelEditorController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?,
                   row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let entry = rows[row]

        let hidden = isHidden(entry.id)

        let box = NSButton(checkboxWithTitle: "", target: self,
                           action: #selector(toggled))
        box.tag = row
        box.state = hidden ? .off : .on

        let label = NSTextField(labelWithString: entry.title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        // A hidden row is still listed, in place, so the user can see what they
        // turned off and put it back — dimmed to say it is not on the panel.
        label.textColor = hidden ? .tertiaryLabelColor : .labelColor

        let cell = NSStackView(views: [box, label])
        cell.orientation = .horizontal
        cell.alignment = .centerY          // the whole point: one shared baseline
        cell.spacing = 6
        cell.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        return cell
    }
}

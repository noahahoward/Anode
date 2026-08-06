import AppKit
import PowerKit

/// The main window's layout, separated from AppDelegate so the delegate is only
/// lifecycle and the layout is testable and replaceable on its own.
///
///   ┌────────────┬───────────────────────────────────────────┐
///   │ rail       │ process table (takes all vertical slack)  │
///   │            ├───────────────────────────────────────────┤
///   │  Battery   │ ledger bar + legend                       │
///   │  CPU       ├──────────────┬────────────────────────────┤
///   │  Memory    │ glance card  │ history graph              │
///   └────────────┴──────────────┴────────────────────────────┘
///
/// Deliberately no header strip: charge, source and health describe the battery, so
/// they live in the glance card, and process coverage lives with the ledger where it
/// states how much of the draw could be attributed. Only the table grows with the
/// window — a graph that expands at the table's expense is the wrong trade in a view
/// you scan.
final class MainWindowController: NSObject {

    let window: NSWindow
    let table = HoverTableView()
    let sidebar = SidebarView()
    let ledger = LedgerBarView()
    let glance = GlanceCardView()
    let graphContainer = NSView()
    let detailContainer = NSView()

    private let scroll = NSScrollView()
    private var detailWidth: CGFloat = 280
    private var detailShown = false
    private let tableSplit = NSSplitView()

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 640),
            // A normal titlebar rather than fullSizeContentView: the design has a
            // distinct top band with the traffic lights and title, and letting the
            // system draw it means the buttons never collide with our own content.
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init()

        // NSWindow.isReleasedWhenClosed defaults to TRUE for programmatically
        // created windows, so closing one deallocates it while a strong reference
        // still points at the freed memory — the next message is EXC_BAD_ACCESS.
        // A menu bar app outlives its windows by design.
        window.isReleasedWhenClosed = false
        window.title = "BetterStats"
        window.backgroundColor = Palette.background
        window.center()
        window.setFrameAutosaveName("BetterStatsMain")
        window.minSize = NSSize(width: 760, height: 500)

        let content = NSView()
        content.wantsLayer = true

        // ── Rail ────────────────────────────────────────────────────────────
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebar)

        // ── Table ───────────────────────────────────────────────────────────
        table.style = .plain
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.rowSizeStyle = .custom
        table.rowHeight = 22
        table.gridStyleMask = []
        table.headerView = NSTableHeaderView()
        // Not user-resizable: a draggable divider can be pulled clean off the
        // window, and content-sized columns are already the width they should be.
        table.allowsColumnResizing = false
        table.allowsColumnReordering = false
        table.allowsEmptySelection = true
        table.selectionHighlightStyle = .none   // drawn by BetterStatsRowView
        table.intercellSpacing = NSSize(width: 0, height: 0)
        // Spare width goes to the app name, not spread across every column. Spreading
        // pushes the numbers to opposite ends of a wide window, so a row can no longer
        // be read as one line.
        // Slack goes to a trailing spacer column, not to the app name. Growing the
        // name column pushed the numeric columns to the window edge, outside the
        // inset hover pill, so a row no longer read as one line.
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.documentView = table

        detailContainer.isHidden = true
        tableSplit.isVertical = true
        tableSplit.dividerStyle = .thin
        tableSplit.translatesAutoresizingMaskIntoConstraints = false
        tableSplit.addArrangedSubview(scroll)
        tableSplit.addArrangedSubview(detailContainer)
        content.addSubview(tableSplit)

        // ── Ledger ──────────────────────────────────────────────────────────
        ledger.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(ledger)

        // ── Bottom: glance | graph, one continuous surface ──────────────────
        glance.translatesAutoresizingMaskIntoConstraints = false
        graphContainer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(glance)
        content.addSubview(graphContainer)

        let railWidth: CGFloat = 168
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: railWidth),

            tableSplit.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            tableSplit.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tableSplit.topAnchor.constraint(equalTo: content.topAnchor),

            ledger.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 16),
            ledger.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            ledger.topAnchor.constraint(equalTo: tableSplit.bottomAnchor, constant: 11),

            // Fixed-height bottom row: only the table grows.
            glance.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 16),
            glance.widthAnchor.constraint(equalToConstant: 236),
            glance.topAnchor.constraint(equalTo: ledger.bottomAnchor, constant: 14),
            // Equal, not lessThanOrEqual: the graph and the card are one row, so
            // their bottoms have to line up. With an inequality the card floated and
            // the graph sat above the last line of its text.
            glance.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            graphContainer.leadingAnchor.constraint(equalTo: glance.trailingAnchor, constant: 18),
            graphContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            graphContainer.topAnchor.constraint(equalTo: ledger.bottomAnchor, constant: 14),
            // No fixed height: top and bottom already define it, and adding a third
            // constraint over-constrained the row so AppKit silently broke one of them.
            graphContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 118),
            graphContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])

        window.contentView = content
    }

    /// Column set for the active lens. Rebuilding rather than hiding keeps the
    /// header honest — a hidden column still occupies sort state and confuses
    /// keyboard navigation.
    func setColumns(_ columns: [(id: String, title: String, width: CGFloat)]) {
        let sort = table.sortDescriptors.first
        while let c = table.tableColumns.last { table.removeTableColumn(c) }
        for spec in columns {
            let c = NSTableColumn(identifier: .init(spec.id))
            c.title = spec.title
            c.width = spec.width
            c.minWidth = 30
            c.resizingMask = spec.id == "spacer" ? .autoresizingMask : []
            c.sortDescriptorPrototype = NSSortDescriptor(key: spec.id, ascending: false)
            if spec.id != "name" { c.headerCell.alignment = .right }
            table.addTableColumn(c)
        }
        if let sort, columns.contains(where: { $0.id == sort.key }) {
            table.sortDescriptors = [sort]
        }
    }

    func installGraph(_ view: NSView) { install(view, in: graphContainer) }
    func installDetail(_ view: NSView) { install(view, in: detailContainer) }

    /// Pinned with constraints rather than an autoresizing mask: the containers are
    /// Auto Layout driven, so their bounds are still zero at install time and
    /// seeding a frame from a zero rect then autoresizing it produces garbage —
    /// which showed up as a clipped plot with its axis labels off-screen.
    private func install(_ view: NSView, in container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    func setDetailVisible(_ visible: Bool) {
        guard visible != detailShown else { return }
        detailShown = visible
        detailContainer.isHidden = !visible
        tableSplit.adjustSubviews()
        if visible {
            tableSplit.setPosition(max(360, tableSplit.bounds.width - detailWidth), ofDividerAt: 0)
        }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggle() {
        if window.isVisible && NSApp.isActive { window.orderOut(nil) } else { show() }
    }
}

/// Row background. The selection is one continuous pill across the row, and the
/// separator's ENDS are inset by the same radius so the hairline stops exactly where
/// the pill's straight edge begins — a full-width border overhangs the curve at both
/// corners, which is visible the moment a row is selected.
/// Table that knows which row the pointer is over.
///
/// Hover was originally tracked per row view, which is wrong because NSTableView
/// RECYCLES row views: this table reloads every couple of seconds, so a reused view
/// kept its `hovered` flag and painted the highlight on whichever row it became —
/// appearing as a highlight offset from the pointer. The hovered row is an index on
/// the table, and row views only ever ask whether they are it.
final class HoverTableView: NSTableView {

    private(set) var hoveredRow: Int = -1
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.mouseEnteredAndExited, .mouseMoved,
                                         .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        setHovered(row(at: convert(event.locationInWindow, from: nil)))
    }
    override func mouseExited(with event: NSEvent) { setHovered(-1) }

    /// Scrolling under a stationary pointer changes which row is beneath it, and
    /// mouseMoved does not fire for that.
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        setHovered(row(at: convert(event.locationInWindow, from: nil)))
    }

    private func setHovered(_ newRow: Int) {
        guard newRow != hoveredRow else { return }
        let old = hoveredRow
        hoveredRow = newRow
        for r in [old, newRow] where r >= 0 {
            rowView(atRow: r, makeIfNecessary: false)?.needsDisplay = true
        }
    }
}

/// Row background. The selection is one continuous pill across the row, and the
/// separator's ENDS are inset by the same radius so the hairline stops exactly where
/// the pill's straight edge begins — a full-width border overhangs the curve at both
/// corners, which is visible the moment a row is selected.
final class BetterStatsRowView: NSTableRowView {

    /// Geometry shared by selection and hover so the two read as one control at
    /// different strengths rather than two different shapes.
    private var pill: NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1),
                     xRadius: Palette.Radius.row,
                     yRadius: Palette.Radius.row)
    }

    private var isHovered: Bool {
        guard let table = superview as? HoverTableView else { return false }
        let myRow = table.row(for: self)
        return myRow >= 0 && myRow == table.hoveredRow
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        Palette.selection.setFill()
        pill.fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard !isSelected else { return }   // no hairline under a rounded selection
        if isHovered {
            Palette.selection.withAlphaComponent(0.45).setFill()
            pill.fill()
        }
        Palette.lineSoft.setFill()
        NSRect(x: 6 + Palette.Radius.row, y: bounds.maxY - 1,
               width: bounds.width - 12 - Palette.Radius.row * 2, height: 1).fill()
    }

    override var isEmphasized: Bool {
        get { false }   // keep our own colours when the window loses focus
        set {}
    }
}

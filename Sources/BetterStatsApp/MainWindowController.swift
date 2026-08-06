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
    let table = NSTableView()
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
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init()

        // NSWindow.isReleasedWhenClosed defaults to TRUE for programmatically
        // created windows, so closing one deallocates it while a strong reference
        // still points at the freed memory — the next message is EXC_BAD_ACCESS.
        // A menu bar app outlives its windows by design.
        window.isReleasedWhenClosed = false
        window.title = "BetterStats"
        window.titlebarAppearsTransparent = true
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
        table.allowsColumnResizing = true
        table.allowsEmptySelection = true
        table.selectionHighlightStyle = .none   // drawn by BetterStatsRowView
        table.intercellSpacing = NSSize(width: 0, height: 0)
        // Spare width goes to the app name, not spread across every column. Spreading
        // pushes the numbers to opposite ends of a wide window, so a row can no longer
        // be read as one line.
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

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
            tableSplit.topAnchor.constraint(equalTo: content.topAnchor, constant: 38),

            ledger.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 16),
            ledger.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            ledger.topAnchor.constraint(equalTo: tableSplit.bottomAnchor, constant: 11),

            // Fixed-height bottom row: only the table grows.
            glance.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 16),
            glance.widthAnchor.constraint(equalToConstant: 236),
            glance.topAnchor.constraint(equalTo: ledger.bottomAnchor, constant: 14),
            glance.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -14),

            graphContainer.leadingAnchor.constraint(equalTo: glance.trailingAnchor, constant: 18),
            graphContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            graphContainer.topAnchor.constraint(equalTo: ledger.bottomAnchor, constant: 14),
            graphContainer.heightAnchor.constraint(equalToConstant: 132),
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
            c.minWidth = 44
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
final class BetterStatsRowView: NSTableRowView {

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let r = bounds.insetBy(dx: 6, dy: 1)
        Palette.selection.setFill()
        NSBezierPath(roundedRect: r,
                     xRadius: Palette.Radius.row,
                     yRadius: Palette.Radius.row).fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard !isSelected else { return }   // no hairline under a rounded selection
        Palette.lineSoft.setFill()
        NSRect(x: 6 + Palette.Radius.row, y: bounds.maxY - 1,
               width: bounds.width - 12 - Palette.Radius.row * 2, height: 1).fill()
    }

    override var isEmphasized: Bool {
        get { false }   // keep our own colours when the window loses focus
        set {}
    }
}

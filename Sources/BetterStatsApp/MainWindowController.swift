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
    /// Holds a whole-machine pane. Swapped in over the table area; the ledger,
    /// glance card and graph stay put, because they describe the battery and remain
    /// true whichever pane is showing.
    let paneContainer = NSView()

    private let scroll = NSScrollView()
    private var detailWidth: CGFloat = 380
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
        window.delegate = self
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

        paneContainer.translatesAutoresizingMaskIntoConstraints = false
        paneContainer.isHidden = true
        content.addSubview(paneContainer)

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
            tableSplit.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),

            paneContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            paneContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            paneContainer.topAnchor.constraint(equalTo: content.topAnchor),
            paneContainer.bottomAnchor.constraint(equalTo: tableSplit.bottomAnchor),

            ledger.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 16),
            ledger.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            ledger.topAnchor.constraint(equalTo: tableSplit.bottomAnchor, constant: 11),

            // Fixed-height bottom row: only the table grows.
            // The bottom row has a DEFINITE height. Without one the solver is free to
            // satisfy the chain by growing this row instead of the table, which it
            // did — the table and ledger were squeezed to nothing and the window
            // became one giant card and graph.
            glance.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 16),
            glance.widthAnchor.constraint(equalToConstant: 236),
            glance.topAnchor.constraint(equalTo: ledger.bottomAnchor, constant: 14),
            glance.heightAnchor.constraint(equalToConstant: 128),
            glance.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            // Same top and bottom as the card, so the two line up by construction
            // rather than by matching numbers in two places.
            graphContainer.leadingAnchor.constraint(equalTo: glance.trailingAnchor, constant: 18),
            graphContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            graphContainer.topAnchor.constraint(equalTo: glance.topAnchor),
            graphContainer.bottomAnchor.constraint(equalTo: glance.bottomAnchor),
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

    /// Show a whole-machine pane instead of the process table, or nil for the table.
    func showPane(_ view: NSView?) {
        if let view {
            if view.superview !== paneContainer { install(view, in: paneContainer) }
            paneContainer.isHidden = false
            // NOT hidden. Hiding a sibling here blanked the sidebar's rows even
            // though they kept correct frames, non-zero alpha and isHidden=false —
            // a compositing artifact, not a layout one. paneContainer is opaque and
            // sits above the split in z-order, so covering it is enough.
            tableSplit.isHidden = false
            setDetailVisible(false)
            sidebar.redraw()
        } else {
            paneContainer.isHidden = true
            tableSplit.isHidden = false
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
        // Hold the inspector's width and let the table absorb the change, rather than
        // relying on adjustSubviews to guess. Without the holding priority the pane
        // could be given zero width and appear not to open at all.
        tableSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        tableSplit.adjustSubviews()
        if visible {
            let target = max(360, tableSplit.bounds.width - detailWidth)
            tableSplit.setPosition(target, ofDividerAt: 0)
        }
        tableSplit.layoutSubtreeIfNeeded()
    }

    func show() {
        // Back to a normal app before showing: an .accessory app cannot take key
        // focus properly and gets no application menu, so Cmd-Q would be dead.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggle() {
        if window.isVisible && NSApp.isActive { hide() } else { show() }
    }

    /// Put the app back in the menu bar and out of the Dock.
    ///
    /// Closing the window must not end the session: the widgets ARE the app for
    /// most of its life, and they die with the process. But an app with no window
    /// has no business holding a Dock tile and an application menu either, which
    /// is what made closing the window feel like the app was still "open" while
    /// quitting took the widgets with it. `.accessory` is the state that matches
    /// what the app actually is at that moment — a menu bar tool.
    func hide() {
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }
}

extension MainWindowController: NSWindowDelegate {
    /// The red button is a hide, not a quit. Returning false and hiding by hand
    /// keeps the window controller and its whole view tree alive, so reopening is
    /// instant and the table keeps its selection.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
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

    /// Recompute from the pointer's current position. Needed after a reload:
    /// re-sorting moves rows under a stationary cursor, and no mouse event fires for
    /// content shifting beneath it — so the highlight would stick to a stale row or
    /// vanish entirely.
    func refreshHover() {
        guard let window, window.isKeyWindow else { return }
        let inWindow = window.mouseLocationOutsideOfEventStream
        let local = convert(inWindow, from: nil)
        setHovered(bounds.contains(local) ? row(at: local) : -1)
    }

    private func setHovered(_ newRow: Int) {
        guard newRow != hoveredRow else { return }
        let old = hoveredRow
        hoveredRow = newRow
        // Bounds-check against the CURRENT row count. refreshHover runs right after
        // reloadData, so the previous hovered index can be past the end of the new
        // data — and rowView(atRow:) raises rather than returning nil for an
        // out-of-range row. That crashed the app on the first reload after a hover.
        let count = numberOfRows
        for r in [old, newRow] where r >= 0 && r < count {
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
        // NO style guard here. NSTableView propagates its own selectionHighlightStyle
        // to its row views, and the table is set to .none precisely BECAUSE we draw
        // the selection ourselves — so guarding on it made this method return early
        // and the selection never appeared at all.
        Palette.selection.setFill()
        pill.fill()
    }

    /// AppKit only calls drawSelection when it believes the row is selected AND the
    /// style is not .none, so draw it from drawBackground as well.
    private var shouldDrawSelection: Bool { isSelected }

    override func drawBackground(in dirtyRect: NSRect) {
        if shouldDrawSelection {
            Palette.selection.setFill()
            pill.fill()
            return   // no hairline under a rounded selection
        }
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

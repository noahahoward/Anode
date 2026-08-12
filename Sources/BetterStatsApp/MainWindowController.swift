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
    /// Range picker for the history graph. Lives on `content`, NOT inside
    /// graphContainer: install() clears that container's subviews, so anything
    /// parked there would vanish the moment the graph was installed.
    let graphRanges = RangePicker()

    /// The bottom row's height, held so Resources can collapse it. See
    /// `setBottomHidden`.
    private var bottomRowHeight: NSLayoutConstraint!
    /// The card's width, held so it can take the graph's space on Resources.
    private var glanceWidth: NSLayoutConstraint!
    /// The card's trailing edge when it HAS taken that space. Swapped with
    /// `glanceWidth` rather than setting a measured constant, so the card keeps
    /// filling the window as the window is resized.
    private var glanceWide: NSLayoutConstraint!
    /// Where the graph starts. Collapsed to the window's own trailing edge while
    /// hidden: a hidden view still solves its constraints, and leaving this
    /// pinned 18 pt past a full-width card asks the solver for a negative width.
    private var graphLeading: NSLayoutConstraint!
    private var graphLeadingCollapsed: NSLayoutConstraint!

    private let scroll = NSScrollView()
    private var detailWidth: CGFloat = 380
    private var detailShown = false
    private let tableSplit = NSSplitView()

    override init() {
        window = NSWindow(
            // Wider than the old 940. The Processes tab carries twelve columns
            // where the widest lens used to carry five, and the rail gave back 116
            // pt of the difference by becoming icons.
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 660),
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
        window.minSize = NSSize(width: 760, height: 500)
        window.setFrameAutosaveName("BetterStatsMain")


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
        // Twelve columns do not fit a narrow window, and the alternative to
        // scrolling them is squeezing every number until it truncates. The trailing
        // spacer absorbs slack when there IS slack; this is what happens when there
        // is not.
        scroll.hasHorizontalScroller = true
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
        graphRanges.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(graphRanges)

        let railWidth = SidebarView.width
        bottomRowHeight = glance.heightAnchor.constraint(equalToConstant: 128)
        glanceWidth = glance.widthAnchor.constraint(equalToConstant: 236)
        glanceWide = glance.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                                      constant: -16)
        graphLeading = graphContainer.leadingAnchor.constraint(
            equalTo: glance.trailingAnchor, constant: 18)
        graphLeadingCollapsed = graphContainer.leadingAnchor.constraint(
            equalTo: content.trailingAnchor, constant: -16)
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
            glanceWidth,
            glance.topAnchor.constraint(equalTo: ledger.bottomAnchor, constant: 14),
            bottomRowHeight,
            glance.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            // Same top and bottom as the card, so the two line up by construction
            // rather than by matching numbers in two places.
            graphLeading,
            graphContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            graphContainer.topAnchor.constraint(equalTo: glance.topAnchor),
            graphContainer.bottomAnchor.constraint(equalTo: glance.bottomAnchor),

            // Top-right of the plot, where it overlaps only empty headroom.
            graphRanges.trailingAnchor.constraint(equalTo: graphContainer.trailingAnchor,
                                                  constant: -44),
            graphRanges.topAnchor.constraint(equalTo: graphContainer.topAnchor, constant: -3),
        ])

        window.contentView = content
    }

    /// Install the process table's columns.
    ///
    /// Rebuilding rather than hiding keeps the header honest — a hidden column
    /// still occupies sort state and confuses keyboard navigation.
    ///
    /// Everything a column knows comes from its `ProcessColumn`: the title, the
    /// starting width, and the tooltip. A header this narrow cannot explain what
    /// "%/hr" divides by, and `headerToolTip` is the only place that answer fits.
    func setColumns(_ columns: [ProcessColumn]) {
        let sort = table.sortDescriptors.first
        while let c = table.tableColumns.last { table.removeTableColumn(c) }
        for spec in columns {
            let c = NSTableColumn(identifier: .init(spec.id))
            c.headerCell = BetterStatsHeaderCell(textCell: spec.title)
            c.title = spec.title
            c.headerToolTip = spec.tooltip
            c.width = spec.width
            c.minWidth = 34
            c.resizingMask = []
            c.sortDescriptorPrototype = NSSortDescriptor(key: spec.id, ascending: false)
            if spec.id != "name" { c.headerCell.alignment = .right }
            table.addTableColumn(c)
        }
        // Trailing slack absorber, always last. Not part of the column list because
        // it holds no data and must never be sortable.
        let spacer = NSTableColumn(identifier: .init(ProcessColumns.spacerID))
        spacer.headerCell = BetterStatsHeaderCell(textCell: "")
        spacer.title = ""
        spacer.width = 16
        spacer.minWidth = 0
        spacer.resizingMask = .autoresizingMask
        table.addTableColumn(spacer)

        if let sort, columns.contains(where: { $0.id == sort.key }) {
            table.sortDescriptors = [sort]
        }
        refreshSortIndicators()
    }

    /// Mark the sorted column, and unmark every other one.
    ///
    /// Pushed rather than pulled: a header cell has no idea which column it
    /// belongs to (`NSTableHeaderCell` is handed a rect, not an identity), so
    /// asking each cell to work out whether it is the sorted one means reaching
    /// back through the header view to match rects, which is exactly the kind of
    /// geometry guess that breaks when a column is dragged.
    func refreshSortIndicators() {
        let sorted = table.sortDescriptors.first
        for column in table.tableColumns {
            guard let cell = column.headerCell as? BetterStatsHeaderCell else { continue }
            cell.sortIndicator = column.identifier.rawValue == sorted?.key
                ? (sorted?.ascending == true ? .ascending : .descending)
                : .none
        }
        table.headerView?.needsDisplay = true
    }

    /// Drop the graph, and give its width to the card.
    ///
    /// Resources only. That tab draws a graph on every card plus one at the top of
    /// its rail, so a ninth at the bottom of the window is noise.
    ///
    /// The CARD STAYS, and widens to take the space. It is the thing that follows
    /// the rail's selection — click Memory and it says what memory is doing — so
    /// dropping it with the graph would be dropping the answer along with the
    /// duplicate. An earlier version did exactly that, which left the tab with no
    /// bottom at all.
    func setGraphHidden(_ hidden: Bool) {
        guard graphContainer.isHidden != hidden else { return }
        graphContainer.isHidden = hidden
        // NOT the range picker. Two things decide whether it is on screen — this,
        // and whether the subject offers more than one range — and a view with two
        // owners ends up visible because one of them ran last. `retargetBottom`
        // owns it, and it is the only caller of this.
        glanceWidth.isActive = !hidden
        graphLeading.isActive = !hidden
        glanceWide.isActive = hidden
        graphLeadingCollapsed.isActive = hidden
        glance.isWide = hidden
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
        // Enforce the minimum HERE rather than at construction. The autosaved
        // frame is restored asynchronously, after init has returned, so clamping
        // in init reads the placeholder frame and does nothing. Observed live: a
        // saved frame of 260x332 survived relaunches with the layout crushed,
        // because minSize is not applied to a restored frame.
        let f = window.frame
        if f.width < window.minSize.width || f.height < window.minSize.height {
            window.setFrame(NSRect(x: f.minX, y: f.minY,
                                   width: max(f.width, 1180),
                                   height: max(f.height, 660)),
                            display: false)
            window.center()
        }

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
    ///
    /// Unless there is no menu bar to be a tool in: with widgets switched off
    /// `AppPresence` keeps the Dock tile, because it is then the only way back to
    /// the window that still exists.
    func hide() {
        window.orderOut(nil)
        NSApp.setActivationPolicy(
            AppPresence.policyWithWindowHidden(
                widgetsEnabled: Settings.shared.menuBarWidgetsEnabled))
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

/// Table header, on the app's own ground rather than the system's.
///
/// A default NSTableHeaderCell paints the system's control grey, which against a
/// true black window reads as a control someone dropped onto the design rather than
/// part of it — and against twelve columns it is a wide band of the wrong colour.
///
/// The sort marker is drawn HERE rather than left to AppKit, and it has to be.
/// The comment that used to sit on this line claimed the indicator "stays with
/// AppKit" — but `draw(withFrame:in:)` below replaces the superclass's draw and
/// calls only `drawInterior`, and the superclass's draw is what would have called
/// `drawSortIndicator`. So the indicator was never drawn: the table sorted
/// correctly and said nothing about it, which with a bottom section that follows
/// the sort means three panels change subject with nothing on screen naming the
/// subject they changed to.
final class BetterStatsHeaderCell: NSTableHeaderCell {

    /// Which way this column is sorted, or that it is not the sorted one.
    ///
    /// Int-backed on purpose. `NSCell` copies through `NSCopyObject`, which is a
    /// bitwise copy that does not retain Swift references — a stored `String` here
    /// would be a dangling pointer in any copy AppKit decided to make. An enum
    /// with an integer raw value is stored inline and survives that intact.
    enum SortIndicator: Int { case none, ascending, descending }

    var sortIndicator: SortIndicator = .none

    /// Where the chevron was last drawn, for tests — the geometry is the whole
    /// behaviour here, and the alternative is asserting on pixels in a rendered
    /// image, which is how the endpoint-marker bug passed four tests in a row.
    private(set) var lastIndicatorRect: NSRect?

    /// Uppercase, small, and monospaced so twelve headers read as a row of labels
    /// rather than twelve differently-shaped words. Now the shared small-label
    /// voice, which the graph's axis name and the Resources card titles also
    /// wear — three surfaces doing the same job in one typeface.
    static let font = Palette.Font.label()

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        Palette.surfaceAlt.setFill()
        cellFrame.fill()

        // The header view is flipped, so maxY is the bottom edge on screen: this is
        // the rule between the header and the first row.
        Palette.line.setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1,
               width: cellFrame.width, height: 1).fill()
        // A short tick between columns. Full height would draw a grid; twelve
        // full-height rules is exactly the busyness this table is trying to lose.
        Palette.line.withAlphaComponent(0.6).setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 5,
               width: 1, height: max(0, cellFrame.height - 11)).fill()

        drawInterior(withFrame: cellFrame.insetBy(dx: 6, dy: 0), in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        lastIndicatorRect = nil
        let text = stringValue
        guard !text.isEmpty else { return }
        // The sorted column's own title brightens as well as gaining the chevron.
        // One faint label out of twelve turning white is legible from across the
        // window; a 7 pt chevron alone is not.
        let sorted = sortIndicator != .none
        let attrs = Palette.labelAttributes(sorted ? Palette.text : Palette.faint)

        // The estimate mark gets its own run, in the brighter ink.
        //
        // It is the most load-bearing character in the header — it is the whole
        // difference between a measured column and an apportioned one — and set
        // in the same grey as the word beside it at 9.5 pt it was the least
        // visible thing in the row. Brighter, not coloured: a colour would make a
        // claim about what KIND of estimate it is, and the tooltip is where that
        // is said properly.
        let marked = text.hasSuffix("*")
        let base = (marked ? String(text.dropLast()) : text).uppercased() as NSString
        let mark = "*" as NSString
        var markAttrs = attrs
        markAttrs[.foregroundColor] = Palette.dim

        let baseSize = base.size(withAttributes: attrs)
        let markSize: NSSize = marked ? mark.size(withAttributes: markAttrs) : .zero
        let x = alignment == .right
            ? cellFrame.maxX - baseSize.width - markSize.width
            : cellFrame.minX
        let y = cellFrame.midY - baseSize.height / 2
        base.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        if marked {
            mark.draw(at: NSPoint(x: x + baseSize.width, y: y), withAttributes: markAttrs)
        }
        guard sorted else { return }

        // OUTSIDE the title's alignment edge: a right-aligned title is pinned to
        // the cell's right edge and the slack is all on its left, so the chevron
        // goes left of it and stays beside the word instead of floating in the
        // middle of a wide column. The name column aligns the other way and so
        // does its chevron. The column sizer already reserves the width for this.
        // 4 pt of gap plus the chevron's own 8 is exactly the 12 pt the column
        // sizer reserves.
        let gap: CGFloat = 4, size = Palette.Chevron.up.size
        let originX = alignment == .right
            ? x - gap - size.width
            : x + baseSize.width + markSize.width + gap
        let rect = NSRect(x: originX, y: cellFrame.midY - size.height / 2,
                          width: size.width, height: size.height)
        lastIndicatorRect = rect

        // Ascending points up, matching Finder and Explorer both: the apex is the
        // end the small values are at. The header view is flipped and the shared
        // drawer takes that as its default.
        Palette.accent.setStroke()
        Palette.chevron(sortIndicator == .ascending ? .up : .down,
                        at: NSPoint(x: rect.midX, y: rect.midY)).stroke()
    }
}

/// Row background. The selection is one continuous pill across the row, and the
/// separator's ENDS are inset by the same radius so the hairline stops exactly where
/// the pill's straight edge begins — a full-width border overhangs the curve at both
/// corners, which is visible the moment a row is selected.
final class BetterStatsRowView: NSTableRowView {

    /// FULL BLEED, and square. Every ground this row draws is the same rectangle.
    ///
    /// These were inset pills at `Radius.row`, which is the right shape for a
    /// short list in a panel and the wrong one for a dense grid. Twelve columns is
    /// a long way for the eye to hold one row across, and a highlight that stops
    /// 14 pt short at both ends — the inset plus the corner radius — breaks the
    /// only line the eye has to follow. The separators were inset to match, so
    /// they did not reach the edges either.
    ///
    /// So: function over form here, form still wins in the panel lists. The
    /// Sensors rows keep their pills deliberately — that list is one narrow
    /// column inside a bounded panel, where a pill reads as an item and a
    /// full-bleed band would read as a table this app does not have there.
    private var band: NSBezierPath { NSBezierPath(rect: bounds) }

    /// Put this row under the pointer without a pointer.
    ///
    /// A test seam, on the ROW rather than the table, because that is where the
    /// drawing reads it: a row view held outside a real table has no index, so
    /// asking the table which row is hovered can only ever answer "none".
    var hoverForTesting: Bool?

    private var isHovered: Bool {
        if let hoverForTesting { return hoverForTesting }
        guard let table = superview as? HoverTableView else { return false }
        let myRow = table.row(for: self)
        return myRow >= 0 && myRow == table.hoveredRow
    }

    /// The hover wash's strength, eased rather than switched.
    ///
    /// Driven from `drawBackground` rather than from a mouse event, because this
    /// row does not receive one: the TABLE tracks the pointer and rows only ever
    /// ask whether they are the hovered index. So each draw compares where the
    /// wash is against where it should be, and starts easing when they differ.
    /// That also covers the cases a mouse event would miss — rows moving under a
    /// stationary pointer as the table re-sorts, which happens every two seconds.
    private var hover = Eased()

    private func aimHover() {
        let wanted: CGFloat = isHovered ? 1 : 0
        guard hover.target != wanted else { return }
        // A forced state is a question about the RESTING appearance — "what does a
        // hovered row look like" — not about the transition into it. Easing there
        // would make a single rendered frame catch the wash at whatever fraction
        // one tick had reached, which is a value nothing in the app ever shows.
        guard hoverForTesting == nil else { hover.set(wanted); return }
        hover.aim(wanted)
        Motion.shared.start(self) { [weak self] dt in self?.hover.advance(dt) ?? false }
    }

    /// Whether this row gets the alternating tint.
    ///
    /// Zebra striping, in the app's OWN ink rather than macOS's — the system pair
    /// is tuned for a window painted in the control grey and reads as two foreign
    /// colours on a black ground, which is why the detail table's system stripes
    /// were turned off in this same sweep.
    ///
    /// It is there to make a row easier to hit with a pointer across twelve
    /// columns of a wide window, so it is a ground rather than a signal: barely
    /// there, and quieter than either hover or selection, both of which land on
    /// top of it.
    /// Test seam, for the same reason `hoverForTesting` is one: a row held
    /// outside a live table has no index, so it can never be the odd one.
    var alternateForTesting: Bool?

    private var isAlternate: Bool {
        if let alternateForTesting { return alternateForTesting }
        guard let table = superview as? NSTableView else { return false }
        let row = table.row(for: self)
        return row >= 0 && row % 2 == 1
    }

    /// The row's background, in layers: stripe, then selection, then hover.
    ///
    /// STACKING, not replacing. Selection used to win outright and carry a hard
    /// accent edge, on the reasoning that hover and selection needed to be
    /// categorically different marks rather than one mark at two strengths. That
    /// bought a distinction nobody needs — you cannot be looking at a hovered row
    /// and a selected row as separate questions, because the pointer is on one of
    /// them — and it cost the obvious behaviour, where the row under the pointer
    /// is always the brightest thing on screen.
    ///
    /// Layered, "selected" and "selected and under the pointer" are simply two
    /// steps of the same wash, and the brightest row is always the one about to
    /// be clicked.
    private func fillBackground() {
        // The table tracks the pointer, not this row, so each draw is where the
        // hover state is noticed and the ease is started. See `aimHover`.
        aimHover()

        // ONE opaque fill, chosen by state — not a stack of translucent washes.
        //
        // Stacked, each wash TINTED whatever ground the row happened to have, and
        // a tint of two different grounds is two different colours: the same hover
        // read one way on an alternating row and another on a plain one, and the
        // same for selection. Reported as the hover differing with the grey
        // background.
        //
        // Finished colours also make the claim testable. "These two look the same"
        // is a measurable statement about two opaque fills and a vague one about
        // two translucent ones.
        let resting: NSColor? = isAlternate ? Palette.rowAlternate : nil
        let active: NSColor? = isSelected
            ? (hover.value > 0.001 ? Palette.rowSelectedHover : Palette.rowSelected)
            : (hover.value > 0.001 ? Palette.rowHover : nil)

        let shape = band
        guard let active else {
            resting.map { $0.setFill(); shape.fill() }
            return
        }
        // Mid-fade, mix towards it from where this row rests. A selected row
        // already rests at `rowSelected`, so hovering it eases only the last step
        // — which is what keeps the three levels ordered while they move.
        let from = isSelected ? Palette.rowSelected : (resting ?? Palette.background)
        (from.blended(withFraction: hover.value, of: active) ?? active).setFill()
        shape.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // NO style guard here. NSTableView propagates its own selectionHighlightStyle
        // to its row views, and the table is set to .none precisely BECAUSE we draw
        // the selection ourselves — so guarding on it made this method return early
        // and the selection never appeared at all.
        //
        // Nothing is drawn here now: `drawBackground` paints every layer in order,
        // and painting the selection twice would double its wash on a selected row.
    }

    override func drawBackground(in dirtyRect: NSRect) {
        fillBackground()
        // ON EVERY ROW. It used to be suppressed wherever the row had a ground of
        // its own, because a rule across the bottom of a rounded pill cuts its
        // corners off — a correct rule for a shape that no longer exists. With
        // alternating stripes that suppression silently removed the line from
        // every other row, which is half of what "they don't extend" was
        // describing.
        //
        // Edge to edge, for the same reason the grounds are: this is a ledger, and
        // a rule that stops short is not one.
        Palette.lineSoft.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    override var isEmphasized: Bool {
        get { false }   // keep our own colours when the window loses focus
        set {}
    }
}


// ─────────────────────────────────────────────────────────────────────────────

/// Compact range selector for the history graph.
///
/// Drawn by hand rather than built from NSButtons or an NSSegmentedControl.
/// Both of those bring their own vibrancy, corner radius and control-size
/// metrics, which is why the first version read as a system widget dropped onto
/// a black chart instead of part of it. This is one view that paints a pill,
/// fills the selected cell with the app's own accent wash, and uses the same
/// radius token as every other chip in the window.
final class RangePicker: NSView {

    /// Seconds per option. 7 days matches the store's retention, so nothing here
    /// can ask for history that has already been pruned.
    static let options: [(label: String, seconds: TimeInterval)] = [
        ("1H", 3600), ("6H", 6 * 3600), ("24H", 86400), ("7D", 7 * 86400),
    ]

    var onSelect: ((TimeInterval) -> Void)?
    /// Worth showing at all: a chooser with one option is not a chooser. It reads
    /// as a button that does nothing, and its dead width sits on top of the graph
    /// — which is where the click that zoomed a temperature graph into a
    /// historical view landed.
    var isWorthShowing: Bool { shown.count > 1 }

    /// The options actually offered, which is not always all of them.
    ///
    /// Temperatures and fan speeds live only in this session's memory, so a 7D
    /// button on those subjects would promise a week and draw an empty plot. A
    /// range picker that offers what it cannot answer is worse than a shorter one.
    private(set) var shown = options
    private(set) var selectedIndex = 0
    private var hoverIndex: Int?
    private var tracking: NSTrackingArea?

    fileprivate let cellW: CGFloat = 34
    fileprivate let height: CGFloat = 19

    /// Offer exactly these, in the static order. An empty or unknown set falls
    /// back to all of them rather than rendering a picker with no cells.
    func setRanges(_ seconds: [TimeInterval]) {
        let wanted = Set(seconds)
        let next = Self.options.filter { wanted.contains($0.seconds) }
        let resolved = next.isEmpty ? Self.options : next
        // Compared on seconds because the options are tuples, which are not
        // Equatable — and without the guard this invalidates layout on every tick.
        guard resolved.map(\.seconds) != shown.map(\.seconds) else { return }
        shown = resolved
        selectedIndex = min(selectedIndex, shown.count - 1)
        cells = makeCells()
        invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: cellW * CGFloat(shown.count), height: height)
    }
    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    private func index(at p: NSPoint) -> Int? {
        guard bounds.contains(p) else { return nil }
        let i = Int(p.x / cellW)
        return (i >= 0 && i < shown.count) ? i : nil
    }

    override func mouseMoved(with e: NSEvent) {
        let i = index(at: convert(e.locationInWindow, from: nil))
        if i != hoverIndex { hoverIndex = i; needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) { hoverIndex = nil; needsDisplay = true }

    override func mouseDown(with e: NSEvent) {
        guard let i = index(at: convert(e.locationInWindow, from: nil)) else { return }
        selectedIndex = i
        needsDisplay = true
        onSelect?(shown[i].seconds)
    }

    /// Reflect a range set from elsewhere without re-firing onSelect.
    func select(seconds: TimeInterval) {
        if let i = shown.firstIndex(where: { $0.seconds == seconds }) {
            selectedIndex = i
            needsDisplay = true
        }
    }

    // A hand-drawn control is invisible to VoiceOver and to any automation
    // unless it says what it is. The rail already does this; drawing this picker
    // by hand must not quietly cost what the buttons it replaced had for free.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .radioGroup }
    override func accessibilityLabel() -> String? { "Graph time range" }
    override func accessibilityChildren() -> [Any]? { cells }
    override func accessibilityValue() -> Any? { shown[selectedIndex].label }

    /// One proxy element per cell, so each range is individually focusable and
    /// pressable rather than the whole strip being one opaque blob.
    /// Rebuilt whenever the offered set changes, NOT built once from the static
    /// list. VoiceOver would otherwise announce four ranges on a subject that
    /// draws one, and each cell's index would address the wrong option the moment
    /// the offered set was anything but a prefix of the full one.
    private lazy var cells: [NSAccessibilityElement] = makeCells()

    private func makeCells() -> [NSAccessibilityElement] {
        shown.enumerated().map { i, opt in
            let e = RangeCell(picker: self, index: i)
            e.setAccessibilityRole(.radioButton)
            e.setAccessibilityLabel(opt.label)
            e.setAccessibilityParent(self)
            return e
        }
    }

    final class RangeCell: NSAccessibilityElement {
        weak var picker: RangePicker?
        let index: Int
        init(picker: RangePicker, index: Int) {
            self.picker = picker
            self.index = index
            super.init()
        }
        override func accessibilityValue() -> Any? { picker?.selectedIndex == index }
        override func accessibilityPerformPress() -> Bool {
            guard let p = picker else { return false }
            p.selectedIndex = index
            p.needsDisplay = true
            p.onSelect?(RangePicker.options[index].seconds)
            return true
        }
        override func accessibilityFrame() -> NSRect {
            guard let p = picker, let win = p.window else { return .zero }
            let local = NSRect(x: CGFloat(index) * p.cellW, y: 0,
                               width: p.cellW, height: p.height)
            return win.convertToScreen(p.convert(local, to: nil))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: 0, width: cellW * CGFloat(shown.count), height: height)
        let radius = Palette.Radius.chip

        // A faint trough, so the control reads as one object rather than four
        // loose words floating over the plot.
        Palette.surfaceAlt.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        for (i, opt) in shown.enumerated() {
            let cell = NSRect(x: CGFloat(i) * cellW, y: 0, width: cellW, height: height)
            if i == selectedIndex {
                Palette.accent.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: cell.insetBy(dx: 1.5, dy: 1.5),
                             xRadius: radius - 1, yRadius: radius - 1).fill()
            } else if i == hoverIndex {
                Palette.text.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: cell.insetBy(dx: 1.5, dy: 1.5),
                             xRadius: radius - 1, yRadius: radius - 1).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Palette.Font.mono(9.5, i == selectedIndex ? .bold : .medium),
                .foregroundColor: i == selectedIndex ? Palette.accent : Palette.faint,
            ]
            let str = opt.label as NSString
            let sz = str.size(withAttributes: attrs)
            str.draw(at: NSPoint(x: cell.midX - sz.width / 2,
                                 y: cell.midY - sz.height / 2), withAttributes: attrs)
        }
    }
}

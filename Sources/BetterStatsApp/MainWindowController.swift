import AppKit
import PowerKit

/// The main window's layout, separated from AppDelegate so the delegate is only
/// lifecycle and the layout is testable/replaceable on its own.
///
/// Structure — an Activity-Monitor-shaped window, which is the whole point of the
/// project. Stats (the app being replaced) renders into menu-bar-sized NSViews and
/// its "window" is a non-resizable dropdown, so none of its UI could be reused.
///
///   ┌──────────────────────────────────────────────┐
///   │ header: battery, health, coverage            │
///   ├───────────────────────────┬──────────────────┤
///   │ app table (sortable)      │ detail pane      │  ← detail appears on selection
///   ├───────────────────────────┴──────────────────┤
///   │ history graph                                │
///   ├──────────────────────────────────────────────┤
///   │ ledger: buckets + measured total + residual  │
///   └──────────────────────────────────────────────┘
///
/// The graph and detail areas are containers rather than concrete types so the
/// window can be built and shipped before those views exist, and so either can be
/// swapped without touching layout code.
public final class MainWindowController: NSObject {

    public let window: NSWindow
    public let table = NSTableView()
    public let header = NSTextField(labelWithString: "starting…")
    public let ledger = NSTextField(labelWithString: "")
    /// Host for HistoryGraphView. Empty until a graph is installed.
    public let graphContainer = NSView()
    /// Host for AppDetailView. Hidden until a row is selected.
    public let detailContainer = NSView()

    private let splitH = NSSplitView()
    private var detailWidth: CGFloat = 260
    private var detailShown = false

    public override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init()

        // CRITICAL. NSWindow.isReleasedWhenClosed defaults to TRUE for windows
        // created programmatically with initWithContentRect. Closing the window
        // then deallocates it while our strong reference still points at the freed
        // memory, and the next message to it — e.g. clicking the menu bar item to
        // reopen — is EXC_BAD_ACCESS. This crashed the shipped build:
        //   objc_msgSend / AppDelegate.toggleWindow() / -[NSStatusBarButtonCell _sendActionFrom:]
        // It reads as a random crash because it needs close-then-reopen to trigger.
        // A menu bar app outlives its windows by design, so this must be false.
        window.isReleasedWhenClosed = false

        window.title = "BetterStats — Battery"
        window.center()
        window.setFrameAutosaveName("BetterStatsMain")
        window.minSize = NSSize(width: 640, height: 420)

        let content = NSView()
        content.autoresizingMask = [.width, .height]

        // ── Header ───────────────────────────────────────────────────────────
        header.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingTail
        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)

        // ── Table ────────────────────────────────────────────────────────────
        table.usesAlternatingRowBackgroundColors = true
        table.rowSizeStyle = .small
        table.allowsColumnResizing = true
        table.allowsEmptySelection = true
        table.style = .inset

        func column(_ id: String, _ title: String, _ width: CGFloat, rightAligned: Bool) {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            c.minWidth = 48
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: false)
            if rightAligned { c.headerCell.alignment = .right }
            table.addTableColumn(c)
        }
        column("name", "App", 240, rightAligned: false)
        column("pctHr", "%/hr", 78, rightAligned: true)
        // Populated once HistoryStore is wired; shows "—" until the window has data.
        column("window", "10 hr power", 96, rightAligned: true)
        column("cost", "Runtime cost", 104, rightAligned: true)
        column("procs", "Procs", 60, rightAligned: true)
        column("kind", "Kind", 70, rightAligned: false)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.documentView = table
        scroll.autohidesScrollers = true

        // ── Split: table | detail ────────────────────────────────────────────
        splitH.isVertical = true
        splitH.dividerStyle = .thin
        splitH.translatesAutoresizingMaskIntoConstraints = false
        splitH.addArrangedSubview(scroll)
        detailContainer.isHidden = true
        splitH.addArrangedSubview(detailContainer)
        content.addSubview(splitH)

        // ── Graph ────────────────────────────────────────────────────────────
        graphContainer.translatesAutoresizingMaskIntoConstraints = false
        graphContainer.wantsLayer = true
        content.addSubview(graphContainer)

        // ── Ledger ───────────────────────────────────────────────────────────
        ledger.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        ledger.maximumNumberOfLines = 3
        ledger.lineBreakMode = .byTruncatingTail
        ledger.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(ledger)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),

            splitH.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            splitH.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            splitH.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),

            graphContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            graphContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            graphContainer.topAnchor.constraint(equalTo: splitH.bottomAnchor, constant: 8),
            graphContainer.heightAnchor.constraint(equalToConstant: 96),

            ledger.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            ledger.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            ledger.topAnchor.constraint(equalTo: graphContainer.bottomAnchor, constant: 8),
            ledger.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])

        window.contentView = content
    }

    /// Installs a view into the graph area. Kept generic so the window does not need
    /// to know the graph type at compile time.
    ///
    /// Pinned with constraints rather than an autoresizing mask. The containers are
    /// themselves Auto Layout driven, so at install time their bounds are still zero;
    /// seeding a subview's frame from a zero rect and then letting the autoresizing
    /// mask scale it produces a garbage frame — which showed up as a clipped plot
    /// with its y-axis labels off-screen.
    public func installGraph(_ view: NSView) {
        install(view, in: graphContainer)
    }

    public func installDetail(_ view: NSView) {
        install(view, in: detailContainer)
    }

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

    /// Show/hide the detail pane. Animating the split rather than rebuilding it keeps
    /// the table's scroll position and selection intact, which matters because the
    /// table reloads every couple of seconds underneath the user.
    public func setDetailVisible(_ visible: Bool) {
        guard visible != detailShown else { return }
        detailShown = visible
        detailContainer.isHidden = !visible
        splitH.adjustSubviews()
        if visible {
            let total = splitH.bounds.width
            splitH.setPosition(max(320, total - detailWidth), ofDividerAt: 0)
        }
    }

    public func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func toggle() {
        if window.isVisible && NSApp.isActive {
            window.orderOut(nil)
        } else {
            show()
        }
    }
}

import AppKit
import PowerKit

// BetterStats — milestone 1.
//
// One sampling loop feeds everything: the table, the history graph, the ledger,
// the metric registry (and through it the menu bar widgets), and the SQLite
// history that backs the "10 hr power" column.

final class Row: NSObject {
    let name: String
    let procs: Int
    let pctHr: Double
    /// Percent of battery consumed over the trailing on-battery window. nil until
    /// the history store has data for this app — shown as "—", never as 0, because
    /// "no data yet" and "used nothing" are different claims.
    let windowPct: Double?
    /// Minutes of runtime quitting this would buy back. nil outside the band where
    /// the counterfactual is meaningful.
    let costMin: Double?
    let isApp: Bool
    let app: AppDrain

    init(app: AppDrain, windowPct: Double?, costMin: Double?) {
        self.name = app.name
        self.procs = app.processCount
        self.pctHr = app.percentPerHour
        self.windowPct = windowPct
        self.costMin = costMin
        self.isApp = app.isApp
        self.app = app
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {

    var main: MainWindowController!
    var graph: HistoryGraphView!
    var inspector: InspectorView!
    var widgets: MenuBarWidgetController!

    var monitor: PowerMonitor?
    var store: HistoryStore?
    let drain = DrainRateEstimator()
    /// CPU, memory, GPU, network and sensors. Cheap enough to run even while
    /// hidden — unlike the per-process sweep, these are a handful of syscalls.
    let sysMetrics = SystemMetrics()

    var rows: [Row] = []
    var sortKey = "pctHr"
    var ascending = false
    var timer: Timer?

    /// In-memory graph history. The store owns durable history; this is just the
    /// last hour at tick resolution for drawing.
    var totalSeries: [HistoryGraphView.Point] = []
    let graphSpan: TimeInterval = 3600

    var lastSnapshot: PowerMonitor.Snapshot?
    /// Active lens. Drives which columns the table shows and what each row reports.
    var lens: SidebarView.Lens = .battery
    /// The SELECTED APP, held by identity rather than by row index.
    ///
    /// Rows re-sort every couple of seconds because they are sorted on a live value,
    /// so an index means nothing between refreshes — reading the selection back by
    /// index made the inspector jump to whatever app had moved into that position.
    var selectedAppName: String?
    /// Set while restoring selection programmatically, so the restore is not mistaken
    /// for the user picking a different row.
    var isRestoringSelection = false
    /// When the window is closed the app is menu-bar-only, and the expensive
    /// per-process sweep populates a table nobody is looking at. Full ticks then
    /// drop to this cadence purely so the 10 hr power history keeps accruing.
    var lastFullTick = Date.distantPast
    let backgroundFullInterval: TimeInterval = 60
    var windowPercents: [String: Double] = [:]
    var lastWindowQuery = Date.distantPast

    func applicationDidFinishLaunching(_ note: Notification) {
        monitor = PowerMonitor()
        store = HistoryStore()

        buildMenu()

        main = MainWindowController()
        main.table.dataSource = self
        main.table.delegate = self
        main.table.sortDescriptors = [NSSortDescriptor(key: "pctHr", ascending: false)]
        main.table.target = self
        main.table.action = #selector(tableClicked)

        main.setColumns([
            ("name", "Application", 240), ("pctHr", "%/hr", 82),
            ("window", "10 hr power", 96), ("cost", "Runtime cost", 104), ("procs", "Procs", 62),
        ])
        main.sidebar.onSelect = { [weak self] lens in self?.select(lens) }
        main.table.rowHeight = 22

        graph = HistoryGraphView(frame: .zero)
        graph.yAxisLabel = "%/hr"
        graph.showsGrid = false
        main.installGraph(graph)

        inspector = InspectorView(frame: .zero)
        inspector.onClose = { [weak self] in
            self?.selectedAppName = nil
            self?.main.table.deselectAll(nil)
            self?.main.setDetailVisible(false)
        }
        main.installDetail(inspector)

        // Menu bar widgets bind to metric IDs, so any metric the app ever gains is
        // automatically available to every widget with no new widget code.
        widgets = MenuBarWidgetController(onClick: { [weak self] in self?.main.toggle() })
        PreferencesWindowController.metricProvider = {
            var choices = MetricRegistry.shared.descriptors()
                .map { MetricChoice(id: $0.id.rawValue, label: $0.title) }
            // The group widget binds to no single metric, so it has no descriptor —
            // it still has to be offerable in the picker.
            choices.append(MetricChoice(id: MetricID.groupPlaceholder.rawValue,
                                        label: "All metrics (expandable group)"))
            return choices
        }
        PreferencesWindowController.currentWidgetIDs = { [weak self] in
            self?.widgets.configs.filter(\.enabled).map(\.metricID) ?? []
        }
        PreferencesWindowController.onWidgetsChanged = { [weak self] ids in
            guard let self else { return }
            // Keep each metric's existing render style; only membership changes here.
            let byID = Dictionary(self.widgets.configs.map { ($0.metricID, $0) },
                                  uniquingKeysWith: { a, _ in a })
            self.widgets.setConfigs(ids.map { id in
                byID[id] ?? WidgetConfig(
                    metricID: id,
                    style: id == MetricID.groupPlaceholder.rawValue ? .group : .textWithLabel)
            })
        }

        main.show()

        monitor?.tick()   // prime; the first tick has no interval to diff against
        restartTimer()

        // React to a changed sample interval without needing a relaunch.
        _ = Settings.shared.observe(Settings.Key.sampleInterval) { [weak self] in
            DispatchQueue.main.async { self?.restartTimer() }
        }
    }

    func restartTimer() {
        timer?.invalidate()
        let interval = Settings.shared.sampleInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        guard let m = monitor else { return }
        // Read visibility on the main thread; AppKit state is not thread-safe.
        let visible = main.window.isVisible
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let wantFull = visible
                || Date().timeIntervalSince(self.lastFullTick) >= self.backgroundFullInterval
            guard let snap = m.tick(full: wantFull) else { return }
            if wantFull { self.lastFullTick = Date() }

            // Sensor discovery walks thousands of SMC keys, so only pay for it when
            // something is actually displaying a temperature or fan speed.
            let sysSnap = self.sysMetrics.sample(includeSensors: visible || self.needsSensors)
            MetricRegistry.shared.update(system: sysSnap)

            // Durable history and the observed-drain estimate both belong off the
            // main thread: one touches SQLite, the other only does arithmetic but
            // there is no reason to make the UI wait for either.
            let onBattery = !(snap.state?.onAC ?? true)
            // Only full ticks carry per-app energy, and writing an interval row with
            // no apps would add WAL churn for nothing. At 2 s with ~30 apps this was
            // driving ~20 KB/s of write-ahead log.
            if wantFull {
                self.store?.record(apps: snap.apps,
                                   measured_W: snap.measured_W,
                                   attributed_W: snap.attributed_W,
                                   residual_W: snap.residual_W,
                                   onBattery: onBattery,
                                   interval: snap.interval)
            }
            if let st = snap.state {
                self.drain.record(state: st, scale: snap.scale,
                                  powerBased_pctHr: snap.smoothed_pctHr)
            }

            // The window query walks history, so it is not worth doing every tick.
            var pcts: [String: Double]? = nil
            if visible, Date().timeIntervalSince(self.lastWindowQuery) > 20, let store = self.store {
                let hours = Settings.shared.powerWindowHours
                let rowsW = store.windowPower(hours: hours,
                                              joulesPerPercent: snap.scale.joulesPerPercent)
                pcts = Dictionary(rowsW.map { ($0.name, $0.percentOfBattery) },
                                  uniquingKeysWith: { a, b in a + b })
            }

            DispatchQueue.main.async {
                if let p = pcts { self.windowPercents = p; self.lastWindowQuery = Date() }
                // Hidden: refresh only the menu bar. Reloading a table, re-sorting
                // rows and redrawing the graph for an off-screen window is pure cost.
                if visible {
                    self.apply(snap)
                } else {
                    MetricRegistry.shared.update(with: snap)
                    self.widgets.refresh()
                }
            }
        }
    }

    func apply(_ s: PowerMonitor.Snapshot) {
        lastSnapshot = s

        // Feed the registry first so the widgets and any UI reading metrics see
        // this tick's values rather than the previous one.
        MetricRegistry.shared.update(with: s)
        widgets.refresh()

        let showDaemons = Settings.shared.showDaemons
        let floor = Settings.shared.minimumDisplayPercentPerHour
        rows = s.apps
            .filter { showDaemons || $0.isApp }
            .filter { row in
                if row.isApp { return true }
                switch self.lens {
                case .cpu:    return row.cpuPercent >= 0.05
                case .memory: return row.memoryBytes > 0
                case .disk:   return row.diskBytesPerSec >= 1
                default:      return row.percentPerHour >= floor
                }
            }
            .map { app in
                Row(app: app,
                    windowPct: windowPercents[app.name],
                    costMin: s.runtimeCost_min(appWatts: app.watts))
            }
        sortRows()

        main.table.reloadData()
        autosizeColumns()

        // Re-find the selected APP by name. If it is gone (quit, or fell below the
        // display floor) the selection is dropped rather than silently transferred
        // to whichever app inherited its row.
        if let name = selectedAppName, let idx = rows.firstIndex(where: { $0.name == name }) {
            isRestoringSelection = true
            main.table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            isRestoringSelection = false
        } else if selectedAppName != nil {
            main.table.deselectAll(nil)
        }
        updateDetail()

        // Rows moved under a stationary pointer, so recompute what is hovered —
        // mouseMoved does not fire for content shifting beneath the cursor.
        main.table.refreshHover()

        updateLedger(s)
        updateGraph(s)
    }

    func updateLedger(_ s: PowerMonitor.Snapshot) {
        main.ledger.model = LedgerBarView.Model(
            apps_pctHr: s.attributed_pctHr,
            gpu_pctHr: s.gpu_pctHr ?? 0,
            unattributed_pctHr: s.residual_pctHr ?? 0,
            total_pctHr: s.smoothed_pctHr,
            source: s.smcTotal_W != nil
                ? "PSTR" + (s.smcGain.map { String(format: " ×%.2f", $0) } ?? "")
                : (s.measured_W != nil ? "gas gauge" : "estimating"),
            readable: s.readable,
            attempted: s.attempted,
            overflow: s.hasAttributionOverflow)

        main.glance.model = GlanceCardView.model(from: s, drain: drain.estimate())
        main.sidebar.refreshValues()
    }

    func updateGraph(_ s: PowerMonitor.Snapshot) {
        let now = Date()
        totalSeries.append(.init(time: now, value: s.smoothed_pctHr))
        let cutoff = now.addingTimeInterval(-graphSpan)
        totalSeries.removeAll { $0.time < cutoff }

        // One series: total drain. The attributed-versus-unaccounted split already
        // has a home in the ledger bar directly above, and drawing it twice turned a
        // glanceable trend into something you had to decode.
        graph.series = [
            .init(name: "total", color: Palette.accent, points: totalSeries, filled: true)
        ]
    }

    func updateDetail() {
        // Resolve by NAME, never by the current row index.
        guard let name = selectedAppName,
              let row = rows.first(where: { $0.name == name }),
              let snap = lastSnapshot else {
            main.setDetailVisible(false)
            return
        }
        inspector.model = InspectorView.model(app: row.app, snapshot: snap, lens: lens)
        main.setDetailVisible(true)
    }

    @objc func tableClicked() {}   // selection change does the work

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRestoringSelection else { return }
        let sel = main.table.selectedRow
        selectedAppName = (sel >= 0 && sel < rows.count) ? rows[sel].name : nil
        updateDetail()
    }

    func sortRows() {
        let asc = ascending
        rows.sort { a, b in
            let r: Bool
            switch sortKey {
            case "name":   r = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case "window": r = (a.windowPct ?? -1) < (b.windowPct ?? -1)
            case "cost":   r = (a.costMin ?? -1) < (b.costMin ?? -1)
            case "cpu":    r = a.app.cpuPercent < b.app.cpuPercent
            case "mem":    r = a.app.memoryBytes < b.app.memoryBytes
            case "disk":   r = a.app.diskBytesPerSec < b.app.diskBytesPerSec
            case "procs":  r = a.procs < b.procs
            case "kind":   r = (a.isApp ? 1 : 0) < (b.isApp ? 1 : 0)
            default:       r = a.pctHr < b.pctHr
            }
            return asc ? r : !r
        }
    }

    // ── Menu ────────────────────────────────────────────────────────────────
    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About BetterStats", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openPrefs), keyEquivalent: ",")
        prefs.target = self
        appMenu.addItem(prefs)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit BetterStats", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        NSApp.mainMenu = main
    }

    @objc func openPrefs() { PreferencesWindowController.shared.show() }

    /// Lens switch. Only Battery has its columns implemented so far; the rest keep
    /// the current table rather than showing an empty one, and are wired as their
    /// data lands.
    func select(_ lens: SidebarView.Lens) {
        // Whole-machine entries have no per-process data, so they keep the current
        // table rather than showing an empty or invented one. Their panes land later.
        guard lens.isPerProcess else { return }
        self.lens = lens
        main.setColumns(Self.columns(for: lens))
        // Set the descriptor explicitly. setColumns restores the previous one when
        // its column still exists, and %/hr exists in every lens — so switching to
        // CPU kept sorting by battery drain, which is not what the CPU lens is for.
        sortKey = Self.defaultSort(for: lens)
        ascending = false
        main.table.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: false)]
        sortRows()
        main.table.reloadData()
        autosizeColumns()
        updateDetail()
    }

    /// Every lens keeps the app column and swaps the measures. All four of these
    /// come from the same `proc_pid_rusage` call already made once per process per
    /// sweep, so switching costs nothing beyond a redraw.
    static func columns(for lens: SidebarView.Lens) -> [(id: String, title: String, width: CGFloat)] {
        switch lens {
        case .battery:
            return [("name", "Application", 300), ("pctHr", "%/hr", 84),
                    ("window", "10 hr power", 100), ("cost", "Runtime cost", 108),
                    ("procs", "Procs", 64), ("spacer", "", 20)]
        case .cpu:
            return [("name", "Application", 300), ("cpu", "% CPU", 84),
                    ("pctHr", "%/hr", 84), ("procs", "Procs", 64), ("spacer", "", 20)]
        case .memory:
            return [("name", "Application", 300), ("mem", "Memory", 100),
                    ("pctHr", "%/hr", 84), ("procs", "Procs", 64), ("spacer", "", 20)]
        case .disk:
            return [("name", "Application", 300), ("disk", "Disk", 100),
                    ("pctHr", "%/hr", 84), ("procs", "Procs", 64), ("spacer", "", 20)]
        case .gpu:
            return [("name", "Application", 300), ("pctHr", "%/hr", 84),
                    ("procs", "Procs", 64), ("spacer", "", 20)]
        default:
            return Self.columns(for: .battery)
        }
    }

    static func defaultSort(for lens: SidebarView.Lens) -> String {
        switch lens {
        case .cpu: return "cpu"
        case .memory: return "mem"
        case .disk: return "disk"
        default: return "pctHr"
        }
    }

    /// True when a menu bar widget is bound to a sensor metric, so the sampler
    /// knows whether the SMC read is worth doing while the window is closed.
    var needsSensors: Bool {
        let sensorIDs: Set<String> = [
            MetricID.cpuTemperature.rawValue,
            MetricID.gpuTemperature.rawValue,
            MetricID.fanSpeed.rawValue,
        ]
        return widgets.configs.contains { $0.enabled && sensorIDs.contains($0.metricID) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    /// Closing the window leaves the app alive in the menu bar, so activating it
    /// again — Dock icon, Finder, ⌘-Tab — must bring the window back. Without this
    /// the app appears to launch and do nothing, because AppKit does not reopen a
    /// window it did not create from a nib.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { main.show() }
        return true
    }

    // ── Table ───────────────────────────────────────────────────────────────
    func tableView(_ tv: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        BetterStatsRowView()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tv: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        guard let d = tv.sortDescriptors.first, let k = d.key else { return }
        sortKey = k
        ascending = d.ascending
        sortRows()
        tv.reloadData()
    }

    /// Single source of truth for what a cell says. The column sizer measures the
    /// same strings the renderer draws — deriving them twice is how a column ends up
    /// one character too narrow.
    func cellText(_ r: Row, _ id: String) -> (text: String, dim: Bool) {
        switch id {
        case "name":
            return (r.name, false)
        case "pctHr":
            return (r.pctHr < 0.01 ? "<0.01" : String(format: "%.2f", r.pctHr), r.pctHr < 0.01)
        case "window":
            // "—" not "0.00": no recorded on-battery history is not zero usage.
            return (r.windowPct.map { String(format: "%.2f%%", $0) } ?? "—", r.windowPct == nil)
        case "cost":
            return (r.costMin.map { $0 >= 60
                ? String(format: "%dh %02dm", Int($0 / 60), Int($0) % 60)
                : String(format: "%.0f min", $0) } ?? "—", r.costMin == nil)
        case "cpu":
            // Percent of one core, Activity Monitor's convention: a busy 4-thread
            // process reads 400%.
            return (r.app.cpuPercent < 0.05 ? "—" : String(format: "%.1f%%", r.app.cpuPercent),
                    r.app.cpuPercent < 0.05)
        case "mem":
            return (r.app.memoryBytes == 0 ? "—" : MetricUnit.bytes.format(Double(r.app.memoryBytes)),
                    r.app.memoryBytes == 0)
        case "disk":
            return (r.app.diskBytesPerSec < 1
                        ? "—" : MetricUnit.bytesPerSecond.format(r.app.diskBytesPerSec),
                    r.app.diskBytesPerSec < 1)
        case "procs":
            return (r.procs > 1 ? "\(r.procs)" : "—", true)
        default:
            return ("", true)
        }
    }

    private func font(for id: String, isApp: Bool) -> NSFont {
        id == "name" ? Palette.Font.sans(11.5, isApp ? .semibold : .regular)
                     : Palette.Font.mono(11)
    }

    /// Size every column to its widest cell. Columns are not user-resizable — a
    /// draggable divider can be pulled clean off the window, and there is nothing to
    /// gain from a hand-set width when the content dictates the right one.
    ///
    /// Widths only ever GROW within a lens. Shrinking them as values change would
    /// make the whole table twitch sideways every two seconds while a number drops a
    /// digit, which is far more distracting than a few points of slack.
    func autosizeColumns() {
        for column in main.table.tableColumns {
            let id = column.identifier.rawValue
            guard id != "spacer" else { continue }

            let headerFont = NSFont.systemFont(ofSize: 11, weight: .medium)
            var widest = (column.title as NSString)
                .size(withAttributes: [.font: headerFont]).width

            for r in rows {
                let (text, _) = cellText(r, id)
                let w = (text as NSString)
                    .size(withAttributes: [.font: font(for: id, isApp: r.isApp)]).width
                widest = max(widest, w)
            }

            let target = ceil(widest) + (id == "name" ? 26 : 20)
            if target > column.width + 1 { column.width = target }
        }
    }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count, let id = col?.identifier.rawValue else { return nil }
        if id == "spacer" { return NSView() }
        let r = rows[row]
        let (text, dim) = cellText(r, id)

        let label = NSTextField(labelWithString: text)
        label.font = font(for: id, isApp: r.isApp)
        label.alignment = id == "name" ? .left : .right
        label.lineBreakMode = .byTruncatingTail
        label.textColor = dim ? Palette.dim : Palette.text
        label.translatesAutoresizingMaskIntoConstraints = false

        // A bare NSTextField is pinned to the top of its cell, so every row read as
        // sitting high against its own separator. Centring it is the fix.
        let cell = NSTableCellView()
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor,
                                           constant: id == "name" ? 10 : 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

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
    var detail: AppDetailView!
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
    var appsSeries: [HistoryGraphView.Point] = []
    let graphSpan: TimeInterval = 3600

    var lastSnapshot: PowerMonitor.Snapshot?
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

        graph = HistoryGraphView(frame: .zero)
        graph.yAxisLabel = "%/hr"
        main.installGraph(graph)

        detail = AppDetailView(frame: .zero)
        main.installDetail(detail)

        // Menu bar widgets bind to metric IDs, so any metric the app ever gains is
        // automatically available to every widget with no new widget code.
        widgets = MenuBarWidgetController(onClick: { [weak self] in self?.main.toggle() })
        if widgets.configs.isEmpty {
            // First-run defaults: the two battery numbers you actually watch, plus
            // the group so everything else is one click away without claiming
            // menu bar width up front.
            widgets.setConfigs([
                WidgetConfig(metricID: MetricID.batteryDrain.rawValue, style: .textWithLabel),
                WidgetConfig(metricID: MetricID.cpuUsage.rawValue, style: .textWithLabel),
                WidgetConfig(metricID: MetricID.memoryUsage.rawValue, style: .textWithLabel),
                WidgetConfig(metricID: MetricID.groupPlaceholder.rawValue, style: .group),
            ])
        }
        PreferencesWindowController.metricProvider = {
            MetricRegistry.shared.descriptors().map { MetricChoice(id: $0.id.rawValue, label: $0.title) }
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
            .filter { $0.percentPerHour >= floor || $0.isApp }
            .map { app in
                Row(app: app,
                    windowPct: windowPercents[app.name],
                    costMin: s.runtimeCost_min(appWatts: app.watts))
            }
        sortRows()

        // Preserve selection across the reload — the table refreshes under the
        // user every couple of seconds and losing their row would make the detail
        // pane useless.
        let selectedName = main.table.selectedRow >= 0 && main.table.selectedRow < rows.count
            ? rows[main.table.selectedRow].name : nil
        main.table.reloadData()
        if let name = selectedName, let idx = rows.firstIndex(where: { $0.name == name }) {
            main.table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            updateDetail()
        }

        updateHeader(s)
        updateLedger(s)
        updateGraph(s)
    }

    func updateHeader(_ s: PowerMonitor.Snapshot) {
        let charge = s.state.map { "\($0.percent)%\($0.onAC ? " (AC)" : "")" } ?? "—"
        let est = drain.estimate()
        let obs = est.map { e in
            String(format: "  ·  observed %.2f %%/hr (%@, %.0f%% conf)",
                   e.percentPerHour, e.source.rawValue, e.confidence * 100)
        } ?? ""
        main.header.stringValue = String(
            format: "battery %@  ·  health %.0f%%  ·  1%% = %.0f J  ·  %d of %d readable, %d denied%@",
            charge, s.scale.health * 100, s.scale.joulesPerPercent,
            s.readable, s.attempted, s.denied, obs)
    }

    func updateLedger(_ s: PowerMonitor.Snapshot) {
        let gpu = s.gpu_pctHr.map { String(format: "%5.2f", $0) } ?? "   —"
        let res = s.residual_pctHr.map { String(format: "%5.2f", $0) } ?? "   —"
        let share = s.residualShare.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
        let src = s.smcTotal_W != nil
            ? "SMC PSTR" + (s.smcGain.map { String(format: " ×%.2f", $0) } ?? "")
            : (s.measured_W != nil ? "gas gauge (60s)" : "estimating")

        // Time remaining prefers the observed-discharge estimate over the
        // power-derived one: it is measured from actual charge leaving the pack,
        // and it is slew-limited so it cannot swing 3h→9h between ticks.
        let est = drain.estimate()
        let left: String
        if let t = est?.timeRemaining, t.isFinite, t > 0 {
            left = String(format: "→ %dh %02dm left", Int(t / 3600), (Int(t) % 3600) / 60)
        } else if let h = s.projectedRuntime_hr() {
            left = String(format: "→ ~%dh %02dm left", Int(h), Int(h * 60) % 60)
        } else {
            left = "on AC"
        }

        var warn = ""
        if s.hasAttributionOverflow {
            // Physically impossible; means double counting. Surfaced rather than
            // hidden by the max(0,…) clamp on the displayed residual.
            warn = String(format: "   ⚠︎ attribution overflow %.2f W", -s.rawResidual_W)
        }

        main.ledger.stringValue = [
            String(format: "apps (CPU) %5.2f %%/hr    GPU %@ %%/hr    unmeasured %@ %%/hr (%@)",
                   s.attributed_pctHr, gpu, res, share),
            String(format: "TOTAL      %5.2f %%/hr    source: %@    %@%@",
                   s.smoothed_pctHr, src, left, warn),
            "unmeasured = display, radios, SSD, kernel, and root-owned processes",
        ].joined(separator: "\n")
    }

    func updateGraph(_ s: PowerMonitor.Snapshot) {
        let now = Date()
        totalSeries.append(.init(time: now, value: s.smoothed_pctHr))
        appsSeries.append(.init(time: now, value: s.attributed_pctHr))
        let cutoff = now.addingTimeInterval(-graphSpan)
        totalSeries.removeAll { $0.time < cutoff }
        appsSeries.removeAll { $0.time < cutoff }

        graph.series = [
            .init(name: "total", color: .systemBlue, points: totalSeries, filled: true),
            .init(name: "apps", color: .systemOrange, points: appsSeries, filled: false),
        ]
    }

    func updateDetail() {
        let sel = main.table.selectedRow
        guard sel >= 0, sel < rows.count, let snap = lastSnapshot else {
            main.setDetailVisible(false)
            return
        }
        detail.model = AppDetailView.Model(app: rows[sel].app, snapshot: snap)
        main.setDetailVisible(true)
    }

    @objc func tableClicked() { updateDetail() }

    func tableViewSelectionDidChange(_ notification: Notification) { updateDetail() }

    func sortRows() {
        let asc = ascending
        rows.sort { a, b in
            let r: Bool
            switch sortKey {
            case "name":   r = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case "window": r = (a.windowPct ?? -1) < (b.windowPct ?? -1)
            case "cost":   r = (a.costMin ?? -1) < (b.costMin ?? -1)
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
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tv: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        guard let d = tv.sortDescriptors.first, let k = d.key else { return }
        sortKey = k
        ascending = d.ascending
        sortRows()
        tv.reloadData()
    }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count, let id = col?.identifier.rawValue else { return nil }
        let r = rows[row]

        var text: String
        var align = NSTextAlignment.right
        var dim = false
        switch id {
        case "name":
            text = r.name; align = .left
        case "pctHr":
            text = r.pctHr < 0.01 ? "<0.01" : String(format: "%.2f", r.pctHr)
        case "window":
            // "—" not "0.00": no recorded on-battery history is not zero usage.
            text = r.windowPct.map { String(format: "%.2f%%", $0) } ?? "—"
            dim = r.windowPct == nil
        case "cost":
            text = r.costMin.map { $0 >= 60
                ? String(format: "%dh %02dm", Int($0 / 60), Int($0) % 60)
                : String(format: "%.0f min", $0) } ?? "—"
            dim = r.costMin == nil
        case "procs":
            text = r.procs > 1 ? "\(r.procs)" : "—"; dim = true
        default:
            text = r.isApp ? "app" : "daemon"; align = .left; dim = true
        }

        let cell = NSTextField(labelWithString: text)
        cell.font = .monospacedSystemFont(ofSize: 11, weight: id == "name" && r.isApp ? .semibold : .regular)
        cell.alignment = align
        cell.lineBreakMode = .byTruncatingTail
        if dim { cell.textColor = .secondaryLabelColor }
        return cell
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

import AppKit
import PowerKit

// BetterStats — milestone 1.
//
// One sampling loop feeds everything: the table, the history graph, the ledger,
// the metric registry (and through it the menu bar widgets), and the SQLite
// history that backs the "10 hr power" column.

private extension MetricID {
    /// The namespace an ID lives in: everything before the first dot —
    /// "battery", "system", "sensors", "widget". Lets a whole family be routed
    /// without repeating the prefix as a literal.
    var family: Substring { rawValue.prefix { $0 != "." } }
}

// `Row`, the column definitions and the runtime-cost counterfactual live in
// ProcessTable.swift — one file that owns what the table IS, so this one is left
// owning the sampling loop and the wiring.

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {

    var main: MainWindowController!
    var graph: HistoryGraphView!
    var inspector: InspectorView!
    let networkPane = NetworkPane(frame: .zero)
    let sensorsPane = SensorsPane(frame: .zero)
    let fansPane = FansPane(frame: .zero)
    let resourcesPane = ResourcesPane(frame: .zero)
    /// Latest utilisation snapshot, so a pane can redraw without waiting for the
    /// next sample.
    var lastSystem: SystemMetrics.Snapshot?
    /// Process and thread counts, for the card when the subject is CPU.
    ///
    /// Refreshed only while CPU IS the subject, the same rule the Resources tab
    /// applies: it is a 0.48 ms sweep of ~900 processes, which is affordable once
    /// a tick for a number on screen and not worth paying on the ticks where
    /// nothing displays it.
    var lastCensus: MachineInfo.Census?
    var widgets: MenuBarWidgetController!

    var monitor: PowerMonitor?
    var store: HistoryStore?
    let drain = DrainRateEstimator()
    /// Throttles the trend's crash-insurance write. See the call site.
    var lastTrendSave = Date.distantPast
    /// The most recent estimate, computed on the sampling queue beside the
    /// `record` that produced it and then handed to the main thread as a value.
    /// `DrainRateEstimator` is not thread-safe and `record` does not run on main,
    /// so calling `estimate()` from a UI path was reading a buffer while the
    /// sampler mutated it.
    var lastDrain: DrainEstimate?
    /// CPU, memory, GPU, network and sensors. Cheap enough to run even while
    /// hidden — unlike the per-process sweep, these are a handful of syscalls.
    let sysMetrics = SystemMetrics()
    /// Per-process network, via nettop. Refreshed only while the Network pane is
    /// on screen.
    let netAttribution = NetworkAttribution()

    var rows: [Row] = []
    var sortKey = ProcessColumns.defaultSortKey
    var ascending = false
    var timer: Timer?

    /// The active column set, keyed by identifier. Rebuilt only when the trailing
    /// power window changes, because that is the only thing a column definition
    /// depends on — and looked up rather than re-derived, because the renderer, the
    /// sizer and the sorter must all be reading the same closure.
    var columns: [ProcessColumn] = ProcessColumns.all(
        powerWindowHours: Settings.shared.powerWindowHours)
    var columnsByID: [String: ProcessColumn] = ProcessColumns.byID(
        Settings.shared.powerWindowHours)
    /// The window the current column set was built for, so a changed setting
    /// re-titles the column instead of leaving a header claiming ten hours over a
    /// two-hour figure.
    private var columnsBuiltForHours = Settings.shared.powerWindowHours

    /// Installed RAM, for the "% Mem" column. Constant for the life of the process.
    let totalMemoryBytes = MemoryUsage.totalBytes

    /// Every sample runs here and nowhere else.
    ///
    /// This used to be `DispatchQueue.global()`, which is CONCURRENT: a tick that
    /// ran long overlapped the next one, and the two then mutated the same
    /// unprotected state — the monitor's rail windows and paired sleep-gap
    /// timestamps, `CPUUsage.previous`, `NetworkThroughput.previous`,
    /// `lastFullTick`, and the SMC wrapper, which takes no lock at all. Concurrent
    /// Dictionary mutation is a crash, not a wrong number.
    ///
    /// `.utility` is the same QoS the concurrent dispatch asked for, so the change
    /// is to the ordering guarantee and not to the priority.
    let sampling = DispatchQueue(label: "com.betterstats.sampling", qos: .utility)
    /// Admits one tick at a time and counts the rest. The serial queue alone would
    /// let a late tick queue up and run immediately behind the slow one; the gate
    /// drops it instead, because a tick that could not run did not happen.
    let sampleGate = SamplingGate()

    /// In-memory graph history. The store owns durable history; this is just the
    /// last hour at tick resolution for drawing.
    /// Chosen range in seconds. Live mode (1 h) keeps the in-memory strip chart;
    /// anything longer is served from the durable store, because the in-memory
    /// series is deliberately capped at an hour and cannot answer for yesterday.
    var graphRange: TimeInterval = 3600
    /// Ledger bucket the graph is drilled into, or nil for the whole-system
    /// total. Only meaningful in the live range: the store keeps per-app energy
    /// but not a per-bucket breakdown, so a historical drill-down would have to
    /// invent the split rather than read it.
    var graphSegment: LedgerBarView.Segment?
    /// Per-contributor history while drilled in, keyed by name. Capped to the
    /// live window like the main series.
    var segmentSeries: [String: [HistoryGraphView.Point]] = [:]
    /// Set once the user zooms or pans, and cleared by picking a range. While set
    /// the graph shows exactly what was asked for rather than following "now".
    var graphDomainOverride: (start: Date, end: Date)?
    var lastHistoryQuery = Date.distantPast

    var totalSeries: [HistoryGraphView.Point] = []
    /// Battery charge over the same window, plotted on the right-hand 0-100 axis.
    var chargeSeries: [HistoryGraphView.Point] = []
    /// Live utilisation, for the bottom graph when it is not about the battery.
    ///
    /// Kept beside `totalSeries` rather than derived from it because they are
    /// different measurements: one is the pack's drain, these are the device's
    /// own load. Same window, same cutoff, same 1H buffer — the longer ranges
    /// come from `utilizationSeries`, which the store has kept all along.
    var utilizationSeries: [BottomContext: [HistoryGraphView.Point]] = [:]
    /// Disk's live buffers, in MiB/s. Its own pair rather than a `.disk` entry
    /// above, because it is the one subject that draws two lines and the
    /// dictionary holds exactly one series per subject.
    var diskReadSeries: [HistoryGraphView.Point] = []
    var diskWriteSeries: [HistoryGraphView.Point] = []
    var netInSeries: [HistoryGraphView.Point] = []
    var netOutSeries: [HistoryGraphView.Point] = []
    /// Every live buffer that is not `totalSeries`, `chargeSeries` or the
    /// per-subject dictionary — listed once so the cutoff cannot trim seven of
    /// eight and leave one growing without bound.
    static let sessionSeries: [ReferenceWritableKeyPath<AppDelegate, [HistoryGraphView.Point]>] = [
        \.diskReadSeries, \.diskWriteSeries, \.netInSeries, \.netOutSeries,
        \.fanLoadSeries, \.temperatureSeries, \.cpuTempSeries, \.gpuTempSeries,
        \.pickedSensorSeries,
    ]

    /// Session-only, and unavoidably so: the SMC sweep is gated on a tab that
    /// reads it being open, so there is no history of these to seed from. Both
    /// subjects offer 1H alone for exactly that reason — see `BottomContext.ranges`.
    var fanLoadSeries: [HistoryGraphView.Point] = []
    var temperatureSeries: [HistoryGraphView.Point] = []
    var cpuTempSeries: [HistoryGraphView.Point] = []
    var gpuTempSeries: [HistoryGraphView.Point] = []
    /// The one sensor the user clicked in the Sensors list, alongside the
    /// averages. Cleared when the pick changes: a line that kept its old points
    /// under a new name would be two sensors drawn as one.
    var pickedSensorSeries: [HistoryGraphView.Point] = []
    let graphSpan: TimeInterval = 3600

    var lastSnapshot: PowerMonitor.Snapshot?
    /// Active tab. Drives which pane is on screen and — through
    /// `SidebarView.Lens.needs` — which subsystems are sampled at all.
    var lens: SidebarView.Lens = .processes
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

    /// Fill the 1H graph from the database before the first tick.
    ///
    /// The 1H view is an in-memory ring; 6H and longer read SQLite. So the live
    /// hour started EMPTY on every launch and grew a pixel at a time — a user who
    /// had just reopened the app saw one minute of history in a window labelled
    /// one hour, which reads as data loss rather than as a buffer filling.
    ///
    /// Same source and same units as `refreshHistoryGraph`, so a restart is
    /// invisible: the seeded points and the ones appended a second later are the
    /// same measurements from the same store.
    ///
    /// Synchronous, and deliberately so — it runs once, before the first frame,
    /// and doing it asynchronously would race the first tick's `append` and
    /// interleave an hour of history after a second of live data.
    private func seedLiveGraphFromHistory() {
        guard let store else { return }
        let now = Date()
        let pts = store.powerSeries(since: now.addingTimeInterval(-graphSpan),
                                    until: now, maxPoints: 700)
        guard !pts.isEmpty else { return }
        let scale = monitor?.scale
        totalSeries = pts.map { p in
            // %/hr, not watts — matching the live append and the long views.
            let pctHr = scale.map { 3600 * p.watts / $0.joulesPerPercent } ?? p.watts
            return .init(time: p.time, value: pctHr)
        }
        chargeSeries = pts.compactMap { p in
            guard let soc = p.socPercent else { return nil }
            return .charge(time: p.time, percent: soc, onBattery: p.onBattery)
        }

        // The other subjects too, or the 1H view of a CPU graph starts at the
        // moment the app launched while its own 6H view shows the full week's
        // worth — which is the exact complaint the battery graph drew ("only
        // showing 6 mins as that's when I restarted the app"), and seeding only
        // the battery buffer fixed it for one subject out of five.
        let util = store.utilizationSeries(since: now.addingTimeInterval(-graphSpan),
                                           until: now, maxPoints: 700)
        func seed(_ context: BottomContext, _ get: (HistoryStore.UtilizationPoint) -> Double?) {
            let s = util.compactMap { p in get(p).map { HistoryGraphView.Point(time: p.time, value: $0) } }
            if !s.isEmpty { utilizationSeries[context] = s }
        }
        seed(.cpu) { $0.cpuPercent }
        seed(.gpu) { $0.gpuPercent }
        seed(.memory) { $0.memoryPercent }
        func seedDisk(_ get: (HistoryStore.UtilizationPoint) -> Double?)
            -> [HistoryGraphView.Point] {
            util.compactMap { p in
                get(p).map { .init(time: p.time, value: Self.mib($0)) }
            }
        }
        diskReadSeries = seedDisk { $0.diskReadBytesPerSec }
        diskWriteSeries = seedDisk { $0.diskWriteBytesPerSec }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        monitor = PowerMonitor()
        store = HistoryStore()
        seedLiveGraphFromHistory()
        // The battery does not know the app restarted, so the trend must not
        // either. Restoring is safe because the accumulator is hardware and keeps
        // counting while nothing is watching; the guards in `record` still throw
        // the restored history away on a reboot, on time spent on the adapter, or
        // on an absence longer than the window. See
        // `BatteryDischargeTrend.Persisted`.
        if let saved = BatteryDischargeTrend.Persisted.load() { drain.restoreTrend(saved) }

        buildMenu()

        main = MainWindowController()
        main.table.dataSource = self
        main.table.delegate = self
        main.table.sortDescriptors =
            [NSSortDescriptor(key: ProcessColumns.defaultSortKey, ascending: false)]
        main.table.target = self
        main.table.action = #selector(tableClicked)

        main.setColumns(columns)
        main.sidebar.onSelect = { [weak self] lens in self?.select(lens) }
        // Clicking a rail card changes the subject exactly as clicking a tab or a
        // column header does, so it goes through the same path.
        resourcesPane.onSelectResource = { [weak self] in self?.retargetBottom() }
        // Picking a sensor gives it its own line. The buffer is cleared rather
        // than kept, because points recorded under the previous pick belong to a
        // different sensor and drawing them under a new name is a lie the graph
        // has no way to unpick.
        sensorsPane.onPickSensor = { [weak self] _ in
            guard let self else { return }
            pickedSensorSeries.removeAll()
            updateGraph(lastSnapshot, appending: false)
        }
        // 20, not 22. Twelve columns is a table you scan down as much as across, and
        // two points a row is three more rows on screen at this window height.
        main.table.rowHeight = 20

        graph = HistoryGraphView(frame: .zero)
        graph.yAxisLabel = "%/hr"
        graph.showsGrid = false
        graph.earliestAvailable = store?.earliestSample()
        // Keep the legend clear of the range picker overlaid on the header.
        // The picker is 4 cells of 34 pt inset 44 from the trailing edge, so it
        // occupies 180 pt; 190 leaves a little air rather than butting up to it.
        graph.headerTrailingInset = 190
        // Zoom and pan set an explicit domain; re-query at the new range rather
        // than stretching whatever is already in memory, or a 7-day view would be
        // an hour of data smeared across the width.
        graph.onDomainChanged = { [weak self] start, end in
            guard let self else { return }
            self.graphDomainOverride = (start, end)
            self.loadHistorySeries(start: start, end: end)
        }
        main.installGraph(graph)

        // Clicking a ledger segment turns the graph into that bucket's
        // contributors. Clicking it again returns to the total.
        main.ledger.onSelectSegment = { [weak self] seg in
            self?.graphSegment = seg
            self?.updateGraph(self?.lastSnapshot)
        }
        main.graphRanges.onSelect = { [weak self] seconds in
            guard let self else { return }
            self.graphRange = seconds
            self.graphDomainOverride = nil          // back to following "now"
            self.graph.earliestAvailable = self.store?.earliestSample()
            if seconds <= 3600 {
                self.graph.timeDomain = nil          // live strip chart
                self.updateGraph(self.lastSnapshot)
            } else {
                let end = Date()
                self.graph.timeDomain = (end.addingTimeInterval(-seconds), end)
                self.loadHistorySeries(start: end.addingTimeInterval(-seconds), end: end)
            }
        }

        inspector = InspectorView(frame: .zero)
        inspector.onClose = { [weak self] in
            self?.selectedAppName = nil
            self?.main.table.deselectAll(nil)
            self?.main.setDetailVisible(false)
        }
        main.installDetail(inspector)

        // Menu bar widgets bind to metric IDs, so any metric the app ever gains is
        // automatically available to every widget with no new widget code. The ID
        // is also the widget's destination: clicking one opens the window on the
        // lens that explains that number.
        widgets = MenuBarWidgetController(onClick: { [weak self] metric in
            self?.openFromWidget(metric)
        }, enabled: Settings.shared.menuBarWidgetsEnabled)
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

        // The one place launch decides whether it is an app or a menu bar tool.
        // The activation policy was already set from the same rule before run()
        // (see the bottom of this file), so nothing flashes a Dock tile here.
        if AppPresence.showsWindowAtLaunch(
            startInMenuBarOnly: Settings.shared.startInMenuBarOnly,
            widgetsEnabled: Settings.shared.menuBarWidgetsEnabled) {
            main.show()
        }

        monitor?.tick()   // prime; the first tick has no interval to diff against
        restartTimer()

        // React to a changed sample interval without needing a relaunch.
        //
        // Retained, not `_ =`'d. A discarded token unobserves in its own deinit,
        // so this handler had never once run; the slider kept working only
        // because `refresh()` re-reads the interval on every tick anyway. Held
        // here so the two paths agree, and `hidden:` is passed rather than
        // defaulted — waking the sampler to the visible cadence because a value
        // changed in a settings window is not what the setting asked for.
        settingsTokens.append(
            Settings.shared.observe(Settings.Key.sampleInterval) { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.restartTimer(hidden: !self.main.window.isVisible)
                }
            })
        settingsTokens.append(
            Settings.shared.observe(Settings.Key.menuBarWidgetsEnabled) { [weak self] in
                self?.applyMenuBarSwitch()
            })
        // The trailing-window column is TITLED from this setting, so a change has to
        // reach the header. Without it the column would keep saying "10 HR POWER"
        // over a two-hour figure.
        settingsTokens.append(
            Settings.shared.observe(Settings.Key.powerWindowHours) { [weak self] in
                DispatchQueue.main.async { self?.rebuildColumnsIfNeeded() }
            })
    }

    /// Re-derive the column set when the setting its titles depend on has moved.
    func rebuildColumnsIfNeeded() {
        let hours = Settings.shared.powerWindowHours
        guard hours != columnsBuiltForHours else { return }
        columnsBuiltForHours = hours
        columns = ProcessColumns.all(powerWindowHours: hours)
        columnsByID = ProcessColumns.byID(hours)
        guard lens.isPerProcess else { return }
        main.setColumns(columns)
        main.table.reloadData()
        autosizeColumns()
    }

    /// Observation tokens are only alive while retained — a discarded token
    /// unobserves in its deinit, which is why these are held rather than `_ =`'d.
    private var settingsTokens: [AnyObject] = []

    /// The menu bar master switch was flipped. Takes effect now; no relaunch.
    ///
    /// The activation policy has to move with it, and only while the window is
    /// hidden. Switching the widgets off is the moment an `.accessory` app loses
    /// its last clickable surface, so the Dock tile comes back at exactly that
    /// point; switching them on again while the window is closed hands the tile
    /// back and returns the app to what it is — a menu bar tool.
    private func applyMenuBarSwitch() {
        let on = Settings.shared.menuBarWidgetsEnabled
        widgets.setEnabled(on)
        guard !main.window.isVisible else { return }
        NSApp.setActivationPolicy(AppPresence.policyWithWindowHidden(widgetsEnabled: on))
    }

    /// Tick cadence while the window is hidden.
    ///
    /// The window needs a live-feeling chart; the menu bar needs a number that is
    /// roughly current. Sampling both at the same rate means the expensive path
    /// runs for a reader that cannot tell the difference — a menu bar figure
    /// updated every 2 s and every 5 s look identical, and everything downstream
    /// (IORegistry reads, SMC reads, metric formatting, image drawing) scales with
    /// the rate.
    static let hiddenInterval: TimeInterval = 8

    /// Interval the timer is currently scheduled at, so visibility changes only
    /// rebuild the timer when the rate actually needs to change.
    private var timerInterval: TimeInterval = 0

    func restartTimer(hidden: Bool = false) {
        let interval = hidden
            ? max(Settings.shared.sampleInterval, Self.hiddenInterval)
            : Settings.shared.sampleInterval
        guard interval != timerInterval else { return }
        timer?.invalidate()
        timerInterval = interval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Let the OS coalesce this wakeup with whatever else it was going to wake
        // for. Idle cost here is dominated by waking the CPU at all rather than by
        // the work done once awake — the whole tick measures 0.19% of one core —
        // and a timer with no tolerance is one the kernel must honour to the
        // millisecond, alone.
        //
        // 10%: at the 2 s visible cadence that is 200 ms of slack, which is
        // invisible in a strip chart plotted against real timestamps, and the
        // monitor differences actual elapsed time rather than assuming the nominal
        // interval, so a late tick costs accuracy nothing. Much more than this and
        // the hidden 8 s cadence starts to wander visibly in the menu bar.
        timer?.tolerance = interval * 0.1
    }

    func refresh() {
        guard let m = monitor else { return }
        // Read visibility on the main thread; AppKit state is not thread-safe.
        let visible = main.window.isVisible
        // Read beside it, for the same reason the interval is: one value used by
        // the whole tick, so logging cannot be on for the sweep and off for the
        // write within a single sample.
        let logging = Settings.shared.batteryLogging
        // The tab on screen, read on main because that is where it is written. It
        // decides which subsystems this tick pays for — see `visibleNeeds`.
        let needs = visible ? visibleNeeds : hiddenNeeds
        // Match the cadence to who is actually reading.
        restartTimer(hidden: !visible)

        // One tick at a time, on one queue. A tick arriving while the previous one
        // is still running is dropped, not queued and not run beside it.
        sampleGate.submit(on: sampling) { [weak self] in
            guard let self else { return }
            // The background full tick exists for ONE reason — keeping the trailing
            // power window accruing while the window is closed. With logging off
            // there is nothing to accrue into, so the per-process sweep, the
            // IOReport channel diff and the rollup behind it are not paid for. The
            // whole-machine figures the menu bar shows come from every tick, light
            // or full, so the widgets do not go quiet.
            let wantFull = visible
                || (logging
                    && Date().timeIntervalSince(self.lastFullTick) >= self.backgroundFullInterval)
            // Attribution only when someone can see it. The rollup feeds the
            // process table and the drill-down, both of which are off screen.
            guard let snap = m.tick(full: wantFull, attribution: visible) else { return }
            if wantFull { self.lastFullTick = Date() }

            // Computed on the main thread above, because the tab it depends on is
            // main-thread state. Hidden: only what a widget is bound to. Visible:
            // that, plus what the tab on screen is actually displaying.
            let sysSnap = self.sysMetrics.sample(needs: needs)
            MetricRegistry.shared.update(system: sysSnap)

            // Durable history and the observed-drain estimate both belong off the
            // main thread: one touches SQLite, the other only does arithmetic but
            // there is no reason to make the UI wait for either.
            let onBattery = !(snap.state?.onAC ?? true)
            // Only full ticks carry per-app energy, and writing an interval row with
            // no apps would add WAL churn for nothing. At 2 s with ~30 apps this was
            // driving ~20 KB/s of write-ahead log.
            // `logging` gates the write itself as well as the sweep above, because a
            // VISIBLE tick is full whether or not anyone is recording.
            if wantFull, logging {
                self.store?.record(apps: snap.apps,
                                   measured_W: snap.measured_W,
                                   attributed_W: snap.attributed_W,
                                   residual_W: snap.residual_W,
                                   onBattery: onBattery,
                                   socPercent: snap.state.map { Double($0.percent) },
                                   interval: snap.interval)
            }
            var est: DrainEstimate?
            if let st = snap.state {
                self.drain.record(state: st, scale: snap.scale,
                                  powerBased_pctHr: snap.smoothed_pctHr)
                est = self.drain.estimate()

                // Insurance against the exits that skip `applicationWillTerminate`
                // — a crash, a force quit, a logout that does not wait. Every two
                // minutes and not every tick: this is a few dozen samples of five
                // numbers, and macOS has killed this app once already for dirtying
                // pages too fast. Losing at most two minutes of a thirty-minute
                // window is not worth a write per second to avoid.
                if Date().timeIntervalSince(self.lastTrendSave) > 120 {
                    self.lastTrendSave = Date()
                    let snapshot = self.drain.persistedTrend()
                    DispatchQueue.global(qos: .utility).async { snapshot.save() }
                }
            }

            // The window query walks history, so it is not worth doing every tick.
            var pcts: [String: Double]? = nil
            // 60 s, not 20. "10 hr power" is a ten-hour trailing total; refreshing
            // it three times a minute cost a full re-scan of the window for a number
            // that cannot visibly move in that time.
            if visible, Date().timeIntervalSince(self.lastWindowQuery) > 60, let store = self.store {
                let hours = Settings.shared.powerWindowHours
                let rowsW = store.windowPower(hours: hours,
                                              joulesPerPercent: snap.scale.joulesPerPercent)
                pcts = Dictionary(rowsW.map { ($0.name, $0.percentOfBattery) },
                                  uniquingKeysWith: { a, b in a + b })
            }

            DispatchQueue.main.async {
                self.lastSystem = sysSnap
                self.lastDrain = est
                if let p = pcts { self.windowPercents = p; self.lastWindowQuery = Date() }
                // Hidden: refresh only the menu bar. Reloading a table, re-sorting
                // rows and redrawing the graph for an off-screen window is pure cost.
                if visible {
                    self.apply(snap)
                } else {
                    MetricRegistry.shared.update(with: snap)
                    // Published on hidden ticks too. Without this the menu bar kept
                    // whatever pair was current when the window was last closed and
                    // showed it for as long as the app stayed in the background —
                    // which is most of its life.
                    MetricRegistry.shared.update(displayedRate: Self.reconciledRate(snap, est))
                    self.widgets.refresh()
                }
            }
        }

        // Published every tick, admitted or dropped, so what a widget shows is
        // this tick's count. A dropped tick is a span of time the app measured
        // nothing over; the one thing it must never be is silent.
        MetricRegistry.shared.update(droppedSamples: sampleGate.dropped)
    }

    func apply(_ s: PowerMonitor.Snapshot) {
        // Feed the registry first so the widgets and any UI reading metrics see
        // this tick's values rather than the previous one. The whole-machine
        // figures behind these — total, charge, time left — are measured on every
        // tick, light or full.
        MetricRegistry.shared.update(with: s)
        MetricRegistry.shared.update(displayedRate: Self.reconciledRate(s, lastDrain))
        widgets.refresh()

        // Everything below reads what only a full sweep produces: the app rows,
        // the ledger's per-bucket split, the inspector. Handed a light sample the
        // table would empty out — "no app is using any power" — and the ledger
        // would draw one full-width unattributed bar. A visible tick is always a
        // full one (see `refresh`), so this cannot fire today; it is here so that
        // stops being a fact you have to reconstruct from two functions away.
        guard s.isFullSample else { return }
        lastSnapshot = s

        let showDaemons = Settings.shared.showDaemons
        let floor = Settings.shared.minimumDisplayPercentPerHour
        // One table now, so the three row sources are JOINED rather than switched
        // between. An app that is both burning CPU and holding the GPU used to be
        // two rows in two tabs that nothing connected.
        rows = ProcessRowBuilder.rows(
            apps: showDaemons ? s.apps : s.apps.filter(\.isApp),
            systemApps: showDaemons ? s.systemApps : [],
            gpuApps: s.gpuApps,
            windowPercents: windowPercents,
            runtimeCost: { RuntimeCost.minutes(appWatts: $0, snapshot: s) },
            totalMemoryBytes: totalMemoryBytes,
            deviceGPUPercent: lastSystem?.gpu?.utilization)
            // The GPU rollup is fed in whatever the setting says, so an APP always
            // finds its GPU share; this is what drops the coalitions that matched
            // no app — WindowServer and friends — when daemons are switched off.
            .filter { showDaemons || $0.isApp }
            .filter { ProcessRowBuilder.isNotable($0, floor_pctHr: floor) }
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
        updateGlance(s)
        updateFanSpin()
        updateGraph(s)
        refreshPane()
    }

    /// The bar, for whichever subject the sort names. See `BottomContext`.
    ///
    /// Split by the same test the process table uses — `identity.isApp` — so the
    /// bar's "apps" is exactly the set of rows the table calls apps. Two
    /// definitions of an app on one screen is how a total stops matching its own
    /// breakdown.
    func updateUtilizationBar(_ context: BottomContext) -> Bool {
        guard let sys = lastSystem else { return false }
        func sum(_ value: (AppDrain) -> Double, apps: Bool) -> Double {
            rows.compactMap(\.app)
                .filter { $0.identity.isApp == apps }
                .reduce(0) { $0 + value($1) }
        }

        switch context {
        case .battery:
            return false

        case .cpu:
            guard let total = sys.cpu?.total else { return false }
            // DIVIDED BY THE CORE COUNT, and everything about this bar was wrong
            // without it.
            //
            // `AppDrain.cpuPercent` is percent of ONE core — Activity Monitor's
            // convention, where a fully busy four-thread process reads 400%. The
            // device total from `CPUUsage` is 0-100 across ALL cores. Summing the
            // first and comparing it to the second mixes two scales by a factor of
            // the core count: on this 15-core machine the bar read "CPU 129.0% in
            // use" while the device was at 17.3%, and the caption said so out loud.
            //
            // `activeProcessorCount` is the right divisor because it is what the
            // host statistics behind `total` average over.
            let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
            main.ledger.utilization = .attributed(
                "CPU",
                UtilizationSlices(total: total,
                                  apps: sum({ $0.cpuPercent }, apps: true) / cores,
                                  systemProcesses: sum({ $0.cpuPercent }, apps: false) / cores),
                idle: max(0, 100 - total),
                // The one place the two conventions meet, so it is said here: the
                // table's own % CPU column is per-core and these are not, and a
                // user adding the column up will not get this number.
                note: "of all \(Int(cores)) cores")

        case .gpu:
            guard let total = sys.gpu?.utilization else { return false }
            // Said out loud rather than smoothed over. Per-app GPU comes from the
            // coalition store at ~30-60 s resolution while the device total is
            // read every tick, so the split steps while the whole moves — which
            // looks like a stall and is not one.
            //
            // APPORTIONED, not measured per process. macOS exposes no per-process
            // GPU utilisation; what exists is each coalition's share of GPU TIME,
            // and the device's own utilisation is measured whole. Multiplying one
            // by the other is the same method the GPU %/hr column uses, and it is
            // an apportionment either way — which is why the remainder still gets
            // its hatched slice rather than being folded into the named ones.
            func gpuShare(apps: Bool) -> Double {
                rows.filter { $0.app?.identity.isApp == apps }
                    .reduce(0) { $0 + ($1.gpuTimeShare ?? 0) } * total
            }
            main.ledger.utilization = .attributed(
                "GPU",
                UtilizationSlices(total: total,
                                  apps: gpuShare(apps: true),
                                  systemProcesses: gpuShare(apps: false)),
                idle: max(0, 100 - total),
                note: "per-app GPU updates every ~30-60 s")

        case .memory:
            guard let m = sys.memory, m.total > 0 else { return false }
            func pct(_ b: UInt64) -> Double { Double(b) / Double(m.total) * 100 }
            main.ledger.utilization = .memory(app: pct(m.app),
                                              wired: pct(m.wired),
                                              compressed: pct(m.compressed))

        case .disk:
            guard let d = sys.disk else { return false }
            // The same cut as CPU, in bytes per second instead of percent. Read
            // and write are NOT the cut here: the bar answers "who", and the two
            // graph lines behind it already answer "which direction".
            //
            // The unattributed slice is usually the large one and that is real.
            // `ri_diskio_bytesread` counts a process's own I/O; the device counter
            // counts everything reaching the block device, which includes the page
            // cache flushing, Spotlight, and every process this app cannot read.
            main.ledger.utilization = .attributed(
                "Disk",
                UtilizationSlices(total: d.totalPerSec,
                                  apps: sum({ $0.diskBytesPerSec }, apps: true),
                                  systemProcesses: sum({ $0.diskBytesPerSec }, apps: false)),
                scale: .bytesPerSecond)

        case .network:
            guard let n = sys.network else { return false }
            // Per-process network is a real measurement here — `NetworkAttribution`
            // reads each process's own counters — so this is the same cut as CPU
            // rather than an apportionment. The unattributed slice is usually
            // large and honestly so: the interface counters see everything on the
            // wire, including every process this app cannot read.
            func netSum(apps: Bool) -> Double {
                let names = Set(rows.filter { $0.app?.identity.isApp == apps }.map(\.name))
                return netAttribution.latest
                    .filter { names.contains($0.name) }
                    .reduce(0) { $0 + $1.totalPerSec }
            }
            main.ledger.utilization = .attributed(
                "Network",
                UtilizationSlices(total: n.totalPerSec,
                                  apps: netSum(apps: true),
                                  systemProcesses: netSum(apps: false)),
                scale: .bytesPerSecond)

        case .fans:
            guard !sys.fans.isEmpty else { return false }
            // A GAUGE, not a split. Two fans do not divide one quantity between
            // them — they each sit somewhere in their own min..max — so the bar
            // shows how far into that range they are and what is left, which is
            // exactly what the graph above plots and the pane's own dials show.
            let load = sys.fans.averageLoad * 100
            let rpm = sys.fans.averageRPM
            main.ledger.utilization = .gauge(
                "Fan speed", percent: load,
                caption: String(format: "%.0f rpm average of %d", rpm, sys.fans.count))

        case .sensors:
            // A SPREAD, not a division. A stacked bar states parts of a whole and
            // a temperature has neither — sensors do not divide a quantity between
            // them, and this machine publishes no ceiling to be a fraction of — so
            // this tab had no bar at all for a while. A range invents nothing: both
            // ends are readings the machine reported and the mark is their mean.
            //
            // Off the same cached sweep the Sensors pane just did, so this is a
            // read of a dictionary rather than a second 90 ms walk of the SMC.
            let temps = Sensors.temperatures()
            guard let coolest = temps.min(by: { $0.value < $1.value }),
                  let hottest = temps.max(by: { $0.value < $1.value })
            else { return false }
            let mean = temps.reduce(0) { $0 + $1.value } / Double(temps.count)
            main.ledger.spread = .init(
                title: "Temperature",
                low: coolest.value, high: hottest.value,
                lowName: coolest.qualifiedName, highName: hottest.qualifiedName,
                average: mean, count: temps.count,
                scale: LedgerBarView.SpreadBar.celsius)
            return true
        }
        return true
    }

    func updateLedger(_ s: PowerMonitor.Snapshot) {
        // A change of subject takes the bar with it. Nil-ing it first means a
        // subject with no reading yet falls back to the battery bar rather than
        // leaving the previous subject's numbers on screen under a new title.
        // Both cleared first. A subject that sets neither falls back to the
        // battery bar, and a leftover from the previous subject would otherwise
        // sit under a new heading — the same staleness the card had.
        main.ledger.utilization = nil
        main.ledger.spread = nil
        if updateUtilizationBar(bottomContext) {
            main.sidebar.refreshValues()
            return
        }
        main.ledger.model = LedgerBarView.Model(
            apps_pctHr: s.attributed_pctHr,
            systemProcesses_pctHr: s.systemProcesses_pctHr ?? 0,
            gpu_pctHr: s.gpu_pctHr ?? 0,
            display_pctHr: s.display_pctHr ?? 0,
            displayIsMeasured: s.displayIsMeasured,
            memory_pctHr: s.memory_pctHr ?? 0,
            storage_pctHr: s.storage_pctHr ?? 0,
            usb_pctHr: s.usb_pctHr ?? 0,
            usbUnmeasured: s.usbHasUnmeasured,
            // Platform when the CPU rail is readable; otherwise fall back to the old
            // single residual rather than showing a bucket we cannot justify.
            unattributed_pctHr: s.platform_pctHr ?? s.residual_pctHr ?? 0,
            total_pctHr: s.smoothed_pctHr,
            // The bar is laid out across the SPAN, printed as the TOTAL. They are
            // the same number except in the seconds after a load spike, when
            // instantaneous attributed energy can exceed a total still anchored to
            // the gauge's 60 s mean — and then the bar would otherwise render
            // "apps = 100% of the machine". Nothing is clamped and the overflow
            // alarm still fires; only the denominator gives way.
            span_pctHr: s.ledgerSpan_pctHr,
            source: s.smcTotal_W != nil
                ? "PSTR" + (s.smcGain.map { String(format: " ×%.2f", $0) } ?? "")
                : (s.measured_W != nil ? "gas gauge" : "estimating"),
            readable: s.readable,
            attempted: s.attempted,
            overflow: s.hasAttributionOverflow)

        main.sidebar.refreshValues()
    }

    /// The card in the corner, for whichever subject the sort names.
    ///
    /// ITS OWN FUNCTION, because it used to be the tail of `updateLedger` and that
    /// function grew an early return: the moment the bar switched to CPU it
    /// returned before reaching this, so the card froze on whatever it had last
    /// drawn. Reported as "the card doesn't change according to the sort", and it
    /// was not that the card ignored the sort — it was that nothing told it.
    ///
    /// Falls back to the battery when the subject has no reading yet, rather than
    /// leaving the previous subject's numbers under a new heading.
    /// The rail's fan glyph, turning at the speed the fans are.
    ///
    /// Only while the window is up: this is called from `apply`, which a hidden
    /// window never reaches (see the visibility check in the sampler). So the one
    /// animation in this app that is not a response to the user is also the one
    /// that cannot run while nobody is looking.
    func updateFanSpin() {
        main.sidebar.setFanSpin(rpm: lastSystem?.fans.averageRPM ?? 0)
        // The HOTTEST reading, not the average: the rail is an alarm here, and an
        // average hides one component cooking behind five that are fine.
        let temps = [lastSystem?.cpuTemperature, lastSystem?.gpuTemperature].compactMap { $0 }
        main.sidebar.setTemperature(temps.max())
        main.sidebar.setNetworkKind(NetworkInventory.snapshot().primary?.kind)
    }

    func updateGlance(_ s: PowerMonitor.Snapshot) {
        lastCensus = bottomContext == .cpu ? MachineInfo.census() : nil
        main.glance.model = lastSystem.flatMap {
            GlanceCardView.model(for: bottomContext, system: $0,
                                 facts: MachineInfo.facts, census: lastCensus)
        } ?? GlanceCardView.model(from: s, drain: lastDrain)
    }

    /// The same range, for a subject that is a utilisation rather than a drain.
    ///
    /// One series and no right-hand axis: the battery's charge line belongs to the
    /// battery, and drawing it under a CPU curve is a fact about something else
    /// laid over the answer. The axis is pinned at 100 for the same reason the
    /// live path pins it — a percentage of a fixed whole read against an
    /// autoscaled axis makes 4 % and 40 % look identical.
    func loadUtilizationHistory(_ context: BottomContext, start: Date, end: Date) {
        guard let store else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let pts = store.utilizationSeries(since: start, until: end, maxPoints: 700)
            if context == .disk || context == .network {
                // Both directions come out of the same bucket, and each is
                // dropped independently when that bucket never measured it.
                func line(_ get: (HistoryStore.UtilizationPoint) -> Double?)
                    -> [HistoryGraphView.Point] {
                    pts.compactMap { p in
                        get(p).map { .init(time: p.time, value: Self.mib($0)) }
                    }
                }
                let isDisk = context == .disk
                let a = line { isDisk ? $0.diskReadBytesPerSec : $0.networkInBytesPerSec }
                let b = line { isDisk ? $0.diskWriteBytesPerSec : $0.networkOutBytesPerSec }
                return DispatchQueue.main.async {
                    self.graph.sharesRightAxisScale = false
                    self.graph.yMax = nil
                    self.graph.rightSeries = nil
                    self.graph.rightAxisLabel = ""
                    self.graph.rightAxisUnit = "%"
                    self.graph.series = isDisk ? Self.diskSeries(read: a, write: b)
                                               : Self.networkSeries(down: a, up: b)
                    self.graph.yAxisLabel = Self.rateAxisLabel
                }
            }
            let series = pts.compactMap { p -> HistoryGraphView.Point? in
                let v: Double?
                switch context {
                case .cpu:    v = p.cpuPercent
                case .memory: v = p.memoryPercent
                case .gpu:    v = p.gpuPercent
                // Disk returned above. Network is handled with it, and the
                // session-only subjects never reach here at all: their ranges
                // offer 1H alone, so nothing ever asks the store for them.
                // Disk and network returned above; battery has its own path. The
                // session-only subjects never reach here — `loadHistorySeries`
                // turns back before the store is asked — and if one ever does, no
                // point is better than a point on the wrong axis.
                case .battery, .disk, .network, .sensors, .fans: v = nil
                }
                // A bucket the store has no reading for yields NO point, so the
                // graph's own gap rule draws the silence. A zero here would be a
                // claim that the device was idle in a window nobody sampled.
                guard let v else { return nil }
                return .init(time: p.time, value: v)
            }
            DispatchQueue.main.async {
                self.graph.sharesRightAxisScale = false
                self.graph.yMax = 100
                self.graph.rightSeries = nil
                self.graph.rightAxisLabel = ""
                self.graph.series = [
                    .init(name: context.title.lowercased(), color: Palette.accent,
                          points: series, filled: true)
                ]
                self.graph.yAxisLabel = "% \(context.title.lowercased())"
            }
        }
    }

    /// Pull a historical range out of the store and hand it to the graph.
    ///
    /// Bucketed SQL-side to at most ~700 points, so a 7-day query costs the same
    /// as an hour and the view never receives more samples than it has pixels.
    func loadHistorySeries(start: Date, end: Date) {
        // A subject the store has never held cannot be answered from it, and
        // asking anyway is worse than not asking: the query returns nothing, the
        // caller falls through to the generic utilisation path, and a temperature
        // graph ends up titled "% TEMPERATURE" on a 0-100 axis over "no history
        // yet". Reached by clicking beside the range pill, which lands on the
        // graph and zooms it — and a zoomed graph is a historical one.
        guard !bottomContext.isSessionOnly else {
            return updateGraph(lastSnapshot, appending: false)
        }
        guard let store else { return }
        // A change of subject changes the query, not just the label. The store has
        // kept CPU, memory and GPU alongside the battery all along — see
        // `utilizationSeries` — so a week of CPU is as real as a week of drain and
        // costs the same to ask for.
        guard bottomContext == .battery else {
            return loadUtilizationHistory(bottomContext, start: start, end: end)
        }
        let scale = lastSnapshot?.scale
        DispatchQueue.global(qos: .userInitiated).async {
            let pts = store.powerSeries(since: start, until: end, maxPoints: 700)
            let series = pts.map { p -> HistoryGraphView.Point in
                // Same unit as the live chart: %/hr, not watts.
                let pctHr = scale.map { 3600 * p.watts / $0.joulesPerPercent } ?? p.watts
                return .init(time: p.time, value: pctHr)
            }
            // Battery level on the right axis for EVERY range, not just the live
            // hour. An hour is far too short to see a charge curve, which is the
            // whole reason to look at a week.
            // `onPower` is what paints the charging spans green, and it is the
            // stored fact rather than a reading of the curve's slope: a machine
            // left on the adapter at 100% draws a flat line, which no rise
            // detector can distinguish from idling unplugged.
            let charge = pts.compactMap { p -> HistoryGraphView.Point? in
                guard let soc = p.socPercent else { return nil }
                return .charge(time: p.time, percent: soc, onBattery: p.onBattery)
            }
            DispatchQueue.main.async {
                self.graph.sharesRightAxisScale = true
                self.graph.series = [.init(name: Self.drainSeriesName, color: Palette.accent, points: series)]
                self.graph.rightSeries = charge.count >= 2
                    ? .init(name: "battery", color: Palette.chargeLine,
                            points: charge, filled: true)
                    : nil
                self.graph.rightAxisLabel = charge.count >= 2 ? "battery" : ""
            }
        }
    }

    /// Named contributors to one ledger bucket, in watts.
    ///
    /// Each case reads the bucket the ledger actually draws, so the lines always
    /// sum to the segment they came from. The platform bucket has no contributors
    /// by construction — it is precisely the part no process explains — so it
    /// drills into nothing rather than into a fabricated breakdown.
    func contributors(of segment: LedgerBarView.Segment,
                      in s: PowerMonitor.Snapshot) -> [(String, Double)] {
        switch segment {
        case .apps:
            return s.apps.map { ($0.name, $0.watts) }
        case .systemProcesses:
            return s.systemApps.map { ($0.name, $0.watts) }
        case .gpu:
            return s.gpuApps.map { ($0.name, $0.watts) }
        case .memory, .storage, .usb, .display, .platform:
            // Neither drills down. The display is a single modeled quantity, and
            // the platform bucket is by definition the part no process explains.
            return []
        }
    }

    /// Distinct hues for multi-line mode. Deliberately not a gradient: adjacent
    /// lines have to be told apart, not ranked by colour.
    static func seriesColor(_ i: Int) -> NSColor {
        let palette: [NSColor] = [Palette.accent, Palette.blue, Palette.warn,
                                  Palette.chargeLine, Palette.critical,
                                  Palette.accentDim,
                                  Palette.violet, Palette.teal]
        return palette[i % palette.count]
    }

    /// The one drain figure the whole app shows, the hours it implies, and where
    /// both came from.
    ///
    /// The menu bar used to compute this from instantaneous power while the
    /// window computed it from observed discharge, and they disagreed on screen —
    /// reported as a widget and a card three inches apart giving different
    /// answers to one question, with the card noticeably steadier. Every surface
    /// reads this pair; nothing recomputes either half of it.
    ///
    /// Three tiers, best first:
    ///
    /// 1. `.discharge` — the half-hour mean of the battery's own discharge
    ///    accumulator. Charge that has already left the pack, integrated by the
    ///    hardware. It wins outright: nothing here can improve on a measurement,
    ///    and the 2x guard below exists to catch an estimator with too little
    ///    history, which this one reports as nil instead.
    /// 2. the gauge regression, guarded — it infers from `RemainingCapacity`
    ///    movement, and the gauge publishes about once a minute, so just after
    ///    unplugging it has almost nothing to fit and can report near zero, which
    ///    is how the card once claimed 200 hours. Measured power is available every
    ///    tick and cannot go stale that way, so it takes over whenever the two
    ///    disagree by more than a factor of two.
    /// 3. instantaneous power, when there is no history at all.
    ///
    /// TIME comes from `DrainEstimate.timeToEmpty` in every branch, against the
    /// charge on the mAh basis — so the rate published here and the hours published
    /// here always multiply back to the charge, whichever tier answered.
    static func reconciledRate(_ s: PowerMonitor.Snapshot, _ est: DrainEstimate?)
        -> (pctHr: Double, timeRemaining_hr: Double?, source: DrainEstimate.Source,
            windowSpan: TimeInterval) {
        let draining = s.direction == .draining
        if let e = est, e.source == .discharge, draining {
            return (e.percentPerHour, e.timeRemaining.map { $0 / 3600 }, .discharge, e.windowSpan)
        }
        let measured = s.smoothed_pctHr
        let inferred = est?.percentPerHour
        let trustInferred: Bool = {
            guard let inferred, inferred > 0 else { return false }
            guard measured > 0.05 else { return true }
            let ratio = inferred / measured
            return ratio >= 0.5 && ratio <= 2.0
        }()
        let shown = trustInferred ? (inferred ?? measured) : measured
        let hours: Double? = {
            guard draining, let st = s.state else { return nil }
            return DrainEstimate.timeToEmpty(chargePercent: s.scale.chargePercent(st),
                                             ratePctHr: shown).map { $0 / 3600 }
        }()
        // The label follows the number that was actually taken: overriding the
        // estimator with the power figure and still reporting the estimator's
        // provenance would be the same lie in a different place. `.insufficient`
        // means nothing is known yet — the UI shows "estimating…", not a number.
        let source: DrainEstimate.Source = shown > 0.01
            ? (trustInferred ? (est?.source ?? .power) : .power)
            : .insufficient
        // HOW LONG WE HAVE BEEN WATCHING — not the window of whichever number
        // won. `DrainEstimate.windowSpan` is documented as the history that has
        // ACCUMULATED, and it says so in every tier including the power-only one.
        //
        // The first version of this zeroed the span whenever the power figure was
        // taken instead of the estimator's, on the theory that such a figure "has
        // no window". Two different things were being conflated: the estimator's
        // rate being DISTRUSTED (the two disagreed by more than 2x) and there
        // being NO HISTORY. Only the second should read as still measuring, and
        // the first is not rare — on a machine where the two systematically
        // disagree it holds forever, so the estimate would have said "measuring"
        // for as long as the app ran.
        let span = est?.windowSpan ?? 0
        return (shown, hours, source, span)
    }

    /// One tick of device load, for each subject the bottom can be about.
    ///
    /// A missing reading appends NOTHING rather than a zero — the graph's own gap
    /// rule then draws the silence as a silence. A zero would be a claim that the
    /// GPU was idle during a window where nobody asked it.
    func appendUtilization(_ sys: SystemMetrics.Snapshot, at now: Date) {
        if let cpu = sys.cpu?.total {
            utilizationSeries[.cpu, default: []].append(.init(time: now, value: cpu))
        }
        if let gpu = sys.gpu?.utilization {
            utilizationSeries[.gpu, default: []].append(.init(time: now, value: gpu))
        }
        if let mem = sys.memory?.usedPercent {
            utilizationSeries[.memory, default: []].append(.init(time: now, value: mem))
        }
        // Disk is the one subject that plots TWO lines, so it does not fit the
        // one-series-per-subject buffer above and keeps its own pair.
        if let d = sys.disk {
            diskReadSeries.append(.init(time: now, value: Self.mib(d.bytesReadPerSec)))
            diskWriteSeries.append(.init(time: now, value: Self.mib(d.bytesWrittenPerSec)))
        }
        if let n = sys.network {
            netInSeries.append(.init(time: now, value: Self.mib(n.bytesInPerSec)))
            netOutSeries.append(.init(time: now, value: Self.mib(n.bytesOutPerSec)))
        }
        // Only when the SMC was actually read. A skipped sweep yields an empty fan
        // list and nil temperatures, and appending a zero for that would draw the
        // fans stopping every time the window was hidden.
        if sys.sensorsSampled {
            if !sys.fans.isEmpty {
                let load = sys.fans.averageLoad
                let rpm = sys.fans.averageRPM
                // The rpm rides ALONG with the percentage rather than replacing
                // it. The line has to be a percentage — two fans with different
                // top speeds have no shared rpm scale — but nobody reads a fan in
                // percent, so the readout says both. Recorded at the same instant
                // as the value it annotates, which is the whole reason it is
                // carried on the point.
                fanLoadSeries.append(.init(
                    time: now, value: load * 100,
                    detail: String(format: "%.0f%% · %.0f rpm", load * 100, rpm)))
            }
            if let c = sys.cpuTemperature {
                cpuTempSeries.append(.init(time: now, value: c,
                                           detail: String(format: "%.1f °C", c)))
            }
            if let g = sys.gpuTemperature {
                gpuTempSeries.append(.init(time: now, value: g,
                                           detail: String(format: "%.1f °C", g)))
            }
            // The picked sensor, off the same cached sweep the pane just did — a
            // dictionary read, not a second SMC walk. Only while one is picked and
            // only on the tab that sweeps, so it costs nothing the rest of the time.
            if let picked = sensorsPane.pickedSensor,
               let r = Sensors.temperatures().first(where: { $0.qualifiedName == picked }) {
                pickedSensorSeries.append(.init(time: now, value: r.value,
                                                detail: String(format: "%.1f °C", r.value)))
            }
            let temps = [sys.cpuTemperature, sys.gpuTemperature].compactMap { $0 }
            if !temps.isEmpty {
                let mean = temps.reduce(0, +) / Double(temps.count)
                temperatureSeries.append(.init(
                    time: now, value: mean,
                    detail: String(format: "%.1f °C", mean)))
            }
        }
    }

    /// The disk graph's two lines, built the same way whether they came from the
    /// live buffer or out of the store — the 1H view and the 6H view differing in
    /// colour or legend order is precisely the class of bug that let the live
    /// charge line stay the wrong colour for a whole release.
    static func diskSeries(read: [HistoryGraphView.Point],
                           write: [HistoryGraphView.Point]) -> [HistoryGraphView.Series] {
        [.init(name: "read", color: Palette.accent, points: read, filled: false),
         .init(name: "write", color: Palette.blue, points: write, filled: false)]
    }

    /// Network's two lines, in the same shape and for the same reason as disk's.
    ///
    /// Down before up, because that is the order the Network pane states them in
    /// and the order the numbers are usually read in.
    static func networkSeries(down: [HistoryGraphView.Point],
                              up: [HistoryGraphView.Point]) -> [HistoryGraphView.Series] {
        [.init(name: "down", color: Palette.accent, points: down, filled: false),
         .init(name: "up", color: Palette.blue, points: up, filled: false)]
    }

    /// The fan graph: speed as a percentage of each fan's own range on the left,
    /// temperature on the right — the shape the battery graph uses for rate
    /// against charge, and for the same reason. A fan spins up BECAUSE something
    /// got hot, and the two lines against a shared time axis is the whole story;
    /// on one axis, a 2200 rpm fan and a 45 °C sensor would have to share a scale
    /// that suits neither.
    ///
    /// A percentage of each fan's OWN min..max, averaged, rather than of the
    /// fastest fan's range: `FanInfo.load` is what the Fans pane's gauges already
    /// show, so the graph and the gauges above it cannot disagree.
    static func fanSeries(load: [HistoryGraphView.Point]) -> [HistoryGraphView.Series] {
        [.init(name: "fan speed", color: Palette.accent, points: load, filled: true)]
    }

    /// What the battery's own line is called, in the legend and in the hover.
    ///
    /// It was "total" — which says what the line is a total OF only to someone who
    /// already knows, and reads as a running sum to everyone else. The unit says
    /// what the number IS, which is the job of a legend sitting next to three
    /// other lines that are not it.
    ///
    /// One constant because the live path and the store-backed path both name it,
    /// and a legend that renames itself when you press 6H is the same class of
    /// drift as the charge line that was the wrong colour for only one range.
    static let drainSeriesName = "%/hr"

    /// MB, meaning 1024², to match `MetricUnit.bytesPerSecond` and the Disk and
    /// Network columns. Shared by both rate subjects so they cannot drift.
    static let rateAxisLabel = "MB/s"

    /// Bytes per second as MiB/s, which is what the disk graph plots.
    ///
    /// The axis draws bare numbers, so a byte rate has to arrive pre-scaled or the
    /// gridlines read "12000000". 1024-based to match `MetricUnit.bytesPerSecond`,
    /// which is what the Disk columns and the bar's own labels use — the axis
    /// saying "MB/s" while the column beside it means MiB/s is a 5 % lie that
    /// nobody would ever track down.
    static func mib(_ bytesPerSec: Double) -> Double { bytesPerSec / 1_048_576 }

    /// What the bottom of the window is currently about. See `BottomContext`.
    var bottomContext: BottomContext {
        BottomContext.forLens(lens, sortKey: sortKey, resource: resourcesPane.selectedResource)
    }

    /// The Resources tab draws a graph on every card plus one at the top of its
    /// rail, so the bottom one is hidden there and the space goes to the pane.
    ///
    /// A fact about the TAB, not about the subject: CPU is the same subject
    /// whether it was reached by sorting the table or by clicking a rail card, and
    /// it would be strange for one of those to come with a graph and the other not.
    var graphHidden: Bool { lens == .resources }

    /// `appending: false` redraws from the buffers WITHOUT adding a sample.
    ///
    /// Changing the sort has to redraw the bottom at once — the same lesson the
    /// Resources rail taught, where a click changed the highlight and left the
    /// readings describing the thing you clicked away from. But this function also
    /// records a tick, and calling it out of band to force a redraw would push a
    /// duplicate sample into the history for every click.
    func updateGraph(_ s: PowerMonitor.Snapshot?, appending: Bool = true) {
        guard let s else { return }
        let now = Date()
        if appending {
            totalSeries.append(.init(time: now, value: s.smoothed_pctHr))
            if let pct = s.state?.percent {
                // `onPower` is what paints the charging spans green, and the LIVE
                // series forgot it while the store-backed one (loadHistorySeries)
                // has always set it. That is why 1H drew a charging span in the
                // ordinary colour while 6H/24H/7D drew the same span green: the
                // 1H view is this in-memory buffer, the rest come from SQLite.
                //
                // `onPower` means ON THE ADAPTER, so this is `onAC` and NOT its
                // negation. The store path builds the same flag from the opposite
                // column — `onPower: !p.onBattery` — and negating `onAC` to match the
                // SHAPE of that line is a double negative: it made the 1H view claim
                // the machine was charging while it was running the battery down, and
                // the comment that used to sit here asserted the two paths agreed.
                //
                // Only 1H was affected, because only 1H comes from this buffer, which
                // is exactly why it survived the fix that was supposed to address it.
                chargeSeries.append(.charge(time: now, percent: Double(pct),
                                            onAC: s.state?.onAC ?? false))
            }
            if let sys = lastSystem {
                appendUtilization(sys, at: now)
            }
        }

        let cutoff = now.addingTimeInterval(-graphSpan)
        totalSeries.removeAll { $0.time < cutoff }
        chargeSeries.removeAll { $0.time < cutoff }
        for key in utilizationSeries.keys {
            utilizationSeries[key]?.removeAll { $0.time < cutoff }
        }
        for series in Self.sessionSeries {
            self[keyPath: series].removeAll { $0.time < cutoff }
        }

        // RECORDING IS DONE. Everything above this line happens on every tick;
        // everything below draws.
        //
        // A historical or zoomed view is not a live chart — ticking new points
        // into it would make the line creep rightward under a fixed axis and
        // overwrite what the user asked to look at. So the DRAWING stops here.
        //
        // The recording must not, and used to. This guard sat at the top of the
        // function, so while the graph was zoomed nothing was appended to any live
        // buffer. For the persisted subjects that is invisible — the store kept
        // collecting and the gap fills itself on the way back. For temperatures
        // and fan speeds there is no store, so the hole was permanent: reported as
        // "while I was on that invisible option graph, it stopped collecting temp
        // data", and the graph drew a two-minute break to say so.
        //
        // Which is the general rule this got wrong: what the app RECORDS cannot
        // depend on what it happens to be SHOWING.
        guard graphRange <= 3600, graphDomainOverride == nil else { return }

        // Accumulate per-contributor history whenever a bucket is drilled into.
        if let seg = graphSegment {
            for (name, watts) in contributors(of: seg, in: s) {
                segmentSeries[name, default: []]
                    .append(.init(time: now, value: 3600 * watts / s.scale.joulesPerPercent))
            }
            for k in segmentSeries.keys {
                segmentSeries[k]?.removeAll { $0.time < cutoff }
                if segmentSeries[k]?.isEmpty ?? true { segmentSeries.removeValue(forKey: k) }
            }
        } else if !segmentSeries.isEmpty {
            segmentSeries.removeAll()
        }

        if let seg = graphSegment {
            // Top contributors only. Every process that ever twitched would be a
            // hairball, and the ones below the floor are individually invisible on
            // the axis anyway.
            let ranked = segmentSeries
                .map { (name: $0.key, pts: $0.value, last: $0.value.last?.value ?? 0) }
                .filter { $0.last >= Settings.shared.minimumDisplayPercentPerHour }
                .sorted { $0.last > $1.last }
                .prefix(8)
            graph.series = ranked.enumerated().map { i, r in
                .init(name: r.name, color: Self.seriesColor(i), points: r.pts, filled: false)
            }
            graph.yAxisLabel = "%/hr · \(seg.title)"
        } else if bottomContext == .network {
            graph.series = Self.networkSeries(down: netInSeries, up: netOutSeries)
            graph.yAxisLabel = Self.rateAxisLabel
        } else if bottomContext == .fans {
            graph.series = Self.fanSeries(load: fanLoadSeries)
            graph.yAxisLabel = "% fan speed"
        } else if bottomContext == .sensors {
            // Average first so it reads as the headline, with the two the machine
            // reports by name behind it. Filled would be three washes over each
            // other; see the disk graph for the same call.
            var series: [HistoryGraphView.Series] = [
                .init(name: "average", color: Palette.accent,
                      points: temperatureSeries, filled: false),
                .init(name: "cpu", color: Palette.blue, points: cpuTempSeries, filled: false),
                .init(name: "gpu", color: Palette.violet, points: gpuTempSeries, filled: false),
            ]
            // The picked one LAST so it draws over the averages it is being
            // compared against, and in the warn ink so it reads as the singled-out
            // line rather than as a fourth average.
            if let picked = sensorsPane.pickedSensor, !pickedSensorSeries.isEmpty {
                series.append(.init(name: picked, color: Palette.warn,
                                    points: pickedSensorSeries, filled: false))
            }
            graph.series = series
            graph.yAxisLabel = "°C"
        } else if bottomContext == .disk {
            // Two lines, unfilled. A filled area under both would put one
            // translucent wash on top of another and the overlap would read as a
            // third value; the battery graph fills because it has one left-hand
            // series to fill.
            graph.series = Self.diskSeries(read: diskReadSeries, write: diskWriteSeries)
            graph.yAxisLabel = Self.rateAxisLabel
        } else if bottomContext != .battery {
            // The subject the table is sorted by. See `BottomContext`: the sort is
            // the user saying what the question is, and the bottom answers that
            // question rather than the one the app happens to be named after.
            let context = bottomContext
            graph.series = [
                .init(name: context.title.lowercased(), color: Palette.accent,
                      points: utilizationSeries[context] ?? [], filled: true)
            ]
            graph.yAxisLabel = "% \(context.title.lowercased())"
        } else {
            // One series: total drain. The attributed-versus-unaccounted split
            // already has a home in the ledger bar directly above, and drawing it
            // twice turned a glanceable trend into something you had to decode.
            graph.series = [
                .init(name: Self.drainSeriesName, color: Palette.accent,
                      points: totalSeries, filled: true)
            ]
            graph.yAxisLabel = "%/hr"
        }
        // BOTH OF THESE ARE ABOUT THE BATTERY and neither survives a change of
        // subject.
        //
        // The charge line is a second series on a second axis, there so a drop can
        // be read against the spike that caused it. On a CPU graph it is a fact
        // about something else, drawn over the answer.
        //
        // And the shared 0-100 scale exists because %/hr and % are commensurable —
        // a drain line level with the 50 % gridline means half the battery in an
        // hour. A CPU graph is already a percentage of a fixed whole, so it pins
        // its own axis at 100 instead: an autoscaled utilisation graph makes 4 %
        // and 40 % look identical, and the height is the entire reading.
        // Set on EVERY branch, including the empty case. This used to be left
        // untouched by the live path, so it kept whatever the last history load
        // had written — which was invisible while battery was the only subject
        // with a right axis and becomes "°C" labelling a battery axis the moment
        // there are two.
        if bottomContext == .battery {
            graph.sharesRightAxisScale = true
            graph.yMax = nil
            graph.rightSeries = chargeSeries.isEmpty ? nil
                // Filled, like every other line alone on its axis. It is cut by
                // the drain fill below it, so the charge line's wash stops where
                // that one starts instead of the two stacking.
                : .init(name: "charge", color: Palette.chargeLine,
                        points: chargeSeries, filled: true)
            graph.rightAxisLabel = chargeSeries.count >= 2 ? "battery" : ""
            graph.rightAxisUnit = "%"
        } else if bottomContext == .fans {
            // Temperature on the right axis, fan speed on the left: the shape the
            // battery graph uses for rate against charge. NOT a shared scale —
            // 100 % of a fan's range and 100 °C are not commensurable, and the
            // battery's two ARE (a drain line level with the 50 % gridline means
            // half the battery in an hour), which is the entire reason that one
            // shares.
            graph.sharesRightAxisScale = false
            graph.yMax = 100
            graph.rightAxisLabel = "°C"
            graph.rightAxisUnit = "°C"
            graph.rightSeries = temperatureSeries.isEmpty ? nil
                // Filled, like every other line that is alone on its axis. It is
                // cut by the fan-speed fill underneath it, so the two never stack
                // into a third apparent value.
                : .init(name: "temp", color: Palette.warn,
                        points: temperatureSeries, filled: true)
        } else {
            graph.sharesRightAxisScale = false
            // A rate has no ceiling to pin to. Pinning disk at 100 would draw
            // every ordinary moment as a flat line on the floor and clip the one
            // burst worth looking at.
            graph.yMax = bottomContext.isPercentage ? 100 : nil
            graph.rightSeries = nil
            graph.rightAxisLabel = ""
            graph.rightAxisUnit = "%"
        }
    }

    func updateDetail() {
        // Resolve by NAME, never by the current row index.
        guard let name = selectedAppName,
              let row = rows.first(where: { $0.name == name }),
              let snap = lastSnapshot else {
            main.setDetailVisible(false)
            return
        }
        // A system row has no process behind it, so there is nothing for the
        // inspector to show and nothing to quit. Closing the pane is honest;
        // showing an empty one reads as a bug.
        guard let app = row.app else {
            main.setDetailVisible(false)
            return
        }
        inspector.model = InspectorView.model(app: app, snapshot: snap)
        main.setDetailVisible(true)
    }

    @objc func tableClicked() {}   // selection change does the work

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRestoringSelection else { return }
        let sel = main.table.selectedRow
        selectedAppName = (sel >= 0 && sel < rows.count) ? rows[sel].name : nil
        updateDetail()
    }

    /// Sort by whatever the clicked column says it sorts by.
    ///
    /// Read from the SAME `ProcessColumn` the cell was drawn from, so a column can
    /// never display one quantity and order by another. A nil `value` — no reading
    /// for this row — ranks below every real number in both directions, because a
    /// genuine zero is a measurement and "not measurable here" is not.
    func sortRows() {
        let asc = ascending
        let column = columnsByID[sortKey] ?? columnsByID[ProcessColumns.defaultSortKey]
        // Name sorts alphabetically; nothing else does.
        if let string = column?.stringValue {
            rows.sort { a, b in
                let r = string(a).localizedCaseInsensitiveCompare(string(b)) == .orderedAscending
                return asc ? r : !r
            }
            return
        }
        guard let value = column?.value else { return }
        rows.sort { a, b in
            switch (value(a), value(b)) {
            case let (x?, y?): return asc ? x < y : x > y
            // A missing reading always sinks, whichever way the arrow points.
            case (nil, _?):    return false
            case (_?, nil):    return true
            case (nil, nil):   return a.name.localizedCaseInsensitiveCompare(b.name)
                                    == .orderedAscending
            }
        }
    }

    // The main menu lives in AppMenu.swift: it grew from one submenu to five, and
    // the Edit menu it now carries is what makes ⌘C/⌘V work at all.

    /// Push the latest readings into whichever whole-machine pane is showing.
    func refreshPane() {
        guard !lens.isPerProcess, let sys = lastSystem else { return }
        switch lens {
        case .resources:
            resourcesPane.update(sys, power: lastSnapshot)
        case .network:
            // Only refreshed while the pane is actually visible: nettop blocks for
            // ~5 s per sample, and spawning it forever for a pane nobody is looking
            // at is precisely the idle cost this app exists to avoid.
            netAttribution.refreshIfNeeded()
            networkPane.update(sys.network,
                               perProcess: netAttribution.latest,
                               age: netAttribution.age)
        // `sensorsSampled` distinguishes "the SMC was not read on this tick"
        // from "the SMC reported nothing". A hidden tick skips the sweep, so
        // without it a reopened window shows a two-fan machine as fanless.
        // SensorsPane drives its own SMC sweep through SensorCache and renders a
        // missing temperature as "—", so it needs no such flag.
        case .sensors: sensorsPane.update(cpu: sys.cpuTemperature, gpu: sys.gpuTemperature)
        case .fans:    fansPane.update(sys.fans, sampled: sys.sensorsSampled)
        default: break
        }
    }

    /// Where a menu bar widget takes you.
    ///
    /// Derived from the MetricID constants, never from their raw strings, so
    /// retiring or renaming a metric is a compile error here rather than a widget
    /// that quietly stops navigating. nil means "this widget names no
    /// destination" — the group widget, or an ID written by another build — and
    /// the caller must then leave the lens alone rather than invent one.
    static func lens(forWidget metric: MetricID) -> SidebarView.Lens? {
        switch metric {
        // Every whole-machine utilisation is now one tab. The old rail sent each of
        // these to its own lens, and each of those lenses was the process table with
        // a different column — so a CPU widget click landed on a list of processes
        // rather than on the CPU. Resources is where that number actually lives.
        case .cpuUsage, .memoryUsage, .gpuUsage,
             .diskRead, .diskWrite, .diskActivity: return .resources
        case .networkDown, .networkUp, .networkThroughput: return .network
        case .cpuTemperature, .gpuTemperature: return .sensors
        // Fans, not Sensors. The Sensors pane shows temperatures and nothing
        // else, so a fan-speed click sent there lands on a pane that does not
        // contain the number just clicked. Fans has exactly that number.
        case .fanSpeed: return .fans
        // The group widget owns its click (AppKit opens its menu instead), so
        // this is unreachable — stated anyway so the intent is not inferred from
        // the absence of a case.
        case .groupPlaceholder: return nil
        // Sampler health is not a reading of the machine, so no lens explains it
        // and there is nowhere to send the click.
        case .samplerDrops: return nil
        default:
            // The whole battery family — drain, charge, time left, GPU drain,
            // unattributed share, coverage, and any added later — is answered by
            // the process table: "what is draining it" is a per-app question, and
            // the ledger, glance card and history graph that answer the rest of it
            // are on screen under every tab. Compared by family taken from a
            // constant, so the prefix is not spelled out a second time here.
            return metric.family == MetricID.batteryPercent.family ? .processes : nil
        }
    }

    /// A menu bar widget was clicked. Ends with the window visible, frontmost and
    /// showing what that widget measures.
    ///
    /// SHOW, not toggle, whenever the destination differs from what is on screen.
    /// Clicking the CPU widget while the window sits on Memory is a request to
    /// see CPU, and `toggle()` would answer that navigation by hiding the window.
    /// Clicking the widget for the lens already showing keeps the toggle, which
    /// is what lets a second click on the same widget put the window away again.
    func openFromWidget(_ metric: MetricID?) {
        guard let metric,
              let lens = Self.lens(forWidget: metric),
              // A fan-speed widget on a machine whose Fans tab is hidden names a
              // destination that is not there. Opening the window is what a
              // widget with no destination already does, and it beats navigating
              // to a tab the rail cannot show the user how to leave.
              SidebarView.Lens.displayOrder.contains(lens),
              lens != main.sidebar.selected else {
            main.toggle()
            return
        }
        // Through the rail rather than straight into select(): the rail owns
        // `selected` and the highlight, so switching around it would leave the
        // old row lit beside the new content. Its select() calls back into ours.
        main.sidebar.select(lens)
        // After the lens, so the window never appears on the outgoing one first.
        main.show()
        // The window was most likely hidden, where the sampler deliberately runs
        // at `hiddenInterval`. Without this the lens just opened can sit on
        // values several seconds stale — which reads as a click that did nothing.
        restartTimer(hidden: false)
    }

    /// Tab switch.
    ///
    /// Switching now changes which SUBSYSTEMS are sampled, not just what is drawn:
    /// the next tick reads `visibleNeeds`, which is derived from this. A tab is
    /// therefore also a statement about what the app is allowed to cost while it is
    /// open — see `visibleNeeds`.
    func select(_ lens: SidebarView.Lens) {
        let before = bottomContext
        self.lens = lens
        // The bottom follows the TAB now, so a tab change moves it exactly as a
        // sort change does — and for the same reason: two seconds of a graph
        // describing the tab you just left is the defect the Resources rail
        // taught, one level up.
        if bottomContext != before { retargetBottom() }

        // Whole-machine tabs get their own pane; there is no honest per-process
        // view of network traffic or fan speed.
        guard lens.isPerProcess else {
            switch lens {
            case .resources: main.showPane(resourcesPane)
            case .network:   main.showPane(networkPane)
            case .sensors:   main.showPane(sensorsPane)
            case .fans:      main.showPane(fansPane)
            case .processes: main.showPane(nil)
            }
            refreshPane()
            return
        }
        main.showPane(nil)
        main.table.reloadData()
        autosizeColumns()
        updateDetail()
    }

    /// Exactly the subsystems something on screen is reading.
    ///
    /// This used to be `.all` for every visible tick, whatever the window was
    /// showing. That was affordable when the tabs were five re-columnings of one
    /// table; it is not the rule to keep now that one tab genuinely wants
    /// everything, because "Resources needs it" would otherwise become "every tab
    /// pays for it".
    ///
    /// The cheap readings are taken regardless: CPU ticks, VM statistics, the
    /// interface table and the block-storage counters are one syscall or one
    /// IOKit read each, and taking them keeps the rail's tooltips live and the
    /// graphs continuous across a tab switch. The SMC sweep is the one that is
    /// gated, because it is the one that was MEASURED to matter — walking the key
    /// set doubled idle CPU (0.375% → 0.727%) on its own.
    var visibleNeeds: SystemMetrics.Needs {
        var needs: SystemMetrics.Needs = [.cpu, .memory, .gpu, .network, .disk]
        needs.formUnion(lens.needs)
        // A widget bound to a temperature still has to be fed while the window is
        // open on a tab that does not show one.
        needs.formUnion(hiddenNeeds)
        return needs
    }

    /// True when a menu bar widget is bound to a sensor metric, so the sampler
    /// knows whether the SMC read is worth doing while the window is closed.
    var needsSensors: Bool { hiddenNeeds.contains(.sensors) }

    /// Exactly the subsystems the menu bar is currently displaying.
    ///
    /// Generalises what `needsSensors` already did for the SMC to every source:
    /// with the window closed the only reader is the widget set, so anything not
    /// bound to a widget is work done for nobody. The group widget is the one
    /// exception — it can expand to show everything, so it asks for everything.
    var hiddenNeeds: SystemMetrics.Needs {
        // Master switch off and the window closed: nothing displays a utilisation
        // figure, so nothing is sampled for one. Read from Settings rather than
        // from the controller because this runs on the sampling queue and the
        // controller's flag is main-thread state.
        guard Settings.shared.menuBarWidgetsEnabled else { return [] }
        var needs: SystemMetrics.Needs = []
        for c in widgets.configs where c.enabled {
            if c.metricID == MetricID.groupPlaceholder.rawValue {
                // Everything EXCEPT sensors. The group can expand to show any
                // metric, but sensors mean walking thousands of SMC keys, and
                // paying that on every tick for a group that is usually collapsed
                // measurably doubled idle CPU (0.375% -> 0.727%). Temperatures
                // appear when a sensor widget is bound, which is the same rule the
                // SMC read has always followed.
                needs.formUnion([.cpu, .memory, .gpu, .network, .disk])
                continue
            }
            switch c.metricID {
            case MetricID.cpuUsage.rawValue:
                needs.insert(.cpu)
            case MetricID.memoryUsage.rawValue:
                needs.insert(.memory)
            case MetricID.gpuUsage.rawValue:
                needs.insert(.gpu)
            case MetricID.networkDown.rawValue, MetricID.networkUp.rawValue,
                 MetricID.networkThroughput.rawValue:
                needs.insert(.network)
            case MetricID.diskRead.rawValue, MetricID.diskWrite.rawValue,
                 MetricID.diskActivity.rawValue:
                needs.insert(.disk)
            case MetricID.cpuTemperature.rawValue, MetricID.gpuTemperature.rawValue,
                 MetricID.fanSpeed.rawValue:
                needs.insert(.sensors)
            default:
                break   // a battery metric: served by the monitor, not from here
            }
        }
        return needs
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    /// Hand the fans back on the way out.
    ///
    /// This closes the socket rather than sending a goodbye, which means quitting
    /// and crashing take the identical path: the helper releases the fans when
    /// its client disappears either way. The disaster path is then the one
    /// exercised every time the app is closed normally, instead of the one nobody
    /// runs until it matters. AppKit does not call this for a crash or a SIGKILL,
    /// which is exactly why the release cannot live only here.
    func applicationWillTerminate(_ note: Notification) {
        fansPane.teardown()
        drain.persistedTrend().save()
    }

    /// Closing the window leaves the app alive in the menu bar, so activating it
    /// again — Dock icon, Finder, ⌘-Tab — must bring the window back. Without this
    /// the app appears to launch and do nothing, because AppKit does not reopen a
    /// window it did not create from a nib.
    ///
    /// This is also the second way back that "Start in the menu bar only" relies
    /// on and its caption promises: opening an already-running BetterStats from
    /// Finder does not start a second copy, it arrives here — so a user who
    /// launched headless and expected a window gets one by doing the obvious
    /// thing again. LaunchServices sends the reopen event whatever the activation
    /// policy is, so this works while the app is `.accessory` and invisible.
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
        let before = bottomContext
        sortKey = k
        ascending = d.ascending
        sortRows()
        tv.reloadData()
        main.refreshSortIndicators()

        // The bottom follows the sort, so it redraws NOW rather than on the next
        // tick. Two seconds of three panels describing the column you just sorted
        // away from is the same defect the Resources rail had.
        //
        // Only when the SUBJECT changed: sorting by name and by process count are
        // both battery, and rebuilding the graph for that would be work nobody
        // asked for and a visible flicker.
        guard bottomContext != before else { return }
        retargetBottom()
    }

    /// Point the whole bottom at the current subject, NOW rather than on the next
    /// tick. Called from both things that can change the subject — the sort and
    /// the tab.
    func retargetBottom() {
        let context = bottomContext
        main.setGraphHidden(graphHidden)

        // Offer only the ranges this subject can answer. Temperatures and fan
        // speeds exist for this session alone, so a 7D button on them would
        // promise a week and draw an empty plot.
        main.graphRanges.setRanges(context.ranges)
        // ONE owner for this. Two reasons to hide it — no graph at all, or a
        // subject with a single range — and both are decided here rather than
        // half here and half in the window controller.
        main.graphRanges.isHidden = graphHidden || !main.graphRanges.isWorthShowing
        if !context.ranges.contains(graphRange), let first = context.ranges.first {
            graphRange = first
            graphDomainOverride = nil
            main.graphRanges.select(seconds: first)
        }

        if let s = lastSnapshot {
            updateLedger(s)
            updateGlance(s)
        }
        if graphRange > 3600 || graphDomainOverride != nil {
            let end = Date()
            loadHistorySeries(start: end.addingTimeInterval(-graphRange), end: end)
        } else {
            updateGraph(lastSnapshot, appending: false)
        }
    }

    /// What a cell says, from the column's own definition.
    ///
    /// One lookup, not a second switch: the sizer measures exactly what the renderer
    /// draws, because both call this and this calls the closure the column was built
    /// with. The spacer has no definition and says nothing.
    func cellText(_ r: Row, _ id: String) -> (text: String, dim: Bool) {
        guard let column = columnsByID[id] else { return ("", true) }
        return column.text(r)
    }

    private func font(for id: String, isApp: Bool) -> NSFont {
        // Monospaced DIGITS for every numeric column so figures line up down the
        // table; the name is proportional because it is prose, and bold when the
        // row is an application rather than a daemon.
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
    /// Header attributes for measurement — the same font, case and kerning
    /// `BetterStatsHeaderCell` draws with, so a column is never sized to a string
    /// nobody renders.
    private static let headerAttributes: [NSAttributedString.Key: Any] = [
        .font: BetterStatsHeaderCell.font, .kern: 0.4,
    ]

    /// Widen columns to fit, measuring only the rows actually on screen.
    ///
    /// This measured EVERY row for EVERY column on every tick — ~240 text
    /// measurements a couple of times a second for a table where the off-screen
    /// rows, by definition, nobody is looking at.
    ///
    /// Measuring only the visible rows is safe here precisely because widths
    /// only ever GROW (the comparison below never shrinks a column). A wider row
    /// scrolled into view widens its column at that point and it stays widened,
    /// so the layout converges to the same place the exhaustive version reached
    /// immediately — it just gets there by looking at what it was shown.
    func autosizeColumns() {
        let visible = main.table.rows(in: main.table.visibleRect)
        // An empty range means the table has not been laid out yet (zero-height
        // visibleRect on first load). Fall back to the full set for that one
        // pass, or the columns would size to their headers and stay there.
        let range: Range<Int> = visible.length > 0
            ? visible.lowerBound..<min(visible.upperBound, rows.count)
            : 0..<rows.count

        for column in main.table.tableColumns {
            let id = column.identifier.rawValue
            guard id != ProcessColumns.spacerID else { continue }

            var widest = (column.title.uppercased() as NSString)
                .size(withAttributes: Self.headerAttributes).width
            // The sort indicator AppKit draws sits inside the header cell, so a
            // column sized exactly to its title truncates the moment it is sorted.
            widest += 12

            for i in range where i < rows.count {
                let r = rows[i]
                let (text, _) = cellText(r, id)
                let w = (text as NSString)
                    .size(withAttributes: [.font: font(for: id, isApp: r.isApp)]).width
                widest = max(widest, w)
            }

            let target = ceil(widest) + (id == "name" ? 22 : 16)
            if target > column.width + 1 { column.width = target }
        }
    }

    /// Cells are REUSED, not rebuilt.
    ///
    /// This used to allocate an NSTextField, an NSTableCellView and three
    /// constraints for every cell it was asked for — and it is asked for every
    /// visible cell after every reload, which is every couple of seconds while
    /// the window is open. At ~40 rows across 6 columns that is ~240 views and
    /// ~720 constraints built and thrown away per tick, plus the Auto Layout
    /// solve for all of them. An app whose premise is not costing what it
    /// measures cannot spend that on redrawing a table whose text is all that
    /// changed.
    ///
    /// The reuse key is the COLUMN identifier, which is what makes this safe:
    /// everything set at construction time (alignment, leading inset) depends
    /// only on the column, so a recycled cell can never arrive carrying another
    /// column's geometry. Everything that depends on the ROW — string, font,
    /// colour — is reassigned on every pass below, including in the branch that
    /// just created the cell, so there is exactly one place that decides how a
    /// cell looks and no path that skips it.
    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count, let col else { return nil }
        let id = col.identifier.rawValue
        if id == ProcessColumns.spacerID {
            if let v = tv.makeView(withIdentifier: col.identifier, owner: self) { return v }
            let v = NSView()
            v.identifier = col.identifier
            return v
        }
        let r = rows[row]
        let (text, dim) = cellText(r, id)

        let cell: NSTableCellView
        if let reused = tv.makeView(withIdentifier: col.identifier, owner: self)
            as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = col.identifier
            let label = NSTextField(labelWithString: "")
            label.alignment = id == "name" ? .left : .right
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            // A bare NSTextField is pinned to the top of its cell, so every row
            // read as sitting high against its own separator. Centring it is the
            // fix.
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor,
                                               constant: id == "name" ? 10 : 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        guard let label = cell.textField else { return cell }
        label.stringValue = text
        label.font = font(for: id, isApp: r.isApp)
        // System rows take the same colour the ledger bar gives its "system
        // processes" segment, so the link is visual rather than something the
        // user has to be told: these rows ARE that segment, itemised. It also
        // keeps them from reading as ordinary measured rows, which they are not.
        label.textColor = r.isModeled && id == "name" ? Palette.accentDim
                                                      : (dim ? Palette.dim : Palette.text)
        // The row's own tooltip carries what a truncated name cannot: the full
        // name, and — for a row that has no measured process behind it — the fact
        // that its battery figure is a share of a bucket rather than a reading.
        if id == "name" {
            let tip = r.isModeled
                ? "\(r.name)\nApportioned from Apple's coalition rollup — this row has no "
                + "process this app can read, so its battery figure is a modeled share."
                : r.name
            if label.toolTip != tip { label.toolTip = tip }
        }
        return cell
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Before run(), not inside applicationDidFinishLaunching: the policy set here is
// the one the first frame is drawn under, so a menu-bar-only start never shows a
// Dock tile at all rather than showing one and taking it away.
app.setActivationPolicy(
    AppPresence.launchActivationPolicy(
        startInMenuBarOnly: Settings.shared.startInMenuBarOnly,
        widgetsEnabled: Settings.shared.menuBarWidgetsEnabled))
app.run()

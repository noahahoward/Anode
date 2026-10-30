import AppKit
import PowerKit

// Anode — milestone 1.
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
    /// The Forecast Check window, created on first use from View → Developer Tools.
    var forecastCheck: ForecastCheckWindowController?
    /// The Anode Stats window, created on first use from View → Developer Tools.
    var anodeStats: AnodeStatsWindowController?
    /// The black strip behind the menu bar. Lives as long as the app does.
    var menuBarBackdrop: MenuBarBackdrop?
    var windowSwitcher: WindowSwitcher?
    var dockPreviews: DockPreviews?
    var desktopSwitcher: DesktopSwitcher?
    var temperatureAlarm = TemperatureAlarm()
    /// The Beta Features window (Settings → Beta Features…), created on first use.
    lazy var betaFeaturesWindow = BetaFeaturesWindowController()
    /// Time left = charge ÷ the mean drain since the lid was last opened.
    let drain = DrainRateEstimator(trend: .sinceLidOpened())
    /// Throttles the trend's crash-insurance write. See the call site.
    var lastTrendSave = Date.distantPast
    /// The most recent estimate, computed on the sampling queue beside the
    /// `record` that produced it and then handed to the main thread as a value.
    /// `DrainRateEstimator` is not thread-safe and `record` does not run on main,
    /// so calling `estimate()` from a UI path was reading a buffer while the
    /// sampler mutated it.
    var lastDrain: DrainEstimate?
    /// What this machine usually draws and how long heavy stretches last, learned
    /// over its whole life on battery. Owned by the SAMPLING queue — read and
    /// written only there, and handed to main as a `DrainPrior` value. nil on a
    /// Mac with no battery. See `LifetimeDrainModel`.
    var lifetime: LifetimeDrainModel?
    /// The prior that came with `lastDrain`, for `apply`.
    var lastPrior: DrainPrior?
    /// `LifetimeDrainModel.allTimeMean_W` as of `lastDrain`, for `apply`.
    var lastAllTime_W: Double?
    /// The trailing mean behind the "Drain" figure — see `RecentDrain`. Owned
    /// by the sampling queue, like `lifetime`; `lastRecent_W` is main's copy.
    var recentDrain = RecentDrain()
    var lastRecent_W: Double?
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
    let sampling = DispatchQueue(label: "com.anode.sampling", qos: .utility)
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
        \.pickedSensorSeries, \.unattributedSeries, \.coverageSeries,
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
    /// Live buffers for the ledger graph's session-only lines that nothing else
    /// already keeps (fan speed is `fanLoadSeries`). Percentages, 0-100.
    var unattributedSeries: [HistoryGraphView.Point] = []
    var coverageSeries: [HistoryGraphView.Point] = []
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
        // The lifetime model: this Mac's, or a cold start. A macOS update since
        // it was saved starts a new baseline — see `adopt(osBuild:)`.
        if let design = Battery.scale()?.designCapacity_mAh {
            sampling.async { [weak self] in
                let machine = LifetimeDrainModel.hostModel()
                var m = LifetimeDrainModel.fileURL().flatMap {
                    LifetimeDrainModel.load(from: $0, machineModel: machine,
                                            designCapacity_mAh: design)
                } ?? LifetimeDrainModel(machineModel: machine, designCapacity_mAh: design,
                                        osBuild: LifetimeDrainModel.hostOSBuild())
                m.adopt(osBuild: LifetimeDrainModel.hostOSBuild())
                self?.lifetime = m
            }
        }

        // The write-rate basis: (bytes written, wall clock) captured the first time
        // this app ever saw this drive, then left alone for a month. It is a LAUNCH
        // that anchors and deliberately not a metric provider — a provider that wrote
        // would anchor the machine merely because something drew a menu, including
        // the menus GroupMenuTests and PanelEditorTests draw. See `SSDWriteAnchor`.
        //
        // Off the main thread: this is the one storage reading that comes from an
        // IOKit user client rather than a sysctl, and it was measured at 12.95 ms
        // while the drive is busy — most of a frame. Nothing waits on the result.
        DispatchQueue.global(qos: .utility).async {
            if let s = NVMeHealth.read() {
                SSDWriteAnchor.shared.observe(bytesWritten: s.bytesWritten)
            }
        }

        buildMenu()
        menuBarBackdrop = MenuBarBackdrop(appearanceButton: { [weak self] in self?.widgets?.appearanceButton })
        windowSwitcher = WindowSwitcher()
        dockPreviews = DockPreviews()
        desktopSwitcher = DesktopSwitcher()

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
            updateGraph(lastSnapshot)
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
            self?.applyGraphRange(seconds)
        }
        main.graphSettings.onPress = { PreferencesWindowController.shared.showGraph() }

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
        // Sample at the panel's needs the moment it opens, rather than showing
        // whatever the last hidden tick happened to collect and correcting it up to
        // eight seconds later. `refresh` re-reads the needs and re-paces the timer,
        // so both halves follow from this one call.
        widgets.onPanelVisibilityChange = { [weak self] _ in self?.refresh() }
        widgets.onPlacementChange = { [weak self] placement in
            self?.menuBarPlacementChanged(placement)
        }
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
            offerAutoUpdate()
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
                    self.restartTimer(hidden: !self.windowIsWorthDrawing)
                }
            })
        settingsTokens.append(
            Settings.shared.observe(Settings.Key.menuBarWidgetsEnabled) { [weak self] in
                self?.applyMenuBarSwitch()
            })
        // Ticking a line in Settings → Graph has to show at once, not at the next
        // tick or the next press of a range button.
        settingsTokens.append(
            Settings.shared.observe(Settings.Key.ledgerGraphLines) { [weak self] in
                DispatchQueue.main.async { self?.redrawLedgerGraph() }
            })

        // Uncovering the window has to wake the sampler NOW, not up to eight
        // seconds later. AppKit posts this the moment a window is covered or
        // revealed, so the cadence follows the window rather than a poll — and
        // the immediate refresh means a window brought forward is already
        // current when it lands rather than showing the last background tick.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: main.window, queue: .main) { [weak self] _ in
                guard let self else { return }
                let awake = self.windowIsWorthDrawing
                self.restartTimer(hidden: !awake)
                if awake { self.refresh() }
            }
        // The trailing-window column is TITLED from this setting, so a change has to
        // reach the header. Without it the column would keep saying "10 HR POWER"
        // over a two-hour figure.
        settingsTokens.append(
            Settings.shared.observe(Settings.Key.powerWindowHours) { [weak self] in
                DispatchQueue.main.async { self?.rebuildColumnsIfNeeded() }
            })
    }

    /// Redraw the bottom graph after its line selection changed: from the store when
    /// it is showing a longer or zoomed range, from the live buffers otherwise.
    func redrawLedgerGraph() {
        guard bottomContext == .battery else { return }
        if graphRange > 3600 || graphDomainOverride != nil {
            let d = graph.timeDomain
                ?? (start: Date().addingTimeInterval(-graphRange), end: Date())
            loadHistorySeries(start: d.start, end: d.end)
        } else {
            updateGraph(lastSnapshot)
        }
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
        widgets.setEnabled(Settings.shared.menuBarWidgetsEnabled)
        AppPresence.settle()
    }

    /// Ask, once ever, whether Anode should keep itself up to date.
    ///
    /// Only on a launch that shows the window, and as a sheet on it: the
    /// question needs somewhere to be, and saying yes reads the checkout, which
    /// for one under Downloads raises a consent prompt that needs the same. A
    /// launch that cannot host it leaves the question unasked for the next one.
    /// A build with no checkout to pull into is never asked at all.
    private func offerAutoUpdate() {
        guard !Settings.shared.autoUpdatePromptSeen, AutoUpdater.shared.isAvailable else { return }
        // After the window is up — `bringForward` presents on a later turn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.main.window.isVisible,
                  !Settings.shared.autoUpdatePromptSeen else { return }
            let alert = NSAlert()
            alert.messageText = "Keep Anode up to date automatically?"
            alert.informativeText =
                "Each time Anode starts, it can check GitHub for changes. If "
                + "there are any it rebuilds itself from your checkout first, showing a "
                + "progress bar, then opens.\n\n"
                + "You can change this under Settings \u{203A} General."
            alert.addButton(withTitle: "Turn On")
            alert.addButton(withTitle: "Not Now")
            alert.beginSheetModal(for: self.main.window) { answer in
                Settings.shared.autoUpdatePromptSeen = true
                guard answer == .alertFirstButtonReturn else { return }
                Settings.shared.autoUpdateEnabled = true
                AutoUpdater.shared.confirmAccess()
            }
        }
    }

    /// Whether the user has already been told, this session, that macOS is not
    /// showing the widgets. Once is information; every screen change is nagging.
    private var toldAboutHiddenMenuBar = false

    /// macOS started or stopped showing the widgets.
    ///
    /// The invariant in `AppPresence` — always something to click — was kept by
    /// assuming a created status item is a visible one. On a full menu bar it is
    /// not, and an `.accessory` app whose widgets macOS dropped is an app with no
    /// window, no Dock tile and no menu: running, and unreachable. So the moment
    /// the controller reports that nothing is on screen, the Dock tile comes back
    /// and the user is told why, once.
    private func menuBarPlacementChanged(_ placement: MenuBarWidgetController.Placement) {
        guard !placement.isReachable else { return }
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        guard !toldAboutHiddenMenuBar,
              !UserDefaults.standard.bool(forKey: Self.hiddenMenuBarAlertSuppressedKey)
        else { return }
        toldAboutHiddenMenuBar = true
        main.show()
        let alert = NSAlert()
        if placement == .notAllowed {
            alert.messageText = "Anode is switched off in the menu bar"
            alert.informativeText =
                "macOS is hiding every Anode widget because Anode is turned off under "
                + "System Settings \u{203A} Menu Bar \u{203A} Allow in the Menu Bar.\n\n"
                + "Turn it on there and the widgets appear straight away. Until then "
                + "Anode keeps its Dock icon."
        } else {
            alert.messageText = "The menu bar is too full for Anode"
            alert.informativeText =
                "macOS drops menu bar items that don\u{2019}t fit, without an overflow "
                + "menu. Anode already shrank its widgets to a single item and even that "
                + "did not fit.\n\n"
                + "Quit a menu bar app you don\u{2019}t need, hide some system items under "
                + "System Settings \u{203A} Menu Bar, or choose \u{201C}More Space\u{201D} "
                + "in System Settings \u{203A} Displays. Until then Anode keeps its Dock icon."
        }
        alert.addButton(withTitle: "Open Menu Bar Settings")
        alert.addButton(withTitle: "OK")
        // Settings › Menu Bar carries the same verdict permanently, so the
        // alert can be declined for good without losing the information.
        alert.showsSuppressionButton = true
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: Self.hiddenMenuBarAlertSuppressedKey)
        }
        if answer == .alertFirstButtonReturn {
            Self.openMenuBarSettings()
        }
    }

    static let hiddenMenuBarAlertSuppressedKey = "com.anode.menubar.hiddenAlertSuppressed"


    /// System Settings' menu bar pane. Addressed by the Control Center extension
    /// ID, which is where the menu bar settings lived through macOS 15 and still
    /// opens the Menu Bar pane — "Allow in the Menu Bar" included — on macOS 27.
    /// If it does not resolve, System Settings itself is the next best place.
    static func openMenuBarSettings() {
        let ws = NSWorkspace.shared
        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"),
           ws.open(url) { return }
        ws.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    /// Whether the window is open AND actually on screen — see `AppPresence`.
    /// A window covered by another app is worth exactly as much work as a closed
    /// one, which is the light tick and the menu bar.
    var windowIsWorthDrawing: Bool {
        let open = main.window.isVisible
        let onScreen = main.window.occlusionState.contains(.visible)
        let answer = AppPresence.windowIsWorthDrawing(isOpen: open, isOnScreen: onScreen)
        // `ANODE_LOG_VISIBILITY=1` prints every change to this answer and the two
        // readings behind it. Kept because "is the window actually being drawn"
        // is invisible from outside the process and cannot be measured by CPU
        // alone — a busy machine hides the difference entirely, which is exactly
        // what happened the first time this was checked.
        if ProcessInfo.processInfo.environment["ANODE_LOG_VISIBILITY"] == "1",
           answer != lastLoggedVisibility {
            lastLoggedVisibility = answer
            NSLog("anode.visibility drawing=\(answer) isVisible=\(open) onScreen=\(onScreen)")
        }
        return answer
    }
    private var lastLoggedVisibility: Bool?

    /// Tick cadence while the window is hidden.
    ///
    /// The window needs a live-feeling chart; the menu bar needs a number that is
    /// roughly current. Sampling both at the same rate means the expensive path
    /// runs for a reader that cannot tell the difference — a menu bar figure
    /// updated every 2 s and every 5 s look identical, and everything downstream
    /// (IORegistry reads, SMC reads, metric formatting, image drawing) scales with
    /// the rate.
    static let hiddenInterval: TimeInterval = 8

    /// Tick cadence while this app is holding a fan.
    ///
    /// A control the user has hold of needs a feedback loop, and the ordinary two
    /// seconds is not one — reported as dragging to full speed and seeing the rpm
    /// four seconds later. Faster sampling only helps if the tick that consumes it
    /// is faster too, so this is the other half of `SystemMetrics.fansAreDriven`.
    ///
    /// Affordable because the reading it accelerates is the cheap one: the fans
    /// alone are 0.16 ms of CPU, against 9.48 ms for the sweep it does not
    /// trigger. And it applies only while a fan is HELD — the moment the user
    /// hands them back, the cadence goes with it.
    static let drivingFansInterval: TimeInterval = 1

    /// Interval the timer is currently scheduled at, so visibility changes only
    /// rebuild the timer when the rate actually needs to change.
    private var timerInterval: TimeInterval = 0

    func restartTimer(hidden: Bool = false) {
        restartTimer(at: Self.cadence(hidden: hidden,
                                      setting: Settings.shared.sampleInterval,
                                      drivingFans: fansPane.isDrivingFans))
    }

    /// Does this tick need the expensive half — the per-process sweep and the GPU
    /// rail — as arithmetic, so it can be read and tested without a window.
    ///
    /// `panelOpen` is here for the same reason `visible` is, and it is the second
    /// half of the defect that left three sensor rows dashed. `gpu_W`,
    /// `attributed_W`, `residual_W` and `coverage` are all documented ABSENT on a
    /// light tick rather than zero — deliberately, because a light tick did not
    /// look — so GPU drain, Unattributed power and Process coverage render "—" for
    /// as long as the panel is open unless opening it asks for a full sample.
    /// Reported from the field on a machine where they had never shown a number.
    ///
    /// `widgetNeedsFull` is the third reader of the same metrics: a standalone
    /// widget bound to one of them is on screen while the window is closed, and
    /// with only light ticks it read "—" for as long as the app was hidden.
    static func wantsFullSample(visible: Bool, panelOpen: Bool, widgetNeedsFull: Bool,
                                logging: Bool, sinceLastFull: TimeInterval,
                                backgroundInterval: TimeInterval) -> Bool {
        if visible || panelOpen || widgetNeedsFull { return true }
        return logging && sinceLastFull >= backgroundInterval
    }

    /// Is an enabled widget bound to a metric that only a full tick produces?
    ///
    /// The collapsed group is not: it shows no value until opened, and opening it
    /// already forces a full tick through `panelOpen`.
    static func widgetsNeedFullSample(configs: [WidgetConfig]) -> Bool {
        let fullOnly: Set<String> = [MetricID.gpuDrain.rawValue,
                                     MetricID.unattributedShare.rawValue,
                                     MetricID.processCoverage.rawValue]
        return configs.contains { $0.enabled && fullOnly.contains($0.metricID) }
    }

    /// What the tick rate should be, as arithmetic — so the three rules that
    /// decide it can be read, and tested, without a window or a fan.
    static func cadence(hidden: Bool, setting: TimeInterval,
                        drivingFans: Bool) -> TimeInterval {
        // Hidden wins outright: nothing on screen is waiting on a fan, and the
        // whole point of the hidden rate is that nobody is reading.
        if hidden { return max(setting, hiddenInterval) }
        // A held fan outranks the setting, but only downwards — someone who has
        // asked for a faster tick than this keeps it.
        if drivingFans { return min(setting, drivingFansInterval) }
        return setting
    }

    private func restartTimer(at interval: TimeInterval) {
        guard interval != timerInterval else { return }
        timer?.invalidate()
        timerInterval = interval
        // NOT `Timer.scheduledTimer`, which schedules in `.default` mode ONLY.
        //
        // AppKit runs an open menu in `NSEventTrackingRunLoopMode`, and a
        // default-mode timer does not fire there — so for the entire time the menu
        // bar panel was on screen, THE TICK DID NOT RUN AT ALL. Not slowly: not at
        // once. The panel showed whatever the registry happened to hold when it was
        // built and could never move, and the three sensor rows could never fill,
        // because the state that asks for sensors is the same state that suspended
        // the sampling which would collect them. Reported as "the menu still has —"
        // after the needs and the cadence were both already fixed, which is what
        // sent us looking here.
        //
        // `.common` carries this in a running app: it is a SET, not a mode, and
        // AppKit registers `NSEventTrackingRunLoopMode` into it once NSApplication
        // is up. MEASURED both ways — in a bare process `CFRunLoopCopyAllModes`
        // returns only `kCFRunLoopDefaultMode` and a `.common` timer does NOT fire
        // during tracking (0 ticks); in a process where AppKit has initialised, the
        // same timer fires normally (30 ticks).
        //
        // `.eventTracking` is named anyway, because the guarantee then does not
        // depend on AppKit having registered the mode before this timer was built.
        // It is one line and it removes an ordering assumption — which is the same
        // class of assumption that produced the bug above.
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        RunLoop.main.add(t, forMode: .eventTracking)
        timer = t
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

    /// See `StrandingLog`. Main-thread only, like the tick that feeds it.
    private var strandingLog = StrandingLog()

    func refresh() {
        guard let m = monitor else { return }
        // The cheap half first: a closed window cannot be stranded, and that is
        // the state this app spends most of its life in, so the hidden tick pays
        // one property read and never asks the window server anything.
        if let event = strandingLog.observe(
            stranded: main.window.isVisible && main.window.isStranded) {
            let w = main.window
            StrandingLog.append(StrandingLog.line(
                for: event,
                context: "occlusion=\(w.occlusionState.rawValue) active=\(NSApp.isActive) "
                    + "screens=\(NSScreen.screens.count) screen=\(w.screen?.localizedName ?? "nil")"))
        }
        // Read visibility on the main thread; AppKit state is not thread-safe.
        let visible = windowIsWorthDrawing
        // Read beside it, for the same reason the interval is: one value used by
        // the whole tick, so logging cannot be on for the sweep and off for the
        // write within a single sample.
        let logging = Settings.shared.batteryLogging
        // The tab on screen, read on main because that is where it is written. It
        // decides which subsystems this tick pays for — see `visibleNeeds`.
        // An open panel is a reader too — see `MenuBarWidgetController.isPanelOpen`.
        let panelOpen = widgets?.isPanelOpen ?? false
        let needs = visible ? visibleNeeds : hiddenNeeds
        // Main-thread state for the same reason: the widget configs live here.
        let widgetNeedsFull = Settings.shared.menuBarWidgetsEnabled
            && Self.widgetsNeedFullSample(configs: widgets?.configs ?? [])
        // Read here, on the main thread, where the panel's state lives — and
        // BEFORE the tick uses it. While a fan is held its speed is the feedback
        // for a control the user has hold of, so the sampler re-reads the fans
        // (and only the fans) every tick instead of every five seconds.
        sysMetrics.fansAreDriven = visible && fansPane.isDrivingFans
        // Match the cadence to who is actually reading. The hidden rate states its
        // own assumption — "the whole point of the hidden rate is that nobody is
        // reading" — so someone holding the panel open is exactly the case it must
        // not apply to. Eight seconds is visibly stale on CPU, network and disk.
        restartTimer(hidden: !visible && !panelOpen)
        TickLedger.shared.note(
            mode: .init(effectiveInterval: timerInterval,
                        settingInterval: Settings.shared.sampleInterval,
                        windowVisible: visible, panelOpen: panelOpen,
                        drivingFans: sysMetrics.fansAreDriven, historyLogging: logging,
                        backgroundFullInterval: backgroundFullInterval),
            dropped: sampleGate.dropped)
        // The two animations that are not a response to the user keep running on
        // their layers until told otherwise, and a covered window still has its
        // layers. Idempotent, so it can sit on the tick rather than needing every
        // path that can hide a window to remember it.
        if !visible { main.sidebar.pauseSelfRunningAnimations() }

        // One tick at a time, on one queue. A tick arriving while the previous one
        // is still running is dropped, not queued and not run beside it.
        sampleGate.submit(on: sampling) { [weak self] in
            guard let self else { return }
            // `ANODE_LOG_TICKS=1` prints what each tick actually cost, in CPU
            // rather than wall time, and which kind it was.
            //
            // Total CPU over a minute cannot separate one 60 s full tick from the
            // seven light ticks beside it, and the background floor is the sum of
            // exactly those two things — so the number that matters all day is the
            // one an outside measurement cannot see. Thread CPU time, because this
            // queue is serial and a block stays on the thread it started on.
            let tickStartCPU = TickCost.now()
            // Always on, unlike the line above: `TickLedger` keeps every tick's
            // cost for Anode Stats. See `TickCost.cpuNow`.
            let ledgerStartCPU = TickCost.cpuNow()
            let ledgerStartWall = DispatchTime.now().uptimeNanoseconds
            let tickStartedAt = Date()
            // The background full tick exists for ONE reason — keeping the trailing
            // power window accruing while the window is closed. With logging off
            // there is nothing to accrue into, so the per-process sweep, the
            // IOReport channel diff and the rollup behind it are not paid for. The
            // whole-machine figures the menu bar shows come from every tick, light
            // or full, so the widgets do not go quiet.
            // `panelOpen` for the same reason `visible` is here, and it is the
            // second half of the same defect: the panel lists metrics that ONLY a
            // full tick produces. `gpu_W`, `attributed_W`, `residual_W` and
            // `coverage` are all documented ABSENT on a light tick — not zero —
            // so GPU drain, Unattributed power and Process coverage rendered as
            // "—" for as long as the panel was open, exactly as the three sensor
            // rows did before the run-loop fix. Reported from the field on a
            // machine where they had never once shown a number.
            //
            // Attribution stays gated on `visible` below: the per-app rollup feeds
            // the process table and the drill-down, and the panel shows none of it.
            let wantFull = Self.wantsFullSample(
                visible: visible, panelOpen: panelOpen,
                widgetNeedsFull: widgetNeedsFull, logging: logging,
                sinceLastFull: Date().timeIntervalSince(self.lastFullTick),
                backgroundInterval: self.backgroundFullInterval)
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
                                   chargePercent: snap.state.map { snap.scale.chargePercent($0) },
                                   forecast: Self.forecastForStore(),
                                   interval: snap.interval)
            }
            var est: DrainEstimate?
            var prior: DrainPrior?
            var allTime_W: Double?
            var recent_W: Double?
            if let st = snap.state {
                self.recentDrain.observe(
                    batteryWatts: LifetimeDrainModel.batteryWatts(
                        state: st, measured_W: snap.measured_W,
                        measuredAge: snap.measuredAge, smoothed_W: snap.smoothed_W),
                    onBattery: !st.onAC, interval: snap.interval,
                    awake: PowerMonitor.awakeSeconds(),
                    // The threshold is in %/hr, the unit it is read in; the
                    // window holds watts. Converted at the live voltage, the
                    // inverse of `BatteryScale.pctHrAtVoltage`.
                    jump_W: st.voltage_mV > 0 && snap.scale.fullChargeCapacity_mAh > 0
                        ? RecentDrain.jumpPctHr * Double(st.voltage_mV)
                            * snap.scale.fullChargeCapacity_mAh / 1e8
                        : nil)
                recent_W = self.recentDrain.mean_W
                self.drain.record(state: st, scale: snap.scale,
                                  powerBased_pctHr: snap.smoothed_pctHr)
                est = self.drain.estimate()

                // Every tick, light or full: the baseline needs only the pack's
                // own watts. The dominant app only rides along on full ticks,
                // which is why the model treats it as opportunistic.
                if var lt = self.lifetime {
                    let awakeNow = PowerMonitor.awakeSeconds()
                    lt.observe(batteryWatts: LifetimeDrainModel.batteryWatts(
                                   state: st, measured_W: snap.measured_W,
                                   measuredAge: snap.measuredAge,
                                   smoothed_W: snap.smoothed_W),
                               onBattery: !st.onAC,
                               displayOn: CGDisplayIsAsleep(CGMainDisplayID()) == 0,
                               interval: snap.interval,
                               awake: awakeNow, now: Date(),
                               topApp: wantFull ? .dominant(in: snap.apps) : nil)
                    prior = lt.prior(awake: awakeNow)
                    allTime_W = lt.allTimeMean_W
                    self.lifetime = lt
                }

                // Insurance against the exits that skip `applicationWillTerminate`
                // — a crash, a force quit, a logout that does not wait. Every two
                // minutes and not every tick: this is a few dozen samples of five
                // numbers, and macOS has killed this app once already for dirtying
                // pages too fast. Losing at most two minutes of a thirty-minute
                // window is not worth a write per second to avoid.
                if Date().timeIntervalSince(self.lastTrendSave) > 120 {
                    self.lastTrendSave = Date()
                    let snapshot = self.drain.persistedTrend()
                    let learned = self.lifetime
                    DispatchQueue.global(qos: .utility).async {
                        snapshot.save()
                        if let m = learned, let url = LifetimeDrainModel.fileURL() { m.save(to: url) }
                    }
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

            TickCost.log(kind: wantFull ? "FULL" : "light",
                         visible: visible, needs: needs, since: tickStartCPU)
            TickLedger.shared.record(
                kind: wantFull ? .full : .light, startedAt: tickStartedAt,
                cpu_ns: TickCost.cpuNow() &- ledgerStartCPU,
                wall_ns: DispatchTime.now().uptimeNanoseconds &- ledgerStartWall,
                // The same figure the drain estimate divides by. `measured_W`
                // alone is nil whenever the pack's own reading is stale, which
                // left "share of machine draw" blank on a machine that was
                // plainly drawing power.
                machine_W: LifetimeDrainModel.batteryWatts(
                    state: snap.state, measured_W: snap.measured_W,
                    measuredAge: snap.measuredAge, smoothed_W: snap.smoothed_W),
                joulesPerPercent: snap.state == nil ? nil : snap.scale.joulesPerPercent)

            DispatchQueue.main.async {
                // The sampling queue's cost is logged above; this is the OTHER
                // half of a tick, and the half that was never measured — the
                // menu bar widgets redraw here on every hidden tick.
                let mainStartCPU = TickCost.now()
                let ledgerMainCPU = TickCost.cpuNow()
                defer {
                    TickCost.log(kind: "main-thread", visible: visible,
                                 needs: needs, since: mainStartCPU)
                    TickLedger.shared.recordMain(cpu_ns: TickCost.cpuNow() &- ledgerMainCPU)
                }
                self.lastSystem = sysSnap
                self.lastDrain = est
                self.lastPrior = prior
                self.lastAllTime_W = allTime_W
                self.lastRecent_W = recent_W
                // BEFORE the visibility branch, and outside it. The live graph
                // buffers back the 1H view, and a window that is closed or covered
                // is still a machine worth having a record of — see
                // `recordGraphSample`. Appending a few numbers costs nothing; the
                // drawing is what was expensive, and that stays below.
                self.recordGraphSample(snap)
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
                    MetricRegistry.shared.update(displayedRate: Self.reconciledRate(
                        snap, est, previous: MetricRegistry.shared.displayedRate,
                        prior: prior, allTime_W: allTime_W, recent_W: recent_W))
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
        MetricRegistry.shared.update(displayedRate: Self.reconciledRate(
            s, lastDrain, previous: MetricRegistry.shared.displayedRate, prior: lastPrior,
            allTime_W: lastAllTime_W, recent_W: lastRecent_W))
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
            // no app — WindowServer and the like — when daemons are switched off.
            .filter { showDaemons || $0.isApp }
            .filter { ProcessRowBuilder.isNotable($0, floor_pctHr: floor) }
        sortRows()

        refreshTable()
        autosizeColumns()

        reselectByName()
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
            // No divisor here any more, and that is the fix rather than an
            // omission. `AppDrain.cpuPercent` used to be percent of ONE core, so
            // summing it against a device total that is 0-100 across ALL cores
            // mixed two scales by the core count: this bar read "CPU 129.0% in
            // use" on a machine sitting at 17.3%. The divisor patched it here
            // while the table's own column went on showing the other unit.
            //
            // The unit is now settled at the source — `MachTime.machinePercent`,
            // percent of the whole machine — so every number in this window is on
            // one scale and nothing needs converting on the way to the screen.
            main.ledger.utilization = .attributed(
                "CPU",
                UtilizationSlices(total: total,
                                  apps: sum({ $0.cpuPercent }, apps: true),
                                  systemProcesses: sum({ $0.cpuPercent }, apps: false)),
                idle: max(0, 100 - total),
                note: "of all \(MachTime.activeCores) cores")

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
        // The fans' own range as well as their speed: a glyph turning in
        // proportion to absolute rpm cannot show the difference between idling
        // and idling slightly harder, because that difference is eight percent.
        let fans = lastSystem?.fans ?? []
        main.sidebar.setFanSpin(
            rpm: fans.averageRPM,
            limits: fans.isEmpty ? nil
                : .init(minRPM: fans.map(\.minRPM).min() ?? 0,
                        maxRPM: fans.map(\.maxRPM).max() ?? 0))
        // The HOTTEST reading, not the average: the rail is an alarm here, and an
        // average hides one component cooking behind five that are fine.
        //
        // It took the larger of two AVERAGES, which is not the hottest reading:
        // each spans 20-40 sensors, so a single core at 102 °C read as ~65 °C and
        // the ≥ 90 °C pulse never fired. The peak die sensor is what this means.
        let temps = [lastSystem?.peakTemperature, lastSystem?.cpuTemperature,
                     lastSystem?.gpuTemperature].compactMap { $0 }
        // The glyph's alarm needs the (already smoothed) peak to stay hot for a while; see
        // `TemperatureAlarm`. It used to pulse on the first reading that crossed 90 °C.
        let hottest = temps.max()
        main.sidebar.setTemperature(hottest, alarming: temperatureAlarm.update(hottest))
        main.sidebar.setNetworkKind(NetworkInventory.snapshot().primary?.kind)
    }

    func updateGlance(_ s: PowerMonitor.Snapshot) {
        lastCensus = bottomContext == .cpu ? MachineInfo.census() : nil
        main.glance.model = lastSystem.flatMap {
            GlanceCardView.model(for: bottomContext, system: $0,
                                 facts: MachineInfo.facts, census: lastCensus)
        } ?? GlanceCardView.model(from: s, drain: lastDrain,
                                  shared: MetricRegistry.shared.displayedRate)
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

    /// The battery graph for the live hour, built from the in-memory buffers and
    /// whichever lines Settings → Graph has ticked.
    func ledgerGraphDrawn() -> LedgerGraphLine.Drawn {
        let selected = LedgerGraphLine.selected()
        return LedgerGraphLine.build(
            selected: selected,
            drain: totalSeries,
            mean: Self.sessionMean(totalSeries, charge: chargeSeries,
                                   minimumSpan: Self.drainTrendMinimumSpan),
            charge: chargeSeries,
            extras: ledgerLiveExtras(selected),
            drainFilled: true)
    }

    /// The live buffers behind the ledger graph's extra lines, as they stand now.
    /// Copied (arrays are values) so the history path can read them off the main
    /// thread without racing the sampler.
    func ledgerLiveExtras(_ selected: Set<LedgerGraphLine>)
        -> [LedgerGraphLine: [HistoryGraphView.Point]] {
        var out: [LedgerGraphLine: [HistoryGraphView.Point]] = [:]
        func pct(_ points: [HistoryGraphView.Point]) -> [HistoryGraphView.Point] {
            points.map { LedgerGraphLine.percentPoint($0.time, $0.value) }
        }
        if selected.contains(.cpu) { out[.cpu] = pct(utilizationSeries[.cpu] ?? []) }
        if selected.contains(.memory) { out[.memory] = pct(utilizationSeries[.memory] ?? []) }
        if selected.contains(.gpu) { out[.gpu] = pct(utilizationSeries[.gpu] ?? []) }
        if selected.contains(.fan) { out[.fan] = fanLoadSeries }
        if selected.contains(.unattributed) { out[.unattributed] = unattributedSeries }
        if selected.contains(.coverage) { out[.coverage] = coverageSeries }
        return out
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
            return updateGraph(lastSnapshot)
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
        let selected = LedgerGraphLine.selected()
        // Read on the main thread, used on the background one.
        let liveExtras = ledgerLiveExtras(selected)
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
            let trend = Self.sessionMean(series, charge: charge,
                                         minimumSpan: Self.drainTrendMinimumSpan)

            // The store keeps CPU, memory and GPU. The session-only lines come from
            // the live buffers, clipped to the range asked for: a zoom inside the
            // live hour lands here too, and they must not vanish when it does.
            var extras: [LedgerGraphLine: [HistoryGraphView.Point]] = [:]
            if !selected.isDisjoint(with: [.cpu, .memory, .gpu]) {
                let util = store.utilizationSeries(since: start, until: end, maxPoints: 700)
                func line(_ get: (HistoryStore.UtilizationPoint) -> Double?)
                    -> [HistoryGraphView.Point] {
                    util.compactMap { p in
                        get(p).map { LedgerGraphLine.percentPoint(p.time, $0) }
                    }
                }
                if selected.contains(.cpu) { extras[.cpu] = line { $0.cpuPercent } }
                if selected.contains(.memory) { extras[.memory] = line { $0.memoryPercent } }
                if selected.contains(.gpu) { extras[.gpu] = line { $0.gpuPercent } }
            }
            for (line, pts) in liveExtras where line.sessionOnly {
                extras[line] = pts.filter { $0.time >= start && $0.time <= end }
            }
            let drawn = LedgerGraphLine.build(selected: selected, drain: series, mean: trend,
                                              charge: charge, extras: extras,
                                              drainFilled: false)
            DispatchQueue.main.async {
                self.graph.sharesRightAxisScale = true
                self.graph.series = drawn.series
                self.graph.rightSeries = drawn.right
                self.graph.rightAxisLabel = drawn.rightAxisLabel
                self.graph.yAxisLabel = drawn.axisLabel
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

    /// What the app is showing right now, as the history stores it: the time
    /// left and the rate behind it, only while draining. Read from the last
    /// published rate, at most one tick old.
    static func forecastForStore() -> HistoryStore.Forecast {
        guard let r = MetricRegistry.shared.lockedDisplayedRate(),
              r.chargePercent != nil, r.canQuoteTime,
              let hr = r.timeRemaining_hr() else { return .none }
        return .init(predictedSeconds: hr * 3600, shownPctHr: r.pctHr,
                     paceSeconds: r.paceRemaining_hr().map { $0 * 3600 })
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
    /// 1. `.discharge` — the mean, since the lid was last opened, of the
    ///    battery's own discharge accumulator. Charge that has already left the pack, integrated by the
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
    /// TIME is not published as a number at all. What goes out is the CHARGE and
    /// the instant it was read, and the renderers divide — see `DisplayedRate`.
    /// The rate published here and the charge published here still multiply back
    /// to the time, whichever tier answered.
    ///
    /// ## The anchor instant, and the one rule that governs it
    /// `anchorAwake` is re-stamped WHEN THE CHARGE CHANGES, and at no other time.
    /// That is the whole of it, and both halves matter:
    ///
    /// Re-stamping every call would undo the change entirely. This function runs
    /// every tick — every 2 s visible, 8 s hidden — while the gauge publishes a
    /// new charge about once a minute. An anchor re-stamped each tick always has
    /// ~0 elapsed against it, so the projection would be a no-op and the headline
    /// would sit still exactly as it did before.
    ///
    /// NOT re-stamping on a rate change is deliberate rather than an omission.
    /// On the power tier the rate moves every tick while the charge does not, and
    /// applying the new rate from the old charge reading — `projected(charge,
    /// newRate, elapsed)` — is the more correct answer: it charges the elapsed
    /// seconds at what the machine is doing now, rather than pretending the
    /// gauge spoke again.
    ///
    /// Equality on `chargePercent` is the same test the estimator already makes
    /// on the same value (`isNewPublish = mAh != lastMAh`), so the two agree
    /// about what a publish is.
    static func reconciledRate(_ s: PowerMonitor.Snapshot, _ est: DrainEstimate?,
                               previous: DisplayedRate?,
                               awake: TimeInterval = PowerMonitor.awakeSeconds(),
                               prior: DrainPrior? = nil,
                               allTime_W: Double? = nil,
                               recent_W: Double? = nil)
        -> DisplayedRate {
        let r = rateForTimeLeft(s, est, previous: previous, awake: awake,
                                prior: prior, allTime_W: allTime_W)
        // Both of these ride along and decide nothing: everything above this
        // line is what time left is divided from, and it is computed exactly as
        // it was before there was a second rate. See `DisplayedRate.recentPctHr`
        // and `DisplayedRate.pacePctHr`.
        //
        // The pace rate is the estimator's own, because `rateForTimeLeft` returns
        // at the all-time branch before it consults the estimator and so the
        // discharge trend never reaches `r` on a machine with history. Gated by
        // the same `canQuoteTime` the headline answers to: a half-hour mean of
        // the first seconds after an unplug is not a trend.
        let pace: Double? = r.chargePercent == nil ? nil : trailingPace(s, est)
        let recent: Double? = {
            guard s.direction == .draining, let w = recent_W, w > 0,
                  let mV = s.state?.voltage_mV, mV > 0 else { return nil }
            let v = s.scale.pctHrAtVoltage(watts: w, voltage_mV: Double(mV))
            return v.isFinite && v > 0 ? v : nil
        }()
        guard pace != nil || recent != nil else { return r }
        return DisplayedRate(pctHr: r.pctHr, chargePercent: r.chargePercent,
                             anchorAwake: r.anchorAwake, source: r.source,
                             windowSpan: r.windowSpan, prior: r.prior,
                             recentPctHr: recent, pacePctHr: pace)
    }

    /// The last half hour's measured drain, when it is fit to quote: the
    /// estimator's own discharge trend, gated by the same `canQuoteTime` the
    /// headline answers to — a half-hour mean of the first seconds after an
    /// unplug is not a trend. nil otherwise.
    ///
    /// The estimator's, because `rateForTimeLeft` returns at the all-time branch
    /// before it consults the estimator, so the trend never reaches `r` on a
    /// machine with history.
    static func trailingPace(_ s: PowerMonitor.Snapshot, _ est: DrainEstimate?) -> Double? {
        guard s.direction == .draining, let e = est, e.source == .discharge,
              DrainEstimate.canQuoteTime(source: e.source, windowSpan: e.windowSpan),
              e.percentPerHour >= 0.1, e.percentPerHour.isFinite else { return nil }
        return e.percentPerHour
    }

    private static func rateForTimeLeft(_ s: PowerMonitor.Snapshot, _ est: DrainEstimate?,
                                        previous: DisplayedRate?,
                                        awake: TimeInterval,
                                        prior: DrainPrior?,
                                        allTime_W: Double?)
        -> DisplayedRate {
        // The lifetime forecast, converted at the LIVE voltage so its two rates
        // are on the basis `timeToEmpty` assumes — see `pctHrAtVoltage`. Only
        // while draining: a time-to-empty on AC is inapplicable, not missing.
        let lifetime: DisplayedRate.Prior? = {
            guard let p = prior, s.direction == .draining,
                  let raw = s.state?.voltage_mV, raw > 0 else { return nil }
            let mV = Double(raw)
            return DisplayedRate.Prior(
                baselinePctHr: s.scale.pctHrAtVoltage(watts: p.baseline_W, voltage_mV: mV),
                currentPctHr: s.scale.pctHrAtVoltage(watts: p.current_W, voltage_mV: mV),
                tau_s: p.tau_s, band: p.band, appName: p.appName)
        }()
        func anchored(pctHr: Double, charge: Double?,
                      source: DrainEstimate.Source, span: TimeInterval) -> DisplayedRate {
            let held = previous.flatMap { p -> TimeInterval? in
                guard let c = charge, let pc = p.chargePercent, c == pc else { return nil }
                // A backwards awake clock cannot happen (CLOCK_UPTIME_RAW is
                // monotonic), but a restored/never-set anchor can be in the
                // future relative to this process. Re-stamp rather than project
                // a negative interval.
                return p.anchorAwake <= awake ? p.anchorAwake : nil
            }
            return DisplayedRate(pctHr: pctHr, chargePercent: charge,
                                 anchorAwake: held ?? awake,
                                 source: source, windowSpan: span,
                                 prior: charge == nil ? nil : lifetime)
        }

        let draining = s.direction == .draining
        // Time left = charge ÷ the average drain over all the display-on battery
        // time ever recorded, once there are two hours of it. Outranks the session
        // mean and the lifetime forecast: it is the definition the user chose.
        if draining, let w = allTime_W, w > 0, let st = s.state, st.voltage_mV > 0 {
            let charge = s.scale.chargePercent(st)
            // Converted at the live voltage, which sags with every change in
            // load; re-converting each tick would move the time with it. So the
            // rate, like the anchor, changes only when the gauge publishes.
            let pctHr: Double
            if let p = previous, p.source == .allTime, p.chargePercent == charge {
                pctHr = p.pctHr
            } else {
                let allTime = s.scale.pctHrAtVoltage(watts: w, voltage_mV: Double(st.voltage_mV))
                // The all-time mean alone read ~15 %/hr through a light afternoon
                // that really drained ~6: it assumes the present load is about to
                // become the average one. Weight the last half hour's measured
                // drain heavily and let the average only pull it back from the
                // extremes. See `DisplayedRate.trailingWeight`.
                pctHr = DisplayedRate.blended(allTime: allTime, trailing: trailingPace(s, est))
            }
            let r = anchored(pctHr: pctHr, charge: charge,
                             source: .allTime, span: est?.windowSpan ?? 0)
            return DisplayedRate(pctHr: r.pctHr, chargePercent: r.chargePercent,
                                 anchorAwake: r.anchorAwake, source: .allTime,
                                 windowSpan: r.windowSpan, prior: nil)
        }
        if let e = est, e.source == .discharge, draining {
            return anchored(pctHr: e.percentPerHour, charge: e.chargePercent,
                            source: .discharge, span: e.windowSpan)
        }
        // Live-voltage basis, the one `timeToEmpty` divides — see
        // `Snapshot.smoothedLive_pctHr`.
        let measured = s.smoothedLive_pctHr
        let inferred = est?.percentPerHour
        let trustInferred: Bool = {
            guard let inferred, inferred > 0 else { return false }
            guard measured > 0.05 else { return true }
            let ratio = inferred / measured
            return ratio >= 0.5 && ratio <= 2.0
        }()
        let shown = trustInferred ? (inferred ?? measured) : measured
        // The charge the renderers will divide. nil off battery, where a
        // time-to-empty is not a missing reading but an inapplicable one.
        let charge: Double? = {
            guard draining, let st = s.state else { return nil }
            return s.scale.chargePercent(st)
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
        return anchored(pctHr: shown, charge: charge, source: source, span: span)
    }

    /// Adopt a graph range: the domain, the data behind it, and the redraw.
    ///
    /// Both callers go through here — the range picker, and the subject switch
    /// that has to fall back when the new subject cannot draw the current range.
    /// The switch used to do two thirds of this inline and skip the domain,
    /// which is the fan-graph defect; see `graphDomain`.
    func applyGraphRange(_ seconds: TimeInterval) {
        graphRange = seconds
        graphDomainOverride = nil          // back to following "now"
        graph.earliestAvailable = store?.earliestSample()
        let domain = Self.graphDomain(for: seconds)
        graph.timeDomain = domain
        if let domain {
            loadHistorySeries(start: domain.start, end: domain.end)
        } else {
            updateGraph(lastSnapshot)
        }
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
    /// The name the trend overlay draws under, in the legend and the hover.
    static let drainTrendSeriesName = "mean since lid opened"
    /// And the same substance floor, for the same reason `minTicks` has one: a
    /// mean over the first few seconds is the instantaneous value wearing a
    /// different colour.
    static let drainTrendMinimumSpan: TimeInterval = 300

    /// Trailing mean of a plotted series, one output point per input point that
    /// has `minimumSpan` of history behind it.
    ///
    /// ## What this is for
    /// Reported from the field: the graph read ~4.5 %/hr while the readout beside
    /// it read ~7.5. Both were right. The graph plots one value per tick and the
    /// eye reads where that line SITS; the readout is a mean over half an hour,
    /// and a mean is pulled up by spikes the line only touches. Measured on the
    /// reporting machine over 24 minutes: base 2.97 W, mean 6.11 W, peak 28.97 W
    /// — the base 51 % below the mean, worse than the 35-45 % `DischargeTrend`
    /// records for bursty loads.
    ///
    /// No number was wrong and none could be changed, because a pack is drained
    /// by the AREA under that line rather than by where it rests. What was
    /// missing was the connection, so this draws the mean over the line it is
    /// the mean OF.
    ///
    /// ## Derived, never buffered
    /// A stored second series would need seeding at launch, a cutoff of its own,
    /// and some definition for the store-backed ranges, where the published rate
    /// was never persisted. Deriving it from the points being drawn gives ONE
    /// definition on every range and makes the drawn claim self-evidently true
    /// of the drawn data.
    ///
    /// ## Time-weighted, and that is not a detail
    /// The live buffer ticks every 2 s while the window is visible and every 8 s
    /// while it is hidden (`cadence`), and the store-backed ranges mix raw rows
    /// with 60 s buckets. A mean over SAMPLES would count a visible minute four
    /// times as heavily as a hidden one and quietly redefine the window — the
    /// same trap `DischargeTrend` documents for its own accumulator ("a mean over
    /// SAMPLES rather than over TICKS would silently misweight them"), and the
    /// same fix. Each point is weighted by the gap it stands for.
    ///
    /// TRAILING, so a point sees only what came before it. A centred mean would
    /// let the future move the past, and the graph would redraw its own history
    /// on every tick.
    /// The range to fall back to when the subject being switched to cannot draw
    /// the one currently chosen. nil = the current range is fine, leave it.
    ///
    /// nil rather than "return the current range" so the caller can tell "no
    /// change needed" from "changed to the same value", and skip the reset work
    /// on every ordinary tab change.
    static func snappedRange(for context: BottomContext,
                             current: TimeInterval) -> TimeInterval? {
        guard !context.ranges.contains(current) else { return nil }
        return context.ranges.first
    }

    /// The domain a chosen range implies, and THE one place that decides it.
    ///
    /// nil means a live strip chart: no explicit domain, so the axis follows the
    /// data's own extent. Anything longer than the live window pins an explicit
    /// window instead, because a store-backed range must draw the hours it asked
    /// for even where they are empty — "an empty stretch of history stays empty
    /// on screen instead of silently rescaling the axis to whatever few points
    /// happen to exist."
    ///
    /// This existed only inside the range picker's `onSelect`, and the subject
    /// switch could not reach it: `GraphRanges.select(seconds:)` moves the
    /// highlight and deliberately does not fire `onSelect`. So switching to a
    /// subject with no stored history snapped the RANGE to 1 h, lit the 1 h chip,
    /// and left the graph holding the previous subject's six-hour domain — which
    /// it then correctly honoured, drawing a six-hour axis over a buffer holding
    /// minutes. Reported as a broken fan graph; it was a correct axis over the
    /// wrong window.
    static func graphDomain(for seconds: TimeInterval,
                            now: Date = Date()) -> (start: Date, end: Date)? {
        seconds <= 3600 ? nil : (now.addingTimeInterval(-seconds), now)
    }

    /// The overlay as a series, or nothing at all.
    ///
    /// Empty rather than an empty series: a named series with no points still
    /// occupies the legend, and a legend entry for a line that is not on screen
    /// is worse than no overlay — it asks the reader to look for something that
    /// is not there.
    ///
    /// UNFILLED, and drawn after the drain line so it sits on top of it. The
    /// comment beside the drain series records why this graph carries one filled
    /// series and not two: "drawing it twice turned a glanceable trend into
    /// something you had to decode." That objection was to a DECOMPOSITION —
    /// attributed versus unaccounted, two parts of one total, both wanting the
    /// same area. This is not one: it is the same quantity over a longer window,
    /// and a bare line over a fill is exactly how that reads without competing
    /// for the area.
    static func trendOverlay(_ points: [HistoryGraphView.Point]) -> [HistoryGraphView.Series] {
        guard points.count >= 2 else { return [] }
        return [.init(name: drainTrendSeriesName, color: Palette.drainTrendLine,
                      points: points, filled: false)]
    }

    /// The overlay drawn at the headline's own window: the time-weighted mean of
    /// the drain line since the lid was last opened (or the pack last unplugged),
    /// which is what `BatteryDischargeTrend.sinceLidOpened()` averages.
    ///
    /// A session ends at a sleep, seen here as a gap in the plotted series wider
    /// than any awake cadence produces, and at any point `charge` marks as on the
    /// adapter. The gap bar scales with the series' own spacing, because the
    /// store-backed ranges are bucketed and a week drawn in 700 points is ~15
    /// minutes a point, every one of which would otherwise read as a sleep.
    static func sessionMean(_ points: [HistoryGraphView.Point],
                            charge: [HistoryGraphView.Point],
                            minimumSpan: TimeInterval) -> [HistoryGraphView.Point] {
        let clean = points.filter { $0.value.isFinite }.sorted { $0.time < $1.time }
        guard clean.count > 1 else { return [] }
        let onAC = Set(charge.filter { $0.onPower == true }.map(\.time))
        let gaps = zip(clean.dropFirst(), clean).map { $0.time.timeIntervalSince($1.time) }
        let median = gaps.sorted()[gaps.count / 2]
        let restartGap = max(HistoryStore.maxPlausibleInterval, 3 * median)

        var out: [HistoryGraphView.Point] = []
        var start: Date?
        var wSum = 0.0, vSum = 0.0
        for i in clean.indices {
            let p = clean[i]
            guard !onAC.contains(p.time) else { start = nil; continue }
            let dt = i > 0 ? p.time.timeIntervalSince(clean[i - 1].time) : .infinity
            if start == nil || dt > restartGap {
                // First battery point of a session: an instant, not a span.
                start = p.time; wSum = 0; vSum = 0
                continue
            }
            wSum += dt
            vSum += dt * p.value
            guard let s = start, p.time.timeIntervalSince(s) >= minimumSpan,
                  wSum > 0 else { continue }
            out.append(.init(time: p.time, value: vSum / wSum))
        }
        return out
    }

    static func trailingMean(_ points: [HistoryGraphView.Point],
                             window: TimeInterval,
                             minimumSpan: TimeInterval) -> [HistoryGraphView.Point] {
        // The view sanitises before drawing; this runs before that, so it cannot
        // assume either order or finiteness.
        let clean = points.filter { $0.value.isFinite }
            .sorted { $0.time < $1.time }
        guard clean.count > 1 else { return [] }

        // Weight for each point: the gap it stands for, which is the interval
        // BACK to its predecessor. The first point has no predecessor and so no
        // duration — it is an instant, not a span, and contributes nothing.
        var weight = [Double](repeating: 0, count: clean.count)
        for i in 1..<clean.count {
            let dt = clean[i].time.timeIntervalSince(clean[i - 1].time)
            // A gap wider than the window is not a span this mean can carry: it
            // would be one sample speaking for more time than the whole average
            // covers. Zero-weighted, and the window below then starts after it.
            weight[i] = (dt > 0 && dt <= window) ? dt : 0
        }

        var out: [HistoryGraphView.Point] = []
        out.reserveCapacity(clean.count)
        var lo = 0
        var wSum = 0.0, vSum = 0.0
        for i in 1..<clean.count {
            wSum += weight[i]
            vSum += weight[i] * clean[i].value
            // Drop everything that has fallen out of the trailing window.
            while lo + 1 <= i,
                  clean[i].time.timeIntervalSince(clean[lo + 1].time) > window {
                lo += 1
                wSum -= weight[lo]
                vSum -= weight[lo] * clean[lo].value
            }
            let span = clean[i].time.timeIntervalSince(clean[lo].time)
            guard span >= minimumSpan, wSum > 0 else { continue }
            let mean = vSum / wSum
            guard mean.isFinite else { continue }
            out.append(.init(time: clean[i].time, value: mean))
        }
        return out
    }

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

    /// Redrawing is now free of side effects, so anything may call it at any time.
    ///
    /// Changing the sort has to redraw the bottom at once — the same lesson the
    /// Resources rail taught, where a click changed the highlight and left the
    /// readings describing the thing you clicked away from. This used to be a
    /// hazard, because the same function also recorded a tick and an out-of-band
    /// redraw pushed a duplicate sample in for every click; `appending: false`
    /// existed to suppress that. Recording lives in `recordGraphSample` now, and
    /// the parameter with it.
    /// Append this tick's values to the live buffers, and trim them to the span.
    ///
    /// Called from the TICK, not from `apply`, and therefore on every tick
    /// whether or not anything is on screen. That placement is the whole point:
    /// what the app records cannot depend on what it happens to be showing.
    ///
    /// It was inside `updateGraph` until a covered window stopped reaching it.
    /// The 1H view is this in-memory buffer — the longer spans come from SQLite —
    /// so a window left behind another app grew a hole here and the graph drew it
    /// as a sleep break, on a machine that had not slept. Reported as a dotted
    /// line five to ten minutes wide, which was exactly the stretch spent covered.
    ///
    /// Nothing here fabricates a reading: `appendUtilization` guards every field,
    /// so a hidden tick that never sampled the GPU appends nothing for it rather
    /// than a zero.
    func recordGraphSample(_ s: PowerMonitor.Snapshot) {
        let now = Date()
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
        // A light tick attempted no attribution, so these are absent rather than 0 —
        // the registry's providers refuse the same ticks for the same reason.
        if s.isFullSample {
            if let share = s.residualShare {
                unattributedSeries.append(LedgerGraphLine.percentPoint(now, share * 100))
            }
            coverageSeries.append(LedgerGraphLine.percentPoint(now, s.coverage * 100))
        }
        if let sys = lastSystem {
            appendUtilization(sys, at: now)
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
    }

    /// Draws. Recording is `recordGraphSample`, and the two are separate so that
    /// hiding, covering or zooming the graph can never stop the app collecting.
    func updateGraph(_ s: PowerMonitor.Snapshot?) {
        guard let s else { return }
        let now = Date()
        let cutoff = now.addingTimeInterval(-graphSpan)

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
            let drawn = ledgerGraphDrawn()
            graph.series = drawn.series
            graph.yAxisLabel = drawn.axisLabel
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
            // Filled, like every other line alone on its axis. It is cut by the drain
            // fill below it, so the charge line's wash stops where that one starts
            // instead of the two stacking.
            let drawn = ledgerGraphDrawn()
            graph.rightSeries = drawn.right
            graph.rightAxisLabel = drawn.rightAxisLabel
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

    /// Re-find the selected APP by name. If it is gone (quit, or fell below the
    /// display floor) the selection is dropped rather than silently transferred
    /// to whichever app inherited its row.
    func reselectByName() {
        if let name = selectedAppName, let idx = rows.firstIndex(where: { $0.name == name }) {
            isRestoringSelection = true
            main.table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            isRestoringSelection = false
        } else if selectedAppName != nil {
            main.table.deselectAll(nil)
        }
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
    /// Which CARD inside the Resources tab a widget names, if any.
    ///
    /// The lens alone is not a destination: six resources sit behind that one
    /// tab, so sending a RAM widget to `.resources` and stopping there lands on
    /// whichever card happened to be selected last. Reported exactly that way —
    /// the CPU and RAM widgets opened Resources and showed the previous card.
    ///
    /// nil for every metric whose lens IS the whole answer: a temperature widget
    /// opens Sensors, a network widget opens Network, and neither has a card to
    /// pick underneath.
    static func resource(forWidget metric: MetricID) -> Resource? {
        switch metric {
        case .cpuUsage:                                return .cpu
        case .memoryUsage:                             return .memory
        case .gpuUsage:                                return .gpu
        case .diskRead, .diskWrite, .diskActivity:     return .disk
        // Every storage reading, swap included, is on the Disk card. Swap is
        // filed under Memory in the registry — it is memory pressure — but the
        // card that shows what that pressure DOES is this one, and it carries
        // its own Swap block precisely so this routing lands on the number.
        case .swapUsed, .writePerDay, .ssdHealth, .ssdLifeUsed,
             .ssdWritten, .ssdRead, .ssdSpare:          return .disk
        default:                                       return nil
        }
    }

    static func lens(forWidget metric: MetricID) -> SidebarView.Lens? {
        switch metric {
        // Every whole-machine utilisation is now one tab. The old rail sent each of
        // these to its own lens, and each of those lenses was the process table with
        // a different column — so a CPU widget click landed on a list of processes
        // rather than on the CPU. Resources is where that number actually lives.
        case .cpuUsage, .memoryUsage, .gpuUsage,
             .diskRead, .diskWrite, .diskActivity,
             // Storage is not its own lens. A Storage tab was designed and cut:
             // what survived fits the Disk card, and a sixth rail entry for it
             // would be navigation nobody had earned. So these route to the same
             // tab as the other utilisations and pick their card underneath.
             .swapUsed, .writePerDay, .ssdHealth, .ssdLifeUsed,
             .ssdWritten, .ssdRead, .ssdSpare: return .resources
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
              SidebarView.Lens.displayOrder.contains(lens) else {
            main.toggle()
            return
        }
        // "Already there" has to mean the CARD too, not just the tab. Testing the
        // lens alone made a RAM click while sitting on Resources/CPU do nothing
        // but toggle the window — the destination was reported as reached when
        // the number asked for was not on screen.
        let card = Self.resource(forWidget: metric)
        let alreadyThere = lens == main.sidebar.selected
            && (card == nil || card == resourcesPane.selectedResource)
        guard !alreadyThere else {
            main.toggle()
            return
        }
        // Through the rail rather than straight into select(): the rail owns
        // `selected` and the highlight, so switching around it would leave the
        // old row lit beside the new content. Its select() calls back into ours.
        main.sidebar.select(lens)
        // After the lens, because selecting a card retargets the bottom of the
        // window and the lens is what decides whether there is one.
        if let card { resourcesPane.select(card) }
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
        // A ticked fan-speed line is read off the SMC sweep, which is otherwise only
        // taken on the tabs that show a sensor. Cached behind
        // `SystemMetrics.sensorInterval`, so this is one sweep per interval.
        if Settings.shared.ledgerGraphLines.contains(LedgerGraphLine.fan.rawValue) {
            needs.insert(.sensors)
        }
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
        return Self.hiddenNeeds(configs: widgets.configs,
                                panelOpen: widgets?.isPanelOpen ?? false)
    }

    /// The same decision as arithmetic over what is enabled and what is on screen,
    /// so it can be read and tested without a menu bar. `panelOpen` is the half
    /// that was missing: the group's collapsed needs are correct for a collapsed
    /// group and wrong for an open one.
    static func hiddenNeeds(configs: [WidgetConfig], panelOpen: Bool)
        -> SystemMetrics.Needs {
        // An OPEN panel lists every metric there is, sensors included, and three of
        // its rows can otherwise only ever be dashes. Sampling them is what the
        // group's own exclusion below deliberately refuses to do on every tick —
        // correct while collapsed, and the reason this is a separate branch rather
        // than a change to that line. The sweep is cached behind
        // `SystemMetrics.sensorInterval`, so an open panel pays it once and not
        // per tick.
        if panelOpen { return [.cpu, .memory, .gpu, .network, .disk, .sensors] }
        var needs: SystemMetrics.Needs = []
        for c in configs where c.enabled {
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
        // Read on the sampling queue, which owns both — reading them here on
        // main raced the tick that mutates them. Safe to wait on: the sampling
        // queue only ever hands work to main asynchronously.
        let (trend, learned) = sampling.sync { (drain.persistedTrend(), lifetime) }
        trend.save()
        if let m = learned, let url = LifetimeDrainModel.fileURL() { m.save(to: url) }
    }

    /// Closing the window leaves the app alive in the menu bar, so activating it
    /// again — Dock icon, Finder, ⌘-Tab — must bring the window back. Without this
    /// the app appears to launch and do nothing, because AppKit does not reopen a
    /// window it did not create from a nib.
    ///
    /// This is also the second way back that "Start in the menu bar only" relies
    /// on and its caption promises: opening an already-running Anode from
    /// Finder does not start a second copy, it arrives here — so a user who
    /// launched headless and expected a window gets one by doing the obvious
    /// thing again. LaunchServices sends the reopen event whatever the activation
    /// policy is, so this works while the app is `.accessory` and invisible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // `hasVisibleWindows` is AppKit's opinion, and it is `true` for a window
        // stranded on a Space that no longer exists — which made the Dock icon
        // the third control that could not open the app. See `WindowPresence`.
        //
        // And `hasVisibleWindows` counts the menu bar backdrop, which is always up:
        // with it in play the flag is never false and opening Anode again did
        // nothing. `anyWindowOpen` counts titled windows only, so the backdrop and
        // the widgets are not among them. Measured: with the flag, `open Anode.app`
        // left the window hidden.
        if !AppPresence.anyWindowOpen || main.window.isStranded { main.show() }
        return true
    }

    // ── Table ───────────────────────────────────────────────────────────────
    func tableView(_ tv: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        AnodeRowView()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tv: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        guard let d = tv.sortDescriptors.first, let k = d.key else { return }
        let before = bottomContext
        sortKey = k
        ascending = d.ascending
        sortRows()
        // In place, not `reloadData()`. A sort moves rows and changes nothing
        // else, which is the case `refreshTable` exists for — and a reload here
        // rebuilt every visible cell on the click itself: 85–190 ms of layout
        // measured on a 44-row, 14-column table, before any drawing. Clicks
        // queued behind it, so the order changed late and a second click undid
        // the first before either was seen.
        refreshTable()
        // The selection is an index, and the app it meant has just moved.
        reselectByName()
        main.table.refreshHover()
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
        main.graphSettings.isHidden = graphHidden
        // The chip and the domain both have to move, and only the chip used to.
        // `select(seconds:)` moves the highlight and does NOT fire `onSelect`,
        // so the domain reset that lives there was never reached from here.
        let snapped = Self.snappedRange(for: context, current: graphRange)
        if let snapped {
            main.graphRanges.select(seconds: snapped)
            graphRange = snapped
            graphDomainOverride = nil
            graph.timeDomain = Self.graphDomain(for: snapped)
        }

        if let s = lastSnapshot {
            updateLedger(s)
            updateGlance(s)
        }
        if graphRange > 3600 || graphDomainOverride != nil {
            let end = Date()
            loadHistorySeries(start: end.addingTimeInterval(-graphRange), end: end)
        } else {
            updateGraph(lastSnapshot)
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
    /// `AnodeHeaderCell` draws with, so a column is never sized to a string
    /// nobody renders.
    private static let headerAttributes: [NSAttributedString.Key: Any] = [
        .font: AnodeHeaderCell.font, .kern: 0.4,
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
    static let nameColumnCap: CGFloat = 240

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

            // The name column is capped. Columns only ever grow, the name is the
            // one with no natural bound ("com.apple.WebKit.WebContent (Safari)"),
            // and the starting widths already total ~1070 of a ~1130 pt table at
            // the default window — so one long name pushed the last column off
            // the edge behind a horizontal scroller. Its cells truncate with an
            // ellipsis and carry the full name as a tooltip.
            let target = id == "name"
                ? min(ceil(widest) + 22, Self.nameColumnCap)
                : ceil(widest) + 16
            if target > column.width + 1 { main.widen(column, to: target) }
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
        let cell: ProcessCellView
        if let reused = tv.makeView(withIdentifier: col.identifier, owner: self)
            as? ProcessCellView {
            cell = reused
        } else {
            cell = ProcessCellView(leadingInset: id == "name" ? 10 : 4,
                                   alignment: id == "name" ? .left : .right)
            cell.identifier = col.identifier
        }
        configure(cell, with: rows[row], id: id)
        return cell
    }

    /// Refreshes the table without rebuilding it when nothing structural moved.
    ///
    /// `reloadData()` removes every visible row view and adds it back, and for
    /// each one AppKit re-derives the tab-key focus chain by walking the row's
    /// whole subtree. Profiled with `sample`, that was the largest single cost in
    /// the app: 927 samples under `_addRowViewForVisibleRow:`, of which 462 were
    /// `_setDefaultKeyViewLoop` alone — against 73 for the entire sampling queue
    /// that produces the numbers. Every two seconds, to change some text.
    ///
    /// None of that work is needed here, because a row view holds nothing about
    /// the row it is showing: `AnodeRowView` draws alternation, selection and
    /// hover, all of which are properties of the INDEX and not of the process
    /// sitting at it. So a re-sort — which is most ticks, since the table is
    /// ordered by a number that keeps moving — needs no new views at all. Only
    /// the labels are stale, and writing straight into them skips the teardown,
    /// the re-add and the focus-chain walk entirely.
    ///
    /// A changed row COUNT is the one thing this cannot paint over, and it takes
    /// `noteNumberOfRowsChanged()` rather than a reload: that adds or removes the
    /// rows that actually differ instead of every row on screen.
    func refreshTable() {
        if main.table.numberOfRows != rows.count { main.table.noteNumberOfRowsChanged() }

        // Every row view that EXISTS, which is not the same as every row view on
        // screen: AppKit keeps a margin of them just outside the visible rect and
        // does not ask for them again when they scroll back in. Refreshing only
        // what `visibleRect` covers would leave that margin holding the values it
        // had when it left, ready to be scrolled to. Rows with no view yet need
        // nothing — they are built through `viewFor`, which configures them.
        main.table.enumerateAvailableRowViews { rowView, row in
            guard row >= 0, row < rows.count else { return }
            for (column, col) in main.table.tableColumns.enumerated() {
                let id = col.identifier.rawValue
                guard id != ProcessColumns.spacerID,
                      let cell = rowView.view(atColumn: column) as? ProcessCellView
                else { continue }
                configure(cell, with: rows[row], id: id)
            }
        }
    }

    /// Puts a row's values into an existing cell. The only writer of cell content,
    /// so the in-place refresh above and AppKit's own `viewFor` cannot drift apart.
    func configure(_ cell: ProcessCellView, with r: Row, id: String) {
        let (text, dim) = cellText(r, id)
        guard let label = cell.textField else { return }
        label.stringValue = text
        cell.setFont(font(for: id, isApp: r.isApp))
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
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Before run(), not inside applicationDidFinishLaunching: the policy set here is
// the one the first frame is drawn under, so a menu-bar-only start never shows a
// Dock tile at all rather than showing one and taking it away.
//
// From here on the policy follows the windows: `.regular` while one is open,
// because an `.accessory` app gets NO application menu, and `.accessory` once
// the last one closes and there is a menu bar widget to click instead. See
// `AppPresence.settle` and `NSWindow.bringForward` for how the two directions
// are kept out of each other's runloop turn.
app.setActivationPolicy(
    AppPresence.launchActivationPolicy(
        startInMenuBarOnly: Settings.shared.startInMenuBarOnly,
        widgetsEnabled: Settings.shared.menuBarWidgetsEnabled))
// Settings, the forecast check and anything else titled: when the last of them
// closes with the main window already hidden, the tile goes with it.
NotificationCenter.default.addObserver(
    forName: NSWindow.willCloseNotification, object: nil, queue: .main
) { _ in AppPresence.settle() }
app.run()

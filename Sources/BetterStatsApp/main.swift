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
    /// nil for system rows: those come from Apple's coalition rollup, which
    /// reports per-app totals and no pids at all, so there is no process to
    /// inspect, no memory footprint to read and nothing to quit.
    let app: AppDrain?
    /// Set when this row is an apportioned share of a measured bucket rather than
    /// a measured quantity in its own right. Everything user-facing keys off this:
    /// a modeled row must never be presentable as a measured one.
    let system: SystemAttribution.Row?

    var isModeled: Bool { system != nil }

    init(app: AppDrain, windowPct: Double?, costMin: Double?) {
        self.name = app.name
        self.procs = app.processCount
        self.pctHr = app.percentPerHour
        self.windowPct = windowPct
        self.costMin = costMin
        self.isApp = app.isApp
        self.app = app
        self.system = nil
    }

    /// A named share of the CPU power `proc_pid_rusage` could not attribute.
    /// `windowPct` and `costMin` stay nil: there is no per-app history for a
    /// coalition, and the quit-this counterfactual needs a process to quit.
    init(system: SystemAttribution.Row) {
        self.name = system.name
        self.procs = 0
        self.pctHr = system.percentPerHour
        self.windowPct = nil
        self.costMin = nil
        self.isApp = false
        self.app = nil
        self.system = system
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {

    var main: MainWindowController!
    var graph: HistoryGraphView!
    var inspector: InspectorView!
    let networkPane = NetworkPane(frame: .zero)
    let sensorsPane = SensorsPane(frame: .zero)
    let fansPane = FansPane(frame: .zero)
    /// Latest utilisation snapshot, so a pane can redraw without waiting for the
    /// next sample.
    var lastSystem: SystemMetrics.Snapshot?
    var widgets: MenuBarWidgetController!

    var monitor: PowerMonitor?
    var store: HistoryStore?
    let drain = DrainRateEstimator()
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
    var sortKey = "pctHr"
    var ascending = false
    var timer: Timer?

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
        })
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
        // Match the cadence to who is actually reading.
        restartTimer(hidden: !visible)

        // One tick at a time, on one queue. A tick arriving while the previous one
        // is still running is dropped, not queued and not run beside it.
        sampleGate.submit(on: sampling) { [weak self] in
            guard let self else { return }
            let wantFull = visible
                || Date().timeIntervalSince(self.lastFullTick) >= self.backgroundFullInterval
            // Attribution only when someone can see it. The rollup feeds the
            // process table and the drill-down, both of which are off screen.
            guard let snap = m.tick(full: wantFull, attribution: visible) else { return }
            if wantFull { self.lastFullTick = Date() }

            // Sensor discovery walks thousands of SMC keys, so only pay for it when
            // something is actually displaying a temperature or fan speed.
            // A sensors or fans pane needs the SMC read whether or not a widget is
            // bound to one.
            // Visible: everything, because a pane or a lens may show any of it.
            // Hidden: only what a widget is actually bound to.
            let needs: SystemMetrics.Needs = visible
                ? .all
                : self.hiddenNeeds
            let sysSnap = self.sysMetrics.sample(needs: needs)
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
                                   socPercent: snap.state.map { Double($0.percent) },
                                   interval: snap.interval)
            }
            var est: DrainEstimate?
            if let st = snap.state {
                self.drain.record(state: st, scale: snap.scale,
                                  powerBased_pctHr: snap.smoothed_pctHr)
                est = self.drain.estimate()
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
        rows = s.apps
            .filter { showDaemons || $0.isApp }
            .filter { row in
                if row.isApp { return true }
                switch self.lens {
                // 2.0, not 0.05. The old floor sat on a value that was 41.667x
                // too small, so it was really admitting anything above 2.08% of
                // one core. Keeping 0.05 after the unit fix would admit every
                // process that executed at all and the lens would stop filtering.
                // This preserves the behaviour the floor actually had.
                case .cpu:    return row.cpuPercent >= 2.0
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

        // Named shares of the CPU power rusage cannot see — WindowServer and the
        // root daemons. Battery lens only: these carry an apportioned wattage and
        // nothing else, so in the CPU, memory or disk lenses every column but the
        // name would be "—" and the rows would be pure clutter.
        if lens == .battery, showDaemons {
            rows += s.systemApps
                .filter { $0.percentPerHour >= floor }
                .map(Row.init(system:))
        }

        // The GPU lens is a different table entirely. rusage's energy counter is
        // CPU-side, so the app rows have nothing to say about the GPU; these come
        // from the measured GPU rail split by coalition GPU time, and they were
        // being computed every tick and shown nowhere.
        if lens == .gpu {
            rows = s.gpuApps.map(Row.init(system:))
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
        refreshPane()
    }

    func updateLedger(_ s: PowerMonitor.Snapshot) {
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
            source: s.smcTotal_W != nil
                ? "PSTR" + (s.smcGain.map { String(format: " ×%.2f", $0) } ?? "")
                : (s.measured_W != nil ? "gas gauge" : "estimating"),
            readable: s.readable,
            attempted: s.attempted,
            overflow: s.hasAttributionOverflow)

        main.glance.model = GlanceCardView.model(from: s, drain: lastDrain)
        main.sidebar.refreshValues()
    }

    /// Pull a historical range out of the store and hand it to the graph.
    ///
    /// Bucketed SQL-side to at most ~700 points, so a 7-day query costs the same
    /// as an hour and the view never receives more samples than it has pixels.
    func loadHistorySeries(start: Date, end: Date) {
        guard let store else { return }
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
                return .init(time: p.time, value: soc, onPower: !p.onBattery)
            }
            DispatchQueue.main.async {
                self.graph.series = [.init(name: "total", color: Palette.accent, points: series)]
                self.graph.rightSeries = charge.count >= 2
                    ? .init(name: "battery", color: Palette.chargeLine, points: charge)
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
                                  NSColor.systemPurple, NSColor.systemTeal]
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
        -> (pctHr: Double, timeRemaining_hr: Double?, source: DrainEstimate.Source) {
        let draining = s.direction == .draining
        if let e = est, e.source == .discharge, draining {
            return (e.percentPerHour, e.timeRemaining.map { $0 / 3600 }, .discharge)
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
        return (shown, hours, source)
    }

    func updateGraph(_ s: PowerMonitor.Snapshot?) {
        guard let s else { return }
        // A historical or zoomed view is not a live chart. Ticking new points into
        // it would make the line creep rightward under a fixed axis and slowly
        // overwrite what the user asked to look at.
        guard graphRange <= 3600, graphDomainOverride == nil else { return }
        let now = Date()
        totalSeries.append(.init(time: now, value: s.smoothed_pctHr))
        if let pct = s.state?.percent {
            chargeSeries.append(.init(time: now, value: Double(pct)))
        }
        let cutoff = now.addingTimeInterval(-graphSpan)
        totalSeries.removeAll { $0.time < cutoff }
        chargeSeries.removeAll { $0.time < cutoff }

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
        } else {
            // One series: total drain. The attributed-versus-unaccounted split
            // already has a home in the ledger bar directly above, and drawing it
            // twice turned a glanceable trend into something you had to decode.
            graph.series = [
                .init(name: "total", color: Palette.accent, points: totalSeries, filled: true)
            ]
            graph.yAxisLabel = "%/hr"
        }
        // Charge on its own axis, sampled at the same cadence as the rate, so the
        // fall can be read against the spike that caused it.
        graph.rightSeries = chargeSeries.isEmpty ? nil
            : .init(name: "charge", color: Palette.chargeLine,
                    points: chargeSeries, filled: false)
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
        inspector.model = InspectorView.model(app: app, snapshot: snap, lens: lens)
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
            // System rows sort as -1 rather than 0 on these: they have no reading
            // at all, and a real zero should still outrank "not measurable".
            case "cpu":    r = (a.app?.cpuPercent ?? -1) < (b.app?.cpuPercent ?? -1)
            case "mem":    r = (a.app.map { Double($0.memoryBytes) } ?? -1)
                             < (b.app.map { Double($0.memoryBytes) } ?? -1)
            case "disk":   r = (a.app?.diskBytesPerSec ?? -1) < (b.app?.diskBytesPerSec ?? -1)
            case "gputime": r = (a.system?.gpu_ms ?? 0) < (b.system?.gpu_ms ?? 0)
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

    /// Push the latest readings into whichever whole-machine pane is showing.
    func refreshPane() {
        guard !lens.isPerProcess, let sys = lastSystem else { return }
        switch lens {
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
        case .cpuUsage:    return .cpu
        case .memoryUsage: return .memory
        case .gpuUsage:    return .gpu
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
            // the Battery lens. Compared by family taken from a constant, so the
            // prefix is not spelled out a second time here.
            return metric.family == MetricID.batteryPercent.family ? .battery : nil
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

    /// Lens switch. Only Battery has its columns implemented so far; the rest keep
    /// the current table rather than showing an empty one, and are wired as their
    /// data lands.
    func select(_ lens: SidebarView.Lens) {
        self.lens = lens

        // Whole-machine entries get their own pane; there is no honest per-process
        // view of network traffic or fan speed.
        guard lens.isPerProcess else {
            switch lens {
            case .network: main.showPane(networkPane)
            case .sensors: main.showPane(sensorsPane)
            case .fans:    main.showPane(fansPane)
            default:       main.showPane(nil)
            }
            refreshPane()
            return
        }
        main.showPane(nil)
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
            // GPU power per app, which macOS exposes no API for at all. Both
            // columns come from Apple's coalition rollup, so both are modeled.
            return [("name", "Application", 300), ("pctHr", "%/hr (GPU)", 96),
                    ("gputime", "GPU time", 100), ("spacer", "", 20)]
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
    var needsSensors: Bool { hiddenNeeds.contains(.sensors) }

    /// Exactly the subsystems the menu bar is currently displaying.
    ///
    /// Generalises what `needsSensors` already did for the SMC to every source:
    /// with the window closed the only reader is the widget set, so anything not
    /// bound to a widget is work done for nobody. The group widget is the one
    /// exception — it can expand to show everything, so it asks for everything.
    var hiddenNeeds: SystemMetrics.Needs {
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
            guard let a = r.app else { return ("—", true) }
            // Once a row is shown its number is shown down to a tenth of a
            // percent; the 2.0 gate above decides membership, this only decides
            // whether a value is meaningful enough to print.
            return (a.cpuPercent < 0.1 ? "—" : String(format: "%.1f%%", a.cpuPercent),
                    a.cpuPercent < 0.1)
        case "mem":
            guard let a = r.app else { return ("—", true) }
            return (a.memoryBytes == 0 ? "—" : MetricUnit.bytes.format(Double(a.memoryBytes)),
                    a.memoryBytes == 0)
        case "disk":
            guard let a = r.app else { return ("—", true) }
            return (a.diskBytesPerSec < 1
                        ? "—" : MetricUnit.bytesPerSecond.format(a.diskBytesPerSec),
                    a.diskBytesPerSec < 1)
        case "gputime":
            guard let g = r.system?.gpu_ms, g > 0 else { return ("—", true) }
            return (g >= 1000 ? String(format: "%.1f s", Double(g) / 1000)
                              : "\(g) ms", false)
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
    /// Header font for measurement. Hoisted out of the loop it used to sit in,
    /// where it was reconstructed once per column per tick.
    private static let headerFont = NSFont.systemFont(ofSize: 11, weight: .medium)

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
            guard id != "spacer" else { continue }

            var widest = (column.title as NSString)
                .size(withAttributes: [.font: Self.headerFont]).width

            for i in range where i < rows.count {
                let r = rows[i]
                let (text, _) = cellText(r, id)
                let w = (text as NSString)
                    .size(withAttributes: [.font: font(for: id, isApp: r.isApp)]).width
                widest = max(widest, w)
            }

            let target = ceil(widest) + (id == "name" ? 26 : 20)
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
        if id == "spacer" {
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
        return cell
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

import AppKit
import PowerKit

/// Developer view: what is Anode doing, and what does that cost?
///
/// Stats for nerds. Which build is running, how often it is really sampling (and
/// why that rate), what a tick costs, and what the process itself draws — CPU,
/// GPU, memory, wakeups, and watts, which is the number this whole app exists to
/// be honest about.
///
/// Two sources, matched to what they cost. The sampling half is the tick's own
/// ledger (`TickLedger`), which is always on because it cannot be reconstructed
/// afterwards. The process half is read from the kernel by THIS window's timer
/// and nobody else's, so a closed window adds nothing to the background floor.
///
/// The window's own refresh is part of what it measures. Its timer wakes the app
/// once a second while it is open, and that shows up in the "now" column — said
/// on screen at the foot, because a gauge that disturbs what it reads should not
/// let the reading pass for the undisturbed one.
final class AnodeStatsWindowController: NSWindowController, NSWindowDelegate {

    private let store: HistoryStore?
    private let build = BuildInfo(info: Bundle.main.infoDictionary)

    // Everything below the main thread's line is touched only on `reader`.
    private let reader = DispatchQueue(label: "Anode.AnodeStats", qos: .utility)
    private let gpu = SelfGPU()
    private var previous: SelfUsage.Sample?
    private var history: (cpu: [HistoryGraphView.Point], power: [HistoryGraphView.Point]) = ([], [])
    private var storeLine = "—"
    private var storeReadAt = Date.distantPast
    private var peakFootprint: UInt64 = 0

    private var timer: Timer?
    private var values: [String: [NSTextField]] = [:]
    private let cpuGraph = HistoryGraphView()
    private let powerGraph = HistoryGraphView()

    /// Five minutes at the one-second refresh.
    private static let historyLimit = 300

    init(store: HistoryStore?) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 700),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Anode Stats"
        window.minSize = NSSize(width: 760, height: 620)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildLayout()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        showWindow(nil)
        window?.bringForward()
        startTimer()
        refresh()
    }

    // The timer exists only while the window does. Not `.common` + a visibility
    // check on every fire: a stopped timer is a wakeup that never happens.
    func windowWillClose(_ notification: Notification) { stopTimer() }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        // Back to a cold start next time: a gap of hours between two samples is
        // not a rate, and the graph should not draw a line across it.
        reader.async { [self] in
            previous = nil
            history = ([], [])
        }
    }

    // ── Layout ──────────────────────────────────────────────────────────────

    private func buildLayout() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = Palette.background.cgColor

        let left = NSStackView(views: [
            section("Build", rows: [
                ("version", "Version"), ("commit", "Source commit"),
                ("checkout", "Source checkout"), ("bundle", "Installed at"),
                ("process", "Process"), ("system", "System"),
                ("uptime", "Running for"),
            ]),
            section("Sampling", rows: [
                ("mode", "Cadence set by"), ("interval", "Timer interval"),
                ("gaps", "Observed gap"), ("ticks", "Ticks since launch"),
                ("dropped", "Dropped ticks"), ("fullPolicy", "Full ticks"),
                ("lastFull", "Last full tick"),
                ("fullCost", "Full tick cost"), ("lightCost", "Light tick cost"),
                ("mainCost", "Main-thread half"), ("duty", "Tick work, all-time"),
                ("history", "History database"),
            ]),
        ])
        let right = NSStackView(views: [
            section("This process", columns: ["now", "since launch"], rows: [
                ("cpu", "CPU (% of one core)"), ("power", "Power"),
                ("share", "Share of machine draw"), ("battery", "Battery cost"),
                ("gpu", "GPU time"), ("memory", "Memory footprint"),
                ("threads", "Threads"), ("wakeups", "Wakeups"),
                ("diskRead", "Disk read"), ("diskWrite", "Disk write"),
                ("ipc", "Instructions per cycle"),
            ]),
            graphBlock(),
        ])
        for column in [left, right] {
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 18
        }

        let note = NSTextField(wrappingLabelWithString:
            "This window refreshes once a second while it is open, and its own work is "
          + "inside the “now” column. “Since launch” averages the whole life of the "
          + "process, window included only while it was open.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = Palette.faint

        let columns = NSStackView(views: [left, right])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.distribution = .fillEqually
        columns.spacing = 28

        let stack = NSStackView(views: [columns, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            columns.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            note.widthAnchor.constraint(equalTo: columns.widthAnchor),
            content.bottomAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor),
        ])
    }

    private func graphBlock() -> NSView {
        cpuGraph.yAxisLabel = "% of a core"
        powerGraph.yAxisLabel = "mW"
        let stack = NSStackView(views: [cpuGraph, powerGraph])
        stack.orientation = .vertical
        stack.spacing = 8
        NSLayoutConstraint.activate([
            cpuGraph.heightAnchor.constraint(equalToConstant: 118),
            powerGraph.heightAnchor.constraint(equalToConstant: 118),
            cpuGraph.widthAnchor.constraint(equalTo: stack.widthAnchor),
            powerGraph.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return stack
    }

    /// A titled grid of label → value rows. Values are registered by id so a
    /// refresh is a lookup, not a rebuild.
    private func section(_ title: String, columns: [String] = [""],
                         rows: [(id: String, label: String)]) -> NSView {
        let header = NSTextField(labelWithString: title.uppercased())
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = Palette.accent
        let grid = NSGridView()
        grid.rowSpacing = 5
        grid.columnSpacing = 12
        if columns.count > 1 {
            let heads: [NSView] = [NSGridCell.emptyContentView]
                + columns.map { name in
                    let f = NSTextField(labelWithString: name)
                    f.font = .systemFont(ofSize: 10)
                    f.textColor = Palette.faint
                    f.alignment = .right
                    return f
                }
            grid.addRow(with: heads)
        }
        for row in rows {
            let label = NSTextField(labelWithString: row.label)
            label.font = .systemFont(ofSize: 12)
            label.textColor = Palette.faint
            let fields: [NSTextField] = columns.map { _ in
                let f = NSTextField(labelWithString: "—")
                f.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                f.textColor = Palette.text
                f.lineBreakMode = .byTruncatingMiddle
                f.alignment = columns.count > 1 ? .right : .left
                f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                return f
            }
            values[row.id] = fields
            grid.addRow(with: [label] + fields)
        }
        grid.column(at: 0).xPlacement = .leading
        for i in 1..<grid.numberOfColumns {
            grid.column(at: i).xPlacement = columns.count > 1 ? .trailing : .leading
        }
        let stack = NSStackView(views: [header, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private func set(_ id: String, _ text: String, column: Int = 0) {
        guard let fields = values[id], column < fields.count else { return }
        if fields[column].stringValue != text { fields[column].stringValue = text }
    }

    // ── Refresh ─────────────────────────────────────────────────────────────

    private func refresh() {
        // The sampling half is main-thread state to read and cheap, so it happens
        // here; the kernel and the registry are read off it.
        let ledger = TickLedger.shared.summary()
        showBuild()
        showSampling(ledger)
        let store = self.store
        reader.async { [self] in
            // GPU first, so both counters in the sample describe the same moment
            // as nearly as two reads can.
            let sample = SelfUsage.read(gpu: gpu.accumulated_ns())
            if Date().timeIntervalSince(storeReadAt) > 30, let store {
                storeReadAt = Date()
                let size = ByteCountFormatter.string(fromByteCount: store.sizeOnDisk, countStyle: .file)
                let n = store.stats()
                storeLine = "\(size) · \(n.rawIntervals.formatted()) raw, "
                          + "\(n.intervals.formatted()) bucketed, \(n.appRows.formatted()) app rows"
            }
            guard let sample else { return }
            let now = Date()
            let rates = previous.flatMap { SelfUsage.rates(from: $0, to: sample) }
            previous = sample
            peakFootprint = max(peakFootprint, sample.peakFootprint)
            if let r = rates {
                history.cpu.append(.init(time: now, value: r.cpuPercent))
                history.power.append(.init(time: now, value: r.watts * 1000))
                if history.cpu.count > Self.historyLimit {
                    history.cpu.removeFirst(); history.power.removeFirst()
                }
            }
            let lifetime = SelfUsage.lifetimeRates(sample)
            let snapshot = (history.cpu, history.power, storeLine)
            DispatchQueue.main.async { [self] in
                showProcess(sample: sample, now: rates, lifetime: lifetime, ledger: ledger)
                set("history", snapshot.2)
                cpuGraph.timeDomain = (now.addingTimeInterval(-Double(Self.historyLimit)), now)
                powerGraph.timeDomain = cpuGraph.timeDomain
                cpuGraph.series = [.init(name: "Anode CPU", color: Palette.accent, points: snapshot.0)]
                powerGraph.series = [.init(name: "Anode power", color: Palette.violet, points: snapshot.1)]
            }
        }
    }

    private func showBuild() {
        let info = Bundle.main.infoDictionary
        set("version", "\(build.version) (build \(build.build))")
        set("commit", build.commit.map { $0 + (build.isModified ? "  · modified tree" : "") }
            ?? "unknown")
        set("checkout", build.sourcePath ?? "not recorded")
        set("bundle", info == nil ? "not a bundle (swift run)" : Bundle.main.bundlePath)
        let arch = ProcessInfo.processInfo.isiOSAppOnMac ? "iOS-on-Mac" : Self.machineArchitecture
        set("process", "pid \(getpid()) · \(arch)")
        set("system", ProcessInfo.processInfo.operatingSystemVersionString)
    }

    private func showSampling(_ l: TickLedger.Summary) {
        if let m = l.mode {
            set("mode", m.headline)
            set("interval", Self.seconds(m.effectiveInterval) + "  — " + m.reason)
            set("fullPolicy", m.fullTickPolicy)
        }
        if let g = TickLedger.gapStats(l.recentGaps) {
            set("gaps", String(format: "%.2f s mean · %.2f–%.2f s  (last %d)",
                               g.mean, g.min, g.max, l.recentGaps.count))
        } else {
            set("gaps", "—")
        }
        set("ticks", "\(l.totalTicks.formatted()) · \(l.full.count.formatted()) full, "
                   + "\(l.light.count.formatted()) light")
        set("dropped", l.dropped == 0 ? "none" : "\(l.dropped.formatted())")
        set("lastFull", l.lastFullAt.map { Self.ago($0) } ?? "none yet")
        set("fullCost", Self.cost(l.full))
        set("lightCost", Self.cost(l.light))
        set("mainCost", l.main.count == 0 ? "—"
            : String(format: "%.2f ms CPU mean", l.main.meanCPU_ms ?? 0))
    }

    private func showProcess(sample s: SelfUsage.Sample, now: SelfUsage.Rates?,
                             lifetime life: SelfUsage.Rates?, ledger l: TickLedger.Summary) {
        let launched = Date().addingTimeInterval(
            -Double(s.uptime_ns &- s.launchedAt_ns) / 1e9)
        set("uptime", Self.duration(Date().timeIntervalSince(launched))
            + "  (since \(launched.formatted(date: .abbreviated, time: .shortened)))")

        // Tick work as a share of the process's whole life — the number that
        // decides whether the background floor is where the battery goes.
        let tickNs = Double(l.light.cpu_ns &+ l.full.cpu_ns &+ l.main.cpu_ns)
        let lifeNs = Double(s.uptime_ns &- s.launchedAt_ns)
        set("duty", lifeNs > 0
            ? String(format: "%.3f %% of one core  (%.0f %% of the process's CPU)",
                     tickNs / lifeNs * 100, s.cpu_ns > 0 ? tickNs / Double(s.cpu_ns) * 100 : 0)
            : "—")

        func both(_ id: String, _ f: (SelfUsage.Rates) -> String) {
            set(id, now.map(f) ?? "—", column: 0)
            set(id, life.map(f) ?? "—", column: 1)
        }
        both("cpu") { String(format: "%.2f %%", $0.cpuPercent) }
        both("power") { Self.milliwatts($0.watts) }
        both("battery") { r in
            guard let j = l.joulesPerPercent, j > 0 else { return "—" }
            return String(format: "%.3f %%/hr", r.watts * 3600 / j)
        }
        both("share") { r in
            guard let machine = l.machine_W, machine > 0.05 else { return "—" }
            return String(format: "%.2f %%", r.watts / machine * 100)
        }
        both("wakeups") { String(format: "%.1f /s", $0.wakeupsPerSecond) }
        both("gpu") { r in r.gpuPercent.map { String(format: "%.3f %%", $0) } ?? "—" }
        both("diskRead") { Self.rate($0.diskReadBytesPerSecond) }
        both("diskWrite") { Self.rate($0.diskWriteBytesPerSecond) }
        // Since launch, a rate alone hides the total it came from: a process that
        // wrote 400 MB in a day and one that wrote 4 KB both round to "0 B/s".
        if let life {
            set("gpu", (life.gpuPercent.map { String(format: "%.3f %%", $0) } ?? "—")
                + (s.gpu_ns.map { " · " + Self.gpuTotal($0) } ?? ""), column: 1)
            set("diskRead", Self.rate(life.diskReadBytesPerSecond) + " · "
                + Self.bytes(s.diskRead), column: 1)
            set("diskWrite", Self.rate(life.diskWriteBytesPerSecond) + " · "
                + Self.bytes(s.diskWritten), column: 1)
        }

        set("memory", Self.bytes(s.footprint, memory: true))
        set("memory", "peak " + Self.bytes(peakFootprint, memory: true), column: 1)
        set("threads", s.threads.map(String.init) ?? "—")
        if s.cycles > 0 {
            set("ipc", String(format: "%.2f", Double(s.instructions) / Double(s.cycles)))
        }
    }

    // ── Formatting ──────────────────────────────────────────────────────────

    private static var machineArchitecture: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    private static func seconds(_ t: TimeInterval) -> String {
        t == t.rounded() ? String(format: "%.0f s", t) : String(format: "%.1f s", t)
    }

    private static func cost(_ t: TickLedger.Tally) -> String {
        guard let cpu = t.meanCPU_ms, let wall = t.meanWall_ms else { return "—" }
        return String(format: "%.2f ms CPU · %.2f ms wall  (last %.2f)",
                      cpu, wall, Double(t.lastCPU_ns) / 1e6)
    }

    private static func ago(_ date: Date) -> String {
        let s = max(0, Date().timeIntervalSince(date))
        return s < 90 ? String(format: "%.0f s ago", s) : duration(s) + " ago"
    }

    private static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        let (d, h, m, sec) = (s / 86_400, s / 3600 % 24, s / 60 % 60, s % 60)
        return d > 0 ? String(format: "%dd %02d:%02d:%02d", d, h, m, sec)
                     : String(format: "%02d:%02d:%02d", h, m, sec)
    }

    private static func milliwatts(_ w: Double) -> String {
        w >= 1 ? String(format: "%.2f W", w) : String(format: "%.1f mW", w * 1000)
    }

    private static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    private static func bytes(_ n: UInt64, memory: Bool = false) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: n),
                                  countStyle: memory ? .memory : .file)
    }

    private static func gpuTotal(_ ns: UInt64) -> String {
        let s = Double(ns) / 1e9
        return s < 1 ? String(format: "%.1f ms", s * 1000) : String(format: "%.2f s", s)
    }
}

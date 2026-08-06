import AppKit
import PowerKit

// BetterStats — milestone 1, launchable.
// Window + menu bar readout, both fed by the same PowerMonitor.

final class Row: NSObject {
    let name: String, procs: Int, pctHr: Double, joules: Double, isApp: Bool
    init(name: String, procs: Int, pctHr: Double, joules: Double, isApp: Bool) {
        self.name = name; self.procs = procs; self.pctHr = pctHr
        self.joules = joules; self.isApp = isApp
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {

    var window: NSWindow!
    var table: NSTableView!
    var statusItem: NSStatusItem!
    var ledger: NSTextField!
    var header: NSTextField!
    var monitor: PowerMonitor?
    var rows: [Row] = []
    var sortKey = "pctHr"
    var ascending = false
    let interval: TimeInterval = 2

    func applicationDidFinishLaunching(_ note: Notification) {
        monitor = PowerMonitor()

        // ── Menu bar ────────────────────────────────────────────────────────
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⚡ —"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleWindow)

        // ── Window ──────────────────────────────────────────────────────────
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "BetterStats — Battery"
        window.center()
        window.setFrameAutosaveName("BetterStatsMain")

        let content = NSView(frame: window.contentView!.bounds)
        content.autoresizingMask = [.width, .height]

        header = NSTextField(labelWithString: "starting…")
        header.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        header.textColor = .secondaryLabelColor
        header.frame = NSRect(x: 12, y: 448, width: 696, height: 20)
        header.autoresizingMask = [.width, .minYMargin]
        content.addSubview(header)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 64, width: 720, height: 384))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        table = NSTableView(frame: scroll.bounds)
        table.usesAlternatingRowBackgroundColors = true
        table.rowSizeStyle = .small
        table.allowsColumnResizing = true

        func column(_ id: String, _ title: String, _ width: CGFloat, _ align: NSTextAlignment) {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: false)
            if align == .right { c.headerCell.alignment = .right }
            table.addTableColumn(c)
        }
        column("name", "App", 290, .left)
        column("pctHr", "%/hr", 90, .right)
        column("joules", "Joules", 90, .right)
        column("procs", "Procs", 70, .right)
        column("kind", "Kind", 90, .left)

        table.dataSource = self
        table.delegate = self
        table.sortDescriptors = [NSSortDescriptor(key: "pctHr", ascending: false)]
        scroll.documentView = table
        content.addSubview(scroll)

        ledger = NSTextField(labelWithString: "")
        ledger.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        ledger.frame = NSRect(x: 12, y: 8, width: 696, height: 52)
        ledger.autoresizingMask = [.width, .maxYMargin]
        ledger.maximumNumberOfLines = 3
        content.addSubview(ledger)

        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // ── Sampling loop ───────────────────────────────────────────────────
        monitor?.tick()  // prime; first tick has no window to diff
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        guard let m = monitor else { return }
        DispatchQueue.global(qos: .utility).async {
            guard let snap = m.tick() else { return }
            DispatchQueue.main.async { self.apply(snap) }
        }
    }

    func apply(_ s: PowerMonitor.Snapshot) {
        rows = s.apps.map {
            Row(name: $0.name, procs: $0.processCount, pctHr: $0.percentPerHour,
                joules: $0.joules, isApp: $0.isApp)
        }
        sortRows()
        table.reloadData()

        let st = s.state
        let charge = st.map { "\($0.percent)%\($0.onAC ? " (AC)" : "")" } ?? "—"
        header.stringValue = String(
            format: "battery %@   ·   health %.0f%%   ·   1%% = %.0f J   ·   %d readable of %d (%.0f%%), %d denied   ·   %d active",
            charge, s.scale.health * 100, s.scale.joulesPerPercent,
            s.readable, s.attempted, s.coverage * 100, s.denied, s.active)

        // Ledger: named buckets that sum to the measured total, with the residual
        // printed rather than smeared across apps.
        let gpuTxt = s.gpu_pctHr.map { String(format: "%5.2f", $0) } ?? "   —"
        let resTxt = s.residual_pctHr.map { String(format: "%5.2f", $0) } ?? "   —"
        let shareTxt = s.residualShare.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
        let src = s.smcTotal_W != nil
            ? String(format: "SMC PSTR%@", s.smcGain.map { g in String(format: " ×%.2f", g) } ?? " (uncal)")
            : (s.measured_W != nil ? "gas gauge (60s)" : "estimated")

        ledger.stringValue = [
            String(format: "apps (CPU) %5.2f %%/hr    GPU %@ %%/hr    unmeasured %@ %%/hr (%@)",
                   s.attributed_pctHr, gpuTxt, resTxt, shareTxt),
            String(format: "TOTAL      %5.2f %%/hr    source: %@    %@",
                   s.smoothed_pctHr, src,
                   s.projectedRuntime_hr().map { h in
                       String(format: "→ %dh %02dm left", Int(h), Int(h * 60) % 60)
                   } ?? "on AC"),
            "unmeasured = display, radios, SSD, kernel, and root-owned processes",
        ].joined(separator: "\n")

        var title = String(format: "⚡ %.1f %%/hr", s.smoothed_pctHr)
        if let hr = s.projectedRuntime_hr() {
            title += String(format: "  %dh%02dm", Int(hr), Int(hr * 60) % 60)
        }
        if !s.isCalibrated { title += "*" }
        statusItem.button?.title = title
    }

    func sortRows() {
        let asc = ascending
        rows.sort { a, b in
            let r: Bool
            switch sortKey {
            case "name":   r = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case "joules": r = a.joules < b.joules
            case "procs":  r = a.procs < b.procs
            case "kind":   r = (a.isApp ? 1 : 0) < (b.isApp ? 1 : 0)
            default:       r = a.pctHr < b.pctHr
            }
            return asc ? r : !r
        }
    }

    @objc func toggleWindow() {
        if window.isVisible && NSApp.isActive {
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

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

        let text: String
        var align = NSTextAlignment.right
        switch id {
        case "name":   text = r.name; align = .left
        case "pctHr":  text = r.pctHr < 0.01 ? "<0.01" : String(format: "%.2f", r.pctHr)
        case "joules": text = String(format: "%.2f", r.joules)
        case "procs":  text = r.procs > 1 ? "\(r.procs)" : "—"
        default:       text = r.isApp ? "app" : "daemon"; align = .left
        }

        let cell = NSTextField(labelWithString: text)
        cell.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        cell.alignment = align
        cell.lineBreakMode = .byTruncatingTail
        if id == "kind" || id == "procs" { cell.textColor = .secondaryLabelColor }
        if id == "name" && r.isApp { cell.font = .monospacedSystemFont(ofSize: 11, weight: .semibold) }
        return cell
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

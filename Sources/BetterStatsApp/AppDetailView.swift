import AppKit
import UniformTypeIdentifiers

/// Drill-down from one app row to the processes behind it.
///
/// The summary table deliberately rolls fifteen `Code Helper` processes into one
/// "Visual Studio Code" row — right for deciding WHAT to quit, wrong for deciding
/// WHICH helper is burning the battery. A renderer pinned at 100% and a leaking
/// extension host are indistinguishable at the app level; this view splits them.
///
/// Deliberately PowerKit-free: it consumes a plain `Model` so it can be exercised
/// (and offscreen-rendered) without the measurement stack. The bridge that builds
/// a `Model` from `AppDrain` + `PowerMonitor.Snapshot` lives in
/// `AppDetailModel+PowerKit.swift`.
///
/// Honesty contract, same as the main ledger:
///   - The two share figures are DIFFERENT DENOMINATORS and are labelled as such.
///     "of attributed" divides by the sum of app rows (own-uid CPU + GPU — an
///     under-count). "of measured" divides by the whole-machine measurement.
///     Attributed is often <15% of measured; conflating them would make every app
///     look 7x more guilty than it is.
///   - Watts are internal only. Everything displayed is %/hr or joules.
///   - This view NEVER kills a process. Quit intent is surfaced through
///     `onQuitRequested` and the integrator owns the decision.
public final class AppDetailView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {

    // MARK: - Public model

    public struct ProcessRow {
        public let name: String
        public let pid: Int32
        public let path: String
        public let percentPerHour: Double
        public let joules: Double
        public init(name: String, pid: Int32, path: String, percentPerHour: Double, joules: Double) {
            self.name = name; self.pid = pid; self.path = path
            self.percentPerHour = percentPerHour; self.joules = joules
        }
    }

    public struct Model {
        public let appName: String
        public let bundlePath: String?
        public let bundleID: String?
        public let isApp: Bool
        public let totalPercentPerHour: Double
        /// This app ÷ sum of all attributed app rows. 0...1.
        public let shareOfAttributed: Double
        /// This app ÷ the whole-machine measured total. 0...1.
        /// nil until a measured total exists (first 60 s gas-gauge batch, or SMC).
        public let shareOfMeasured: Double?
        public let processes: [ProcessRow]
        public init(appName: String, bundlePath: String?, bundleID: String?, isApp: Bool,
                    totalPercentPerHour: Double, shareOfAttributed: Double,
                    shareOfMeasured: Double?, processes: [ProcessRow]) {
            self.appName = appName; self.bundlePath = bundlePath; self.bundleID = bundleID
            self.isApp = isApp; self.totalPercentPerHour = totalPercentPerHour
            self.shareOfAttributed = shareOfAttributed; self.shareOfMeasured = shareOfMeasured
            self.processes = processes
        }
    }

    /// Setting this re-renders in place, preserving selection and scroll position —
    /// the model arrives every tick and yanking the user's context every 2 s would
    /// make the table unusable.
    public var model: Model? { didSet { apply() } }

    /// Quit intent only. nil (the default) hides the quit affordances entirely, so
    /// an integrator that hasn't decided its policy exposes nothing dangerous.
    public var onQuitRequested: ((Int32) -> Void)? { didSet { refreshQuitAffordances() } }

    /// pid of the selected row, nil when none. Exposed so the integrator can
    /// persist selection when switching between apps.
    public var selectedPID: Int32? {
        let i = table.selectedRow
        guard i >= 0, i < rows.count else { return nil }
        return rows[i].pid
    }

    /// Programmatic selection by pid (pass nil to clear). No-op if absent.
    public func selectPID(_ pid: Int32?) {
        guard let pid, let i = rows.firstIndex(where: { $0.pid == pid }) else {
            table.deselectAll(nil); return
        }
        table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
    }

    // MARK: - Subviews

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let totalLabel = NSTextField(labelWithString: "—")
    private let procCountLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let attributedBar = ShareBar()
    private let measuredBar = ShareBar()
    private let attributedValue = NSTextField(labelWithString: "—")
    private let measuredValue = NSTextField(labelWithString: "—")
    private let caveatLabel = NSTextField(labelWithString: "")
    private let quitButton = NSButton(title: "Quit Process…", target: nil, action: nil)

    private var rows: [ProcessRow] = []
    /// Last bundlePath an icon was fetched for; NSWorkspace hits the disk, and this
    /// is re-applied every 2 s tick, so don't refetch for an unchanged app.
    private var iconKey: String??

    // MARK: - Construction

    public override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    // Not storyboard/nib-instantiable; the whole app is programmatic.
    public required init?(coder: NSCoder) { fatalError("AppDetailView is code-only") }

    // Paint our own semantic background so the view is self-contained wherever the
    // integrator embeds it (window, sheet, popover) instead of relying on whatever
    // happens to be behind it. Semantic colour resolves per effectiveAppearance.
    public override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    private func build() {
        // ── Header ──────────────────────────────────────────────────────────
        iconView.imageScaling = .scaleProportionallyUpOrDown

        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        // Long Electron names ("Visual Studio Code - Insiders …") must not push the
        // totals off the right edge; the name compresses first.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        totalLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        totalLabel.alignment = .right
        procCountLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        procCountLabel.textColor = .secondaryLabelColor
        procCountLabel.alignment = .right

        // ── Table ───────────────────────────────────────────────────────────
        func column(_ id: String, _ title: String, _ width: CGFloat, right: Bool) {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            c.minWidth = 40
            if right { c.headerCell.alignment = .right }
            table.addTableColumn(c)
        }
        column("proc", "Process", 300, right: false)
        column("pid", "PID", 64, right: true)
        column("pctHr", "%/hr", 84, right: true)
        column("joules", "Joules", 90, right: true)

        table.usesAlternatingRowBackgroundColors = true
        table.rowSizeStyle = .small
        // Names deserve the spare width; the numeric columns stay compact at the
        // trailing edge (default style would stretch the LAST column instead).
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.allowsColumnResizing = true
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self

        // Context menu carries the quit intent; enabled per-row in menuNeedsUpdate.
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Quit Process…",
                                action: #selector(quitFromMenu(_:)), keyEquivalent: ""))
        menu.items.first?.target = self
        table.menu = menu

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        // ── Footer: the two-denominator breakdown ───────────────────────────
        func caption(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            l.textColor = .labelColor
            l.lineBreakMode = .byTruncatingTail
            return l
        }
        for v in [attributedValue, measuredValue] {
            v.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            v.alignment = .right
        }
        let grid = NSGridView(views: [
            [caption("share of ATTRIBUTED (own-uid CPU + GPU rows)"), attributedBar, attributedValue],
            [caption("share of MEASURED (whole machine)"), measuredBar, measuredValue],
        ])
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 2).xPlacement = .trailing
        grid.rowAlignment = .none
        for r in 0..<grid.numberOfRows { grid.row(at: r).yPlacement = .center }

        caveatLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        caveatLabel.textColor = .tertiaryLabelColor
        caveatLabel.lineBreakMode = .byTruncatingTail
        caveatLabel.stringValue =
            "different denominators — measured includes display, radios, SSD, kernel and root daemons that no app row can claim"

        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .small
        quitButton.font = .systemFont(ofSize: 11)
        quitButton.target = self
        quitButton.action = #selector(quitClicked)
        quitButton.toolTip = "Ask to quit the selected process — the request goes to the app, which decides"
        quitButton.isHidden = true   // until an integrator supplies onQuitRequested

        // ── Layout ──────────────────────────────────────────────────────────
        for v: NSView in [iconView, nameLabel, subtitleLabel, totalLabel, procCountLabel,
                          scroll, emptyLabel, grid, caveatLabel, quitButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let pad: CGFloat = 12
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: totalLabel.leadingAnchor, constant: -12),

            subtitleLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: totalLabel.leadingAnchor, constant: -12),

            totalLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            totalLabel.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            procCountLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            procCountLabel.topAnchor.constraint(equalTo: totalLabel.bottomAnchor, constant: 2),

            scroll.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40),

            grid.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),

            caveatLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 6),
            caveatLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            caveatLabel.trailingAnchor.constraint(lessThanOrEqualTo: quitButton.leadingAnchor, constant: -12),
            caveatLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),

            quitButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            quitButton.centerYAnchor.constraint(equalTo: caveatLabel.centerYAnchor),

            attributedBar.widthAnchor.constraint(equalToConstant: 140),
            attributedBar.heightAnchor.constraint(equalToConstant: 6),
            measuredBar.widthAnchor.constraint(equalToConstant: 140),
            measuredBar.heightAnchor.constraint(equalToConstant: 6),
        ])
    }

    // MARK: - Model application

    private func apply() {
        guard let m = model else {
            rows = []
            table.reloadData()
            iconView.image = nil
            iconKey = nil
            nameLabel.stringValue = ""
            subtitleLabel.stringValue = ""
            totalLabel.stringValue = "—"
            procCountLabel.stringValue = ""
            attributedBar.fraction = nil; attributedValue.stringValue = "—"
            measuredBar.fraction = nil; measuredValue.stringValue = "—"
            emptyLabel.stringValue = "No app selected"
            emptyLabel.isHidden = false
            refreshQuitAffordances()
            return
        }

        // Header. Icon by bundle path; daemons have none, so fall back to the
        // generic executable icon rather than a blank square.
        if iconKey != .some(m.bundlePath) {
            iconKey = .some(m.bundlePath)
            if let bp = m.bundlePath {
                iconView.image = NSWorkspace.shared.icon(forFile: bp)
            } else {
                iconView.image = NSWorkspace.shared.icon(for: .unixExecutable)
            }
        }
        nameLabel.stringValue = m.appName
        nameLabel.toolTip = m.appName
        if let id = m.bundleID, !id.isEmpty {
            subtitleLabel.stringValue = id
        } else if let bp = m.bundlePath {
            subtitleLabel.stringValue = bp
        } else {
            subtitleLabel.stringValue = m.isApp ? "bundle unknown" : "daemon — no app bundle"
        }
        subtitleLabel.toolTip = m.bundlePath

        totalLabel.stringValue = Self.pctHrText(m.totalPercentPerHour) + " %/hr"
        let n = m.processes.count
        procCountLabel.stringValue = n == 1 ? "1 process" : "\(n) processes"

        // Defensive re-sort: the contract is %/hr descending regardless of caller.
        let newRows = m.processes.sorted { $0.percentPerHour > $1.percentPerHour }

        // Live update without yanking context. Selection is keyed by pid, not row
        // index, because rows reorder every tick as draws change. (pid alone can be
        // reused by the kernel, but within one 2 s tick that ambiguity is acceptable
        // for a selection highlight — ProcessRow carries no startAbsTime.)
        let keepPID = selectedPID
        let clip = scroll.contentView
        let savedOrigin = clip.bounds.origin

        rows = newRows
        table.reloadData()

        if let pid = keepPID, let i = rows.firstIndex(where: { $0.pid == pid }) {
            table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        }
        // reloadData can reset the clip origin; restore it, clamped to the new
        // content height so a shrinking table doesn't leave a blank viewport.
        table.layoutSubtreeIfNeeded()
        let maxY = max(0, table.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: savedOrigin.x, y: min(savedOrigin.y, maxY)))
        scroll.reflectScrolledClipView(clip)

        emptyLabel.stringValue =
            "No processes drew measurable energy this interval.\nIdle helpers and processes that exited between sweeps do not appear."
        emptyLabel.isHidden = !rows.isEmpty

        // Shares: clamp defensively — a race between numerator and denominator
        // snapshots can push a ratio just past 1, and >100% would be nonsense.
        let att = min(1, max(0, m.shareOfAttributed))
        attributedBar.fraction = att
        attributedValue.stringValue = String(format: "%.1f%%", att * 100)
        if let raw = m.shareOfMeasured {
            let meas = min(1, max(0, raw))
            measuredBar.fraction = meas
            measuredValue.stringValue = String(format: "%.1f%%", meas * 100)
        } else {
            measuredBar.fraction = nil
            measuredValue.stringValue = "awaiting measurement"
        }

        refreshQuitAffordances()
    }

    private static func pctHrText(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        return v > 0 && v < 0.01 ? "<0.01" : String(format: "%.2f", v)
    }

    // MARK: - Quit intent (never executed here)

    private func refreshQuitAffordances() {
        quitButton.isHidden = onQuitRequested == nil
        quitButton.isEnabled = onQuitRequested != nil && selectedPID != nil
    }

    @objc private func quitClicked() {
        guard let pid = selectedPID else { return }
        onQuitRequested?(pid)
    }

    @objc private func quitFromMenu(_ sender: NSMenuItem) {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        onQuitRequested?(rows[row].pid)
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        let row = table.clickedRow
        let valid = onQuitRequested != nil && row >= 0 && row < rows.count
        menu.items.first?.isEnabled = valid
        menu.items.first?.title = valid ? "Quit “\(rows[row].name)”…" : "Quit Process…"
    }

    // MARK: - NSTableViewDataSource / Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count, let id = col?.identifier else { return nil }
        let r = rows[row]

        let cell: NSTextField
        if let reused = tv.makeView(withIdentifier: id, owner: self) as? NSTextField {
            cell = reused
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = id
            cell.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            cell.lineBreakMode = .byTruncatingTail
        }

        switch id.rawValue {
        case "proc":
            cell.stringValue = r.name
            cell.alignment = .left
            cell.textColor = .labelColor
        case "pid":
            cell.stringValue = "\(r.pid)"
            cell.alignment = .right
            cell.textColor = .secondaryLabelColor
        case "pctHr":
            cell.stringValue = Self.pctHrText(r.percentPerHour)
            cell.alignment = .right
            cell.textColor = .labelColor
        default: // joules
            cell.stringValue = String(format: "%.2f", r.joules)
            cell.alignment = .right
            cell.textColor = .labelColor
        }
        // The executable path answers "which helper is this, exactly" — too long
        // for a column, so it rides on every cell as a tooltip.
        cell.toolTip = r.path.isEmpty ? nil : r.path
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        refreshQuitAffordances()
    }
}

/// Minimal horizontal fraction bar. draw(_:) with semantic colours so it re-resolves
/// per effectiveAppearance — no layer colour caching to go stale on theme flips.
private final class ShareBar: NSView {
    /// nil = no measurement yet: draw only the track, never a fake zero-length fill.
    var fraction: Double? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        guard r.width > 0, r.height > 0 else { return }
        let radius = r.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()

        guard let f = fraction, f.isFinite, f > 0 else { return }
        let w = max(r.height, r.width * CGFloat(min(1, f)))
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: r.height),
                     xRadius: radius, yRadius: radius).fill()
    }
}

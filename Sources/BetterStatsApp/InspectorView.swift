import AppKit
import PowerKit

/// Drill-down for one selected app: which of its processes are actually burning the
/// energy the summary row attributes to it.
///
/// Replaces the earlier detail pane, which predated the design system and — more
/// importantly — had no way to close it. A pane you can open but not dismiss is a
/// trap, so the close control is part of the view rather than something the host is
/// expected to remember to provide.
///
/// The app rollup is right for the summary table (fifteen `Code Helper` rows tell you
/// nothing), but it destroys the information a power user needs: a pinned renderer
/// and a leaking extension host look identical at the app level.
final class InspectorView: NSView {

    struct Row {
        let name: String
        let pid: pid_t
        let value: String
        let path: String
    }

    struct Model {
        let appName: String
        let bundlePath: String?
        let subtitle: String
        /// Share of the ATTRIBUTED total and, separately, of the MEASURED total.
        /// These differ a lot — attributed is often under 15% of measured — and
        /// conflating them is exactly the dishonesty this project exists to avoid.
        let shareOfAttributed: Double
        let shareOfMeasured: Double?
        let rows: [Row]
    }

    var model: Model? { didSet { rebuild() } }
    var onClose: (() -> Void)?
    /// Selected process, if any. Details and the quit controls act on this one.
    private var selectedPID: pid_t?
    private let detailsBox = NSStackView()
    private let quitButton = NSButton()
    private let forceButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let shares = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let list = NSStackView()
    private let scroll = NSScrollView()

    /// NSClipView is NOT flipped, so a top-anchored document view lays out from the
    /// bottom up — the process list was rendering at the bottom of the pane with a
    /// large empty gap above it.
    private final class FlippedClipView: NSClipView {
        override var isFlipped: Bool { true }
    }
    private var buttonRow: NSStackView!

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Palette.surface.setFill()
        dirtyRect.fill()
        Palette.line.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        needsDisplay = true
        restyle()
        rebuild()
    }

    private func build() {
        icon.imageScaling = .scaleProportionallyUpOrDown

        title.font = Palette.Font.sans(13, .semibold)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = Palette.Font.mono(10)
        subtitle.lineBreakMode = .byTruncatingMiddle
        shares.font = Palette.Font.mono(10)
        shares.maximumNumberOfLines = 2

        // Plain-styled so it reads as a dismiss affordance rather than a push button,
        // and it takes Escape as well as a click — a pane with only one way out is
        // the thing being fixed here.
        closeButton.image = NSImage(systemSymbolName: "xmark",
                                    accessibilityDescription: "Close inspector")
        closeButton.isBordered = false
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.toolTip = "Close (Esc)"

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 3
        list.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)

        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView = FlippedClipView()
        scroll.documentView = list
        // A stack view used as a documentView has no width of its own, so without
        // this it lays out at zero width and every row is invisible — the pane looked
        // empty even though the rows were there.
        list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        detailsBox.orientation = .vertical
        detailsBox.alignment = .leading
        detailsBox.spacing = 3
        detailsBox.isHidden = true

        for b in [quitButton, forceButton] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.target = self
            b.isHidden = true
        }
        quitButton.title = "Quit"
        quitButton.action = #selector(quitSelected)
        forceButton.title = "Force Quit"
        forceButton.action = #selector(forceQuitSelected)

        statusLabel.font = Palette.Font.sans(10)
        statusLabel.textColor = Palette.dim
        statusLabel.maximumNumberOfLines = 2

        let buttons = NSStackView(views: [quitButton, forceButton, statusLabel])
        buttons.orientation = .horizontal
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false
        self.buttonRow = buttons

        for v in [icon, title, subtitle, shares, closeButton, scroll,
                  detailsBox, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            title.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 14),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),

            shares.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            shares.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            shares.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 10),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: shares.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: detailsBox.topAnchor, constant: -10),

            detailsBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            detailsBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            detailsBox.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),

            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        restyle()
    }

    private func restyle() {
        title.textColor = Palette.text
        subtitle.textColor = Palette.faint
        shares.textColor = Palette.dim
        closeButton.contentTintColor = Palette.dim
    }

    @objc private func close() { onClose?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }
    override var acceptsFirstResponder: Bool { true }

    private func rebuild() {
        guard let m = model else { return }

        title.stringValue = m.appName
        subtitle.stringValue = m.bundlePath.map { ($0 as NSString).lastPathComponent } ?? m.subtitle
        icon.image = m.bundlePath.map { NSWorkspace.shared.icon(forFile: $0) }

        // Both shares, never one. "18% of apps" and "2% of the machine" are both true
        // and mean very different things; showing only the first implies apps are
        // the whole story, which is the Activity Monitor error.
        var text = String(format: "%.0f%% of attributed", m.shareOfAttributed * 100)
        if let sm = m.shareOfMeasured {
            text += String(format: "   ·   %.1f%% of measured total", sm * 100)
        }
        shares.stringValue = text

        list.arrangedSubviews.forEach {
            list.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        if m.rows.isEmpty {
            let empty = NSTextField(labelWithString: "No measurable activity this interval")
            empty.font = Palette.Font.sans(11)
            empty.textColor = Palette.faint
            list.addArrangedSubview(empty)
            return
        }
        for r in m.rows {
            let row = makeRow(r)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
        }
        // Keep the selection across the two-second refresh if that process is still
        // alive; drop it silently if it exited.
        if let pid = selectedPID, !m.rows.contains(where: { $0.pid == pid }) {
            selectedPID = nil
        }
        // Default to the busiest process. The pane exists to answer "what inside this
        // app is doing the work", and requiring a second click before showing any
        // detail — or any Quit button — hides the feature entirely.
        if selectedPID == nil, let first = m.rows.first {
            selectedPID = first.pid
            for case let row as ProcessRowView in list.arrangedSubviews
            where row.pid == first.pid { row.isSelected = true }
        }
        showDetails()
    }

    // ── Process details and quitting ────────────────────────────────────────

    private func showDetails() {
        detailsBox.arrangedSubviews.forEach {
            detailsBox.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        guard let pid = selectedPID, let d = ProcessInspector.details(for: pid) else {
            detailsBox.isHidden = true
            quitButton.isHidden = true
            forceButton.isHidden = true
            statusLabel.stringValue = ""
            return
        }
        detailsBox.isHidden = false

        func line(_ label: String, _ value: String) {
            let l = NSTextField(labelWithString: label)
            l.font = Palette.Font.sans(10)
            l.textColor = Palette.faint
            let v = NSTextField(labelWithString: value)
            v.font = Palette.Font.mono(10)
            v.textColor = Palette.dim
            v.lineBreakMode = .byTruncatingMiddle
            let row = NSStackView(views: [l, v])
            row.orientation = .horizontal
            row.distribution = .fill
            l.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            detailsBox.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: detailsBox.widthAnchor).isActive = true
        }

        line("PID", "\(d.pid)")
        if let parent = d.parentName { line("Parent", "\(parent) (\(d.parentPID))") }
        line("User", d.userName ?? "uid \(d.uid)")
        line("Threads", "\(d.threadCount) (\(d.runningThreads) running)")
        line("Memory", MetricUnit.bytes.format(Double(d.residentSize)))
        line("Open files", "\(d.openFiles)")
        line("Ctx switches", "\(d.contextSwitches)")

        // Quitting is only offered where it can actually work. A button that is
        // guaranteed to fail with EPERM is worse than no button — it implies the
        // app could do it and chose not to.
        let canSignal = d.isOwnedByCurrentUser && !ProcessControl.isSelf(pid)
        quitButton.isHidden = false
        forceButton.isHidden = false
        quitButton.isEnabled = canSignal
        forceButton.isEnabled = canSignal
        if ProcessControl.isSelf(pid) {
            statusLabel.stringValue = "This is BetterStats"
        } else if !d.isOwnedByCurrentUser {
            statusLabel.stringValue = "Owned by \(d.userName ?? "another user")"
        } else {
            statusLabel.stringValue = ""
        }
    }

    @objc private func quitSelected() {
        guard let pid = selectedPID else { return }
        report(ProcessControl.quit(pid: pid))
    }

    @objc private func forceQuitSelected() {
        guard let pid = selectedPID,
              let d = ProcessInspector.details(for: pid) else { return }

        // Force quit is SIGKILL: uncatchable, so unsaved work is simply gone. That
        // warrants a confirmation in a way an ordinary quit does not.
        let alert = NSAlert()
        alert.messageText = "Force quit \(d.name)?"
        alert.informativeText = "Force quitting sends SIGKILL, which the process "
            + "cannot catch. Any unsaved work will be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        report(ProcessControl.forceQuit(pid: pid))
    }

    private func report(_ result: ProcessControl.Result) {
        statusLabel.stringValue = result.message
        statusLabel.textColor = result == .requested || result == .killed
            ? Palette.dim : Palette.warn
    }

    private func makeRow(_ r: Row) -> NSView {
        let name = NSTextField(labelWithString: r.name)
        name.font = Palette.Font.sans(11)
        name.textColor = Palette.text
        name.lineBreakMode = .byTruncatingTail
        name.toolTip = r.path.isEmpty ? nil : r.path

        let pid = NSTextField(labelWithString: "\(r.pid)")
        pid.font = Palette.Font.mono(9.5)
        pid.textColor = Palette.faint

        let value = NSTextField(labelWithString: r.value)
        value.font = Palette.Font.mono(11, .medium)
        value.textColor = Palette.text
        value.alignment = .right

        let left = NSStackView(views: [name, pid])
        left.orientation = .horizontal
        left.spacing = 6

        let row = ProcessRowView(pid: r.pid) { [weak self] pid in
            self?.selectedPID = (self?.selectedPID == pid) ? nil : pid
            self?.rebuild()
        }
        row.isSelected = (r.pid == selectedPID)
        let stack = NSStackView(views: [left, value])
        stack.orientation = .horizontal
        stack.distribution = .fill
        left.setContentHuggingPriority(.defaultLow, for: .horizontal)
        value.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 5),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -5),
            stack.topAnchor.constraint(equalTo: row.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -2),
        ])
        return row
    }

    /// A selectable process row. Same rounded-pill treatment as the main table so
    /// selection reads consistently across the app.
    private final class ProcessRowView: NSView {
        let pid: pid_t
        private let onClick: (pid_t) -> Void
        var isSelected = false { didSet { needsDisplay = true } }

        init(pid: pid_t, onClick: @escaping (pid_t) -> Void) {
            self.pid = pid
            self.onClick = onClick
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            setAccessibilityRole(.button)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            guard isSelected else { return }
            Palette.selection.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Palette.Radius.chip,
                         yRadius: Palette.Radius.chip).fill()
        }
        override func mouseDown(with event: NSEvent) { onClick(pid) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    }

    // ── Model construction ──────────────────────────────────────────────────

    static func model(app: AppDrain, snapshot s: PowerMonitor.Snapshot,
                      lens: SidebarView.Lens) -> Model {
        let pids = Set(app.pids)
        let procs = s.drains.filter { pids.contains($0.pid) }
            .sorted { $0.percentPerHour > $1.percentPerHour }

        return Model(
            appName: app.name,
            bundlePath: app.identity.bundlePath,
            subtitle: app.identity.bundleID ?? "\(app.processCount) process\(app.processCount == 1 ? "" : "es")",
            shareOfAttributed: s.attributed_W > 0 ? app.watts / s.attributed_W : 0,
            shareOfMeasured: s.smoothed_W > 0 ? app.watts / s.smoothed_W : nil,
            rows: procs.map {
                Row(name: $0.name, pid: $0.pid,
                    value: $0.percentPerHour < 0.01
                        ? "<0.01 %/hr" : String(format: "%.2f %%/hr", $0.percentPerHour),
                    path: $0.path)
            })
    }
}

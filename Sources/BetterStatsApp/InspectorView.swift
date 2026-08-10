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

    var model: Model? {
        didSet {
            // A different app is a different subject: a pid selected inside the old
            // one means nothing here, and a status line reporting what was just done
            // to it would be reporting it against the wrong name.
            if model?.appName != oldValue?.appName {
                selectedPID = nil
                isShowingResult = false
            }
            rebuild()
        }
    }
    var onClose: (() -> Void)?
    /// Selected process, if any. The details box and the per-process kill act on
    /// this one; the two app-level buttons act on every pid in the model.
    private var selectedPID: pid_t?
    private let detailsBox = NSStackView()
    /// App-wide: ask politely, and the uncatchable version.
    private let quitAppButton = NSButton()
    private let forceQuitAppButton = NSButton()
    /// Just the selected sub-process, leaving the rest of the app running.
    private let killProcessButton = NSButton()
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
        // Rows are reused between ticks and keep the ink they were built with, so a
        // theme flip has to discard them rather than let rebuild() re-text them.
        emptyList()
        emptyDetails()
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

        for b in [quitAppButton, forceQuitAppButton, killProcessButton] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.target = self
            b.isHidden = true
        }
        quitAppButton.title = "Quit App"
        quitAppButton.action = #selector(quitApp)
        quitAppButton.toolTip = "Ask every process of this app to quit. A GUI app can "
                              + "still prompt about unsaved work."
        forceQuitAppButton.title = "Force Quit App"
        forceQuitAppButton.action = #selector(forceQuitApp)
        forceQuitAppButton.toolTip = "SIGKILL every process of this app. Uncatchable — "
                                   + "unsaved work is lost."
        killProcessButton.title = "Force Quit Process"
        killProcessButton.action = #selector(forceQuitProcess)
        killProcessButton.toolTip = "SIGKILL only the selected sub-process, leaving the "
                                  + "rest of the app running."

        statusLabel.font = Palette.Font.sans(10)
        statusLabel.textColor = Palette.dim
        statusLabel.maximumNumberOfLines = 3

        // Two rows, not one: three buttons and a status line do not fit across a
        // 380 pt inspector, and wrapping them into an unreadable strip is how the
        // destructive one ends up under the pointer by accident.
        let appButtons = NSStackView(views: [quitAppButton, forceQuitAppButton])
        appButtons.orientation = .horizontal
        appButtons.spacing = 6
        let processButtons = NSStackView(views: [killProcessButton])
        processButtons.orientation = .horizontal
        processButtons.spacing = 6

        let buttons = NSStackView(views: [appButtons, processButtons, statusLabel])
        buttons.orientation = .vertical
        buttons.alignment = .leading
        buttons.spacing = 5
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
        } else {
            // Say why the second figure is missing rather than dropping it. A lone
            // "18% of attributed" reads as the whole story, which is the error above.
            text += "   ·   measured total not available yet"
        }
        shares.stringValue = text

        guard !m.rows.isEmpty else {
            emptyList()
            // Still here, because this branch returns: with no rows there are no
            // pids, so the quit controls have nothing to act on and must go away
            // rather than keep the previous app's plan.
            updateActionButtons()
            let empty = NSTextField(labelWithString: "No measurable activity this interval")
            empty.font = Palette.Font.sans(11)
            empty.textColor = Palette.faint
            list.addArrangedSubview(empty)
            return
        }

        // Keep the selection across the two-second refresh if that process is still
        // alive; drop it silently if it exited.
        if let pid = selectedPID, !m.rows.contains(where: { $0.pid == pid }) {
            selectedPID = nil
        }
        // Default to the busiest process. The pane exists to answer "what inside this
        // app is doing the work", and requiring a second click before showing any
        // detail — or any Quit button — hides the feature entirely.
        if selectedPID == nil, let first = m.rows.first { selectedPID = first.pid }

        // Re-text the rows already on screen rather than replacing them. MEASURED
        // on this machine: rebuilding a 15-process app is 11.8 ms of CPU per tick
        // and a 40-process one 34 ms — about 0.75 ms per row of view allocation and
        // Auto Layout — and the inspector re-renders every 2 s for as long as an app
        // is selected. Reused: 0.7 ms. The rows reorder as draws change, so a reused
        // view is not the same process it was last tick; everything it shows comes
        // from `apply`.
        let reusable = list.arrangedSubviews.count == m.rows.count
            && list.arrangedSubviews.allSatisfy { $0 is ProcessRowView }
        if !reusable {
            emptyList()
            for _ in m.rows {
                let row = ProcessRowView { [weak self] pid in
                    self?.selectedPID = (self?.selectedPID == pid) ? nil : pid
                    self?.isShowingResult = false   // a new subject, not the last result
                    self?.rebuild()
                }
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
                row.heightAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
            }
        }
        for (view, r) in zip(list.arrangedSubviews, m.rows) {
            (view as? ProcessRowView)?.apply(r, selected: r.pid == selectedPID)
        }
        showDetails()
    }

    private func emptyList() {
        list.arrangedSubviews.forEach {
            list.removeArrangedSubview($0); $0.removeFromSuperview()
        }
    }

    private func emptyDetails() {
        detailsBox.arrangedSubviews.forEach {
            detailsBox.removeArrangedSubview($0); $0.removeFromSuperview()
        }
    }

    // ── Process details and quitting ────────────────────────────────────────

    private func showDetails() {
        updateActionButtons()
        guard let pid = selectedPID, let d = ProcessInspector.details(for: pid) else {
            emptyDetails()
            detailsBox.isHidden = true
            return
        }
        detailsBox.isHidden = false

        var lines: [(String, String)] = [("PID", "\(d.pid)")]
        if let parent = d.parentName { lines.append(("Parent", "\(parent) (\(d.parentPID))")) }
        lines.append(("User", d.userName ?? "uid \(d.uid)"))
        lines.append(("Threads", "\(d.threadCount) (\(d.runningThreads) running)"))
        lines.append(("Memory", MetricUnit.bytes.format(Double(d.residentSize))))
        lines.append(("Open files", "\(d.openFiles)"))
        lines.append(("Ctx switches", "\(d.contextSwitches)"))

        // Same reuse as the process list: seven two-label rows rebuilt every 2 s is
        // 2.5 ms of CPU a tick for text that mostly does not move.
        if detailsBox.arrangedSubviews.count != lines.count
            || !detailsBox.arrangedSubviews.allSatisfy({ $0 is DetailLine }) {
            emptyDetails()
            for _ in lines {
                let row = DetailLine()
                detailsBox.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: detailsBox.widthAnchor).isActive = true
            }
        }
        for (view, line) in zip(detailsBox.arrangedSubviews, lines) {
            (view as? DetailLine)?.apply(label: line.0, value: line.1)
        }

    }

    /// Decide what the three buttons can do, before the user can click one.
    ///
    /// Quitting is only OFFERED where it can actually work. A button guaranteed to
    /// fail with EPERM is worse than no button — it implies the app could do it and
    /// chose not to — so a root-owned process disables the control and the status
    /// line says who owns it instead of waiting for the click to fail.
    private func updateActionButtons() {
        guard let m = model, !m.rows.isEmpty else {
            for b in [quitAppButton, forceQuitAppButton, killProcessButton] { b.isHidden = true }
            statusLabel.stringValue = ""
            return
        }
        let appPlan = ProcessActions.plan(for: ProcessActions.candidates(pids: m.rows.map(\.pid)))
        quitAppButton.isHidden = false
        forceQuitAppButton.isHidden = false
        quitAppButton.isEnabled = appPlan.canAct
        forceQuitAppButton.isEnabled = appPlan.canAct

        let processPlan = selectedPID.map {
            ProcessActions.plan(for: ProcessActions.candidates(pids: [$0]))
        }
        // Only worth offering when there is more than one process — with one, it is
        // the same button as Force Quit App wearing a different name.
        killProcessButton.isHidden = m.rows.count < 2 || processPlan == nil
        killProcessButton.isEnabled = processPlan?.canAct ?? false
        // The pid rides in the tooltip rather than in the title: the title is
        // re-read on every two-second refresh, and assigning a new one each time
        // re-solves the whole button row for a string that says the same thing.
        killProcessButton.toolTip = selectedPID.map {
            "SIGKILL pid \($0) only, leaving the rest of the app running."
        }

        // Never overwrite the outcome of a click the user just made. `report` sets
        // this and clears the flag on the next selection change.
        guard !isShowingResult else { return }
        statusLabel.stringValue = appPlan.explanation
        statusLabel.textColor = Palette.dim
    }

    /// Set while the status line is showing what a button just did, so the next
    /// two-second refresh does not wipe it before it has been read.
    private var isShowingResult = false

    @objc private func quitApp() {
        guard let m = model else { return }
        let plan = ProcessActions.plan(for: ProcessActions.candidates(pids: m.rows.map(\.pid)))
        report(ProcessActions.perform(plan, force: false), ok: plan.canAct)
    }

    @objc private func forceQuitApp() {
        guard let m = model else { return }
        let plan = ProcessActions.plan(for: ProcessActions.candidates(pids: m.rows.map(\.pid)))
        guard plan.canAct,
              ProcessActions.confirmForceQuit(subject: m.appName,
                                              processCount: plan.signalable.count) else { return }
        report(ProcessActions.perform(plan, force: true), ok: true)
    }

    @objc private func forceQuitProcess() {
        guard let pid = selectedPID, let d = ProcessInspector.details(for: pid) else { return }
        let plan = ProcessActions.plan(for: ProcessActions.candidates(pids: [pid]))
        guard plan.canAct,
              ProcessActions.confirmForceQuit(subject: "\(d.name) (\(pid))",
                                              processCount: 1) else { return }
        report(ProcessActions.perform(plan, force: true), ok: true)
    }

    private func report(_ message: String, ok: Bool) {
        isShowingResult = true
        statusLabel.stringValue = message
        statusLabel.textColor = ok ? Palette.dim : Palette.warn
    }

    /// A selectable process row. Same rounded-pill treatment as the main table so
    /// selection reads consistently across the app.
    ///
    /// The row owns its labels so `apply` can re-text it in place; it used to be
    /// built from scratch on every tick, and at 15 processes that was the single
    /// largest cost of having the inspector open.
    private final class ProcessRowView: NSView {
        private(set) var pid: pid_t = 0
        private let onClick: (pid_t) -> Void
        private let name = NSTextField(labelWithString: "")
        private let pidLabel = NSTextField(labelWithString: "")
        private let value = NSTextField(labelWithString: "")
        var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }

        init(onClick: @escaping (pid_t) -> Void) {
            self.onClick = onClick
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            setAccessibilityRole(.button)

            name.font = Palette.Font.sans(11)
            name.textColor = Palette.text
            name.lineBreakMode = .byTruncatingTail

            pidLabel.font = Palette.Font.mono(9.5)
            pidLabel.textColor = Palette.faint

            value.font = Palette.Font.mono(11, .medium)
            value.textColor = Palette.text
            value.alignment = .right

            let left = NSStackView(views: [name, pidLabel])
            left.orientation = .horizontal
            left.spacing = 6

            let stack = NSStackView(views: [left, value])
            stack.orientation = .horizontal
            stack.distribution = .fill
            left.setContentHuggingPriority(.defaultLow, for: .horizontal)
            value.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            ])
        }
        required init?(coder: NSCoder) { fatalError() }

        /// Assigning `stringValue` invalidates an NSTextField's intrinsic size and
        /// re-solves the enclosing stacks, so only the fields that actually moved
        /// are written.
        func apply(_ r: Row, selected: Bool) {
            pid = r.pid
            if name.stringValue != r.name { name.stringValue = r.name }
            let pidText = "\(r.pid)"
            if pidLabel.stringValue != pidText { pidLabel.stringValue = pidText }
            if value.stringValue != r.value { value.stringValue = r.value }
            let tip = r.path.isEmpty ? nil : r.path
            if name.toolTip != tip { name.toolTip = tip }
            isSelected = selected
        }

        override func draw(_ dirtyRect: NSRect) {
            guard isSelected else { return }
            Palette.selection.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Palette.Radius.chip,
                         yRadius: Palette.Radius.chip).fill()
        }
        override func mouseDown(with event: NSEvent) { onClick(pid) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    }

    /// One `label   value` line of the process details box.
    private final class DetailLine: NSStackView {
        private let label = NSTextField(labelWithString: "")
        private let value = NSTextField(labelWithString: "")

        init() {
            super.init(frame: .zero)
            orientation = .horizontal
            distribution = .fill
            label.font = Palette.Font.sans(10)
            label.textColor = Palette.faint
            value.font = Palette.Font.mono(10)
            value.textColor = Palette.dim
            value.lineBreakMode = .byTruncatingMiddle
            label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addArrangedSubview(label)
            addArrangedSubview(value)
        }
        required init?(coder: NSCoder) { fatalError() }

        func apply(label l: String, value v: String) {
            if label.stringValue != l { label.stringValue = l }
            if value.stringValue != v { value.stringValue = v }
        }
    }

    // ── Model construction ──────────────────────────────────────────────────

    static func model(app: AppDrain, snapshot s: PowerMonitor.Snapshot) -> Model {
        let pids = Set(app.pids)
        let procs = s.drains.filter { pids.contains($0.pid) }
            .sorted { $0.percentPerHour > $1.percentPerHour }

        // Clamped: numerator and denominator are sampled from the same snapshot but
        // are computed by different paths, and a race between them can put the ratio
        // fractionally over 1. "104% of attributed" is not a finding, it is a rounding
        // artefact printed as one.
        let attributedShare = s.attributed_W > 0
            ? min(1, max(0, app.watts / s.attributed_W))
            : 0

        // MEASURED has to mean measured: the battery gas gauge once a 60 s batch has
        // published, else gain-corrected SMC PSTR. Never `smoothed_W` — that is the
        // scaled, smoothed display ESTIMATE, and dividing by it under a label that
        // says "of measured total" launders a model into a measurement. Nil when
        // neither has landed yet, because "we have not measured the machine yet" is
        // a different claim from any number we could print.
        let measuredTotal_W = s.measured_W ?? s.smcTotal_W
        let measuredShare = measuredTotal_W.flatMap { total -> Double? in
            total > 0 ? min(1, max(0, app.watts / total)) : nil
        }

        return Model(
            appName: app.name,
            bundlePath: app.identity.bundlePath,
            subtitle: app.identity.bundleID ?? "\(app.processCount) process\(app.processCount == 1 ? "" : "es")",
            shareOfAttributed: attributedShare,
            shareOfMeasured: measuredShare,
            rows: procs.map {
                Row(name: $0.name, pid: $0.pid,
                    value: $0.percentPerHour < 0.01
                        ? "<0.01 %/hr" : String(format: "%.2f %%/hr", $0.percentPerHour),
                    path: $0.path)
            })
    }
}

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

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let shares = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let list = NSStackView()
    private let scroll = NSScrollView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
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
        scroll.documentView = list

        for v in [icon, title, subtitle, shares, closeButton, scroll] as [NSView] {
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
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
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
        }
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

        let row = NSStackView(views: [left, value])
        row.orientation = .horizontal
        row.distribution = .fill
        left.setContentHuggingPriority(.defaultLow, for: .horizontal)
        value.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
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

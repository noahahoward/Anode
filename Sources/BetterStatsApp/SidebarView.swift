import AppKit
import PowerKit

/// Category rail.
///
/// Two kinds of destination, and the grouping says which is which:
///
///   PER PROCESS   — lenses. The same table stays; columns and sort change to that
///                   resource. Battery, CPU, Memory, Disk and GPU all come from the
///                   single `proc_pid_rusage` call already made once per process per
///                   sweep, so four of them cost no extra sampling at all.
///   WHOLE MACHINE — their own panes. There is no unprivileged per-process network
///                   attribution on macOS, and a fan does not belong to a process.
///                   Pretending otherwise would be the same dishonesty as
///                   normalising a ledger to 100%.
///
/// Live values sit in the rail itself so a glance answers most questions without
/// switching at all.
final class SidebarView: NSView {

    enum Lens: String, CaseIterable {
        case battery, cpu, memory, disk, gpu, network, sensors, fans

        var title: String {
            switch self {
            case .battery: return "Battery"
            case .cpu:     return "CPU"
            case .memory:  return "Memory"
            case .disk:    return "Disk"
            case .gpu:     return "GPU"
            case .network: return "Network"
            case .sensors: return "Sensors"
            case .fans:    return "Fans"
            }
        }

        /// True when this re-columns the process table rather than replacing it.
        var isPerProcess: Bool {
            switch self {
            case .battery, .cpu, .memory, .disk, .gpu: return true
            case .network, .sensors, .fans: return false
            }
        }

        /// The metric whose current value is shown beside the label.
        var metric: MetricID? {
            switch self {
            case .battery: return .batteryDrain
            case .cpu:     return .cpuUsage
            case .memory:  return .memoryUsage
            case .gpu:     return .gpuUsage
            case .network: return .networkThroughput
            case .sensors: return .cpuTemperature
            case .fans:    return .fanSpeed
            case .disk:    return .diskActivity
            }
        }

        /// What the number beside the label actually means, for rows where that is
        /// not obvious from the unit.
        ///
        /// Disk is the row that needs it. It sits between CPU and GPU, both of
        /// which show a utilisation, and it deliberately does not — there is no
        /// honest disk utilisation to show on this hardware (see `DiskActivity`),
        /// so the row says bytes per second and this says why.
        var valueTooltip: String? {
            switch self {
            case .disk:
                return """
                       Read/write throughput, whole machine.

                       Not a utilisation: the only read/write timer macOS exposes \
                       adds up requests that overlap in the queue, so on this SSD \
                       it reaches 1394% under load and cannot be a percentage.
                       """
            default:
                return nil
            }
        }
    }

    var onSelect: ((Lens) -> Void)?
    private(set) var selected: Lens = .battery

    private let stack = NSStackView()
    private var rows: [Lens: RowView] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); build() }

    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Palette.sidebar.setFill()
        dirtyRect.fill()
        Palette.line.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }
    override func viewDidChangeEffectiveAppearance() { redraw() }

    /// Force the rail and every row to repaint.
    func redraw() {
        needsDisplay = true
        rows.values.forEach { $0.needsDisplay = true }
    }

    private func build() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        // The system titlebar owns the space above, so no clearance is needed here.
        // (This was 46 to dodge the traffic lights under fullSizeContentView, which
        // the window no longer uses — leaving it made the rail start half an inch
        // lower than the table header beside it.)
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 8, bottom: 12, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            stack.topAnchor.constraint(equalTo: topAnchor),
        ])

        stack.addArrangedSubview(header("Per process"))
        for l in Lens.allCases where l.isPerProcess { add(l) }
        stack.addArrangedSubview(header("Whole machine"))
        for l in Lens.allCases where !l.isPerProcess { add(l) }

        rows[selected]?.isSelected = true
    }

    private func header(_ text: String) -> NSView {
        let l = NSTextField(labelWithString: text.uppercased())
        l.font = Palette.Font.mono(9, .medium)
        l.textColor = Palette.faint
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        l.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            l.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            l.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -5),
            l.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor),
        ])
        return box
    }

    private func add(_ lens: Lens) {
        let row = RowView(lens: lens) { [weak self] l in self?.select(l) }
        rows[lens] = row
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
    }

    func select(_ lens: Lens) {
        guard lens != selected else { return }
        rows[selected]?.isSelected = false
        selected = lens
        rows[lens]?.isSelected = true
        onSelect?(lens)
    }

    /// Refresh the live value beside each label from the registry.
    func refreshValues() {
        for (lens, row) in rows {
            guard let id = lens.metric else { row.value = nil; continue }
            row.value = MetricRegistry.shared.value(for: id)?.text
        }
    }

    // ── Row ─────────────────────────────────────────────────────────────────

    private final class RowView: NSView {
        private let lens: Lens
        private let onClick: (Lens) -> Void
        private let title = NSTextField(labelWithString: "")
        private let valueLabel = NSTextField(labelWithString: "")

        var isSelected = false { didSet { restyle(); needsDisplay = true } }
        var value: String? {
            didSet {
                valueLabel.stringValue = value ?? ""
                restyle()
            }
        }

        init(lens: Lens, onClick: @escaping (Lens) -> Void) {
            self.lens = lens
            self.onClick = onClick
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false

            title.stringValue = lens.title
            title.font = Palette.Font.sans(12.5)
            valueLabel.font = Palette.Font.mono(10.5)
            valueLabel.alignment = .right

            let stack = NSStackView(views: [title, valueLabel])
            stack.orientation = .horizontal
            stack.distribution = .fill
            title.setContentHuggingPriority(.defaultLow, for: .horizontal)
            valueLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            ])
            // Without this the rail is invisible to VoiceOver and to any automation:
            // a plain NSView with a mouseDown override is a button to a sighted user
            // and nothing at all to anyone else.
            setAccessibilityRole(.button)
            setAccessibilityLabel(lens.title)
            setAccessibilityElement(true)
            // A unit that differs from the rows above and below it has to explain
            // itself somewhere the user can actually reach.
            toolTip = lens.valueTooltip

            restyle()
        }
        required init?(coder: NSCoder) { fatalError() }

        override func accessibilityPerformPress() -> Bool {
            onClick(lens)
            return true
        }

        private func restyle() {
            title.textColor = isSelected ? Palette.text : Palette.dim
            title.font = Palette.Font.sans(12.5, isSelected ? .semibold : .regular)
            valueLabel.textColor = isSelected ? Palette.accent : Palette.faint
        }

        override func draw(_ dirtyRect: NSRect) {
            guard isSelected else { return }
            Palette.selection.setFill()
            NSBezierPath(roundedRect: bounds,
                         xRadius: Palette.Radius.chip,
                         yRadius: Palette.Radius.chip).fill()
        }

        override func mouseDown(with event: NSEvent) { onClick(lens) }
        override func viewDidChangeEffectiveAppearance() { restyle(); needsDisplay = true }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}

import AppKit
import PowerKit

/// The small window shown in place of the main one while an automatic update
/// runs.
///
/// It is what stands in for the Terminal window the Update button opens: the
/// app is about to quit and be replaced, and this is the thing on screen that
/// says so. It has no close button while the update is running, because
/// closing it would not stop anything — and gains one, with the log, if the
/// update fails.
final class UpdatePanelController: NSWindowController, NSWindowDelegate {

    /// Called once, when a failed update is dismissed by button or close box.
    var onDismiss: (() -> Void)?

    private let heading = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let buttons = NSStackView()
    private let target: String
    private var logURL: URL?
    private var dismissed = false

    /// `build` is the number About will show afterwards, when it is known.
    init(build: Int?) {
        target = build.map { "build \($0)" } ?? "the latest build"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 110),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Anode"
        window.isReleasedWhenClosed = false
        window.level = .floating
        super.init(window: window)
        window.delegate = self

        heading.stringValue = "Updating Anode…"
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 3
        detail.preferredMaxLayoutWidth = 300

        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let log = NSButton(title: "Show Log", target: self, action: #selector(showLog))
        let open = NSButton(title: "Open Anode", target: self, action: #selector(dismiss))
        open.keyEquivalent = "\r"
        buttons.setViews([NSView(), log, open], in: .leading)
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.isHidden = true

        let stack = NSStackView(views: [heading, bar, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        buttons.widthAnchor.constraint(equalToConstant: 300).isActive = true
        window.contentView = stack
        update(AutoUpdate.Progress())
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() { window?.bringForward() }

    func update(_ progress: AutoUpdate.Progress) {
        detail.stringValue = "\(progress.stage.label) Anode will reopen on \(target)."
        if let fraction = progress.fraction {
            if bar.isIndeterminate {
                bar.stopAnimation(nil)
                bar.isIndeterminate = false
            }
            bar.doubleValue = fraction
        } else if !bar.isIndeterminate {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
    }

    /// The update stopped. Nothing has been replaced unless the log says so.
    func fail(_ reason: String, log: URL) {
        logURL = log
        heading.stringValue = "Anode could not update itself"
        detail.stringValue = reason
        bar.isHidden = true
        buttons.isHidden = false
        window?.styleMask.insert(.closable)
        window?.layoutIfNeeded()
        show()
    }

    @objc private func showLog() {
        if let logURL { NSWorkspace.shared.open(logURL) }
    }

    @objc private func dismiss() {
        window?.close()
    }

    func windowWillClose(_ note: Notification) {
        guard !dismissed else { return }
        dismissed = true
        onDismiss?()
    }
}

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
    /// What the update is, in the two sentences its author wrote. Hidden when the update has none.
    private let note = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let bar = NSProgressIndicator()
    private let buttons = NSStackView()
    private let target: String
    private var logURL: URL?
    private var dismissed = false

    /// `version` and `build` are what About will show afterwards, when they are known; `note` is the update in two
    /// sentences (`UpdateNote`), shown under the heading so the person waiting reads what is arriving.
    init(build: Int?, version: String? = nil, note text: String? = nil) {
        switch (version, build) {
        case let (v?, b?): target = "version \(v) (build \(b))"
        case let (v?, nil): target = "version \(v)"
        case let (nil, b?): target = "build \(b)"
        default: target = "the latest build"
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 110),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Anode"
        window.isReleasedWhenClosed = false
        window.level = .floating
        super.init(window: window)
        window.delegate = self

        heading.stringValue = version.map { "Updating to Anode \($0)…" } ?? "Updating Anode…"
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        note.stringValue = text ?? ""
        note.isHidden = text == nil
        note.font = .systemFont(ofSize: NSFont.systemFontSize)
        note.textColor = .labelColor
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0
        note.preferredMaxLayoutWidth = 300
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

        stack.setViews([heading, note, bar, detail, buttons], in: .leading)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        buttons.widthAnchor.constraint(equalToConstant: 300).isActive = true
        window.contentView = stack
        update(AutoUpdate.Progress())
        fitToContent()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() { window?.bringForward() }

    /// The window is as tall as what it holds: a note of two sentences takes three or four lines at this width, and a
    /// panel with no note keeps its old small size.
    private func fitToContent() {
        stack.layoutSubtreeIfNeeded()
        window?.setContentSize(NSSize(width: 340, height: ceil(stack.fittingSize.height)))
    }

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
        note.isHidden = true
        buttons.isHidden = false
        window?.styleMask.insert(.closable)
        fitToContent()
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

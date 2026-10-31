import AppKit

// ── The shortcuts window ────────────────────────────────────────────────────
//
// Every command with its shortcut. Click a shortcut, press the combination you want; it is captured by
// the same tap that will act on it (`KeybindCenter.record`), so a combination macOS would normally take
// for itself can be chosen, and the row says when it replaces one of macOS's. A shortcut another of
// Anode's commands had is moved to this one, and the row says which lost it.

/// A button that records a shortcut when clicked.
final class ShortcutRecorderButton: NSButton {
    var onChange: ((Shortcut?) -> Void)?
    private(set) var shortcut: Shortcut?
    private(set) var isRecording = false
    private let center: KeybindCenter

    init(center: KeybindCenter = .shared) {
        self.center = center
        super.init(frame: .zero)
        bezelStyle = .rounded
        controlSize = .small
        target = self
        action = #selector(clicked)
        setContentHuggingPriority(.required, for: .horizontal)
        widthAnchor.constraint(equalToConstant: 118).isActive = true
        show(nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ shortcut: Shortcut?) {
        self.shortcut = shortcut
        isRecording = false
        title = shortcut?.label ?? "—"
    }

    @objc private func clicked() {
        if isRecording { center.cancelRecording(); return }
        isRecording = true
        title = "Type shortcut…"
        center.record { [weak self] result in
            guard let self else { return }
            switch result {
            case .shortcut(let s): self.show(s); self.onChange?(s)
            case .cancelled: self.show(self.shortcut)
            case .needsModifier: self.title = "Hold a modifier…"
            case .unavailable:
                self.show(self.shortcut)
                self.title = "Needs Accessibility"
            }
        }
    }
}

final class ShortcutsWindowController: NSWindowController {

    static let shared = ShortcutsWindowController()

    private let store: ShortcutStore
    private let commands: [ShortcutCommand]
    private var rows: [String: (recorder: ShortcutRecorderButton, note: NSTextField)] = [:]
    private var token: NSObjectProtocol?

    init(store: ShortcutStore = .shared, commands: [ShortcutCommand] = ShortcutCommands.all) {
        self.store = store
        self.commands = commands
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Shortcuts"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        refresh()
        token = NotificationCenter.default.addObserver(forName: ShortcutStore.didChange, object: store, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { if let token { NotificationCenter.default.removeObserver(token) } }

    func show() {
        refresh()
        showWindow(nil)
        window?.bringForward()
    }

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let intro = BetaFeaturesWindowController.wrapping(
            "Click a shortcut and press the keys you want. Yours win over macOS's and other apps': if one "
            + "replaces a macOS shortcut it is said beside it. A shortcut one command already had moves to the new one.",
            color: .secondaryLabelColor)
        stack.addArrangedSubview(intro)

        var section = ""
        for command in commands {
            if command.section != section {
                section = command.section
                let heading = NSTextField(labelWithString: section)
                heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
                stack.setCustomSpacing(14, after: stack.arrangedSubviews.last ?? intro)
                stack.addArrangedSubview(heading)
            }
            let name = NSTextField(labelWithString: command.title)
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let recorder = ShortcutRecorderButton()
            let clear = NSButton(title: "Clear", target: nil, action: nil)
            clear.bezelStyle = .inline
            clear.controlSize = .small
            let reset = NSButton(title: "Reset", target: nil, action: nil)
            reset.bezelStyle = .inline
            reset.controlSize = .small
            let note = NSTextField(labelWithString: "")
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.textColor = .secondaryLabelColor
            let row = NSStackView(views: [name, NSView(), recorder, clear, reset])
            row.spacing = 8
            row.distribution = .fill
            row.setCustomSpacing(8, after: name)
            name.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
            stack.addArrangedSubview(row)
            stack.addArrangedSubview(note)
            stack.setCustomSpacing(0, after: row)
            row.widthAnchor.constraint(equalToConstant: 500).isActive = true

            recorder.onChange = { [weak self] new in self?.assign(new, to: command) }
            let clearHandler = ActionTarget { [weak self] in self?.assign(nil, to: command) }
            let resetHandler = ActionTarget { [weak self] in self?.store.reset(command) }
            clear.target = clearHandler; clear.action = #selector(ActionTarget.fire)
            reset.target = resetHandler; reset.action = #selector(ActionTarget.fire)
            objc_setAssociatedObject(clear, &Self.handlerKey, clearHandler, .OBJC_ASSOCIATION_RETAIN)
            objc_setAssociatedObject(reset, &Self.handlerKey, resetHandler, .OBJC_ASSOCIATION_RETAIN)
            rows[command.id] = (recorder, note)
        }

        let resetAll = NSButton(title: "Reset all to defaults", target: nil, action: nil)
        resetAll.bezelStyle = .rounded
        let resetAllHandler = ActionTarget { [weak self] in self?.store.resetAll() }
        resetAll.target = resetAllHandler; resetAll.action = #selector(ActionTarget.fire)
        objc_setAssociatedObject(resetAll, &Self.handlerKey, resetAllHandler, .OBJC_ASSOCIATION_RETAIN)
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(resetAll)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let document = FlippedView()
        document.addSubview(stack)
        stack.leadingAnchor.constraint(equalTo: document.leadingAnchor).isActive = true
        stack.topAnchor.constraint(equalTo: document.topAnchor).isActive = true
        scroll.documentView = document
        window?.contentView = scroll
        stack.layoutSubtreeIfNeeded()
        let fit = stack.fittingSize
        document.frame = NSRect(origin: .zero, size: fit)
        let limit = (NSScreen.main?.visibleFrame.height ?? 800) - 80
        window?.setContentSize(NSSize(width: max(540, fit.width), height: min(fit.height, limit)))
        window?.center()
    }

    private static var handlerKey = 0

    private func assign(_ new: Shortcut?, to command: ShortcutCommand) {
        let stolen = store.assign(new, to: command, among: commands)
        refresh()
        if let stolen, let note = rows[command.id]?.note {
            note.stringValue = "Taken from “\(stolen.title)”, which now has none."
            note.textColor = .systemOrange
        }
    }

    /// Show every command's current shortcut, and what each one replaces.
    func refresh() {
        for command in commands {
            guard let row = rows[command.id] else { continue }
            let s = store.shortcut(for: command)
            if !row.recorder.isRecording { row.recorder.show(s) }
            if let s, let clash = SystemShortcuts.clash(for: s) {
                row.note.stringValue = "Replaces macOS's “\(clash)”."
                row.note.textColor = .systemOrange
            } else {
                row.note.stringValue = ""
            }
        }
    }
}

/// A target that runs a closure, for buttons made in a loop.
final class ActionTarget: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

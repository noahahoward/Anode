import AppKit
import PowerKit

/// The control strip at the top of the Fans tab.
///
/// Fan control is OFF by default and there is nothing to turn on inside the app:
/// the privileged half is a program the user starts themselves, under sudo, and
/// stops when they are done. This view is therefore mostly a truthful status
/// line — it says which of the four states the machine is in and, when the answer
/// is "you would have to start the helper", it says exactly what to run rather
/// than offering a button that cannot do it.
///
/// The trust model behind all of this is written out at the top of
/// `FanLink.swift`; the one-sentence version is in the confirmation sheet, which
/// is the only place a user is actually reading before deciding.
final class FanControlPanel: NSView {

    /// Told when the strip's height changes, so the pane can resize it. A view
    /// that grows a row per fan cannot have its height fixed at construction.
    var onLayoutChanged: (() -> Void)?

    private let link = FanControlLink()
    private var status: FanControlLink.Status = .disconnected
    private var fans: [FanInfo] = []
    /// Fans the user has taken over this session. Their sliders stop following
    /// the hardware reading, because the knob now represents what was ASKED for
    /// and yanking it back to the current rpm mid-spin-up reads as the control
    /// fighting the user.
    private var driven: Set<Int> = []
    private var lastConnectAttempt = Date.distantPast

    private let stack = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let hintField = NSTextField(labelWithString: "")
    private let fanRows = NSStackView()
    private let buttonRow = NSStackView()
    private var sliders: [Int: NSSlider] = [:]
    private var valueLabels: [Int: NSTextField] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        render()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Height this strip wants right now. Read by the pane after every render.
    var preferredHeight: CGFloat {
        max(46, ceil(stack.fittingSize.height))
    }

    // ── Lifecycle ───────────────────────────────────────────────────────────

    /// New fan readings, once per tick while the tab is on screen.
    func update(fans: [FanInfo]) {
        self.fans = fans
        if Settings.shared.fanControlEnabled { connectIfNeeded() }
        render()
    }

    /// The app is going away.
    ///
    /// Closing the socket IS the release: the helper hands the fans back when its
    /// client disappears, so quitting takes the same path a crash takes and the
    /// path that matters is the one exercised every day.
    func teardown() {
        link.disconnect()
    }

    // ── Connection ──────────────────────────────────────────────────────────

    private func connectIfNeeded() {
        switch status {
        case .connected:
            return
        case .disconnected, .notRunning, .refused:
            // Retried on a timer rather than only on a button, so starting the
            // helper in a terminal is noticed on its own within a few seconds.
            // The attempt is a socket() and a connect() that fails immediately
            // when nothing is listening — cheaper than the tick that triggers it.
            guard Date().timeIntervalSince(lastConnectAttempt) > 5 else { return }
        }
        lastConnectAttempt = Date()
        link.connect { [weak self] newStatus in
            guard let self else { return }
            self.status = newStatus
            self.render()
        }
    }

    // ── Actions ─────────────────────────────────────────────────────────────

    @objc private func enableTapped() {
        let alert = NSAlert()
        alert.messageText = "Turn on fan control?"
        alert.informativeText = """
        While you run the fan helper, one program can set your fan speeds: this \
        exact build of BetterStats, running as you, within the minimum and maximum \
        the fan itself reports.

        The helper is not installed and does not run in the background. You start \
        it in Terminal with the command below and stop it with ⌃C, and the fans go \
        back to automatic control when you do — or if BetterStats quits or crashes.

        BetterStats is not signed with an Apple Developer ID, so nothing verifies \
        the helper before it runs as root except you, when you read the path you \
        are typing.
        """
        let command = NSTextField(labelWithString: Self.startCommand())
        command.font = Palette.Font.mono(11)
        command.isSelectable = true
        command.lineBreakMode = .byTruncatingMiddle
        command.frame = NSRect(x: 0, y: 0, width: 460, height: 18)
        alert.accessoryView = command
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Settings.shared.fanControlEnabled = true
        lastConnectAttempt = .distantPast
        connectIfNeeded()
        render()
    }

    @objc private func disableTapped() {
        // Release before disconnecting rather than relying on the dead man's
        // switch: the user asked for this one, so it should be reported.
        release { [weak self] in
            guard let self else { return }
            Settings.shared.fanControlEnabled = false
            self.link.disconnect()
            self.status = .disconnected
            self.driven.removeAll()
            self.render()
        }
    }

    @objc private func copyCommandTapped() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.startCommand(), forType: .string)
    }

    @objc private func releaseTapped() {
        release { [weak self] in self?.render() }
    }

    private func release(_ done: @escaping () -> Void) {
        guard case .connected = status else { return done() }
        link.send(.releaseAll) { [weak self] reply in
            guard let self else { return }
            self.driven.removeAll()
            self.lastReply = reply
            done()
        }
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard case .connected = status else { return }
        let index = sender.tag
        driven.insert(index)
        // Every gesture is sent. There is deliberately no "one request at a time"
        // guard: the link's queue already serialises these, and dropping a drag
        // because the previous one had not replied yet would leave the knob
        // somewhere the fan is not — a control that silently did nothing.
        //
        // The slider is not continuous, so this is one write per gesture rather
        // than one per pixel of drag — an SMC write per mouse-move would be
        // hundreds of privileged round trips to reach one speed.
        link.send(.setTarget(FanTarget(index: index, rpm: sender.doubleValue))) { [weak self] reply in
            guard let self else { return }
            self.lastReply = reply
            // A refusal means the helper is gone or said no; either way the
            // status line has to stop claiming the fan is where the knob is.
            if !reply.ok { self.driven.remove(index) }
            self.render()
        }
    }

    /// The helper's last word, shown verbatim. Its refusals name the reason, and
    /// paraphrasing them here would be a second place to keep in step.
    private var lastReply: FanReply?

    // ── Rendering ───────────────────────────────────────────────────────────

    private func render() {
        let enabled = Settings.shared.fanControlEnabled

        // Sliders exist only while there is something to drive.
        let wantSliders: Bool
        if case .connected = status, enabled { wantSliders = true } else { wantSliders = false }
        rebuildFanRows(wantSliders ? fans : [])

        switch (enabled, status) {
        case (false, _):
            statusLabel.stringValue = "Fan control is off — macOS is deciding."
            hintField.stringValue = ""
            setButtons([("Turn On Fan Control…", #selector(enableTapped))])

        case (true, .connected(let count)):
            statusLabel.stringValue = count == 0
                ? "Fan helper connected, but it found no fan it can control."
                : "Fan helper connected. \(count) fan\(count == 1 ? "" : "s") under manual control."
            hintField.stringValue = lastReply?.message ?? ""
            setButtons([("Return to Automatic", #selector(releaseTapped)),
                        ("Turn Off", #selector(disableTapped))])

        case (true, .notRunning), (true, .disconnected):
            statusLabel.stringValue = "Fan control is on, but the fan helper is not running."
            hintField.stringValue = Self.startCommand()
            setButtons([("Copy Start Command", #selector(copyCommandTapped)),
                        ("Turn Off", #selector(disableTapped))])

        case (true, .refused(let why)):
            statusLabel.stringValue = "The fan helper refused this app: \(why)"
            hintField.stringValue = Self.startCommand()
            setButtons([("Copy Start Command", #selector(copyCommandTapped)),
                        ("Turn Off", #selector(disableTapped))])
        }

        statusLabel.textColor = Palette.text
        hintField.textColor = Palette.dim
        hintField.isHidden = hintField.stringValue.isEmpty
        onLayoutChanged?()
    }

    private func rebuildFanRows(_ fans: [FanInfo]) {
        guard fans.map(\.index) != fanRows.arrangedSubviews.compactMap({ ($0 as? FanRow)?.index })
        else {
            for f in fans { applyReading(f) }
            return
        }
        fanRows.arrangedSubviews.forEach {
            fanRows.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        sliders.removeAll(); valueLabels.removeAll()
        for f in fans {
            // A fan whose reported range is nonsense gets no slider at all. The
            // helper would refuse the write anyway (FanPolicy.limitsImplausible),
            // and a control that is always refused is worse than none.
            guard f.maxRPM > f.minRPM, f.minRPM > 0 else { continue }
            let row = FanRow(index: f.index)
            let slider = NSSlider(value: f.targetRPM ?? f.currentRPM,
                                  minValue: f.minRPM, maxValue: f.maxRPM,
                                  target: self, action: #selector(sliderChanged(_:)))
            // Fires on mouse-up, not on every pixel: see `sliderChanged`.
            slider.isContinuous = false
            slider.tag = f.index
            slider.controlSize = .small
            let name = NSTextField(labelWithString: "Fan \(f.index + 1)")
            name.font = Palette.Font.sans(11.5)
            name.textColor = Palette.dim
            let value = NSTextField(labelWithString: "")
            value.font = Palette.Font.mono(11)
            value.textColor = Palette.text
            value.alignment = .right
            row.install(name: name, slider: slider, value: value)
            fanRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: fanRows.widthAnchor).isActive = true
            sliders[f.index] = slider
            valueLabels[f.index] = value
            applyReading(f)
        }
    }

    private func applyReading(_ f: FanInfo) {
        guard let slider = sliders[f.index], let label = valueLabels[f.index] else { return }
        if !driven.contains(f.index) {
            slider.minValue = f.minRPM
            slider.maxValue = f.maxRPM
            slider.doubleValue = min(max(f.targetRPM ?? f.currentRPM, f.minRPM), f.maxRPM)
        }
        // Asked-for versus actual, both shown. A fan takes seconds to reach a new
        // target, and showing only one of the two makes the lag look like a
        // control that did not work.
        label.stringValue = String(format: "%.0f → %.0f rpm", f.currentRPM, slider.doubleValue)
    }

    private func setButtons(_ items: [(String, Selector)]) {
        let titles = items.map(\.0)
        guard titles != buttonRow.arrangedSubviews.compactMap({ ($0 as? NSButton)?.title }) else {
            return
        }
        buttonRow.arrangedSubviews.forEach {
            buttonRow.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        for (title, action) in items {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = Palette.Font.sans(11)
            buttonRow.addArrangedSubview(b)
        }
        buttonRow.addArrangedSubview(NSView())   // pushes the buttons to the left
    }

    // ── Chrome ──────────────────────────────────────────────────────────────

    private func build() {
        statusLabel.font = Palette.Font.sans(11.5)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        hintField.font = Palette.Font.mono(10.5)
        hintField.lineBreakMode = .byTruncatingMiddle
        // Selectable, so the command can be copied by hand as well as by button.
        hintField.isSelectable = true

        fanRows.orientation = .vertical
        fanRows.alignment = .leading
        fanRows.spacing = 4
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in [statusLabel, hintField, fanRows, buttonRow] as [NSView] {
            stack.addArrangedSubview(v)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            fanRows.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        statusLabel.textColor = Palette.text
        hintField.textColor = Palette.dim
        for label in valueLabels.values { label.textColor = Palette.text }
    }

    /// The exact command that starts the helper for THIS build.
    ///
    /// Derived from where the running binary actually is, because that is the
    /// path the helper will pin and the user is about to type after `sudo`. A
    /// bundled build names the helper inside its own bundle and needs nothing
    /// else; a bare `swift build` binary has no bundle, so the client is named
    /// explicitly — otherwise the helper would refuse to start, which is correct
    /// but unhelpful to print.
    static func startCommand() -> String {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            return "sudo " + quoted(bundle.appendingPathComponent("Contents/MacOS/BetterStatsHelper").path)
        }
        let exe = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            .resolvingSymlinksInPath()
        let helper = exe.deletingLastPathComponent().appendingPathComponent("BetterStatsHelper")
        return "sudo " + quoted(helper.path) + " --client " + quoted(exe.path)
    }

    /// This project's own checkout path contains a space, so an unquoted command
    /// would be two arguments and the instruction would be wrong for the person
    /// most likely to read it.
    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// One fan's row: name, slider, reading.
    private final class FanRow: NSView {
        let index: Int
        init(index: Int) {
            self.index = index
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
        }
        required init?(coder: NSCoder) { fatalError() }

        func install(name: NSView, slider: NSView, value: NSView) {
            for v in [name, slider, value] {
                v.translatesAutoresizingMaskIntoConstraints = false
                addSubview(v)
            }
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 22),
                name.leadingAnchor.constraint(equalTo: leadingAnchor),
                name.centerYAnchor.constraint(equalTo: centerYAnchor),
                name.widthAnchor.constraint(equalToConstant: 46),
                slider.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 8),
                slider.centerYAnchor.constraint(equalTo: centerYAnchor),
                value.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 10),
                value.trailingAnchor.constraint(equalTo: trailingAnchor),
                value.centerYAnchor.constraint(equalTo: centerYAnchor),
                value.widthAnchor.constraint(equalToConstant: 118),
            ])
        }
    }
}

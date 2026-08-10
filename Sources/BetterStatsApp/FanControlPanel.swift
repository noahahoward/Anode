import AppKit
import PowerKit

/// The control strip at the top of the Fans tab: one row per fan, each
/// `[ name ] [ ——slider—— ] [ reading ] [ ❄︎ ] [ ✕ ]`.
///
/// The slider is a LIVE GAUGE until this app has asked for something. It is drawn
/// faded so it reads as "not yours yet", but it is not `isEnabled = false`: a
/// disabled slider cannot be grabbed, and grabbing it is precisely how a user
/// says they want control. Grabbing a faded knob, or pressing ❄︎, is what starts
/// the privileged half — visibly, and never behind the user's back.
///
/// The trust model behind all of this is written out at the top of
/// `FanLink.swift`, and the decision machinery — what a grab means in each state,
/// what a cancel leaves behind — is `FanSession` in `FanControl.swift`, which
/// this view is a rendering of. The two things this file adds are the pixels and
/// the one honest way it has found to elevate.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// HOW THE HELPER GETS STARTED, AND WHY IT IS THIS WAY.
///
/// The app cannot become root, and it must not pretend to. Two routes were
/// available and only one of them survives contact with this project's own trust
/// model:
///
///   * `osascript`'s `do shell script … with administrator privileges` puts up
///     the system authentication dialog. It is one click and a password — and it
///     shows the user NOTHING about what they are authorising. That is fatal
///     here. The whole security argument for this feature (FanLink.swift, and
///     the helper's own startup banner) is that no signature verifies the helper
///     before it runs as root, so THE USER DOES, by reading the path they type
///     after `sudo`. A password box that names no path replaces a check by a
///     person with a reflex. `FanLink.swift` already rejected a design for
///     exactly this reason: it "trains a user to type their password whenever an
///     app asks — which is a worse hole than the one the pin closed". Worse
///     still, a helper started that way is detached, so ⌃C — the documented and
///     only way to stop it — no longer applies, leaving a root process the user
///     has no obvious way to end.
///
///   * TERMINAL, PRE-FILLED. This is what is implemented. The app writes a short
///     script, opens it in Terminal, and the script prints the exact command,
///     says what it is about to do, and only then runs it. The user reads the
///     path, then authenticates at `sudo`'s own prompt in a window they can see.
///     Everything the existing design depends on stays true: `sudo` sets
///     `SUDO_UID`, so the helper serves the right user; the helper's startup
///     disclosure (client path, cdhash, uid, socket) is printed where a person
///     is actually looking; and ⌃C still stops it.
///
/// It is opened through LaunchServices (`open -a Terminal`) rather than Apple
/// events, so it needs no Automation permission and cannot be silently denied by
/// TCC. If it fails anyway, the command goes to the clipboard and the strip says
/// so — the app degrades to instructions, never to a half-state.
///
/// Nothing here elevates when a helper is already running. In that case a grab is
/// just a socket write, with no prompt of any kind.
/// ─────────────────────────────────────────────────────────────────────────────
final class FanControlPanel: NSView {

    /// Told when the strip's height changes, so the pane can resize it. A view
    /// that grows a row per fan cannot have its height fixed at construction.
    var onLayoutChanged: (() -> Void)?

    /// How long to wait for a helper the user is starting by hand. Generous
    /// because the wait includes finding the Terminal window, reading the path
    /// and typing a password — and because the cost of giving up too early is a
    /// helper that arrives to find nobody queued anything for it.
    private static let startTimeout: TimeInterval = 180

    private let link = FanControlLink()
    private var session = FanSession(enabled: Settings.shared.fanControlEnabled)
    private var fans: [FanInfo] = []
    /// The helper's last word, shown verbatim. Its refusals name the reason, and
    /// paraphrasing them here would be a second place to keep in step.
    ///
    /// It fades after a while so it cannot sit on top of the standing hint — the
    /// start command — for the rest of the session. Set it through `say`.
    private var note: String?
    private var noteAt = Date.distantPast
    private static let noteLifetime: TimeInterval = 10

    private func say(_ text: String?) {
        note = text
        noteAt = Date()
    }

    private var lastConnectAttempt = Date.distantPast
    private var lastPing = Date.distantPast
    private var connecting = false
    private var startDeadline: Date?
    private var pollTimer: Timer?

    private let stack = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let hintField = NSTextField(labelWithString: "")
    private let fanRows = NSStackView()
    private let buttonRow = NSStackView()
    private var sliders: [Int: NSSlider] = [:]
    private var valueLabels: [Int: NSTextField] = [:]
    private var boostButtons: [Int: NSButton] = [:]
    private var releaseButtons: [Int: NSButton] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        render()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { pollTimer?.invalidate() }

    override var isFlipped: Bool { true }

    /// Height this strip wants right now. Read by the pane after every render.
    var preferredHeight: CGFloat {
        max(46, ceil(stack.fittingSize.height))
    }

    // ── Lifecycle ───────────────────────────────────────────────────────────

    /// New fan readings, once per tick while the tab is on screen.
    func update(fans: [FanInfo]) {
        self.fans = fans
        session.enabled = Settings.shared.fanControlEnabled
        if note != nil, Date().timeIntervalSince(noteAt) > Self.noteLifetime { note = nil }
        upkeep()
        render()
    }

    /// The app is going away.
    ///
    /// Closing the socket IS the release: the helper hands the fans back when its
    /// client disappears, so quitting takes the same path a crash takes and the
    /// path that matters is the one exercised every day.
    func teardown() {
        endPolling()
        link.disconnect()
    }

    // ── Connection ──────────────────────────────────────────────────────────

    /// Keep what the strip believes in step with what is actually on the socket.
    private func upkeep() {
        guard session.enabled else { return }
        switch session.helper {
        case .connected:
            // A helper that dies while nothing is being dragged is otherwise
            // invisible — our end of the socket stays open until something tries
            // to use it, and until then the strip would go on claiming manual
            // control of fans that were handed back seconds ago. `ping` is a
            // `hello`, which writes nothing.
            guard Date().timeIntervalSince(lastPing) > 5 else { return }
            lastPing = Date()
            link.ping { [weak self] in self?.linkAnswered($0) }
        case .starting:
            return   // the poll timer owns this state
        case .absent, .refused:
            // Retried on a timer rather than only on a button, so a helper
            // started in a terminal by hand is noticed within a few seconds. The
            // attempt is a socket() and a connect() that fails immediately when
            // nothing is listening — cheaper than the tick that triggers it.
            guard Date().timeIntervalSince(lastConnectAttempt) > 5 else { return }
            attemptConnect()
        }
    }

    private func attemptConnect() {
        guard !connecting else { return }
        connecting = true
        lastConnectAttempt = Date()
        link.connect { [weak self] status in
            guard let self else { return }
            self.connecting = false
            self.linkAnswered(status)
        }
    }

    private func linkAnswered(_ status: FanControlLink.Status) {
        // While a helper is being started by hand, "nothing is listening" is not
        // news — it is what waiting looks like. Only a connection or a refusal
        // ends the wait, so a slow password prompt does not throw away the
        // request the user queued.
        if case .starting = session.mode, case .notRunning = status { return }

        if case .connected = status {
            endPolling()
            lastPing = Date()
        }
        let before = session.helper
        let queued = session.helperBecame(Self.helper(from: status))
        // A message about the previous state is worse than no message at all.
        if session.helper != before { say(nil) }
        for command in queued { send(command) }
        render()
    }

    private static func helper(from status: FanControlLink.Status) -> FanSession.Helper {
        switch status {
        case .connected(let n):           return .connected(fanCount: n)
        case .refused(let why):           return .refused(why)
        case .notRunning, .disconnected:  return .absent
        }
    }

    private func send(_ command: FanCommand) {
        link.send(command) { [weak self] reply in
            guard let self else { return }
            self.session.completed(command, ok: reply.ok)
            self.say(reply.message)
            self.render()
        }
    }

    // ── Gestures ────────────────────────────────────────────────────────────

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard let limits = limits(for: sender.tag) else { return }
        gesture(.setSpeed(index: sender.tag, rpm: sender.doubleValue, limits: limits))
    }

    @objc private func boostTapped(_ sender: NSButton) {
        guard let limits = limits(for: sender.tag) else { return }
        gesture(.fullSpeed(index: sender.tag, limits: limits))
    }

    @objc private func releaseTapped() {
        gesture(.release)
    }

    private func gesture(_ g: FanSession.Gesture) {
        // Grabbing a knob is the first thing most people will try, and it must
        // not silently do nothing just because the feature ships off. The sheet
        // is the same one the "Turn On" button shows, because it is the same
        // decision — and a cancel here re-renders, which snaps the knob back to
        // the live reading rather than leaving it where the drag ended.
        if !Settings.shared.fanControlEnabled {
            if case .release = g { return render() }
            guard confirmTurnOn() else { return render() }
            Settings.shared.fanControlEnabled = true
            session.enabled = true
        }
        perform(session.apply(g))
    }

    private func perform(_ effect: FanSession.Effect) {
        switch effect {
        case .nothing(let why):
            say(why)
        case .send(let command):
            say(nil)
            send(command)
        case .startHelper:
            startHelper()
        case .abandonStart:
            endPolling()
            say("Cancelled. Nothing was written — the fans are on automatic.")
        }
        render()
    }

    /// Start the privileged half, in front of the user. See the note at the top
    /// of this file for why it is a Terminal window and not a password box.
    private func startHelper() {
        let command = Self.startCommand()
        switch FanHelperLaunch.start(command: command) {
        case .openedTerminal:
            say(nil)
            startDeadline = Date().addingTimeInterval(Self.startTimeout)
            beginPolling()
        case .failed(let why):
            // No half-state: back to automatic, with the command to hand. The
            // ordinary reconnect poll will find the helper if they run it.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            session.helperBecame(.absent)
            endPolling()
            say("Could not open Terminal (\(why)). The command is on your clipboard — "
              + "run it in a terminal and this will connect on its own.")
        }
    }

    private func beginPolling() {
        pollTimer?.invalidate()
        // A timer as well as the sample tick, so the helper coming up is noticed
        // even if the user has switched to another tab while typing a password.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.pollWhileStarting()
        }
    }

    private func endPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        startDeadline = nil
    }

    private func pollWhileStarting() {
        guard case .starting = session.mode else { return endPolling() }
        if let deadline = startDeadline, Date() > deadline {
            endPolling()
            session.helperBecame(.absent)
            say("The fan helper did not start. Nothing was written — "
              + "the fans are on automatic.")
            return render()
        }
        attemptConnect()
    }

    // ── The on/off decision ─────────────────────────────────────────────────

    @objc private func enableTapped() {
        guard confirmTurnOn() else { return }
        Settings.shared.fanControlEnabled = true
        session.enabled = true
        lastConnectAttempt = .distantPast
        upkeep()
        render()
    }

    /// The disclosure, shown before the feature is switched on for the first time
    /// and before any grab that would switch it on.
    private func confirmTurnOn() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Turn on fan control?"
        alert.informativeText = """
        While you run the fan helper, one program can set your fan speeds: this \
        exact build of BetterStats, running as you, within the minimum and maximum \
        the fan itself reports.

        The helper is not installed and does not run in the background. Taking a \
        slider opens a Terminal window with the command below; you read it, \
        authenticate, and stop it with ⌃C. The fans go back to automatic control \
        when you do — or if BetterStats quits or crashes.

        BetterStats is not signed with an Apple Developer ID, so nothing verifies \
        the helper before it runs as root except you, when you read the path.
        """
        let command = NSTextField(labelWithString: Self.startCommand())
        command.font = Palette.Font.mono(11)
        command.isSelectable = true
        command.lineBreakMode = .byTruncatingMiddle
        command.frame = NSRect(x: 0, y: 0, width: 460, height: 18)
        alert.accessoryView = command
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func disableTapped() {
        // Release before disconnecting rather than relying on the dead man's
        // switch: the user asked for this one, so it should be reported.
        perform(session.apply(.release))
        Settings.shared.fanControlEnabled = false
        session.enabled = false
        endPolling()
        link.disconnect()
        session.helperBecame(.absent)
        render()
    }

    @objc private func copyCommandTapped() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.startCommand(), forType: .string)
    }

    // ── Rendering ───────────────────────────────────────────────────────────

    private func render() {
        rebuildFanRows(fans)

        switch session.mode {
        case .off:
            statusLabel.stringValue = "Fan control is off — macOS is deciding. "
                                    + "The sliders are live readings; take one to turn it on."
            hintField.stringValue = ""
            setButtons([("Turn On Fan Control…", #selector(enableTapped))])

        case .automatic:
            if case .connected(let count) = session.helper {
                statusLabel.stringValue = count == 0
                    ? "Fan helper connected, but it found no fan it can control."
                    : "Fan helper connected. No fan is held — macOS is still deciding. "
                    + "Take a slider or press ❄︎ to change that."
                hintField.stringValue = ""
                setButtons([("Turn Off", #selector(disableTapped))])
            } else {
                statusLabel.stringValue = "Fan control is on and macOS is deciding. "
                                        + "Take a slider or press ❄︎ and you will be asked to start the helper."
                hintField.stringValue = Self.startCommand()
                setButtons([("Copy Start Command", #selector(copyCommandTapped)),
                            ("Turn Off", #selector(disableTapped))])
            }

        case .starting:
            statusLabel.stringValue = "Waiting for the fan helper — a Terminal window is open. "
                                    + "Read the command, authenticate, and this connects on its own."
            hintField.stringValue = Self.startCommand()
            setButtons([("Cancel", #selector(releaseTapped)),
                        ("Turn Off", #selector(disableTapped))])

        case .manual(let count):
            statusLabel.stringValue = count == 1
                ? "1 fan under manual control. ✕ hands them all back."
                : "\(count) fans under manual control. ✕ hands them all back."
            hintField.stringValue = ""
            setButtons([("Return to Automatic", #selector(releaseTapped)),
                        ("Turn Off", #selector(disableTapped))])

        case .blocked(let why):
            statusLabel.stringValue = "The fan helper refused this app: \(why)"
            hintField.stringValue = Self.startCommand()
            setButtons([("Copy Start Command", #selector(copyCommandTapped)),
                        ("Turn Off", #selector(disableTapped))])
        }

        if let note, !note.isEmpty { hintField.stringValue = note }
        statusLabel.textColor = Palette.text
        hintField.textColor = Palette.dim
        hintField.isHidden = hintField.stringValue.isEmpty
        onLayoutChanged?()
    }

    private func rebuildFanRows(_ fans: [FanInfo]) {
        // A fan whose reported range is nonsense gets no row at all. The helper
        // would refuse the write anyway (FanPolicy.limitsImplausible), and a
        // control that is always refused is worse than none.
        let usable = fans.filter { $0.maxRPM > $0.minRPM && $0.minRPM > 0 }
        guard usable.map(\.index) != fanRows.arrangedSubviews.compactMap({ ($0 as? FanRow)?.index })
        else {
            for f in usable { applyReading(f) }
            return
        }
        fanRows.arrangedSubviews.forEach {
            fanRows.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        sliders.removeAll(); valueLabels.removeAll()
        boostButtons.removeAll(); releaseButtons.removeAll()
        for f in usable {
            let row = FanRow(index: f.index)
            let slider = GaugeSlider()
            slider.minValue = f.minRPM
            slider.maxValue = f.maxRPM
            slider.doubleValue = f.currentRPM
            slider.target = self
            slider.action = #selector(sliderChanged(_:))
            // Fires on mouse-up, not on every pixel: one privileged round trip
            // per gesture rather than hundreds per drag.
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

            let boost = symbolButton("snowflake", fallback: "❄︎",
                                     action: #selector(boostTapped(_:)))
            boost.tag = f.index
            boost.contentTintColor = Palette.blue
            boost.toolTip = "Run fan \(f.index + 1) flat out (100% of its reported range). "
                          + "Starts the fan helper first if it is not running."
            boost.setAccessibilityLabel("Set fan \(f.index + 1) to full speed")

            let stop = symbolButton("xmark", fallback: "✕",
                                    action: #selector(releaseTapped))
            stop.tag = f.index
            stop.contentTintColor = Palette.critical
            // Says "every fan" because that is what it does. The helper's whole
            // privileged vocabulary is "set one fan" and "release the fans" —
            // there is no per-fan release, and inventing one by writing a single
            // fan its minimum would PIN it there, quietly, which is the exact
            // failure this button exists to undo.
            stop.toolTip = "Return every fan to automatic control"
            stop.setAccessibilityLabel("Return every fan to automatic control")

            row.install(name: name, slider: slider, value: value, boost: boost, stop: stop)
            fanRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: fanRows.widthAnchor).isActive = true
            sliders[f.index] = slider
            valueLabels[f.index] = value
            boostButtons[f.index] = boost
            releaseButtons[f.index] = stop
            applyReading(f)
        }
    }

    private func applyReading(_ f: FanInfo) {
        guard let slider = sliders[f.index], let label = valueLabels[f.index] else { return }
        let limits = FanPolicy.Limits(minRPM: f.minRPM, maxRPM: f.maxRPM)
        let asked = session.asked(f.index)
        // Never under a hand that is dragging it. The reading beside it still
        // updates — that is the number the user is aiming with.
        if !((slider as? GaugeSlider)?.isTracking ?? false) {
            slider.minValue = f.minRPM
            slider.maxValue = f.maxRPM
            slider.doubleValue = FanGauge.knobRPM(current: f.currentRPM, asked: asked,
                                                  limits: limits)
        }
        label.stringValue = FanGauge.readout(current: f.currentRPM, asked: asked)

        // Faded, not disabled. A disabled slider cannot be grabbed, and grabbing
        // it is how a user asks for control in the first place.
        slider.alphaValue = asked == nil ? 0.45 : (session.held[f.index] == nil ? 0.7 : 1)
        label.textColor = asked == nil ? Palette.dim : Palette.text

        let canRelease = session.isDriving || session.mode == .starting
        if let stop = releaseButtons[f.index] {
            stop.isEnabled = canRelease
            stop.alphaValue = canRelease ? 1 : 0.25
        }
        boostButtons[f.index]?.alphaValue = session.held[f.index] == nil ? 0.85 : 1
    }

    private func symbolButton(_ symbol: String, fallback: String, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.bezelStyle = .inline
        button.isBordered = false
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            image.isTemplate = true
            button.image = image.withSymbolConfiguration(
                .init(pointSize: 12, weight: .semibold)) ?? image
            button.imagePosition = .imageOnly
        } else {
            // Older systems, or a symbol Apple renames out from under us. A glyph
            // is not as tidy but it is still a button that says what it does.
            button.title = fallback
            button.font = Palette.Font.sans(13)
        }
        return button
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
        for b in boostButtons.values { b.contentTintColor = Palette.blue }
        for b in releaseButtons.values { b.contentTintColor = Palette.critical }
    }

    private func limits(for index: Int) -> FanPolicy.Limits? {
        guard let f = fans.first(where: { $0.index == index }) else { return nil }
        return FanPolicy.Limits(minRPM: f.minRPM, maxRPM: f.maxRPM)
    }

    /// The exact command that starts the helper for THIS build.
    ///
    /// Derived from where the running binary actually is, because that is the
    /// path the helper will pin and the user is about to read after `sudo`. A
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

    /// A slider that knows when it is being dragged.
    ///
    /// It has to, now that the knob is a live gauge in automatic mode: the sample
    /// tick rewrites the knob from the hardware on every render, and doing that
    /// under a hand that is dragging it would make the control fight the user.
    /// `super.mouseDown` runs AppKit's own tracking loop and returns when the
    /// mouse is let go, so the flag is exact rather than guessed from event state.
    private final class GaugeSlider: NSSlider {
        private(set) var isTracking = false
        override func mouseDown(with event: NSEvent) {
            isTracking = true
            super.mouseDown(with: event)
            isTracking = false
        }
    }

    /// One fan's row: name, slider, reading, ❄︎, ✕.
    private final class FanRow: NSView {
        let index: Int
        init(index: Int) {
            self.index = index
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
        }
        required init?(coder: NSCoder) { fatalError() }

        func install(name: NSView, slider: NSView, value: NSView,
                     boost: NSView, stop: NSView) {
            for v in [name, slider, value, boost, stop] {
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
                value.centerYAnchor.constraint(equalTo: centerYAnchor),
                value.widthAnchor.constraint(equalToConstant: 118),
                boost.leadingAnchor.constraint(equalTo: value.trailingAnchor, constant: 8),
                boost.centerYAnchor.constraint(equalTo: centerYAnchor),
                boost.widthAnchor.constraint(equalToConstant: 20),
                stop.leadingAnchor.constraint(equalTo: boost.trailingAnchor, constant: 4),
                stop.centerYAnchor.constraint(equalTo: centerYAnchor),
                stop.widthAnchor.constraint(equalToConstant: 20),
                stop.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Opening a Terminal window on the command that starts the helper.
///
/// The script exists so the user reads the path BEFORE `sudo` asks for anything.
/// It is written fresh every time from the running app's own location, so it can
/// never point at a bundle that has moved, and it is opened through
/// LaunchServices rather than Apple events so it needs no Automation permission.
enum FanHelperLaunch {

    enum Outcome: Equatable {
        case openedTerminal(scriptPath: String)
        case failed(String)
    }

    /// In the app's own support directory, not a shared temp dir: a script that
    /// runs `sudo` should not live anywhere another user on the machine could
    /// reach it.
    static var scriptURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("BetterStats/start-fan-helper.command")
    }

    /// The script, as text. Pure, so what the user is about to be shown can be
    /// asserted in the test suite rather than discovered in a Terminal window.
    ///
    /// `exec` rather than a plain call: ⌃C then reaches the helper directly, and
    /// ⌃C is the documented and only way to stop it.
    static func script(command: String) -> String {
        """
        #!/bin/sh
        # Written by BetterStats immediately before this window opened, and
        # rewritten every time. Running it by hand does exactly what the app does.

        cat <<'BETTERSTATS_END'
        ────────────────────────────────────────────────────────────────────────
         BetterStats fan control

         The command below runs as ROOT. BetterStats is not signed with an Apple
         Developer ID, so nothing verifies it before it runs — except you, now,
         reading the path:
        BETTERSTATS_END
        printf '\\n   %s\\n\\n' \(FanControlPanel.quoted(command))
        cat <<'BETTERSTATS_END'
         It stays in this window. Press ⌃C to stop fan control at any time and
         the fans go back to automatic — as they also do if BetterStats quits or
         crashes. Press ⌃C now to back out instead.
        ────────────────────────────────────────────────────────────────────────
        BETTERSTATS_END

        exec \(command)
        """
    }

    /// Write it and open it. Returns what to tell the user.
    static func start(command: String,
                      open: (URL) -> Int32 = FanHelperLaunch.openInTerminal) -> Outcome {
        let url = scriptURL
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
        } catch {
            return .failed(error.localizedDescription)
        }
        try? fm.removeItem(at: url)
        // Created 0700 in one step rather than written and then chmodded: for the
        // moment in between, a script that runs sudo would be writable at the
        // process umask.
        guard fm.createFile(atPath: url.path,
                            contents: Data(script(command: command).utf8),
                            attributes: [.posixPermissions: 0o700]) else {
            return .failed("could not write \(url.path)")
        }
        guard open(url) == 0 else { return .failed("Terminal would not open") }
        return .openedTerminal(scriptPath: url.path)
    }

    private static func openInTerminal(_ url: URL) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Terminal", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

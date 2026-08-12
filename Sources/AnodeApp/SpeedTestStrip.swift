import AppKit
import Network
import PowerKit

/// The Network tab's speed test: a dial, a button under it, and two result tiles.
///
/// THIS IS THE ONLY CONTROL IN THE APP THAT SENDS DATA ANYWHERE, and the whole
/// design of it follows from that. `SpeedTest.swift` states the engine's side of
/// the bargain — user-initiated only, endpoint named, failure is nil rather than
/// zero — and this view is the half a person actually sees:
///
///  * **Nothing happens until the button is pressed.** No timer, no run on first
///    open, no "refresh while you are looking at the tab". Opening the Network
///    tab is not consent to transfer several hundred megabytes.
///  * **The first press explains itself**, once, naming Cloudflare and roughly
///    what it will cost at a couple of line speeds and the fact that they see
///    your IP. `SpeedTestGate` owns that decision so it is a rule rather than a
///    layout, and so it can be tested.
///  * **A metered path asks every time.** Low Data Mode and personal hotspots
///    are the user having already said they want less traffic here; the answer
///    to that is not a silent few hundred megabytes.
///  * **The host is on screen even when idle.** Who gets contacted should not be
///    something you have to press a button to discover.
final class SpeedTestStrip: NSView {

    /// Told when the strip's height changes, so the pane can resize it.
    var onLayoutChanged: (() -> Void)?

    /// Told when a test starts and stops, with the bytes it is about to move.
    ///
    /// The Network tab's own graph is about to show a spike that Anode
    /// caused, and the battery ledger is about to attribute the energy for it to
    /// Anode — correctly, and confusingly. A monitor that makes a mess of
    /// its own readings without saying so is the kind of quiet dishonesty this
    /// project exists to avoid.
    var onActivity: ((Bool) -> Void)?

    private let dial = SpeedometerView(frame: .zero)
    private let downTile = SpeedTileView(caption: "Mbps download")
    private let upTile = SpeedTileView(caption: "Mbps upload")
    private let button = NSButton(title: "", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    private var running = false
    /// Last result, kept only for as long as the app runs. Nothing is persisted:
    /// a speed test is a reading of one moment on one path, and a stale one
    /// presented as current would be a worse answer than no answer.
    private var lastResult: SpeedTest.Result?
    private var lastError: String?
    /// When the button becomes pressable again. See `SpeedTest.cooldownSeconds`:
    /// the endpoint is free and rate-limits by volume, and one run is a few
    /// hundred megabytes of it.
    private var readyAt = Date.distantPast
    private var cooldownTimer: Timer?

    /// Watches the current path so the metered question can be answered before
    /// the user is asked anything. Started once; `NWPathMonitor` is cheap and
    /// event-driven, and polling it at press time would race the first update.
    private let pathMonitor = NWPathMonitor()
    private var pathIsExpensive = false
    private var pathIsConstrained = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.pathIsExpensive = path.isExpensive
                self?.pathIsConstrained = path.isConstrained
                self?.render()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "dev.anode.app.speedtest.path"))
        render()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { pathMonitor.cancel() }

    override func viewDidChangeEffectiveAppearance() { render() }

    // ── The one action ──────────────────────────────────────────────────────

    @objc private func runTapped() {
        guard !running, Date() >= readyAt else { return }
        switch SpeedTestGate.decide(hasAgreedBefore: Settings.shared.speedTestAgreed,
                                    isExpensive: pathIsExpensive,
                                    isConstrained: pathIsConstrained,
                                    host: SpeedTest.Endpoint.cloudflare.host) {
        case .run:
            start()
        case .ask(let text):
            guard confirm(text) else { return }
            // Recorded only after they agreed, and only for the ordinary case:
            // agreeing once on a metered network is not agreeing to every future
            // metered network.
            if !pathIsExpensive && !pathIsConstrained { Settings.shared.speedTestAgreed = true }
            start()
        }
    }

    private func confirm(_ text: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Run an internet speed test?"
        alert.informativeText = text
        alert.addButton(withTitle: "Run Test")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func start() {
        running = true
        lastError = nil
        lastResult = nil
        dial.mbps = nil
        downTile.mbps = nil
        upTile.mbps = nil
        dial.phase = "Starting…"
        onActivity?(true)
        render()

        Task { [weak self] in
            do {
                let result = try await SpeedTest.run { update in
                    // `progress` is documented as arriving on an arbitrary queue.
                    DispatchQueue.main.async { self?.show(update) }
                }
                await MainActor.run { self?.finished(.success(result)) }
            } catch {
                await MainActor.run { self?.finished(.failure(error)) }
            }
        }
    }

    /// One live update, straight onto the dial.
    ///
    /// The tiles fill in as each phase FINISHES rather than tracking the live
    /// figure, so a settled number never twitches: the dial is the thing that
    /// moves and the tiles are the thing you read afterwards.
    private func show(_ update: SpeedTest.Update) {
        switch update.phase {
        case "download":
            dial.phase = "Testing download…"
            dial.mbps = update.mbps
        case "upload":
            // Download is finished the moment upload starts, so its tile lands
            // here with the last live figure the dial had.
            if downTile.mbps == nil { downTile.mbps = dial.mbps }
            dial.phase = "Testing upload…"
            dial.mbps = update.mbps
        case "latency":
            dial.phase = "Measuring latency…"
        default:
            dial.phase = nil
        }
    }

    private func finished(_ outcome: Result<SpeedTest.Result, Error>) {
        running = false
        onActivity?(false)
        readyAt = Date().addingTimeInterval(SpeedTest.cooldownSeconds)
        cooldownTimer?.invalidate()
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            if Date() >= self.readyAt { t.invalidate(); self.cooldownTimer = nil }
            self.render()
        }
        switch outcome {
        case .success(let r):
            lastResult = r
            downTile.mbps = r.downloadMbps
            upTile.mbps = r.uploadMbps
            dial.mbps = r.downloadMbps
            dial.phase = nil
        case .failure(let error):
            // A failed test yields NO number. "0 Mbps" is a measurement, and we
            // did not make one — the same rule the ledger follows everywhere.
            //
            // `localizedDescription` and not `String(describing:)`: the former is
            // the sentence written for a person, now that `Failure` is a
            // LocalizedError. The latter would print the enum case.
            lastError = error.localizedDescription
            dial.mbps = nil
            dial.phase = nil
            downTile.mbps = nil
            upTile.mbps = nil
        }
        render()
    }

    // ── Rendering ───────────────────────────────────────────────────────────

    private func render() {
        let host = SpeedTest.Endpoint.cloudflare.host
        let waiting = max(0, readyAt.timeIntervalSinceNow)
        button.isEnabled = !running && waiting <= 0
        // Short, because the button is inside the ring now and the opening is
        // about 126 points across — "Test Internet Speed" measures 135 with its
        // bezel and would cross the arc on both sides. Nothing is lost: the line
        // under the dial already names the endpoint and what it will cost.
        button.title = running ? "Testing…"
            : waiting > 0 ? "Again in \(Int(waiting.rounded(.up)))s"
            : "Test Speed"
        // The button steps aside for the dial while a test runs — the live number
        // IS the feedback, and a disabled button sitting under it is furniture.
        // They now occupy the same spot, so exactly one of them is ever visible.
        button.isHidden = running
        dial.showsReadout = running

        if running {
            statusLabel.stringValue = ""
        } else if let why = lastError {
            statusLabel.stringValue = "No result — \(why)"
        } else if pathIsExpensive || pathIsConstrained {
            statusLabel.stringValue = pathIsConstrained
                ? "Low Data Mode — this will ask before using data."
                : "Metered connection — this will ask before using data."
        } else if let r = lastResult {
            statusLabel.stringValue = String(format: "%.0f ms · %@ · %.0f MB moved",
                                             r.latencyMs, r.host,
                                             Double(r.downloadBytes + r.uploadBytes) / 1e6)
        } else {
            statusLabel.stringValue = String(
                format: "About %ds to and from %@, only when you press it",
                Int(SpeedTest.downSeconds + SpeedTest.upSeconds), host)
        }
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
        statusLabel.textColor = Palette.dim
        onLayoutChanged?()
    }

    /// Tall enough for the dial, the line under it and the two tiles.
    ///
    /// Was 300, when the button had a row of its own between the dial and the
    /// tiles. It does not any more, so the tiles move up by that row and its
    /// spacing — which is height given back to the graph above on a small
    /// window, where this strip and the chart are competing for the same inches.
    var preferredHeight: CGFloat { 268 }

    private func build() {
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = Palette.Font.sans(12)
        button.target = self
        button.action = #selector(runTapped)

        statusLabel.font = Palette.Font.sans(10.5)
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail

        dial.translatesAutoresizingMaskIntoConstraints = false

        // The two tiles, side by side under the dial, with a hairline between
        // them — the same divider the rest of the app uses between columns.
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let tiles = NSStackView(views: [downTile, divider, upTile])
        tiles.orientation = .horizontal
        tiles.distribution = .fillProportionally
        tiles.spacing = 0
        tiles.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(dial)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(tiles)
        addSubview(stack)

        // INSIDE the dial, where the number used to be — not in the stack under
        // it. The centre of a dial that no longer prints a figure is the largest
        // empty space on the tab, and a button in its own row below was pushing
        // the two result tiles down for no reason. Putting the control where the
        // reading was also says what the dial is for.
        button.translatesAutoresizingMaskIntoConstraints = false
        dial.addSubview(button)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            dial.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dial.heightAnchor.constraint(equalToConstant: 190),
            // NEGATIVE, and that sign is the whole subtlety. `draw` puts the
            // arc's centre six points ABOVE the frame's, to balance the gap at
            // the bottom of the ring — but Auto Layout's `centerY` constant runs
            // top-down here regardless of the view being unflipped, so a positive
            // constant moves the button down. Written the other way first, which
            // put it twelve points off the middle of its own arc.
            button.centerXAnchor.constraint(equalTo: dial.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: dial.centerYAnchor,
                                            constant: -SpeedometerView.centreLift),
            tiles.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tiles.heightAnchor.constraint(equalToConstant: 56),
            divider.widthAnchor.constraint(equalToConstant: 1),
            downTile.widthAnchor.constraint(equalTo: upTile.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
}

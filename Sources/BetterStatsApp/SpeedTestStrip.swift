import AppKit
import Network
import PowerKit

/// The Network tab's speed-test control: a button, a progress line, and the
/// result.
///
/// THIS IS THE ONLY CONTROL IN THE APP THAT SENDS DATA ANYWHERE, and the whole
/// design of it follows from that. `SpeedTest.swift` states the engine's side of
/// the bargain — user-initiated only, endpoint named, failure is nil rather than
/// zero — and this view is the half a person actually sees:
///
///  * **Nothing happens until the button is pressed.** No timer, no run on first
///    open, no "refresh while you are looking at the tab". Opening the Network
///    tab is not consent to transfer 47 MB.
///  * **The first press explains itself**, once, naming Cloudflare and the size
///    and the fact that they see your IP. `SpeedTestGate` owns that decision so
///    it is a rule rather than a layout, and so it can be tested.
///  * **A metered path asks every time.** Low Data Mode and personal hotspots
///    are the user having already said they want less traffic here; the answer
///    to that is not a silent 47 MB.
///  * **The host is on screen even when idle.** Who gets contacted should not be
///    something you have to press a button to discover.
final class SpeedTestStrip: NSView {

    /// Told when the strip's height changes, so the pane can resize it.
    var onLayoutChanged: (() -> Void)?

    /// Told when a test starts and stops, with the bytes it is about to move.
    ///
    /// The Network tab's own graph is about to show a spike that BetterStats
    /// caused, and the battery ledger is about to attribute the energy for it to
    /// BetterStats — correctly, and confusingly. A monitor that makes a mess of
    /// its own readings without saying so is the kind of quiet dishonesty this
    /// project exists to avoid.
    var onActivity: ((Bool) -> Void)?

    private let button = NSButton(title: "", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let resultLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    private var running = false
    /// Last result, kept only for as long as the app runs. Nothing is persisted:
    /// a speed test is a reading of one moment on one path, and a stale one
    /// presented as current would be a worse answer than no answer.
    private var lastResult: SpeedTest.Result?
    private var lastError: String?

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
        pathMonitor.start(queue: DispatchQueue(label: "dev.noah.betterstats.speedtest.path"))
        render()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { pathMonitor.cancel() }

    override func viewDidChangeEffectiveAppearance() { render() }

    // ── The one action ──────────────────────────────────────────────────────

    @objc private func runTapped() {
        guard !running else { return }
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
        statusLabel.stringValue = "Starting…"
        onActivity?(true)
        render()

        Task { [weak self] in
            do {
                let result = try await SpeedTest.run { fraction, phase in
                    // `progress` is documented as arriving on an arbitrary queue.
                    DispatchQueue.main.async {
                        self?.statusLabel.stringValue =
                            String(format: "%@ — %.0f%%", phase.capitalized, fraction * 100)
                    }
                }
                await MainActor.run { self?.finished(.success(result)) }
            } catch {
                await MainActor.run { self?.finished(.failure(error)) }
            }
        }
    }

    private func finished(_ outcome: Result<SpeedTest.Result, Error>) {
        running = false
        onActivity?(false)
        switch outcome {
        case .success(let r):
            lastResult = r
        case .failure(let error):
            // A failed test yields NO number. "0 Mbps" is a measurement, and we
            // did not make one — the same rule the ledger follows everywhere.
            lastError = (error as NSError).localizedDescription
        }
        render()
    }

    // ── Rendering ───────────────────────────────────────────────────────────

    private func render() {
        let host = SpeedTest.Endpoint.cloudflare.host
        button.isEnabled = !running
        button.title = running ? "Testing…" : "Test Internet Speed"

        if running {
            // statusLabel is owned by the progress callback while a test runs.
        } else if pathIsExpensive || pathIsConstrained {
            statusLabel.stringValue = pathIsConstrained
                ? "This network is in Low Data Mode — the test will ask before using data."
                : "This looks like a metered connection — the test will ask before using data."
        } else {
            statusLabel.stringValue = String(
                format: "Sends up to %.0f MB to and from %@. Only when you press the button.",
                Double(SpeedTestGate.worstCaseBytes) / 1e6, host)
        }

        if let r = lastResult {
            resultLabel.stringValue = String(
                format: "%.1f Mbps down · %.1f Mbps up · %.0f ms · %@  (%.0f MB moved)",
                r.downloadMbps, r.uploadMbps, r.latencyMs, r.host,
                Double(r.downloadBytes + r.uploadBytes) / 1e6)
            resultLabel.textColor = Palette.text
        } else if let why = lastError {
            resultLabel.stringValue = "No result — \(why)"
            resultLabel.textColor = Palette.dim
        } else {
            resultLabel.stringValue = ""
        }
        resultLabel.isHidden = resultLabel.stringValue.isEmpty

        statusLabel.textColor = Palette.dim
        onLayoutChanged?()
    }

    /// The height this strip needs, so the pane can give it exactly that.
    var preferredHeight: CGFloat { resultLabel.isHidden ? 46 : 66 }

    private func build() {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = Palette.Font.sans(11)
        button.target = self
        button.action = #selector(runTapped)

        statusLabel.font = Palette.Font.sans(10.5)
        statusLabel.lineBreakMode = .byTruncatingTail
        resultLabel.font = Palette.Font.mono(11)
        resultLabel.lineBreakMode = .byTruncatingTail

        let top = NSStackView(views: [button, statusLabel])
        top.orientation = .horizontal
        top.spacing = 10
        top.alignment = .centerY

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(top)
        stack.addArrangedSubview(resultLabel)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
        ])
    }
}

import AppKit
import PowerKit
import UniformTypeIdentifiers

// Memory Watch: the diagnostic window a "possible memory leak" notification opens.
//
// It costs nothing while it is closed (nothing here is built until a window is asked for) and almost nothing while it is
// open: it creates NO timer, thread, observer or polling loop. The watch feeds it, one `appendLive` per new reading of the
// flagged process, and the window redraws only when a point arrives AND somebody can see it (not covered, not minimised).
// A point that arrives while it is hidden is still kept (the graph is complete when it is looked at again), but nothing is
// drawn for it.
//
// All the words and numbers are built by `MemoryWatchWindowModel`, a plain value, so they are tested without a window.

// MARK: - The words and numbers

struct MemoryWatchWindowModel {

    /// Live points kept beyond the finding's own history: about 70 minutes at an 8 s cadence.
    static let maxLivePoints = 512
    static let heading = "Possible memory leak"
    static let whyHeading = "Why Anode flagged this"
    /// What a low-memory warning's window says in their place (`headingText` / `whyHeadingText` choose by the finding's tier).
    static let pressureHeading = "Memory is running low"
    static let pressureWhyHeading = "Why Anode warned you"
    static let pressureWindowTitle = "Memory Is Running Low"
    static let leakWindowTitle = "Possible Memory Leak"
    /// What a leak's window says once the memory has come back down (`recovered`).
    static let recoveredHeading = "Memory came back down"
    static let recoveredWhyHeading = "What Anode saw"
    static let recoveredWindowTitle = "Memory Came Back Down"
    static let historyUnavailableText = "History isn't available after Anode restarted."

    let finding: Finding
    let live: [MemorySample]
    let plan: MemoryWatchQuitPlan?
    /// The app's bundle id when it is known; the app's path stands in when it is not.
    let bundleID: String?
    let timeZone: TimeZone

    init(finding: Finding, live: [MemorySample] = [], plan: MemoryWatchQuitPlan? = nil, bundleID: String? = nil,
         timeZone: TimeZone = .current) {
        self.finding = finding
        self.live = live
        self.plan = plan
        self.bundleID = bundleID
        self.timeZone = timeZone
    }

    // MARK: Header

    /// A low-memory warning, not a leak: the numbers, the graph's title and the words around them differ.
    var isPressure: Bool { finding.tier == .pressure }
    /// A leak that is no longer one: its memory has fallen back to under the start plus half of what was flagged. Follows the
    /// newest point, so a window left open changes its words by itself.
    var recovered: Bool { finding.hasRecovered(currentBytes: nowBytes) }
    var headingText: String { isPressure ? Self.pressureHeading : (recovered ? Self.recoveredHeading : Self.heading) }
    var whyHeadingText: String { isPressure ? Self.pressureWhyHeading : (recovered ? Self.recoveredWhyHeading : Self.whyHeading) }
    var windowTitle: String { isPressure ? Self.pressureWindowTitle : (recovered ? Self.recoveredWindowTitle : Self.leakWindowTitle) }

    /// The app's name; a low-memory warning that found no app to name is about the Mac as a whole.
    var title: String { finding.name.isEmpty && isPressure ? "Your Mac" : finding.name }

    /// "WebContent · pid 4412 · com.apple.Safari"
    var detailLine: String {
        let process = (finding.path as NSString).lastPathComponent
        let name = process.isEmpty ? finding.name : process
        let place = bundleID ?? (finding.isApp ? finding.identityKey : finding.path)
        return "\(name) · pid \(finding.pid) · \(place)"
    }

    // MARK: Numbers

    /// The finding's own points, then the live ones that come after them, oldest first.
    var samples: [MemorySample] {
        var out = finding.history
        let last = out.last?.seconds ?? -Double.infinity
        out.append(contentsOf: live.filter { $0.seconds > last })
        return out
    }

    var nowBytes: UInt64 { samples.last?.bytes ?? finding.nowBytes }
    var nowText: String { MetricUnit.bytes.format(Double(nowBytes)) }

    /// "+412 MB (+29%)"
    var grewText: String {
        let percent = Int((finding.growthFraction * 100).rounded())
        return "+\(MetricUnit.bytes.format(Double(finding.netGrowthBytes))) (+\(percent)%)"
    }

    /// "over 75 s, since 14:03:22": the stretch the growth was measured over, and when it began.
    var grewDetail: String {
        // The fast tier measures in seconds ("over 75 s"); the slow one in hours ("over 2 hours 10 minutes").
        let seconds = Int(finding.windowSeconds.rounded())
        let span = finding.tier == .slow ? "over " + DurationText.text(seconds: finding.windowSeconds) : "over \(seconds) s"
        let began = finding.flaggedAtWall.addingTimeInterval(-finding.windowSeconds)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return "\(span), since \(formatter.string(from: began))"
    }

    /// "~5.5MB/s"
    var rateText: String {
        // A slow leak is a fraction of a megabyte a second, which reads better as a rate per hour.
        if finding.tier == .slow { return "~" + MetricUnit.bytes.format(finding.growthBytesPerSecond * 3600) + "/hour" }
        return "~" + MetricUnit.bytesPerSecond.format(finding.growthBytesPerSecond)
    }

    /// A share of the Mac's memory, whole percent ("11%"); "<1%" for a sliver and a dash when the total is not known.
    private static func percentText(_ part: UInt64, of total: UInt64) -> String {
        guard total > 0 else { return "\u{2014}" }
        let percent = Double(part) / Double(total) * 100
        return percent > 0 && percent < 1 ? "<1%" : "\(Int(percent.rounded()))%"
    }

    /// A low-warning's second number: the app's memory as a share of all of the Mac's.
    var ofRAMText: String { Self.percentText(nowBytes, of: finding.system?.totalBytes ?? 0) }
    /// A low-warning's third number: how much memory is swapped out to the disk.
    var swapText: String { finding.system.map { MetricUnit.bytes.format(Double($0.swapUsedBytes)) } ?? "\u{2014}" }

    var stats: [(label: String, value: String)] {
        if isPressure { return [("Now", nowText), ("Of your RAM", ofRAMText), ("Swap", swapText)] }
        return [("Now", nowText), ("Grew", grewText), ("Rate", rateText)]
    }

    /// The number shown in the warning colour (a leak's growth); a low-memory warning has none.
    var emphasizedStat: Int? { isPressure ? nil : 1 }

    /// The line under the numbers: for a leak how long it grew and since when; for a low-memory warning the Mac as a whole
    /// ("Mac: 91% of memory in use").
    var underStatsLine: String {
        guard isPressure else { return grewDetail }
        guard let system = finding.system else { return "" }
        return "Mac: \(Self.percentText(system.usedBytes, of: system.totalBytes)) of memory in use"
    }

    // MARK: Graph

    var historyUnavailable: Bool { finding.history.isEmpty }

    private func date(forAwake seconds: Double) -> Date {
        finding.flaggedAtWall.addingTimeInterval(seconds - finding.flaggedAtAwake)
    }

    private static func gigabytes(_ bytes: UInt64) -> Double { Double(bytes) / 1_073_741_824 }

    private func point(_ s: MemorySample) -> HistoryGraphView.Point {
        // Tick labels print the plotted number with %g, so the axis is in GB and the readout carries the sentence.
        HistoryGraphView.Point(time: date(forAwake: s.seconds), value: Self.gigabytes(s.bytes),
                               detail: MetricUnit.bytes.format(Double(s.bytes)))
    }

    /// Every point, in GB.
    var memoryPoints: [HistoryGraphView.Point] { samples.map(point) }

    /// What the graph's line is called: the app's own memory for a low-memory warning.
    var graphSeriesName: String { isPressure ? "\(finding.name) memory (GB)" : "Memory (GB)" }

    /// The points inside the window the verdict rested on, drawn over the line in the warning colour. None for a low-memory
    /// warning: there is no growth span to mark.
    var flaggedPoints: [HistoryGraphView.Point] {
        guard !isPressure else { return [] }
        let start = finding.flaggedAtAwake - finding.windowSeconds
        return samples.filter { $0.seconds >= start && $0.seconds <= finding.flaggedAtAwake }.map(point)
    }

    // MARK: Explanation

    var explanation: String {
        guard recovered else { return finding.explanation }
        return "Its memory grew \(MetricUnit.bytes.format(Double(finding.netGrowthBytes))) and has since fallen back to "
            + "\(nowText). A leak keeps what it takes, so this is probably not a leak: work that finished, or memory the app "
            + "gave back. Anode only reads memory sizes, and will not flag this process again."
    }

    /// A low-memory warning only: what Quit does to the work in the app. (A leak's window does not have this line.)
    var explanationHint: String? {
        guard isPressure else { return nil }
        return wholeApp ? "Quit App closes the whole app; save your work first"
                        : "Quit Process asks only this process to quit; save your work first"
    }

    /// Said when the app has several processes, so "Quit App" is not a surprise.
    var processesLine: String? {
        guard finding.isApp, let plan, plan.totalProcessCount > 1 else { return nil }
        let which = isPressure ? "The largest is" : "The one growing is"
        return "\(finding.name) has \(plan.totalProcessCount) processes running. \(which) pid \(finding.pid)."
    }

    // MARK: Buttons

    var wholeApp: Bool { finding.isApp }
    var quitTitle: String { wholeApp ? "Quit App" : "Quit Process" }
    var forceQuitTitle: String { wholeApp ? "Force Quit App" : "Force Quit Process" }

    private var processesPhrase: String? {
        guard let n = plan?.processCount, n > 0 else { return nil }
        return n == 1 ? "its 1 process" : "all \(n) processes"
    }

    /// Beside the Quit button: says what it reaches, the whole app or one process.
    var quitCaption: String {
        if wholeApp {
            return "Asks the whole app to quit" + (processesPhrase.map { ": \($0)." } ?? ", every process of it.")
        }
        return "Asks only this one process (pid \(finding.pid)) to quit. Nothing else is touched."
    }

    /// Beside the Force Quit button.
    var forceQuitCaption: String {
        if wholeApp {
            return "Kills the whole app" + (processesPhrase.map { ": \($0)." } ?? ", every process of it.")
        }
        return "Kills only this one process (pid \(finding.pid)). Nothing else is touched."
    }

    /// Both buttons wait for the plan, and stay off when there is nothing Anode may signal.
    var buttonsEnabled: Bool { plan?.canAct ?? false }

    /// The reason a button is off, or what is partly refused; empty when there is nothing to say.
    var planNote: String { plan?.explanation ?? "" }
    /// True when `planNote` is the reason the buttons are off.
    var planNoteIsProblem: Bool { plan.map { !$0.canAct } ?? false }

    // MARK: Links

    var ignoreTitle: String { "Don't warn about \(finding.name)" }
    var ignoredLine: String { "Anode won't warn about \(finding.name) again." }
    static let showInProcessesTitle = "Show in Processes"
}

// MARK: - The window

protocol MemoryWatchWindowing: AnyObject {
    var onClose: (() -> Void)? { get set }
    func show()
    func update(with finding: Finding)
    /// A live point. Always kept; drawn only while the window can be seen.
    func appendLive(_ sample: MemorySample)
    /// The watch's own record of the process since the finding, handed over when the window opens: a window opened minutes
    /// after the finding would otherwise show a gap between the finding's history and the live points.
    func setHistory(_ samples: [MemorySample])
    func close()
}

final class MemoryWatchWindowController: NSWindowController, NSWindowDelegate, MemoryWatchWindowing {

    /// How long after a Quit click the one "is it still running?" check happens.
    static let stillRunningDelay: TimeInterval = 10
    /// A plain tool exits the moment it is asked to, so the first look comes early; the rest of the ten seconds is the
    /// second look. Two one-shot calls fired by the click, and no more.
    static let firstLookDelay: TimeInterval = 1.5
    private static let width: CGFloat = 600

    var onClose: (() -> Void)?

    private(set) var finding: Finding
    /// Live points beyond the finding's history, oldest first, at most `MemoryWatchWindowModel.maxLivePoints`.
    private(set) var liveSamples: [MemorySample] = []
    /// How many times a live point caused a redraw. A point that arrives while the window is hidden adds nothing.
    private(set) var liveRedraws = 0
    private(set) var plan: MemoryWatchQuitPlan?
    private(set) var isClosed = false
    /// The text under the buttons.
    var statusLine: String { statusLabel.stringValue }
    /// The text beside each button.
    var captions: (quit: String, forceQuit: String) { (quitCaption.stringValue, forceQuitCaption.stringValue) }
    var buttonTitles: (quit: String, forceQuit: String) { (quitButton.title, forceQuitButton.attributedTitle.string) }
    var buttonsAreEnabled: (quit: Bool, forceQuit: Bool) { (quitButton.isEnabled, forceQuitButton.isEnabled) }

    /// Whether anyone can see the window right now: not covered, not minimised. A property so a test can say so without
    /// a window server.
    var isDrawable: () -> Bool = { false }

    private var ignoreApp: ((String) -> Void)?
    private var showInProcesses: ((Finding) -> Void)?
    private let quitter: MemoryWatchQuitting
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let appIdentity: (Finding) -> (icon: NSImage, bundleID: String?)
    private var bundleID: String?

    private var status: (text: String, ok: Bool)?
    /// A polite quit was asked for and has not been seen to fail.
    private var quitRequested = false
    private var isActing = false
    private var ignored = false
    /// Bumped by every request for a plan, so a late answer to an old request is dropped.
    private var planGeneration = 0

    // Views
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: MemoryWatchWindowModel.heading)
    /// Set when the window was last sized for a low-memory warning (its explanation has one more line).
    private var sizedForPressure = false
    private var contentStack: NSStackView?
    private let detailLabel = NSTextField(labelWithString: "")
    private let statTitles = ["Now", "Grew", "Rate"].map { NSTextField(labelWithString: $0) }
    private let statValues = [NSTextField(labelWithString: ""), NSTextField(labelWithString: ""),
                              NSTextField(labelWithString: "")]
    private let grewDetailLabel = NSTextField(labelWithString: "")
    private let graph = FixedWindowGraphView(frame: .zero)
    private let historyNote = NSTextField(wrappingLabelWithString: MemoryWatchWindowModel.historyUnavailableText)
    private let whyHeader = NSTextField(labelWithString: MemoryWatchWindowModel.whyHeading.uppercased())
    private let whyBody = NSTextField(wrappingLabelWithString: "")
    /// The one-line hint a low-memory warning adds under the explanation; hidden for a leak.
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let processesLabel = NSTextField(wrappingLabelWithString: "")
    private let quitButton = NSButton(title: "", target: nil, action: nil)
    private let forceQuitButton = NSButton(title: "", target: nil, action: nil)
    private let quitCaption = NSTextField(wrappingLabelWithString: "")
    private let forceQuitCaption = NSTextField(wrappingLabelWithString: "")
    private let ignoreButton = NSButton(title: "", target: nil, action: nil)
    private let showButton = NSButton(title: "", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    init(finding: Finding,
         ignoreApp: @escaping (String) -> Void,
         showInProcesses: @escaping (Finding) -> Void,
         quitter: MemoryWatchQuitting = MemoryWatchQuitter.live(),
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) { work() }
         },
         appIdentity: @escaping (Finding) -> (icon: NSImage, bundleID: String?) = MemoryWatchWindowController.liveAppIdentity) {
        self.finding = finding
        self.ignoreApp = ignoreApp
        self.showInProcesses = showInProcesses
        self.quitter = quitter
        self.schedule = schedule
        self.appIdentity = appIdentity
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = MemoryWatchWindowModel.leakWindowTitle
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        isDrawable = { [weak self] in
            guard let w = self?.window else { return false }
            return w.occlusionState.contains(.visible) && !w.isMiniaturized
        }
        buildLayout()
        let identity = appIdentity(finding)
        iconView.image = identity.icon
        bundleID = identity.bundleID
        refreshAll()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: MemoryWatchWindowing

    func show() {
        isClosed = false
        showWindow(nil)
        window?.bringForward()
        refreshAll()
        requestPlan()
    }

    func update(with finding: Finding) {
        guard !isClosed else { return }
        if finding.processKey != self.finding.processKey { liveSamples.removeAll() }
        if finding.identityKey != self.finding.identityKey { ignored = false }
        self.finding = finding
        let identity = appIdentity(finding)
        iconView.image = identity.icon
        bundleID = identity.bundleID
        plan = nil
        status = nil
        refreshAll()
        requestPlan()
    }

    func appendLive(_ sample: MemorySample) {
        guard !isClosed else { return }
        liveSamples.append(sample)
        let extra = liveSamples.count - MemoryWatchWindowModel.maxLivePoints
        if extra > 0 { liveSamples.removeFirst(extra) }
        // Kept either way; drawn only when somebody can see it.
        guard isDrawable() else { return }
        liveRedraws += 1
        refreshAll()
    }

    func setHistory(_ samples: [MemorySample]) {
        guard !isClosed, !samples.isEmpty else { return }
        liveSamples = samples
        let extra = liveSamples.count - MemoryWatchWindowModel.maxLivePoints
        if extra > 0 { liveSamples.removeFirst(extra) }
        guard isDrawable() else { return }
        liveRedraws += 1
        refreshAll()
    }

    override func close() {
        guard !isClosed else { return }
        window?.close()
        finishClosing()
    }

    func windowWillClose(_ notification: Notification) { finishClosing() }

    /// Idempotent: the window's own close and `close()` both end here, and `onClose` fires once.
    private func finishClosing() {
        guard !isClosed else { return }
        isClosed = true
        planGeneration += 1
        liveSamples.removeAll()
        plan = nil
        status = nil
        isActing = false
        graph.series = []
        onClose?()
    }

    // MARK: Plan and clicks

    private func requestPlan() {
        planGeneration += 1
        let generation = planGeneration
        quitter.plan(for: finding) { [weak self] plan in
            guard let self, !self.isClosed, generation == self.planGeneration else { return }
            self.plan = plan
            self.refreshAll()
        }
    }

    // Not private: the tests press the buttons through these, without a window on screen.
    @objc func quitClicked() { act(force: false) }
    @objc func forceQuitClicked() { act(force: true) }

    /// The plan is worked out again at the click, with the start-time check, so a process that exited in the meantime (or
    /// whose pid was reused) is never signalled on the strength of what the window showed a minute ago.
    private func act(force: Bool) {
        guard !isActing, !isClosed else { return }
        isActing = true
        planGeneration += 1
        let generation = planGeneration
        refreshAll()
        quitter.plan(for: finding) { [weak self] fresh in
            guard let self, !self.isClosed, generation == self.planGeneration else { return }
            self.plan = fresh
            guard fresh.canAct else {
                // Asked to quit a moment ago and gone now: that is the quit working, not an error.
                if fresh.alreadyGone, self.quitRequested {
                    self.status = (MemoryWatchQuitter.closedLine, true)
                } else {
                    self.status = (fresh.explanation.isEmpty ? "Nothing to quit" : fresh.explanation, false)
                }
                self.isActing = false
                self.refreshAll()
                return
            }
            let line = self.quitter.perform(fresh, force: force)
            self.status = (line, true)
            self.isActing = false
            self.refreshAll()
            if !force, line.hasPrefix(MemoryWatchQuitter.quitRequestedLine) {
                self.quitRequested = true
                self.scheduleStillRunningCheck(fresh)
            }
        }
    }

    /// Two looks, both fired by the click that asked to quit: an early one (a plain tool is usually gone at once) and one at
    /// the ten second mark. No timer is kept and nothing polls.
    private func scheduleStillRunningCheck(_ plan: MemoryWatchQuitPlan) {
        look(plan, after: Self.firstLookDelay, final: false)
    }

    private func look(_ plan: MemoryWatchQuitPlan, after delay: TimeInterval, final: Bool) {
        schedule(delay) { [weak self] in
            guard let self, !self.isClosed else { return }
            self.quitter.isStillRunning(plan) { [weak self] running in
                guard let self, !self.isClosed else { return }
                if !running {
                    self.status = (MemoryWatchQuitter.closedLine, true)
                    self.refreshAll()
                    self.requestPlan()
                } else if final {
                    self.status = (MemoryWatchQuitter.stillRunningLine, false)
                    self.refreshAll()
                } else {
                    self.look(plan, after: Self.stillRunningDelay - Self.firstLookDelay, final: true)
                }
            }
        }
    }

    @objc func ignoreClicked() {
        guard !ignored, !isClosed else { return }
        ignored = true
        ignoreApp?(finding.identityKey)
        status = (makeModel().ignoredLine, true)
        refreshAll()
    }

    @objc func showClicked() { showInProcesses?(finding) }

    // MARK: Drawing

    private func makeModel() -> MemoryWatchWindowModel {
        MemoryWatchWindowModel(finding: finding, live: liveSamples, plan: plan, bundleID: bundleID)
    }

    private func refreshAll() {
        guard !isClosed else { return }
        let model = makeModel()
        window?.contentView?.layer?.backgroundColor = Palette.background.cgColor

        titleLabel.stringValue = model.title
        titleLabel.textColor = Palette.text
        badgeLabel.stringValue = model.headingText
        badgeLabel.textColor = model.recovered ? Palette.dim : Palette.warn
        if window?.title != model.windowTitle { window?.title = model.windowTitle }
        detailLabel.stringValue = model.detailLine
        detailLabel.textColor = Palette.faint

        for (i, stat) in model.stats.enumerated() {
            statTitles[i].stringValue = stat.label
            statTitles[i].textColor = Palette.faint
            statValues[i].stringValue = stat.value
            statValues[i].textColor = i == model.emphasizedStat ? Palette.warn : Palette.text
        }
        grewDetailLabel.stringValue = model.underStatsLine
        grewDetailLabel.textColor = Palette.faint

        graph.isHidden = model.historyUnavailable
        historyNote.isHidden = !model.historyUnavailable
        historyNote.textColor = Palette.dim
        if !model.historyUnavailable {
            var series = [HistoryGraphView.Series(name: model.graphSeriesName, color: Palette.accent, points: model.memoryPoints)]
            // The span the verdict rested on is a leak's; a low-memory warning has none to mark.
            if !model.isPressure {
                series.append(HistoryGraphView.Series(name: "Flagged span", color: Palette.warn, points: model.flaggedPoints))
            }
            graph.series = series
        }

        whyHeader.stringValue = model.whyHeadingText.uppercased()
        whyHeader.textColor = Palette.accent
        whyBody.stringValue = model.explanation
        whyBody.textColor = Palette.dim
        hintLabel.stringValue = model.explanationHint ?? ""
        hintLabel.isHidden = model.explanationHint == nil
        hintLabel.textColor = Palette.dim
        processesLabel.stringValue = model.processesLine ?? ""
        processesLabel.isHidden = model.processesLine == nil
        processesLabel.textColor = Palette.dim

        quitButton.title = model.quitTitle
        forceQuitButton.attributedTitle = NSAttributedString(
            string: model.forceQuitTitle,
            attributes: [.foregroundColor: NSColor.white, .font: Palette.Font.sans(13, .semibold)])
        forceQuitButton.bezelColor = Palette.critical
        let enabled = model.buttonsEnabled && !isActing
        quitButton.isEnabled = enabled
        forceQuitButton.isEnabled = enabled
        quitCaption.stringValue = model.quitCaption
        forceQuitCaption.stringValue = model.forceQuitCaption
        quitCaption.textColor = Palette.dim
        forceQuitCaption.textColor = Palette.dim

        ignoreButton.attributedTitle = Self.link(model.ignoreTitle)
        ignoreButton.isEnabled = !ignored
        showButton.attributedTitle = Self.link(MemoryWatchWindowModel.showInProcessesTitle)

        if let status {
            statusLabel.stringValue = status.text
            statusLabel.textColor = status.ok ? Palette.dim : Palette.warn
        } else {
            statusLabel.stringValue = model.planNote
            statusLabel.textColor = model.planNoteIsProblem ? Palette.warn : Palette.dim
        }
        // A low-memory warning has one more line (the hint): the window is sized again when the kind changes, and a leak's is
        // never touched.
        if model.isPressure != sizedForPressure {
            sizedForPressure = model.isPressure
            resizeToFit()
        }
    }

    private func resizeToFit() {
        guard let content = window?.contentView, let stack = contentStack else { return }
        content.layoutSubtreeIfNeeded()
        window?.setContentSize(NSSize(width: Self.width, height: ceil(stack.fittingSize.height) + 24))
    }

    private static func link(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .foregroundColor: Palette.accent,
            .font: Palette.Font.sans(12),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
    }

    // MARK: Layout

    private func buildLayout() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 48),
            iconView.heightAnchor.constraint(equalToConstant: 48),
        ])
        titleLabel.font = Palette.Font.sans(20, .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        badgeLabel.font = Palette.Font.sans(12, .semibold)
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailLabel.font = Palette.Font.mono(11)
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleStack = Self.stack([titleLabel, detailLabel], .vertical, spacing: 2)
        titleStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = Self.stack([iconView, titleStack, badgeLabel], .horizontal, spacing: 12)
        header.alignment = .centerY

        var columns: [NSView] = []
        for i in 0..<3 {
            statTitles[i].font = Palette.Font.sans(11)
            statValues[i].font = Palette.Font.mono(20, .semibold)
            columns.append(Self.stack([statTitles[i], statValues[i]], .vertical, spacing: 2))
        }
        let statsRow = Self.stack(columns, .horizontal, spacing: 24)
        statsRow.distribution = .fillEqually
        grewDetailLabel.font = Palette.Font.sans(11)

        graph.showsGrid = true
        graph.bridgesGaps = false
        graph.yAxisLabel = "GB"
        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.heightAnchor.constraint(equalToConstant: 170).isActive = true
        historyNote.font = Palette.Font.sans(12)

        whyHeader.font = Palette.Font.sans(11, .semibold)
        whyBody.font = Palette.Font.sans(12)
        processesLabel.font = Palette.Font.sans(12)

        let quitRow = Self.buttonRow(quitButton, quitCaption)
        let forceRow = Self.buttonRow(forceQuitButton, forceQuitCaption)
        for button in [quitButton, forceQuitButton] {
            button.bezelStyle = .rounded
            button.controlSize = .large
            button.target = self
        }
        quitButton.action = #selector(quitClicked)
        forceQuitButton.action = #selector(forceQuitClicked)
        forceQuitButton.hasDestructiveAction = true
        for caption in [quitCaption, forceQuitCaption] { caption.font = Palette.Font.sans(12) }

        for button in [ignoreButton, showButton] {
            button.isBordered = false
            button.target = self
        }
        ignoreButton.action = #selector(ignoreClicked)
        showButton.action = #selector(showClicked)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let links = Self.stack([ignoreButton, spacer, showButton], .horizontal, spacing: 8)

        statusLabel.font = Palette.Font.sans(11)
        statusLabel.maximumNumberOfLines = 3

        hintLabel.font = Palette.Font.sans(12)
        hintLabel.isHidden = true       // only a low-memory warning has it: a leak's window is laid out as it always was

        let rows: [NSView] = [header, statsRow, grewDetailLabel, graph, historyNote, whyHeader, whyBody, hintLabel,
                              processesLabel, quitRow, forceRow, statusLabel, links]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(18, after: grewDetailLabel)
        stack.setCustomSpacing(18, after: historyNote)
        stack.setCustomSpacing(20, after: processesLabel)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentStack = stack
        content.addSubview(stack)
        let inner = Self.width - 40
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
        ])
        for view in rows { view.widthAnchor.constraint(equalToConstant: inner).isActive = true }
        for label in [historyNote, whyBody, hintLabel, processesLabel, statusLabel, quitCaption, forceQuitCaption] {
            label.preferredMaxLayoutWidth = inner
        }
        quitCaption.preferredMaxLayoutWidth = inner - 210
        forceQuitCaption.preferredMaxLayoutWidth = inner - 210

        content.layoutSubtreeIfNeeded()
        // The room the longest text will need is allowed for, since the window is not resizable.
        window?.setContentSize(NSSize(width: Self.width, height: ceil(stack.fittingSize.height) + 24))
    }

    private static func stack(_ views: [NSView], _ axis: NSUserInterfaceLayoutOrientation,
                              spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = axis
        s.alignment = axis == .vertical ? .leading : .centerY
        s.spacing = spacing
        return s
    }

    /// A large button with its one-line caption beside it.
    private static func buttonRow(_ button: NSButton, _ caption: NSTextField) -> NSStackView {
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 200),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])
        return stack([button, caption], .horizontal, spacing: 10)
    }

    // MARK: Live lookups

    /// The app's icon and bundle id from the running app (LaunchServices already knows it), not from files on disk:
    /// reading a bundle's files could raise a consent prompt for a folder it sits in.
    static func liveAppIdentity(for finding: Finding) -> (icon: NSImage, bundleID: String?) {
        guard finding.isApp else { return (NSWorkspace.shared.icon(for: .unixExecutable), nil) }
        let own = NSRunningApplication(processIdentifier: finding.pid)
        let app = own?.bundleURL?.path == finding.identityKey
            ? own
            : NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == finding.identityKey }
        return (app?.icon ?? NSWorkspace.shared.icon(for: .applicationBundle), app?.bundleIdentifier)
    }
}

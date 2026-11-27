import Foundation
import PowerKit

// ── Memory Watch (Beta Features): the app side ──────────────────────────────
//
// PowerKit's `MemoryWatch` does the detecting; this joins it to the app: the settings, the notifications, the diagnostic
// windows and the feed of live points to an open window.
//
// Two boxes in Beta Features switch it on: leak detection (`memoryWatchEnabled`) and the high-memory warning
// (`memoryWatchPressureWarning`). The feature is on when EITHER is ticked, and one watch serves both (`setModes`).
//
// OFF MEANS NOTHING EXISTS. While both settings are off the controller holds two `Settings.observe` tokens and nothing else:
// no watch, no findings, no window, no notification delegate, and it makes no call to the notifier. There is no timer,
// thread or observer of its own at any time: the watch is fed by the app's existing sampling tick (`MemoryWatchHook`), and
// the one system memory reading is made on that tick only while the high-memory warning is switched on.
//
// THREADS. The controller lives on the main thread. The watch lives on the sampling queue and is touched only inside
// `onSampling` blocks (the `watch` property below is confined to that queue); what it reports comes back to main through
// `onMain`. In the app both are the real queues; in the tests both run at once.

/// What the controller and the sampling tick need of a watch. `MemoryWatch` is the real one; a test makes its own.
protocol MemoryWatching: AnyObject {
    var onFinding: (Finding) -> Void { get set }
    var onLivePoint: ((ProcessKey, MemorySample) -> Void)? { get set }
    func ingest(sweep: ProcessSampler.Sweep, awake: TimeInterval)
    func probe(awake: TimeInterval, wall: Date)
    /// True while the high-memory warning is switched on: only then does the tick read the system's memory.
    var watchesPressure: Bool { get }
    /// Which of the two jobs the watch does. Called on the sampling queue.
    func setModes(leaks: Bool, pressure: Bool)
    /// One reading of how full the Mac's memory is (nil when it could not be read), once per tick.
    func ingestSystem(_ reading: SystemMemoryReading?, awake: TimeInterval, wall: Date)
    func pin(_ key: ProcessKey)
    func unpin(_ key: ProcessKey)
    func setLive(_ keys: Set<ProcessKey>)
    func ignore(identityKey: String)
    /// What the watch has recorded of one process (empty once it has let the process go).
    func samples(of key: ProcessKey) -> [MemorySample]
}

extension MemoryWatch: MemoryWatching {}

/// The one thing the sampling tick does for Memory Watch: a full tick hands over the sweep it just made (the watch ignores
/// one it already had), a light tick has the watch re-read its candidates. Then, only while the high-memory warning is on,
/// one reading of the system's memory (an unprivileged read of sizes, nothing started) goes to the watch.
enum MemoryWatchHook {
    static func feed(_ watch: MemoryWatching, sweep: ProcessSampler.Sweep?, awake: TimeInterval, wall: Date,
                     readSystem: () -> SystemMemoryReading? = { SystemMemoryReader.read() }) {
        if let sweep {
            watch.ingest(sweep: sweep, awake: awake)
        } else {
            watch.probe(awake: awake, wall: wall)
        }
        if watch.watchesPressure {
            watch.ingestSystem(readSystem(), awake: awake, wall: wall)
        }
    }
}

final class MemoryWatchController {

    /// The running controller, for the Beta Features section to read.
    static weak var current: MemoryWatchController?
    /// Posted (on the main thread) when the findings or the notification status changed.
    static let didChange = Notification.Name("MemoryWatchController.didChange")
    /// How many findings are kept for the list in Beta Features.
    static let maxFindings = 10

    private let settings: Settings
    private let notifier: LeakNotifying
    private let makeWatch: () -> MemoryWatching
    /// Runs a block on the sampling queue, after what was handed to it before.
    private let onSampling: (@escaping () -> Void) -> Void
    /// Hands the watch to the sampling tick (nil takes it away). Called on the sampling queue.
    private let attach: (MemoryWatching?) -> Void
    private let makeWindow: (Finding) -> MemoryWatchWindowing
    private let isSandboxed: () -> Bool
    private let bringForward: () -> Void
    private let onMain: (@escaping () -> Void) -> Void

    /// One per setting; held for the controller's whole life (and nothing else is, while both boxes are off).
    private var tokens: [AnyObject] = []

    /// On when either box is ticked.
    private(set) var isEnabled = false
    /// The two jobs as last handed to the watch (main thread); toggling a box sends the change, never a new watch.
    private var modes: (leaks: Bool, pressure: Bool) = (false, false)
    /// The newest first, at most `maxFindings`. Memory only: gone with the process, and gone when the feature is turned off.
    private(set) var findings: [Finding] = []
    /// What macOS says about banners, as last read; nil until the first answer.
    private(set) var authorization: LeakAuthorization?

    private struct OpenWindow {
        let window: MemoryWatchWindowing
        /// The processes the window is following (pinned in the watch, and fed live): the one it was opened on, and any
        /// other process of the same app flagged since.
        var processKeys: Set<ProcessKey>
    }
    /// One window per window key (`Finding.windowKey`).
    private var windows: [String: OpenWindow] = [:]

    /// The watch. Touched ONLY on the sampling queue (inside `onSampling` blocks); the sampling tick has its own reference
    /// through `attach`. Nothing the watch holds points back at it.
    private var watch: MemoryWatching?

    /// - Parameters:
    ///   - makeWatch: builds the watch; called on the sampling queue, each time the feature is turned on.
    ///   - onSampling: `{ sampling.async(execute: $0) }` in the app.
    ///   - attach: gives the sampling tick the watch it feeds; `{ self.leakWatch = $0 }` in the app.
    ///   - makeWindow: builds a diagnostic window for a finding (not shown until asked).
    ///   - isSandboxed: the install-test copy of the app: it never asks macOS for anything.
    ///   - bringForward: what a click on an old banner does when nothing is left to show (after a relaunch the findings are
    ///     gone): brings Anode forward, and no more.
    ///   - onMain: `{ DispatchQueue.main.async(execute: $0) }` in the app.
    init(settings: Settings, notifier: LeakNotifying,
         makeWatch: @escaping () -> MemoryWatching,
         onSampling: @escaping (@escaping () -> Void) -> Void,
         attach: @escaping (MemoryWatching?) -> Void,
         makeWindow: @escaping (Finding) -> MemoryWatchWindowing,
         isSandboxed: @escaping () -> Bool = { AppSandbox.isOn },
         bringForward: @escaping () -> Void = {},
         onMain: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.settings = settings
        self.notifier = notifier
        self.makeWatch = makeWatch
        self.onSampling = onSampling
        self.attach = attach
        self.makeWindow = makeWindow
        self.isSandboxed = isSandboxed
        self.bringForward = bringForward
        self.onMain = onMain
        // Fire on the main thread, at once when the write was made there.
        for key in [Settings.Key.memoryWatchEnabled, Settings.Key.memoryWatchPressureWarning] {
            tokens.append(settings.observe(key) { [weak self] in self?.settingsChanged() })
        }
        // A feature that was left on is on again at launch, and the delegate is set then so that a click on a banner that
        // launched Anode is still delivered. Authorization is only READ here, never asked for.
        if wantedModes.leaks || wantedModes.pressure { enable() }
    }

    private var wantedModes: (leaks: Bool, pressure: Bool) {
        (settings.memoryWatchEnabled, settings.memoryWatchPressureWarning)
    }

    private func settingsChanged() {
        let wanted = wantedModes
        guard wanted.leaks || wanted.pressure else { disable(); return }
        if !isEnabled {
            enable()
        } else if wanted != modes {
            // One box changed while the other stays on: the same watch is told, not rebuilt.
            modes = wanted
            onSampling { [weak self] in self?.watch?.setModes(leaks: wanted.leaks, pressure: wanted.pressure) }
        }
    }

    // ── On and off ──────────────────────────────────────────────────────────

    private func enable() {
        guard !isEnabled else { return }
        isEnabled = true
        notifier.installDelegate { [weak self] key in self?.open(windowKey: key) }
        installWatch()
        refreshAuthorization()
    }

    private func disable() {
        guard isEnabled else { return }
        isEnabled = false
        modes = (false, false)
        // Every reference to the watch goes: this one, and the sampling tick's.
        let attach = self.attach
        onSampling { [weak self] in
            self?.watch = nil
            attach(nil)
        }
        let closing = windows.values.map { $0.window }
        windows.removeAll()
        for window in closing {
            window.onClose = nil     // closing them here must not reach back into a watch that is gone
            window.close()
        }
        findings.removeAll()
        authorization = nil
        notifier.removeAllDelivered()
        notifier.removeDelegate()
        postChange()
    }

    /// Ends the controller's part with the app: its windows close. Banners already delivered stay, so a click on one after
    /// the next launch still finds Anode.
    func shutdown() {
        tokens.removeAll()
        let closing = windows.values.map { $0.window }
        windows.removeAll()
        for window in closing {
            window.onClose = nil
            window.close()
        }
        if MemoryWatchController.current === self { MemoryWatchController.current = nil }
    }

    /// Makes a new watch on the sampling queue, replacing any there, and gives it what is open now (the pins and the live
    /// feed of every open window).
    private func installWatch() {
        let pins = followedKeys
        let relay: ((ProcessKey, MemorySample) -> Void)? = windows.isEmpty ? nil : livePointRelay()
        let attach = self.attach
        let wanted = wantedModes
        modes = wanted
        onSampling { [weak self] in
            guard let self else { return }
            let fresh = self.makeWatch()
            fresh.setModes(leaks: wanted.leaks, pressure: wanted.pressure)
            fresh.onFinding = { [weak self] finding in
                guard let self else { return }
                self.onMain { [weak self] in self?.handle(finding: finding) }
            }
            for key in pins { fresh.pin(key) }
            fresh.setLive(pins)
            fresh.onLivePoint = relay
            self.watch = fresh
            attach(fresh)
        }
    }

    // ── Findings ────────────────────────────────────────────────────────────

    /// A finding from the watch, on the main thread. It is listed whether or not it earns a banner; a window already open
    /// for it is given the newer one; a banner is posted when it should and macOS allows it.
    func handle(finding: Finding) {
        guard isEnabled else { return }     // a hop that landed after the feature was turned off
        // ... or after the box for this kind of finding was unticked while the other stays on.
        let kindIsOn = finding.tier == .pressure ? modes.pressure : modes.leaks
        guard kindIsOn else { return }
        withdrawn.remove(finding.windowKey)     // a fresh finding for the key is a new story
        // One low-memory row: a repeat, or the critical alert after the warning, replaces it. Added each time, the two-minute
        // repeats would push real leak findings out of the list, and their badge in the Processes table with them.
        if finding.tier == .pressure { findings.removeAll { $0.tier == .pressure } }
        findings.insert(finding, at: 0)
        if findings.count > Self.maxFindings { findings.removeLast(findings.count - Self.maxFindings) }
        adopt(finding)
        postChange()
        guard finding.shouldNotify, !isSandboxed() else { return }
        // Read each time: the person can switch Anode's notifications on or off in System Settings at any moment.
        notifier.authorizationStatus { [weak self] status in
            guard let self, self.isEnabled else { return }
            self.setAuthorization(status)
            if status == .authorized { self.notifier.post(finding) }
        }
    }

    /// An open window for the finding's key shows the newer finding, and follows the flagged process too.
    private func adopt(_ finding: Finding) {
        let key = finding.windowKey
        guard var entry = windows[key] else { return }
        entry.window.update(with: finding)
        if !entry.processKeys.contains(finding.processKey) {
            entry.processKeys.insert(finding.processKey)
            windows[key] = entry
            syncWatch(pin: [finding.processKey], unpin: [])
        }
    }

    // ── Windows ─────────────────────────────────────────────────────────────

    /// A click on a banner (or on Open in the list): the window for this key comes forward, built first if there is none.
    ///
    /// The key is an app's identity key or a tool's `pid:start`. A finding that is still in the list gives the window its
    /// numbers and graph. After a relaunch the list is empty: there is nothing to draw (the graph's points were never
    /// written anywhere), so Anode is brought forward and that is all.
    func open(windowKey key: String) {
        guard isEnabled else { return }
        notifier.removeDelivered(forKey: key)
        if let entry = windows[key] {
            entry.window.show()
            return
        }
        guard let finding = findings.first(where: { $0.windowKey == key }) else {
            bringForward()
            return
        }
        let window = makeWindow(finding)
        window.onClose = { [weak self] in self?.windowClosed(key) }
        windows[key] = OpenWindow(window: window, processKeys: [finding.processKey])
        window.show()
        syncWatch(pin: [finding.processKey], unpin: [])
        // Fill in what happened between the finding and now, so the graph has no gap. Read on the sampling queue, which owns
        // the watch.
        let processKey = finding.processKey
        onSampling { [weak self] in
            guard let watch = self?.watch else { return }
            let recorded = watch.samples(of: processKey)
            self?.onMain { self?.windows[key]?.window.setHistory(recorded) }
        }
    }

    private func windowClosed(_ key: String) {
        guard let entry = windows.removeValue(forKey: key) else { return }
        entry.window.onClose = nil
        syncWatch(pin: [], unpin: entry.processKeys)
    }

    var openWindowKeys: Set<String> { Set(windows.keys) }

    /// Every process an open window follows.
    private var followedKeys: Set<ProcessKey> {
        var all: Set<ProcessKey> = []
        for entry in windows.values { all.formUnion(entry.processKeys) }
        return all
    }

    /// Tells the watch what the open windows need: the pins, the set whose points are fed, and the relay for them (set only
    /// while a window is open, so nothing at all is posted to the main thread otherwise).
    private func syncWatch(pin: Set<ProcessKey>, unpin: Set<ProcessKey>) {
        let live = followedKeys
        let relay: ((ProcessKey, MemorySample) -> Void)? = windows.isEmpty ? nil : livePointRelay()
        onSampling { [weak self] in
            guard let watch = self?.watch else { return }
            for key in unpin { watch.unpin(key) }
            for key in pin { watch.pin(key) }
            watch.setLive(live)
            watch.onLivePoint = relay
        }
    }

    private func livePointRelay() -> (ProcessKey, MemorySample) -> Void {
        return { [weak self] key, sample in
            guard let self else { return }
            self.onMain { [weak self] in self?.livePointArrived(key, sample) }
        }
    }

    /// A live point, on the main thread: to every window following that process.
    func livePointArrived(_ key: ProcessKey, _ sample: MemorySample) {
        for entry in windows.values where entry.processKeys.contains(key) {
            entry.window.appendLive(sample)
        }
        // A leak whose memory has come back down is withdrawn: its banner goes (once), not left to say "leak".
        for finding in findings where finding.processKey == key && finding.hasRecovered(currentBytes: sample.bytes) {
            // An app's leak and a low-memory warning naming it share one notification: leave a newer warning's banner alone.
            guard findings.first(where: { $0.windowKey == finding.windowKey })?.tier != .pressure else { continue }
            if withdrawn.insert(finding.windowKey).inserted { notifier.removeDelivered(forKey: finding.windowKey) }
        }
    }

    /// Window keys whose banner was taken back because the memory fell (so it is done once, not at every point).
    private var withdrawn: Set<String> = []

    // ── The ignore list ─────────────────────────────────────────────────────

    /// "Don't warn about this app": written to the settings (so the watch keeps skipping it after a relaunch), dropped from
    /// the list, and the watch stops following its processes now.
    func ignore(identityKey: String) {
        var list = settings.memoryWatchIgnoredApps
        if !list.contains(identityKey) {
            list.append(identityKey)
            settings.memoryWatchIgnoredApps = list
        }
        findings.removeAll { $0.identityKey == identityKey }
        onSampling { [weak self] in self?.watch?.ignore(identityKey: identityKey) }
        postChange()
    }

    /// Warn about this app again. A watch only forgets what it was told to ignore this session by being made again, so it is.
    func removeIgnored(identityKey: String) {
        settings.memoryWatchIgnoredApps = settings.memoryWatchIgnoredApps.filter { $0 != identityKey }
        if isEnabled { installWatch() }
        postChange()
    }

    // ── Notification permission ─────────────────────────────────────────────

    /// Reads what macOS says now. Cheap, and safe to call as often as the section is refreshed: a change is announced only
    /// when the answer differs from the last. Does nothing while the feature is off.
    func refreshAuthorization() {
        guard isEnabled else { return }
        if isSandboxed() {
            setAuthorization(.notDetermined)
            return
        }
        notifier.authorizationStatus { [weak self] status in
            guard let self, self.isEnabled else { return }
            self.setAuthorization(status)
        }
    }

    /// Asks macOS for permission to show banners, when it has not been asked: called when the person ticks the box (a window
    /// of Anode is open then, so macOS can show its question). Never in the install-test copy and never while the feature is
    /// off.
    func requestAuthorization() {
        guard isEnabled, !isSandboxed() else { return }
        notifier.authorizationStatus { [weak self] status in
            guard let self, self.isEnabled else { return }
            self.setAuthorization(status)
            guard status == .notDetermined else { return }
            self.notifier.requestAuthorization { [weak self] answer in
                guard let self, self.isEnabled else { return }
                self.setAuthorization(answer)
            }
        }
    }

    private func setAuthorization(_ status: LeakAuthorization) {
        guard authorization != status else { return }
        authorization = status
        postChange()
    }

    private func postChange() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

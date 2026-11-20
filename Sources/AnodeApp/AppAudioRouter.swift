import Foundation
import PowerKit

/// Decides which apps have a tap and keeps it right: one session for each app whose volume was changed, none for an app left at
/// 100 % and unmuted (so with nothing changed there is nothing running), and none at all while the feature is off or the
/// permission is refused. Everything ends with `shutdown`, and a tap is private to Anode's process, so a crash ends them too.
final class AppAudioRouter: AppVolumeControlling {

    private struct Session {
        let handle: AppAudioSessionHandle
        let gain: GainStage
        let signature: String
        let muting: Bool
    }

    private let settings: Settings
    private let store: AppAudioStore
    private let backend: AppAudioBackend
    private let bundleID: (String) -> String?
    private let name: (String) -> String
    private let isListable: (String) -> Bool
    private let displayName: (String) -> String?
    private let openApps: () -> [(bundleID: String, name: String)]
    private let looseApps: () -> Set<String>
    private var sessions: [String: Session] = [:]
    private var failedSignatures: [String: String] = [:]
    private var stopped = false
    private var observer: NSObjectProtocol?
    private var recheck: Timer?
    /// The audio processes as last read. Reading them is a round trip to Core Audio's daemon for each one, and the menu is rebuilt on
    /// every step of a volume drag (measured: a third of a drag's time on the main thread), so they are read again only when the
    /// system says the set changed, or after `processMaxAge` seconds in case it did not say.
    private var processCache: (at: Date, list: [AudioProcessInfo])?
    private static let processMaxAge: TimeInterval = 10
    private func audioProcesses() -> [AudioProcessInfo] {
        if let c = processCache, Date().timeIntervalSince(c.at) < Self.processMaxAge { return c.list }
        let list = backend.processes()
        processCache = (Date(), list)
        return list
    }

    /// Why an app's session could not be made or ended, by bundle id; the setting is kept.
    private(set) var failures: [String: String] = [:]
    /// Called when what the menu shows may have changed (a failure).
    var onChange: (() -> Void)?

    init(settings: Settings, store: AppAudioStore, backend: AppAudioBackend, bundleID: @escaping (String) -> String?,
         name: @escaping (String) -> String, isListable: @escaping (String) -> Bool = { _ in true },
         displayName: @escaping (String) -> String? = { _ in nil },
         openApps: @escaping () -> [(bundleID: String, name: String)] = { [] },
         looseApps: @escaping () -> Set<String> = { [] }) {
        self.settings = settings; self.store = store; self.backend = backend
        self.bundleID = bundleID; self.name = name; self.isListable = isListable; self.displayName = displayName
        self.openApps = openApps; self.looseApps = looseApps
        backend.onProcessesChanged = { [weak self] in self?.processCache = nil; self?.reconcile() }
        backend.onOutputChanged = { [weak self] in self?.processCache = nil; self?.reconcile() }
        observer = NotificationCenter.default.addObserver(forName: AppAudioStore.didChange, object: store, queue: .main) { [weak self] _ in
            self?.reconcile()
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var permission: AudioCapturePermission { backend.permission() }
    var activeSessionCount: Int { sessions.count }

    // ── What the menu shows ─────────────────────────────────────────────────

    /// Every open app that can make sound, at its own volume (100 % unless the person changed it), whether or not it
    /// is playing: silent is not muted. Empty while the feature is off. In a steady order: rows that move as apps start and stop
    /// would be hard to aim at.
    var apps: [AppVolumeRow] {
        guard settings.appAudioEnabled, !stopped else { return [] }
        // Apps connected to the sound system now, and every app ever seen so that is still open: a browser is an audio client only
        // while a tab uses sound, and it does not leave the list when the tab stops.
        var names: [String: String] = [:]
        let isListable: (String) -> Bool = { [isListable] in isListable($0) && !NeverSoundApps.contains($0) }
        for app in AudioAppGrouping.group(audioProcesses(), bundleID: bundleID, name: name, looseApps: looseApps()) where isListable(app.bundleID) {
            names[app.bundleID] = app.name
            store.remember(bundleID: app.bundleID, name: app.name)
        }
        for (id, known) in store.knownApps where names[id] == nil && isListable(id) { names[id] = known }
        // An app the person already changed is shown while it is open, whether or not it has been seen yet.
        for id in store.customised.keys where names[id] == nil && isListable(id) {
            if let n = displayName(id) { names[id] = n; store.remember(bundleID: id, name: n) }
        }
        // Every other open app: it is not connected to the sound system until it plays, and it can still be set before that.
        for app in openApps() where names[app.bundleID] == nil && isListable(app.bundleID) { names[app.bundleID] = app.name }
        return names.map { id, name in (id, name) }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
            .map { id, name in
                let s = store.setting(for: id)
                return AppVolumeRow(bundleID: id, name: name, volume: Double(s.gain), muted: s.muted)
            }
    }

    func setVolume(_ value: Double, forBundleID id: String) {
        guard !stopped else { return }
        store.set(AppAudioSetting(gain: Float(value), muted: store.setting(for: id).muted), for: id)
    }

    func setMuted(_ muted: Bool, forBundleID id: String) {
        guard !stopped else { return }
        store.set(AppAudioSetting(gain: store.setting(for: id).gain, muted: muted), for: id)
    }

    // ── Keeping the taps right ──────────────────────────────────────────────

    /// Makes the taps there are the taps there should be. Idempotent; called on every change that could matter.
    func reconcile() {
        guard !stopped else { return }
        guard settings.appAudioEnabled else { stopAll(); return }
        let permission = backend.permission()
        guard permission != .denied, let output = backend.defaultOutputUID() else { stopAll(); return }
        let muting = permission == .granted
        let running = Dictionary(AudioAppGrouping.group(audioProcesses(), bundleID: bundleID, name: name, looseApps: looseApps()).map { ($0.bundleID, $0) },
                                 uniquingKeysWith: { a, _ in a })
        var wanted: [String: (ids: [UInt32], setting: AppAudioSetting)] = [:]
        for (id, setting) in store.customised {
            if let app = running[id] { wanted[id] = (app.processObjectIDs, setting) }
            else if backend.canTapAppsNotYetRunning, LooseApp.executablePath(from: id) == nil { wanted[id] = ([], setting) }   // held from its first sound
        }
        // Back at 100 % and unmuted: the tap goes at once, playing or not. A tap is audio capture, and macOS shows its recording
        // indicator for Anode for as long as one exists; the owner would rather hear the moment the tap takes to go than see that
        // indicator for an app Anode is not changing. (`CoreAudioSession.stop` gives the app its sound back first, to keep that short.)
        for id in sessions.keys where wanted[id] == nil { sessions[id]?.handle.stop(); sessions[id] = nil }
        for (id, want) in wanted {
            // Process ids matter only to a backend that cannot tap an app by name.
            // An app with no bundle id cannot be named to a tap: it is held by its process, once it is running.
            let ids = backend.canTapAppsNotYetRunning && LooseApp.executablePath(from: id) == nil ? [] : want.ids.sorted()
            let signature = "\(output)|\(muting)|\(ids)"
            let level = muting ? want.setting.effectiveGain : 0   // not yet permitted: the tap plays nothing and the app is left alone
            if let existing = sessions[id], existing.signature == signature {
                existing.gain.setTarget(level)
                continue
            }
            if failedSignatures[id] == signature { continue }   // it failed like this already: no retry without a reason
            sessions[id]?.handle.stop(); sessions[id] = nil
            let gain = GainStage(channels: 2, sampleRate: 48000, initialGain: level)
            do {
                let handle = try backend.start(bundleID: id, processObjectIDs: want.ids, outputUID: output, muteOriginal: muting, gain: gain,
                                               onFailure: { [weak self] in self?.sessionFailed(id) })
                sessions[id] = Session(handle: handle, gain: gain, signature: signature, muting: muting)
                failures[id] = nil; failedSignatures[id] = nil
            } catch {
                noteFailure(id, signature: signature)
            }
        }
        scheduleRecheck()
    }

    private func sessionFailed(_ id: String) {
        guard let s = sessions[id] else { return }
        s.handle.stop()
        sessions[id] = nil
        noteFailure(id, signature: s.signature)
    }

    /// Remembers why an app has no tap, and that this exact setup failed, so it is not retried without a reason.
    private func noteFailure(_ id: String, signature: String) {
        failures[id] = "Couldn't control this app"
        failedSignatures[id] = signature
        onChange?()
    }

    /// While the permission has not been answered the tap only listens; look again now and then, so the app is held as soon as the
    /// person says yes.
    private func scheduleRecheck() {
        let waiting = sessions.values.contains { !$0.muting }
        if waiting, recheck == nil {
            // Only while a permission is unanswered; holding the app a second later than the answer is not noticed.
            recheck = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reconcile() }
                .coalescing(tolerance: 1)
        } else if !waiting {
            recheck?.invalidate(); recheck = nil
        }
    }

    private func stopAll() {
        for s in sessions.values { s.handle.stop() }
        sessions = [:]
        recheck?.invalidate(); recheck = nil
    }

    /// Every app back to normal, now and for good: nothing is started after this.
    func shutdown() {
        stopped = true
        stopAll()
    }
}

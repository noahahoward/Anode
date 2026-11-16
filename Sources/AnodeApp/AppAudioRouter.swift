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
    private var sessions: [String: Session] = [:]
    private var failedSignatures: [String: String] = [:]
    private var stopped = false
    private var observer: NSObjectProtocol?
    private var recheck: Timer?

    /// Why an app's session could not be made or ended, by bundle id; the setting is kept.
    private(set) var failures: [String: String] = [:]
    /// Called when what the menu shows may have changed (a failure).
    var onChange: (() -> Void)?

    init(settings: Settings, store: AppAudioStore, backend: AppAudioBackend, bundleID: @escaping (String) -> String?,
         name: @escaping (String) -> String, isListable: @escaping (String) -> Bool = { _ in true }) {
        self.settings = settings; self.store = store; self.backend = backend
        self.bundleID = bundleID; self.name = name; self.isListable = isListable
        backend.onProcessesChanged = { [weak self] in self?.reconcile() }
        backend.onOutputChanged = { [weak self] in self?.reconcile() }
        observer = NotificationCenter.default.addObserver(forName: AppAudioStore.didChange, object: store, queue: .main) { [weak self] _ in
            self?.reconcile()
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var permission: AudioCapturePermission { backend.permission() }
    var activeSessionCount: Int { sessions.count }

    // ── What the menu shows ─────────────────────────────────────────────────

    /// Every open app that makes use of the sound system, at its own volume (100 % unless the person changed it), whether or not it
    /// is playing: silent is not muted. Empty while the feature is off. In a steady order: rows that move as apps start and stop
    /// would be hard to aim at.
    var apps: [AppVolumeRow] {
        guard settings.appAudioEnabled, !stopped else { return [] }
        return AudioAppGrouping.group(backend.processes(), bundleID: bundleID, name: name)
            .filter { isListable($0.bundleID) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { app in
                let s = store.setting(for: app.bundleID)
                return AppVolumeRow(bundleID: app.bundleID, name: app.name, volume: Double(s.gain), muted: s.muted)
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
        let running = Dictionary(AudioAppGrouping.group(backend.processes(), bundleID: bundleID, name: name).map { ($0.bundleID, $0) },
                                 uniquingKeysWith: { a, _ in a })
        var wanted: [String: (ids: [UInt32], setting: AppAudioSetting)] = [:]
        for (id, setting) in store.customised {
            if let app = running[id] { wanted[id] = (app.processObjectIDs, setting) }
            else if backend.canTapAppsNotYetRunning { wanted[id] = ([], setting) }   // held from its first sound
        }
        for id in sessions.keys where wanted[id] == nil { sessions[id]?.handle.stop(); sessions[id] = nil }
        for (id, want) in wanted {
            // Process ids matter only to a backend that cannot tap an app by name.
            let ids = backend.canTapAppsNotYetRunning ? [] : want.ids.sorted()
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
                failures[id] = "Couldn't control this app"
                failedSignatures[id] = signature
                onChange?()
            }
        }
        scheduleRecheck()
    }

    private func sessionFailed(_ id: String) {
        guard let s = sessions[id] else { return }
        s.handle.stop()
        sessions[id] = nil
        failures[id] = "Couldn't control this app"
        failedSignatures[id] = s.signature
        onChange?()
    }

    /// While the permission has not been answered the tap only listens; look again now and then, so the app is held as soon as the
    /// person says yes.
    private func scheduleRecheck() {
        let waiting = sessions.values.contains { !$0.muting }
        if waiting, recheck == nil {
            recheck = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reconcile() }
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

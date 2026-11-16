import Foundation
import PowerKit

/// Whether macOS lets Anode listen to other apps' audio ("System Audio Recording"). Until it is answered, and after a refusal,
/// a tap delivers silence without any error, so an app must never be muted through one.
enum AudioCapturePermission: Equatable {
    case granted
    /// Not asked yet: making the tap is what brings up the system's question.
    case undetermined
    case denied
}

/// A running tap on one app. `stop` ends it and the app is itself again at once; it can be called more than once.
protocol AppAudioSessionHandle: AnyObject {
    func stop()
}

/// What the router needs from Core Audio; tests give it a fake.
protocol AppAudioBackend: AnyObject {
    /// Every audio client now, with the program it runs.
    func processes() -> [AudioProcessInfo]
    func defaultOutputUID() -> String?
    func permission() -> AudioCapturePermission
    /// Whether a tap can be made for an app that is not running yet, and then holds it from its first sound (macOS 26 and later:
    /// a tap by bundle identifier that restores the app when it starts). Without it an app that starts later is heard for a moment
    /// before a tap can be made, so a muted app would not be silent from its first sound.
    var canTapAppsNotYetRunning: Bool { get }
    /// Taps the app and plays what the tap hears through `gain` to the output `outputUID`. With `muteOriginal` the app's own sound
    /// is silenced for as long as the session lives; without it the app is left alone (and `gain` should be silent).
    /// `processObjectIDs` may be empty for an app that is not running yet. Throws having changed nothing.
    func start(bundleID: String, processObjectIDs: [UInt32], outputUID: String, muteOriginal: Bool, gain: GainStage,
               onFailure: @escaping () -> Void) throws -> AppAudioSessionHandle
    /// Called when the list of audio clients changes, and when the default output does.
    var onProcessesChanged: (() -> Void)? { get set }
    var onOutputChanged: (() -> Void)? { get set }
}

/// The devices Anode makes for per-app volume (a private aggregate device each). Core Audio shows them to Anode's own process, so
/// the list of outputs leaves them out: they are plumbing, never somewhere the person sends sound.
enum OwnAudioDevices {
    static let name = "Anode app volume"
    private static let lock = NSLock()
    private static var uids = Set<String>()

    static func add(uid: String) { lock.lock(); uids.insert(uid); lock.unlock() }
    static func remove(uid: String) { lock.lock(); uids.remove(uid); lock.unlock() }
    static func contains(uid: String) -> Bool { lock.lock(); defer { lock.unlock() }; return uids.contains(uid) }
}

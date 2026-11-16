import Foundation

/// One app's own volume: 0 (silent) to 1 (the app's own level, the default), and whether it is muted. A muted app keeps its level,
/// so unmuting comes back to it.
public struct AppAudioSetting: Codable, Equatable {
    public var gain: Float
    public var muted: Bool
    public static let gainRange: ClosedRange<Float> = 0...1
    public static let flat = AppAudioSetting(gain: 1, muted: false)

    public init(gain: Float, muted: Bool) {
        self.gain = min(Self.gainRange.upperBound, max(Self.gainRange.lowerBound, gain.isFinite ? gain : 1))
        self.muted = muted
    }

    /// Nothing to apply: an app at its default needs no tap at all.
    public var isDefault: Bool { gain == 1 && !muted }
    /// What the sound is multiplied by.
    public var effectiveGain: Float { muted ? 0 : gain }

    // Read leniently: a field from an earlier draft is ignored, a missing one takes its default.
    private enum Keys: String, CodingKey { case gain, muted }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(gain: try c.decodeIfPresent(Float.self, forKey: .gain) ?? 1, muted: try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false)
    }
}

/// Every app's setting, by bundle id, kept in the defaults. An app at its default is not kept at all.
public final class AppAudioStore {
    public static let didChange = Notification.Name("dev.anode.appAudioStoreDidChange")

    private let defaults: UserDefaults
    private let key: String
    private var cache: [String: AppAudioSetting]

    public init(defaults: UserDefaults = .standard, key: String = "anode.appAudio.v1") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode([String: AppAudioSetting].self, from: data) {
            cache = decoded.filter { !$0.value.isDefault }
        } else {
            cache = [:]
        }
    }

    public func setting(for bundleID: String) -> AppAudioSetting { cache[bundleID] ?? .flat }
    public var customised: [String: AppAudioSetting] { cache }

    public func set(_ setting: AppAudioSetting, for bundleID: String) {
        guard setting != self.setting(for: bundleID) else { return }
        if setting.isDefault { cache.removeValue(forKey: bundleID) } else { cache[bundleID] = setting }
        if let data = try? JSONEncoder().encode(cache) { defaults.set(data, forKey: key) }
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["bundleID": bundleID])
    }

    public func reset(_ bundleID: String) { set(.flat, for: bundleID) }

    // ── Apps seen using sound ───────────────────────────────────────────────

    private var knownKey: String { key + ".known" }

    /// Apps that have been seen using the sound system (bundle id to name). An app is an audio client only while it has an open
    /// connection (a browser, only while a tab is using sound), so the list of those alone would lose an app that is open and idle.
    public var knownApps: [String: String] {
        guard let data = defaults.data(forKey: knownKey), let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    public func remember(bundleID: String, name: String) {
        var map = knownApps
        guard map[bundleID] != name else { return }
        map[bundleID] = name
        if let data = try? JSONEncoder().encode(map) { defaults.set(data, forKey: knownKey) }
    }
}

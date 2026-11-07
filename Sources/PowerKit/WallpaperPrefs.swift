import Foundation

// ── Live wallpaper preferences ──────────────────────────────────────────────
//
// Everything the user chooses about live wallpapers that is not the library itself: which item goes on which display, what
// pauses it, and how it is drawn. One Codable value kept as JSON under one defaults key, so a change is one write and one
// notification, and a corrupt value falls back to the defaults rather than to a half-read mix.

public enum WallpaperScaling: String, Codable, CaseIterable {
    case fill, fit, stretch
}

/// What one display shows. `inherit` is not stored: a display with no entry follows the default item.
public enum DisplayChoice: Codable, Equatable {
    case inherit
    case none
    case item(UUID)
}

public struct WallpaperAssignments: Codable, Equatable {
    /// The item every display without its own choice shows.
    public var defaultItem: UUID?
    /// Keyed by display UUID (never by index), so a monitor that is unplugged and plugged back in is still remembered.
    public var perDisplay: [String: DisplayChoice]

    public init(defaultItem: UUID? = nil, perDisplay: [String: DisplayChoice] = [:]) {
        self.defaultItem = defaultItem
        self.perDisplay = perDisplay
    }

    /// The item `uuid`'s display shows: its own, else the default, else nothing. `.none` is a choice and beats the default.
    public func resolved(forDisplay uuid: String) -> UUID? {
        switch perDisplay[uuid] {
        case .item(let id)?: return id
        case .none?:         return nil
        case .inherit?, nil: return defaultItem
        }
    }

    public mutating func setChoice(_ c: DisplayChoice, forDisplay uuid: String) {
        if c == .inherit { perDisplay[uuid] = nil } else { perDisplay[uuid] = c }
    }

    /// Forget every reference to `id`: the default, and each display that pointed at it (which then follows the default).
    public mutating func removeItem(_ id: UUID) {
        if defaultItem == id { defaultItem = nil }
        for (uuid, choice) in perDisplay where choice == .item(id) { perDisplay[uuid] = nil }
    }
}

public struct WallpaperPrefs: Codable, Equatable {
    public static let speedRange: ClosedRange<Double> = 0.25...2.0

    public var pauseOnBattery = true
    public var pauseInLowPower = true
    /// Pause while a full-screen app (or anything else that leaves no desktop visible) covers the display.
    public var pauseWhenCovered = true
    public var pauseWhenHot = true
    public var muted = true
    public var volume: Float = 0.5 { didSet { volume = min(1, max(0, volume)) } }
    public var scaling: WallpaperScaling = .fill
    public var speed: Double = 1.0 { didSet { speed = min(Self.speedRange.upperBound, max(Self.speedRange.lowerBound, speed)) } }
    public var assignments = WallpaperAssignments()

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case pauseOnBattery, pauseInLowPower, pauseWhenCovered, pauseWhenHot, muted, volume, scaling, speed, assignments
    }

    /// Every key is optional, so a value written by an older or newer build still reads, with the defaults filling the gaps.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WallpaperPrefs()
        pauseOnBattery = try c.decodeIfPresent(Bool.self, forKey: .pauseOnBattery) ?? d.pauseOnBattery
        pauseInLowPower = try c.decodeIfPresent(Bool.self, forKey: .pauseInLowPower) ?? d.pauseInLowPower
        pauseWhenCovered = try c.decodeIfPresent(Bool.self, forKey: .pauseWhenCovered) ?? d.pauseWhenCovered
        pauseWhenHot = try c.decodeIfPresent(Bool.self, forKey: .pauseWhenHot) ?? d.pauseWhenHot
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? d.muted
        scaling = try c.decodeIfPresent(WallpaperScaling.self, forKey: .scaling) ?? d.scaling
        assignments = try c.decodeIfPresent(WallpaperAssignments.self, forKey: .assignments) ?? d.assignments
        // `didSet` does not run inside an initializer, so clamp what was read by hand.
        let v = try c.decodeIfPresent(Float.self, forKey: .volume) ?? d.volume
        volume = min(1, max(0, v))
        let s = try c.decodeIfPresent(Double.self, forKey: .speed) ?? d.speed
        speed = min(Self.speedRange.upperBound, max(Self.speedRange.lowerBound, s))
    }
}

public final class WallpaperPrefsStore {
    /// Posted (object: the store) after a change that altered the value.
    public static let didChange = Notification.Name("AnodeWallpaperPrefsDidChange")

    private let defaults: UserDefaults
    private let key: String
    private var stored: WallpaperPrefs

    public init(defaults: UserDefaults, key: String = "anode.wallpaper.prefs.v1") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key), let p = try? JSONDecoder().decode(WallpaperPrefs.self, from: data) {
            stored = p
        } else {
            stored = WallpaperPrefs()
        }
    }

    public var prefs: WallpaperPrefs {
        get { stored }
        set {
            guard newValue != stored else { return }
            stored = newValue
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: key) }
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }
}

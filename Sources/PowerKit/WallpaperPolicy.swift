import Foundation

// ── When a live wallpaper should be paused ──────────────────────────────────
//
// Pure decisions, no clocks and no system calls: the controller feeds in what is true and gets back why (if at all) a display's
// wallpaper should stand still. A paused video costs ~0.05 % of a core and a paused web page about the same, so honouring all of
// these is cheap; the point of the rules is that a wallpaper nobody can see, or that is eating a battery, should not be running.

/// Why a wallpaper is paused. Declared in priority order: when several hold, the earliest is the one reported.
public enum WallpaperPauseReason: Equatable {
    case userPaused
    case displaysAsleep
    case screenLocked
    /// Ultra Low Power Mode is on. It turns macOS's Low Power Mode on too, so it sits above that reason: the one given is the
    /// mode's, and it holds whatever the owner's "pause when" switches say.
    case ultraLowPower
    case lowPowerMode
    case onBattery
    case tooHot
    /// No part of the desktop can be seen on this display (a full-screen app is up, or a Space change is sliding past).
    case covered
}

/// What is true of the whole Mac.
public struct WallpaperGlobalConditions: Equatable {
    public var onBattery = false
    public var lowPowerMode = false
    public var thermalHot = false
    public var displaysAsleep = false
    public var screenLocked = false
    public var userPaused = false
    /// Ultra Low Power Mode is on (not merely being asked for).
    public var ultraLowPower = false

    public init(onBattery: Bool = false, lowPowerMode: Bool = false, thermalHot: Bool = false,
                displaysAsleep: Bool = false, screenLocked: Bool = false, userPaused: Bool = false,
                ultraLowPower: Bool = false) {
        self.onBattery = onBattery; self.lowPowerMode = lowPowerMode; self.thermalHot = thermalHot
        self.displaysAsleep = displaysAsleep; self.screenLocked = screenLocked; self.userPaused = userPaused
        self.ultraLowPower = ultraLowPower
    }
}

/// What is true of one display.
public struct WallpaperDisplayConditions: Equatable {
    /// The window server reports the wallpaper window as not visible at all.
    public var covered = false

    public init(covered: Bool = false) { self.covered = covered }
}

public enum WallpaperPolicy {
    /// The reason to pause, or nil to play. Sleep, lock, the user's own pause and Ultra Low Power Mode apply whatever the
    /// preferences say; the rest each need their preference on.
    public static func pauseReason(prefs: WallpaperPrefs, global g: WallpaperGlobalConditions,
                                   display d: WallpaperDisplayConditions) -> WallpaperPauseReason? {
        if g.userPaused { return .userPaused }
        if g.displaysAsleep { return .displaysAsleep }
        if g.screenLocked { return .screenLocked }
        if g.ultraLowPower { return .ultraLowPower }
        if g.lowPowerMode && prefs.pauseInLowPower { return .lowPowerMode }
        if g.onBattery && prefs.pauseOnBattery { return .onBattery }
        if g.thermalHot && prefs.pauseWhenHot { return .tooHot }
        if d.covered && prefs.pauseWhenCovered { return .covered }
        return nil
    }
}

/// Holds back `.covered` until it has been continuously true for `delay`, and lets every other reason (and every clearing)
/// through at once.
///
/// The delay exists because "covered" comes from the wallpaper window's visibility, and a Space switch reads as "hidden" for
/// about half a second (measured 0.54 s) before the window is visible again: without a delay every switch would pause and
/// resume the wallpaper. One second is comfortably longer than that slide and still prompt for a full-screen app. A reason
/// that flickers off and back on starts the count again.
public struct PauseGate {
    public let delay: TimeInterval
    private var pendingSince: Date?
    private var confirmed = false

    public init(delay: TimeInterval = 1.0) { self.delay = delay }

    public mutating func update(_ reason: WallpaperPauseReason?, now: Date) -> WallpaperPauseReason? {
        guard let reason else {
            pendingSince = nil; confirmed = false
            return nil
        }
        guard reason == .covered else {
            pendingSince = nil; confirmed = false
            return reason
        }
        if confirmed { return .covered }
        let since = pendingSince ?? now
        pendingSince = since
        if now.timeIntervalSince(since) >= delay {
            confirmed = true; pendingSince = nil
            return .covered
        }
        return nil
    }

    /// When a delayed reason will take effect, or nil when none is waiting.
    public func nextCheck(now: Date) -> Date? { pendingSince?.addingTimeInterval(delay) }
}

/// Values shared by key and released when the last holder lets go. Main-thread only.
public final class RefCountedPool<Key: Hashable, Value> {
    private struct Entry { var value: Value; var count: Int }
    private var entries: [Key: Entry] = [:]
    private let make: (Key) throws -> Value
    private let dispose: (Value) -> Void

    public init(make: @escaping (Key) throws -> Value, dispose: @escaping (Value) -> Void) {
        self.make = make
        self.dispose = dispose
    }

    /// The value for `key`, made on first use. A `make` that throws registers nothing.
    public func acquire(_ key: Key) throws -> Value {
        if var e = entries[key] {
            e.count += 1
            entries[key] = e
            return e.value
        }
        let value = try make(key)
        entries[key] = Entry(value: value, count: 1)
        return value
    }

    /// Let go of one hold on `key`; the last release disposes the value. An unknown key is ignored.
    public func release(_ key: Key) {
        guard var e = entries[key] else { return }
        e.count -= 1
        if e.count <= 0 {
            entries[key] = nil
            dispose(e.value)
        } else {
            entries[key] = e
        }
    }

    public var liveKeys: Set<Key> { Set(entries.keys) }
}

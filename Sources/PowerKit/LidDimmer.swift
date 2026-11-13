import Foundation
import CoreGraphics
import IOKit

// ── Lid dimmer ──────────────────────────────────────────────────────────────
//
// Always Stay Awake keeps a MacBook running with the lid shut. A shut lid means nobody is looking at the panel, so
// its backlight is turned all the way down while the lid is closed (less heat, less battery, which is the point of
// running closed) and put back EXACTLY as it was when the lid opens, or when Keep Awake stops, or when Anode quits.
//
// The one way this goes wrong is a screen that stays black after the lid is opened, so:
//
//   · the brightness it will put back is read while the lid is still OPEN (a panel that is asleep may not answer),
//     and is refreshed every few seconds so a change made in System Settings is respected;
//   · the moment it dims, the value to restore is written to disk, and removed only after the restore is confirmed;
//   · at every launch `release()` runs first, so a crash or a force-quit while dimmed is undone by the next start;
//   · a restore that fails is retried on every poll until it works;
//   · a panel that is already dark when the lid closes is left alone, and a Mac with no lid sensor is never touched;
//   · the brightness the owner had is kept in `OwnBrightness`, shared with every other feature that lowers the screen,
//     so two features lowering it at once cannot each take the other's lowered level for the owner's own.
//
// The lid and the backlight are behind protocols; every sequence is played in the tests without either.

public protocol LidStateReader {
    /// True while the lid is shut, nil if this Mac has no lid (a desktop) or the answer is unreadable.
    func isClosed() -> Bool?
}

public protocol BacklightControl: AnyObject {
    /// The built-in panel's brightness, 0...1.
    func brightness() -> Float?
    /// Set it; true only if the system accepted the value.
    func setBrightness(_ value: Float) -> Bool
}

/// The brightness the owner had before any feature lowered it, kept once for every feature that lowers the screen.
///
/// The first feature to lower it notes what the owner had. A second, finding the screen already lower, would read the
/// first one's level as the owner's own; so only the earliest value is kept, and every feature that lowers the screen
/// is noted as an owner of it. The value comes back only to the last to leave: while another still wants the screen
/// lowered, leaving must not raise it.
public final class OwnBrightness {

    public static let shared = OwnBrightness()

    private let lock = NSLock()
    private var value: Float?
    private var owners: Set<String> = []

    public init() {}

    /// Notes `owner`, and keeps `value` as the owner's brightness only if nothing is remembered yet.
    public func remember(_ value: Float, for owner: String) {
        lock.lock(); defer { lock.unlock() }
        if self.value == nil { self.value = value }
        owners.insert(owner)
    }

    /// Takes `owner` out. The remembered brightness comes back only when nobody else is left; nil while another
    /// feature still holds the screen lowered, and for one that was never noted.
    public func forget(_ owner: String) -> Float? {
        lock.lock(); defer { lock.unlock() }
        guard owners.remove(owner) != nil, owners.isEmpty else { return nil }
        defer { value = nil }
        return value
    }
}

public final class LidDimmer {

    static let savedKey = "keepAwake.savedBrightness"
    /// The name this dimmer is noted under in `OwnBrightness`.
    static let ownerName = "lid"
    /// Brightness at or below this counts as already dark: nothing to save, nothing to restore.
    static let darkThreshold: Float = 0.02
    /// A closed lid's dimming is tried this many times per closing before giving up (a sleeping panel can refuse).
    static let maxDimAttempts = 5
    /// While the lid is open the brightness to restore is re-read every this many polls.
    static let refreshEvery = 10

    private let lid: LidStateReader
    private let backlight: BacklightControl
    private let defaults: UserDefaults
    private let ownBrightness: OwnBrightness
    private let log: (String) -> Void

    private var lastOpenBrightness: Float?
    private var polls = 0
    private var dimAttempts = 0

    public init(lid: LidStateReader, backlight: BacklightControl, defaults: UserDefaults = .standard,
                ownBrightness: OwnBrightness = .shared, log: @escaping (String) -> Void = { _ in }) {
        self.lid = lid
        self.backlight = backlight
        self.defaults = defaults
        self.ownBrightness = ownBrightness
        self.log = log
    }

    /// The brightness waiting to be put back, if the panel is dimmed by us.
    public var saved: Float? { defaults.object(forKey: Self.savedKey) == nil ? nil : defaults.float(forKey: Self.savedKey) }
    public var isDimmed: Bool { saved != nil }

    /// Called about once a second while Always Stay Awake is running.
    public func poll() {
        guard let closed = lid.isClosed() else { return }
        if closed {
            guard !isDimmed else { return }
            dim()
        } else {
            dimAttempts = 0
            if isDimmed { restore(); return }
            polls += 1
            if lastOpenBrightness == nil || polls % Self.refreshEvery == 0 { lastOpenBrightness = backlight.brightness() }
        }
    }

    /// Put the brightness back if this dimmer took it. Safe to call at any time, any number of times.
    @discardableResult
    public func release() -> Bool {
        guard isDimmed else { lastOpenBrightness = nil; return true }
        let ok = restore()
        lastOpenBrightness = nil
        return ok
    }

    private func dim() {
        guard dimAttempts < Self.maxDimAttempts else { return }
        dimAttempts += 1
        guard let current = lastOpenBrightness ?? backlight.brightness() else {
            log("lid closed: could not read the brightness, leaving it")
            return
        }
        guard current > Self.darkThreshold else { return }
        // Write down what to restore BEFORE changing anything. The saved value stays on disk because it is what a launch
        // after a crash has to go by; the shared record is only in memory.
        defaults.set(current, forKey: Self.savedKey)
        ownBrightness.remember(current, for: Self.ownerName)
        if backlight.setBrightness(0) {
            log(String(format: "lid closed: brightness %.2f → 0", current))
        } else {
            defaults.removeObject(forKey: Self.savedKey)
            // Not an owner of a screen it did not lower, or the other feature's `forget` would never get the value back.
            _ = ownBrightness.forget(Self.ownerName)
            log("lid closed: the panel refused brightness 0 (attempt \(dimAttempts))")
        }
    }

    @discardableResult
    private func restore() -> Bool {
        guard let saved else { return true }
        // The owner's own brightness when no other feature still holds the screen lowered. Otherwise the level the
        // screen had when the lid shut, which is the other feature's: never black, never the owner's while that
        // feature is still on.
        let value = ownBrightness.forget(Self.ownerName) ?? saved
        if backlight.setBrightness(value) {
            defaults.removeObject(forKey: Self.savedKey)
            log(String(format: "lid open / stopped: brightness restored to %.2f", value))
            return true
        }
        // `forget` already took the lid out; put it back so the retry finds the same record and goes to the same level.
        ownBrightness.remember(value, for: Self.ownerName)
        log("restoring brightness \(value) failed; will retry")
        return false
    }
}

// ── The real lid and panel ──────────────────────────────────────────────────

/// `AppleClamshellState` on IOPMrootDomain: Yes while the lid is shut. Absent on a Mac with no lid.
public struct IOKitLidState: LidStateReader {
    public init() {}
    public func isClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
        return value as? Bool
    }
}

/// The built-in panel through DisplayServices. It is private API, so it is looked up by name and everything
/// degrades to "unavailable" rather than failing: the public IOKit brightness call returns success and does
/// nothing on Apple Silicon panels (measured in `anode --display`).
public final class DisplayServicesBacklight: BacklightControl {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32

    private let getFn: GetFn?
    private let setFn: SetFn?
    /// The built-in panel's display id, remembered from when it was online: with the lid shut it may not be listed.
    private var builtinID: UInt32?

    public init() {
        let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        getFn = h.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetFn.self) }
        setFn = h.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetFn.self) }
        builtinID = Self.findBuiltinID()
    }

    private static func findBuiltinID() -> UInt32? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    private func displayID() -> UInt32 {
        if let found = Self.findBuiltinID() { builtinID = found }
        return builtinID ?? CGMainDisplayID()
    }

    public func brightness() -> Float? {
        var v: Float = 0
        guard let getFn, getFn(displayID(), &v) == 0, v.isFinite else { return nil }
        return v
    }

    public func setBrightness(_ value: Float) -> Bool {
        guard let setFn else { return false }
        return setFn(displayID(), max(0, min(1, value))) == 0
    }
}

import CoreGraphics
import Foundation
import PowerKit

/// The built-in display's refresh rate and the keyboard light for Ultra Low Power Mode: the thin layer that touches
/// the system.
///
/// What decides which rate is asked for is `RefreshRatePicker`; this file only turns the display's mode list into plain
/// values for it and turns its answer back into a mode. Both live classes sit behind protocols so the controller is
/// tested with fakes. Both calls are synchronous and can block (the display reconfigures, the light is another
/// process's), so whoever calls them keeps them off the main thread.

// ── The protocols the controller is written against ─────────────────────────

protocol DisplayRateControlling: AnyObject {
    /// False when there is no built-in display, or it offers no lower rate at the current resolution.
    var canLower: Bool { get }
    /// Asks for the lowest rate. App-scope configuration: the system puts the rate back by itself if Anode dies.
    /// True when the display took it; false when there was nothing to lower or it refused.
    func lower() -> Bool
    /// Asks for the rate the display had before `lower()`. Does nothing if `lower()` did not take.
    func restore()
}

protocol KeyboardBacklightControlling: AnyObject {
    /// The keyboard light's level, 0...1. nil when this Mac has none or the system's part for it is not there.
    func level() -> Float?
    /// True only if the system took the level.
    func set(_ level: Float) -> Bool
}

// ── Refresh rate ────────────────────────────────────────────────────────────

/// What the rate rule reads of a display mode. `CGDisplayMode` has all of it already; a stub has it in the tests.
protocol DisplayModeValues {
    var width: Int { get }
    var height: Int { get }
    var pixelWidth: Int { get }
    var pixelHeight: Int { get }
    var refreshRate: Double { get }
    func isUsableForDesktopGUI() -> Bool
}

extension CGDisplayMode: DisplayModeValues {}

/// Acts on the built-in display only: an external display is the owner's and is left as it is.
///
/// The change is an app-scope display configuration (`.forAppOnly`). Measured, it applies to the whole display and the
/// system takes it back when the process ends, so a crash or a kill of Anode needs no undoing of the rate by anyone.
final class LiveDisplayRate: DisplayRateControlling {

    /// What `lower()` changed, kept to put back: the display and the mode it had.
    private var lowered: (display: CGDirectDisplayID, original: CGDisplayMode)?

    var canLower: Bool { plan() != nil }

    func lower() -> Bool {
        // Already lowered by this object: the original is kept, and asking again must not replace it with the lowered one.
        if lowered != nil { return true }
        guard let plan = plan() else { return false }
        guard Self.apply(plan.target, to: plan.display) else { return false }
        lowered = (plan.display, plan.current)
        return true
    }

    func restore() {
        guard let held = lowered else { return }
        // On a refusal the state stays, so a later restore tries again; the system puts it back when Anode ends anyway.
        if Self.apply(held.original, to: held.display) { lowered = nil }
    }

    // Plain values for the rule

    /// The mode list as the values the picker reads. `index` is the place in `modes`, which is how its answer is found
    /// again in the list the system gave.
    static func info(from modes: [DisplayModeValues]) -> [DisplayModeInfo] {
        modes.enumerated().map { index, mode in
            DisplayModeInfo(index: index, width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth,
                            pixelHeight: mode.pixelHeight, rate: mode.refreshRate, usable: mode.isUsableForDesktopGUI())
        }
    }

    /// The place in `modes` of the lowest rate the display offers at `current`'s resolution; nil when `current` is
    /// already as low as it goes.
    static func lowerIndex(in modes: [DisplayModeValues], current: DisplayModeValues) -> Int? {
        // `current` is not looked up in the list: it is described on its own, so no place in the list is claimed for it.
        let now = DisplayModeInfo(index: -1, width: current.width, height: current.height, pixelWidth: current.pixelWidth,
                                  pixelHeight: current.pixelHeight, rate: current.refreshRate,
                                  usable: current.isUsableForDesktopGUI())
        return RefreshRatePicker.lowest(of: info(from: modes), current: now)?.index
    }

    // The system

    private struct Plan {
        var display: CGDirectDisplayID
        var current: CGDisplayMode
        var target: CGDisplayMode
    }

    private func plan() -> Plan? {
        guard let display = Self.builtinDisplay(), let current = CGDisplayCopyDisplayMode(display) else { return nil }
        // Without this the list leaves out the duplicates of a scaled mode, which can be the mode in use.
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
        guard let index = Self.lowerIndex(in: modes, current: current) else { return nil }
        return Plan(display: display, current: current, target: modes[index])
    }

    /// The built-in display, when it is online (with the lid shut it may not be). nil on a Mac without one.
    private static func builtinDisplay() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    private static func apply(_ mode: CGDisplayMode, to display: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, display, mode, nil) == .success else {
            _ = CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forAppOnly) == .success
    }
}

// ── Keyboard light ──────────────────────────────────────────────────────────

/// The keyboard light through `KeyboardBrightnessClient` in the private CoreBrightness framework. Measured: it reads and
/// sets the level without root. It is private, so it is looked up by name and every missing piece means "no keyboard
/// light" rather than a failure, as with `DisplayServicesBacklight`. The framework is loaded on first use, not at launch.
final class LiveKeyboardBacklight: KeyboardBacklightControlling {

    private typealias GetFn = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetFn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool

    private struct Client {
        let object: NSObject
        let idsSelector: Selector
        let getSelector: Selector
        let setSelector: Selector
        let get: GetFn
        let set: SetFn
    }

    private lazy var client: Client? = Self.makeClient()

    func level() -> Float? {
        guard let client, let id = keyboardID(client) else { return nil }
        let value = client.get(client.object, client.getSelector, id)
        return value.isFinite ? value : nil
    }

    func set(_ level: Float) -> Bool {
        guard let client, let id = keyboardID(client), level.isFinite else { return false }
        return client.set(client.object, client.setSelector, max(0, min(1, level)), id)
    }

    /// The built-in keyboard's id: the first the system lists. nil on a Mac with no keyboard light.
    private func keyboardID(_ client: Client) -> UInt64? {
        // `copy…` hands the list over retained, so it is taken retained.
        let ids = client.object.perform(client.idsSelector)?.takeRetainedValue() as? [NSNumber]
        return ids?.first?.uint64Value
    }

    private static func makeClient() -> Client? {
        guard let framework = Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework"), framework.load(),
              let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        let object = type.init()
        let ids = NSSelectorFromString("copyKeyboardBacklightIDs")
        let get = NSSelectorFromString("brightnessForKeyboard:")
        let set = NSSelectorFromString("setBrightness:forKeyboard:")
        guard object.responds(to: ids), object.responds(to: get), object.responds(to: set) else { return nil }
        return Client(object: object, idsSelector: ids, getSelector: get, setSelector: set,
                      get: unsafeBitCast(object.method(for: get), to: GetFn.self),
                      set: unsafeBitCast(object.method(for: set), to: SetFn.self))
    }
}

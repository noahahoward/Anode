import AppKit

// ── How windows are placed: the choices that are the user's ─────────────────
//
// Beyond the shortcuts (`ShortcutStore`), four things about window placement are the user's to set:
// - which action each drag zone gives (`SnapZoneMap`: the left edge is "left half" unless they say
//   otherwise, or nothing at all);
// - whether pressing the same action again steps through sizes (half, two thirds, one third);
// - the gap left between windows and the screen's edge;
// - a modifier that must be held for a drag to snap, for people who drag windows to the edge for other reasons.
// Kept in the user defaults, small, and read through `WindowPrefs` so the shortcut window, the beta
// window and the snapping all see the same values.

/// A modifier that must be held while dragging for the window to snap.
enum SnapModifier: String, CaseIterable {
    case none, shift, option, command

    var title: String {
        switch self {
        case .none: return "Nothing (always snap)"
        case .shift: return "Shift"
        case .option: return "Option"
        case .command: return "Command"
        }
    }

    /// Does `flags` satisfy this? `.none` always does.
    func isSatisfied(by flags: CGEventFlags) -> Bool {
        switch self {
        case .none: return true
        case .shift: return flags.contains(.maskShift)
        case .option: return flags.contains(.maskAlternate)
        case .command: return flags.contains(.maskCommand)
        }
    }
}

extension SnapZone: CaseIterable {
    static var allCases: [SnapZone] {
        [.topLeft, .top, .topRight, .left, .right, .bottomLeft, .bottomFirst, .bottomCenter, .bottomLast, .bottomRight]
    }

    var key: String {
        switch self {
        case .topLeft: return "topLeft"
        case .topRight: return "topRight"
        case .bottomLeft: return "bottomLeft"
        case .bottomRight: return "bottomRight"
        case .left: return "left"
        case .right: return "right"
        case .top: return "top"
        case .bottomFirst: return "bottomFirst"
        case .bottomCenter: return "bottomCenter"
        case .bottomLast: return "bottomLast"
        }
    }

    init?(key: String) {
        guard let zone = Self.allCases.first(where: { $0.key == key }) else { return nil }
        self = zone
    }

    var title: String {
        switch self {
        case .topLeft: return "top-left corner"
        case .topRight: return "top-right corner"
        case .bottomLeft: return "bottom-left corner"
        case .bottomRight: return "bottom-right corner"
        case .left: return "left edge"
        case .right: return "right edge"
        case .top: return "top edge"
        case .bottomFirst: return "bottom edge, left third"
        case .bottomCenter: return "bottom edge, middle third"
        case .bottomLast: return "bottom edge, right third"
        }
    }
}

extension WindowAction {
    /// Does it put the window in a rectangle of one screen? Only those can be a drag zone's outline.
    var hasRegion: Bool {
        switch self {
        case .restore, .nextDisplay, .previousDisplay, .center, .maximizeHeight: return false
        default: return true
        }
    }
}

/// What each drag zone does: the default, unless the user changed it. A zone can be given no action.
struct SnapZoneMap: Equatable {
    /// A zone listed here has been changed; a nil action means the user turned it off.
    private(set) var overrides: [SnapZone: WindowAction?] = [:]

    static func defaultAction(for zone: SnapZone) -> WindowAction {
        switch zone {
        case .topLeft: return .topLeft
        case .topRight: return .topRight
        case .bottomLeft: return .bottomLeft
        case .bottomRight: return .bottomRight
        case .left: return .leftHalf
        case .right: return .rightHalf
        case .top: return .maximize
        case .bottomFirst: return .firstThird
        case .bottomCenter: return .centerThird
        case .bottomLast: return .lastThird
        }
    }

    func action(for zone: SnapZone) -> WindowAction? {
        if let o = overrides[zone] { return o }
        return Self.defaultAction(for: zone)
    }

    func zones(for action: WindowAction) -> [SnapZone] { SnapZone.allCases.filter { self.action(for: $0) == action } }

    /// Give `zone` the action `new` (nil turns it off).
    mutating func set(_ new: WindowAction?, for zone: SnapZone) {
        if new == Self.defaultAction(for: zone) { overrides[zone] = nil } else { overrides[zone] = .some(new) }
    }

    /// A click on a zone while `action` is being edited: it takes the action, or, if it already has it, loses it.
    mutating func toggle(_ zone: SnapZone, for action: WindowAction) {
        set(self.action(for: zone) == action ? nil : action, for: zone)
    }

    mutating func reset() { overrides = [:] }

    var isDefault: Bool { overrides.isEmpty }

    // Stored as { zone: action, "" for none }.
    var stored: [String: String] {
        Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.key, $0.value?.rawValue ?? "") })
    }

    init() {}

    init(stored: [String: String]) {
        for (k, v) in stored {
            guard let zone = SnapZone(key: k) else { continue }
            if v.isEmpty { overrides[zone] = .some(nil) } else if let a = WindowAction(rawValue: v), a.hasRegion { overrides[zone] = .some(a) }
        }
    }
}

final class WindowPrefs {
    static let shared = WindowPrefs()
    static let didChange = Notification.Name("AnodeWindowPrefsDidChange")
    static let maxGap = 40

    private let defaults: UserDefaults
    private let prefix: String

    init(defaults: UserDefaults = .standard, prefix: String = "anode.window.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    private func changed() { NotificationCenter.default.post(name: Self.didChange, object: self) }

    /// Points left between windows and the screen's edge (and between two placed windows, in all).
    var gap: Int {
        get { min(max(defaults.integer(forKey: prefix + "gap"), 0), Self.maxGap) }
        set { defaults.set(min(max(newValue, 0), Self.maxGap), forKey: prefix + "gap"); changed() }
    }

    /// Pressing the same action again steps through sizes. On unless turned off.
    var cycles: Bool {
        get { defaults.object(forKey: prefix + "cycle") as? Bool ?? true }
        set { defaults.set(newValue, forKey: prefix + "cycle"); changed() }
    }

    var snapModifier: SnapModifier {
        get { SnapModifier(rawValue: defaults.string(forKey: prefix + "snapModifier") ?? "") ?? .none }
        set { defaults.set(newValue.rawValue, forKey: prefix + "snapModifier"); changed() }
    }

    var zoneMap: SnapZoneMap {
        get { SnapZoneMap(stored: defaults.dictionary(forKey: prefix + "snapZones") as? [String: String] ?? [:]) }
        set {
            if newValue.isDefault { defaults.removeObject(forKey: prefix + "snapZones") }
            else { defaults.set(newValue.stored, forKey: prefix + "snapZones") }
            changed()
        }
    }
}

// ── Gaps and cycling: the pure parts ────────────────────────────────────────

extension WindowGeometry {

    /// `frame` pulled in by `gap`: the whole gap where it meets the screen's edge, half of it where it meets
    /// another window's (so two placed side by side are a whole gap apart). Unchanged when a gap would
    /// leave nothing of it.
    static func gapped(_ frame: CGRect, in area: CGRect, gap: CGFloat, horizontally: Bool = true) -> CGRect {
        guard gap > 0 else { return frame }
        func inset(_ edge: CGFloat, _ screenEdge: CGFloat) -> CGFloat { abs(edge - screenEdge) < 1 ? gap : gap / 2 }
        let l = horizontally ? inset(frame.minX, area.minX) : 0, r = horizontally ? inset(frame.maxX, area.maxX) : 0
        let t = inset(frame.minY, area.minY), b = inset(frame.maxY, area.maxY)
        let out = CGRect(x: frame.minX + l, y: frame.minY + t, width: frame.width - l - r, height: frame.height - t - b)
        guard out.width >= 50, out.height >= 50 else { return frame }
        return CGRect(x: out.minX.rounded(), y: out.minY.rounded(), width: out.width.rounded(), height: out.height.rounded())
    }

    /// Where `action` puts a window, with the user's gap: what both the shortcut and the drag outline use.
    static func placement(for action: WindowAction, from frame: CGRect, in area: CGRect, gap: CGFloat) -> CGRect? {
        guard let base = Self.frame(for: action, from: frame, in: area) else { return nil }
        switch action {
        case .center: return base
        case .maximizeHeight: return gapped(base, in: area, gap: gap, horizontally: false)
        default: return gapped(base, in: area, gap: gap)
        }
    }

    /// The sizes pressing an action again steps through: a half, then two thirds, then a third.
    static func cycle(for action: WindowAction) -> [WindowAction]? {
        switch action {
        case .leftHalf: return [.leftHalf, .firstTwoThirds, .firstThird]
        case .rightHalf: return [.rightHalf, .lastTwoThirds, .lastThird]
        default: return nil
        }
    }

    /// What was last done to a window by an action.
    struct LastPlacement: Equatable {
        let pressed: WindowAction
        let step: WindowAction
        let frame: CGRect
    }

    /// The step to take now. The first step, unless this is the same action pressed again on a window still
    /// where that last put it (within `tolerance`), when it is the next step, wrapping round.
    static func nextStep(for action: WindowAction, last: LastPlacement?, current: CGRect, tolerance: CGFloat = 3) -> WindowAction {
        guard let chain = cycle(for: action) else { return action }
        guard let last, last.pressed == action, let at = chain.firstIndex(of: last.step),
              abs(last.frame.minX - current.minX) <= tolerance, abs(last.frame.minY - current.minY) <= tolerance,
              abs(last.frame.width - current.width) <= tolerance, abs(last.frame.height - current.height) <= tolerance
        else { return chain[0] }
        return chain[(at + 1) % chain.count]
    }
}

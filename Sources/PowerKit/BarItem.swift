import Foundation

// ── One item in the menu bar (Menu Bar Hider) ───────────────────────────────

/// One status item as the Accessibility extras menu bar reports it.
public struct BarItem: Equatable {
    /// See `BarItemKey`. Stable across relaunches and across a change of position.
    public var key: String
    public var bundleID: String?
    public var appName: String
    public var title: String
    /// Global screen points, origin top-left, as Accessibility reports it.
    public var frame: CGRect
    /// The clock and Control Center: never hidden, never covered.
    public var isLocked: Bool
    public var hasPress: Bool
    public var pid: pid_t?
    /// Reported where a system item is drawn, so not drawn itself: macOS folds an icon that does not fit into its own
    /// "Show Hidden Menu Bar Items" arrow and still reports it there. Set by `markingThoseUnderSystemItems`.
    public var isUnderSystemItem = false

    public init(key: String, bundleID: String?, appName: String, title: String, frame: CGRect,
                isLocked: Bool, hasPress: Bool, pid: pid_t?) {
        self.key = key
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.frame = frame
        self.isLocked = isLocked
        self.hasPress = hasPress
        self.pid = pid
    }

    /// `items` with every unlocked item that a locked (system) item covers by at least a third of its width marked
    /// `isUnderSystemItem`. Neighbours that merely touch are left alone. Seen 2026-11-11: ChatGPT reported at x 1025, 24 wide,
    /// under the overflow arrow at x 1039.
    public static func markingThoseUnderSystemItems(_ items: [BarItem]) -> [BarItem] {
        let system = items.filter(\.isLocked).map(\.frame)
        return items.map { item in
            guard !item.isLocked, item.frame.size.width > 0 else { return item }
            var marked = item
            marked.isUnderSystemItem = system.contains { s in
                let overlap = s.intersection(item.frame)
                return !overlap.isNull && overlap.width >= item.frame.width / 3
            }
            return marked
        }
    }

    /// How far down from the top of a screen an item can sit and still be on the bar.
    public static let barBand: CGFloat = 40

    /// Whether the item is drawn on a menu bar: it has a size, and at least half of it lies inside the top band of some
    /// screen. macOS parks items that do not fit off the bar (measured: x -1...7, y 1157), where they cannot be seen or clicked.
    public func isOnBar(screens: [CGRect]) -> Bool {
        guard !isUnderSystemItem else { return false }
        // `size`, not `width`: CGRect.width is the absolute value, which would let a negative size through.
        guard frame.size.width > 0, frame.size.height > 0 else { return false }
        let area = frame.width * frame.height
        for screen in screens {
            let band = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: Self.barBand)
            let overlap = frame.intersection(band)
            if !overlap.isNull, overlap.width * overlap.height >= area / 2 { return true }
        }
        return false
    }

    /// The system's right-hand cluster that Anode never hides: the clock and Control Center, by their system identifiers, or
    /// (when an item has none) by exactly those names. A third-party item that merely mentions a clock is not locked.
    /// Every item an Apple process draws (the system's own: Wi-Fi, battery, the microphone-in-use light, Now Playing, …) is
    /// locked, and so are the clock and Control Center by name. A locked item always stays on the bar, is never covered and
    /// cannot be moved behind the chevron: the owner asked for system items to be left alone, and a privacy indicator under
    /// a cover is the worst case (seen 2026-11-11).
    public static func isLockedItem(bundleID: String? = nil, identifier: String?, title: String?) -> Bool {
        if let owner = bundleID?.lowercased(), owner.hasPrefix("com.apple.") { return true }
        if let id = identifier?.lowercased(), id == "com.apple.menuextra.clock" || id == "com.apple.menuextra.controlcenter" { return true }
        guard identifier?.isEmpty ?? true, let name = title?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return name == "clock" || name == "control center"
    }
}

public enum BarItemKey {
    /// `"<bundle id or app name>|<identifier, else title, else description, else #ordinal>"`, with `#<ordinal>` appended
    /// when a named item is not the first of its name. The position is not in it, so the key survives the item moving.
    /// `ordinal` is the item's index, left to right, among that app's items that share its name (or among its unnamed
    /// ones), which is what tells apart two items with the same name (OpenVPN shows two).
    public static func make(bundleID: String?, appName: String, identifier: String?, title: String?,
                            description: String?, ordinal: Int) -> String {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        let owner = clean(bundleID) ?? appName
        if let name = clean(identifier) ?? clean(title) ?? clean(description) {
            return ordinal > 0 ? "\(owner)|\(name)#\(ordinal)" : "\(owner)|\(name)"
        }
        return "\(owner)|#\(ordinal)"
    }
}

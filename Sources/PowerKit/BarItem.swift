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

    /// How far down from the top of a screen an item can sit and still be on the bar.
    public static let barBand: CGFloat = 40

    /// Whether the item is drawn on a menu bar: it has a size, and at least half of it lies inside the top band of some
    /// screen. macOS parks items that do not fit off the bar (measured: x -1...7, y 1157), where they cannot be seen or clicked.
    public func isOnBar(screens: [CGRect]) -> Bool {
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

    /// The system's right-hand cluster that Anode never hides: the clock and Control Center.
    public static func isLockedItem(identifier: String?, title: String?) -> Bool {
        let hay = [identifier, title].compactMap { $0?.lowercased() }
        return hay.contains { $0.contains("clock") || $0.contains("controlcenter") || $0.contains("control center") }
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

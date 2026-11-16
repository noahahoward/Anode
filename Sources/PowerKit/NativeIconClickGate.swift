import CoreGraphics

/// Decides, for each press and release of the mouse, whether Anode takes it for itself as a click on macOS's own Sound icon
/// (and opens its own menu) or leaves it alone.
///
/// A press is taken only when it lands near the icon's last known frame AND a fresh look at what is under the pointer says it
/// really is that icon (the bar may have moved since the frame was read: the other items change width and push it along, so the
/// frame is only a rough guide and the fresh look decides), and only without Command, Option or Control held:
/// Command-drag is how a person rearranges menu bar icons. The release that goes with a press taken is taken too, wherever the
/// pointer has gone, so macOS never sees half a click.
public struct NativeIconClickGate {

    public enum Phase { case down, up }
    public enum Verdict: Equatable { case pass, swallow, swallowAndOpen }

    private var swallowedPress = false

    public init() {}

    /// How far either side of the last known frame a press is still worth a fresh look.
    public static let slack: CGFloat = 48

    /// `isTheIcon` is asked only for a press near `icon` (in the menu bar, within `slack` of it): it can be slow, and everything
    /// else must stay instant.
    public mutating func decide(_ phase: Phase, at point: CGPoint, modifiers: Bool, icon: CGRect?,
                                isTheIcon: () -> Bool) -> Verdict {
        switch phase {
        case .up:
            defer { swallowedPress = false }
            return swallowedPress ? .swallow : .pass
        case .down:
            swallowedPress = false
            guard !modifiers, let icon, Self.isNear(point, icon), isTheIcon() else { return .pass }
            swallowedPress = true
            return .swallowAndOpen
        }
    }

    /// In the menu bar, and not more than `slack` points from the icon's last known frame sideways.
    public static func isNear(_ point: CGPoint, _ icon: CGRect) -> Bool {
        point.y >= icon.minY - icon.minY && point.y <= icon.maxY + 6 && point.x >= icon.minX - slack && point.x <= icon.maxX + slack
    }
}

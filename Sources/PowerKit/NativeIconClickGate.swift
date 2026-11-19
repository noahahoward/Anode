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
    public mutating func decide(_ phase: Phase, at point: CGPoint, modifiers: Bool, icon: CGRect?, bar: CGRect? = nil,
                                isTheIcon: () -> Bool) -> Verdict {
        switch phase {
        case .up:
            defer { swallowedPress = false }
            return swallowedPress ? .swallow : .pass
        case .down:
            swallowedPress = false
            guard !modifiers, let icon, Self.isNear(point, icon, bar: bar), isTheIcon() else { return .pass }
            swallowedPress = true
            return .swallowAndOpen
        }
    }

    /// Not more than `slack` points sideways of the icon's last known frame, and no higher or lower than the item it sits in (`bar`:
    /// the icon is a small square in the middle of an item as tall as the bar, and the whole height is the item), or, when that is
    /// not known, 6 above or below the icon.
    public static func isNear(_ point: CGPoint, _ icon: CGRect, bar: CGRect? = nil) -> Bool {
        let top = min(icon.minY - 6, bar?.minY ?? .infinity), bottom = max(icon.maxY + 6, bar?.maxY ?? -.infinity)
        return point.y >= top && point.y <= bottom && point.x >= icon.minX - slack && point.x <= icon.maxX + slack
    }

    /// Where the icon and its item are when the menu bar is on the screen. With the bar set to hide, Accessibility reports the items
    /// where the bar is while hidden, above the top edge, so a click on the icon of a bar that has just slid in (before the next look)
    /// landed nowhere near the frame the gate had, and went to macOS. The icon's place along the bar is the same hidden or shown; only
    /// its height differs, so a frame above the top edge is brought down to where the bar sits when it is shown (its top at 0).
    public static func shownPosition(icon: CGRect, bar: CGRect?) -> (icon: CGRect, bar: CGRect?) {
        let top = min(icon.minY, bar?.minY ?? .infinity)
        guard top < 0 else { return (icon, bar) }
        let shift = -top
        return (icon.offsetBy(dx: 0, dy: shift), bar?.offsetBy(dx: 0, dy: shift))
    }

    /// Whether a click is on the still picture Anode keeps over `icon` while macOS's panel is read: the icon's own width and the
    /// room the picture has round it (`IconCoverGeometry`), not the wider slack of `isNear`: a neighbouring icon is inside that.
    public static func isOnCover(_ point: CGPoint, of icon: CGRect, bar: CGRect? = nil) -> Bool {
        let cover = IconCoverGeometry.rect(for: icon)
        return isNear(point, icon, bar: bar) && point.x >= cover.minX && point.x <= cover.maxX
    }
}

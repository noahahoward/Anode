import CoreGraphics

/// Decides, for each press and release of the mouse, whether Anode takes it for itself as a click on macOS's own Sound icon
/// (and opens its own menu) or leaves it alone.
///
/// A press is taken only when it lands inside the icon's last known frame AND a fresh look at what is under the pointer says it
/// really is that icon (the bar may have moved since the frame was read), and only without Command, Option or Control held:
/// Command-drag is how a person rearranges menu bar icons. The release that goes with a press taken is taken too, wherever the
/// pointer has gone, so macOS never sees half a click.
public struct NativeIconClickGate {

    public enum Phase { case down, up }
    public enum Verdict: Equatable { case pass, swallow, swallowAndOpen }

    private var swallowedPress = false

    public init() {}

    /// `isTheIcon` is asked only for a press inside `icon`: it can be slow, and everything else must stay instant.
    public mutating func decide(_ phase: Phase, at point: CGPoint, modifiers: Bool, icon: CGRect?,
                                isTheIcon: () -> Bool) -> Verdict {
        switch phase {
        case .up:
            defer { swallowedPress = false }
            return swallowedPress ? .swallow : .pass
        case .down:
            swallowedPress = false
            guard !modifiers, let icon, icon.contains(point), isTheIcon() else { return .pass }
            swallowedPress = true
            return .swallowAndOpen
        }
    }
}

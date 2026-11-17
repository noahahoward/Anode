import CoreGraphics

/// Where the picture that stands in for macOS's Sound icon goes while its panel is read. Whole points, because a cover placed
/// between pixels shows an edge.
public enum IconCoverGeometry {
    /// The icon with room each side for the pill macOS lights round it (about 11 pt past the icon, measured at 120 fps), at least
    /// 33 pt tall, and no lower than `barBottom` (the bottom of the menu bar, when known): under the bar is a window, which a
    /// still picture would show stale after it moved.
    public static func rect(for frame: CGRect, barBottom: CGFloat?) -> CGRect {
        let top = CGFloat(Int(frame.minY))
        var height = CGFloat(Int(max(frame.height, 33)))
        if let barBottom { height = min(height, max(1, barBottom - top)) }
        return CGRect(x: CGFloat(Int(frame.minX) - 13), y: top, width: CGFloat(Int(frame.width) + 26), height: height)
    }
}

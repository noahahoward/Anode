import CoreGraphics

/// Where the picture that stands in for macOS's Sound icon goes while its panel is read. Whole points, because a cover placed
/// between pixels shows an edge.
public enum IconCoverGeometry {
    /// The icon with room each side for the pill macOS lights round it, and no more. Measured on the lit pill (macOS's panel open,
    /// against the idle bar): it spans the icon's rows exactly (y 8 to 31 for an icon at 8.5 to 30.5) and reaches about 9 pt either
    /// side. The cover is one point taller each way and 13 wider each side, and stops there: the rest of the bar's height belongs
    /// to a bar whose lower edge darkens with whatever window is under it, and a still picture of that edge, taken a moment before,
    /// shows as a patch when the window has since moved.
    public static func rect(for frame: CGRect) -> CGRect {
        CGRect(x: CGFloat(Int(frame.minX) - 13), y: CGFloat(Int(frame.minY) - 1),
               width: CGFloat(Int(frame.width) + 26), height: CGFloat(Int(frame.height) + 4))
    }
}

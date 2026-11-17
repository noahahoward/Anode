import CoreGraphics

/// Every size of macOS's Battery menu, in points, measured on macOS 27 (dark, 14" MacBook Pro) from Accessibility frames and the
/// pixel rows of a screenshot of the panel. Positions are from the panel's top-left corner. (The Sound menu is 309 wide with rows set
/// in 5; this one is 308 with everything set in 14.)
public enum BatteryMenuMetrics {
    public static let width: CGFloat = 308
    public static let inset: CGFloat = 14
    public static let contentWidth: CGFloat = 280
    public static let titleY: CGFloat = 12
    public static let titleHeight: CGFloat = 16
    public static let powerSourceY: CGFloat = 37.5
    public static let powerSourceHeight: CGFloat = 15
    public static let firstDividerY: CGFloat = 59.5
    public static let headingHeight: CGFloat = 15
    public static let energyHeadingY: CGFloat = 68.5
    public static let modeRowsY: CGFloat = 87
    public static let modeRowHeight: CGFloat = 32
    /// The line under the last mode row.
    public static let dividerGapBelowRows: CGFloat = 5.5
    public static let headingGapBelowDivider: CGFloat = 9   // from the line's top
    public static let appRowHeight: CGFloat = 22
    /// Not measured (one app was listed): taken as the row's own height.
    public static let appRowPitch: CGFloat = 22
    public static let appsFirstRowGapBelowHeading: CGFloat = 3.5   // heading 197.5 + 15 = 212.5; the row is at 216
    public static let footerRowHeight: CGFloat = 22
    public static let footerGapBelowDivider: CGFloat = 5.5
    public static let bottomPadding: CGFloat = 6.5
}

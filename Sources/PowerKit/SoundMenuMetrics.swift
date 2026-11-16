import CoreGraphics

/// Every size of macOS's Sound menu, in points, measured on macOS 27 (dark, 14" MacBook Pro): from Accessibility frames and the
/// pixel rows of a 2x capture of the panel's own window. Positions are from the panel's top-left corner. Tuned against an
/// overlay of Anode's menu on macOS's until the two differ only by what lies behind the glass.
public enum SoundMenuMetrics {
    public static let width: CGFloat = 309
    public static let titleY: CGFloat = 12
    public static let titleHeight: CGFloat = 17
    public static let sideInset: CGFloat = 14
    /// The slider and the speaker icons beside it.
    public static let sliderY: CGFloat = 37
    public static let sliderX: CGFloat = 34
    public static let sliderWidth: CGFloat = 230
    public static let sliderHeight: CGFloat = 16
    public static let firstDividerY: CGFloat = 64
    public static let headingHeight: CGFloat = 15
    public static let outputHeadingY: CGFloat = 73
    public static let deviceRowsY: CGFloat = 91
    public static let deviceRowHeight: CGFloat = 32
    public static let rowInset: CGFloat = 5
    public static let rowWidth: CGFloat = 298
    /// The lighter block under an opened device.
    public static let blockGap: CGFloat = 5          // from the device row's bottom to the block's top
    public static let blockHeadingToRows: CGFloat = 17
    public static let choiceRowHeight: CGFloat = 26
    public static let choiceRowPitch: CGFloat = 24
    public static let blockTopPadding: CGFloat = 15  // block top to the first heading
    public static let dividerGapBelowRows: CGFloat = 4     // a section's last row to the divider under it
    public static let headingGapBelowDivider: CGFloat = 10
    public static let blockBottomPadding: CGFloat = 5      // the last row of the block to the block's bottom
    public static let afterBlockGap: CGFloat = 5
    public static let footerDividerGap: CGFloat = 5        // the last device row to the divider above the buttons
    public static let footerFirstRowGap: CGFloat = 7
    public static let footerRowHeight: CGFloat = 20
    public static let footerRowPitch: CGFloat = 22
    public static let bottomPadding: CGFloat = 5.5
}

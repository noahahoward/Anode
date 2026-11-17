import Foundation

/// The Display settings of System Settings > Accessibility that change how a menu is drawn. macOS's own panels follow all three, and
/// so do the Sound and Battery menus: Reduce Transparency makes the glass solid, Increase Contrast makes the lines and the dim text
/// stronger, Reduce Motion takes away the fade as the menu closes and the springs.
public struct DisplayAccessibility: Equatable {
    public var reduceTransparency: Bool
    public var increaseContrast: Bool
    public var reduceMotion: Bool

    public init(reduceTransparency: Bool = false, increaseContrast: Bool = false, reduceMotion: Bool = false) {
        self.reduceTransparency = reduceTransparency; self.increaseContrast = increaseContrast; self.reduceMotion = reduceMotion
    }

    /// The menu has no glass: a plain panel of the appearance's colour.
    public var glassIsSolid: Bool { reduceTransparency }

    /// How long the menu fades out as it closes: not at all under Reduce Motion.
    public func fadeSeconds(_ normal: TimeInterval) -> TimeInterval { reduceMotion ? 0 : normal }

    /// Whether things move (the badge turning, rows gliding) or just change.
    public var animates: Bool { !reduceMotion }

    /// The strength of the lines between the sections (white or black at this alpha).
    public var dividerAlpha: Double { increaseContrast ? 0.30 : 0.15 }

    /// The dim text (headings, the power source): stronger under Increase Contrast.
    public func secondaryTextAlpha(dark: Double, light: Double, isDark: Bool) -> Double {
        let base = isDark ? dark : light
        return increaseContrast ? min(1, base + 0.25) : base
    }
}

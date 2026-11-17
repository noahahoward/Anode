import CoreGraphics

/// Which end of a panel hangs from the menu bar icon it belongs to. macOS 27 opens the panel of an icon with its right edge 10.5 pt
/// past the icon's (`endsAtIcon`: it opens to the left, as the Wi-Fi panel does) — except where that would put the window it opens
/// (522 pt wide, 42 pt more than the icon on the side it hangs from) out of the room it has beside the notch: an icon far to the left
/// of the bar gets its panel with the left edge 10.5 pt before the icon's (`startsAtIcon`: it opens to the right). Anode's menus open
/// where macOS's own would, so that the click does not seem to open a different menu, and the picture that hides the first frames of
/// macOS's panel lies where those frames are.
public enum PanelSide: Equatable {
    case endsAtIcon
    case startsAtIcon
}

public enum MenuPanelPlacement {

    /// How far the panel's edge is past the icon's, on the side it hangs from (measured on the screen).
    public static let edgeOverhang: CGFloat = 10.5
    /// The window macOS opens for a panel: this wide, and this far past the icon's edge (measured through Accessibility).
    public static let windowWidth: CGFloat = 522
    public static let windowOverhang: CGFloat = 42

    /// The side a window that starts at `x` was opened on, from where it starts against the two places it can start.
    public static func side(ofWindowMinX x: CGFloat, icon: CGRect) -> PanelSide {
        let startsAtIcon = icon.minX - windowOverhang
        let endsAtIcon = icon.maxX + windowOverhang - windowWidth
        return abs(x - startsAtIcon) < abs(x - endsAtIcon) ? .startsAtIcon : .endsAtIcon
    }

    /// Where a panel `width` wide starts, for the icon it hangs from.
    public static func minX(icon: CGRect, side: PanelSide, width: CGFloat) -> CGFloat {
        switch side {
        case .endsAtIcon: return icon.maxX + edgeOverhang - width
        case .startsAtIcon: return icon.minX - edgeOverhang
        }
    }

    /// A guess, for an icon macOS has not been seen to open a panel for: it opens to the left whenever its window then stays at
    /// or right of `leftLimit` (the right edge of the notch; the screen's left edge where there is none), else to the right.
    public static func predictedSide(for icon: CGRect, leftLimit: CGFloat) -> PanelSide {
        icon.maxX + windowOverhang - windowWidth >= leftLimit ? .endsAtIcon : .startsAtIcon
    }

    /// Whether a panel `width` wide, hanging from `icon` on `side`, stays on the screen. macOS does not open one that would not.
    public static func fits(_ side: PanelSide, icon: CGRect, width: CGFloat, screen: CGRect) -> Bool {
        let x = minX(icon: icon, side: side, width: width)
        return x >= screen.minX && x + width <= screen.maxX
    }

    /// The part of the screen macOS's panel is in for its first frames (the panel, 2 pt under the bar, and room round it for its
    /// shadow), on each of `sides`; the picture that hides those frames lies over it. Never past the screen: a picture of a place
    /// that is not on the screen is shorter than the window it is shown in, and comes out stretched.
    public static func region(for icon: CGRect, sides: [PanelSide], width: CGFloat, screen: CGRect) -> CGRect {
        let wanted = sides.map { side in
            CGRect(x: CGFloat(Int(minX(icon: icon, side: side, width: width)) - 28), y: 40, width: width + 56, height: 600)
        }.reduce(CGRect.null) { $0.union($1) }
        return wanted.intersection(screen)
    }
}

/// What has been seen of the sides macOS opened panels on, by where the icon was. An icon is the same icon within a few points
/// (its neighbours change width and push it along). What is not seen is worked out from what is: an icon further left than one whose
/// panel opened to the right opens to the right too, and one further right than one whose panel opened to the left opens to the
/// left; else it is the guess (`MenuPanelPlacement.predictedSide`).
public struct PanelSideMemory {

    private var seen: [(x: CGFloat, side: PanelSide)] = []

    public init() {}

    /// How far apart two readings of an icon's position can be and still be one icon.
    public static let sameIcon: CGFloat = 3

    private func exact(_ icon: CGRect) -> PanelSide? {
        seen.min { abs($0.x - icon.minX) < abs($1.x - icon.minX) }.flatMap { abs($0.x - icon.minX) <= Self.sameIcon ? $0.side : nil }
    }

    public func knows(_ icon: CGRect) -> Bool { exact(icon) != nil }

    public func side(for icon: CGRect, leftLimit: CGFloat) -> PanelSide {
        if let known = exact(icon) { return known }
        if seen.contains(where: { $0.side == .startsAtIcon && $0.x >= icon.minX }) { return .startsAtIcon }
        if seen.contains(where: { $0.side == .endsAtIcon && $0.x <= icon.minX }) { return .endsAtIcon }
        return MenuPanelPlacement.predictedSide(for: icon, leftLimit: leftLimit)
    }

    /// Notes the side a panel was opened on. True when that is not what `side(for:leftLimit:)` would have said just before.
    @discardableResult
    public mutating func learn(_ side: PanelSide, for icon: CGRect, leftLimit: CGFloat) -> Bool {
        let before = self.side(for: icon, leftLimit: leftLimit)
        seen.removeAll { abs($0.x - icon.minX) <= Self.sameIcon }
        seen.append((icon.minX, side))
        return before != side
    }
}

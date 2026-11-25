import Foundation

/// Which internal-layout picture applies to a Mac.
///
/// Decided from traits (chip, fans, battery, built-in display), never from a
/// model-identifier table: a table goes stale the day a new model ships, while
/// the traits describe the hardware itself. A Mac that matches no rule gets
/// `.generic`, which draws no layout claim at all.
public enum MacFamily: String, Equatable {
    case macBookPro14ProMax
    case macBookPro16ProMax
    case macBookPro14Base
    case macBookNeo
    case macMiniM4
    case generic
}

/// What the hardware says about itself, as plain values so the decision can be
/// tested on any machine.
public struct MacTraits: Equatable {
    /// The model identifier (for example "Mac17,9"). Carried for display; the
    /// resolver never reads it.
    public var model: String
    /// The chip's marketing string (for example "Apple M5 Pro").
    public var chip: String
    public var fans: FanPresence.State
    public var hasBattery: Bool
    /// Pixel width of the built-in display, or nil when there is none.
    public var builtInDisplayPixelWidth: Int?

    public init(model: String,
                chip: String,
                fans: FanPresence.State,
                hasBattery: Bool,
                builtInDisplayPixelWidth: Int?) {
        self.model = model
        self.chip = chip
        self.fans = fans
        self.hasBattery = hasBattery
        self.builtInDisplayPixelWidth = builtInDisplayPixelWidth
    }
}

public enum MacFamilyResolver {

    /// Picks the layout family from traits. Anything that does not match a rule
    /// exactly, including `.unknown` fans, is `.generic`: a wrong picture is
    /// worse than no picture.
    public static func resolve(_ t: MacTraits) -> MacFamily {
        // The fanless A18 laptop.
        if t.chip.contains("A18") {
            return t.fans == .fanless ? .macBookNeo : .generic
        }

        // Laptops: a battery and a built-in display.
        if t.hasBattery, let width = t.builtInDisplayPixelWidth {
            let isBigChip = t.chip.contains("Pro") || t.chip.contains("Max") || t.chip.contains("Ultra")
            switch (width, isBigChip, t.fans) {
            case (3024, true, .fans(2)):  return .macBookPro14ProMax
            case (3456, true, .fans(2)):  return .macBookPro16ProMax
            case (3024, false, .fans(1)): return .macBookPro14Base
            default:                      return .generic
            }
        }

        // The desktop: no battery, no built-in display, one fan.
        if !t.hasBattery, t.builtInDisplayPixelWidth == nil,
           t.fans == .fans(1), t.chip.contains("M4") {
            return .macMiniM4
        }

        return .generic
    }
}

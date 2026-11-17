import Foundation

/// How macOS's Battery panel moves, measured at 120 frames a second.
public enum BatteryMenuMotion {

    /// A chosen Energy Mode's badge turns from grey to blue (the old one back) on a critically damped spring.
    public static let badgeOmega = 15.0
    public static let badgeSettleSeconds = 0.6

    /// How far the badge's colour has gone, 0 to 1, `t` seconds after it started.
    public static func badge(at t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < badgeSettleSeconds else { return 1 }
        let u = badgeOmega * t
        return 1 - (1 + u) * exp(-u)
    }

    /// The panel fades out in a straight line.
    public static let fadeOutSeconds = 0.24

    /// How opaque the panel still is, 1 to 0, `t` seconds into the fade.
    public static func fadeOutAlpha(at t: Double) -> Double {
        guard t > 0 else { return 1 }
        guard t < fadeOutSeconds else { return 0 }
        return 1 - t / fadeOutSeconds
    }
}

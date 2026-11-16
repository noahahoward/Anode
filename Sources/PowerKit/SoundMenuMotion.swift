import Foundation

/// How macOS's Sound panel moves, measured at 120 frames a second: when a row appears or goes the bottom edge (and the footer with
/// it) glides to the new height, fast at first and settling in about half a second; the panel opens at once and fades out in about
/// 70 ms.
public enum SoundMenuMotion {

    /// Natural frequency of the critically damped spring that fits the measured heights (rad/s).
    public static let omega = 11.5
    /// Seconds after which the glide is over for all that can be seen.
    public static let settleSeconds = 0.75
    /// The fade when the menu closes.
    public static let fadeOutSeconds = 0.07

    /// How far along the glide is, 0 to 1, `t` seconds after it started.
    public static func progress(at t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < settleSeconds else { return 1 }
        let u = omega * t
        return 1 - (1 + u) * exp(-u)
    }
}

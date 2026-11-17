import CoreGraphics
import Foundation

/// How macOS 27's slider knob becomes a glass lens while it is held, and turns back when let go (measured on macOS's own panel with
/// a 120 fps recording; see LensMotionTests).
public enum LensMotion {
    /// The held lens, outer ring included: the idle knob is 20 x 16 pt.
    public static let heldSize = CGSize(width: 26, height: 20.5)
    /// The lens appears at this fraction of its held size and grows from there, its top-left corner fixed.
    public static let startScale: CGFloat = 0.75
    /// Fitted to the measured widths: a critically damped spring, which does not overshoot.
    static let omega = 36.0

    public static func pressScale(at t: TimeInterval) -> CGFloat {
        guard t > 0 else { return startScale }
        let progress = 1 - (1 + omega * t) * exp(-omega * t)
        return startScale + (1 - startScale) * CGFloat(progress)
    }

    public static func isGrown(at t: TimeInterval) -> Bool { pressScale(at: t) > 0.9995 }

    public static let releaseDuration: TimeInterval = 0.05
    /// What the lens looks like `t` seconds after it was let go: its size (as a fraction of the held size), how much of its dark ring
    /// is left, and how much of the solid white knob has come in over it.
    public static func release(at t: TimeInterval) -> (scale: CGFloat, ring: CGFloat, knob: CGFloat) {
        let p = CGFloat(min(1, max(0, t / releaseDuration)))
        let eased = 1 - (1 - p) * (1 - p)
        return (1 - 0.23 * eased, 1 - eased, eased)
    }

    public static func isReleased(at t: TimeInterval) -> Bool { t >= releaseDuration }
}

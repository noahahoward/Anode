import Foundation

/// Deciding from a stream of lid angles that the lid is being closed, and how much frost that means.

/// Watches angles and says when a close begins and when it is undone.
///
/// A close is a quick downward run (at least `minSpeed` degrees a second, covering at least `minDrop` degrees)
/// that has reached the trigger angle. The run may have started above the trigger or below it: people work
/// with the lid at 100–120°, so a trigger of 110° that demanded a crossing would never fire for someone
/// whose lid already rests at 105°. A lid that merely sits below the trigger, or drifts, never fires.
public struct LidCloseDetector {

    public enum Event: Equatable { case none, closing, reopened }

    /// Degrees a second a downward run must be at least as fast as.
    public static let minSpeed = 15.0
    /// Degrees a downward run must cover before it counts.
    public static let minDrop = 6.0

    public var trigger: Double
    public private(set) var isActive = false
    /// The angle the frost is measured from while a close is active: the trigger, or the angle the run began at
    /// if that was lower.
    public private(set) var armedFrom: Double?

    private var previous: (angle: Double, time: TimeInterval)?
    private var runStart: Double?

    public init(trigger: Double) { self.trigger = trigger }

    public mutating func reset() {
        isActive = false; armedFrom = nil; previous = nil; runStart = nil
    }

    public mutating func feed(angle: Double, time: TimeInterval) -> Event {
        defer { previous = (angle, time) }
        guard let last = previous else { return .none }

        if isActive {
            if let from = armedFrom, angle > from {
                isActive = false; armedFrom = nil; runStart = nil
                return .reopened
            }
            return .none
        }

        let dt = time - last.time
        guard dt > 0 else { return .none }
        let speedDown = (last.angle - angle) / dt
        if speedDown >= Self.minSpeed {
            runStart = runStart ?? last.angle
        } else {
            runStart = nil
        }
        if let start = runStart, angle <= trigger, start - angle >= Self.minDrop {
            isActive = true
            armedFrom = min(trigger, start)
            return .closing
        }
        return .none
    }
}

/// Turns the sensor's ten-a-second steps into a value that moves smoothly at the screen's refresh rate.
/// Critically damped, so it follows without overshooting.
public struct LidSpring {
    /// Radians a second. Higher follows the target faster and smooths less.
    public static let frequency = 16.0
    /// The longest step it will integrate; a stalled frame must not throw the value.
    public static let maxStep = 1.0 / 30

    public private(set) var value: Double
    private var velocity = 0.0

    public init(value: Double = 0) { self.value = value }

    public mutating func advance(to target: Double, dt: Double) {
        let dt = min(max(dt, 0), Self.maxStep)
        let f = Self.frequency
        velocity += (f * f * (target - value) - 2 * f * velocity) * dt
        value += velocity * dt
    }

    public mutating func reset(to newValue: Double) {
        value = newValue
        velocity = 0
    }
}

/// How frosted the glass is at a lid angle: nothing at `trigger` and above, fully frosted at `darkAngle` and
/// below, easing in between.
public struct LidBlurCurve {
    /// The angle by which the strongest frost is reached. The built-in display goes dark a little before the
    /// lid is shut, so the frost must be complete before that; replaced by a measured value in Task 9.
    public static let defaultDarkAngle = 5.0

    public let trigger: Double
    public let darkAngle: Double

    public init(trigger: Double, darkAngle: Double = LidBlurCurve.defaultDarkAngle) {
        self.trigger = trigger
        self.darkAngle = darkAngle
    }

    public func amount(at angle: Double) -> Double {
        guard trigger > darkAngle else { return angle > trigger ? 0 : 1 }
        let t = min(max((trigger - angle) / (trigger - darkAngle), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

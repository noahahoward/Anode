import Foundation

/// Deciding from a stream of lid angles that the lid is being closed, and smoothing the sensor's steps.

/// Watches angles and says when a close begins and when it is undone.
///
/// A close is a quick downward run (at least `minSpeed` degrees a second, covering at least `minDrop` degrees)
/// that has reached the trigger angle. The run may have started above the trigger or below it: people work
/// with the lid at 100–120°, so a trigger of 110° that demanded a crossing would never fire for someone
/// whose lid already rests at 105°. A lid that merely sits below the trigger, or drifts, never fires.
public struct LidCloseDetector {

    /// `armed`: a steady descent has begun but is not yet a confirmed close; the moment to warm the picture.
    public enum Event: Equatable { case none, armed, closing, reopened }

    /// Degrees a second a downward run must be at least as fast as.
    public static let minSpeed = 15.0
    /// Degrees a downward run must cover before it counts.
    /// Small enough that one fast step of the sensor confirms a close (a quick close steps 4-6 degrees every tenth
    /// of a second); a nudge that is wrongly confirmed is shown flat, identical to the screen, and cleared again.
    public static let minDrop = 3.0
    /// The sensor changes about ten times a second, however fast it is read, so a repeated reading is normal. A
    /// run survives repeats for this long; a lid that has not changed for longer has paused.
    public static let maxFlat = 0.35
    /// The longest a change is taken to have been in coming: the sensor's period, with a little slack. After a long
    /// rest the first change would otherwise look like a crawl.
    public static let sensorPeriod = 0.12

    /// A close slow enough to watch is a steady descent, not a fast step: this much net travel...
    public static let slowMinDrop = 4.0
    /// ...over at least this long (so a flick that stops is not one)...
    public static let slowMinTime = 0.25
    /// ...at no less than this average speed (degrees a second)...
    public static let slowMinSpeed = 5.0
    /// ...looking back no further than this, and never climbing by more than this between readings (so a wander
    /// or a hand that is settling is not one).
    public static let slowWindow = 0.8
    public static let slowBacktrack = 1.0
    /// A descent shows itself this early: this much net travel, for this long, at this average speed, and no further
    /// than this many degrees above the trigger.
    public static let armMinDrop = 2.0
    public static let armMinTime = 0.15
    public static let armMinSpeed = 5.0
    public static let armZone = 25.0

    public var trigger: Double
    public private(set) var isActive = false
    /// The angle the frost was measured from in the first version; the trigger, or where the run began if lower.
    public private(set) var armedFrom: Double?

    private var previous: (angle: Double, time: TimeInterval)?
    /// The last reading that differed from the one before it.
    private var lastChange: (angle: Double, time: TimeInterval)?
    private var runStart: Double?
    /// Recent readings that changed, newest last, for the slow path.
    private var history: [(angle: Double, time: TimeInterval)] = []
    private var armedSent = false

    public init(trigger: Double) { self.trigger = trigger }

    public mutating func reset() {
        isActive = false; armedFrom = nil; previous = nil; lastChange = nil; runStart = nil; history = []; armedSent = false
    }

    /// A steady descent over the last moments: enough net travel, for long enough, fast enough on average, without
    /// climbing back along the way.
    private mutating func slowClose(angle: Double, time: TimeInterval, restedAt: (angle: Double, time: TimeInterval)) -> Event {
        // A lid that has rested began this descent within the last sensor period: seed the window with where it was.
        if history.isEmpty { history = [(restedAt.angle, max(restedAt.time, time - Self.sensorPeriod))] }
        history.append((angle, time))
        history.removeAll { time - $0.time > Self.slowWindow }
        guard let oldest = history.first else { return .none }
        let drop = oldest.angle - angle, elapsed = max(time - oldest.time, 1e-6)
        var steady = true
        var low = oldest.angle
        for reading in history.dropFirst() {
            if reading.angle > low + Self.slowBacktrack { steady = false; break }
            low = min(low, reading.angle)
        }
        guard steady else { armedSent = false; return .none }

        if angle <= trigger, drop >= Self.slowMinDrop, elapsed >= Self.slowMinTime, drop / elapsed >= Self.slowMinSpeed {
            isActive = true
            armedFrom = min(trigger, oldest.angle)
            armedSent = false
            return .closing
        }
        let descending = angle <= trigger + Self.armZone && drop >= Self.armMinDrop
            && elapsed >= Self.armMinTime && drop / elapsed >= Self.armMinSpeed
        if descending, !armedSent {
            armedSent = true
            return .armed
        }
        if !descending { armedSent = false }
        return .none
    }

    public mutating func feed(angle: Double, time: TimeInterval) -> Event {
        defer { previous = (angle, time) }
        guard let last = previous, let changed = lastChange else {
            lastChange = (angle, time)
            return .none
        }

        if isActive {
            if angle != changed.angle { lastChange = (angle, time) }
            if let from = armedFrom, angle > from {
                isActive = false; armedFrom = nil; runStart = nil
                return .reopened
            }
            return .none
        }

        // A repeated reading is no news: it neither extends nor ends a run, unless the lid has been still a while.
        if angle == changed.angle {
            if time - changed.time > Self.maxFlat { runStart = nil }
            return .none
        }

        // A reading that changed. It happened some time after the previous sample, and no earlier than the last
        // change; held readings make that interval uncertain, so take the sensor's period as its upper bound.
        let dt = max(time - last.time, min(time - changed.time, Self.sensorPeriod))
        lastChange = (angle, time)
        guard dt > 0 else { return .none }
        let speedDown = (changed.angle - angle) / dt
        if speedDown >= Self.minSpeed {
            runStart = runStart ?? changed.angle
        } else {
            runStart = nil
        }
        if let start = runStart, angle <= trigger, start - angle >= Self.minDrop {
            isActive = true
            armedFrom = min(trigger, start)
            return .closing
        }
        return slowClose(angle: angle, time: time, restedAt: changed)
    }
}

/// Turns the sensor's ten-a-second steps into a value that moves smoothly at the screen's refresh rate.
/// Critically damped, so it follows without overshooting.
public struct LidSpring {
    /// Radians a second. Higher follows the target faster and smooths less. 30 keeps the drawn angle within about 3° of the
    /// real lid at 50°/s while the tracker supplies the smoothness (measured with a scripted close at 120 fps: 16 trailed by 6°).
    public static let frequency = 30.0
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

/// Turns the sensor's stepped readings into a velocity, and carries the last movement forward between updates so
/// the fold moves on every frame instead of stepping ten times a second. (After Mac Duo's `AngleTracker`,
/// github.com/ninobc/mac-duo, MIT; see LidFold.swift for the notice.)
public struct LidAngleTracker {

    /// How far past the last change the angle is carried on: the sensor's period, with a little slack.
    public static let horizon = 0.11
    /// A reading unchanged for this long means the lid has stopped.
    public static let stillAfter = 0.4

    public private(set) var angle = 0.0
    /// Degrees a second; negative while closing.
    public private(set) var velocity = 0.0
    private var lastAngle: Double?
    private var lastChange: TimeInterval = 0

    public init() {}

    public mutating func reset(to angle: Double, at time: TimeInterval) {
        self.angle = angle
        velocity = 0
        lastAngle = angle
        lastChange = time
    }

    public mutating func ingest(_ reading: Double, at time: TimeInterval) {
        angle = reading
        guard let previous = lastAngle else {
            lastAngle = reading
            lastChange = time
            return
        }
        if reading != previous {
            let dt = time - lastChange
            if dt > 0.001 {
                velocity = 0.5 * ((reading - previous) / dt) + 0.5 * velocity
            }
            lastAngle = reading
            lastChange = time
        } else if time - lastChange > Self.stillAfter {
            velocity = 0
        }
    }

    /// Where the lid most likely is at `time`.
    public func extrapolated(at time: TimeInterval) -> Double {
        let age = min(max(time - lastChange, 0), Self.horizon)
        return min(max(angle + velocity * age, 0), 180)
    }
}

import AppKit
import PowerKit

// ── Hardware View: the fan blades' motion ───────────────────────────────────
//
// The impeller is drawn by HardwareFanPipeDrawing.swift from `fanAngles`; this file turns the angles. Nothing here owns a
// timer, a thread or an observer: while a fan is spinning and the picture can be seen, one closure is registered with `Motion`
// (which runs one 60 Hz timer only while something is moving) and it ends itself the moment the picture cannot be seen, no
// fan is spinning, or Reduce Motion is on. At most one step in 50 ms is taken, and only the fans' own areas are repainted.

/// How fast a blade turns, and one step of it.
enum FanBladeSpin {

    /// Turns per second shown for a fan: 0 when parked, else 0.35 at its minimum speed up to 1.6 at its maximum (a picture
    /// of speed, not the real rate: a real fan at 6000 rpm is 100 turns a second, which a screen cannot show). A fan whose
    /// range is empty or reversed counts as at its minimum (0.35). Anything not a finite number gives 0.
    static func turnsPerSecond(rpm: Double, minRPM: Double, maxRPM: Double) -> Double {
        guard rpm.isFinite, minRPM.isFinite, maxRPM.isFinite, rpm > 0 else { return 0 }
        var fraction = 0.0
        if maxRPM > minRPM {
            fraction = max(0, min(1, (rpm - minRPM) / (maxRPM - minRPM)))
        }
        return 0.35 + 1.25 * fraction
    }

    /// The angle in radians after `dt` seconds at `turnsPerSecond`, wrapped into 0..<2π. A negative or non-finite `dt` (or
    /// rate) turns nothing; a non-finite `angle` starts again from 0.
    static func advance(angle: Double, turnsPerSecond: Double, dt: Double) -> Double {
        let start = angle.isFinite ? angle : 0
        var next = start
        if dt.isFinite, dt > 0, turnsPerSecond.isFinite, turnsPerSecond > 0 {
            next = start + 2 * Double.pi * turnsPerSecond * dt
        }
        return wrap(next)
    }

    private static func wrap(_ x: Double) -> Double {
        guard x.isFinite else { return 0 }
        let full = 2 * Double.pi
        var r = x.truncatingRemainder(dividingBy: full)
        if r < 0 { r += full }
        // A tiny negative remainder plus 2π can round to exactly 2π.
        return r < full ? r : 0
    }
}

extension HardwareCanvasView {

    /// The smallest time between two turns of the blades: the picture moves at most 20 times a second.
    static let fanStep: TimeInterval = 0.05

    /// Whether the blades should be turning now: the window says the picture can be seen, at least one fan is spinning,
    /// Reduce Motion is off, and Ultra Low Power Mode is off (it reads no fans, so the speed shown would be from before it,
    /// and an animation costs the power the mode is saving).
    var fanAnimationWanted: Bool {
        !UltraQuiet.isOn
            && isDrawableNow()
            && (readings?.fans.contains { $0.rpm > 0 } ?? false)
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// True while the blades' animation is registered with `Motion` and still moving.
    var isAnimatingFans: Bool { fanAnimationLive }

    /// Starts the blades turning when they should be and are not; marks them stopped when they should not be (the closure
    /// then ends itself at its next frame). Called whenever a reading arrives and when the view changes window.
    func refreshFanAnimation() {
        if fanAnimationWanted {
            guard !fanAnimationLive else { return }
            fanAnimationLive = true
            fanAccumulated = 0
            Motion.shared.start(fanClock) { [weak self] dt in
                guard let self = self else { return false }
                return self.stepFanAnimation(dt)
            }
        } else {
            fanAnimationLive = false
        }
    }

    /// One frame of the animation: returns whether it is still moving. Re-checks the condition every frame (this is how it
    /// stops for a hidden, covered or minimised window, or when every fan parks). Turns the blades only once 50 ms has gathered.
    func stepFanAnimation(_ dt: TimeInterval) -> Bool {
        guard fanAnimationWanted else {
            fanAnimationLive = false
            return false
        }
        fanAccumulated += max(0, dt)
        guard fanAccumulated >= Self.fanStep else { return true }
        let elapsed = fanAccumulated
        fanAccumulated = 0
        for fan in readings?.fans ?? [] where fan.index >= 0 && fan.index < 64 {
            while fanAngles.count <= fan.index { fanAngles.append(0) }
            let turns = FanBladeSpin.turnsPerSecond(rpm: fan.rpm, minRPM: fan.minRPM, maxRPM: fan.maxRPM)
            fanAngles[fan.index] = FanBladeSpin.advance(angle: fanAngles[fan.index], turnsPerSecond: turns, dt: elapsed)
        }
        for rect in fanRepaintRects() { setNeedsDisplay(rect) }
        return true
    }

    /// The fans' areas in view points, a few points larger than the fan's own box.
    private func fanRepaintRects() -> [NSRect] {
        hardwareLayout.components.compactMap { component in
            guard case .fan = component.kind, let r = component.rect else { return nil }
            return viewRect(fromLayout: r).insetBy(dx: -4, dy: -4)
        }
    }
}

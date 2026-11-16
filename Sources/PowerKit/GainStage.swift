import Foundation

/// The volume of one app's sound, applied buffer by buffer on the audio thread. Gain changes ramp over 10 ms whatever the buffer
/// size, so a slider or the mute button never clicks, and the result is held to full scale.
///
/// `setTarget` may be called from one other thread; `render` only from the audio thread. Nothing in `render` allocates, locks or
/// calls into Objective-C: the one value that crosses threads is the target, a single aligned 32-bit float.
public final class GainStage {
    public static let rampSeconds = 0.010

    private let channels: Int
    private let rampFrames: Float
    private let target: UnsafeMutablePointer<Float>
    private var current: Float
    private var step: Float = 0
    private var goal: Float

    public init(channels: Int, sampleRate: Double, initialGain: Float) {
        self.channels = max(1, channels)
        self.rampFrames = Float(max(1, GainStage.rampSeconds * sampleRate))
        target = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        target.initialize(to: initialGain)
        current = initialGain
        goal = initialGain
    }

    deinit { target.deallocate() }

    /// Where the gain should be heading. Safe from one non-audio thread.
    public func setTarget(_ gain: Float) { target.pointee = gain.isFinite ? max(0, gain) : 1 }

    /// Interleaved samples, `channels` per frame.
    public func render(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frames: Int) {
        let wanted = target.pointee
        if wanted != goal {
            goal = wanted
            step = (goal - current) / rampFrames
        }
        var f = 0
        while f < frames {
            // How far the gain still has to go, in frames; once there it is exactly the goal.
            var gain = current
            if current != goal {
                let next = current + step
                if (step > 0 && next >= goal) || (step < 0 && next <= goal) { current = goal } else { current = next }
                gain = current
            }
            let base = f * channels
            for c in 0..<channels {
                let v = input[base + c] * gain
                output[base + c] = v > 1 ? 1 : (v < -1 ? -1 : v)
            }
            f += 1
        }
    }
}

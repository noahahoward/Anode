import XCTest
@testable import PowerKit

/// The gain applied to an app's sound: smooth, never louder than the app made it, safe on the audio thread.
final class GainStageTests: XCTestCase {

    private func sine(frames: Int, channels: Int, rate: Double, amplitude: Float, hz: Double = 440, onlyChannel: Int? = nil) -> [Float] {
        var out = [Float](repeating: 0, count: frames * channels)
        for f in 0..<frames {
            let v = amplitude * Float(sin(2 * .pi * hz * Double(f) / rate))
            for c in 0..<channels where onlyChannel == nil || onlyChannel == c { out[f * channels + c] = v }
        }
        return out
    }

    private func run(_ stage: GainStage, _ input: [Float], channels: Int, chunk: Int) -> [Float] {
        var output = [Float](repeating: 0, count: input.count)
        var done = 0
        let total = input.count / channels
        while done < total {
            let n = min(chunk, total - done)
            input.withUnsafeBufferPointer { i in output.withUnsafeMutableBufferPointer { o in
                stage.render(input: i.baseAddress! + done * channels, output: o.baseAddress! + done * channels, frames: n)
            } }
            done += n
        }
        return output
    }

    func testFullVolumeLeavesTheSoundExactlyAsItWas() {
        let input = (0..<8192).map { _ in Float.random(in: -1...1) }
        let stage = GainStage(channels: 2, sampleRate: 48000, initialGain: 1)
        XCTAssertEqual(run(stage, input, channels: 2, chunk: 512), input)
    }

    func testHalfVolumeHalvesTheLoudestPoint() {
        let stage = GainStage(channels: 2, sampleRate: 48000, initialGain: 1)
        stage.setTarget(0.5)
        let out = run(stage, sine(frames: 4800, channels: 2, rate: 48000, amplitude: 0.8), channels: 2, chunk: 480)
        let tail = out[(out.count / 2)...]   // after the ramp
        XCTAssertEqual(tail.map { abs($0) }.max() ?? 0, 0.4, accuracy: 0.01)
    }

    func testTheRampTakesTenMillisecondsWhateverTheBufferSize() {
        for chunk in [64, 480, 4096] {
            let stage = GainStage(channels: 1, sampleRate: 48000, initialGain: 1)
            stage.setTarget(0)
            let out = run(stage, [Float](repeating: 1, count: 4800), channels: 1, chunk: chunk)
            let firstZero = out.firstIndex { $0 <= 0 } ?? -1
            XCTAssertEqual(firstZero, 480, accuracy: 1, "chunk \(chunk)")
            XCTAssertGreaterThan(out[240], 0.4); XCTAssertLessThan(out[240], 0.6)
        }
    }

    func testMuteAndUnmuteNeverMakeAStep() {
        let stage = GainStage(channels: 1, sampleRate: 48000, initialGain: 1)
        var input = [Float](repeating: 0.5, count: 9600)
        var out = run(stage, Array(input[0..<2400]), channels: 1, chunk: 100)
        stage.setTarget(0)
        out += run(stage, Array(input[2400..<4800]), channels: 1, chunk: 100)
        stage.setTarget(1)
        out += run(stage, Array(input[4800..<7200]), channels: 1, chunk: 100)
        input = []
        var biggest: Float = 0
        for i in 1..<out.count { biggest = max(biggest, abs(out[i] - out[i - 1])) }
        XCTAssertLessThanOrEqual(biggest, 0.5 / (0.010 * 48000) + 1e-6)
    }

    func testItIsNeverLouderThanFullScale() {
        let stage = GainStage(channels: 2, sampleRate: 48000, initialGain: 3)
        let out = run(stage, sine(frames: 2400, channels: 2, rate: 48000, amplitude: 0.9), channels: 2, chunk: 256)
        XCTAssertLessThanOrEqual(out.map { abs($0) }.max() ?? 0, 1)
    }

    func testAnyNumberOfChannelsAndAnyRate() {
        for (channels, rate) in [(1, 44100.0), (2, 48000.0), (6, 96000.0)] {
            let stage = GainStage(channels: channels, sampleRate: rate, initialGain: 1)
            stage.setTarget(0.5)
            let input = sine(frames: Int(rate / 10), channels: channels, rate: rate, amplitude: 0.8, onlyChannel: 0)
            let out = run(stage, input, channels: channels, chunk: 333)
            for c in 1..<max(1, channels) { XCTAssertTrue(stride(from: c, to: out.count, by: channels).allSatisfy { out[$0] == 0 }, "channel \(c) stays silent") }
            XCTAssertEqual(stride(from: 0, to: out.count, by: channels).map { abs(out[$0]) }.suffix(out.count / (2 * channels)).max() ?? 0, 0.4, accuracy: 0.02)
        }
    }

    func testChangingTheTargetOverAndOverStaysFinite() {
        let stage = GainStage(channels: 2, sampleRate: 48000, initialGain: 1)
        let input = sine(frames: 128, channels: 2, rate: 48000, amplitude: 0.5)
        for i in 0..<200 {
            stage.setTarget(i % 2 == 0 ? 0 : 1)
            XCTAssertTrue(run(stage, input, channels: 2, chunk: 64).allSatisfy { $0.isFinite })
        }
    }
}

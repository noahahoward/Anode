import XCTest
@testable import PowerKit

/// Between the sensor's ten updates a second the fold must keep moving, or it stutters at ten beats a second.
final class LidTrackerTests: XCTestCase {

    /// The hardware's reading at time `t` for a lid closing steadily from `start`: whole degrees, updated every 0.1 s.
    private func hardware(_ t: Double, start: Double = 125, rate: Double = 40) -> Double {
        (start - rate * (t * 10).rounded(.down) / 10).rounded()
    }

    func testItCarriesTheLastMovementForwardBetweenReadings() {
        var tr = LidAngleTracker()
        tr.reset(to: 125, at: 0)
        for (i, a) in [121.0, 117, 113, 109].enumerated() { tr.ingest(a, at: Double(i + 1) * 0.1) }
        XCTAssertLessThan(tr.velocity, -30)
        let later = tr.extrapolated(at: 0.45)
        XCTAssertLessThan(later, 109, "it has moved on from the last reading")
        XCTAssertGreaterThan(later, 100)
    }

    func testItNeverCarriesOnFurtherThanTheHorizon() {
        var tr = LidAngleTracker()
        tr.reset(to: 125, at: 0)
        for (i, a) in [121.0, 117, 113, 109].enumerated() { tr.ingest(a, at: Double(i + 1) * 0.1) }
        let capped = tr.extrapolated(at: 0.4 + LidAngleTracker.horizon)
        XCTAssertEqual(tr.extrapolated(at: 5), capped, accuracy: 1e-9)
    }

    func testAnUnchangedReadingForTooLongMeansTheLidHasStopped() {
        var tr = LidAngleTracker()
        tr.reset(to: 125, at: 0)
        for (i, a) in [121.0, 117, 113].enumerated() { tr.ingest(a, at: Double(i + 1) * 0.1) }
        tr.ingest(113, at: 0.5); tr.ingest(113, at: 0.75)
        XCTAssertEqual(tr.velocity, 0)
        XCTAssertEqual(tr.extrapolated(at: 0.8), 113)
    }

    func testRepeatedReadingsDoNotDisturbTheVelocity() {
        var a = LidAngleTracker(), b = LidAngleTracker()
        a.reset(to: 125, at: 0); b.reset(to: 125, at: 0)
        for step in 1...6 {
            let t = Double(step) * 0.1, angle = 125 - 4 * Double(step)
            a.ingest(angle, at: t)
            for extra in 1...3 { b.ingest(angle, at: t + Double(extra) * 0.02) }   // polled faster: repeats
            b.ingest(angle, at: t)
        }
        XCTAssertEqual(a.velocity, b.velocity, accuracy: 6, "polling faster must not change what the lid is doing")
    }

    /// How far the fold lags the real lid: the mean distance, in degrees, between what is drawn and where the lid truly
    /// is, once the close is under way. A spring chasing the staircase trails the lid by its own time constant.
    private func lag(extrapolating: Bool) -> Double {
        var tr = LidAngleTracker()
        tr.reset(to: 125, at: 0)
        var spring = LidSpring(value: 125)
        var errors: [Double] = []
        var lastReading = hardware(0)
        var t = 0.0
        while t < 1.6 {
            let reading = hardware(t)
            if reading != lastReading { tr.ingest(reading, at: t); lastReading = reading }
            let target = extrapolating ? tr.extrapolated(at: t) : reading
            spring.advance(to: target, dt: 1.0 / 120)
            if t > 0.6 { errors.append(abs(spring.value - (125 - 40 * t))) }
            t += 1.0 / 120
        }
        return errors.reduce(0, +) / Double(errors.count)
    }

    func testExtrapolatingKeepsTheFoldClosertoTheRealLid() {
        let raw = lag(extrapolating: false), predicted = lag(extrapolating: true)
        XCTAssertLessThan(predicted, raw * 0.85, "raw lag \(raw)°, predicted \(predicted)°")
    }
}

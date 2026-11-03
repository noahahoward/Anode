import XCTest
@testable import PowerKit

/// Deciding that the lid is closing, smoothing the 10 Hz readings, and turning an angle into frost.
final class LidMotionTests: XCTestCase {

    private func feed(_ d: inout LidCloseDetector, _ samples: [(Double, TimeInterval)]) -> [LidCloseDetector.Event] {
        samples.map { d.feed(angle: $0.0, time: $0.1) }
    }

    // ── Closing ──

    /// People work with the lid at 100–120°. Sitting there, jiggling by a degree, must never start anything.
    func testRestingBelowTheTriggerNeverCloses() {
        var d = LidCloseDetector(trigger: 110)
        var events: [LidCloseDetector.Event] = []
        for i in 0..<480 {                               // 60 s at 8 Hz
            let angle = 105.0 + (i % 2 == 0 ? 1 : -1)
            events.append(d.feed(angle: angle, time: Double(i) / 8))
        }
        XCTAssertTrue(events.allSatisfy { $0 == .none })
        XCTAssertFalse(d.isActive)
    }

    func testAFastDownwardCrossingFiresClosingOnce() {
        var d = LidCloseDetector(trigger: 110)
        let e = feed(&d, [(125, 0), (120, 0.1), (100, 0.35), (80, 0.45), (60, 0.55)])
        XCTAssertEqual(e, [.none, .none, .closing, .none, .none])
        XCTAssertTrue(d.isActive)
        XCTAssertEqual(d.armedFrom, 110)
    }

    func testSlowDriftThroughTheTriggerDoesNotClose() {
        var d = LidCloseDetector(trigger: 110)
        let e = feed(&d, [(111, 0), (109, 10)])
        XCTAssertEqual(e, [.none, .none])
    }

    func testAClosingLidFromBelowTheTriggerStartsWhereItWas() {
        var d = LidCloseDetector(trigger: 110)
        let e = feed(&d, [(105, 0), (105, 1), (95, 1.2), (70, 1.4)])
        XCTAssertEqual(e, [.none, .none, .closing, .none])
        XCTAssertEqual(d.armedFrom, 105)
    }

    func testAQuickSmallNudgeDoesNotClose() {
        var d = LidCloseDetector(trigger: 110)
        let e = feed(&d, [(105, 0), (101, 0.1), (101, 0.5)])
        XCTAssertEqual(e, [.none, .none, .none])
    }

    func testTheFirstSampleBelowTheTriggerIsNeverAClose() {
        var d = LidCloseDetector(trigger: 110)
        XCTAssertEqual(d.feed(angle: 40, time: 0), .none)
        XCTAssertFalse(d.isActive)
    }

    func testReopeningFiresReopenedAndRearms() {
        var d = LidCloseDetector(trigger: 110)
        let e = feed(&d, [(125, 0), (100, 0.25), (90, 0.4), (115, 0.8), (120, 1.0), (100, 1.25)])
        XCTAssertEqual(e, [.none, .closing, .none, .reopened, .none, .closing])
    }

    func testChangingTheTriggerAppliesToTheNextClose() {
        var d = LidCloseDetector(trigger: 110)
        d.trigger = 90
        let e = feed(&d, [(125, 0), (100, 0.25), (80, 0.4)])
        XCTAssertEqual(e, [.none, .none, .closing])
        XCTAssertEqual(d.armedFrom, 90)
    }

    // ── The spring ──

    func testSpringConvergesWithoutOvershoot() {
        var s = LidSpring(value: 0)
        for _ in 0..<120 {
            s.advance(to: 1, dt: 1.0 / 120)
            XCTAssertLessThanOrEqual(s.value, 1.0001)
        }
        XCTAssertEqual(s.value, 1, accuracy: 0.01)
    }

    func testSpringTreatsAHugeStepAsOneThirtiethOfASecond() {
        var big = LidSpring(value: 0), small = LidSpring(value: 0)
        big.advance(to: 1, dt: 5)
        small.advance(to: 1, dt: 1.0 / 30)
        XCTAssertEqual(big.value, small.value, accuracy: 1e-9)
    }

    func testSpringResetJumpsAndStops() {
        var s = LidSpring(value: 0)
        s.advance(to: 1, dt: 1.0 / 60)
        s.reset(to: 0.5)
        XCTAssertEqual(s.value, 0.5)
        s.advance(to: 0.5, dt: 1.0 / 60)
        XCTAssertEqual(s.value, 0.5, accuracy: 1e-9)
    }

    // ── The frost ──

    func testBlurCurveEndpointsAndMonotonic() {
        let c = LidBlurCurve(trigger: 110, darkAngle: 5)
        XCTAssertEqual(c.amount(at: 110), 0)
        XCTAssertEqual(c.amount(at: 130), 0)
        XCTAssertEqual(c.amount(at: 5), 1)
        XCTAssertEqual(c.amount(at: 0), 1)
        var last = 0.0
        for a in stride(from: 110.0, through: 0, by: -1) {
            let v = c.amount(at: a)
            XCTAssertGreaterThanOrEqual(v, last)
            last = v
        }
    }

    func testBlurCurveWithATriggerBelowTheDarkAngleDoesNotDivideByZero() {
        let c = LidBlurCurve(trigger: 5, darkAngle: 5)
        XCTAssertEqual(c.amount(at: 20), 0)
        XCTAssertEqual(c.amount(at: 3), 1)
    }
}

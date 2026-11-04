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

    /// The sensor changes about ten times a second however fast it is polled, so at 30 Hz two samples in three are
    /// stale repeats. A repeat is "no news", not "stopped": it must not erase a close that is under way.
    private func polled(hz: Double, from start: Double, degreesPerSecond rate: Double, for seconds: Double) -> [(Double, TimeInterval)] {
        var out: [(Double, TimeInterval)] = []
        var t = 0.0
        while t <= seconds {
            let held = (t * 10).rounded(.down) / 10            // the hardware's last update
            out.append(((start - rate * held).rounded(), t))
            t += 1 / hz
        }
        return out
    }

    func testAModerateCloseIsSeenWhenPolledFasterThanTheSensorUpdates() {
        for hz in [8.0, 30, 120] {
            var d = LidCloseDetector(trigger: 110)
            let events = feed(&d, polled(hz: hz, from: 125, degreesPerSecond: 40, for: 1.2))
            XCTAssertTrue(events.contains(.closing), "40°/s polled at \(hz) Hz")
        }
    }

    func testAnIdleLidStillNeverClosesWhenPolledFast() {
        var d = LidCloseDetector(trigger: 110)
        let events = feed(&d, polled(hz: 30, from: 100, degreesPerSecond: 0, for: 20))
        XCTAssertTrue(events.allSatisfy { $0 == .none })
    }

    func testALidThatPausesLongerThanTheSensorPeriodEndsTheRun() {
        var d = LidCloseDetector(trigger: 110)
        let e = feed(&d, [(125, 0), (121, 0.1), (121, 0.2), (121, 0.3), (121, 0.4), (121, 0.5), (117, 0.6), (113, 0.7)])
        XCTAssertEqual(e.filter { $0 == .closing }.count, 0, "a pause of half a second is not one close")
    }

    /// How soon after the lid starts to move a close is confirmed: the first fast step of the run, not the second.
    func testAFastCloseIsConfirmedOnTheFirstStepOfItsRun() {
        for hz in [8.0, 30, 120] {
            var d = LidCloseDetector(trigger: 110)
            var firedAt: Double?
            // Resting at 100°, then closing at 50°/s from t = 0.5 s: the sensor steps 5° every 0.1 s.
            var t = 0.0
            while t < 1.5, firedAt == nil {
                let held = (t * 10).rounded(.down) / 10
                let angle = (100 - max(0, held - 0.5) * 50).rounded()
                if d.feed(angle: angle, time: t) == .closing { firedAt = angle }
                t += 1 / hz
            }
            XCTAssertEqual(firedAt, 95, "closing at \(hz) Hz")
        }
    }

    /// A close slow enough to watch the animation: a degree or two per sensor update, never a fast step.
    func testASlowCloseIsSeenAtAnyPollRate() {
        for (rate, hz) in [(10.0, 10.0), (10.0, 30), (10.0, 120), (6.0, 30), (8.0, 8)] {
            var d = LidCloseDetector(trigger: 110)
            let events = feed(&d, polled(hz: hz, from: 104, degreesPerSecond: rate, for: 2.0))
            XCTAssertTrue(events.contains(.closing), "\(rate)°/s polled at \(hz) Hz")
        }
    }

    /// A slow close shows signs of itself well before it is confirmed; that is when the picture is warmed.
    func testASlowCloseIsAnnouncedBeforeItIsConfirmed() {
        var d = LidCloseDetector(trigger: 110)
        let events = feed(&d, polled(hz: 10, from: 104, degreesPerSecond: 8, for: 2.0))
        let armed = events.firstIndex(of: .armed), closing = events.firstIndex(of: .closing)
        XCTAssertNotNil(armed); XCTAssertNotNil(closing)
        XCTAssertLessThan(armed ?? 99, closing ?? 0)
    }

    func testNothingIsAnnouncedAboveTheClosingZone() {
        var d = LidCloseDetector(trigger: 110)
        let events = feed(&d, polled(hz: 10, from: 160, degreesPerSecond: 8, for: 4.0).filter { $0.0 > 136 })
        XCTAssertFalse(events.contains(.armed), "a lid still 26 degrees above the trigger is not about to close")
    }

    func testAStillLidAndAJitteringOneAreNeverAnnounced() {
        var d = LidCloseDetector(trigger: 110)
        var events: [LidCloseDetector.Event] = []
        for i in 0..<400 { events.append(d.feed(angle: 100 + (i % 2 == 0 ? 1 : -1), time: Double(i) / 8)) }
        XCTAssertTrue(events.allSatisfy { $0 == .none })
    }

    func testAMarginalCrawlIsNotAClose() {
        for rate in [0.0, 1.0, 2.0, 3.0] {
            var d = LidCloseDetector(trigger: 110)
            let events = feed(&d, polled(hz: 30, from: 104, degreesPerSecond: rate, for: 4.0))
            XCTAssertTrue(events.allSatisfy { $0 == .none }, "\(rate)°/s")
        }
    }

    func testAWanderingLidWithNoNetDescentIsNotAClose() {
        var d = LidCloseDetector(trigger: 110)
        var events: [LidCloseDetector.Event] = []
        for i in 0..<200 {
            let angle = 100 + (i % 20 < 10 ? Double(i % 10) / 3 : Double(10 - i % 10) / 3).rounded()
            events.append(d.feed(angle: angle, time: Double(i) * 0.1))
        }
        XCTAssertTrue(events.allSatisfy { $0 == .none })
    }

    func testAQuickSmallNudgeDoesNotClose() {
        var d = LidCloseDetector(trigger: 110)
        let e = feed(&d, [(105, 0), (103, 0.1), (103, 0.5)])
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

    // ── Resting ──

    func testALidThatStaysPutForTheWholeTimeIsAtRest() {
        var w = LidRestWatch(after: 3, tolerance: 3)
        var restedAt: Double?
        var t = 0.0
        while t <= 4, restedAt == nil {
            if w.feed(angle: 60 + (Int(t * 10) % 2 == 0 ? 0 : 1), time: t) { restedAt = t }      // a degree of jitter
            t += 1.0 / 30
        }
        XCTAssertEqual(try XCTUnwrap(restedAt), 3, accuracy: 0.05)
    }

    func testAnyMovementBeyondTheToleranceStartsTheCountAgain() {
        var w = LidRestWatch(after: 3, tolerance: 3)
        var t = 0.0
        while t < 2.5 { XCTAssertFalse(w.feed(angle: 60, time: t)); t += 0.1 }
        XCTAssertFalse(w.feed(angle: 52, time: 2.6), "the lid moved 8 degrees")
        var restedAt: Double?
        t = 2.7
        while t <= 7, restedAt == nil { if w.feed(angle: 52, time: t) { restedAt = t }; t += 0.1 }
        XCTAssertEqual(try XCTUnwrap(restedAt), 2.6 + 3, accuracy: 0.15, "three seconds from the move, not from the start")
    }

    func testResetForgetsTheCount() {
        var w = LidRestWatch(after: 3, tolerance: 3)
        var t = 0.0
        while t < 2.9 { _ = w.feed(angle: 60, time: t); t += 0.1 }
        w.reset()
        XCTAssertFalse(w.feed(angle: 60, time: 3.0))
        XCTAssertFalse(w.feed(angle: 60, time: 5.0), "two seconds since the reset")
        XCTAssertTrue(w.feed(angle: 60, time: 6.1))
    }
}

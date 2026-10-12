import XCTest
@testable import PowerKit

/// The drain rate that is SHOWN, against the one time left is divided from.
///
/// Time left rests on the all-time average, which by design barely moves. Shown
/// as "Drain" it read as a stuck number: the machine could double its draw and
/// the row would not change. So the row gets its own short trailing mean, and
/// these pin the two things that must hold — it follows the last few minutes,
/// and it cannot reach the time.
final class RecentDrainTests: XCTestCase {

    private func fed(_ watts: [Double], every dt: TimeInterval = 10,
                     from start: TimeInterval = 0,
                     into r: RecentDrain = RecentDrain()) -> RecentDrain {
        var r = r
        for (i, w) in watts.enumerated() {
            r.observe(batteryWatts: w, onBattery: true, interval: dt,
                      awake: start + Double(i + 1) * dt)
        }
        return r
    }

    func testNothingIsQuotedFromAFewSeconds() {
        XCTAssertNil(RecentDrain().mean_W)
        XCTAssertNil(fed([8, 8, 8]).mean_W, "30 s is an instant, not an average")
    }

    func testASteadyDrawIsItsOwnMean() throws {
        XCTAssertEqual(try XCTUnwrap(fed(Array(repeating: 6, count: 30)).mean_W), 6,
                       accuracy: 1e-9)
    }

    /// The point of the change: what happened before the window is gone.
    func testOnlyTheTrailingWindowCounts() throws {
        let old = fed(Array(repeating: 20, count: 120))            // 20 min at 20 W
        let n = Int(RecentDrain.window / 10)
        let now = fed(Array(repeating: 5, count: n), from: 1200, into: old)
        XCTAssertEqual(try XCTUnwrap(now.mean_W), 5, accuracy: 1e-9)
    }

    /// Hidden ticks are 8 s and visible ones 2 s; a mean of SAMPLES would let
    /// whichever cadence was running longest outvote the other.
    func testSamplesAreWeightedByTheTimeTheyCover() throws {
        var r = RecentDrain()
        r.observe(batteryWatts: 10, onBattery: true, interval: 90, awake: 90)
        r.observe(batteryWatts: 4, onBattery: true, interval: 30, awake: 120)
        XCTAssertEqual(try XCTUnwrap(r.mean_W), 8.5, accuracy: 1e-9)
    }

    /// The once-a-minute full sweep reports the time since the previous SWEEP,
    /// which the light ticks in between have already accounted for.
    func testATickIsWeightedByTheTimeSinceTheLastOneNotByWhatItClaims() throws {
        var r = fed(Array(repeating: 4, count: 6))                  // 60 s at 4 W
        r.observe(batteryWatts: 40, onBattery: true, interval: 60, awake: 70)
        // 60 s at 4 W and 10 s at 40 W, not 60 s of each.
        XCTAssertEqual(try XCTUnwrap(r.mean_W), (60 * 4 + 10 * 40) / 70.0, accuracy: 1e-9)
    }

    /// A drain average that carried across a charge would open the next
    /// session quoting the last one.
    func testPluggingInForgetsEverything() {
        var r = fed(Array(repeating: 6, count: 30))
        r.observe(batteryWatts: 6, onBattery: false, interval: 10, awake: 310)
        XCTAssertNil(r.mean_W)
    }

    func testAnUnusableReadingIsSkippedNotAveragedIn() throws {
        var r = fed(Array(repeating: 6, count: 30))
        r.observe(batteryWatts: .nan, onBattery: true, interval: 10, awake: 310)
        r.observe(batteryWatts: 0, onBattery: true, interval: 10, awake: 320)
        XCTAssertEqual(try XCTUnwrap(r.mean_W), 6, accuracy: 1e-9)
    }

    // ── A jump drops the average ─────────────────────────────────────────────

    /// A trailing mean answers a step change ten minutes late: the machine went
    /// back to 11 %/hr and the row still said 28. So a reading that moves by
    /// the jump threshold throws the window away and is shown as it is.
    func testAJumpDropsTheAverageAndShowsTheReading() throws {
        var r = fed(Array(repeating: 6, count: 30))
        r.observe(batteryWatts: 20, onBattery: true, interval: 10, awake: 310, jump_W: 3.5)
        XCTAssertEqual(try XCTUnwrap(r.mean_W), 20, accuracy: 1e-9)
    }

    func testAJumpDownIsAJumpToo() throws {
        var r = fed(Array(repeating: 20, count: 30))
        r.observe(batteryWatts: 6, onBattery: true, interval: 10, awake: 310, jump_W: 3.5)
        XCTAssertEqual(try XCTUnwrap(r.mean_W), 6, accuracy: 1e-9)
    }

    /// Once readings stop jumping the average picks up again — from the new
    /// level. What was dropped stays dropped.
    func testTheAverageResumesFromTheNewLevel() throws {
        var r = fed(Array(repeating: 6, count: 30))
        for (i, w) in [20.0, 18, 19].enumerated() {
            r.observe(batteryWatts: w, onBattery: true, interval: 10,
                      awake: 310 + Double(i) * 10, jump_W: 3.5)
        }
        XCTAssertEqual(try XCTUnwrap(r.mean_W), 19, accuracy: 1e-9)
    }

    /// Still climbing: each reading is shown as it arrives, not averaged with
    /// the one before it.
    func testConsecutiveJumpsKeepShowingTheCurrentReading() throws {
        var r = fed(Array(repeating: 6, count: 30))
        r.observe(batteryWatts: 20, onBattery: true, interval: 10, awake: 310, jump_W: 3.5)
        r.observe(batteryWatts: 30, onBattery: true, interval: 10, awake: 320, jump_W: 3.5)
        XCTAssertEqual(try XCTUnwrap(r.mean_W), 30, accuracy: 1e-9)
    }

    func testOrdinaryWobbleIsAveragedNotFollowed() throws {
        var r = fed(Array(repeating: 6, count: 30))
        r.observe(batteryWatts: 9, onBattery: true, interval: 10, awake: 310, jump_W: 3.5)
        XCTAssertEqual(try XCTUnwrap(r.mean_W), (30 * 6 + 9) / 31.0, accuracy: 1e-9)
    }

    /// The minimum span guards a cold start. After a jump the reading is the
    /// answer, however little of it there is — falling back to nothing there
    /// would put the all-time figure on screen at the moment it is least true.
    func testAReadingAfterAJumpIsQuotedAtOnce() throws {
        var r = fed([6, 6])
        XCTAssertNil(r.mean_W)
        r.observe(batteryWatts: 20, onBattery: true, interval: 10, awake: 30, jump_W: 3.5)
        XCTAssertEqual(try XCTUnwrap(r.mean_W), 20, accuracy: 1e-9)
    }

    func testPluggingInAfterAJumpStillForgetsEverything() {
        var r = fed(Array(repeating: 6, count: 30))
        r.observe(batteryWatts: 20, onBattery: true, interval: 10, awake: 310, jump_W: 3.5)
        r.observe(batteryWatts: 20, onBattery: false, interval: 10, awake: 320, jump_W: 3.5)
        XCTAssertNil(r.mean_W)
    }

    // ── The rate shown and the rate divided ─────────────────────────────────

    func testTheShownRateIsTheRecentOneWhenThereIsOne() {
        let r = DisplayedRate(pctHr: 9, chargePercent: 60, anchorAwake: 0,
                              source: .allTime, windowSpan: 7200, recentPctHr: 14)
        XCTAssertEqual(r.shownPctHr, 14)
        XCTAssertEqual(DisplayedRate(pctHr: 9, chargePercent: 60, anchorAwake: 0,
                                     source: .allTime, windowSpan: 7200).shownPctHr, 9)
    }

    /// The other half of the request, and the one a refactor would break
    /// silently: the recent rate is for reading, never for dividing.
    func testTheRecentRateDoesNotMoveTimeLeft() {
        func rate(_ recent: Double?) -> DisplayedRate {
            DisplayedRate(pctHr: 9, chargePercent: 60, anchorAwake: 0,
                          source: .allTime, windowSpan: 7200, recentPctHr: recent)
        }
        let base = rate(nil).timeRemaining_hr(now: 100)
        XCTAssertNotNil(base)
        XCTAssertEqual(rate(30).timeRemaining_hr(now: 100), base)
        XCTAssertEqual(rate(1).timeRemaining_hr(now: 100), base)
    }
}

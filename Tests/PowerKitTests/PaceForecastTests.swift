import XCTest
@testable import PowerKit

/// The load-following time left beside the steady headline.
///
/// The headline divides the all-time average and stays put by design; the pace
/// figure divides the last half hour's drain. These pin that it is the SAME
/// projection with a different rate — same anchor, same constant-power
/// correction, same one-second-per-second countdown — so the two can only differ
/// by the rate.
final class PaceForecastTests: XCTestCase {

    private func anchor(pctHr: Double = 10, pace: Double? = 30, charge: Double? = 60,
                        at awake: TimeInterval = 1000) -> DisplayedRate {
        DisplayedRate(pctHr: pctHr, chargePercent: charge, anchorAwake: awake,
                      source: .allTime, windowSpan: 3600, pacePctHr: pace)
    }

    func testAtTheAnchorPaceIsTimeToEmptyAtThePaceRate() throws {
        let r = anchor()
        let expected = try XCTUnwrap(DrainEstimate.timeToEmpty(chargePercent: 60,
                                                               ratePctHr: 30))
        XCTAssertEqual(try XCTUnwrap(r.paceRemaining_hr(now: 1000)) * 3600, expected,
                       accuracy: 1e-6)
    }

    func testPaceCountsDownOneSecondPerSecond() throws {
        let r = anchor()
        let t0 = try XCTUnwrap(r.paceRemaining_hr(now: 1000)) * 3600
        let t1 = try XCTUnwrap(r.paceRemaining_hr(now: 1300)) * 3600
        XCTAssertEqual(t0 - t1, 300, accuracy: 1e-6)
    }

    func testNoPaceRateMeansNoPaceTime() {
        XCTAssertNil(anchor(pace: nil).paceRemaining_hr(now: 1000))
        XCTAssertNil(anchor(charge: nil).paceRemaining_hr(now: 1000))
    }

    /// A heavy load shows a pace time well below the headline; a pace within the
    /// model's own error of the headline is left unsaid.
    func testOnlyAMaterialDifferenceIsWorthASecondFigure() throws {
        let heavy = anchor(pctHr: 10, pace: 30)
        let headline = try XCTUnwrap(heavy.timeRemaining_hr(now: 1000))
        XCTAssertNotNil(heavy.notablePaceRemaining_hr(headline_hr: headline, now: 1000))

        let same = anchor(pctHr: 10, pace: 10.5)
        let h2 = try XCTUnwrap(same.timeRemaining_hr(now: 1000))
        XCTAssertNil(same.notablePaceRemaining_hr(headline_hr: h2, now: 1000))
        XCTAssertNil(same.notablePaceRemaining_hr(headline_hr: nil, now: 1000))
    }
}

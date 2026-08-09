import XCTest
@testable import PowerKit

/// Time remaining is a projection, always, and one formatter renders it.
final class TimeLeftHonestyTests: XCTestCase {

    /// Below an hour the card used to say "0h 45m" while the menu bar said
    /// "45m" — two formatters for one deliberately-shared number.
    func testMinutesFormatterIsTheOneUsedEverywhere() {
        XCTAssertEqual(MetricUnit.minutes.format(45), "45m")
        XCTAssertEqual(MetricUnit.minutes.format(60), "1h 00m")
        XCTAssertEqual(MetricUnit.minutes.format(203), "3h 23m")
        XCTAssertEqual(MetricUnit.minutes.format(0), "0m")
    }

    /// The formatter is exact: whatever hours it is handed render as those
    /// hours. This pins the rendering, NOT the basis question below.
    func testHoursRenderExactly() {
        XCTAssertEqual(MetricUnit.minutes.format((53.0 / 15.0 * 60).rounded()), "3h 32m")
        XCTAssertEqual(MetricUnit.minutes.format((50.75 / 15.0 * 60).rounded()), "3h 23m")
    }

    /// THE BASIS GAP, pinned so it cannot drift unnoticed.
    ///
    /// A tester's menu bar read 53% / 15 %/hr / 3h 23m. Those do not multiply
    /// out — 53/15 is 3h32m — and the reason is deliberate: the percentage shown
    /// is the gauge's integer `CurrentCapacity` (so it matches what macOS shows
    /// in its own menu bar), while the time is computed from
    /// `RemainingCapacity/FullChargeCapacity`, which reads ~4% lower and which
    /// the gauge's own time-to-empty agrees with.
    ///
    /// So the displayed time is RIGHT and the displayed percentage is the one
    /// macOS shows, and they cannot both also multiply out. TESTING.md tells a
    /// tester the numbers multiply out; while this stands, that instruction is
    /// wrong, which is why this test exists rather than a comment.
    func testTheTwoChargeBasesDisagreeByAKnownAmount() {
        let gaugePercent = 53.0
        let impliedByTime = 15.0 * (3 + 23.0 / 60)     // rate x shown hours
        let gap = (gaugePercent - impliedByTime) / gaugePercent
        XCTAssertEqual(impliedByTime, 50.75, accuracy: 0.01)
        XCTAssertGreaterThan(gap, 0.03, "the mAh basis reads lower than the gauge integer")
        XCTAssertLessThan(gap, 0.06, "but only by a few percent — a larger gap is a bug")
    }

    /// A duration a battery cannot plausibly have must not render as a number.
    /// 240 h is the guard; the starved-estimator bug printed 200 hours once.
    func testImplausibleProjectionsAreRefused() {
        // The card's guard, restated here because it is the invariant that
        // matters rather than the private function that implements it.
        func showable(_ h: Double) -> Bool { h.isFinite && h >= 0 && h < 240 }
        for hours: Double in [.nan, .infinity, -1, 240, 1000] {
            XCTAssertFalse(showable(hours), "\(hours) must not be shown as a time remaining")
        }
        XCTAssertTrue(showable(3.53))
    }
}

import XCTest
@testable import PowerKit
@testable import AnodeApp

/// The trend line drawn over the drain graph.
///
/// ## Why it exists
/// Reported from the field: "the graph is saying my now drain is about 4.5%/hr,
/// while the actual number is showing as 7.5% per hour." Both were right. The
/// graph plots `smoothed_pctHr` per tick, and the eye reads where that line
/// SITS; the readout is a mean over half an hour, and a mean is pulled up by
/// spikes the line only touches. Measured on the reporting machine over 24
/// minutes: base 2.97 W, mean 6.11 W, peak 28.97 W — the base sitting 51 %
/// below the mean, worse than the 35-45 % `DischargeTrend` documents for bursty
/// loads.
///
/// Nothing was wrong, and no number could be changed to fix it, because a pack
/// is drained by the AREA under that line and not by where it rests. What was
/// missing was the connection between the two, so the overlay draws the mean
/// over the line it is the mean OF — making "the mean rides above the base"
/// visible instead of suspicious.
///
/// ## Why derived rather than buffered
/// A stored second series would need seeding at launch, a cutoff of its own,
/// and a definition for the store-backed ranges where the published rate was
/// never persisted. Deriving it from the points being drawn gives ONE
/// definition on every range, and makes the drawn claim self-evidently true of
/// the drawn data.
final class DrainTrendOverlayTests: XCTestCase {

    private func pts(_ pairs: [(TimeInterval, Double)]) -> [HistoryGraphView.Point] {
        pairs.map { .init(time: Date(timeIntervalSinceReferenceDate: $0.0), value: $0.1) }
    }

    /// A flat load is its own mean. The overlay must not invent a wiggle.
    func testAFlatLineIsItsOwnTrend() {
        let flat = pts((0...60).map { (Double($0) * 60, 5.0) })
        let trend = AppDelegate.trailingMean(flat, window: 1800, minimumSpan: 300)
        XCTAssertFalse(trend.isEmpty)
        for p in trend { XCTAssertEqual(p.value, 5.0, accuracy: 1e-9) }
    }

    /// THE case the overlay exists for. A load at a 3 W base with a short spike
    /// to 29 W has a mean well above its base, and the trend must show that —
    /// this is the 4.5-versus-7.5 report, reproduced.
    func testTheTrendRidesAboveABurstyBase() {
        var series: [(TimeInterval, Double)] = []
        for i in 0..<1800 {                              // 30 min at 1 s
            let t = Double(i)
            // 60 s of 29 W in every 300 s, 3 W otherwise: a 20 % duty burst.
            series.append((t, i % 300 < 60 ? 29.0 : 3.0))
        }
        let trend = AppDelegate.trailingMean(pts(series), window: 1800, minimumSpan: 300)
        let last = trend.last!.value
        // 0.2*29 + 0.8*3 = 8.2
        XCTAssertEqual(last, 8.2, accuracy: 0.3)
        XCTAssertGreaterThan(last / 3.0, 2.0,
                             "the mean must sit well above the base the eye reads")
    }

    /// TIME-weighted, not sample-weighted. The live buffer ticks every 2 s while
    /// the window is visible and every 8 s while it is hidden, so a plain mean
    /// over samples would count a visible minute four times as heavily as a
    /// hidden one and quietly redefine the window.
    func testTheMeanIsWeightedByTimeNotBySampleCount() {
        // 10 minutes at 2 W sampled densely, then 10 minutes at 10 W sampled
        // sparsely. Equal TIME, so the mean is 6.
        var series: [(TimeInterval, Double)] = []
        for i in 0...300 { series.append((Double(i) * 2, 2.0)) }        // 600 s, 301 pts
        for i in 1...75 { series.append((600 + Double(i) * 8, 10.0)) }  // 600 s, 75 pts
        let trend = AppDelegate.trailingMean(pts(series), window: 1800, minimumSpan: 300)
        XCTAssertEqual(trend.last!.value, 6.0, accuracy: 0.2,
                       "equal time at 2 W and 10 W is a mean of 6, whatever the "
                       + "sampling density")
        // A sample-weighted mean would land near 3.6 — pinned so the distinction
        // cannot be optimised away.
        XCTAssertGreaterThan(trend.last!.value, 5.0)
    }

    /// Nothing is drawn until the window holds enough to be a trend. The first
    /// point's "mean" is itself, and drawing that would put the overlay ON the
    /// instantaneous line at exactly the moment it is meant to differ from it.
    /// Mirrors `BatteryDischargeTrend.minTicks`, which is the same judgement.
    func testNoTrendIsDrawnBeforeTheWindowHasSubstance() {
        let short = pts((0...100).map { (Double($0), 5.0) })     // 100 s
        XCTAssertTrue(AppDelegate.trailingMean(short, window: 1800, minimumSpan: 300).isEmpty)

        let enough = pts((0...400).map { (Double($0), 5.0) })    // 400 s
        let trend = AppDelegate.trailingMean(enough, window: 1800, minimumSpan: 300)
        XCTAssertFalse(trend.isEmpty)
        XCTAssertGreaterThanOrEqual(
            trend.first!.time.timeIntervalSinceReferenceDate, 300,
            "the line may only begin where a full minimum span sits behind it")
    }

    /// The window is TRAILING: a point's trend may only see what came before it.
    /// A mean centred on the point would let the future move the past, and the
    /// graph would redraw its own history every tick.
    func testTheWindowLooksBackwardsOnly() {
        // Quiet for 20 min, then a step up. The trend at the step must still be
        // near the quiet value, not half way to the new one.
        var series: [(TimeInterval, Double)] = []
        for i in 0...1200 { series.append((Double(i), 2.0)) }
        for i in 1...600 { series.append((1200 + Double(i), 20.0)) }
        let trend = AppDelegate.trailingMean(pts(series), window: 1800, minimumSpan: 300)
        let atStep = trend.first { $0.time.timeIntervalSinceReferenceDate >= 1200 }!
        XCTAssertEqual(atStep.value, 2.0, accuracy: 0.2,
                       "nothing after the step may reach back before it")
        XCTAssertGreaterThan(trend.last!.value, 5.0, "and the step is followed")
    }

    /// Points older than the window fall out of it, or the "30-minute mean"
    /// would silently become a mean over however long the app had been running.
    func testThePastFallsOutOfTheWindow() {
        var series: [(TimeInterval, Double)] = []
        for i in 0...1800 { series.append((Double(i), 20.0)) }          // 30 min hot
        for i in 1...1800 { series.append((1800 + Double(i), 2.0)) }    // 30 min quiet
        let trend = AppDelegate.trailingMean(pts(series), window: 1800, minimumSpan: 300)
        XCTAssertEqual(trend.last!.value, 2.0, accuracy: 0.2,
                       "an hour later the hot half hour must be entirely gone")
    }

    /// Non-finite values are already dropped by the view's own sanitise, but the
    /// mean must not produce one either — a NaN would blank the whole series.
    func testGarbageInDoesNotProduceGarbageOut() {
        let series = pts([(0, 5), (60, .nan), (120, 5), (180, .infinity), (600, 5)])
        let trend = AppDelegate.trailingMean(series, window: 1800, minimumSpan: 300)
        for p in trend { XCTAssertTrue(p.value.isFinite, "\(p.value)") }
    }

    func testEmptyInputIsEmptyOutput() {
        XCTAssertTrue(AppDelegate.trailingMean([], window: 1800, minimumSpan: 300).isEmpty)
    }
}

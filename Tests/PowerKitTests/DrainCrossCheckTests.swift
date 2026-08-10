import XCTest
@testable import PowerKit

/// The time-to-empty cross-check: two instruments, the same seconds, the same
/// joules, so they must agree.
///
/// The failure it exists for was reported live on a cold boot — the app published
/// a 25-hour time-to-empty, which implies 1.7 W, while the pack was independently
/// measured at 9.1 W the same instant. A 5.35x disagreement with a number the app
/// already held, published as fact. Raising the trend's floor from 120 to 300
/// ticks spreads such an error over more windows; it does not notice it.
///
/// The control tests below matter as much as the failure ones. A cross-check
/// against the draw AT THIS INSTANT would fire on every `swift build`: measured
/// over the load profiles this design is scored on, the instantaneous
/// disagreement between a half-hour mean and the live figure reaches 10.72x on a
/// bursty load — twice what the bug did — because that disagreement is the trend
/// doing its job. Matched to the trend's own span the worst legitimate
/// disagreement measured anywhere is 1.68x.
final class DrainCrossCheckTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let volts = 11_878.0
    private let scale = BatteryScale(fullChargeCapacity_mAh: 6193,
                                     designCapacity_mAh: 6249,
                                     nominalVoltage_V: BatteryScale.seedNominalVoltage_V,
                                     isCalibrated: true)

    /// %/hr for a given battery wattage on this pack, so the fixtures can be
    /// written in the watts the report is in.
    private func pctHr(_ watts: Double) -> Double {
        watts * 1000 / volts * 1000 / scale.fullChargeCapacity_mAh * 100
    }

    /// Drives the estimator minute by minute. `accumulatorWatts` is what the
    /// battery's discharge counter integrates; `livePower` is what the app's
    /// whole-system measurement says at the same moment. Driving them apart is the
    /// whole point — on a healthy machine they are the same number.
    private func drive(_ est: DrainRateEstimator, minutes: Int,
                       accumulatorWatts: (Int) -> Double,
                       livePower_W: (Int) -> Double?,
                       mAhPerMinute: Double = 4.0) {
        var acc: Int64 = -1_000_000
        var count: UInt64 = 500_000
        var mAh = 3667.0
        var at = t0
        var awake = 10_000.0
        for m in 0..<minutes {
            for tick in 0..<30 {                       // a record every 2 s
                if tick == 0, m > 0 {
                    acc &-= Int64(accumulatorWatts(m - 1) * 1000 * 60)
                    count &+= 60
                    mAh -= mAhPerMinute
                }
                est.record(remainingCapacity_mAh: mAh, onAC: false, isCharging: false,
                           scale: scale,
                           powerBased_pctHr: livePower_W(m).map { pctHr($0) },
                           discharge: BatteryDischargeTrend.Sample(
                               accumulatedDischarge: acc, accumulatorCount: count,
                               voltage_mV: volts, timestamp: at, awake: awake),
                           at: at)
                at = at.addingTimeInterval(2)
                awake += 2
            }
        }
    }

    // ── The failure ─────────────────────────────────────────────────────────

    /// The reported numbers. The accumulator integrates 1.7 W; every whole-system
    /// reading over the same minutes says 9.1 W. One of them is wrong, and it is
    /// not the one two independent instruments agree on.
    func testATrendThatContradictsMeasuredPowerIsNotPublished() {
        let est = DrainRateEstimator()
        drive(est, minutes: 12, accumulatorWatts: { _ in 1.7 }, livePower_W: { _ in 9.1 })

        let e = est.estimate()
        XCTAssertNotNil(e)
        XCTAssertEqual(e?.source, .power,
                       "a 5.35x disagreement about the same seconds is not a measurement")
        XCTAssertEqual(e?.percentPerHour ?? 0, pctHr(9.1), accuracy: 0.05,
                       "it must publish the figure the check believed, not a third number")
        // 1.7 W would have projected 25 hours. Whatever is shown, it is not that.
        let hours = (e?.timeRemaining ?? 0) / 3600
        XCTAssertLessThan(hours, 10, "25 h was the headline this exists to prevent")
    }

    /// Direction does not matter: an accumulator reading far too HIGH would strand
    /// the user the other way, telling them to plug in when they need not.
    func testTheCheckIsSymmetric() {
        let est = DrainRateEstimator()
        drive(est, minutes: 12, accumulatorWatts: { _ in 40 }, livePower_W: { _ in 5 })
        XCTAssertEqual(est.estimate()?.source, .power)
    }

    // ── The controls: what must NOT trip it ─────────────────────────────────

    /// The one that a naive implementation gets wrong. A build burst puts the live
    /// figure ten times over the half-hour mean — that gap IS the trend holding a
    /// spike to a thirtieth of its weight, and suppressing it here would put the
    /// display back on instantaneous power, which scored MAE 13.6 against 4.6.
    func testABurstThatTheTrendIsMeantToAbsorbDoesNotTripIt() {
        let est = DrainRateEstimator()
        // 4.1 W baseline with one minute at 54 W, the shape of the recorded trace.
        let load: (Int) -> Double = { $0 == 34 ? 54 : 4.1 }
        drive(est, minutes: 35, accumulatorWatts: load, livePower_W: { load($0) })

        let e = est.estimate()
        XCTAssertEqual(e?.source, .discharge,
                       "the trend absorbing a burst is the feature, not the fault")
        // The instantaneous disagreement at this moment is enormous, and irrelevant.
        let trendWatts = (e?.percentPerHour ?? 0) / pctHr(1)
        XCTAssertGreaterThan(54 / trendWatts, 3.0,
                             "the fixture must actually present a >3x instantaneous gap")
    }

    /// A steady machine where both instruments agree: the measured path must speak.
    func testAgreementLeavesTheMeasuredPathInCharge() {
        let est = DrainRateEstimator()
        drive(est, minutes: 12, accumulatorWatts: { _ in 6.0 }, livePower_W: { _ in 6.2 })
        XCTAssertEqual(est.estimate()?.source, .discharge)
    }

    /// Instrument disagreement inside the band is not a fault. 1.68x is the worst
    /// legitimate figure measured across the load profiles; it must pass.
    func testTheWorstLegitimateDisagreementMeasuredStillPasses() {
        let est = DrainRateEstimator()
        drive(est, minutes: 12, accumulatorWatts: { _ in 6.0 }, livePower_W: { _ in 6.0 * 1.68 })
        XCTAssertEqual(est.estimate()?.source, .discharge)
    }

    /// No power figure at all — an older machine, or SMC gone. There is nothing to
    /// cross-check against, and a check that cannot run must not demote a
    /// measurement that is otherwise sound.
    func testWithNothingToCheckAgainstTheTrendStillSpeaks() {
        let est = DrainRateEstimator()
        drive(est, minutes: 12, accumulatorWatts: { _ in 1.7 }, livePower_W: { _ in nil })
        XCTAssertEqual(est.estimate()?.source, .discharge)
    }

    /// The buffer has to cover the span it claims to average. Freshly off AC it
    /// does not, and a mean over 30 seconds must not be presented as the mean over
    /// the trend's window and used to overrule it.
    func testAPowerBufferThatDoesNotCoverTheWindowDoesNotOverruleIt() {
        let est = DrainRateEstimator()
        // Eleven minutes with no power figure at all, then one minute of a wildly
        // disagreeing one. The figure is fresh, so the fallback tier could use it —
        // but as a MEAN it covers a twelfth of the trend's span and is not evidence
        // about the other eleven twelfths.
        drive(est, minutes: 12, accumulatorWatts: { _ in 1.7 },
              livePower_W: { $0 >= 11 ? 9.1 : nil })
        XCTAssertEqual(est.estimate()?.source, .discharge)
    }
}

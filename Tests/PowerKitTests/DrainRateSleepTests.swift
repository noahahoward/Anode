import XCTest
@testable import PowerKit

/// The drain estimator's sample buffer must not fit a line through a sleep.
///
/// The long case was already safe by accident: a nine-hour gap puts every
/// pre-sleep sample outside `prune`'s cutoff, so the buffer empties itself. The
/// dangerous case is a sleep SHORTER than the slow window, which leaves the
/// pre-sleep samples in place and regresses across hours the machine spent
/// asleep drawing almost nothing. That under-reports drain at exactly the moment
/// a user has opened the lid to check it.
final class DrainRateSleepTests: XCTestCase {

    private let scale = makeMachineScale()

    /// Drives a steady discharge and returns the estimator holding that history.
    /// 25 minutes at 60 s publishes clears `minSpan` (300 s) comfortably.
    private func steadyDischarge(from start: Date,
                                 minutes: Int) -> (DrainRateEstimator, Date, Double) {
        let est = DrainRateEstimator()
        var mAh = 4000.0
        var t = start
        for _ in 0..<minutes {
            est.record(remainingCapacity_mAh: mAh, onAC: false, isCharging: false,
                       scale: scale, powerBased_pctHr: nil, at: t)
            mAh -= 6                      // ~350 mAh/hr, a realistic ~5.7 %/hr
            t = t.addingTimeInterval(60)
        }
        return (est, t, mAh)
    }

    /// Baseline: the history built above is trusted, so a nil after the gap
    /// below means the gap did it rather than the fixture being too short.
    func testSteadyDischargeProducesAnEstimate() {
        let (est, _, _) = steadyDischarge(from: Date(timeIntervalSince1970: 1_700_000_000),
                                          minutes: 25)
        XCTAssertNotNil(est.estimate())
        XCTAssertGreaterThan(est.estimate()?.windowSpan ?? 0, 300)
    }

    func testASleepDropsTheHistoryItWouldOtherwiseFitAcross() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let (est, t, mAh) = steadyDischarge(from: t0, minutes: 25)

        // Ten minutes asleep: far longer than a tick, far SHORTER than the
        // 3600 s slow window, so pruning alone would keep every pre-sleep
        // sample and regress straight through the gap.
        let wake = t.addingTimeInterval(600)
        est.record(remainingCapacity_mAh: mAh - 3, onAC: false, isCharging: false,
                   scale: scale, powerBased_pctHr: nil, at: wake)

        // One post-wake sample cannot clear minSpan, so there is no OBSERVED
        // estimate — which is the honest output, not a fabricated rate.
        let e = est.estimate()
        XCTAssertLessThanOrEqual(e?.windowSpan ?? 0, 300, "the fit must not span the sleep")
        XCTAssertNotEqual(e?.source, .observed)
    }

    /// The control: the same shape of step, just short enough to be a real
    /// (if sluggish) tick, must NOT throw the history away. Without this the
    /// test above would pass for an estimator that resets on every sample.
    func testAnOrdinaryGapKeepsTheHistory() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let (est, t, mAh) = steadyDischarge(from: t0, minutes: 25)

        let next = t.addingTimeInterval(120)   // slow, but plainly awake
        est.record(remainingCapacity_mAh: mAh - 12, onAC: false, isCharging: false,
                   scale: scale, powerBased_pctHr: nil, at: next)

        let e = est.estimate()
        XCTAssertNotNil(e)
        XCTAssertGreaterThan(e?.windowSpan ?? 0, 300,
                             "a 120 s tick is not a sleep and must keep the window")
    }

    /// The threshold is shared with the store's notion of an implausible
    /// interval. Pinning it here means the two cannot drift apart silently —
    /// a store that drops a row the estimator still fits across would put two
    /// different sleeps in front of the user.
    func testThresholdIsTheSharedImplausibleInterval() {
        XCTAssertEqual(HistoryStore.maxPlausibleInterval, 300)
    }
}

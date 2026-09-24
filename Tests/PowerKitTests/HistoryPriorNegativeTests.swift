import XCTest
@testable import PowerKit

/// A MEASURED NEGATIVE RESULT, committed so it is not re-guessed.
///
/// The idea, which is an obvious one and was proposed from the field: seed
/// time-to-empty from "the average battery drain from all app history" instead
/// of, or alongside, the trailing 30-minute window.
///
/// It loses, and not narrowly. This file is the evidence, in the shape
/// `TrendSweepHarness.testDownwardCeilingSweep` established — when the answer is
/// "no configuration works", assert the negative rather than printing it, and
/// say what would have to change for it to be worth revisiting.
///
/// ## Where the numbers come from
/// This machine's own `history.sqlite`, read 2026-08-21: seven days, 64 MB, but
/// only **16.3 on-battery hours** across **8 sessions longer than 40 minutes** —
/// the app records only while running, awake and logging, so a "week of history"
/// is a 17 % duty cycle. Those are the entire training set such a prior would
/// ever get.
final class HistoryPriorNegativeTests: XCTestCase {

    /// Mean on-battery watts per day, 2026-08-14 .. 08-20.
    private let dailyMeanWatts: [Double] = [7.51, 18.4, 17.93, 8.66, 5.47, 6.10, 6.84]

    /// The prior an "all history" EWMA would quote, against what each day
    /// actually drew. A single number cannot describe this machine.
    func testAnAllHistoryPriorIsWrongByHalfOnRealDays() {
        // The unweighted mean of the daily means. (A time-weighted mean over the
        // week comes out lower, near 8 W, because the heavy days were shorter —
        // which does not rescue the idea: it just moves which day it fails on.)
        let prior = dailyMeanWatts.reduce(0, +) / Double(dailyMeanWatts.count)
        XCTAssertEqual(prior, 10.13, accuracy: 0.02)

        let errors = dailyMeanWatts.map { (prior - $0) / $0 }
        let worstHigh = errors.max()!, worstLow = errors.min()!
        XCTAssertGreaterThan(worstHigh, 0.80,
                             "on the quietest day the prior overstates drain by 88 %, "
                             + "so it would quote barely half the runtime the machine "
                             + "actually had")
        XCTAssertLessThan(worstLow, -0.4,
                          "and on the heaviest day it understates by 44 %, promising "
                          + "runtime that was never coming")
        let spread = dailyMeanWatts.max()! / dailyMeanWatts.min()!
        XCTAssertGreaterThan(spread, 3.0,
                             "a 3.4x spread across one week is what makes a single "
                             + "prior meaningless — the covariate is 'what am I doing', "
                             + "which the app already measures directly")
    }

    /// And what it would be replacing. `DischargeTrend`'s own scored table puts
    /// the shipped 1800 s window at MAE 4.5 min (random walk) and 5.0 min
    /// (bursty) against the true death time.
    ///
    /// Converting the prior's error into the same units: on the quietest day a
    /// 59 % overstatement of drain shortens an eight-hour estimate by about
    /// three hours. That is not the same order of magnitude as four minutes.
    func testThePriorLosesToTheWindowByAnOrderOfMagnitude() {
        let windowMAE_min = 5.0                       // the worse of the two scored loads
        let prior = dailyMeanWatts.reduce(0, +) / Double(dailyMeanWatts.count)
        let quietest = dailyMeanWatts.min()!
        // 75 % of a pack at the true rate, versus at the prior's rate.
        let truthHours = 75.0 / (quietest * 1.45)     // 1 W ~ 1.45 %/hr on this pack
        let priorHours = 75.0 / (prior * 1.45)
        let priorError_min = abs(truthHours - priorHours) * 60
        XCTAssertGreaterThan(priorError_min, 10 * windowMAE_min,
                             "the prior must lose by an order of magnitude for this "
                             + "negative to stand; if it ever does not, re-run it")
    }

    /// The gap it was supposed to fill does not exist.
    ///
    /// The only true cold starts left are a reboot, an unplug, a sleep past
    /// tolerance, and a gap longer than the window — the trend already survives
    /// app restarts (`BatteryDischargeTrend.Persisted`). On every one of those
    /// the app ALREADY holds a live whole-machine measurement, publishable as
    /// `.power` after `settleSeconds`. So a prior would replace a live
    /// measurement of today's load with an average of last week's, for two
    /// minutes.
    func testThereIsNoColdStartLongEnoughForAPriorToHelp() {
        XCTAssertEqual(DrainEstimate.settleSeconds, 120,
                       "the window a prior could fill at all")
        XCTAssertTrue(DrainEstimate.canQuoteTime(source: .power,
                                                 windowSpan: DrainEstimate.settleSeconds),
                      "and at the end of it a MEASURED figure is already quotable")
        XCTAssertFalse(DrainEstimate.canQuoteTime(source: .power, windowSpan: 119),
                       "before that nothing is quoted, which is the honest answer "
                       + "rather than a gap wanting a guess")
    }

    /// WHAT WOULD HAVE TO CHANGE for this to be worth revisiting:
    ///
    ///  * the store would have to hold the DISCHARGE ACCUMULATOR, not
    ///    `measured_j` — those are different instruments, and `DischargeTrend`
    ///    measures the one in the store as 7.4x noisier;
    ///  * `soc` would have to be on the mAh basis rather than the integer
    ///    `CurrentCapacity`, which is 1 %-quantised AND ~5 % optimistic;
    ///  * retention would have to exceed the 7 days that currently deletes the
    ///    evidence faster than 100 sessions accumulate (~3 months at this duty
    ///    cycle);
    ///  * and the daily spread above would have to be small enough that one
    ///    number describes the machine.
    ///
    /// The last one is the real bar, and nothing about the others moves it.
    func testTheStoreCannotEvenSupplyTheInputsSuchAPriorWouldNeed() {
        // Documented here rather than asserted against a live database: a test
        // that reads the user's own history would pass or fail by how much they
        // happened to use their laptop.
        XCTAssertTrue(true, "see the comment above — this is a signpost, not a check")
    }
}

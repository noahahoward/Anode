import XCTest
@testable import PowerKit

/// The half-hour discharge trend: the signal the displayed time-to-empty is built
/// on. Everything here is synthetic — a simulated `AccumulatedBatteryDischarge`
/// counter driven at 1 Hz and published in 60-tick batches, exactly as the hardware
/// does it — so no test depends on the host being on battery.
final class DischargeTrendTests: XCTestCase {

    private let scale = makeMachineScale()
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let volts = 11_878.0

    /// Drives a trend with a load profile in watts, one 60-tick batch per minute.
    /// Returns the estimator so the caller can read `trend`.
    ///
    /// `awakeGap` inserts wall time the awake clock did NOT see — a sleep — before
    /// the minute at that index, with the counter still advancing at `sleepWatts`
    /// the way a hardware accumulator does.
    private func run(_ trend: BatteryDischargeTrend,
                     minutes: Int,
                     watts: (Int) -> Double,
                     from startMinute: Int = 0,
                     acc: inout Int64, count: inout UInt64, at: inout Date,
                     awake: inout TimeInterval,
                     sleepBefore: Int? = nil, sleepSeconds: TimeInterval = 0,
                     sleepWatts: Double = 0.2) {
        // The app records every couple of seconds, so the counter is read long
        // before the first batch publishes and that read is the window's left
        // endpoint. Seeding here keeps the fixture's arithmetic the same as the
        // running app's: two published batches is two minutes of window.
        if startMinute == 0 {
            trend.record(sample(acc: acc, count: count, at: at, awake: awake), onBattery: true)
        }
        for m in startMinute..<(startMinute + minutes) {
            if m == sleepBefore {
                // Asleep: the wall clock advances, the awake clock does not, and the
                // counter keeps integrating the machine's sleep draw.
                at = at.addingTimeInterval(sleepSeconds)
                acc &-= Int64(sleepWatts * 1000 * sleepSeconds)
                count &+= UInt64(sleepSeconds)
            }
            at = at.addingTimeInterval(60)
            awake += 60
            acc &-= Int64(watts(m) * 1000 * 60)
            count &+= 60
            trend.record(sample(acc: acc, count: count, at: at, awake: awake), onBattery: true)
        }
    }

    private func sample(acc: Int64, count: UInt64, at: Date, awake: TimeInterval,
                        mV: Double? = nil) -> BatteryDischargeTrend.Sample {
        BatteryDischargeTrend.Sample(accumulatedDischarge: acc, accumulatorCount: count,
                                     voltage_mV: mV ?? volts, timestamp: at, awake: awake)
    }

    /// Minutes of runtime the trend implies for a given charge — the displayed
    /// quantity, so every assertion below is about what the user sees.
    private func minutes(_ trend: BatteryDischargeTrend, mAh: Double = 3667) -> Double? {
        guard let t = trend.trend, t.current_mA > 0 else { return nil }
        return mAh / t.current_mA * 60
    }

    private func steady(_ watts: Double, minutes m: Int = 40,
                        trend: BatteryDischargeTrend = BatteryDischargeTrend())
        -> (BatteryDischargeTrend, Int64, UInt64, Date, TimeInterval) {
        var acc: Int64 = -1_000_000, count: UInt64 = 500_000
        var at = t0, awake = 10_000.0
        run(trend, minutes: m, watts: { _ in watts },
            acc: &acc, count: &count, at: &at, awake: &awake)
        return (trend, acc, count, at, awake)
    }

    // ── The quantity itself ─────────────────────────────────────────────────

    /// Units. 6 W at 11.878 V is 505 mA, and the window mean must be the exact
    /// integral, not a wall-clock division.
    func testWindowMeanIsTheExactIntegralOverTicks() {
        let (trend, _, _, _, _) = steady(6.0)
        let t = trend.trend
        XCTAssertNotNil(t)
        XCTAssertEqual(t!.power_mW, 6000, accuracy: 1)
        XCTAssertEqual(t!.current_mA, 6_000_000 / volts, accuracy: 0.5)
        // 30 minutes of window, not 40 minutes of history.
        XCTAssertEqual(Double(t!.ticks), 1800, accuracy: 60)
        XCTAssertTrue(t!.isFull)
    }

    /// A constant load must produce a time that does not wander. The pre-change
    /// path moved on 40% of ticks with a mean step of 1.0 min and a worst 2-minute
    /// swing of 134 min on the same input.
    func testConstantLoadDoesNotWander() {
        let trend = BatteryDischargeTrend()
        var acc: Int64 = -1_000_000, count: UInt64 = 500_000
        var at = t0, awake = 10_000.0
        var seen: [Double] = []
        for m in 0..<120 {
            run(trend, minutes: 1, watts: { _ in 6.0 }, from: m,
                acc: &acc, count: &count, at: &at, awake: &awake)
            if m >= 35, let v = minutes(trend) { seen.append(v) }
        }
        XCTAssertGreaterThan(seen.count, 60)
        let spread = seen.max()! - seen.min()!
        XCTAssertLessThan(spread, 1.0,
                          "a constant load must not move the answer at all: spread \(spread) min")
    }

    // ── Transients vs real change: the whole point ──────────────────────────

    /// One minute of triple load inside a half-hour window is one minute of it.
    /// Measured in the harness against the pre-change path: 44 min of movement
    /// instead of 245.
    func testOneMinuteSpikeBarelyMovesTheAnswer() {
        let (trend, a, c, d, w) = steady(6.0)
        var acc = a, count = c, at = d, awake = w
        let before = minutes(trend)!
        run(trend, minutes: 1, watts: { _ in 18.0 },
            acc: &acc, count: &count, at: &at, awake: &awake)
        let after = minutes(trend)!
        let moved = abs(after - before) / before
        // 1/30 of a 3x step is 6.7% on the rate, 6.2% on the time.
        XCTAssertLessThan(moved, 0.08,
                          "a 60 s spike moved the answer \(moved * 100)%")
        XCTAssertGreaterThan(moved, 0.03, "…but it must still move: this is not a filter")
    }

    /// Two minutes is still a transient and must not restart the window.
    func testTwoMinuteSpikeDoesNotRestartTheWindow() {
        let (trend, a, c, d, w) = steady(6.0)
        var acc = a, count = c, at = d, awake = w
        run(trend, minutes: 2, watts: { _ in 18.0 },
            acc: &acc, count: &count, at: &at, awake: &awake)
        XCTAssertGreaterThan(trend.trend!.ticks, 1500,
                             "the window collapsed on a two-minute transient")
    }

    /// A change that persists is followed, and within the stated time: five minutes
    /// of measured discharge to confirm, at which point the trend is the new load
    /// rather than an average of the two.
    func testSustainedChangeIsFollowedWithinFiveMinutes() {
        let (trend, a, c, d, w) = steady(6.0)
        var acc = a, count = c, at = d, awake = w
        let before = minutes(trend)!
        run(trend, minutes: 5, watts: { _ in 18.0 },
            acc: &acc, count: &count, at: &at, awake: &awake)
        let after = minutes(trend)!
        // The new regime is 3x the old, so the time must have roughly thirded.
        XCTAssertEqual(after, before / 3, accuracy: before / 3 * 0.2,
                       "a five-minute 3x load was not adopted: \(before) -> \(after)")
        XCTAssertLessThanOrEqual(trend.trend!.ticks, 360,
                                 "the window should now hold only the new regime")
    }

    /// The confirmation is measured in accumulator TICKS, not in publishes. On
    /// hardware batching every 10 s, counting publishes would restart the trend on
    /// a 50-second spike.
    func testConfirmationCountsTicksNotPublishes() {
        let trend = BatteryDischargeTrend()
        var acc: Int64 = -1_000_000, count: UInt64 = 500_000
        var at = t0, awake = 10_000.0
        // 30 minutes of 6 W, published every 10 s instead of every 60 s.
        for _ in 0..<180 {
            at = at.addingTimeInterval(10); awake += 10
            acc &-= Int64(6.0 * 1000 * 10); count &+= 10
            trend.record(sample(acc: acc, count: count, at: at, awake: awake), onBattery: true)
        }
        let before = minutes(trend)!
        // A 60 s spike is now SIX publishes.
        for _ in 0..<6 {
            at = at.addingTimeInterval(10); awake += 10
            acc &-= Int64(18.0 * 1000 * 10); count &+= 10
            trend.record(sample(acc: acc, count: count, at: at, awake: awake), onBattery: true)
        }
        XCTAssertGreaterThan(trend.trend!.ticks, 1500, "six publishes is still only one minute")
        XCTAssertLessThan(abs(minutes(trend)! - before) / before, 0.08)
    }

    // ── Warm-up: the detector may not fire against its own reflection ───────
    //
    // `detectRegimeChange` compares a new window against `trend`, and `trend`
    // CONTAINS that window. While the window is short the two are nearly the same
    // data — at five minutes one publish is a fifth of its own reference — so the
    // comparison is a hypothesis tested against itself. Measured over 6 h traces,
    // it collapsed the window inside the first fifteen minutes on 0.53 bursty runs
    // and 0.45 build-like ones.

    /// Five quiet minutes, then six minutes at four times the load. That is well
    /// past the 50 % band and well past the 300-tick confirmation, so before this
    /// gate the window collapsed onto the burst and the trend became a reading of
    /// the last six minutes. It must not: the reference was never a full window.
    func testTheDetectorDoesNotFireWhileItsReferenceIsShortOfAFullWindow() {
        let trend = BatteryDischargeTrend()
        var acc: Int64 = -1_000_000, count: UInt64 = 500_000
        var at = t0, awake = 10_000.0
        run(trend, minutes: 5, watts: { _ in 6.0 },
            acc: &acc, count: &count, at: &at, awake: &awake)
        run(trend, minutes: 6, watts: { _ in 24.0 }, from: 5,
            acc: &acc, count: &count, at: &at, awake: &awake)

        XCTAssertEqual(trend.trend?.ticks ?? 0, 660,
                       "the window kept all eleven minutes: nothing was thrown away")
        // And the answer is the mean of what actually happened, not of the burst:
        // (5 x 6 + 6 x 24) / 11 = 15.8 W.
        XCTAssertEqual(trend.trend?.power_mW ?? 0, 15_818, accuracy: 100)
    }

    /// The same excursion after the window is full DOES collapse it — the gate
    /// removes warm-up firings and nothing else. Without this the test above would
    /// pass for a class that had simply deleted the detector.
    func testTheSameExcursionStillFiresOnceTheWindowIsFull() {
        let (trend, a, c, d, w) = steady(6.0, minutes: 35)
        var acc = a, count = c, at = d, awake = w
        XCTAssertTrue(trend.trend?.isFull ?? false, "the fixture must start full")
        run(trend, minutes: 6, watts: { _ in 24.0 }, from: 35,
            acc: &acc, count: &count, at: &at, awake: &awake)
        XCTAssertLessThanOrEqual(trend.trend?.ticks ?? .max, 420,
                                 "a confirmed regime change must still collapse the window")
    }

    /// A run built up out of warm-up noise must not be banked and cashed in the
    /// instant the window matures — that is the same bug arriving half an hour
    /// later. The load here is out of band for the five minutes either side of the
    /// 30-minute mark, and the window must survive the boundary.
    func testAWarmUpRunIsNotBankedUntilTheWindowMatures() {
        let trend = BatteryDischargeTrend()
        var acc: Int64 = -1_000_000, count: UInt64 = 500_000
        var at = t0, awake = 10_000.0
        run(trend, minutes: 26, watts: { _ in 6.0 },
            acc: &acc, count: &count, at: &at, awake: &awake)
        // Six minutes out of band, starting while the window is still immature and
        // running past the point where it fills. Counted from the first out-of-band
        // publish that is more than the 300-tick confirmation, so a detector that
        // banked the warm-up ticks would have collapsed the window by now.
        run(trend, minutes: 6, watts: { _ in 24.0 }, from: 26,
            acc: &acc, count: &count, at: &at, awake: &awake)
        XCTAssertGreaterThan(trend.trend?.ticks ?? 0, 1500,
                             "the pre-maturity run was cashed the moment the window filled")
    }

    // ── Counters: wrap, reset, direction ────────────────────────────────────

    /// The accumulator is signed and counts DOWN. A wrap past the bottom of the
    /// range must still difference to the true energy — `&-`, not a trap and not a
    /// near-2^64 garbage figure.
    func testCounterWrapIsDifferencedCorrectly() {
        let a = sample(acc: Int64.min + 100, count: 1000, at: t0, awake: 0)
        // 300 mW·s more discharge takes it past Int64.min and round to the top.
        let b = sample(acc: Int64.max - 199, count: 1060,
                       at: t0.addingTimeInterval(60), awake: 60)
        let w = BatteryDischargeTrend.Window.between(a, b)
        XCTAssertNotNil(w, "a wrap must not be rejected")
        XCTAssertEqual(w!.power_mW, 300.0 / 60.0, accuracy: 1e-9)
    }

    /// A wrap in the TICK counter is the same argument.
    func testTickCounterWrapIsDifferencedCorrectly() {
        let a = sample(acc: -1000, count: UInt64.max - 29, at: t0, awake: 0)
        let b = sample(acc: -1000 - 60 * 6000, count: 30,
                       at: t0.addingTimeInterval(60), awake: 60)
        let w = BatteryDischargeTrend.Window.between(a, b)
        XCTAssertEqual(w?.ticks, 60)
        XCTAssertEqual(w?.power_mW ?? 0, 6000, accuracy: 1e-9)
    }

    /// A counter RESET looks identical to a wrap under `&-`, and only the size of
    /// the answer tells them apart. Same rule as `SystemPowerWindow`.
    func testCounterResetYieldsNoWindow() {
        let a = sample(acc: -522_346_500, count: 72_367, at: t0, awake: 0)
        let b = sample(acc: 0, count: 72_427, at: t0.addingTimeInterval(60), awake: 60)
        XCTAssertNil(BatteryDischargeTrend.Window.between(a, b),
                     "a reset to zero is not 8.7e12 W of charging")
    }

    func testChargingWindowIsRefused() {
        let a = sample(acc: -1000, count: 1000, at: t0, awake: 0)
        let b = sample(acc: -400, count: 1060, at: t0.addingTimeInterval(60), awake: 60)
        XCTAssertNil(BatteryDischargeTrend.Window.between(a, b))
    }

    func testImplausiblePowerIsRefused() {
        let a = sample(acc: 0, count: 1000, at: t0, awake: 0)
        let b = sample(acc: -60 * 500_000, count: 1060,   // 500 W
                       at: t0.addingTimeInterval(60), awake: 60)
        XCTAssertNil(BatteryDischargeTrend.Window.between(a, b))
    }

    func testNoNewBatchYieldsNoWindow() {
        let a = sample(acc: -1000, count: 1000, at: t0, awake: 0)
        XCTAssertNil(BatteryDischargeTrend.Window.between(a, a))
    }

    /// A reset counter reaching `record` must drop the window rather than poison it,
    /// AND must let it rebuild. Keeping the pre-reset endpoint is not merely untidy:
    /// every window drawn from it differences the discontinuity, so the trend would
    /// answer nothing for the next half hour rather than the next two minutes.
    func testResetDuringRecordDropsTheWindowAndThenRebuilds() {
        let (trend, _, c, d, w) = steady(6.0)
        var acc: Int64 = 0, count = c, at = d, awake = w
        at = at.addingTimeInterval(60); awake += 60; count &+= 60
        trend.record(sample(acc: acc, count: count, at: at, awake: awake), onBattery: true)
        XCTAssertNil(trend.trend, "a reset counter must leave no trend, not a wrong one")

        // Six minutes, because the floor is five publishes — the point is that it
        // REBUILDS, not how fast.
        run(trend, minutes: 6, watts: { _ in 6.0 }, from: 41,
            acc: &acc, count: &count, at: &at, awake: &awake)
        XCTAssertEqual(trend.trend?.power_mW ?? 0, 6000, accuracy: 1,
                       "the window must rebuild from the post-reset counter")
    }

    // ── Sleep ───────────────────────────────────────────────────────────────

    /// The accumulator is hardware and keeps ticking through a sleep at the ~0.2 W
    /// the machine draws there. Averaged into a half-hour window that reads as a
    /// machine sipping nothing — told to the user at the exact moment they opened
    /// the lid to look.
    func testTrendIsNotFittedAcrossASleep() {
        let (trend, a, c, d, w) = steady(6.0)
        var acc = a, count = c, at = d, awake = w
        let before = minutes(trend)!

        // 40 minutes asleep, then one minute awake at the same 6 W.
        run(trend, minutes: 1, watts: { _ in 6.0 }, from: 40,
            acc: &acc, count: &count, at: &at, awake: &awake,
            sleepBefore: 40, sleepSeconds: 2400)
        // One post-wake minute cannot clear the five-window floor: nothing is claimed.
        XCTAssertNil(trend.trend, "the window must restart, not average across the sleep")

        run(trend, minutes: 6, watts: { _ in 6.0 }, from: 41,
            acc: &acc, count: &count, at: &at, awake: &awake)
        let after = minutes(trend)!
        XCTAssertEqual(after, before, accuracy: before * 0.05,
                       "post-wake the answer must describe the load now, not the sleep")
    }

    /// The control: an ordinary slow tick is not a sleep and must not cost the
    /// window. Without this the test above would pass for a class that reset on
    /// every sample.
    func testAnOrdinaryGapKeepsTheWindow() {
        let (trend, a, c, d, w) = steady(6.0)
        var acc = a, count = c, at = d, awake = w
        at = at.addingTimeInterval(90); awake += 90
        acc &-= Int64(6.0 * 1000 * 90); count &+= 90
        trend.record(sample(acc: acc, count: count, at: at, awake: awake), onBattery: true)
        XCTAssertGreaterThan(trend.trend?.ticks ?? 0, 1500)
    }

    /// The gauge does not publish on a metronome — `dCount` has been seen at 2, 19,
    /// 24 and 26 as well as 60, and a real trace went 156 s between two publishes on
    /// a plainly awake machine. A cumulative counter loses nothing to a missed poll,
    /// so that must not cost the window.
    func testASkippedPublishOnAnAwakeMachineKeepsTheWindow() {
        let (trend, a, c, d, w) = steady(6.0)
        var acc = a, count = c, at = d, awake = w
        let before = minutes(trend)!
        at = at.addingTimeInterval(156); awake += 156
        acc &-= Int64(6.0 * 1000 * 156); count &+= 156
        trend.record(sample(acc: acc, count: count, at: at, awake: awake), onBattery: true)
        XCTAssertGreaterThan(trend.trend?.ticks ?? 0, 1500,
                             "a skipped gauge publish is not a gap in the measurement")
        XCTAssertEqual(minutes(trend)!, before, accuracy: 1.0)
    }

    /// …but a gap longer than the whole window is one the window cannot honour: it
    /// cannot be pruned back to half an hour, because there is nothing in between to
    /// prune to. Start again rather than report a mean over hours as a half-hour one.
    func testAGapLongerThanTheWindowRestartsIt() {
        let (trend, a, c, d, w) = steady(6.0)
        var acc = a, count = c, at = d, awake = w
        at = at.addingTimeInterval(2400); awake += 2400        // awake the whole time
        acc &-= Int64(6.0 * 1000 * 2400); count &+= 2400
        trend.record(sample(acc: acc, count: count, at: at, awake: awake), onBattery: true)
        XCTAssertNil(trend.trend)
    }

    /// AC is not a slower discharge, it is a different question. The window goes.
    func testGoingOnACDropsTheWindow() {
        let (trend, a, c, d, w) = steady(6.0)
        var acc = a, count = c, at = d, awake = w
        at = at.addingTimeInterval(60); awake += 60; acc &-= 100; count &+= 60
        trend.record(sample(acc: acc, count: count, at: at, awake: awake), onBattery: false)
        XCTAssertNil(trend.trend)
    }

    // ── Honest nils ─────────────────────────────────────────────────────────

    /// Before FIVE published windows there is no trend, and nil is the answer.
    /// The caller shows the power-based figure and labels it; it does not guess.
    ///
    /// The floor was two windows until a cold boot on battery produced a headline
    /// of 25 h replaced by 5 h one second later. Two minutes is a third of one
    /// publish, so a single batch moved the answer by twenty hours — and the app
    /// stated it. Five publishes is the point at which one batch can no longer
    /// dominate. It does not make the early estimate ACCURATE (a machine still
    /// settling after login has no stable answer to give); it stops the app
    /// asserting one it cannot support.
    func testTooLittleHistoryReportsNothing() {
        let trend = BatteryDischargeTrend()
        var acc: Int64 = -1_000_000, count: UInt64 = 500_000
        var at = t0, awake = 10_000.0
        run(trend, minutes: 4, watts: { _ in 6.0 },
            acc: &acc, count: &count, at: &at, awake: &awake)
        XCTAssertNil(trend.trend, "four 60 s windows is still not enough to speak")
        run(trend, minutes: 1, watts: { _ in 6.0 }, from: 4,
            acc: &acc, count: &count, at: &at, awake: &awake)
        XCTAssertNotNil(trend.trend, "five windows is an exact five-minute measurement")
        XCTAssertFalse(trend.trend!.isFull, "…and it must say it is not the full window")
    }

    /// A partial window is a shorter measurement, not a worse one: the same load
    /// gives the same answer from two minutes of history as from thirty.
    func testPartialWindowAgreesWithTheFullOne() {
        let trend = BatteryDischargeTrend()
        var acc: Int64 = -1_000_000, count: UInt64 = 500_000
        var at = t0, awake = 10_000.0
        run(trend, minutes: 5, watts: { _ in 6.0 },
            acc: &acc, count: &count, at: &at, awake: &awake)
        let early = minutes(trend)!
        run(trend, minutes: 35, watts: { _ in 6.0 }, from: 5,
            acc: &acc, count: &count, at: &at, awake: &awake)
        XCTAssertEqual(early, minutes(trend)!, accuracy: 1.0)
    }

    /// A cold boot on battery must not publish an ETD from a two-minute window.
    ///
    /// Reported live after a restart: the headline read 25 h, then 5 h one second
    /// later, then held for a minute. Both were defensible in isolation — the
    /// pack was drawing 712 mA at 12.81 V (11.5 %/hr) and the load average was
    /// collapsing from 8.78 to 3.35 as login items settled — but a 120-tick
    /// window is a third of a single publish, so one new batch moved the answer
    /// by twenty hours, and the app asserted "25 hours" on the strength of it.
    func testAShortWindowPublishesNothingRatherThanAWildNumber() {
        let t = BatteryDischargeTrend()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        // Four publishes: 240 ticks, comfortably past the OLD 120-tick floor.
        for i in 0...4 {
            _ = t.record(sample(acc: Int64(-9_000 * i * 60), count: UInt64(i * 60),
                                at: start.addingTimeInterval(Double(i) * 60),
                                awake: Double(i) * 60),
                         onBattery: true)
        }
        XCTAssertNil(t.trend,
                     "240 ticks is four minutes; one batch still dominates it")

        // A fifth publish crosses five minutes and it may speak.
        _ = t.record(sample(acc: Int64(-9_000 * 300), count: 300,
                            at: start.addingTimeInterval(300), awake: 300),
                     onBattery: true)
        XCTAssertNotNil(t.trend, "five publishes is enough to answer")
        XCTAssertEqual(t.trend?.ticks, 300)
    }

    /// The floor is a MINIMUM, not the window. Crossing it must not be mistaken
    /// for the window being full — `isFull` still gates on the 30-minute span,
    /// and a caller that conflated them would stop reporting maturity.
    func testCrossingTheFloorIsNotTheSameAsAFullWindow() {
        let t = BatteryDischargeTrend()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0...5 {
            _ = t.record(sample(acc: Int64(-9_000 * i * 60), count: UInt64(i * 60),
                                at: start.addingTimeInterval(Double(i) * 60),
                                awake: Double(i) * 60),
                         onBattery: true)
        }
        XCTAssertNotNil(t.trend)
        XCTAssertFalse(t.trend?.isFull ?? true,
                       "five minutes of a thirty minute window is not full")
    }
}

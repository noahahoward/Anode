import XCTest
@testable import PowerKit

/// Ready By in the pure policy: hold the battery where it is until it has to charge to be at the limit by a time of
/// day. Every number the rule uses (the window, the floor, the margin, the taper) is pinned here from its own
/// constant, so changing one is a visible change of a test and not a silent change of what the Mac does overnight.
final class ReadyByPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600
    private let minute: TimeInterval = 60

    /// Limit 80, Ready By on, nothing else, at 0.8 percent per minute: the middle band's guess.
    private func settings(limit: Int = 80, readyBy: Bool = true) -> ChargeSettingsSnapshot {
        ChargeSettingsSnapshot(limit: limit, driftEnabled: false, driftGap: 5,
                               pauseWhenHotEnabled: false, maxTemperatureC: 35,
                               holdDuringSleep: false, drainAutomatically: false,
                               readyByEnabled: readyBy, readyByMinutes: 420)
    }

    private func inputs(percent: Int = 54, at now: Date? = nil, by: Date?, rate: Double = 0.8,
                        onAC: Bool = true, sleeping: Bool = false, fullCharge: Bool = false,
                        manualDrain: Bool = false, temperature: Double? = 25) -> ChargeInputs {
        ChargeInputs(percent: percent, onAC: onAC, temperatureC: temperature, sleeping: sleeping,
                     fullCharge: fullCharge, manualDrain: manualDrain, now: now ?? t0, readyBy: by, chargeRate: rate)
    }

    /// The seconds before the moment that charging starts, for a hold at `level` going to `limit`.
    private func lead(level: Int, limit: Int = 80, rate: Double = 0.8) -> TimeInterval {
        ChargePolicy.minutesToCharge(from: level, to: limit, rate: rate) * 60 + ChargePolicy.readyByMargin
    }

    // ── The constants ───────────────────────────────────────────────────────

    func testTheNamedNumbers() {
        XCTAssertEqual(ChargePolicy.readyByWindow, 12 * 3600)
        XCTAssertEqual(ChargePolicy.readyByFloor, 30)
        XCTAssertEqual(ChargePolicy.readyByMargin, 15 * 60)
        XCTAssertEqual(ChargePolicy.chargeTaperAbove, 80)
        XCTAssertEqual(ChargePolicy.chargeTaperFactor, 0.5)
        XCTAssertEqual(ChargePolicy.defaultReadyByMinutes, 420)
        XCTAssertEqual(ChargePolicy.chargeRateRange, 0.1...3.0)
    }

    func testTimeToChargeCountsTheTaperAtHalfTheRate() {
        // Straight: 26 points at 0.8 a minute.
        XCTAssertEqual(ChargePolicy.minutesToCharge(from: 54, to: 80, rate: 0.8), 32.5, accuracy: 1e-9)
        // Entirely above 80: 20 points at 0.4.
        XCTAssertEqual(ChargePolicy.minutesToCharge(from: 80, to: 100, rate: 0.8), 50, accuracy: 1e-9)
        XCTAssertEqual(ChargePolicy.minutesToCharge(from: 90, to: 100, rate: 0.8), 25, accuracy: 1e-9)
        // Across 80: both parts.
        XCTAssertEqual(ChargePolicy.minutesToCharge(from: 54, to: 100, rate: 0.8), 82.5, accuracy: 1e-9)
        // Nothing to charge.
        XCTAssertEqual(ChargePolicy.minutesToCharge(from: 80, to: 80, rate: 0.8), 0)
        XCTAssertEqual(ChargePolicy.minutesToCharge(from: 90, to: 60, rate: 0.8), 0)
    }

    /// A rate that is not a charger's is the slowest one: it starts early, never late.
    func testTimeToChargeBelievesOnlyRatesInsideTheRange() {
        let slowest = ChargePolicy.minutesToCharge(from: 50, to: 80, rate: 0.1)
        for bad in [Double.nan, .infinity, -1, 0] {
            XCTAssertEqual(ChargePolicy.minutesToCharge(from: 50, to: 80, rate: bad), slowest, "rate \(bad)")
        }
        XCTAssertEqual(ChargePolicy.minutesToCharge(from: 50, to: 80, rate: 0.01), slowest)
        XCTAssertEqual(ChargePolicy.minutesToCharge(from: 50, to: 80, rate: 50),
                       ChargePolicy.minutesToCharge(from: 50, to: 80, rate: 3), "faster than 3 is a misreading")
    }

    // ── The hold ────────────────────────────────────────────────────────────

    func testHoldsWhereItIsInsideTheWindowAndSaysWhenToRaise() throws {
        let by = t0.addingTimeInterval(8 * hour)
        var m = ChargeMemory()
        let d = ChargePolicy.decide(settings(), inputs(by: by), &m)
        XCTAssertEqual(d.osLimit, 54)
        XCTAssertEqual(d.reason, .readyBy)
        XCTAssertNil(d.dischargeTo)
        XCTAssertEqual(d.readyBy, ReadyByState(by: by, raiseAt: by.addingTimeInterval(-lead(level: 54)), raiseTo: 80))
        // 26 points at 0.8 is 32.5 minutes, and the margin is 15 more.
        XCTAssertEqual(by.timeIntervalSince(try XCTUnwrap(d.readyBy?.raiseAt)), 32.5 * 60 + 15 * 60, accuracy: 1e-6)
        XCTAssertEqual(m.readyBy, ReadyByMemory(moment: by, level: 54, started: false))
    }

    func testTheWindowIsTwelveHoursAndIncludesItsEdge() {
        var m = ChargeMemory()
        let inside = ChargePolicy.decide(settings(), inputs(by: t0.addingTimeInterval(12 * hour)), &m)
        XCTAssertEqual(inside.reason, .readyBy, "exactly 12 hours away is inside the window")
        m = ChargeMemory()
        let justInside = ChargePolicy.decide(settings(), inputs(by: t0.addingTimeInterval(12 * hour - 1)), &m)
        XCTAssertEqual(justInside.reason, .readyBy)
        m = ChargeMemory()
        let outside = ChargePolicy.decide(settings(), inputs(by: t0.addingTimeInterval(12 * hour + 1)), &m)
        XCTAssertEqual(outside.reason, .limit, "a second further and the battery charges as usual")
        XCTAssertEqual(outside.osLimit, 80)
        XCTAssertNil(outside.readyBy)
        XCTAssertNil(m.readyBy)
    }

    func testBelowTheFloorItChargesToTheFloorFirstThenHolds() {
        let by = t0.addingTimeInterval(8 * hour)
        for p in [20, 25, 29] {
            var m = ChargeMemory()
            let d = ChargePolicy.decide(settings(), inputs(percent: p, by: by), &m)
            XCTAssertEqual(d.reason, .readyBy, "\(p)%")
            XCTAssertEqual(d.osLimit, 30, "\(p)% charges to the floor, not beyond it")
            // The start moment is worked out from where it will hold: 30%.
            XCTAssertEqual(d.readyBy?.raiseAt, by.addingTimeInterval(-lead(level: 30)), "\(p)%")
        }
        var m = ChargeMemory()
        XCTAssertEqual(ChargePolicy.decide(settings(), inputs(percent: 30, by: by), &m).osLimit, 30)
        m = ChargeMemory()
        XCTAssertEqual(ChargePolicy.decide(settings(), inputs(percent: 31, by: by), &m).osLimit, 31)
    }

    /// The floor is not a reason to charge past the person's own limit.
    func testALimitBelowTheFloorIsTheFloor() {
        let by = t0.addingTimeInterval(8 * hour)
        var m = ChargeMemory()
        let d = ChargePolicy.decide(settings(limit: 25), inputs(percent: 22, by: by), &m)
        XCTAssertEqual(d.reason, .readyBy)
        XCTAssertEqual(d.osLimit, 25, "charging to 30 would pass a limit of 25")
        XCTAssertEqual(d.readyBy?.raiseTo, 25)
        // At the limit there is nothing to hold below.
        m = ChargeMemory()
        XCTAssertEqual(ChargePolicy.decide(settings(limit: 25), inputs(percent: 25, by: by), &m).reason, .limit)
    }

    // ── The start moment ────────────────────────────────────────────────────

    func testItStartsExactlyAtTheStartMomentAndNotBefore() {
        let by = t0.addingTimeInterval(8 * hour)
        let start = by.addingTimeInterval(-lead(level: 54))
        var m = ChargeMemory()
        let before = ChargePolicy.decide(settings(), inputs(at: start.addingTimeInterval(-1), by: by), &m)
        XCTAssertEqual(before.reason, .readyBy)
        XCTAssertEqual(before.osLimit, 54)
        XCTAssertTrue(before.readyBy?.isHolding == true)

        let at = ChargePolicy.decide(settings(), inputs(at: start, by: by), &m)
        XCTAssertEqual(at.reason, .readyBy)
        XCTAssertEqual(at.osLimit, 80, "at the start moment the limit is raised to the person's")
        XCTAssertEqual(at.readyBy, ReadyByState(by: by, raiseAt: nil, raiseTo: 80), "charging for Ready By")
        XCTAssertEqual(m.readyBy?.started, true)
    }

    func testTheStartMomentCountsTheTaperAboveEighty() throws {
        // Limit 100 from 54: 32.5 minutes to 80, then 20 points at half the rate, 50 minutes more.
        let by = t0.addingTimeInterval(8 * hour)
        var m = ChargeMemory()
        let d = ChargePolicy.decide(settings(limit: 100), inputs(by: by), &m)
        XCTAssertEqual(d.reason, .readyBy)
        XCTAssertEqual(d.osLimit, 54)
        XCTAssertEqual(d.readyBy?.raiseTo, 100)
        XCTAssertEqual(by.timeIntervalSince(try XCTUnwrap(d.readyBy?.raiseAt)), (32.5 + 50) * 60 + 15 * 60,
                       accuracy: 1e-6)
        // Without the taper the same climb would start 25 minutes later.
        XCTAssertLessThan(try XCTUnwrap(d.readyBy?.raiseAt),
                          by.addingTimeInterval(-((46) / 0.8 * 60 + 15 * 60)))
    }

    func testALimitAboveEightyHoldsAndChargesWithTheTaperFromAHigherLevel() throws {
        let by = t0.addingTimeInterval(6 * hour)
        var m = ChargeMemory()
        let d = ChargePolicy.decide(settings(limit: 100), inputs(percent: 85, by: by), &m)
        XCTAssertEqual(d.osLimit, 85)
        // 15 points entirely above 80 at 0.4 a minute: 37.5 minutes.
        XCTAssertEqual(by.timeIntervalSince(try XCTUnwrap(d.readyBy?.raiseAt)), 37.5 * 60 + 15 * 60, accuracy: 1e-6)
    }

    func testNotEnoughTimeChargesAtOnce() {
        // 20 minutes away, and it needs 47.5.
        let by = t0.addingTimeInterval(20 * minute)
        var m = ChargeMemory()
        let d = ChargePolicy.decide(settings(), inputs(by: by), &m)
        XCTAssertEqual(d.reason, .readyBy)
        XCTAssertEqual(d.osLimit, 80, "no time to wait: charge now")
        XCTAssertNil(d.readyBy?.raiseAt)
        XCTAssertEqual(m.readyBy?.started, true)
    }

    /// Below the floor with no time to spare: no stop at 30, straight to the limit.
    func testNoTimeEvenForTheFloorChargesStraightThrough() {
        let by = t0.addingTimeInterval(30 * minute)
        var m = ChargeMemory()
        let d = ChargePolicy.decide(settings(), inputs(percent: 22, by: by), &m)
        XCTAssertEqual(d.osLimit, 80)
        XCTAssertNil(d.readyBy?.raiseAt)
    }

    // ── Started stays started ───────────────────────────────────────────────

    func testOnceStartedItStaysStartedWhateverTheEstimateDoes() {
        let by = t0.addingTimeInterval(8 * hour)
        let start = by.addingTimeInterval(-lead(level: 54))
        var m = ChargeMemory()
        _ = ChargePolicy.decide(settings(), inputs(at: start, by: by), &m)
        // A much faster rate, and more charge, would put the start hours later. It does not stop again.
        let later = ChargePolicy.decide(settings(), inputs(percent: 63, at: start.addingTimeInterval(5 * minute),
                                                           by: by, rate: 3), &m)
        XCTAssertEqual(later.osLimit, 80)
        XCTAssertNil(later.readyBy?.raiseAt)
        // Even a reading that fell back below where the hold had been.
        let lower = ChargePolicy.decide(settings(), inputs(percent: 50, at: start.addingTimeInterval(10 * minute),
                                                           by: by, rate: 3), &m)
        XCTAssertEqual(lower.osLimit, 80)
        XCTAssertNil(lower.readyBy?.raiseAt)
        // Up to the moment itself.
        let last = ChargePolicy.decide(settings(), inputs(percent: 70, at: by.addingTimeInterval(-1), by: by), &m)
        XCTAssertEqual(last.osLimit, 80)
    }

    func testAtTheLimitStartedHasNothingLeftToDoAndAFallBelowStartsItAgain() {
        let by = t0.addingTimeInterval(20 * minute)
        var m = ChargeMemory()
        _ = ChargePolicy.decide(settings(), inputs(by: by), &m)
        let atLimit = ChargePolicy.decide(settings(), inputs(percent: 80, at: t0.addingTimeInterval(10 * minute), by: by), &m)
        XCTAssertEqual(atLimit.reason, .limit, "at the limit the rule does nothing")
        XCTAssertEqual(m.readyBy?.started, true, "and what it has started is not forgotten")
        let sagged = ChargePolicy.decide(settings(), inputs(percent: 79, at: t0.addingTimeInterval(11 * minute), by: by), &m)
        XCTAssertEqual(sagged.reason, .readyBy)
        XCTAssertEqual(sagged.osLimit, 80, "a sag after the start is charged back, not held")
    }

    func testOncePassedTheNextMomentIsOutsideTheWindowAndTheBatteryChargesAsUsual() {
        let by = t0.addingTimeInterval(20 * minute)
        var m = ChargeMemory()
        _ = ChargePolicy.decide(settings(), inputs(by: by), &m)
        XCTAssertEqual(m.readyBy?.started, true)
        let after = by.addingTimeInterval(1)
        let tomorrow = by.addingTimeInterval(24 * hour)
        let d = ChargePolicy.decide(settings(), inputs(percent: 60, at: after, by: tomorrow), &m)
        XCTAssertEqual(d.reason, .limit)
        XCTAssertEqual(d.osLimit, 80)
        XCTAssertNil(m.readyBy, "the memory for a moment that has passed goes")
    }

    /// 11 hours after the moment has passed the next one is 13 hours away: the same day's evening plug-in. Then, 12
    /// hours or less before it, the next hold begins, as a new one.
    func testTheNextMomentStartsAFreshHold() {
        let by = t0.addingTimeInterval(20 * minute)
        var m = ChargeMemory()
        _ = ChargePolicy.decide(settings(), inputs(by: by), &m)
        let tomorrow = by.addingTimeInterval(24 * hour)
        let evening = tomorrow.addingTimeInterval(-9 * hour)
        let d = ChargePolicy.decide(settings(), inputs(percent: 80, at: evening, by: tomorrow), &m)
        XCTAssertEqual(d.reason, .limit, "at the limit: nothing to hold below")
        let down = ChargePolicy.decide(settings(), inputs(percent: 70, at: evening, by: tomorrow), &m)
        XCTAssertEqual(down.reason, .readyBy)
        XCTAssertEqual(down.osLimit, 70)
        XCTAssertTrue(down.readyBy?.isHolding == true)
        XCTAssertEqual(m.readyBy, ReadyByMemory(moment: tomorrow, level: 70, started: false))
    }

    func testUnpluggingEndsItAndItIsRecalculatedOnTheNextConnection() {
        let by = t0.addingTimeInterval(20 * minute)
        var m = ChargeMemory()
        _ = ChargePolicy.decide(settings(), inputs(by: by), &m)
        XCTAssertEqual(m.readyBy?.started, true)
        let unplugged = ChargePolicy.decide(settings(), inputs(percent: 60, at: t0.addingTimeInterval(5 * minute),
                                                               by: by, onAC: false), &m)
        XCTAssertEqual(unplugged.osLimit, 80)
        XCTAssertEqual(unplugged.reason, .limit)
        XCTAssertNil(unplugged.readyBy)
        XCTAssertNil(m.readyBy, "unplugging forgets that charging had started")
        // Plugged in again with hours to spare: a hold, not a continued charge.
        let later = ChargePolicy.decide(settings(), inputs(percent: 60, at: t0.addingTimeInterval(6 * minute),
                                                           by: t0.addingTimeInterval(9 * hour)), &m)
        XCTAssertEqual(later.osLimit, 60)
        XCTAssertTrue(later.readyBy?.isHolding == true)
    }

    /// Changing the time is a different moment: what was started for the old one is not carried over.
    func testAChangedMomentIsANewPlan() {
        let by = t0.addingTimeInterval(20 * minute)
        var m = ChargeMemory()
        _ = ChargePolicy.decide(settings(), inputs(by: by), &m)
        XCTAssertEqual(m.readyBy?.started, true)
        let later = t0.addingTimeInterval(8 * hour)
        let d = ChargePolicy.decide(settings(), inputs(percent: 60, at: t0.addingTimeInterval(5 * minute), by: later), &m)
        XCTAssertEqual(d.osLimit, 60, "holding again for the new time")
        XCTAssertTrue(d.readyBy?.isHolding == true)
        XCTAssertEqual(m.readyBy?.moment, later)
    }

    // ── The level it holds at ───────────────────────────────────────────────

    func testTheHoldLevelDoesNotFollowTheChargeAbout() throws {
        let by = t0.addingTimeInterval(8 * hour)
        var m = ChargeMemory()
        let first = ChargePolicy.decide(settings(), inputs(percent: 54, by: by), &m)
        // A reading a point up, then a point down: the limit stays where it was put, and so does the moment. Held at
        // 54, a battery that reads 53 is charged back to 54 by macOS, not held at 53.
        let up = ChargePolicy.decide(settings(), inputs(percent: 55, at: t0.addingTimeInterval(30), by: by), &m)
        XCTAssertEqual(up.osLimit, 54)
        XCTAssertEqual(up.readyBy?.raiseAt, first.readyBy?.raiseAt)
        let down = ChargePolicy.decide(settings(), inputs(percent: 53, at: t0.addingTimeInterval(60), by: by), &m)
        XCTAssertEqual(down.osLimit, 54, "held at 54, so macOS charges it back up")
        XCTAssertEqual(down.readyBy?.raiseAt, first.readyBy?.raiseAt)
    }

    /// A hold is a hold only while Ready By is what decides: if something else decided in between, the next hold
    /// starts from where the battery is then.
    func testAnotherRuleDecidingEndsTheHoldAndTheNextOneStartsFromTheChargeThen() {
        let by = t0.addingTimeInterval(8 * hour)
        var m = ChargeMemory()
        XCTAssertEqual(ChargePolicy.decide(settings(), inputs(percent: 54, by: by), &m).osLimit, 54)
        let full = ChargePolicy.decide(settings(), inputs(percent: 60, at: t0.addingTimeInterval(60), by: by,
                                                          fullCharge: true), &m)
        XCTAssertEqual(full.reason, .fullCharge)
        XCTAssertNil(m.readyBy, "a hold the person overrode is over")
        let after = ChargePolicy.decide(settings(), inputs(percent: 60, at: t0.addingTimeInterval(120), by: by), &m)
        XCTAssertEqual(after.osLimit, 60)
    }

    // ── Overrides, and the order ────────────────────────────────────────────

    func testChargeToFullOverridesIt() {
        var m = ChargeMemory()
        let d = ChargePolicy.decide(settings(), inputs(by: t0.addingTimeInterval(8 * hour), fullCharge: true), &m)
        XCTAssertEqual(d.reason, .fullCharge)
        XCTAssertEqual(d.osLimit, 100)
        XCTAssertNil(d.readyBy)
    }

    func testPauseWhenHotStillPauses() {
        var s = settings()
        s.pauseWhenHotEnabled = true
        var m = ChargeMemory()
        let d = ChargePolicy.decide(s, inputs(by: t0.addingTimeInterval(20 * minute), temperature: 40), &m)
        XCTAssertEqual(d.reason, .heat, "a hot pack matters more than the time, even with none to spare")
        XCTAssertEqual(d.osLimit, 54)
        // And Ready By is in force again once the pack has been cool for the five minutes.
        let cool = ChargePolicy.decide(s, inputs(at: t0.addingTimeInterval(1), by: t0.addingTimeInterval(20 * minute),
                                                 temperature: 25), &m)
        XCTAssertEqual(cool.reason, .heat)
        let resumed = ChargePolicy.decide(s, inputs(at: t0.addingTimeInterval(1 + ChargePolicy.heatResumeAfter),
                                                    by: t0.addingTimeInterval(20 * minute), temperature: 25), &m)
        XCTAssertEqual(resumed.reason, .readyBy)
        XCTAssertEqual(resumed.osLimit, 80)
    }

    func testItOutranksHoldLevelDuringSleepInsideTheWindowAndYieldsOutsideIt() {
        var s = settings()
        s.holdDuringSleep = true
        var m = ChargeMemory()
        // Inside the window, before the start: the hold is Ready By's own.
        let hold = ChargePolicy.decide(s, inputs(by: t0.addingTimeInterval(8 * hour), sleeping: true), &m)
        XCTAssertEqual(hold.reason, .readyBy)
        XCTAssertEqual(hold.osLimit, 54)
        // After the start, the battery has to charge while the Mac sleeps.
        m = ChargeMemory()
        let charge = ChargePolicy.decide(s, inputs(by: t0.addingTimeInterval(20 * minute), sleeping: true), &m)
        XCTAssertEqual(charge.reason, .readyBy)
        XCTAssertEqual(charge.osLimit, 80, "Hold Level During Sleep must not stop the charge Ready By started")
        // Outside the window it does nothing, and the sleep hold is the sleep hold.
        m = ChargeMemory()
        let outside = ChargePolicy.decide(s, inputs(by: t0.addingTimeInterval(13 * hour), sleeping: true), &m)
        XCTAssertEqual(outside.reason, .sleeping)
        XCTAssertEqual(outside.osLimit, 54)
    }

    func testAboveTheLimitItDoesNothingAndADrainProceeds() {
        var s = settings()
        s.drainAutomatically = true
        var m = ChargeMemory()
        let d = ChargePolicy.decide(s, inputs(percent: 90, by: t0.addingTimeInterval(8 * hour)), &m)
        XCTAssertEqual(d.reason, .draining)
        XCTAssertEqual(d.dischargeTo, 80)
        s.drainAutomatically = false
        let above = ChargePolicy.decide(s, inputs(percent: 85, by: t0.addingTimeInterval(8 * hour)), &m)
        XCTAssertEqual(above.reason, .limit)
        XCTAssertEqual(above.osLimit, 80)
        // At the limit: nothing to hold below, and nothing to charge for.
        let at = ChargePolicy.decide(s, inputs(percent: 80, by: t0.addingTimeInterval(8 * hour)), &m)
        XCTAssertEqual(at.reason, .limit)
        XCTAssertNil(m.readyBy)
    }

    /// A manual drain that has reached the limit is over, and Ready By's hold does not leave it pressed for ever.
    func testAManualDrainThatHasReachedTheLimitEndsInsteadOfStayingPressed() {
        var m = ChargeMemory()
        let d = ChargePolicy.decide(settings(), inputs(percent: 79, by: t0.addingTimeInterval(8 * hour),
                                                       manualDrain: true), &m)
        XCTAssertEqual(d.reason, .readyBy)
        XCTAssertTrue(d.endManualDrain)
        XCTAssertNil(d.dischargeTo)
    }

    func testDriftAndTheLimitAreOnlyReachedWhenItDoesNothing() {
        var s = settings()
        s.driftEnabled = true
        var m = ChargeMemory()
        // At the limit: drift's rule, as before.
        let drift = ChargePolicy.decide(s, inputs(percent: 80, by: t0.addingTimeInterval(8 * hour)), &m)
        XCTAssertEqual(drift.reason, .drift)
        // Below it, inside the window: Ready By holds first.
        let hold = ChargePolicy.decide(s, inputs(percent: 70, by: t0.addingTimeInterval(8 * hour)), &m)
        XCTAssertEqual(hold.reason, .readyBy)
    }

    func testUnpluggedFallsStraightBackToTheLimit() {
        var m = ChargeMemory()
        let d = ChargePolicy.decide(settings(), inputs(by: t0.addingTimeInterval(8 * hour), onAC: false), &m)
        XCTAssertEqual(d.reason, .limit)
        XCTAssertEqual(d.osLimit, 80)
        XCTAssertTrue(d.endFullCharge)
    }

    // ── A limit of 100, and off ─────────────────────────────────────────────

    func testALimitOfOneHundredHoldsAndThenChargesToOneHundred() {
        var m = ChargeMemory()
        let by = t0.addingTimeInterval(8 * hour)
        let d = ChargePolicy.decide(settings(limit: 100), inputs(percent: 60, by: by), &m)
        XCTAssertEqual(d.reason, .readyBy)
        XCTAssertEqual(d.osLimit, 60)
        XCTAssertEqual(d.readyBy?.raiseTo, 100)
        // At 100 there is nothing to hold below.
        m = ChargeMemory()
        XCTAssertEqual(ChargePolicy.decide(settings(limit: 100), inputs(percent: 100, by: by), &m).reason, .limit)
        // And started, it asks for 100.
        m = ChargeMemory()
        let started = ChargePolicy.decide(settings(limit: 100), inputs(percent: 60, at: t0, by: t0.addingTimeInterval(10 * minute)), &m)
        XCTAssertEqual(started.osLimit, 100)
    }

    func testOffDoesNothingWhateverTheMomentIs() {
        var m = ChargeMemory()
        let by = t0.addingTimeInterval(8 * hour)
        let off = ChargePolicy.decide(settings(readyBy: false), inputs(by: by), &m)
        XCTAssertEqual(off.reason, .limit)
        XCTAssertEqual(off.osLimit, 80)
        XCTAssertNil(m.readyBy)
        // On, with no moment to go by (no helper to wake the Mac): the same.
        let none = ChargePolicy.decide(settings(), inputs(by: nil), &m)
        XCTAssertEqual(none.reason, .limit)
        // A moment that is not in the future is not one.
        let past = ChargePolicy.decide(settings(), inputs(by: t0), &m)
        XCTAssertEqual(past.reason, .limit)
    }

    /// Switching it off in the middle of a charge it started leaves nothing behind.
    func testSwitchingOffForgetsWhatWasStarted() {
        var m = ChargeMemory()
        let by = t0.addingTimeInterval(20 * minute)
        _ = ChargePolicy.decide(settings(), inputs(by: by), &m)
        XCTAssertEqual(m.readyBy?.started, true)
        _ = ChargePolicy.decide(settings(readyBy: false), inputs(by: by), &m)
        XCTAssertNil(m.readyBy)
        let on = ChargePolicy.decide(settings(), inputs(at: t0.addingTimeInterval(60), by: t0.addingTimeInterval(8 * hour)), &m)
        XCTAssertTrue(on.readyBy?.isHolding == true, "switched on again, it begins from nothing")
    }

    func testTheOsLimitStaysInsideTwentyToOneHundred() {
        var m = ChargeMemory()
        let by = t0.addingTimeInterval(8 * hour)
        let d = ChargePolicy.decide(settings(limit: 20), inputs(percent: 10, by: by), &m)
        XCTAssertEqual(d.osLimit, 20)
    }
}

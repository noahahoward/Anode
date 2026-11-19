import XCTest
@testable import PowerKit

/// Ready By in the pure policy: charge to 20 under the limit and hold there until it has to charge to be at the limit
/// by a time of day. Every number the rule uses (the window, the floor, the margin, the taper) is pinned here from its own
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
        XCTAssertEqual(ChargePolicy.readyByWindow, 16 * 3600)
        XCTAssertEqual(ChargePolicy.readyByWindowWithAnOlderHelper, 12 * 3600)
        XCTAssertEqual(ChargePolicy.readyByFloor, 30)
        XCTAssertEqual(ChargePolicy.readyByBelowLimit, 20)
        XCTAssertEqual(ChargePolicy.readyByMargin, 15 * 60)
        XCTAssertEqual(ChargePolicy.chargeTaperAbove, 80)
        XCTAssertEqual(ChargePolicy.chargeTaperFactor, 0.4)
        XCTAssertEqual(ChargePolicy.chargeTopOffAbove, 95)
        XCTAssertEqual(ChargePolicy.chargeTopOffFactor, 0.5)
        XCTAssertEqual(ChargePolicy.defaultReadyByMinutes, 420)
        XCTAssertEqual(ChargePolicy.chargeRateRange, 0.1...3.0)
    }

    func testTimeToChargeCountsTheTaperAndTheLastFivePointsSlower() {
        // Straight: 26 points at 0.8 a minute.
        XCTAssertEqual(ChargePolicy.minutesToCharge(from: 54, to: 80, rate: 0.8), 32.5, accuracy: 1e-9)
        // Entirely above 80, nothing learned for it: 15 points at 0.4 of the rate (0.32), 5 at half of that (0.16).
        XCTAssertEqual(ChargePolicy.minutesToCharge(from: 80, to: 100, rate: 0.8), 78.125, accuracy: 1e-9)
        XCTAssertEqual(ChargePolicy.minutesToCharge(from: 90, to: 100, rate: 0.8), 46.875, accuracy: 1e-9)
        XCTAssertEqual(ChargePolicy.minutesToCharge(from: 80, to: 90, rate: 0.8), 31.25, accuracy: 1e-9)
        XCTAssertEqual(ChargePolicy.minutesToCharge(from: 96, to: 100, rate: 0.8), 25, accuracy: 1e-9)
        // Across 80: all three parts.
        XCTAssertEqual(ChargePolicy.minutesToCharge(from: 54, to: 100, rate: 0.8), 110.625, accuracy: 1e-9)
        // Nothing to charge.
        XCTAssertEqual(ChargePolicy.minutesToCharge(from: 80, to: 80, rate: 0.8), 0)
        XCTAssertEqual(ChargePolicy.minutesToCharge(from: 90, to: 60, rate: 0.8), 0)
    }

    /// The night this was written for: 75% to a limit of 100% on a charger learned at 1.58 a minute. Counting the taper
    /// at half the rate gave 28.5 minutes; the battery took 34.5 to reach 98% and longer for the rest, so the 15-minute
    /// margin was all that got it there. The estimate now is longer than what the climb to 98% took.
    func testTheEstimateForTheNightItWasShortIsNowLongEnough() {
        let now = ChargePolicy.minutesToCharge(from: 75, to: 100, rate: 1.58)
        let steady: Double = 5 / 1.58, taper: Double = 15 / 0.632, last: Double = 5 / 0.316
        XCTAssertEqual(now, steady + taper + last, accuracy: 1e-9)
        XCTAssertGreaterThan(now, 39.5, "the climb to 98% alone took 34.5 minutes")
        let before: Double = steady + 20 / 0.79
        XCTAssertEqual(before, 28.5, accuracy: 0.05, "what it was that night")
    }

    /// Once the rate above 80% has been learned it is what is counted, in place of the share of the steady rate.
    func testALearnedRateAboveEightyIsCounted() {
        XCTAssertEqual(ChargePolicy.minutesToCharge(from: 80, to: 95, rate: 1.58, rateAbove80: 0.5), 30, accuracy: 1e-9)
        XCTAssertEqual(ChargePolicy.minutesToCharge(from: 70, to: 100, rate: 1.0, rateAbove80: 0.5), 60, accuracy: 1e-9)
        // Below 80 it changes nothing.
        XCTAssertEqual(ChargePolicy.minutesToCharge(from: 54, to: 80, rate: 0.8, rateAbove80: 0.1), 32.5, accuracy: 1e-9)
    }

    /// A taper learned as faster than the charge below it is a misreading, and one that is not a rate is none: the
    /// charge would start late, which is the direction that must not happen.
    func testALearnedRateAboveEightyIsNeverBelievedFasterThanTheRateBelowIt() {
        XCTAssertEqual(ChargePolicy.minutesToCharge(from: 80, to: 95, rate: 1.0, rateAbove80: 2.5), 15, accuracy: 1e-9)
        let guessed = ChargePolicy.minutesToCharge(from: 80, to: 95, rate: 1.0)
        for bad in [Double.nan, .infinity, 0, -1] {
            XCTAssertEqual(ChargePolicy.minutesToCharge(from: 80, to: 95, rate: 1.0, rateAbove80: bad), guessed,
                           accuracy: 1e-9, "rate above 80 of \(bad)")
        }
        // And never slower than the slowest charger's taper.
        XCTAssertEqual(ChargePolicy.minutesToCharge(from: 80, to: 95, rate: 1.0, rateAbove80: 0.0001), 375, accuracy: 1e-9)
    }

    /// The policy passes what it is given: with a learned rate above 80 the start moment moves with it.
    func testTheStartMomentUsesTheLearnedRateAboveEighty() throws {
        let by = t0.addingTimeInterval(8 * hour)
        var m = ChargeMemory()
        var i = inputs(percent: 85, by: by)
        i.chargeRateAbove80 = 0.2
        let d = ChargePolicy.decide(settings(limit: 100), i, &m)
        let lead: TimeInterval = (50.0 + 50.0) * 60 + 900   // 10 points at 0.2 a minute, 5 at 0.1, and the margin
        XCTAssertEqual(by.timeIntervalSince(try XCTUnwrap(d.readyBy?.raiseAt)), lead, accuracy: 1e-6)
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

    func testChargesToTwentyUnderTheLimitAndHoldsThereInsideTheWindow() throws {
        let by = t0.addingTimeInterval(8 * hour)
        var m = ChargeMemory()
        let d = ChargePolicy.decide(settings(), inputs(by: by), &m)
        XCTAssertEqual(d.osLimit, 60, "54% is charged to 20 under the limit of 80, not held where it is")
        XCTAssertEqual(d.reason, .readyBy)
        XCTAssertNil(d.dischargeTo)
        XCTAssertEqual(d.readyBy, ReadyByState(by: by, raiseAt: by.addingTimeInterval(-lead(level: 60)), raiseTo: 80))
        // 20 points at 0.8 is 25 minutes, and the margin is 15 more.
        XCTAssertEqual(by.timeIntervalSince(try XCTUnwrap(d.readyBy?.raiseAt)), 25 * 60 + 15 * 60, accuracy: 1e-6)
        XCTAssertEqual(m.readyBy, ReadyByMemory(moment: by, level: 60, started: false))
    }

    func testTheWindowIsSixteenHoursAndIncludesItsEdge() {
        var m = ChargeMemory()
        let inside = ChargePolicy.decide(settings(), inputs(by: t0.addingTimeInterval(16 * hour)), &m)
        XCTAssertEqual(inside.reason, .readyBy, "exactly 16 hours away is inside the window")
        m = ChargeMemory()
        let justInside = ChargePolicy.decide(settings(), inputs(by: t0.addingTimeInterval(16 * hour - 1)), &m)
        XCTAssertEqual(justInside.reason, .readyBy)
        m = ChargeMemory()
        let outside = ChargePolicy.decide(settings(), inputs(by: t0.addingTimeInterval(16 * hour + 1)), &m)
        XCTAssertEqual(outside.reason, .limit, "a second further and the battery charges as usual")
        XCTAssertEqual(outside.osLimit, 80)
        XCTAssertNil(outside.readyBy)
        XCTAssertNil(m.readyBy)
    }

    /// The night it was changed for: a limit of 100 and Hold No Higher Than 80, plugged in at 25% while in use. It was
    /// held at 30% until the early morning, with the charger on the cable and the battery needed. It charges to 80 and
    /// holds there, as an iPhone does.
    func testItChargesToTwentyUnderTheLimitFirstThenHolds() {
        let by = t0.addingTimeInterval(8 * hour)
        for p in [20, 25, 30, 54, 79] {
            var m = ChargeMemory()
            let d = ChargePolicy.decide(lowering(to: 80), inputs(percent: p, by: by), &m)
            XCTAssertEqual(d.reason, .readyBy, "\(p)%")
            XCTAssertEqual(d.osLimit, 80, "\(p)% charges to 80, not beyond it")
            // The start moment is worked out from where it will hold: 80%.
            XCTAssertEqual(d.readyBy?.raiseAt, by.addingTimeInterval(-lead(level: 80, limit: 100)), "\(p)%")
            XCTAssertEqual(d.readyBy?.raiseTo, 100)
        }
        // Hold No Higher Than switched off: the same 20 under the limit.
        var m = ChargeMemory()
        XCTAssertEqual(ChargePolicy.decide(lowering(to: nil), inputs(percent: 25, by: by), &m).osLimit, 80)
        // A limit of 80: 60.
        m = ChargeMemory()
        XCTAssertEqual(ChargePolicy.decide(settings(), inputs(percent: 25, by: by), &m).osLimit, 60)
    }

    /// Hold No Higher Than below 20 under the limit is the level it charges to; above it, it is no reason to charge higher.
    func testALowerHoldNoHigherThanIsTheLevelItChargesTo() {
        let by = t0.addingTimeInterval(8 * hour)
        var m = ChargeMemory()
        XCTAssertEqual(ChargePolicy.decide(lowering(to: 50), inputs(percent: 25, by: by), &m).osLimit, 50)
        m = ChargeMemory()
        XCTAssertEqual(ChargePolicy.decide(lowering(to: 95), inputs(percent: 25, by: by), &m).osLimit, 80)
    }

    /// The level, worked out: 20 under the limit, or Hold No Higher Than when lower, and never under the floor (or the
    /// limit, when that is lower still).
    func testTheLevelItChargesTo() {
        XCTAssertEqual(ChargePolicy.readyByHoldLevel(limit: 100, holdAtMost: 80), 80)
        XCTAssertEqual(ChargePolicy.readyByHoldLevel(limit: 100, holdAtMost: nil), 80)
        XCTAssertEqual(ChargePolicy.readyByHoldLevel(limit: 100, holdAtMost: 95), 80)
        XCTAssertEqual(ChargePolicy.readyByHoldLevel(limit: 100, holdAtMost: 50), 50)
        XCTAssertEqual(ChargePolicy.readyByHoldLevel(limit: 80, holdAtMost: nil), 60)
        XCTAssertEqual(ChargePolicy.readyByHoldLevel(limit: 40, holdAtMost: nil), 30, "20 under 40 is below the floor")
        XCTAssertEqual(ChargePolicy.readyByHoldLevel(limit: 25, holdAtMost: nil), 25)
    }

    /// Under a low limit the floor still stands: 20 under a limit of 40 is 20, and it holds at 30. A battery above the
    /// level is held where it is.
    func testUnderALowLimitItNeverHoldsBelowTheFloor() {
        let by = t0.addingTimeInterval(8 * hour)
        var m = ChargeMemory()
        XCTAssertEqual(ChargePolicy.decide(settings(limit: 40), inputs(percent: 22, by: by), &m).osLimit, 30)
        m = ChargeMemory()
        XCTAssertEqual(ChargePolicy.decide(settings(limit: 40), inputs(percent: 31, by: by), &m).osLimit, 31)
    }

    /// A hold remembered lower (by a build that held wherever the battery was, or before the limit was raised) is
    /// charged up from, not kept.
    func testALevelRememberedLowerIsChargedUpFrom() {
        let by = t0.addingTimeInterval(8 * hour)
        var m = ChargeMemory()
        m.readyBy = ReadyByMemory(moment: by, level: 30, started: false)
        let d = ChargePolicy.decide(lowering(to: 80), inputs(percent: 30, by: by), &m)
        XCTAssertEqual(d.osLimit, 80)
        XCTAssertEqual(m.readyBy?.level, 80)
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
        let start = by.addingTimeInterval(-lead(level: 60))
        var m = ChargeMemory()
        let before = ChargePolicy.decide(settings(), inputs(at: start.addingTimeInterval(-1), by: by), &m)
        XCTAssertEqual(before.reason, .readyBy)
        XCTAssertEqual(before.osLimit, 60)
        XCTAssertTrue(before.readyBy?.isHolding == true)

        let at = ChargePolicy.decide(settings(), inputs(at: start, by: by), &m)
        XCTAssertEqual(at.reason, .readyBy)
        XCTAssertEqual(at.osLimit, 80, "at the start moment the limit is raised to the person's")
        XCTAssertEqual(at.readyBy, ReadyByState(by: by, raiseAt: nil, raiseTo: 80), "charging for Ready By")
        XCTAssertEqual(m.readyBy?.started, true)
    }

    /// The night the window was too short: 23:49, and a time of 13:00 the next day, 13 hours and 11 minutes off. With a
    /// window of 12 hours nothing was held and the battery charged straight to the limit.
    func testAnEveningPlugInForALateMorningTimeIsHeld() {
        var m = ChargeMemory()
        let by = t0.addingTimeInterval(13 * hour + 11 * minute)
        let d = ChargePolicy.decide(settings(limit: 100), inputs(percent: 74, by: by), &m)
        XCTAssertEqual(d.reason, .readyBy)
        XCTAssertEqual(d.osLimit, 80, "it charged on to 100 instead of holding")
    }

    /// The window is what the policy is given: with a helper that cannot plan a wake further off than 13 hours it is
    /// 12, and the same moment is then outside it.
    func testTheWindowIsTheOneItIsGiven() {
        var m = ChargeMemory()
        var i = inputs(by: t0.addingTimeInterval(13 * hour))
        XCTAssertEqual(i.readyByWindow, ChargePolicy.readyByWindow, "the default is the full window")
        XCTAssertEqual(ChargePolicy.decide(settings(), i, &m).reason, .readyBy)
        m = ChargeMemory()
        i.readyByWindow = ChargePolicy.readyByWindowWithAnOlderHelper
        XCTAssertEqual(ChargePolicy.decide(settings(), i, &m).reason, .limit)
        m = ChargeMemory()
        i.readyBy = t0.addingTimeInterval(12 * hour)
        XCTAssertEqual(ChargePolicy.decide(settings(), i, &m).reason, .readyBy, "12 hours exactly is inside the shorter one")
    }

    // ── Coming down before it holds ─────────────────────────────────────────

    private func lowering(to cap: Int? = 50, limit: Int = 100) -> ChargeSettingsSnapshot {
        var s = settings(limit: limit)
        s.readyByHoldAtMost = cap
        return s
    }

    /// The case it was built for: plugged in at 97% for a limit of 100%. It was held at 97% all night. The limit that
    /// is set is now 50, which is below the battery, so nothing charges it and macOS runs the Mac from it.
    func testABatteryAboveTheLevelIsHeldAtTheLevelAndNotWhereItIs() {
        var m = ChargeMemory()
        let by = t0.addingTimeInterval(14 * hour)
        let d = ChargePolicy.decide(lowering(), inputs(percent: 97, by: by), &m)
        XCTAssertEqual(d.reason, .readyBy)
        XCTAssertEqual(d.osLimit, 50, "it was held where it was")
        XCTAssertNil(d.dischargeTo, "the charger is not cut: macOS does not charge a battery above its limit")
        XCTAssertEqual(d.readyBy?.raiseTo, 100)
        XCTAssertEqual(m.readyBy?.level, 50)
        // Switched off, it is held where it is, as before.
        m = ChargeMemory()
        XCTAssertEqual(ChargePolicy.decide(lowering(to: nil), inputs(percent: 97, by: by), &m).osLimit, 97)
    }

    /// Below the level it comes down to, it is charged up to that level (it is under 20 below the limit); switched
    /// off, to 20 under the limit.
    func testABatteryBelowTheLevelIsChargedToIt() {
        for percent in [50, 49, 42, 31] {
            var m = ChargeMemory()
            let d = ChargePolicy.decide(lowering(), inputs(percent: percent, by: t0.addingTimeInterval(8 * hour)), &m)
            XCTAssertEqual(d.osLimit, 50, "\(percent)%")
            var plain = ChargeMemory()
            XCTAssertEqual(ChargePolicy.decide(lowering(to: nil), inputs(percent: percent, by: t0.addingTimeInterval(8 * hour)),
                                               &plain).osLimit, 80, "\(percent)%")
        }
    }

    /// The level is never above the person's limit: with a limit of 40 and a level of 50 the battery is held where it
    /// is, below the limit, and at or above the limit there is then nothing for Ready By to do.
    func testTheLevelIsNeverAboveTheLimit() {
        var m = ChargeMemory()
        let by = t0.addingTimeInterval(8 * hour)
        XCTAssertEqual(ChargePolicy.decide(lowering(to: 50, limit: 40), inputs(percent: 35, by: by), &m).osLimit, 35)
        m = ChargeMemory()
        XCTAssertEqual(ChargePolicy.decide(lowering(to: 50, limit: 40), inputs(percent: 60, by: by), &m).reason, .limit)
        m = ChargeMemory()
        XCTAssertEqual(ChargePolicy.decide(lowering(to: 95, limit: 80), inputs(percent: 90, by: by), &m).reason, .limit,
                       "a level above the limit is no level to come down to")
    }

    /// Above the limit too: a limit of 80 with the battery at 97 comes down to 50 and is charged back to 80 by the time.
    func testABatteryAboveTheLimitComesDownTooAndIsChargedBackToTheLimit() {
        var m = ChargeMemory()
        let by = t0.addingTimeInterval(10 * hour)
        let d = ChargePolicy.decide(lowering(to: 50, limit: 80), inputs(percent: 97, by: by), &m)
        XCTAssertEqual(d.reason, .readyBy)
        XCTAssertEqual(d.osLimit, 50)
        XCTAssertEqual(d.readyBy?.raiseTo, 80)
        // Outside the window it is the limit's own business, as before.
        m = ChargeMemory()
        let far = ChargePolicy.decide(lowering(to: 50, limit: 80), inputs(percent: 97, by: t0.addingTimeInterval(20 * hour)), &m)
        XCTAssertEqual(far.reason, .limit)
    }

    /// When the charge starts is counted from where the battery will be, not from the level it may never reach: a Mac
    /// that sleeps comes down slowly (1.5 points an hour is allowed for). 97% with ten hours to go is taken to be at
    /// 82% by then; from 50% the charge would start hours too early and the battery would sit full for them.
    func testTheStartIsCountedFromWhereTheBatteryWillHaveComeDownTo() throws {
        var m = ChargeMemory()
        let by = t0.addingTimeInterval(10 * hour)
        let d = ChargePolicy.decide(lowering(), inputs(percent: 97, by: by), &m)
        let lead = by.timeIntervalSince(try XCTUnwrap(d.readyBy?.raiseAt))
        let fromWhereItWillBe: TimeInterval = ChargePolicy.minutesToCharge(from: 82, to: 100, rate: 0.8) * 60 + 900
        XCTAssertEqual(lead, fromWhereItWillBe, accuracy: 1e-6)
        let fromTheLevel: TimeInterval = ChargePolicy.minutesToCharge(from: 50, to: 100, rate: 0.8) * 60 + 900
        XCTAssertLessThan(lead, fromTheLevel)
        XCTAssertEqual(ChargePolicy.readyByComingDownPerHour, 1.5)
        // Never from below the level, however long there is.
        m = ChargeMemory()
        let long = ChargePolicy.decide(lowering(to: 90), inputs(percent: 97, by: t0.addingTimeInterval(15 * hour)), &m)
        let longLead = t0.addingTimeInterval(15 * hour).timeIntervalSince(try XCTUnwrap(long.readyBy?.raiseAt))
        let fromNinety: TimeInterval = ChargePolicy.minutesToCharge(from: 90, to: 100, rate: 0.8) * 60 + 900
        XCTAssertEqual(longLead, fromNinety, accuracy: 1e-6)
    }

    /// As the battery really comes down (a Mac in use takes it down much faster than one asleep), each look counts
    /// again from where it is, so the start moves earlier and is never late; once it is at the level, the hold and its
    /// start are the ordinary ones.
    func testAsItComesDownTheStartMovesEarlierAndThenItHoldsAtTheLevel() throws {
        var m = ChargeMemory()
        let by = t0.addingTimeInterval(8 * hour)
        let first = ChargePolicy.decide(lowering(), inputs(percent: 97, by: by), &m)
        let later = ChargePolicy.decide(lowering(), inputs(percent: 70, at: t0.addingTimeInterval(2 * hour), by: by), &m)
        XCTAssertEqual(later.osLimit, 50)
        XCTAssertLessThan(try XCTUnwrap(later.readyBy?.raiseAt), try XCTUnwrap(first.readyBy?.raiseAt))
        let there = ChargePolicy.decide(lowering(), inputs(percent: 50, at: t0.addingTimeInterval(4 * hour), by: by), &m)
        XCTAssertEqual(there.osLimit, 50)
        let lead = by.timeIntervalSince(try XCTUnwrap(there.readyBy?.raiseAt))
        let fromFifty: TimeInterval = ChargePolicy.minutesToCharge(from: 50, to: 100, rate: 0.8) * 60 + 900
        XCTAssertEqual(lead, fromFifty, accuracy: 1e-6)
    }

    /// The level raised, or the option switched off, while the battery is still coming down: it is held at the new
    /// level, or where it is, and not at the level it was coming down to before.
    func testChangingTheLevelWhileItComesDownIsFollowed() {
        var m = ChargeMemory()
        let by = t0.addingTimeInterval(10 * hour)
        XCTAssertEqual(ChargePolicy.decide(lowering(to: 50), inputs(percent: 97, by: by), &m).osLimit, 50)
        XCTAssertEqual(ChargePolicy.decide(lowering(to: 70), inputs(percent: 96, by: by), &m).osLimit, 70)
        XCTAssertEqual(ChargePolicy.decide(lowering(to: nil), inputs(percent: 96, by: by), &m).osLimit, 96,
                       "switched off, it went on coming down")
        // Raised above where the battery is: charged to 20 under the limit, which is lower than the new level.
        var n = ChargeMemory()
        XCTAssertEqual(ChargePolicy.decide(lowering(to: 50), inputs(percent: 80, by: by), &n).osLimit, 50)
        XCTAssertEqual(ChargePolicy.decide(lowering(to: 90), inputs(percent: 66, by: by), &n).osLimit, 80)
        // A hold that overshoots by a point is still the hold it was.
        var o = ChargeMemory()
        XCTAssertEqual(ChargePolicy.decide(lowering(to: nil), inputs(percent: 84, by: by), &o).osLimit, 84)
        XCTAssertEqual(ChargePolicy.decide(lowering(to: nil), inputs(percent: 85, by: by), &o).osLimit, 84)
        XCTAssertEqual(ChargePolicy.decide(lowering(to: nil), inputs(percent: 83, by: by), &o).osLimit, 84)
    }

    /// When the time to charge comes while it is still above the level, it charges, as from any hold.
    func testTheChargeStartsOnTimeAlthoughItNeverGotDownToTheLevel() {
        var m = ChargeMemory()
        let by = t0.addingTimeInterval(10 * hour)
        _ = ChargePolicy.decide(lowering(), inputs(percent: 97, by: by), &m)
        let d = ChargePolicy.decide(lowering(), inputs(percent: 90, at: by.addingTimeInterval(-20 * minute), by: by), &m)
        XCTAssertEqual(d.reason, .readyBy)
        XCTAssertEqual(d.osLimit, 100, "the time to charge had come")
        XCTAssertEqual(m.readyBy?.started, true)
    }

    /// The numbers, named: the level is 80, where an iPhone holds, and it can be chosen between the floor and 95.
    func testTheLevelItComesDownToIsEightyUntilAnotherIsChosen() {
        XCTAssertEqual(ChargePolicy.defaultReadyByHoldAtMost, 80)
        XCTAssertEqual(ChargePolicy.readyByHoldAtMostRange, 30...95)
    }

    func testTheStartMomentCountsTheTaperAboveEighty() throws {
        // Limit 100, held at 80: 15 points at 0.32 a minute and the last 5 at 0.16.
        let by = t0.addingTimeInterval(8 * hour)
        var m = ChargeMemory()
        let d = ChargePolicy.decide(settings(limit: 100), inputs(by: by), &m)
        XCTAssertEqual(d.reason, .readyBy)
        XCTAssertEqual(d.osLimit, 80)
        XCTAssertEqual(d.readyBy?.raiseTo, 100)
        let lead: TimeInterval = (46.875 + 31.25) * 60 + 900
        XCTAssertEqual(by.timeIntervalSince(try XCTUnwrap(d.readyBy?.raiseAt)), lead, accuracy: 1e-6)
        // Without the taper the same climb would start 53 minutes later.
        XCTAssertLessThan(try XCTUnwrap(d.readyBy?.raiseAt),
                          by.addingTimeInterval(-((20) / 0.8 * 60 + 15 * 60)))
    }

    func testALimitAboveEightyHoldsAndChargesWithTheTaperFromAHigherLevel() throws {
        let by = t0.addingTimeInterval(6 * hour)
        var m = ChargeMemory()
        let d = ChargePolicy.decide(settings(limit: 100), inputs(percent: 85, by: by), &m)
        XCTAssertEqual(d.osLimit, 85)
        // 15 points entirely above 80: 10 at 0.32 a minute and the last 5 at 0.16.
        let lead: TimeInterval = (31.25 + 31.25) * 60 + 900
        XCTAssertEqual(by.timeIntervalSince(try XCTUnwrap(d.readyBy?.raiseAt)), lead, accuracy: 1e-6)
    }

    func testNotEnoughTimeChargesAtOnce() {
        // 20 minutes away, and it needs 40.
        let by = t0.addingTimeInterval(20 * minute)
        var m = ChargeMemory()
        let d = ChargePolicy.decide(settings(), inputs(by: by), &m)
        XCTAssertEqual(d.reason, .readyBy)
        XCTAssertEqual(d.osLimit, 80, "no time to wait: charge now")
        XCTAssertNil(d.readyBy?.raiseAt)
        XCTAssertEqual(m.readyBy?.started, true)
    }

    /// Below the level with no time to spare: no stop at 60, straight to the limit.
    func testNoTimeEvenForTheLevelChargesStraightThrough() {
        let by = t0.addingTimeInterval(30 * minute)
        var m = ChargeMemory()
        let d = ChargePolicy.decide(settings(), inputs(percent: 22, by: by), &m)
        XCTAssertEqual(d.osLimit, 80)
        XCTAssertNil(d.readyBy?.raiseAt)
    }

    // ── Started stays started ───────────────────────────────────────────────

    func testOnceStartedItStaysStartedWhateverTheEstimateDoes() {
        let by = t0.addingTimeInterval(8 * hour)
        let start = by.addingTimeInterval(-lead(level: 60))
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
        let first = ChargePolicy.decide(settings(), inputs(percent: 64, by: by), &m)
        // A reading a point up, then a point down: the limit stays where it was put, and so does the moment. Held at
        // 64, a battery that reads 63 is charged back to 64 by macOS, not held at 63.
        let up = ChargePolicy.decide(settings(), inputs(percent: 65, at: t0.addingTimeInterval(30), by: by), &m)
        XCTAssertEqual(up.osLimit, 64)
        XCTAssertEqual(up.readyBy?.raiseAt, first.readyBy?.raiseAt)
        let down = ChargePolicy.decide(settings(), inputs(percent: 63, at: t0.addingTimeInterval(60), by: by), &m)
        XCTAssertEqual(down.osLimit, 64, "held at 64, so macOS charges it back up")
        XCTAssertEqual(down.readyBy?.raiseAt, first.readyBy?.raiseAt)
    }

    /// The level is remembered, and the limit can be lowered under it: with 70 remembered and the limit moved to 58, the
    /// battery was held at 70 and charged past the limit. The hold never sits above the limit that is in force.
    func testARememberedLevelAboveALoweredLimitIsHeldAtTheLimit() {
        let by = t0.addingTimeInterval(8 * hour)
        var m = ChargeMemory()
        XCTAssertEqual(ChargePolicy.decide(settings(), inputs(percent: 70, by: by), &m).osLimit, 70)
        XCTAssertEqual(m.readyBy?.level, 70)
        // The person lowers the limit to 58 with the battery at 55, below it.
        let lowered = ChargePolicy.decide(settings(limit: 58), inputs(percent: 55, at: t0.addingTimeInterval(60), by: by), &m)
        XCTAssertEqual(lowered.reason, .readyBy)
        XCTAssertEqual(lowered.osLimit, 58, "held above the limit, so the battery charges past it")
        XCTAssertEqual(m.readyBy?.level, 58, "the memory still holds the old level")
        XCTAssertEqual(lowered.readyBy?.raiseTo, 58)
        XCTAssertEqual(lowered.readyBy?.raiseAt, by.addingTimeInterval(-lead(level: 58, limit: 58)))
        // Raised again, the remembered 70 is not found again: it followed the limit down, and the level for a limit of
        // 80 is 60.
        let raised = ChargePolicy.decide(settings(limit: 80), inputs(percent: 55, at: t0.addingTimeInterval(120), by: by), &m)
        XCTAssertEqual(raised.osLimit, 60)
    }

    /// A hold is a hold only while Ready By is what decides: if something else decided in between, the next hold
    /// starts from where the battery is then.
    func testAnotherRuleDecidingEndsTheHoldAndTheNextOneStartsFromTheChargeThen() {
        let by = t0.addingTimeInterval(8 * hour)
        var m = ChargeMemory()
        XCTAssertEqual(ChargePolicy.decide(settings(), inputs(percent: 64, by: by), &m).osLimit, 64)
        let full = ChargePolicy.decide(settings(), inputs(percent: 70, at: t0.addingTimeInterval(60), by: by,
                                                          fullCharge: true), &m)
        XCTAssertEqual(full.reason, .fullCharge)
        XCTAssertNil(m.readyBy, "a hold the person overrode is over")
        let after = ChargePolicy.decide(settings(), inputs(percent: 70, at: t0.addingTimeInterval(120), by: by), &m)
        XCTAssertEqual(after.osLimit, 70)
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
        XCTAssertEqual(hold.osLimit, 60)
        // After the start, the battery has to charge while the Mac sleeps.
        m = ChargeMemory()
        let charge = ChargePolicy.decide(s, inputs(by: t0.addingTimeInterval(20 * minute), sleeping: true), &m)
        XCTAssertEqual(charge.reason, .readyBy)
        XCTAssertEqual(charge.osLimit, 80, "Hold Level During Sleep must not stop the charge Ready By started")
        // Outside the window it does nothing, and the sleep hold is the sleep hold.
        m = ChargeMemory()
        let outside = ChargePolicy.decide(s, inputs(by: t0.addingTimeInterval(17 * hour), sleeping: true), &m)
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
        XCTAssertEqual(d.osLimit, 80)
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

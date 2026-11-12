import XCTest
@testable import PowerKit

/// One pure function decides what macOS's charge limit should be and whether to discharge, for every
/// charge feature at once. These pin the priority order and every number in it; the controller
/// that carries the decision out is tested separately and never re-decides.
final class ChargePolicyTests: XCTestCase {

    // ── Fixtures ────────────────────────────────────────────────────────────

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Limit 80, gap 5, 35 °C, every feature off, 50 % on the adapter at 25 °C.
    private func base() -> (ChargeSettingsSnapshot, ChargeInputs) {
        (ChargeSettingsSnapshot(limit: 80,
                                sailingEnabled: false, sailingGap: 5,
                                heatProtectionEnabled: false, maxTemperatureC: 35,
                                stopWhenSleeping: false, automaticDischarge: false),
         ChargeInputs(percent: 50, onAC: true, temperatureC: 25,
                      sleeping: false, topUp: false, manualDischarge: false, now: t0))
    }

    // ── The limit ───────────────────────────────────────────────────────────

    func testPlainLimit() {
        let (s, i) = base()
        var m = ChargeMemory()
        let d = ChargePolicy.decide(s, i, &m)
        XCTAssertEqual(d.osLimit, 80)
        XCTAssertEqual(d.reason, .limit)
        XCTAssertNil(d.dischargeTo)
        XCTAssertFalse(d.endTopUp)
        XCTAssertFalse(d.endManualDischarge)
    }

    func testLowLimitAllowed() {
        var (s, i) = base()
        s.limit = 30
        i.percent = 50
        var m = ChargeMemory()
        XCTAssertEqual(ChargePolicy.decide(s, i, &m).osLimit, 30)
    }

    func testOSLimitIsAlwaysInsideTwentyToOneHundred() {
        var (s, i) = base()
        var m = ChargeMemory()
        s.limit = 10
        XCTAssertEqual(ChargePolicy.decide(s, i, &m).osLimit, 20)
        s.limit = 120
        XCTAssertEqual(ChargePolicy.decide(s, i, &m).osLimit, 100)
        // Unplugged takes the early exit; it clamps too.
        s.limit = 10
        i.onAC = false
        XCTAssertEqual(ChargePolicy.decide(s, i, &m).osLimit, 20)
    }

    // ── Unplug and Top Up ───────────────────────────────────────────────────

    func testTopUpWinsUntilUnplug() {
        var (s, i) = base()
        var m = ChargeMemory()
        i.topUp = true
        let on = ChargePolicy.decide(s, i, &m)
        XCTAssertEqual(on.osLimit, 100)
        XCTAssertEqual(on.reason, .topUp)
        XCTAssertFalse(on.endTopUp)

        i.onAC = false
        let off = ChargePolicy.decide(s, i, &m)
        XCTAssertTrue(off.endTopUp)
        XCTAssertEqual(off.osLimit, 80, "unplugged falls straight back to the user's limit")
    }

    func testUnplugEndsDischargeAndTopUp() {
        var (s, i) = base()
        var m = ChargeMemory()
        i.manualDischarge = true
        i.topUp = true
        i.onAC = false
        i.percent = 90
        s.automaticDischarge = true
        let d = ChargePolicy.decide(s, i, &m)
        XCTAssertTrue(d.endTopUp)
        XCTAssertTrue(d.endManualDischarge)
        XCTAssertNil(d.dischargeTo)
        XCTAssertEqual(d.reason, .limit)
    }

    func testTopUpBeatsHeatSleepAndDischarge() {
        var (s, i) = base()
        var m = ChargeMemory()
        s.heatProtectionEnabled = true
        s.stopWhenSleeping = true
        i.temperatureC = 40
        i.sleeping = true
        i.manualDischarge = true
        i.topUp = true
        let d = ChargePolicy.decide(s, i, &m)
        XCTAssertEqual(d.osLimit, 100)
        XCTAssertEqual(d.reason, .topUp)
        XCTAssertNil(d.dischargeTo)
    }

    // ── Heat Protection ─────────────────────────────────────────────────────

    func testHeatPausesAtCurrentAndHasFiveMinuteHysteresis() {
        var (s, i) = base()
        var m = ChargeMemory()
        s.heatProtectionEnabled = true
        i.percent = 60

        i.temperatureC = 36
        let hot = ChargePolicy.decide(s, i, &m)
        XCTAssertEqual(hot.osLimit, 60)
        XCTAssertEqual(hot.reason, .heat)
        XCTAssertNil(hot.dischargeTo)

        // Cool again: the five minutes run from the first cool reading.
        i.temperatureC = 34
        i.now = t0.addingTimeInterval(60)
        XCTAssertEqual(ChargePolicy.decide(s, i, &m).reason, .heat, "the first cool reading only starts the clock")
        i.now = t0.addingTimeInterval(60 + 299)
        XCTAssertEqual(ChargePolicy.decide(s, i, &m).reason, .heat)
        i.now = t0.addingTimeInterval(60 + 300)
        let resumed = ChargePolicy.decide(s, i, &m)
        XCTAssertEqual(resumed.reason, .limit)
        XCTAssertEqual(resumed.osLimit, 80)
        XCTAssertNil(m.heatPausedSince)
        XCTAssertNil(m.coolSince)
    }

    /// A pause never raises the limit: hot at 91% with a limit of 80 holds 80, not 91 (which macOS would round up to
    /// 95 without the helper, and the Mac would charge while hot).
    func testHeatNeverRaisesTheLimit() {
        var (s, i) = base()
        var m = ChargeMemory()
        s.heatProtectionEnabled = true
        s.limit = 80
        i.percent = 91
        i.temperatureC = 40
        let d = ChargePolicy.decide(s, i, &m)
        XCTAssertEqual(d.reason, .heat)
        XCTAssertEqual(d.osLimit, 80, "Heat Protection raised the limit above the person's own")
        XCTAssertNil(d.dischargeTo)
    }

    func testHeatPauseNeverBelowTwenty() {
        var (s, i) = base()
        var m = ChargeMemory()
        s.heatProtectionEnabled = true
        i.percent = 12
        i.temperatureC = 40
        XCTAssertEqual(ChargePolicy.decide(s, i, &m).osLimit, 20)
    }

    func testReheatingRestartsTheCoolClock() {
        var (s, i) = base()
        var m = ChargeMemory()
        s.heatProtectionEnabled = true
        i.percent = 60

        i.temperatureC = 36
        _ = ChargePolicy.decide(s, i, &m)
        i.temperatureC = 34
        i.now = t0.addingTimeInterval(60)
        _ = ChargePolicy.decide(s, i, &m)                       // clock starts at +60
        i.temperatureC = 36
        i.now = t0.addingTimeInterval(120)
        _ = ChargePolicy.decide(s, i, &m)                       // hot again: clock cleared
        XCTAssertNil(m.coolSince)
        i.temperatureC = 34
        i.now = t0.addingTimeInterval(180)
        _ = ChargePolicy.decide(s, i, &m)                       // clock restarts at +180

        i.now = t0.addingTimeInterval(180 + 299)
        XCTAssertEqual(ChargePolicy.decide(s, i, &m).reason, .heat, "300 s from the first cool reading would already have passed")
        i.now = t0.addingTimeInterval(180 + 300)
        XCTAssertEqual(ChargePolicy.decide(s, i, &m).reason, .limit)
    }

    func testHeatPausesAtExactlyTheMaximum() {
        var (s, i) = base()
        var m = ChargeMemory()
        s.heatProtectionEnabled = true
        i.temperatureC = 35
        XCTAssertEqual(ChargePolicy.decide(s, i, &m).reason, .heat)
    }

    func testHotButHeatProtectionOffChargesNormally() {
        var (s, i) = base()
        var m = ChargeMemory()
        i.temperatureC = 45
        let d = ChargePolicy.decide(s, i, &m)
        XCTAssertEqual(d.reason, .limit)
        XCTAssertNil(m.heatPausedSince)
    }

    func testNoTemperatureReadingNeverStartsAPause() {
        var (s, i) = base()
        var m = ChargeMemory()
        s.heatProtectionEnabled = true
        i.temperatureC = nil
        XCTAssertEqual(ChargePolicy.decide(s, i, &m).reason, .limit)
    }

    func testNoTemperatureReadingHoldsAPauseWithoutMovingItsClock() {
        var (s, i) = base()
        var m = ChargeMemory()
        s.heatProtectionEnabled = true
        i.temperatureC = 40
        _ = ChargePolicy.decide(s, i, &m)
        i.temperatureC = nil
        i.now = t0.addingTimeInterval(1_000)
        XCTAssertEqual(ChargePolicy.decide(s, i, &m).reason, .heat, "a missing reading cannot confirm the pack cooled")
        XCTAssertNil(m.coolSince)
    }

    func testTurningHeatProtectionOffForgetsAPause() {
        var (s, i) = base()
        var m = ChargeMemory()
        s.heatProtectionEnabled = true
        i.temperatureC = 40
        _ = ChargePolicy.decide(s, i, &m)
        XCTAssertNotNil(m.heatPausedSince)

        s.heatProtectionEnabled = false
        _ = ChargePolicy.decide(s, i, &m)
        XCTAssertNil(m.heatPausedSince)

        // Back on and cool: no leftover pause from before.
        s.heatProtectionEnabled = true
        i.temperatureC = 25
        i.now = t0.addingTimeInterval(3_600)
        XCTAssertEqual(ChargePolicy.decide(s, i, &m).reason, .limit)
    }

    func testHeatBeatsDischarge() {
        var (s, i) = base()
        var m = ChargeMemory()
        s.heatProtectionEnabled = true
        i.temperatureC = 40
        i.percent = 77
        i.manualDischarge = true
        let d = ChargePolicy.decide(s, i, &m)
        XCTAssertEqual(d.reason, .heat)
        XCTAssertNil(d.dischargeTo)
        XCTAssertEqual(d.osLimit, 77)
        XCTAssertFalse(d.endManualDischarge, "the discharge is waiting, not finished")
    }

    // ── Stop Charging when Sleeping ─────────────────────────────────────────

    func testSleepingHoldsAtCurrent() {
        var (s, i) = base()
        var m = ChargeMemory()
        s.stopWhenSleeping = true
        i.sleeping = true
        let d = ChargePolicy.decide(s, i, &m)
        XCTAssertEqual(d.osLimit, 50)
        XCTAssertEqual(d.reason, .sleeping)
    }

    func testSleepingAboveTheLimitHoldsAtTheLimit() {
        var (s, i) = base()
        var m = ChargeMemory()
        s.stopWhenSleeping = true
        i.sleeping = true
        i.percent = 90
        XCTAssertEqual(ChargePolicy.decide(s, i, &m).osLimit, 80)
    }

    func testSleepingNeverHoldsBelowTwenty() {
        var (s, i) = base()
        var m = ChargeMemory()
        s.stopWhenSleeping = true
        i.sleeping = true
        i.percent = 8
        XCTAssertEqual(ChargePolicy.decide(s, i, &m).osLimit, 20)
    }

    func testWakeReturnsToUserLimit() {
        var (s, i) = base()
        var m = ChargeMemory()
        s.stopWhenSleeping = true
        i.sleeping = true
        XCTAssertEqual(ChargePolicy.decide(s, i, &m).reason, .sleeping)

        i.sleeping = false
        let d = ChargePolicy.decide(s, i, &m)
        XCTAssertEqual(d.osLimit, 80)
        XCTAssertEqual(d.reason, .limit)
    }

    func testSleepingWithTheFeatureOffChargesNormally() {
        var (s, i) = base()
        var m = ChargeMemory()
        s.stopWhenSleeping = false
        i.sleeping = true
        let d = ChargePolicy.decide(s, i, &m)
        XCTAssertEqual(d.osLimit, 80)
        XCTAssertEqual(d.reason, .limit)
    }

    func testSleepingBeatsDischarge() {
        var (s, i) = base()
        var m = ChargeMemory()
        s.stopWhenSleeping = true
        i.sleeping = true
        i.percent = 77
        s.limit = 40
        i.manualDischarge = true
        let d = ChargePolicy.decide(s, i, &m)
        XCTAssertEqual(d.reason, .sleeping)
        XCTAssertNil(d.dischargeTo)
    }

    // ── Discharge ───────────────────────────────────────────────────────────

    func testManualDischargeToLimit() {
        var (s, i) = base()
        var m = ChargeMemory()
        s.limit = 40
        i.percent = 77
        i.manualDischarge = true
        let d = ChargePolicy.decide(s, i, &m)
        XCTAssertEqual(d.dischargeTo, 40)
        XCTAssertEqual(d.osLimit, 40)
        XCTAssertEqual(d.reason, .discharging)
        XCTAssertFalse(d.endManualDischarge)
    }

    func testDischargeNotStartedAtOrBelowTarget() {
        var (s, i) = base()
        var m = ChargeMemory()
        s.limit = 40
        i.manualDischarge = true

        i.percent = 40
        let atTarget = ChargePolicy.decide(s, i, &m)
        XCTAssertNil(atTarget.dischargeTo)
        XCTAssertTrue(atTarget.endManualDischarge)
        XCTAssertEqual(atTarget.reason, .discharged)
        XCTAssertEqual(atTarget.osLimit, 40)

        i.percent = 33
        let below = ChargePolicy.decide(s, i, &m)
        XCTAssertNil(below.dischargeTo)
        XCTAssertTrue(below.endManualDischarge)
    }

    func testDischargeFloorIsTen() {
        // With the limit's 20 % minimum the floor cannot be seen through `decide`, so the rule
        // is pinned where it lives.
        XCTAssertEqual(ChargePolicy.dischargeTarget(limit: 20), 20)
        XCTAssertEqual(ChargePolicy.dischargeTarget(limit: 5), 10)
        XCTAssertEqual(ChargePolicy.dischargeTarget(limit: 80), 80)

        var (s, i) = base()
        var m = ChargeMemory()
        s.limit = 20
        i.percent = 77
        i.manualDischarge = true
        let d = ChargePolicy.decide(s, i, &m)
        XCTAssertEqual(d.dischargeTo, 20)
        XCTAssertGreaterThanOrEqual(d.dischargeTo ?? 0, 10)
    }

    func testAutomaticDischargeOnlyAboveLimit() {
        var (s, i) = base()
        var m = ChargeMemory()
        s.automaticDischarge = true

        i.percent = 85
        let above = ChargePolicy.decide(s, i, &m)
        XCTAssertEqual(above.dischargeTo, 80)
        XCTAssertEqual(above.reason, .discharging)

        i.percent = 80
        let at = ChargePolicy.decide(s, i, &m)
        XCTAssertNil(at.dischargeTo)
        XCTAssertEqual(at.reason, .limit)
        XCTAssertFalse(at.endManualDischarge, "automatic discharge has no pending request to end")
    }

    func testAutomaticDischargeOffNeverDischarges() {
        var (s, i) = base()
        var m = ChargeMemory()
        s.automaticDischarge = false
        i.percent = 95
        let d = ChargePolicy.decide(s, i, &m)
        XCTAssertNil(d.dischargeTo)
        XCTAssertEqual(d.osLimit, 80)
    }

    // ── Sailing ─────────────────────────────────────────────────────────────

    func testSailingBand() {
        var (s, i) = base()
        var m = ChargeMemory()
        s.sailingEnabled = true

        i.percent = 80
        let top = ChargePolicy.decide(s, i, &m)
        XCTAssertTrue(m.sailingPhase)
        XCTAssertEqual(top.osLimit, 80)
        XCTAssertEqual(top.reason, .sailing)

        i.percent = 77
        let inside = ChargePolicy.decide(s, i, &m)
        XCTAssertEqual(inside.osLimit, 77, "resting: the limit follows the charge down so it does not recharge")
        XCTAssertEqual(inside.reason, .sailing)

        i.percent = 75
        let bottom = ChargePolicy.decide(s, i, &m)
        XCTAssertFalse(m.sailingPhase)
        XCTAssertEqual(bottom.osLimit, 80)
        XCTAssertEqual(bottom.reason, .limit)
    }

    func testSailingDoesNotRestBeforeReachingTheLimit() {
        var (s, i) = base()
        var m = ChargeMemory()
        s.sailingEnabled = true
        i.percent = 78
        let d = ChargePolicy.decide(s, i, &m)
        XCTAssertFalse(m.sailingPhase)
        XCTAssertEqual(d.osLimit, 80)
        XCTAssertEqual(d.reason, .limit)
    }

    func testSailingOffForgetsItsPhase() {
        var (s, i) = base()
        var m = ChargeMemory()
        s.sailingEnabled = true
        i.percent = 80
        _ = ChargePolicy.decide(s, i, &m)
        XCTAssertTrue(m.sailingPhase)

        s.sailingEnabled = false
        i.percent = 77
        let d = ChargePolicy.decide(s, i, &m)
        XCTAssertFalse(m.sailingPhase)
        XCTAssertEqual(d.osLimit, 80)
        XCTAssertEqual(d.reason, .limit)
    }

    func testSailingGapIsClampedToThirty() {
        var (s, i) = base()
        var m = ChargeMemory()
        s.sailingEnabled = true
        s.sailingGap = 99                                       // clamps to 30: the band is 50…80
        i.percent = 80
        _ = ChargePolicy.decide(s, i, &m)
        i.percent = 55
        XCTAssertEqual(ChargePolicy.decide(s, i, &m).reason, .sailing)
        i.percent = 50
        XCTAssertEqual(ChargePolicy.decide(s, i, &m).reason, .limit)
    }
}

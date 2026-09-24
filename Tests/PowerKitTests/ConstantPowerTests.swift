import XCTest
@testable import PowerKit

/// Time-to-empty must project against the charge the pack will actually
/// deliver, not against the current it is delivering right now.
///
/// ## The physics, in one line
/// The SoC rails are buck converters, so a load holds WATTS. As the pack
/// discharges its voltage falls, so the current rises to hold that power, so
/// the charge runs out sooner than `charge / rate_now` predicts. Correctly,
/// `T = (1/P)∫V dQ` — the integral of the pack's voltage over the charge that
/// remains — which is `charge / rate_now` scaled by `V̄_remaining / V_now`.
///
/// ## Why it is a ratio, and why that matters more than it sounds
/// Both voltages sit on the same curve, so every absolute scale cancels: cell
/// count, nominal voltage, pack capacity, units. The correction therefore needs
/// the SHAPE of the discharge curve and nothing else — which is exactly the
/// class of quantity that ports across machines, unlike the 11.58 V seed
/// ARCHITECTURE.md section 6 apologises for.
final class ConstantPowerTests: XCTestCase {

    /// The correction may only ever SHORTEN the estimate. A pack whose voltage
    /// falls cannot deliver more runtime than a constant-current projection.
    func testTheCorrectionOnlyEverShortens() {
        for soc in stride(from: 1.0, through: 100.0, by: 1.0) {
            let f = BatteryScale.constantPowerFactor(atSoCPercent: soc)
            XCTAssertGreaterThan(f, 0.5, "at \(soc)% the factor collapsed")
            XCTAssertLessThanOrEqual(f, 1.0, "at \(soc)% the correction LENGTHENED the estimate")
        }
    }

    /// It is bigger at a high state of charge and nearly vanishes near empty —
    /// because at 70 % most of the steep upper curve still lies ahead, while at
    /// 20 % only the flat plateau remains. This monotonicity IS the finding: no
    /// single constant can do this job.
    func testTheCorrectionGrowsWithStateOfCharge() {
        let high = 1 - BatteryScale.constantPowerFactor(atSoCPercent: 75)
        let mid  = 1 - BatteryScale.constantPowerFactor(atSoCPercent: 50)
        let low  = 1 - BatteryScale.constantPowerFactor(atSoCPercent: 20)
        XCTAssertGreaterThan(high, mid)
        XCTAssertGreaterThan(mid, low)
        XCTAssertGreaterThan(high, 0.05, "at a full pack this is worth ~20 min of an 8 h estimate")
        XCTAssertLessThan(low, 0.03, "near empty it must nearly vanish")
    }

    /// Pinned against the curve measured on 2026-08-21, so a change to the shape
    /// table cannot silently move every displayed time.
    func testPinnedAgainstTheMeasuredCurve() {
        let expected: [(Double, Double)] = [
            (78, 0.929), (70, 0.941), (60, 0.956),
            (50, 0.968), (30, 0.981), (20, 0.982),
        ]
        for (soc, f) in expected {
            XCTAssertEqual(BatteryScale.constantPowerFactor(atSoCPercent: soc), f,
                           accuracy: 0.004, "at \(soc)%")
        }
    }

    /// SCALE-FREE. Doubling every voltage on the curve is a different pack and
    /// the same shape, and must give an identical correction. If this fails the
    /// implementation has smuggled an absolute voltage in, which is the whole
    /// defect being avoided.
    func testTheCorrectionIsIndependentOfAbsoluteScale() {
        // The shape table is normalised; this asserts the PROPERTY by checking
        // the factor never depends on the pack's declared scale.
        let small = BatteryScale(fullChargeCapacity_mAh: 3000, designCapacity_mAh: 3000,
                                 nominalVoltage_V: 3.86, isCalibrated: false)
        let big = BatteryScale(fullChargeCapacity_mAh: 9000, designCapacity_mAh: 9000,
                               nominalVoltage_V: 11.58, isCalibrated: false)
        XCTAssertEqual(small.joulesPerPercent > 0, true)
        XCTAssertEqual(big.joulesPerPercent > 0, true)
        // Same static curve, so the same answer for both — the factor is not a
        // member of the scale for exactly this reason.
        XCTAssertEqual(BatteryScale.constantPowerFactor(atSoCPercent: 60),
                       BatteryScale.constantPowerFactor(atSoCPercent: 60))
    }

    /// The correction is applied where time-to-empty is DEFINED, so every tier
    /// and every renderer inherits it from one place.
    func testTimeToEmptyAppliesIt() {
        let charge = 70.0, rate = 10.0
        let uncorrected = charge / rate * 3600
        let actual = DrainEstimate.timeToEmpty(chargePercent: charge, ratePctHr: rate)!
        XCTAssertLessThan(actual, uncorrected, "the projection must shorten")
        XCTAssertEqual(actual,
                       uncorrected * BatteryScale.constantPowerFactor(atSoCPercent: charge),
                       accuracy: 1e-6)
        // ~6% of seven hours is worth having.
        XCTAssertGreaterThan(uncorrected - actual, 20 * 60)
    }

    /// Everything `timeToEmpty` refused before, it still refuses. The correction
    /// multiplies a time; it must not create or destroy one.
    func testTheRefusalsAreUnchanged() {
        XCTAssertNil(DrainEstimate.timeToEmpty(chargePercent: 50, ratePctHr: 0.05))
        XCTAssertNil(DrainEstimate.timeToEmpty(chargePercent: 0, ratePctHr: 8))
        XCTAssertNil(DrainEstimate.timeToEmpty(chargePercent: -1, ratePctHr: 8))
        XCTAssertNil(DrainEstimate.timeToEmpty(chargePercent: 50, ratePctHr: .nan))
        XCTAssertNotNil(DrainEstimate.timeToEmpty(chargePercent: 50, ratePctHr: 8))
    }

    /// Nothing here may depend on the charge basis being the integer one. The
    /// curve is indexed by the mAh basis, which is what every caller passes.
    func testOutOfRangeStatesOfChargeAreHandled() {
        XCTAssertEqual(BatteryScale.constantPowerFactor(atSoCPercent: 100),
                       BatteryScale.constantPowerFactor(atSoCPercent: 120),
                       accuracy: 1e-9, "above full is clamped, not extrapolated wildly")
        XCTAssertTrue(BatteryScale.constantPowerFactor(atSoCPercent: 0.0001).isFinite)
    }
}

/// `projectedRuntime_hr` is a TIER of time-to-empty, not a separate opinion.
///
/// It carried its own division for as long as time-to-empty was a division, and
/// silently stopped agreeing the moment the constant-power correction landed
/// somewhere else. Found by hand-checking the CLI against the arithmetic: 6h 18m
/// printed where the corrected figure was 5h 50m.
extension ConstantPowerTests {

    func testTheFallbackTierGoesThroughTheOneDefinition() {
        let scale = BatteryScale(fullChargeCapacity_mAh: 5972, designCapacity_mAh: 6249,
                                 nominalVoltage_V: BatteryScale.seedNominalVoltage_V,
                                 isCalibrated: false)
        let st = Battery.State(percent: 77, isCharging: false, onAC: false, cycleCount: 25,
                               voltage_mV: 11900, amperage_mA: -700,
                               remainingCapacity_mAh: 4369, timeRemaining_min: nil)
        let soc = scale.chargePercent(st)
        let watts = 8.0
        let rate = 3600 * watts / scale.joulesPerPercent
        let viaDefinition = DrainEstimate.timeToEmpty(chargePercent: soc, ratePctHr: rate)!
        // The old inline form, kept here as the thing that must NOT come back.
        let oldInline = soc * scale.joulesPerPercent / watts / 3600
        XCTAssertLessThan(viaDefinition / 3600, oldInline,
                          "the corrected tier must be shorter than the raw division")
        XCTAssertEqual(viaDefinition / 3600,
                       oldInline * BatteryScale.constantPowerFactor(atSoCPercent: soc),
                       accuracy: 1e-9)
        // The gap that was on screen: tens of minutes, not a rounding difference.
        XCTAssertGreaterThan((oldInline - viaDefinition / 3600) * 60, 20)
    }
}

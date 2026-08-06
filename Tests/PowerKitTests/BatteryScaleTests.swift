import XCTest
@testable import PowerKit

/// The battery scale is the denominator under EVERY displayed number (%/hr, "10 hr
/// power", minutes of runtime). If it drifts by a unit slip the whole ledger lies
/// in unison, so its arithmetic is pinned to this machine's measured pack here.
final class BatteryScaleTests: XCTestCase {

    /// Mac17,9 measured facts: 6197 mAh full-charge, 11.58 V 3S nominal seed.
    /// 6.197 Ah × 11.58 V × 3600 s = 258,340.5 J → ~2588 J per 1% (documented
    /// figure; computed 2583.4), and 1 W of steady draw ≈ 1.39 %/hr.
    func testRealMachineJoulesPerPercent() {
        let s = makeMachineScale()
        XCTAssertEqual(s.energyFull_J, 6.197 * 11.58 * 3600, accuracy: 1e-6)
        XCTAssertEqual(s.joulesPerPercent, s.energyFull_J / 100, accuracy: 1e-9)
        XCTAssertEqual(s.joulesPerPercent, 2588, accuracy: 10)
        XCTAssertEqual(s.energyFull_Wh, s.energyFull_J / 3600, accuracy: 1e-9)
        XCTAssertEqual(s.energyFull_Wh, 71.76, accuracy: 0.01)
    }

    /// 1 W sustained costs 3600 J per hour → 3600 / joulesPerPercent %/hr.
    /// This is the constant every widget multiplies by; 1.39 is the anchor.
    func testOneWattIsAboutOnePointThreeNinePercentPerHour() {
        let s = makeMachineScale()
        XCTAssertEqual(3600 / s.joulesPerPercent, 1.39, accuracy: 0.005)
    }

    func testHealthIsFullOverDesign() {
        let s = makeMachineScale(design: 6251)
        XCTAssertEqual(s.health, 6197.0 / 6251.0, accuracy: 1e-12)
        // An aged-but-healthy pack: below 1.0, nowhere near 0.
        XCTAssertGreaterThan(s.health, 0.9)
        XCTAssertLessThanOrEqual(s.health, 1.01)
    }

    /// A dead or unreadable gauge must degrade to zeros — never NaN, never a trap.
    /// Note the parse path (`Battery.scale()`) refuses non-positive capacities with
    /// its `> 0` guard, so a zero scale can only be hand-built; if one ever is, the
    /// derived quantities must still be finite.
    func testZeroFullCapacityStaysFiniteAndZero() {
        let s = BatteryScale(fullChargeCapacity_mAh: 0,
                             designCapacity_mAh: 6251,
                             nominalVoltage_V: 11.58,
                             isCalibrated: false)
        XCTAssertEqual(s.energyFull_J, 0)
        XCTAssertEqual(s.energyFull_Wh, 0)
        XCTAssertEqual(s.joulesPerPercent, 0)
        XCTAssertEqual(s.health, 0)
        XCTAssertFalse(s.energyFull_J.isNaN)
        XCTAssertFalse(s.joulesPerPercent.isNaN)
        XCTAssertFalse(s.health.isNaN)
    }

    /// Zero DESIGN capacity: Swift Double division does not trap, so `health` comes
    /// out +infinity — a loud, orderable sentinel, and crucially not NaN (NaN poisons
    /// every comparison downstream). Cannot arise from live parsing (design is
    /// guarded `> 0` in Battery.scale()).
    func testZeroDesignCapacityDoesNotProduceNaN() {
        let s = BatteryScale(fullChargeCapacity_mAh: 6197,
                             designCapacity_mAh: 0,
                             nominalVoltage_V: 11.58,
                             isCalibrated: false)
        XCTAssertFalse(s.health.isNaN)
        XCTAssertFalse(s.energyFull_J.isNaN)
        XCTAssertFalse(s.joulesPerPercent.isNaN)
    }

    /// Downstream contract: a zero joulesPerPercent flowing into the drain conversion
    /// must not crash and must not emit NaN. (It emits +inf %/hr for a positive
    /// consumer — an honest "cannot scale" sentinel, unlike NaN which un-sorts tables.)
    func testDrainConversionWithZeroScaleDoesNotCrashOrNaN() {
        let dead = BatteryScale(fullChargeCapacity_mAh: 0,
                                designCapacity_mAh: 0,
                                nominalVoltage_V: 11.58,
                                isCalibrated: false)
        let a = makeSweep(at: 0, [makeProcess(pid: 1, nJ: 1_000_000_000)])
        let b = makeSweep(at: 2, [makeProcess(pid: 1, nJ: 3_000_000_000)])
        let drains = DrainCalculator.between(a, b, scale: dead)
        XCTAssertEqual(drains.count, 1)
        XCTAssertEqual(drains[0].joules, 2.0)
        XCTAssertEqual(drains[0].watts, 1.0)
        XCTAssertFalse(drains[0].percentPerHour.isNaN)
    }
}

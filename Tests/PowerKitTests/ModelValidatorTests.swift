import XCTest
@testable import PowerKit

/// Runs the ground-truth harness's own synthetic self-test.
///
/// `ModelValidator` is the only thing in the project that can answer "is the
/// power model still right" after macOS moves a key underneath us — it integrates
/// the displayed watts against real pack discharge. A harness that has itself
/// drifted would answer that question wrongly and confidently, so its arithmetic
/// is proved on synthetic data with a known answer before it is trusted with the
/// real one. `selfTest()` shipped with that proof and nothing ran it; this is the
/// wire.
final class ModelValidatorTests: XCTestCase {

    /// The whole self-test, with its own report as the failure message so a break
    /// says which of the four checks failed and with what numbers.
    func testSelfTestPasses() {
        let (passed, report) = ModelValidator.selfTest()
        XCTAssertTrue(passed, "ModelValidator.selfTest() failed:\n\(report)")
        XCTAssertFalse(report.contains("[FAIL]"),
                       "report contradicts the passed flag:\n\(report)")
    }

    /// `selfTest()` seeds `ok = true` and only ever ANDs into it, so a case that
    /// stops running takes its failure mode with it and the suite still goes
    /// green. Pin the four checks by name so silent removal is a test failure.
    func testSelfTestStillRunsEveryCheck() {
        let (_, report) = ModelValidator.selfTest()
        for name in ["exact ratio", "clean ledger", "broken ledger detected",
                     "AC aborts the run", "no premature verdict"] {
            XCTAssertTrue(report.contains(name),
                          "self-test no longer covers '\(name)':\n\(report)")
        }
        XCTAssertEqual(report.components(separatedBy: "[PASS]").count - 1, 5,
                       "expected 5 passing checks:\n\(report)")
    }

    /// The harness must refuse a verdict it cannot support. Nothing recorded means
    /// no window, and no window means nil — never a default ratio of 1.0.
    func testEmptyValidatorProducesNoVerdict() {
        let v = ModelValidator(scale: BatteryScale(fullChargeCapacity_mAh: 6197,
                                                   designCapacity_mAh: 6249,
                                                   nominalVoltage_V: 11.58,
                                                   isCalibrated: false))
        XCTAssertNil(v.result(minimumSeconds: 0))
        XCTAssertNil(v.runningRatio())
        XCTAssertEqual(v.sampleCount, 0)
        XCTAssertEqual(v.status, "no on-battery samples yet")
    }
}

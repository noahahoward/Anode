import XCTest
@testable import PowerKit

/// The additive-vs-multiplicative distinction cost real debugging time, so it is
/// pinned here in both directions:
///   BaselineCalibrator — PARTIAL signal (CPU+GPU) + roughly-constant rest → ADD.
///   GainCalibrator     — WHOLE-SYSTEM signal (SMC PSTR) with systematic gain → MULTIPLY.
/// Getting them crossed amplifies noise (measured: k≈3.6 turned ±3 W into ±11 W).
final class CalibratorTests: XCTestCase {

    // ── BaselineCalibrator: additive ────────────────────────────────────────

    func testBaselineIsSlowMinusFast() {
        let c = BaselineCalibrator(alpha: 0.35)
        XCTAssertNil(c.baseline)
        XCTAssertFalse(c.isCalibrated)
        c.observe(fast: 9, slow: 34)
        XCTAssertEqual(c.baseline!, 25, accuracy: 1e-12)
        XCTAssertTrue(c.isCalibrated)
    }

    func testEstimateAddsBaselineToFast() {
        let c = BaselineCalibrator(alpha: 0.35)
        c.observe(fast: 9, slow: 34)                 // baseline = 25 W
        XCTAssertEqual(c.estimate(fast: 9)!, 34, accuracy: 1e-12)
        XCTAssertEqual(c.estimate(fast: 0)!, 25, accuracy: 1e-12)
    }

    /// THE regression. With a 25 W baseline, fast jitter of ±3 W must come out as
    /// ±3 W of output jitter — passed through 1:1, never scaled. The multiplicative
    /// version (total = k × fast, k = 34/9 ≈ 3.78) scaled that same jitter to ±11 W
    /// and made the display flap between 29 and 60 W.
    func testJitterIsPassedThroughNotAmplified() {
        let c = BaselineCalibrator(alpha: 0.35)
        c.observe(fast: 9, slow: 34)                 // baseline = 25 W

        let lo = c.estimate(fast: 6)!                // −3 W of jitter
        let hi = c.estimate(fast: 12)!               // +3 W of jitter
        XCTAssertEqual(hi - lo, 6, accuracy: 1e-12,
                       "additive fusion must pass jitter through exactly 1:1")

        // What the buggy multiplicative model does with identical inputs:
        let k = 34.0 / 9.0
        XCTAssertGreaterThan(k * 12 - k * 6, 20, "the bug this test exists to prevent")
    }

    /// fast > slow means a double-counted rail or a gauge window that missed a
    /// burst. The baseline is then unknown-but-small — clamp to 0, never negative
    /// (a negative baseline would subtract phantom watts from every estimate).
    func testBaselineClampsAtZeroWhenFastExceedsSlow() {
        let c = BaselineCalibrator(alpha: 0.35)
        c.observe(fast: 40, slow: 30)
        XCTAssertEqual(c.baseline!, 0)
        XCTAssertEqual(c.estimate(fast: 40)!, 40)
        XCTAssertGreaterThanOrEqual(c.estimate(fast: 0)!, 0)
    }

    func testBaselineEMASmoothsSuccessiveObservations() {
        let c = BaselineCalibrator(alpha: 0.35)
        c.observe(fast: 10, slow: 35)                // seeds at 25
        c.observe(fast: 10, slow: 45)                // new evidence: 35
        // 25 + 0.35 × (35 − 25) = 28.5 — moves, but does not slam.
        XCTAssertEqual(c.baseline!, 28.5, accuracy: 1e-9)
    }

    func testBaselineIgnoresBogusSlowSignal() {
        let c = BaselineCalibrator(alpha: 0.35)
        c.observe(fast: 5, slow: 0)                  // gauge glitch: no reading
        XCTAssertNil(c.baseline)
        XCTAssertNil(c.estimate(fast: 5), "no gauge window yet → honest nil, not a guess")
    }

    // ── GainCalibrator: multiplicative ──────────────────────────────────────

    /// The measured numbers this class exists for: PSTR reads 5.280 W against a
    /// gauge mean of 4.681 W (ratio 1.128). Corrected PSTR must land on the gauge.
    func testGainMatchesMeasuredPSTRRatio() {
        let g = GainCalibrator(alpha: 0.3, range: 0.5...2.0)
        g.observe(fast: 5.280, slow: 4.681)
        XCTAssertEqual(g.value!, 4.681 / 5.280, accuracy: 1e-12)
        XCTAssertEqual(g.corrected(5.280), 4.681, accuracy: 1e-9)
    }

    /// A whole-system gain far outside ~1 means one signal is garbage; trusting it
    /// would let a single bad window poison every subsequent reading.
    func testGainClampsToAllowedRange() {
        let high = GainCalibrator(alpha: 0.3, range: 0.5...2.0)
        high.observe(fast: 1, slow: 10)              // raw ratio 10 → clamp 2.0
        XCTAssertEqual(high.value!, 2.0)

        let low = GainCalibrator(alpha: 0.3, range: 0.5...2.0)
        low.observe(fast: 10, slow: 1)               // raw ratio 0.1 → clamp 0.5
        XCTAssertEqual(low.value!, 0.5)

        let tight = GainCalibrator(alpha: 0.3, range: 0.9...1.1)
        tight.observe(fast: 1, slow: 5)
        XCTAssertEqual(tight.value!, 1.1)
    }

    func testGainEMASmoothsSuccessiveObservations() {
        let g = GainCalibrator(alpha: 0.3, range: 0.5...2.0)
        g.observe(fast: 10, slow: 5)                 // seeds at 0.5
        g.observe(fast: 10, slow: 20)                // new evidence: 2.0
        // 0.5 + 0.3 × (2.0 − 0.5) = 0.95
        XCTAssertEqual(g.value!, 0.95, accuracy: 1e-9)
        XCTAssertEqual(g.corrected(10), 9.5, accuracy: 1e-8)
    }

    /// Before the first gauge window the gain is 1.0 — the raw whole-system reading
    /// is used rather than nothing, because PSTR is already close.
    func testCorrectedIsIdentityBeforeCalibration() {
        let g = GainCalibrator(alpha: 0.3, range: 0.5...2.0)
        XCTAssertFalse(g.isCalibrated)
        XCTAssertNil(g.value)
        XCTAssertEqual(g.corrected(7.5), 7.5)
    }

    /// Near-zero signals make the ratio meaningless (0/0 territory) — skip them.
    func testGainIgnoresNearZeroSignals() {
        let g = GainCalibrator(alpha: 0.3, range: 0.5...2.0)
        g.observe(fast: 0.04, slow: 10)
        g.observe(fast: 10, slow: 0.04)
        XCTAssertNil(g.value)
        XCTAssertFalse(g.isCalibrated)
    }
}

import XCTest
@testable import PowerKit

/// The smoother's contract: steady by default, but a REAL load change moves the
/// display within ~2 ticks. "Real" = two consecutive samples outside the band.
/// Parameters are passed explicitly so retuning the production defaults cannot
/// silently invalidate these numbers.
final class AdaptiveSmootherTests: XCTestCase {

    private func makeSmoother() -> AdaptiveSmoother {
        AdaptiveSmoother(alpha: 0.25, snapAlpha: 0.8, relBand: 0.35, absBand: 0.4, confirmations: 2)
    }

    func testFirstSampleSeedsTheEstimate() {
        let s = makeSmoother()
        XCTAssertNil(s.value)
        XCTAssertEqual(s.update(5.0), 5.0)
        XCTAssertEqual(s.value, 5.0)
        XCTAssertFalse(s.didJump, "seeding is not a regime change")
    }

    func testSteadyInputConverges() {
        let s = makeSmoother()
        s.update(8.0)                      // seed off-target; |10-8| = 2 < band(8) = 2.8
        var jumped = false
        for _ in 0..<40 {
            s.update(10.0)
            jumped = jumped || s.didJump
        }
        // Geometric convergence: 2 × 0.75^40 ≈ 2e-5.
        XCTAssertEqual(s.value!, 10.0, accuracy: 1e-3)
        XCTAssertFalse(jumped, "in-band drift must never register as a jump")
    }

    /// One wild sample is telemetry noise (the 60 s gauge window problem), not a
    /// regime change. It may nudge the estimate slightly; it must not move it.
    func testSingleOutlierDoesNotJump() {
        let s = makeSmoother()
        s.update(10.0)
        s.update(30.0)                     // outlier: band = max(0.35×10, 0.4) = 3.5
        XCTAssertFalse(s.didJump)
        // Unconfirmed outlier nudges by alpha/4: 10 + 0.0625 × 20 = 11.25 exactly.
        XCTAssertEqual(s.value!, 11.25, accuracy: 1e-12)

        s.update(10.0)                     // back in band: the streak is broken
        XCTAssertFalse(s.didJump)
        XCTAssertLessThan(s.value!, 11.25, "must relax back toward the level")
    }

    /// Two consecutive outliers ARE the regime change, and the snap must target the
    /// MEAN of the confirming samples — snapping to the last one would let a single
    /// extreme value set the new level, re-importing the noise we filtered.
    func testTwoConsecutiveOutliersJumpToMeanOfConfirmingSamples() {
        let s = makeSmoother()
        s.update(10.0)
        s.update(30.0)
        XCTAssertFalse(s.didJump)
        s.update(34.0)
        XCTAssertTrue(s.didJump, "second consecutive outlier confirms the change")

        // e was 11.25 after the nudge; target = mean(30, 34) = 32:
        //   11.25 + 0.8 × (32 − 11.25) = 27.85
        XCTAssertEqual(s.value!, 27.85, accuracy: 1e-9)
        // Had it targeted the LAST sample (34): 11.25 + 0.8 × 22.75 = 29.45.
        XCTAssertGreaterThan(abs(s.value! - 29.45), 1.0,
                             "jump targeted the last sample, not the mean")
    }

    func testDidJumpIsSetOnlyOnTheConfirmingUpdate() {
        let s = makeSmoother()
        s.update(10.0)
        s.update(30.0)
        s.update(34.0)
        XCTAssertTrue(s.didJump)
        s.update(28.0)                     // in band around 27.85 — ordinary smoothing
        XCTAssertFalse(s.didJump, "didJump must clear on the next non-jump update")
    }

    /// Outlier, in-band, outlier: the confirmation streak must reset in between —
    /// two NON-consecutive outliers are two separate noise events, not a change.
    func testInBandSampleBreaksTheOutlierStreak() {
        let s = makeSmoother()
        s.update(10.0)
        var jumped = false
        for x in [30.0, 10.0, 30.0, 10.0] {
            s.update(x)
            jumped = jumped || s.didJump
        }
        XCTAssertFalse(jumped, "alternating noise must never confirm a jump")
        XCTAssertLessThan(s.value!, 15.0, "estimate must stay near the true level")
    }

    func testResetForgetsEverything() {
        let s = makeSmoother()
        s.update(10.0)
        s.update(30.0)                     // leaves a pending outlier
        s.reset()
        XCTAssertNil(s.value)
        XCTAssertFalse(s.didJump)
        s.update(7.0)                      // seeds fresh
        XCTAssertEqual(s.value, 7.0)
        s.update(50.0)                     // only ONE outlier since reset
        XCTAssertFalse(s.didJump, "pending outliers must not survive reset")
    }
}

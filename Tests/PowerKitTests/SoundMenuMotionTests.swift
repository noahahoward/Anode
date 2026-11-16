import XCTest
@testable import PowerKit

/// The glide is the one measured from macOS's panel: heights 159 → 253 pt, fractions of the way at these times after it began.
final class SoundMenuMotionTests: XCTestCase {
    func testItStartsAtZeroAndEndsAtOne() {
        XCTAssertEqual(SoundMenuMotion.progress(at: 0), 0)
        XCTAssertEqual(SoundMenuMotion.progress(at: -1), 0)
        XCTAssertEqual(SoundMenuMotion.progress(at: SoundMenuMotion.settleSeconds), 1)
        XCTAssertEqual(SoundMenuMotion.progress(at: 5), 1)
    }

    func testItNeverGoesBackwardsOrPastTheEnd() {
        var last = 0.0
        for i in 0...400 {
            let p = SoundMenuMotion.progress(at: Double(i) / 400 * SoundMenuMotion.settleSeconds)
            XCTAssertGreaterThanOrEqual(p, last - 1e-12)
            XCTAssertLessThanOrEqual(p, 1)
            last = p
        }
    }

    func testItFollowsWhatWasMeasuredOnMacOS() {
        // (seconds since it began, fraction of the height covered), from the 120 fps recording of macOS's panel.
        let measured: [(Double, Double)] = [(0.075, 0.19), (0.125, 0.40), (0.167, 0.56), (0.217, 0.71), (0.275, 0.84), (0.333, 0.91), (0.392, 0.96)]
        for (t, p) in measured {
            XCTAssertEqual(SoundMenuMotion.progress(at: t), p, accuracy: 0.09, "at \(t) s")
        }
    }
}

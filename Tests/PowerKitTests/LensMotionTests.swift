import XCTest
@testable import PowerKit

/// How macOS 27's slider knob becomes a glass lens when held, and turns back when let go. Measured on macOS's own panel at 120 fps:
/// the white knob is swapped at once for a lens its own size (19.5 x 16 pt), which grows to 26 x 20.5 in about 0.17 s without
/// overshooting, its top-left corner fixed; on release the lens stays full size, then the white knob fades in inside it while its
/// ring fades out and its outline closes in on the knob (about 50 ms).
final class LensMotionTests: XCTestCase {

    func testTheLensStartsAtThreeQuartersOfItsHeldSize() {
        XCTAssertEqual(LensMotion.pressScale(at: 0), 0.75, accuracy: 0.001)
        XCTAssertEqual(LensMotion.heldSize.width * LensMotion.pressScale(at: 0), 19.5, accuracy: 0.01)
    }

    func testItGrowsMonotonicallyWithoutOvershooting() {
        var last: CGFloat = 0
        for ms in stride(from: 0, through: 400, by: 4) {
            let s = LensMotion.pressScale(at: Double(ms) / 1000)
            XCTAssertGreaterThanOrEqual(s, last); XCTAssertLessThanOrEqual(s, 1.0000001)
            last = s
        }
        XCTAssertEqual(last, 1, accuracy: 0.001)
    }

    func testItHasMostlyGrownByWhatWasMeasured() {
        // 0.46 of the way at 50 ms, 0.69 at 75 ms, 0.85 at 100 ms, and done by about 150 ms (measured width fractions).
        func fraction(_ t: Double) -> Double { Double((LensMotion.pressScale(at: t) - 0.75) / 0.25) }
        XCTAssertEqual(fraction(0.05), 0.46, accuracy: 0.08)
        XCTAssertEqual(fraction(0.075), 0.69, accuracy: 0.08)
        XCTAssertEqual(fraction(0.10), 0.85, accuracy: 0.08)
        XCTAssertGreaterThan(fraction(0.15), 0.97)
    }

    func testTheHeldLensIsBiggerThanTheKnobByTheMeasuredAmounts() {
        XCTAssertEqual(LensMotion.heldSize.width, 26, accuracy: 0.01)
        XCTAssertEqual(LensMotion.heldSize.height, 20.5, accuracy: 0.01)
    }

    func testReleaseTurnsTheLensIntoTheKnobInAboutFiftyMilliseconds() {
        let start = LensMotion.release(at: 0)
        XCTAssertEqual(start.scale, 1, accuracy: 0.001); XCTAssertEqual(start.ring, 1, accuracy: 0.001); XCTAssertEqual(start.knob, 0, accuracy: 0.001)
        let end = LensMotion.release(at: LensMotion.releaseDuration)
        XCTAssertEqual(end.scale, 0.77, accuracy: 0.01); XCTAssertEqual(end.ring, 0, accuracy: 0.001); XCTAssertEqual(end.knob, 1, accuracy: 0.001)
        XCTAssertEqual(LensMotion.releaseDuration, 0.05, accuracy: 0.01)
        XCTAssertTrue(LensMotion.isReleased(at: LensMotion.releaseDuration + 0.001))
        XCTAssertFalse(LensMotion.isReleased(at: 0.02))
    }
}

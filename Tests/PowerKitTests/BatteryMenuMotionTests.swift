import XCTest
@testable import PowerKit

/// How the Battery menu moves, as measured on macOS's own panel at 120 frames a second (macOS 27).
final class BatteryMenuMotionTests: XCTestCase {

    // A chosen Energy Mode's badge turns from grey to blue (and the old one back) on a critically damped spring, omega 15: measured on the
    // badge's brightness, 28% a 66 ms in, 59% at 133 ms, 83% at 216 ms, 95% at 316 ms.
    func testTheBadgeColourFollowsTheMeasuredCurve() {
        XCTAssertEqual(BatteryMenuMotion.badge(at: 0), 0)
        XCTAssertEqual(BatteryMenuMotion.badge(at: 0.066), 0.28, accuracy: 0.03)
        XCTAssertEqual(BatteryMenuMotion.badge(at: 0.133), 0.59, accuracy: 0.03)
        XCTAssertEqual(BatteryMenuMotion.badge(at: 0.216), 0.83, accuracy: 0.03)
        XCTAssertEqual(BatteryMenuMotion.badge(at: 0.316), 0.95, accuracy: 0.03)
        XCTAssertEqual(BatteryMenuMotion.badge(at: BatteryMenuMotion.badgeSettleSeconds + 0.01), 1)
    }

    func testTheBadgeNeverOvershoots() {
        var last = 0.0
        for i in 0...100 {
            let p = BatteryMenuMotion.badge(at: Double(i) * 0.006)
            XCTAssertGreaterThanOrEqual(p, last); XCTAssertLessThanOrEqual(p, 1)
            last = p
        }
    }

    // The panel fades out after a click on the icon, in a straight line over about 240 ms (measured: 96% left 241 ms before the end,
    // 50% at 125 ms, 20% at 50 ms).
    func testTheFadeOutIsAStraightLineOverTwoHundredFortyMilliseconds() {
        XCTAssertEqual(BatteryMenuMotion.fadeOutAlpha(at: 0), 1)
        XCTAssertEqual(BatteryMenuMotion.fadeOutAlpha(at: 0.115), 0.52, accuracy: 0.05)
        XCTAssertEqual(BatteryMenuMotion.fadeOutAlpha(at: 0.19), 0.2, accuracy: 0.05)
        XCTAssertEqual(BatteryMenuMotion.fadeOutAlpha(at: BatteryMenuMotion.fadeOutSeconds), 0)
        XCTAssertEqual(BatteryMenuMotion.fadeOutAlpha(at: 1), 0)
    }
}

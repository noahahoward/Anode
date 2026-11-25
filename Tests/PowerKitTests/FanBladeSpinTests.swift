import AppKit
import XCTest
@testable import AnodeApp
@testable import PowerKit

/// The fan blades' spin rate and step, and the rule for when the canvas animates them. No timers are waited on: the decision
/// is read from `isAnimatingFans`, and a frame is driven by calling `stepFanAnimation` directly.
final class FanBladeSpinTests: XCTestCase {

    // MARK: - turnsPerSecond

    func testAParkedFanDoesNotTurn() {
        XCTAssertEqual(FanBladeSpin.turnsPerSecond(rpm: 0, minRPM: 2000, maxRPM: 6000), 0)
        XCTAssertEqual(FanBladeSpin.turnsPerSecond(rpm: -5, minRPM: 2000, maxRPM: 6000), 0)
    }

    func testTheMinimumSpeedTurnsAtPoint35() {
        XCTAssertEqual(FanBladeSpin.turnsPerSecond(rpm: 2000, minRPM: 2000, maxRPM: 6000), 0.35, accuracy: 1e-12)
        // Below the minimum (a fan spinning up) is clamped to the same.
        XCTAssertEqual(FanBladeSpin.turnsPerSecond(rpm: 800, minRPM: 2000, maxRPM: 6000), 0.35, accuracy: 1e-12)
    }

    func testTheMaximumSpeedTurns1Point6() {
        XCTAssertEqual(FanBladeSpin.turnsPerSecond(rpm: 6000, minRPM: 2000, maxRPM: 6000), 1.6, accuracy: 1e-12)
    }

    func testAboveTheMaximumIsClamped() {
        XCTAssertEqual(FanBladeSpin.turnsPerSecond(rpm: 9000, minRPM: 2000, maxRPM: 6000), 1.6, accuracy: 1e-12)
    }

    func testTheMiddleOfTheRangeIsHalfwayBetween() {
        XCTAssertEqual(FanBladeSpin.turnsPerSecond(rpm: 4000, minRPM: 2000, maxRPM: 6000), 0.975, accuracy: 1e-12)
    }

    func testAnEmptyOrReversedRangeCountsAsTheMinimum() {
        // Chosen: the fraction is 0, so a spinning fan with no usable range turns at 0.35 (not 0: it is spinning).
        XCTAssertEqual(FanBladeSpin.turnsPerSecond(rpm: 3000, minRPM: 3000, maxRPM: 3000), 0.35, accuracy: 1e-12)
        XCTAssertEqual(FanBladeSpin.turnsPerSecond(rpm: 3000, minRPM: 6000, maxRPM: 2000), 0.35, accuracy: 1e-12)
        XCTAssertEqual(FanBladeSpin.turnsPerSecond(rpm: 0, minRPM: 3000, maxRPM: 3000), 0)
    }

    func testNotANumberGivesZero() {
        XCTAssertEqual(FanBladeSpin.turnsPerSecond(rpm: .nan, minRPM: 2000, maxRPM: 6000), 0)
        XCTAssertEqual(FanBladeSpin.turnsPerSecond(rpm: 3000, minRPM: .nan, maxRPM: 6000), 0)
        XCTAssertEqual(FanBladeSpin.turnsPerSecond(rpm: 3000, minRPM: 2000, maxRPM: .infinity), 0)
        XCTAssertEqual(FanBladeSpin.turnsPerSecond(rpm: .infinity, minRPM: 2000, maxRPM: 6000), 0)
    }

    // MARK: - advance

    func testAdvanceWrapsIntoOneTurn() {
        // 6.2 + 2π * 1 * 0.5 = 9.3416..., minus 2π = 3.0584...
        let a = FanBladeSpin.advance(angle: 6.2, turnsPerSecond: 1, dt: 0.5)
        XCTAssertGreaterThanOrEqual(a, 0)
        XCTAssertLessThan(a, 2 * Double.pi)
        XCTAssertEqual(a, 6.2 + Double.pi - 2 * Double.pi, accuracy: 1e-9)
    }

    func testAdvanceIsMonotonicForSmallSteps() {
        var angle = 0.0
        for _ in 0..<20 {
            let next = FanBladeSpin.advance(angle: angle, turnsPerSecond: 1, dt: 0.05)
            XCTAssertGreaterThan(next, angle, "a 50 ms step at 1 turn/s is under a quarter turn, so it cannot wrap here")
            angle = next
            if angle > 5 { break }
        }
        XCTAssertGreaterThan(angle, 0)
    }

    func testAdvanceIgnoresNegativeOrBrokenTime() {
        XCTAssertEqual(FanBladeSpin.advance(angle: 1.5, turnsPerSecond: 1, dt: -0.5), 1.5, accuracy: 1e-12)
        XCTAssertEqual(FanBladeSpin.advance(angle: 1.5, turnsPerSecond: 1, dt: .nan), 1.5, accuracy: 1e-12)
        XCTAssertEqual(FanBladeSpin.advance(angle: 1.5, turnsPerSecond: 1, dt: .infinity), 1.5, accuracy: 1e-12)
        XCTAssertEqual(FanBladeSpin.advance(angle: 1.5, turnsPerSecond: 0, dt: 1), 1.5, accuracy: 1e-12)
    }

    func testAdvanceKeepsTheAngleInRangeWhateverItIsGiven() {
        XCTAssertEqual(FanBladeSpin.advance(angle: .nan, turnsPerSecond: 1, dt: 0), 0)
        let wrapped = FanBladeSpin.advance(angle: -1, turnsPerSecond: 0, dt: 0)
        XCTAssertEqual(wrapped, 2 * Double.pi - 1, accuracy: 1e-12)
        let big = FanBladeSpin.advance(angle: 1000, turnsPerSecond: 1.6, dt: 3)
        XCTAssertGreaterThanOrEqual(big, 0)
        XCTAssertLessThan(big, 2 * Double.pi)
    }

    // MARK: - The canvas's decision

    private func fan(_ index: Int, rpm: Double) -> FanReading {
        FanReading(index: index, rpm: rpm, minRPM: 2000, maxRPM: 6000, targetRPM: nil, isManual: false)
    }

    private func canvas(fans: [FanReading]) -> HardwareCanvasView {
        let v = HardwareCanvasView(layout: HardwareLayout.layout(for: .generic))
        v.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
        v.readings = HardwareReadings(fans: fans)
        return v
    }

    func testItDoesNotAnimateWhileTheWindowCannotBeSeen() {
        let v = canvas(fans: [fan(0, rpm: 3000)])
        v.isDrawableNow = { false }
        v.refreshFanAnimation()
        XCTAssertFalse(v.isAnimatingFans)
    }

    func testItDoesNotAnimateWhenEveryFanIsParked() {
        let v = canvas(fans: [fan(0, rpm: 0), fan(1, rpm: 0)])
        v.isDrawableNow = { true }
        v.refreshFanAnimation()
        XCTAssertFalse(v.isAnimatingFans)
    }

    func testItDoesNotAnimateWithoutReadings() {
        let v = canvas(fans: [])
        v.readings = nil
        v.refreshFanAnimation()
        XCTAssertFalse(v.isAnimatingFans)
    }

    func testItAnimatesASpinningFanAndStopsWhenTheWindowCannotBeSeen() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Reduce Motion is on here, so nothing animates")
        let v = canvas(fans: [fan(0, rpm: 3000)])
        v.isDrawableNow = { true }
        v.refreshFanAnimation()
        XCTAssertTrue(v.isAnimatingFans)

        v.isDrawableNow = { false }
        v.refreshFanAnimation()
        XCTAssertFalse(v.isAnimatingFans, "the decision follows the window at once")
    }

    func testAFrameTurnsTheBladesOnlyOnceFiftyMillisecondsHaveGathered() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Reduce Motion is on here, so nothing animates")
        let v = canvas(fans: [fan(0, rpm: 6000), fan(1, rpm: 0)])
        v.isDrawableNow = { true }

        XCTAssertTrue(v.stepFanAnimation(0.02))
        XCTAssertTrue(v.fanAngles.allSatisfy { $0 == 0 }, "20 ms is under the step")
        XCTAssertTrue(v.stepFanAnimation(0.04))
        XCTAssertEqual(v.fanAngles.count, 2)
        // 60 ms gathered at 1.6 turns/s.
        XCTAssertEqual(v.fanAngles[0], 2 * Double.pi * 1.6 * 0.06, accuracy: 1e-9)
        XCTAssertEqual(v.fanAngles[1], 0, "a parked fan stays where it is")

        v.isDrawableNow = { false }
        XCTAssertFalse(v.stepFanAnimation(0.1), "a frame while the window cannot be seen ends the animation")
        XCTAssertFalse(v.isAnimatingFans)
    }
}

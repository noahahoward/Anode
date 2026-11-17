import XCTest
@testable import PowerKit

/// A press that means one thing when let go soon, and another when held: the Battery menu's minus button (a press is Soft Drain,
/// three seconds held asks about Hard Drain). The clock is the test's.
final class HoldPressTests: XCTestCase {

    private final class Clock {
        var jobs: [(id: Int, at: TimeInterval, run: () -> Void)] = []
        var now: TimeInterval = 0
        var nextID = 0
        var cancelled = 0
        func schedule(_ after: TimeInterval, _ run: @escaping () -> Void) -> () -> Void {
            nextID += 1; let id = nextID
            jobs.append((id, now + after, run))
            return { [self] in cancelled += 1; jobs.removeAll { $0.id == id } }
        }
        func advance(_ seconds: TimeInterval) {
            now += seconds
            for j in jobs.filter({ $0.at <= now }) { jobs.removeAll { $0.id == j.id }; j.run() }
        }
    }

    private func rig() -> (HoldPress, Clock, () -> (presses: Int, holds: Int)) {
        let clock = Clock()
        let hold = HoldPress(seconds: 3, schedule: clock.schedule)
        var presses = 0, holds = 0
        hold.onPress = { presses += 1 }; hold.onHold = { holds += 1 }
        return (hold, clock, { (presses, holds) })
    }

    func testALetGoBeforeTheTimeIsAPress() {
        let (h, clock, got) = rig()
        h.pressDown(); clock.advance(0.4); h.release(inside: true)
        XCTAssertEqual(got().presses, 1); XCTAssertEqual(got().holds, 0)
        clock.advance(10)
        XCTAssertEqual(got().holds, 0, "the timer went with the press")
    }

    func testHeldForThreeSecondsIsAHold_AndTheLetGoAfterItIsNotAlsoAPress() {
        let (h, clock, got) = rig()
        h.pressDown(); clock.advance(2.9)
        XCTAssertEqual(got().holds, 0)
        clock.advance(0.2)
        XCTAssertEqual(got().holds, 1)
        h.release(inside: true)
        XCTAssertEqual(got().presses, 0, "a hold never also starts Soft Drain")
        XCTAssertEqual(got().holds, 1)
    }

    func testALetGoOffTheButtonIsNeitherAPressNorAHold() {
        let (h, clock, got) = rig()
        h.pressDown(); clock.advance(0.5); h.release(inside: false)
        clock.advance(10)
        XCTAssertEqual(got().presses, 0); XCTAssertEqual(got().holds, 0)
    }

    func testTheNextPressStartsAFreshCount() {
        let (h, clock, got) = rig()
        h.pressDown(); clock.advance(3.1); h.release(inside: true)
        h.pressDown(); clock.advance(0.1); h.release(inside: true)
        XCTAssertEqual(got().holds, 1); XCTAssertEqual(got().presses, 1)
    }

    func testAbandoningAPressNeverFires() {
        let (h, clock, got) = rig()
        h.pressDown(); h.abandon(); clock.advance(10)
        XCTAssertEqual(got().holds, 0); XCTAssertEqual(got().presses, 0)
    }
}

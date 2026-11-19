import XCTest
import CoreGraphics
@testable import AnodeApp

/// A menu of Anode's closes when the menu bar slides away (it is set to hide), as macOS's own do.
final class MenuBarWatchTests: XCTestCase {

    private func bar(y: Double, height: Double = 39, width: Double = 1800, owner: String = "Window Server", layer: Int = 24) -> [String: Any] {
        [kCGWindowOwnerName as String: owner, kCGWindowLayer as String: layer,
         kCGWindowBounds as String: ["X": 0.0, "Y": y, "Width": width, "Height": height]]
    }

    func testTheBarIsShownWhenItsWindowIsOnTheScreen() {
        XCTAssertTrue(MenuBarVisibility.isShown(in: [bar(y: 0)]))
        XCTAssertTrue(MenuBarVisibility.isShown(in: [bar(y: -10)]), "sliding: most of it is still down")
    }

    func testTheBarIsGoneWhenItIsAboveTheEdgeOrNotListed() {
        XCTAssertFalse(MenuBarVisibility.isShown(in: [bar(y: -39)]))
        XCTAssertFalse(MenuBarVisibility.isShown(in: [bar(y: -25)]), "mostly above the edge")
        XCTAssertFalse(MenuBarVisibility.isShown(in: []))
    }

    func testOnlyTheBarsWindowCounts() {
        XCTAssertFalse(MenuBarVisibility.isShown(in: [bar(y: 0, owner: "Safari")]))
        XCTAssertFalse(MenuBarVisibility.isShown(in: [bar(y: 0, layer: 3)]))
        XCTAssertFalse(MenuBarVisibility.isShown(in: [bar(y: 0, height: 600)]), "a tall window is not the bar")
        XCTAssertFalse(MenuBarVisibility.isShown(in: [bar(y: 0, width: 200)]), "nor is a narrow one")
    }

    /// It only counts as gone after it was seen: where the window cannot be found at all, no menu is closed by it.
    func testTheBarOnlyGoesAfterItWasSeen() {
        var r = MenuBarVisibility.step(seenShown: false, shownNow: false)
        XCTAssertEqual(r.gone, false)
        r = MenuBarVisibility.step(seenShown: r.seenShown, shownNow: true)
        XCTAssertEqual(r.seenShown, true)
        XCTAssertEqual(r.gone, false)
        r = MenuBarVisibility.step(seenShown: r.seenShown, shownNow: false)
        XCTAssertEqual(r.gone, true)
    }

    func testTheWatchCallsOnceWhenTheBarGoes() {
        let watch = MenuBarWatch()
        var list = [bar(y: 0)]
        var calls = 0
        let expectation = expectation(description: "gone")
        watch.start(windows: { list }, onGone: { calls += 1; expectation.fulfill() })
        XCTAssertEqual(calls, 0)
        list = []
        wait(for: [expectation], timeout: 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(calls, 1)
        watch.stop()
    }
}

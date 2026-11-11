import XCTest
@testable import PowerKit

/// Which stretches of the bar get a cover, from the owner's measured layout: Anode's widgets x 1114-1500, then the system's
/// items 1507-1780, on a 1800 x 1169 screen.
final class CoverPlannerTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)

    private func item(_ key: String, _ x: CGFloat, w: CGFloat = 40, y: CGFloat = 0, h: CGFloat = 37, locked: Bool = false) -> BarItem {
        BarItem(key: key, bundleID: nil, appName: "A", title: key, frame: CGRect(x: x, y: y, width: w, height: h),
                isLocked: locked, hasPress: true, pid: 1)
    }

    private func layout() -> [BarItem] {
        [item("w1", 1114), item("w2", 1160), item("w3", 1206), item("w4", 1252),
         item("wifi", 1507), item("sound", 1550), item("battery", 1600), item("cc", 1700, locked: true), item("clock", 1740, w: 40, locked: true)]
    }

    private func arrangement(pinned: [String]) -> BarArrangement { BarArrangement(pinned: pinned, pillOrder: []) }

    func testRunOfHiddenItemsIsOneRect() {
        let rects = CoverPlanner.covers(items: layout(), arrangement: arrangement(pinned: ["wifi", "sound", "battery"]), screen: screen)
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].minX, 1111, accuracy: 0.01)    // 1114 - 3
        XCTAssertEqual(rects[0].maxX, 1295, accuracy: 0.01)    // 1292 + 3
        XCTAssertEqual(rects[0].minY, 0)
        XCTAssertEqual(rects[0].height, 37, accuracy: 0.01)
    }

    func testPinnedItemBetweenHiddenSplitsIntoTwoRects() {
        // w1 w2 [w3 pinned] w4: macOS decides the order; the pinned one stays showing between two covers.
        let rects = CoverPlanner.covers(items: layout(), arrangement: arrangement(pinned: ["w3", "wifi", "sound", "battery"]), screen: screen)
        XCTAssertEqual(rects.count, 2)
        XCTAssertLessThanOrEqual(rects[0].maxX, 1206)
        XCTAssertGreaterThanOrEqual(rects[1].minX, 1246)
    }

    func testPaddingNeverOverlapsAPinnedNeighbour() {
        let items = [item("a", 100), item("p", 142)]   // a ends at 140, p starts at 142: a 2 pt gap
        let rects = CoverPlanner.covers(items: items, arrangement: arrangement(pinned: ["p"]), screen: screen, pad: 3)
        XCTAssertEqual(rects.count, 1)
        XCTAssertLessThanOrEqual(rects[0].maxX, 142)
        XCTAssertGreaterThanOrEqual(rects[0].maxX, 140)
    }

    func testParkedAndZeroSizeItemsProduceNoCover() {
        let parked = item("g", -1, w: 24, y: 1157, h: 24)
        let zero = item("z", 1300, w: 0)
        let rects = CoverPlanner.covers(items: [parked, zero], arrangement: arrangement(pinned: []), screen: screen)
        XCTAssertEqual(rects, [])
        let withReal = CoverPlanner.covers(items: [parked, item("r", 1300)], arrangement: arrangement(pinned: []), screen: screen)
        XCTAssertEqual(withReal.count, 1)
        XCTAssertEqual(withReal[0].minX, 1297, accuracy: 0.01)
    }

    func testNothingHiddenMeansNoCovers() {
        let rects = CoverPlanner.covers(items: layout(), arrangement: arrangement(pinned: layout().map(\.key)), screen: screen)
        XCTAssertEqual(rects, [])
        XCTAssertEqual(CoverPlanner.covers(items: [], arrangement: arrangement(pinned: []), screen: screen), [])
    }

    func testRectClampedToScreen() {
        let items = [item("edge", 1770, w: 40)]   // ends at 1810, past the 1800 edge
        let rects = CoverPlanner.covers(items: items, arrangement: arrangement(pinned: []), screen: screen)
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].maxX, 1800, accuracy: 0.01)
    }

    func testLockedItemsAreNeverCovered() {
        let rects = CoverPlanner.covers(items: layout(), arrangement: arrangement(pinned: []), screen: screen)
        for r in rects {
            XCTAssertFalse(r.intersects(CGRect(x: 1700, y: 0, width: 80, height: 37)), "covered the clock or Control Center: \(r)")
        }
    }
}

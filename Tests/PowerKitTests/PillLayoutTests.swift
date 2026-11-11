import XCTest
@testable import PowerKit

/// How many icons fit on a row of the pill, and where the pill sits.
final class PillLayoutTests: XCTestCase {

    private let cell = CGSize(width: 40, height: 30)

    func testSingleRowForFewItems() {
        let r = PillLayout.frames(count: 3, cell: cell, maxWidth: 400, padding: 10, spacing: 6)
        XCTAssertEqual(r.cells.count, 3)
        XCTAssertEqual(r.cells[0], CGRect(x: 10, y: 10, width: 40, height: 30))
        XCTAssertEqual(r.cells[1].minX, 56, accuracy: 0.01)
        let expectedWidth: CGFloat = 10 + 120 + 12 + 10
        XCTAssertEqual(r.size.width, expectedWidth, accuracy: 0.01)
        XCTAssertEqual(r.size.height, 50, accuracy: 0.01)
    }

    func testWrapsToSecondRowAtMaxWidth() {
        // Inner width 100 fits two cells (40 + 6 + 40 = 86); a third does not.
        let r = PillLayout.frames(count: 3, cell: cell, maxWidth: 120, padding: 10, spacing: 6)
        XCTAssertEqual(r.cells[2].minX, 10, accuracy: 0.01)
        XCTAssertEqual(r.cells[2].minY, 46, accuracy: 0.01)
        XCTAssertEqual(r.size.height, 86, accuracy: 0.01)
        XCTAssertEqual(r.size.width, 106, accuracy: 0.01)
    }

    func testZeroItemsGivesPaddingOnlySize() {
        let r = PillLayout.frames(count: 0, cell: cell, maxWidth: 400, padding: 10, spacing: 6)
        XCTAssertEqual(r.cells, [])
        XCTAssertEqual(r.size, CGSize(width: 20, height: 20))
    }

    func testAtLeastOneCellPerRowEvenWhenTooNarrow() {
        let r = PillLayout.frames(count: 2, cell: cell, maxWidth: 30, padding: 10, spacing: 6)
        XCTAssertEqual(r.cells.count, 2)
        XCTAssertEqual(r.cells[1].minY, 46, accuracy: 0.01)
    }

    func testCentredUnderNotch() {
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let notch = CGRect(x: 790, y: 0, width: 220, height: 37)
        let p = PillLayout.origin(size: CGSize(width: 300, height: 60), screen: screen, notch: notch, menuBarHeight: 37, gap: 4)
        XCTAssertEqual(p.x, 900 - 150, accuracy: 0.01)
        XCTAssertEqual(p.y, 41, accuracy: 0.01)
    }

    func testNoNotchCentresOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let p = PillLayout.origin(size: CGSize(width: 200, height: 60), screen: screen, notch: nil, menuBarHeight: 24, gap: 4)
        XCTAssertEqual(p.x, 700, accuracy: 0.01)
        XCTAssertEqual(p.y, 28, accuracy: 0.01)
    }

    func testClampedWhenWiderThanScreen() {
        let screen = CGRect(x: 0, y: 0, width: 500, height: 800)
        let p = PillLayout.origin(size: CGSize(width: 900, height: 60), screen: screen, notch: nil, menuBarHeight: 24, gap: 4)
        XCTAssertEqual(p.x, 0, accuracy: 0.01)
        let q = PillLayout.origin(size: CGSize(width: 100, height: 60), screen: CGRect(x: 100, y: 0, width: 500, height: 800),
                                  notch: CGRect(x: 580, y: 0, width: 200, height: 30), menuBarHeight: 30, gap: 4)
        XCTAssertEqual(q.x, 500, accuracy: 0.01)   // pushed back inside the screen's right edge (600 - 100)
    }
}

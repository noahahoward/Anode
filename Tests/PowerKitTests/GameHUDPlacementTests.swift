import XCTest
@testable import PowerKit

/// Where the strip sits. Cocoa coordinates: the origin is the bottom-left of the primary screen.
final class GameHUDPlacementTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)   // this Mac, measured
    private let size = CGSize(width: 400, height: 22)

    private func frame(_ corner: HUDCorner, on frame: CGRect? = nil, safeTop: CGFloat = 0, menuBar: CGFloat = 24,
                       fullscreen: Bool = true) -> CGRect {
        GameHUDPlacement.frame(size: size, corner: corner, screenFrame: frame ?? screen, safeTop: safeTop,
                               menuBarHeight: menuBar, fullscreen: fullscreen)
    }

    func testTopRightFullscreenNotchedSitsInTheBand() {
        let f = frame(.topRight, safeTop: 39, menuBar: 39)
        XCTAssertEqual(f.origin.x, 1392)
        XCTAssertEqual(f.origin.y, 1138.5)
        XCTAssertEqual(f.size, size)
    }

    func testTopRightFullscreenWithoutNotchIsAtTheEdge() {
        XCTAssertEqual(frame(.topRight).origin.y, 1147)
    }

    func testTopRightWindowedIsBelowTheMenuBar() {
        XCTAssertEqual(frame(.topRight, safeTop: 39, menuBar: 39, fullscreen: false).origin.y, 1104)
    }

    func testBottomLeft() {
        let f = frame(.bottomLeft)
        XCTAssertEqual(f.origin.x, 8)
        XCTAssertEqual(f.origin.y, 8)
    }

    func testSecondaryDisplayOriginIsRespected() {
        let second = CGRect(x: 1800, y: -200, width: 1920, height: 1080)
        let f = frame(.topLeft, on: second)
        XCTAssertEqual(f.origin.x, 1808)
        XCTAssertEqual(f.origin.y, 858)
    }

    func testAlwaysInsideTheScreen() {
        let screens = [screen, CGRect(x: 1800, y: -200, width: 1920, height: 1080)]
        for s in screens {
            for corner in HUDCorner.allCases {
                for fullscreen in [true, false] {
                    for safeTop: CGFloat in [0, 39] {
                        let f = frame(corner, on: s, safeTop: safeTop, menuBar: max(safeTop, 24), fullscreen: fullscreen)
                        XCTAssertTrue(s.contains(f), "\(corner) fullscreen=\(fullscreen) safeTop=\(safeTop) on \(s): \(f)")
                    }
                }
            }
        }
    }
}

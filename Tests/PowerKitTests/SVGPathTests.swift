import AppKit
import XCTest
@testable import AnodeApp

/// The path reader behind the Hardware View's Apple logo and pipe polylines.
final class SVGPathTests: XCTestCase {

    func testTriangleHasTheRightBoundingBox() throws {
        let path = try XCTUnwrap(SVGPath.bezier("M0 0 L10 0 L5 8 Z"))
        XCTAssertEqual(path.bounds.minX, 0, accuracy: 0.001)
        XCTAssertEqual(path.bounds.minY, 0, accuracy: 0.001)
        XCTAssertEqual(path.bounds.width, 10, accuracy: 0.001)
        XCTAssertEqual(path.bounds.height, 8, accuracy: 0.001)
    }

    func testRelativeCommandsOffsetFromTheCurrentPoint() throws {
        let path = try XCTUnwrap(SVGPath.bezier("m10 10 l5 0 l0 5 z"))
        XCTAssertEqual(path.bounds.minX, 10, accuracy: 0.001)
        XCTAssertEqual(path.bounds.minY, 10, accuracy: 0.001)
        XCTAssertEqual(path.bounds.width, 5, accuracy: 0.001)
        XCTAssertEqual(path.bounds.height, 5, accuracy: 0.001)
    }

    func testExtraPairsAfterAMoveAreLines() throws {
        let path = try XCTUnwrap(SVGPath.bezier("M0 0 4 0 4 3"))
        XCTAssertEqual(path.elementCount, 3)
        XCTAssertEqual(path.bounds.width, 4, accuracy: 0.001)
        XCTAssertEqual(path.bounds.height, 3, accuracy: 0.001)
    }

    func testPackedNumbersAreSplitTheWayTheyAreInTheLogo() throws {
        // "3.96.948" is 3.96 then .948, and "1.5-2" is 1.5 then -2 (an implicit second L): a move and two lines.
        let path = try XCTUnwrap(SVGPath.bezier("M0 0L3.96.948 1.5-2"))
        XCTAssertEqual(path.elementCount, 3)
        XCTAssertEqual(path.currentPoint.x, 1.5, accuracy: 0.001)
        XCTAssertEqual(path.currentPoint.y, -2, accuracy: 0.001)
    }

    func testACubicIsOneCurveElement() throws {
        let path = try XCTUnwrap(SVGPath.bezier("M0 0 C 0 10 10 10 10 0"))
        XCTAssertEqual(path.elementCount, 2)
        XCTAssertEqual(path.currentPoint.x, 10, accuracy: 0.001)
        XCTAssertEqual(path.currentPoint.y, 0, accuracy: 0.001)
    }

    func testTheAppleLogoParses() throws {
        let path = try XCTUnwrap(SVGPath.bezier(HardwareStyle.appleLogoData))
        // Two sub-paths (the body and the leaf). The box of every point, control points included, is about 20.7 wide and
        // 24.05 tall (the glyph sits in a 24-unit square); the drawn outline is inside it.
        let box = path.controlPointBounds
        XCTAssertEqual(box.width, 20.66, accuracy: 0.05)
        XCTAssertEqual(box.height, 24.05, accuracy: 0.05)
        XCTAssertGreaterThan(path.bounds.width, 14)
        XCTAssertLessThanOrEqual(path.bounds.width, box.width)
        XCTAssertNotNil(HardwareStyle.appleLogo)
    }

    func testEmptyAndGarbageGiveNil() {
        XCTAssertNil(SVGPath.bezier(""))
        XCTAssertNil(SVGPath.bezier("   "))
        XCTAssertNil(SVGPath.bezier("hello"))
        XCTAssertNil(SVGPath.bezier("M 0"))               // a missing number
        XCTAssertNil(SVGPath.bezier("M 10 10"))           // draws nothing
        XCTAssertNil(SVGPath.bezier("L 1 2"))             // no move first
        XCTAssertNil(SVGPath.bezier("M0 0 L 1 x"))        // not a number
        XCTAssertNil(SVGPath.bezier("M0 0 A 5 5 0 0 1 10 10"))   // an arc, which this reader does not do
        XCTAssertNil(SVGPath.bezier("M0 0 L1 1 Z 5 5"))   // numbers after Z with no command
    }
}

import XCTest
@testable import PowerKit

/// The stand-in picture over macOS's Sound icon covers the pill macOS lights round it, and not the rest of the bar.
final class IconCoverGeometryTests: XCTestCase {
    private let icon = CGRect(x: 1540, y: 8.5, width: 22, height: 22)

    func testTheCoverIsWiderThanTheIconByTheLitPillsReach() {
        let r = IconCoverGeometry.rect(for: icon)
        XCTAssertEqual(r.minX, 1527); XCTAssertEqual(r.width, 48)
    }

    func testTheCoverReachesOnePointPastTheLitPillRowsAndNoFurther() {
        // The lit pill was measured at rows 8 to 31 for this icon.
        let r = IconCoverGeometry.rect(for: icon)
        XCTAssertEqual(r.minY, 7); XCTAssertEqual(r.maxY, 33)
    }

    func testTheCoverStaysWellAboveTheBarsLowerEdge() {
        XCTAssertLessThan(IconCoverGeometry.rect(for: icon).maxY, 36, "the lower edge of the 39 pt bar darkens with what is under it")
    }
}

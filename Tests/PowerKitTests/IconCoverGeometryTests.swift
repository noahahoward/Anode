import XCTest
@testable import PowerKit

/// The stand-in picture over macOS's Sound icon must stay inside the menu bar: below it is whatever window is there at the time.
final class IconCoverGeometryTests: XCTestCase {
    private let icon = CGRect(x: 1540, y: 8.5, width: 22, height: 22)

    func testTheCoverIsWiderThanTheIconAndAtLeast33PointsTall() {
        let r = IconCoverGeometry.rect(for: icon, barBottom: nil)
        XCTAssertEqual(r, CGRect(x: 1527, y: 8, width: 48, height: 33))
    }

    func testTheCoverNeverReachesBelowTheBar() {
        let r = IconCoverGeometry.rect(for: icon, barBottom: 39)
        XCTAssertEqual(r.maxY, 39)
        XCTAssertEqual(r.minY, 8)
        XCTAssertEqual(r.minX, 1527); XCTAssertEqual(r.width, 48)
    }

    func testABarTallerThanTheCoverLeavesItAlone() {
        XCTAssertEqual(IconCoverGeometry.rect(for: icon, barBottom: 60).height, 33)
    }

    func testABarBottomAboveTheIconMakesNoNegativeHeight() {
        XCTAssertGreaterThanOrEqual(IconCoverGeometry.rect(for: icon, barBottom: 5).height, 1)
    }
}

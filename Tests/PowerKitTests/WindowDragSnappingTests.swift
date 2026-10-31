import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

final class WindowDragSnappingTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    private func zone(_ x: CGFloat, _ y: CGFloat, screens: [CGRect]? = nil,
                      previous: SnapZone? = nil, dwelt: Bool = true) -> SnapZone? {
        SnapZones.zone(at: CGPoint(x: x, y: y), screens: screens ?? [screen], previous: previous, topDwelt: dwelt)
    }

    // ── Zones ──

    func testCornersGiveQuarters() {
        XCTAssertEqual(zone(5, 5), .topLeft)
        XCTAssertEqual(zone(1795, 5), .topRight)
        XCTAssertEqual(zone(5, 1164), .bottomLeft)
        XCTAssertEqual(zone(1795, 1164), .bottomRight)
        XCTAssertEqual(zone(50, 40), .topLeft, "a corner is generous, not a single point")
    }

    func testSidesGiveHalvesAndTheTopMaximizes() {
        XCTAssertEqual(zone(3, 600), .left)
        XCTAssertEqual(zone(1797, 600), .right)
        XCTAssertEqual(zone(900, 3), .top)
    }

    func testTheMiddleOfTheScreenAndTheInsideOfTheMarginAreNotZones() {
        XCTAssertNil(zone(900, 600))
        XCTAssertNil(zone(40, 600), "past the 14 pt edge")
        XCTAssertNil(zone(900, 40), "below the top edge")
    }

    /// The reported gap: thirds by dragging. The bottom edge gives them, wherever the Dock is, because
    /// dragging a window does not make an auto-hiding Dock appear.
    func testTheBottomEdgeIsThirds() {
        XCTAssertEqual(zone(100, 1166), .bottomFirst)        // left third of the width, outside the corner
        XCTAssertEqual(zone(900, 1166), .bottomCenter)
        XCTAssertEqual(zone(1500, 1166), .bottomLast)
        XCTAssertEqual(zone(5, 1164), .bottomLeft, "the corners are still quarters")
        XCTAssertEqual(zone(1795, 1164), .bottomRight)
    }

    func testTheThirdsBoundariesAreAtOneAndTwoThirdsOfTheWidth() {
        XCTAssertEqual(zone(599, 1166), .bottomFirst)
        XCTAssertEqual(zone(601, 1166), .bottomCenter)
        XCTAssertEqual(zone(1199, 1166), .bottomCenter)
        XCTAssertEqual(zone(1201, 1166), .bottomLast)
    }

    func testEveryEdgeIsAZoneWhateverTheDockDoes() {
        XCTAssertEqual(zone(3, 600), .left)
        XCTAssertEqual(zone(1797, 600), .right)
        XCTAssertEqual(zone(900, 1166), .bottomCenter)
    }

    // ── Seams between displays ──

    private let two = [CGRect(x: 0, y: 0, width: 1800, height: 1169), CGRect(x: 1800, y: 0, width: 1280, height: 800)]

    func testTheEdgeSharedWithAnotherDisplayIsNotAZone() {
        XCTAssertNil(zone(1797, 600, screens: two), "right edge of the left display, over the other display")
        XCTAssertNil(zone(1803, 600, screens: two), "left edge of the right display")
        XCTAssertEqual(zone(1797, 1000, screens: two), .right,
                       "below the other display's bottom (y 800) the edge is a real edge again")
    }

    func testACornerOnASeamIsNotACornerAndFallsBackToWhatIsLeft() {
        // Top right of the left display touches the other along its right side: no quarter there, but the
        // pointer is still at the very top, so it is the top zone (maximize), not nothing.
        XCTAssertEqual(zone(1795, 5, screens: two), .top)
        XCTAssertEqual(zone(1805, 5, screens: two), .top, "and the same on the other side of the seam")
        XCTAssertNotEqual(zone(1795, 5, screens: two), .topRight)
        XCTAssertEqual(zone(1795, 900, screens: two), .right, "below the other display, a real edge again")
    }

    func testTheFarEdgesOfTheOutermostDisplaysStillWork() {
        XCTAssertEqual(zone(3, 600, screens: two), .left)
        XCTAssertEqual(zone(3075, 400, screens: two), .right)
    }

    // ── The top is the whole menu bar ──

    private func top(_ y: CGFloat, depth: CGFloat = 39, previous: SnapZone? = nil, dwelt: Bool = true, x: CGFloat = 900) -> SnapZone? {
        SnapZones.zone(at: CGPoint(x: x, y: y), screens: [screen], previous: previous, topDwelt: dwelt, topDepths: [depth])
    }

    /// The report: maximizing had to be done in the top 14 points; it should engage in the menu bar.
    func testTheTopZoneIsAsDeepAsTheMenuBar() {
        XCTAssertEqual(top(30), .top, "the middle of a 39 pt menu bar")
        XCTAssertEqual(top(38), .top, "its bottom edge")
        XCTAssertNil(top(45), "just below the menu bar: not the top zone")
        XCTAssertNil(zone(900, 30), "with no depth given it is still the 14 pt edge")
    }

    func testAShallowMenuBarOnAnotherDisplayUsesItsOwnDepth() {
        XCTAssertEqual(top(20, depth: 24), .top)
        XCTAssertNil(top(30, depth: 24))
        XCTAssertEqual(top(3, depth: 0), .top, "a screen with no menu bar keeps the edge depth")
    }

    func testTheCornersAreStillQuartersInsideTheMenuBar() {
        XCTAssertEqual(top(30, x: 20), .topLeft)
        XCTAssertEqual(top(30, x: 1780), .topRight)
    }

    func testTheMenuBarZoneStaysActiveLikeAnyOther() {
        XCTAssertEqual(top(50, previous: .top, dwelt: false), .top, "39 + 18 hysteresis")
        XCTAssertNil(top(70, previous: .top))
        XCTAssertTrue(SnapZones.inTopEdge(CGPoint(x: 900, y: 30), screens: [screen], topDepths: [39]))
        XCTAssertFalse(SnapZones.inTopEdge(CGPoint(x: 900, y: 30), screens: [screen]))
    }

    func testTheRestIsBrief() {
        XCTAssertEqual(SnapZones.Config().topDwell, 0.1, accuracy: 0.001)
    }

    // ── The top, and sticking ──

    func testTheTopWaitsForTheDwell() {
        XCTAssertNil(zone(900, 3, dwelt: false), "just passing through the menu bar")
        XCTAssertEqual(zone(900, 3, dwelt: true), .top)
        XCTAssertEqual(zone(900, 3, previous: .top, dwelt: false), .top, "once active it stays")
        XCTAssertTrue(SnapZones.inTopEdge(CGPoint(x: 900, y: 3), screens: [screen]))
        XCTAssertFalse(SnapZones.inTopEdge(CGPoint(x: 900, y: 300), screens: [screen]))
    }

    /// No flicker on a boundary: an active zone reaches 18 pt further than one being entered.
    func testAnActiveZoneReachesFurtherOut() {
        XCTAssertNil(zone(25, 600), "entering: 25 pt is outside the 14 pt zone")
        XCTAssertEqual(zone(25, 600, previous: .left), .left, "leaving: still in it until 32 pt")
        XCTAssertNil(zone(40, 600, previous: .left))
        XCTAssertEqual(zone(70, 40, previous: .topLeft), .topLeft)
    }

    func testAPointOffEveryScreenIsNothing() {
        XCTAssertNil(zone(-300, 600))
        XCTAssertNil(zone(900, 5000))
    }

    // ── Unsnapping ──

    func testADraggedSnappedWindowGetsItsOldSizeBackUnderThePointer() {
        let snapped = CGRect(x: 0, y: 39, width: 900, height: 1130)
        let r = SnapZones.unsnapped(snapped: snapped, original: CGSize(width: 600, height: 400), pointer: CGPoint(x: 450, y: 60))
        XCTAssertEqual(r.size, CGSize(width: 600, height: 400))
        XCTAssertEqual(r.minX, 150, "the pointer was halfway along the title bar, so it still is")
        XCTAssertEqual(r.minY, 39, "and the same distance down it")
        let edge = SnapZones.unsnapped(snapped: snapped, original: CGSize(width: 600, height: 400), pointer: CGPoint(x: 0, y: 50))
        XCTAssertEqual(edge.minX, 0)
    }

    // ── The footprint, the setting, the section ──

    func testTheFootprintIsDrawnWhereTheWindowWillGo() {
        let area = CGRect(x: 0, y: 39, width: 1800, height: 1130)
        XCTAssertEqual(WindowGeometry.frame(for: SnapZone.left.action, from: .zero, in: area), CGRect(x: 0, y: 39, width: 900, height: 1130))
        XCTAssertEqual(WindowGeometry.frame(for: SnapZone.bottomLast.action, from: .zero, in: area)?.maxX, 1800)
        XCTAssertEqual(SnapZone.top.action, .maximize)
    }

    func testTheSettingDefaultsToOffAndTheSectionWarnsAboutMacOSTiling() {
        let defaults = UserDefaults(suiteName: "drag-snap-\(UUID().uuidString)")!
        let s = Settings(defaults: defaults)
        XCTAssertFalse(s.windowDragSnapEnabled)
        s.windowDragSnapEnabled = true
        XCTAssertTrue(Settings(defaults: defaults).windowDragSnapEnabled)
        let f = WindowActionsFeature(settings: s, accessibilityAllowed: { true }, nativeEdgeTiling: { true })
        _ = f.makeView()
        XCTAssertTrue(f.dragNote.stringValue.contains("macOS's own edge tiling is on"))
        XCTAssertEqual(f.dragCheckbox.state, .on)
        let g = WindowActionsFeature(settings: s, accessibilityAllowed: { true }, nativeEdgeTiling: { false })
        _ = g.makeView()
        XCTAssertFalse(g.dragNote.stringValue.contains("macOS's own edge tiling"))
    }
}

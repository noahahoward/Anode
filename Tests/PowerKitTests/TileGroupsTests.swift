import XCTest
@testable import AnodeApp

final class TileGroupsTests: XCTestCase {
    /// A 1800 x 1169 display, menu bar 39 pt, Dock auto-hiding.
    private let screen = CGRect(x: 0, y: 39, width: 1800, height: 1130)

    private func w(_ id: CGWindowID, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
                   pid: pid_t = 1, off: Bool = false) -> SwitchableWindow {
        SwitchableWindow(id: id, pid: pid, appName: "", title: "", bounds: CGRect(x: x, y: y, width: width, height: height),
                         isOffScreen: off)
    }
    private func ids(_ target: CGWindowID, _ windows: [SwitchableWindow]) -> [CGWindowID]? {
        TileGroups.group(containing: target, windows: windows, screens: [screen])?.map(\.id)
    }

    /// The reported layout: three windows in thirds.
    func testThreeThirdsAreAGroup() {
        let thirds = [w(1, 0, 39, 600, 1130), w(2, 600, 39, 600, 1130), w(3, 1200, 39, 600, 1130)]
        XCTAssertEqual(ids(2, thirds), [2, 1, 3], "the clicked window first, then front to back")
    }

    func testTwoHalvesOfDifferentAppsAreAGroup() {
        XCTAssertEqual(ids(5, [w(5, 0, 39, 900, 1130, pid: 1), w(6, 900, 39, 900, 1130, pid: 2)]), [5, 6])
    }

    /// Something opened over the layout is not part of it, and does not hide it.
    func testAWindowLyingAcrossTheLayoutIsLeftOut() {
        let windows = [w(9, 300, 200, 1200, 800, pid: 3),       // in front, across both halves
                       w(5, 0, 39, 900, 1130, pid: 1), w(6, 900, 39, 900, 1130, pid: 2)]
        XCTAssertEqual(ids(5, windows), [5, 6])
    }

    func testAWindowThatFillsNothingLikeALayoutIsNotAGroup() {
        // One big window and a small one beside it: covered, but not tiles.
        XCTAssertNil(ids(1, [w(1, 0, 39, 1700, 1130), w(2, 1700, 39, 100, 300)]))
        XCTAssertNil(ids(1, [w(1, 0, 39, 1800, 1130)]), "one window alone is not a group")
    }

    /// A Dock that is always shown: tiles stop above it, ~91% of the area below the menu bar.
    func testTilesAboveAFixedDockAreAGroup() {
        XCTAssertEqual(ids(1, [w(1, 0, 39, 900, 1030), w(2, 900, 39, 900, 1030)]), [1, 2])
    }

    func testHalfALayoutIsNotAGroup() {
        // Two thirds side by side, the last third empty: 67% covered.
        XCTAssertNil(ids(1, [w(1, 0, 39, 600, 1130), w(2, 600, 39, 600, 1130)]))
    }

    /// The case that broke the first version: a third of ANOTHER layout behind, beside the
    /// clicked half, must not shut out the real partner.
    func testAnotherLayoutBehindDoesNotStealThePartner() {
        let windows = [w(10, 0, 39, 900, 1130, pid: 1),                    // TextEdit, left half, in front
                       w(21, 600, 39, 600, 1130, pid: 2), w(22, 0, 39, 600, 1130, pid: 2),
                       w(23, 1200, 39, 600, 1130, pid: 2),                 // Code in thirds
                       w(30, 900, 39, 900, 1130, pid: 3)]                  // Finder, right half, further back
        XCTAssertEqual(ids(10, windows), [10, 30])
    }

    func testOnATieTheWindowsNearerTheFrontWin() {
        let windows = [w(1, 0, 39, 900, 1130), w(2, 900, 39, 900, 1130, pid: 2), w(3, 900, 39, 900, 1130, pid: 3)]
        XCTAssertEqual(ids(1, windows), [1, 2])
    }

    func testGapsBetweenTilesStillCount() {
        // macOS can leave margins around tiled windows.
        let withMargins = [w(1, 8, 47, 884, 1114), w(2, 908, 47, 884, 1114)]
        XCTAssertEqual(ids(1, withMargins), [1, 2])
    }

    func testWindowsOnAnotherScreenOrMinimizedAreNotMembers() {
        let windows = [w(1, 0, 39, 900, 1130), w(2, 900, 39, 900, 1130, off: true), w(3, 1800, 0, 900, 800)]
        XCTAssertNil(ids(1, windows))
    }
}

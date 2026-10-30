import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

final class DesktopSwitcherTests: XCTestCase {

    private func display(_ id: String, current: Int, spaces: [(Int, Int)]) -> [String: Any] {
        ["Display Identifier": id, "Current Space": ["ManagedSpaceID": current],
         "Spaces": spaces.map { ["ManagedSpaceID": $0.0, "type": $0.1] }]
    }

    // ── Reading the desktops ──

    func testDesktopsAreNumberedInOrderAndTheCurrentOneIsMarked() {
        let d = display("A", current: 20, spaces: [(10, 0), (20, 0), (30, 0)])
        let r = SpaceCatalog.desktops(displays: [d], displayUUID: "A", windowsBySpace: [:])!
        XCTAssertEqual(r.desktops.map(\.number), [1, 2, 3])
        XCTAssertEqual(r.desktops.map(\.isCurrent), [false, true, false])
        XCTAssertEqual(r.display, "A")
    }

    /// A full-screen app is its own Space; it must not take a "Desktop N" number.
    func testAFullScreenSpaceHasNoDesktopNumberAndDoesNotShiftTheOthers() {
        let d = display("A", current: 10, spaces: [(10, 0), (15, 4), (20, 0)])
        let r = SpaceCatalog.desktops(displays: [d], displayUUID: "A", windowsBySpace: [:])!
        XCTAssertEqual(r.desktops.map(\.number), [1, nil, 2])
        XCTAssertEqual(r.desktops.map(\.isFullScreen), [false, true, false])
    }

    func testEachDesktopListsItsAppsOnceAndCountsItsWindows() {
        let d = display("A", current: 10, spaces: [(10, 0), (20, 0), (30, 0)])
        let r = SpaceCatalog.desktops(displays: [d], displayUUID: "A",
                                      windowsBySpace: [10: [5, 5, 7, 5], 20: [9]])!
        XCTAssertEqual(r.desktops[0].pids, [5, 7]); XCTAssertEqual(r.desktops[0].windowCount, 4)
        XCTAssertEqual(r.desktops[1].pids, [9]);    XCTAssertEqual(r.desktops[1].windowCount, 1)
        XCTAssertEqual(r.desktops[2].windowCount, 0)
    }

    func testTheRightDisplayIsChosenAndAnUnknownOneFallsBackToTheFirst() {
        let a = display("A", current: 1, spaces: [(1, 0), (2, 0)]), b = display("B", current: 3, spaces: [(3, 0), (4, 0), (5, 0)])
        XCTAssertEqual(SpaceCatalog.desktops(displays: [a, b], displayUUID: "b", windowsBySpace: [:])?.desktops.count, 3,
                       "matched without regard to case")
        XCTAssertEqual(SpaceCatalog.desktops(displays: [a, b], displayUUID: "nope", windowsBySpace: [:])?.display, "A")
        XCTAssertNil(SpaceCatalog.desktops(displays: [], displayUUID: nil, windowsBySpace: [:]))
    }

    // ── Selection ──

    func testOpeningSelectsTheNextDesktopAndWraps() {
        var s = DesktopSelection()
        s.start(count: 3, current: 0, backward: false); XCTAssertEqual(s.index, 1)
        s.start(count: 3, current: 2, backward: false); XCTAssertEqual(s.index, 0, "wraps past the last")
        s.start(count: 3, current: 0, backward: true);  XCTAssertEqual(s.index, 2, "Shift goes back, wrapping")
    }

    func testOneDesktopOrNoneSelectsNothing() {
        var s = DesktopSelection()
        s.start(count: 1, current: 0, backward: false); XCTAssertNil(s.index)
        s.start(count: 0, current: 0, backward: false); XCTAssertNil(s.index)
        s.step(1); XCTAssertNil(s.index)
    }

    func testSteppingAndDirectSelection() {
        var s = DesktopSelection()
        s.start(count: 4, current: 0, backward: false)
        s.step(1); XCTAssertEqual(s.index, 2)
        s.step(-3); XCTAssertEqual(s.index, 3)
        s.select(0); XCTAssertEqual(s.index, 0)
        s.select(9); XCTAssertEqual(s.index, 0, "out of range is ignored")
    }

    func testTheNumberRowMapsToDesktopsOneToNine() {
        XCTAssertEqual(DesktopSwitcher.digits.count, 9)
        XCTAssertEqual(Set(DesktopSwitcher.digits.values), Set(0..<9))
    }

    // ── Layout and labels ──

    func testFewDesktopsAreOneRowAndManyWrap() {
        XCTAssertEqual(DesktopPanel.grid(count: 3, width: 1500).columns, 3)
        let g = DesktopPanel.grid(count: 16, width: 700)
        XCTAssertGreaterThan(g.rows, 1)
        XCTAssertGreaterThanOrEqual(g.columns * g.rows, 16)
        XCTAssertEqual(DesktopPanel.grid(count: 0, width: 700).columns, 0)
    }

    func testTitlesAndDetails() {
        let d = DesktopInfo(id: 1, number: 2, isFullScreen: false, isCurrent: true, pids: [], windowCount: 3)
        XCTAssertEqual(DesktopTile.title(for: d), "Desktop 2")
        XCTAssertEqual(DesktopTile.detail(for: d), "Current · 3 windows")
        let e = DesktopInfo(id: 2, number: 3, isFullScreen: false, isCurrent: false, pids: [], windowCount: 0)
        XCTAssertEqual(DesktopTile.detail(for: e), "Empty")
        XCTAssertEqual(DesktopTile.detail(for: DesktopInfo(id: 3, number: 4, isFullScreen: false, isCurrent: false, pids: [], windowCount: 1)),
                       "1 window")
        XCTAssertEqual(DesktopTile.title(for: DesktopInfo(id: 4, number: nil, isFullScreen: true, isCurrent: false, pids: [], windowCount: 1)),
                       "Full screen")
    }

    // ── Setting and section ──

    func testTheSettingDefaultsToOffAndRoundTrips() {
        let defaults = UserDefaults(suiteName: "desktop-switcher-\(UUID().uuidString)")!
        let s = Settings(defaults: defaults)
        XCTAssertFalse(s.desktopSwitcherEnabled)
        s.desktopSwitcherEnabled = true
        XCTAssertTrue(Settings(defaults: defaults).desktopSwitcherEnabled)
    }

    func testTheCheckboxWritesTheSetting() {
        let defaults = UserDefaults(suiteName: "desktop-switcher-\(UUID().uuidString)")!
        let s = Settings(defaults: defaults)
        let f = DesktopSwitcherFeature(settings: s, accessibilityAllowed: { true })
        _ = f.makeView()
        f.enableCheckbox.state = .on
        _ = f.enableCheckbox.target?.perform(f.enableCheckbox.action)
        XCTAssertTrue(s.desktopSwitcherEnabled)
        XCTAssertTrue(f.accessButton.isHidden)
    }

    func testTheBetaWindowListsIt() {
        XCTAssertTrue(BetaFeaturesWindowController().features.contains { $0 is DesktopSwitcherFeature })
    }
}

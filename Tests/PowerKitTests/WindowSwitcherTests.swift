import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

final class WindowSwitcherTests: XCTestCase {

    private func entry(_ id: Int, pid: Int32, layer: Int = 0, alpha: Double = 1,
                       w: CGFloat = 800, h: CGFloat = 600, name: String = "App", title: String? = nil) -> [String: Any] {
        var e: [String: Any] = [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
                                kCGWindowLayer as String: layer, kCGWindowAlpha as String: alpha,
                                kCGWindowOwnerName as String: name,
                                kCGWindowBounds as String: CGRect(x: 0, y: 40, width: w, height: h)
                                    .dictionaryRepresentation as NSDictionary]
        if let title { e[kCGWindowName as String] = title }
        return e
    }

    // ── Which windows ──

    func testKeepsOrdinaryWindowsOfRegularAppsInFrontToBackOrder() {
        let list = WindowCatalog.switchable(windowInfo: [entry(3, pid: 1, title: "front"), entry(1, pid: 2), entry(2, pid: 1)],
                                            regularPIDs: [1, 2])
        XCTAssertEqual(list.map(\.id), [3, 1, 2])
        XCTAssertEqual(list.first?.title, "front")
    }

    func testDropsWhatIsNotAWindowToSwitchTo() {
        let list = WindowCatalog.switchable(windowInfo: [
            entry(1, pid: 9),                       // an app with no Dock tile
            entry(2, pid: 1, layer: 3),             // a floating panel or overlay
            entry(3, pid: 1, alpha: 0),             // invisible
            entry(4, pid: 1, w: 40, h: 300),        // a sliver
            entry(5, pid: 1),
        ], regularPIDs: [1])
        XCTAssertEqual(list.map(\.id), [5])
    }

    func testAnUntitledWindowStillCounts() {
        XCTAssertEqual(WindowCatalog.switchable(windowInfo: [entry(1, pid: 1)], regularPIDs: [1]).first?.title, "")
    }

    // ── Selection ──

    func testOpeningSelectsThePreviousWindow() {
        var s = SwitcherSelection()
        s.start(count: 4)
        XCTAssertEqual(s.index, 1, "a quick ⌘Tab goes back to the window behind")
    }

    func testOneWindowSelectsItAndNoneSelectsNothing() {
        var s = SwitcherSelection()
        s.start(count: 1); XCTAssertEqual(s.index, 0)
        s.start(count: 0); XCTAssertNil(s.index)
        s.step(1); XCTAssertNil(s.index)
    }

    func testSteppingWrapsBothWays() {
        var s = SwitcherSelection()
        s.start(count: 3)
        s.step(1); XCTAssertEqual(s.index, 2)
        s.step(1); XCTAssertEqual(s.index, 0)
        s.step(-1); XCTAssertEqual(s.index, 2)
    }

    func testShiftTabOpensOnTheLastWindow() {
        var s = SwitcherSelection()
        s.start(count: 5)
        s.step(-2)   // what `begin(backward: true)` does
        XCTAssertEqual(s.index, 4)
    }

    func testSelectIgnoresOutOfRange() {
        var s = SwitcherSelection()
        s.start(count: 2)
        s.select(5); XCTAssertEqual(s.index, 1)
        s.select(0); XCTAssertEqual(s.index, 0)
    }

    // ── Layout ──

    func testAFewWindowsGoInOneFullSizeRow() {
        let g = SwitcherPanel.grid(count: 3, width: 1600, height: 900)
        XCTAssertEqual(g.columns, 3); XCTAssertEqual(g.rows, 1); XCTAssertEqual(g.scale, 1)
    }

    func testManyWindowsWrapAndShrinkToFit() {
        let height: CGFloat = 700
        let g = SwitcherPanel.grid(count: 40, width: 1500, height: height)
        XCTAssertGreaterThanOrEqual(g.columns * g.rows, 40)
        XCTAssertLessThan(g.scale, 1)
        let used = CGFloat(g.rows) * (SwitcherPanel.tileHeight + SwitcherPanel.spacing) * g.scale + 2 * SwitcherPanel.padding
        XCTAssertLessThanOrEqual(used, height)
    }

    // ── Setting and section ──

    func testTheSettingDefaultsToOffAndRoundTrips() {
        let defaults = UserDefaults(suiteName: "switcher-\(UUID().uuidString)")!
        let s = Settings(defaults: defaults)
        XCTAssertFalse(s.windowSwitcherEnabled, "it takes over a system shortcut, so the user turns it on")
        s.windowSwitcherEnabled = true
        XCTAssertTrue(Settings(defaults: defaults).windowSwitcherEnabled)
    }

    func testTheCheckboxWritesTheSettingAndTheStatusFollowsPermission() {
        let defaults = UserDefaults(suiteName: "switcher-\(UUID().uuidString)")!
        let s = Settings(defaults: defaults)
        var allowed = true
        let f = WindowSwitcherFeature(settings: s, accessibilityAllowed: { allowed }, screenRecordingAllowed: { true })
        _ = f.makeView()
        XCTAssertEqual(f.enableCheckbox.state, .off)
        XCTAssertTrue(f.accessStatus.isHidden)

        // As a click does: the box changes state, then sends its action.
        f.enableCheckbox.state = .on
        _ = f.enableCheckbox.target?.perform(f.enableCheckbox.action)
        XCTAssertTrue(s.windowSwitcherEnabled)
        XCTAssertFalse(f.accessStatus.isHidden)
        XCTAssertTrue(f.accessButton.isHidden, "nothing to open when it is already allowed")

        allowed = false
        f.refresh()
        XCTAssertFalse(f.accessButton.isHidden)
        XCTAssertTrue(f.accessStatus.stringValue.contains("not allowed"))
    }

    func testTheBetaWindowListsTheSwitcher() {
        let c = BetaFeaturesWindowController()
        XCTAssertTrue(c.features.contains { $0 is WindowSwitcherFeature })
    }
}

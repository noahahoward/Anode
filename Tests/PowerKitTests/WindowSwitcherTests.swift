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

    func testATallAndAWideWindowGetTilesOfTheirOwnShape() {
        let shape = SwitcherPanel.shape
        let (frames, _) = shape.layout(aspects: [0.7, 1.6], limit: CGSize(width: 1600, height: 900))
        XCTAssertEqual(frames[0].width, shape.previewHeight * 0.7 + 2 * shape.tileInset, accuracy: 0.01)
        XCTAssertEqual(frames[1].width, shape.previewHeight * 1.6 + 2 * shape.tileInset, accuracy: 0.01)
        XCTAssertEqual(frames[0].height, shape.tileHeight, "one height for all")
    }

    func testManyWindowsWrapAndShrinkToFitTheScreen() {
        let shape = SwitcherPanel.shape
        let limit = CGSize(width: 1500, height: 560)
        let (frames, size) = shape.layout(aspects: Array(repeating: 1.4, count: 60), limit: limit)
        XCTAssertEqual(frames.count, 60)
        XCTAssertLessThanOrEqual(size.width, limit.width + 0.01)
        XCTAssertLessThanOrEqual(size.height, limit.height + 0.01, "shrinks until the rows fit the height")
        XCTAssertLessThan(frames[0].height, shape.tileHeight)
    }

    func testAnEmptyListLaysOutNothing() {
        XCTAssertEqual(SwitcherPanel.shape.layout(aspects: [], limit: CGSize(width: 1000, height: 500)).size, .zero)
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

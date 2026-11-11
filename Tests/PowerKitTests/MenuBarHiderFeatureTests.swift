import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The Menu Bar Hider section of Beta Features drives the settings and the arrangement the way a click and a drag would. No
/// drag is run: a drop is the call the table's drop handler makes.
final class MenuBarHiderFeatureTests: XCTestCase {

    private typealias Fakes = MenuBarHiderControllerTests

    private struct Rig {
        let feature: MenuBarHiderFeature
        let settings: Settings
        let defaults: UserDefaults
        let suite: String
    }

    private func item(_ key: String, locked: Bool = false) -> BarItem {
        BarItem(key: key, bundleID: "b", appName: "App", title: key, frame: CGRect(x: 100, y: 0, width: 24, height: 37),
                isLocked: locked, hasPress: true, pid: 100)
    }

    private var items: [BarItem] {
        [item("op|1Password"), item("wg|WireGuard"), item("cc|Wi-Fi"), item("cc|Sound"), item("cc|Clock", locked: true)]
    }

    private func rig(trusted: Bool = true, captured: Bool = true, items: [BarItem]? = nil) throws -> Rig {
        let (defaults, suite) = try TestDefaults.make(owner: "MenuBarHiderUI", test: name)
        let settings = Settings(defaults: defaults)
        let list = items ?? self.items
        let feature = MenuBarHiderFeature(settings: settings, items: { list }, accessibilityAllowed: { trusted },
                                          screenRecordingAllowed: { captured }, status: { nil })
        _ = feature.makeView()
        return Rig(feature: feature, settings: settings, defaults: defaults, suite: suite)
    }

    private func done(_ r: Rig) { TestDefaults.destroy(r.defaults, r.suite) }

    func testRowsSplitByArrangement() {
        let a = BarArrangement(pinned: ["cc|Wi-Fi", "cc|Sound"], pillOrder: ["wg|WireGuard", "op|1Password"])
        let rows = MenuBarHiderFeature.rows(for: a, items: items)
        XCTAssertEqual(rows.onBar.map(\.key), ["cc|Wi-Fi", "cc|Sound", "cc|Clock"])
        XCTAssertEqual(rows.behind.map(\.key), ["wg|WireGuard", "op|1Password"])
    }

    func testLockedItemsShownOnBarAndNotDraggable() throws {
        let r = try rig(); defer { done(r) }
        XCTAssertTrue(r.feature.onBarKeys.contains("cc|Clock"))
        XCTAssertFalse(r.feature.isDraggable(key: "cc|Clock"))
        XCTAssertTrue(r.feature.isDraggable(key: "op|1Password"))
        r.feature.handleDrop(key: "cc|Clock", to: .behindChevron, at: 0)
        XCTAssertTrue(r.feature.onBarKeys.contains("cc|Clock"))
    }

    func testDropMovesItemAndStores() throws {
        let r = try rig(); defer { done(r) }
        r.settings.menuBarHiderArrangement = BarArrangement(pinned: ["cc|Wi-Fi", "cc|Sound"], pillOrder: ["op|1Password", "wg|WireGuard"])
        r.feature.refresh()
        r.feature.handleDrop(key: "cc|Sound", to: .behindChevron, at: 1)
        let stored = r.settings.menuBarHiderArrangement
        XCTAssertEqual(stored?.pinned, ["cc|Wi-Fi"])
        XCTAssertEqual(Array((stored?.pillOrder ?? []).prefix(3)), ["op|1Password", "cc|Sound", "wg|WireGuard"])
        XCTAssertEqual(r.feature.behindKeys, ["op|1Password", "cc|Sound", "wg|WireGuard"])
        // Back to the bar: dropped between the pinned items, the table row counting the locked clock too.
        r.feature.handleDrop(key: "cc|Sound", to: .onBar, at: 0)
        XCTAssertEqual(r.settings.menuBarHiderArrangement?.pinned, ["cc|Sound", "cc|Wi-Fi"])
    }

    func testDropOfUnknownKeyIsIgnored() throws {
        let r = try rig(); defer { done(r) }
        r.settings.menuBarHiderArrangement = BarArrangement(pinned: ["cc|Wi-Fi"], pillOrder: [])
        r.feature.handleDrop(key: "never|seen", to: .onBar, at: 0)
        XCTAssertEqual(r.settings.menuBarHiderArrangement, BarArrangement(pinned: ["cc|Wi-Fi"], pillOrder: []))
    }

    /// Anode's own chevron is in the Accessibility read; the controller leaves its own items out, so it is never offered.
    func testChevronIsNotListed() throws {
        let (defaults, suite) = try TestDefaults.make(owner: "MenuBarHiderUI", test: name)
        defer { TestDefaults.destroy(defaults, suite) }
        let settings = Settings(defaults: defaults)
        settings.menuBarHiderEnabled = true
        let reader = Fakes.FakeReader()
        reader.fallback = items + [item("dev.anode.app|AnodeHiderChevron")].map { var i = $0; i.pid = 777; return i }
        let controller = MenuBarHiderController(
            settings: settings, reader: reader, covers: Fakes.FakeCovers(), pill: Fakes.FakePill(), chevron: Fakes.FakeChevron(),
            widgets: Fakes.FakeWidgets(),
            environment: { HiderEnvironment(trusted: true, fullScreen: false, secondsSinceChange: 60,
                                            screen: CGRect(x: 0, y: 0, width: 1800, height: 1169), notch: nil, menuBarHeight: 37) },
            ownPID: 777, log: { _ in }, schedule: { delay, work in if delay < 0.9 { work() } })
        defer { controller.shutdown() }
        controller.reevaluate()
        let feature = MenuBarHiderFeature(settings: settings, items: { controller.allItems }, accessibilityAllowed: { true },
                                          screenRecordingAllowed: { true }, status: { nil })
        _ = feature.makeView()
        XCTAssertFalse((feature.onBarKeys + feature.behindKeys).contains { $0.contains("AnodeHiderChevron") })
        XCTAssertTrue((feature.onBarKeys + feature.behindKeys).contains("op|1Password"))
    }

    func testEnableCheckboxWritesSetting() throws {
        let r = try rig(); defer { done(r) }
        XCTAssertEqual(r.feature.enableCheckbox.state, .off)
        r.feature.enableCheckbox.performClick(nil)
        XCTAssertTrue(r.settings.menuBarHiderEnabled)
        r.feature.enableCheckbox.performClick(nil)
        XCTAssertFalse(r.settings.menuBarHiderEnabled)
    }

    func testAutoClosePopupWritesSetting() throws {
        let r = try rig(); defer { done(r) }
        XCTAssertEqual(r.feature.autoClosePopup.itemTitles, ["5 seconds", "10 seconds", "30 seconds", "Never"])
        XCTAssertEqual(r.feature.autoClosePopup.indexOfSelectedItem, 1)
        r.feature.autoClosePopup.selectItem(at: 3)
        NSApp.sendAction(r.feature.autoClosePopup.action!, to: r.feature.autoClosePopup.target, from: r.feature.autoClosePopup)
        XCTAssertEqual(r.settings.menuBarHiderAutoCloseSeconds, 0)
        r.settings.menuBarHiderAutoCloseSeconds = 30
        r.feature.refresh()
        XCTAssertEqual(r.feature.autoClosePopup.indexOfSelectedItem, 2)
    }

    func testStatusNamesMissingAccessibility() throws {
        let r = try rig(trusted: false, captured: false); defer { done(r) }
        r.settings.menuBarHiderEnabled = true
        r.feature.refresh()
        XCTAssertTrue(r.feature.statusLabel.stringValue.contains("Accessibility"))
        XCTAssertFalse(r.feature.accessibilityButton.isHidden)
        XCTAssertFalse(r.feature.screenRecordingButton.isHidden)
        let ok = try rig(); defer { done(ok) }
        ok.settings.menuBarHiderEnabled = true
        ok.feature.refresh()
        XCTAssertTrue(ok.feature.accessibilityButton.isHidden)
        XCTAssertTrue(ok.feature.screenRecordingButton.isHidden)
    }

    /// The section follows the settings and the controller on its own, without waiting for the window to come forward.
    func testTheSectionRefreshesWhenTheSettingsOrTheControllerChange() throws {
        let r = try rig(); defer { done(r) }
        XCTAssertEqual(r.feature.statusLabel.stringValue, "Off.")
        r.settings.menuBarHiderEnabled = true
        XCTAssertNotEqual(r.feature.statusLabel.stringValue, "Off.")
        XCTAssertEqual(r.feature.enableCheckbox.state, .on)
        r.settings.menuBarHiderAutoCloseSeconds = 30
        XCTAssertEqual(r.feature.autoClosePopup.indexOfSelectedItem, 2)
        r.settings.menuBarHiderEnabled = false
        r.feature.enableCheckbox.state = .on        // stale on screen
        NotificationCenter.default.post(name: MenuBarHiderController.didChange, object: nil)
        XCTAssertEqual(r.feature.enableCheckbox.state, .off)
    }

    func testAParkedChevronIsExplainedInPlainWords() {
        let text = MenuBarHiderFeature.describe(.standDown(.chevronOffBar)) ?? ""
        XCTAssertTrue(text.contains("no room"), text)
        XCTAssertTrue(text.contains("off and on again"), text)
    }

    func testFeatureIsInDefaultList() {
        XCTAssertTrue(BetaFeaturesWindowController.defaultFeatures(hasLidSensor: false).contains { $0 is MenuBarHiderFeature })
    }
}

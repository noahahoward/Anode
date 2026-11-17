import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The Battery menu's behaviour, with macOS's own panel, its icon and the drawn menu faked.
final class BatteryMenuControllerTests: XCTestCase {

    final class FakePresenter: BatteryMenuPresenting {
        var isOpen = false
        var shown: [BatteryMenuModel] = []
        var lastAnchor: CGRect?
        var closeCount = 0
        func show(_ model: BatteryMenuModel, below frame: CGRect) { isOpen = true; lastAnchor = frame; shown.append(model) }
        func update(_ model: BatteryMenuModel) { shown.append(model) }
        func close() { isOpen = false; closeCount += 1 }
    }

    struct Rig {
        let controller: BatteryMenuController
        let driver: SoundMenuControllerTests.FakeDriver, presenter: FakePresenter, native: SoundMenuControllerTests.FakeNative
        let settings: Settings
        let cleanup: () -> Void
    }

    private func node(_ role: String, id: String = "", desc: String = "", value: String = "", sub: String = "", children: [AXNode] = []) -> AXNode {
        AXNode(role: role, subrole: sub, identifier: id, description: desc, value: value, enabled: true, frame: .zero, children: children)
    }

    /// The panel as macOS draws it, with `selected` the Energy Mode in force.
    private func tree(selected: String = "automatic", source: String = "Battery", apps: [String] = []) -> AXNode {
        func mode(_ id: String, _ title: String) -> AXNode {
            node("AXCheckBox", id: "energy-mode-\(id)", desc: title, value: selected == id ? "1" : "0", sub: "AXToggle")
        }
        var kids = [node("AXStaticText", id: "battery-header", value: "Battery"),
                    node("AXStaticText", id: "battery-header", value: "Power Source: \(source)"),
                    node("AXHeading", desc: "Energy Mode"),
                    mode("automatic", "Automatic"), mode("low", "Low Power"), mode("high", "High Power")]
        if !apps.isEmpty { kids.append(node("AXHeading", desc: "Using Significant Energy")); kids += apps.map { node("AXButton", desc: $0) } }
        kids.append(node("AXButton", desc: "Battery Settings…"))
        return node("AXWindow", sub: "AXSystemDialog", children: [node("AXGroup", sub: "AXHostingView", children: kids)])
    }

    private func rig(enabled: Bool = true, trusted: Bool = true, lastReading: Bool = false) throws -> Rig {
        let (defaults, suite) = try TestDefaults.make(owner: "BatteryMenu", test: name)
        let settings = Settings(defaults: defaults)
        settings.batteryMenuEnabled = enabled
        if lastReading { settings.batteryMenuLastReading = try JSONEncoder().encode(AppleBatteryPanel.parse(tree(selected: "low"))) }
        let driver = SoundMenuControllerTests.FakeDriver(), presenter = FakePresenter(), native = SoundMenuControllerTests.FakeNative()
        let c = BatteryMenuController(settings: settings, driver: driver, accessibility: { trusted }, presenter: presenter, native: native,
                                      pollInterval: 0, followUpDelay: 0)
        c.start()
        return Rig(controller: c, driver: driver, presenter: presenter, native: native, settings: settings,
                   cleanup: { c.stop(); TestDefaults.destroy(defaults, suite) })
    }

    // ── Starting and stopping ───────────────────────────────────────────────

    func testNothingRunsWhileTheSettingIsOff() throws {
        let r = try rig(enabled: false); defer { r.cleanup() }
        XCTAssertFalse(r.native.running)
    }

    func testTurningTheSettingOnTakesOverMacOSsIcon_AndOffGivesItBack() throws {
        let r = try rig(enabled: false); defer { r.cleanup() }
        r.settings.batteryMenuEnabled = true
        XCTAssertTrue(r.native.running)
        r.settings.batteryMenuEnabled = false
        XCTAssertFalse(r.native.running)
        XCTAssertGreaterThan(r.presenter.closeCount, 0)
    }

    // ── Opening ─────────────────────────────────────────────────────────────

    func testAClickOnTheIconOpensTheMenuBelowIt_WithWhatWasLastRead() throws {
        let r = try rig(lastReading: true); defer { r.cleanup() }
        let icon = CGRect(x: 1500, y: 8, width: 24, height: 22)
        r.native.onClick?(icon)
        XCTAssertTrue(r.presenter.isOpen)
        XCTAssertEqual(r.presenter.lastAnchor, icon)
        XCTAssertEqual(r.presenter.shown.first?.selectedModeID, "low", "the first picture is the last reading, not a blank")
        XCTAssertEqual(r.driver.jobs.count, 1)
        XCTAssertEqual(r.driver.jobs.first?.0, .battery)
        XCTAssertEqual(r.driver.jobs.first?.1, .read)
    }

    func testWhatMacOSsPanelSaysReplacesTheOldPictureInPlace() throws {
        let r = try rig(lastReading: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.driver.complete(0, .tree(tree(selected: "high", source: "Power Adapter", apps: ["Safari"])))
        let m = try XCTUnwrap(r.presenter.shown.last)
        XCTAssertEqual(m.selectedModeID, "high")
        XCTAssertEqual(m.powerSource, "Power Adapter")
        XCTAssertEqual(m.energyApps, [.init(name: "Safari")])
        XCTAssertEqual(r.presenter.shown.count, 2, "one opening, one correction")
    }

    func testWithNothingReadYetTheMenuOpensWhenTheFirstReadingArrives() throws {
        let r = try rig(); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        XCTAssertFalse(r.presenter.isOpen, "a blank panel is never drawn")
        r.driver.complete(0, .tree(tree(selected: "low")))
        XCTAssertTrue(r.presenter.isOpen)
        XCTAssertEqual(r.presenter.shown.first?.selectedModeID, "low")
    }

    func testAClickThatClosesTheMenuBeforeTheFirstReadingArrivesLeavesItClosed() throws {
        let r = try rig(); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.native.onClick?(r.native.frame!)
        r.driver.complete(0, .tree(tree()))
        XCTAssertFalse(r.presenter.isOpen)
    }

    func testAReadThatFailsWithNothingKnownShowsNothing() throws {
        let r = try rig(); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.driver.complete(0, .failed(.panelDidNotOpen))
        XCTAssertFalse(r.presenter.isOpen)
    }

    func testAnotherClickClosesTheOpenMenu() throws {
        let r = try rig(lastReading: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.native.onClick?(r.native.frame!)
        XCTAssertFalse(r.presenter.isOpen)
    }

    func testWithoutAccessibilityNothingOpens() throws {
        let r = try rig(trusted: false, lastReading: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        XCTAssertFalse(r.presenter.isOpen)
        XCTAssertTrue(r.driver.jobs.isEmpty)
    }

    func testTheLastReadingIsKeptForTheNextFirstClick() throws {
        let r = try rig(); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.driver.complete(0, .tree(tree(selected: "high")))
        let kept = try XCTUnwrap(r.settings.batteryMenuLastReading)
        XCTAssertEqual(try JSONDecoder().decode(AppleBatteryPanel.self, from: kept).modes.first { $0.isSelected }?.id, "high")
    }

    func testATreeThatIsNotTheBatteryPanelIsNotKept() throws {
        let r = try rig(lastReading: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.driver.complete(0, .tree(node("AXWindow")))
        XCTAssertEqual(r.presenter.shown.last?.selectedModeID, "low", "what was known stays")
    }

    // ── Pressing ────────────────────────────────────────────────────────────

    func testPickingAModePressesMacOSsRowAndMovesTheCheckAtOnce() throws {
        let r = try rig(lastReading: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.driver.complete(0, .tree(tree(selected: "low")))
        r.controller.pickMode("high")
        XCTAssertEqual(r.presenter.shown.last?.selectedModeID, "high")
        XCTAssertEqual(r.driver.jobs.last?.0, .battery)
        XCTAssertEqual(r.driver.jobs.last?.1, .press(SystemPanelRow(identifier: "energy-mode-high", description: "High Power")))
    }

    func testPickingTheModeAlreadyInForceDoesNothing() throws {
        let r = try rig(lastReading: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.driver.complete(0, .tree(tree(selected: "low")))
        r.controller.pickMode("low")
        XCTAssertEqual(r.driver.jobs.count, 1, "only the read")
    }

    func testARefusedPressPutsTheCheckBack() throws {
        let r = try rig(lastReading: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.driver.complete(0, .tree(tree(selected: "low")))
        r.controller.pickMode("high")
        r.driver.complete(1, .refused("Can't change"))
        XCTAssertEqual(r.presenter.shown.last?.selectedModeID, "low")
    }

    func testAFailedPressPutsTheCheckBack() throws {
        let r = try rig(lastReading: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.driver.complete(0, .tree(tree(selected: "low")))
        r.controller.pickMode("high")
        r.driver.complete(1, .failed(.rowNotFound))
        XCTAssertEqual(r.presenter.shown.last?.selectedModeID, "low")
    }

    func testAfterAPressTheMenuReadsHowItEnded() throws {
        let r = try rig(lastReading: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.driver.complete(0, .tree(tree(selected: "low")))
        r.controller.pickMode("high")
        r.driver.complete(1, .pressed)
        XCTAssertEqual(r.driver.jobs.last?.1, .read)
        r.driver.complete(2, .tree(tree(selected: "high")))
        XCTAssertEqual(r.presenter.shown.last?.selectedModeID, "high")
    }

    func testAReadingThatWasAskedForBeforeAPressDoesNotUndoIt() throws {
        let r = try rig(lastReading: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)             // read 0 in flight
        r.controller.pickMode("high")                  // press 1 queued behind it
        r.driver.complete(0, .tree(tree(selected: "low")))
        XCTAssertEqual(r.presenter.shown.last?.selectedModeID, "high", "the reading is from before the press")
    }

    // ── Closing ─────────────────────────────────────────────────────────────

    func testBatterySettingsOpensTheSettingsPaneAndClosesTheMenu() throws {
        let r = try rig(lastReading: true); defer { r.cleanup() }
        var opened: URL?
        r.controller.openURL = { opened = $0 }
        r.native.onClick?(r.native.frame!)
        r.controller.pressSettings()
        XCTAssertEqual(opened?.absoluteString, "x-apple.systempreferences:com.apple.Battery-Settings.extension")
        XCTAssertFalse(r.presenter.isOpen)
    }
}

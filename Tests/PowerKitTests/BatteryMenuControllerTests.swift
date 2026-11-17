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

    final class FakeUltra: UltraModeControlling {
        var isOn = false
        var isOff: Bool { !isOn }
        var calls: [String] = []
        var onCall: ((String) -> Void)?
        var listeners: [() -> Void] = []
        func request() { calls.append("request"); onCall?("request") }
        func turnOff() { calls.append("turnOff"); onCall?("turnOff") }
        func observe(_ changed: @escaping () -> Void) -> AnyObject { listeners.append(changed); return NSObject() }
        /// The mode went on or off by itself, or finished putting things back.
        func set(on: Bool) { isOn = on; listeners.forEach { $0() } }
    }

    struct Rig {
        let controller: BatteryMenuController
        let driver: SoundMenuControllerTests.FakeDriver, presenter: FakePresenter, native: SoundMenuControllerTests.FakeNative
        let settings: Settings
        var ultra: FakeUltra?
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

    private func rig(enabled: Bool = true, trusted: Bool = true, lastReading: Bool = false, openBeta: @escaping () -> Void = {},
                     ultra: FakeUltra? = nil, ultraEnabled: Bool = false) throws -> Rig {
        let (defaults, suite) = try TestDefaults.make(owner: "BatteryMenu", test: name)
        let settings = Settings(defaults: defaults)
        settings.batteryMenuEnabled = enabled
        settings.ultraLowPowerEnabled = ultraEnabled
        if lastReading { settings.batteryMenuLastReading = try JSONEncoder().encode(AppleBatteryPanel.parse(tree(selected: "low"))) }
        let driver = SoundMenuControllerTests.FakeDriver(), presenter = FakePresenter(), native = SoundMenuControllerTests.FakeNative()
        let c = BatteryMenuController(settings: settings, driver: driver, accessibility: { trusted }, presenter: presenter, native: native,
                                      pollInterval: 0, followUpDelay: 0, openBetaFeatures: openBeta, ultra: ultra)
        c.start()
        return Rig(controller: c, driver: driver, presenter: presenter, native: native, settings: settings, ultra: ultra,
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

    // ── The gear ────────────────────────────────────────────────────────────

    func testTheMenuShowsTheGear() throws {
        let r = try rig(lastReading: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        XCTAssertEqual(r.presenter.shown.first?.showsGear, true)
    }

    func testThePressOfTheGearClosesTheMenuAndOpensBetaFeatures() throws {
        var opened = 0
        let r = try rig(lastReading: true, openBeta: { opened += 1 }); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.controller.pressGear()
        XCTAssertEqual(opened, 1)
        XCTAssertFalse(r.presenter.isOpen)
    }

    // ── Ultra Low Power as a fourth Energy Mode ─────────────────────────────

    func testTheRowIsNotThereWhileTheFeatureIsOff() throws {
        let r = try rig(lastReading: true, ultra: FakeUltra(), ultraEnabled: false); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        XCTAssertEqual(r.presenter.shown.first?.modes.map(\.id), ["automatic", "low", "high"])
    }

    func testTheRowComesBelowHighPowerWhileTheFeatureIsOn_AndIsNotChecked() throws {
        let r = try rig(lastReading: true, ultra: FakeUltra(), ultraEnabled: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        let m = try XCTUnwrap(r.presenter.shown.first)
        XCTAssertEqual(m.modes.map(\.id), ["automatic", "low", "high", "ultra"])
        XCTAssertEqual(m.modes.last?.title, "Ultra Low Power")
        XCTAssertEqual(m.selectedModeID, "low", "macOS's own mode is the one checked")
    }

    func testWhileTheModeRunsOnlyItsRowIsChecked() throws {
        let ultra = FakeUltra(); ultra.isOn = true
        let r = try rig(lastReading: true, ultra: ultra, ultraEnabled: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.driver.complete(0, .tree(tree(selected: "low")))   // macOS reads Low Power: the mode has switched it on underneath
        XCTAssertEqual(r.presenter.shown.last?.selectedModeID, "ultra")
        XCTAssertEqual(r.presenter.shown.last?.modes.filter(\.isSelected).count, 1)
    }

    func testChoosingTheRowClosesTheMenuAndThenAsks() throws {
        let ultra = FakeUltra()
        let r = try rig(lastReading: true, ultra: ultra, ultraEnabled: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        var menuOpenWhenAsked: Bool?
        ultra.onCall = { _ in menuOpenWhenAsked = r.presenter.isOpen }
        r.controller.pickMode("ultra")
        XCTAssertEqual(ultra.calls, ["request"])
        XCTAssertEqual(menuOpenWhenAsked, false, "the box opens above where the menu was, so the menu goes first")
        XCTAssertEqual(r.driver.jobs.count, 1, "nothing is pressed in macOS's panel (only the reading)")
    }

    func testTheCheckDoesNotMoveUntilTheModeIsOn_ADeclinedBoxChangesNothing() throws {
        let ultra = FakeUltra()
        let r = try rig(lastReading: true, ultra: ultra, ultraEnabled: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.controller.pickMode("ultra")      // asks; the person says No: the mode stays off
        XCTAssertEqual(r.controller.model?.selectedModeID, "low")
        ultra.set(on: true)
        XCTAssertEqual(r.controller.model?.selectedModeID, "ultra")
    }

    func testChoosingTheRowWhileItRunsDoesNothing() throws {
        let ultra = FakeUltra(); ultra.isOn = true
        let r = try rig(lastReading: true, ultra: ultra, ultraEnabled: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.controller.pickMode("ultra")
        XCTAssertTrue(ultra.calls.isEmpty)
    }

    func testChoosingAnotherModeWhileItRunsEndsItFirstAndPressesWhenItHasPutThingsBack() throws {
        let ultra = FakeUltra(); ultra.isOn = true
        let r = try rig(lastReading: true, ultra: ultra, ultraEnabled: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.driver.complete(0, .tree(tree(selected: "low")))
        r.controller.pickMode("high")
        XCTAssertEqual(ultra.calls, ["turnOff"])
        XCTAssertEqual(r.driver.jobs.count, 1, "not pressed yet: the mode is still putting things back")
        XCTAssertEqual(r.presenter.shown.last?.selectedModeID, "high", "the row shows the new choice as soon as it is clicked")
        ultra.set(on: false)
        XCTAssertEqual(r.driver.jobs.last?.1, .press(SystemPanelRow(identifier: "energy-mode-high", description: "High Power")))
    }

    func testAChoiceWaitsForTheModeToBeOffWhateverElseChanges() throws {
        let ultra = FakeUltra(); ultra.isOn = true
        let r = try rig(lastReading: true, ultra: ultra, ultraEnabled: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.driver.complete(0, .tree(tree(selected: "low")))
        r.controller.pickMode("automatic")
        ultra.listeners.forEach { $0() }    // something else of the mode changed: it is still on
        XCTAssertEqual(r.driver.jobs.count, 1)
        ultra.set(on: false)
        XCTAssertEqual(r.driver.jobs.count, 2)
    }
}

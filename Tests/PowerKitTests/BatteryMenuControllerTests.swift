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
        /// Whether each close faded, in order.
        var fades: [Bool] = []
        func show(_ model: BatteryMenuModel, below frame: CGRect) { isOpen = true; lastAnchor = frame; shown.append(model) }
        func update(_ model: BatteryMenuModel) { shown.append(model) }
        func close(fade: Bool) { isOpen = false; closeCount += 1; fades.append(fade) }
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

    final class FakeCharge: ChargeLimiting {
        var limit = 80
        var softDrainRunning = false
        var hardDrainRunning = false
        var canHardDrain = true
        var topUpRunning = false
        var canTopUp = true
        var calls: [String] = []
        var listeners: [() -> Void] = []
        let range = 20...100
        func setLimit(_ v: Int) { calls.append("limit \(v)"); limit = v; listeners.forEach { $0() } }
        func pressSoftDrain() { calls.append("soft"); softDrainRunning.toggle(); listeners.forEach { $0() } }
        func pressHardDrain() { calls.append("hard"); hardDrainRunning.toggle(); listeners.forEach { $0() } }
        func pressTopUp() { calls.append("topUp"); topUpRunning.toggle(); listeners.forEach { $0() } }
        func observe(_ changed: @escaping () -> Void) -> AnyObject { listeners.append(changed); return NSObject() }
    }

    final class FakePrompt: HardDrainPrompting {
        var asked = 0, explained = 0
        var answer: ((Bool) -> Void)?
        var menuOpenWhenAsked: (() -> Bool)?
        var sawMenuOpen: Bool?
        func ask(_ done: @escaping (Bool) -> Void) { asked += 1; sawMenuOpen = menuOpenWhenAsked?(); answer = done }
        func explainBlocked() { explained += 1 }
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
                     ultra: FakeUltra? = nil, ultraEnabled: Bool = false,
                     charge: FakeCharge? = nil, chargeEnabled: Bool = false, prompt: FakePrompt? = nil,
                     apps: @escaping () -> [SignificantEnergy.Candidate] = { [] }, opened: @escaping (Bool) -> Void = { _ in }, afterPressRead: TimeInterval = 0) throws -> Rig {
        let (defaults, suite) = try TestDefaults.make(owner: "BatteryMenu", test: name)
        let settings = Settings(defaults: defaults)
        settings.batteryMenuEnabled = enabled
        settings.ultraLowPowerEnabled = ultraEnabled
        settings.chargeControlEnabled = chargeEnabled
        if lastReading { settings.batteryMenuLastReading = try JSONEncoder().encode(AppleBatteryPanel.parse(tree(selected: "low"))) }
        let driver = SoundMenuControllerTests.FakeDriver(), presenter = FakePresenter(), native = SoundMenuControllerTests.FakeNative()
        let c = BatteryMenuController(settings: settings, driver: driver, accessibility: { trusted }, presenter: presenter, native: native,
                                      pollInterval: 0, followUpDelay: 0, openBetaFeatures: openBeta, ultra: ultra, charge: charge, hardDrainPrompt: prompt,
                                      energyApps: apps, onOpenChanged: opened, afterPressReadDelay: afterPressRead)
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
        XCTAssertTrue(m.energyApps.isEmpty, "the apps are Anode's own list, not what macOS's panel says")
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

    // macOS fades a panel out when it is closed, but not when another icon's panel takes its place: that is one frame.
    func testAMenuClosesWithAFadeUnlessItIsToldTheOtherOneIsTakingItsPlace() throws {
        let r = try rig(lastReading: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!); r.controller.closeMenu()
        r.native.onClick?(r.native.frame!); r.controller.closeMenu(fade: false)
        XCTAssertEqual(r.presenter.fades, [true, false])
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

    // ── The charge limit ────────────────────────────────────────────────────

    func testTheChargeRowIsNotThereWhileChargeControlIsOff() throws {
        let r = try rig(lastReading: true, charge: FakeCharge(), chargeEnabled: false); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        XCTAssertNil(r.presenter.shown.first?.chargeLimit)
    }

    func testTheChargeRowShowsTheLimitAndWhatIsDraining() throws {
        let charge = FakeCharge(); charge.limit = 75; charge.softDrainRunning = true
        let r = try rig(lastReading: true, charge: charge, chargeEnabled: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        let c = try XCTUnwrap(r.presenter.shown.first?.chargeLimit)
        XCTAssertEqual(c.limit, 75); XCTAssertEqual(c.range, 20...100)
        XCTAssertTrue(c.softDrainRunning); XCTAssertFalse(c.hardDrainRunning)
    }

    func testTheLimitIsWrittenOnlyWhenTheSliderIsLetGo() throws {
        let charge = FakeCharge()
        let r = try rig(lastReading: true, charge: charge, chargeEnabled: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.controller.commitChargeLimit(60)
        XCTAssertEqual(charge.calls, ["limit 60"])
        XCTAssertEqual(r.presenter.shown.last?.chargeLimit?.limit, 60)
    }

    func testTheLimitStaysInTheRange() throws {
        let charge = FakeCharge()
        let r = try rig(lastReading: true, charge: charge, chargeEnabled: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.controller.commitChargeLimit(5); r.controller.commitChargeLimit(250)
        XCTAssertEqual(charge.calls, ["limit 20", "limit 100"])
    }

    func testAPressOfMinusStartsSoftDrain_AndAnotherStopsIt() throws {
        let charge = FakeCharge()
        let r = try rig(lastReading: true, charge: charge, chargeEnabled: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.controller.pressMinus()
        XCTAssertEqual(charge.calls, ["soft"])
        XCTAssertEqual(r.presenter.shown.last?.chargeLimit?.softDrainRunning, true)
        r.controller.pressMinus()
        XCTAssertEqual(charge.calls, ["soft", "soft"])
    }

    // Top Up is Charge to Full: to 100% this once, until unplugged. It needs the charger, and a press of it again cancels.
    func testAPressOfTopUpStartsChargeToFull_AndAnotherCancelsIt() throws {
        let charge = FakeCharge()
        let r = try rig(lastReading: true, charge: charge, chargeEnabled: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.controller.pressTopUp()
        XCTAssertEqual(charge.calls, ["topUp"])
        XCTAssertEqual(r.presenter.shown.last?.chargeLimit?.topUpRunning, true)
        r.controller.pressTopUp()
        XCTAssertEqual(charge.calls, ["topUp", "topUp"])
        XCTAssertEqual(r.presenter.shown.last?.chargeLimit?.topUpRunning, false)
    }

    func testTopUpWithNoChargerDoesNothing_ButIsShownAsUnavailable() throws {
        let charge = FakeCharge(); charge.canTopUp = false
        let r = try rig(lastReading: true, charge: charge, chargeEnabled: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        XCTAssertEqual(r.presenter.shown.last?.chargeLimit?.canTopUp, false)
        r.controller.pressTopUp()
        XCTAssertTrue(charge.calls.isEmpty)
    }

    func testARunningTopUpCanAlwaysBeCancelled() throws {
        let charge = FakeCharge(); charge.canTopUp = false; charge.topUpRunning = true
        let r = try rig(lastReading: true, charge: charge, chargeEnabled: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.controller.pressTopUp()
        XCTAssertEqual(charge.calls, ["topUp"])
    }

    func testTopUpDoesNothingWhileChargeControlIsOff() throws {
        let charge = FakeCharge()
        let r = try rig(lastReading: true, charge: charge, chargeEnabled: false); defer { r.cleanup() }
        r.controller.pressTopUp()
        XCTAssertTrue(charge.calls.isEmpty)
    }

    func testAPressOfMinusWhileHardDrainRunsStopsHardDrain() throws {
        let charge = FakeCharge(); charge.hardDrainRunning = true
        let r = try rig(lastReading: true, charge: charge, chargeEnabled: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.controller.pressMinus()
        XCTAssertEqual(charge.calls, ["hard"])
    }

    func testHoldingMinusAsksAfterClosingTheMenu_AndYesRunsHardDrain() throws {
        let charge = FakeCharge(); let prompt = FakePrompt()
        let r = try rig(lastReading: true, charge: charge, chargeEnabled: true, prompt: prompt); defer { r.cleanup() }
        prompt.menuOpenWhenAsked = { r.presenter.isOpen }
        r.native.onClick?(r.native.frame!)
        r.controller.holdMinus()
        XCTAssertEqual(prompt.asked, 1)
        XCTAssertEqual(prompt.sawMenuOpen, false, "the box would open behind the menu")
        XCTAssertTrue(charge.calls.isEmpty, "nothing runs until Yes")
        prompt.answer?(true)
        XCTAssertEqual(charge.calls, ["hard"])
    }

    func testNoToTheBoxRunsNothing() throws {
        let charge = FakeCharge(); let prompt = FakePrompt()
        let r = try rig(lastReading: true, charge: charge, chargeEnabled: true, prompt: prompt); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.controller.holdMinus()
        prompt.answer?(false)
        XCTAssertTrue(charge.calls.isEmpty)
    }

    func testWhenHardDrainCannotRunTheBoxExplainsInsteadOfAsking() throws {
        let charge = FakeCharge(); charge.canHardDrain = false; let prompt = FakePrompt()
        let r = try rig(lastReading: true, charge: charge, chargeEnabled: true, prompt: prompt); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.controller.holdMinus()
        XCTAssertEqual(prompt.asked, 0); XCTAssertEqual(prompt.explained, 1)
    }

    func testAChangeOfTheLimitElsewhereIsShownInTheOpenMenu() throws {
        let charge = FakeCharge()
        let r = try rig(lastReading: true, charge: charge, chargeEnabled: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        charge.limit = 90; charge.listeners.forEach { $0() }
        XCTAssertEqual(r.presenter.shown.last?.chargeLimit?.limit, 90)
    }

    // ── Anode's figures beside each app ─────────────────────────────────────

    private func candidate(_ name: String, _ pct: Double, isApp: Bool = true) -> SignificantEnergy.Candidate {
        .init(name: name, isApp: isApp, stats: EnergyStats(pctPerHour: pct, cpuPercent: 4.1, memoryBytes: 1, minutesBack: nil))
    }

    func testTheAppsListedAreTheOnesAnodeMeasuresAboveTheMinimum_WhateverMacOSsPanelSays() throws {
        let r = try rig(lastReading: true, apps: { [self.candidate("Safari", 0.9), self.candidate("Quiet", 0.03), self.candidate("kernel_task", 5, isApp: false)] })
        defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.driver.complete(0, .tree(tree(selected: "low", apps: ["Quiet", "Something macOS Lists"])))
        let apps = try XCTUnwrap(r.presenter.shown.last?.energyApps)
        XCTAssertEqual(apps.map(\.name), ["Safari"])
        XCTAssertEqual(apps.first?.stats?.pctPerHour, 0.9)
    }

    func testTheFirstPictureAlreadyHasTheList() throws {
        let r = try rig(lastReading: true, apps: { [self.candidate("Safari", 0.9)] }); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        XCTAssertEqual(r.presenter.shown.first?.energyApps.map(\.name), ["Safari"], "before macOS's panel has been read")
    }

    func testTheListFollowsAnodesMeasurementsWhileTheMenuIsOpen() throws {
        var current = [candidate("Safari", 0.9)]
        let r = try rig(lastReading: true, apps: { current }); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        current = [candidate("Safari", 0.9), candidate("Mail", 2.0)]
        r.controller.refreshEnergyStats()
        XCTAssertEqual(r.presenter.shown.last?.energyApps.map(\.name), ["Mail", "Safari"])
        current = [candidate("Mail", 2.4), candidate("Safari", 0.4)]   // under the minimum, over what a listed row keeps
        r.controller.refreshEnergyStats()
        XCTAssertEqual(r.presenter.shown.last?.energyApps.map(\.name), ["Mail", "Safari"], "an app at the line does not flicker out")
        current = [candidate("Mail", 2.4), candidate("Safari", 0.2)]
        r.controller.refreshEnergyStats()
        XCTAssertEqual(r.presenter.shown.last?.energyApps.map(\.name), ["Mail"])
    }

    func testARowNeedsTheFullMinimumAgainOnTheNextOpening() throws {
        var current = [candidate("Safari", 0.9)]
        let r = try rig(lastReading: true, apps: { current }); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)          // opens: Safari listed
        r.native.onClick?(r.native.frame!)          // closes
        current = [candidate("Safari", 0.4)]
        r.native.onClick?(r.native.frame!)          // opens again
        XCTAssertTrue(r.presenter.shown.last?.energyApps.isEmpty ?? false)
    }

    func testTheMenuTellsTheAppWhileItIsOpenSoTheFiguresAreFresh() throws {
        var told: [Bool] = []
        let r = try rig(lastReading: true, opened: { told.append($0) }); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.native.onClick?(r.native.frame!)
        XCTAssertEqual(told, [true, false])
    }

    func testNothingIsDrawnForAMeasurementWhileTheMenuIsClosed() throws {
        let r = try rig(lastReading: true, apps: { [self.candidate("Safari", 0.9)] }); defer { r.cleanup() }
        r.controller.refreshEnergyStats()
        XCTAssertTrue(r.presenter.shown.isEmpty)
    }

    // ── Only one of the two menus at a time ─────────────────────────────────

    func testOpeningTheMenuTellsTheOtherToClose() throws {
        let r = try rig(lastReading: true); defer { r.cleanup() }
        var told = 0
        r.controller.onWillOpen = { told += 1 }
        r.native.onClick?(r.native.frame!)
        XCTAssertEqual(told, 1)
        r.native.onClick?(r.native.frame!)   // closes: no word
        XCTAssertEqual(told, 1)
    }

    func testTheWordIsGivenEvenWhileWaitingForTheFirstReading() throws {
        let r = try rig(); defer { r.cleanup() }
        var told = 0
        r.controller.onWillOpen = { told += 1 }
        r.native.onClick?(r.native.frame!)
        XCTAssertEqual(told, 1)
    }

    func testOpeningTheMenuClosesAPanelOfMacOSThePersonHadOpen() throws {
        let r = try rig(lastReading: true); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        XCTAssertEqual(r.driver.closedPanelsOfThePerson, 1)
    }

    func testTheReadAfterAPressWaitsForTheBadgeToFinishTurning() throws {
        let r = try rig(lastReading: true, afterPressRead: 0.05); defer { r.cleanup() }
        r.native.onClick?(r.native.frame!)
        r.driver.complete(0, .tree(tree(selected: "low")))
        r.controller.pickMode("high")
        r.driver.complete(1, .pressed)
        XCTAssertEqual(r.driver.jobs.count, 2, "not at once")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(r.driver.jobs.count, 3)
        XCTAssertEqual(r.driver.jobs.last?.1, .read)
    }
}

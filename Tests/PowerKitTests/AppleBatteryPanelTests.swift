import XCTest
@testable import PowerKit

/// Apple's Battery panel, read through Accessibility, turned into rows. The fixture is the tree measured on macOS 27 (14" MacBook Pro,
/// High Power selected, Visual Studio Code using significant energy).
final class AppleBatteryPanelTests: XCTestCase {

    private func node(_ role: String, id: String = "", desc: String = "", value: String = "", sub: String = "", children: [AXNode] = []) -> AXNode {
        AXNode(role: role, subrole: sub, identifier: id, description: desc, value: value, enabled: true, frame: .zero, children: children)
    }
    private func mode(_ id: String, _ title: String, on: Bool) -> AXNode {
        node("AXCheckBox", id: "energy-mode-\(id)", desc: title, value: on ? "1" : "0", sub: "AXToggle")
    }

    private func tree(source: String = "Battery", selected: String = "high", apps: [String] = ["Visual Studio Code"]) -> AXNode {
        var kids: [AXNode] = [
            node("AXStaticText", id: "battery-header", value: "Battery"),
            node("AXStaticText", id: "battery-header", value: "Power Source: \(source)"),
            node("AXHeading", desc: "Energy Mode"),
            mode("automatic", "Automatic", on: selected == "automatic"),
            mode("low", "Low Power", on: selected == "low"),
            mode("high", "High Power", on: selected == "high"),
        ]
        if !apps.isEmpty {
            kids.append(node("AXHeading", desc: "Using Significant Energy"))
            kids += apps.map { node("AXButton", desc: $0) }
        }
        kids.append(node("AXButton", desc: "Battery Settings…"))
        return node("AXWindow", sub: "AXSystemDialog", children: [node("AXGroup", sub: "AXHostingView", children: kids)])
    }

    func testTheMeasuredTreeGivesItsRows() {
        let p = AppleBatteryPanel.parse(tree())
        XCTAssertEqual(p.powerSource, "Battery")
        XCTAssertEqual(p.modes, [.init(id: "automatic", title: "Automatic", isSelected: false),
                                 .init(id: "low", title: "Low Power", isSelected: false),
                                 .init(id: "high", title: "High Power", isSelected: true)])
        XCTAssertEqual(p.energyApps, ["Visual Studio Code"])
        XCTAssertEqual(p.settingsTitle, "Battery Settings…")
        XCTAssertTrue(p.looksLikeTheBatteryPanel)
    }

    func testThePowerSourceIsWhateverFollowsTheColon() {
        XCTAssertEqual(AppleBatteryPanel.parse(tree(source: "Power Adapter")).powerSource, "Power Adapter")
    }

    func testNoAppUsingSignificantEnergyGivesNoApps() {
        XCTAssertEqual(AppleBatteryPanel.parse(tree(apps: [])).energyApps, [])
    }

    func testSeveralAppsComeInTheOrderListed_AndTheSettingsButtonIsNotOne() {
        XCTAssertEqual(AppleBatteryPanel.parse(tree(apps: ["A", "B", "C"])).energyApps, ["A", "B", "C"])
    }

    func testATreeThatIsNotTheBatteryPanelGivesNothing() {
        let other = node("AXWindow", children: [node("AXButton", desc: "Volume Lower"), node("AXHeading", desc: "Output")])
        let p = AppleBatteryPanel.parse(other)
        XCTAssertFalse(p.looksLikeTheBatteryPanel)
        XCTAssertTrue(p.modes.isEmpty); XCTAssertTrue(p.energyApps.isEmpty)
    }

    func testTheReadingBecomesTheMenuModel() {
        let m = BatteryMenuModel(apple: AppleBatteryPanel.parse(tree(selected: "low", apps: ["X"])))
        XCTAssertEqual(m.powerSource, "Battery")
        XCTAssertEqual(m.selectedModeID, "low")
        XCTAssertEqual(m.energyApps.map(\.name), ["X"])
    }

    func testTheReadingSurvivesBeingSavedAndLoaded() throws {
        let p = AppleBatteryPanel.parse(tree())
        XCTAssertEqual(try JSONDecoder().decode(AppleBatteryPanel.self, from: JSONEncoder().encode(p)), p)
    }

    // On the charger macOS adds a line under the power source (measured: "1h 51m until fully charged", another static text with the same id).
    func testALineUnderThePowerSourceIsKept() {
        var t = tree(source: "Power Adapter")
        var kids = t.children[0].children
        kids.insert(node("AXStaticText", id: "battery-header", value: "1h 51m until fully charged"), at: 2)
        t = node("AXWindow", sub: "AXSystemDialog", children: [node("AXGroup", sub: "AXHostingView", children: kids)])
        let p = AppleBatteryPanel.parse(t)
        XCTAssertEqual(p.powerSource, "Power Adapter")
        XCTAssertEqual(p.statusLine, "1h 51m until fully charged")
        XCTAssertEqual(BatteryMenuModel(apple: p).statusLine, "1h 51m until fully charged")
    }

    func testOnBatteryThereIsNoSuchLine() {
        XCTAssertNil(AppleBatteryPanel.parse(tree()).statusLine)
    }
}


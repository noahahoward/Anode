import XCTest
@testable import PowerKit

/// AirPods batteries, from the accessory entries IOKit lists beside the Mac's own battery.
final class AccessoryBatteryTests: XCTestCase {

    private func source(_ part: String, _ percent: Int, charging: Bool = false, group: String = "G1",
                        type: String = "Accessory Source") -> [String: Any] {
        ["Type": type, "Part Identifier": part, "Group Identifier": group, "Current Capacity": percent,
         "Is Charging": charging ? 1 : 0, "Accessory Category": part == "Case" ? "Audio Battery Case" : "Headset"]
    }

    private var sources: [[String: Any]] {
        [["Type": "InternalBattery", "Current Capacity": 50, "Is Charging": 0],
         source("Right", 64), source("Case", 77), source("Left", 100, charging: true)]
    }

    func testBatteryPartsFromPowerSources() {
        let b = AccessoryBattery.parse(sources)
        XCTAssertEqual(b.count, 3)
        XCTAssertEqual(b.first { $0.part == .left }?.percent, 100)
        XCTAssertEqual(b.first { $0.part == .left }?.charging, true)
        XCTAssertEqual(b.first { $0.part == .right }?.percent, 64)
        XCTAssertEqual(b.first { $0.part == .case_ }?.percent, 77)
    }

    func testTheMacsOwnBatteryIsIgnored() {
        XCTAssertFalse(AccessoryBattery.parse(sources).contains { $0.percent == 50 })
    }

    func testBothBudsPresent() {
        let b = AccessoryBattery.parse(sources)
        XCTAssertTrue(AccessoryBattery.bothBudsPresent(in: b, group: "G1"))
        XCTAssertFalse(AccessoryBattery.bothBudsPresent(in: b, group: "G2"))
        XCTAssertFalse(AccessoryBattery.bothBudsPresent(in: AccessoryBattery.parse([source("Right", 64), source("Case", 77)]), group: "G1"))
    }

    func testSingleEarbudHasOnePart() {
        let b = AccessoryBattery.parse([source("Main", 80, group: "G9")])
        XCTAssertEqual(b.map(\.part), [.single])
    }

    func testProductIDIsKept() {
        var d = source("Left", 90); d["Product ID"] = 8228
        XCTAssertEqual(AccessoryBattery.parse([d]).first?.productID, 8228)
    }

    func testAnEntryWithoutAPercentIsSkipped() {
        XCTAssertTrue(AccessoryBattery.parse([["Type": "Accessory Source", "Part Identifier": "Left"]]).isEmpty)
    }

    func testAKeyboardOrMouseIsNotAnAccessoryOfTheAirPods() {
        let b = AccessoryBattery.parse([
            ["Type": "Accessory Source", "Group Identifier": "KB", "Current Capacity": 31, "Accessory Category": "Keyboard", "Name": "Magic Keyboard"],
            source("Left", 90, group: "G1")])
        XCTAssertEqual(b.map(\.group), ["G1"])
    }

    func testTheBatteriesOfTheOutputThatIsNamedAreTheOnesUsed() {
        func entry(_ name: String, _ group: String, _ part: String, _ percent: Int) -> [String: Any] {
            ["Type": "Accessory Source", "Name": name, "Group Identifier": group, "Part Identifier": part, "Current Capacity": percent]
        }
        let all = AccessoryBattery.parse([entry("Other Headset", "A", "Left", 11), entry("Other Headset", "A", "Right", 12),
                                          entry("Noah\u{2019}s AirPods", "B", "Left", 80), entry("Noah\u{2019}s AirPods Case", "B", "Case", 60)])
        XCTAssertEqual(AccessoryBattery.selected(forDeviceNamed: "Noah\u{2019}s AirPods", in: all).map(\.percent).sorted(), [60, 80])
        XCTAssertEqual(AccessoryBattery.selected(forDeviceNamed: "Noah's AirPods", in: all).map(\.group), ["B", "B"], "a straight quote is the same name")
    }

    func testWithNoNamesTheFirstGroupWithPartsIsUsed() {
        XCTAssertEqual(AccessoryBattery.selected(forDeviceNamed: "Anything", in: AccessoryBattery.parse(sources)).count, 3)
    }
}

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
}

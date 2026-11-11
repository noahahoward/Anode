import XCTest
@testable import PowerKit

/// Which icons stay on the bar, which sit behind the chevron, and what a drag does to that.
final class BarArrangementTests: XCTestCase {

    private func item(_ key: String, title: String? = nil, locked: Bool = false) -> BarItem {
        BarItem(key: key, bundleID: nil, appName: "A", title: title ?? key, frame: CGRect(x: 0, y: 0, width: 24, height: 24),
                isLocked: locked, hasPress: true, pid: 1)
    }

    private var items: [BarItem] {
        [item("cc|Battery", title: "Battery"), item("cc|Sound", title: "Sound"), item("cc|Wi-Fi", title: "Wi-Fi"),
         item("cc|Clock", title: "Clock", locked: true),
         item("op|1Password"), item("wg|WireGuard"), item("ov|OpenVPN"), item("ov|OpenVPN#1")]
    }

    func testDefaultPinsBatterySoundWifi() {
        let a = BarArrangement.defaultArrangement(for: items)
        XCTAssertEqual(Set(a.pinned), ["cc|Battery", "cc|Sound", "cc|Wi-Fi"])
        XCTAssertEqual(a.pillOrder, ["op|1Password", "wg|WireGuard", "ov|OpenVPN", "ov|OpenVPN#1"])
    }

    /// Anode's own widgets fold into the pill by default, even the battery-drain one whose key says "battery".
    func testDefaultDoesNotPinAnodeWidgets() {
        let own = BarItem(key: "dev.anode.app|widget.batteryDrain", bundleID: "dev.anode.app", appName: "Anode", title: "Battery drain",
                          frame: .zero, isLocked: false, hasPress: false, pid: nil)
        let a = BarArrangement.defaultArrangement(for: items + [own])
        XCTAssertFalse(a.pinned.contains(own.key))
        XCTAssertTrue(a.pillOrder.contains(own.key))
    }

    func testUnknownItemsLandBehindChevron() {
        let a = BarArrangement(pinned: ["cc|Battery"], pillOrder: [])
        XCTAssertEqual(a.group(of: "never|seen", items: items), .behindChevron)
        XCTAssertEqual(a.group(of: "cc|Sound", items: items), .behindChevron)
        XCTAssertEqual(a.group(of: "cc|Battery", items: items), .onBar)
    }

    func testPillOrderRespectedThenNewcomersAppended() {
        let a = BarArrangement(pinned: [], pillOrder: ["wg|WireGuard", "op|1Password"])
        let keys = a.pillItems(from: items).map(\.key)
        XCTAssertEqual(Array(keys.prefix(2)), ["wg|WireGuard", "op|1Password"])
        XCTAssertEqual(Set(keys), Set(items.filter { !$0.isLocked }.map(\.key)))
        XCTAssertEqual(keys.count, 7)
    }

    func testKeysOfAppsNoLongerRunningAreIgnored() {
        let a = BarArrangement(pinned: ["gone|App"], pillOrder: ["gone|Other", "op|1Password"])
        let keys = a.pillItems(from: items).map(\.key)
        XCTAssertFalse(keys.contains("gone|Other"))
        XCTAssertEqual(keys.first, "op|1Password")
    }

    func testLockedItemsCannotBeMoved() {
        let a = BarArrangement(pinned: [], pillOrder: [])
        XCTAssertEqual(a.moving("cc|Clock", to: .behindChevron, at: 0, items: items), a)
        XCTAssertEqual(a.group(of: "cc|Clock", items: items), .onBar)
        XCTAssertFalse(a.pillItems(from: items).map(\.key).contains("cc|Clock"))
    }

    func testMoveToBehindChevronAtIndexAndClamp() {
        let a = BarArrangement(pinned: ["cc|Battery", "cc|Sound"], pillOrder: ["op|1Password", "wg|WireGuard"])
        let b = a.moving("cc|Sound", to: .behindChevron, at: 1, items: items)
        XCTAssertFalse(b.pinned.contains("cc|Sound"))
        XCTAssertEqual(Array(b.pillItems(from: items).map(\.key).prefix(3)), ["op|1Password", "cc|Sound", "wg|WireGuard"])
        let c = a.moving("cc|Sound", to: .behindChevron, at: 99, items: items)
        XCTAssertEqual(c.pillItems(from: items).map(\.key).last, "cc|Sound")
        XCTAssertEqual(a.moving("cc|Sound", to: .behindChevron, at: -5, items: items).pillItems(from: items).first?.key, "cc|Sound")
    }

    func testMoveToOnBarUnhides() {
        let a = BarArrangement(pinned: [], pillOrder: ["op|1Password", "wg|WireGuard"])
        let b = a.moving("wg|WireGuard", to: .onBar, at: 0, items: items)
        XCTAssertEqual(b.group(of: "wg|WireGuard", items: items), .onBar)
        XCTAssertFalse(b.pillItems(from: items).map(\.key).contains("wg|WireGuard"))
        XCTAssertFalse(b.pillOrder.contains("wg|WireGuard"))
    }

    func testReorderWithinPill() {
        let a = BarArrangement(pinned: [], pillOrder: ["op|1Password", "wg|WireGuard", "ov|OpenVPN"])
        let b = a.moving("ov|OpenVPN", to: .behindChevron, at: 0, items: items)
        XCTAssertEqual(Array(b.pillItems(from: items).map(\.key).prefix(3)), ["ov|OpenVPN", "op|1Password", "wg|WireGuard"])
    }

    func testUnknownKeyMoveIsIgnored() {
        let a = BarArrangement(pinned: ["cc|Battery"], pillOrder: [])
        XCTAssertEqual(a.moving("never|seen", to: .onBar, at: 0, items: items), a)
    }

    func testDamagedFieldDecodesAsEmpty() throws {
        let json = #"{"pinned": 7, "pillOrder": ["a|b"]}"#.data(using: .utf8)!
        let a = try JSONDecoder().decode(BarArrangement.self, from: json)
        XCTAssertEqual(a.pinned, [])
        XCTAssertEqual(a.pillOrder, ["a|b"])
        let none = try JSONDecoder().decode(BarArrangement.self, from: "{}".data(using: .utf8)!)
        XCTAssertEqual(none, BarArrangement(pinned: [], pillOrder: []))
    }
}

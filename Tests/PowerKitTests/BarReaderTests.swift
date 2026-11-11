import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// Turning what Accessibility reports about the menu bar into `BarItem`s. Only the pure part is tested: nothing here makes an
/// accessibility call.
final class BarReaderTests: XCTestCase {

    private typealias Child = AXBarReader.Child
    private let agent = (bundleID: Optional("com.apple.MenuBarAgent"), name: "MenuBarAgent", pid: pid_t(300))

    private func child(_ id: String? = nil, title: String? = nil, desc: String? = nil, x: CGFloat, press: Bool = true) -> Child {
        Child(identifier: id, title: title, description: desc, frame: CGRect(x: x, y: 0, width: 22, height: 39), hasPress: press)
    }

    func testOrdinalsAreOrderedByX() {
        // Measured: a third-party item has no identifier, title or description. Two of them from one app are told apart by
        // their order on the bar, whatever order they are listed in.
        let items = AXBarReader.parse(app: (bundleID: "net.openvpn", name: "OpenVPN", pid: 5),
                                      children: [child(x: 900), child(x: 800)])
        XCTAssertEqual(items.map(\.key), ["net.openvpn|#0", "net.openvpn|#1"])
        XCTAssertEqual(items.map(\.frame.minX), [800, 900])
    }

    func testSameNameGetsOrdinalsOnlyAfterTheFirst() {
        let items = AXBarReader.parse(app: (bundleID: "a", name: "A", pid: 1),
                                      children: [child(title: "Menu", x: 10), child(title: "Menu", x: 40), child(title: "Other", x: 70)])
        XCTAssertEqual(items.map(\.key), ["a|Menu", "a|Menu#1", "a|Other"])
    }

    func testItemWithoutPressActionIsKept() {
        let items = AXBarReader.parse(app: agent, children: [child("com.apple.menuextra.wifi", x: 1502, press: false)])
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].hasPress)
        XCTAssertEqual(items[0].key, "com.apple.MenuBarAgent|com.apple.menuextra.wifi")
        XCTAssertEqual(items[0].pid, 300)
    }

    func testEmptyChildrenGivesNoItems() {
        XCTAssertEqual(AXBarReader.parse(app: agent, children: []), [])
    }

    func testLockedFlagSetForClockAndControlCenter() {
        let items = AXBarReader.parse(app: agent, children: [
            child("com.apple.menuextra.wifi", x: 1502), child("com.apple.menuextra.controlcenter", x: 1620),
            child("com.apple.menuextra.clock", x: 1662)])
        XCTAssertEqual(items.map(\.isLocked), [false, true, true])
    }

    func testTitleOfAnItemIsItsDescriptionWhenThereIsNoTitle() {
        let items = AXBarReader.parse(app: (bundleID: "dev.anode.app", name: "Anode", pid: 9),
                                      children: [child(title: "", desc: "Keep Awake", x: 1067)])
        XCTAssertEqual(items[0].title, "Keep Awake")
    }
}

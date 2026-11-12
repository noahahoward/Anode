import XCTest
@testable import PowerKit

/// What identifies a menu bar item across relaunches, and which items are really on the bar.
final class BarItemTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)

    private func item(_ frame: CGRect) -> BarItem {
        BarItem(key: "a|b", bundleID: "a", appName: "A", title: "b", frame: frame, isLocked: false, hasPress: true, pid: 1)
    }

    func testKeyIgnoresPosition() {
        let a = BarItemKey.make(bundleID: "com.x", appName: "X", identifier: nil, title: "Menu", description: nil, ordinal: 0)
        let b = BarItemKey.make(bundleID: "com.x", appName: "X", identifier: nil, title: "Menu", description: nil, ordinal: 0)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "com.x|Menu")
    }

    func testTwoItemsOfOneAppGetDistinctKeysByOrdinal() {
        // OpenVPN shows two items with the same title.
        let first = BarItemKey.make(bundleID: "net.openvpn", appName: "OpenVPN", identifier: nil, title: "OpenVPN", description: nil, ordinal: 0)
        let second = BarItemKey.make(bundleID: "net.openvpn", appName: "OpenVPN", identifier: nil, title: "OpenVPN", description: nil, ordinal: 1)
        XCTAssertNotEqual(first, second)
    }

    func testUnnamedItemFallsBackToOrdinal() {
        let k = BarItemKey.make(bundleID: nil, appName: "Thing", identifier: nil, title: nil, description: nil, ordinal: 2)
        XCTAssertEqual(k, "Thing|#2")
        let blank = BarItemKey.make(bundleID: "b", appName: "Thing", identifier: "", title: "  ", description: "", ordinal: 0)
        XCTAssertEqual(blank, "b|#0")
    }

    func testIdentifierWinsOverTitle() {
        let k = BarItemKey.make(bundleID: "c", appName: "C", identifier: "com.apple.menuextra.battery", title: "Battery", description: "d", ordinal: 0)
        XCTAssertEqual(k, "c|com.apple.menuextra.battery")
        let t = BarItemKey.make(bundleID: "c", appName: "C", identifier: nil, title: "Battery", description: "d", ordinal: 0)
        XCTAssertEqual(t, "c|Battery")
        let d = BarItemKey.make(bundleID: "c", appName: "C", identifier: nil, title: nil, description: "d", ordinal: 0)
        XCTAssertEqual(d, "c|d")
    }

    func testItemOnTheBarIsOnTheBar() {
        XCTAssertTrue(item(CGRect(x: 1507, y: 0, width: 30, height: 24)).isOnBar(screens: [screen]))
    }

    func testParkedItemIsNotOnBar() {
        // Measured on the owner's Mac: parked items sit at x -1...7, y 1157.
        XCTAssertFalse(item(CGRect(x: -1, y: 1157, width: 24, height: 24)).isOnBar(screens: [screen]))
        XCTAssertFalse(item(CGRect(x: -20, y: 0, width: 24, height: 24)).isOnBar(screens: [screen]))
    }

    func testZeroAndNegativeSizeNeverOnBar() {
        XCTAssertFalse(item(CGRect(x: 1500, y: 0, width: 0, height: 24)).isOnBar(screens: [screen]))
        XCTAssertFalse(item(CGRect(x: 1500, y: 0, width: 30, height: 0)).isOnBar(screens: [screen]))
        XCTAssertFalse(item(CGRect(x: 1500, y: 0, width: -30, height: 24)).isOnBar(screens: [screen]))
    }

    func testItemOffEveryScreenIsNotOnBar() {
        XCTAssertFalse(item(CGRect(x: 5000, y: 0, width: 30, height: 24)).isOnBar(screens: [screen]))
        XCTAssertFalse(item(CGRect(x: 100, y: 0, width: 30, height: 24)).isOnBar(screens: []))
    }

    func testClockAndControlCenterAreLocked() {
        XCTAssertTrue(BarItem.isLockedItem(identifier: "com.apple.menuextra.clock", title: nil))
        XCTAssertTrue(BarItem.isLockedItem(identifier: nil, title: "Clock"))
        XCTAssertTrue(BarItem.isLockedItem(identifier: "com.apple.menuextra.controlcenter", title: nil))
        XCTAssertTrue(BarItem.isLockedItem(identifier: nil, title: "Control Center"))
        XCTAssertFalse(BarItem.isLockedItem(identifier: "com.apple.menuextra.battery", title: "Battery"))
        XCTAssertFalse(BarItem.isLockedItem(identifier: nil, title: nil))
    }

    /// Only the system's own clock and Control Center are locked, not any third-party item that mentions a clock.
    func testAThirdPartyClockIsNotLocked() {
        XCTAssertFalse(BarItem.isLockedItem(identifier: nil, title: "World Clock Pro"))
        XCTAssertFalse(BarItem.isLockedItem(identifier: "com.example.clockwork", title: nil))
        XCTAssertTrue(BarItem.isLockedItem(identifier: "com.apple.menuextra.clock", title: nil))
        XCTAssertTrue(BarItem.isLockedItem(identifier: nil, title: "Control Center"))
    }

    /// Every item macOS draws itself is locked: never covered, never behind the chevron. Seen on hardware 2026-11-11: the
    /// orange microphone-in-use indicator and an AirPods item appeared, were not in the arrangement, went behind the chevron
    /// by default and were covered (the cover narrower than the indicator, its orange edges showing).
    func testEverySystemItemIsLocked() {
        for owner in ["com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.TextInputMenuAgent",
                      "com.apple.Spotlight"] {
            XCTAssertTrue(BarItem.isLockedItem(bundleID: owner, identifier: nil, title: nil), owner)
            XCTAssertTrue(BarItem.isLockedItem(bundleID: owner, identifier: "com.apple.menuextra.battery", title: "Battery"), owner)
        }
        XCTAssertFalse(BarItem.isLockedItem(bundleID: "com.logi.ghub", identifier: nil, title: nil))
        XCTAssertFalse(BarItem.isLockedItem(bundleID: "com.example.audio", identifier: nil, title: "Sound"))
        XCTAssertFalse(BarItem.isLockedItem(bundleID: "dev.anode.app", identifier: nil, title: "CPU usage"))
        XCTAssertFalse(BarItem.isLockedItem(bundleID: nil, identifier: nil, title: nil))
        XCTAssertFalse(BarItem.isLockedItem(bundleID: "com.applesauce.menu", identifier: nil, title: nil))
    }
}

import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// Anode's own side of Ultra Low Power Mode: what the menu bar readings say while the app has stopped measuring, and which
/// apps its window features leave alone because the mode has stopped them. Only the pure parts are tested: nothing here
/// creates a status item, a window or a timer, or makes an accessibility call.
final class UltraQuietTests: XCTestCase {

    // ── The readings ────────────────────────────────────────────────────────

    func testEveryReadingShowsPausedWhileTheModeIsOn() {
        XCTAssertEqual(MenuBarWidgetController.pausedText, "Paused")
        for value in ["12%/hr", "3.2 W", "\u{2014}", ""] {
            XCTAssertEqual(MenuBarWidgetController.shownValue(paused: true, value: value), "Paused", "value \"\(value)\"")
        }
    }

    func testReadingsShowTheirValuesOtherwise() {
        for value in ["12%/hr", "3.2 W", "\u{2014}", ""] {
            XCTAssertEqual(MenuBarWidgetController.shownValue(paused: false, value: value), value)
        }
    }

    /// The button is a bare one: it was never in a status item.
    func testAClickOnAPausedReadingOpensTheModesMenu() {
        let button = NSStatusBarButton()
        var opened = 0, pausedClicks: [NSStatusBarButton] = []
        MenuBarWidgetController.routeLeftClick(on: button, metric: .cpuUsage, paused: true,
                                               onClick: { _ in opened += 1 }, onPausedClick: { pausedClicks.append($0) })
        XCTAssertEqual(pausedClicks.count, 1)
        XCTAssertTrue(pausedClicks.first === button, "the mode's menu opens from the reading that was clicked")
        XCTAssertEqual(opened, 0, "the usual action (open the window) is not taken")
    }

    func testAClickOnAReadingThatIsNotPausedDoesWhatItAlwaysDid() {
        var opened: [MetricID?] = [], pausedClicks = 0
        MenuBarWidgetController.routeLeftClick(on: NSStatusBarButton(), metric: .cpuUsage, paused: false,
                                               onClick: { opened.append($0) }, onPausedClick: { _ in pausedClicks += 1 })
        XCTAssertEqual(opened, [.cpuUsage])
        XCTAssertEqual(pausedClicks, 0)
    }

    /// Nothing is listening for the paused click (the app has not wired it): the click is not lost.
    func testAPausedClickWithNobodyListeningOpensTheWindow() {
        var opened: [MetricID?] = []
        MenuBarWidgetController.routeLeftClick(on: NSStatusBarButton(), metric: .memoryUsage, paused: true,
                                               onClick: { opened.append($0) }, onPausedClick: nil)
        XCTAssertEqual(opened, [.memoryUsage])
    }

    // ── Which apps are left alone ───────────────────────────────────────────

    private func entry(_ id: Int, pid: Int32) -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: 0,
         kCGWindowAlpha as String: 1.0, kCGWindowOwnerName as String: "App",
         kCGWindowBounds as String: CGRect(x: 0, y: 40, width: 800, height: 600).dictionaryRepresentation as NSDictionary]
    }

    func testFrozenAppsAreLeftOutOfTheWindowList() {
        let info = [entry(3, pid: 1), entry(1, pid: 2), entry(2, pid: 1), entry(4, pid: 3)]
        let list = WindowCatalog.switchable(windowInfo: info, regularPIDs: [1, 2, 3], isFrozen: { $0 == 2 })
        XCTAssertEqual(list.map(\.id), [3, 2, 4], "the frozen app's window is gone and the order of the others is kept")
        XCTAssertFalse(list.contains { $0.pid == 2 })
    }

    func testWithNothingFrozenTheWindowListIsAsItWas() {
        let info = [entry(3, pid: 1), entry(1, pid: 2), entry(2, pid: 1)]
        XCTAssertEqual(WindowCatalog.switchable(windowInfo: info, regularPIDs: [1, 2], isFrozen: { _ in false }).map(\.id), [3, 1, 2])
        XCTAssertEqual(WindowCatalog.switchable(windowInfo: info, regularPIDs: [1, 2]).map(\.id), [3, 1, 2])
    }

    /// Every mouse-down comes to the drag snapper, and its lookup of the window's accessibility element runs on one serial
    /// queue: for an app the mode stopped (its hide was refused or late, so a window is still on screen) each click would hold
    /// that queue for the whole timeout.
    func testADragOnAStoppedAppsWindowIsNotLookedUp() {
        XCTAssertFalse(WindowDragSnapper.looksUpWindow(ofApp: 20, isFrozen: { $0 == 20 }))
        XCTAssertTrue(WindowDragSnapper.looksUpWindow(ofApp: 10, isFrozen: { $0 == 20 }), "another app's window is looked up as always")
        XCTAssertTrue(WindowDragSnapper.looksUpWindow(ofApp: 20, isFrozen: { _ in false }))
    }

    /// Nothing creates the controller yet, and while there is none (or the mode is off) every question gets the answer it got
    /// before the mode existed.
    func testWithNoControllerNothingIsFrozenAndTheModeIsOff() throws {
        try XCTSkipIf(UltraLowPowerController.current != nil, "another test left a controller behind")
        XCTAssertFalse(UltraQuiet.isOn)
        XCTAssertFalse(UltraQuiet.isFrozen(pid: 1))
        XCTAssertFalse(UltraQuiet.isFrozen(pid: getpid()))
        UltraQuiet.activated(pid: 1)   // nobody to tell: nothing happens
    }
}

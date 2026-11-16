import XCTest
@testable import PowerKit

/// The steps of using macOS's own panel without it being seen, as a pure sequence: what to do, in which order, and what to
/// report. The live driver (in the app) only carries the actions out.
final class SystemPanelPressTests: XCTestCase {

    private let row = SystemPanelRow(identifier: "sound-device-Test AirPods Pro", description: "Adaptive")
    private let tree = AXNode(role: "AXWindow", children: [AXNode(role: "AXGroup")])

    func testReadOpensMovesReadsCloses() {
        var s = SystemPanelPress(job: .read, route: .menuExtra, personHasPanelOpen: false)
        XCTAssertEqual(s.start(), [.coverIcon, .openPanel(.menuExtra)])
        XCTAssertEqual(s.handle(.opened), [.movePanelOffScreen, .readTree])
        XCTAssertEqual(s.handle(.treeRead(tree)), [.closePanel])
        XCTAssertEqual(s.handle(.closed), [.uncoverIcon(after: SystemPanelTiming.coverHold), .finish(.tree(tree))])
    }

    func testPressOpensMovesPressesClosesAtOnceAndWatchesForAnAlert() {
        var s = SystemPanelPress(job: .press(row), route: .menuExtra, personHasPanelOpen: false)
        XCTAssertEqual(s.start(), [.coverIcon, .openPanel(.menuExtra)])
        XCTAssertEqual(s.handle(.opened), [.movePanelOffScreen, .pressRow(row)])
        XCTAssertEqual(s.handle(.rowPressed), [.closePanel, .waitForAlert(SystemPanelTiming.alertWindow)])
        XCTAssertEqual(s.handle(.closed), [])
        XCTAssertEqual(s.handle(.alertWindowElapsed), [.uncoverIcon(after: SystemPanelTiming.coverHold), .finish(.pressed)])
    }

    func testAlertIsDismissedAndReported() {
        var s = SystemPanelPress(job: .press(row), route: .menuExtra, personHasPanelOpen: false)
        _ = s.start(); _ = s.handle(.opened); _ = s.handle(.rowPressed)
        let text = "Failed to set listening mode / Put Test AirPods Pro in both ears to use Adaptive Audio."
        XCTAssertEqual(s.handle(.alert(text)), [.dismissAlert])
        XCTAssertEqual(s.handle(.alertWindowElapsed), [.uncoverIcon(after: SystemPanelTiming.coverHold), .finish(.refused(text))])
    }

    func testAnAlertAfterTheWindowIsIgnoredNotReported() {
        var s = SystemPanelPress(job: .press(row), route: .menuExtra, personHasPanelOpen: false)
        _ = s.start(); _ = s.handle(.opened); _ = s.handle(.rowPressed); _ = s.handle(.alertWindowElapsed)
        XCTAssertEqual(s.handle(.alert("late")), [.dismissAlert])
    }

    func testPressWithNoPanelRevertsAndSaysSo() {
        var s = SystemPanelPress(job: .press(row), route: .menuExtra, personHasPanelOpen: false)
        _ = s.start()
        XCTAssertEqual(s.handle(.openTimedOut),
                       [.closePanel, .uncoverIcon(after: SystemPanelTiming.coverHold), .finish(.failed(.panelDidNotOpen))])
    }

    func testDoesNotUseAPanelThePersonOpened() {
        var s = SystemPanelPress(job: .press(row), route: .menuExtra, personHasPanelOpen: true)
        XCTAssertEqual(s.start(), [.finish(.failed(.personHasItOpen))])
    }

    func testMissingRowClosesAndReports() {
        var s = SystemPanelPress(job: .press(row), route: .menuExtra, personHasPanelOpen: false)
        _ = s.start(); _ = s.handle(.opened)
        XCTAssertEqual(s.handle(.rowMissing), [.closePanel])
        XCTAssertEqual(s.handle(.closed), [.uncoverIcon(after: SystemPanelTiming.coverHold), .finish(.failed(.rowNotFound))])
    }

    func testRouteThroughControlCenterOpensTheSectionFirst() {
        var s = SystemPanelPress(job: .read, route: .controlCenter(section: "controlcenter-volume"), personHasPanelOpen: false)
        XCTAssertEqual(s.start(), [.coverIcon, .openPanel(.controlCenter(section: "controlcenter-volume"))])
        XCTAssertEqual(s.handle(.opened), [.movePanelOffScreen, .openSection("controlcenter-volume")])
        XCTAssertEqual(s.handle(.sectionOpened), [.movePanelOffScreen, .readTree])
    }

    func testNoAccessibilityFinishesAtOnce() {
        var s = SystemPanelPress(job: .read, route: .menuExtra, personHasPanelOpen: false, accessibility: false)
        XCTAssertEqual(s.start(), [.finish(.failed(.noAccessibility))])
    }
}

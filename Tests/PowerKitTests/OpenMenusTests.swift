import XCTest
@testable import PowerKit
@testable import AnodeApp

/// Clicking "All readings" in the menu bar and then macOS's Sound icon showed half of Anode's list beside the new Sound menu for a moment:
/// the Sound menu opens on a click Anode took before any app saw it, so the open menu of Anode's never heard it, and went only when the
/// reading of macOS's own panel pressed that icon (measured: Sound menu up at 221 ms, the list gone at 513 ms). The Sound and Battery
/// menus now close every open menu of Anode's as they open.
final class OpenMenusTests: XCTestCase {

    private var center: NotificationCenter!
    private var cancelled: [NSMenu]!
    private var menus: OpenMenus!

    override func setUp() {
        super.setUp()
        center = NotificationCenter()
        cancelled = []
        menus = OpenMenus(center: center, cancel: { [unowned self] in self.cancelled.append($0) })
        menus.start()
    }

    private func begin(_ menu: NSMenu) { center.post(name: NSMenu.didBeginTrackingNotification, object: menu) }
    private func end(_ menu: NSMenu) { center.post(name: NSMenu.didEndTrackingNotification, object: menu) }

    func testAMenuThatIsOpenIsClosedAtOnce() {
        let list = NSMenu(title: "All readings")
        begin(list)
        XCTAssertEqual(menus.open, [list])
        menus.closeAll()
        XCTAssertEqual(cancelled, [list])
        XCTAssertTrue(menus.open.isEmpty, "nothing is left to close twice")
    }

    func testAMenuThatHasClosedByItselfIsLeftAlone() {
        let list = NSMenu(title: "All readings")
        begin(list); end(list)
        menus.closeAll()
        XCTAssertTrue(cancelled.isEmpty)
    }

    func testNothingOpenMeansNothingIsDone() {
        menus.closeAll()
        XCTAssertTrue(cancelled.isEmpty)
    }

    func testEveryOpenMenuGoesOutermostFirst() {
        let outer = NSMenu(title: "outer"), sub = NSMenu(title: "sub")
        begin(outer); begin(sub)
        menus.closeAll()
        XCTAssertEqual(cancelled, [outer, sub])
    }

    func testAMenuAnnouncedTwiceIsClosedOnce() {
        let list = NSMenu(title: "All readings")
        begin(list); begin(list)
        menus.closeAll()
        XCTAssertEqual(cancelled.count, 1)
    }

    func testStartingTwiceDoesNotListenTwice() {
        menus.start()
        let list = NSMenu(title: "All readings")
        begin(list)
        menus.closeAll()
        XCTAssertEqual(cancelled.count, 1)
    }

    func testAMenuThatHasGoneAwayIsNotHeldOnTo() {
        autoreleasepool { begin(NSMenu(title: "gone")) }
        XCTAssertTrue(menus.open.isEmpty, "the list holds menus weakly")
        menus.closeAll()
        XCTAssertTrue(cancelled.isEmpty)
    }

    func testBeforeStartingNothingIsHeard() {
        let late = OpenMenus(center: center, cancel: { [unowned self] in self.cancelled.append($0) })
        begin(NSMenu(title: "All readings"))
        late.closeAll()
        XCTAssertTrue(cancelled.isEmpty, "the announcement of a menu already open is not heard: it is started at launch")
    }

    // ── It is wired in ──────────────────────────────────────────────────────

    func testBothMenusCloseTheOpenMenusOfAnodeAsTheyOpenAndTheListeningStartsAtLaunch() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let main = try String(contentsOf: root.appendingPathComponent("Sources/AnodeApp/main.swift"), encoding: .utf8)
        XCTAssertTrue(main.contains("OpenMenus.shared.start()"))
        for line in ["soundMenu?.onWillOpen = {", "batteryMenu?.onWillOpen = {"] {
            let l = main.split(separator: "\n").first { $0.contains(line) }.map(String.init) ?? ""
            XCTAssertTrue(l.contains("OpenMenus.shared.closeAll()"), "\(line) does not close the open menus of Anode's")
        }
        let started = try XCTUnwrap(main.range(of: "OpenMenus.shared.start()"), "the listening is never started")
        let hooked = try XCTUnwrap(main.range(of: "soundMenu?.onWillOpen = {"))
        XCTAssertLessThan(started.lowerBound, hooked.lowerBound, "it has to be listening before the first menu can open")
    }
}

import XCTest
@testable import PowerKit
@testable import AnodeApp

/// With the readings list open (the group widget's menu), a click on another reading did not open the window: macOS spent that
/// press closing the list, and the reading never saw it. The list now carries out the click on the reading the press landed on.
final class ReadingsListClickThroughTests: XCTestCase {

    // Three readings in the bar: CPU, the readings list (a group), Swap. Screen points, origin bottom-left, as NSEvent gives them.
    private let frames: [NSRect?] = [NSRect(x: 1217, y: 1137, width: 49, height: 24),
                                     NSRect(x: 1497, y: 1137, width: 36, height: 24),
                                     NSRect(x: 1436, y: 1137, width: 63, height: 24)]
    private let isGroup = [false, true, false]

    func testAPressOnAnotherReadingIsThatReadingsClick() {
        XCTAssertEqual(ClickThrough.reading(at: NSPoint(x: 1460, y: 1149)), 2)
        XCTAssertEqual(ClickThrough.reading(at: NSPoint(x: 1240, y: 1149)), 0)
    }

    func testAPressOnTheListsOwnItemOnlyClosesIt() {
        XCTAssertNil(ClickThrough.reading(at: NSPoint(x: 1515, y: 1149)), "the list's own item toggles it: closing is all a press there does")
    }

    func testAPressAnywhereElseIsNobodysClick() {
        XCTAssertNil(ClickThrough.reading(at: NSPoint(x: 700, y: 600)), "the desktop, a window")
        XCTAssertNil(ClickThrough.reading(at: NSPoint(x: 1551, y: 1149)), "macOS's Sound icon, beside the list")
    }

    func testAListThatClosedWithoutAPressCarriesOutNothing() {
        // Esc, a row chosen, or Anode's Sound menu opening: the pointer may well rest on a reading, and nobody clicked it.
        XCTAssertNil(MenuBarWidgetController.readingUnderClick(at: NSPoint(x: 1460, y: 1149), pressing: false, frames: frames, isGroup: isGroup))
    }

    func testAReadingWithNoWindowYetIsSkipped() {
        XCTAssertNil(MenuBarWidgetController.readingUnderClick(at: NSPoint(x: 1460, y: 1149), pressing: true, frames: [nil, nil, nil], isGroup: isGroup))
    }

    private enum ClickThrough {
        static func reading(at p: NSPoint) -> Int? {
            MenuBarWidgetController.readingUnderClick(at: p, pressing: true,
                                                      frames: ReadingsListClickThroughTests().frames, isGroup: [false, true, false])
        }
    }

    // ── It is wired in ──────────────────────────────────────────────────────

    func testTheListCarriesTheClickOutAsItClosesAndTheButtonDoesNotTakeItTwice() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/AnodeApp/MenuBarWidgets.swift"), encoding: .utf8)
        let didClose = try XCTUnwrap(text.range(of: "public func menuDidClose(_ menu: NSMenu) {"))
        let body = text[didClose.upperBound...].prefix(400)
        XCTAssertTrue(body.contains("carryOutClickThatClosed()"), "the list does not carry out the click that closed it")
        XCTAssertTrue(text.contains("done.button === sender, Date().timeIntervalSince(done.at) < Self.carriedOutClickWindow"),
                      "a click carried out here could be taken twice")
    }
}

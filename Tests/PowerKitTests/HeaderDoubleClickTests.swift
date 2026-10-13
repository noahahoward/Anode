import AppKit
import XCTest
@testable import AnodeApp

/// Every click on a column header sorts, including the second of a fast pair.
///
/// `NSTableHeaderView` sorts from a single-click gesture recognizer and carries
/// a double-click one beside it, for fitting a column to its content from its
/// divider. Two quick clicks belong to the second, so the sort flipped on every
/// other click. Columns here are not resizable by hand, so the double click has
/// nothing to do and must not be listening.
final class HeaderDoubleClickTests: XCTestCase {

    func testTheHeaderDoesNotListenForDoubleClicks() throws {
        let controller = MainWindowController()
        controller.setColumns(Array(ProcessColumns.all(powerWindowHours: 10).prefix(4)))
        controller.window.orderFront(nil)
        defer { controller.window.close() }
        controller.window.layoutIfNeeded()

        let header = try XCTUnwrap(controller.table.headerView)
        let clicks = header.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }
        // Older systems track header clicks in `mouseDown` and install none.
        try XCTSkipIf(clicks.isEmpty, "this AppKit does not sort from gesture recognizers")

        XCTAssertTrue(clicks.contains { $0.isEnabled && $0.numberOfClicksRequired == 1 },
                      "nothing is left to sort on a click")
        XCTAssertFalse(clicks.contains { $0.isEnabled && $0.numberOfClicksRequired > 1 },
                       "a double-click recognizer is still claiming every second click")
    }
}

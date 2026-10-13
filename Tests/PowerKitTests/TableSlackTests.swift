import AppKit
import XCTest
@testable import AnodeApp

/// A table that fits must not scroll sideways.
///
/// The trailing spacer column takes up whatever width the data columns leave,
/// but AppKit only re-fits it when the TABLE is resized. Widening a data column
/// is not that: the table grew by the difference and the spacer kept everything
/// it had, so a table using half the window scrolled sideways into blank space.
final class TableSlackTests: XCTestCase {

    func testWideningAColumnTakesTheWidthFromTheSpacer() throws {
        let controller = MainWindowController()
        controller.setColumns(Array(ProcessColumns.all(powerWindowHours: 10).prefix(4)))
        let table = controller.table
        let clip = try XCTUnwrap(table.enclosingScrollView?.contentView)

        // Resize, so the spacer has absorbed the slack the way it has in a
        // window that has been open for a moment.
        var size = controller.window.contentLayoutRect.size
        size.width += 40
        controller.window.setContentSize(size)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        table.tile()

        let spacer = try XCTUnwrap(table.tableColumns.last)
        try XCTSkipUnless(spacer.width > 100, "columns do not leave slack at this window size")
        XCTAssertEqual(table.frame.width, clip.bounds.width, accuracy: 0.5)

        controller.widen(table.tableColumns[0], to: table.tableColumns[0].width + 40)
        table.tile()

        XCTAssertLessThanOrEqual(
            table.frame.width, clip.bounds.width + 0.5,
            "the table outgrew its clip view with \(spacer.width) pt of spacer to spare")
    }
}

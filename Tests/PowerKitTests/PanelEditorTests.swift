import AppKit
import XCTest
@testable import AnodeApp
@testable import PowerKit

/// The panel editor sheet: reorder by drag, show/hide by checkbox.
///
/// Driven through the real `NSTableViewDataSource`/`Delegate` methods rather
/// than through private helpers, because the bugs this guards against live
/// exactly there: an off-by-one in the drop index, a checkbox reading the wrong
/// row, or a commit that quietly drops the ids it cannot render.
final class PanelEditorTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var settings: Settings!
    private var editor: PanelEditorController!
    private var table: NSTableView { editor.testTable }

    override func setUpWithError() throws {
        let made = try TestDefaults.make(owner: "PanelEditor")
        defaults = made.defaults
        suiteName = made.name
        settings = Settings(defaults: defaults)
        editor = PanelEditorController(settings: settings)
    }

    override func tearDownWithError() throws {
        editor = nil
        settings = nil
        TestDefaults.destroy(defaults, suiteName)
    }

    private func titles() -> [String] { editor.testRowTitles }

    private func cellView(row: Int) throws -> NSView {
        try XCTUnwrap(editor.tableView(table, viewFor: table.tableColumns[0], row: row))
    }

    /// The box lives inside the row's stack now, not as the cell view itself.
    private func checkbox(row: Int, in cell: NSView? = nil) throws -> NSButton {
        let host = try cell ?? cellView(row: row)
        return try XCTUnwrap(host.subviews.compactMap { $0 as? NSButton }.first,
                             "row \(row) has no checkbox")
    }

    private func labelField(row: Int, in cell: NSView? = nil) throws -> NSTextField {
        let host = try cell ?? cellView(row: row)
        return try XCTUnwrap(host.subviews.compactMap { $0 as? NSTextField }.first,
                             "row \(row) has no label")
    }

    /// Click a row's checkbox the way AppKit would.
    private func toggle(row: Int, to on: Bool) throws {
        let box = try checkbox(row: row)
        box.state = on ? .on : .off
        _ = box.target?.perform(box.action, with: box)
    }

    /// The same entry point a real drop reaches once the pasteboard has been
    /// decoded — the index arithmetic under test, not the transport.
    private func drop(from: Int, toGap: Int) -> Bool {
        editor.move(fromRow: from, toGap: toGap)
    }

    // ── Listing ─────────────────────────────────────────────────────────────

    /// The editor lists EVERY metric, hidden ones included and in place — that
    /// is how a user finds what they turned off in order to turn it back on.
    func testListsEveryMetricIncludingHiddenOnesInPlace() {
        let all = titles()
        XCTAssertGreaterThan(all.count, 10)
        settings.panelHidden = [MetricID.cpuUsage.rawValue]
        let reopened = PanelEditorController(settings: settings)
        XCTAssertEqual(reopened.testRowTitles, all,
                       "hiding a row removed it from the editor instead of "
                       + "leaving it in place, unchecked")
    }

    /// Reported from the field as "checkboxes not aligned": with the box and the
    /// label in SEPARATE COLUMNS, each centres within its own column, on
    /// independent baselines, and they visibly drift. Measured here on the laid
    /// out cell rather than asserted structurally, so any future layout that
    /// reintroduces the drift fails whatever shape it takes.
    func testTheBoxAndItsLabelShareOneBaseline() throws {
        XCTAssertEqual(table.tableColumns.count, 1,
                       "a second column reintroduces the split-baseline drift")
        for row in 0..<min(5, titles().count) {
            let cell = try cellView(row: row)
            cell.frame = NSRect(x: 0, y: 0, width: 300, height: table.rowHeight)
            cell.layoutSubtreeIfNeeded()
            let box = try checkbox(row: row, in: cell)
            let label = try labelField(row: row, in: cell)
            XCTAssertEqual(box.frame.midY, label.frame.midY, accuracy: 0.5,
                           "row \(row): box and label are \(box.frame.midY - label.frame.midY)pt apart")
        }
    }

    /// The regression the alignment fix caused, and the reason the row is a
    /// stack rather than one checkbox carrying its title: an `NSControl`
    /// spanning the row swallows `mouseDown`, the table never sees the event
    /// that starts a drag session, and the list cannot be reordered.
    func testTheCellViewDoesNotSwallowTheDragMouseDown() throws {
        for row in 0..<min(5, titles().count) {
            let cell = try cellView(row: row)
            XCTAssertFalse(cell is NSControl,
                           "row \(row)'s cell view is an NSControl: it will "
                           + "swallow mouseDown and break drag-to-reorder")
        }
    }

    func testOpensOnTheSubjectGroupedDefault() {
        guard let cpu = titles().firstIndex(of: "CPU usage") else {
            return XCTFail("no CPU usage row: \(titles())")
        }
        XCTAssertEqual(titles()[cpu + 1], "CPU temperature")
    }

    // ── Reordering ──────────────────────────────────────────────────────────

    func testDraggingARowDownPersistsTheNewOrder() {
        let before = titles()
        // Move row 0 to the gap AFTER row 2 — the classic off-by-one: the gap
        // index counts the row that is about to leave.
        XCTAssertTrue(drop(from: 0, toGap: 3))
        var want = before
        let moved = want.remove(at: 0)
        want.insert(moved, at: 2)
        XCTAssertEqual(titles(), want)
        XCTAssertEqual(Settings(defaults: defaults).panelOrder.count, before.count,
                       "the whole arrangement should be saved, not just the move")
        XCTAssertEqual(PanelEditorController(settings: settings).testRowTitles, want,
                       "the order did not survive reopening the sheet")
    }

    func testDraggingARowUpPersistsTheNewOrder() {
        let before = titles()
        XCTAssertTrue(drop(from: 3, toGap: 1))
        var want = before
        let moved = want.remove(at: 3)
        want.insert(moved, at: 1)
        XCTAssertEqual(titles(), want)
    }

    func testADropThatChangesNothingIsRejected() {
        let before = titles()
        XCTAssertFalse(drop(from: 2, toGap: 2), "a no-op move reported success")
        XCTAssertFalse(drop(from: 2, toGap: 3), "a no-op move reported success")
        XCTAssertEqual(titles(), before)
    }

    func testAnOutOfRangeDropIsRefusedRatherThanCrashing() {
        let before = titles()
        XCTAssertFalse(drop(from: -1, toGap: 0))
        XCTAssertFalse(drop(from: 999, toGap: 0))
        XCTAssertFalse(drop(from: 0, toGap: 999))
        XCTAssertEqual(titles(), before)
    }

    // ── Show / hide ─────────────────────────────────────────────────────────

    func testUncheckingARowHidesItFromThePanelButNotFromTheEditor() throws {
        let hiddenTitle = titles()[1]
        try toggle(row: 1, to: false)

        XCTAssertEqual(settings.panelHidden.count, 1)
        XCTAssertEqual(titles()[1], hiddenTitle, "the row left the editor")

        let shown = MenuBarWidgetController.buildGroupMenu(settings: settings)
            .items.map { $0.title.components(separatedBy: "\t")[0] }
        XCTAssertFalse(shown.contains(hiddenTitle), "the hidden row still renders")
    }

    func testRecheckingARowRestoresItToItsOriginalPlace() throws {
        let before = titles()
        try toggle(row: 2, to: false)
        try toggle(row: 2, to: true)

        XCTAssertTrue(settings.panelHidden.isEmpty)
        let shown = MenuBarWidgetController.buildGroupMenu(settings: settings)
            .items.map { $0.title.components(separatedBy: "\t")[0] }
        XCTAssertEqual(shown, before, "unhiding did not put the row back where it was")
    }

    /// Restore clears BOTH keys rather than writing today's default into them:
    /// an empty arrangement is how `PanelOrder` knows to speak for itself, so a
    /// user who restores keeps tracking future improvements to the default.
    func testRestoreDefaultsClearsRatherThanMaterializes() {
        settings.panelOrder = [MetricID.cpuUsage.rawValue]
        settings.panelHidden = [MetricID.fanSpeed.rawValue]
        editor.testRestoreDefaults()
        XCTAssertTrue(settings.panelOrder.isEmpty)
        XCTAssertTrue(settings.panelHidden.isEmpty)
        XCTAssertEqual(titles(), PanelEditorController(settings: settings).testRowTitles)
    }

    /// A saved id this build cannot render is not the editor's to discard: it
    /// belongs to a module that isn't loaded, and opening the sheet must not
    /// quietly delete that module's rows from someone's arrangement.
    func testAnUnrenderableSavedIDSurvivesAnEdit() {
        settings.panelOrder = ["future.metric"] + PanelOrder.defaultOrder.map(\.rawValue)
        let editor = PanelEditorController(settings: settings)
        XCTAssertFalse(editor.testRowTitles.contains("future.metric"),
                       "an unrenderable id should have no row")
        editor.testCommit()
        XCTAssertTrue(settings.panelOrder.contains("future.metric"),
                      "the editor discarded an id it merely could not draw")
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// The pasteboard half of the drop, which `move(fromRow:toGap:)` above does not
/// cover: the row a drag writes must be the row the drop reads back.
extension PanelEditorTests {

    func testTheDragPasteboardRoundTripsTheRowIndex() throws {
        let written = try XCTUnwrap(
            editor.tableView(table, pasteboardWriterForRow: 4) as? NSPasteboardItem)
        XCTAssertEqual(written.string(forType: PanelEditorController.testDragType), "4")
    }
}

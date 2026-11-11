import XCTest
import AppKit
@testable import AnodeApp

/// A key window whose pointer is wherever the test says, so hover can be tested without touching the real one.
private final class PointerWindow: NSWindow {
    var pointer = NSPoint(x: -1000, y: -1000)
    override var isKeyWindow: Bool { true }
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
}

/// Expanding a group in the Sensors list rebuilt its rows, every new row asked "is the pointer over me?", and every
/// one answered yes — `visibleRect` is the whole viewport on current macOS, not the row — so the entire list showed
/// as hovered. Reported as "clicking the dropdown highlights everything in the temps menu".
final class PointerHoverTests: XCTestCase {

    private func items(expanded: Bool) -> [BodyItem] {
        var list: [BodyItem] = [.heading("Summary"), .row("CPU", "50 °C"), .row("GPU", "40 °C")]
        for group in ["Battery", "CPU", "GPU"] {
            let open = expanded && group == "CPU"
            list.append(.group(group, "3 · 40 °C max", expanded: open))
            if open { for n in 0..<12 { list.append(.row("\(group) sensor \(n)", "4\(n) °C", fill: 0.3)) } }
        }
        return list
    }

    private func makePane() -> (SystemPane, PointerWindow) {
        let window = PointerWindow(contentRect: NSRect(x: -3000, y: -3000, width: 900, height: 900),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        let pane = SystemPane(frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        window.contentView = pane
        pane.setBody(items(expanded: false))
        pane.layoutSubtreeIfNeeded()
        return (pane, window)
    }

    private func rows(_ pane: SystemPane) -> [SystemPane.BarRow] {
        pane.body.arrangedSubviews.compactMap { $0 as? SystemPane.BarRow }
    }

    /// What AppKit does after a rebuild and a layout: each new view's tracking areas are brought up to date.
    private func settle(_ pane: SystemPane) {
        pane.body.arrangedSubviews.forEach { $0.updateTrackingAreas() }
        pane.layoutSubtreeIfNeeded()
        pane.body.arrangedSubviews.forEach { $0.updateTrackingAreas() }
    }

    func testExpandingAGroupUnderThePointerDoesNotHoverEveryRow() {
        let (pane, window) = makePane()
        let header = pane.body.arrangedSubviews.compactMap { $0 as? SystemPane.GroupHeaderView }[1]
        window.pointer = header.convert(NSPoint(x: header.bounds.midX, y: header.bounds.midY), to: nil)

        pane.setBody(items(expanded: true))   // the click: the list is rebuilt, the pointer has not moved
        settle(pane)

        XCTAssertEqual(rows(pane).count, 14)
        XCTAssertEqual(rows(pane).filter { $0.isHovering }.count, 0,
                       "the pointer is over the header, so no row is hovered")
        XCTAssertEqual(rows(pane).filter { $0.isPicked }.count, 0)
    }

    func testOnlyTheRowUnderThePointerIsHoveredAfterARebuild() throws {
        let (pane, window) = makePane()
        pane.setBody(items(expanded: true))
        pane.layoutSubtreeIfNeeded()
        let target = try XCTUnwrap(rows(pane).dropFirst(5).first)
        window.pointer = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)

        pane.setBody(items(expanded: false))
        pane.setBody(items(expanded: true))    // rebuilt again, pointer now where a row will be
        settle(pane)

        let hovered = rows(pane).filter { $0.isHovering }
        XCTAssertEqual(hovered.count, 1, "exactly the row the pointer is on")
        XCTAssertEqual(hovered.first?.rowLabel, target.rowLabel)
    }

    func testAViewIsNeverUnderThePointerOutsideItsOwnBounds() {
        let (pane, window) = makePane()
        let row = rows(pane)[0]
        window.pointer = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.maxY + 200), to: nil)
        XCTAssertGreaterThan(row.visibleRect.height, row.bounds.height,
                             "premise: on this macOS the visible rect is wider than the row; if not, this test proves nothing")
        XCTAssertFalse(row.isUnderPointer)
        window.pointer = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        XCTAssertTrue(row.isUnderPointer)
    }
}

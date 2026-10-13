import AppKit
import XCTest
@testable import AnodeApp

/// A row that scrolls out from under the pointer stops being hovered.
///
/// `mouseExited` is not sent for that. The pointer did not move, and by the time
/// it does the row's tracking area has been replaced by one that never saw the
/// pointer inside it — so every row that passed under a stationary pointer kept
/// its highlight until it was hovered and left again.
final class HoverAfterScrollTests: XCTestCase {

    func testARowScrolledAwayFromThePointerIsNotLeftHovered() throws {
        let rows = (0..<40).map { i -> SystemPane.BarRow in
            let row = SystemPane.BarRow(.row("Thermal sensor \(i)", "40°"))
            row.onSelect = {}
            row.heightAnchor.constraint(equalToConstant: 22).isActive = true
            return row
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        scroll.documentView = stack
        stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        // Far from wherever the pointer really is, so no row is under it.
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 300, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        defer { window.close() }
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let row = rows[3]
        let entered = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil))
        row.mouseEntered(with: entered)
        XCTAssertTrue(row.isHovering)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        scroll.reflectScrolledClipView(scroll.contentView)
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertFalse(row.isHovering,
                       "the row kept its hover after scrolling away from the pointer")
    }
}

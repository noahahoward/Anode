import XCTest
import AppKit
@testable import PowerKit
@testable import AnodeApp

/// A row lights up under the pointer. macOS's keeps its light while the button is held and the pointer drags off it (a press on a
/// row is cancelled by letting go elsewhere), and a release off the row does not choose it.
@MainActor
final class HoverRowTests: XCTestCase {
    private func event(_ type: NSEvent.EventType, at p: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    private func rig() -> (NSWindow, HoverRow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let row = HoverRow(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        window.contentView?.addSubview(row)
        return (window, row)
    }

    func testTheLightGoesWhenThePointerLeavesAndNoButtonIsDown() {
        let (w, row) = rig(); defer { w.close() }
        row.mouseEntered(with: event(.mouseMoved, at: NSPoint(x: 50, y: 16), in: w))
        XCTAssertTrue(row.isLit)
        row.mouseExited(with: event(.mouseMoved, at: NSPoint(x: 50, y: 80), in: w))
        XCTAssertFalse(row.isLit)
    }

    func testTheLightStaysWhileTheButtonIsHeldAndThePointerDragsOff() {
        let (w, row) = rig(); defer { w.close() }
        var picked = 0; row.onPick = { picked += 1 }
        row.mouseEntered(with: event(.mouseMoved, at: NSPoint(x: 50, y: 16), in: w))
        row.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 50, y: 16), in: w))
        row.mouseExited(with: event(.leftMouseDragged, at: NSPoint(x: 50, y: 80), in: w))
        XCTAssertTrue(row.isLit, "still lit: the press is still on this row")
        row.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 50, y: 80), in: w))
        XCTAssertEqual(picked, 0, "let go off the row: not chosen")
        XCTAssertFalse(row.isLit, "and the light goes with the press")
    }

    func testAReleaseOnTheRowChoosesIt() {
        let (w, row) = rig(); defer { w.close() }
        var picked = 0; row.onPick = { picked += 1 }
        row.mouseEntered(with: event(.mouseMoved, at: NSPoint(x: 50, y: 16), in: w))
        row.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 50, y: 16), in: w))
        row.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 50, y: 16), in: w))
        XCTAssertEqual(picked, 1)
    }
}

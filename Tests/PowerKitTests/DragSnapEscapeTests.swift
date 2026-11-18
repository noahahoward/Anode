import XCTest
@testable import PowerKit
@testable import AnodeApp

/// The tap that watches the mouse for window drags used to watch every key press too, only to catch Escape ("no snap for this drag").
/// An active tap sits in the path of every key press until its callback returns, so it now watches the mouse alone and Escape is read
/// from the key's state while a window is being dragged (that needs no permission: measured in an app with neither Accessibility nor
/// Input Monitoring, where a global key monitor saw nothing).
final class DragSnapEscapeTests: XCTestCase {

    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/AnodeApp/WindowDragSnapping.swift"), encoding: .utf8)
    }

    func testTheDragTapNoLongerWatchesKeys() throws {
        let text = try source()
        XCTAssertFalse(text.contains("CGEventType.keyDown"), "the drag tap watches every key press again")
        XCTAssertTrue(text.contains("CGEventType.leftMouseDown.rawValue"), "it still watches the mouse")
    }

    func testEscapeIsReadFromTheKeyStateAndOnlyWhileAWindowIsBeingDragged() throws {
        let text = try source()
        XCTAssertTrue(text.contains("CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Escape))"))
        // Started when the window starts to move, stopped with the drag: no timer runs while nothing is being dragged.
        XCTAssertTrue(text.contains("moving = true\n            watchEscape()"))
        XCTAssertTrue(text.contains("escapeTimer?.invalidate(); escapeTimer = nil"))
    }

    func testEscapeCancelsOnlyADragThatIsMovingAndNotAlreadyCancelled() {
        XCTAssertTrue(WindowDragSnapper.escapeCancels(held: true, moving: true, alreadyCancelled: false))
        XCTAssertFalse(WindowDragSnapper.escapeCancels(held: false, moving: true, alreadyCancelled: false))
        XCTAssertFalse(WindowDragSnapper.escapeCancels(held: true, moving: false, alreadyCancelled: false), "Escape with no window moving is nobody's business")
        XCTAssertFalse(WindowDragSnapper.escapeCancels(held: true, moving: true, alreadyCancelled: true))
    }
}

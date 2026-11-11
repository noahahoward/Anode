import XCTest
import AppKit
@testable import AnodeApp

/// A MacBook Neo crashed the first time the window switcher went to one of Anode's own windows: `ownWindow`
/// turned every window's number into a `CGWindowID`, and a window that had never been shown has number -1.
final class WindowServerIDTests: XCTestCase {

    private func neverShownWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                 backing: .buffered, defer: true)
    }

    func testAWindowNeverShownHasNoServerID() {
        let w = neverShownWindow()
        XCTAssertLessThanOrEqual(w.windowNumber, 0, "the premise: a window never ordered in has no number")
        XCTAssertNil(w.windowServerID)
    }

    /// The exact situation that crashed: the list holds a window that was never shown, and the wanted id belongs
    /// to another. It used to trap before reaching the end of the list.
    func testLookingForAnIDAmongWindowsThatIncludeAnUnshownOneDoesNotTrap() {
        let windows = [neverShownWindow(), neverShownWindow()]
        XCTAssertNil(WindowActivator.ownWindow(withID: 12345, in: windows))
        XCTAssertNil(WindowActivator.ownWindow(withID: 0, in: windows), "id 0 is the null window, never a match")
    }

    func testAShownWindowIsFoundByItsID() throws {
        let shown = neverShownWindow()
        shown.orderFrontRegardless()
        defer { shown.orderOut(nil) }
        guard let id = shown.windowServerID else { throw XCTSkip("no window server in this environment") }
        XCTAssertEqual(WindowActivator.ownWindow(withID: id, in: [neverShownWindow(), shown]), shown)
        XCTAssertNil(WindowActivator.ownWindow(withID: id &+ 1, in: [neverShownWindow(), shown]))
    }
}

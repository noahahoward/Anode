import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// Anode's own windows are read and moved with NSWindow, never through accessibility: the accessibility server's
/// answer for one of our own windows deadlocked against the main thread's display cycle and froze the app (see
/// `AccessibleWindow`). These tests need no Accessibility permission, which is the point.
final class OwnWindowAccessTests: XCTestCase {

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 400, height: 300),
                         styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        return w
    }

    func testCoordinatesRoundTripBetweenAppKitAndAccessibility() {
        let f = NSRect(x: 120, y: 340, width: 500, height: 260)
        XCTAssertEqual(AccessibleWindow.appKitFrame(AccessibleWindow.accessibilityFrame(f)), f)
    }

    func testAnOwnWindowReportsItselfWithoutAccessibility() {
        let w = makeWindow()
        let a = AccessibleWindow.own(w)
        XCTAssertEqual(a.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(a.windowID, CGWindowID(w.windowNumber))
        XCTAssertTrue(a.isResizable)
        XCTAssertEqual(a.frame, AccessibleWindow.accessibilityFrame(w.frame))
    }

    func testSetFrameMovesTheWindowAndReturnsWhereItLanded() {
        let w = makeWindow()
        let a = AccessibleWindow.own(w)
        let target = CGRect(x: 100, y: 200, width: 420, height: 320)
        let landed = a.setFrame(target)
        XCTAssertEqual(landed, AccessibleWindow.accessibilityFrame(w.frame))
        XCTAssertEqual(w.frame.size.width, 420, accuracy: 1)
    }

    /// The drag snapper's queue is not the main thread; it must be able to read and move our window from there
    /// while the main thread is busy (here: waiting), without either side waiting on the other for ever.
    func testItWorksFromABackgroundQueueWhileMainIsWaiting() {
        let w = makeWindow()
        let a = AccessibleWindow.own(w)
        let done = expectation(description: "background move")
        var landed: CGRect?
        DispatchQueue(label: "test.ax").async {
            _ = a.frame
            landed = a.setFrame(CGRect(x: 150, y: 250, width: 380, height: 280))
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(landed?.size.width ?? 0, 380, accuracy: 1)
    }

    func testFindingAnOwnWindowByNumberNeverNeedsAccessibility() {
        let w = makeWindow()
        w.orderFrontRegardless()
        defer { w.orderOut(nil) }
        let found = AccessibleWindow.find(id: CGWindowID(w.windowNumber), pid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertNotNil(found?.local)
        XCTAssertEqual(found?.windowID, CGWindowID(w.windowNumber))
    }
}

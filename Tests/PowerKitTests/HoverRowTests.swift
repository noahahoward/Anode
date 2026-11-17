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

    // ── The Battery menu's rows (measured on macOS's own panel) ─────────────

    private func modeRow(in w: NSWindow) -> ModeRow {
        let row = ModeRow(frame: NSRect(x: 0, y: 0, width: 294, height: 32), mode: .init(id: "low", title: "Low Power", isSelected: false))
        w.contentView?.addSubview(row)
        return row
    }

    func testABatteryRowDimsItsContentWhileItIsPressed_AndAfterLetGo() {
        let (w, _) = rig(); defer { w.close() }
        let row = modeRow(in: w)
        row.mouseEntered(with: event(.mouseMoved, at: NSPoint(x: 50, y: 16), in: w))
        XCTAssertTrue(row.subviews.allSatisfy { $0.alphaValue == 1 })
        row.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 50, y: 16), in: w))
        XCTAssertTrue(row.subviews.allSatisfy { abs($0.alphaValue - 0.8) < 0.001 }, "the text and badge go to 0.8 (measured: 236 to 200 on the text)")
        row.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 50, y: 16), in: w))
        XCTAssertTrue(row.subviews.allSatisfy { $0.alphaValue == 1 })
    }

    // Measured on macOS's own panel by dragging off a pressed row: the content goes back to full strength at once, the light stays
    // until the pointer next moves (a plain move off the row puts it out), and dragging back on dims the content again.
    func testDraggingAPressedBatteryRowOffUndimsItAndLeavesTheLight_AndBackOnDimsItAgain() {
        let (w, _) = rig(); defer { w.close() }
        let row = modeRow(in: w)
        var picked = 0; row.onPick = { picked += 1 }
        row.mouseEntered(with: event(.mouseMoved, at: NSPoint(x: 50, y: 16), in: w))
        row.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 50, y: 16), in: w))
        row.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: 50, y: 80), in: w))
        XCTAssertTrue(row.isLit, "the light stays")
        XCTAssertTrue(row.subviews.allSatisfy { $0.alphaValue == 1 }, "the content is back at full strength")
        row.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: 60, y: 16), in: w))
        XCTAssertTrue(row.subviews.allSatisfy { abs($0.alphaValue - 0.8) < 0.001 })
        row.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: 50, y: 80), in: w))
        row.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 50, y: 80), in: w))
        XCTAssertEqual(picked, 0)
        XCTAssertTrue(row.subviews.allSatisfy { $0.alphaValue == 1 })
    }

    func testASoundRowIsNotDimmedByAPress() {
        let (w, row) = rig(); defer { w.close() }
        let label = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10)); row.addSubview(label)
        row.mouseEntered(with: event(.mouseMoved, at: NSPoint(x: 50, y: 16), in: w))
        row.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 50, y: 16), in: w))
        XCTAssertEqual(label.alphaValue, 1)
    }
}

/// The Energy Mode badge turns on the measured spring, in real time.
@MainActor
final class ModeRowBadgeTurnTests: XCTestCase {
    private func progress(of row: ModeRow, badge: BadgeView) -> Double {
        // The red of the badge over a mid grey backdrop: the idle badge is white at a low alpha, the chosen one is blue.
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        (badge.fill.usingColorSpace(.sRGB) ?? badge.fill).getRed(&r, green: &g, blue: &b, alpha: &a)
        // As it looks over a mid grey backdrop (the badge is translucent).
        return Double(r * a + 0.5 * (1 - a))
    }

    func testTheBadgeIsAboutAQuarterOfTheWayAfterSixtySixMillisecondsAndAllTheWayAfterAHalfSecond() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let row = ModeRow(frame: NSRect(x: 0, y: 0, width: 294, height: 32), mode: .init(id: "low", title: "Low Power", isSelected: false))
        window.contentView?.addSubview(row)
        window.orderFront(nil)
        let badge = try XCTUnwrap(row.subviews.compactMap { $0 as? BadgeView }.first)
        let before = progress(of: row, badge: badge)
        row.setSelected(true, animated: true)
        let start = CACurrentMediaTime()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.066))
        let elapsed = CACurrentMediaTime() - start
        let mid = progress(of: row, badge: badge)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
        let after = progress(of: row, badge: badge)
        let fraction = (mid - before) / (after - before)
        let expected = BatteryMenuMotion.badge(at: elapsed)
        XCTAssertEqual(fraction, expected, accuracy: 0.12, "after \(elapsed) s")
    }
}

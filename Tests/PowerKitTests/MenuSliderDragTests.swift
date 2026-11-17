import XCTest
import AppKit
@testable import PowerKit
@testable import AnodeApp

/// The knob is drawn, and sent to the screen, before the volume is changed: changing the volume is a call into the audio system
/// that can take milliseconds, and a knob that waits for it trails the pointer.
@MainActor
final class MenuSliderDragTests: XCTestCase {

    private func rig() -> (NSWindow, MenuSlider) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let slider = MenuSlider(frame: NSRect(x: 20, y: 10, width: 230, height: 16))
        window.contentView?.addSubview(slider)
        window.orderFrontRegardless()
        slider.displayIfNeeded()
        return (window, slider)
    }

    private func drag(at x: CGFloat, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: x, y: 18), modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func testTheKnobIsDrawnBeforeTheVolumeChangeIsMade() {
        let (window, slider) = rig(); defer { window.close() }
        var wasDrawnWhenTheChangeWasMade: Bool?
        slider.onChange = { _ in wasDrawnWhenTheChangeWasMade = !slider.needsDisplay }
        slider.mouseDragged(with: drag(at: 120, in: window))
        XCTAssertEqual(wasDrawnWhenTheChangeWasMade, true)
    }

    func testEveryPointerSampleOfADragReachesTheSlider() {
        let (window, slider) = rig(); defer { window.close() }
        let before = NSEvent.isMouseCoalescingEnabled
        slider.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 60, y: 18), modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        XCTAssertFalse(NSEvent.isMouseCoalescingEnabled, "while the knob is held, samples are not merged into fewer")
        slider.mouseUp(with: drag(at: 60, in: window))
        XCTAssertEqual(NSEvent.isMouseCoalescingEnabled, before)
    }
}

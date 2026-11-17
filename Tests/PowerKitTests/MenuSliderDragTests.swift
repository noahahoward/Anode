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

    private func press(_ window: NSWindow, at x: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: x, y: 18), modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    // macOS 27's slider knob turns into a glass lens while it is held: bigger than the knob, drawn in place of it.
    func testHoldingTheKnobShowsALensBiggerThanTheKnobCentredOnIt() {
        let (window, slider) = rig(); defer { window.close() }
        slider.value = 0.5
        XCTAssertFalse(slider.lensVisible)
        slider.mouseDown(with: press(window, at: 135))
        XCTAssertTrue(slider.lensVisible)
        let lens = slider.lensFrame
        let knobCentreX = CGFloat(0.5) * (slider.bounds.width - 20) + 10
        XCTAssertEqual(lens.midX, knobCentreX, accuracy: 1)
        XCTAssertEqual(lens.midY, slider.bounds.midY, accuracy: 1)
        XCTAssertGreaterThan(lens.width, 20); XCTAssertGreaterThan(lens.height, 16)
        slider.mouseUp(with: drag(at: 135, in: window))
        XCTAssertFalse(slider.lensVisible)
    }

    func testTheLensFollowsTheKnobWhileItIsDragged() {
        let (window, slider) = rig(); defer { window.close() }
        slider.mouseDown(with: press(window, at: 40))
        let before = slider.lensFrame.midX
        slider.mouseDragged(with: drag(at: 160, in: window))
        XCTAssertGreaterThan(slider.lensFrame.midX, before + 50)
        slider.mouseUp(with: drag(at: 160, in: window))
    }
}

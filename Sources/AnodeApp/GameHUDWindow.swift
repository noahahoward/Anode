import AppKit
import PowerKit

// ── The Game Mode strip (Beta Features) ─────────────────────────────────────
//
// One borderless window with one line of text. The recipe is the one verified over a fullscreen Bloons TD6 on 2026-11-09:
//  - `.screenSaver` level and a collection behaviour that joins every Space and is allowed over a fullscreen app;
//  - it ignores the mouse, so a click reaches the game underneath;
//  - it is ordered front WITHOUT becoming key (`orderFrontRegardless`), so the game keeps keyboard focus.
// The window is made on first use and kept; hiding only orders it out.

final class GameHUDWindow: GameHUDPresenting {

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private static let padding: CGFloat = 8

    private var window: NSWindow?
    private let label = NSTextField(labelWithString: "")

    var isShowing: Bool { window?.isVisible ?? false }

    func size(for text: String) -> CGSize {
        let textWidth = (text as NSString).size(withAttributes: [.font: Self.font]).width
        return CGSize(width: max(120, ceil(textWidth) + 2 * Self.padding), height: GameHUDPlacement.height)
    }

    /// The window, not yet on screen.
    func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: GameHUDPlacement.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none

        let background = NSView(frame: w.contentLayoutRect)
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        background.layer?.cornerRadius = 6
        label.font = Self.font
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byClipping
        background.addSubview(label)
        w.contentView = background
        return w
    }

    func show(text: String, frame: CGRect) {
        let w = window ?? makeWindow()
        window = w
        label.stringValue = text
        w.setFrame(frame, display: false)
        let labelHeight: CGFloat = 14
        label.frame = NSRect(x: Self.padding, y: (frame.height - labelHeight) / 2,
                             width: frame.width - 2 * Self.padding, height: labelHeight)
        w.orderFrontRegardless()
    }

    func hide() { window?.orderOut(nil) }
}

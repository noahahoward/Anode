import AppKit
import PowerKit

// ── The covers (Menu Bar Hider) ─────────────────────────────────────────────
//
// One borderless black panel per run of hidden items. The recipe is the one verified over a fullscreen game (`GameHUDWindow`):
// a non-activating `NSPanel` that does not hide when Anode is inactive, `.screenSaver` level, joins every Space (but not a full-screen app's). Unlike the
// Game Mode strip it does NOT ignore the mouse: a click on a cover is swallowed, so it cannot reach an icon underneath.
// Measured 2026-11-10: a black panel at this level over x 1108-1504 hid Anode's widgets and their neighbours seamlessly, and
// 2026-11-11: the owner's bar is solid black, so black matches it exactly.

final class BarCoverWindows: CoverPresenting {

    static let fill = NSColor.black
    /// Every Space but a full-screen app's: a cover must never be drawn over a full-screen app, which has no menu bar to hide
    /// things in, so `fullScreenAuxiliary` (what lets the Game Mode strip appear there) is deliberately absent.
    static let collectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

    private var panels: [NSPanel] = []
    private(set) var rects: [CGRect] = []

    /// A rectangle in top-left global points (what Accessibility reports) as an AppKit frame (origin bottom-left of the
    /// primary screen). Pure.
    static func appKitFrame(forTopLeft rect: CGRect, primaryScreenHeight: CGFloat) -> NSRect {
        NSRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    func show(_ rects: [CGRect], on screen: CGRect) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.height
        while panels.count < rects.count { panels.append(makePanel()) }
        for (i, rect) in rects.enumerated() {
            let panel = panels[i]
            panel.setFrame(Self.appKitFrame(forTopLeft: rect, primaryScreenHeight: primaryHeight), display: true)
            panel.orderFrontRegardless()
        }
        for extra in panels.dropFirst(rects.count) { extra.orderOut(nil) }
        self.rects = rects
    }

    func removeAll() {
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels.removeAll()
        rects = []
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.hidesOnDeactivate = false
        p.level = .screenSaver
        p.identifier = NSUserInterfaceItemIdentifier(BarPictures.hiderWindowIdentifier)
        p.collectionBehavior = Self.collectionBehavior
        p.isOpaque = true
        p.backgroundColor = Self.fill
        p.hasShadow = false
        p.ignoresMouseEvents = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        return p
    }
}

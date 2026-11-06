import AppKit

// ── The black windows of the keyboard cleaner ───────────────────────────────
//
// One borderless pure-black window per display, covering the whole display (menu bar and Dock included), above everything
// else (the shielding level is what the system uses for its own full-screen takeovers), on every Space. Each carries one line
// in its bottom-left corner: the combination that ends the session.
//
// The windows draw and nothing else: all input is swallowed by the tap (`CleanerInputTap`) before it can reach them. While
// they are up Anode is the active app and the pointer is hidden, because a pointer frozen on a black screen reads as a hang.

final class CleanerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class CleanerWindows: CleanerWindowPresenting {

    static let margin: CGFloat = 24

    private var windows: [NSWindow] = []
    private var pointerHidden = false
    private var previousApp: NSRunningApplication?

    var isShowing: Bool { !windows.isEmpty }

    /// One window frame per display: exactly the display.
    static func frames(for screens: [NSRect]) -> [NSRect] { screens }

    /// Where the hint's lower-left corner goes, in the same coordinates as `frame`.
    static func hintOrigin(in frame: NSRect, hintSize: NSSize) -> NSPoint {
        NSPoint(x: frame.minX + margin, y: frame.minY + margin)
    }

    static func makeWindow(frame: NSRect, hint: String) -> NSWindow {
        let w = CleanerWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.setFrame(frame, display: false)
        w.isReleasedWhenClosed = false
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.backgroundColor = .black
        w.isOpaque = true
        w.hasShadow = false
        w.animationBehavior = .none
        w.ignoresMouseEvents = false

        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        let label = NSTextField(labelWithString: hint)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.55)
        label.sizeToFit()
        let origin = hintOrigin(in: frame, hintSize: label.frame.size)
        label.setFrameOrigin(NSPoint(x: origin.x - frame.minX, y: origin.y - frame.minY))
        content.addSubview(label)
        w.contentView = content
        return w
    }

    func show(hint: String, on screens: [NSScreen]) {
        closeWindows()
        for frame in Self.frames(for: screens.map(\.frame)) {
            let w = Self.makeWindow(frame: frame, hint: hint)
            w.orderFrontRegardless()
            windows.append(w)
        }
        guard !windows.isEmpty else { return }
        if !pointerHidden {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
            NSApp.activate(ignoringOtherApps: true)
            NSCursor.hide()
            pointerHidden = true
        }
        windows.first?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        closeWindows()
        if pointerHidden {
            NSCursor.unhide()
            pointerHidden = false
            previousApp?.activate()
            previousApp = nil
        }
    }

    private func closeWindows() {
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
    }
}

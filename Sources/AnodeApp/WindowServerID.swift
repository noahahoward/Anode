import AppKit

// ── An NSWindow's number as the window server's id ──────────────────────────
//
// `NSWindow.windowNumber` is an Int, and -1 for a window the window server does not know yet: one that has
// never been ordered on screen (a Beta Features, Settings or panel window that is built and kept). `CGWindowID`
// is unsigned, and `CGWindowID(-1)` is not a conversion that fails, it is a Swift runtime trap ("Not enough bits
// to represent the passed value") that ends the app. It did exactly that on a MacBook Neo (macOS 27.2) the first
// time the window switcher was used to go to one of Anode's own windows: `ownWindow` converted EVERY window of the
// app to compare it with the chosen one, and one of them had never been shown.

extension NSWindow {
    /// The window server's id for this window, or nil when it has none (never shown, or gone).
    var windowServerID: CGWindowID? {
        windowNumber > 0 ? CGWindowID(exactly: windowNumber) : nil
    }
}

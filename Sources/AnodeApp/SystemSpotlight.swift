import AppKit
import ApplicationServices

// ── The system's own search, out of the way ─────────────────────────────────
//
// On this macOS ⌘Space opens "Search or Ask", a panel that the Siri process hosts. It does not close when another panel opens over it,
// so Clipboard History, opened with Spotlight on screen, stood on top of it. Before the panel opens, Spotlight is shut the way a
// person shuts it: Escape. The key goes to the Siri process alone (`postToPid`), so it can reach nothing else, whatever has the focus.
//
// Measured (macOS 27.3, by logging the window list every few milliseconds): the panel is a window of the process named "Siri", at
// layer 23, alpha 1 while open. When it closes it fades to alpha 0 and stays in the window list at the size of the screen, so a window
// that is there is not enough: it has to be visible. Escape closes it at once when the field is empty; with something typed the first
// Escape clears the field and the second closes it.

enum SystemSpotlight {

    /// The process that hosts the system's search.
    static let hostName = "Siri"
    /// A window this faded is gone (the panel keeps one at alpha 0 after it closes).
    static let visibleAlpha: Double = 0.05
    /// Escape is sent again this long after, if Spotlight is still on screen: the first can only have cleared what was typed.
    static let retryDelays: [TimeInterval] = [0.12, 0.3]

    /// The process id of Siri when one of its windows is on screen and not faded away, from a window list as the system gives it
    /// (`CGWindowListCopyWindowInfo`). Pure, so it is tested without a screen.
    static func openHost(in windows: [[String: Any]]) -> pid_t? {
        for window in windows where (window[kCGWindowOwnerName as String] as? String) == hostName {
            let alpha = (window[kCGWindowAlpha as String] as? Double) ?? 1
            guard alpha > visibleAlpha, let pid = window[kCGWindowOwnerPID as String] as? Int else { continue }
            return pid_t(pid)
        }
        return nil
    }

    /// The Siri process, if its search is open now.
    static func openHost() -> pid_t? {
        openHost(in: CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
    }

    /// Shuts the search if it is open: Escape to the Siri process, again if it is still there a moment later. Nothing happens when it
    /// is not open, or without Accessibility (which macOS requires to post a key).
    static func closeIfOpen() {
        guard AXIsProcessTrusted(), let pid = openHost() else { return }
        pressEscape(pid)
        for delay in retryDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if let pid = openHost() { pressEscape(pid) }
            }
        }
    }

    private static func pressEscape(_ pid: pid_t) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down) else { return }
            event.postToPid(pid)
        }
    }
}

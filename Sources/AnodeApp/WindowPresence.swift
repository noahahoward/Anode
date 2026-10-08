import AppKit

/// Whether a window the app believes it is showing is one the user can see.
///
/// The two are not the same thing, and assuming they were is the bug behind
/// "Anode is in the menu bar and the Dock but the window will not open".
///
/// MEASURED inside a stuck process with a debugger, after a day and a half up:
///
///     isVisible        = 1      AppKit: already ordered in
///     isMiniaturized   = 0
///     isOnActiveSpace  = 0
///     SLSCopySpacesForWindows  -> ()   the window server: on NO Space at all
///
/// and the one Space on the display had a different id and uuid from the one it
/// had two days earlier. macOS had rebuilt the Space underneath the app and the
/// window was not carried across. From then on every way of opening it was a
/// no-op, each for its own reason:
///
///   * `makeKeyAndOrderFront` — AppKit thinks the window is already in front;
///   * `toggle()` — "visible and active" was true, so a click HID a window
///     nobody could see;
///   * the Dock icon — `applicationShouldHandleReopen` is told
///     `hasVisibleWindows: true` and did nothing.
///
/// Tried on that same live process, in this order: `orderOut` then
/// `makeKeyAndOrderFront` did NOT bring it back; `.moveToActiveSpace`, then
/// `orderOut`, then `orderFrontRegardless` did — the window server listed it on
/// the current Space immediately afterwards. So recovery is all three steps, and
/// the collection behaviour is set at construction so the window follows the
/// active Space in the first place instead of needing rescue.
enum WindowPresence {

    /// Ordered in as far as AppKit knows, and on no Space the user is looking at.
    ///
    /// A miniaturized window is excluded: it is in the Dock on purpose, and
    /// `deminiaturize` is what brings that back.
    static func isStranded(isVisible: Bool, isOnActiveSpace: Bool,
                           isMiniaturized: Bool) -> Bool {
        isVisible && !isOnActiveSpace && !isMiniaturized
    }

    /// The question `toggle()` and the Dock actually mean when they ask whether
    /// the window is open: could a person see it if nothing were in front of it.
    static func isPresented(isVisible: Bool, isOnActiveSpace: Bool) -> Bool {
        isVisible && isOnActiveSpace
    }

    /// Windows waiting for the runloop turn after a policy change to be shown.
    /// Main-thread only. `AppPresence.settle` reads it so the tile is not taken
    /// away again in the gap.
    fileprivate(set) static var pendingPresentations = 0
    static var isPresenting: Bool { pendingPresentations > 0 }
}

extension NSWindow {

    var isStranded: Bool {
        WindowPresence.isStranded(isVisible: isVisible, isOnActiveSpace: isOnActiveSpace,
                                  isMiniaturized: isMiniaturized)
    }

    var isPresented: Bool {
        WindowPresence.isPresented(isVisible: isVisible, isOnActiveSpace: isOnActiveSpace)
    }

    /// For a window that belongs to a menu bar tool: it should appear where the
    /// user is, not pull them to wherever it was last left — and not be lost
    /// when that place stops existing.
    func followActiveSpace() {
        collectionBehavior.insert(.moveToActiveSpace)
    }

    /// Put the window in front of the user, from whatever state it is in, and
    /// make the app frontmost.
    ///
    /// The one way every window in this app is shown, so the three recoveries
    /// cannot be remembered at one call site and forgotten at the next.
    ///
    /// The app is `.accessory` while it has no window (see `AppPresence`), and
    /// a window needs `.regular` to get an application menu. The policy change
    /// and the ordering front are kept in SEPARATE runloop turns: doing both in
    /// one is the pattern that was suspected, though never shown, to leave the
    /// process unable to put any window on screen. When the policy is already
    /// `.regular` nothing is deferred.
    func bringForward() {
        guard NSApp.activationPolicy() != .regular else { return present() }
        NSApp.setActivationPolicy(.regular)
        WindowPresence.pendingPresentations += 1
        DispatchQueue.main.async { [self] in
            WindowPresence.pendingPresentations -= 1
            present()
        }
    }

    private func present() {
        followActiveSpace()
        // Not restored by ordering front; the two are different operations.
        if isMiniaturized { deminiaturize(nil) }
        // Ordering front a window AppKit already believes is in front does
        // nothing, so a stranded one has to be taken out first.
        if isStranded { orderOut(nil) }
        makeKeyAndOrderFront(nil)
        // `makeKeyAndOrderFront` alone was the step that failed in the stuck
        // process; this is the call that was seen to work.
        orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
}

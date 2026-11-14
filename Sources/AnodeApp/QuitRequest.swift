import AppKit

/// A quit asked for from outside the app (`tell application id "dev.anode.app" to quit`, the Dock's Quit, a logout)
/// gets through a dialog that is on screen.
///
/// AppKit's own handler refuses the quit Apple event while a sheet or an app-modal dialog is up, and the sender gets
/// "user cancelled" (-128). Anode puts one up by itself on a first launch (the question about automatic updates, then
/// the helper's notice), which is exactly when a script asks it to quit: `update.sh` and `uninstall.sh` on a freshly
/// installed Mac found Anode still running, replaced or removed the bundle under it, or stopped. A logout was held up
/// the same way.
///
/// So the quit event is handled here. Nothing in the way: `terminate` at once, as AppKit does. A sheet or a modal
/// dialog in the way: each is dismissed with `.abort`, which no dialog in the app takes for a yes (they all compare
/// with the first button, or with OK), and `terminate` follows once the modal loop has unwound. `underway` is true from
/// then on, so a dialog whose dismissal means "do not ask again" can tell being dismissed from being answered.
final class QuitRequest: NSObject {

    static let shared = QuitRequest()

    /// The app as far as a quit needs it. The real one is `NSApplication`; a test gives closures.
    struct Host {
        /// One closure for each sheet that is up, which ends it without an answer.
        var sheetEnders: () -> [() -> Void]
        var modalIsRunning: () -> Bool
        var abortModal: () -> Void
        var terminate: () -> Void
        /// Runs `work` on a later turn of the main run loop, also while a modal loop is still unwinding.
        var later: (@escaping () -> Void) -> Void

        static let real = Host(
            sheetEnders: {
                NSApp.windows.compactMap { window in
                    guard let sheet = window.attachedSheet else { return nil }
                    return { window.endSheet(sheet, returnCode: .abort) }
                }
            },
            modalIsRunning: { NSApp.modalWindow != nil },
            // `stopModal`, not `abortModal`: that one has been documented as raising an exception for the modal loop to
            // catch, which would unwind through this handler and whatever dispatched the Apple event, and nothing
            // after it would run. A stop is looked at only after the modal loop's next event, and the handler is
            // called from the run loop and not from one, so an event is posted for it to find.
            abortModal: {
                NSApp.stopModal(withCode: .abort)
                if let nudge = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                                  context: nil, subtype: 0, data1: 0, data2: 0) {
                    NSApp.postEvent(nudge, atStart: true)
                }
            },
            terminate: { NSApp.terminate(nil) },
            later: { work in DispatchQueue.main.asyncAfter(deadline: .now() + QuitRequest.unwindInterval, execute: work) })
    }

    /// How long a modal loop is given to unwind between looks, and how many looks it gets. After the last one the app
    /// terminates all the same: a quit that was asked for is not dropped.
    static let unwindInterval: TimeInterval = 0.05
    static let unwindLooks = 40

    /// A quit from outside has arrived and dismissed something on its way.
    private(set) var underway = false

    /// Takes the quit Apple event over from AppKit. After launch has finished: AppKit installs its own handlers while
    /// it finishes launching, and the last one registered is the one that is called.
    func install() {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handle(_:withReplyEvent:)),
                                                     forEventClass: AEEventClass(kCoreEventClass),
                                                     andEventID: AEEventID(kAEQuitApplication))
    }

    @objc private func handle(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        run(host: .real, cause: RunTrace.quitCause())
    }

    /// `cause` is who asked, read while the event is still the current one: by the time a deferred `terminate` runs it
    /// is not, and the run log would say nobody asked.
    func run(host: Host, cause: String? = nil) {
        let enders = host.sheetEnders()
        let modal = host.modalIsRunning()
        // Nothing is in the way: inside this event, as AppKit's own handler would.
        guard !enders.isEmpty || modal else { return host.terminate() }
        underway = true
        RunTrace.causeOfADeferredQuit = cause.map { "\($0); a dialog on screen was dismissed for it" }
        // The terminate is put in place before anything is dismissed: whatever dismissing a dialog does to this
        // call (see `Host.real`), the quit that was asked for still happens.
        terminateOnceUnwound(host, looksLeft: Self.unwindLooks)
        for end in enders { end() }
        if modal { host.abortModal() }
    }

    private func terminateOnceUnwound(_ host: Host, looksLeft: Int) {
        host.later { [self] in
            if host.modalIsRunning(), looksLeft > 1 {
                terminateOnceUnwound(host, looksLeft: looksLeft - 1)
            } else {
                host.terminate()
            }
        }
    }
}

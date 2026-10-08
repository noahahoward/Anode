import Foundation

/// The folders macOS gates behind a consent prompt.
///
/// Reading a file under one of these raises a TCC dialog the FIRST time, and a
/// menu bar app is the worst possible place to raise one: when the window is
/// closed there is nothing on screen to attach it to, the request can go
/// unanswered, and until it is answered the app cannot show a window at all.
/// Observed exactly that — `tccd` attributing a Downloads request to Anode every
/// ~40 s for hours, the app frontmost with its menu bar drawn and no window,
/// cleared only by relaunching.
///
/// Anode reads other processes' executables for two cosmetic facts: the code
/// signature (`CodeSignature.origin`) and the display name on an `.app` bundle.
/// NEITHER is worth a consent prompt. A user who keeps a binary in Downloads
/// gets the same answer a daemon already gets — the executable's own name, and
/// an unknown origin — which both callers already render correctly.
///
/// This is a PATH test, not a file read: nothing here touches the disk, so
/// asking the question cannot itself trigger what it exists to avoid.
enum ProtectedPath {

    /// Trailing slash on each root so `/Users/me/Downloads-old/x` is not matched
    /// as being inside `/Users/me/Downloads`.
    private static let roots: [String] = {
        let home = NSHomeDirectory()
        return ["Downloads", "Desktop", "Documents",
                // iCloud Drive, which is where "Desktop & Documents" actually
                // live once that sync option is on.
                "Library/Mobile Documents"]
            .map { "\(home)/\($0)/" }
    }()

    /// True when reading this path could raise a consent prompt.
    static func isGated(_ path: String) -> Bool {
        roots.contains { path.hasPrefix($0) }
    }
}

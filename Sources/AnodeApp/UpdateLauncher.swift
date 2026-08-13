import AppKit
import PowerKit

/// Opens `update.sh` in a Terminal window.
///
/// ── WHY THE SCRIPT COMES FROM THE BUNDLE ────────────────────────────────────
///
/// The first version ran `update.sh` out of the checkout. That works right up
/// until the checkout is at a commit where the file does not exist — and moving
/// the checkout is exactly what an update does, so the failure is reachable by
/// ordinary use. Observed: `git reset --hard HEAD~1` onto a commit from before
/// the updater was written, after which the Update button reported its own
/// script missing. A tool that repairs a checkout cannot be stored in the
/// checkout at the version it is repairing.
///
/// So `build-app.sh` copies the script into `Contents/Resources`, this runs THAT
/// copy, and the checkout is passed to it as an argument. The bundled script
/// always matches the build the user is looking at.
///
/// ── AND WHY A `.command` WRAPPER ────────────────────────────────────────────
///
/// LaunchServices opens a file with an application; it does not pass arguments.
/// So a tiny wrapper is written that calls the real script with the path, and
/// THAT is what Terminal opens — the same shape `FanElevation` uses, for the
/// same reason: it needs no Automation permission and cannot be silently denied
/// by TCC.
enum UpdateLauncher {

    enum Outcome: Equatable {
        case openedTerminal(scriptPath: String)
        case failed(String)
    }

    /// In the app's own support directory rather than a shared temp dir.
    static var wrapperURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Anode/update.command")
    }

    /// The bundled updater, or nil for a build that predates it — a `swift run`
    /// binary has no bundle at all.
    static func bundledScript(in bundle: Bundle = .main) -> String? {
        guard let path = bundle.path(forResource: "update", ofType: "sh"),
              FileManager.default.isReadableFile(atPath: path) else { return nil }
        return path
    }

    /// The wrapper's text. Pure, so what the user is about to be shown can be
    /// asserted in tests rather than discovered in a Terminal window.
    static func wrapper(script: String, checkout: String) -> String {
        """
        #!/bin/sh
        # Written by Anode immediately before this window opened, and rewritten
        # every time. Running it by hand does exactly what the button does.
        #
        # The updater itself lives inside Anode.app so that it still exists when
        # the checkout is at an older commit. It pulls, rebuilds, and relaunches.
        exec \(shellQuoted(script)) \(shellQuoted(checkout))
        """
    }

    /// Single quotes, with embedded quotes closed and reopened — the one form
    /// that survives a path containing spaces, which this project's own checkout
    /// has ("better stats app").
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    static func launch(checkout: String, bundle: Bundle = .main) -> Outcome {
        guard let script = bundledScript(in: bundle) else {
            return .failed("This build does not carry an updater. "
                         + "Run ./update.sh in your checkout.")
        }
        let url = wrapperURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try wrapper(script: script, checkout: checkout)
                .write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: url.path)
        } catch {
            return .failed("Could not prepare the update: \(error.localizedDescription)")
        }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
        return .openedTerminal(scriptPath: url.path)
    }
}

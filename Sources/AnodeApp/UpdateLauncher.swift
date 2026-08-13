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
    static func wrapperURL(named name: String) -> URL {
        supportDirectory.appendingPathComponent(name)
    }

    static var supportDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Anode")
    }

    static var wrapperURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Anode/update.command")
    }

    /// The bundled updater, or nil for a build that predates it — a `swift run`
    /// binary has no bundle at all.
    static func bundledScript(_ name: String, in bundle: Bundle = .main) -> String? {
        guard let path = bundle.path(forResource: name, ofType: "sh"),
              FileManager.default.isReadableFile(atPath: path) else { return nil }
        return path
    }

    static func bundledScript(in bundle: Bundle = .main) -> String? {
        bundledScript("update", in: bundle)
    }

    /// Uninstalling runs from the BUNDLE for the same reason updating does, and
    /// one better: it is about to delete the app, and on a machine installed by
    /// `install.sh` the checkout may be somewhere the app never recorded.
    @discardableResult
    static func launchUninstall(removingData: Bool, bundle: Bundle = .main) -> Outcome {
        guard let script = bundledScript("uninstall", in: bundle) else {
            return .failed("This build does not carry an uninstaller. "
                         + "Run ./uninstall.sh in your checkout.")
        }
        // `--yes` because the dialog that got here listed the same paths. The
        // script still PRINTS them, so the window shows what happened.
        var args = ["--yes"]
        if removingData { args.append("--data") }
        return open(script: script, arguments: args, wrapper: "uninstall.command")
    }

    /// The wrapper's text. Pure, so what the user is about to be shown can be
    /// asserted in tests rather than discovered in a Terminal window.
    static func wrapper(script: String, arguments: [String]) -> String {
        let args = arguments.map(shellQuoted).joined(separator: " ")
        let call = shellQuoted(script) + (args.isEmpty ? "" : " " + args)
        return [
            "#!/bin/sh",
            "# Written by Anode immediately before this window opened, and",
            "# rewritten every time. Running it by hand does exactly what the",
            "# button does.",
            "exec " + call,
            "",
        ].joined(separator: "\n")
    }

    /// The update case, kept as its own signature because a checkout path is
    /// not just any argument — it is the one thing the updater cannot guess.
    static func wrapper(script: String, checkout: String) -> String {
        wrapper(script: script, arguments: [checkout])
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
        return open(script: script, arguments: [checkout], wrapper: "update.command")
    }

    /// Write the wrapper and hand it to Terminal.
    private static func open(script: String, arguments: [String],
                             wrapper name: String) -> Outcome {
        let url = wrapperURL(named: name)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try wrapper(script: script, arguments: arguments)
                .write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: url.path)
        } catch {
            return .failed("Could not prepare that: " + error.localizedDescription)
        }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
        return .openedTerminal(scriptPath: url.path)
    }
}

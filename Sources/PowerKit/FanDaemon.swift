import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// ONE BUTTON, ONE AUTHORISATION, AND THEN IT KEEPS WORKING.
//
// The question this file answers: Stats has a single "Install Fan Helper" button
// that asks for a password once and then works forever, with no Terminal. How,
// without an Apple Developer ID — which this project is never getting, and any
// design beginning "obtain a Developer ID" is not a design.
//
// Stats does it with SMJobBless: launchd verifies a Developer ID signature and
// installs a privileged LaunchDaemon. That specific mechanism is closed to us.
// The USER EXPERIENCE is not, and this is the part worth being precise about.
//
// ── THE ROUTES, AND WHY THIS ONE ────────────────────────────────────────────
//
// SMJobBless — needs a Developer ID. Its whole contract is that launchd checks
// the helper's designated requirement against the app's, and on an ad-hoc
// signature the designated requirement is a bare cdhash. Measured on this
// machine's own installed bundle:
//
//     $ codesign -d --requirements - ~/Applications/BetterStats.app
//     designated => cdhash H"3a4c876a97cf1770714f3ee3276592ee523a1f7d"
//     Signature=adhoc   TeamIdentifier=not set
//
// There is nothing in that requirement but a hash of this exact build. Rejected.
//
// SMAppService.daemon(plistName:) — macOS 13+, and the modern replacement. Not
// guessed at either; Apple's own header on this machine settles it, in
// ServiceManagement.framework/Headers/SMAppService.h:
//
//     "For SMAppServices initialized as LaunchDaemons, the register and
//      unregister APIs provide a replacement for installing plists in
//      /Library/LaunchDaemons. APPS THAT CONTAIN LAUNCHDAEMONS MUST BE
//      NOTARIZED."
//     "If the app bundle is not properly code signed, this API will return error
//      kSMErrorInvalidSignature"
//
// Notarisation requires a Developer ID. Rejected — and note this is a documented
// refusal, not a bug to work around.
//
// There is a second, independent reason to reject it that would still apply if
// registration somehow succeeded. An SMAppService daemon runs a program INSIDE
// THE APP BUNDLE (that is what the `BundleProgram` key is for). The bundle lives
// in ~/Applications and is writable by you. Root executing a binary out of a
// user-writable directory is a privilege escalation waiting for the first thing
// that can write your home directory — Apple closes that hole with the
// notarisation requirement, and we cannot. Any design that has root run code
// from the app bundle is worse than the problem it solves.
//
// AuthorizationExecuteWithPrivileges — deprecated since 10.7 and gone from the
// SDK. Not a route.
//
// AN ADMIN-AUTHORISED INSTALL — what is implemented. The same header says why it
// works, in the same paragraph:
//
//     "Legacy LaunchDaemons installed in /Library/LaunchDaemons will continue to
//      be bootstrapped without explicit approval in System Settings SINCE
//      WRITING TO /LIBRARY IS PROTECTED WITH FILESYSTEM PERMISSIONS."
//
// That is the whole mechanism, stated by Apple: the permission on the directory
// IS the check. No signature is consulted, so there is nothing for the lack of a
// certificate to fail. A plist there is bootstrapped at every boot, forever,
// until it is removed.
//
// So: one admin authorisation copies the helper to a root-owned directory and
// writes a plist naming it. After that there is no prompt, ever — not on the next
// launch, not after a rebuild, not after a reboot.
//
// ── HOW THE PIN SURVIVES A REBUILD ──────────────────────────────────────────
//
// This is the part that killed the first draft of fan control, and it is not
// solved by being cleverer about hashing. An ad-hoc cdhash changes on every
// build. A daemon that pins one is broken by the next `./build-app.sh`, and the
// repair is another admin prompt — which trains a user to type their password
// whenever an app asks. That is a worse hole than the one the pin closes.
//
// Two things make it survive here, and neither is airtight on its own:
//
//   1. WHAT RUNS AS ROOT NEVER CHANGES. The helper is COPIED to
//      /Library/PrivilegedHelperTools at install time. Rebuilding the app does
//      not touch it. Nothing you build later can become the root process; only
//      an explicit reinstall, with its own authorisation, replaces it.
//
//   2. WHAT IT LISTENS TO IS PINNED BY SIGNING IDENTIFIER, not by hash.
//      `dev.noah.betterstats` comes from CFBundleIdentifier and is the same in
//      every build. `FanClientPin.signingIdentifier` states in full what that
//      stops and what it does not, and the short version is repeated here
//      because it is the price of the button: ANYONE WHO CAN RUN `codesign -s -
//      -i dev.noah.betterstats` ON THEIR OWN BINARY SATISFIES IT. Verified:
//
//          $ cc -o notmine t.c
//          $ codesign --force --sign - -i dev.noah.betterstats notmine
//          $ codesign -dvv notmine
//          Identifier=dev.noah.betterstats   Signature=adhoc   valid on disk
//
//      So the installed daemon's real boundary is the uid check, which is the
//      kernel's and cannot be forged, plus a vocabulary of two commands whose
//      values the fan's own firmware clamps. It is not "only this app". Saying
//      it were would be the overstatement this project keeps refusing to make.
//
// ── WHAT A USER IS AGREEING TO ──────────────────────────────────────────────
//
// Before installing: nothing of this project runs as root, ever, unless the user
// starts the session helper by hand.
//
// After installing: a root process is running at all times whose entire ability
// is to set a fan target within the range the fan itself reports, on request from
// the uid that installed it. Anything running as that user can ask. An attacker
// who takes it can make the machine loud, or hold a fan where the firmware would
// also hold it — the SMC arbitrates and has been observed clamping a written
// target upward. It cannot read anything, cannot write any other SMC key, cannot
// run anything, and has no path or key name in its input.
//
// The undo is one button and removes every trace, including handing the fans
// back. `FanHelperInstall.artifacts` is the list, and it is asserted complete.
// ─────────────────────────────────────────────────────────────────────────────

/// Names, paths and versions for the installed fan daemon. One place, because a
/// path that appears in the installer and again in the uninstaller is a path that
/// will eventually disagree with itself.
public enum FanDaemon {

    /// Distinct from `FanHelperInstall.retiredDaemonLabel`, which named the first
    /// draft's daemon. A user may still have that one loaded; they are not the
    /// same job and must not share a label.
    public static let label = "dev.noah.betterstats.fanhelper"

    /// Root-owned, root-writable-only. The point of copying the helper here is
    /// that neither a rebuild nor anything running as the user can change what
    /// runs as root.
    public static let helperPath = "/Library/PrivilegedHelperTools/\(label)"
    public static let helperDirectory = "/Library/PrivilegedHelperTools"
    public static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    public static let launchDaemonDirectory = "/Library/LaunchDaemons"

    /// The signing identifier the installed daemon will answer. From
    /// CFBundleIdentifier, so it is identical in every build of this app — which
    /// is the only reason the install survives a rebuild. See
    /// `FanClientPin.signingIdentifier` for what that costs.
    public static let clientSigningIdentifier = "dev.noah.betterstats"

    /// Bumped when the socket protocol changes in a way an older daemon cannot
    /// serve.
    ///
    /// This exists because of a real consequence of the design above: the
    /// installed daemon is a FROZEN COPY, so an app rebuilt six months later
    /// talks to a helper built today. Without a version on the wire that goes
    /// wrong silently. With one, the app can say "the installed fan helper is
    /// older than this build" and offer to reinstall.
    public static let protocolVersion = 1

    /// The argument that tells the helper it is the installed daemon rather than
    /// a session helper. The difference is the pin and nothing else.
    public static let serveArgument = "--serve"
    public static let installArgument = "--install"

    // ── What the app can see without any privilege ──────────────────────────

    /// Is the daemon installed? True when its plist is where launchd reads
    /// plists. Readable by anyone; installing is what needs the authorisation.
    public static func isInstalled(fileManager fm: FileManager = .default) -> Bool {
        fm.fileExists(atPath: plistPath)
    }

    /// What the app knows about the privileged half, as one value.
    ///
    /// Pure, and derived from two observations, so every sentence the UI can
    /// print about the install is decided somewhere a test can reach.
    public enum State: Equatable {
        /// No plist. The shipped state: nothing of this project runs as root.
        case notInstalled
        /// Installed and answering.
        case running
        /// The plist is there and nothing answered. launchd should have started
        /// it, so this is a fault rather than a normal state.
        case installedButSilent
        /// Answering, but built before this app was — the frozen-copy problem.
        case installedButOlder(daemonVersion: Int)
    }

    /// `helloVersion` is the `version` field of the daemon's answer to `hello`,
    /// or nil if nothing answered. An answering helper that reports no version at
    /// all is a build from before the field existed, which is version 1.
    public static func state(installed: Bool,
                             answered: Bool,
                             helloVersion: Int?,
                             appVersion: Int = protocolVersion) -> State {
        guard installed else { return .notInstalled }
        guard answered else { return .installedButSilent }
        let daemon = helloVersion ?? 1
        return daemon < appVersion ? .installedButOlder(daemonVersion: daemon) : .running
    }

    /// Which of the two install buttons the strip offers, if either.
    ///
    /// `bundled` is false for a bare `swift build` binary. Neither button is
    /// offered there: the install would be refused (nothing to copy that signs
    /// correctly) and the uninstall names a helper path that does not exist.
    public enum Button: Equatable {
        case install
        case uninstall
        case none
    }

    public static func button(installed: Bool, bundled: Bool) -> Button {
        guard bundled else { return .none }
        return installed ? .uninstall : .install
    }

    /// One sentence per state, for the strip. Here rather than in the view so the
    /// wording is testable and so a state cannot be added without someone having
    /// to say what it looks like.
    public static func summary(_ state: State) -> String {
        switch state {
        case .notInstalled:
            return "The fan helper is not installed. Nothing of BetterStats runs as root."
        case .running:
            return "The fan helper is installed and running."
        case .installedButSilent:
            return "The fan helper is installed but is not answering. "
                 + "Uninstalling and installing again replaces it."
        case .installedButOlder(let v):
            return "The installed fan helper is older than this build "
                 + "(version \(v), this app speaks \(protocolVersion)). "
                 + "Install it again to replace it."
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Installing the daemon: what will be done, said as data first.
///
/// The plan is separate from the doing because everything here happens as root
/// on a machine that is not a test machine. A plan can be printed, asserted,
/// shown to the user in a sheet and diffed against what an uninstall removes.
/// `perform` is a small loop over it that adds no decisions of its own.
public enum FanDaemonInstall {

    // ── The plan ────────────────────────────────────────────────────────────

    public struct Step: Equatable {
        public enum Action: Equatable {
            case makeDirectory
            case copy(from: String)
            case write(Data)
            /// launchctl, mostly. `path` is empty for these.
            case run(executable: String, arguments: [String])
        }
        public let action: Action
        /// Absolute, and for a `.run` step the empty string.
        public let path: String
        /// Applied after the file lands, explicitly, because `bind`/`copy` apply
        /// the process umask and a root binary at the umask's mercy is not a
        /// thing to ship.
        public let mode: mode_t
        /// chown root:wheel. Every file this installs is root-owned; a
        /// user-writable file that root executes is the escalation the whole
        /// copy-to-/Library exists to avoid.
        public let ownedByRoot: Bool

        public init(action: Action, path: String, mode: mode_t, ownedByRoot: Bool) {
            self.action = action
            self.path = path
            self.mode = mode
            self.ownedByRoot = ownedByRoot
        }
    }

    public struct Plan: Equatable {
        public let steps: [Step]
        /// The user the daemon will serve — the one who authorised the install.
        public let ownerUID: uid_t
        /// The helper being copied.
        public let source: String
    }

    public enum Refusal: Error, Equatable, LocalizedError {
        case noSuchHelper(String)
        case notInsideAnAppBundle(String)
        case ownerWouldBeRoot
        case wrongSigningIdentifier(found: String?)

        public var errorDescription: String? {
            switch self {
            case .noSuchHelper(let p):
                return "There is no fan helper at \(p) to install."
            case .notInsideAnAppBundle(let p):
                return "\(p) is not inside a BetterStats.app. Only a bundled build "
                     + "can be installed — run ./build-app.sh and install from "
                     + "~/Applications/BetterStats.app."
            case .ownerWouldBeRoot:
                return "The fan helper serves one ordinary user and would serve "
                     + "nobody if installed for root. Run the app as yourself."
            case .wrongSigningIdentifier(let found):
                // The install would "succeed" and then refuse every connection,
                // which is the worst kind of working.
                return "This build signs as \(found ?? "nothing readable"), but the "
                     + "fan helper only answers \(FanDaemon.clientSigningIdentifier). "
                     + "Installing it would produce a daemon that refuses this app."
            }
        }
    }

    /// What installing from `sourceHelper` would do.
    ///
    /// `sourceHelper` is the helper inside the app bundle — the bundle is derived
    /// from it rather than passed separately, so the thing being copied and the
    /// thing being trusted cannot come from two different places.
    public static func plan(
        sourceHelper: String,
        ownerUID: uid_t,
        clientIdentifier: String?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Result<Plan, Refusal> {

        guard fileExists(sourceHelper) else { return .failure(.noSuchHelper(sourceHelper)) }
        // A `swift build` binary has no bundle and is signed by the linker under
        // an identifier like `BetterStatsHelper-3f2a…`, so a daemon installed from
        // one would refuse the app it was installed for. Refused here, where the
        // message can say what to do.
        let bundle = URL(fileURLWithPath: sourceHelper)
            .deletingLastPathComponent()    // MacOS
            .deletingLastPathComponent()    // Contents
            .deletingLastPathComponent()    // BetterStats.app
        guard bundle.pathExtension == "app" else {
            return .failure(.notInsideAnAppBundle(sourceHelper))
        }
        guard ownerUID != 0 else { return .failure(.ownerWouldBeRoot) }
        guard clientIdentifier == FanDaemon.clientSigningIdentifier else {
            return .failure(.wrongSigningIdentifier(found: clientIdentifier))
        }

        let plistData: Data
        do { plistData = try plist(ownerUID: ownerUID) }
        catch { return .failure(.noSuchHelper(FanDaemon.plistPath)) }

        return .success(Plan(steps: [
            // 0755, not 0777: this directory is Apple's own home for privileged
            // helpers and already exists on most machines. Created if not.
            Step(action: .makeDirectory, path: FanDaemon.helperDirectory,
                 mode: 0o755, ownedByRoot: true),
            // The copy is the load-bearing step. What runs as root from here on
            // is this file, and only root can replace it.
            Step(action: .copy(from: sourceHelper), path: FanDaemon.helperPath,
                 mode: 0o755, ownedByRoot: true),
            Step(action: .write(plistData), path: FanDaemon.plistPath,
                 mode: 0o644, ownedByRoot: true),
            // Boot out first: an install over a running daemon must replace it,
            // and launchd will not notice a rewritten plist on its own. Failure
            // here is normal on a first install and is not fatal.
            Step(action: .run(executable: "/bin/launchctl",
                              arguments: ["bootout", "system/\(FanDaemon.label)"]),
                 path: "", mode: 0, ownedByRoot: false),
            Step(action: .run(executable: "/bin/launchctl",
                              arguments: ["bootstrap", "system", FanDaemon.plistPath]),
                 path: "", mode: 0, ownedByRoot: false),
        ], ownerUID: ownerUID, source: sourceHelper))
    }

    /// The launchd job.
    ///
    /// `ProgramArguments` names the INSTALLED copy, never the source bundle —
    /// pointing launchd at ~/Applications would have root execute a file the user
    /// can rewrite, which is the hole this whole design avoids.
    ///
    /// `RunAtLoad` + `KeepAlive` is what "never prompts again" means: launchd
    /// starts it at every boot and restarts it if it dies. There is no
    /// `StandardOutPath`; the helper logs to the unified log, so the install
    /// leaves no file that needs rotating or cleaning up.
    public static func plistDictionary(ownerUID: uid_t) -> [String: Any] {
        [
            "Label": FanDaemon.label,
            "ProgramArguments": [FanDaemon.helperPath,
                                 FanDaemon.serveArgument,
                                 "--uid", String(ownerUID)],
            "RunAtLoad": true,
            "KeepAlive": true,
            // Not Interactive: it draws nothing and should be throttled like any
            // other daemon.
            "ProcessType": "Background",
        ]
    }

    public static func plist(ownerUID: uid_t) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plistDictionary(ownerUID: ownerUID),
                                           format: .xml, options: 0)
    }

    // ── Doing it ────────────────────────────────────────────────────────────

    /// The privileged operations, behind a protocol so the whole installer can be
    /// driven in the test suite by something that records instead of doing. There
    /// is no test machine here: the only alternative is to run an installer as
    /// root to find out whether it works, which is how a machine ends up with a
    /// half-installed root daemon.
    public protocol Operations {
        func makeDirectory(_ path: String, mode: mode_t) -> Bool
        func copyFile(from: String, to: String, mode: mode_t) -> Bool
        func writeFile(_ data: Data, to path: String, mode: mode_t) -> Bool
        func setOwnerRoot(_ path: String) -> Bool
        func run(_ executable: String, _ arguments: [String]) -> Int32
    }

    public struct Outcome: Equatable {
        public let path: String
        public let detail: String
        public let ok: Bool
    }

    public struct Report: Equatable {
        public let outcomes: [Outcome]
        public let ok: Bool
    }

    /// Run a plan. Stops at the first failure that matters.
    ///
    /// Stopping is the point. A half-finished install can leave a root-owned
    /// binary with no plist (harmless) or a plist naming a binary that is not
    /// there (launchd retries forever), and continuing past a failed chown could
    /// leave a USER-WRITABLE file that root executes. The one step allowed to
    /// fail is the pre-emptive `bootout`, which fails whenever there was nothing
    /// loaded — i.e. on every first install.
    public static func perform(_ plan: Plan, ops: Operations) -> Report {
        var outcomes: [Outcome] = []

        func fail(_ path: String, _ detail: String) -> Report {
            outcomes.append(Outcome(path: path, detail: detail, ok: false))
            return Report(outcomes: outcomes, ok: false)
        }

        for step in plan.steps {
            switch step.action {
            case .makeDirectory:
                guard ops.makeDirectory(step.path, mode: step.mode) else {
                    return fail(step.path, "could not create the directory")
                }
                outcomes.append(Outcome(path: step.path, detail: "directory ready", ok: true))

            case .copy(let from):
                guard ops.copyFile(from: from, to: step.path, mode: step.mode) else {
                    return fail(step.path, "could not copy \(from)")
                }
                outcomes.append(Outcome(path: step.path,
                                        detail: "copied from \(from)", ok: true))

            case .write(let data):
                guard ops.writeFile(data, to: step.path, mode: step.mode) else {
                    return fail(step.path, "could not write it")
                }
                outcomes.append(Outcome(path: step.path, detail: "written", ok: true))

            case .run(let executable, let arguments):
                let status = ops.run(executable, arguments)
                // launchctl bootout exits non-zero when there was nothing to boot
                // out, which is the ordinary first install. bootstrap failing is
                // real, and it is the last step, so the report says so and the
                // files stay put for a retry.
                let isBootout = arguments.first == "bootout"
                outcomes.append(Outcome(path: executable + " " + arguments.joined(separator: " "),
                                        detail: "exit \(status)",
                                        ok: status == 0 || isBootout))
                if status != 0 && !isBootout {
                    return Report(outcomes: outcomes, ok: false)
                }
                continue
            }

            if step.ownedByRoot, !ops.setOwnerRoot(step.path) {
                // Never continue past this. The next step would write a plist
                // telling launchd to run a file somebody other than root can
                // replace.
                return fail(step.path, "could not give it to root:wheel")
            }
        }
        return Report(outcomes: outcomes, ok: true)
    }

    /// The real thing. Used only by `BetterStatsHelper --install`, which is
    /// already running as root by the time it gets here.
    public struct SystemOperations: Operations {
        private let fm = FileManager.default
        public init() {}

        public func makeDirectory(_ path: String, mode: mode_t) -> Bool {
            if fm.fileExists(atPath: path) {
                return (try? fm.setAttributes([.posixPermissions: NSNumber(value: mode)],
                                              ofItemAtPath: path)) != nil
            }
            return (try? fm.createDirectory(atPath: path, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions:
                                                            NSNumber(value: mode)])) != nil
        }

        public func copyFile(from: String, to: String, mode: mode_t) -> Bool {
            // Removed rather than overwritten: replacing a running binary in
            // place is how you get a killed process with a truncated file where
            // its code used to be.
            try? fm.removeItem(atPath: to)
            guard (try? fm.copyItem(atPath: from, toPath: to)) != nil else { return false }
            return (try? fm.setAttributes([.posixPermissions: NSNumber(value: mode)],
                                          ofItemAtPath: to)) != nil
        }

        public func writeFile(_ data: Data, to path: String, mode: mode_t) -> Bool {
            try? fm.removeItem(atPath: path)
            return fm.createFile(atPath: path, contents: data,
                                 attributes: [.posixPermissions: NSNumber(value: mode)])
        }

        public func setOwnerRoot(_ path: String) -> Bool {
            chown(path, 0, 0) == 0
        }

        public func run(_ executable: String, _ arguments: [String]) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = arguments
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return -1 }
            p.waitUntilExit()
            return p.terminationStatus
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Getting one authorisation dialog, from an app that cannot become root.
///
/// `do shell script … with administrator privileges` is the only mechanism left
/// to an app with no Developer ID: SMJobBless needs one, SMAppService needs
/// notarisation, and `AuthorizationExecuteWithPrivileges` is gone.
///
/// `FanControlPanel` rejected this same mechanism for STARTING the session helper
/// and the reasoning there still holds — "a password box that names no path
/// replaces a check by a person with a reflex". Two things make it acceptable
/// here and they are both about the user being told:
///
///   * the app shows its own sheet first, naming both files, the exact command
///     and what is being given up, and the button on that sheet is what raises
///     the dialog. The authorisation is the second thing the user sees, not the
///     first.
///   * `do shell script` takes a `with prompt` parameter — verified in this
///     machine's own StandardAdditions.sdef, "the prompt to be displayed in the
///     password dialog" — so the dialog itself carries a sentence naming what is
///     about to be installed rather than only naming osascript.
///
/// And unlike the session helper, this is a one-time deliberate act the user
/// navigated to, not a side effect of touching a slider. The session helper's
/// Terminal flow is untouched; a developer who does not want an install still
/// reads a path before typing a password, exactly as before.
public enum FanElevation {

    /// POSIX single-quoting. This project's own checkout path contains a space
    /// and this is a command that runs as root, so an unquoted path is not a
    /// cosmetic problem.
    public static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// An AppleScript string literal. Only `\` and `"` need escaping, and both
    /// can appear in a macOS path.
    public static func appleScriptQuoted(_ s: String) -> String {
        "\"" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The shell command that installs, as it would be typed.
    ///
    /// Also what the UI shows, so a user who would rather run it themselves in a
    /// terminal runs the identical thing rather than an approximation of it.
    ///
    /// `--uid` IS NOT OPTIONAL HERE, and finding that out cost a bug. The helper
    /// falls back to `$SUDO_UID` to learn who to serve, which is right for
    /// someone typing `sudo`. `do shell script … with administrator privileges`
    /// does NOT go through sudo and does not set it, so an install run from the
    /// button would have refused with "cannot tell which user to install for".
    /// The app knows its own uid; it says so.
    public static func installCommand(helper: String, ownerUID: uid_t) -> String {
        shellQuoted(helper) + " " + FanDaemon.installArgument + " --uid \(ownerUID)"
    }

    public static func uninstallCommand(helper: String) -> String {
        shellQuoted(helper) + " --uninstall"
    }

    /// The AppleScript that raises exactly one authorisation dialog.
    public static func script(command: String, prompt: String) -> String {
        "do shell script \(appleScriptQuoted(command))"
        + " with prompt \(appleScriptQuoted(prompt))"
        + " with administrator privileges"
    }

    /// The prompt the system dialog carries. Names the two paths, because the
    /// objection to this mechanism is that it names none.
    public static let installPrompt =
        "BetterStats will install a fan helper that runs as root: "
        + "\(FanDaemon.helperPath) and \(FanDaemon.plistPath). "
        + "Uninstalling from the Fans tab removes both."

    public static let uninstallPrompt =
        "BetterStats will hand the fans back to macOS and remove everything it "
        + "has installed as root."

    public static func osascriptArguments(command: String, prompt: String) -> [String] {
        ["-e", script(command: command, prompt: prompt)]
    }

    public enum Result: Equatable {
        case done(String)
        /// The user pressed Cancel. Not an error, and must not be reported as
        /// one — the whole point of the dialog is that it can be refused.
        case cancelled
        case failed(String)
    }

    /// osascript's exit for a user-cancelled authorisation. Its stderr says
    /// "User canceled. (-128)"; -128 is `userCanceledErr`.
    static func classify(status: Int32, output: String, error: String) -> Result {
        if status == 0 { return .done(output) }
        if error.contains("-128") || error.lowercased().contains("cancel") {
            return .cancelled
        }
        return .failed(error.isEmpty ? "osascript exited \(status)" : error)
    }

    /// Run it. Blocking, and never called from a test: it puts up a system
    /// authorisation dialog and then does something as root.
    public static func run(command: String, prompt: String) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = osascriptArguments(command: command, prompt: prompt)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return .failed(error.localizedDescription) }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return classify(status: p.terminationStatus,
                        output: String(decoding: outData, as: UTF8.self),
                        error: String(decoding: errData, as: UTF8.self))
    }
}

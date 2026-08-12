import CLaunchActivate
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
//     $ codesign -d --requirements - ~/Applications/Anode.app
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
//      `dev.anode.app` comes from CFBundleIdentifier and is the same in
//      every build. `FanClientPin.signingIdentifier` states in full what that
//      stops and what it does not, and the short version is repeated here
//      because it is the price of the button: ANYONE WHO CAN RUN `codesign -s -
//      -i dev.anode.app` ON THEIR OWN BINARY SATISFIES IT. Verified:
//
//          $ cc -o notmine t.c
//          $ codesign --force --sign - -i dev.anode.app notmine
//          $ codesign -dvv notmine
//          Identifier=dev.anode.app   Signature=adhoc   valid on disk
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
// After installing: STILL NOTHING RUNS until fan control is used. launchd holds
// the socket and starts the helper on a connection; it leaves again once it has
// been idle and is holding no fan. Not at boot, not while the app is closed, not
// while fan control is off. The first draft of this made the daemon resident with
// RunAtLoad + KeepAlive, which was a permanent root process bought to save a
// process launch — see `plistDictionary`.
//
// While it is up, its entire ability is to set a fan target within the range the
// fan itself reports, on request from the uid that installed it. Anything running
// as that user can ask. An attacker who takes it can make the machine loud, or
// hold a fan where the firmware would also hold it — the SMC arbitrates and has
// been observed clamping a written target upward. It cannot read anything, cannot
// write any other SMC key, cannot run anything, and has no path or key name in
// its input.
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
    public static let label = "dev.anode.app.fanhelper"

    /// Every name this daemon has ever had, newest first.
    ///
    /// A LIST, because there are now two of them: the app was renamed from
    /// BetterStats to Anode, and then the bundle identifier had the author's name
    /// taken out of it. A single `previousLabel` could only ever describe the most
    /// recent rename, so the one before it would stop being looked for the moment
    /// a second rename happened — silently, on exactly the machines that have been
    /// running this longest.
    ///
    /// None of these can be migrated. The plist is in `/Library/LaunchDaemons` and
    /// the binary in `/Library/PrivilegedHelperTools`, both root-owned, and this
    /// app has no way to move them — which is the correct arrangement, and also
    /// means every rename leaves a root daemon installed under a name nothing
    /// looks for any more.
    ///
    /// Detected rather than ignored, because the failure is bad in a specific
    /// way: `isInstalled` would report false, the app would offer to install, and
    /// the machine would end up with TWO root fan daemons — one of them orphaned,
    /// still holding a socket, and answering to a build that no longer exists.
    public static let previousLabels = [
        "dev.noah.anode.fanhelper",        // before the identifier was neutralised
        "dev.noah.betterstats.fanhelper",  // before the app was renamed
    ]

    /// The ones actually on disk right now.
    public static var previousInstallsPresent: [String] {
        previousLabels.filter {
            FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/\($0).plist")
        }
    }

    /// Is a daemon from before any rename still installed?
    ///
    /// Only ever reported, never acted on. Removing it needs root and it is
    /// exactly the kind of thing that must be done deliberately, with the command
    /// visible — the same rule the install follows.
    public static var previousInstallIsPresent: Bool { !previousInstallsPresent.isEmpty }

    /// Is the daemon on disk the same build as the app asking it for things?
    ///
    /// IT IS NOT UPDATED BY REBUILDING THE APP. The helper is copied into
    /// `/Library/PrivilegedHelperTools` at install time and stays exactly as it
    /// was; a new app bundle beside it changes nothing. So every fix to the helper
    /// is invisible until someone reinstalls, and the app goes on talking to a
    /// binary from whenever the last install happened.
    ///
    /// That cost a whole debugging round: a fix to the readback was built, run,
    /// and reported as having changed nothing — correctly, because the daemon
    /// answering was half an hour older than the fix. The tell was the error
    /// message being word-for-word the old one, which the new binary does not
    /// contain.
    ///
    /// Compared by CONTENT rather than by version number. A protocol version only
    /// moves when the protocol does, and this needs to notice any change at all —
    /// including the ones that are pure bug fixes, which are exactly the ones
    /// someone is in the middle of testing.
    /// `installed` is injectable ONLY so a test can point it at a fixture.
    ///
    /// Reading the real `/Library` path made this a function of the developer's
    /// machine: a test asserting "nothing installed says nothing" failed on the
    /// one machine that HAD an install, which is the machine it needs to work on.
    /// The same seam the settings migration needed, for the same reason — a
    /// function whose whole job is to look at a fixed path cannot be tested
    /// without being told which path.
    public static func installedBuildMatchesBundle(bundled: URL?,
                                                   installed: String = helperPath) -> Bool? {
        let fm = FileManager.default
        guard let bundled, fm.fileExists(atPath: installed),
              fm.fileExists(atPath: bundled.path) else { return nil }
        // Size first: it is a stat, and two different builds of a two-megabyte
        // binary almost never match on it. The hash is the answer when they do.
        let installedSize = (try? fm.attributesOfItem(atPath: installed)[.size]) as? Int
        let bundledSize = (try? fm.attributesOfItem(atPath: bundled.path)[.size]) as? Int
        if let a = installedSize, let b = bundledSize, a != b { return false }
        guard let a = try? Data(contentsOf: URL(fileURLWithPath: installed)),
              let b = try? Data(contentsOf: bundled) else { return nil }
        return a == b
    }

    /// Said when the installed helper is not the one this app ships.
    public static func staleInstallNote(bundled: URL?,
                                        installed: String = helperPath) -> String? {
        guard installedBuildMatchesBundle(bundled: bundled,
                                          installed: installed) == false else { return nil }
        return "The installed fan helper is from a different build of Anode. "
             + "Reinstall it — rebuilding the app does not replace the copy running as root."
    }

    /// Said alongside `summary`, never folded into it.
    ///
    /// The first version put this inside `summary(.notInstalled)`, which made a
    /// pure function depend on what happens to be installed on the machine — a
    /// test asserting its wording started failing on the one developer machine
    /// that HAD an old daemon, which is precisely the environment it needs to keep
    /// working on. Kept apart, `summary` stays a function of its argument and this
    /// stays a fact about the disk.
    public static var orphanNote: String? {
        let found = previousInstallsPresent
        guard !found.isEmpty else { return nil }
        let subject = found.count == 1 ? "A fan helper" : "\(found.count) fan helpers"
        let verb = found.count == 1 ? "is" : "are"
        return "\(subject) from an earlier name of this app \(verb) still installed as "
             + "root. Remove \(found.count == 1 ? "it" : "them") before installing this "
             + "one, or the machine runs more than one."
    }

    /// What to run to be rid of the named daemons, for the app to show and the
    /// user to read.
    ///
    /// TAKES the labels rather than reading the disk. The first draft of this
    /// built itself from `previousInstallsPresent`, which made the wording a
    /// function of what happens to be installed — the same mistake `orphanNote`
    /// documents two functions up, where a test asserting the wording failed on
    /// the one developer machine that HAD an old daemon. A command is a string
    /// about labels; which labels are on disk is a separate question.
    public static func uninstallCommand(for labels: [String]) -> String {
        labels.map {
            "sudo launchctl bootout system/\($0); "
            + "sudo rm -f /Library/LaunchDaemons/\($0).plist "
            + "/Library/PrivilegedHelperTools/\($0)"
        }.joined(separator: "\n")
    }

    /// The command for what is actually installed, so the user is not asked to
    /// run lines as root that do nothing.
    public static var previousUninstallCommand: String {
        uninstallCommand(for: previousInstallsPresent)
    }

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
    public static let clientSigningIdentifier = "dev.anode.app"

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
    /// a session helper. The difference is the pin, and where the socket comes
    /// from: a session helper makes its own, the daemon is handed one by launchd.
    public static let serveArgument = "--serve"
    public static let installArgument = "--install"

    /// The key under `Sockets` in the plist, and the name passed to
    /// `launch_activate_socket`. The two must agree or the daemon starts with no
    /// socket to serve; there is a test that reads it out of the generated plist
    /// rather than restating it.
    public static let socketActivationName = "FanControl"

    /// How long the on-demand daemon waits, with no client and no fan held,
    /// before exiting and letting launchd hold the socket again.
    ///
    /// It exists so the helper is not resident, and it is 90 seconds rather than
    /// something eager because leaving is not free: launchd has to start a new
    /// process on the next connection. The app pings every 5 s while its Fans
    /// tab is open and holds the connection between pings, so in practice this
    /// fires once, after the app has gone.
    ///
    /// A HELPER HOLDING A FAN NEVER IDLE-EXITS, whatever this says. Exiting runs
    /// the dead-man's switch and hands the fans back, which is right when the
    /// app has crashed and wrong when it simply has nothing to say. `run()`
    /// enforces that, not this constant.
    public static let idleExit: TimeInterval = 90

    // ── The socket launchd is holding ───────────────────────────────────────

    /// Why the daemon could not get its socket from launchd. Separated from a
    /// bare errno because two of these mean "you ran this wrong" and should say
    /// so to a person, rather than printing a number.
    public enum ActivationFailure: Error, Equatable {
        /// ESRCH. Nothing launched this with a socket — almost always someone
        /// running `--serve` by hand, which is not how the daemon starts.
        case notLaunchedByLaunchd
        /// ENOENT. launchd started it, but the job has no socket by that name:
        /// the installed plist is older than this binary, or was edited.
        case noSocketNamed(String)
        /// The plist and this code disagree about the job's shape.
        case unexpectedSocketCount
        case failed(code: Int32)

        public var message: String {
            switch self {
            case .notLaunchedByLaunchd:
                return "\(FanDaemon.serveArgument) is how launchd starts the installed "
                     + "daemon; it is not a way to run the helper by hand. Run it with "
                     + "no arguments for a session helper, or install it first."
            case .noSocketNamed(let name):
                return "launchd has no socket named \(name) for this job — the installed "
                     + "plist does not match this helper. Uninstall and install again."
            case .unexpectedSocketCount:
                return "launchd offered a number of sockets other than one, which this "
                     + "job never asks for. Uninstall and install again."
            case .failed(let code):
                return "could not adopt the launchd socket: \(String(cString: strerror(code)))"
            }
        }
    }

    /// The listening socket launchd created for this job, ready to `accept` on.
    ///
    /// This is what makes the daemon on-demand. launchd binds the socket at
    /// install time and holds it while nothing is running; the first connection
    /// starts this process, which asks for the descriptor here and serves it.
    /// Nothing is bound, `chmod`ed or `chown`ed by us on this path — launchd did
    /// it from the plist, and doing it again would be a second opinion about
    /// permissions with no way to tell which one won.
    public static func activatedSocket(
        named name: String = FanDaemon.socketActivationName
    ) throws -> Int32 {
        var fd: Int32 = -1
        let rc = bs_launch_activate_one(name, &fd)
        switch rc {
        case 0:       return fd
        case ESRCH:   throw ActivationFailure.notLaunchedByLaunchd
        case ENOENT:  throw ActivationFailure.noSocketNamed(name)
        case EINVAL:  throw ActivationFailure.unexpectedSocketCount
        default:      throw ActivationFailure.failed(code: rc)
        }
    }

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
        /// Installed, with nothing running. THE ORDINARY RESTING STATE, not a
        /// fault: the job is launched on demand, so launchd holds the socket and
        /// starts nothing until the app takes a fan. This used to mean "launchd
        /// should have started it and did not", which was true of the resident
        /// daemon and is exactly backwards for this one — as a message telling
        /// the user to reinstall a perfectly healthy install, it would have
        /// fired every time the Fans tab was opened.
        ///
        /// A connection that is genuinely refused or fails is reported by the
        /// link itself, verbatim, so nothing is lost by this no longer being an
        /// alarm.
        case installedAndIdle
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
        guard answered else { return .installedAndIdle }
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
            return "The fan helper is not installed. Nothing of Anode runs as root."
        case .running:
            return "The fan helper is installed and running."
        case .installedAndIdle:
            return "The fan helper is installed. Nothing runs until you take a fan — "
                 + "launchd starts it on demand and it stops again when you are done."
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
                return "\(p) is not inside a Anode.app. Only a bundled build "
                     + "can be installed — run ./build-app.sh and install from "
                     + "~/Applications/Anode.app."
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
        // an identifier like `AnodeHelper-3f2a…`, so a daemon installed from
        // one would refuse the app it was installed for. Refused here, where the
        // message can say what to do.
        let bundle = URL(fileURLWithPath: sourceHelper)
            .deletingLastPathComponent()    // MacOS
            .deletingLastPathComponent()    // Contents
            .deletingLastPathComponent()    // Anode.app
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
    /// IT IS LAUNCHED ON DEMAND, AND NOTHING RUNS UNTIL SOMETHING CONNECTS.
    ///
    /// The first cut of this used `RunAtLoad` + `KeepAlive`, which is the easy
    /// way to make "never prompts again" true and costs a root process resident
    /// from boot to shutdown, whether or not fan control is ever used. That is a
    /// bad trade for a feature most users touch rarely, and it is not necessary:
    /// `Sockets` makes launchd hold the listening socket itself and start this
    /// program only when a connection arrives.
    ///
    /// So: no process at boot. No process while Anode is closed. No
    /// process while fan control is off. The helper appears when the app asks a
    /// fan for something and leaves again when it is done (`FanDaemon.idleExit`).
    ///
    /// THE ACCESS CONTROL IS UNCHANGED, which is the reason this was safe to do.
    /// The helper used to create the socket, `chmod` it 0600 and `chown` it to
    /// the user it serves. `SockPathOwner` + `SockPathMode` ask launchd for
    /// exactly that, so the socket has the same owner and the same mode as
    /// before — it is simply created by launchd instead. `getpeereid` still does
    /// the real enforcement on every connection; the file mode is defence in
    /// depth in both designs.
    ///
    /// `SockPathMode` is decimal on purpose. Property lists have no octal, which
    /// launchd.plist(5) calls out as a known bug; `0o600` is a Swift integer
    /// literal and serialises as 384, which is what launchd wants to read.
    ///
    /// There is no `StandardOutPath`; the helper logs to the unified log, so the
    /// install leaves no file that needs rotating or cleaning up.
    public static func plistDictionary(ownerUID: uid_t) -> [String: Any] {
        [
            "Label": FanDaemon.label,
            "ProgramArguments": [FanDaemon.helperPath,
                                 FanDaemon.serveArgument,
                                 "--uid", String(ownerUID)],
            "Sockets": [
                FanDaemon.socketActivationName: [
                    "SockPathName": FanSocket.path,
                    "SockPathOwner": Int(ownerUID),
                    "SockPathMode": 0o600,
                ],
            ],
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

    /// The real thing. Used only by `AnodeHelper --install`, which is
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
        "Anode will install a fan helper that runs as root: "
        + "\(FanDaemon.helperPath) and \(FanDaemon.plistPath). "
        + "Uninstalling from the Fans tab removes both."

    public static let uninstallPrompt =
        "Anode will hand the fans back to macOS and remove everything it "
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

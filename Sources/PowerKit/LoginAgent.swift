import Foundation

/// A user LaunchAgent, for when `SMAppService` will not hold a registration.
///
/// WHY THIS EXISTS, measured rather than assumed. `SMAppService.mainApp` is the
/// modern, correct mechanism and it is tried first. On this build it does not
/// survive a reboot:
///
///     ticked "Launch at login"  -> register() succeeded, status .enabled,
///                                  the confirmation sheet appeared
///     restarted the Mac         -> nothing launched, no process, no launchd job
///     reopened Settings         -> status .notFound
///
/// The bundle is ad-hoc signed (`codesign --sign -`): `Signature=adhoc`,
/// `TeamIdentifier=not set`, and a cdhash that changes on every rebuild.
/// Background Task Management records a login item against a code identity and
/// validates it at boot, so an identity with no team and an unstable hash is
/// accepted at registration time and dropped later. The failure is silent and
/// arrives a reboot after the mistake, which is the worst possible time.
///
/// A user LaunchAgent has no such requirement. launchd reads the plist from
/// `~/Library/LaunchAgents`, which needs no signature and no entitlement, and
/// macOS 13+ still honours it — it simply appears under "Allow in the
/// Background" in System Settings rather than as a login item. It is the older
/// mechanism, and it is the one that works for a build nobody paid Apple for.
///
/// THIS IS A FALLBACK, NOT THE PLAN. When the app is signed with a Developer ID,
/// `SMAppService` will hold and this should stop being used — it is checked
/// second, and `isInstalled` is only consulted when SMAppService reports it has
/// nothing. Do not "simplify" by deleting the SMAppService path: the LaunchAgent
/// cannot be revoked from the app if the user removes it by hand, and
/// SMAppService's self-cleaning behaviour is the better contract wherever it is
/// available.
public enum LoginAgent {

    /// Reverse-DNS plus a suffix, so it cannot collide with the bundle id that
    /// SMAppService uses for the same app.
    public static let label = "dev.anode.app.loginagent"

    /// Every label this agent has been registered under before, newest first.
    ///
    /// UNLIKE the fan daemon's, these are removable: the plist is in the user's
    /// own `~/Library/LaunchAgents`, so the app can clean up after itself instead
    /// of printing a sudo command. It must, too — an agent left under an old
    /// label still points at the app's path and would go on launching it at
    /// login, so a rename without this leaves the user with two registrations and
    /// a "start at login" switch that cannot turn one of them off.
    public static let previousLabels = [
        "dev.noah.anode.loginagent",        // before the identifier was neutralised
        "dev.noah.betterstats.loginagent",  // before the app was renamed
    ]

    private static func plistURL(for label: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Boot out and delete any agent registered under a name this app used to
    /// use. Safe to call at any time: a label with no plist is a no-op.
    public static func removeStaleRegistrations() {
        for old in previousLabels {
            let url = plistURL(for: old)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            _ = launchctl(["bootout", "gui/\(getuid())/\(old)"])
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Passed to the app by the agent, so a launch AT LOGIN can be told apart
    /// from a user opening the app.
    ///
    /// The app has one setting — "start in menu bar only" — that is meant for the
    /// first case and was being applied to both, so double-clicking the app did
    /// nothing visible. That reads as a broken app rather than as a preference.
    ///
    /// AN ARGUMENT, not an environment variable. Measured: launchd sets
    /// `XPC_SERVICE_NAME` to this agent's Label for a job it starts, while a
    /// manual launch gets `application.dev.anode.app.<hash>` from
    /// LaunchServices — so the two ARE distinguishable that way. It is still the
    /// wrong mechanism, because `SMAppService` (the other registrar this app
    /// tries first) starts the app through LaunchServices too, and its login
    /// launch is then indistinguishable from a double-click. An argument we put
    /// in the plist ourselves cannot be ambiguous.
    public static let loginArgument = "--opened-at-login"

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Is our agent installed AND pointing at the executable now running?
    ///
    /// The path check matters: a plist left behind by an older install points at
    /// a bundle that may have moved or been deleted, and reporting that as
    /// "enabled" would promise a launch that silently fails. A stale agent is
    /// treated as absent so the caller reinstalls it correctly.
    public static var isInstalled: Bool { installedProgramPath == currentExecutablePath }

    /// The program path recorded in the installed plist, or nil if not installed.
    public static var installedProgramPath: String? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String]
        else { return nil }
        return args.first
    }

    /// The running executable, resolved through symlinks so two spellings of the
    /// same path cannot read as different programs.
    public static var currentExecutablePath: String {
        URL(fileURLWithPath: Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0])
            .resolvingSymlinksInPath().path
    }

    /// Is the running binary inside an .app bundle?
    ///
    /// A LaunchAgent pointing at a `swift build` binary in `.build/debug` would
    /// launch something that vanishes on the next clean, so installation is
    /// refused for unbundled builds rather than writing a plist that will rot.
    public static var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    public enum Failure: LocalizedError {
        case notBundled
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notBundled:
                return "This build is not an .app bundle, so there is no stable "
                     + "path to launch at login. Run ./build-app.sh and open the "
                     + "installed app."
            case .writeFailed(let why):
                return "Could not write the launch agent: \(why)"
            }
        }
    }

    /// Write the plist and hand it to launchd for this session.
    ///
    /// `RunAtLoad` is what makes it a login item. There is deliberately no
    /// `KeepAlive`: this is a monitor the user may quit, and a job that
    /// resurrects itself after being quit is a job the user cannot turn off.
    public static func install() throws {
        guard isBundled else { throw Failure.notBundled }
        let exec = currentExecutablePath
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exec, loginArgument],
            "RunAtLoad": true,
            // Interactive: it draws a menu bar. Background would have launchd
            // treat it as a daemon and throttle it.
            "ProcessType": "Interactive",
        ]
        let dir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
        // Best effort. The plist alone is enough for the NEXT login, which is
        // what the setting promises; bootstrapping now only saves a reboot, and
        // failing to do so must not report the setting as broken.
        _ = launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        // After the new one is in place, never before: a failure above leaves the
        // old registration doing its job rather than leaving nothing at all.
        removeStaleRegistrations()
    }

    /// Remove it, and tell launchd to forget it now rather than at logout.
    public static func uninstall() {
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
        // "Off" has to mean off, including for names this app used to answer to.
        removeStaleRegistrations()
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

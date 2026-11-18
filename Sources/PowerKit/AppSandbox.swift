import Foundation

/// The copy of Anode that `./test.sh --full` installs in a folder next to the checkout and drives through its own windows
/// (Settings, then the Uninstall button) runs in a sandbox, because it is a second Anode on the same Mac as the person's own
/// and would otherwise share what is theirs:
///
///   * its settings are kept in memory (`Settings.appDefaults`), not in `com.anode.settings`;
///   * it makes none of the first-run offers (the welcome, the automatic-update question, the helper), the last of which
///     asks for the Mac's password;
///   * it leaves the login item alone: `LoginAgent` boots out a launchd job by a label the person's Anode shares;
///   * the Terminal window its Uninstall button opens runs the uninstaller through a "door" the test wrote, which gives the
///     script the test's stand-ins for every tool that reaches the Mac (the real uninstaller quits an Anode by the
///     identifier `dev.anode.app`, resets that identifier's privacy approvals, and looks for running Anodes in `ps`).
///
/// THE ONLY THING THAT TURNS IT ON is the bundle identifier of the copy: the test changes it in the installed app's
/// Info.plist before the first launch. An environment variable, a setting or a file could be there by accident, in the
/// person's own Anode, and an Anode that kept its settings in memory and made no offers would be a bug nobody could find; a
/// bundle identifier the person's app does not have cannot be. A test pins that (`AppSandboxTests`).
public enum AppSandbox {

    /// The identifier the test gives its copy: the one the person's own is not, and not a prefix or a variant of it.
    public static let bundleIdentifier = "dev.anode.app.installtest"

    /// The environment variable that names the door (a script) in a Terminal window the sandbox's Uninstall button opens.
    public static let doorVariable = "ANODE_SANDBOX_DOOR"

    /// Whether this process is the test copy. Decided once.
    public static let isOn: Bool = isOn(bundleIdentifier: Bundle.main.bundleIdentifier)

    /// The decision, with the identifier a parameter so a test can show what it turns on and what it does not.
    public static func isOn(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == Self.bundleIdentifier
    }

    /// The door the test made, from the environment the copy was started with; nil when there is none (or an empty name).
    public static func door(environment: [String: String]) -> String? {
        guard let path = environment[doorVariable], !path.isEmpty else { return nil }
        return path
    }
}

import Foundation

/// Everything this project puts on a machine, and what removing it means.
///
/// Written as a PLAN rather than as a function that deletes things, for three
/// reasons. It can be shown to the user before anything happens, which an
/// irreversible operation deserves. It can be tested without a machine to
/// destroy. And it forces the awkward cases to be decided in one place instead
/// of being discovered halfway through a shell script — the root daemon that
/// cannot be removed without a password, and the source checkout that must not
/// be removed at all.
public enum Uninstall {

    /// What will be removed, in the order it will happen.
    public struct Plan: Equatable {
        /// The installed bundle. nil when there is nothing at either location.
        public var appBundle: String?
        /// Login agents, including labels from before the app was renamed — an
        /// agent left behind still launches something at login.
        public var loginAgents: [String] = []
        /// Scripts this app wrote into Application Support.
        public var scripts: [String] = []
        /// History and settings. Only with `removingData`, because a reinstall
        /// that lost a month of measurements would be its own bug report.
        public var data: [String] = []
        public var defaultsDomains: [String] = []
        /// SHOWN, never run. Removing it needs root, and this project's rule is
        /// that anything needing root is a command the user reads and types.
        public var rootDaemonCommand: String?

        public var isEmpty: Bool {
            appBundle == nil && loginAgents.isEmpty && scripts.isEmpty
                && data.isEmpty && defaultsDomains.isEmpty
        }
    }

    /// Where an installed bundle can be. `~/Applications` is where
    /// `build-app.sh` puts it; `/Applications` is where someone may have
    /// dragged it.
    public static func bundleLocations(home: String) -> [String] {
        ["\(home)/Applications/Anode.app", "/Applications/Anode.app"]
    }

    public static func supportDirectory(home: String) -> String {
        "\(home)/Library/Application Support/Anode"
    }

    /// Build the plan. `exists` is injected so this can be tested against a
    /// machine that does not have any of it — which is every machine running
    /// the suite except one.
    public static func plan(removingData: Bool,
                            home: String = NSHomeDirectory(),
                            exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
    -> Plan {
        var plan = Plan()
        plan.appBundle = bundleLocations(home: home).first(where: exists)

        let agents = [LoginAgent.label] + LoginAgent.previousLabels
        plan.loginAgents = agents
            .map { "\(home)/Library/LaunchAgents/\($0).plist" }
            .filter(exists)

        let support = supportDirectory(home: home)
        // The two scripts this app writes for Terminal to run. They go whatever
        // the user decides about data, because they are not data.
        plan.scripts = ["\(support)/update.command", "\(support)/start-fan-helper.command"]
            .filter(exists)

        if removingData {
            plan.data = ["\(support)/history.sqlite", "\(support)/history.sqlite-wal",
                         "\(support)/history.sqlite-shm", "\(support)/discharge-trend.json"]
                .filter(exists)
            // Both domains: a machine that predates the rename still has the old
            // one, and leaving it means a reinstall silently inherits settings
            // from an app the user thought they removed.
            //
            // Existence-checked like everything else. Listing a domain that is
            // not there made a clean machine report that it was about to remove
            // settings, which is both untrue and the exact impression an
            // uninstaller must not give.
            plan.defaultsDomains = [Settings.suiteName, Settings.previousSuiteName]
                .filter { exists("\(home)/Library/Preferences/\($0).plist") }
        }

        if exists("/Library/LaunchDaemons/\(FanDaemon.label).plist") {
            plan.rootDaemonCommand = FanDaemon.uninstallCommand(for: [FanDaemon.label])
        }
        return plan
    }

    /// What the user is asked to agree to. Every path spelled out: an uninstall
    /// that says "and associated files" is asking for trust it has not earned.
    public static func summary(_ plan: Plan, removingData: Bool) -> String {
        guard !plan.isEmpty || plan.rootDaemonCommand != nil else {
            return "Nothing of Anode was found on this machine."
        }
        var lines: [String] = []
        if let app = plan.appBundle { lines.append("• \(app)") }
        for a in plan.loginAgents { lines.append("• \(a)") }
        for s in plan.scripts { lines.append("• \(s)") }
        for d in plan.data { lines.append("• \(d)") }
        for d in plan.defaultsDomains { lines.append("• settings: \(d)") }
        if !removingData && plan.data.isEmpty {
            lines.append("\nYour measurement history and settings are KEPT. "
                       + "Tick the box to remove those too.")
        }
        if plan.rootDaemonCommand != nil {
            lines.append("\nThe fan helper runs as root and cannot be removed from here. "
                       + "The command to remove it is printed at the end.")
        }
        lines.append("\nThe source checkout is never touched — delete it yourself "
                   + "if you want it gone.")
        return lines.joined(separator: "\n")
    }
}

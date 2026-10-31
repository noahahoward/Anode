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
        /// What macOS itself keeps for this bundle identifier — caches, the
        /// saved window state, WebKit and network storage. Not data: nothing in
        /// it is the user's, so it goes whatever they decide about history.
        public var systemFiles: [String] = []
        /// History and settings. Only with `removingData`, because a reinstall
        /// that lost a month of measurements would be its own bug report.
        public var data: [String] = []
        public var defaultsDomains: [String] = []
        /// The clone `install.sh` made. Only that one: a checkout anywhere else
        /// is somebody's working copy and is never listed. Even this one is
        /// removed by the script only if it has no uncommitted or unpushed work,
        /// which a plan built from file existence cannot know.
        public var installedCheckout: String?
        /// SHOWN, never run. Removing it needs root, and this project's rule is
        /// that anything needing root is a command the user reads and types.
        public var rootDaemonCommand: String?

        public var isEmpty: Bool {
            appBundle == nil && loginAgents.isEmpty && scripts.isEmpty && systemFiles.isEmpty
                && data.isEmpty && defaultsDomains.isEmpty && installedCheckout == nil
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

    /// Per-bundle-identifier folders macOS creates on an app's behalf, relative to
    /// the home directory. Existence-checked, so listing one that this machine
    /// never made costs nothing.
    public static func systemFileLocations(home: String) -> [String] {
        let id = "dev.anode.app"
        return ["Library/Caches/\(id)", "Library/HTTPStorages/\(id)",
                "Library/HTTPStorages/\(id).binarycookies", "Library/WebKit/\(id)",
                "Library/Saved Application State/\(id).savedState",
                "Library/Logs/\(id)"].map { "\(home)/\($0)" }
    }

    /// macOS's per-user cache folder for the app, which it keeps under /var/folders and which
    /// the Library folder never shows. `cacheDirectory` ends in a slash, as `getconf` gives it.
    public static func userCacheFolders(cacheDirectory: String) -> [String] {
        ["dev.anode.app", "dev.noah.anode", "dev.noah.betterstats"].map { cacheDirectory + $0 }
    }

    /// The lock files `swift build` leaves in the per-user temp folder for the clone `install.sh`
    /// made: its path with the slashes turned into underscores, then `_.build…lock`. The script
    /// matches `_.build*.lock`; these are the names seen.
    public static func buildLockFiles(checkout: String, tempDirectory: String) -> [String] {
        let stem = tempDirectory + checkout.replacingOccurrences(of: "/", with: "_")
        return ["_.build.lock", "_.build_workspace-state.json.lock",
                "_.build_index-build.lock", "_.build_index-build_workspace-state.json.lock"]
            .map { stem + $0 }
    }

    /// One of macOS's per-user folders (`_CS_DARWIN_USER_CACHE_DIR`, …), with its trailing slash.
    public static func userDirectory(_ name: Int32) -> String {
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard Foundation.confstr(name, &buffer, buffer.count) > 0 else { return "" }
        return String(cString: buffer)
    }

    /// Where `install.sh` clones to unless told otherwise.
    public static func installedCheckoutDirectory(home: String) -> String {
        "\(home)/Developer/Anode"
    }

    /// Settings domains, newest first. `dev.anode.app` is the bundle identifier,
    /// which is where the app's own `UserDefaults.standard` lands (the window
    /// frame, the menu bar widgets, the charge limit). The other two are the
    /// named suite and the one before the rename; `dev.noah.anode` is the
    /// bundle identifier from before that.
    public static let defaultsDomainNames = [Settings.suiteName, Settings.previousSuiteName,
                                              "dev.anode.app", "dev.noah.anode"]

    /// Build the plan. `exists` is injected so this can be tested against a
    /// machine that does not have any of it — which is every machine running
    /// the suite except one.
    public static func plan(removingData: Bool,
                            home: String = NSHomeDirectory(),
                            cacheDirectory: String = userDirectory(_CS_DARWIN_USER_CACHE_DIR),
                            tempDirectory: String = userDirectory(_CS_DARWIN_USER_TEMP_DIR),
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
        plan.scripts = ["\(support)/update.command", "\(support)/start-fan-helper.command",
                        "\(support)/uninstall.command"]
            .filter(exists)

        plan.systemFiles = systemFileLocations(home: home).filter(exists)
        if !cacheDirectory.isEmpty {
            plan.systemFiles += userCacheFolders(cacheDirectory: cacheDirectory).filter(exists)
        }

        if removingData {
            plan.data = ["\(support)/history.sqlite", "\(support)/history.sqlite-wal",
                         "\(support)/history.sqlite-shm", "\(support)/discharge-trend.json",
                         "\(support)/lifetime-drain.json",
                         "\(support)/dock-previews.log", "\(support)/update.log",
                         "\(support)/widget-squeeze.log", "\(support)/window-stranding.log"]
                .filter(exists)
            // The directory itself, last, with whatever else a version of the app
            // put in it — a list of file names goes stale the day a feature adds
            // one. It is Anode's own folder, so nothing in it is anyone else's.
            if exists(support) { plan.data.append(support) }
            // Every domain: a machine that predates the rename still has the old
            // ones, and leaving them means a reinstall silently inherits settings
            // from an app the user thought they removed.
            //
            // Existence-checked like everything else. Listing a domain that is
            // not there made a clean machine report that it was about to remove
            // settings, which is both untrue and the exact impression an
            // uninstaller must not give.
            plan.defaultsDomains = defaultsDomainNames
                .filter { exists("\(home)/Library/Preferences/\($0).plist") }
        }

        let checkout = installedCheckoutDirectory(home: home)
        if exists("\(checkout)/.git") {
            plan.installedCheckout = checkout
            if !tempDirectory.isEmpty {
                plan.systemFiles += buildLockFiles(checkout: checkout, tempDirectory: tempDirectory)
                    .filter(exists)
            }
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
        for f in plan.systemFiles { lines.append("• \(f)") }
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
        if let checkout = plan.installedCheckout {
            lines.append("• \(checkout)  (the copy the installer cloned — only if it has "
                       + "no uncommitted or unpushed changes)")
        }
        lines.append("\nA source checkout anywhere else is never touched — delete it "
                   + "yourself if you want it gone.")
        return lines.joined(separator: "\n")
    }
}

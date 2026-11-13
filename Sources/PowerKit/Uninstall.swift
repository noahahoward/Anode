import Foundation

/// Everything this project puts on a machine, and what removing it means.
///
/// Written as a PLAN rather than as a function that deletes things, for three
/// reasons. It can be shown to the user before anything happens, which an
/// irreversible operation deserves. It can be tested without a machine to
/// destroy. And it forces the awkward cases to be decided in one place instead
/// of being discovered halfway through a shell script — the root-owned helper and
/// permission that are removed with a password the Terminal asks for once, and the
/// source checkout that must not be removed at all.
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
        /// The crash records macOS keeps for Anode's programs (the plist in Application Support/CrashReporter, the
        /// reports in Logs/DiagnosticReports and its Retired folder), found by name. Only with `removingData`.
        public var crashRecords: [String] = []
        /// Settings files the test suite makes in Preferences (`com.anode.tests.*.plist`). Only with `removingData`.
        public var testSettings: [String] = []
        /// The clone `install.sh` made. Only that one: a checkout anywhere else
        /// is somebody's working copy and is never listed. Even this one is
        /// removed by the script only if it has no uncommitted or unpushed work,
        /// which a plan built from file existence cannot know.
        public var installedCheckout: String?
        /// The Anode helper's launchd job and binary, root-owned, whichever are there. NOT in `systemFiles` or `data`:
        /// the app cannot delete them. The script removes them with `sudo`, running the helper's own `--uninstall`
        /// (which reconnects the charger first), and the Terminal it runs in asks for the password once.
        public var helperFiles: [String] = []
        /// The sudoers rule Always Stay Awake installs, when it is there. Root-owned too; the script removes it with
        /// `sudo rm -f`, under the same single password prompt.
        public var keepAwakeRule: String?

        public var isEmpty: Bool {
            appBundle == nil && loginAgents.isEmpty && scripts.isEmpty && systemFiles.isEmpty
                && data.isEmpty && defaultsDomains.isEmpty && installedCheckout == nil
                && helperFiles.isEmpty && keepAwakeRule == nil && crashRecords.isEmpty && testSettings.isEmpty
        }
    }

    /// Where the helper's launchd job and binary, and the Always Stay Awake rule, are. `uninstall.sh` names the same
    /// four places (its defaults for ANODE_LAUNCH_DAEMONS_DIR and the other variables the tests use); a test keeps
    /// the two in step.
    public static let helperFileLocations = [FanDaemon.plistPath, FanDaemon.helperPath]
    public static let keepAwakeRuleLocation = KeepAwakeAuthorisation.path

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
                "Library/Logs/\(id)",
                // The signing identity build-app.sh makes so permissions survive updates, and the
                // log of the install. Both are this app's own and not data.
                "Library/Keychains/anode-signing.keychain-db",
                "Library/Logs/Anode-install.log"].map { "\(home)/\($0)" }
    }

    /// The bundle identifiers the app has had, newest first. macOS keeps a cache folder, three WebKit folders and the
    /// privacy approvals under each; `uninstall.sh` names the same ones (IDENTIFIERS) and a test keeps them in step.
    public static let bundleIdentifiers = ["dev.anode.app", "dev.noah.anode", "dev.noah.betterstats"]

    /// The processes WebKit keeps a cache folder for, per app: `com.apple.WebKit.<process>+<bundle identifier>`.
    public static let webKitProcessNames = ["GPU", "Networking", "WebContent"]

    /// macOS's per-user cache folders for the app, which it keeps under /var/folders and which
    /// the Library folder never shows: one for each bundle identifier, and WebKit's three for it.
    /// `cacheDirectory` ends in a slash, as `getconf` gives it.
    public static func userCacheFolders(cacheDirectory: String) -> [String] {
        bundleIdentifiers.flatMap { id in
            [cacheDirectory + id] + webKitProcessNames.map { cacheDirectory + "com.apple.WebKit.\($0)+\(id)" }
        }
    }

    /// The names crash records are kept under: exact and case-sensitive, followed by `_` or `-`. Never a bare
    /// `*anode*`: a program that only contains one of these is not Anode's. `uninstall.sh` names the same
    /// (CRASH_NAMES, CRASH_EXTENSIONS).
    public static let crashReportNames = ["AnodeApp", "AnodeHelper", "anode", "BetterStatsApp", "betterstats"]
    public static let crashReportExtensions = ["ips", "crash", "diag", "spin", "hang"]

    /// Is this file in a crash-record folder one of Anode's: `<name>_*.<ext>` or `<name>-*.<ext>`, for a name above?
    public static func isCrashRecord(_ fileName: String, extensions: [String]) -> Bool {
        for name in crashReportNames {
            for separator in ["_", "-"] where fileName.hasPrefix(name + separator) {
                if extensions.contains(where: { fileName.hasSuffix("." + $0) }) { return true }
            }
        }
        return false
    }

    /// Where macOS keeps them, with the extensions each folder holds: the plist the crash reporter writes, and the
    /// reports, which move to `Retired` once they have aged.
    public static func crashRecordFolders(home: String) -> [(folder: String, extensions: [String])] {
        [("\(home)/Library/Application Support/CrashReporter", ["plist"]),
         ("\(home)/Library/Logs/DiagnosticReports", crashReportExtensions),
         ("\(home)/Library/Logs/DiagnosticReports/Retired", crashReportExtensions)]
    }

    /// The settings suites the test suite makes leave `com.anode.tests.<…>.plist` in Preferences.
    public static let testSettingsPrefix = "com.anode.tests."

    public static func directoryContents(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
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

    /// Where `install.sh` clones to unless told otherwise, newest first: a hidden folder of its own, then
    /// `~/Developer/Anode`, where earlier versions of the script put it and where those installs still are.
    public static func installedCheckoutDirectories(home: String) -> [String] {
        ["\(home)/.anode/source", "\(home)/Developer/Anode"]
    }

    /// Settings domains, newest first. `dev.anode.app` is the bundle identifier,
    /// which is where the app's own `UserDefaults.standard` lands (the window
    /// frame, the menu bar widgets, the charge limit). The other two are the
    /// named suite and the one before the rename; `dev.noah.anode` is the
    /// bundle identifier from before that. The last four are the domains the app and the `anode` tool write
    /// under when they run outside the bundle (`AnodeApp`, `anode`) and what they were called before the rename.
    public static let defaultsDomainNames = [Settings.suiteName, Settings.previousSuiteName,
                                              "dev.anode.app", "dev.noah.anode",
                                              "AnodeApp", "anode", "BetterStatsApp", "betterstats"]

    /// Build the plan. `exists` is injected so this can be tested against a
    /// machine that does not have any of it — which is every machine running
    /// the suite except one.
    public static func plan(removingData: Bool,
                            home: String = NSHomeDirectory(),
                            cacheDirectory: String = userDirectory(_CS_DARWIN_USER_CACHE_DIR),
                            tempDirectory: String = userDirectory(_CS_DARWIN_USER_TEMP_DIR),
                            exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                            listDirectory: (String) -> [String] = Uninstall.directoryContents)
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
            // Found by name in the folders macOS keeps them in: a glob cannot be asked of `exists`.
            plan.crashRecords = crashRecordFolders(home: home).flatMap { entry in
                listDirectory(entry.folder).filter { isCrashRecord($0, extensions: entry.extensions) }
                    .sorted().map { "\(entry.folder)/\($0)" }
            }
            let preferences = "\(home)/Library/Preferences"
            plan.testSettings = listDirectory(preferences)
                .filter { $0.hasPrefix(testSettingsPrefix) && $0.hasSuffix(".plist") }
                .sorted().map { "\(preferences)/\($0)" }
        }

        if let checkout = installedCheckoutDirectories(home: home).first(where: { exists("\($0)/.git") }) {
            plan.installedCheckout = checkout
            if !tempDirectory.isEmpty {
                plan.systemFiles += buildLockFiles(checkout: checkout, tempDirectory: tempDirectory)
                    .filter(exists)
            }
        }

        plan.helperFiles = helperFileLocations.filter(exists)
        if exists(keepAwakeRuleLocation) { plan.keepAwakeRule = keepAwakeRuleLocation }
        return plan
    }

    /// Said whatever else is found: the script resets the privacy approvals macOS holds for the app, because they stay
    /// in macOS's list after the app is gone and the signing keychain goes with it, so a reinstalled Anode would show
    /// the old approval as on while it does not work. The script says the same, after it has done it.
    public static let approvalsSentence = "Accessibility, Screen Recording and the other approvals are reset: "
        + "a reinstalled Anode will ask for them again."

    /// What is said about the root-owned parts, naming only the ones that are there, or nil when none is. The
    /// Terminal the script runs in asks for the password once; it is not asked for here.
    public static func passwordSentence(_ plan: Plan) -> String? {
        let parts = (plan.helperFiles.isEmpty ? [] : ["The Anode helper"])
            + (plan.keepAwakeRule == nil ? [] : ["the Always Stay Awake permission"])
        guard !parts.isEmpty else { return nil }
        let subject = parts.count == 2 ? "\(parts[0]) and \(parts[1])" : parts[0]
        let sentence = "\(subject) \(parts.count == 2 ? "are" : "is") removed too; "
            + "the Terminal window will ask for your password once."
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }

    /// What the user is asked to agree to. Every path spelled out: an uninstall
    /// that says "and associated files" is asking for trust it has not earned.
    public static func summary(_ plan: Plan, removingData: Bool) -> String {
        guard !plan.isEmpty else {
            return "Nothing of Anode was found on this machine."
        }
        var lines: [String] = []
        if let app = plan.appBundle { lines.append("• \(app)") }
        for a in plan.loginAgents { lines.append("• \(a)") }
        for s in plan.scripts { lines.append("• \(s)") }
        for f in plan.systemFiles { lines.append("• \(f)") }
        for d in plan.data { lines.append("• \(d)") }
        for d in plan.defaultsDomains { lines.append("• settings: \(d)") }
        // A Mac that has crashed a few times has dozens of these: past a few, a count and where they are.
        if plan.crashRecords.count <= 4 {
            for r in plan.crashRecords { lines.append("• \(r)") }
        } else {
            lines.append("• \(plan.crashRecords.count) crash records macOS kept for Anode's programs "
                       + "(in Application Support/CrashReporter and Logs/DiagnosticReports)")
        }
        if let first = plan.testSettings.first {
            lines.append("• \(plan.testSettings.count) settings files made by Anode's tests "
                       + "(\((first as NSString).deletingLastPathComponent)/\(testSettingsPrefix)*.plist)")
        }
        if !removingData && plan.data.isEmpty {
            lines.append("\nYour measurement history and settings are KEPT. "
                       + "Tick the box to remove those too.")
        }
        for f in plan.helperFiles { lines.append("• \(f)") }
        if let rule = plan.keepAwakeRule { lines.append("• \(rule)") }
        if let sentence = passwordSentence(plan) { lines.append("\n" + sentence) }
        if let checkout = plan.installedCheckout {
            lines.append("• \(checkout)  (the copy the installer cloned — only if it has "
                       + "no uncommitted or unpushed changes)")
        }
        lines.append("\n" + approvalsSentence)
        lines.append("\nA source checkout anywhere else is never touched — delete it "
                   + "yourself if you want it gone.")
        return lines.joined(separator: "\n")
    }
}

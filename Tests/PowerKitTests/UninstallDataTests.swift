import XCTest
@testable import PowerKit

// "Remove my data" has to mean all of it, and the list exists twice — the app's
// uninstall plan and the shell script — kept in step by hand. Every data file the
// app writes to Application Support is named here, and both lists are checked.
final class UninstallDataTests: XCTestCase {

    private let dataFiles = ["history.sqlite", "history.sqlite-wal", "history.sqlite-shm",
                             "discharge-trend.json", "lifetime-drain.json",
                             "dock-previews.log", "update.log", "widget-squeeze.log",
                             "window-stranding.log"]

    func testTheAppsPlanRemovesEveryDataFile() {
        let plan = Uninstall.plan(removingData: true, home: "/h", exists: { _ in true })
        let names = Set(plan.data.map { ($0 as NSString).lastPathComponent })
        // Plus the folder itself, so a file a later version adds does not outlive it.
        XCTAssertEqual(names, Set(dataFiles + ["Anode"]))
    }

    func testKeepingDataKeepsTheLearnedModel() {
        let plan = Uninstall.plan(removingData: false, home: "/h", exists: { _ in true })
        XCTAssertTrue(plan.data.isEmpty)
    }

    /// The settings the script clears and the ones the app's plan clears are the same list, in the same order. A
    /// domain added to one and not the other is a setting that "remove my data" leaves behind.
    func testTheScriptClearsTheSameSettingsDomains() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("uninstall.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("DOMAINS=(") },
                                 "uninstall.sh has no DOMAINS=(…) line")
        let inside = try XCTUnwrap(line.split(separator: "(").last?.split(separator: ")").first)
        let domains = inside.split(separator: " ").map(String.init)
        XCTAssertEqual(domains, Uninstall.defaultsDomainNames,
                       "uninstall.sh clears a different list of settings domains than the app's uninstall plan")
    }

    private func scriptText() throws -> String {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("uninstall.sh")
        return try String(contentsOf: script, encoding: .utf8)
    }

    /// The root-owned places the app installs into, and the script removes with sudo, are the same ones: the helper's
    /// launchd job and binary, its socket, the Always Stay Awake rule. A path changed in one and not the other is a
    /// helper that an uninstall leaves running as root.
    func testTheScriptNamesTheRootOwnedPlacesTheAppInstalls() throws {
        let text = try scriptText()
        func folder(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
        XCTAssertTrue(text.contains("DAEMON_LABEL=\"\(FanDaemon.label)\""))
        XCTAssertTrue(text.contains("ANODE_LAUNCH_DAEMONS_DIR:-\(folder(FanDaemon.plistPath))}"))
        XCTAssertTrue(text.contains("ANODE_PRIVILEGED_HELPER_TOOLS_DIR:-\(folder(FanDaemon.helperPath))}"))
        XCTAssertTrue(text.contains("ANODE_SUDOERS_DIR:-\(folder(KeepAwakeAuthorisation.path))}"))
        XCTAssertTrue(text.contains("KEEP_AWAKE_RULE=\"$SUDOERS_DIR/\((KeepAwakeAuthorisation.path as NSString).lastPathComponent)\""))
        XCTAssertTrue(text.contains("ANODE_FAN_SOCKET:-\(FanSocket.path)}"))
        XCTAssertEqual(Uninstall.helperFileLocations, [FanDaemon.plistPath, FanDaemon.helperPath])
        XCTAssertEqual(Uninstall.keepAwakeRuleLocation, KeepAwakeAuthorisation.path)
    }

    /// The text of an array the script declares on one line: `NAME=(a b c)`.
    private func scriptArray(_ name: String) throws -> [String] {
        let text = try scriptText()
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("\(name)=(") },
                                 "uninstall.sh has no \(name)=(…) line")
        let inside = try XCTUnwrap(line.split(separator: "(").last?.split(separator: ")").first)
        return inside.split(separator: " ").map(String.init)
    }

    /// The identifiers the script resets privacy approvals for and clears caches of, and the names and extensions it
    /// finds crash records by, are the app's plan's: one list in two places, kept in step by hand.
    func testTheScriptNamesTheSameIdentifiersAndCrashRecords() throws {
        XCTAssertEqual(try scriptArray("IDENTIFIERS"), Uninstall.bundleIdentifiers)
        XCTAssertEqual(try scriptArray("CRASH_NAMES"), Uninstall.crashReportNames)
        XCTAssertEqual(try scriptArray("CRASH_EXTENSIONS"), Uninstall.crashReportExtensions)
    }

    /// Anode's WebKit folders: `com.apple.WebKit.<process>+<identifier>` for each, which the script builds from
    /// the identifier and the plan builds the same way.
    func testTheScriptRemovesTheSameWebKitFolders() throws {
        let text = try scriptText()
        for process in Uninstall.webKitProcessNames {
            XCTAssertTrue(text.contains("\"${USER_CACHE_DIR}com.apple.WebKit.\(process)+${id}\""),
                          "uninstall.sh does not remove the WebKit \(process) folder")
        }
        let folders = Uninstall.userCacheFolders(cacheDirectory: "/C/")
        XCTAssertEqual(folders.count, Uninstall.bundleIdentifiers.count * (1 + Uninstall.webKitProcessNames.count))
        XCTAssertTrue(folders.contains("/C/com.apple.WebKit.GPU+dev.anode.app"))
        XCTAssertTrue(folders.contains("/C/com.apple.WebKit.Networking+dev.noah.anode"))
        XCTAssertTrue(folders.contains("/C/com.apple.WebKit.WebContent+dev.noah.betterstats"))
    }

    /// The script says once, after it has reset them, what resetting the approvals means; the dialog says it first.
    func testTheScriptAndTheDialogSayWhatResettingTheApprovalsMeans() throws {
        let text = try scriptText()
        XCTAssertTrue(text.contains("Accessibility, Screen Recording and the other approvals were reset: "
                                    + "a reinstalled Anode will ask for them again."))
        XCTAssertTrue(text.contains("tccutil reset All \"$id\""))
        XCTAssertTrue(Uninstall.approvalsSentence.hasSuffix("a reinstalled Anode will ask for them again."))
    }

    func testTheScriptRemovesTheSameFiles() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("uninstall.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        for f in dataFiles {
            XCTAssertTrue(text.contains("\"$SUPPORT/\(f)\""), "uninstall.sh does not remove \(f)")
        }
        XCTAssertTrue(text.contains("\"$SUPPORT\""), "uninstall.sh does not remove the folder")
    }
}

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

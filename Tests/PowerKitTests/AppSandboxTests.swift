import XCTest
@testable import PowerKit
@testable import AnodeApp

/// The copy of the app that `./test.sh --full` installs next to the checkout and drives through its own windows runs in a
/// sandbox: its settings are kept in memory, it asks nothing of the person, it does not touch the login item, and the
/// Terminal window its Uninstall button opens runs the uninstaller through a door the test made. Nothing of that can be
/// switched on in the person's own Anode: the one thing that turns it on is the bundle identifier of the test copy.
final class AppSandboxTests: XCTestCase {

    func testOnlyTheTestCopysBundleIdentifierTurnsItOn() {
        XCTAssertTrue(AppSandbox.isOn(bundleIdentifier: "dev.anode.app.installtest"))
        XCTAssertFalse(AppSandbox.isOn(bundleIdentifier: "dev.anode.app"), "the person's own Anode")
        XCTAssertFalse(AppSandbox.isOn(bundleIdentifier: nil), "a process with no bundle")
        XCTAssertFalse(AppSandbox.isOn(bundleIdentifier: "dev.anode.app.installtest2"))
        XCTAssertFalse(AppSandbox.isOn(bundleIdentifier: "dev.anode.app.installtest.x"))
        XCTAssertFalse(AppSandbox.isOn(bundleIdentifier: "Dev.Anode.App.InstallTest"))
        XCTAssertFalse(AppSandbox.isOn(bundleIdentifier: ""))
    }

    func testThisProcessIsNotInTheSandbox() {
        XCTAssertFalse(AppSandbox.isOn, "a test run is not the test copy")
    }

    func testTheDoorIsNamedByTheEnvironmentAndByNothingElse() {
        XCTAssertEqual(AppSandbox.door(environment: ["ANODE_SANDBOX_DOOR": "/t/door.sh"]), "/t/door.sh")
        XCTAssertNil(AppSandbox.door(environment: [:]))
        XCTAssertNil(AppSandbox.door(environment: ["ANODE_SANDBOX_DOOR": ""]), "an empty name is no name")
    }

    // ── The Terminal window of the Uninstall button ─────────────────────────

    func testTheSandboxWrapperRunsTheScriptOnlyThroughTheDoor() {
        let text = UpdateLauncher.sandboxWrapper(script: "/A.app/Contents/Resources/uninstall.sh", arguments: ["--yes"],
                                                 door: "/t/door.sh")
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.last, "exec \"$door\" '/A.app/Contents/Resources/uninstall.sh' '--yes'")
        XCTAssertTrue(text.contains("door='/t/door.sh'"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("exec '/A.app") }, "never the script on its own")
    }

    func testTheSandboxWrapperRunsNothingWhenTheDoorIsMissing() {
        let text = UpdateLauncher.sandboxWrapper(script: "/A.app/Contents/Resources/uninstall.sh", arguments: ["--yes"], door: nil)
        XCTAssertFalse(text.contains("exec"), "no door, no run")
        XCTAssertTrue(text.contains("exit 1"))
        XCTAssertFalse(text.contains("uninstall.sh"), "the script is not even named")
    }

    func testTheSandboxWrapperChecksTheDoorExistsBeforeUsingIt() {
        let text = UpdateLauncher.sandboxWrapper(script: "/u.sh", arguments: [], door: "/t/door.sh")
        let check = text.range(of: "[ -x \"$door\" ]")
        let run = text.range(of: "exec \"$door\"")
        XCTAssertNotNil(check)
        XCTAssertNotNil(run)
        if let check, let run { XCTAssertLessThan(check.lowerBound, run.lowerBound) }
        XCTAssertTrue(text.contains("exit 1"), "a door that is not there stops it")
    }

    func testThePlainWrapperIsUnchanged() {
        let text = UpdateLauncher.wrapper(script: "/u.sh", arguments: ["--yes"])
        XCTAssertEqual(text.split(separator: "\n").last.map(String.init), "exec '/u.sh' '--yes'")
        XCTAssertFalse(text.contains("door"))
    }

    // ── What the sandbox switches off, read in the sources ──────────────────
    // The person's login item, the charge settings and the first-run offers are acted on by code that cannot be run in a test
    // without reaching this Mac, so what is pinned here is that each is guarded.

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheLoginItemIsNotTouchedInTheSandbox() throws {
        let text = try source("Sources/PowerKit/Settings.swift")
        let setter = try XCTUnwrap(text.range(of: "public var launchAtLogin: Bool {"))
        let body = String(text[setter.upperBound...].prefix(600))
        let guardAt = try XCTUnwrap(body.range(of: "guard !AppSandbox.isOn"))
        let firstUse = try XCTUnwrap(body.range(of: "SMAppService"))
        XCTAssertLessThan(guardAt.lowerBound, firstUse.lowerBound)
    }

    func testChargeSettingsAreNotRestoredByTheSandboxsUninstallButton() throws {
        let text = try source("Sources/AnodeApp/PreferencesWindow.swift")
        XCTAssertTrue(text.contains("if !AppSandbox.isOn { ChargeController.current?.restoreForUninstall() }"))
    }

    func testTheFirstRunOffersAreNotMadeInTheSandbox() throws {
        let main = try source("Sources/AnodeApp/main.swift")
        XCTAssertTrue(main.contains("!AppSandbox.isOn && FirstRunWelcome.isDue("))
        XCTAssertTrue(main.contains("guard !AppSandbox.isOn, !Settings.shared.autoUpdatePromptSeen, AutoUpdater.shared.isAvailable"))
        let helper = try source("Sources/AnodeApp/HelperOfferAtLaunch.swift")
        XCTAssertTrue(helper.contains("canInstall: { FanControlPanel.helperIsBundled && !AppSandbox.isOn }"))
    }

    func testTheSandboxKeepsItsSettingsInMemory() throws {
        let text = try source("Sources/PowerKit/Settings.swift")
        XCTAssertTrue(text.contains("guard isTestRun || AppSandbox.isOn else { return nil }"))
        XCTAssertTrue(text.contains("isTestRun || AppSandbox.isOn ? throwawayProcessDefaults"))
    }
}

import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// A newly installed Anode, with nothing turned on, runs no sudo command and asks for no administrator password; and the
/// moment something that will run them is turned on, the person is told first. These hold both halves.
final class AdminNoticeTests: XCTestCase {

    private var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
    }

    /// Every Swift file under Sources that contains `needle`, as paths under Sources.
    private func files(containing needle: String) throws -> Set<String> {
        var found: Set<String> = []
        let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains(needle) { found.insert(String(url.path.dropFirst(sources.path.count + 1))) }
        }
        return found
    }

    // ── Nothing runs on its own ─────────────────────────────────────────────

    /// The only code that can run `/usr/bin/sudo` is Keep Awake's, and nothing else spawns it. A new place that does must
    /// be added here on purpose, with its warning.
    func testOnlyKeepAwakeCanRunSudo() throws {
        XCTAssertEqual(try files(containing: "/usr/bin/sudo"), ["PowerKit/KeepAwake.swift"])
    }

    /// The same for the administrator dialog: Keep Awake's one-time rule, and the helper's install and uninstall.
    func testTheAdministratorDialogIsOnlyUsedWhereAWarningPrecedesIt() throws {
        XCTAssertEqual(try files(containing: "with administrator privileges"),
                       ["AnodeApp/FanControlPanel.swift", "AnodeHelper/main.swift", "PowerKit/FanDaemon.swift",
                        "PowerKit/KeepAwake.swift"])
        XCTAssertEqual(try files(containing: "osascript"),
                       ["AnodeApp/FanControlPanel.swift", "PowerKit/FanDaemon.swift", "PowerKit/KeepAwake.swift"])
    }

    /// The Beta Features window used to run `sudo -n -l` whenever it was opened, with Keep Awake off. The probe is now
    /// asked only while the feature is on.
    func testOpeningBetaFeaturesWithKeepAwakeOffRunsNoSudoCheck() throws {
        let settings = try throwawaySettings(owner: "AdminNotice", test: name)
        var probes = 0
        let feature = KeepAwakeFeature(settings: settings, isAuthorised: { probes += 1; return false },
                                       confirmEnable: { true })
        _ = feature.makeView()
        feature.refresh()
        feature.refresh()
        XCTAssertEqual(probes, 0, "Keep Awake is off: nothing of it is asked of sudo")
    }

    // ── The warning ─────────────────────────────────────────────────────────

    func testTheKeepAwakeWarningNamesTheCommandsTheRuleAndTheAudit() {
        let alert = AdminNotice.keepAwakeAlert()
        XCTAssertEqual(alert.messageText, "Keep Awake can run sudo commands")
        let text = alert.informativeText
        XCTAssertTrue(text.contains("sudo pmset -a disablesleep 1"), text)
        XCTAssertTrue(text.contains("/etc/sudoers.d/anode-keep-awake"), text)
        XCTAssertTrue(text.contains("audits sudo"), text)
        XCTAssertTrue(text.contains("Never Sleep"), "it says which mode needs none: \(text)")
        XCTAssertEqual(alert.buttons.map(\.title), ["Turn On", "Cancel"])
    }

    func testTicksKeepAwakeOnOnlyAfterTheWarningIsAccepted() throws {
        let settings = try throwawaySettings(owner: "AdminNotice", test: name)
        var asked = 0
        var answer = false
        let feature = KeepAwakeFeature(settings: settings, isAuthorised: { false },
                                       confirmEnable: { asked += 1; return answer })
        _ = feature.makeView()
        feature.enableCheckbox.state = .on
        feature.toggled()
        XCTAssertEqual(asked, 1, "the warning comes the moment it is ticked")
        XCTAssertFalse(settings.keepAwakeEnabled, "Cancel leaves it off")
        XCTAssertEqual(feature.enableCheckbox.state, .off)

        answer = true
        feature.enableCheckbox.state = .on
        feature.toggled()
        XCTAssertEqual(asked, 2)
        XCTAssertTrue(settings.keepAwakeEnabled)

        feature.enableCheckbox.state = .off
        feature.toggled()
        XCTAssertEqual(asked, 2, "turning it off asks nothing")
        XCTAssertFalse(settings.keepAwakeEnabled)
    }

    /// Every way the helper is installed says that it runs as root and may be logged by an organisation that audits it.
    func testEveryHelperInstallNoticeCarriesTheAuditNote() {
        XCTAssertTrue(HelperVocabulary.auditNote.contains("audits sudo"))
        XCTAssertTrue(FanElevation.installDisclosure.contains(HelperVocabulary.auditNote))
        for kind in [HelperOffer.install, .update] {
            XCTAssertTrue(HelperOfferNotice.text(kind).contains(HelperVocabulary.auditNote))
        }
        for origin in [FanControlPanel.InstallOrigin.fansTab, .chargeControl, .ultraLowPower] {
            let body = FanControlPanel.installAlert(helper: "/x", origin: origin).informativeText
            XCTAssertTrue(body.contains(HelperVocabulary.auditNote), "\(origin): \(body)")
        }
    }
}

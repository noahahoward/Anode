import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The "Possible memory leaks" section of Beta Features, on throwaway settings and the fakes of
/// `MemoryWatchControllerTests`: no real notification centre, window, process or setting is reached.
final class MemoryWatchFeatureTests: XCTestCase {

    private final class Log {
        var windowsBuilt = 0
        var openedURLs: [String] = []
        /// What `NSWorkspace.open` says to each URL in turn; true when this runs out.
        var urlAnswers: [Bool] = []
        var controllerLooks = 0
    }

    private final class Rig {
        let settings: Settings
        let notifier = FakeLeakNotifier()
        let log = Log()
        let controller: MemoryWatchController
        let feature: MemoryWatchFeature

        /// 2 minutes after the default finding (`makeLeakFinding`).
        static let now = Date(timeIntervalSince1970: 1_000_120)

        init(settings: Settings, sandboxed: Bool = false) {
            self.settings = settings
            let log = self.log
            let controller = MemoryWatchController(
                settings: settings, notifier: notifier,
                makeWatch: { FakeLeakWatch() },
                onSampling: { $0() },
                attach: { _ in },
                makeWindow: { _ in log.windowsBuilt += 1; return FakeLeakWindow() },
                isSandboxed: { sandboxed },
                onMain: { $0() })
            self.controller = controller
            feature = MemoryWatchFeature(settings: settings,
                                         controller: { log.controllerLooks += 1; return controller },
                                         openURL: { url in
                                             log.openedURLs.append(url.absoluteString)
                                             return log.urlAnswers.isEmpty ? true : log.urlAnswers.removeFirst()
                                         },
                                         now: { Rig.now })
        }
    }

    /// `tag` tells apart a second rig of one test: the same test name is the same throwaway store.
    private func rig(enabled: Bool = false, pressure: Bool = false, sandboxed: Bool = false, tag: String = "") throws -> Rig {
        let settings = try throwawaySettings(owner: "MemoryWatchFeature", test: name + tag)
        if enabled { settings.memoryWatchEnabled = true }
        if pressure { settings.memoryWatchPressureWarning = true }
        let r = Rig(settings: settings, sandboxed: sandboxed)
        _ = r.feature.makeView()
        return r
    }

    private func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    // ── In the window ───────────────────────────────────────────────────────

    func testTheSectionIsInTheDefaultListAndOffByDefault() throws {
        let settings = try throwawaySettings(owner: "MemoryWatchFeature", test: name)
        let list = BetaFeaturesWindowController.defaultFeatures(hasLidSensor: false, settings: settings)
        let feature = try XCTUnwrap(list.first { $0 is MemoryWatchFeature } as? MemoryWatchFeature)
        XCTAssertEqual(feature.title, "Possible memory leaks")
        XCTAssertFalse(settings.memoryWatchEnabled, "off until asked for")
        _ = feature.makeView()
        XCTAssertEqual(feature.enableCheckbox.state, .off)
        XCTAssertFalse(settings.memoryWatchPressureWarning, "the low-memory warning is off until asked for too")
        XCTAssertEqual(feature.pressureCheckbox.state, .off)
    }

    func testTheSummarySaysWhatItDoesWhatItCostsWhatItNeedsAndWhatItNeverDoes() throws {
        let summary = MemoryWatchFeature(settings: try throwawaySettings(owner: "MemoryWatchFeature", test: name),
                                         controller: { nil }).summary
        XCTAssertTrue(summary.contains("memory keeps growing"))
        XCTAssertTrue(summary.contains("no extra timer"))
        XCTAssertTrue(summary.contains("no disk writes"))
        XCTAssertTrue(summary.contains("notifications"))
        XCTAssertTrue(summary.contains("never quits anything by itself"))
    }

    func testTheLimitationsAndTheUninstallNoteAreShown() throws {
        let r = try rig()
        XCTAssertEqual(r.feature.limitationsLabel.stringValue,
                       MemoryWatchFeature.limitationsText)
        XCTAssertTrue(r.feature.limitationsLabel.stringValue.contains("slow growth"), "the slow tier is described")
        XCTAssertEqual(r.feature.uninstallLabel.stringValue,
                       "After uninstalling Anode the Anode entry stays in System Settings > Notifications.")
    }


    // ── The low-memory warning ──────────────────────────────────────────────

    func testTheSecondBoxIsInTheSameSectionAndOffByDefault() throws {
        let r = try rig()
        XCTAssertEqual(r.feature.title, "Possible memory leaks", "the section keeps its name and its first box")
        XCTAssertEqual(r.feature.enableCheckbox.title, "Warn me about possible memory leaks")
        XCTAssertEqual(r.feature.pressureCheckbox.title, "Warn when memory is running low")
        XCTAssertEqual(r.feature.pressureCheckbox.state, .off)
        XCTAssertFalse(r.settings.memoryWatchPressureWarning)
        XCTAssertEqual(r.log.controllerLooks, 0, "off means the section asks no one")
        XCTAssertFalse(r.controller.isEnabled)
    }

    func testTheSecondBoxSaysWhatItDoesWhatItNeverDoesAndWhatItCosts() throws {
        let r = try rig()
        let text = r.feature.pressureLabel.stringValue
        XCTAssertEqual(text, MemoryWatchFeature.pressureSummary)
        for phrase in ["how much of the Mac's memory is left", "2.5 GB or less", "0.5 GB or less", "repeats",
                       "Alerts", "naming the biggest app", "never quits anything by itself", "reads memory sizes only",
                       "no administrator privileges", "runs no commands", "one small system reading",
                       "permission to show notifications"] {
            XCTAssertTrue(text.contains(phrase), "the summary says \"\(phrase)\"")
        }
        // The leak box's own words are as they were.
        XCTAssertTrue(r.feature.summary.contains("memory keeps growing"))
        XCTAssertTrue(r.feature.limitationsLabel.stringValue.contains("slow growth"))
    }

    func testTickingTheSecondBoxWritesTheSettingAndAsksForPermission() throws {
        let r = try rig()
        r.notifier.status = .notDetermined
        r.feature.pressureCheckbox.performClick(nil)
        XCTAssertTrue(r.settings.memoryWatchPressureWarning)
        XCTAssertFalse(r.settings.memoryWatchEnabled, "the other box is its own")
        XCTAssertTrue(r.controller.isEnabled, "the controller followed the setting")
        XCTAssertEqual(r.notifier.requestCalls, 1, "the question is asked when the box is ticked")
        XCTAssertEqual(r.feature.statusLabel.stringValue, MemoryWatchFeature.allowedText)
        XCTAssertFalse(r.feature.statusLabel.isHidden)

        r.feature.pressureCheckbox.performClick(nil)
        XCTAssertFalse(r.settings.memoryWatchPressureWarning)
        XCTAssertFalse(r.controller.isEnabled)
        XCTAssertEqual(r.notifier.requestCalls, 1, "unticking asks nothing")
        XCTAssertTrue(r.feature.statusLabel.isHidden, "nothing is shown while both boxes are off")
    }

    func testTheSecondBoxNeverAsksInTheInstallTestCopy() throws {
        let r = try rig(sandboxed: true)
        r.notifier.status = .notDetermined
        r.feature.pressureCheckbox.performClick(nil)
        XCTAssertTrue(r.settings.memoryWatchPressureWarning)
        XCTAssertEqual(r.notifier.requestCalls, 0)
    }

    func testTheStatusAndTheListStayWhileEitherBoxIsTicked() throws {
        let r = try rig(enabled: true, pressure: true)
        XCTAssertFalse(r.feature.statusLabel.isHidden)
        r.settings.memoryWatchEnabled = false
        pump()
        XCTAssertEqual(r.feature.enableCheckbox.state, .off)
        XCTAssertEqual(r.feature.pressureCheckbox.state, .on)
        XCTAssertFalse(r.feature.statusLabel.isHidden, "the low-memory box is still ticked")
        XCTAssertFalse(r.feature.findingsStack.isHidden)
        r.settings.memoryWatchPressureWarning = false
        pump()
        XCTAssertEqual(r.feature.pressureCheckbox.state, .off)
        XCTAssertTrue(r.feature.statusLabel.isHidden)
        XCTAssertTrue(r.feature.findingsStack.isHidden)
    }

    func testTheBoxesFollowTheirSettings() throws {
        let r = try rig()
        r.settings.memoryWatchPressureWarning = true
        pump()
        XCTAssertEqual(r.feature.pressureCheckbox.state, .on)
        XCTAssertEqual(r.feature.enableCheckbox.state, .off)
        r.settings.memoryWatchPressureWarning = false
        pump()
        XCTAssertEqual(r.feature.pressureCheckbox.state, .off)
    }

    func testTheNotificationStatusIsSharedByBothBoxes() throws {
        let r = try rig(pressure: true)
        r.notifier.status = .denied
        r.feature.refresh()
        XCTAssertEqual(r.feature.statusLabel.stringValue, MemoryWatchFeature.deniedText)
        XCTAssertFalse(r.feature.openSettingsButton.isHidden)
        XCTAssertFalse(r.feature.hintLabel.isHidden)
    }

    func testTheListShowsBothKindsAndSaysWhichIsLow() throws {
        let r = try rig(enabled: true, pressure: true)
        r.controller.handle(finding: makeLeakFinding("Safari", pid: 1))
        r.controller.handle(finding: makeLeakFinding("node", app: false, pid: 77, start: 4))
        r.controller.handle(finding: makePressureFinding("Chrome", pid: 2))
        r.feature.refresh()
        XCTAssertEqual(MemoryWatchFeature.rowTitles(of: r.feature.findingsStack),
                       ["Chrome, memory low, 2 min ago", "node (process 77), 2 min ago", "Safari, 2 min ago"])
        let buttons = MemoryWatchFeature.rowButtons(of: r.feature.findingsStack)
        XCTAssertEqual(buttons.map(\.title), ["Open", "Open", "Open"])
        buttons[0].performClick(nil)
        XCTAssertEqual(r.controller.openWindowKeys, ["/Applications/Chrome.app"], "the window of the low-memory finding")
    }

    func testTheRowWordsForEachKind() {
        let now = Date(timeIntervalSince1970: 1_000_180)
        XCTAssertEqual(MemoryWatchFeature.rowTitle(for: makeLeakFinding("Safari"), now: now), "Safari, 3 min ago")
        XCTAssertEqual(MemoryWatchFeature.rowTitle(for: makePressureFinding("Chrome"), now: now), "Chrome, memory low, 3 min ago")
    }

    // ── Off: nothing is read ────────────────────────────────────────────────

    func testWhileOffTheControllerIsNeverLookedAtAndNothingIsShown() throws {
        let r = try rig()
        r.feature.refresh()
        XCTAssertEqual(r.log.controllerLooks, 0, "off means the section asks no one")
        XCTAssertEqual(r.notifier.totalCalls, 0)
        XCTAssertTrue(r.feature.statusLabel.isHidden)
        XCTAssertTrue(r.feature.openSettingsButton.isHidden)
        XCTAssertTrue(r.feature.hintLabel.isHidden)
        XCTAssertTrue(r.feature.findingsStack.isHidden)
        XCTAssertTrue(r.feature.findingsCaption.isHidden)
    }

    func testWithNoControllerTheSectionStillBuildsAndRefreshes() throws {
        // How every other test that builds the default sections gets it, and the app before it has launched.
        let settings = try throwawaySettings(owner: "MemoryWatchFeature", test: name)
        settings.memoryWatchEnabled = true
        let feature = MemoryWatchFeature(settings: settings, controller: { nil })
        _ = feature.makeView()
        feature.refresh()
        XCTAssertEqual(feature.statusLabel.stringValue, MemoryWatchFeature.checkingText)
        XCTAssertEqual(MemoryWatchFeature.rowTitles(of: feature.findingsStack), [MemoryWatchFeature.noFindingsText])
    }

    // ── The switch ──────────────────────────────────────────────────────────

    func testTickingTheBoxWritesTheSettingAndAsksForPermission() throws {
        let r = try rig()
        r.notifier.status = .notDetermined
        r.feature.enableCheckbox.performClick(nil)
        XCTAssertTrue(r.settings.memoryWatchEnabled)
        XCTAssertTrue(r.controller.isEnabled, "the controller followed the setting")
        XCTAssertEqual(r.notifier.requestCalls, 1, "the question is asked when the box is ticked")
        XCTAssertEqual(r.feature.statusLabel.stringValue, MemoryWatchFeature.allowedText)

        r.feature.enableCheckbox.performClick(nil)
        XCTAssertFalse(r.settings.memoryWatchEnabled)
        XCTAssertFalse(r.controller.isEnabled)
        XCTAssertEqual(r.notifier.requestCalls, 1, "unticking asks nothing")
    }

    func testTheInstallTestCopyNeverAsks() throws {
        let r = try rig(sandboxed: true)
        r.notifier.status = .notDetermined
        r.feature.enableCheckbox.performClick(nil)
        XCTAssertTrue(r.settings.memoryWatchEnabled)
        XCTAssertEqual(r.notifier.requestCalls, 0)
    }

    func testTheBoxFollowsTheSetting() throws {
        let r = try rig()
        r.settings.memoryWatchEnabled = true
        pump()
        XCTAssertEqual(r.feature.enableCheckbox.state, .on)
        r.settings.memoryWatchEnabled = false
        pump()
        XCTAssertEqual(r.feature.enableCheckbox.state, .off)
    }

    // ── Notification status ─────────────────────────────────────────────────

    func testTheStatusWordsForEachState() {
        XCTAssertEqual(MemoryWatchFeature.statusText(for: .authorized), "Notifications: allowed")
        XCTAssertEqual(MemoryWatchFeature.statusText(for: .denied), "Notifications are off for Anode")
        XCTAssertEqual(MemoryWatchFeature.statusText(for: .notDetermined), "Not asked yet")
        XCTAssertEqual(MemoryWatchFeature.statusText(for: nil), "Notifications: checking\u{2026}")
    }

    func testTheViewShowsTheStatusAndOffersTheSettingsOnlyWhenBannersCannotShow() throws {
        let cases: [(LeakAuthorization, String, Bool)] = [
            (.authorized, "Notifications: allowed", false),
            (.denied, "Notifications are off for Anode", true),
            (.notDetermined, "Not asked yet", true),
        ]
        for (status, text, offers) in cases {
            let r = try rig(enabled: true, tag: "\(status)")
            r.notifier.status = status
            r.feature.refresh()
            XCTAssertEqual(r.feature.statusLabel.stringValue, text)
            XCTAssertFalse(r.feature.statusLabel.isHidden)
            XCTAssertEqual(r.feature.openSettingsButton.isHidden, !offers, "\(status)")
            XCTAssertEqual(r.feature.hintLabel.isHidden, !offers, "\(status)")
            XCTAssertEqual(r.feature.openSettingsButton.title, "Open Notification Settings")
            XCTAssertTrue(r.feature.hintLabel.stringValue.contains("switch it on there"))
        }
    }

    func testTheSectionFollowsAPermissionChangedBehindIt() throws {
        let r = try rig(enabled: true)
        XCTAssertEqual(r.feature.statusLabel.stringValue, MemoryWatchFeature.allowedText)
        r.notifier.status = .denied          // switched off in System Settings; the window is brought forward
        r.feature.refresh()
        pump()
        XCTAssertEqual(r.feature.statusLabel.stringValue, MemoryWatchFeature.deniedText)
        XCTAssertFalse(r.feature.openSettingsButton.isHidden)
    }

    func testOpenNotificationSettingsTriesTheNewPaneThenTheOldOne() throws {
        let r = try rig(enabled: true)
        r.notifier.status = .denied          // the button is there when banners cannot show
        r.feature.refresh()
        r.log.urlAnswers = [false, true]
        r.feature.openSettingsButton.performClick(nil)
        XCTAssertEqual(r.log.openedURLs, ["x-apple.systempreferences:com.apple.Notifications-Settings.extension",
                                          "x-apple.systempreferences:com.apple.preference.notifications"])

        let again = try rig(enabled: true, tag: "Again")
        again.notifier.status = .denied
        again.feature.refresh()
        again.log.urlAnswers = [true]
        again.feature.openSettingsButton.performClick(nil)
        XCTAssertEqual(again.log.openedURLs, ["x-apple.systempreferences:com.apple.Notifications-Settings.extension"],
                       "the old pane is only the fall-back")
    }

    // ── Recent findings ─────────────────────────────────────────────────────

    func testTheListSaysHowLongAgoAndOpensTheWindow() throws {
        let r = try rig(enabled: true)
        XCTAssertEqual(MemoryWatchFeature.rowTitles(of: r.feature.findingsStack), ["None yet."])

        r.controller.handle(finding: makeLeakFinding("Safari", pid: 1))
        r.controller.handle(finding: makeLeakFinding("node", app: false, pid: 77, start: 4))
        r.feature.refresh()
        XCTAssertEqual(MemoryWatchFeature.rowTitles(of: r.feature.findingsStack),
                       ["node (process 77), 2 min ago", "Safari, 2 min ago"], "newest first, a tool told apart by its process")

        let buttons = MemoryWatchFeature.rowButtons(of: r.feature.findingsStack)
        XCTAssertEqual(buttons.map(\.title), ["Open", "Open"])
        buttons[1].performClick(nil)
        XCTAssertEqual(r.log.windowsBuilt, 1)
        XCTAssertEqual(r.controller.openWindowKeys, ["/Applications/Safari.app"])
    }

    func testTheListShowsAtMostTenAndTheFindingsLeaveWithTheSwitch() throws {
        let r = try rig(enabled: true)
        for pid in 1...12 { r.controller.handle(finding: makeLeakFinding("node", app: false, pid: pid_t(pid))) }
        r.feature.refresh()
        XCTAssertEqual(MemoryWatchFeature.rowTitles(of: r.feature.findingsStack).count, 10)
        r.settings.memoryWatchEnabled = false
        r.feature.refresh()
        XCTAssertTrue(r.feature.findingsStack.isHidden)
        XCTAssertTrue(MemoryWatchFeature.rowTitles(of: r.feature.findingsStack).isEmpty, "none of it is kept while off")
    }

    func testHowLongAgo() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        func ago(_ seconds: Double) -> String { MemoryWatchFeature.ago(from: now.addingTimeInterval(-seconds), now: now) }
        XCTAssertEqual(ago(0), "just now")
        XCTAssertEqual(ago(59), "just now")
        XCTAssertEqual(ago(60), "1 min ago")
        XCTAssertEqual(ago(3599), "59 min ago")
        XCTAssertEqual(ago(3600), "1 h ago")
        XCTAssertEqual(ago(86_399), "23 h ago")
        XCTAssertEqual(ago(86_400 * 3), "3 d ago")
        XCTAssertEqual(ago(-30), "just now", "a clock that moved back never reads a negative time")
    }

    // ── Ignored apps ────────────────────────────────────────────────────────

    func testTheIgnoredAppsAreListedByNameWithARemoveButton() throws {
        let r = try rig(enabled: true)
        XCTAssertTrue(r.feature.ignoredStack.isHidden)
        XCTAssertTrue(r.feature.ignoredCaption.isHidden)

        r.settings.memoryWatchIgnoredApps = ["/Applications/Safari.app", "/usr/local/bin/node"]
        r.feature.refresh()
        XCTAssertFalse(r.feature.ignoredStack.isHidden)
        XCTAssertEqual(MemoryWatchFeature.rowTitles(of: r.feature.ignoredStack), ["Safari", "node"])
        let buttons = MemoryWatchFeature.rowButtons(of: r.feature.ignoredStack)
        XCTAssertEqual(buttons.map(\.title), ["Remove", "Remove"])

        buttons[0].performClick(nil)
        XCTAssertEqual(r.settings.memoryWatchIgnoredApps, ["/usr/local/bin/node"])
        XCTAssertEqual(MemoryWatchFeature.rowTitles(of: r.feature.ignoredStack), ["node"])

        MemoryWatchFeature.rowButtons(of: r.feature.ignoredStack)[0].performClick(nil)
        XCTAssertEqual(r.settings.memoryWatchIgnoredApps, [])
        XCTAssertTrue(r.feature.ignoredStack.isHidden)
    }

    func testRemovingAnIgnoredAppWithNoControllerStillWritesTheSetting() throws {
        let settings = try throwawaySettings(owner: "MemoryWatchFeature", test: name)
        settings.memoryWatchIgnoredApps = ["/Applications/Safari.app"]
        let feature = MemoryWatchFeature(settings: settings, controller: { nil })
        _ = feature.makeView()
        XCTAssertEqual(MemoryWatchFeature.rowTitles(of: feature.ignoredStack), ["Safari"])
        MemoryWatchFeature.rowButtons(of: feature.ignoredStack)[0].performClick(nil)
        XCTAssertEqual(settings.memoryWatchIgnoredApps, [])
    }
}

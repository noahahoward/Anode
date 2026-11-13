import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// Ready By in the Charge Control section: its switch, its time of day, the line that says what it is doing in the
/// person's own time format, the sentence in the summary, and the Install Helper… button that now shows whenever
/// something switched on needs more of the helper than there is. The controller is a real one on fakes; no helper,
/// charge limit or install dialog is reached.
final class ReadyBySectionTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!
    private var settings: Settings!
    private var helper: FakeHelperLink!
    private var client: FakeChargeLimitClient!
    private var battery: Battery.State?
    private var controller: ChargeController?
    private var clockNow = ISO8601DateFormatter().date(from: "2026-11-12T23:00:00Z")!
    private var view: NSView?

    override func setUpWithError() throws {
        _ = NSApplication.shared
        (defaults, suite) = try TestDefaults.make(owner: "ReadyBySection", test: name)
        settings = Settings(defaults: defaults)
        helper = FakeHelperLink()
        client = FakeChargeLimitClient()
        helper.landsOn = client
        battery = ReadyByControllerTests.plugged(54)
    }

    override func tearDownWithError() throws {
        controller?.shutdown()
        controller = nil
        settings = nil
        TestDefaults.destroy(defaults, suite)
    }

    private func make(enabled: Bool = true, withController: Bool = true) -> ChargeControlFeature {
        settings.chargeControlEnabled = enabled
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let c: ChargeController? = !withController ? nil : ChargeController(settings: settings, makeClient: { [weak self] in self?.client }, helper: helper,
                                 battery: { [weak self] in self?.battery }, chargerSwitch: { nil }, log: { _ in },
                                 noClientBecause: { ChargeController.NoClientReason(unsupportedMac: true, step: nil) },
                                 onConsole: { true }, rateStore: MemoryRateStore(),
                                 now: { [weak self] in self?.clockNow ?? Date() }, calendar: { utc })
        controller = c
        let f = ChargeControlFeature(settings: settings, controller: { c }, installHelper: { _ in })
        view = f.makeView()
        return f
    }

    private func send(_ control: NSControl) { _ = control.target?.perform(control.action, with: control) }

    // ── The controls ────────────────────────────────────────────────────────

    func testTheRowHasASwitchAndATimeAndTheirNames() throws {
        let f = make()
        XCTAssertEqual(f.readyByCheckbox.title, "Ready By")
        XCTAssertEqual(f.readyByTimePicker.accessibilityLabel(), "Ready By: the time of day the battery is to be at the limit")
        XCTAssertEqual(f.readyByTimePicker.datePickerElements, .hourMinute, "hours and minutes, and no date")
        XCTAssertTrue((f.readyByCheckbox.toolTip ?? "").contains("Anode helper"), f.readyByCheckbox.toolTip ?? "")
        XCTAssertTrue(f.readyByCheckbox.isDescendant(of: try XCTUnwrap(view)))
        XCTAssertTrue(f.readyByTimePicker.isDescendant(of: try XCTUnwrap(view)))
    }

    func testOffByDefaultAndTheTimeIsSevenOClock() {
        let f = make()
        XCTAssertEqual(f.readyByCheckbox.state, .off)
        XCTAssertFalse(f.readyByTimePicker.isEnabled, "a time that does nothing is not offered until Ready By is on")
        XCTAssertEqual(ChargeControlFeature.minutes(ofPickerDate: f.readyByTimePicker.dateValue), 420)
    }

    func testTheSwitchWritesTheSettingAndEnablesTheTime() {
        let f = make()
        f.readyByCheckbox.state = .on
        send(f.readyByCheckbox)
        XCTAssertTrue(settings.chargeReadyByEnabled)
        XCTAssertTrue(f.readyByTimePicker.isEnabled)
        f.readyByCheckbox.state = .off
        send(f.readyByCheckbox)
        XCTAssertFalse(settings.chargeReadyByEnabled)
        XCTAssertFalse(f.readyByTimePicker.isEnabled)
    }

    func testTheTimeWritesMinutesAfterMidnight() {
        let f = make()
        for (minutes, label) in [(390, "6:30"), (0, "midnight"), (1439, "23:59"), (735, "12:15"), (60, "1:00")] {
            f.readyByTimePicker.dateValue = ChargeControlFeature.pickerDate(minutes: minutes)
            send(f.readyByTimePicker)
            XCTAssertEqual(settings.chargeReadyByMinutes, minutes, label)
        }
    }

    /// A picker that has stepped past midnight is on another day and is still a time of day.
    func testAPickerOnAnotherDayIsStillATimeOfDay() {
        XCTAssertEqual(ChargeControlFeature.minutes(ofPickerDate: ChargeControlFeature.pickerDate(minutes: 450)
                                                        .addingTimeInterval(86_400)), 450)
        XCTAssertEqual(ChargeControlFeature.minutes(ofPickerDate: ChargeControlFeature.pickerDate(minutes: 450)
                                                        .addingTimeInterval(-86_400)), 450)
        for m in [0, 1, 59, 60, 419, 420, 1438, 1439] {
            XCTAssertEqual(ChargeControlFeature.minutes(ofPickerDate: ChargeControlFeature.pickerDate(minutes: m)), m)
        }
    }

    /// Changed elsewhere (the Mac's own defaults, another window), it shows at once.
    func testSettingsChangedElsewhereShowAtOnce() {
        let f = make()
        settings.chargeReadyByEnabled = true
        settings.chargeReadyByMinutes = 345
        XCTAssertEqual(f.readyByCheckbox.state, .on)
        XCTAssertTrue(f.readyByTimePicker.isEnabled)
        XCTAssertEqual(ChargeControlFeature.minutes(ofPickerDate: f.readyByTimePicker.dateValue), 345)
    }

    /// The section follows the two settings by itself, with no controller to tell it.
    func testWithNoControllerTheSwitchAndTheTimeStillFollowTheSettings() {
        let f = make(withController: false)
        settings.chargeReadyByEnabled = true
        settings.chargeReadyByMinutes = 200
        XCTAssertEqual(f.readyByCheckbox.state, .on)
        XCTAssertEqual(ChargeControlFeature.minutes(ofPickerDate: f.readyByTimePicker.dateValue), 200)
    }

    func testHiddenWhileChargeControlIsOffAndDisabledWhenItCannotRun() {
        let f = make(enabled: false)
        XCTAssertTrue(f.readyByCheckbox.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(f.readyByTimePicker.isHiddenOrHasHiddenAncestor)
        settings.chargeControlEnabled = true
        XCTAssertFalse(f.readyByCheckbox.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(f.readyByCheckbox.isEnabled)
        settings.chargeControlEnabled = false
        XCTAssertTrue(f.readyByCheckbox.isHiddenOrHasHiddenAncestor)

        client = FakeChargeLimitClient(state: nil)       // macOS will not say: Charge Control cannot run
        controller?.shutdown()
        let g = make()
        XCTAssertFalse(g.readyByCheckbox.isEnabled)
        XCTAssertFalse(g.readyByTimePicker.isEnabled)
    }

    // ── The line ────────────────────────────────────────────────────────────

    private func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    private var plainTime: (Date) -> String {
        { d in
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(identifier: "UTC")!
            let p = c.dateComponents([.hour, .minute], from: d)
            let h = p.hour ?? 0
            return String(format: "%d:%02d %@", h % 12 == 0 ? 12 : h % 12, p.minute ?? 0, h < 12 ? "am" : "pm")
        }
    }

    private func readyBy(_ percent: Int?, holdingAt level: Int = 54, until raise: String? = "2026-11-13T05:40:00Z",
                         limit: Int = 80, by: String = "2026-11-13T07:00:00Z") -> String {
        let d = ChargeDecision(osLimit: raise == nil ? limit : level, dischargeTo: nil, reason: .readyBy,
                               readyBy: ReadyByState(by: at(by), raiseAt: raise.map(at), raiseTo: limit))
        return ChargeControlFeature.statusText(.active(d), ChargeControlFeature.Facts(percent: percent), time: plainTime)
    }

    func testTheLineSaysWhatItIsHoldingAndWhenItWillCharge() {
        XCTAssertEqual(readyBy(54), "Holding at 54% until 5:40 am, then charging to reach 80% by 7:00 am")
        XCTAssertEqual(readyBy(nil), "Holding at 54% until 5:40 am, then charging to reach 80% by 7:00 am")
        XCTAssertEqual(readyBy(53), "Holding at 54% until 5:40 am, then charging to reach 80% by 7:00 am",
                       "a point under a held level is still a hold")
        XCTAssertEqual(readyBy(55, holdingAt: 55, limit: 90), "Holding at 55% until 5:40 am, then charging to reach 90% by 7:00 am")
    }

    func testTheLineSaysChargingOnceItHasStarted() {
        XCTAssertEqual(readyBy(60, until: nil), "Charging to reach 80% by 7:00 am")
        XCTAssertEqual(readyBy(nil, until: nil, limit: 100, by: "2026-11-13T19:30:00Z"), "Charging to reach 100% by 7:30 pm")
    }

    /// Below the lowest it holds at, it first charges up to it.
    func testTheLineSaysSoWhileItChargesUpToTheLowestItHolds() {
        XCTAssertEqual(readyBy(22, holdingAt: 30),
                       "Charging to 30%, then holding until 5:40 am, then charging to reach 80% by 7:00 am")
    }

    func testTheTimesAreInThePersonsOwnShortFormat() {
        let d = at("2026-11-13T05:40:00Z")
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(ChargeControlFeature.shortTime(d, locale: Locale(identifier: "de_DE"), timeZone: utc), "05:40",
                       "a Mac set to 24 hours")
        XCTAssertEqual(ChargeControlFeature.shortTime(d, locale: Locale(identifier: "en_GB"), timeZone: utc), "05:40")
        let us = ChargeControlFeature.shortTime(d, locale: Locale(identifier: "en_US"), timeZone: utc)
        XCTAssertTrue(us.hasPrefix("5:40"), us)
        XCTAssertTrue(us.uppercased().hasSuffix("AM"), us)
        // And in the person's zone, not UTC: the same moment is half past midnight elsewhere.
        let tokyo = ChargeControlFeature.shortTime(d, locale: Locale(identifier: "de_DE"),
                                                   timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertEqual(tokyo, "14:40")
    }

    /// The section shows it: a held battery on a live controller says what it is waiting for.
    func testTheSectionShowsTheLineForARealHold() {
        let f = make()
        settings.chargeReadyByEnabled = true
        let line = f.statusLabel.stringValue
        let moment = ChargeControlFeature.shortTime(at("2026-11-13T07:00:00Z"))
        let start = ChargeControlFeature.shortTime(at("2026-11-13T06:19:00Z"))
        XCTAssertEqual(line, "Holding at 54% until \(start), then charging to reach 80% by \(moment)")
        XCTAssertFalse(f.statusLabel.isHiddenOrHasHiddenAncestor)
    }

    func testNoWattsAndNoOtherWordsInTheLine() {
        for text in [readyBy(54), readyBy(60, until: nil), readyBy(22, holdingAt: 30)] {
            XCTAssertNil(text.range(of: #"\d\s?W\b"#, options: .regularExpression), text)
            for word in ["watt", "SMC", "MCL", "fullCharge", "readyBy", "schedul"] {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(word), "\(word) in: \(text)")
            }
        }
    }

    // ── The summary ─────────────────────────────────────────────────────────

    func testTheSummaryHasOneSentenceAboutReadyBy() {
        let s = ChargeControlFeature().summary
        let sentence = "Ready By holds the battery where it is and charges it to the limit by a time you choose, waking "
            + "the Mac if it has to; it needs the Anode helper."
        XCTAssertTrue(s.contains(sentence), s)
        XCTAssertEqual(s.components(separatedBy: "Ready By").count - 1, 1, "one sentence, not a paragraph")
        XCTAssertTrue(s.contains("Quit Anode before removing it by hand"), "the rest of the summary is still there")
    }

    // ── The install button ──────────────────────────────────────────────────

    /// Ready By on, no helper: the line says so and the button is there, with the battery charging to the limit as usual.
    func testWithNoHelperTheSectionSaysSoAndOffersTheInstall() {
        helper.available = false
        helper.installed = false
        helper.speaksReadyBy = false
        let f = make()
        settings.chargeReadyByEnabled = true
        XCTAssertEqual(f.statusLabel.stringValue, ChargeController.readyByNeedsHelperText)
        XCTAssertEqual(f.statusLabel.stringValue, "Ready By needs the Anode helper")
        XCTAssertFalse(f.installButton.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(client.state?.mclLimit, 80, "the battery charges to the limit as usual")
    }

    func testWithAnOlderHelperItSaysItNeedsUpdatingAndOffersTheInstall() {
        helper.speaksReadyBy = false      // protocol 2: it still serves a drain
        let f = make()
        settings.chargeReadyByEnabled = true
        XCTAssertEqual(f.statusLabel.stringValue, ChargeController.helperOutdatedText)
        XCTAssertFalse(f.installButton.isHiddenOrHasHiddenAncestor)
    }

    func testWithAHelperThatKnowsEnoughThereIsNoButton() {
        let f = make()
        settings.chargeReadyByEnabled = true
        XCTAssertTrue(f.installButton.isHiddenOrHasHiddenAncestor)
    }

    /// Not only at the moment a helper-only value is wanted: a switch that needs the helper, with none, shows it.
    func testAnySwitchThatNeedsTheHelperShowsTheButtonWhenThereIsNone() {
        helper.available = false
        helper.installed = false
        helper.speaksReadyBy = false
        battery = ReadyByControllerTests.plugged(80)    // at the limit, so nothing is asked of the helper yet
        let f = make()
        XCTAssertTrue(f.installButton.isHiddenOrHasHiddenAncestor, "nothing switched on needs it")
        for (name, flip) in [("Drift Below the Limit", { self.settings.chargeDriftEnabled = true }),
                             ("Pause When Hot", { self.settings.chargePauseWhenHotEnabled = true }),
                             ("Hold Level During Sleep", { self.settings.chargeHoldDuringSleep = true }),
                             ("Drain Automatically Above the Limit", { self.settings.chargeDrainAutomatically = true })] {
            settings.chargeDriftEnabled = false
            settings.chargePauseWhenHotEnabled = false
            settings.chargeHoldDuringSleep = false
            settings.chargeDrainAutomatically = false
            XCTAssertTrue(f.installButton.isHiddenOrHasHiddenAncestor, "\(name): shown before it was switched on")
            flip()
            XCTAssertFalse(f.installButton.isHiddenOrHasHiddenAncestor, "\(name) needs a helper and none is installed")
        }
    }

    func testTheButtonWaitsUntilTheHelperHasAnswered() {
        helper.answersAtOnce = false
        helper.available = false
        helper.speaksReadyBy = false
        let f = make()
        settings.chargeReadyByEnabled = true
        XCTAssertTrue(f.installButton.isHiddenOrHasHiddenAncestor, "nothing is said about the helper before it answers")
        helper.firstAnswer()
        XCTAssertFalse(f.installButton.isHiddenOrHasHiddenAncestor)
    }

    func testAHelperNeededByASwitchIsWhatTheControllerSaysItIs() {
        let s = settings!
        XCTAssertNil(ChargeController.helperNeeded(by: s))
        s.chargeLimit = 63
        XCTAssertEqual(ChargeController.helperNeeded(by: s), .charge)
        s.chargeLimit = 90
        XCTAssertNil(ChargeController.helperNeeded(by: s), "90 is a limit macOS takes by itself")
        s.chargeDriftEnabled = true
        XCTAssertEqual(ChargeController.helperNeeded(by: s), .charge)
        s.chargeReadyByEnabled = true
        XCTAssertEqual(ChargeController.helperNeeded(by: s), .readyBy)
        XCTAssertLessThan(ChargeController.HelperReach.none, .charge)
        XCTAssertLessThan(ChargeController.HelperReach.charge, .readyBy)
    }

    // ── Names ───────────────────────────────────────────────────────────────

    /// Ready By is not a schedule, and says so nowhere a person can read.
    func testNothingCallsReadyByAScheduleOrTheOtherAppsName() throws {
        let f = make()
        settings.chargeReadyByEnabled = true
        var shown = [f.title, f.summary, f.statusLabel.stringValue, f.readyByCheckbox.title,
                     f.readyByCheckbox.toolTip ?? "", f.readyByTimePicker.toolTip ?? "",
                     f.readyByTimePicker.accessibilityLabel() ?? "", ChargeControlFeature.readyByTip,
                     ChargeController.readyByNeedsHelperText, ChargeController.helperOutdatedText,
                     FanElevation.sessionDisclosure, FanElevation.installDisclosure, FanElevation.wakeForTheLimit,
                     FanElevation.installPrompt, HelperVocabulary.sentence]
        shown += HelperVocabulary.commands
        let otherApp = ["Al", "Den", "te"].joined()
        for text in shown {
            XCTAssertNil(text.range(of: #"schedul"#, options: [.regularExpression, .caseInsensitive]), text)
            XCTAssertFalse(text.localizedCaseInsensitiveContains(otherApp), text)
        }
    }
}

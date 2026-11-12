import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The Charge Control section of Beta Features drives the settings and the controller the way a click would.
///
/// The controller is a real `ChargeController` built on fakes: `FakeChargeLimitClient` for macOS's charge limit,
/// `FakeHelperLink` for the helper, and a battery the test sets. No PowerUI client, helper socket or install dialog is
/// reached: the "Install Helper…" button is handed a closure that counts.
final class ChargeControlFeatureTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!
    private var settings: Settings!
    private var helper: FakeHelperLink!
    /// What the controller's `makeClient` hands over. nil = "this Mac has no client".
    private var clientToMake: ChargeLimitClient?
    private var battery: Battery.State?
    private var controller: ChargeController?
    private var installs = 0
    /// What `makeView` returned for the last section made.
    private var view: NSView?

    override func setUpWithError() throws {
        _ = NSApplication.shared
        (defaults, suite) = try TestDefaults.make(owner: "ChargeControlFeature", test: name)
        settings = Settings(defaults: defaults)
        helper = FakeHelperLink()
        clientToMake = FakeChargeLimitClient()
        battery = ChargeControllerTests.state(70)
        installs = 0
    }

    override func tearDownWithError() throws {
        controller?.shutdown()
        controller = nil
        settings = nil
        TestDefaults.destroy(defaults, suite)
    }

    /// The section, built as the window builds it, on a controller made of fakes (or none).
    private func make(enabled: Bool, withController: Bool = true) -> ChargeControlFeature {
        settings.chargeControlEnabled = enabled
        if withController {
            controller = ChargeController(settings: settings,
                                          makeClient: { [weak self] in self?.clientToMake },
                                          helper: helper,
                                          battery: { [weak self] in self?.battery },
                                          log: { _ in })
        }
        let c = controller
        let f = ChargeControlFeature(settings: settings, controller: { c },
                                     installHelper: { [weak self] in self?.installs += 1 })
        view = f.makeView()
        return f
    }

    private func send(_ control: NSControl) {
        _ = control.target?.perform(control.action, with: control)
    }

    /// Everything the section shows below its checkbox while Charge Control is on.
    private func controls(_ f: ChargeControlFeature) -> [NSView] {
        [f.limitLabel, f.limitSlider, f.limitValueLabel, f.dischargeButton, f.topUpButton,
         f.sailingCheckbox, f.sailingLabel, f.sailingStepper, f.heatCheckbox, f.heatLabel, f.heatStepper,
         f.sleepCheckbox, f.autoDischargeCheckbox, f.statusLabel]
    }

    /// The controls a person changes, which `.unavailable` disables.
    private func inputs(_ f: ChargeControlFeature) -> [NSControl] {
        [f.limitSlider, f.dischargeButton, f.topUpButton, f.sailingCheckbox, f.sailingStepper,
         f.heatCheckbox, f.heatStepper, f.sleepCheckbox, f.autoDischargeCheckbox]
    }

    // ── The brief's four ────────────────────────────────────────────────────

    func testRegisteredInDefaultFeatures() {
        let list = BetaFeaturesWindowController.defaultFeatures(hasLidSensor: false)
        XCTAssertTrue(list.contains { $0 is ChargeControlFeature })
        XCTAssertEqual(list.first { $0 is ChargeControlFeature }?.title, "Charge Control")
    }

    func testSliderRangeAndCommitOnRelease() throws {
        let f = make(enabled: true)
        XCTAssertEqual(f.limitLabel.stringValue, "Limit")
        XCTAssertEqual(f.limitSlider.minValue, 20)
        XCTAssertEqual(f.limitSlider.maxValue, 100)
        XCTAssertFalse(f.limitSlider.isContinuous, "the limit is written on release, not on every pixel of a drag")
        XCTAssertEqual(f.limitSlider.doubleValue, 80)
        XCTAssertEqual(f.limitValueLabel.stringValue, "80%")

        // A drag, through the slider cell's own tracking calls: the label follows the knob, the setting waits.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView?.addSubview(f.limitSlider)
        f.limitSlider.frame = NSRect(x: 50, y: 20, width: 200, height: 21)
        let cell = try XCTUnwrap(f.limitSlider.cell as? NSSliderCell)
        let knob = NSPoint(x: 150, y: 10)
        XCTAssertTrue(cell.startTracking(at: knob, in: f.limitSlider))
        _ = cell.continueTracking(last: knob, current: NSPoint(x: 60, y: 10), in: f.limitSlider)
        let dragged = Int(f.limitSlider.doubleValue.rounded())
        XCTAssertLessThan(dragged, 70, "the drag did not move the knob")
        XCTAssertEqual(f.limitValueLabel.stringValue, "\(dragged)%", "the label does not follow the knob")
        XCTAssertEqual(settings.chargeLimit, 80, "written before the knob was let go")
        // A refresh mid-drag (the controller's timer runs in the tracking mode) leaves the knob and label alone.
        f.refresh()
        XCTAssertEqual(Int(f.limitSlider.doubleValue.rounded()), dragged)
        XCTAssertEqual(f.limitValueLabel.stringValue, "\(dragged)%")
        cell.stopTracking(last: NSPoint(x: 60, y: 10), current: NSPoint(x: 60, y: 10), in: f.limitSlider, mouseIsUp: true)

        // Release: the action is what writes the setting, in whole percent.
        f.limitSlider.doubleValue = 63.4
        send(f.limitSlider)
        XCTAssertEqual(settings.chargeLimit, 63)
        XCTAssertEqual(f.limitSlider.doubleValue, 63, "the knob settles on the whole percent written")
        XCTAssertEqual(f.limitValueLabel.stringValue, "63%")
    }

    func testControlsHiddenWhileOff() {
        let f = make(enabled: false)
        XCTAssertEqual(f.enableCheckbox.title, "Charge Control")
        XCTAssertEqual(f.enableCheckbox.state, .off)
        XCTAssertFalse(f.enableCheckbox.isHiddenOrHasHiddenAncestor)
        for v in controls(f) + [f.installButton] {
            XCTAssertTrue(v.isHiddenOrHasHiddenAncestor, "shown while off: \(v)")
        }
        XCTAssertFalse(f.dischargeButton.isEnabled)
        XCTAssertFalse(f.topUpButton.isEnabled)

        settings.chargeControlEnabled = true
        XCTAssertEqual(f.enableCheckbox.state, .on)
        for v in controls(f) { XCTAssertFalse(v.isHiddenOrHasHiddenAncestor, "hidden while on: \(v)") }
        XCTAssertTrue(f.installButton.isHiddenOrHasHiddenAncestor, "nothing needs the helper")
        XCTAssertTrue(f.dischargeButton.isEnabled)
        XCTAssertTrue(f.topUpButton.isEnabled)

        settings.chargeControlEnabled = false
        for v in controls(f) + [f.installButton] {
            XCTAssertTrue(v.isHiddenOrHasHiddenAncestor, "shown after switching off: \(v)")
        }
        XCTAssertFalse(f.dischargeButton.isEnabled)
    }

    func testStatusTextForEachStatus() {
        let text = ChargeControlFeature.statusText
        XCTAssertEqual(text(.active(ChargeDecision(osLimit: 63, dischargeTo: nil, reason: .sailing))),
                       "macOS is holding 63% (sailing)")
        XCTAssertEqual(text(.active(ChargeDecision(osLimit: 80, dischargeTo: 40, reason: .discharging))),
                       "Discharging to 40% on the adapter")
        XCTAssertEqual(text(.active(ChargeDecision(osLimit: 80, dischargeTo: nil, reason: .limit))),
                       "macOS is holding 80% (your limit)")
        XCTAssertEqual(text(.active(ChargeDecision(osLimit: 100, dischargeTo: nil, reason: .topUp))),
                       "macOS is holding 100% (Top Up)")
        XCTAssertEqual(text(.active(ChargeDecision(osLimit: 57, dischargeTo: nil, reason: .heat))),
                       "macOS is holding 57% (Heat Protection)")
        XCTAssertEqual(text(.active(ChargeDecision(osLimit: 66, dischargeTo: nil, reason: .sleeping))),
                       "macOS is holding 66% (sleeping)")
        XCTAssertEqual(text(.active(ChargeDecision(osLimit: 40, dischargeTo: nil, reason: .discharged))),
                       "macOS is holding 40% (discharged)")
        for msg in [ChargeController.limitNeedsHelperText, ChargeController.dischargeNeedsHelperText,
                    ChargeController.helperOutdatedText] {
            XCTAssertEqual(text(.needsHelper(msg)), msg)
        }
        for msg in [ChargeController.unavailableText, ChargeController.unreadableText, ChargeController.noBatteryText] {
            XCTAssertEqual(text(.unavailable(msg)), msg)
        }
        XCTAssertEqual(text(.off), "Off")
    }

    // ── Controls write their settings, and show them ────────────────────────

    func testCheckboxesAndSteppersWriteTheirSettings() {
        let f = make(enabled: false)
        f.enableCheckbox.performClick(nil)
        XCTAssertTrue(settings.chargeControlEnabled)

        XCTAssertEqual(f.sailingCheckbox.title, "Sailing Mode")
        f.sailingCheckbox.performClick(nil)
        XCTAssertTrue(settings.chargeSailingEnabled)
        XCTAssertEqual(f.sailingStepper.minValue, 1)
        XCTAssertEqual(f.sailingStepper.maxValue, 30)
        f.sailingStepper.integerValue = 9
        send(f.sailingStepper)
        XCTAssertEqual(settings.chargeSailingGap, 9)
        XCTAssertEqual(f.sailingLabel.stringValue, "recharge below limit \u{2212} 9%")

        XCTAssertEqual(f.heatCheckbox.title, "Heat Protection")
        f.heatCheckbox.performClick(nil)
        XCTAssertTrue(settings.chargeHeatProtectionEnabled)
        XCTAssertEqual(f.heatStepper.minValue, 25)
        XCTAssertEqual(f.heatStepper.maxValue, 50)
        f.heatStepper.integerValue = 41
        send(f.heatStepper)
        XCTAssertEqual(settings.chargeMaxTemperatureC, 41)
        XCTAssertEqual(f.heatLabel.stringValue, "pause above 41 \u{00B0}C")

        XCTAssertEqual(f.sleepCheckbox.title, "Stop charging when sleeping")
        f.sleepCheckbox.performClick(nil)
        XCTAssertTrue(settings.chargeStopWhenSleeping)

        XCTAssertEqual(f.autoDischargeCheckbox.title, "Discharge automatically to the limit")
        f.autoDischargeCheckbox.performClick(nil)
        XCTAssertTrue(settings.chargeAutomaticDischarge)

        f.enableCheckbox.performClick(nil)
        XCTAssertFalse(settings.chargeControlEnabled)
    }

    /// A change made elsewhere (the menu, `defaults write`, another window) shows without anyone calling refresh.
    func testSettingsChangedElsewhereShowAtOnce() {
        let f = make(enabled: true)
        XCTAssertEqual(f.sailingLabel.stringValue, "recharge below limit \u{2212} 5%")
        XCTAssertEqual(f.heatLabel.stringValue, "pause above 35 \u{00B0}C")
        XCTAssertFalse(f.sailingStepper.isEnabled, "a stepper for a switched-off mode")
        XCTAssertFalse(f.heatStepper.isEnabled, "a stepper for a switched-off mode")

        settings.chargeLimit = 63
        settings.chargeSailingEnabled = true
        settings.chargeSailingGap = 12
        settings.chargeHeatProtectionEnabled = true
        settings.chargeMaxTemperatureC = 42.5
        settings.chargeStopWhenSleeping = true
        settings.chargeAutomaticDischarge = true

        XCTAssertEqual(f.limitSlider.doubleValue, 63)
        XCTAssertEqual(f.limitValueLabel.stringValue, "63%")
        XCTAssertEqual(f.sailingCheckbox.state, .on)
        XCTAssertEqual(f.sailingStepper.integerValue, 12)
        XCTAssertTrue(f.sailingStepper.isEnabled)
        XCTAssertEqual(f.sailingLabel.stringValue, "recharge below limit \u{2212} 12%")
        XCTAssertEqual(f.heatCheckbox.state, .on)
        XCTAssertTrue(f.heatStepper.isEnabled)
        XCTAssertEqual(f.heatLabel.stringValue, "pause above 42.5 \u{00B0}C", "a stored half degree is shown as stored")
        XCTAssertEqual(f.sleepCheckbox.state, .on)
        XCTAssertEqual(f.autoDischargeCheckbox.state, .on)
    }

    // ── The controller ──────────────────────────────────────────────────────

    /// Ruling 3: the line changes when the controller's status does, without a refresh and without the 30 s tick.
    func testStatusLineFollowsTheController() throws {
        settings.chargeLimit = 40
        let f = make(enabled: true)
        let c = try XCTUnwrap(controller)
        XCTAssertEqual(f.statusLabel.stringValue, "macOS is holding 40% (your limit)")
        c.pressDischarge()   // as the menu would: the section is not told
        XCTAssertEqual(f.statusLabel.stringValue, "Discharging to 40% on the adapter")
        XCTAssertEqual(f.dischargeButton.title, "Stop Discharge")
        battery = ChargeControllerTests.state(40)
        c.tick()
        XCTAssertEqual(f.statusLabel.stringValue, "macOS is holding 40% (discharged)")
        XCTAssertEqual(f.dischargeButton.title, "Discharge", "a discharge that reached the limit ended itself")
    }

    /// Whatever already listened to the controller keeps hearing it.
    func testHookingTheControllerKeepsAnEarlierListener() throws {
        settings.chargeControlEnabled = true
        let c = ChargeController(settings: settings, makeClient: { [weak self] in self?.clientToMake }, helper: helper,
                                 battery: { [weak self] in self?.battery }, log: { _ in })
        controller = c
        var heard = 0
        c.onChange = { heard += 1 }
        let f = ChargeControlFeature(settings: settings, controller: { c }, installHelper: {})
        _ = f.makeView()
        f.refresh()
        c.pressTopUp()
        XCTAssertGreaterThan(heard, 0, "the earlier listener was dropped")
        XCTAssertEqual(f.topUpButton.title, "Cancel Top Up")
    }

    func testDischargeAndTopUpPressTheControllerAndSayHowToUndo() throws {
        settings.chargeLimit = 40
        let f = make(enabled: true)
        let c = try XCTUnwrap(controller)
        XCTAssertEqual(f.dischargeButton.title, "Discharge")
        XCTAssertEqual(f.topUpButton.title, "Top Up")

        f.dischargeButton.performClick(nil)
        XCTAssertTrue(c.isDischargeRequested)
        XCTAssertEqual(f.dischargeButton.title, "Stop Discharge")
        XCTAssertEqual(f.topUpButton.title, "Top Up")

        f.topUpButton.performClick(nil)
        XCTAssertTrue(c.isTopUpRequested)
        XCTAssertFalse(c.isDischargeRequested, "Top Up cancels a discharge")
        XCTAssertEqual(f.dischargeButton.title, "Discharge")
        XCTAssertEqual(f.topUpButton.title, "Cancel Top Up")
        XCTAssertEqual(f.statusLabel.stringValue, "macOS is holding 100% (Top Up)")

        f.topUpButton.performClick(nil)
        XCTAssertFalse(c.isTopUpRequested)
        XCTAssertEqual(f.topUpButton.title, "Top Up")
    }

    /// Ruling 4: this Mac cannot do it. Every control is disabled and the reason shown; the switch still works.
    func testUnavailableDisablesTheControlsAndSaysWhy() throws {
        clientToMake = nil
        let f = make(enabled: true)
        XCTAssertEqual(controller?.status, .unavailable(ChargeController.unavailableText))
        XCTAssertEqual(f.statusLabel.stringValue, ChargeController.unavailableText)
        XCTAssertFalse(f.statusLabel.isHiddenOrHasHiddenAncestor)
        for control in inputs(f) { XCTAssertFalse(control.isEnabled, "enabled while unavailable: \(control)") }
        XCTAssertTrue(f.enableCheckbox.isEnabled, "it must still be possible to switch it off")
        XCTAssertTrue(f.installButton.isHiddenOrHasHiddenAncestor, "a helper would not help")
        f.enableCheckbox.performClick(nil)
        XCTAssertFalse(settings.chargeControlEnabled)
    }

    /// Ruling 4: a limit only the helper can set. The slider still works, the message is shown, and the button opens
    /// the install flow.
    func testNeedsHelperForTheLimitKeepsTheSliderAndOffersTheInstall() throws {
        helper.available = false
        settings.chargeLimit = 63
        let f = make(enabled: true)
        XCTAssertEqual(controller?.status, .needsHelper(ChargeController.limitNeedsHelperText))
        XCTAssertEqual(f.statusLabel.stringValue, ChargeController.limitNeedsHelperText)
        XCTAssertTrue(f.limitSlider.isEnabled)
        XCTAssertFalse(f.installButton.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(f.installButton.isEnabled)
        XCTAssertEqual(f.installButton.title, "Install Helper\u{2026}")
        f.installButton.performClick(nil)
        XCTAssertEqual(installs, 1)

        f.limitSlider.doubleValue = 85
        send(f.limitSlider)
        XCTAssertEqual(settings.chargeLimit, 85)
        XCTAssertEqual(f.statusLabel.stringValue, "macOS is holding 85% (your limit)")
        XCTAssertTrue(f.installButton.isHiddenOrHasHiddenAncestor, "85 needs no helper")
    }

    func testNeedsHelperForADischargeOffersTheInstall() throws {
        helper.available = false
        battery = ChargeControllerTests.state(90)
        let f = make(enabled: true)
        f.dischargeButton.performClick(nil)
        XCTAssertEqual(controller?.status, .needsHelper(ChargeController.dischargeNeedsHelperText))
        XCTAssertEqual(f.statusLabel.stringValue, "Discharge needs the Anode helper")
        XCTAssertFalse(f.installButton.isHiddenOrHasHiddenAncestor)
        f.installButton.performClick(nil)
        XCTAssertEqual(installs, 1)
    }

    /// The windows built from `defaultFeatures()` make this section with no controller (tests, or before launch
    /// finishes). On, it must show its controls without a controller to press.
    func testOnWithoutAControllerIsSafe() {
        let f = make(enabled: true, withController: false)
        XCTAssertFalse(f.limitSlider.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(f.dischargeButton.isEnabled)
        XCTAssertFalse(f.topUpButton.isEnabled)
        f.dischargeButton.performClick(nil)
        f.topUpButton.performClick(nil)
        XCTAssertTrue(f.installButton.isHiddenOrHasHiddenAncestor)
    }

    // ── Words ───────────────────────────────────────────────────────────────

    /// Ruling 5: the summary says what a person needs to know before switching it on.
    func testSummarySaysWhatItChangesAndWhatItNeeds() {
        let s = ChargeControlFeature().summary
        XCTAssertTrue(s.contains("keeps working while Anode is closed"), s)
        XCTAssertTrue(s.contains("turns off Optimized Battery Charging"), s)
        XCTAssertTrue(s.contains("puts it back"), s)
        XCTAssertTrue(s.contains("Discharging needs the Anode helper"), s)
    }

    /// Ruling 1: no jargon and no watts in anything the section can show, the controller's sentences included.
    func testEveryWordShownIsPlain() throws {
        settings.chargeLimit = 40
        let f = make(enabled: true)
        var shown = [f.title, f.summary]
        func collect(_ v: NSView) {
            if let b = v as? NSButton { shown.append(b.title); shown.append(b.toolTip ?? "") }
            else if let t = v as? NSTextField { shown.append(t.stringValue) }
            v.subviews.forEach(collect)
        }
        let root = try XCTUnwrap(view)
        collect(root)
        f.dischargeButton.performClick(nil)
        f.topUpButton.performClick(nil)
        collect(root)
        let reasons: [ChargeReason] = [.limit, .topUp, .heat, .sleeping, .sailing, .discharging, .discharged]
        shown += reasons.map { ChargeControlFeature.statusText(.active(ChargeDecision(osLimit: 70, dischargeTo: nil, reason: $0))) }
        shown += [ChargeController.unavailableText, ChargeController.unreadableText, ChargeController.noBatteryText,
                  ChargeController.limitNeedsHelperText, ChargeController.dischargeNeedsHelperText,
                  ChargeController.helperOutdatedText]
        let banned = ["MCL", "SMC", "PowerUI", "topUp", "watt", "CHIE", "OBC"]
        for text in shown {
            for word in banned { XCTAssertFalse(text.localizedCaseInsensitiveContains(word), "“\(word)” in: \(text)") }
            XCTAssertNil(text.range(of: #"\d\s?W\b"#, options: .regularExpression), "watts in: \(text)")
        }
    }
}

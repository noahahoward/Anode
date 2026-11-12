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
    /// What the last "Install Helper…" press was handed to say how the install is going.
    private var installReport: ((String) -> Void)?
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
        installReport = nil
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
                                     installHelper: { [weak self] report in
                                         self?.installs += 1
                                         self?.installReport = report
                                     })
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

    /// A drag AppKit refuses to start (the slider was disabled under the pointer) is not a drag: the knob must go on
    /// following the setting afterwards.
    func testADragThatNeverStartedDoesNotFreezeTheKnob() throws {
        let f = make(enabled: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView?.addSubview(f.limitSlider)
        f.limitSlider.frame = NSRect(x: 50, y: 20, width: 200, height: 21)
        let cell = try XCTUnwrap(f.limitSlider.cell as? NSSliderCell)
        f.limitSlider.isEnabled = false
        XCTAssertFalse(cell.startTracking(at: NSPoint(x: 150, y: 10), in: f.limitSlider),
                       "AppKit started a drag on a disabled slider; this test needs another way to refuse one")
        settings.chargeLimit = 63
        XCTAssertEqual(f.limitSlider.doubleValue, 63, "the knob stopped following the setting")
        XCTAssertEqual(f.limitValueLabel.stringValue, "63%")
    }

    /// A slider in a window, with its cell, so a test can drag it through the cell's own tracking calls.
    private func draggable(_ f: ChargeControlFeature) throws -> (NSWindow, NSSliderCell) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView?.addSubview(f.limitSlider)
        f.limitSlider.frame = NSRect(x: 50, y: 20, width: 200, height: 21)
        return (window, try XCTUnwrap(f.limitSlider.cell as? NSSliderCell))
    }

    /// Let the main run loop take one turn in the default mode, as it does once a drag has ended.
    private func settle() {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// A drag that ends while the slider is disabled (or hidden: switched off from the menu mid-drag) sends no action.
    /// The knob goes back to the stored limit rather than resting on a value nobody stored.
    func testADragEndingWithoutItsActionPutsTheKnobBack() throws {
        let f = make(enabled: true)
        let (window, cell) = try draggable(f)
        let knob = NSPoint(x: 150, y: 10), there = NSPoint(x: 60, y: 10)
        XCTAssertTrue(cell.startTracking(at: knob, in: f.limitSlider))
        _ = cell.continueTracking(last: knob, current: there, in: f.limitSlider)
        XCTAssertLessThan(f.limitSlider.doubleValue, 70, "the drag did not move the knob")
        f.limitSlider.isEnabled = false
        cell.stopTracking(last: there, current: there, in: f.limitSlider, mouseIsUp: true)
        settle()
        XCTAssertEqual(f.limitSlider.doubleValue, 80, "the knob rests on a limit that was never stored")
        XCTAssertEqual(f.limitValueLabel.stringValue, "80%")
        XCTAssertEqual(settings.chargeLimit, 80)
        withExtendedLifetime(window) {}
    }

    /// The ordinary release: the action AppKit sends after the drag writes the limit, and the redraw that follows
    /// the drag keeps it.
    func testAReleasedDragKeepsWhatItWrote() throws {
        let f = make(enabled: true)
        let (window, cell) = try draggable(f)
        let knob = NSPoint(x: 150, y: 10), there = NSPoint(x: 60, y: 10)
        XCTAssertTrue(cell.startTracking(at: knob, in: f.limitSlider))
        _ = cell.continueTracking(last: knob, current: there, in: f.limitSlider)
        let dragged = Int(f.limitSlider.doubleValue.rounded())
        cell.stopTracking(last: there, current: there, in: f.limitSlider, mouseIsUp: true)
        send(f.limitSlider)
        settle()
        XCTAssertEqual(settings.chargeLimit, dragged)
        XCTAssertEqual(f.limitSlider.doubleValue, Double(dragged))
        XCTAssertEqual(f.limitValueLabel.stringValue, "\(dragged)%")
        withExtendedLifetime(window) {}
    }

    /// VoiceOver names each control that has no title of its own.
    func testControlsHaveAccessibleNames() {
        let f = make(enabled: true)
        XCTAssertEqual(f.limitSlider.accessibilityLabel(), "Charge limit")
        XCTAssertEqual(f.sailingStepper.accessibilityLabel(), "Sailing Mode: how far below the limit to recharge")
        XCTAssertEqual(f.heatStepper.accessibilityLabel(), "Heat Protection: temperature to pause at")
    }

    func testControlsHiddenWhileOff() {
        battery = ChargeControllerTests.state(90)   // above the limit, so both buttons can do something when on
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
        typealias Facts = ChargeControlFeature.Facts
        func text(_ s: ChargeStatus, _ facts: Facts = Facts()) -> String { ChargeControlFeature.statusText(s, facts) }
        func active(_ limit: Int, _ reason: ChargeReason, to: Int? = nil) -> ChargeStatus {
            .active(ChargeDecision(osLimit: limit, dischargeTo: to, reason: reason))
        }
        let plugged = { (p: Int) in Facts(percent: p, cablePresent: true) }

        // A ceiling is a ceiling: "charging to" below it, "holding" only at it.
        XCTAssertEqual(text(active(80, .limit), plugged(70)), "Charging to 80% (your limit)")
        XCTAssertEqual(text(active(80, .limit), plugged(80)), "Holding 80% (your limit)")
        XCTAssertEqual(text(active(80, .limit), plugged(85)), "Not charging: 85% is above 80% (your limit)")
        XCTAssertEqual(text(active(100, .topUp), plugged(70)), "Charging to 100% (Top Up)")
        XCTAssertEqual(text(active(100, .topUp), plugged(100)), "Holding 100% (Top Up)")
        XCTAssertEqual(text(active(63, .sailing), plugged(63)), "Holding 63% (sailing)")
        XCTAssertEqual(text(active(57, .heat), plugged(57)), "Holding 57% (Heat Protection)")
        XCTAssertEqual(text(active(66, .sleeping), plugged(66)), "Holding 66% (sleeping)")
        XCTAssertEqual(text(active(40, .discharged), plugged(40)), "Holding 40% (discharged)")
        XCTAssertEqual(text(active(80, .limit), Facts(percent: 70, cablePresent: false)),
                       "On battery; charging stops at 80%")
        XCTAssertEqual(text(active(80, .limit)), "Charging stops at 80% (your limit)", "nothing known about the battery")

        // A discharge is what the helper runs, not what was asked for.
        XCTAssertEqual(text(active(80, .discharging, to: 40), Facts(percent: 90, dischargeInForce: 40)),
                       "Discharging to 40% on the adapter")
        XCTAssertEqual(text(active(80, .discharging, to: 40), plugged(90)), "Starting to discharge\u{2026}")
        XCTAssertEqual(text(active(80, .limit), Facts(percent: 90, dischargeInForce: 40)),
                       "Stopping the discharge\u{2026}")

        // The minute after a discharge, when macOS shows "not charging" though nothing is wrong.
        XCTAssertEqual(text(active(80, .discharged), Facts(percent: 79, reconnecting: true)),
                       "Reconnecting the charger\u{2026}")
        XCTAssertEqual(text(active(80, .discharged), Facts(percent: 80, reconnecting: true)),
                       "Holding 80% (discharged)", "at the limit there is nothing to reconnect for")

        for msg in [ChargeController.limitNeedsHelperText, ChargeController.dischargeNeedsHelperText,
                    ChargeController.helperOutdatedText] {
            XCTAssertEqual(text(.needsHelper(msg)), msg)
        }
        for msg in [ChargeController.unavailableText, ChargeController.unreadableText, ChargeController.noBatteryText] {
            XCTAssertEqual(text(.unavailable(msg)), msg)
        }
        let refusal = ChargeController.dischargeRefusedText("this Mac cannot warn the helper before it sleeps")
        XCTAssertEqual(text(.refused(refusal)), "The Anode helper would not discharge: this Mac cannot warn the helper "
                       + "before it sleeps")
        XCTAssertEqual(text(.refused(ChargeController.limitRefusedText(63, "macOS did not take the charge limit"))),
                       "The Anode helper did not set the limit to 63%: macOS did not take the charge limit")
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
        XCTAssertEqual(f.sailingLabel.stringValue, "recharge at limit \u{2212} 9%")

        XCTAssertEqual(f.heatCheckbox.title, "Heat Protection")
        f.heatCheckbox.performClick(nil)
        XCTAssertTrue(settings.chargeHeatProtectionEnabled)
        XCTAssertEqual(f.heatStepper.minValue, 25)
        XCTAssertEqual(f.heatStepper.maxValue, 50)
        f.heatStepper.integerValue = 41
        send(f.heatStepper)
        XCTAssertEqual(settings.chargeMaxTemperatureC, 41)
        XCTAssertEqual(f.heatLabel.stringValue, "pause at 41 \u{00B0}C")

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
        XCTAssertEqual(f.sailingLabel.stringValue, "recharge at limit \u{2212} 5%")
        XCTAssertEqual(f.heatLabel.stringValue, "pause at 35 \u{00B0}C")
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
        XCTAssertEqual(f.sailingLabel.stringValue, "recharge at limit \u{2212} 12%")
        XCTAssertEqual(f.heatCheckbox.state, .on)
        XCTAssertTrue(f.heatStepper.isEnabled)
        XCTAssertEqual(f.heatLabel.stringValue, "pause at 42.5 \u{00B0}C", "a stored half degree is shown as stored")
        XCTAssertEqual(f.sleepCheckbox.state, .on)
        XCTAssertEqual(f.autoDischargeCheckbox.state, .on)
    }

    // ── The controller ──────────────────────────────────────────────────────

    /// Ruling 3: the line changes when the controller's status does, without a refresh and without the 30 s tick.
    func testStatusLineFollowsTheController() throws {
        settings.chargeLimit = 40
        let f = make(enabled: true)
        let c = try XCTUnwrap(controller)
        XCTAssertEqual(f.statusLabel.stringValue, "Not charging: 70% is above 40% (your limit)")
        c.pressDischarge()   // as the menu would: the section is not told
        XCTAssertEqual(f.statusLabel.stringValue, "Discharging to 40% on the adapter")
        XCTAssertEqual(f.dischargeButton.title, "Stop Discharge")
        battery = ChargeControllerTests.state(40)
        c.tick()
        XCTAssertEqual(f.statusLabel.stringValue, "Holding 40% (discharged)")
        XCTAssertEqual(f.dischargeButton.title, "Discharge", "a discharge that reached the limit ended itself")
    }

    /// Another part of the app listening to the controller neither silences the section nor is silenced by it.
    func testAnotherListenerDoesNotDisplaceTheSection() throws {
        let f = make(enabled: true)
        let c = try XCTUnwrap(controller)
        var heard = 0
        let other = c.observeChanges { heard += 1 }
        f.refresh()
        c.pressTopUp()
        XCTAssertGreaterThan(heard, 0, "the other listener was dropped")
        XCTAssertEqual(f.topUpButton.title, "Cancel Top Up", "the section was dropped")
        withExtendedLifetime(other) {}
    }

    /// While the helper has not yet said yes, the line says a discharge is starting, and it changes when the
    /// helper answers, with nobody calling refresh. The same for a stop.
    func testStartingAndStoppingADischargeSaySo() throws {
        settings.chargeLimit = 40
        battery = ChargeControllerTests.state(90)
        let f = make(enabled: true)
        let c = try XCTUnwrap(controller)
        helper.deferReplies = true
        c.pressDischarge()
        XCTAssertEqual(f.statusLabel.stringValue, "Starting to discharge\u{2026}")
        helper.flushReplies()
        XCTAssertEqual(f.statusLabel.stringValue, "Discharging to 40% on the adapter")
        helper.deferReplies = true
        c.pressDischarge()
        XCTAssertEqual(f.statusLabel.stringValue, "Stopping the discharge\u{2026}")
        helper.flushReplies()
        XCTAssertEqual(f.statusLabel.stringValue, "Not charging: 90% is above 40% (your limit)")
    }

    /// The minute after a discharge in which macOS shows "not charging" is shown as what it is, not as a fault; then
    /// the line says the battery is charging.
    func testAfterADischargeTheLineSaysTheChargerIsReconnecting() throws {
        battery = ChargeControllerTests.state(90)
        let f = make(enabled: true)
        let c = try XCTUnwrap(controller)
        c.pressDischarge()
        battery = ChargeControllerTests.state(79)
        c.tick()
        XCTAssertEqual(f.statusLabel.stringValue, "Reconnecting the charger\u{2026}")
        XCTAssertEqual(f.statusLabel.textColor, .secondaryLabelColor, "shown as a fault")
    }

    /// The words follow the charge and the cable as the controller sees them, with nobody calling refresh.
    func testTheLineFollowsTheChargeAndTheCable() throws {
        let f = make(enabled: true)
        let c = try XCTUnwrap(controller)
        XCTAssertEqual(f.statusLabel.stringValue, "Charging to 80% (your limit)")
        battery = ChargeControllerTests.state(80)
        c.tick()
        XCTAssertEqual(f.statusLabel.stringValue, "Holding 80% (your limit)")
        battery = ChargeControllerTests.state(80, ac: false)
        c.tick()
        XCTAssertEqual(f.statusLabel.stringValue, "On battery; charging stops at 80%")
    }

    /// Top Up with the cable out would end the moment it began: the button waits for the charger, and says so.
    func testTopUpNeedsTheCharger() throws {
        battery = ChargeControllerTests.state(70, ac: false)
        let f = make(enabled: true)
        let c = try XCTUnwrap(controller)
        XCTAssertFalse(f.topUpButton.isEnabled)
        XCTAssertEqual(f.topUpButton.toolTip, "Top Up needs the charger.")
        battery = ChargeControllerTests.state(70)
        c.tick()
        XCTAssertTrue(f.topUpButton.isEnabled)
        XCTAssertEqual(f.topUpButton.toolTip, "Charge to 100% this once. It ends when you unplug.")
    }

    /// Discharge needs the charger and a battery above the limit; otherwise it would end the moment it began. A
    /// discharge under way can always be stopped.
    func testDischargeNeedsTheChargerAndABatteryAboveTheLimit() throws {
        let blocked = "Discharge needs the charger and a battery above the limit."
        let f = make(enabled: true)   // 70%, limit 80
        let c = try XCTUnwrap(controller)
        XCTAssertFalse(f.dischargeButton.isEnabled, "nothing above the limit to discharge")
        XCTAssertEqual(f.dischargeButton.toolTip, blocked)
        battery = ChargeControllerTests.state(80)
        c.tick()
        XCTAssertFalse(f.dischargeButton.isEnabled, "at the limit there is nothing to discharge")
        battery = ChargeControllerTests.state(81)
        c.tick()
        XCTAssertTrue(f.dischargeButton.isEnabled)
        XCTAssertTrue(f.dischargeButton.toolTip?.hasPrefix("Run the Mac from the battery") == true)
        battery = ChargeControllerTests.state(90, ac: false)
        c.tick()
        XCTAssertFalse(f.dischargeButton.isEnabled, "the cable is out")
        XCTAssertEqual(f.dischargeButton.toolTip, blocked)

        battery = ChargeControllerTests.state(90)
        c.tick()
        f.dischargeButton.performClick(nil)
        XCTAssertEqual(f.dischargeButton.title, "Stop Discharge")
        XCTAssertTrue(f.dischargeButton.isEnabled, "a discharge under way cannot be stopped")
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
        // The discharge Top Up ended hands the battery back to the charger, which macOS takes a minute over.
        XCTAssertEqual(f.statusLabel.stringValue, "Reconnecting the charger\u{2026}")

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
        XCTAssertEqual(f.statusLabel.stringValue, "Charging to 85% (your limit)")
        XCTAssertTrue(f.installButton.isHiddenOrHasHiddenAncestor, "85 needs no helper")
    }

    /// The install is started here and runs in the Fans tab's flow, whose own strip is not on screen: everything it
    /// says (waiting, a second press, the outcome) is shown in this section, under the button.
    func testTheInstallSaysHowItIsGoingHere() throws {
        helper.available = false
        settings.chargeLimit = 63
        let f = make(enabled: true)
        XCTAssertTrue(f.installNoteLabel.isHiddenOrHasHiddenAncestor, "a note before anything was pressed")
        f.installButton.performClick(nil)
        let report = try XCTUnwrap(installReport)
        for text in ["Waiting for authorisation\u{2026}", "Finish the authorisation already on screen.",
                     "The Anode helper was not installed: the disk is locked"] {
            report(text)
            XCTAssertEqual(f.installNoteLabel.stringValue, text)
            XCTAssertFalse(f.installNoteLabel.isHiddenOrHasHiddenAncestor, "not shown: \(text)")
        }
        // Pressed again: the old outcome goes; the new install says its own.
        f.installButton.performClick(nil)
        XCTAssertTrue(f.installNoteLabel.isHiddenOrHasHiddenAncestor, "an old outcome shown for a new install")
        try XCTUnwrap(installReport)("The Anode helper is installed. Fan control is as it was.")
        XCTAssertEqual(f.installNoteLabel.stringValue, "The Anode helper is installed. Fan control is as it was.")
        // Still shown once the helper is there and the button has gone.
        helper.becomeAvailable()
        XCTAssertTrue(f.installButton.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(f.installNoteLabel.isHiddenOrHasHiddenAncestor, "the outcome went with the button")
        // Switched off, it goes, and does not come back on.
        settings.chargeControlEnabled = false
        XCTAssertTrue(f.installNoteLabel.isHiddenOrHasHiddenAncestor)
        settings.chargeControlEnabled = true
        XCTAssertTrue(f.installNoteLabel.isHiddenOrHasHiddenAncestor)
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

    /// The window shows the section (or the app comes forward with it open): the controller looks again for a helper
    /// that has not answered. The section's own redraws, on every setting and status change, do not; nor does a
    /// timer.
    func testShowingTheSectionLooksForTheHelperAgain() throws {
        battery = ChargeControllerTests.state(90)
        let f = make(enabled: true)
        let before = helper.rechecks
        f.refresh()
        XCTAssertEqual(helper.rechecks, before + 1)
        settings.chargeLimit = 85
        f.dischargeButton.performClick(nil)
        controller?.periodicTick()
        XCTAssertEqual(helper.rechecks, before + 1, "a redraw looked for the helper")
    }

    /// The helper refusing a discharge for a reason that does not pass by itself: the reason is shown, and there is
    /// nothing to install.
    func testALastingRefusalIsShownWithoutAnInstallButton() throws {
        let why = "the charger may still be cut off from an earlier failure"
        helper.answer = { cmd in
            if case .discharge = cmd { return FanReply(ok: false, message: why) }
            return FanReply(ok: true, message: "ok")
        }
        battery = ChargeControllerTests.state(90)
        let f = make(enabled: true)
        f.dischargeButton.performClick(nil)
        XCTAssertEqual(controller?.status, .refused(ChargeController.dischargeRefusedText(why)))
        XCTAssertEqual(f.statusLabel.stringValue, "The Anode helper would not discharge: \(why)")
        XCTAssertFalse(f.statusLabel.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(f.installButton.isHiddenOrHasHiddenAncestor, "the helper is there; installing would not help")
        XCTAssertTrue(f.dischargeButton.isEnabled)
        XCTAssertEqual(f.dischargeButton.title, "Stop Discharge")
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
            shown.append(v.accessibilityLabel() ?? "")
            v.subviews.forEach(collect)
        }
        let root = try XCTUnwrap(view)
        collect(root)
        f.dischargeButton.performClick(nil)
        f.topUpButton.performClick(nil)
        collect(root)
        battery = ChargeControllerTests.state(30, ac: false)   // both buttons say why they wait
        controller?.tick()
        collect(root)
        let reasons: [ChargeReason] = [.limit, .topUp, .heat, .sleeping, .sailing, .discharging, .discharged]
        typealias Facts = ChargeControlFeature.Facts
        let facts = [Facts(), Facts(percent: 60), Facts(percent: 70), Facts(percent: 80), Facts(percent: 60, cablePresent: false),
                     Facts(percent: 60, reconnecting: true), Facts(percent: 80, dischargeInForce: 70)]
        for reason in reasons {
            for to in [nil, 70] as [Int?] {
                shown += facts.map {
                    ChargeControlFeature.statusText(.active(ChargeDecision(osLimit: 70, dischargeTo: to, reason: reason)), $0)
                }
            }
        }
        shown += [ChargeController.unavailableText, ChargeController.unreadableText, ChargeController.noBatteryText,
                  ChargeController.limitNeedsHelperText, ChargeController.dischargeNeedsHelperText,
                  ChargeController.helperOutdatedText,
                  ChargeController.dischargeRefusedText("the charger may still be cut off from an earlier failure"),
                  ChargeController.limitRefusedText(63, "macOS did not take the charge limit")]
        // What an install started here can say under its button.
        shown += [FanControlPanel.waitingText, FanControlPanel.authorisationOnScreenText,
                  FanControlPanel.notBundledInstallText, FanControlPanel.cancelledText,
                  FanControlPanel.installedForChargeControlText, FanControlPanel.notInstalledText("the disk is locked")]
        // The other charge app's name, built from pieces so this file does not carry it either.
        let otherApp = ["Al", "Den", "te"].joined()
        let banned = ["MCL", "SMC", "PowerUI", "topUp", "watt", "CHIE", "OBC", otherApp]
        for text in shown {
            for word in banned { XCTAssertFalse(text.localizedCaseInsensitiveContains(word), "“\(word)” in: \(text)") }
            XCTAssertNil(text.range(of: #"\d\s?W\b"#, options: .regularExpression), "watts in: \(text)")
        }
    }
}

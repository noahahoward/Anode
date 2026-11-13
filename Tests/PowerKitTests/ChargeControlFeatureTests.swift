import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The Charge Control section of Beta Features drives the settings and the controller the way a click would.
///
/// The controller is a real `ChargeController` built on fakes: `FakeChargeLimitClient` for macOS's charge limit,
/// `FakeHelperLink` for the helper, and a battery the test sets. No PowerUI client, helper socket or install dialog is
/// reached: the "Install Anode Helper…" button is handed a closure that counts.
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
    /// What the controller wrote to its log.
    private var logLines: [String] = []
    /// What the last "Install Anode Helper…" press was handed to say how the install is going.
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
        logLines = []
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
                                          chargerSwitch: { nil },
                                          log: { [weak self] in self?.logLines.append($0) },
                                          noClientBecause: { ChargeController.NoClientReason(unsupportedMac: true,
                                                                                            step: nil) },
                                          onConsole: { true })
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
        [f.limitLabel, f.limitSlider, f.limitValueLabel, f.drainButton, f.fullChargeButton,
         f.driftCheckbox, f.driftLabel, f.driftStepper, f.heatCheckbox, f.heatLabel, f.heatStepper,
         f.sleepCheckbox, f.drainAutomaticallyCheckbox, f.readyByCheckbox, f.readyByTimePicker, f.statusLabel]
    }

    /// The controls a person changes, which `.unavailable` disables.
    private func inputs(_ f: ChargeControlFeature) -> [NSControl] {
        [f.limitSlider, f.drainButton, f.fullChargeButton, f.driftCheckbox, f.driftStepper,
         f.heatCheckbox, f.heatStepper, f.sleepCheckbox, f.drainAutomaticallyCheckbox, f.readyByCheckbox,
         f.readyByTimePicker]
    }

    // ── The brief's four ────────────────────────────────────────────────────

    func testRegisteredInDefaultFeatures() throws {
        let list = BetaFeaturesWindowController.defaultFeatures(hasLidSensor: false, settings: try throwawaySettings(owner: "ChargeControlFeature"))
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
        XCTAssertEqual(f.driftStepper.accessibilityLabel(), "Drift Below the Limit: how far below the limit to recharge")
        XCTAssertEqual(f.heatStepper.accessibilityLabel(), "Pause When Hot: temperature to pause at")
        XCTAssertEqual(f.readyByTimePicker.accessibilityLabel(),
                       "Ready By: the time of day the battery is to be at the limit")
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
        XCTAssertFalse(f.drainButton.isEnabled)
        XCTAssertFalse(f.fullChargeButton.isEnabled)

        settings.chargeControlEnabled = true
        XCTAssertEqual(f.enableCheckbox.state, .on)
        for v in controls(f) { XCTAssertFalse(v.isHiddenOrHasHiddenAncestor, "hidden while on: \(v)") }
        XCTAssertTrue(f.installButton.isHiddenOrHasHiddenAncestor, "nothing needs the helper")
        XCTAssertTrue(f.drainButton.isEnabled)
        XCTAssertTrue(f.fullChargeButton.isEnabled)

        settings.chargeControlEnabled = false
        for v in controls(f) + [f.installButton] {
            XCTAssertTrue(v.isHiddenOrHasHiddenAncestor, "shown after switching off: \(v)")
        }
        XCTAssertFalse(f.drainButton.isEnabled)
    }

    /// Off, with a discharge's end never confirmed (a helper started by hand and killed under it, then Charge Control
    /// switched off): the line still shows, in orange, under the switch alone, saying the charger may still be
    /// switched off and how to get it back. It goes once the debt is settled.
    func testWhileOffAnUnconfirmedDischargeEndStillShowsTheWarning() throws {
        settings.chargeCutUnconfirmed = true
        helper.installed = false
        let f = make(enabled: false)
        XCTAssertFalse(f.statusLabel.isHiddenOrHasHiddenAncestor, "the debt was silent while off")
        XCTAssertEqual(f.statusLabel.stringValue, ChargeController.cutWarningOffText)
        XCTAssertEqual(f.statusLabel.textColor, .systemOrange)
        // The button the line points at is shown beside it, with Charge Control off: a Charge-Control-only person
        // has no other (the Fans tab's Copy Start Command is there only with fan control on).
        XCTAssertFalse(f.installButton.isHiddenOrHasHiddenAncestor, "the line points at a button that is not there")
        for v in controls(f) where v !== f.statusLabel {
            XCTAssertTrue(v.isHiddenOrHasHiddenAncestor, "shown while off: \(v)")
        }
        XCTAssertTrue(helper.commands.isEmpty, "the line sent something")

        // Switching on asks the helper (started again by now), whose yes settles it; switching off again is quiet.
        settings.chargeControlEnabled = true
        XCTAssertFalse(settings.chargeCutUnconfirmed)
        settings.chargeControlEnabled = false
        XCTAssertTrue(f.statusLabel.isHiddenOrHasHiddenAncestor)
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
        XCTAssertEqual(text(active(100, .fullCharge), plugged(70)), "Charging to 100% (Charge to Full)")
        XCTAssertEqual(text(active(100, .fullCharge), plugged(100)), "Holding 100% (Charge to Full)")
        XCTAssertEqual(text(active(63, .drift), plugged(63)), "Holding 63% (drifting)")
        XCTAssertEqual(text(active(57, .heat), plugged(57)), "Holding 57% (Pause When Hot)")
        XCTAssertEqual(text(active(66, .sleeping), plugged(66)), "Holding 66% (sleeping)")
        XCTAssertEqual(text(active(40, .drained), plugged(40)), "Holding 40% (drained)")
        XCTAssertEqual(text(active(80, .limit), Facts(percent: 70, cablePresent: false)),
                       "On battery; charging stops at 80%")
        XCTAssertEqual(text(active(80, .limit)), "Charging stops at 80% (your limit)", "nothing known about the battery")

        // A discharge is what the helper runs, not what was asked for.
        XCTAssertEqual(text(active(80, .draining, to: 40), Facts(percent: 90, dischargeInForce: 40)),
                       "Draining to 40% on the adapter")
        XCTAssertEqual(text(active(80, .draining, to: 40), plugged(90)), "Starting to drain\u{2026}")
        XCTAssertEqual(text(active(80, .limit), Facts(percent: 90, dischargeInForce: 40)),
                       "Stopping the drain\u{2026}")

        // The minute after a discharge, when macOS shows "not charging" though nothing is wrong.
        XCTAssertEqual(text(active(80, .drained), Facts(percent: 79, reconnecting: true)),
                       "Reconnecting the charger\u{2026}")
        XCTAssertEqual(text(active(80, .drained), Facts(percent: 80, reconnecting: true)),
                       "Holding 80% (drained)", "at the limit there is nothing to reconnect for")

        for msg in [ChargeController.limitNeedsHelperText, ChargeController.drainNeedsHelperText,
                    ChargeController.helperOutdatedText] {
            XCTAssertEqual(text(.needsHelper(msg)), msg)
        }
        for msg in [ChargeController.unavailableText, ChargeController.clientMissingText,
                    ChargeController.unreadableText, ChargeController.noBatteryText] {
            XCTAssertEqual(text(.unavailable(msg)), msg)
        }
        let refusal = ChargeController.drainRefusedText("this Mac cannot warn the helper before it sleeps")
        XCTAssertEqual(text(.refused(refusal)), "The Anode helper would not start the drain: this Mac cannot warn the helper "
                       + "before it sleeps")
        XCTAssertEqual(text(.refused(ChargeController.limitRefusedText(63, "macOS did not take the charge limit"))),
                       "The Anode helper did not set the limit to 63%: macOS did not take the charge limit")
        XCTAssertEqual(text(.off), "Off")
        XCTAssertEqual(text(.waiting(ChargeController.liftedText)), ChargeController.liftedText)
    }

    /// After an unclean exit the section says plainly that the limit was lifted and when Charge Control starts again;
    /// Drain to Limit and Charge to Full wait with it, and everything is back when it starts.
    func testWhileWaitingOutTheDelayTheLineSaysSo() throws {
        settings.chargeRestoreRecord = ChargeController.encodeRecord(
            NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: true))
        let f = make(enabled: true)
        XCTAssertEqual(controller?.isWaitingToStart, true)
        XCTAssertFalse(f.statusLabel.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(f.statusLabel.stringValue,
                       "Starting again in a minute. Charge Control waits before holding a limit when Anode did not "
                       + "close normally last time.")
        XCTAssertEqual(f.statusLabel.stringValue, ChargeController.liftedText)
        XCTAssertFalse(f.drainButton.isEnabled)
        XCTAssertFalse(f.fullChargeButton.isEnabled, "Charge to Full can be pressed while nothing is held")
        // They do not claim the charger is missing: nothing is known about it yet.
        XCTAssertEqual(f.fullChargeButton.toolTip, ChargeControlFeature.fullChargeTip)
        XCTAssertEqual(f.drainButton.toolTip, ChargeControlFeature.drainTip)
        XCTAssertTrue(f.enableCheckbox.state == .on)
        XCTAssertTrue(f.limitSlider.isEnabled, "the limit can still be chosen for when it starts")

        controller?.resumeIfDue(now: Date().addingTimeInterval(ChargeController.startDelay + 1))
        XCTAssertEqual(f.statusLabel.stringValue, "Charging to 80% (your limit)")
        XCTAssertTrue(f.fullChargeButton.isEnabled)
    }

    /// With no helper installed to ask, the line that tells how to get the charger back cannot say "once Charge Control
    /// is on": the checkbox is on already. It says nothing about the checkbox, and points at the button.
    func testADebtWithNoHelperDuringTheDelayDoesNotSayChargeControlIsOff() throws {
        settings.chargeRestoreRecord = ChargeController.encodeRecord(
            NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: true))
        settings.chargeCutUnconfirmed = true
        helper.installed = false
        helper.gone = true   // nobody answers the launch's stop, so the debt stays
        let f = make(enabled: true)
        XCTAssertEqual(controller?.isWaitingToStart, true)
        XCTAssertEqual(f.statusLabel.stringValue, ChargeController.cutWarningOffText)
        XCTAssertFalse(f.statusLabel.stringValue.contains("is on and"), f.statusLabel.stringValue)
        XCTAssertEqual(f.statusLabel.textColor, .systemOrange)
        XCTAssertFalse(f.installButton.isHiddenOrHasHiddenAncestor, "the line points at a button that is not there")
        // Once it has started, it is the on-state line.
        controller?.resumeIfDue(now: Date().addingTimeInterval(ChargeController.startDelay + 1))
        XCTAssertNotEqual(f.statusLabel.stringValue, ChargeController.cutWarningOffText)
    }

    /// A discharge's end never confirmed is shown during the delay too, and first: the charger may be cut.
    func testADebtIsShownDuringTheDelay() throws {
        settings.chargeRestoreRecord = ChargeController.encodeRecord(
            NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: true))
        settings.chargeCutUnconfirmed = true
        helper.gone = true
        let f = make(enabled: true)
        XCTAssertEqual(controller?.isWaitingToStart, true)
        // Asked, and not answered (a helper that is gone): "Reconnecting…" would no longer be true.
        XCTAssertEqual(f.statusLabel.stringValue, ChargeController.cutWarningStillAskingText)
        XCTAssertEqual(f.statusLabel.textColor, .systemOrange)
    }

    // ── Controls write their settings, and show them ────────────────────────

    func testCheckboxesAndSteppersWriteTheirSettings() {
        let f = make(enabled: false)
        f.enableCheckbox.performClick(nil)
        XCTAssertTrue(settings.chargeControlEnabled)

        XCTAssertEqual(f.driftCheckbox.title, "Drift Below the Limit")
        f.driftCheckbox.performClick(nil)
        XCTAssertTrue(settings.chargeDriftEnabled)
        XCTAssertEqual(f.driftStepper.minValue, 1)
        XCTAssertEqual(f.driftStepper.maxValue, 30)
        f.driftStepper.integerValue = 9
        send(f.driftStepper)
        XCTAssertEqual(settings.chargeDriftGap, 9)
        XCTAssertEqual(f.driftLabel.stringValue, "recharge at limit \u{2212} 9%")

        XCTAssertEqual(f.heatCheckbox.title, "Pause When Hot")
        f.heatCheckbox.performClick(nil)
        XCTAssertTrue(settings.chargePauseWhenHotEnabled)
        XCTAssertEqual(f.heatStepper.minValue, 25)
        XCTAssertEqual(f.heatStepper.maxValue, 50)
        f.heatStepper.integerValue = 41
        send(f.heatStepper)
        XCTAssertEqual(settings.chargeMaxTemperatureC, 41)
        XCTAssertEqual(f.heatLabel.stringValue, "pause at 41 \u{00B0}C")

        XCTAssertEqual(f.sleepCheckbox.title, "Hold Level During Sleep")
        f.sleepCheckbox.performClick(nil)
        XCTAssertTrue(settings.chargeHoldDuringSleep)

        XCTAssertEqual(f.drainAutomaticallyCheckbox.title, "Drain Automatically Above the Limit")
        f.drainAutomaticallyCheckbox.performClick(nil)
        XCTAssertTrue(settings.chargeDrainAutomatically)

        f.enableCheckbox.performClick(nil)
        XCTAssertFalse(settings.chargeControlEnabled)
    }

    /// A change made elsewhere (the menu, `defaults write`, another window) shows without anyone calling refresh.
    func testSettingsChangedElsewhereShowAtOnce() {
        let f = make(enabled: true)
        XCTAssertEqual(f.driftLabel.stringValue, "recharge at limit \u{2212} 5%")
        XCTAssertEqual(f.heatLabel.stringValue, "pause at 35 \u{00B0}C")
        XCTAssertFalse(f.driftStepper.isEnabled, "a stepper for a switched-off mode")
        XCTAssertFalse(f.heatStepper.isEnabled, "a stepper for a switched-off mode")

        settings.chargeLimit = 63
        settings.chargeDriftEnabled = true
        settings.chargeDriftGap = 12
        settings.chargePauseWhenHotEnabled = true
        settings.chargeMaxTemperatureC = 42.5
        settings.chargeHoldDuringSleep = true
        settings.chargeDrainAutomatically = true

        XCTAssertEqual(f.limitSlider.doubleValue, 63)
        XCTAssertEqual(f.limitValueLabel.stringValue, "63%")
        XCTAssertEqual(f.driftCheckbox.state, .on)
        XCTAssertEqual(f.driftStepper.integerValue, 12)
        XCTAssertTrue(f.driftStepper.isEnabled)
        XCTAssertEqual(f.driftLabel.stringValue, "recharge at limit \u{2212} 12%")
        XCTAssertEqual(f.heatCheckbox.state, .on)
        XCTAssertTrue(f.heatStepper.isEnabled)
        XCTAssertEqual(f.heatLabel.stringValue, "pause at 42.5 \u{00B0}C", "a stored half degree is shown as stored")
        XCTAssertEqual(f.sleepCheckbox.state, .on)
        XCTAssertEqual(f.drainAutomaticallyCheckbox.state, .on)
    }

    // ── The controller ──────────────────────────────────────────────────────

    /// Ruling 3: the line changes when the controller's status does, without a refresh and without the 30 s tick.
    func testStatusLineFollowsTheController() throws {
        settings.chargeLimit = 40
        let f = make(enabled: true)
        let c = try XCTUnwrap(controller)
        XCTAssertEqual(f.statusLabel.stringValue, "Not charging: 70% is above 40% (your limit)")
        c.pressDrain()   // as the menu would: the section is not told
        XCTAssertEqual(f.statusLabel.stringValue, "Draining to 40% on the adapter")
        XCTAssertEqual(f.drainButton.title, "Stop Draining")
        battery = ChargeControllerTests.state(40)
        c.tick()
        XCTAssertEqual(f.statusLabel.stringValue, "Holding 40% (drained)")
        XCTAssertEqual(f.drainButton.title, "Drain to Limit", "a discharge that reached the limit ended itself")
    }

    /// Another part of the app listening to the controller neither silences the section nor is silenced by it.
    func testAnotherListenerDoesNotDisplaceTheSection() throws {
        let f = make(enabled: true)
        let c = try XCTUnwrap(controller)
        var heard = 0
        let other = c.observeChanges { heard += 1 }
        f.refresh()
        c.pressFullCharge()
        XCTAssertGreaterThan(heard, 0, "the other listener was dropped")
        XCTAssertEqual(f.fullChargeButton.title, "Cancel Charge to Full", "the section was dropped")
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
        c.pressDrain()
        XCTAssertEqual(f.statusLabel.stringValue, "Starting to drain\u{2026}")
        helper.flushReplies()
        XCTAssertEqual(f.statusLabel.stringValue, "Draining to 40% on the adapter")
        helper.deferReplies = true
        c.pressDrain()
        XCTAssertEqual(f.statusLabel.stringValue, "Stopping the drain\u{2026}")
        helper.flushReplies()
        XCTAssertEqual(f.statusLabel.stringValue, "Not charging: 90% is above 40% (your limit)")
    }

    /// The minute after a discharge in which macOS shows "not charging" is shown as what it is, not as a fault; then
    /// the line says the battery is charging.
    func testAfterADischargeTheLineSaysTheChargerIsReconnecting() throws {
        battery = ChargeControllerTests.state(90)
        let f = make(enabled: true)
        let c = try XCTUnwrap(controller)
        c.pressDrain()
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

    /// Charge to Full with the cable out would end the moment it began: the button waits for the charger, and says so.
    func testFullChargeNeedsTheCharger() throws {
        battery = ChargeControllerTests.state(70, ac: false)
        let f = make(enabled: true)
        let c = try XCTUnwrap(controller)
        XCTAssertFalse(f.fullChargeButton.isEnabled)
        XCTAssertEqual(f.fullChargeButton.toolTip, "Charge to Full needs the charger.")
        battery = ChargeControllerTests.state(70)
        c.tick()
        XCTAssertTrue(f.fullChargeButton.isEnabled)
        XCTAssertEqual(f.fullChargeButton.toolTip, "Charge to 100% this once. It ends when you unplug.")
    }

    /// Drain to Limit needs the charger and a battery above the limit; otherwise it would end the moment it began. A
    /// discharge under way can always be stopped.
    func testDrainToLimitNeedsTheChargerAndABatteryAboveTheLimit() throws {
        let blocked = "Drain to Limit needs the charger and a battery above the limit."
        let f = make(enabled: true)   // 70%, limit 80
        let c = try XCTUnwrap(controller)
        XCTAssertFalse(f.drainButton.isEnabled, "nothing above the limit to discharge")
        XCTAssertEqual(f.drainButton.toolTip, blocked)
        battery = ChargeControllerTests.state(80)
        c.tick()
        XCTAssertFalse(f.drainButton.isEnabled, "at the limit there is nothing to discharge")
        battery = ChargeControllerTests.state(81)
        c.tick()
        XCTAssertTrue(f.drainButton.isEnabled)
        XCTAssertTrue(f.drainButton.toolTip?.hasPrefix("Run the Mac from the battery") == true)
        battery = ChargeControllerTests.state(90, ac: false)
        c.tick()
        XCTAssertFalse(f.drainButton.isEnabled, "the cable is out")
        XCTAssertEqual(f.drainButton.toolTip, blocked)

        battery = ChargeControllerTests.state(90)
        c.tick()
        f.drainButton.performClick(nil)
        XCTAssertEqual(f.drainButton.title, "Stop Draining")
        XCTAssertTrue(f.drainButton.isEnabled, "a discharge under way cannot be stopped")
    }

    func testDrainAndFullChargePressTheControllerAndSayHowToUndo() throws {
        settings.chargeLimit = 40
        let f = make(enabled: true)
        let c = try XCTUnwrap(controller)
        XCTAssertEqual(f.drainButton.title, "Drain to Limit")
        XCTAssertEqual(f.fullChargeButton.title, "Charge to Full")

        f.drainButton.performClick(nil)
        XCTAssertTrue(c.isDrainRequested)
        XCTAssertEqual(f.drainButton.title, "Stop Draining")
        XCTAssertEqual(f.fullChargeButton.title, "Charge to Full")

        f.fullChargeButton.performClick(nil)
        XCTAssertTrue(c.isFullChargeRequested)
        XCTAssertFalse(c.isDrainRequested, "Charge to Full cancels a discharge")
        XCTAssertEqual(f.drainButton.title, "Drain to Limit")
        XCTAssertEqual(f.fullChargeButton.title, "Cancel Charge to Full")
        // The discharge Charge to Full ended hands the battery back to the charger, which macOS takes a minute over.
        XCTAssertEqual(f.statusLabel.stringValue, "Reconnecting the charger\u{2026}")

        f.fullChargeButton.performClick(nil)
        XCTAssertFalse(c.isFullChargeRequested)
        XCTAssertEqual(f.fullChargeButton.title, "Charge to Full")
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
        XCTAssertEqual(f.installButton.title, "Install Anode Helper\u{2026}")
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

    /// The cut warnings point at the section's own button, so no sentence may name a remedy the person may not have:
    /// the Fans tab shows "Copy Start Command" only with fan control on (or blocked), and fan control is off by
    /// default and stays off when the helper is installed from here.
    func testTheCutWarningsPointAtTheButtonAndNotAtTheFansTab() {
        for text in ChargeController.cutWarningsThatOfferInstall {
            XCTAssertTrue(text.contains("Press Install Anode Helper\u{2026} below"), text)
            XCTAssertFalse(text.contains("Fans tab"), text)
            XCTAssertFalse(text.contains("Copy Start Command"), text)
            XCTAssertFalse(text.contains("sudo"), text)
        }
        // The lines that are shown with the helper installed do not send anyone to a button that is not there.
        for text in [ChargeController.cutWarningText, ChargeController.cutWarningInstalledText] {
            XCTAssertFalse(text.contains("Install Anode Helper"), text)
            XCTAssertFalse(text.contains("Fans tab"), text)
        }
        XCTAssertEqual(ChargeController.cutWarningsThatOfferInstall,
                       [ChargeController.cutWarningNoHelperText, ChargeController.cutWarningOffText])
    }

    /// Running, the charger may be cut and no helper is installed: the line points at the button, so the button is
    /// there, and goes when a helper is (then the line says it is asking).
    func testARunningCutWarningWithNoHelperShowsTheInstallButton() {
        battery = ChargeControllerTests.state(90)
        let f = make(enabled: true)
        f.drainButton.performClick(nil)
        helper.gone = true
        helper.installed = false
        f.drainButton.performClick(nil)   // the stop is not answered: the cut may be left
        XCTAssertEqual(f.statusLabel.stringValue, ChargeController.cutWarningNoHelperText)
        XCTAssertFalse(f.installButton.isHiddenOrHasHiddenAncestor, "the line points at a button that is not there")
        f.installButton.performClick(nil)
        XCTAssertEqual(installs, 1)
        // The helper is installed and starts: the line is the asking one, and nothing points at the button.
        helper.installed = true
        helper.gone = false
        helper.becomeAvailable()
        XCTAssertTrue(f.installButton.isHiddenOrHasHiddenAncestor)
        XCTAssertNotEqual(f.statusLabel.stringValue, ChargeController.cutWarningNoHelperText)
    }

    /// Off, with the cut owed and nothing installed: the button is there, says how the install is going (under it),
    /// and once it has installed the helper the owed stop is asked at once, since nothing else would ask while off.
    func testWhileOffTheInstallButtonShowsItsNoteAndThenAsksTheNewHelper() throws {
        settings.chargeCutUnconfirmed = true
        helper.installed = false
        let f = make(enabled: false)
        XCTAssertFalse(f.installButton.isHiddenOrHasHiddenAncestor)
        f.installButton.performClick(nil)
        XCTAssertEqual(installs, 1)
        let report = try XCTUnwrap(installReport)
        report("Waiting for authorisation\u{2026}")
        XCTAssertEqual(f.installNoteLabel.stringValue, "Waiting for authorisation\u{2026}")
        XCTAssertFalse(f.installNoteLabel.isHiddenOrHasHiddenAncestor, "the note was dropped while off")
        XCTAssertTrue(helper.commands.isEmpty)
        helper.installed = true
        report(FanControlPanel.installedForChargeControlText)
        XCTAssertEqual(helper.stops(), 1, "the helper that was just installed was not asked about the charger")
        XCTAssertNil(controller?.offWarning)
        XCTAssertFalse(settings.chargeCutUnconfirmed)
        XCTAssertTrue(f.installButton.isHiddenOrHasHiddenAncestor)
    }

    func testNeedsHelperForADischargeOffersTheInstall() throws {
        helper.available = false
        battery = ChargeControllerTests.state(90)
        let f = make(enabled: true)
        f.drainButton.performClick(nil)
        XCTAssertEqual(controller?.status, .needsHelper(ChargeController.drainNeedsHelperText))
        XCTAssertEqual(f.statusLabel.stringValue, "Draining to the limit needs the Anode helper")
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
        f.drainButton.performClick(nil)
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
        f.drainButton.performClick(nil)
        XCTAssertEqual(controller?.status, .refused(ChargeController.drainRefusedText(why)))
        XCTAssertEqual(f.statusLabel.stringValue, "The Anode helper would not start the drain: \(why)")
        XCTAssertFalse(f.statusLabel.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(f.installButton.isHiddenOrHasHiddenAncestor, "the helper is there; installing would not help")
        XCTAssertTrue(f.drainButton.isEnabled)
        XCTAssertEqual(f.drainButton.title, "Stop Draining")
    }

    /// The windows built from `defaultFeatures()` make this section with no controller (tests, or before launch
    /// finishes). On, it must show its controls without a controller to press.
    func testOnWithoutAControllerIsSafe() {
        let f = make(enabled: true, withController: false)
        XCTAssertFalse(f.limitSlider.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(f.drainButton.isEnabled)
        XCTAssertFalse(f.fullChargeButton.isEnabled)
        f.drainButton.performClick(nil)
        f.fullChargeButton.performClick(nil)
        XCTAssertTrue(f.installButton.isHiddenOrHasHiddenAncestor)
    }

    // ── Words ───────────────────────────────────────────────────────────────

    /// Ruling 5: the summary says what a person needs to know before switching it on.
    func testSummarySaysWhatItChangesAndWhatItNeeds() {
        let s = ChargeControlFeature(settings: settings, controller: { nil }, installHelper: { _ in }).summary
        // The limit is in force only while Anode runs: it is lifted when Anode quits.
        XCTAssertTrue(s.contains("The limit applies while Anode is running, and is lifted when Anode quits, unless "
                                 + "another account's Anode is holding one."), s)
        XCTAssertFalse(s.contains("keeps working while Anode is closed"), s)
        XCTAssertTrue(s.contains("turns off Optimized Battery Charging"), s)
        XCTAssertTrue(s.contains("puts it back"), s)
        XCTAssertTrue(s.contains("Draining needs the Anode helper"), s)
        // Which features need it besides: anything that holds the charge where macOS cannot by itself.
        for feature in ["Pause When Hot", "Drift Below the Limit", "Hold Level During Sleep"] {
            XCTAssertTrue(s.contains(feature), "the summary does not say \(feature) can need the helper: \(s)")
        }
        // Removed by hand, Anode puts nothing back: quitting does, so quit first.
        XCTAssertTrue(s.contains("Quit Anode before removing it by hand"), s)
        XCTAssertTrue(s.contains("Trash"), s)
    }

    /// The three holds say on their own switch that they cannot pause everywhere without the helper.
    func testTheHoldsSayTheyCanNeedTheHelper() throws {
        let f = make(enabled: true)
        _ = try XCTUnwrap(view)
        for box in [f.heatCheckbox, f.driftCheckbox, f.sleepCheckbox] {
            XCTAssertTrue((box.toolTip ?? "").contains("Anode helper"), "\(box.title): \(box.toolTip ?? "")")
        }
    }

    /// Everything the section can say, in every state a person can put it in: each control's title, tooltip and
    /// accessibility label (a button both as pressed and as not), the status line for every reason, the controller's
    /// own sentences, and what an install started here says under its button.
    private func everythingTheSectionSays() throws -> [String] {
        settings.chargeLimit = 40
        let f = make(enabled: true)
        var shown = [f.title, f.summary]
        func collect(_ v: NSView) {
            if let b = v as? NSButton { shown.append(b.title) }
            else if let t = v as? NSTextField { shown.append(t.stringValue) }
            shown.append(v.toolTip ?? "")
            shown.append(v.accessibilityLabel() ?? "")
            v.subviews.forEach(collect)
        }
        let root = try XCTUnwrap(view)
        collect(root)
        f.drainButton.performClick(nil)
        collect(root)                                  // Stop Draining
        f.fullChargeButton.performClick(nil)           // cancels the drain, which it outranks
        collect(root)                                  // Cancel Charge to Full
        battery = ChargeControllerTests.state(30, ac: false)   // both buttons say why they wait
        controller?.tick()
        collect(root)
        let reasons: [ChargeReason] = [.limit, .fullCharge, .heat, .sleeping, .drift, .draining, .drained, .readyBy]
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
        // Ready By's line, holding, charging up to the lowest it holds at, and charging for the moment.
        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        for raiseAt in [moment.addingTimeInterval(-2400), nil] as [Date?] {
            let state = ReadyByState(by: moment, raiseAt: raiseAt, raiseTo: 80)
            for level in [30, 54] {
                shown += facts.map {
                    ChargeControlFeature.statusText(
                        .active(ChargeDecision(osLimit: raiseAt == nil ? 80 : level, dischargeTo: nil, reason: .readyBy,
                                               readyBy: state)), $0)
                }
            }
        }
        shown += [ChargeControlFeature.readyByTip, ChargeController.readyByNeedsHelperText]
        shown += [ChargeController.unavailableText, ChargeController.clientMissingText,
                  ChargeController.unreadableText, ChargeController.noBatteryText,
                  ChargeController.limitNeedsHelperText, ChargeController.drainNeedsHelperText,
                  ChargeController.helperOutdatedText,
                  ChargeController.drainRefusedText("the charger may still be cut off from an earlier failure"),
                  ChargeController.drainRefusedText("the SMC would not cut the charger"),
                  ChargeController.drainRefusedText("the SMC took the cut and the charger does not read as cut"),
                  ChargeController.limitRefusedText(63, "macOS did not take the charge limit"),
                  ChargeController.macOSRefusedLimitText(wanted: 80, refused: 80, inForce: nil),
                  ChargeController.cutWarningText, ChargeController.cutWarningNoHelperText,
                  ChargeController.cutWarningOffText, ChargeController.cutWarningInstalledText,
                  ChargeController.liftedText]
        shown += reasons.map {
            ChargeController.limitNeedsHelperText(for: ChargeDecision(osLimit: 63, dischargeTo: nil, reason: $0))
        }
        // What an install started here can say under its button.
        shown += [FanControlPanel.waitingText, FanControlPanel.authorisationOnScreenText,
                  FanControlPanel.notBundledInstallText, FanControlPanel.cancelledText,
                  FanControlPanel.installedForChargeControlText, FanControlPanel.notInstalledText("the disk is locked")]
        return shown
    }

    /// Ruling 1: no jargon and no watts in anything the section can show, the controller's sentences included.
    func testEveryWordShownIsPlain() throws {
        let shown = try everythingTheSectionSays()
        // The other charge app's name, built from pieces so this file does not carry it either.
        let otherApp = ["Al", "Den", "te"].joined()
        let banned = ["MCL", "SMC", "PowerUI", "fullCharge", "watt", "CHIE", "OBC", otherApp]
        for text in shown {
            for word in banned { XCTAssertFalse(text.localizedCaseInsensitiveContains(word), "“\(word)” in: \(text)") }
            XCTAssertNil(text.range(of: #"\d\s?W\b"#, options: .regularExpression), "watts in: \(text)")
        }
    }

    // ── Names ───────────────────────────────────────────────────────────────

    private var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// What the helper's sheets and refusals say; the section shows some of it and points at the rest.
    private func theHelperSays() -> [String] {
        [FanElevation.sessionDisclosure, FanElevation.installDisclosure, FanElevation.chargeLimitOutlivesTheHelper,
         FanElevation.wakeForTheLimit, FanElevation.lowPowerModeAndBack, FanElevation.installPrompt, ChargeRefusal.cannotWake,
         ChargeRefusal.planNotInTheFuture, ChargeRefusal.planTooFarAway, ChargeRefusal.wakeNotScheduled,
         FanElevation.uninstallPrompt, FanElevation.uninstallDone, HelperVocabulary.sentence,
         ChargeRefusal.noChargeControl, ChargeRefusal.noSleepNotices, ChargeRefusal.goingToSleep,
         ChargeRefusal.reconnectOwed, ChargeRefusal.targetOutOfRange, ChargeRefusal.batteryUnreadable,
         ChargeRefusal.noCharger, ChargeRefusal.atOrBelow(40), ChargeRefusal.switchedRecently,
         ChargeRefusal.cutRefused, ChargeRefusal.cutNotKept]
    }

    /// Every string literal in a Swift source file, comments left out: what the file can say or log. An
    /// interpolation is cut out of its string, and a string inside one is a literal of its own.
    private func literals(inSource path: String) throws -> [String] {
        let c = Array(try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8))
        var i = 0
        var found: [String] = []
        func at(_ s: String) -> Bool {
            let a = Array(s)
            return i + a.count <= c.count && Array(c[i..<i + a.count]) == a
        }
        func code(untilClose: Bool) {
            var depth = 0
            while i < c.count {
                if at("//") { while i < c.count, c[i] != "\n" { i += 1 }; continue }
                if at("/*") { while i < c.count, !at("*/") { i += 1 }; i += 2; continue }
                if c[i] == "\"" { string(); continue }
                if c[i] == "(" { depth += 1 }
                if c[i] == ")" {
                    if untilClose && depth == 0 { i += 1; return }
                    depth -= 1
                }
                i += 1
            }
        }
        func string() {
            let multiline = at("\"\"\"")
            i += multiline ? 3 : 1
            var text = ""
            while i < c.count {
                if multiline ? at("\"\"\"") : c[i] == "\"" { i += multiline ? 3 : 1; break }
                if c[i] == "\\", i + 1 < c.count {
                    if c[i + 1] == "(" { i += 2; code(untilClose: true); text += " " } else { text.append(c[i + 1]); i += 2 }
                    continue
                }
                text.append(c[i])
                i += 1
            }
            found.append(text)
        }
        code(untilClose: false)
        return found
    }

    /// The names the section's controls were first given, which another app uses for the same features, put together
    /// from pieces so that this file does not carry them either. Each is a pattern for finding it in a sentence.
    /// Discharge is matched with its capital, as the name of a control starts a label or a sentence: the plain word,
    /// for what the battery does and what the helper is asked to do, is lower case and stays.
    private static let oldNames: [(name: String, pattern: String, options: String.CompareOptions)] = {
        let dis = ["Dis", "charg"].joined()
        return [
            (dis + "e", #"\b"# + dis, [.regularExpression]),
            ("Stop " + dis + "e", "stop " + dis.lowercased(), [.regularExpression, .caseInsensitive]),
            ("Top " + "Up", #"\btop[ -]?up\b"#, [.regularExpression, .caseInsensitive]),
            (["Sail", "ing Mode"].joined(), #"\bsail"#, [.regularExpression, .caseInsensitive]),
            (["Heat ", "Protection"].joined(), #"\bheat[ -]?protection"#, [.regularExpression, .caseInsensitive]),
            (["Stop charging", " when sleeping"].joined(), ["stop charging", " when sleeping"].joined(),
             [.regularExpression, .caseInsensitive]),
            (dis + "e automatically to the limit", dis.lowercased() + #"\w* automatically"#,
             [.regularExpression, .caseInsensitive]),
        ]
    }()

    /// The owner's ruling: none of Charge Control's controls carries a name another app uses for the same feature.
    /// Not in the section (every state of every control, its tooltips and accessibility labels), not in the
    /// controller's status and warning texts, not in anything it logs, not in the helper's disclosures, and not in
    /// `uninstall.sh`, which says what to do when Charge Control could not be put away.
    func testNoControlKeepsAnOldName() throws {
        let section = try everythingTheSectionSays()
        // The controller's own words, as it can say them in a run of this test and as its source can say any of them.
        var sources: [String] = []
        for file in ["Sources/AnodeApp/ChargeControlFeature.swift", "Sources/AnodeApp/ChargeController.swift",
                     "Sources/AnodeApp/ChargeRecords.swift", "Sources/PowerKit/ChargeRefusal.swift"] {
            sources += try literals(inSource: file)
        }
        XCTAssertGreaterThan(sources.count, 100, "the scan of the sources found next to no strings")
        let uninstall = try String(contentsOf: repo.appendingPathComponent("uninstall.sh"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.map(String.init)
        let surfaces: [(String, [String])] = [
            ("the section", section), ("charge.log", logLines), ("the sources' strings", sources),
            ("the helper's disclosures", theHelperSays()), ("uninstall.sh", uninstall),
        ]
        for (surface, texts) in surfaces {
            for text in texts {
                for old in Self.oldNames {
                    XCTAssertNil(text.range(of: old.pattern, options: old.options),
                                 "\(old.name) still on \(surface): \(text)")
                }
            }
        }
        // And what they are called now is there, so a gap in what was collected cannot pass for a clean section.
        for name in ["Drain to Limit", "Stop Draining", "Draining to", "Charge to Full", "Cancel Charge to Full",
                     "Drift Below the Limit", "Pause When Hot", "Hold Level During Sleep",
                     "Drain Automatically Above the Limit", "Ready By"] {
            XCTAssertTrue(section.contains { $0.contains(name) }, "\(name) is not shown by the section")
        }
        for line in ["Drain to Limit pressed", "Charge to Full pressed"] {
            XCTAssertTrue(logLines.contains(line), "\(line) is not what the log says: \(logLines)")
        }
        XCTAssertTrue(uninstall.contains { $0.contains("install Anode again, switch Charge Control on and press Install Anode Helper\u{2026}") },
                      "the way back must say the button is shown once Charge Control is on")
        XCTAssertFalse(uninstall.contains { $0.contains("press Install Anode Helper\u{2026} in Charge Control") })
    }
}

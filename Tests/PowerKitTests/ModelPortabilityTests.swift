import XCTest
@testable import AnodeApp
@testable import PowerKit

// Everything this app measures was measured on `Mac17,9` (M5 Pro, 3S pack). A
// second machine — `Mac17,5`, Apple A18 Pro, macOS 26.6, fanless, 1S pack — showed
// what that cost: three defects, all of them the same mistake in different places,
// which is reading ONE model's field names or ONE model's pack topology as if it
// were the hardware.
//
// The numbers in this file are the second machine's, read off it over SSH while it
// ran on battery. They are fixtures, not hypotheses.

// ── The charge basis ────────────────────────────────────────────────────────

/// `Battery.scale()` tried three key names across two dicts; `Battery.state()`
/// read exactly one, with no fallback. On `Mac17,5` that one is absent and the
/// whole drain estimator went down with it.
final class CapacityBasisTests: XCTestCase {

    /// `Mac17,9`, as this app has always read it. The first pair answers, so
    /// nothing about this machine moves.
    func testMac17_9UsesTheFirstPairUnchanged() {
        let props: [String: Any] = [
            "BatteryData": ["RemainingCapacity": 4666, "FullChargeCapacity": 5939,
                            "DesignCapacity": 6249, "NominalChargeCapacity": 6091],
        ]
        let r = Battery.resolveCapacity(props)
        XCTAssertEqual(r?.remaining_mAh, 4666)
        XCTAssertEqual(r?.full_mAh, 5939)
    }

    /// `Mac17,5`: no `RemainingCapacity` anywhere, and the halves of the pair that
    /// DOES answer live in different dicts — `TrueRemainingCapacity` is nested,
    /// `NominalChargeCapacity` is top level.
    func testMac17_5FallsToTheTrueNominalPairAcrossBothDicts() {
        let r = Battery.resolveCapacity(Self.mac17_5)
        XCTAssertEqual(r?.remaining_mAh, 7399)
        XCTAssertEqual(r?.full_mAh, 9340)
        // 79.2%, and the machine's own integer CurrentCapacity read 80.
        XCTAssertEqual(r!.remaining_mAh / r!.full_mAh * 100, 79.2, accuracy: 0.1)
    }

    /// THE POINT OF THE TABLE. Resolving the halves independently would take
    /// `TrueRemainingCapacity` (first remaining available) with `AppleRawMaxCapacity`
    /// (a full that is also available) and print 77.6% — a real-looking number 1.6
    /// points off, from two real fields. Both halves come from one pair or neither.
    func testHalvesAreNeverCrossedBetweenPairs() {
        let r = Battery.resolveCapacity(Self.mac17_5)!
        let crossed = 7399.0 / 9530.0 * 100          // True over AppleRawMax
        let alsoCrossed = 7528.0 / 9340.0 * 100      // AppleRawCurrent over Nominal
        XCTAssertEqual(crossed, 77.6, accuracy: 0.1)
        XCTAssertEqual(alsoCrossed, 80.6, accuracy: 0.1)
        let chosen = r.remaining_mAh / r.full_mAh * 100
        XCTAssertNotEqual(chosen, crossed, accuracy: 0.5)
        XCTAssertNotEqual(chosen, alsoCrossed, accuracy: 0.5)
    }

    /// A pair that answers only its full half is not a basis and must not be used
    /// for one — otherwise the next pair's remaining gets crossed with this one's full.
    func testAPairAnsweringOnlyOneHalfIsSkipped() {
        let props: [String: Any] = [
            "BatteryData": ["FullChargeCapacity": 5939,        // half of pair 1
                            "TrueRemainingCapacity": 7399],    // half of pair 2
            "AppleRawCurrentCapacity": 7528, "AppleRawMaxCapacity": 9530,
        ]
        let r = Battery.resolveCapacity(props)
        XCTAssertEqual(r?.remaining_mAh, 7528, "should fall through to the pair that answers BOTH")
        XCTAssertEqual(r?.full_mAh, 9530)
    }

    func testNoPairAtAllIsNilRatherThanZero() {
        XCTAssertNil(Battery.resolveCapacity(["BatteryData": ["DesignCapacity": 9516]]))
    }

    static let mac17_5: [String: Any] = [
        "BatteryData": ["TrueRemainingCapacity": 7399, "DesignCapacity": 9516,
                        "MaxCapacity": 100, "StateOfCharge": 79],
        "NominalChargeCapacity": 9340,
        "AppleRawCurrentCapacity": 7528,
        "AppleRawMaxCapacity": 9530,
        "Voltage": 4186,
        "CurrentCapacity": 80,
    ]
}

// ── The pack topology ───────────────────────────────────────────────────────

/// `seedNominalVoltage_V` = 11.58 was applied to every machine. It is a 3S
/// constant, and it is wrong by a whole factor on a pack that is not 3S.
final class NominalVoltageTests: XCTestCase {

    /// THE SAFETY PROPERTY. `Mac17,9` reads 12111 mV, resolves to 3 cells, and
    /// lands on exactly the old constant — so every measurement in this repo,
    /// all of which were taken on that machine, still holds to the last digit.
    func testThreeCellPackIsExactlyTheOldSeed() {
        XCTAssertEqual(BatteryScale.nominalVoltage(measured_mV: 12111),
                       BatteryScale.seedNominalVoltage_V, accuracy: 1e-12)
    }

    /// `Mac17,5` reads 4186 mV — one cell. MEASURED consequence of getting this
    /// wrong: 9340 mAh x 11.58 V = 108.2 Wh for a 36.0 Wh pack, so every %/hr off
    /// the power tier came out 3.01x too small.
    func testOneCellPackIsOneThirdOfIt() {
        let v = BatteryScale.nominalVoltage(measured_mV: 4186)
        XCTAssertEqual(v, BatteryScale.seedNominalVoltage_V / 3, accuracy: 1e-12)

        let wrong = BatteryScale(fullChargeCapacity_mAh: 9340, designCapacity_mAh: 9516,
                                 nominalVoltage_V: BatteryScale.seedNominalVoltage_V,
                                 isCalibrated: false)
        let right = BatteryScale(fullChargeCapacity_mAh: 9340, designCapacity_mAh: 9516,
                                 nominalVoltage_V: v, isCalibrated: false)
        XCTAssertEqual(wrong.energyFull_Wh, 108.2, accuracy: 0.2)
        XCTAssertEqual(right.energyFull_Wh, 36.0, accuracy: 0.2)
        XCTAssertEqual(wrong.energyFull_Wh / right.energyFull_Wh, 3.01, accuracy: 0.02)
    }

    /// The measured draw, through both scales, against what macOS said the same
    /// minute (10:11 at 78.9%).
    func testTheNeoDrainFigureLandsOnTheGaugeRatherThanThreeTimesUnderIt() {
        let W = 2.821, soc = 78.9
        func pctHr(_ s: BatteryScale) -> Double { 3600 * W / s.joulesPerPercent }
        let right = BatteryScale(fullChargeCapacity_mAh: 9340, designCapacity_mAh: 9516,
                                 nominalVoltage_V: BatteryScale.nominalVoltage(measured_mV: 4186),
                                 isCalibrated: false)
        let wrong = BatteryScale(fullChargeCapacity_mAh: 9340, designCapacity_mAh: 9516,
                                 nominalVoltage_V: BatteryScale.seedNominalVoltage_V,
                                 isCalibrated: false)
        XCTAssertEqual(pctHr(right), 7.83, accuracy: 0.15)
        XCTAssertEqual(soc / pctHr(right), 10.1, accuracy: 0.4, "macOS said 10:11")
        XCTAssertEqual(soc / pctHr(wrong), 30.3, accuracy: 1.0, "what it used to claim")
    }

    /// Unreadable, absent or implausible: keep the seed. Scaling by a wrong
    /// integer is worse than the constant this replaces.
    func testImplausibleReadingsFallBackToTheSeed() {
        for mV in [nil, Optional(0.0), Optional(-1.0), Optional(60_000.0),
                   Optional(Double.nan), Optional(Double.infinity)] {
            XCTAssertEqual(BatteryScale.nominalVoltage(measured_mV: mV),
                           BatteryScale.seedNominalVoltage_V, "mV = \(String(describing: mV))")
        }
    }

    /// A charged 3S pack reads well above nominal and must not round to 4 cells.
    func testTerminalVoltageSwingDoesNotChangeTheCellCount() {
        for mV in [11_400.0, 12_111.0, 12_600.0, 11_000.0] {
            XCTAssertEqual(BatteryScale.nominalVoltage(measured_mV: mV),
                           BatteryScale.seedNominalVoltage_V, accuracy: 1e-12, "mV = \(mV)")
        }
        for mV in [3_700.0, 4_186.0, 4_400.0] {
            XCTAssertEqual(BatteryScale.nominalVoltage(measured_mV: mV),
                           BatteryScale.seedNominalVoltage_V / 3, accuracy: 1e-12, "mV = \(mV)")
        }
    }
}

// ── The fan question ────────────────────────────────────────────────────────

/// Hiding the Fans tab is a claim about the hardware, so `.fanless` is reached
/// only on evidence. The old rule could never reach it on a machine that
/// publishes no `FNum`, because "no fan key decoded" could not be told apart from
/// "the decoder cannot read this type" — which is the Intel `fpe2` case.
final class FanPresenceOnFanlessHardwareTests: XCTestCase {

    /// `Mac17,5`: SMC opens, publishes 2334 keys, and not one begins with `F`.
    /// A connection answering for thousands of keys while holding no fan key is
    /// evidence of absence, and the tab goes away.
    func testAnsweringSMCWithNoFanKeyIsFanless() {
        let s = FanPresence.decide(smcReachable: true, reportedCount: nil,
                                   respondingFans: 0, smcAnswering: true)
        XCTAssertEqual(s, .fanless)
        XCTAssertFalse(FanPresence.showsFanTab(s))
    }

    /// The distinction that keeps this honest: an SMC that opened but is not
    /// answering has measured nothing, and nothing is not zero.
    func testOpenButSilentSMCIsStillUnknownAndKeepsTheTab() {
        let s = FanPresence.decide(smcReachable: true, reportedCount: nil,
                                   respondingFans: 0, smcAnswering: false)
        XCTAssertEqual(s, .unknown)
        XCTAssertTrue(FanPresence.showsFanTab(s))
    }

    /// The Intel case, and why `detect` now counts keys that EXIST rather than
    /// keys that decode: `F<n>Ac` is `fpe2` there, so the old count was 0 on a
    /// machine with two fans. Counted by existence it is 2, and this branch is
    /// never reached.
    func testAnExistingFanKeyOutranksAMissingCountEvenWhenAnswering() {
        let s = FanPresence.decide(smcReachable: true, reportedCount: nil,
                                   respondingFans: 2, smcAnswering: true)
        XCTAssertEqual(s, .fans(2))
        XCTAssertTrue(FanPresence.showsFanTab(s))
    }

    /// An unreachable SMC has measured nothing, whatever else is passed.
    func testUnreachableSMCIsNeverFanless() {
        XCTAssertEqual(FanPresence.decide(smcReachable: false, reportedCount: nil,
                                          respondingFans: 0, smcAnswering: true), .unknown)
    }

    /// The rail on a fanless machine drops the tab and keeps every other lens,
    /// in order.
    func testFanlessRailOffersEveryOtherLens() {
        let rail = SidebarView.Lens.order(whenFans: .fanless)
        XCTAssertFalse(rail.contains(.fans))
        XCTAssertEqual(rail.count, SidebarView.Lens.allCases.count - 1)
        XCTAssertEqual(rail, SidebarView.Lens.order(whenFans: .unknown)
                          .filter { $0 != SidebarView.Lens.fans })
    }
}

// ── The open panel ──────────────────────────────────────────────────────────

/// Reported from a screenshot: with the group panel open, CPU temperature, GPU
/// temperature and Fan speed all read "—" while every other row carried a live
/// figure — on a machine with two working fans. One cause under that and under
/// the panel updating on the 8 s hidden clock: an open panel was neither
/// window-visible nor "nobody is reading", and the app modelled only those two.
final class OpenPanelSamplingTests: XCTestCase {

    /// Rows carry their metric so an OPEN panel can be updated in place — an
    /// NSMenu cannot have its items swapped while it is on screen, and the panel
    /// has to keep moving while someone is looking at it.
    func testEveryPanelRowKnowsWhichMetricItIs() {
        let menu = MenuBarWidgetController.buildGroupMenu()
        XCTAssertFalse(menu.items.isEmpty)
        for item in menu.items {
            XCTAssertNotNil(item.representedObject as? MetricID, "row '\(item.title)'")
            XCTAssertNotNil(item.view as? MetricRowView, "row '\(item.title)'")
        }
    }

    /// Re-pointing a row at a new reading changes what it shows, and takes it out
    /// of the placeholder ink it was drawn in while it had nothing.
    func testARowCanBeRepointedAtANewReadingInPlace() {
        let row = MetricRowView(name: "CPU temperature", value: "\u{2014}", hasReading: false)
        XCTAssertEqual(row.valueField.textColor, MenuBarWidgetController.placeholderInk)
        row.update(value: "48 °C", hasReading: true)
        XCTAssertEqual(row.valueField.stringValue, "48 °C")
        XCTAssertEqual(row.valueField.textColor, MenuBarWidgetController.rowInk)
        row.update(value: "\u{2014}", hasReading: false)
        XCTAssertEqual(row.valueField.textColor, MenuBarWidgetController.placeholderInk)
    }


    /// The three rows that were dashed are exactly the ones needing `.sensors`.
    func testAnOpenPanelAsksForSensors() {
        let needs = AppDelegate.hiddenNeeds(configs: [], panelOpen: true)
        XCTAssertTrue(needs.contains(.sensors))
        for other: SystemMetrics.Needs in [.cpu, .memory, .gpu, .network, .disk] {
            XCTAssertTrue(needs.contains(other))
        }
    }

    /// The panel lists EVERY metric, so its needs cannot depend on which widgets
    /// happen to be bound — that was the old rule and the reason a temperature row
    /// could only ever show a figure by coincidence.
    func testAnOpenPanelsNeedsDoNotDependOnBoundWidgets() {
        let bare = AppDelegate.hiddenNeeds(configs: [], panelOpen: true)
        let loaded = AppDelegate.hiddenNeeds(
            configs: [WidgetConfig(metricID: MetricID.cpuUsage.rawValue, style: .text)],
            panelOpen: true)
        XCTAssertEqual(bare, loaded)
    }

    /// COLLAPSED, the exclusion stands. Paying the SMC sweep every tick for a group
    /// that is usually collapsed measurably doubled idle CPU (0.375% -> 0.727%),
    /// which is why this is a separate branch and not a change to that rule.
    func testACollapsedGroupStillDoesNotPayForSensors() {
        let needs = AppDelegate.hiddenNeeds(
            configs: [WidgetConfig(metricID: MetricID.groupPlaceholder.rawValue,
                                   style: .group)],
            panelOpen: false)
        XCTAssertFalse(needs.contains(.sensors))
        XCTAssertTrue(needs.contains(.cpu))
    }

    /// A bound sensor widget is the one way the old rule reached the SMC, and it
    /// still does.
    func testABoundSensorWidgetStillAsksForSensorsWhileCollapsed() {
        let needs = AppDelegate.hiddenNeeds(
            configs: [WidgetConfig(metricID: MetricID.cpuTemperature.rawValue,
                                   style: .text)],
            panelOpen: false)
        XCTAssertTrue(needs.contains(.sensors))
    }

    /// THE ROOT CAUSE, as a run-loop fact rather than a claim.
    ///
    /// `Timer.scheduledTimer` schedules in `.default` mode only, and AppKit runs an
    /// open menu in `NSEventTrackingRunLoopMode`. So while the panel was on screen
    /// the tick did not run at all — the state that asks for sensors was the same
    /// state that suspended the sampling which would collect them, and no amount of
    /// fixing `needs` or `cadence` could reach it.
    /// `run(mode:before:)` returns after ONE pass, not at the deadline — alone it
    /// passed in isolation and failed in the full suite, which is a flaky test
    /// rather than a finding. Driven to a deadline instead.
    private func ticks(addingTo modes: [RunLoop.Mode], within: TimeInterval) -> Int {
        var fired = 0
        let t = Timer(timeInterval: 0.01, repeats: true) { _ in fired += 1 }
        for m in modes { RunLoop.current.add(t, forMode: m) }
        defer { t.invalidate() }
        let deadline = Date().addingTimeInterval(within)
        while fired == 0, Date() < deadline {
            RunLoop.current.run(mode: .eventTracking, before: deadline)
        }
        return fired
    }

    func testTheTickSurvivesMenuTracking() {
        // Exactly the modes `restartTimer` adds.
        XCTAssertGreaterThan(ticks(addingTo: [.common, .eventTracking], within: 1.0), 0,
                             "the tick must keep running while a menu is open")
    }

    /// The negative control, so the test above is known to be measuring the mode
    /// and not merely that timers fire.
    func testADefaultModeTickIsDeadDuringMenuTracking() {
        let fired = ticks(addingTo: [.default], within: 0.3)
        XCTAssertEqual(fired, 0, "if this fires, .default now runs during tracking and the "
                     + "comment in restartTimer is wrong")
    }

    /// An open panel is a reader, so it gets the reader's cadence, not the 8 s
    /// hidden one whose own justification is that nobody is looking.
    func testAnOpenPanelIsPacedForAReader() {
        XCTAssertEqual(AppDelegate.cadence(hidden: false, setting: 2, drivingFans: false), 2)
        XCTAssertEqual(AppDelegate.cadence(hidden: true, setting: 2, drivingFans: false),
                       AppDelegate.hiddenInterval)
        XCTAssertGreaterThan(AppDelegate.hiddenInterval, 2)
    }
}

// ── Saying nothing about fans a machine does not have ───────────────────────

/// Hiding the tab was only part of it. "Fan speed  —" in a column of live
/// figures is still a claim that this machine has a fan whose speed is unknown.
final class FanlessSilenceTests: XCTestCase {

    func testFanSpeedIsNotOfferedOnAFanlessMachine() {
        XCTAssertFalse(MetricRegistry.offered(.fanSpeed, fans: .fanless))
    }

    /// Same asymmetry as the tab: `.unknown` KEEPS it, because withdrawing a real
    /// reading from a machine that has fans is the worse of the two errors.
    func testEveryOtherFanStateKeepsIt() {
        XCTAssertTrue(MetricRegistry.offered(.fanSpeed, fans: .unknown))
        XCTAssertTrue(MetricRegistry.offered(.fanSpeed, fans: .fans(1)))
        XCTAssertTrue(MetricRegistry.offered(.fanSpeed, fans: .fans(2)))
    }

    /// Only the fan metric is touched — the filter must not quietly withdraw
    /// anything else.
    func testNoOtherMetricIsWithheldOnAFanlessMachine() {
        for d in MetricRegistry.shared.allDescriptors() where d.id != .fanSpeed {
            XCTAssertTrue(MetricRegistry.offered(d.id, fans: .fanless), "\(d.id.rawValue)")
        }
    }

    /// The panel, the widget picker and the panel editor all build from
    /// `descriptors()`, so dropping it there is what makes them all follow.
    func testTheOrderedPanelDropsItWhenItIsNotOffered() {
        let all = MetricRegistry.shared.allDescriptors().map(\.id)
        let withFans = PanelOrder.visible(saved: [], hidden: [], available: all)
        let withoutFans = PanelOrder.visible(
            saved: [], hidden: [],
            available: all.filter { MetricRegistry.offered($0, fans: .fanless) })
        XCTAssertTrue(withFans.contains(MetricID.fanSpeed.rawValue))
        XCTAssertFalse(withoutFans.contains(MetricID.fanSpeed.rawValue))
        XCTAssertEqual(withFans.count - 1, withoutFans.count)
    }
}

// ── The panel needs a FULL tick, not just the right subsystems ──────────────

/// Second half of the same defect as the sensor rows. `gpu_W`, `attributed_W`,
/// `residual_W` and `coverage` are documented ABSENT on a light tick rather than
/// zero — `LightTickTests` pins that — so the three panel metrics built on them
/// can only ever read "—" unless opening the panel asks for a full sample.
final class OpenPanelNeedsAFullTickTests: XCTestCase {

    private func wants(visible: Bool = false, panelOpen: Bool = false,
                       logging: Bool = false, since: TimeInterval = 0) -> Bool {
        AppDelegate.wantsFullSample(visible: visible, panelOpen: panelOpen,
                                    logging: logging, sinceLastFull: since,
                                    backgroundInterval: 60)
    }

    func testAnOpenPanelForcesAFullSample() {
        XCTAssertTrue(wants(panelOpen: true))
    }

    /// Closed panel, closed window, no logging: still nothing to pay for. The
    /// expensive half is a per-process sweep, and this is the guard that keeps it
    /// off an idle machine.
    func testNobodyLookingStillCostsNothing() {
        XCTAssertFalse(wants())
        XCTAssertFalse(wants(logging: true, since: 10))
    }

    func testTheExistingRulesAreUnchanged() {
        XCTAssertTrue(wants(visible: true))
        XCTAssertTrue(wants(logging: true, since: 120))
    }
}

// ── "AC" is a state, not a missing reading ──────────────────────────────────

/// "—" is what this app shows for a reading it does not have. Time-to-empty on
/// AC is not missing, it is inapplicable, and the machine knows which.
final class TimeRemainingOnACTests: XCTestCase {

    /// NaN, not zero. A sparkline skips non-finite values but would plot a 0 as
    /// "no time remaining" — alarming and false. The neighbouring `batteryRate`
    /// metric uses 0 for "AC" correctly, because 0 %/hr on AC is TRUE.
    func testTheACValueIsNonFiniteSoNoGraphPlotsZeroMinutesLeft() {
        let v = MetricValue(value: .nan, text: "AC", isEstimate: false, label: "Power")
        XCTAssertFalse(v.value.isFinite)
        XCTAssertEqual(v.text, "AC")
        XCTAssertFalse(v.isEstimate, "'AC*' would mark a fact as a projection")
        XCTAssertNil(WidgetRenderer.normalizedFraction(MetricUnit.minutes, v.value),
                     "a non-finite value must not colour the widget by severity")
    }

    /// The panel renders text verbatim and only appends "*" for an estimate, so
    /// this is what the row will read.
    func testThePanelWouldRenderItAsPlainAC() {
        let v = MetricValue(value: .nan, text: "AC", isEstimate: false)
        XCTAssertEqual(v.text + (v.isEstimate ? "*" : ""), "AC")
    }
}

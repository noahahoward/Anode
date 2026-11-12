import XCTest
@testable import AnodeApp
@testable import PowerKit

/// Charge Control's controller: what it feeds the policy, and what it does with the answer.
///
/// Nothing here touches the real Mac. The client is `FakeChargeLimitClient` (or `RecordingChargeClient`, where a test
/// must see a call the fake would refuse without recording), the helper is `FakeHelperLink`, and the battery is a
/// value the test sets. No real PowerUI setter, SMC write or helper socket is reached from this file.
final class ChargeControllerTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var settings: Settings!
    private var client: FakeChargeLimitClient!
    /// What `makeClient` hands over. nil = "this Mac has no client".
    private var clientToMake: ChargeLimitClient?
    private var helper: FakeHelperLink!
    private var battery: Battery.State?
    private var lines: [String] = []
    private var clientsMade = 0
    private var controller: ChargeController?

    override func setUpWithError() throws {
        (defaults, suiteName) = try TestDefaults.make(owner: "ChargeController", test: name)
        settings = Settings(defaults: defaults)
        client = FakeChargeLimitClient(state: NativeChargeState(mclEnabled: false, mclLimit: 100,
                                                                optimizedChargingEnabled: true))
        clientToMake = client
        helper = FakeHelperLink()
        battery = Self.state(70)
        lines = []
        clientsMade = 0
    }

    override func tearDownWithError() throws {
        controller?.shutdown()
        controller = nil
        settings = nil
        TestDefaults.destroy(defaults, suiteName)
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    static func state(_ percent: Int, ac: Bool = true, adapter: Bool? = nil,
                      temperature: Double? = nil) -> Battery.State {
        var s = Battery.State(percent: percent, isCharging: false, onAC: ac, cycleCount: 100,
                              voltage_mV: 12_000, amperage_mA: 0, remainingCapacity_mAh: 4_000,
                              timeRemaining_min: nil)
        s.adapterPresent = adapter ?? ac
        s.temperature_C = temperature
        return s
    }

    @discardableResult
    private func make(enabled: Bool = true) -> ChargeController {
        settings.chargeControlEnabled = enabled
        let c = ChargeController(settings: settings,
                                 makeClient: { [weak self] in
                                     self?.clientsMade += 1
                                     return self?.clientToMake
                                 },
                                 helper: helper,
                                 battery: { [weak self] in self?.battery },
                                 log: { [weak self] in self?.lines.append($0) })
        controller = c
        return c
    }

    private var record: NativeChargeState? {
        settings.chargeRestoreRecord.flatMap { try? JSONDecoder().decode(NativeChargeState.self, from: Data($0.utf8)) }
    }

    private func discharges(_ commands: [FanCommand]) -> [Int] {
        commands.compactMap { if case .discharge(let p) = $0 { return p } else { return nil } }
    }

    // ── Off ─────────────────────────────────────────────────────────────────

    func testOffCreatesNoClient() {
        let c = make(enabled: false)
        c.tick()
        c.pressDischarge()
        c.pressTopUp()
        c.willSleep()
        c.didWake()
        XCTAssertEqual(clientsMade, 0, "a client was created while Charge Control was off")
        XCTAssertEqual(c.status, .off)
        XCTAssertNil(c.lastDecision)
        XCTAssertTrue(helper.commands.isEmpty, "a helper command was sent while off")
        XCTAssertEqual(helper.follows, 0, "the helper link was held while off")
        XCTAssertNil(settings.chargeRestoreRecord)
    }

    /// Off means no observers: a charge setting changed while off does nothing.
    func testChargeKeysAreIgnoredWhileOff() {
        make()
        settings.chargeControlEnabled = false
        let calls = client.limitCalls
        settings.chargeLimit = 90
        settings.chargeSailingEnabled = true
        XCTAssertEqual(client.limitCalls, calls)
        XCTAssertEqual(clientsMade, 1)
    }

    func testFollowsTheHelperOnlyWhileOn() {
        make(enabled: false)
        XCTAssertEqual(helper.follows, 0)
        settings.chargeControlEnabled = true
        XCTAssertTrue(helper.following, "Charge Control on does not follow the helper")
        settings.chargeControlEnabled = false
        XCTAssertFalse(helper.following, "Charge Control off still follows the helper")
        XCTAssertFalse(helper.isOpen)
    }

    // ── Enable ──────────────────────────────────────────────────────────────

    func testEnableRecordsStateAndTurnsOffOptimizedCharging() {
        make()
        XCTAssertEqual(record, NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: true))
        XCTAssertEqual(client.optimizedChargingCalls, [false])
        XCTAssertEqual(client.limitEnabledCalls, [true])
        XCTAssertEqual(client.state?.optimizedChargingEnabled, false)
        XCTAssertEqual(client.state?.mclEnabled, true)
        XCTAssertEqual(client.limitCalls, [80], "turning on did not apply the default limit")
    }

    /// The way back is written down, as JSON, before anything in macOS changes.
    func testRecordIsWrittenBeforeAnythingChanges() {
        let spy = RecordingChargeClient(state: NativeChargeState(mclEnabled: true, mclLimit: 95,
                                                                 optimizedChargingEnabled: true))
        spy.settings = settings
        clientToMake = spy
        make()
        XCTAssertFalse(spy.recordAtEachCall.isEmpty)
        XCTAssertTrue(spy.recordAtEachCall.allSatisfy { $0 != nil },
                      "macOS was changed before the restore record was stored")
        let json = try? JSONSerialization.jsonObject(with: Data((settings.chargeRestoreRecord ?? "").utf8)) as? [String: Any]
        XCTAssertEqual(json?["mclLimit"] as? Int, 95)
        XCTAssertEqual(json?["mclEnabled"] as? Bool, true)
        XCTAssertEqual(json?["optimizedChargingEnabled"] as? Bool, true)
    }

    /// A record from an earlier run is the state before Charge Control ever ran; a later enable must not replace it
    /// with a state Charge Control itself made.
    func testReEnableKeepsTheFirstRecord() {
        client.state = NativeChargeState(mclEnabled: true, mclLimit: 90, optimizedChargingEnabled: true)
        make()
        controller?.shutdown()
        controller = nil
        make()
        XCTAssertEqual(record, NativeChargeState(mclEnabled: true, mclLimit: 90, optimizedChargingEnabled: true))
    }

    /// A record that cannot be read may still be the only trace of the state before Charge Control ran, and the
    /// state found now may be one Charge Control made: it is never written over. Switching off puts back macOS's
    /// defaults instead (no limit, Optimized Battery Charging on), says so, and then clears it.
    func testUndecodableRecordIsKeptAndSwitchingOffPutsBackTheDefaults() {
        settings.chargeRestoreRecord = "{not a record"
        client.state = NativeChargeState(mclEnabled: true, mclLimit: 85, optimizedChargingEnabled: false)
        let c = make()
        XCTAssertEqual(settings.chargeRestoreRecord, "{not a record", "the unreadable record was written over")
        settings.chargeControlEnabled = false
        XCTAssertEqual(client.state, NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: true))
        XCTAssertNil(settings.chargeRestoreRecord)
        XCTAssertEqual(c.status, .off)
        XCTAssertTrue(lines.contains { $0.contains("could not be read") && $0.contains("defaults") },
                      lines.joined(separator: "\n"))
    }

    /// The same while off, before an uninstall.
    func testUninstallPutsBackTheDefaultsForAnUndecodableRecord() {
        settings.chargeRestoreRecord = "[1,2,3]"
        client.state = NativeChargeState(mclEnabled: true, mclLimit: 80, optimizedChargingEnabled: false)
        let c = make(enabled: false)
        c.restoreForUninstall()
        XCTAssertEqual(client.state, NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: true))
        XCTAssertNil(settings.chargeRestoreRecord)
    }

    func testUnavailableClientShowsReason() {
        clientToMake = nil
        let c = make()
        XCTAssertEqual(c.status, .unavailable("Needs macOS 26.4 or later on Apple silicon"))
        XCTAssertNil(settings.chargeRestoreRecord)
        XCTAssertEqual(helper.follows, 0)
        XCTAssertTrue(helper.commands.isEmpty)
    }

    /// A client that cannot read macOS's settings gives nothing to restore later, so nothing is changed.
    func testUnreadableStateChangesNothing() {
        client.state = nil
        let c = make()
        guard case .unavailable = c.status else { return XCTFail("status \(c.status)") }
        XCTAssertTrue(client.limitCalls.isEmpty)
        XCTAssertTrue(client.limitEnabledCalls.isEmpty)
        XCTAssertTrue(client.optimizedChargingCalls.isEmpty)
        XCTAssertNil(settings.chargeRestoreRecord)
    }

    // ── Disable ─────────────────────────────────────────────────────────────

    func testDisableRestoresTheStateFoundAtFirstEnable() {
        let found = NativeChargeState(mclEnabled: true, mclLimit: 90, optimizedChargingEnabled: true)
        client.state = found
        let c = make()
        XCTAssertEqual(client.state?.mclLimit, 80)
        XCTAssertEqual(client.state?.optimizedChargingEnabled, false)

        settings.chargeControlEnabled = false
        XCTAssertEqual(client.state, found)
        XCTAssertNil(settings.chargeRestoreRecord, "the record outlived the restore")
        XCTAssertEqual(c.status, .off)
    }

    /// Nothing Charge Control set lingers once the switch is off: the limit, the limit's switch and Optimized
    /// Battery Charging all go back in the same call, and a running discharge is stopped.
    func testDisableStopsADischargeAndRestoresAtOnce() {
        battery = Self.state(90)
        let c = make()
        c.pressDischarge()
        XCTAssertEqual(discharges(helper.commands), [80])

        settings.chargeControlEnabled = false
        XCTAssertEqual(helper.commands.last, .stopDischarge)
        XCTAssertEqual(client.state, NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: true))
        XCTAssertFalse(helper.following)
        let after = helper.commands.count
        c.tick()
        XCTAssertEqual(helper.commands.count, after, "the controller kept working after it was switched off")
    }

    /// Limit 63 → 62 puts `.setChargeLimit(62)` on the link; Charge Control is switched off before it has been
    /// answered. The restore must land after it, or macOS would be left at 62 with the record cleared.
    func testSwitchingOffLandsAfterAHelperLimitStillOnItsWay() {
        settings.chargeLimit = 63
        helper.landsOn = client
        make()
        XCTAssertEqual(client.state?.mclLimit, 63)
        helper.deferReplies = true
        settings.chargeLimit = 62
        settings.chargeControlEnabled = false
        helper.flushReplies()   // anything still on its way lands now, if it had not already
        XCTAssertEqual(client.state, NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: true),
                       "a limit still on its way to the helper landed after the restore")
        XCTAssertNil(settings.chargeRestoreRecord)
    }

    /// The same before an uninstall.
    func testUninstallLandsAfterAHelperLimitStillOnItsWay() {
        settings.chargeLimit = 63
        helper.landsOn = client
        let c = make()
        helper.deferReplies = true
        settings.chargeLimit = 62
        c.restoreForUninstall()
        helper.flushReplies()
        XCTAssertEqual(client.state, NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: true))
    }

    /// When the link cannot be waited for (2 s at most), the restore is not known to have landed last: the record
    /// is kept, and that is logged, so the next switch-off tries again from the true original.
    func testARestoreThatCouldNotWaitForTheHelperKeepsTheRecord() {
        settings.chargeLimit = 63
        make()
        helper.deferReplies = true
        settings.chargeLimit = 62
        helper.drainTimesOut = true
        settings.chargeControlEnabled = false
        XCTAssertNotNil(settings.chargeRestoreRecord, "the record was cleared though the restore may be overtaken")
        XCTAssertTrue(lines.contains { $0.contains("record is kept") }, lines.joined(separator: "\n"))
    }

    /// A limit only the helper can put back is waited for, and a refusal keeps the record.
    func testAHelperRestoreIsWaitedForAndARefusalKeepsTheRecord() {
        settings.chargeRestoreRecord = ChargeController.encodeRecord(
            NativeChargeState(mclEnabled: true, mclLimit: 63, optimizedChargingEnabled: true))
        make()
        helper.answer = { cmd in
            if case .setChargeLimit(63) = cmd { return FanReply(ok: false, message: "macOS did not take the charge limit") }
            return FanReply(ok: true, message: "ok")
        }
        settings.chargeControlEnabled = false
        XCTAssertEqual(helper.waited, [.setChargeLimit(63)], "the helper's part of the restore was not waited for")
        XCTAssertNotNil(settings.chargeRestoreRecord, "a refused restore cleared the record")
        XCTAssertTrue(lines.contains { $0.contains("record is kept") }, lines.joined(separator: "\n"))
    }

    func testAHelperRestoreThatSucceedsClearsTheRecord() {
        settings.chargeRestoreRecord = ChargeController.encodeRecord(
            NativeChargeState(mclEnabled: true, mclLimit: 63, optimizedChargingEnabled: true))
        make()
        settings.chargeControlEnabled = false
        XCTAssertEqual(helper.waited, [.setChargeLimit(63)])
        XCTAssertNil(settings.chargeRestoreRecord)
        XCTAssertEqual(client.state?.optimizedChargingEnabled, true)
    }

    func testRestoreForUninstallRestoresAndTurnsOff() {
        battery = Self.state(90)
        let c = make()
        c.pressDischarge()
        c.restoreForUninstall()
        XCTAssertEqual(helper.waited, [.stopDischarge], "the discharge was not stopped before returning")
        XCTAssertEqual(client.state, NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: true))
        XCTAssertFalse(settings.chargeControlEnabled)
        XCTAssertNil(settings.chargeRestoreRecord)
        XCTAssertEqual(c.status, .off)
    }

    /// A record left over while off (a switch-off macOS partly refused, or the setting turned off while Anode was
    /// closed) is put back before an uninstall: once Anode is gone nothing could undo the hold.
    func testUninstallPutsBackALeftoverRecordEvenWhileOff() {
        let found = NativeChargeState(mclEnabled: true, mclLimit: 90, optimizedChargingEnabled: true)
        settings.chargeRestoreRecord = ChargeController.encodeRecord(found)
        client.state = NativeChargeState(mclEnabled: true, mclLimit: 80, optimizedChargingEnabled: false)
        let c = make(enabled: false)
        XCTAssertEqual(clientsMade, 0)
        c.restoreForUninstall()
        XCTAssertEqual(client.state, found)
        XCTAssertNil(settings.chargeRestoreRecord)
        XCTAssertEqual(c.status, .off)
        c.tick()
        XCTAssertEqual(client.limitCalls, [90], "the client outlived the restore")
    }

    /// A controller that goes away without a shutdown still lets go of its claim on the shared connection; otherwise
    /// the socket could never close again, and the helper's dead man's switch would never run.
    func testDeinitLetsGoOfTheHelper() {
        var c: ChargeController? = ChargeController(settings: settings, makeClient: { [weak self] in self?.clientToMake },
                                                    helper: helper, battery: { [weak self] in self?.battery },
                                                    log: { _ in })
        settings.chargeControlEnabled = true
        XCTAssertTrue(helper.following)
        XCTAssertNotNil(c)
        c = nil
        XCTAssertFalse(helper.following, "the controller went away still holding its claim on the helper link")
    }

    /// Quitting leaves macOS's limit in force (it outlives the app by design) and lets the helper link go.
    func testShutdownLeavesTheLimitAndLetsGo() {
        let c = make()
        c.shutdown()
        XCTAssertFalse(helper.following)
        XCTAssertEqual(client.state?.mclLimit, 80)
        XCTAssertNotNil(settings.chargeRestoreRecord)
        XCTAssertTrue(settings.chargeControlEnabled)
    }

    // ── Which route a limit takes ───────────────────────────────────────────

    func testClientValueUsesClientNotHelper() {
        settings.chargeLimit = 85
        make()
        XCTAssertEqual(client.limitCalls, [85])
        XCTAssertFalse(helper.commands.contains(.setChargeLimit(85)))
        XCTAssertTrue(helper.commands.isEmpty)
    }

    func testOtherValueUsesHelper() {
        settings.chargeLimit = 63
        let c = make()
        XCTAssertEqual(helper.commands, [.setChargeLimit(63)])
        XCTAssertTrue(client.limitCalls.isEmpty)
        XCTAssertEqual(c.status, .active(ChargeDecision(osLimit: 63, dischargeTo: nil, reason: .limit)))
    }

    func testLimitOutsideClientSetWithoutHelperIsReportedNotApplied() {
        let spy = RecordingChargeClient(state: NativeChargeState(mclEnabled: false, mclLimit: 100,
                                                                 optimizedChargingEnabled: true))
        clientToMake = spy
        helper.available = false
        settings.chargeLimit = 63
        let c = make()
        XCTAssertEqual(c.status, .needsHelper("Limits other than 80, 85, 90, 95 or 100% need the Anode helper"))
        XCTAssertEqual(spy.limitCalls, [80], "the nearest client value at or above 63 is 80")
        XCTAssertFalse(spy.limitCalls.contains(63))
        XCTAssertTrue(helper.commands.isEmpty)
    }

    /// Every limit and every hold, with no helper: the client is never asked for a value outside its set, and never
    /// for less than was wanted.
    func testNeverAsksTheClientForAValueOutsideItsSet() {
        let spy = RecordingChargeClient(state: NativeChargeState(mclEnabled: false, mclLimit: 100,
                                                                 optimizedChargingEnabled: true))
        clientToMake = spy
        helper.available = false
        settings.chargeSailingEnabled = true
        settings.chargeStopWhenSleeping = true
        let c = make()
        for limit in stride(from: 20, through: 100, by: 7) {
            settings.chargeLimit = limit
            for percent in [15, limit - 3, limit, limit + 4, 99] {
                battery = Self.state(max(1, min(100, percent)))
                c.tick()
                c.willSleep()
                c.didWake()
            }
        }
        XCTAssertFalse(spy.limitCalls.isEmpty)
        let outside = spy.limitCalls.filter { !NativeChargeLimit.isClientSettable($0) }
        XCTAssertEqual(outside, [], "the client was asked for values it refuses")
    }

    func testHelperBecomingAvailableAppliesTheRealLimit() {
        helper.available = false
        settings.chargeLimit = 63
        let c = make()
        XCTAssertEqual(client.limitCalls, [80])
        helper.becomeAvailable()
        XCTAssertEqual(helper.commands, [.setChargeLimit(63)])
        XCTAssertEqual(c.status, .active(ChargeDecision(osLimit: 63, dischargeTo: nil, reason: .limit)))
    }

    /// At launch the helper's hello is a moment away. A limit only it can set is not replaced by the client's
    /// nearest value in that moment, or the limit would go up and come back down at every launch.
    func testANonClientLimitWaitsForTheHelpersFirstAnswer() {
        helper.available = false
        helper.answersAtOnce = false
        settings.chargeLimit = 63
        make()
        XCTAssertTrue(client.limitCalls.isEmpty, "the fallback was set before the helper had answered")
        helper.firstAnswer()
        XCTAssertEqual(client.limitCalls, [80])
    }

    /// A limit the helper refuses is not sent again on every tick (each would wake the daemon): the nearest value
    /// macOS takes above it holds, the reason is shown, and a new limit is asked for at once.
    func testALimitTheHelperRefusesIsNotAskedForEveryTick() {
        settings.chargeLimit = 63
        helper.answer = { cmd in
            if case .setChargeLimit = cmd { return FanReply(ok: false, message: "macOS did not take the charge limit") }
            return FanReply(ok: true, message: "ok")
        }
        let c = make()
        XCTAssertEqual(helper.commands, [.setChargeLimit(63)])
        XCTAssertEqual(client.limitCalls, [80], "the nearest value above did not hold meanwhile")
        XCTAssertEqual(c.status, .refused(ChargeController.limitRefusedText(63, "macOS did not take the charge limit")))
        for _ in 0..<3 { c.periodicTick() }
        XCTAssertEqual(helper.commands, [.setChargeLimit(63)], "a refused limit was asked for again on the timer")
        settings.chargeLimit = 64
        XCTAssertEqual(helper.commands, [.setChargeLimit(63), .setChargeLimit(64)])
    }

    /// At launch, until the helper has answered, nothing is said about it: the status does not flash "needs the
    /// helper" for the moment before its hello.
    func testNoNeedsHelperBeforeTheHelperHasAnswered() {
        helper.available = false
        helper.answersAtOnce = false
        settings.chargeLimit = 63
        let c = make()
        XCTAssertNotEqual(c.status, .needsHelper(ChargeController.limitNeedsHelperText),
                          "the status said the helper was needed before it had answered")
        c.tick()
        XCTAssertNotEqual(c.status, .needsHelper(ChargeController.limitNeedsHelperText))
        helper.firstAnswer()
        XCTAssertEqual(c.status, .needsHelper(ChargeController.limitNeedsHelperText))
    }

    func testOutdatedHelperAsksForAnUpdate() {
        helper.available = false
        helper.outdated = true
        settings.chargeLimit = 63
        let c = make()
        XCTAssertEqual(c.status, .needsHelper("The Anode helper needs updating to control charging"))
        XCTAssertTrue(helper.commands.isEmpty)
    }

    func testDischargeWithoutHelperNeedsTheHelper() {
        helper.available = false
        battery = Self.state(90)
        let c = make()
        c.pressDischarge()
        XCTAssertEqual(c.status, .needsHelper("Discharge needs the Anode helper"))
        XCTAssertTrue(helper.commands.isEmpty)
    }

    // ── Only on change ──────────────────────────────────────────────────────

    func testNoResendWhenDecisionUnchanged() {
        battery = Self.state(90)
        let c = make()
        c.tick()
        c.tick()
        XCTAssertEqual(client.limitCalls, [80])
        c.pressDischarge()
        c.tick()
        c.tick()
        XCTAssertEqual(discharges(helper.commands), [80])
        XCTAssertEqual(helper.commands.count, 1)
    }

    /// A tick that lands while a discharge is still on its way does not send a second one, which the helper would
    /// refuse.
    func testNoSecondDischargeWhileOneIsInFlight() {
        battery = Self.state(90)
        helper.deferReplies = true
        let c = make()
        c.pressDischarge()
        c.tick()
        c.tick()
        XCTAssertEqual(discharges(helper.commands), [80])
        helper.flushReplies()
        c.tick()
        XCTAssertEqual(discharges(helper.commands), [80])
    }

    // ── Discharge ───────────────────────────────────────────────────────────

    func testDischargeSendsHelperCommandAndStopsOnUnplug() {
        battery = Self.state(90)
        let c = make()
        c.pressDischarge()
        XCTAssertEqual(helper.commands, [.discharge(toPercent: 80)])
        XCTAssertEqual(c.status, .active(ChargeDecision(osLimit: 80, dischargeTo: 80, reason: .discharging)))
        XCTAssertTrue(c.isDischargeRequested)

        battery = Self.state(89, ac: false, adapter: false)
        c.tick()
        XCTAssertEqual(helper.commands, [.discharge(toPercent: 80), .stopDischarge])
        XCTAssertFalse(c.isDischargeRequested, "unplugging did not end the manual discharge")
    }

    /// While Anode's own cut is on, macOS says the Mac is off the adapter; the adapter's own details say it is still
    /// there. That is not an unplug, and must not end the discharge.
    func testAdapterPresentCountsAsOnACDuringOurOwnCut() {
        battery = Self.state(90)
        let c = make()
        c.pressDischarge()
        battery = Self.state(88, ac: false, adapter: true)
        c.tick()
        XCTAssertEqual(helper.commands, [.discharge(toPercent: 80)])
        XCTAssertTrue(c.isDischargeRequested)
        XCTAssertEqual(c.lastDecision?.reason, .discharging)
    }

    /// The helper refuses a second discharge while one runs, so a new target is a stop and then a start.
    func testChangingTheTargetStopsFirst() {
        settings.chargeLimit = 85
        settings.chargeAutomaticDischarge = true
        battery = Self.state(95)
        make()
        XCTAssertEqual(helper.commands, [.discharge(toPercent: 85)])
        settings.chargeLimit = 80
        XCTAssertEqual(helper.commands, [.discharge(toPercent: 85), .stopDischarge, .discharge(toPercent: 80)])
    }

    func testSleepRefusalIsRetriedOnTheNextTick() {
        battery = Self.state(90)
        helper.answer = { c in
            if case .discharge = c { return FanReply(ok: false, message: "the Mac is going to sleep") }
            return FanReply(ok: true, message: "ok")
        }
        let c = make()
        c.pressDischarge()
        XCTAssertEqual(discharges(helper.commands), [80])
        XCTAssertEqual(c.status, .active(ChargeDecision(osLimit: 80, dischargeTo: 80, reason: .discharging)),
                       "a refusal because the Mac is going to sleep is not an error")

        helper.answer = { _ in FanReply(ok: true, message: "ok") }
        c.tick()
        XCTAssertEqual(discharges(helper.commands), [80, 80], "the discharge was not asked for again")
        c.tick()
        XCTAssertEqual(discharges(helper.commands), [80, 80])
    }

    /// The real link never answers "nothing": a socket that is gone comes back as a refusal saying the helper stopped
    /// answering. For a stop that is as good as done (the helper reconnects the charger when its client goes), so
    /// it is not asked again and again.
    func testAStopThatFindsTheHelperGoneIsNotRepeated() {
        battery = Self.state(90)
        let c = make()
        c.pressDischarge()
        helper.answer = { cmd in
            if case .stopDischarge = cmd { return FanReply(ok: false, message: "the fan helper stopped answering") }
            return FanReply(ok: true, message: "ok")
        }
        battery = Self.state(89, ac: false, adapter: false)
        c.tick()
        c.tick()
        c.tick()
        XCTAssertEqual(helper.commands, [.discharge(toPercent: 80), .stopDischarge],
                       "a stop answered by a helper that is gone was sent again")
    }

    /// Two refusals from the helper do not pass by themselves: the charger may still be cut off from an earlier
    /// failure, or the Mac cannot warn the helper before it sleeps. The reason is shown, and the discharge is not
    /// asked for again until the person presses again.
    func testADischargeRefusalThatWillNotPassIsShownAndNotRetried() {
        let why = "the charger may still be cut off from an earlier failure"
        battery = Self.state(90)
        helper.answer = { cmd in
            if case .discharge = cmd { return FanReply(ok: false, message: why) }
            return FanReply(ok: true, message: "ok")
        }
        let c = make()
        c.pressDischarge()
        XCTAssertEqual(discharges(helper.commands), [80])
        XCTAssertTrue(ChargeControlFeature.statusText(c.status).contains(why), "status: \(c.status)")
        c.tick()
        c.periodicTick()
        c.tick()
        XCTAssertEqual(discharges(helper.commands), [80], "a refusal that will not pass was asked again")
        XCTAssertTrue(ChargeControlFeature.statusText(c.status).contains(why), "status: \(c.status)")

        c.pressDischarge()   // cancel
        c.pressDischarge()   // and ask again
        XCTAssertEqual(discharges(helper.commands), [80, 80], "pressing again did not ask again")
    }

    /// An automatic discharge refused that way is asked again when the decision changes, not before.
    func testAnAutomaticDischargeRefusedThatWayWaitsForTheDecisionToChange() {
        let why = "this Mac cannot warn the helper before it sleeps"
        settings.chargeAutomaticDischarge = true
        battery = Self.state(95)
        helper.answer = { cmd in
            if case .discharge = cmd { return FanReply(ok: false, message: why) }
            return FanReply(ok: true, message: "ok")
        }
        let c = make()
        c.periodicTick()
        c.periodicTick()
        XCTAssertEqual(discharges(helper.commands), [80])
        XCTAssertTrue(ChargeControlFeature.statusText(c.status).contains(why), "status: \(c.status)")
        settings.chargeLimit = 85
        XCTAssertEqual(discharges(helper.commands), [80, 85])
    }

    /// The Fans tab's "return to automatic" also reconnects the charger, and so does a reopened socket. A discharge
    /// that is still wanted is asked for again.
    func testHelperResetStartsTheDischargeAgain() {
        battery = Self.state(90)
        let c = make()
        c.pressDischarge()
        helper.reset()
        XCTAssertEqual(discharges(helper.commands), [80, 80])
        XCTAssertTrue(c.isDischargeRequested)
    }

    func testTopUpAndDischargeAreExclusiveToggles() {
        battery = Self.state(90)
        let c = make()
        c.pressDischarge()
        XCTAssertTrue(c.isDischargeRequested)
        c.pressTopUp()
        XCTAssertTrue(c.isTopUpRequested)
        XCTAssertFalse(c.isDischargeRequested, "Top Up did not cancel the discharge")
        XCTAssertEqual(c.lastDecision?.reason, .topUp)
        XCTAssertEqual(helper.commands.last, .stopDischarge)
        c.pressTopUp()
        XCTAssertFalse(c.isTopUpRequested, "a second press did not cancel Top Up")
        XCTAssertEqual(c.lastDecision?.reason, .limit)
        c.pressDischarge()
        c.pressDischarge()
        XCTAssertFalse(c.isDischargeRequested, "a second press did not cancel the discharge")
    }

    // ── Policy inputs ───────────────────────────────────────────────────────

    /// The policy keeps its sailing and heat memory between calls; an unplug starts it again.
    func testMemoryResetsOnUnplug() {
        settings.chargeSailingEnabled = true
        battery = Self.state(80)
        let c = make()
        XCTAssertEqual(c.lastDecision?.reason, .sailing)
        battery = Self.state(78)
        c.tick()
        XCTAssertEqual(c.lastDecision?.reason, .sailing)

        battery = Self.state(78, ac: false, adapter: false)
        c.tick()
        battery = Self.state(78)
        c.tick()
        XCTAssertEqual(c.lastDecision?.reason, .limit, "sailing memory survived an unplug")
    }

    /// A temperature that is not a number is no reading at all: it neither starts a pause nor counts as cool.
    func testNonFiniteTemperatureIsNoReading() {
        settings.chargeHeatProtectionEnabled = true
        let t0 = Date()
        battery = Self.state(60, temperature: 40)
        let c = make()
        c.tick(now: t0)
        XCTAssertEqual(c.lastDecision?.reason, .heat)
        battery = Self.state(60, temperature: .nan)
        c.tick(now: t0.addingTimeInterval(10))
        c.tick(now: t0.addingTimeInterval(400))
        XCTAssertEqual(c.lastDecision?.reason, .heat, "NaN was read as a cool pack")
        battery = Self.state(60, temperature: .infinity)
        c.tick(now: t0.addingTimeInterval(800))
        XCTAssertEqual(c.lastDecision?.reason, .heat)
    }

    // ── Sleep ───────────────────────────────────────────────────────────────

    func testWakeReappliesDecision() {
        settings.chargeStopWhenSleeping = true
        battery = Self.state(63)
        let c = make()
        XCTAssertEqual(client.limitCalls, [80])
        c.willSleep()
        XCTAssertEqual(c.lastDecision?.reason, .sleeping)
        XCTAssertEqual(helper.commands, [.setChargeLimit(63)], "the charge was not held where it was")
        c.didWake()
        XCTAssertEqual(c.lastDecision?.reason, .limit)
        XCTAssertEqual(client.limitCalls, [80, 80])
    }

    /// Whatever Stop Charging when Sleeping says, a running discharge is stopped and the answer awaited before
    /// `willSleep` returns: nothing watches the floor while the Mac sleeps. A manual discharge does not come back.
    func testSleepStopsADischargeBeforeReturning() {
        battery = Self.state(90)
        let c = make()
        c.pressDischarge()
        c.willSleep()
        XCTAssertEqual(helper.waited, [.stopDischarge])
        XCTAssertFalse(c.isDischargeRequested)
        c.didWake()
        XCTAssertEqual(discharges(helper.commands), [80], "a manual discharge came back after the wake")
    }

    func testAutomaticDischargeResumesAfterWake() {
        settings.chargeAutomaticDischarge = true
        battery = Self.state(90)
        let c = make()
        XCTAssertEqual(discharges(helper.commands), [80])
        c.willSleep()
        XCTAssertEqual(helper.waited, [.stopDischarge])
        XCTAssertEqual(discharges(helper.commands), [80], "a discharge was asked for while going to sleep")
        c.didWake()
        XCTAssertEqual(discharges(helper.commands), [80, 80])
    }

    // ── macOS changed behind Charge Control ─────────────────────────────────

    /// The person turns the limit off in System Settings. The next timer tick reads macOS back, says so in one line,
    /// and puts all three settings back.
    func testTheTimerPutsBackALimitTurnedOffElsewhere() {
        let c = make()
        XCTAssertEqual(client.limitCalls, [80])
        client.state?.mclEnabled = false
        c.periodicTick()
        XCTAssertEqual(client.state?.mclEnabled, true, "the limit turned off elsewhere was left off")
        XCTAssertEqual(client.limitCalls, [80, 80], "the limit was not asserted again")
        XCTAssertEqual(client.optimizedChargingCalls, [false, false])
        XCTAssertEqual(lines.filter { $0.contains("changed outside Charge Control") }.count, 1,
                       lines.joined(separator: "\n"))
        c.periodicTick()
        XCTAssertEqual(client.limitCalls, [80, 80], "a tick with nothing changed asserted the limit again")
        XCTAssertEqual(client.optimizedChargingCalls, [false, false])
    }

    /// 100 set in System Settings, while the status still says 80.
    func testTheTimerPutsBackALimitChangedElsewhere() {
        let c = make()
        client.state?.mclLimit = 100
        c.periodicTick()
        XCTAssertEqual(client.state?.mclLimit, 80)
        XCTAssertEqual(c.status, .active(ChargeDecision(osLimit: 80, dischargeTo: nil, reason: .limit)))
    }

    /// Optimized Battery Charging turned back on: two controllers would fight over the charger.
    func testTheTimerTurnsOptimizedChargingOffAgain() {
        let c = make()
        client.state?.optimizedChargingEnabled = true
        c.periodicTick()
        XCTAssertEqual(client.state?.optimizedChargingEnabled, false)
        XCTAssertTrue(lines.contains { $0.contains("changed outside Charge Control") }, lines.joined(separator: "\n"))
    }

    /// A limit only the helper can set is read back the same way, and put back through the helper.
    func testAHelperLimitChangedElsewhereGoesBackThroughTheHelper() {
        settings.chargeLimit = 63
        let c = make()
        XCTAssertEqual(helper.commands, [.setChargeLimit(63)])
        client.state = NativeChargeState(mclEnabled: true, mclLimit: 63, optimizedChargingEnabled: false)
        c.periodicTick()
        XCTAssertEqual(helper.commands, [.setChargeLimit(63)], "a limit read back as set was set again")
        client.state?.mclLimit = 90
        c.periodicTick()
        XCTAssertEqual(helper.commands, [.setChargeLimit(63), .setChargeLimit(63)])
    }

    /// The timer checks on the helper only while a discharge lives on the connection; otherwise the daemon is left
    /// asleep.
    func testTheTimerChecksOnTheHelperOnlyUnderADischarge() {
        battery = Self.state(90)
        let c = make()
        for _ in 0..<3 { c.periodicTick() }
        XCTAssertEqual(helper.refreshes, 0, "the timer talked to the helper with no discharge running")
        c.pressDischarge()
        c.periodicTick()
        XCTAssertEqual(helper.refreshes, 1)
    }

    /// A macOS that keeps refusing is asked once per tick, not in a loop, and the drift is logged once.
    func testARefusingMacIsAskedOncePerTick() {
        let c = make()
        client.state?.optimizedChargingEnabled = true
        client.succeeds = false
        c.periodicTick()
        c.periodicTick()
        c.periodicTick()
        XCTAssertEqual(client.optimizedChargingCalls, [false, false, false, false])
        XCTAssertEqual(lines.filter { $0.contains("changed outside Charge Control") }.count, 1,
                       lines.joined(separator: "\n"))
    }

    /// The same check after a wake: the person may have changed it while the Mac slept.
    func testWakeReadsMacOSBack() {
        let c = make()
        c.willSleep()
        client.state?.optimizedChargingEnabled = true
        client.state?.mclEnabled = false
        c.didWake()
        XCTAssertEqual(client.state?.optimizedChargingEnabled, false)
        XCTAssertEqual(client.state?.mclEnabled, true)
        XCTAssertTrue(lines.contains { $0.contains("changed outside Charge Control") }, lines.joined(separator: "\n"))
    }

    // ── Restore record ──────────────────────────────────────────────────────

    func testRecordRoundTripsAsJSON() {
        let s = NativeChargeState(mclEnabled: true, mclLimit: 85, optimizedChargingEnabled: false)
        XCTAssertEqual(ChargeController.decodeRecord(ChargeController.encodeRecord(s)), s)
        XCTAssertNil(ChargeController.decodeRecord("[1,2,3]"))
        XCTAssertNil(ChargeController.decodeRecord(nil))
    }

    func testNearestClientValueAtOrAbove() {
        XCTAssertEqual(ChargeController.nearestClientValue(atOrAbove: 20), 80)
        XCTAssertEqual(ChargeController.nearestClientValue(atOrAbove: 80), 80)
        XCTAssertEqual(ChargeController.nearestClientValue(atOrAbove: 81), 85)
        XCTAssertEqual(ChargeController.nearestClientValue(atOrAbove: 96), 100)
        XCTAssertEqual(ChargeController.nearestClientValue(atOrAbove: 100), 100)
    }

    // ── Logging ─────────────────────────────────────────────────────────────

    func testAppliedChangesAreLoggedInOneLine() {
        battery = Self.state(90)
        let c = make()
        c.pressDischarge()
        XCTAssertTrue(lines.contains("discharge to 80 started"), lines.joined(separator: "\n"))
        settings.chargeLimit = 85
        XCTAssertTrue(lines.contains("limit 80 -> 85 (discharging)"), lines.joined(separator: "\n"))
        settings.chargeLimit = 63
        XCTAssertTrue(lines.contains("limit 85 -> 63 (discharging)"), lines.joined(separator: "\n"))
    }
}

// ── Fakes ───────────────────────────────────────────────────────────────────

/// The helper as Charge Control sees it, scripted. Replies come back at once unless `deferReplies` is set. Like the
/// real link it never answers "nothing": a helper that is gone answers ok:false, "the fan helper stopped answering".
final class FakeHelperLink: ChargeHelperLink {
    var available = true
    var outdated = false
    /// Set when `follow` answers (`answersAtOnce`), or by `firstAnswer`.
    private(set) var known = false
    private(set) var isOpen = false
    /// Whether `keepOpen(true)` opens the connection at once, as one the Fans tab already holds is. When false it
    /// opens on `finishOpening`, as a new connection does when its hello comes back.
    var opensAtOnce = true
    private(set) var resets = 0
    private(set) var commands: [FanCommand] = []
    /// The commands sent through `sendWaiting`, in order.
    private(set) var waited: [FanCommand] = []
    private(set) var follows = 0
    private(set) var letGos = 0
    private(set) var refreshes = 0
    private(set) var rechecks = 0
    /// Every `keepOpen`, in order.
    private(set) var openRequests: [Bool] = []
    var following: Bool { follows > letGos }
    var answer: (FanCommand) -> FanReply = { _ in FanReply(ok: true, message: "ok") }
    /// Hold every exchange back until `flushReplies` (or a drain): a command still on its way.
    var deferReplies = false
    /// Where a `.setChargeLimit` the helper accepts lands: the same macOS limit the client reads.
    var landsOn: FakeChargeLimitClient?
    /// `drain` gives up, as the real one does after its timeout.
    var drainTimesOut = false
    private(set) var drains = 0
    /// Sent and not yet answered on the main thread, in order. The link's queue is serial: an exchange runs (and a
    /// limit lands) in this order, whether its answer has reached the main thread or not.
    private var queue: [Exchange] = []
    private var changed: (() -> Void)?

    private final class Exchange {
        let command: FanCommand
        let done: (FanReply) -> Void
        var reply: FanReply?
        init(_ command: FanCommand, _ done: @escaping (FanReply) -> Void) { self.command = command; self.done = done }
    }

    @discardableResult
    private func run(_ e: Exchange) -> FanReply {
        if let r = e.reply { return r }
        let r = answer(e.command)
        e.reply = r
        land(e.command, r)
        return r
    }

    private func land(_ c: FanCommand, _ reply: FanReply) {
        guard reply.ok, case .setChargeLimit(let p) = c else { return }
        landsOn?.state?.mclLimit = p
    }

    /// Whether `follow` answers at once, as a link that has greeted the helper (or found it missing) does.
    var answersAtOnce = true

    func follow(_ changed: @escaping () -> Void) {
        follows += 1
        self.changed = changed
        if answersAtOnce {
            known = true
            changed()
        }
    }

    /// The link's first answer, for a test that held it back.
    func firstAnswer() {
        known = true
        changed?()
    }

    func letGo() {
        letGos += 1
        changed = nil
        isOpen = false
        known = false
    }

    func keepOpen(_ open: Bool) {
        openRequests.append(open)
        if !open { isOpen = false } else if opensAtOnce { isOpen = true }
    }

    func finishOpening() {
        isOpen = true
        changed?()
    }

    func recheck() { rechecks += 1 }
    func refresh() { refreshes += 1 }

    func send(_ c: FanCommand, _ done: @escaping (FanReply) -> Void) {
        commands.append(c)
        let e = Exchange(c, done)
        if deferReplies {
            queue.append(e)
        } else {
            done(run(e))
        }
    }

    /// Answered after everything sent before it, as on the real link's serial queue.
    func sendWaiting(_ c: FanCommand, timeout: TimeInterval) -> FanReply? {
        commands.append(c)
        waited.append(c)
        queue.forEach { run($0) }
        let reply = answer(c)
        land(c, reply)
        return reply
    }

    /// Everything sent so far has been exchanged; the answers still reach the main thread later.
    func drain(timeout: TimeInterval) -> Bool {
        drains += 1
        guard !drainTimesOut else { return false }
        queue.forEach { run($0) }
        return true
    }

    func flushReplies() {
        let pending = queue
        queue = []
        deferReplies = false
        for e in pending { e.done(run(e)) }
    }

    /// What the shared connection reports when the Fans tab releases everything or a socket is reopened.
    func reset() { resets += 1; changed?() }

    func becomeAvailable() { available = true; outdated = false; known = true; changed?() }
}

/// A client that records EVERY limit asked of it, including the ones it refuses, and whether the restore record was
/// stored at the moment of each call. `FakeChargeLimitClient` refuses a non-client value without recording it, so it
/// cannot show that one was never asked for.
final class RecordingChargeClient: ChargeLimitClient {
    var state: NativeChargeState?
    weak var settings: Settings?
    private(set) var limitCalls: [Int] = []
    private(set) var recordAtEachCall: [String?] = []

    init(state: NativeChargeState?) { self.state = state }

    func read() -> NativeChargeState? { state }

    func setLimit(_ percent: Int) -> Bool {
        limitCalls.append(percent)
        recordAtEachCall.append(settings?.chargeRestoreRecord)
        guard NativeChargeLimit.isClientSettable(percent) else { return false }
        state?.mclLimit = percent
        return true
    }

    func setLimitEnabled(_ on: Bool) -> Bool {
        recordAtEachCall.append(settings?.chargeRestoreRecord)
        state?.mclEnabled = on
        return true
    }

    func setOptimizedCharging(_ on: Bool) -> Bool {
        recordAtEachCall.append(settings?.chargeRestoreRecord)
        state?.optimizedChargingEnabled = on
        return true
    }
}

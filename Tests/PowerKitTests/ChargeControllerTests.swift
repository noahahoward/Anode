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
    /// What the charger switch reads. nil = the read fails. Until a read has worked, that is a Mac whose switch cannot
    /// be read, and the controller goes by what macOS says, which is what every test that does not set this is about.
    /// After a read has worked, a failed read is no information.
    private var chargerSwitch: UInt8?
    /// How many times the switch was read.
    private var switchReads = 0
    private var lines: [String] = []
    private var clientsMade = 0
    /// How many times the helper link was asked for by the early lift (it builds one only when it has work).
    private var helpersMade = 0
    private var controller: ChargeController?
    /// Stands in for NSWorkspace's notification center, so a test can say the Mac sleeps or the account is switched.
    private var center: NotificationCenter!
    private var limitInForce: ChargeLimitInForce!
    /// Why `makeClient` gave nothing, when `clientToMake` is nil. The tests that say only "no client" mean a Mac that
    /// is too old for it.
    private var noClientReason = ChargeController.NoClientReason(unsupportedMac: true, step: nil)
    /// Whether this account is the one on screen when the controller is made; nil = the session cannot be read.
    private var onConsole: Bool? = true

    override func setUpWithError() throws {
        (defaults, suiteName) = try TestDefaults.make(owner: "ChargeController", test: name)
        settings = Settings(defaults: defaults)
        client = FakeChargeLimitClient(state: NativeChargeState(mclEnabled: false, mclLimit: 100,
                                                                optimizedChargingEnabled: true))
        clientToMake = client
        helper = FakeHelperLink()
        battery = Self.state(70)
        chargerSwitch = nil
        switchReads = 0
        lines = []
        clientsMade = 0
        helpersMade = 0
        center = NotificationCenter()
        limitInForce = ChargeLimitInForce()
    }

    override func tearDownWithError() throws {
        controller?.shutdown()
        controller = nil
        settings = nil
        TestDefaults.destroy(defaults, suiteName)
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    static func state(_ percent: Int, ac: Bool = true, adapter: Bool? = nil,
                      temperature: Double? = nil, charging: Bool = false) -> Battery.State {
        var s = Battery.State(percent: percent, isCharging: charging, onAC: ac, cycleCount: 100,
                              voltage_mV: 12_000, amperage_mA: 0, remainingCapacity_mAh: 4_000,
                              timeRemaining_min: nil)
        s.adapterPresent = adapter ?? ac
        s.temperature_C = temperature
        return s
    }

    @discardableResult
    private func make(enabled: Bool = true, startDelay: TimeInterval = ChargeController.startDelay,
                      liftedAtLaunch: Bool = false) -> ChargeController {
        settings.chargeControlEnabled = enabled
        let c = ChargeController(settings: settings,
                                 makeClient: { [weak self] in
                                     self?.clientsMade += 1
                                     return self?.clientToMake
                                 },
                                 helper: helper,
                                 battery: { [weak self] in self?.battery },
                                 chargerSwitch: { [weak self] in
                                     self?.switchReads += 1
                                     return self?.chargerSwitch
                                 },
                                 log: { [weak self] in self?.lines.append($0) },
                                 workspace: center, limitInForce: limitInForce, startDelay: startDelay,
                                 liftedAtLaunch: liftedAtLaunch,
                                 noClientBecause: { [weak self] in
                                     self?.noClientReason ?? ChargeController.NoClientReason(unsupportedMac: true,
                                                                                            step: nil)
                                 },
                                 onConsole: { [weak self] in self?.onConsole })
        controller = c
        return c
    }

    private var record: NativeChargeState? {
        settings.chargeRestoreRecord.flatMap { try? JSONDecoder().decode(NativeChargeState.self, from: Data($0.utf8)) }
    }

    private func discharges(_ commands: [FanCommand]) -> [Int] {
        commands.compactMap { if case .discharge(let p) = $0 { return p } else { return nil } }
    }

    /// What macOS says before Charge Control has ever touched it, for the tests that follow it through a quit or a
    /// crash: a limit of 90 that is on, and Optimized Battery Charging on.
    private let found = NativeChargeState(mclEnabled: true, mclLimit: 90, optimizedChargingEnabled: true)

    /// A run that ended with no `shutdown` (a crash, a kill, the power going): the controller is dropped as it stands.
    /// macOS keeps what Charge Control set, and the record and the setting stay on disk.
    private func crash() {
        controller = nil
    }

    /// The last run held a limit and then crashed: Charge Control was switched on over `found` and set `limit`.
    private func crashedWhileHolding(limit: Int = 85) {
        client.state = found
        settings.chargeLimit = limit
        make()
        XCTAssertEqual(client.state?.mclLimit, limit, "the run before did not hold its limit")
        XCTAssertNotNil(settings.chargeRestoreRecord)
        crash()
    }

    /// A time after the delay that follows an unclean exit has run out, and one before.
    private var afterTheDelay: Date { Date().addingTimeInterval(ChargeController.startDelay + 1) }
    private var beforeTheDelayEnds: Date { Date().addingTimeInterval(ChargeController.startDelay - 10) }

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
        XCTAssertEqual(helper.drains, 0, "the helper link was used while off")
        XCTAssertNil(settings.chargeRestoreRecord)
    }

    /// Off at launch with nothing left to put back: nothing is made at all.
    func testOffWithNoRecordMakesNothingAtLaunch() {
        let c = make(enabled: false)
        XCTAssertEqual(clientsMade, 0, "a client was made at launch while off")
        XCTAssertEqual(helper.follows, 0)
        XCTAssertEqual(helper.drains, 0)
        XCTAssertTrue(helper.commands.isEmpty)
        XCTAssertEqual(c.status, .off)
        XCTAssertTrue(lines.isEmpty, lines.joined(separator: "\n"))
    }

    /// Off at launch with a record left over (a switch-off macOS partly refused, or the setting turned off while
    /// Anode was closed): macOS would otherwise keep a limit Anode set while the switch shows off. It is put back
    /// once, with a client made only for that; nothing else starts.
    func testOffWithALeftoverRecordPutsItBackOnceAtLaunch() {
        let found = NativeChargeState(mclEnabled: true, mclLimit: 90, optimizedChargingEnabled: true)
        settings.chargeRestoreRecord = ChargeController.encodeRecord(found)
        client.state = NativeChargeState(mclEnabled: true, mclLimit: 80, optimizedChargingEnabled: false)
        let c = make(enabled: false)
        XCTAssertEqual(client.state, found, "the leftover record was not put back at launch")
        XCTAssertNil(settings.chargeRestoreRecord)
        XCTAssertEqual(clientsMade, 1)
        XCTAssertEqual(c.status, .off)
        XCTAssertEqual(helper.follows, 0, "the helper was followed while off")
        XCTAssertTrue(lines.contains { $0.contains("left over while off; putting it back at launch") },
                      lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("put back macOS's own settings") }, lines.joined(separator: "\n"))
        // Nothing runs on: no timer, no observer, no client kept.
        let calls = client.limitCalls
        settings.chargeLimit = 85
        c.periodicTick()
        c.tick()
        XCTAssertEqual(client.limitCalls, calls, "the client outlived the restore")
        XCTAssertEqual(clientsMade, 1)
    }

    /// A launch-time restore macOS refuses keeps the record and says so, and is not tried again on its own.
    func testALaunchRestoreThatIsRefusedKeepsTheRecord() {
        let found = NativeChargeState(mclEnabled: true, mclLimit: 90, optimizedChargingEnabled: true)
        settings.chargeRestoreRecord = ChargeController.encodeRecord(found)
        client.succeeds = false
        let c = make(enabled: false)
        XCTAssertNotNil(settings.chargeRestoreRecord, "a refused restore cleared the record")
        XCTAssertTrue(lines.contains { $0.contains("record is kept") }, lines.joined(separator: "\n"))
        c.periodicTick()
        c.tick()
        XCTAssertEqual(clientsMade, 1, "tried again without a launch, a switch-off or an uninstall")
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

    /// A record that is there is the state before Charge Control ever ran; a later switch-on must not replace it with a
    /// state Charge Control itself made. Here a switch-off macOS refused leaves the record (and Charge Control's own
    /// settings in force), and the person switches on again by hand.
    func testSwitchingOnAgainKeepsTheFirstRecord() {
        client.state = found
        make()
        client.succeeds = false
        settings.chargeControlEnabled = false
        XCTAssertEqual(record, found, "a refused switch-off lost the record")
        XCTAssertEqual(client.state?.mclLimit, 80, "macOS was not refusing")
        client.succeeds = true
        settings.chargeControlEnabled = true
        XCTAssertEqual(record, found, "switching on again replaced the first record with a state Charge Control made")
    }

    /// A record that cannot be read may still be the only trace of the state before Charge Control ran, and the
    /// state found now may be one Charge Control made: it is never written over. Switching off puts back macOS's
    /// defaults instead (no limit, Optimized Battery Charging on), says so, and then clears it. The only way such a
    /// record meets a switch-on is by hand: at launch with Charge Control on it is put back at once (see
    /// `testALaunchAfterACrashPutsBackTheDefaultsForAnUnreadableRecord`), so here macOS refuses that while Charge
    /// Control is off, and the record is still there when the person switches on.
    func testUndecodableRecordIsKeptAndSwitchingOffPutsBackTheDefaults() {
        settings.chargeRestoreRecord = "{not a record"
        client.state = NativeChargeState(mclEnabled: true, mclLimit: 85, optimizedChargingEnabled: false)
        client.succeeds = false
        let c = make(enabled: false)
        XCTAssertEqual(settings.chargeRestoreRecord, "{not a record", "a refused put-back cleared the record")
        client.succeeds = true
        settings.chargeControlEnabled = true
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
        client.state = NativeChargeState(mclEnabled: true, mclLimit: 63, optimizedChargingEnabled: true)
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
        client.state = NativeChargeState(mclEnabled: true, mclLimit: 63, optimizedChargingEnabled: true)
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
        client.succeeds = false   // the launch-time restore is refused, so the record is still there to uninstall
        let c = make(enabled: false)
        XCTAssertEqual(clientsMade, 1)
        XCTAssertNotNil(settings.chargeRestoreRecord)
        client.succeeds = true
        c.restoreForUninstall()
        XCTAssertEqual(clientsMade, 2)
        XCTAssertEqual(client.state, found)
        XCTAssertNil(settings.chargeRestoreRecord)
        XCTAssertEqual(c.status, .off)
        let calls = client.limitCalls
        c.tick()
        XCTAssertEqual(client.limitCalls, calls, "the client outlived the restore")
    }

    /// A controller that goes away without a shutdown still lets go of its claim on the shared connection; otherwise
    /// the socket could never close again, and the helper's dead man's switch would never run.
    func testDeinitLetsGoOfTheHelper() {
        var c: ChargeController? = ChargeController(settings: settings,
                                                    makeClient: { [weak self] in self?.clientToMake },
                                                    helper: helper, battery: { [weak self] in self?.battery },
                                                    chargerSwitch: { nil }, log: { _ in })
        settings.chargeControlEnabled = true
        XCTAssertTrue(helper.following)
        XCTAssertNotNil(c)
        c = nil
        XCTAssertFalse(helper.following, "the controller went away still holding its claim on the helper link")
    }

    // ── Quitting ────────────────────────────────────────────────────────────

    /// Charge Control's limit is in force only while Anode runs: quitting puts macOS's own settings back (the limit's
    /// switch, the limit, Optimized Battery Charging) as switching off does, and clears the record. The setting and
    /// what the person chose are not touched: the next launch switches on again.
    func testQuittingPutsMacOSsOwnSettingsBackAndLetsGo() {
        client.state = found
        settings.chargeLimit = 85
        settings.chargeSailingEnabled = true
        settings.chargeHeatProtectionEnabled = true
        let c = make()
        XCTAssertEqual(client.state?.mclLimit, 85)
        XCTAssertEqual(client.state?.optimizedChargingEnabled, false)
        c.shutdown()
        XCTAssertFalse(helper.following)
        XCTAssertEqual(client.state, found, "Charge Control's settings were left in force after the quit")
        XCTAssertNil(settings.chargeRestoreRecord, "the record outlived a restore that worked")
        XCTAssertTrue(settings.chargeControlEnabled, "quitting is not switching off")
        XCTAssertEqual(settings.chargeLimit, 85)
        XCTAssertTrue(settings.chargeSailingEnabled)
        XCTAssertTrue(settings.chargeHeatProtectionEnabled)
        XCTAssertTrue(lines.contains { $0.hasPrefix("put back macOS's own settings") }, lines.joined(separator: "\n"))
    }

    /// A hold is a limit too (Heat Protection at 24%): it is not put back to the person's own, it is lifted with
    /// the rest.
    func testQuittingLiftsAHoldToo() {
        settings.chargeHeatProtectionEnabled = true
        battery = Self.state(24, temperature: 40)
        helper.landsOn = client
        let c = make()
        XCTAssertEqual(client.state?.mclLimit, 24)
        c.shutdown()
        XCTAssertEqual(client.state, NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: true),
                       "a heat hold was left in force after the quit")
        XCTAssertNil(settings.chargeRestoreRecord)
        XCTAssertTrue(settings.chargeControlEnabled)
        XCTAssertFalse(helper.following)
    }

    /// Top Up's 100 is a hold too.
    func testQuittingEndsTopUp() {
        battery = Self.state(85)
        let c = make()
        c.pressTopUp()
        XCTAssertEqual(client.state?.mclLimit, 100)
        c.shutdown()
        XCTAssertEqual(client.state, NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: true))
        XCTAssertNil(settings.chargeRestoreRecord)
    }

    /// A limit only the helper can set that macOS had before Charge Control (set by another tool, say) goes back
    /// through the helper, waited for; the record goes only once that landed.
    func testQuittingPutsBackALimitOnlyTheHelperCanSet() {
        client.state = NativeChargeState(mclEnabled: true, mclLimit: 63, optimizedChargingEnabled: true)
        battery = Self.state(70)
        helper.landsOn = client
        let c = make()
        c.pressTopUp()
        XCTAssertEqual(client.state?.mclLimit, 100)
        c.shutdown()
        XCTAssertEqual(helper.waited, [.setChargeLimit(63)])
        XCTAssertEqual(client.state?.mclLimit, 63)
        XCTAssertNil(settings.chargeRestoreRecord)
    }

    /// A discharge is stopped, and its end waited for, before macOS is put back: nothing drains with nobody watching,
    /// and the stop goes behind everything the helper was already sent.
    func testQuittingDuringADischargeStopsItFirstAndThenPutsMacOSsOwnSettingsBack() {
        battery = Self.state(90)
        let c = make()
        c.pressDischarge()
        XCTAssertEqual(discharges(helper.commands), [80])
        var heldWhenStopped: NativeChargeState?
        helper.beforeSend = { [unowned self] cmd in
            if cmd == .stopDischarge { heldWhenStopped = self.client.state }
        }
        c.shutdown()
        XCTAssertEqual(helper.waited, [.stopDischarge], "the stop was not waited for")
        XCTAssertEqual(heldWhenStopped?.mclLimit, 80, "macOS was put back before the discharge was stopped")
        XCTAssertEqual(client.state, NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: true))
        XCTAssertNil(settings.chargeRestoreRecord)
        XCTAssertFalse(settings.chargeCutUnconfirmed, "the helper's yes to the stop was not heard")
    }

    /// A limit on its way to the helper lands before macOS is put back, or it would land after and stay.
    func testQuittingLandsAfterAHelperLimitStillOnItsWay() {
        settings.chargeLimit = 63
        helper.landsOn = client
        let c = make()
        XCTAssertEqual(client.state?.mclLimit, 63)
        helper.deferReplies = true
        settings.chargeLimit = 62
        c.shutdown()
        helper.flushReplies()
        XCTAssertEqual(client.state, NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: true),
                       "a limit still on its way to the helper landed after the quit's restore")
        XCTAssertNil(settings.chargeRestoreRecord)
    }

    /// If macOS refuses part of it the record stays and a line says so; the next launch then takes the route of an
    /// unclean exit and lifts the limit before anything else.
    func testQuittingWhenMacOSRefusesTheRestoreKeepsTheRecordAndTheNextLaunchLiftsTheLimit() {
        client.state = found
        let c = make()
        client.succeeds = false
        c.shutdown()
        XCTAssertNotNil(settings.chargeRestoreRecord, "a restore macOS refused cleared the record")
        XCTAssertTrue(lines.contains { $0.contains("record is kept") }, lines.joined(separator: "\n"))
        XCTAssertTrue(settings.chargeControlEnabled)

        crash()
        client.succeeds = true
        let next = make()
        XCTAssertEqual(client.state, found, "the launch after a refused restore did not lift the limit")
        XCTAssertNil(settings.chargeRestoreRecord)
        XCTAssertTrue(next.isWaitingToStart)
    }

    /// A limit the helper has not answered, because it is slow, may land after the restore and stay: the drain says
    /// so (false), and the record is kept and a line says it may land after this, so that the next launch lifts it
    /// instead of recording it as macOS's own. Quitting, as switching off.
    func testQuittingBehindALimitTheHelperHasNotLandedKeepsTheRecord() {
        settings.chargeLimit = 63
        helper.landsOn = client
        let c = make()
        helper.deferReplies = true
        settings.chargeLimit = 62
        helper.drainTimesOut = true
        c.shutdown()
        XCTAssertNotNil(settings.chargeRestoreRecord, "the record was cleared though a limit may land after it")
        XCTAssertTrue(lines.contains { $0.contains("may land after this") }, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.contains("record is kept") }, lines.joined(separator: "\n"))
        XCTAssertTrue(settings.chargeControlEnabled)

        // The next launch takes the unclean route: it lifts, and does not take the late limit for macOS's own.
        crash()
        helper.drainTimesOut = false
        helper.flushReplies()
        XCTAssertEqual(client.state?.mclLimit, 62, "the late limit landed")
        let next = make()
        XCTAssertTrue(next.isWaitingToStart)
        XCTAssertEqual(client.state, NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: true),
                       "the late limit was kept as macOS's own")
        XCTAssertNil(settings.chargeRestoreRecord)
    }

    /// The helper not answering the stop on the way out: macOS is still put back, but not known to be, so the record
    /// stays and the next launch takes the unclean route.
    func testQuittingWithAHelperThatDoesNotAnswerKeepsTheRecord() {
        battery = Self.state(90)
        client.state = found
        let c = make()
        c.pressDischarge()
        helper.gone = true
        c.shutdown()
        XCTAssertEqual(client.state, found)
        XCTAssertNotNil(settings.chargeRestoreRecord)
        XCTAssertTrue(settings.chargeCutUnconfirmed)
    }

    /// Quitting once the record has gone (an uninstall put macOS back) puts nothing back: with no record there is
    /// nothing of Charge Control's to undo, and a restore would write macOS's defaults over whatever is there.
    func testQuittingWithNoRecordPutsNothingBack() {
        let c = make()
        settings.chargeRestoreRecord = nil
        client.state = NativeChargeState(mclEnabled: true, mclLimit: 95, optimizedChargingEnabled: true)
        let calls = (client.limitCalls, client.limitEnabledCalls, client.optimizedChargingCalls)
        c.shutdown()
        XCTAssertEqual(client.limitCalls, calls.0)
        XCTAssertEqual(client.limitEnabledCalls, calls.1)
        XCTAssertEqual(client.optimizedChargingCalls, calls.2)
        XCTAssertEqual(client.state, NativeChargeState(mclEnabled: true, mclLimit: 95, optimizedChargingEnabled: true))
    }

    /// The launch after a quit is a cold start: Charge Control comes on at once, writes down what macOS says now
    /// (not what an earlier run found), and sets the person's limit. No delay.
    func testTheLaunchAfterAQuitSwitchesOnAsFromAColdStart() {
        client.state = found
        settings.chargeLimit = 85
        let c = make()
        c.shutdown()
        crash()
        // The person changes macOS's own setting while Anode is closed.
        let changed = NativeChargeState(mclEnabled: true, mclLimit: 95, optimizedChargingEnabled: true)
        client.state = changed
        let next = make()
        XCTAssertFalse(next.isWaitingToStart, "a quit was taken for a crash")
        XCTAssertEqual(record, changed, "macOS's own settings were not recorded afresh")
        XCTAssertEqual(client.state?.mclLimit, 85, "the limit was not set at launch")
        XCTAssertEqual(client.state?.mclEnabled, true)
        XCTAssertEqual(client.state?.optimizedChargingEnabled, false)
        XCTAssertTrue(helper.following)
        XCTAssertEqual(next.status, .active(ChargeDecision(osLimit: 85, dischargeTo: nil, reason: .limit)))
        XCTAssertFalse(lines.contains { $0.contains("did not quit cleanly") }, lines.joined(separator: "\n"))
    }

    // ── Launching after an unclean exit ─────────────────────────────────────

    /// What was asked of macOS so far: the limits, the limit's switch and Optimized Battery Charging.
    private var writesToMacOS: [Int] {
        [client.limitCalls.count, client.limitEnabledCalls.count, client.optimizedChargingCalls.count]
    }

    /// A quit puts macOS back and clears the record, so a record still there at launch with Charge Control on means
    /// the last run did not quit cleanly (a crash, a kill, the power going). The limit is lifted at once. It starts
    /// again only after Anode has run for `startDelay`: an Anode that breaks on launch must leave the battery
    /// released, not held.
    func testALaunchAfterACrashLiftsTheLimitAtOnceAndStartsAgainAfterTheDelay() {
        crashedWhileHolding(limit: 85)
        XCTAssertEqual(client.state?.mclLimit, 85, "macOS keeps what the dead run set")
        let c = make()

        // At launch: macOS's own settings are back, the record is gone, and the section says why.
        XCTAssertEqual(client.state, found, "the limit was not lifted at launch")
        XCTAssertNil(settings.chargeRestoreRecord)
        XCTAssertTrue(c.isWaitingToStart)
        XCTAssertEqual(c.status, .waiting(ChargeController.liftedText))
        XCTAssertTrue(lines.contains { $0.contains("did not quit cleanly") }, lines.joined(separator: "\n"))
        XCTAssertFalse(helper.following, "the helper was followed while the delay runs")
        XCTAssertTrue(settings.chargeControlEnabled, "the setting was changed")
        XCTAssertEqual(settings.chargeLimit, 85, "the person's limit was changed")
        XCTAssertTrue(settings.chargeStartPending, "a start pending was not written down for the wait")

        // For the delay nothing is set, whatever happens: the limit changes, the Mac sleeps and wakes, the timer runs.
        let writes = writesToMacOS
        settings.chargeLimit = 95
        c.tick()
        c.willSleep()
        c.didWake()
        c.periodicTick()
        c.resumeIfDue(now: beforeTheDelayEnds)
        XCTAssertTrue(c.isWaitingToStart)
        XCTAssertEqual(writesToMacOS, writes, "something was set during the delay")
        XCTAssertEqual(client.state, found)
        XCTAssertTrue(settings.chargeStartPending, "the pending start was cleared before the delay ended")

        // After it: as from a cold start, with the limit as it is now, and macOS's own settings written down afresh.
        c.resumeIfDue(now: afterTheDelay)
        XCTAssertFalse(c.isWaitingToStart)
        XCTAssertEqual(record, found)
        XCTAssertEqual(client.state?.mclLimit, 95)
        XCTAssertEqual(client.state?.mclEnabled, true)
        XCTAssertEqual(client.state?.optimizedChargingEnabled, false)
        XCTAssertTrue(helper.following)
        XCTAssertEqual(c.status, .active(ChargeDecision(osLimit: 95, dischargeTo: nil, reason: .limit)))
        XCTAssertFalse(settings.chargeStartPending, "the pending start outlived the switch-on that followed the delay")
    }

    /// The delay is a timer on the main run loop, not only something a test can call: it fires by itself.
    func testTheDelayEndsByItself() {
        crashedWhileHolding(limit: 85)
        let c = make(startDelay: 0.05)
        XCTAssertTrue(c.isWaitingToStart)
        let deadline = Date().addingTimeInterval(5)
        while c.isWaitingToStart, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(c.isWaitingToStart, "the delay never ended")
        XCTAssertFalse(settings.chargeStartPending)
        XCTAssertEqual(client.state?.mclLimit, 85)
        XCTAssertEqual(c.status, .active(ChargeDecision(osLimit: 85, dischargeTo: nil, reason: .limit)))
    }

    /// The delay is a minute, and the sentence says "a minute".
    func testTheDelayIsAMinute() {
        XCTAssertEqual(ChargeController.startDelay, 60)
        XCTAssertEqual(ChargeController.liftedText, "Starting again in a minute. Charge Control waits before holding a "
                       + "limit when Anode did not close normally last time.")
    }

    /// An Anode that stops again within the delay leaves the limit lifted: nothing was set, and the record is gone,
    /// so macOS has its own settings whatever happens next.
    func testStoppingBeforeTheDelayEndsLeavesMacOSsOwnSettingsInForce() {
        crashedWhileHolding(limit: 85)
        let c = make()
        c.shutdown()
        XCTAssertEqual(client.state, found)
        XCTAssertNil(settings.chargeRestoreRecord)
        XCTAssertFalse(c.isWaitingToStart)
        XCTAssertTrue(settings.chargeControlEnabled)
        XCTAssertFalse(settings.chargeStartPending, "a clean quit left a start pending")
        let writes = writesToMacOS
        c.resumeIfDue(now: afterTheDelay)
        XCTAssertEqual(writesToMacOS, writes, "the delay ended after the controller had stopped")
        XCTAssertFalse(helper.following)
    }

    /// The same when it crashes again: the limit is still lifted.
    func testCrashingAgainDuringTheDelayLeavesTheLimitLifted() {
        crashedWhileHolding(limit: 85)
        make()
        crash()
        XCTAssertEqual(client.state, found, "a crash during the delay left a limit in force")
        XCTAssertNil(settings.chargeRestoreRecord)
    }

    /// A crash during the delay leaves no record, but it does not earn a cold start: the pending start is still on
    /// disk, so the next launch waits the full delay again, writing nothing. Only an Anode that stays up for the
    /// whole delay holds a limit, however often it crashes before that.
    func testCrashingDuringTheDelayMakesTheNextLaunchWaitAgain() {
        crashedWhileHolding(limit: 85)
        for _ in 1...3 {
            let c = make()
            XCTAssertTrue(c.isWaitingToStart, "a launch after a crash during the delay did not wait")
            XCTAssertEqual(client.state, found, "a limit was held by an Anode that had not stayed up")
            XCTAssertNil(settings.chargeRestoreRecord)
            XCTAssertTrue(settings.chargeStartPending)
            crash()
        }
        // One that stays up for the whole delay does hold it.
        let c = make()
        c.resumeIfDue(now: afterTheDelay)
        XCTAssertFalse(c.isWaitingToStart)
        XCTAssertEqual(client.state?.mclLimit, 85)
        XCTAssertFalse(settings.chargeStartPending)
        // And a crash after that is the ordinary one: the record is there, the pending start is not.
        crash()
        XCTAssertNotNil(settings.chargeRestoreRecord)
        XCTAssertFalse(settings.chargeStartPending)
    }

    /// With a start pending and no record there is nothing to put back: the launch writes nothing, says a start was
    /// still pending, waits the full delay, then switches on as from a cold start and clears the pending start.
    func testALaunchWithAStartPendingAndNoRecordWaitsTheFullDelay() {
        settings.chargeStartPending = true
        settings.chargeLimit = 85
        let macOS = NativeChargeState(mclEnabled: true, mclLimit: 95, optimizedChargingEnabled: true)
        client.state = macOS
        let c = make()
        XCTAssertTrue(c.isWaitingToStart)
        XCTAssertEqual(c.status, .waiting(ChargeController.liftedText))
        XCTAssertEqual(writesToMacOS, [0, 0, 0], "something was written with nothing to put back")
        XCTAssertEqual(client.state, macOS)
        XCTAssertNil(settings.chargeRestoreRecord)
        XCTAssertTrue(lines.contains { $0.contains("start was still pending") }, lines.joined(separator: "\n"))
        XCTAssertFalse(helper.following)
        XCTAssertTrue(settings.chargeStartPending)
        c.resumeIfDue(now: beforeTheDelayEnds)
        XCTAssertTrue(c.isWaitingToStart)
        XCTAssertEqual(writesToMacOS, [0, 0, 0])

        c.resumeIfDue(now: afterTheDelay)
        XCTAssertFalse(c.isWaitingToStart)
        XCTAssertEqual(record, macOS, "macOS's own settings were not written down afresh")
        XCTAssertEqual(client.state?.mclLimit, 85)
        XCTAssertEqual(client.state?.optimizedChargingEnabled, false)
        XCTAssertFalse(settings.chargeStartPending, "the start was still pending after it had run")
        XCTAssertTrue(helper.following)
    }

    /// The pending start is on disk before the record goes. If it were written after, a crash between the two would
    /// leave neither, and the next launch would hold the limit at once.
    func testThePendingStartIsWrittenBeforeTheRecordGoes() {
        let spy = RecordingChargeClient(state: found)
        spy.settings = settings
        clientToMake = spy
        settings.chargeRestoreRecord = ChargeController.encodeRecord(found)
        make()
        XCTAssertFalse(spy.pendingAtEachCall.isEmpty, "nothing was put back")
        XCTAssertTrue(spy.pendingAtEachCall.allSatisfy { $0 },
                      "macOS was changed before the pending start was stored")
        XCTAssertNil(settings.chargeRestoreRecord)
    }

    /// A pending start with a debt: the debt is still asked about at once, with nothing to put back first.
    func testACutDebtIsStillAskedAboutWhenOnlyAStartIsPending() {
        settings.chargeStartPending = true
        settings.chargeCutUnconfirmed = true
        helper.gone = true
        let c = make()
        XCTAssertTrue(c.isWaitingToStart)
        XCTAssertTrue(helper.commands.contains(.stopDischarge), "the debt was not asked about at launch")
        XCTAssertNotNil(c.offWarning)
        helper.gone = false
        helper.available = true
        c.retryOwedStopWhileOff()
        XCTAssertFalse(settings.chargeCutUnconfirmed)
        XCTAssertTrue(c.isWaitingToStart)
        XCTAssertEqual(writesToMacOS, [0, 0, 0])
    }

    /// A clean quit during the delay is the ordinary exit of an Anode that put macOS back: nothing is pending, and
    /// the next launch is a cold start.
    func testAQuitDuringTheDelayLeavesNothingPendingAndTheNextLaunchIsAColdStart() {
        crashedWhileHolding(limit: 85)
        let c = make()
        XCTAssertTrue(settings.chargeStartPending)
        c.shutdown()
        XCTAssertFalse(settings.chargeStartPending)
        XCTAssertEqual(client.state, found)
        crash()
        let next = make()
        XCTAssertFalse(next.isWaitingToStart, "a clean quit was taken for a crash")
        XCTAssertEqual(client.state?.mclLimit, 85, "the limit was not set at launch")
        XCTAssertEqual(record, found)
    }

    /// The headless restore (`uninstall.sh`) leaves nothing pending: Charge Control is switched off and macOS is
    /// as it found it.
    func testTheHeadlessRestoreClearsAPendingStart() {
        settings.chargeStartPending = true
        settings.chargeControlEnabled = true
        XCTAssertTrue(ChargeController.restoreForUninstall(settings: settings, makeClient: { [weak self] in
            self?.client
        }, helper: helper, log: { _ in }))
        XCTAssertFalse(settings.chargeStartPending)
        XCTAssertFalse(settings.chargeControlEnabled)
    }

    /// Switching Charge Control off during the delay cancels it: nothing starts when it runs out.
    func testSwitchingOffDuringTheDelayCancelsIt() {
        crashedWhileHolding(limit: 85)
        let c = make()
        XCTAssertTrue(c.isWaitingToStart)
        settings.chargeControlEnabled = false
        XCTAssertFalse(c.isWaitingToStart)
        XCTAssertEqual(c.status, .off)
        XCTAssertEqual(client.state, found)
        XCTAssertNil(settings.chargeRestoreRecord)
        XCTAssertFalse(settings.chargeStartPending, "switching off left a start pending")
        let writes = writesToMacOS, made = clientsMade
        c.resumeIfDue(now: afterTheDelay)
        XCTAssertEqual(writesToMacOS, writes, "the delay ran out after Charge Control was switched off")
        XCTAssertEqual(clientsMade, made)
        XCTAssertEqual(c.status, .off)
        XCTAssertFalse(helper.following)

        // Switched on again by hand, it starts at once: nothing was left over to wait for.
        settings.chargeControlEnabled = true
        XCTAssertFalse(c.isWaitingToStart)
        XCTAssertEqual(client.state?.mclLimit, 85)
    }

    /// Another account on screen holds the limit, so the delay does not end into it: macOS's current state is that
    /// account's, and writing over it (or writing it down as "macOS's own") would corrupt the record and fight it every
    /// 30 s. The start waits until this account is back.
    func testTheDelayDoesNotEndWhileAnotherAccountIsOnScreen() {
        crashedWhileHolding(limit: 85)
        let c = make()
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        let theirs = NativeChargeState(mclEnabled: true, mclLimit: 95, optimizedChargingEnabled: false)
        client.state = theirs
        let writes = writesToMacOS
        c.resumeIfDue(now: afterTheDelay)
        XCTAssertTrue(c.isWaitingToStart, "the delay ended into another account's limit")
        XCTAssertEqual(writesToMacOS, writes)
        XCTAssertEqual(client.state, theirs)
        XCTAssertNil(settings.chargeRestoreRecord, "the other account's state was written down as macOS's own")
        XCTAssertFalse(helper.following)
        XCTAssertTrue(settings.chargeStartPending, "the start was no longer pending though it had not run")

        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertFalse(c.isWaitingToStart, "the start did not come once this account was back")
        XCTAssertFalse(settings.chargeStartPending)
        XCTAssertEqual(client.state?.mclLimit, 85)
        XCTAssertEqual(record, theirs, "macOS's state when this account came back is what is written down")
        XCTAssertTrue(helper.following)
        XCTAssertEqual(c.status, .active(ChargeDecision(osLimit: 85, dischargeTo: nil, reason: .limit)))
    }

    /// Away for part of the delay and back before it is over: nothing changes, and it ends on time.
    func testAnAccountSwitchWithinTheDelayChangesNothing() {
        crashedWhileHolding(limit: 85)
        let c = make()
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertTrue(c.isWaitingToStart)
        XCTAssertEqual(client.state, found)
        c.resumeIfDue(now: afterTheDelay)
        XCTAssertFalse(c.isWaitingToStart)
        XCTAssertEqual(client.state?.mclLimit, 85)
    }

    /// Switched off while another account is on screen, and on again by hand later: the person is at the screen, so
    /// the limit is held; the account that was away is not remembered as still away.
    func testSwitchingOnAgainAfterAnAbsenceDuringTheDelayHoldsTheLimit() {
        crashedWhileHolding(limit: 85)
        make()
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        settings.chargeControlEnabled = false
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        settings.chargeControlEnabled = true
        XCTAssertEqual(client.state?.mclLimit, 85)
        XCTAssertEqual(record, found)
    }

    /// A lift macOS refused leaves the dead run's limit in force and its record on disk, and the controller waits all
    /// the same. Switching off during that wait puts the record back, as it would from any other off state: nothing
    /// else would, and the limit would stay for the rest of the run.
    func testSwitchingOffDuringTheDelayAfterARefusedLiftPutsTheRecordBack() {
        crashedWhileHolding(limit: 85)
        client.succeeds = false
        let c = make()
        XCTAssertTrue(c.isWaitingToStart)
        XCTAssertNotNil(settings.chargeRestoreRecord, "the refused lift cleared the record")
        XCTAssertEqual(client.state?.mclLimit, 85, "macOS was not refusing")
        client.succeeds = true
        settings.chargeControlEnabled = false
        XCTAssertFalse(c.isWaitingToStart)
        XCTAssertEqual(client.state, found, "the dead run's limit was left in force after switching off")
        XCTAssertNil(settings.chargeRestoreRecord)
        XCTAssertFalse(settings.chargeStartPending)
        XCTAssertEqual(c.status, .off)
    }

    /// The same on the way out: a quit during that wait puts the record back, with the quit's own bounded waits.
    func testQuittingDuringTheDelayAfterARefusedLiftPutsTheRecordBack() {
        crashedWhileHolding(limit: 85)
        client.succeeds = false
        let c = make()
        XCTAssertNotNil(settings.chargeRestoreRecord)
        client.succeeds = true
        c.shutdown()
        XCTAssertEqual(client.state, found, "the dead run's limit was left in force after the quit")
        XCTAssertNil(settings.chargeRestoreRecord)
        XCTAssertFalse(settings.chargeStartPending)
        XCTAssertTrue(settings.chargeControlEnabled)
    }

    /// With a per-account record and another account on screen, a quit during the wait puts nothing back, as any quit.
    func testWithAPerAccountRecordQuittingDuringTheDelayAfterARefusedLiftWithAnotherAccountOnScreenPutsNothingBack() {
        crashedWhileHolding(limit: 85)
        client.succeeds = false
        let c = make()
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        client.succeeds = true
        let writes = writesToMacOS
        c.shutdown()
        XCTAssertEqual(writesToMacOS, writes)
        XCTAssertNotNil(settings.chargeRestoreRecord)
    }

    // ── The lift at the top of the program ──────────────────────────────────

    /// What `main.swift` runs before anything else of the app is built, on the fakes: the settings, the client, the
    /// helper link (asked for only when there is work) and the log.
    @discardableResult
    private func liftAtLaunch() -> Bool {
        ChargeController.liftAtLaunch(settings: settings, makeClient: { [weak self] in
            self?.clientsMade += 1
            return self?.client
        }, helper: { [unowned self] in
            self.helpersMade += 1
            return self.helper
        }, log: { [weak self] in self?.lines.append($0) })
    }

    /// A relaunch that crashes in everything it builds before the controller (the history database, a state file the
    /// dead run left half written) must still release the battery: the lift is the first thing, before any of that.
    /// With a record, macOS's own settings are back, the record is gone, the start is pending, and no controller (or
    /// anything else of the app) was made.
    func testTheEarlyLiftWithARecordPutsMacOSBackAndWritesThePendingStart() {
        crashedWhileHolding(limit: 85)
        XCTAssertEqual(client.state?.mclLimit, 85)
        let follows = helper.follows
        XCTAssertTrue(liftAtLaunch())
        XCTAssertEqual(client.state, found, "the limit was not lifted")
        XCTAssertNil(settings.chargeRestoreRecord)
        XCTAssertTrue(settings.chargeStartPending)
        XCTAssertTrue(settings.chargeControlEnabled, "the setting was changed")
        XCTAssertEqual(settings.chargeLimit, 85)
        XCTAssertEqual(helper.follows, follows, "the helper was followed")
        XCTAssertFalse(helper.following)
        XCTAssertTrue(lines.contains { $0.contains("did not quit cleanly") }, lines.joined(separator: "\n"))
    }

    /// Crashing again before the controller exists, however often: the pending start is on disk, so each launch
    /// lifts again, writing nothing, and the battery is never held by an Anode that cannot get as far as the
    /// controller.
    func testAnAnodeThatCrashesBeforeTheControllerExistsNeverHoldsTheLimit() {
        crashedWhileHolding(limit: 85)
        let made = clientsMade
        for _ in 1...3 {
            XCTAssertTrue(liftAtLaunch())
            XCTAssertEqual(client.state, found, "a limit was held by an Anode that never got started")
            XCTAssertTrue(settings.chargeStartPending)
        }
        XCTAssertEqual(clientsMade, made + 1, "only the first lift had anything to put back")
    }

    /// With only a pending start there is nothing to put back: nothing is written, no client is made.
    func testTheEarlyLiftWithOnlyAPendingStartWritesNothing() {
        settings.chargeControlEnabled = true
        settings.chargeStartPending = true
        client.state = found
        XCTAssertTrue(liftAtLaunch())
        XCTAssertEqual(writesToMacOS, [0, 0, 0])
        XCTAssertEqual(clientsMade, 0, "a client was made with nothing to put back")
        XCTAssertEqual(client.state, found)
        XCTAssertTrue(settings.chargeStartPending)
        XCTAssertTrue(lines.contains { $0.contains("start was still pending") }, lines.joined(separator: "\n"))
    }

    /// The normal launch: no record, nothing pending. Nothing is built and nothing is logged.
    func testTheEarlyLiftWithNeitherMakesNothing() {
        settings.chargeControlEnabled = true
        XCTAssertFalse(liftAtLaunch())
        XCTAssertEqual(clientsMade, 0)
        XCTAssertEqual(helpersMade, 0, "a helper link was built for a launch with nothing to lift")
        XCTAssertTrue(lines.isEmpty, lines.joined(separator: "\n"))
        XCTAssertFalse(settings.chargeStartPending)
    }

    /// Off, a record left over (a switch-off macOS partly refused, or the setting turned off while Anode was closed) is
    /// put back at the top of the program too: left to the controller, in the middle of launch, an Anode that crashes
    /// before it never releases it. No wait and no pending start: nothing is switched on again.
    func testTheEarlyLiftWhileOffPutsBackALeftoverRecordWithNoWaitAndNoPendingStart() {
        settings.chargeRestoreRecord = ChargeController.encodeRecord(found)
        client.state = NativeChargeState(mclEnabled: true, mclLimit: 80, optimizedChargingEnabled: false)
        settings.chargeControlEnabled = false
        XCTAssertTrue(liftAtLaunch())
        XCTAssertEqual(client.state, found, "the leftover limit was not lifted at the top of the program")
        XCTAssertNil(settings.chargeRestoreRecord)
        XCTAssertFalse(settings.chargeStartPending, "nothing is switched on again, so nothing is pending")
        XCTAssertFalse(settings.chargeControlEnabled, "the setting was changed")
        XCTAssertEqual(helper.follows, 0)
        XCTAssertTrue(lines.contains { $0.contains("left over while off; putting it back at the top of the program") },
                      lines.joined(separator: "\n"))
        // The controller, built later and told the lift ran, does not ask macOS again.
        let made = clientsMade
        let c = make(enabled: false, liftedAtLaunch: true)
        XCTAssertEqual(clientsMade, made, "macOS was asked to put the same record back a second time")
        XCTAssertEqual(c.status, .off)
    }

    /// With a stale pending start and no record, nothing is left in force and nothing is built.
    func testTheEarlyLiftWhileOffWithOnlyAStalePendingStartMakesNothing() {
        settings.chargeStartPending = true
        settings.chargeControlEnabled = false
        XCTAssertFalse(liftAtLaunch())
        XCTAssertEqual(clientsMade, 0)
        XCTAssertEqual(helpersMade, 0)
        XCTAssertTrue(lines.isEmpty, lines.joined(separator: "\n"))
    }

    /// The normal launch with Charge Control off: no record and nothing pending builds nothing and logs nothing.
    func testTheEarlyLiftWhileOffWithNeitherMakesNothing() {
        settings.chargeControlEnabled = false
        XCTAssertFalse(liftAtLaunch())
        XCTAssertEqual(clientsMade, 0)
        XCTAssertEqual(helpersMade, 0, "a helper link was built for a launch with nothing to lift")
        XCTAssertTrue(lines.isEmpty, lines.joined(separator: "\n"))
        XCTAssertFalse(settings.chargeStartPending)
    }

    /// A refusal while off keeps the record, as at any other time, and no start is pending for it.
    func testARefusedEarlyLiftWhileOffKeepsTheRecord() {
        settings.chargeRestoreRecord = ChargeController.encodeRecord(found)
        settings.chargeControlEnabled = false
        client.succeeds = false
        XCTAssertTrue(liftAtLaunch())
        XCTAssertNotNil(settings.chargeRestoreRecord)
        XCTAssertFalse(settings.chargeStartPending)
        XCTAssertTrue(lines.contains { $0.contains("record is kept") }, lines.joined(separator: "\n"))
    }

    /// The line says "while off" only when the setting is off: before an uninstall the setting may be on.
    func testTheLeftoverLineDoesNotSayOffWhenChargeControlIsOn() {
        settings.chargeRestoreRecord = ChargeController.encodeRecord(found)
        settings.chargeControlEnabled = true
        ChargeController.restoreForUninstall(settings: settings, makeClient: { [client] in client },
                                             helper: helper, log: { [weak self] in self?.lines.append($0) })
        XCTAssertTrue(lines.contains { $0.contains("was left over; putting it back before uninstalling") },
                      lines.joined(separator: "\n"))
        XCTAssertFalse(lines.contains { $0.contains("while off") }, lines.joined(separator: "\n"))
    }

    /// A restore macOS refuses keeps the record, and the pending start is on disk all the same.
    func testARefusedEarlyLiftKeepsTheRecordAndWritesThePendingStart() {
        crashedWhileHolding(limit: 85)
        client.succeeds = false
        XCTAssertTrue(liftAtLaunch())
        XCTAssertNotNil(settings.chargeRestoreRecord)
        XCTAssertTrue(settings.chargeStartPending)
        XCTAssertTrue(lines.contains { $0.contains("record is kept") }, lines.joined(separator: "\n"))
    }

    /// The pending start is on disk before anything is put back, so no crash in the middle can leave neither.
    func testTheEarlyLiftWritesThePendingStartBeforePuttingAnythingBack() {
        let spy = RecordingChargeClient(state: found)
        spy.settings = settings
        clientToMake = spy
        settings.chargeRestoreRecord = ChargeController.encodeRecord(found)
        settings.chargeControlEnabled = true
        XCTAssertTrue(ChargeController.liftAtLaunch(settings: settings, makeClient: { spy }, helper: { self.helper },
                                                    log: { _ in }))
        XCTAssertFalse(spy.pendingAtEachCall.isEmpty)
        XCTAssertTrue(spy.pendingAtEachCall.allSatisfy { $0 })
    }

    /// A cut debt is asked about first: the stop is sent and waited for before macOS is put back.
    func testTheEarlyLiftAsksAboutACutDebtFirst() {
        crashedWhileHolding(limit: 85)
        settings.chargeCutUnconfirmed = true
        var heldWhenAsked: NativeChargeState?
        helper.beforeSend = { [unowned self] cmd in
            if cmd == .stopDischarge, heldWhenAsked == nil { heldWhenAsked = self.client.state }
        }
        XCTAssertTrue(liftAtLaunch())
        XCTAssertEqual(helper.waited.first, .stopDischarge, "the debt was not asked about first")
        XCTAssertEqual(heldWhenAsked?.mclLimit, 85, "macOS was put back before the debt was asked about")
        XCTAssertFalse(settings.chargeCutUnconfirmed, "the helper's yes was not heard")
        XCTAssertEqual(client.state, found)
    }

    /// The controller started after the lift waits and does not lift again: no second client, nothing written. The
    /// wait is the same as after a lift of its own, and ends in the ordinary switch-on.
    func testTheControllerStartedAfterTheEarlyLiftWaitsAndDoesNotLiftTwice() {
        crashedWhileHolding(limit: 85)
        XCTAssertTrue(liftAtLaunch())
        let made = clientsMade, writes = writesToMacOS, lineCount = lines.count
        let c = make(liftedAtLaunch: true)
        XCTAssertTrue(c.isWaitingToStart)
        XCTAssertEqual(c.status, .waiting(ChargeController.liftedText))
        XCTAssertEqual(clientsMade, made, "the controller made a client to lift again")
        XCTAssertEqual(writesToMacOS, writes)
        XCTAssertEqual(client.state, found)
        XCTAssertFalse(lines.dropFirst(lineCount).contains { $0.contains("did not quit cleanly") },
                       "the lift was logged twice")
        XCTAssertTrue(settings.chargeStartPending)
        XCTAssertFalse(helper.following)

        c.resumeIfDue(now: afterTheDelay)
        XCTAssertFalse(c.isWaitingToStart)
        XCTAssertEqual(client.state?.mclLimit, 85)
        XCTAssertEqual(record, found)
        XCTAssertFalse(settings.chargeStartPending)
    }

    /// A lift macOS refused is not repeated by the controller either (it was just refused); the record stays, and
    /// what starts after the delay keeps it.
    func testTheControllerDoesNotRepeatARefusedEarlyLift() {
        crashedWhileHolding(limit: 85)
        client.succeeds = false
        XCTAssertTrue(liftAtLaunch())
        let made = clientsMade, writes = writesToMacOS
        let c = make(liftedAtLaunch: true)
        XCTAssertTrue(c.isWaitingToStart)
        XCTAssertEqual(clientsMade, made)
        XCTAssertEqual(writesToMacOS, writes)
        XCTAssertNotNil(settings.chargeRestoreRecord)
        client.succeeds = true
        c.resumeIfDue(now: afterTheDelay)
        XCTAssertEqual(record, found, "the record was replaced")
        XCTAssertEqual(client.state?.mclLimit, 85)
    }

    /// The controller still asks about a debt the lift could not settle, on the off-retry's timer, as before.
    func testTheControllerAfterTheEarlyLiftStillPaysADebtTheLiftCouldNotSettle() {
        crashedWhileHolding(limit: 85)
        settings.chargeCutUnconfirmed = true
        helper.gone = true
        XCTAssertTrue(liftAtLaunch())
        XCTAssertTrue(settings.chargeCutUnconfirmed)
        let c = make(liftedAtLaunch: true)
        XCTAssertNotNil(c.offWarning)
        helper.gone = false
        helper.available = true
        c.retryOwedStopWhileOff()
        XCTAssertFalse(settings.chargeCutUnconfirmed)
        XCTAssertTrue(c.isWaitingToStart)
    }

    /// `main.swift` runs the lift first: after the `--restore-charge-settings` branch (which must stay first, so the
    /// uninstall never lifts), and before the application object, the delegate (whose properties build the panes) and
    /// everything else of the app. Read from the source, because the order of top-level statements is the point.
    func testMainRunsTheLiftBeforeAnythingOfTheAppIsBuilt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let main = try String(contentsOf: root.appendingPathComponent("Sources/AnodeApp/main.swift"), encoding: .utf8)
        func at(_ s: String) throws -> String.Index { try XCTUnwrap(main.range(of: s)?.lowerBound, s) }
        let restoreBranch = try at("if CommandLine.arguments.contains(ChargeController.restoreArgument)")
        let lift = try at("ChargeController.liftAtLaunch(")
        let application = try at("let app = NSApplication.shared")
        let delegate = try at("let delegate = AppDelegate()")
        XCTAssertLessThan(restoreBranch, lift)
        XCTAssertLessThan(lift, application)
        XCTAssertLessThan(lift, delegate)
        XCTAssertTrue(main.contains("liftedAtLaunch: chargeLiftedAtLaunch"), "the controller is not told")
        // Every way into the record is the one shared record, not this account's own: the headless restore, the lift
        // and the controller. (Tests build controllers with per-account records on purpose; the app never does.)
        XCTAssertTrue(main.contains("let chargeRecords = ChargeRecords.live()"))
        XCTAssertTrue(main.contains("restoreForUninstallOutcome(settings: .shared, records: chargeRecords"))
        XCTAssertTrue(main.contains("ChargeController.liftAtLaunch(records: chargeRecords)"))
        XCTAssertTrue(main.contains("ChargeController(settings: .shared, records: chargeRecords"))
        XCTAssertLessThan(try at("let chargeRecords = ChargeRecords.live()"), restoreBranch)
    }

    /// The Uninstall button during the delay: nothing of Charge Control's is in force, so nothing is put back over
    /// what macOS has, and the delay is over.
    func testUninstallingDuringTheDelayPutsNothingBackOverMacOSsOwnSettings() {
        crashedWhileHolding(limit: 85)
        let c = make()
        client.state = NativeChargeState(mclEnabled: true, mclLimit: 95, optimizedChargingEnabled: true)
        let writes = writesToMacOS
        c.restoreForUninstall()
        XCTAssertFalse(c.isWaitingToStart)
        XCTAssertFalse(settings.chargeControlEnabled)
        XCTAssertFalse(settings.chargeStartPending)
        XCTAssertEqual(writesToMacOS, writes)
        XCTAssertEqual(client.state?.mclLimit, 95)
    }

    /// A cut debt is still dealt with first, and during the delay: the delay holds back the limit and new
    /// discharges, never the reconnecting of a charger.
    func testACutDebtAtLaunchIsStillPaidDuringTheDelay() {
        crashedWhileHolding(limit: 85)
        settings.chargeCutUnconfirmed = true
        battery = Self.state(95)
        settings.chargeAutomaticDischarge = true   // a discharge is wanted at 95% over a limit of 85
        var heldWhenAsked: NativeChargeState?
        helper.beforeSend = { [unowned self] cmd in
            if cmd == .stopDischarge, heldWhenAsked == nil { heldWhenAsked = self.client.state }
        }
        helper.gone = true   // nobody answers at launch
        let c = make()
        XCTAssertTrue(c.isWaitingToStart)
        XCTAssertTrue(helper.waited.contains(.stopDischarge), "the debt was not asked about at launch")
        XCTAssertEqual(heldWhenAsked?.mclLimit, 85, "the debt was asked about after macOS was put back, not first")
        XCTAssertTrue(settings.chargeCutUnconfirmed, "a stop nobody answered settled the debt")
        XCTAssertNotNil(c.offWarning, "an unconfirmed discharge end is not shown during the delay")

        // The helper is back: the next ask settles it, with the delay still running and nothing discharged.
        helper.gone = false
        helper.available = true
        c.retryOwedStopWhileOff()
        XCTAssertFalse(settings.chargeCutUnconfirmed, "the debt was not paid during the delay")
        XCTAssertNil(c.offWarning)
        XCTAssertTrue(c.isWaitingToStart)
        XCTAssertTrue(discharges(helper.commands).isEmpty, "a discharge was started during the delay")

        // After it, the discharge that is wanted is started.
        c.resumeIfDue(now: afterTheDelay)
        XCTAssertFalse(discharges(helper.commands).isEmpty, "Charge Control did not start after the delay")
    }

    /// A debt still owed when the delay ends is paid first, as at any launch.
    func testADebtStillOwedWhenTheDelayEndsIsPaidFirst() {
        crashedWhileHolding(limit: 85)
        settings.chargeCutUnconfirmed = true
        helper.gone = true
        let c = make()
        XCTAssertTrue(settings.chargeCutUnconfirmed)
        helper.gone = false
        helper.available = true
        let before = helper.commands.count
        c.resumeIfDue(now: afterTheDelay)
        XCTAssertEqual(helper.commands.dropFirst(before).first, .stopDischarge, "\(helper.commands)")
        XCTAssertFalse(settings.chargeCutUnconfirmed)
    }

    /// The battery card is told what Charge Control holds. During the delay it holds nothing.
    func testTheMonitorIsToldNothingIsHeldDuringTheDelay() {
        crashedWhileHolding(limit: 85)
        let c = make()
        XCTAssertNil(ChargeController.limitForMonitor(settings: settings, inForce: limitInForce),
                     "the card was told a limit is held while it is lifted")
        c.resumeIfDue(now: afterTheDelay)
        XCTAssertEqual(ChargeController.limitForMonitor(settings: settings, inForce: limitInForce), 85)
        c.shutdown()
    }

    /// Only a launch takes the unclean route. A record that is there when the person switches Charge Control on by
    /// hand (a switch-off macOS refused) does not make the start wait.
    func testSwitchingOnByHandWithARecordStillThereStartsAtOnce() {
        settings.chargeRestoreRecord = ChargeController.encodeRecord(found)
        client.state = NativeChargeState(mclEnabled: true, mclLimit: 80, optimizedChargingEnabled: false)
        client.succeeds = false
        let c = make(enabled: false)
        XCTAssertNotNil(settings.chargeRestoreRecord, "the refused put-back at launch cleared the record")
        client.succeeds = true
        settings.chargeControlEnabled = true
        XCTAssertFalse(c.isWaitingToStart)
        XCTAssertEqual(client.state?.mclLimit, 80)
        XCTAssertEqual(record, found, "the first record was replaced")
        XCTAssertTrue(helper.following)
    }

    /// With Charge Control off a record left over is put back once, as before: no delay, nothing starts.
    func testALeftoverRecordWhileOffIsNotTheUncleanRoute() {
        settings.chargeRestoreRecord = ChargeController.encodeRecord(found)
        client.state = NativeChargeState(mclEnabled: true, mclLimit: 80, optimizedChargingEnabled: false)
        let c = make(enabled: false)
        XCTAssertFalse(c.isWaitingToStart)
        XCTAssertEqual(c.status, .off)
        XCTAssertEqual(client.state, found)
        XCTAssertFalse(lines.contains { $0.contains("did not quit cleanly") })
    }

    /// An unreadable record is put back as macOS's defaults, as at any put-back, and the launch waits all the same.
    func testALaunchAfterACrashPutsBackTheDefaultsForAnUnreadableRecord() {
        settings.chargeRestoreRecord = "{not a record"
        client.state = NativeChargeState(mclEnabled: true, mclLimit: 85, optimizedChargingEnabled: false)
        let c = make()
        XCTAssertEqual(client.state, ChargeController.defaultRecord)
        XCTAssertNil(settings.chargeRestoreRecord)
        XCTAssertTrue(c.isWaitingToStart)
        XCTAssertTrue(lines.contains { $0.contains("could not be read") && $0.contains("defaults") },
                      lines.joined(separator: "\n"))
    }

    /// A Mac with no client has nothing to lift: the section says so, and there is nothing to wait for.
    func testALaunchAfterACrashOnAMacWithNoClientSaysUnavailable() {
        settings.chargeRestoreRecord = ChargeController.encodeRecord(found)
        clientToMake = nil
        let c = make()
        XCTAssertEqual(c.status, .unavailable(ChargeController.unavailableText))
        XCTAssertFalse(c.isWaitingToStart)
    }

    /// A limit macOS refuses to take back at launch: the record stays (the next launch tries again), the delay runs
    /// all the same, and what starts after it keeps the first record.
    func testALiftThatMacOSRefusesKeepsTheRecordAndTheDelayStillRuns() {
        crashedWhileHolding(limit: 85)
        client.succeeds = false
        let c = make()
        XCTAssertNotNil(settings.chargeRestoreRecord)
        XCTAssertTrue(c.isWaitingToStart)
        XCTAssertTrue(lines.contains { $0.contains("record is kept") }, lines.joined(separator: "\n"))
        client.succeeds = true
        c.resumeIfDue(now: afterTheDelay)
        XCTAssertEqual(record, found, "the record was replaced by a state Charge Control made")
        XCTAssertEqual(client.state?.mclLimit, 85)
    }

    /// The limit in force for other threads to read (the battery card, on the monitor's queue): the hold while
    /// one is in force, nil while off.
    func testTheLimitInForceIsPublished() {
        settings.chargeHeatProtectionEnabled = true
        battery = Self.state(24, temperature: 40)
        let c = make()
        let read = { () -> Int? in
            var v: Int?
            DispatchQueue.global().sync { v = self.limitInForce.value }
            return v
        }
        XCTAssertEqual(read(), 24)
        c.pressTopUp()
        XCTAssertEqual(read(), 100)
        settings.chargeControlEnabled = false
        XCTAssertNil(read())
    }

    /// What the monitor is given: the limit in force when it is known, else the setting; nothing while off.
    func testTheMonitorIsToldTheLimitInForce() {
        let box = ChargeLimitInForce()
        settings.chargeControlEnabled = true
        settings.chargeLimit = 80
        XCTAssertEqual(ChargeController.limitForMonitor(settings: settings, inForce: box), 80)
        box.set(100)
        XCTAssertEqual(ChargeController.limitForMonitor(settings: settings, inForce: box), 100)
        settings.chargeControlEnabled = false
        XCTAssertNil(ChargeController.limitForMonitor(settings: settings, inForce: box))
    }

    // ── Uninstalling from a script ──────────────────────────────────────────

    /// `uninstall.sh` runs the app with no window to put macOS back. With the setting on (as the app left it),
    /// nothing is switched on first: the record is put back, the debt settled, the setting turned off, and the
    /// answer says whether anything is left.
    func testTheHeadlessRestorePutsBackWithoutStartingAnything() {
        let found = NativeChargeState(mclEnabled: true, mclLimit: 90, optimizedChargingEnabled: true)
        settings.chargeRestoreRecord = ChargeController.encodeRecord(found)
        settings.chargeControlEnabled = true
        settings.chargeCutUnconfirmed = true
        client.state = NativeChargeState(mclEnabled: true, mclLimit: 80, optimizedChargingEnabled: false)
        let ok = ChargeController.restoreForUninstall(settings: settings, makeClient: { [weak self] in
            self?.clientsMade += 1
            return self?.client
        }, helper: helper, log: { [weak self] in self?.lines.append($0) })
        XCTAssertTrue(ok)
        XCTAssertEqual(client.state, found)
        XCTAssertEqual(client.optimizedChargingCalls, [true], "Charge Control was switched on before it was put back")
        XCTAssertNil(settings.chargeRestoreRecord)
        XCTAssertFalse(settings.chargeControlEnabled)
        XCTAssertFalse(settings.chargeCutUnconfirmed)
        XCTAssertEqual(helper.waited.first, .stopDischarge)
        XCTAssertEqual(helper.follows, 0)
        XCTAssertEqual(clientsMade, 1)
    }

    func testTheHeadlessRestoreSaysWhenSomethingIsLeft() {
        settings.chargeRestoreRecord = ChargeController.encodeRecord(
            NativeChargeState(mclEnabled: true, mclLimit: 90, optimizedChargingEnabled: true))
        client.succeeds = false
        XCTAssertFalse(ChargeController.restoreForUninstall(settings: settings, makeClient: { [weak self] in
            self?.client
        }, helper: helper, log: { _ in }))
        XCTAssertNotNil(settings.chargeRestoreRecord)

        // No record, and a debt nobody answers.
        settings.chargeRestoreRecord = nil
        client.succeeds = true
        settings.chargeCutUnconfirmed = true
        helper.gone = true
        XCTAssertFalse(ChargeController.restoreForUninstall(settings: settings, makeClient: { [weak self] in
            self?.client
        }, helper: helper, log: { _ in }), "a debt nobody answered was reported as settled")
        XCTAssertTrue(settings.chargeCutUnconfirmed)
    }

    /// Nothing to put back is success.
    func testTheHeadlessRestoreWithNothingToDoSucceeds() {
        XCTAssertTrue(ChargeController.restoreForUninstall(settings: settings, makeClient: { [weak self] in
            self?.clientsMade += 1
            return self?.client
        }, helper: helper, log: { _ in }))
        XCTAssertEqual(clientsMade, 0)
        XCTAssertTrue(helper.commands.isEmpty)
    }

    // ── Restoring a limit only the helper can set ───────────────────────────

    /// A record of 45 (set by another tool before Charge Control ran) put back while off: the helper is greeted for
    /// it, the restore waits for it, and the record goes only once 45 itself landed.
    func testARestoreOfALimitOnlyTheHelperCanSetGreetsTheHelper() {
        settings.chargeRestoreRecord = ChargeController.encodeRecord(
            NativeChargeState(mclEnabled: true, mclLimit: 45, optimizedChargingEnabled: true))
        helper.available = false   // nothing has greeted it this run
        helper.landsOn = client
        make(enabled: false)
        XCTAssertEqual(helper.waited, [.setChargeLimit(45)])
        XCTAssertEqual(client.state?.mclLimit, 45)
        XCTAssertNil(settings.chargeRestoreRecord)
    }

    /// When 45 cannot land (no helper installed), macOS is set to the nearest value at or above it, so the Mac can
    /// charge at least that far. That is the best this Mac can do, so the record is cleared and the line says what
    /// was put back and what could not be, once (the record was once kept, and every launch then waited 60 s).
    func testARestoreThatCannotLandWithNoHelperInstalledIsTheBestThereIsAndClearsTheRecord() {
        settings.chargeRestoreRecord = ChargeController.encodeRecord(
            NativeChargeState(mclEnabled: true, mclLimit: 45, optimizedChargingEnabled: true))
        helper.available = false
        helper.installed = false
        make(enabled: false)
        XCTAssertTrue(helper.commands.isEmpty)
        XCTAssertEqual(client.state?.mclLimit, 80)
        XCTAssertNil(settings.chargeRestoreRecord, "the record was kept for a restore nothing will ever complete")
        XCTAssertEqual(lines.filter { $0.contains("45") && $0.contains("needs the helper") }.count, 1,
                       lines.joined(separator: "\n"))
    }

    /// A record lost while Charge Control is on (removed by hand, say) does not leave Charge Control's settings in
    /// force: switching off puts back macOS's defaults, as for a record that cannot be read.
    func testALostRecordPutsBackMacOSDefaults() {
        client.state = NativeChargeState(mclEnabled: true, mclLimit: 90, optimizedChargingEnabled: true)
        make()
        settings.chargeRestoreRecord = nil
        settings.chargeControlEnabled = false
        XCTAssertEqual(client.state, ChargeController.defaultRecord)
        XCTAssertTrue(lines.contains { $0.contains("no record") && $0.contains("defaults") },
                      lines.joined(separator: "\n"))
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

    /// A hold below what macOS takes by itself needs the helper as much as a limit does; with the person's limit at
    /// 80 the status must not talk about "limits other than 80". It says which feature could not pause, where, and
    /// that charging goes on.
    func testAHoldTheHelperIsNeededForSaysWhichFeature() {
        helper.available = false
        settings.chargeHeatProtectionEnabled = true
        battery = Self.state(63, temperature: 40)
        let c = make()
        XCTAssertEqual(c.status, .needsHelper(ChargeController.limitNeedsHelperText(
            for: ChargeDecision(osLimit: 63, dischargeTo: nil, reason: .heat))))
        let heat = ChargeControlFeature.statusText(c.status)
        XCTAssertTrue(heat.contains("heat") && heat.contains("63%") && heat.contains("80%"), heat)
        XCTAssertFalse(heat.contains("Limits other than"), heat)

        settings.chargeHeatProtectionEnabled = false
        settings.chargeStopWhenSleeping = true
        c.willSleep()
        let asleep = ChargeControlFeature.statusText(c.status)
        XCTAssertTrue(asleep.contains("sleeps") && asleep.contains("63%"), asleep)
        c.didWake()

        settings.chargeSailingEnabled = true
        battery = Self.state(80)
        c.tick()
        battery = Self.state(77)
        c.tick()
        let sailing = ChargeControlFeature.statusText(c.status)
        XCTAssertTrue(sailing.contains("Sailing") && sailing.contains("77%"), sailing)

        settings.chargeSailingEnabled = false
        settings.chargeLimit = 63
        XCTAssertEqual(c.status, .needsHelper(ChargeController.limitNeedsHelperText))
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

    /// While Anode's own cut is on, macOS can say the Mac is off the adapter (measured with no macOS limit holding the
    /// battery); the adapter's own details say it is still there. That is not an unplug, and must not end the
    /// discharge.
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

    /// A new target is a stop and then a start: the charger is reconnected, and that confirmed, before it is cut
    /// again for the new target (the helper would re-cut over a running discharge without it).
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

    /// Measured: a helper that dies leaves the charger cut, and nothing but a fresh helper switches it back on. So a
    /// stop answered "stopped answering" is not a discharge that ended: it is asked again at once (the link opens a
    /// new connection, which starts a fresh helper), then on every tick, with a warning, until a helper that is
    /// running says the charger is connected. The debt is written down before the discharge is even asked for.
    func testAStopThatFindsTheHelperGoneIsNotTakenForEnded() {
        battery = Self.state(90)
        var flagWhenSent: [Bool] = []
        helper.beforeSend = { [weak self] cmd in
            if case .discharge = cmd { flagWhenSent.append(self?.settings.chargeCutUnconfirmed ?? false) }
        }
        let c = make()
        c.pressDischarge()
        XCTAssertEqual(flagWhenSent, [true], "the discharge was asked for before the debt was written down")

        helper.gone = true
        c.pressDischarge()   // Stop, moments after the helper died
        XCTAssertEqual(helper.commands, [.discharge(toPercent: 80), .stopDischarge, .stopDischarge],
                       "a stop that found the helper gone was not sent again at once")
        XCTAssertTrue(settings.chargeCutUnconfirmed, "a stop nobody answered cleared the debt")
        XCTAssertNil(c.dischargeInForce)
        XCTAssertEqual(c.status, .warning(ChargeController.cutWarningText))
        XCTAssertEqual(helper.openRequests.last, true, "the connection was let go with the charger perhaps still cut")

        c.tick()
        c.periodicTick()
        XCTAssertEqual(helper.stops(), 4, "not asked again on every tick")
        XCTAssertEqual(c.status, .warning(ChargeController.cutWarningText))

        helper.gone = false
        helper.available = true
        c.tick()
        XCTAssertEqual(helper.stops(), 5)
        XCTAssertFalse(settings.chargeCutUnconfirmed, "a helper said the charger is connected, and the debt stayed")
        XCTAssertEqual(c.status, .active(ChargeDecision(osLimit: 80, dischargeTo: nil, reason: .limit)))
        c.tick()
        c.periodicTick()
        XCTAssertEqual(helper.stops(), 5, "asked again after a helper had answered")
        XCTAssertEqual(helper.openRequests.last, false)
    }

    /// Once a tick, however many times the tick applies the decision: an answer that comes back inside the tick (a
    /// limit the helper set) applies it again, and must not ask about the cut a second time.
    func testALostCutIsAskedAboutOnceATick() {
        settings.chargeLimit = 63
        battery = Self.state(90)
        let c = make()
        c.pressDischarge()
        helper.answer = { cmd in
            cmd == .stopDischarge ? FanReply(ok: false, message: HelperConnection.stoppedAnswering)
                                  : FanReply(ok: true, message: "ok")
        }
        c.pressDischarge()   // Stop: not answered, so the cut is lost
        XCTAssertEqual(c.status, .warning(ChargeController.cutWarningText))
        let before = helper.stops()
        settings.chargeLimit = 64   // one tick, in which the helper also sets a limit and answers inside it
        XCTAssertTrue(helper.commands.contains(.setChargeLimit(64)))
        XCTAssertEqual(helper.stops(), before + 1, "a lost cut was asked about more than once in one tick")
    }

    /// The same for a discharge that went out just as the helper died: it may have cut the charger before it went.
    func testADischargeThatFindsTheHelperGoneIsStoppedNotForgotten() {
        battery = Self.state(90)
        helper.gone = true
        let c = make()
        c.pressDischarge()
        XCTAssertEqual(helper.commands.first, .discharge(toPercent: 80))
        XCTAssertTrue(helper.commands.dropFirst().contains(.stopDischarge), "\(helper.commands)")
        XCTAssertTrue(settings.chargeCutUnconfirmed)
        XCTAssertEqual(c.status, .warning(ChargeController.cutWarningText))
    }

    /// With no helper installed as a daemon, nothing starts a fresh one, and unplugging does not undo the cut: the
    /// warning says what does.
    func testAWarningWithNoInstalledHelperSaysHowToRecover() {
        battery = Self.state(90)
        let c = make()
        c.pressDischarge()
        helper.gone = true
        helper.installed = false
        c.pressDischarge()
        XCTAssertEqual(c.status, .warning(ChargeController.cutWarningNoHelperText))
        let text = ChargeController.cutWarningNoHelperText
        XCTAssertTrue(text.contains("unplugging"), text)
        XCTAssertTrue(text.contains("Install Helper\u{2026}"), text)
        XCTAssertFalse(text.contains("Fans tab"), "the Fans tab has no button for this with fan control off: " + text)
    }

    /// The safety net. macOS saying the Mac is off the adapter while the adapter is there is what a charger cut looks
    /// like; with no discharge in force for more than 90 s it is taken for a cut left behind. The helper is asked to
    /// reconnect and the warning shows; once a running helper says the charger is connected, the same stretch is not
    /// asked about again.
    func testACutWithNoDischargeInForceIsTreatedAsOrphaned() {
        let t0 = Date()
        battery = Self.state(70, ac: false, adapter: true)
        let c = make()
        c.tick(now: t0.addingTimeInterval(60))
        XCTAssertEqual(helper.stops(), 0, "a minute is still how long macOS takes after a discharge")
        XCTAssertNotEqual(c.status, .warning(ChargeController.cutWarningText))

        helper.gone = true
        c.tick(now: t0.addingTimeInterval(91))
        XCTAssertGreaterThan(helper.stops(), 0, "a cut nobody holds was left alone")
        XCTAssertEqual(c.status, .warning(ChargeController.cutWarningText))

        helper.gone = false
        helper.available = true
        c.tick(now: t0.addingTimeInterval(121))
        XCTAssertNotEqual(c.status, .warning(ChargeController.cutWarningText))
        let asked = helper.stops()
        c.tick(now: t0.addingTimeInterval(400))
        c.periodicTick(now: t0.addingTimeInterval(600))
        XCTAssertEqual(helper.stops(), asked, "the helper was woken again over the same stretch")

        // A real unplug and plug starts a new stretch.
        battery = Self.state(70, ac: false, adapter: false)
        c.tick(now: t0.addingTimeInterval(610))
        battery = Self.state(70, ac: false, adapter: true)
        c.tick(now: t0.addingTimeInterval(620))
        c.tick(now: t0.addingTimeInterval(715))
        XCTAssertEqual(helper.stops(), asked + 1)
    }

    /// A stop answered "the charger switch holds a value Anode did not write" settles the debt (it is not Anode's
    /// cut: Anode keeps a cut only when it reads back exactly 0x08), but it is not "the charger is connected". It is
    /// logged once, in its own words, however many stops hear it.
    func testAValueAnodeDidNotWriteIsLoggedOnceAndNeverCalledConnected() {
        let foreign = ChargeRelease.Result(.unrecognised(0x04), writes: 0).message
        helper.answer = { cmd in
            FanReply(ok: true, message: cmd == .stopDischarge ? foreign : "ok")
        }
        settings.chargeCutUnconfirmed = true
        let t0 = Date()
        battery = Self.state(70, ac: false, adapter: true)
        let c = make()   // the debt from last time is paid first, which answers this stretch of the cut look
        XCTAssertFalse(settings.chargeCutUnconfirmed)
        // Then the net, over the next stretch.
        battery = Self.state(70, ac: false, adapter: false)
        c.tick(now: t0.addingTimeInterval(100))
        battery = Self.state(70, ac: false, adapter: true)
        c.tick(now: t0.addingTimeInterval(110))
        c.tick(now: t0.addingTimeInterval(205))
        XCTAssertEqual(helper.stops(), 2)
        XCTAssertEqual(lines.filter { $0.contains(ChargeRelease.notAnodesValue) }.count, 1, lines.joined(separator: "\n"))
        XCTAssertFalse(lines.contains { $0.contains("charger is connected") }, lines.joined(separator: "\n"))
    }

    // ── What else settles the debt ──────────────────────────────────────────

    /// A discharge running, then the helper uninstalled under it (the Fans tab's button): the stop finds nobody.
    private func lostUnderAnUninstall() -> ChargeController {
        battery = Self.state(90)
        let c = make()
        c.pressDischarge()
        helper.gone = true
        helper.installed = false
        c.pressDischarge()   // Stop
        XCTAssertEqual(c.status, .warning(ChargeController.cutWarningNoHelperText))
        XCTAssertTrue(settings.chargeCutUnconfirmed)
        return c
    }

    /// The helper's uninstall reconnects the charger itself, and fails when it could not. One that finished settles
    /// the debt and the warning, and the stop is not asked again: no helper is left to answer it, ever.
    func testAHelperUninstallThatFinishedSettlesTheDebtWhileOn() {
        let c = lostUnderAnUninstall()
        c.helperUninstalled()
        XCTAssertFalse(settings.chargeCutUnconfirmed)
        XCTAssertEqual(c.status, .active(ChargeDecision(osLimit: 80, dischargeTo: nil, reason: .limit)))
        let asked = helper.stops()
        c.tick()
        c.periodicTick()
        XCTAssertEqual(helper.stops(), asked, "the stop was asked again after the uninstall reconnected the charger")
    }

    /// The same while off: the flag goes, the section is told, and the retry ends.
    func testAHelperUninstallThatFinishedSettlesTheDebtWhileOff() {
        settings.chargeCutUnconfirmed = true
        helper.gone = true
        let c = make(enabled: false)
        XCTAssertEqual(helper.stops(), 1)
        var heard = 0
        let token = c.observeChanges { heard += 1 }
        c.helperUninstalled()
        XCTAssertFalse(settings.chargeCutUnconfirmed)
        XCTAssertNil(c.offWarning)
        XCTAssertGreaterThan(heard, 0, "the section was not told")
        c.retryOwedStopWhileOff()
        XCTAssertEqual(helper.stops(), 1, "the stop was asked again after the uninstall reconnected the charger")
        withExtendedLifetime(token) {}
    }

    /// A stop still on its way when the uninstall finished is answered "stopped answering" after it. That answer is
    /// about a helper the uninstall has dealt with, and does not bring the warning back.
    func testAStopAnsweredAfterTheUninstallDoesNotBringTheWarningBack() {
        battery = Self.state(90)
        let c = make()
        c.pressDischarge()
        helper.deferReplies = true
        helper.answer = { _ in FanReply(ok: false, message: HelperConnection.stoppedAnswering) }
        c.pressDischarge()   // Stop, on its way
        helper.installed = false
        c.helperUninstalled()
        helper.flushReplies()
        XCTAssertFalse(settings.chargeCutUnconfirmed)
        XCTAssertEqual(c.status, .active(ChargeDecision(osLimit: 80, dischargeTo: nil, reason: .limit)))
    }

    /// Evidence the charger IS connected settles everything, with no helper left to answer a stop. On a Mac whose
    /// charger switch cannot be read (as here, and in every test that does not set `chargerSwitch`), that is macOS
    /// saying the Mac is on the adapter (its own flag, not the adapter's details, which a cut leaves as they were)
    /// for more than 90 s, with no discharge in force or on its way. It is the weaker evidence: measured, a cut
    /// leaves that flag at yes while a macOS limit below the battery level is in force. See "The charger switch
    /// itself" below for a Mac whose switch can be read.
    func testMacOSSayingOnTheAdapterForLongEnoughSettlesTheDebt() {
        let c = lostUnderAnUninstall()
        XCTAssertNil(chargerSwitch)
        let t0 = Date()
        c.tick(now: t0)
        c.tick(now: t0.addingTimeInterval(60))
        XCTAssertTrue(settings.chargeCutUnconfirmed, "a minute is not long enough")
        XCTAssertEqual(c.status, .warning(ChargeController.cutWarningNoHelperText))
        c.tick(now: t0.addingTimeInterval(91))
        XCTAssertFalse(settings.chargeCutUnconfirmed)
        XCTAssertEqual(c.status, .active(ChargeDecision(osLimit: 80, dischargeTo: nil, reason: .limit)))
        let asked = helper.stops()
        c.tick(now: t0.addingTimeInterval(120))
        c.periodicTick(now: t0.addingTimeInterval(150))
        XCTAssertEqual(helper.stops(), asked, "the stop was asked again after macOS showed the charger connected")
    }

    /// The same with a helper installed that is not answering: the evidence does not need one.
    func testTheEvidenceNeedsNoHelper() {
        battery = Self.state(90)
        let c = make()
        c.pressDischarge()
        helper.gone = true
        c.pressDischarge()
        XCTAssertEqual(c.status, .warning(ChargeController.cutWarningText))
        let t0 = Date()
        c.tick(now: t0)
        c.tick(now: t0.addingTimeInterval(91))
        XCTAssertFalse(settings.chargeCutUnconfirmed)
        XCTAssertNotEqual(c.status, .warning(ChargeController.cutWarningText))
    }

    /// Only macOS's own "on the adapter" counts, and it must last: the adapter's details say yes all through a cut,
    /// and one reading of "off the adapter" starts the 90 s again.
    func testOnlyMacOSsOwnOnTheAdapterCountsAndItMustLast() {
        let c = lostUnderAnUninstall()
        let t0 = Date()
        battery = Self.state(90, ac: false, adapter: true)
        c.tick(now: t0)
        c.tick(now: t0.addingTimeInterval(200))
        XCTAssertTrue(settings.chargeCutUnconfirmed, "the adapter's details were taken for a connected charger")
        battery = Self.state(90)
        c.tick(now: t0.addingTimeInterval(210))
        battery = Self.state(90, ac: false, adapter: true)
        c.tick(now: t0.addingTimeInterval(260))
        battery = Self.state(90)
        c.tick(now: t0.addingTimeInterval(270))
        c.tick(now: t0.addingTimeInterval(330))
        XCTAssertTrue(settings.chargeCutUnconfirmed, "the 90 s did not start again")
        c.tick(now: t0.addingTimeInterval(361))
        XCTAssertFalse(settings.chargeCutUnconfirmed)
    }

    /// A discharge in force is never evidence however long macOS says "on the adapter": it may cut the charger at any
    /// moment. Were it taken for evidence the debt would be settled under a discharge that is still running, and the
    /// same tick would send the discharge again and write the debt again, so the flag cannot show it. What shows it:
    /// the line that says the debt was settled, and a second discharge going out.
    func testADischargeInForceIsNeverEvidence() {
        battery = Self.state(90)
        let t0 = Date()
        let c = make()
        c.pressDischarge()
        XCTAssertEqual(c.dischargeInForce, 80)
        let sent = helper.commands
        c.tick(now: t0.addingTimeInterval(1))
        c.tick(now: t0.addingTimeInterval(200))
        c.tick(now: t0.addingTimeInterval(400))
        XCTAssertTrue(settings.chargeCutUnconfirmed)
        XCTAssertEqual(c.dischargeInForce, 80)
        XCTAssertEqual(helper.commands, sent, "a discharge in force was settled by macOS's word, and sent again")
        XCTAssertFalse(lines.contains { $0.contains("with no discharge running") }, lines.joined(separator: "\n"))
    }

    /// One on its way is not evidence either. The request is cancelled while it is on its way, so that nothing asks
    /// again: a discharge still wanted would be sent again after the debt was settled, and written down again, and the
    /// flag would read true whether or not the guard held.
    func testADischargeOnItsWayIsNeverEvidence() {
        battery = Self.state(90)
        let t0 = Date()
        let c = make()
        helper.deferReplies = true
        c.pressDischarge()   // asked, and not answered yet
        XCTAssertTrue(settings.chargeCutUnconfirmed)
        c.pressDischarge()   // cancelled while on its way: nothing wants one now
        c.tick(now: t0.addingTimeInterval(300))
        c.tick(now: t0.addingTimeInterval(500))
        XCTAssertTrue(settings.chargeCutUnconfirmed, "a discharge on its way was settled by macOS's word")
        XCTAssertFalse(lines.contains { $0.contains("with no discharge running") }, lines.joined(separator: "\n"))
    }

    // ── The charger switch itself ───────────────────────────────────────────
    //
    // Measured on Mac17,9, macOS 27.0. With a macOS charge limit below the battery level in force (limit 63, battery
    // 100), the charger switch read cut for 50 s and macOS said "on the adapter" the whole time. With no limit in
    // force, the same cut made macOS say "off the adapter" within 1 to 2 s. So macOS's word is not proof either
    // way, and where the switch itself can be read (reading it needs no root) it is what counts.

    /// macOS saying "on the adapter" does not settle the debt while the switch reads cut, however long it says so.
    func testMacOSsWordDoesNotSettleTheDebtWhileTheSwitchReadsCut() {
        let c = lostUnderAnUninstall()
        chargerSwitch = AdapterCutKey.cut
        let t0 = Date()
        c.tick(now: t0)
        c.tick(now: t0.addingTimeInterval(91))
        c.tick(now: t0.addingTimeInterval(400))
        XCTAssertTrue(settings.chargeCutUnconfirmed, "the debt was settled on macOS's word, over a switch reading cut")
        XCTAssertEqual(c.status, .warning(ChargeController.cutWarningNoHelperText))

        // Nor on a value Anode never writes: only connected is connected.
        chargerSwitch = 0x04
        c.tick(now: t0.addingTimeInterval(410))
        c.tick(now: t0.addingTimeInterval(600))
        XCTAssertTrue(settings.chargeCutUnconfirmed)
        XCTAssertEqual(c.status, .warning(ChargeController.cutWarningNoHelperText))
    }

    /// The switch reading connected for more than 90 s, with no discharge in force or on its way, settles it; one
    /// reading of anything else starts the 90 s again.
    func testTheSwitchReadingConnectedForLongEnoughSettlesTheDebt() {
        let c = lostUnderAnUninstall()
        chargerSwitch = AdapterCutKey.connected
        let t0 = Date()
        c.tick(now: t0)
        chargerSwitch = AdapterCutKey.cut
        c.tick(now: t0.addingTimeInterval(50))
        chargerSwitch = AdapterCutKey.connected
        c.tick(now: t0.addingTimeInterval(60))
        c.tick(now: t0.addingTimeInterval(140))
        XCTAssertTrue(settings.chargeCutUnconfirmed, "the 90 s did not start again")
        XCTAssertEqual(c.status, .warning(ChargeController.cutWarningNoHelperText))
        c.tick(now: t0.addingTimeInterval(151))
        XCTAssertFalse(settings.chargeCutUnconfirmed)
        XCTAssertEqual(c.status, .active(ChargeDecision(osLimit: 80, dischargeTo: nil, reason: .limit)))
        XCTAssertTrue(lines.contains { $0.contains("the charger switch has read connected") },
                      lines.joined(separator: "\n"))
        let asked = helper.stops()
        c.tick(now: t0.addingTimeInterval(180))
        c.periodicTick(now: t0.addingTimeInterval(210))
        XCTAssertEqual(helper.stops(), asked, "the stop was asked again after the switch showed the charger connected")
    }

    /// Where the switch can be read, it is the evidence whatever macOS says: connected settles the debt even while
    /// macOS says the Mac is off the adapter.
    func testTheSwitchSettlesTheDebtWhateverMacOSSays() {
        let c = lostUnderAnUninstall()
        chargerSwitch = AdapterCutKey.connected
        battery = Self.state(90, ac: false, adapter: true)
        let t0 = Date()
        c.tick(now: t0)
        c.tick(now: t0.addingTimeInterval(91))
        XCTAssertFalse(settings.chargeCutUnconfirmed)
        XCTAssertNotEqual(c.status, .warning(ChargeController.cutWarningNoHelperText))
    }

    /// A discharge on its way is never evidence, however long the switch has read connected before it cuts. Cancelled
    /// while on its way, as in `testADischargeOnItsWayIsNeverEvidence`, so that nothing asks again.
    func testTheSwitchIsNotEvidenceWhileADischargeIsOnItsWay() {
        battery = Self.state(90)
        chargerSwitch = AdapterCutKey.connected
        let t0 = Date()
        let c = make()
        helper.deferReplies = true
        c.pressDischarge()   // asked, and not answered yet
        XCTAssertTrue(settings.chargeCutUnconfirmed)
        c.pressDischarge()   // cancelled while on its way
        c.tick(now: t0.addingTimeInterval(100))
        c.tick(now: t0.addingTimeInterval(300))
        XCTAssertTrue(settings.chargeCutUnconfirmed, "a discharge on its way was settled by the switch")
        XCTAssertFalse(lines.contains { $0.contains("with no discharge running") }, lines.joined(separator: "\n"))
    }

    /// Nor is one in force: the switch is not even read under it, and nothing is settled.
    func testTheSwitchIsNotEvidenceWhileADischargeIsInForce() {
        battery = Self.state(90)
        chargerSwitch = AdapterCutKey.connected
        let t0 = Date()
        let c = make()
        c.pressDischarge()
        XCTAssertEqual(c.dischargeInForce, 80)
        let sent = helper.commands
        c.tick(now: t0.addingTimeInterval(100))
        c.tick(now: t0.addingTimeInterval(300))
        XCTAssertTrue(settings.chargeCutUnconfirmed)
        XCTAssertEqual(c.dischargeInForce, 80)
        XCTAssertEqual(helper.commands, sent, "a discharge in force was settled by the switch, and sent again")
        XCTAssertFalse(lines.contains { $0.contains("with no discharge running") }, lines.joined(separator: "\n"))
    }

    /// A discharge sent starts the count of evidence again: whatever was read before it says nothing about what it
    /// does. The first request is refused, which leaves the debt (a refused or unanswered request may have cut the
    /// charger all the same) and no discharge on its way or in force, so nothing else stops the count; a second, for
    /// another target, is refused too. Ninety-one seconds after the first count began is then not enough.
    func testADischargeSentStartsTheCountOfConnectedAgain() {
        battery = Self.state(90)
        chargerSwitch = AdapterCutKey.connected
        helper.answer = { cmd in
            if case .discharge = cmd { return FanReply(ok: false, message: "refused: not now") }
            return FanReply(ok: true, message: "ok")
        }
        let t0 = Date()
        let c = make()
        c.pressDischarge()
        XCTAssertTrue(settings.chargeCutUnconfirmed, "a refused request left no debt")
        XCTAssertNil(c.dischargeInForce)
        c.tick(now: t0.addingTimeInterval(10))   // the count of connected begins here
        settings.chargeLimit = 85                // another target: asked again, and refused again
        XCTAssertEqual(discharges(helper.commands), [80, 85])
        c.tick(now: t0.addingTimeInterval(101))  // 91 s after the first count began, 0 s after the second
        XCTAssertTrue(settings.chargeCutUnconfirmed, "a discharge sent did not start the count again")
        c.tick(now: t0.addingTimeInterval(150))
        XCTAssertTrue(settings.chargeCutUnconfirmed)
        c.tick(now: t0.addingTimeInterval(192))  // 91 s after the second count began
        XCTAssertFalse(settings.chargeCutUnconfirmed)
    }

    /// The net, by the switch. Cut, with no discharge running or on its way, for more than 90 s is a cut left behind
    /// whatever macOS says (here it says "on the adapter" throughout, as measured under a limit below the battery
    /// level): the helper is asked to reconnect it and the warning shows, and macOS's word does not clear it. Once
    /// a running helper has reconnected it, nothing more is asked.
    func testASwitchLeftCutIsALeftOverCutWhateverMacOSSays() {
        let t0 = Date()
        chargerSwitch = AdapterCutKey.cut
        let c = make()
        c.tick(now: t0.addingTimeInterval(60))
        XCTAssertEqual(helper.stops(), 0, "a minute is not long enough")
        XCTAssertNotEqual(c.status, .warning(ChargeController.cutWarningText))

        helper.gone = true
        c.tick(now: t0.addingTimeInterval(91))
        XCTAssertGreaterThan(helper.stops(), 0, "a switch left cut was left alone, because macOS says on the adapter")
        XCTAssertEqual(c.status, .warning(ChargeController.cutWarningText))
        XCTAssertTrue(lines.contains { $0.contains("the charger switch has read cut") }, lines.joined(separator: "\n"))
        c.tick(now: t0.addingTimeInterval(300))
        XCTAssertEqual(c.status, .warning(ChargeController.cutWarningText), "macOS's word cleared the warning")

        helper.gone = false
        helper.available = true
        helper.answer = { [weak self] cmd in
            if cmd == .stopDischarge { self?.chargerSwitch = AdapterCutKey.connected }
            return FanReply(ok: true, message: "ok")
        }
        c.tick(now: t0.addingTimeInterval(330))
        XCTAssertNotEqual(c.status, .warning(ChargeController.cutWarningText))
        let asked = helper.stops()
        c.tick(now: t0.addingTimeInterval(400))
        c.periodicTick(now: t0.addingTimeInterval(600))
        XCTAssertEqual(helper.stops(), asked, "the helper was woken again with the switch reading connected")
    }

    /// A discharge in force is the cut, not one left behind, however long the switch reads cut; and nothing reads
    /// the switch under it.
    func testADischargeInForceIsNotALeftOverCutByTheSwitch() {
        let t0 = Date()
        battery = Self.state(90)
        chargerSwitch = AdapterCutKey.connected
        let c = make()
        c.pressDischarge()
        chargerSwitch = AdapterCutKey.cut
        let reads = switchReads
        c.tick(now: t0.addingTimeInterval(200))
        c.tick(now: t0.addingTimeInterval(400))
        c.periodicTick(now: t0.addingTimeInterval(430))
        XCTAssertEqual(helper.commands, [.discharge(toPercent: 80)])
        XCTAssertEqual(c.dischargeInForce, 80)
        XCTAssertEqual(c.status, .active(ChargeDecision(osLimit: 80, dischargeTo: 80, reason: .discharging)))
        XCTAssertEqual(switchReads, reads, "the switch was read under a discharge, where nothing asks about it")
    }

    /// Nor is one on its way: the helper may have cut before its answer is back.
    func testADischargeOnItsWayIsNotALeftOverCutByTheSwitch() {
        let t0 = Date()
        battery = Self.state(90)
        chargerSwitch = AdapterCutKey.connected
        let c = make()
        helper.deferReplies = true
        c.pressDischarge()
        chargerSwitch = AdapterCutKey.cut
        c.tick(now: t0.addingTimeInterval(10))
        c.tick(now: t0.addingTimeInterval(200))
        XCTAssertEqual(helper.stops(), 0, "a discharge on its way was taken for a cut left behind")
        helper.flushReplies()
        c.tick(now: t0.addingTimeInterval(400))
        XCTAssertEqual(helper.stops(), 0)
        XCTAssertEqual(c.dischargeInForce, 80)
    }

    /// Where the switch reads connected, macOS's look of a cut (off the adapter, with the adapter there) is not one:
    /// there is nothing to reconnect, and the helper is not woken to say so. A value Anode never writes does not
    /// overrule the look.
    func testMacOSsLookOfACutIsNotOneWhileTheSwitchReadsConnected() {
        let t0 = Date()
        battery = Self.state(70, ac: false, adapter: true)
        chargerSwitch = AdapterCutKey.connected
        let c = make()
        c.tick(now: t0.addingTimeInterval(91))
        c.tick(now: t0.addingTimeInterval(400))
        XCTAssertEqual(helper.stops(), 0)
        XCTAssertNotEqual(c.status, .warning(ChargeController.cutWarningText))

        chargerSwitch = 0x04
        c.tick(now: t0.addingTimeInterval(410))
        c.tick(now: t0.addingTimeInterval(505))
        XCTAssertEqual(helper.stops(), 1)
    }

    /// The switch is read where something asks about it and nowhere else: never while off, with the cable out and
    /// nothing owed, or while another account is on screen; and once a tick, however many passes the tick makes.
    func testTheSwitchIsReadOnlyWhereItIsNeededAndOnceATick() {
        settings.chargeLimit = 63
        battery = Self.state(70, ac: false, adapter: false)
        chargerSwitch = AdapterCutKey.connected
        let c = make()
        c.tick()
        c.periodicTick()
        XCTAssertEqual(switchReads, 0, "the switch was read with the cable out and nothing owed")

        battery = Self.state(70)
        c.tick()
        XCTAssertEqual(switchReads, 1)
        // A tick the helper's news interrupts runs a second pass, and reads once all the same.
        var interrupted = false
        helper.beforeSend = { [weak self] _ in
            interrupted = true
            self?.helper.reset()
        }
        settings.chargeLimit = 64
        XCTAssertTrue(interrupted)
        XCTAssertEqual(switchReads, 2, "the switch was read more than once in one tick")
        helper.beforeSend = nil

        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        let reads = switchReads
        c.tick()
        c.periodicTick()
        XCTAssertEqual(switchReads, reads, "the switch was read for an account not on screen, with nothing owed")
    }

    /// While off nothing reads it, a debt or not.
    func testTheSwitchIsNotReadWhileOff() {
        settings.chargeCutUnconfirmed = true
        chargerSwitch = AdapterCutKey.cut
        let c = make(enabled: false)
        c.retryOwedStopWhileOff()
        c.recheckHelper()
        XCTAssertEqual(switchReads, 0)
    }

    // ── A switch that has been read and then cannot be ──────────────────────
    //
    // Once the switch has been read in this run of the app, a read that fails says nothing about the charger. It does
    // not end a stretch of reading cut, it does not make one longer, and it does not stand in for a reading of
    // connected with macOS's word. Before the first read that works, a failed read means this Mac's switch cannot be
    // read, and macOS's word is what there is (every test above that leaves `chargerSwitch` nil).

    /// A cut left behind, read as cut, cut, failed, cut: the failed read neither starts the 90 s again nor adds to
    /// them, so the net fires at the first read after 90 s, as it would with no failed read at all.
    func testAFailedReadAmongCutReadsDoesNotPutOffTheNet() {
        let t0 = Date()
        chargerSwitch = AdapterCutKey.cut
        let c = make()
        c.tick(now: t0.addingTimeInterval(30))
        chargerSwitch = nil
        c.tick(now: t0.addingTimeInterval(60))
        chargerSwitch = AdapterCutKey.cut
        c.tick(now: t0.addingTimeInterval(90))
        XCTAssertEqual(helper.stops(), 0, "90 s is not more than 90 s")
        c.tick(now: t0.addingTimeInterval(120))
        XCTAssertGreaterThan(helper.stops(), 0, "a failed read among the cut reads put the net off")
        XCTAssertTrue(lines.contains { $0.contains("the charger switch has read cut") }, lines.joined(separator: "\n"))
    }

    /// A read that fails every third tick, with the switch cut at every other, is a cut left behind all the same.
    func testAFailedReadEveryThirdTickDoesNotKeepTheNetFromFiring() {
        let t0 = Date()
        chargerSwitch = AdapterCutKey.cut
        let c = make()
        for i in 1...12 {
            chargerSwitch = i % 3 == 0 ? nil : AdapterCutKey.cut
            c.tick(now: t0.addingTimeInterval(TimeInterval(i * 30)))
        }
        XCTAssertGreaterThan(helper.stops(), 0, "a cut left behind was never found, because every third read failed")
    }

    /// A failed read is no information, so it does not fire the net either, however long the cut has been read: the
    /// first read that works after it does.
    func testAFailedReadDoesNotFireTheNetBecauseTheTimeIsUp() {
        let t0 = Date()
        chargerSwitch = AdapterCutKey.cut
        let c = make()
        chargerSwitch = nil
        c.tick(now: t0.addingTimeInterval(91))
        c.tick(now: t0.addingTimeInterval(200))
        XCTAssertEqual(helper.stops(), 0, "the net fired on a read that failed")
        XCTAssertNotEqual(c.status, .warning(ChargeController.cutWarningText))
        chargerSwitch = AdapterCutKey.cut
        c.tick(now: t0.addingTimeInterval(230))
        XCTAssertGreaterThan(helper.stops(), 0, "the cut read before the failed reads was forgotten")
    }

    /// The same for macOS's look of a cut, which is what counts where the switch reads a value Anode never writes:
    /// a failed read does not let it run on.
    func testAFailedReadDoesNotAdvanceMacOSsLookOfACut() {
        let t0 = Date()
        battery = Self.state(70, ac: false, adapter: true)
        chargerSwitch = 0x04
        let c = make()
        chargerSwitch = nil
        c.tick(now: t0.addingTimeInterval(91))
        XCTAssertEqual(helper.stops(), 0, "macOS's look of a cut ran on over a switch that could not be read")
        chargerSwitch = 0x04
        c.tick(now: t0.addingTimeInterval(121))
        XCTAssertEqual(helper.stops(), 1)
    }

    /// A debt, the switch read as cut, then reads that fail while macOS says "on the adapter" for far longer than 90
    /// s: nothing is settled, because macOS's word is no proof and the switch said nothing.
    func testFailedReadsDoNotSettleTheDebtOnMacOSsWord() {
        let c = lostUnderAnUninstall()
        chargerSwitch = AdapterCutKey.cut
        let t0 = Date()
        c.tick(now: t0)
        chargerSwitch = nil
        for seconds in [30.0, 60, 91, 200, 400] { c.tick(now: t0.addingTimeInterval(seconds)) }
        XCTAssertTrue(settings.chargeCutUnconfirmed, "the debt was settled on macOS's word over a switch last read cut")
        XCTAssertEqual(c.status, .warning(ChargeController.cutWarningNoHelperText))
        XCTAssertFalse(lines.contains { $0.contains("macOS has said the Mac is on the adapter") },
                       lines.joined(separator: "\n"))
    }

    /// Failed reads hold the count of reads of connected: they do not start it, end it or add to it, and settle
    /// nothing. The next read of connected, past the 90 s counted from the one before, settles.
    func testFailedReadsHoldTheCountOfReadsOfConnected() {
        let c = lostUnderAnUninstall()
        chargerSwitch = AdapterCutKey.connected
        let t0 = Date()
        c.tick(now: t0)
        chargerSwitch = nil
        c.tick(now: t0.addingTimeInterval(60))
        c.tick(now: t0.addingTimeInterval(120))
        XCTAssertTrue(settings.chargeCutUnconfirmed, "failed reads settled the debt")
        chargerSwitch = AdapterCutKey.connected
        c.tick(now: t0.addingTimeInterval(121))
        XCTAssertFalse(settings.chargeCutUnconfirmed, "the failed reads put the count back to nothing")
        XCTAssertTrue(lines.contains { $0.contains("the charger switch has read connected") },
                      lines.joined(separator: "\n"))
    }

    /// A switch that has never been read in this run (a Mac without one, or one that cannot be opened) goes by
    /// macOS's word, both ways. The look of a cut starts the net; the switch is still asked each tick, so a Mac whose
    /// switch comes back is noticed.
    func testASwitchNeverReadStillGoesByMacOSsLookOfACut() {
        let t0 = Date()
        battery = Self.state(70, ac: false, adapter: true)
        let c = make()
        c.tick(now: t0.addingTimeInterval(91))
        XCTAssertGreaterThan(helper.stops(), 0, "macOS's look of a cut was ignored where the switch cannot be read")
        XCTAssertGreaterThan(switchReads, 0)
    }

    /// And "on the adapter" for more than 90 s settles a debt there, as it always did.
    func testASwitchNeverReadStillGoesByMacOSsWordOnTheAdapter() {
        let c = lostUnderAnUninstall()
        let t0 = Date()
        c.tick(now: t0)
        c.tick(now: t0.addingTimeInterval(91))
        XCTAssertFalse(settings.chargeCutUnconfirmed, "macOS's word was ignored on a Mac whose switch cannot be read")
        XCTAssertGreaterThan(switchReads, 0)
    }

    /// A switch that stops answering after it answered is logged once, and so is its return; nothing per tick.
    func testALostSwitchIsLoggedOnceAndSoIsItsReturn() {
        let t0 = Date()
        chargerSwitch = AdapterCutKey.connected
        let c = make()
        let lost = { self.lines.filter { $0.contains("can no longer be read") }.count }
        let back = { self.lines.filter { $0.contains("can be read again") }.count }
        XCTAssertEqual(lost() + back(), 0)

        chargerSwitch = nil
        for i in 1...5 { c.tick(now: t0.addingTimeInterval(TimeInterval(i * 30))) }
        XCTAssertEqual(lost(), 1, lines.joined(separator: "\n"))
        XCTAssertEqual(back(), 0)

        chargerSwitch = AdapterCutKey.connected
        for i in 6...9 { c.tick(now: t0.addingTimeInterval(TimeInterval(i * 30))) }
        XCTAssertEqual(lost(), 1)
        XCTAssertEqual(back(), 1, lines.joined(separator: "\n"))

        // Lost again: a new stretch is a new line.
        chargerSwitch = nil
        c.tick(now: t0.addingTimeInterval(300))
        c.tick(now: t0.addingTimeInterval(330))
        XCTAssertEqual(lost(), 2)
    }

    /// A switch that never answered says nothing at all: it is the ordinary state of a Mac without one.
    func testASwitchThatNeverAnsweredIsNotLogged() {
        let t0 = Date()
        let c = make()
        for i in 1...5 { c.tick(now: t0.addingTimeInterval(TimeInterval(i * 30))) }
        XCTAssertTrue(lines.filter { $0.contains("charger switch") }.isEmpty, lines.joined(separator: "\n"))
    }

    /// The real reader opens its connection at the first read, and when a read fails opens a new one for the next:
    /// `SystemChargeHardware()` cannot fail (a refused open is kept inside it as no connection, for good), and a
    /// connection that dies stays dead. One open attempt per read at most, none after a read that worked.
    func testAReadThatFailsIsFollowedByAFreshConnection() {
        let charger = FakeChargeHardware(cut: false)
        var line = ChargeLine(charger)
        var opened = 0
        let read = ChargeController.systemChargerSwitch(open: {
            opened += 1
            line = ChargeLine(charger)
            return line
        })
        XCTAssertEqual(opened, 0, "the switch was opened before anything read it")
        XCTAssertEqual(read(), AdapterCutKey.connected)
        XCTAssertEqual(read(), AdapterCutKey.connected)
        XCTAssertEqual(opened, 1, "the connection was opened again with reads working")

        line.sever()
        XCTAssertNil(read(), "a dead connection read")
        XCTAssertEqual(opened, 1, "a failed read opened a connection of its own")
        XCTAssertEqual(read(), AdapterCutKey.connected, "the read after a failed one kept the old connection")
        XCTAssertEqual(opened, 2)
        XCTAssertEqual(read(), AdapterCutKey.connected)
        XCTAssertEqual(opened, 2, "a connection that works was opened again")
    }

    /// A key that cannot be read at all is asked again with a new connection each read, and no more than one.
    func testAnUnreadableSwitchIsOpenedOnceAReadAtMost() {
        let charger = FakeChargeHardware(cut: false)
        charger.cutUnreadable = true
        var opened = 0
        let read = ChargeController.systemChargerSwitch(open: {
            opened += 1
            return ChargeLine(charger)
        })
        for expected in 1...4 {
            XCTAssertNil(read())
            XCTAssertEqual(opened, expected, "more than one connection was opened for one read")
        }
        charger.cutUnreadable = false
        XCTAssertEqual(read(), AdapterCutKey.connected)
        XCTAssertEqual(opened, 5)
        XCTAssertEqual(read(), AdapterCutKey.connected)
        XCTAssertEqual(opened, 5)
    }

    /// Another account on screen: its Anode may be discharging, and the helper's socket is its own, so this one could
    /// not even ask. The net does not run there, and nothing is asserted: no stop, no warning. Back on screen, the
    /// look starts again from nothing.
    func testTheNetDoesNotRunWhileAnotherAccountIsOnScreen() {
        let t0 = Date().addingTimeInterval(-1000)
        let c = make()
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        helper.gone = true   // the socket is the other account's
        battery = Self.state(70, ac: false, adapter: true)
        c.tick(now: t0)
        c.tick(now: t0.addingTimeInterval(91))
        c.tick(now: t0.addingTimeInterval(400))
        c.periodicTick(now: t0.addingTimeInterval(430))
        XCTAssertEqual(helper.stops(), 0, "the net ran for an account not on screen")
        XCTAssertNotEqual(c.status, .warning(ChargeController.cutWarningText))

        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)   // a tick, now
        c.tick(now: t0.addingTimeInterval(1060))
        XCTAssertEqual(helper.stops(), 0, "the look did not start again from nothing")
        c.tick(now: t0.addingTimeInterval(1100))
        XCTAssertGreaterThan(helper.stops(), 0)
    }

    /// A cut the net found is owed (see "A cut the net found" below), so the account switch does not drop it: the look
    /// itself is dropped (the net does not run there), but a debt is still asked about while another account is on
    /// screen, as any other is. That is putting right, not holding.
    func testADebtTheNetFoundOutlivesAnAccountSwitch() {
        let t0 = Date()
        battery = Self.state(70, ac: false, adapter: true)
        helper.gone = true
        let c = make()
        c.tick(now: t0)
        c.tick(now: t0.addingTimeInterval(91))
        XCTAssertEqual(c.status, .warning(ChargeController.cutWarningText))
        XCTAssertTrue(settings.chargeCutUnconfirmed)
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        XCTAssertTrue(settings.chargeCutUnconfirmed, "the account switch dropped a debt the net had written down")
        XCTAssertEqual(c.status, .warning(ChargeController.cutWarningText))
        let asked = helper.stops()
        c.tick(now: t0.addingTimeInterval(200))
        XCTAssertGreaterThan(helper.stops(), asked, "a debt was not asked about while another account is on screen")
    }

    // ── A cut the net found is owed ─────────────────────────────────────────
    //
    // The net finds a cut nobody holds (the switch read cut for more than 90 s with no discharge running). That cut
    // is as much a debt as one a discharge left: written down before the helper is asked, asked about by a switch-off
    // and by a quit, shown while off, and settled the same ways (a running helper's yes, or the switch reading
    // connected for long enough). Held only in memory, a person who saw "may still be switched off" and switched
    // Charge Control off, or quit, sent no stop and left no flag and no warning.

    /// The switch read cut for more than 90 s with no helper answering: the net has fired, and the stop is not
    /// answered.
    private func netFoundACutNobodyAnswers() -> ChargeController {
        let t0 = Date()
        chargerSwitch = AdapterCutKey.cut
        let c = make()
        helper.gone = true
        c.tick(now: t0.addingTimeInterval(91))
        XCTAssertEqual(c.status, .warning(ChargeController.cutWarningText))
        return c
    }

    /// Written down before anything is asked, and settled by a running helper's yes like any other debt.
    func testACutTheNetFoundIsWrittenDownBeforeTheHelperIsAskedAndSettledByItsYes() {
        let t0 = Date()
        chargerSwitch = AdapterCutKey.cut
        let c = make()
        var owedWhenAsked: [Bool] = []
        helper.beforeSend = { [weak self] cmd in
            if cmd == .stopDischarge, let self { owedWhenAsked.append(self.settings.chargeCutUnconfirmed) }
        }
        helper.answer = { [weak self] cmd in
            if cmd == .stopDischarge { self?.chargerSwitch = AdapterCutKey.connected }
            return FanReply(ok: true, message: "ok")
        }
        c.tick(now: t0.addingTimeInterval(91))
        XCTAssertEqual(owedWhenAsked, [true], "the stop went out before the cut was written down")
        XCTAssertFalse(settings.chargeCutUnconfirmed, "a running helper's yes did not settle the debt")
        XCTAssertNotEqual(c.status, .warning(ChargeController.cutWarningText))
    }

    /// The person sees the warning and switches Charge Control off: a stop is waited for, and with nobody answering
    /// the debt stays on disk and the section says so while off.
    func testSwitchingOffAfterTheNetFoundACutAsksTheHelperAndKeepsTheDebt() {
        let c = netFoundACutNobodyAnswers()
        XCTAssertTrue(settings.chargeCutUnconfirmed, "the cut the net found was not written down")
        let waited = helper.waited.count
        settings.chargeControlEnabled = false
        XCTAssertTrue(helper.waited.dropFirst(waited).contains(.stopDischarge),
                      "switching off did not ask the helper to reconnect a charger the net found cut: \(helper.waited)")
        XCTAssertTrue(settings.chargeCutUnconfirmed, "the debt was forgotten by the switch-off")
        XCTAssertNotNil(c.offWarning, "the section says nothing while off")
        XCTAssertEqual(c.status, .off)
    }

    /// The same when the helper is there: the switch-off's stop is answered yes, and that settles it.
    func testSwitchingOffAfterTheNetFoundACutSettlesItWhenTheHelperAnswers() {
        let c = netFoundACutNobodyAnswers()
        helper.gone = false
        helper.available = true
        let waited = helper.waited.count
        settings.chargeControlEnabled = false
        XCTAssertTrue(helper.waited.dropFirst(waited).contains(.stopDischarge), "\(helper.waited)")
        XCTAssertFalse(settings.chargeCutUnconfirmed)
        XCTAssertNil(c.offWarning)
    }

    /// Quitting: the same stop is waited for, and what is left is shown at the next launch, and while off.
    func testQuittingAfterTheNetFoundACutAsksTheHelperAndKeepsTheDebt() {
        let c = netFoundACutNobodyAnswers()
        XCTAssertTrue(settings.chargeCutUnconfirmed, "the cut the net found was not written down")
        let waited = helper.waited.count
        c.shutdown()
        XCTAssertTrue(helper.waited.dropFirst(waited).contains(.stopDischarge),
                      "quitting did not ask the helper to reconnect a charger the net found cut: \(helper.waited)")
        XCTAssertTrue(settings.chargeCutUnconfirmed, "the debt was forgotten by the quit")
        XCTAssertNotNil(c.offWarning)
    }

    /// With no helper to answer, the switch reading connected for more than 90 s settles it, as it does any debt.
    func testACutTheNetFoundIsSettledByTheSwitchReadingConnectedForLongEnough() {
        let c = netFoundACutNobodyAnswers()
        helper.installed = false
        XCTAssertTrue(settings.chargeCutUnconfirmed)
        chargerSwitch = AdapterCutKey.connected
        let t0 = Date()
        c.tick(now: t0.addingTimeInterval(100))
        c.tick(now: t0.addingTimeInterval(150))
        XCTAssertTrue(settings.chargeCutUnconfirmed, "90 s of the switch reading connected was not waited for")
        c.tick(now: t0.addingTimeInterval(191))
        XCTAssertFalse(settings.chargeCutUnconfirmed)
        XCTAssertNotEqual(c.status, .warning(ChargeController.cutWarningNoHelperText))
        XCTAssertNotEqual(c.status, .warning(ChargeController.cutWarningText))
    }

    /// macOS's word does not settle it while the switch reads cut, however long it says the Mac is on the adapter.
    func testMacOSsWordDoesNotSettleACutTheNetFound() {
        let c = netFoundACutNobodyAnswers()
        helper.installed = false
        let t0 = Date()
        c.tick(now: t0.addingTimeInterval(100))
        c.tick(now: t0.addingTimeInterval(300))
        XCTAssertTrue(settings.chargeCutUnconfirmed)
    }

    /// Its own debt is still put right while another account is on screen: that is not holding the charger.
    func testADebtOfItsOwnIsStillAskedAboutWhileAnotherAccountIsOnScreen() {
        let c = lostUnderAnUninstall()
        helper.installed = true
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        let asked = helper.stops()
        battery = Self.state(90, ac: false, adapter: true)
        c.tick()
        XCTAssertGreaterThan(helper.stops(), asked)
        XCTAssertTrue(settings.chargeCutUnconfirmed)
    }

    // ── While off ───────────────────────────────────────────────────────────

    /// A session helper killed under a discharge, then Charge Control switched off: nothing can be greeted while
    /// off, so the debt would be silent. The section shows a warning all the same, saying the charger may still be
    /// switched off and how to get it back. Nothing is made or sent for it.
    func testWhileOffADebtSaysSoAndHowToRecover() {
        settings.chargeCutUnconfirmed = true
        helper.installed = false
        let c = make(enabled: false)
        XCTAssertEqual(c.offWarning, ChargeController.cutWarningOffText)
        XCTAssertEqual(c.status, .off)
        XCTAssertTrue(helper.commands.isEmpty)
        XCTAssertEqual(clientsMade, 0)
        XCTAssertEqual(helper.follows, 0)
        let text = ChargeController.cutWarningOffText
        XCTAssertTrue(text.contains("may still be switched off"), text)
        XCTAssertTrue(text.contains("Install Helper\u{2026}"), text)
        XCTAssertFalse(text.contains("Fans tab"), "the Fans tab has no button for this with fan control off: " + text)
        XCTAssertTrue(text.contains("as it starts"), text)
        // With an installed helper at launch, not answering yet, it is asked every 30 s: the line says that.
        helper.installed = true
        helper.gone = true
        let asking = make(enabled: false)
        XCTAssertEqual(helper.stops(), 1)
        XCTAssertEqual(asking.offWarning, ChargeController.cutWarningText)
        withExtendedLifetime(c) {}
        // Nothing owed, nothing said.
        settings.chargeCutUnconfirmed = false
        XCTAssertNil(make(enabled: false).offWarning)
    }

    /// The line says "Reconnecting…" only while something is. A helper installed while off, after the debt arose
    /// with none, is asked when the section is next shown (what the debt already causes for an installed helper:
    /// a stop now, then every 30 s), and only then does the line say so.
    func testAHelperInstalledWhileOffIsAskedWhenTheSectionIsShown() {
        settings.chargeCutUnconfirmed = true
        helper.installed = false
        let c = make(enabled: false)
        helper.installed = true   // installed from the Fans tab, with Charge Control off
        XCTAssertEqual(c.offWarning, ChargeController.cutWarningInstalledText,
                       "it said reconnecting with nothing asking, or pointed at a button that is not there")
        XCTAssertTrue(helper.commands.isEmpty)

        var heard = 0
        let token = c.observeChanges { heard += 1 }
        helper.gone = true   // its first answer is slow to come
        c.recheckHelper()    // the section was shown
        XCTAssertEqual(helper.stops(), 1)
        XCTAssertEqual(c.offWarning, ChargeController.cutWarningText)
        XCTAssertGreaterThan(heard, 0, "the section was not told the line changed")
        c.recheckHelper()
        XCTAssertEqual(helper.stops(), 1, "asked on every look as well as every 30 s")

        helper.gone = false
        c.retryOwedStopWhileOff()   // the timer
        XCTAssertFalse(settings.chargeCutUnconfirmed)
        XCTAssertNil(c.offWarning)
        withExtendedLifetime(token) {}
    }

    /// Without a debt, showing the section while off sends nothing.
    func testShowingTheSectionWhileOffWithNothingOwedSendsNothing() {
        let c = make(enabled: false)
        c.recheckHelper()
        XCTAssertTrue(helper.commands.isEmpty)
        XCTAssertEqual(helper.follows, 0)
        XCTAssertEqual(clientsMade, 0)
    }

    /// The section is told when the debt goes, while off as well as on: nothing else would redraw it.
    func testTheSectionIsToldWhenTheDebtIsSettledWhileOff() {
        battery = Self.state(90)
        let c = make()
        c.pressDischarge()
        helper.gone = true
        settings.chargeControlEnabled = false
        XCTAssertTrue(settings.chargeCutUnconfirmed)
        XCTAssertEqual(c.offWarning, ChargeController.cutWarningText)
        var heard = 0
        let token = c.observeChanges { heard += 1 }
        helper.gone = false
        c.retryOwedStopWhileOff()
        XCTAssertFalse(settings.chargeCutUnconfirmed)
        XCTAssertNil(c.offWarning)
        XCTAssertGreaterThan(heard, 0, "the section was not told the debt was settled")
        withExtendedLifetime(token) {}
    }

    /// A discharge in force is not a cut left behind, however long it runs.
    func testADischargeInForceIsNotTakenForAnOrphanedCut() {
        let t0 = Date()
        battery = Self.state(90)
        let c = make()
        c.pressDischarge()
        battery = Self.state(88, ac: false, adapter: true)
        c.tick(now: t0.addingTimeInterval(200))
        c.tick(now: t0.addingTimeInterval(400))
        XCTAssertEqual(helper.commands, [.discharge(toPercent: 80)])
        XCTAssertEqual(c.dischargeInForce, 80)
    }

    /// At launch, with Charge Control on and the debt left from last time, a stop goes out first, whatever the
    /// policy wants, and nothing is said unless it fails.
    func testALeftoverDischargeFlagIsSettledAtLaunchWhileOn() {
        settings.chargeCutUnconfirmed = true
        var shown: [ChargeStatus] = []
        let c = make()
        shown.append(c.status)
        XCTAssertEqual(helper.commands.first, .stopDischarge)
        XCTAssertFalse(settings.chargeCutUnconfirmed)
        XCTAssertFalse(shown.contains(.warning(ChargeController.cutWarningText)))
    }

    /// Off at launch with the debt left over (Charge Control switched off while the helper could not be reached):
    /// the helper is greeted and asked to reconnect, and asked again until it answers. Nothing else starts.
    func testALeftoverDischargeFlagIsSettledAtLaunchEvenWhileOff() {
        settings.chargeCutUnconfirmed = true
        helper.gone = true
        let c = make(enabled: false)
        XCTAssertEqual(helper.commands, [.stopDischarge], "a relaunch while off never greeted the helper")
        XCTAssertTrue(settings.chargeCutUnconfirmed)
        XCTAssertEqual(clientsMade, 0)
        XCTAssertEqual(helper.follows, 0)
        XCTAssertEqual(c.status, .off)

        c.retryOwedStopWhileOff()
        XCTAssertEqual(helper.stops(), 2, "not asked again")
        helper.gone = false
        c.retryOwedStopWhileOff()
        XCTAssertEqual(helper.stops(), 3)
        XCTAssertFalse(settings.chargeCutUnconfirmed)
        c.retryOwedStopWhileOff()
        XCTAssertEqual(helper.stops(), 3, "asked again after it had answered")
        XCTAssertEqual(clientsMade, 0)
    }

    /// No helper installed: nothing can be greeted while off, so nothing is sent.
    func testALeftoverDischargeFlagWithNoInstalledHelperSendsNothingWhileOff() {
        settings.chargeCutUnconfirmed = true
        helper.installed = false
        make(enabled: false)
        XCTAssertTrue(helper.commands.isEmpty)
    }

    /// Only two refusals of a discharge pass by themselves: the Mac going to sleep, and the charger switched a
    /// moment ago. Those are asked again on the next tick.
    func testTheTransientRefusalsAreRetriedOnTheNextTick() {
        XCTAssertEqual(ChargeController.transientDischargeRefusals,
                       ["the Mac is going to sleep", "the charger was switched a moment ago; try again shortly"])
        battery = Self.state(90)
        helper.answer = { c in
            if case .discharge = c {
                return FanReply(ok: false, message: "the charger was switched a moment ago; try again shortly")
            }
            return FanReply(ok: true, message: "ok")
        }
        let c = make()
        c.pressDischarge()
        XCTAssertEqual(c.status, .active(ChargeDecision(osLimit: 80, dischargeTo: 80, reason: .discharging)))
        helper.answer = { _ in FanReply(ok: true, message: "ok") }
        c.tick()
        XCTAssertEqual(discharges(helper.commands), [80, 80])
        XCTAssertEqual(c.dischargeInForce, 80)
    }

    /// The controller tells the helper's refusals apart by the helper's own words: its transient set is exactly
    /// `ChargeRefusal.goingToSleep` and `.switchedRecently`, never a copy that can drift, and every other refusal
    /// listed here from `ChargeRefusal` lasts — shown, and not asked again on a tick — including one with a figure
    /// in it and a refused cut with its failed undo after it. Fails if the set holds anything else, or if any listed
    /// refusal is asked again. A constant added to `ChargeRefusal` must be added to `published` by hand.
    func testTheControllersRefusalKindsAreTheHelpersOwnConstants() {
        let published = [ChargeRefusal.noChargeControl, ChargeRefusal.noSleepNotices, ChargeRefusal.goingToSleep,
                         ChargeRefusal.reconnectOwed, ChargeRefusal.targetOutOfRange, ChargeRefusal.batteryUnreadable,
                         ChargeRefusal.noCharger, ChargeRefusal.atOrBelow(80), ChargeRefusal.switchedRecently,
                         ChargeRefusal.cutRefused, ChargeRefusal.cutNotKept]
        for why in ChargeController.transientDischargeRefusals {
            XCTAssertTrue(published.contains(why), "\"\(why)\" is not one of the helper's ChargeRefusal constants")
        }
        XCTAssertEqual(ChargeController.transientDischargeRefusals,
                       [ChargeRefusal.goingToSleep, ChargeRefusal.switchedRecently])

        let lasting = published.filter { !ChargeController.transientDischargeRefusals.contains($0) }
            + ["\(ChargeRefusal.cutRefused); \(ChargeRelease.Result(.stillCut, writes: 3).message)"]
        XCTAssertEqual(lasting.count, 10)
        battery = Self.state(90)
        let c = make()
        for (n, why) in lasting.enumerated() {
            helper.answer = { cmd in
                if case .discharge = cmd { return FanReply(ok: false, message: why) }
                return FanReply(ok: true, message: "ok")
            }
            if n > 0 { c.pressDischarge() }   // cancel the one refused before
            c.pressDischarge()
            XCTAssertEqual(c.status, .refused(ChargeController.dischargeRefusedText(why)), why)
            c.tick()
            c.periodicTick()
            c.tick()
            XCTAssertEqual(discharges(helper.commands).count, n + 1, "a lasting refusal was asked again: \(why)")
        }
    }

    /// Every other refusal is shown, in plain words, and not asked again on a tick, the timer or a power change,
    /// until the person presses again.
    func testAnyOtherDischargeRefusalIsShownAndNotRetried() {
        let why = "refused: the battery is already at or below 80%"
        battery = Self.state(90)
        helper.answer = { cmd in
            if case .discharge = cmd { return FanReply(ok: false, message: why) }
            return FanReply(ok: true, message: "ok")
        }
        let c = make()
        c.pressDischarge()
        XCTAssertEqual(c.status, .refused(ChargeController.dischargeRefusedText(why)))
        XCTAssertFalse(ChargeControlFeature.statusText(c.status).contains("refused:"), "\(c.status)")
        c.tick()
        c.periodicTick()
        c.tick()
        XCTAssertEqual(discharges(helper.commands), [80], "a refusal was asked again on its own")
        c.pressDischarge()
        c.pressDischarge()
        XCTAssertEqual(discharges(helper.commands), [80, 80])
    }

    /// The helper's reasons can name parts of the Mac nobody needs to know about; they are said in plain words.
    func testARefusalIsShownInPlainWords() {
        let shown = ChargeController.dischargeRefusedText("the SMC would not cut the charger")
        XCTAssertFalse(shown.contains("SMC"), shown)
        XCTAssertTrue(shown.contains("would not cut the charger"), shown)
    }

    /// A discharge answered yes after the connection was reset: the helper it ran on may be gone. It is booked as
    /// uncertain, so a stop goes out before anything else, and then the discharge is asked for again.
    func testAnAnsweredDischargeAfterAResetIsStoppedNotForgotten() {
        battery = Self.state(90)
        let c = make()
        helper.deferReplies = true
        c.pressDischarge()
        helper.reset()
        helper.flushReplies()
        XCTAssertEqual(helper.commands, [.discharge(toPercent: 80), .stopDischarge, .discharge(toPercent: 80)])
        XCTAssertEqual(c.dischargeInForce, 80)
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

    /// The sleep hold is in force before sleep is allowed: a limit only the helper can set is waited for (within
    /// the same 2 s as the stop), not sent and left on its way.
    func testTheSleepHoldIsInForceBeforeSleepIsAllowed() {
        settings.chargeStopWhenSleeping = true
        battery = Self.state(63)
        helper.landsOn = client
        let c = make()
        XCTAssertEqual(client.state?.mclLimit, 80)
        helper.deferReplies = true
        c.willSleep()
        XCTAssertEqual(client.state?.mclLimit, 63, "the sleep hold was still on its way when sleep was allowed")
        XCTAssertEqual(helper.waited, [.setChargeLimit(63)])
        helper.flushReplies()
        c.didWake()
        XCTAssertEqual(client.state?.mclLimit, 80)
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

    // ── Two accounts ────────────────────────────────────────────────────────

    /// The limit is the whole Mac's, and each account has its own Anode and settings. With fast user switching,
    /// only the Anode of the account on screen holds the limit: one switched away from stops its discharge before
    /// it lets go (waited for, as for sleep), applies nothing and puts nothing back while away, and takes up its
    /// own limit again when its account comes back.
    func testOnlyTheAccountOnScreenHoldsTheLimit() {
        battery = Self.state(90)
        let c = make()
        c.pressDischarge()
        XCTAssertEqual(c.dischargeInForce, 80)
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        XCTAssertEqual(helper.waited, [.stopDischarge], "a discharge was left running for an account not on screen")
        XCTAssertNil(c.dischargeInForce)
        XCTAssertFalse(c.isDischargeRequested)

        // The other account's Anode sets its own limit (and its own Optimized Battery Charging); this one leaves
        // them alone, whatever changes here.
        let calls = (client.limitCalls, client.limitEnabledCalls, client.optimizedChargingCalls)
        client.state?.mclLimit = 95
        client.state?.optimizedChargingEnabled = true
        settings.chargeLimit = 85
        c.periodicTick()
        c.tick()
        XCTAssertEqual(client.limitCalls, calls.0, "an account not on screen changed the limit")
        XCTAssertEqual(client.limitEnabledCalls, calls.1, "an account not on screen put the limit's switch back")
        XCTAssertEqual(client.optimizedChargingCalls, calls.2,
                       "an account not on screen put Optimized Battery Charging back")
        XCTAssertEqual(client.state?.mclLimit, 95)
        XCTAssertEqual(discharges(helper.commands), [80])

        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertEqual(client.state?.mclLimit, 85, "the account back on screen did not take up its limit")
    }

    /// With a per-account record (the shared file could not be had, which is what every test here uses) nobody can say
    /// whose limit is in force, so quitting while another account is on screen puts nothing back: the limit in force
    /// is probably that account's Anode's. The record stays, so this account's next launch lifts whatever is then in
    /// force and starts again after the delay. With the shared record the rule is the holders', not the screen's:
    /// see `ChargeSharedRecordTests`.
    func testWithAPerAccountRecordQuittingWhileAnotherAccountIsOnScreenPutsNothingBack() {
        battery = Self.state(85)
        let c = make()
        c.pressTopUp()
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        let theirs = NativeChargeState(mclEnabled: true, mclLimit: 90, optimizedChargingEnabled: false)
        client.state = theirs   // the other account's
        let writes = writesToMacOS
        c.shutdown()
        XCTAssertEqual(client.state, theirs, "this account's quit changed the other account's settings")
        XCTAssertEqual(writesToMacOS, writes)
        XCTAssertNotNil(settings.chargeRestoreRecord, "the record went though nothing was put back")
        XCTAssertTrue(settings.chargeControlEnabled)
    }

    /// The same while off: nothing exists, so there is nothing to observe.
    func testAccountSwitchesWhileOffDoNothing() {
        make(enabled: false)
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertEqual(clientsMade, 0)
        XCTAssertTrue(helper.commands.isEmpty)
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

    /// Measured on Mac17,9, macOS 27.0: once the limit is set to 100, macOS turns its own limit switch off and reads
    /// back "off, 100". With 100 in force that is agreement, not a change made elsewhere: nothing is logged and
    /// nothing is sent again, however many times the timer reads it back. (It was taken for drift, and 100 was set
    /// again every 30 s for as long as the limit was 100.)
    func testALimitOf100ReadBackAsOffIsAgreement() {
        settings.chargeLimit = 100
        let c = make()
        XCTAssertEqual(client.limitCalls, [100])
        client.state = NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: false)
        let said = lines
        for _ in 0..<3 { c.periodicTick() }
        XCTAssertEqual(client.limitCalls, [100], "100 was set again over macOS's own off-at-100")
        XCTAssertEqual(client.limitEnabledCalls, [true], "the switch macOS turns off at 100 was turned on again")
        XCTAssertEqual(client.optimizedChargingCalls, [false])
        XCTAssertEqual(lines, said, "agreement was logged")
        XCTAssertEqual(c.status, .active(ChargeDecision(osLimit: 100, dischargeTo: nil, reason: .limit)))
        XCTAssertEqual(limitInForce.value, 100)
    }

    /// The same while Top Up holds 100 over the person's own limit.
    func testTopUpsHundredReadBackAsOffIsAgreement() {
        let c = make()
        c.pressTopUp()
        XCTAssertEqual(client.limitCalls, [80, 100])
        client.state = NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: false)
        let said = lines
        for _ in 0..<3 { c.periodicTick() }
        XCTAssertEqual(client.limitCalls, [80, 100])
        XCTAssertEqual(client.limitEnabledCalls, [true])
        XCTAssertEqual(lines, said, "agreement was logged")
    }

    /// Off is agreement only at 100. With 80 in force, macOS reading back as it does with no limit at all (off, 100)
    /// is a change made elsewhere, and is put back.
    func testALimitBelow100ReadBackAsOffIsStillPutBack() {
        let c = make()
        client.state = NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: false)
        c.periodicTick()
        XCTAssertEqual(client.state, NativeChargeState(mclEnabled: true, mclLimit: 80, optimizedChargingEnabled: false))
        XCTAssertEqual(client.limitCalls, [80, 80])
        XCTAssertEqual(client.limitEnabledCalls, [true, true])
        XCTAssertEqual(lines.filter { $0.contains("changed outside Charge Control") }.count, 1,
                       lines.joined(separator: "\n"))
    }

    /// With 100 in force, everything else is still drift: another limit value with the switch off, and Optimized
    /// Battery Charging turned on.
    func testAt100AnotherLimitOrOptimizedChargingIsStillDrift() {
        settings.chargeLimit = 100
        let c = make()
        client.state = NativeChargeState(mclEnabled: false, mclLimit: 80, optimizedChargingEnabled: false)
        c.periodicTick()
        XCTAssertEqual(client.limitCalls, [100, 100], "a limit changed elsewhere was left, because the switch is off")
        XCTAssertEqual(client.limitEnabledCalls, [true, true])

        client.state = NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: true)
        c.periodicTick()
        XCTAssertEqual(client.state?.optimizedChargingEnabled, false)
        XCTAssertEqual(client.limitCalls, [100, 100, 100])
        XCTAssertEqual(lines.filter { $0.contains("changed outside Charge Control") }.count, 2,
                       lines.joined(separator: "\n"))
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

    // ── What the section reads ──────────────────────────────────────────────

    /// Every listener hears every change, however many there are; one that drops its token stops hearing, and
    /// nobody can take another's place.
    func testEveryListenerHearsAndADroppedOneStops() {
        let c = make()
        var first = 0, second = 0
        var a: AnyObject? = c.observeChanges { first += 1 }
        let b = c.observeChanges { second += 1 }
        c.pressTopUp()
        XCTAssertGreaterThan(first, 0)
        XCTAssertGreaterThan(second, 0)
        XCTAssertNotNil(a)
        a = nil
        let (f0, s0) = (first, second)
        c.pressTopUp()
        XCTAssertEqual(first, f0, "a listener that let go was still called")
        XCTAssertGreaterThan(second, s0)
        withExtendedLifetime(b) {}
    }

    /// The charge and whether the cable is in, as the last tick saw them, so the section's words and buttons agree
    /// with the decision they sit next to. A change is announced.
    func testTheBatteryAsLastSeenIsReadableAndAnnounced() {
        let c = make()
        XCTAssertEqual(c.batteryPercent, 70)
        XCTAssertTrue(c.isCablePresent)
        var heard = 0
        let token = c.observeChanges { heard += 1 }
        battery = Self.state(71)
        c.tick()
        XCTAssertEqual(c.batteryPercent, 71)
        XCTAssertEqual(heard, 1, "a new charge was not announced")
        c.tick()
        XCTAssertEqual(heard, 1, "nothing changed, and it was announced anyway")
        battery = Self.state(71, ac: false, adapter: true)   // Anode's own charger cut: the cable is still in
        c.tick()
        XCTAssertTrue(c.isCablePresent)
        XCTAssertEqual(heard, 1, "the cable did not change, and it was announced anyway")
        battery = Self.state(71, ac: false)
        c.tick()
        XCTAssertFalse(c.isCablePresent)
        XCTAssertGreaterThan(heard, 1, "pulling the cable was not announced")
        settings.chargeControlEnabled = false
        XCTAssertNil(c.batteryPercent, "kept after switching off")
        XCTAssertFalse(c.isCablePresent)
        withExtendedLifetime(token) {}
    }

    /// What the helper is actually running, not what was asked for: nil until it says yes, and still there until it
    /// says the stop worked. Each change is announced, though the status itself does not change.
    func testTheDischargeInForceIsWhatTheHelperAccepted() {
        settings.chargeLimit = 40
        battery = Self.state(90)
        let c = make()
        var heard = 0
        let token = c.observeChanges { heard += 1 }
        helper.deferReplies = true
        c.pressDischarge()
        XCTAssertNil(c.dischargeInForce, "booked before the helper answered")
        var before = heard
        helper.flushReplies()
        XCTAssertEqual(c.dischargeInForce, 40)
        XCTAssertGreaterThan(heard, before, "nobody was told the discharge started")

        helper.deferReplies = true
        c.pressDischarge()   // cancel
        XCTAssertEqual(c.dischargeInForce, 40, "the discharge runs until the helper says it stopped")
        before = heard
        helper.flushReplies()
        XCTAssertNil(c.dischargeInForce)
        XCTAssertGreaterThan(heard, before, "nobody was told the discharge stopped")
        withExtendedLifetime(token) {}
    }

    /// Measured on this Mac: when a discharge ends with the cable in, macOS shows "not charging" for about a minute
    /// before charging resumes. The controller says how long that may still last; an unplug or a new discharge
    /// ends it.
    func testTheChargerIsReconnectingForAMinuteAndAHalfAfterADischargeEnds() throws {
        battery = Self.state(90)
        let c = make()
        XCTAssertNil(c.chargerReconnectTimeLeft())
        c.pressDischarge()
        XCTAssertEqual(c.dischargeInForce, 80)
        XCTAssertNil(c.chargerReconnectTimeLeft(), "a discharge is running")
        battery = Self.state(79)
        c.tick()
        XCTAssertNil(c.dischargeInForce)
        let left = try XCTUnwrap(c.chargerReconnectTimeLeft())
        XCTAssertEqual(left, ChargeController.chargerReconnectTime, accuracy: 1)
        XCTAssertEqual(ChargeController.chargerReconnectTime, 90)
        XCTAssertNil(c.chargerReconnectTimeLeft(now: Date().addingTimeInterval(91)))
        battery = Self.state(79, ac: false)
        c.tick()
        XCTAssertNil(c.chargerReconnectTimeLeft(), "nothing reconnects with the cable out")
    }

    /// A discharge that ends because the cable was pulled reconnects nothing.
    func testADischargeEndedByAnUnplugIsNotReconnecting() {
        battery = Self.state(90)
        let c = make()
        c.pressDischarge()
        XCTAssertEqual(c.dischargeInForce, 80)
        battery = Self.state(90, ac: false)
        c.tick()
        XCTAssertNil(c.dischargeInForce)
        XCTAssertNil(c.chargerReconnectTimeLeft())
        battery = Self.state(90)
        c.tick()
        XCTAssertNil(c.chargerReconnectTimeLeft(), "plugging back in is not the end of a discharge")
    }

    // ── A helper-set limit after 100 ────────────────────────────────────────

    /// macOS turns its limit switch off by itself at a limit of 100, and the helper only writes the value, so a value
    /// only the helper can set is not in force until the switch is turned on. It is turned on before the helper is
    /// asked, not 35 s later by a drift pass. The fake client does not turn the switch off at 100 as macOS does, so
    /// the tests do it, and look at the switch at the moment each command goes out.
    func testALimitOnlyTheHelperCanSetFollowing100TurnsTheSwitchOnFirst() {
        settings.chargeLimit = 100
        helper.landsOn = client
        let c = make()
        XCTAssertEqual(client.state?.mclLimit, 100)
        client.state?.mclEnabled = false   // macOS, at 100
        var switchAtSend: [Bool?] = []
        helper.beforeSend = { [client] in if case .setChargeLimit = $0 { switchAtSend.append(client?.state?.mclEnabled) } }
        settings.chargeLimit = 63
        XCTAssertEqual(helper.commands, [.setChargeLimit(63)])
        XCTAssertEqual(switchAtSend, [true], "the helper was asked while macOS's limit switch was still off")
        XCTAssertEqual(client.state, NativeChargeState(mclEnabled: true, mclLimit: 63, optimizedChargingEnabled: false))
        XCTAssertEqual(limitInForce.value, 63)
        c.periodicTick()
        XCTAssertFalse(lines.contains { $0.contains("changed outside") }, lines.joined(separator: "\n"))
    }

    /// Top Up ends (the person cancels it) into a limit only the helper can set: 100 was in force, and the switch with
    /// it off.
    func testTopUpEndingIntoAHelperOnlyLimitTurnsTheSwitchOnFirst() {
        settings.chargeLimit = 63
        helper.landsOn = client
        battery = Self.state(50)
        let c = make()
        c.pressTopUp()
        XCTAssertEqual(client.state?.mclLimit, 100)
        client.state?.mclEnabled = false   // macOS, at 100
        var switchAtSend: [Bool?] = []
        helper.beforeSend = { [client] in if case .setChargeLimit = $0 { switchAtSend.append(client?.state?.mclEnabled) } }
        c.pressTopUp()
        XCTAssertEqual(switchAtSend, [true], "Top Up ended into a limit the helper set while the switch was off")
        XCTAssertEqual(client.state, NativeChargeState(mclEnabled: true, mclLimit: 63, optimizedChargingEnabled: false))
    }

    /// Going to sleep at a limit of 100 with a hold at the current charge: the waited send must find the switch on, or
    /// the Mac sleeps with nothing held (no tick runs asleep to put it right).
    func testTheSleepHoldAfter100TurnsTheSwitchOnBeforeTheWaitedSend() {
        settings.chargeLimit = 100
        settings.chargeStopWhenSleeping = true
        battery = Self.state(63)
        helper.landsOn = client
        let c = make()
        client.state?.mclEnabled = false   // macOS, at 100
        var switchAtSend: [Bool?] = []
        helper.beforeSend = { [client] in if case .setChargeLimit = $0 { switchAtSend.append(client?.state?.mclEnabled) } }
        c.willSleep()
        XCTAssertEqual(helper.waited, [.setChargeLimit(63)])
        XCTAssertEqual(switchAtSend, [true], "the Mac was let go to sleep with the limit's switch off")
        XCTAssertEqual(client.state, NativeChargeState(mclEnabled: true, mclLimit: 63, optimizedChargingEnabled: false))
    }

    /// If macOS turns the switch off again as the limit lands (it does at 100, and what it does when the switch is
    /// turned on at 100 is not measured), the helper's yes is followed by turning it on once more.
    func testTheSwitchIsTurnedOnAgainAfterTheHelpersYesWhenItMayHaveBeenOff() {
        settings.chargeLimit = 100
        let c = make()
        client.state?.mclEnabled = false
        helper.answer = { [client] in
            // The helper writes the value; macOS, meanwhile, leaves the switch off.
            if case .setChargeLimit(let p) = $0 { client?.state?.mclLimit = p; client?.state?.mclEnabled = false }
            return FanReply(ok: true, message: "ok")
        }
        settings.chargeLimit = 63
        XCTAssertEqual(client.state?.mclEnabled, true, "the limit is not in force: the switch is still off after the yes")
        _ = c
    }

    /// While a helper limit is on its way, a switch reading off (and a limit that has landed before its yes) is not
    /// news: it is what the transition looks like, and Charge Control is turning it on. Not a line in the log that
    /// says someone else changed macOS's settings.
    func testNoFalseDriftLineWhileAHelperLimitIsOnItsWayFrom100() {
        settings.chargeLimit = 100
        let c = make()
        client.state?.mclEnabled = false
        helper.deferReplies = true
        settings.chargeLimit = 63
        client.state?.mclLimit = 63        // the helper's write has landed; its answer has not
        client.state?.mclEnabled = false
        c.periodicTick()
        XCTAssertFalse(lines.contains { $0.contains("changed outside") }, lines.joined(separator: "\n"))
        helper.flushReplies()
    }

    func testNoFalseDriftLineWhileTheFirstHelperLimitIsOnItsWay() {
        settings.chargeLimit = 63
        helper.deferReplies = true
        let c = make()
        client.state?.mclEnabled = false
        c.periodicTick()
        XCTAssertFalse(lines.contains { $0.contains("changed outside") }, lines.joined(separator: "\n"))
        helper.flushReplies()
    }

    /// The suppression is only for the window: a switch found off with a limit in force (a person's change) is still
    /// news.
    func testASwitchTurnedOffWithAHelperLimitInForceIsStillDrift() {
        settings.chargeLimit = 63
        helper.landsOn = client
        let c = make()
        XCTAssertEqual(client.state?.mclLimit, 63)
        client.state?.mclEnabled = false
        c.periodicTick()
        XCTAssertTrue(lines.contains { $0.contains("the limit was turned off") }, lines.joined(separator: "\n"))
    }

    // ── A helper that dies between ticks ────────────────────────────────────

    /// The helper dies under a discharge, with nothing being exchanged (measured: Charge Control noticed 28 s later,
    /// at its next tick, and the section said "Discharging" meanwhile). The link now reports the closed socket, the
    /// connection records it, and the controller sends its stop at once, on a fresh socket (for an installed helper
    /// that starts a new one, whose startup reconnects the charger), before the discharge it still wants.
    func testAHelperThatDiesUnderADischargeIsStoppedAtOnceWithNoTick() {
        let wire = ScriptedWire()
        wire.answerAtOnce = .connected(fanCount: 0, version: 2)
        let adapter = ChargeHelperAdapter(connection: HelperConnection(wire: wire), isInstalled: { true })
        battery = Self.state(90)
        settings.chargeControlEnabled = true
        let c = ChargeController(settings: settings, makeClient: { [client] in client }, helper: adapter,
                                 battery: { [weak self] in self?.battery }, chargerSwitch: { nil },
                                 log: { [weak self] in self?.lines.append($0) }, workspace: center,
                                 limitInForce: limitInForce, onConsole: { true })
        controller = c
        c.pressDischarge()
        XCTAssertEqual(c.dischargeInForce, 80)
        XCTAssertEqual(wire.sent, [.discharge(toPercent: 80)])
        wire.peerCloses()
        XCTAssertEqual(Array(wire.sent.prefix(2)), [.discharge(toPercent: 80), .stopDischarge],
                       "the stop did not go out at once: " + lines.joined(separator: "\n"))
        XCTAssertEqual(wire.reachedAHelper.prefix(2).last, true, "the stop went to a socket nobody had opened")
        XCTAssertTrue(lines.contains { $0.contains("reset under the discharge") }, lines.joined(separator: "\n"))
    }

    // ── A warning that never clears while off ───────────────────────────────

    /// A discharge on a hand-started helper (no installed daemon), the helper stopped (it reconnects the charger as
    /// it goes), the cut marked lost, and Charge Control switched off: nothing was left that could read the switch,
    /// so the line stayed for good, across launches, with the charger connected. The section reading the switch once,
    /// when it is shown, settles it.
    func testAnOwedCutIsSettledByOneReadOfTheSwitchWhenTheSectionIsShownWithNoHelper() {
        settings.chargeCutUnconfirmed = true
        helper.installed = false
        let c = make(enabled: false)
        XCTAssertEqual(c.offWarning, ChargeController.cutWarningOffText)
        XCTAssertEqual(switchReads, 0, "the switch was read at launch, with nothing asking")
        chargerSwitch = AdapterCutKey.connected
        c.recheckHelper()
        XCTAssertEqual(switchReads, 1)
        XCTAssertNil(c.offWarning, "the charger reads connected and the line stayed")
        XCTAssertFalse(settings.chargeCutUnconfirmed, "the debt was kept on disk, for the next launch to show again")
        XCTAssertTrue(lines.contains { $0.contains("the charger switch reads connected") }, lines.joined(separator: "\n"))
        XCTAssertTrue(helper.commands.isEmpty, "a helper that is not installed was asked")
        // Nothing owed: nothing is read any more, and a later launch says nothing.
        c.recheckHelper()
        XCTAssertEqual(switchReads, 1)
        XCTAssertNil(make(enabled: false).offWarning)
    }

    /// Anything but a clear "connected" settles nothing: the cut, a value Anode never writes, a switch that cannot be
    /// read. One read per look, no timer.
    func testAnOwedCutIsNotSettledByASwitchThatReadsCutOrOddOrNothing() {
        settings.chargeCutUnconfirmed = true
        helper.installed = false
        let c = make(enabled: false)
        var reads = 0
        for value in [AdapterCutKey.cut, 0x04, nil] as [UInt8?] {
            chargerSwitch = value
            c.recheckHelper()
            reads += 1
            XCTAssertEqual(switchReads, reads, "one read for each look")
            XCTAssertEqual(c.offWarning, ChargeController.cutWarningOffText, "settled by \(String(describing: value))")
            XCTAssertTrue(settings.chargeCutUnconfirmed)
        }
    }

    /// Nothing to read for: an installed helper is asked instead (which a yes settles), and with no debt nothing is
    /// read at all.
    func testTheSwitchIsReadOnlyForADebtWithNoInstalledHelper() {
        chargerSwitch = AdapterCutKey.connected
        helper.installed = false
        let clean = make(enabled: false)
        clean.recheckHelper()
        XCTAssertEqual(switchReads, 0, "read with nothing owed")

        settings.chargeCutUnconfirmed = true
        helper.installed = true
        helper.gone = true
        let asked = make(enabled: false)
        asked.recheckHelper()
        XCTAssertEqual(switchReads, 0, "read when an installed helper is there to ask")
        withExtendedLifetime(clean) {}
    }

    /// While waiting out the delay after an unclean exit nothing is running either, and the line is the same.
    func testAnOwedCutIsSettledByTheSwitchDuringTheDelayToo() {
        settings.chargeRestoreRecord = ChargeController.encodeRecord(found)
        settings.chargeCutUnconfirmed = true
        helper.installed = false
        helper.gone = true   // nobody answers the launch's stop, so the debt stays
        let c = make(enabled: true)
        XCTAssertTrue(c.isWaitingToStart)
        XCTAssertEqual(c.offWarning, ChargeController.cutWarningOffText)
        chargerSwitch = AdapterCutKey.connected
        c.recheckHelper()
        XCTAssertNil(c.offWarning)
        XCTAssertFalse(settings.chargeCutUnconfirmed)
    }

    // ── Why there is no client ──────────────────────────────────────────────

    /// "Needs macOS 26.4 or later on Apple silicon" was said whenever the client could not be made, which is any failed
    /// framework, class, method or signature check, not only an old macOS. It is said only for a Mac that is too old.
    func testNoClientOnAnOldMacSaysItNeedsANewerMacOS() {
        clientToMake = nil
        noClientReason = .init(unsupportedMac: true, step: nil)
        let c = make()
        XCTAssertEqual(c.status, .unavailable(ChargeController.unavailableText))
    }

    func testNoClientOnAMacThatFitsSaysSoInPlainWordsAndLogsTheStepOnce() {
        clientToMake = nil
        noClientReason = .init(unsupportedMac: false, step: "the method setMCLLimit:error: is not there")
        let c = make()
        XCTAssertEqual(c.status, .unavailable(ChargeController.clientMissingText))
        XCTAssertFalse(ChargeController.clientMissingText.contains("26.4"), ChargeController.clientMissingText)
        let said = lines.filter { $0.contains("the method setMCLLimit:error: is not there") }
        XCTAssertEqual(said.count, 1, lines.joined(separator: "\n"))
        XCTAssertFalse(said[0].contains("older than macOS 26.4"), said[0])
        // Switched off and on again: the same news is not said again.
        settings.chargeControlEnabled = false
        settings.chargeControlEnabled = true
        XCTAssertEqual(lines.filter { $0.contains("setMCLLimit:error:") }.count, 1, lines.joined(separator: "\n"))
        XCTAssertEqual(c.status, .unavailable(ChargeController.clientMissingText))
    }

    func testTheLogSaysWhenTheMacIsTooOld() {
        clientToMake = nil
        noClientReason = .init(unsupportedMac: true, step: "the framework /x did not load")
        _ = make()
        XCTAssertTrue(lines.contains { $0.contains("older than macOS 26.4") && $0.contains("did not load") },
                      lines.joined(separator: "\n"))
    }

    func testWhichMacsFitChargeControl() {
        func fits(_ major: Int, _ minor: Int, silicon: Bool = true) -> Bool {
            ChargeController.osFitsChargeControl(OperatingSystemVersion(majorVersion: major, minorVersion: minor,
                                                                         patchVersion: 0), appleSilicon: silicon)
        }
        XCTAssertFalse(fits(15, 6))
        XCTAssertFalse(fits(26, 0))
        XCTAssertFalse(fits(26, 3))
        XCTAssertTrue(fits(26, 4))
        XCTAssertTrue(fits(26, 5))
        XCTAssertTrue(fits(27, 0))
        XCTAssertFalse(fits(27, 0, silicon: false), "an Intel Mac is not one it needs")
        XCTAssertFalse(fits(26, 4, silicon: false))
    }

    // ── Reconnecting, until charging resumes ────────────────────────────────

    /// The line said "Reconnecting the charger…" for a fixed 90 s after a discharge ended below the limit; charging was
    /// measured to resume after about 55 s. Once the battery reports charging the line goes, and does not come back
    /// for the rest of the 90 s if charging stops again (at the limit, say).
    func testReconnectingEndsWhenChargingResumes() throws {
        battery = Self.state(90)
        let c = make()
        c.pressDischarge()
        battery = Self.state(79)
        c.tick()
        XCTAssertNotNil(c.chargerReconnectTimeLeft(), "the discharge ended with the cable in")
        var heard = 0
        let token = c.observeChanges { heard += 1 }
        battery = Self.state(79, charging: true)
        c.tick()
        XCTAssertNil(c.chargerReconnectTimeLeft(now: Date().addingTimeInterval(55)), "charging has resumed")
        XCTAssertGreaterThan(heard, 0, "the section was not told")
        battery = Self.state(79, charging: false)
        c.tick()
        XCTAssertNil(c.chargerReconnectTimeLeft(now: Date().addingTimeInterval(60)),
                     "charging resumed and stopped again: it is not reconnecting")
        withExtendedLifetime(token) {}
    }

    /// While macOS says it is not charging, the clock still rules.
    func testReconnectingGoesOnWhileNotChargingForNinetySeconds() throws {
        battery = Self.state(90)
        let c = make()
        c.pressDischarge()
        battery = Self.state(79, charging: false)
        c.tick()
        XCTAssertNotNil(c.chargerReconnectTimeLeft(now: Date().addingTimeInterval(55)))
        XCTAssertNil(c.chargerReconnectTimeLeft(now: Date().addingTimeInterval(91)))
    }

    // ── A restore that can never complete ───────────────────────────────────

    /// The original limit is one only the helper can set (left by another tool before Charge Control was switched on)
    /// and no helper is installed: the nearest value macOS takes, at or above it, goes in, the switch and Optimized
    /// Battery Charging go back as recorded, and that is the best this Mac can do. The record is cleared, with a line
    /// that says exactly what was put back and what could not be. It used to keep the record, so every launch took the
    /// unclean route and waited 60 s, for ever.
    func testARestoreOnlyTheHelperCouldCompleteWithNoHelperInstalledIsTheBestThereIsAndClearsTheRecord() {
        client.state = NativeChargeState(mclEnabled: true, mclLimit: 63, optimizedChargingEnabled: true)
        helper.installed = false
        helper.available = false
        let c = make()
        settings.chargeControlEnabled = false
        XCTAssertEqual(client.state, NativeChargeState(mclEnabled: true, mclLimit: 80, optimizedChargingEnabled: true),
                       "the nearest value above 63, with the switch and Optimized Battery Charging as they were")
        XCTAssertNil(settings.chargeRestoreRecord, "the record stayed, and every launch would wait 60 s again")
        XCTAssertTrue(helper.waited.isEmpty, "a helper that is not installed was asked")
        let said = lines.first { $0.contains("as much of macOS's own settings as this Mac can") } ?? ""
        XCTAssertTrue(said.contains("limit 80 on"), said)
        XCTAssertTrue(said.contains("was 63"), said)
        XCTAssertTrue(said.contains("Optimized Battery Charging on"), said)
        XCTAssertTrue(said.contains("needs the helper"), said)
        XCTAssertFalse(lines.contains { $0.contains("record is kept") }, lines.joined(separator: "\n"))
        // The next launch finds nothing to lift.
        XCTAssertFalse(settings.chargeStartPending)
        let next = ChargeRecords(settings: settings)
        XCTAssertFalse(next.hasRecord)
        XCTAssertFalse(next.lastRunDidNotRelease(), "the next launch would take this for an unclean exit")
        withExtendedLifetime(c) {}
    }

    /// The same at a launch that lifts after a crash, and before an uninstall: one rule, wherever the restore runs.
    func testTheLaunchLiftWithNoHelperInstalledClearsAnUnsettableRecordToo() {
        settings.chargeRestoreRecord = ChargeController.encodeRecord(
            NativeChargeState(mclEnabled: true, mclLimit: 63, optimizedChargingEnabled: false))
        client.state = NativeChargeState(mclEnabled: true, mclLimit: 100, optimizedChargingEnabled: false)
        helper.installed = false
        helper.available = false
        let c = make(enabled: false)
        XCTAssertEqual(client.state, NativeChargeState(mclEnabled: true, mclLimit: 80, optimizedChargingEnabled: false))
        XCTAssertNil(settings.chargeRestoreRecord)
        c.restoreForUninstall()
    }

    /// A helper that is installed and did not answer is not "none installed": it may answer next time, so the record
    /// is kept, as before, and the nearest value holds meanwhile.
    func testARestoreWithAnInstalledHelperThatDidNotAnswerKeepsTheRecord() {
        client.state = NativeChargeState(mclEnabled: true, mclLimit: 63, optimizedChargingEnabled: true)
        let c = make()
        helper.gone = true
        settings.chargeControlEnabled = false
        XCTAssertNotNil(settings.chargeRestoreRecord, "an installed helper that was only silent lost the record")
        XCTAssertTrue(lines.contains { $0.contains("record is kept") }, lines.joined(separator: "\n"))
        XCTAssertFalse(lines.contains { $0.contains("as much of macOS's own settings as this Mac can") })
        XCTAssertEqual(client.state?.mclLimit, 80)
        withExtendedLifetime(c) {}
    }

    /// Not clearing anything on a best effort that did not land: macOS refusing the nearest value is a failure.
    func testABestEffortMacOSRefusesKeepsTheRecord() {
        client.state = NativeChargeState(mclEnabled: true, mclLimit: 63, optimizedChargingEnabled: true)
        helper.installed = false
        helper.available = false
        let c = make()
        client.succeeds = false
        settings.chargeControlEnabled = false
        XCTAssertNotNil(settings.chargeRestoreRecord)
        XCTAssertFalse(lines.contains { $0.contains("as much of macOS's own settings as this Mac can") })
        withExtendedLifetime(c) {}
    }

    // ── Launched while another account is on screen ─────────────────────────

    /// `sessionActive` started true. An Anode launched while its account is not the one on screen (relaunched by an
    /// update while switched away, say) took the whole Mac's limit and ran the left-over-cut net, over the Anode of
    /// the account that is. It starts from the session's own answer.
    func testLaunchedWhileAnotherAccountIsOnScreenItAssertsNothingAndLooksForNothing() {
        onConsole = false
        battery = Self.state(90)
        chargerSwitch = AdapterCutKey.cut
        client.state = found
        let c = make()
        XCTAssertEqual(client.limitCalls, [], "the limit was asserted over the account on screen")
        XCTAssertEqual(client.limitEnabledCalls, [], "the limit's switch was turned on over the account on screen")
        XCTAssertEqual(client.optimizedChargingCalls, [], "Optimized Battery Charging was turned off over it")
        XCTAssertEqual(client.state, found, "macOS's settings were touched")
        XCTAssertTrue(helper.commands.isEmpty)
        // The net does not run: a cut look for longer than it takes is another Anode's, through a helper this one
        // cannot reach.
        let later = Date().addingTimeInterval(ChargeController.chargerReconnectTime + 5)
        c.tick(now: Date())
        c.tick(now: later)
        XCTAssertEqual(switchReads, 0, "the net looked at the charger while another account is on screen")
        XCTAssertFalse(settings.chargeCutUnconfirmed)
        XCTAssertTrue(helper.commands.isEmpty)
        c.periodicTick()
        XCTAssertEqual(client.limitCalls, [])

        // Back on screen: the limit goes in, as a switch-on does, and that is not someone else's change.
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertEqual(client.state?.mclLimit, 80, "this account's limit was not asserted once it was on screen")
        XCTAssertEqual(client.state?.mclEnabled, true)
        XCTAssertEqual(client.state?.optimizedChargingEnabled, false)
        XCTAssertFalse(lines.contains { $0.contains("changed outside") }, lines.joined(separator: "\n"))
    }

    /// An account on screen at launch, or one whose session cannot be read, is the ordinary case.
    func testLaunchedOnScreenOrWithNoSessionAnswerItHoldsTheLimit() {
        for answer in [true, nil] as [Bool?] {
            setUpClean()
            onConsole = answer
            _ = make()
            XCTAssertEqual(client.state?.mclLimit, 80, "not held for \(String(describing: answer))")
        }
    }

    /// The session's dictionary says whether this account is on the console; anything else is no answer.
    func testTheSessionDictionaryIsReadForTheConsoleKey() {
        let key = kCGSessionOnConsoleKey as String
        XCTAssertEqual(ChargeController.onConsole(fromSession: [key: true]), true)
        XCTAssertEqual(ChargeController.onConsole(fromSession: [key: false]), false)
        XCTAssertNil(ChargeController.onConsole(fromSession: [:]))
        XCTAssertNil(ChargeController.onConsole(fromSession: nil))
        XCTAssertNil(ChargeController.onConsole(fromSession: [key: "yes"]))
    }

    private func setUpClean() {
        controller?.shutdown()
        controller = nil
        client = FakeChargeLimitClient(state: NativeChargeState(mclEnabled: false, mclLimit: 100,
                                                                optimizedChargingEnabled: true))
        clientToMake = client
        settings.chargeRestoreRecord = nil
        lines = []
    }
}

// ── Fakes ───────────────────────────────────────────────────────────────────

/// The helper as Charge Control sees it, scripted. Replies come back at once unless `deferReplies` is set. Like the
/// real link it never answers "nothing": a helper that is gone answers ok:false, "the fan helper stopped answering".
final class FakeHelperLink: ChargeHelperLink {
    var available = true
    var outdated = false
    /// Installed as a daemon, so a connection starts it.
    var installed = true
    /// The helper is gone: every command is answered as the real link answers one with nobody there ("stopped
    /// answering"), and a waited one gets nothing. It is unavailable from its first such answer.
    var gone = false
    /// Called with each command as it goes out, before it is answered.
    var beforeSend: ((FanCommand) -> Void)?
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
        beforeSend?(c)
        if gone {
            available = false
            return done(FanReply(ok: false, message: HelperConnection.stoppedAnswering))
        }
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
        beforeSend?(c)
        if gone {
            available = false
            return nil
        }
        queue.forEach { run($0) }
        let reply = answer(c)
        land(c, reply)
        return reply
    }

    func stops() -> Int { commands.filter { $0 == .stopDischarge }.count }

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
    /// Whether a start was pending (`Settings.chargeStartPending`) at the moment of each call.
    private(set) var pendingAtEachCall: [Bool] = []

    init(state: NativeChargeState?) { self.state = state }

    func read() -> NativeChargeState? { state }

    func setLimit(_ percent: Int) -> Bool {
        limitCalls.append(percent)
        recordAtEachCall.append(settings?.chargeRestoreRecord)
        pendingAtEachCall.append(settings?.chargeStartPending ?? false)
        guard NativeChargeLimit.isClientSettable(percent) else { return false }
        state?.mclLimit = percent
        return true
    }

    func setLimitEnabled(_ on: Bool) -> Bool {
        recordAtEachCall.append(settings?.chargeRestoreRecord)
        pendingAtEachCall.append(settings?.chargeStartPending ?? false)
        state?.mclEnabled = on
        return true
    }

    func setOptimizedCharging(_ on: Bool) -> Bool {
        recordAtEachCall.append(settings?.chargeRestoreRecord)
        pendingAtEachCall.append(settings?.chargeStartPending ?? false)
        state?.optimizedChargingEnabled = on
        return true
    }
}

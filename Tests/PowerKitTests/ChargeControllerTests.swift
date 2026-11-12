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
        XCTAssertEqual(helper.holds, 0, "the helper link was held while off")
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

    func testHoldsTheHelperOnlyWhileOn() {
        make(enabled: false)
        XCTAssertEqual(helper.holds, 0)
        settings.chargeControlEnabled = true
        XCTAssertTrue(helper.holding, "Charge Control on does not hold the helper link")
        settings.chargeControlEnabled = false
        XCTAssertFalse(helper.holding, "Charge Control off still holds the helper link")
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

    func testUndecodableRecordIsTreatedAsNone() {
        settings.chargeRestoreRecord = "{not a record"
        client.state = NativeChargeState(mclEnabled: true, mclLimit: 85, optimizedChargingEnabled: false)
        make()
        XCTAssertEqual(record, NativeChargeState(mclEnabled: true, mclLimit: 85, optimizedChargingEnabled: false))
    }

    func testUnavailableClientShowsReason() {
        clientToMake = nil
        let c = make()
        XCTAssertEqual(c.status, .unavailable("Needs macOS 26.4 or later on Apple silicon"))
        XCTAssertNil(settings.chargeRestoreRecord)
        XCTAssertEqual(helper.holds, 0)
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
        XCTAssertFalse(helper.holding)
        let after = helper.commands.count
        c.tick()
        XCTAssertEqual(helper.commands.count, after, "the controller kept working after it was switched off")
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

    /// Quitting leaves macOS's limit in force (it outlives the app by design) and lets the helper link go.
    func testShutdownLeavesTheLimitAndLetsGo() {
        let c = make()
        c.shutdown()
        XCTAssertFalse(helper.holding)
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
        helper.answersOnHold = false
        settings.chargeLimit = 63
        make()
        XCTAssertTrue(client.limitCalls.isEmpty, "the fallback was set before the helper had answered")
        helper.firstAnswer()
        XCTAssertEqual(client.limitCalls, [80])
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
    }
}

// ── Fakes ───────────────────────────────────────────────────────────────────

/// The helper as Charge Control sees it, scripted. Replies come back at once unless `deferReplies` is set.
final class FakeHelperLink: ChargeHelperLink {
    var available = true
    var outdated = false
    private(set) var resets = 0
    private(set) var commands: [FanCommand] = []
    /// The commands sent through `sendWaiting`, in order.
    private(set) var waited: [FanCommand] = []
    private(set) var holds = 0
    private(set) var letGos = 0
    private(set) var refreshes = 0
    var holding: Bool { holds > letGos }
    var answer: (FanCommand) -> FanReply? = { _ in FanReply(ok: true, message: "ok") }
    var deferReplies = false
    private var deferred: [() -> Void] = []
    private var changed: (() -> Void)?

    /// Whether `hold` answers at once, as a link that has connected (or found nothing) does.
    var answersOnHold = true

    func hold(_ changed: @escaping () -> Void) {
        holds += 1
        self.changed = changed
        if answersOnHold { changed() }
    }

    /// The link's first answer, for a test that held it back.
    func firstAnswer() { changed?() }
    func letGo() { letGos += 1; changed = nil }
    func refresh() { refreshes += 1 }

    func send(_ c: FanCommand, _ done: @escaping (FanReply?) -> Void) {
        commands.append(c)
        let reply = answer(c)
        if deferReplies { deferred.append { done(reply) } } else { done(reply) }
    }

    func sendWaiting(_ c: FanCommand, timeout: TimeInterval) -> FanReply? {
        commands.append(c)
        waited.append(c)
        return answer(c)
    }

    func flushReplies() {
        let pending = deferred
        deferred = []
        deferReplies = false
        pending.forEach { $0() }
    }

    /// What the shared connection reports when the Fans tab releases everything or a socket is reopened.
    func reset() { resets += 1; changed?() }

    func becomeAvailable() { available = true; outdated = false; changed?() }
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

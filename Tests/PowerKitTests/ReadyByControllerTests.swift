import XCTest
@testable import AnodeApp
@testable import PowerKit

/// The next moment a time of day names, on a calendar: today if it is still ahead, otherwise tomorrow, and right across
/// a change of time zone and both daylight-saving changes. Pure: the calendar is a parameter.
final class ReadyByMomentTests: XCTestCase {

    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    private func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func next(after now: Date, _ minutes: Int, _ zone: String = "UTC") -> Date? {
        ChargeController.nextReadyBy(after: now, minutes: minutes, calendar: calendar(zone))
    }

    func testTodayWhileItIsStillAhead() {
        XCTAssertEqual(next(after: utc("2026-11-12T05:00:00Z"), 420), utc("2026-11-12T07:00:00Z"))
        XCTAssertEqual(next(after: utc("2026-11-12T06:59:59Z"), 420), utc("2026-11-12T07:00:00Z"))
    }

    func testTomorrowOnceItHasPassed() {
        XCTAssertEqual(next(after: utc("2026-11-12T07:00:01Z"), 420), utc("2026-11-13T07:00:00Z"))
        XCTAssertEqual(next(after: utc("2026-11-12T23:00:00Z"), 420), utc("2026-11-13T07:00:00Z"))
    }

    /// At the moment itself it is the moment that has passed, and the next one is a day on.
    func testAtTheMomentItselfTheNextOneIsTomorrows() {
        XCTAssertEqual(next(after: utc("2026-11-12T07:00:00Z"), 420), utc("2026-11-13T07:00:00Z"))
    }

    func testTheEdgesOfTheDay() {
        XCTAssertEqual(next(after: utc("2026-11-12T23:59:59Z"), 0), utc("2026-11-13T00:00:00Z"), "midnight")
        XCTAssertEqual(next(after: utc("2026-11-12T12:00:00Z"), 1439), utc("2026-11-12T23:59:00Z"), "23:59")
        XCTAssertEqual(next(after: utc("2026-11-12T23:59:30Z"), 1439), utc("2026-11-13T23:59:00Z"))
        XCTAssertEqual(next(after: utc("2026-11-12T00:00:00Z"), 0), utc("2026-11-13T00:00:00Z"))
    }

    func testAlwaysAfterNowAndNeverMoreThanADayAndAnHourOff() {
        var now = utc("2026-03-07T00:00:00Z")
        for step in 0..<(24 * 60 * 3) {
            now = now.addingTimeInterval(20 * 60)
            _ = step
            for minutes in [0, 90, 150, 420, 1439] {
                guard let n = next(after: now, minutes, "America/New_York") else { return XCTFail("no moment") }
                XCTAssertGreaterThan(n, now)
                XCTAssertLessThanOrEqual(n.timeIntervalSince(now), 25 * 3600, "\(now) \(minutes)")
            }
        }
    }

    /// Clocks go forward at 2:00 on 2026-03-08 in New York: the night before is an hour shorter, and 7:00 is still 7:00
    /// on the wall.
    func testSpringForwardKeepsTheWallClockTime() throws {
        let now = utc("2026-03-08T04:00:00Z")       // 23:00 on the 7th, EST
        let n = try XCTUnwrap(next(after: now, 420, "America/New_York"))
        XCTAssertEqual(n, utc("2026-03-08T11:00:00Z"), "7:00 EDT")
        XCTAssertEqual(n.timeIntervalSince(now), 7 * 3600, "seven hours of clock time, because an hour was skipped")
    }

    /// A time that does not exist that day (2:30 in the hour that was skipped) is the next time that does.
    func testATimeInTheSkippedHourIsTheNextThatExists() throws {
        let now = utc("2026-03-08T04:00:00Z")
        let n = try XCTUnwrap(next(after: now, 150, "America/New_York"))
        let wall = calendar("America/New_York").dateComponents([.day, .hour], from: n)
        XCTAssertEqual(wall.day, 8)
        XCTAssertEqual(wall.hour, 3, "2:30 does not exist on the 8th; 3:xx is what the clock shows next")
        XCTAssertGreaterThanOrEqual(n, utc("2026-03-08T07:00:00Z"))
        XCTAssertLessThanOrEqual(n, utc("2026-03-08T07:30:00Z"))
    }

    /// Clocks go back at 2:00 on 2026-11-01: the night is an hour longer.
    func testFallBackKeepsTheWallClockTime() throws {
        let now = utc("2026-11-01T03:00:00Z")       // 23:00 on the 31st, EDT
        let n = try XCTUnwrap(next(after: now, 420, "America/New_York"))
        XCTAssertEqual(n, utc("2026-11-01T12:00:00Z"), "7:00 EST")
        XCTAssertEqual(n.timeIntervalSince(now), 9 * 3600, "nine hours of clock time, because an hour was repeated")
    }

    /// 1:30 happens twice that night; the first is the one to be ready by.
    func testATimeInTheRepeatedHourIsTheFirstOne() throws {
        let now = utc("2026-11-01T03:00:00Z")
        let n = try XCTUnwrap(next(after: now, 90, "America/New_York"))
        XCTAssertEqual(n, utc("2026-11-01T05:30:00Z"), "1:30 EDT, not 1:30 EST")
    }

    func testTheDayAfterAChangeIsBackToTwentyFourHours() throws {
        let n = try XCTUnwrap(next(after: utc("2026-03-08T12:00:00Z"), 420, "America/New_York"))
        XCTAssertEqual(n, utc("2026-03-09T11:00:00Z"))
    }

    /// The same time of day is a different moment in another time zone, and a calendar that has changed zone is the
    /// one asked each time.
    func testATimeZoneChangeMovesTheMoment() throws {
        let now = utc("2026-11-12T12:00:00Z")
        let newYork = try XCTUnwrap(next(after: now, 420, "America/New_York"))
        let tokyo = try XCTUnwrap(next(after: now, 420, "Asia/Tokyo"))
        let london = try XCTUnwrap(next(after: now, 420, "Europe/London"))
        XCTAssertEqual(newYork, utc("2026-11-13T12:00:00Z"), "7:00 EST")
        XCTAssertEqual(tokyo, utc("2026-11-12T22:00:00Z"), "7:00 JST is 22:00 the day before, in UTC")
        XCTAssertEqual(london, utc("2026-11-13T07:00:00Z"))
    }
}

/// A rate store held in memory.
final class MemoryRateStore: ChargeRateStore {
    var rates = ChargeRate()
    private(set) var saves = 0
    func load() -> ChargeRate { rates }
    func save(_ r: ChargeRate) { rates = r; saves += 1 }
}

/// Ready By in the controller: it feeds the policy the next moment and the learned rate, holds through the helper as
/// any hold does, raises the limit itself when the moment comes while awake, hands the helper the plan before the Mac
/// sleeps, and takes it back when the hold ends for a real reason. Nothing here touches the Mac: the client, the helper,
/// the battery, the clock and the calendar are all the test's.
final class ReadyByControllerTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var settings: Settings!
    private var client: FakeChargeLimitClient!
    private var helper: FakeHelperLink!
    private var battery: Battery.State?
    private var lines: [String] = []
    private var center: NotificationCenter!
    private var limitInForce: ChargeLimitInForce!
    private var controller: ChargeController?
    private var rateStore: MemoryRateStore!
    private var calendar = ReadyByControllerTests.utcCalendar
    private var clockNow = ReadyByControllerTests.utc("2026-11-12T23:00:00Z")

    private static var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private static func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    /// 07:00 the next morning, which is what the settings say unless a test changes it.
    private let by = ReadyByControllerTests.utc("2026-11-13T07:00:00Z")
    /// 54 to 80 on a 100 W charger at the guess for it (1.0 a minute) is 26 minutes, and the margin is 15 more.
    private var raiseAt: Date { by.addingTimeInterval(-(26 * 60 + 15 * 60)) }

    /// What macOS says before Charge Control has ever touched it.
    private let found = NativeChargeState(mclEnabled: true, mclLimit: 90, optimizedChargingEnabled: true)

    override func setUpWithError() throws {
        (defaults, suiteName) = try TestDefaults.make(owner: "ReadyByController", test: name)
        settings = Settings(defaults: defaults)
        client = FakeChargeLimitClient(state: found)
        helper = FakeHelperLink()
        helper.landsOn = client
        battery = Self.plugged(54)
        lines = []
        center = NotificationCenter()
        limitInForce = ChargeLimitInForce()
        rateStore = MemoryRateStore()
        calendar = Self.utcCalendar
        clockNow = Self.utc("2026-11-12T23:00:00Z")
        settings.chargeReadyByEnabled = true
    }

    override func tearDownWithError() throws {
        controller?.shutdown()
        controller = nil
        settings = nil
        TestDefaults.destroy(defaults, suiteName)
    }

    /// On the charger that comes with the Mac: 100 W, so the over-65 class.
    static func plugged(_ percent: Int, ac: Bool = true, charging: Bool = false, watts: Double? = 100) -> Battery.State {
        var s = ChargeControllerTests.state(percent, ac: ac, charging: charging)
        s.adapterWatts = ac ? watts : nil
        return s
    }

    @discardableResult
    private func make(enabled: Bool = true, startDelay: TimeInterval = ChargeController.startDelay) -> ChargeController {
        settings.chargeControlEnabled = enabled
        let c = ChargeController(settings: settings,
                                 makeClient: { [weak self] in self?.client },
                                 helper: helper,
                                 battery: { [weak self] in self?.battery },
                                 chargerSwitch: { nil },
                                 log: { [weak self] in self?.lines.append($0) },
                                 workspace: center, limitInForce: limitInForce, startDelay: startDelay,
                                 noClientBecause: { ChargeController.NoClientReason(unsupportedMac: true, step: nil) },
                                 onConsole: { true },
                                 rateStore: rateStore,
                                 now: { [weak self] in self?.clockNow ?? Date() },
                                 calendar: { [weak self] in self?.calendar ?? .current })
        controller = c
        return c
    }

    private func count(_ command: FanCommand) -> Int { helper.commands.filter { $0 == command }.count }
    private var schedules: [FanCommand] {
        helper.commands.filter { if case .scheduleChargeLimit = $0 { return true } else { return false } }
    }
    private let cancel = FanCommand.cancelScheduledChargeLimit

    /// Holding at 54, Mac awake, nothing sent to the helper about a plan yet.
    private func holding() -> ChargeController {
        let c = make()
        XCTAssertEqual(c.lastDecision?.reason, .readyBy, "the fixture is not holding: \(String(describing: c.lastDecision))")
        return c
    }

    /// Holding, the Mac has gone to sleep (the plan was sent) and woken again before the moment: awake, a plan pending.
    private func awakeWithAPlan() -> ChargeController {
        let c = holding()
        c.willSleep()
        c.didWake(now: clockNow.addingTimeInterval(3600))
        XCTAssertNotNil(c.wakePlan, "the fixture has no plan pending")
        return c
    }

    // ── The hold ────────────────────────────────────────────────────────────

    func testItHoldsWhereTheBatteryIsThroughTheHelper() throws {
        let c = holding()
        XCTAssertEqual(c.lastDecision?.osLimit, 54)
        XCTAssertEqual(c.lastDecision?.readyBy, ReadyByState(by: by, raiseAt: raiseAt, raiseTo: 80))
        XCTAssertEqual(helper.commands, [.setChargeLimit(54)], "54 is not a limit macOS takes by itself")
        XCTAssertEqual(client.state?.mclLimit, 54)
        XCTAssertEqual(c.status, .active(try XCTUnwrap(c.lastDecision)))
    }

    /// The card's "held at" follows the hold as it follows every other hold.
    func testTheBatteryCardFollowsTheHold() {
        let c = holding()
        XCTAssertEqual(limitInForce.value, 54)
        XCTAssertEqual(ChargeController.limitForMonitor(settings: settings, inForce: limitInForce), 54)
        c.tick(now: raiseAt)
        XCTAssertEqual(limitInForce.value, 80)
        XCTAssertEqual(ChargeController.limitForMonitor(settings: settings, inForce: limitInForce), 80)
    }

    func testTheMomentComesFromTheCalendarEachTick() throws {
        let c = holding()
        XCTAssertEqual(c.lastDecision?.readyBy?.by, by)
        // The Mac is carried to India: it is 4:30 there, and the next 7:00 is at 01:30 UTC, two and a half hours off.
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        c.tick()
        XCTAssertEqual(c.lastDecision?.readyBy?.by, Self.utc("2026-11-13T01:30:00Z"))
        calendar = Self.utcCalendar
        settings.chargeReadyByMinutes = 480
        XCTAssertEqual(c.lastDecision?.readyBy?.by, Self.utc("2026-11-13T08:00:00Z"), "a changed time is acted on at once")
    }

    func testAnUnplugEndsTheHold() {
        let c = holding()
        battery = Self.plugged(54, ac: false)
        c.tick()
        XCTAssertEqual(c.lastDecision?.reason, .limit)
        XCTAssertEqual(c.lastDecision?.osLimit, 80)
        XCTAssertNil(c.lastDecision?.readyBy)
    }

    func testWithTimeToSpareNothingIsHeldBackBeyondTheWindow() {
        // 20:00 is 11 hours from 7:00, 8:00 the next morning is 23 hours: outside the window.
        clockNow = Self.utc("2026-11-12T07:30:00Z")   // the next 7:00 is 23.5 hours away
        let c = make()
        XCTAssertEqual(c.lastDecision?.reason, .limit, "a Mac plugged in at 7:30 must not sit at 54% all day")
        XCTAssertEqual(c.lastDecision?.osLimit, 80)
        XCTAssertTrue(helper.commands.isEmpty)
    }

    // ── The start moment, awake ─────────────────────────────────────────────

    func testItRaisesTheLimitItselfWhenTheMomentComesWhileAwake() {
        let c = holding()
        XCTAssertEqual(c.readyByTimerAt, raiseAt, "its own wake-up is set for the start moment")
        c.readyByDue(now: raiseAt)
        XCTAssertEqual(c.lastDecision?.osLimit, 80)
        XCTAssertEqual(c.lastDecision?.readyBy, ReadyByState(by: by, raiseAt: nil, raiseTo: 80), "charging for Ready By")
        XCTAssertEqual(client.state?.mclLimit, 80, "80 is one macOS takes by itself")
        XCTAssertNil(c.readyByTimerAt, "and nothing is left waiting")
    }

    func testTheStartMomentIsNotEarlyAndNotLate() {
        let c = holding()
        c.tick(now: raiseAt.addingTimeInterval(-1))
        XCTAssertEqual(c.lastDecision?.osLimit, 54)
        c.tick(now: raiseAt)
        XCTAssertEqual(c.lastDecision?.osLimit, 80)
        // And it stays started: a later tick with the charge a little up does not hold it again.
        battery = Self.plugged(60, charging: true)
        c.tick(now: raiseAt.addingTimeInterval(60))
        XCTAssertEqual(c.lastDecision?.osLimit, 80)
    }

    func testNoTimeToSpareChargesAtOnceAndSetsNoWakeUp() {
        clockNow = Self.utc("2026-11-13T06:30:00Z")
        let c = make()
        XCTAssertEqual(c.lastDecision?.osLimit, 80)
        XCTAssertNil(c.lastDecision?.readyBy?.raiseAt)
        XCTAssertNil(c.readyByTimerAt)
    }

    func testTheWakeUpGoesWhenTheHoldEnds() {
        let c = holding()
        XCTAssertNotNil(c.readyByTimerAt)
        settings.chargeReadyByEnabled = false
        XCTAssertNil(c.readyByTimerAt)
        settings.chargeReadyByEnabled = true
        XCTAssertEqual(c.readyByTimerAt, raiseAt)
        settings.chargeControlEnabled = false
        XCTAssertNil(c.readyByTimerAt)
    }

    // ── Before the Mac sleeps ───────────────────────────────────────────────

    func testThePlanIsSentBeforeSleepAndWaitedFor() {
        let c = holding()
        var linkOpenWhenSent: Bool?
        helper.beforeSend = { [unowned self] cmd in
            if case .scheduleChargeLimit = cmd { linkOpenWhenSent = self.helper.isOpen }
        }
        c.willSleep()
        XCTAssertEqual(helper.waited, [.scheduleChargeLimit(limit: 80, at: raiseAt)],
                       "the plan was not waited for, or was not the plan")
        // Closing the connection is what makes the helper drop a plan, and the link lets go once a command is answered
        // unless it was asked to stay: so it was asked first.
        XCTAssertEqual(linkOpenWhenSent, true, "the connection was not held open when the plan went out")
        XCTAssertEqual(helper.openRequests.last, true, "and it is held open while the plan is pending")
        XCTAssertEqual(c.wakePlan, ChargeController.WakePlan(by: by, limit: 80, raiseAt: raiseAt))
        XCTAssertEqual(count(cancel), 0)
    }

    func testThePlanIsSentOnlyWhenTheHoldHasATimeToRaiseAt() {
        battery = Self.plugged(80)          // at the limit: nothing to hold below
        let c = make()
        c.willSleep()
        XCTAssertTrue(schedules.isEmpty)
        XCTAssertNil(c.wakePlan)
    }

    /// A plan the helper does not take leaves the hold running through sleep, and the battery sits at the hold level until
    /// someone wakes the Mac after the time. With no plan in place when the Mac is about to sleep, the battery charges as
    /// usual: the person's own limit goes in before it sleeps, and the log says so.
    func testAPlanTheHelperRefusesIsNotLeftHoldingThroughSleep() {
        helper.answer = { cmd in
            if case .scheduleChargeLimit = cmd { return FanReply(ok: false, message: ChargeRefusal.wakeNotScheduled) }
            return FanReply(ok: true, message: "ok")
        }
        let c = holding()
        XCTAssertEqual(client.state?.mclLimit, 54)
        c.willSleep()
        XCTAssertNil(c.wakePlan)
        XCTAssertEqual(helper.openRequests.last, false, "nothing is pending, so the connection is not held")
        XCTAssertEqual(client.state?.mclLimit, 80, "the Mac sleeps with the hold level still in force")
        XCTAssertNotEqual(c.lastDecision?.reason, .readyBy)
        XCTAssertTrue(lines.contains { $0.contains(ChargeRefusal.wakeNotScheduled) }, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.contains("charging as usual") && $0.contains("80%") }, lines.joined(separator: "\n"))
        XCTAssertEqual(count(cancel), 0)
    }

    /// A limit only the helper can set goes in too, waited for within the same budget, after the plan's own try.
    func testAHelperOnlyLimitIsWaitedForWhenThePlanIsRefused() {
        settings.chargeLimit = 87
        helper.answer = { cmd in
            if case .scheduleChargeLimit = cmd { return FanReply(ok: false, message: ChargeRefusal.wakeNotScheduled) }
            return FanReply(ok: true, message: "ok")
        }
        let c = holding()
        helper.landsOn = client
        c.willSleep()
        XCTAssertEqual(client.state?.mclLimit, 87)
        let waited = helper.waited
        XCTAssertEqual(waited.last, .setChargeLimit(87), "the person's limit was not waited for: \(waited)")
        XCTAssertTrue(waited.contains { if case .scheduleChargeLimit = $0 { return true } else { return false } })
        XCTAssertTrue(helper.waitedTimeouts.allSatisfy { $0 <= ChargeController.stopTimeout })
    }

    /// If that send cannot be confirmed either, the log says so plainly.
    func testALimitThatCannotBeConfirmedWhenThePlanIsRefusedIsSaidPlainly() {
        settings.chargeLimit = 87
        helper.answer = { cmd in
            switch cmd {
            case .scheduleChargeLimit: return FanReply(ok: false, message: ChargeRefusal.wakeNotScheduled)
            case .setChargeLimit: return FanReply(ok: false, message: "refused: not now")
            default: return FanReply(ok: true, message: "ok")
            }
        }
        let c = holding()
        c.willSleep()
        XCTAssertTrue(lines.contains { $0.contains("could not be confirmed") && $0.contains("sleep") },
                      lines.joined(separator: "\n"))
        XCTAssertNil(c.wakePlan)
    }

    /// Ready By is set aside for that sleep only: on the wake it holds again, and the plan is tried again at the next
    /// sleep; the status line follows the decision.
    func testReadyByIsBackAtTheWakeAfterAPlanWasRefused() {
        var refuse = true
        helper.answer = { cmd in
            if case .scheduleChargeLimit = cmd, refuse { return FanReply(ok: false, message: ChargeRefusal.wakeNotScheduled) }
            return FanReply(ok: true, message: "ok")
        }
        let c = holding()
        c.willSleep()
        XCTAssertEqual(client.state?.mclLimit, 80)
        c.didWake(now: clockNow.addingTimeInterval(3600))
        XCTAssertEqual(c.lastDecision?.reason, .readyBy, "Ready By stayed set aside after the wake")
        XCTAssertEqual(client.state?.mclLimit, 54, "the hold level did not come back")
        guard case .active(let d) = c.status, d.reason == .readyBy else { return XCTFail("status \(c.status)") }
        refuse = false
        c.willSleep()
        XCTAssertNotNil(c.wakePlan, "the plan was not tried again at the next sleep")
        XCTAssertEqual(client.state?.mclLimit, 54)
    }

    /// The helper not answering within the sleep budget does not hold the Mac up; the battery charges as usual.
    /// (A plan send that timed out can still land at the helper: harmless, it raises to the person's own limit and dies
    /// with the connection.)
    func testAHelperThatDoesNotAnswerTheSleepPlanIsNotLeftHoldingEither() {
        let c = holding()
        helper.gone = true
        c.willSleep()
        XCTAssertNil(c.wakePlan)
        XCTAssertTrue(lines.contains { $0.contains("plan") && $0.contains("no answer") }, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.contains("charging as usual") }, lines.joined(separator: "\n"))
        XCTAssertEqual(client.state?.mclLimit, 80)
    }

    // ── Going to sleep paused for heat ──────────────────────────────────────

    /// Pause When Hot is the rule above Ready By, so a hot pack at the moment of sleep made the decision the heat pause,
    /// no plan was sent, and nothing raised the limit asleep: Ready By was lost for the night. Going to sleep paused for
    /// heat, with Ready By on, the battery below the limit and the moment inside its window, the plan is sent all the
    /// same, for the later of the start moment and half an hour from now (`ChargeController.heatCoolingTime`), so the
    /// pack has cooled asleep.
    private func hotAtNight(_ celsius: Double = 40) {
        settings.chargePauseWhenHotEnabled = true
        settings.chargeMaxTemperatureC = 35
        battery?.temperature_C = celsius
    }

    private func plannedAt() -> Date? {
        for case .scheduleChargeLimit(_, let at) in helper.waited { return at }
        return nil
    }

    func testAHotPackAtSleepStillGetsAPlanForTheStartMoment() throws {
        hotAtNight()
        let c = make()
        XCTAssertEqual(c.lastDecision?.reason, .heat, "the fixture is not paused for heat")
        c.willSleep()
        let plan = try XCTUnwrap(c.wakePlan, "no plan for a hot pack at sleep")
        XCTAssertEqual(plan.limit, 80)
        XCTAssertEqual(plan.by, by)
        XCTAssertEqual(plan.raiseAt, raiseAt, "the start moment is later than half an hour from now")
        XCTAssertEqual(plannedAt(), raiseAt)
        XCTAssertEqual(helper.waited.last, .scheduleChargeLimit(limit: 80, at: raiseAt))
        XCTAssertEqual(ChargeController.heatCoolingTime, 30 * 60)
        // A plan made for a hot pack is for sleep only: awake with the pack still hot it is cancelled (the next sleep
        // sends it again), because the helper's own timer would raise the limit onto the hot pack with the Mac awake.
        c.didWake(now: clockNow.addingTimeInterval(3600))
        XCTAssertEqual(c.lastDecision?.reason, .heat)
        XCTAssertNil(c.wakePlan, "the plan outlived a wake with the pack still hot")
        XCTAssertEqual(count(cancel), 1)
        XCTAssertEqual(client.state?.mclLimit, 54)
    }

    /// Ready By had started charging and heat paused it: the start moment has passed, so the plan is for half an hour
    /// from now.
    func testAHotPackAfterTheStartMomentIsPlannedForHalfAnHourFromNow() throws {
        clockNow = raiseAt.addingTimeInterval(10 * 60)
        let c = make()
        XCTAssertEqual(c.lastDecision?.reason, .readyBy, "Ready By has started charging")
        hotAtNight()
        c.tick()
        XCTAssertEqual(c.lastDecision?.reason, .heat)
        c.willSleep()
        let plan = try XCTUnwrap(c.wakePlan)
        XCTAssertEqual(plan.raiseAt, clockNow.addingTimeInterval(ChargeController.heatCoolingTime))
        XCTAssertEqual(plannedAt(), clockNow.addingTimeInterval(30 * 60))
    }

    /// A start moment sooner than half an hour from now is put back to half an hour: the pack has to cool.
    func testAStartMomentSoonerThanTheCoolingTimeIsPutBackToIt() throws {
        clockNow = raiseAt.addingTimeInterval(-5 * 60)
        hotAtNight()
        let c = make()
        XCTAssertEqual(c.lastDecision?.reason, .heat)
        c.willSleep()
        let plan = try XCTUnwrap(c.wakePlan)
        XCTAssertEqual(plan.raiseAt, clockNow.addingTimeInterval(ChargeController.heatCoolingTime))
    }

    func testAHotPackWithReadyByOffGetsNoPlan() {
        hotAtNight()
        settings.chargeReadyByEnabled = false
        let c = make()
        c.willSleep()
        XCTAssertNil(c.wakePlan)
        XCTAssertTrue(schedules.isEmpty)
    }

    /// At or above the limit there is nothing to charge: no plan.
    func testAHotPackAtTheLimitGetsNoPlan() {
        battery = Self.plugged(80)
        hotAtNight()
        let c = make()
        c.willSleep()
        XCTAssertNil(c.wakePlan)
        XCTAssertTrue(schedules.isEmpty)
    }

    /// A moment outside its window (more than 12 hours off) gets none either, as without heat.
    func testAHotPackWithTheMomentBeyondTheWindowGetsNoPlan() {
        clockNow = Self.utc("2026-11-12T15:00:00Z")   // 16 hours before 07:00
        hotAtNight()
        let c = make()
        c.willSleep()
        XCTAssertNil(c.wakePlan)
        XCTAssertTrue(schedules.isEmpty)
    }

    /// The pack cools while the Mac is awake before the moment: the plan was cancelled at the wake (it was made for sleep
    /// only), Ready By decides again with nothing planned, and the next sleep sends the plan again.
    func testAPlanForAHotPackIsSentAgainAtTheNextSleepWhenItIsStillWanted() throws {
        hotAtNight()
        let c = make()
        c.willSleep()
        XCTAssertEqual(schedules.count, 1)
        battery?.temperature_C = 25
        c.didWake(now: clockNow.addingTimeInterval(3600))
        XCTAssertEqual(c.lastDecision?.reason, .heat, "heat resumes only after the pack has been cool for a while")
        XCTAssertNil(c.wakePlan, "a plan made for a hot pack outlived the wake")
        XCTAssertEqual(count(cancel), 1)
        let later = clockNow.addingTimeInterval(3600 + ChargePolicy.heatResumeAfter + 1)
        c.tick(now: later)
        XCTAssertEqual(c.lastDecision?.reason, .readyBy)
        XCTAssertNil(c.wakePlan)
        XCTAssertEqual(count(cancel), 1, "nothing more to cancel")
        c.willSleep(now: later)
        XCTAssertEqual(schedules.count, 2, "the plan was not sent again before the next sleep")
        XCTAssertEqual(c.wakePlan?.by, by)
        XCTAssertEqual(c.wakePlan?.limit, 80)
        XCTAssertEqual(client.state?.mclLimit, 54)
    }

    // ── A plan for a hot pack is for sleep only ─────────────────────────────

    /// What the real helper does with a plan, as far as these tests need: the last plan sent stands until a cancel is sent
    /// after it, and at its moment the helper writes the plan's limit, whether the Mac is awake or asleep.
    private func helperWritesItsPlan() {
        guard let i = helper.commands.lastIndex(where: { if case .scheduleChargeLimit = $0 { return true } else { return false } }),
              case .scheduleChargeLimit(let limit, _) = helper.commands[i],
              !helper.commands[(i + 1)...].contains(cancel) else { return }
        client.state?.mclLimit = limit
    }

    /// The start moment is sooner than the cooling time, so the plan for a hot pack is for half an hour on.
    private func hotAndAboutToSleep() -> ChargeController {
        clockNow = raiseAt.addingTimeInterval(-5 * 60)
        hotAtNight()
        let c = make()
        XCTAssertEqual(c.lastDecision?.reason, .heat, "the fixture is not paused for heat")
        return c
    }

    /// A reviewer's probe: pack hot, Ready By on, the plan for 30 minutes on, the Mac wakes after 10 with the pack still
    /// hot, and at the plan's moment the helper's own timer wrote the person's limit onto it while the app said nothing
    /// and never put its hold back. The limit in force is asserted at each step.
    func testAPlanForAHotPackNeverRaisesTheLimitWhileTheMacIsAwake() throws {
        let c = hotAndAboutToSleep()
        XCTAssertEqual(client.state?.mclLimit, 54, "hot, before sleep")
        c.willSleep()
        let plan = try XCTUnwrap(c.wakePlan)
        XCTAssertEqual(plan.raiseAt, clockNow.addingTimeInterval(30 * 60))
        XCTAssertEqual(client.state?.mclLimit, 54, "asleep, the hold stays until the plan's moment")
        c.didWake(now: clockNow.addingTimeInterval(10 * 60))
        XCTAssertEqual(c.lastDecision?.reason, .heat, "still hot after ten minutes")
        XCTAssertNil(c.wakePlan, "the plan is for sleep only; the Mac is awake")
        XCTAssertEqual(count(cancel), 1)
        XCTAssertEqual(client.state?.mclLimit, 54, "awake and hot")
        lines = []
        helperWritesItsPlan()       // the plan's moment: the cancel has gone, so there is nothing for the helper to write
        c.periodicTick(now: plan.raiseAt.addingTimeInterval(1))
        XCTAssertEqual(client.state?.mclLimit, 54, "the limit was raised onto a pack that is still hot")
        XCTAssertFalse(lines.contains { $0.contains("changed outside") }, lines.joined(separator: "\n"))
        // Still wanted, so it is sent again before the next sleep.
        let again = plan.raiseAt.addingTimeInterval(2)
        c.willSleep(now: again)
        XCTAssertEqual(schedules.count, 2)
        XCTAssertEqual(c.wakePlan?.raiseAt, again.addingTimeInterval(ChargeController.heatCoolingTime))
        XCTAssertEqual(client.state?.mclLimit, 54)
    }

    /// The Mac slept through the plan's moment, the helper wrote the limit, and it woke with the pack still hot: the hold
    /// goes back at once, and the log says what happened: the helper's write was its plan working, not an outside change.
    func testAHelperWriteAsleepOntoAPackStillHotIsPutBackAndSaidPlainly() throws {
        let c = hotAndAboutToSleep()
        c.willSleep()
        let plan = try XCTUnwrap(c.wakePlan)
        helperWritesItsPlan()
        XCTAssertEqual(client.state?.mclLimit, 80, "the fixture: the helper raised the limit asleep")
        lines = []
        c.didWake(now: plan.raiseAt.addingTimeInterval(60))
        XCTAssertEqual(client.state?.mclLimit, 54, "the limit was left raised on a hot pack")
        XCTAssertTrue(lines.contains {
            $0.contains("the helper raised the limit to 80% as planned, but the battery is still paused for heat; holding again")
        }, lines.joined(separator: "\n"))
        XCTAssertFalse(lines.contains { $0.contains("changed outside") }, lines.joined(separator: "\n"))
        XCTAssertNil(c.wakePlan)
        XCTAssertEqual(count(cancel), 1)
    }

    /// A Ready By plan, the Mac awake, and the pack heats up between two looks: at the plan's moment the helper writes
    /// the limit. The pass that finds it is not an outside change, and the decision is the heat pause, so the hold goes
    /// straight back.
    func testAPlannedWriteOntoAPackThatHeatedUpSinceTheLastLookIsPutBack() {
        settings.chargePauseWhenHotEnabled = true
        settings.chargeMaxTemperatureC = 35
        battery?.temperature_C = 25
        let c = awakeWithAPlan()
        battery?.temperature_C = 40
        helperWritesItsPlan()
        lines = []
        c.periodicTick(now: raiseAt.addingTimeInterval(1))
        XCTAssertEqual(c.lastDecision?.reason, .heat)
        XCTAssertEqual(client.state?.mclLimit, 54, "the limit was left raised on a hot pack")
        XCTAssertTrue(lines.contains { $0.contains("as planned, but the battery is still paused for heat; holding again") },
                      lines.joined(separator: "\n"))
        XCTAssertFalse(lines.contains { $0.contains("changed outside") }, lines.joined(separator: "\n"))
        XCTAssertNil(c.wakePlan, "awake and hot: the plan is cancelled")
        XCTAssertEqual(count(cancel), 1)
    }

    /// The helper's timer can fire before it has processed the cancel. The write that lands then is still its own plan
    /// working, and the app has not been told yet that the plan is gone.
    func testAWriteThatLandsBeforeTheHelperAnswersTheCancelIsNotAnOutsideChange() throws {
        let c = hotAndAboutToSleep()
        c.willSleep()
        let plan = try XCTUnwrap(c.wakePlan)
        helper.defersOnly = { $0 == FanCommand.cancelScheduledChargeLimit }
        c.didWake(now: clockNow.addingTimeInterval(10 * 60))
        XCTAssertEqual(count(cancel), 1)
        XCTAssertNil(c.wakePlan)
        client.state?.mclLimit = 80         // the helper's timer fired just before the cancel was processed
        lines = []
        c.periodicTick(now: plan.raiseAt.addingTimeInterval(1))
        XCTAssertFalse(lines.contains { $0.contains("changed outside") }, lines.joined(separator: "\n"))
        helper.flushReplies()
        XCTAssertEqual(client.state?.mclLimit, 54, "put back at once")
        XCTAssertTrue(lines.contains { $0.contains("as planned, but the battery is still paused for heat; holding again") },
                      lines.joined(separator: "\n"))
    }

    /// The ordinary Ready By plan is still the app's own at its moment, and nothing is said against it.
    func testTheOrdinaryReadyByPlanIsStillExpectedAtItsMoment() {
        let c = awakeWithAPlan()
        lines = []
        helperWritesItsPlan()
        c.periodicTick(now: raiseAt.addingTimeInterval(1))
        XCTAssertEqual(client.state?.mclLimit, 80)
        XCTAssertFalse(lines.contains { $0.contains("changed outside") || $0.contains("as planned, but") },
                       lines.joined(separator: "\n"))
        XCTAssertEqual(c.lastDecision?.reason, .readyBy)
        XCTAssertNil(c.lastDecision?.readyBy?.raiseAt, "Ready By is charging now")
    }

    // ── The helper's write at the moment, with the Mac awake ────────────────

    /// Awake with a plan pending, the helper's own timer writes the limit at the moment. The app's 30 s pass found macOS
    /// holding 80 where it had put 54, called it "changed outside Charge Control" and put things back. At the moment
    /// the planned limit is the app's own.
    func testTheHelpersWriteAtTheMomentIsNotTakenForSomeoneElsesChange() {
        let c = awakeWithAPlan()
        lines = []
        client.state?.mclLimit = 80   // what the helper's timer wrote
        c.periodicTick(now: raiseAt.addingTimeInterval(1))
        XCTAssertFalse(lines.contains { $0.contains("changed outside") }, lines.joined(separator: "\n"))
        XCTAssertEqual(client.state?.mclLimit, 80)
        XCTAssertEqual(c.lastDecision?.readyBy?.raiseAt, nil, "Ready By is charging now")
        XCTAssertEqual(count(cancel), 1, "the plan is cancelled once the app has raised the limit itself")
        XCTAssertNil(c.wakePlan)
    }

    /// Only at the moment: the same limit written before it, by anyone, is still a change.
    func testTheSameLimitBeforeTheMomentIsStillAChange() {
        let c = awakeWithAPlan()
        lines = []
        client.state?.mclLimit = 80
        c.periodicTick(now: raiseAt.addingTimeInterval(-600))
        XCTAssertTrue(lines.contains { $0.contains("changed outside") && $0.contains("the limit is 80, not 54") },
                      lines.joined(separator: "\n"))
    }

    /// And only the planned limit: another value at the moment is a change like any other.
    func testAnotherLimitAtTheMomentIsStillAChange() {
        let c = awakeWithAPlan()
        lines = []
        client.state?.mclLimit = 70
        c.periodicTick(now: raiseAt.addingTimeInterval(1))
        XCTAssertTrue(lines.contains { $0.contains("changed outside") }, lines.joined(separator: "\n"))
    }

    // ── Guards that a gate upstream masked ──────────────────────────────────

    /// `sendThePlan` has a protocol guard of its own: the tick's gate (no moment for a helper that speaks 2) means the
    /// decision is never Ready By then, so through `willSleep` the guard is never the one that decides. Asked directly,
    /// with a decision that is Ready By and a helper that no longer speaks 3, nothing is sent.
    func testThePlanIsNotSentToAHelperThatDoesNotKnowIt() {
        let c = holding()
        XCTAssertEqual(c.lastDecision?.reason, .readyBy)
        helper.speaksReadyBy = false
        c.sendThePlan(deadline: Date().addingTimeInterval(2), now: nil)
        XCTAssertTrue(schedules.isEmpty, "a plan was sent to a helper that closes the connection on it")
        XCTAssertNil(c.wakePlan)
        XCTAssertEqual(helper.waited.count, 0)
        helper.speaksReadyBy = true
        c.sendThePlan(deadline: Date().addingTimeInterval(2), now: nil)
        XCTAssertEqual(schedules.count, 1, "and with protocol 3 it goes")
    }

    /// The one-shot timer for the start moment is really set for it: the date the run loop will fire it at, not only the
    /// date the controller says it asked for.
    func testTheStartMomentTimerReallyFiresAtTheStartMoment() throws {
        let c = holding()
        XCTAssertEqual(c.readyByTimerAt, raiseAt)
        let fire = try XCTUnwrap(c.readyByTimerFireDate, "no timer is scheduled")
        XCTAssertEqual(fire.timeIntervalSince(raiseAt), 0, accuracy: 0.5)
        // A changed time moves it with the moment.
        settings.chargeReadyByMinutes = 480
        let later = try XCTUnwrap(c.readyByTimerFireDate)
        XCTAssertEqual(later.timeIntervalSince(raiseAt), 3600, accuracy: 0.5, "the timer did not follow the new time")
        // And none while it has no moment to fire for.
        settings.chargeReadyByEnabled = false
        XCTAssertNil(c.readyByTimerFireDate)
    }

    func testTheSameHoldIsPlannedAgainBeforeEverySleep() {
        let c = holding()
        c.willSleep()
        c.didWake(now: clockNow.addingTimeInterval(3600))
        c.willSleep()
        XCTAssertEqual(helper.waited.filter { if case .scheduleChargeLimit = $0 { return true } else { return false } }.count, 2,
                       "a replaced plan is harmless; one the helper has lost would be missing")
        XCTAssertEqual(count(cancel), 0)
    }

    // ── On a wake ───────────────────────────────────────────────────────────

    /// The Mac wakes by itself many times a night. A wake before the moment leaves the plan, and the hold.
    func testAWakeBeforeTheMomentLeavesThePlanAndTheHold() {
        let c = holding()
        c.willSleep()
        let plan = c.wakePlan
        for hours in [1.0, 3, 5] {
            c.didWake(now: clockNow.addingTimeInterval(hours * 3600))
            XCTAssertEqual(c.wakePlan, plan, "a wake cancelled the plan")
            XCTAssertEqual(c.lastDecision?.osLimit, 54)
            c.willSleep()
        }
        XCTAssertEqual(count(cancel), 0, "the plan was cancelled by a wake that was not its moment")
        XCTAssertEqual(helper.openRequests.last, true)
    }

    func testAWakeAfterTheMomentRaisesTheLimitAndCancelsThePlan() {
        let c = holding()
        c.willSleep()
        // While the Mac slept the helper raised the limit.
        client.state?.mclLimit = 80
        c.didWake(now: raiseAt.addingTimeInterval(2))
        XCTAssertEqual(c.lastDecision?.osLimit, 80)
        XCTAssertEqual(client.state?.mclLimit, 80)
        XCTAssertEqual(limitInForce.value, 80)
        XCTAssertEqual(count(cancel), 1, "the plan the helper may still hold is cancelled")
        XCTAssertNil(c.wakePlan)
        XCTAssertEqual(helper.openRequests.last, false, "the connection is let go with nothing left pending")
        XCTAssertFalse(lines.contains { $0.contains("changed outside Charge Control") },
                       "the helper's own raise was taken for someone else's change: \(lines.joined(separator: "\n"))")
    }

    /// It raises the limit itself even when the helper did nothing (a Mac that woke late, a charger back in).
    func testAWakeAfterTheMomentRaisesTheLimitEvenIfTheHelperDidNot() {
        let c = holding()
        c.willSleep()
        c.didWake(now: raiseAt.addingTimeInterval(600))
        XCTAssertEqual(client.state?.mclLimit, 80)
        XCTAssertEqual(count(cancel), 1)
    }

    // ── Each real reason to end the plan ────────────────────────────────────

    /// A hold that ends just as the Mac goes to sleep has its plan cancelled before the Mac sleeps, waited for: a Mac
    /// that has gone to sleep sends nothing.
    func testAPlanCancelledAsTheMacGoesToSleepIsWaitedFor() {
        let c = awakeWithAPlan()
        battery = Self.plugged(54, ac: false)   // unplugged, and the tick for it has not run yet
        c.willSleep(now: clockNow.addingTimeInterval(3700))
        XCTAssertEqual(helper.waited.filter { $0 == .cancelScheduledChargeLimit }.count, 1)
        XCTAssertNil(c.wakePlan)
    }

    /// A plan lives on the connection. A reset that closed it took the plan with it; one that left it open (the Fans tab
    /// released everything) did not, so the plan is still there to be cancelled when the hold ends.
    func testAResetThatClosedTheConnectionTakesThePlanWithIt() {
        let c = awakeWithAPlan()
        helper.keepOpen(false)      // the socket is gone
        helper.reset()
        XCTAssertNil(c.wakePlan)
        XCTAssertTrue(lines.contains { $0.contains("reset") && $0.contains("plan") }, lines.joined(separator: "\n"))
    }

    func testAResetThatLeftTheConnectionOpenKeepsThePlanToCancelLater() {
        let c = awakeWithAPlan()
        XCTAssertTrue(helper.isOpen)
        helper.reset()
        XCTAssertNotNil(c.wakePlan)
        settings.chargeReadyByEnabled = false
        XCTAssertEqual(count(cancel), 1, "the plan the helper still held was not cancelled")
    }

    func testAPendingPlanIsLeftAloneWhileNothingChanges() {
        let c = awakeWithAPlan()
        c.tick(now: clockNow.addingTimeInterval(3700))
        c.periodicTick(now: clockNow.addingTimeInterval(3730))
        XCTAssertEqual(count(cancel), 0)
        XCTAssertNotNil(c.wakePlan)
    }

    func testUnpluggingCancelsThePlan() {
        let c = awakeWithAPlan()
        battery = Self.plugged(54, ac: false)
        c.tick(now: clockNow.addingTimeInterval(3700))
        XCTAssertEqual(count(cancel), 1)
        XCTAssertNil(c.wakePlan)
    }

    func testSwitchingReadyByOffCancelsThePlan() {
        let c = awakeWithAPlan()
        settings.chargeReadyByEnabled = false
        XCTAssertEqual(count(cancel), 1)
        XCTAssertNil(c.wakePlan)
        XCTAssertEqual(helper.openRequests.last, false)
    }

    func testChangingTheTimeCancelsThePlan() {
        let c = awakeWithAPlan()
        settings.chargeReadyByMinutes = 480
        XCTAssertEqual(count(cancel), 1, "a wake at the old time would raise the limit an hour early")
        XCTAssertNil(c.wakePlan)
    }

    func testChangingTheLimitCancelsThePlan() {
        let c = awakeWithAPlan()
        settings.chargeLimit = 90
        XCTAssertEqual(count(cancel), 1, "a plan for 80 would write the wrong limit")
        XCTAssertNil(c.wakePlan)
    }

    func testChargeToFullCancelsThePlan() {
        let c = awakeWithAPlan()
        c.pressFullCharge()
        XCTAssertEqual(c.lastDecision?.reason, .fullCharge)
        XCTAssertEqual(count(cancel), 1)
        XCTAssertNil(c.wakePlan)
    }

    /// Switching Charge Control off takes the plan back first, waited for, and before macOS is put back: the helper
    /// writes nothing after that.
    func testSwitchingChargeControlOffCancelsThePlanBeforePuttingMacOSBack() {
        let c = awakeWithAPlan()
        var heldWhenCancelled: NativeChargeState?
        helper.beforeSend = { [unowned self] cmd in
            if cmd == .cancelScheduledChargeLimit { heldWhenCancelled = self.client.state }
        }
        settings.chargeControlEnabled = false
        XCTAssertEqual(helper.waited.filter { $0 == .cancelScheduledChargeLimit }.count, 1, "the cancel was not waited for")
        XCTAssertEqual(heldWhenCancelled?.mclLimit, 54, "macOS was put back before the plan was cancelled")
        XCTAssertEqual(client.state, found)
        XCTAssertNil(c.wakePlan)
    }

    /// A quit in the middle of a hold: the plan is cancelled (the Fans tab may be holding the connection, which would
    /// keep the plan alive), and macOS's own settings are put back.
    func testQuittingDuringAHoldCancelsThePlanAndPutsMacOSsOwnSettingsBack() {
        let c = awakeWithAPlan()
        XCTAssertEqual(client.state?.mclLimit, 54)
        c.shutdown()
        XCTAssertEqual(helper.waited.filter { $0 == .cancelScheduledChargeLimit }.count, 1)
        XCTAssertEqual(client.state, found, "macOS was left holding the limit after the quit")
        XCTAssertNil(settings.chargeRestoreRecord)
        XCTAssertNil(c.wakePlan)
    }

    /// With no record of macOS's own settings there is nothing to put back, and the plan still goes: the wake must not
    /// outlive the app whatever else the quit does or does not do.
    func testQuittingWithNoRecordStillCancelsThePlan() {
        let c = awakeWithAPlan()
        settings.chargeRestoreRecord = nil
        c.shutdown()
        XCTAssertEqual(helper.waited.filter { $0 == .cancelScheduledChargeLimit }.count, 1)
        XCTAssertNil(c.wakePlan)
    }

    func testQuittingDuringAHoldWithNoPlanSendsNoCancel() {
        let c = holding()
        c.shutdown()
        XCTAssertEqual(count(cancel), 0, "nothing was planned, so nothing is cancelled")
        XCTAssertEqual(client.state, found)
    }

    func testAnotherAccountComingOnScreenCancelsThePlan() {
        let c = awakeWithAPlan()
        c.sessionResigned()
        XCTAssertEqual(helper.waited.filter { $0 == .cancelScheduledChargeLimit }.count, 1)
        XCTAssertNil(c.wakePlan)
    }

    // ── A helper that cannot do it ──────────────────────────────────────────

    /// A helper that speaks protocol 2 closes the connection on a command it does not know, which ends a drain and hands
    /// the fans back. It is never sent one, the battery charges to the limit as usual, and the section says why.
    func testAProtocolTwoHelperIsNeverSentAPlanAndTheBatteryChargesToTheLimit() {
        helper.speaksReadyBy = false
        let c = make()
        XCTAssertEqual(c.lastDecision?.reason, .limit)
        XCTAssertEqual(c.lastDecision?.osLimit, 80)
        XCTAssertEqual(client.state?.mclLimit, 80)
        c.willSleep()
        c.didWake(now: clockNow.addingTimeInterval(60))
        settings.chargeReadyByEnabled = false
        settings.chargeReadyByEnabled = true
        c.shutdown()
        XCTAssertTrue(schedules.isEmpty, "a plan was sent to a helper that does not know it")
        XCTAssertEqual(count(cancel), 0, "a cancel was sent to a helper that does not know it")
    }

    /// A protocol 2 helper does control charging, so the status does not say it cannot: it is what the features that
    /// work make it, and the one thing Ready By needs is said apart (`readyByNeedsNewerHelper`), in its own sentence.
    func testAProtocolTwoHelperIsNotSaidToBeUnableToControlCharging() {
        helper.speaksReadyBy = false
        let c = make()
        if case .active = c.status {} else { XCTFail("the status was replaced by \(c.status)") }
        XCTAssertTrue(c.readyByNeedsNewerHelper)
        XCTAssertEqual(ChargeController.readyByNeedsNewerHelperText,
                       "Ready By needs a newer Anode helper. Press Install Helper\u{2026} to update it.")
        XCTAssertNotEqual(ChargeController.readyByNeedsNewerHelperText, ChargeController.helperOutdatedText)
        // Ready By off: nothing is said about it.
        settings.chargeReadyByEnabled = false
        XCTAssertFalse(c.readyByNeedsNewerHelper)
        settings.chargeReadyByEnabled = true
        XCTAssertTrue(c.readyByNeedsNewerHelper)
    }

    /// A helper too old for any charge command keeps the old sentence, and has no Ready By sentence of its own.
    func testAHelperTooOldForAnyChargeCommandKeepsTheOldSentence() {
        helper.available = false
        helper.outdated = true
        helper.speaksReadyBy = false
        let c = make()
        XCTAssertEqual(c.status, .needsHelper(ChargeController.helperOutdatedText))
        XCTAssertFalse(c.readyByNeedsNewerHelper)
    }

    /// The section is told when the sentence appears, though the status stays as it was.
    func testTheSectionIsToldWhenTheNewerHelperSentenceAppears() {
        helper.speaksReadyBy = false
        helper.answersAtOnce = false   // the helper has not answered yet
        let c = make()
        XCTAssertFalse(c.readyByNeedsNewerHelper, "said before the helper answered")
        var heard = 0
        let token = c.observeChanges { heard += 1 }
        helper.firstAnswer()
        XCTAssertTrue(c.readyByNeedsNewerHelper)
        XCTAssertGreaterThan(heard, 0)
        withExtendedLifetime(token) {}
    }

    /// The features that need only protocol 2 keep working with a protocol 2 helper, Ready By on or off.
    func testAProtocolTwoHelperStillServesTheOtherFeatures() {
        helper.speaksReadyBy = false
        settings.chargeLimit = 63
        let c = make()
        XCTAssertEqual(helper.commands, [.setChargeLimit(63)], "a limit only the helper can set still goes to it")
        XCTAssertEqual(client.state?.mclLimit, 63)
        battery = Self.plugged(90)
        settings.chargeLimit = 80
        c.pressDrain()
        XCTAssertTrue(helper.commands.contains(.discharge(toPercent: 80)), "a drain no longer works: \(helper.commands)")
    }

    /// A helper that stopped answering left Ready By silently off until the Beta Features window was next shown: only a
    /// limit waiting for the helper, or a drain, counted as needing it. Ready By switched on does, so the helper is
    /// looked for again with the same back-off, 30 s, 60 s, 120 s and then every five minutes.
    func testAHelperThatStoppedAnsweringIsLookedForAgainWhileReadyByIsOn() {
        helper.available = false
        helper.speaksReadyBy = false
        let c = make()
        XCTAssertEqual(helper.rechecks, 0)
        func at(_ s: TimeInterval) { c.periodicTick(now: clockNow.addingTimeInterval(s)) }
        at(31)
        XCTAssertEqual(helper.rechecks, 1, "not looked for again 30 s later")
        at(61)
        XCTAssertEqual(helper.rechecks, 1, "looked for again too soon")
        at(92)
        XCTAssertEqual(helper.rechecks, 2)
        at(213)
        XCTAssertEqual(helper.rechecks, 3)
        at(300)
        XCTAssertEqual(helper.rechecks, 3)
        at(514)
        XCTAssertEqual(helper.rechecks, 4)
    }

    /// With Ready By off nothing needs the helper, and it is left asleep.
    func testAHelperThatStoppedAnsweringIsLeftAloneWithReadyByOff() {
        helper.available = false
        helper.speaksReadyBy = false
        settings.chargeReadyByEnabled = false
        let c = make()
        for s in [31.0, 92, 213, 514, 1000] { c.periodicTick(now: clockNow.addingTimeInterval(s)) }
        XCTAssertEqual(helper.rechecks, 0)
    }

    /// A helper that answered but is too old is not woken to say so again, as for any other need.
    func testAnOutdatedHelperIsNotLookedForAgain() {
        helper.available = false
        helper.outdated = true
        helper.speaksReadyBy = false
        let c = make()
        for s in [31.0, 92, 213] { c.periodicTick(now: clockNow.addingTimeInterval(s)) }
        XCTAssertEqual(helper.rechecks, 0)
    }

    func testWithNoHelperTheSectionSaysSoAndTheBatteryChargesToTheLimit() {
        helper.available = false
        helper.installed = false
        helper.speaksReadyBy = false
        let c = make()
        XCTAssertEqual(c.status, .needsHelper(ChargeController.readyByNeedsHelperText))
        XCTAssertEqual(c.lastDecision?.osLimit, 80)
        XCTAssertEqual(client.state?.mclLimit, 80)
        XCTAssertTrue(helper.commands.isEmpty)
    }

    /// Ready By off asks nothing of the helper and says nothing about it.
    func testWithReadyByOffNothingIsSaidAboutTheHelper() throws {
        settings.chargeReadyByEnabled = false
        helper.speaksReadyBy = false
        let c = make()
        XCTAssertEqual(c.status, .active(try XCTUnwrap(c.lastDecision)))
    }

    /// A helper that learns protocol 3 later (installed, or updated, while Anode runs) takes over from the next tick.
    func testAHelperThatTurnsUpHoldsFromThen() {
        helper.speaksReadyBy = false
        let c = make()
        XCTAssertEqual(c.lastDecision?.reason, .limit)
        helper.speaksReadyBy = true
        helper.becomeAvailable()
        XCTAssertEqual(c.lastDecision?.reason, .readyBy)
        XCTAssertEqual(client.state?.mclLimit, 54)
    }

    // ── After an unclean exit ───────────────────────────────────────────────

    /// The last run died in the middle of a hold with a plan pending. Its connection closing is what ended the plan at
    /// the helper. This run lifts macOS's limit at once and holds nothing for the delay, plan or no plan, and asks the
    /// helper nothing at all.
    func testTheDelayAfterAnUncleanExitHoldsNothingEarly() {
        let first = make()
        first.willSleep()
        XCTAssertEqual(client.state?.mclLimit, 54)
        XCTAssertNotNil(first.wakePlan)
        controller = nil   // a crash: no quit, the record stays
        let before = helper.commands.count
        let c = make()
        XCTAssertEqual(client.state, found, "the limit the dead run held was not lifted at launch")
        XCTAssertTrue(c.isWaitingToStart)
        c.tick()
        c.willSleep()
        c.didWake(now: clockNow.addingTimeInterval(120))
        c.periodicTick(now: clockNow.addingTimeInterval(150))
        c.resumeIfDue(now: Date().addingTimeInterval(ChargeController.startDelay - 10))
        XCTAssertEqual(client.state, found, "something was held during the delay")
        XCTAssertTrue(Array(helper.commands.dropFirst(before)).isEmpty,
                      "the helper was asked something during the delay: \(helper.commands.dropFirst(before))")
        XCTAssertNil(c.wakePlan)
        // After it, the policy holds again as from a cold start.
        c.resumeIfDue(now: Date().addingTimeInterval(ChargeController.startDelay + 1))
        XCTAssertEqual(c.lastDecision?.reason, .readyBy)
        XCTAssertEqual(client.state?.mclLimit, 54)
    }

    // ── The charge rate ─────────────────────────────────────────────────────

    /// The controller feeds the learner what the battery does, and what it learns changes the start moment.
    func testItLearnsTheChargeRateAndUsesIt() throws {
        settings.chargeReadyByEnabled = false
        battery = Self.plugged(40, charging: true, watts: 20)
        let c = make()
        // One percent a minute for six minutes on a 20 W charger, whose guess is 0.3: a measurement is believed by a
        // factor of 1.5 at most in one step, so the first is 0.45 and the rest of the way is learned over the next ones.
        var t = clockNow
        for s in stride(from: 30.0, through: 360, by: 30) {
            t = clockNow.addingTimeInterval(s)
            battery = Self.plugged(40 + Int((s / 60).rounded(.down)), charging: true, watts: 20)
            c.tick(now: t)
        }
        XCTAssertTrue(rateStore.rates.hasLearned(.under30), "nothing was learned")
        XCTAssertEqual(rateStore.rates.rate(for: .under30), 0.3 * ChargeRate.stepFactor, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(rateStore.saves, 1, "what was learned was not stored")
        XCTAssertFalse(rateStore.rates.hasLearned(.over65), "another class learned it too")

        // Held on the same charger, the start moment is from the learned 0.45 and not from the guess of 0.3.
        battery = Self.plugged(54, watts: 20)
        settings.chargeReadyByEnabled = true
        let lead = by.timeIntervalSince(try XCTUnwrap(c.lastDecision?.readyBy?.raiseAt))
        let learned = rateStore.rates.rate(for: .under30)
        XCTAssertEqual(lead, 26 / learned * 60 + 15 * 60, accuracy: 1, "the learned rate was not the one used")
        XCTAssertLessThan(lead, 26 / 0.3 * 60 + 15 * 60 - 600, "it is still going by the guess")
    }

    func testTheGuessIsUsedForAChargerNothingHasBeenLearnedFor() throws {
        battery = Self.plugged(54, watts: 20)    // 0.3 a minute: 26 points is 86.7 minutes
        let c = make()
        let lead = by.timeIntervalSince(try XCTUnwrap(c.lastDecision?.readyBy?.raiseAt))
        XCTAssertEqual(lead, 26 / 0.3 * 60 + 15 * 60, accuracy: 1)
        battery = Self.plugged(54, watts: 45)    // the middle class, 0.8
        settings.chargeLimit = 81
        settings.chargeLimit = 80
        let lead2 = by.timeIntervalSince(try XCTUnwrap(c.lastDecision?.readyBy?.raiseAt))
        XCTAssertEqual(lead2, 26 / 0.8 * 60 + 15 * 60, accuracy: 1)
    }

    func testWhatWasLearnedIsKeptForTheNextRun() throws {
        let store = SettingsChargeRateStore(settings: settings)
        var r = ChargeRate()
        r.record(1.2, for: .over65)
        store.save(r)
        // A controller made without a store of its own reads the settings it was given, and no others.
        let c = ChargeController(settings: settings, makeClient: { [weak self] in self?.client }, helper: helper,
                                 battery: { [weak self] in self?.battery }, chargerSwitch: { nil }, log: { _ in },
                                 workspace: center, limitInForce: limitInForce,
                                 noClientBecause: { ChargeController.NoClientReason(unsupportedMac: true, step: nil) },
                                 onConsole: { true },
                                 now: { [weak self] in self?.clockNow ?? Date() },
                                 calendar: { [weak self] in self?.calendar ?? .current })
        controller = c
        settings.chargeControlEnabled = true
        let lead = by.timeIntervalSince(try XCTUnwrap(c.lastDecision?.readyBy?.raiseAt))
        XCTAssertEqual(lead, 26 / 1.2 * 60 + 15 * 60, accuracy: 1)
    }
}

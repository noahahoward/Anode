import XCTest
@testable import PowerKit

// The helper's plan for Ready By: a charge limit to write at a moment, with the Mac woken for it.
//
// Every test here uses a fake power-event scheduler and, except the one that says so, a fake timer and a clock the
// test moves. NOTHING here may build a `SystemPowerEventScheduler` and call it: that puts an event in this Mac's real
// list of scheduled wakes, which outlives the test. The one test that touches a timer for real uses a fake scheduler
// and a wall-clock timer one second away, and nothing else.
//
// The class matches `--filter ChargeHelper` but not `--filter ChargeHelperTests`.

/// Scheduled wakes as a list in memory.
final class FakePowerEvents: PowerEventScheduler {
    private let lock = NSLock()
    private var _scheduled: [Date] = []
    private var _cancelled: [Date] = []
    private var _pending: Set<Date> = []
    private var _refuseSchedule = false
    private var _refuseCancel = false

    var scheduled: [Date] { lock.lock(); defer { lock.unlock() }; return _scheduled }
    var cancelled: [Date] { lock.lock(); defer { lock.unlock() }; return _cancelled }
    /// The wakes the system would still make.
    var pending: Set<Date> { lock.lock(); defer { lock.unlock() }; return _pending }
    var refuseSchedule: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _refuseSchedule }
        set { lock.lock(); _refuseSchedule = newValue; lock.unlock() }
    }
    var refuseCancel: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _refuseCancel }
        set { lock.lock(); _refuseCancel = newValue; lock.unlock() }
    }

    func scheduleWake(at date: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _scheduled.append(date)
        guard !_refuseSchedule else { return false }
        _pending.insert(date)
        return true
    }

    func cancelWake(at date: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _cancelled.append(date)
        guard !_refuseCancel else { return false }
        _pending.remove(date)
        return true
    }

    private var _cancelAlls = 0
    /// How many times every wake under the helper's name was asked to go.
    var cancelAlls: Int { lock.lock(); defer { lock.unlock() }; return _cancelAlls }
    /// Wakes a helper that was killed left in the system's list, as `IOPMSchedulePowerEvent` keeps them on disk.
    func leaveBehind(_ dates: [Date]) {
        lock.lock(); _pending.formUnion(dates); lock.unlock()
    }

    func cancelAllWakes() -> (removed: Int, failed: Int) {
        lock.lock(); defer { lock.unlock() }
        _cancelAlls += 1
        guard !_refuseCancel else { return (0, _pending.count) }
        let n = _pending.count
        _pending.removeAll()
        return (n, 0)
    }
}

/// A wall-clock timer the test fires by hand.
final class FakeWallTimer: WallClockTimer {
    private let lock = NSLock()
    private var _armedAt: Date?
    private var _fire: (() -> Void)?
    private var _arms = 0
    private var _disarms = 0

    var armedAt: Date? { lock.lock(); defer { lock.unlock() }; return _armedAt }
    var arms: Int { lock.lock(); defer { lock.unlock() }; return _arms }
    var disarms: Int { lock.lock(); defer { lock.unlock() }; return _disarms }
    /// The handler the last arming left, whether or not it has been disarmed since: a timer that was already on its
    /// way to firing when it was stopped.
    var lastHandler: (() -> Void)? { lock.lock(); defer { lock.unlock() }; return _fire }

    func arm(at date: Date, _ fire: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        _armedAt = date
        _fire = fire
        _arms += 1
    }

    func disarm() {
        lock.lock(); defer { lock.unlock() }
        _armedAt = nil
        _disarms += 1
    }

    /// The moment comes, as far as the timer is concerned.
    func fireNow() {
        lock.lock()
        let f = _armedAt == nil ? nil : _fire
        _armedAt = nil
        lock.unlock()
        f?()
    }
}

final class ChargeHelperPlanTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600

    private var events: FakePowerEvents!
    private var timer: FakeWallTimer!
    private var hw: FakeChargeHardware!
    private var clock: Date!
    private var lines: [String] = []

    override func setUp() {
        super.setUp()
        events = FakePowerEvents()
        timer = FakeWallTimer()
        hw = FakeChargeHardware(percent: 54, onAC: true)
        clock = t0
        lines = []
    }

    private func makeServer(withEvents: Bool = true, withCharge: Bool = true) -> FanHelperServer {
        let server = FanHelperServer(
            hardware: FakeFans([:]),
            configuration: .init(socketPath: NSTemporaryDirectory() + "bs-unused.sock", ownerUID: getuid(),
                                 pin: .signingIdentifier(FanDaemon.clientSigningIdentifier)),
            log: { [weak self] in self?.lines.append($0) },
            charge: withCharge ? hw : nil,
            powerEvents: withEvents ? events : nil,
            wakeTimer: timer)
        server.chargeTiming = .immediate
        server.now = { [weak self] in self?.clock ?? Date() }
        return server
    }

    private func plan(_ server: FanHelperServer, _ limit: Int = 80, in seconds: TimeInterval = 8 * 3600) -> FanReply {
        server.handle(.command(.scheduleChargeLimit(limit: limit, at: t0.addingTimeInterval(seconds))))
    }

    // ── Scheduling ──────────────────────────────────────────────────────────

    func testAPlanSchedulesAWakeAndArmsItsOwnTimerAndWritesNothingYet() {
        let server = makeServer()
        let at = t0.addingTimeInterval(8 * hour + 0.4)
        let reply = server.handle(.command(.scheduleChargeLimit(limit: 80, at: at)))
        XCTAssertTrue(reply.ok, reply.message)
        XCTAssertEqual(server.chargePlan?.limit, 80)
        XCTAssertEqual(server.chargePlan?.at, at)
        // The system keeps whole seconds: the wake is at the next one, never before the moment.
        let wake = Date(timeIntervalSince1970: at.timeIntervalSince1970.rounded(.up))
        XCTAssertEqual(events.scheduled, [wake])
        XCTAssertEqual(server.chargePlan?.wakeAt, wake)
        XCTAssertEqual(timer.armedAt, at, "the helper's own timer is for the moment itself")
        XCTAssertTrue(hw.limitWrites.isEmpty, "nothing is written before the moment")
        XCTAssertTrue(hw.cutWrites.isEmpty)
        XCTAssertTrue(lines.contains { $0.contains("80%") && $0.contains("wake") }, "\(lines)")
    }

    func testOnlyAHelperThatCanWakeTheMacTakesAPlan() {
        var reply = plan(makeServer(withEvents: false))
        XCTAssertEqual(reply, FanReply(ok: false, message: ChargeRefusal.cannotWake))
        reply = plan(makeServer(withCharge: false))
        XCTAssertEqual(reply, FanReply(ok: false, message: ChargeRefusal.noChargeControl))
        XCTAssertTrue(events.scheduled.isEmpty)
        XCTAssertNil(timer.armedAt)
    }

    func testALimitOutsideTwentyToOneHundredIsRefusedWithNothingScheduled() {
        let server = makeServer()
        for bad in [-5, 0, 19, 101, 500] {
            let reply = plan(server, bad)
            XCTAssertFalse(reply.ok, "\(bad)")
            XCTAssertTrue(reply.message.contains("20–100%"), "\(bad): \(reply.message)")
        }
        for good in [20, 63, 100] { XCTAssertTrue(plan(makeServer(), good).ok, "\(good)") }
        XCTAssertNil(server.chargePlan)
    }

    func testAMomentThatIsNotInTheFutureIsRefused() {
        let server = makeServer()
        for seconds in [0.0, -1, -3600] {
            let reply = plan(server, 80, in: seconds)
            XCTAssertEqual(reply, FanReply(ok: false, message: ChargeRefusal.planNotInTheFuture), "\(seconds)")
        }
        XCTAssertTrue(plan(server, 80, in: 1).ok, "a second ahead is the future")
        XCTAssertTrue(events.scheduled.count == 1)
    }

    func testAMomentMoreThanThirteenHoursAwayIsRefused() {
        let server = makeServer()
        XCTAssertEqual(FanHelperServer.chargePlanReach, 13 * 3600)
        let far = plan(server, 80, in: 13 * hour + 1)
        XCTAssertEqual(far, FanReply(ok: false, message: ChargeRefusal.planTooFarAway))
        XCTAssertTrue(events.scheduled.isEmpty)
        XCTAssertTrue(plan(server, 80, in: 13 * hour).ok, "thirteen hours exactly is allowed")
        let absurd = server.handle(.command(.scheduleChargeLimit(limit: 80, at: .distantFuture)))
        XCTAssertFalse(absurd.ok)
    }

    func testARefusedPlanLeavesNothingBehind() {
        let server = makeServer()
        _ = plan(server, 101)
        _ = plan(server, 80, in: -1)
        _ = plan(server, 80, in: 20 * hour)
        XCTAssertNil(server.chargePlan)
        XCTAssertTrue(server.isIdle)
        XCTAssertNil(timer.armedAt)
        XCTAssertEqual(timer.arms, 0)
    }

    /// If the system will not take the wake there is nothing to promise: no plan.
    func testAWakeTheSystemWillNotTakeIsNoPlan() {
        events.refuseSchedule = true
        let server = makeServer()
        let reply = plan(server)
        XCTAssertEqual(reply, FanReply(ok: false, message: ChargeRefusal.wakeNotScheduled))
        XCTAssertNil(server.chargePlan)
        XCTAssertNil(timer.armedAt)
        XCTAssertTrue(server.isIdle)
    }

    // ── Replacing and cancelling ────────────────────────────────────────────

    func testANewPlanReplacesTheOldAndItsWake() throws {
        let server = makeServer()
        XCTAssertTrue(plan(server, 80, in: 8 * 3600).ok)
        let first = try XCTUnwrap(events.scheduled.first)
        XCTAssertTrue(plan(server, 90, in: 7 * 3600).ok)
        XCTAssertEqual(server.chargePlan?.limit, 90)
        XCTAssertEqual(events.cancelled, [first], "the old wake was taken away")
        XCTAssertEqual(events.pending, [t0.addingTimeInterval(7 * 3600)], "one wake, the new one")
        XCTAssertEqual(timer.armedAt, t0.addingTimeInterval(7 * 3600))
    }

    /// The same moment again (the app sends the plan before every sleep): nothing is scheduled twice, and the limit is
    /// the new one.
    func testTheSameMomentAgainDoesNotScheduleASecondWake() {
        let server = makeServer()
        XCTAssertTrue(plan(server, 80).ok)
        XCTAssertTrue(plan(server, 85).ok)
        XCTAssertEqual(events.scheduled.count, 1)
        XCTAssertTrue(events.cancelled.isEmpty)
        XCTAssertEqual(server.chargePlan?.limit, 85)
        XCTAssertEqual(events.pending.count, 1)
    }

    func testAPlanTheSystemRefusedKeepsTheOldOne() {
        let server = makeServer()
        XCTAssertTrue(plan(server, 80, in: 8 * 3600).ok)
        events.refuseSchedule = true
        XCTAssertFalse(plan(server, 90, in: 7 * 3600).ok)
        XCTAssertEqual(server.chargePlan?.limit, 80, "the plan that was working is still the plan")
        XCTAssertEqual(server.chargePlan?.at, t0.addingTimeInterval(8 * 3600))
        XCTAssertEqual(events.pending, [t0.addingTimeInterval(8 * 3600)])
    }

    func testCancellingRemovesTheWakeAndWritesNothing() {
        let server = makeServer()
        XCTAssertTrue(plan(server).ok)
        let reply = server.handle(.command(.cancelScheduledChargeLimit))
        XCTAssertTrue(reply.ok, reply.message)
        XCTAssertNil(server.chargePlan)
        XCTAssertTrue(events.pending.isEmpty)
        XCTAssertNil(timer.armedAt, "the timer is stopped too")
        XCTAssertTrue(hw.limitWrites.isEmpty, "a cancelled plan writes nothing, now or later")
        XCTAssertTrue(server.isIdle)
        XCTAssertTrue(lines.contains { $0.lowercased().contains("cancel") }, "\(lines)")
    }

    func testCancellingWithNothingPlannedIsNotAFailure() {
        let server = makeServer()
        let reply = server.handle(.command(.cancelScheduledChargeLimit))
        XCTAssertTrue(reply.ok, reply.message)
        XCTAssertTrue(events.cancelled.isEmpty, "nothing was scheduled, so nothing is cancelled")
        XCTAssertTrue(hw.limitWrites.isEmpty)
        // Not even on a helper that cannot wake the Mac at all.
        XCTAssertTrue(makeServer(withEvents: false).handle(.command(.cancelScheduledChargeLimit)).ok)
    }

    /// A wake the system would not give back is left to wake the Mac once with nothing to do; the plan is still gone
    /// and still writes nothing.
    func testAWakeThatCannotBeCancelledStillEndsThePlan() {
        let server = makeServer()
        XCTAssertTrue(plan(server).ok)
        events.refuseCancel = true
        let reply = server.handle(.command(.cancelScheduledChargeLimit))
        XCTAssertTrue(reply.ok)
        XCTAssertNil(server.chargePlan)
        XCTAssertNil(timer.armedAt)
        XCTAssertTrue(lines.contains { $0.contains("WARNING") }, "\(lines)")
        clock = t0.addingTimeInterval(9 * hour)
        server.systemDidWake()
        XCTAssertTrue(hw.limitWrites.isEmpty, "the stray wake wrote nothing")
    }

    func testAPlanKeepsTheHelperFromBeingIdle() {
        let server = makeServer()
        XCTAssertTrue(server.isIdle)
        XCTAssertTrue(plan(server).ok)
        XCTAssertFalse(server.isIdle, "an on-demand helper that exited would take the plan with it")
        _ = server.handle(.command(.cancelScheduledChargeLimit))
        XCTAssertTrue(server.isIdle)
    }

    // ── The moment comes ────────────────────────────────────────────────────

    func testTheSystemsWakeNoticeAtTheMomentWritesTheLimitAndForgetsThePlan() throws {
        let server = makeServer()
        let at = t0.addingTimeInterval(8 * hour)
        XCTAssertTrue(plan(server, 80).ok)
        let wake = try XCTUnwrap(events.scheduled.first)
        server.systemWillSleep()
        clock = at
        server.systemDidWake()
        XCTAssertEqual(hw.limitWrites, [80])
        XCTAssertNil(server.chargePlan)
        XCTAssertEqual(events.cancelled, [wake], "its scheduled wake is removed once it has been used")
        XCTAssertNil(timer.armedAt)
        XCTAssertTrue(server.isIdle)
        XCTAssertTrue(lines.contains { $0.contains("80%") }, "\(lines)")
        // Once only.
        server.systemDidWake()
        XCTAssertEqual(hw.limitWrites, [80])
    }

    /// The wake lands within a second of the moment, either side of it.
    func testAWakeNoticeAFewSecondsBeforeTheMomentIsTheMoment() {
        let server = makeServer()
        XCTAssertTrue(plan(server).ok)
        clock = t0.addingTimeInterval(8 * hour - 2)
        server.systemDidWake()
        XCTAssertEqual(hw.limitWrites, [80])
    }

    /// The Mac wakes by itself many times a night. A wake before the moment leaves the plan where it is.
    func testAWakeBeforeTheMomentLeavesThePlan() {
        let server = makeServer()
        XCTAssertTrue(plan(server).ok)
        for hoursIn in [1.0, 3, 7.5] {
            clock = t0.addingTimeInterval(hoursIn * hour)
            server.systemWillSleep()
            server.systemDidWake()
        }
        XCTAssertTrue(hw.limitWrites.isEmpty)
        XCTAssertNotNil(server.chargePlan)
        XCTAssertEqual(events.pending.count, 1, "the wake is still scheduled")
        XCTAssertTrue(events.cancelled.isEmpty)
        XCTAssertEqual(timer.armedAt, t0.addingTimeInterval(8 * hour))
        clock = t0.addingTimeInterval(8 * hour + 3)
        server.systemDidWake()
        XCTAssertEqual(hw.limitWrites, [80])
    }

    func testItsOwnTimerWritesTheLimitWhenTheWakeNoticeNeverComes() {
        let server = makeServer()
        XCTAssertTrue(plan(server, 85).ok)
        clock = t0.addingTimeInterval(8 * hour)
        timer.fireNow()
        // The timer hands the news to the loop; the loop acts on it.
        XCTAssertTrue(hw.limitWrites.isEmpty, "the timer's own thread writes nothing")
        server.actOnPowerNotices()
        XCTAssertEqual(hw.limitWrites, [85])
        XCTAssertNil(server.chargePlan)
        XCTAssertEqual(events.pending.count, 0)
    }

    func testAnOldTimerThatFiresAfterTheCancelWritesNothing() {
        let server = makeServer()
        XCTAssertTrue(plan(server, 80, in: 8 * 3600).ok)
        let stale = timer.lastHandler
        _ = server.handle(.command(.cancelScheduledChargeLimit))
        XCTAssertTrue(plan(server, 90, in: 10 * 3600).ok)
        clock = t0.addingTimeInterval(8 * hour)
        let armsBefore = timer.arms
        stale?()
        server.actOnPowerNotices()
        XCTAssertTrue(hw.limitWrites.isEmpty, "the first plan's timer must not write the second plan's limit early")
        XCTAssertEqual(server.chargePlan?.limit, 90)
        XCTAssertEqual(timer.arms, armsBefore, "and does not touch the second plan's timer")
        XCTAssertEqual(timer.armedAt, t0.addingTimeInterval(10 * hour))
    }

    /// Whichever comes first, and only once.
    func testTheTimerAfterTheWakeNoticeWritesNothingMore() {
        let server = makeServer()
        XCTAssertTrue(plan(server).ok)
        let handler = timer.lastHandler
        clock = t0.addingTimeInterval(8 * hour)
        server.systemDidWake()
        XCTAssertEqual(hw.limitWrites, [80])
        handler?()
        server.actOnPowerNotices()
        XCTAssertEqual(hw.limitWrites, [80])
    }

    func testATimerThatFiresBeforeTheMomentWaitsForIt() {
        let server = makeServer()
        XCTAssertTrue(plan(server).ok)
        clock = t0.addingTimeInterval(6 * hour)   // the clock was set back, or the timer is early
        timer.fireNow()
        server.actOnPowerNotices()
        XCTAssertTrue(hw.limitWrites.isEmpty)
        XCTAssertEqual(timer.armedAt, t0.addingTimeInterval(8 * hour), "armed again for the moment itself")
        XCTAssertNotNil(server.chargePlan)
    }

    func testNoChargerAtTheMomentWritesNothingAndDropsThePlan() {
        let server = makeServer()
        XCTAssertTrue(plan(server).ok)
        hw.cable = false
        clock = t0.addingTimeInterval(8 * hour)
        server.systemDidWake()
        XCTAssertTrue(hw.limitWrites.isEmpty, "the charger was pulled while the Mac slept")
        XCTAssertNil(server.chargePlan)
        XCTAssertTrue(events.pending.isEmpty, "and its wake is gone")
        XCTAssertNil(timer.armedAt)
        XCTAssertTrue(lines.contains { $0.contains("no charger") }, "\(lines)")
    }

    /// A battery that cannot be read cannot say a charger is there.
    func testAnUnreadableBatteryIsNoChargerEither() {
        let server = makeServer()
        XCTAssertTrue(plan(server).ok)
        hw.cable = nil
        clock = t0.addingTimeInterval(8 * hour)
        server.systemDidWake()
        XCTAssertTrue(hw.limitWrites.isEmpty)
        XCTAssertNil(server.chargePlan)
    }

    func testALimitWriteThatFailsIsSaidAndThePlanStillEnds() {
        let server = makeServer()
        XCTAssertTrue(plan(server).ok)
        hw.refuseLimitWrites = true
        clock = t0.addingTimeInterval(8 * hour)
        server.systemDidWake()
        XCTAssertEqual(hw.limitWrites, [80], "it tried")
        XCTAssertNil(server.chargePlan)
        XCTAssertTrue(events.pending.isEmpty)
        XCTAssertTrue(lines.contains { $0.contains("WARNING") && $0.contains("80%") }, "\(lines)")
    }

    /// Sleeping is not an end: the helper's own will-sleep notice leaves the plan alone.
    func testTheHelpersOwnSleepNoticeLeavesThePlanAlone() {
        let server = makeServer()
        XCTAssertTrue(plan(server).ok)
        server.systemWillSleep()
        XCTAssertNotNil(server.chargePlan)
        XCTAssertFalse(server.isIdle)
        XCTAssertTrue(events.cancelled.isEmpty)
    }

    /// The Fans tab's "release everything" is not this client going away.
    func testReleasingTheFansDoesNotDropThePlan() {
        let server = makeServer()
        XCTAssertTrue(plan(server).ok)
        XCTAssertTrue(server.handle(.command(.releaseAll)).ok)
        XCTAssertNotNil(server.chargePlan)
        XCTAssertTrue(events.cancelled.isEmpty)
    }

    // ── The wire ────────────────────────────────────────────────────────────

    func testTheCommandsRoundTripOverTheWire() throws {
        let at = Date(timeIntervalSince1970: 1_800_028_800.123456)
        for request in [FanRequest.command(.scheduleChargeLimit(limit: 80, at: at)),
                        FanRequest.command(.cancelScheduledChargeLimit)] {
            var line = try FanWire.encode(request)
            XCTAssertEqual(line.last, 0x0A)
            line.removeLast()
            XCTAssertFalse(line.contains(0x0A))
            XCTAssertLessThan(line.count, FanWire.maxLineBytes)
            XCTAssertEqual(try FanWire.decode(FanRequest.self, from: line), request)
        }
    }

    func testTheProtocolIsVersionThreeAndTheHelloSaysSo() {
        XCTAssertEqual(FanDaemon.protocolVersion, 3)
        XCTAssertEqual(makeServer().handle(.hello).version, 3)
    }

    func testAFanSessionTracksNothingForThePlanCommands() {
        var session = FanSession(enabled: true, helper: .connected(fanCount: 2))
        session.completed(.scheduleChargeLimit(limit: 80, at: t0), ok: true)
        session.completed(.cancelScheduledChargeLimit, ok: false)
        XCTAssertTrue(session.held.isEmpty)
    }

    /// With no client at all (a plan was made on a call that has since been dealt with) the helper stopping still takes
    /// the wake away: the one place nothing else would.
    func testAPlanHeldWithNoClientIsDroppedWhenTheHelperStops() throws {
        let path = NSTemporaryDirectory() + "bs-planstop-\(UUID().uuidString.prefix(8)).sock"
        let server = FanHelperServer(hardware: FakeFans([:]),
                                     configuration: .init(socketPath: path, ownerUID: getuid(),
                                                          pin: .signingIdentifier(FanDaemon.clientSigningIdentifier)),
                                     log: { [weak self] in self?.lines.append($0) },
                                     charge: hw, powerEvents: events, wakeTimer: timer)
        server.now = { [weak self] in self?.clock ?? Date() }
        try server.start()
        XCTAssertTrue(plan(server).ok)
        XCTAssertEqual(events.pending.count, 1)
        server.stop()
        server.run()   // unwinds at once, through the way out every stop takes
        XCTAssertTrue(events.pending.isEmpty, "the wake outlived the helper")
        XCTAssertNil(timer.armedAt)
        XCTAssertTrue(hw.limitWrites.isEmpty)
        XCTAssertTrue(lines.contains { $0.contains("the helper is stopping") }, "\(lines)")
    }

    // ── A wake a killed helper left behind ──────────────────────────────────

    /// SIGKILL runs nothing: the wake the helper scheduled stays in the system's own list, on disk, and wakes the Mac
    /// for a plan that nobody holds. The next helper to start removes every wake under its own name, before it serves.
    func testStartingRemovesTheWakesAKilledHelperLeftBehind() throws {
        events.leaveBehind([t0.addingTimeInterval(3 * hour), t0.addingTimeInterval(9 * hour)])
        let path = NSTemporaryDirectory() + "bs-orphanwake-\(UUID().uuidString.prefix(8)).sock"
        let server = FanHelperServer(hardware: FakeFans([:]),
                                     configuration: .init(socketPath: path, ownerUID: getuid(),
                                                          pin: .signingIdentifier(FanDaemon.clientSigningIdentifier)),
                                     log: { [weak self] in self?.lines.append($0) },
                                     charge: hw, powerEvents: events, wakeTimer: timer)
        server.now = { [weak self] in self?.clock ?? Date() }
        XCTAssertEqual(events.pending.count, 2)
        try server.start()
        XCTAssertTrue(events.pending.isEmpty, "wakes a dead helper scheduled were left in the system's list")
        XCTAssertEqual(events.cancelAlls, 1)
        XCTAssertTrue(lines.contains { $0.contains("2") && $0.contains("left behind") }, "\(lines)")
        // Nothing was written or planned for it, and a plan made now is the helper's own and is left alone.
        XCTAssertTrue(hw.limitWrites.isEmpty)
        XCTAssertTrue(plan(server).ok)
        XCTAssertEqual(events.pending.count, 1)
        server.stop()
        server.run()
    }

    /// The same under launchd, which hands the helper its socket (`start(adopting:)`): before anything is served.
    func testAdoptingLaunchdsSocketRemovesThemToo() throws {
        events.leaveBehind([t0.addingTimeInterval(5 * hour)])
        let path = NSTemporaryDirectory() + "bs-orphanwake2-\(UUID().uuidString.prefix(8)).sock"
        // A listening unix socket of the test's own stands in for the one launchd hands over.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = try XCTUnwrap(FanSocketIO.address(path))
        XCTAssertEqual(FanSocketIO.withAddress(&addr, { p, len in Darwin.bind(fd, p, len) }), 0)
        XCTAssertEqual(listen(fd, 1), 0)
        defer { unlink(path) }
        let server = FanHelperServer(hardware: FakeFans([:]),
                                     configuration: .init(socketPath: path, ownerUID: getuid(),
                                                          pin: .signingIdentifier(FanDaemon.clientSigningIdentifier)),
                                     log: { [weak self] in self?.lines.append($0) },
                                     charge: hw, powerEvents: events, wakeTimer: timer)
        try server.start(adopting: fd)
        XCTAssertTrue(events.pending.isEmpty, "wakes a dead helper scheduled were left in the system's list")
        XCTAssertEqual(events.cancelAlls, 1)
        server.stop()
        server.run()
    }

    func testNothingLeftBehindSaysNothing() {
        let server = makeServer()
        server.clearOrphanedWakes()
        XCTAssertEqual(events.cancelAlls, 1)
        XCTAssertFalse(lines.contains { $0.contains("left behind") }, "\(lines)")
    }

    /// A system that will not take them away is a warning, said once, and the helper still starts.
    func testWakesThatCannotBeRemovedAreAWarningNotAFailure() {
        events.leaveBehind([t0.addingTimeInterval(hour)])
        events.refuseCancel = true
        let server = makeServer()
        server.clearOrphanedWakes()
        XCTAssertTrue(lines.contains { $0.contains("WARNING") && $0.contains("could not be removed") }, "\(lines)")
    }

    /// A helper that cannot wake the Mac has no power events to clear.
    func testAHelperWithNoPowerEventsClearsNothing() {
        let server = makeServer(withEvents: false)
        server.clearOrphanedWakes()
        XCTAssertEqual(events.cancelAlls, 0)
    }

    func testTheRealSchedulerCarriesTheHelpersOwnName() {
        // Built, never asked: asking would put a wake in this Mac's real list of scheduled events.
        _ = SystemPowerEventScheduler()
        XCTAssertEqual(SystemPowerEventScheduler.owner, "dev.anode.app.chargelimit")
    }
}

// ── With the loop running ───────────────────────────────────────────────────

/// A real server on a real socket, against fake hardware, a fake scheduler and, in the last test, the real wall-clock
/// timer. A client leaving or the helper stopping is the loop's business, and only the loop can show it is done.
final class ChargeHelperPlanLoopTests: XCTestCase {

    private var server: FanHelperServer!
    private var thread: Thread!
    private var link: FanControlLink!
    private var socketPath = ""
    private var events: FakePowerEvents!
    private var timer: FakeWallTimer!
    private var hw: FakeChargeHardware!

    override func setUp() {
        super.setUp()
        events = FakePowerEvents()
        timer = FakeWallTimer()
        hw = FakeChargeHardware(percent: 54, onAC: true)
    }

    override func tearDown() {
        link?.disconnect()
        server?.stop()
        spin(until: { self.thread == nil || self.thread.isFinished }, timeout: 3, failOnTimeout: false)
        super.tearDown()
    }

    private func spin(until done: () -> Bool, timeout: TimeInterval = 3, failOnTimeout: Bool = true) {
        let end = Date().addingTimeInterval(timeout)
        while !done(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        if failOnTimeout { XCTAssertTrue(done(), "timed out") }
    }

    private func start(realTimer: Bool = false) throws {
        socketPath = NSTemporaryDirectory() + "bs-plan-\(UUID().uuidString.prefix(8)).sock"
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0, let mine = FanPeer.of(socket: pair[0])?.cdhash else {
            throw XCTSkip("no code identity available in this test environment")
        }
        close(pair[0]); close(pair[1])
        server = FanHelperServer(hardware: FakeFans([:]),
                                 configuration: .init(socketPath: socketPath, ownerUID: getuid(),
                                                      pin: .exactBuild(cdhash: mine)),
                                 charge: hw, powerEvents: events,
                                 wakeTimer: realTimer ? DispatchWallClockTimer() : timer)
        server.chargeTiming = .immediate
        try server.start()
        thread = Thread { [server] in server?.run() }
        thread.start()
        link = FanControlLink(socketPath: socketPath)
        var status: FanControlLink.Status?
        link.connect { status = $0 }
        spin(until: { status != nil })
    }

    private func send(_ command: FanCommand) -> FanReply {
        var result: FanReply?
        link.send(command) { result = $0 }
        spin(until: { result != nil })
        return result ?? FanReply(ok: false, message: "no reply")
    }

    func testThePlanLivesAsLongAsTheClientAndGoesWithIt() throws {
        try start()
        let at = Date().addingTimeInterval(6 * 3600)
        XCTAssertTrue(send(.scheduleChargeLimit(limit: 80, at: at)).ok)
        XCTAssertEqual(events.pending.count, 1)
        // Still there between exchanges.
        XCTAssertTrue(send(.setChargeLimit(60)).ok)
        XCTAssertEqual(events.pending.count, 1)
        XCTAssertEqual(hw.limitWrites, [60], "only the limit that was asked for, not the plan's")
        link.disconnect()
        spin(until: { self.events.pending.isEmpty })
        XCTAssertEqual(events.cancelled.count, 1, "the scheduled wake was cancelled")
        XCTAssertEqual(hw.limitWrites, [60], "and nothing was written for the plan")
        XCTAssertNil(timer.armedAt)
    }

    func testStoppingTheHelperDropsThePlanAndWritesNothing() throws {
        try start()
        XCTAssertTrue(send(.scheduleChargeLimit(limit: 80, at: Date().addingTimeInterval(3600))).ok)
        XCTAssertEqual(events.pending.count, 1)
        server.stop()
        spin(until: { self.thread.isFinished })
        XCTAssertTrue(events.pending.isEmpty, "a helper that stops leaves no wake behind")
        XCTAssertTrue(hw.limitWrites.isEmpty)
    }

    /// The whole route, with nothing faked but the hardware and the power events: the real wall-clock timer fires, hands
    /// the news to the loop through the wake pipe, and the loop writes the limit and takes its wake away.
    func testTheRealTimerWritesTheLimitAtTheMoment() throws {
        try start(realTimer: true)
        let at = Date().addingTimeInterval(1.0)
        XCTAssertTrue(send(.scheduleChargeLimit(limit: 85, at: at)).ok)
        spin(until: { !self.hw.limitWrites.isEmpty }, timeout: 5)
        XCTAssertEqual(hw.limitWrites, [85])
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(at), -0.2, "not before the moment")
        spin(until: { self.events.pending.isEmpty })
        XCTAssertEqual(events.cancelled.count, 1)
    }
}

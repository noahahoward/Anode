import XCTest
import Darwin
@testable import AnodeApp
@testable import PowerKit

/// How long Charge Control holds the main thread against a helper that accepts and never answers: quitting,
/// switching off, the Uninstall button's restore, going to sleep, an account switch and the headless restore each
/// take about 2.5 s at most, all their waits together.
///
/// Measured against the REAL link — `FanControlLink` under `HelperConnection` under `ChargeHelperAdapter` — talking
/// to `StallingHelper` on a temporary socket: it answers like the helper until told to stop, then keeps every
/// connection open, reads what comes and answers nothing, so every exchange waits out the link's 2 s receive timeout.
/// Nothing here reaches the real helper socket, the SMC, the real preferences or a PowerUI client.
final class ChargeHelperWaitTests: XCTestCase {

    /// The most any of these may hold the main thread.
    static let bound: TimeInterval = 2.5

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var settings: Settings!
    private var stalling: StallingHelper!
    private var wire: FanControlLink!
    private var connection: HelperConnection!
    private var adapter: ChargeHelperAdapter!
    private var client: FakeChargeLimitClient!
    private var center: NotificationCenter!
    private var controller: ChargeController?
    private var lines: [String] = []

    override func setUpWithError() throws {
        (defaults, suiteName) = try TestDefaults.make(owner: "ChargeHelperWait", test: name)
        settings = Settings(defaults: defaults)
        stalling = try StallingHelper()
        wire = FanControlLink(socketPath: stalling.path)
        connection = HelperConnection(wire: wire)
        adapter = ChargeHelperAdapter(connection: connection, isInstalled: { true })
        // macOS's own limit before Charge Control was one only the helper can put back, so every restore waits for
        // the helper twice: the stop, then the limit. Switching on writes it down as the record; a record already in
        // the settings at launch would be taken for the last run not having quit, and Charge Control would wait.
        client = FakeChargeLimitClient(state: NativeChargeState(mclEnabled: true, mclLimit: 63,
                                                                optimizedChargingEnabled: true))
        center = NotificationCenter()
        lines = []
    }

    override func tearDownWithError() throws {
        // The helper goes first: every exchange still queued on the link then ends at once.
        stalling.stop()
        controller = nil
        _ = wire.drain(timeout: 10)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        settings = nil
        TestDefaults.destroy(defaults, suiteName)
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    private func make() -> ChargeController {
        let c = ChargeController(settings: settings, makeClient: { [client] in client }, helper: adapter,
                                 battery: { ChargeControllerTests.state(90) }, chargerSwitch: { nil },
                                 log: { [weak self] in self?.lines.append($0) },
                                 workspace: center, limitInForce: ChargeLimitInForce(), onConsole: { true })
        controller = c
        return c
    }

    /// Charge Control on with a limit only the helper sets, a discharge running on the helper's yes, and then the
    /// helper stops answering.
    @discardableResult
    private func dischargingThenStalled() -> ChargeController {
        let c = holdingALimitOnlyTheHelperSets()
        c.pressDrain()
        spin(until: { c.dischargeInForce != nil })
        XCTAssertEqual(c.dischargeInForce, 63, "the discharge did not start: \(lines)")
        XCTAssertTrue(settings.chargeCutUnconfirmed)
        stalling.answering = false
        return c
    }

    private func holdingALimitOnlyTheHelperSets() -> ChargeController {
        settings.chargeLimit = 63
        settings.chargeControlEnabled = true
        let c = make()
        spin(until: { c.status == .active(ChargeDecision(osLimit: 63, dischargeTo: nil, reason: .limit)) })
        return c
    }

    private func measured(_ body: () -> Void) -> TimeInterval {
        let start = Date()
        body()
        return Date().timeIntervalSince(start)
    }

    private func spin(until done: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(done(), "timed out")
    }

    // ── The paths ───────────────────────────────────────────────────────────

    func testSwitchingOffDoesNotHoldTheMainThread() {
        dischargingThenStalled()
        let took = measured { settings.chargeControlEnabled = false }
        XCTAssertLessThan(took, Self.bound, "switching off held the main thread \(took) s")
        XCTAssertTrue(settings.chargeCutUnconfirmed, "a stop nobody answered settled the debt")
    }

    func testQuittingDoesNotHoldTheMainThread() {
        let c = dischargingThenStalled()
        let took = measured { c.shutdown() }
        XCTAssertLessThan(took, Self.bound, "quitting held the main thread \(took) s")
    }

    func testTheUninstallButtonsRestoreDoesNotHoldTheMainThread() {
        let c = dischargingThenStalled()
        let took = measured { c.restoreForUninstall() }
        XCTAssertLessThan(took, Self.bound, "the uninstall's restore held the main thread \(took) s")
    }

    func testGoingToSleepDoesNotHoldTheMainThread() {
        let c = dischargingThenStalled()
        let took = measured { c.willSleep() }
        XCTAssertLessThan(took, Self.bound, "going to sleep held the main thread \(took) s")
    }

    func testAnAccountSwitchDoesNotHoldTheMainThread() {
        dischargingThenStalled()
        let took = measured { center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil) }
        XCTAssertLessThan(took, Self.bound, "an account switch held the main thread \(took) s")
    }

    /// The uninstall script's run with no window: a debt left over, and a record only the helper can put back.
    func testTheHeadlessRestoreDoesNotHoldTheMainThread() {
        settings.chargeRestoreRecord = ChargeController.encodeRecord(
            NativeChargeState(mclEnabled: true, mclLimit: 63, optimizedChargingEnabled: true))
        settings.chargeCutUnconfirmed = true
        stalling.answering = false
        var left = false
        let took = measured {
            left = !ChargeController.restoreForUninstall(settings: settings, makeClient: { [client] in client },
                                                         helper: adapter, log: { [weak self] in self?.lines.append($0) })
        }
        XCTAssertLessThan(took, Self.bound, "the headless restore held the main thread \(took) s")
        XCTAssertTrue(left, "a restore nobody answered said nothing was left")
    }

    /// A launch after an unclean exit lifts the limit at once, with the same waits as a switch-off: a debt left over
    /// and a helper that has stopped answering must not hold the main thread longer.
    func testALaunchAfterACrashDoesNotHoldTheMainThread() {
        settings.chargeRestoreRecord = ChargeController.encodeRecord(
            NativeChargeState(mclEnabled: true, mclLimit: 63, optimizedChargingEnabled: true))
        settings.chargeCutUnconfirmed = true
        settings.chargeControlEnabled = true
        stalling.answering = false
        var c: ChargeController?
        let took = measured { c = make() }
        XCTAssertLessThan(took, Self.bound, "a launch after a crash held the main thread \(took) s")
        XCTAssertEqual(c?.isWaitingToStart, true)
        XCTAssertTrue(settings.chargeCutUnconfirmed, "a stop nobody answered settled the debt")
    }

    /// The sequence on the real link: the limit is 63, the person moves it to 62, and Anode quits 0.3 s later. The
    /// helper takes longer over 62 than the link waits, so the exchange ends with no answer and the drain behind it
    /// must not call that landed: the restore would write the original and clear the record, and the helper would
    /// then apply 62 and the next cold start would take 62 for macOS's own. The record is kept instead, and the
    /// next launch lifts the limit.
    func testQuittingBehindALimitTheHelperAppliesLateKeepsTheRecord() {
        // A faster link than the default, so the helper being slower than it costs a second, not three.
        wire = FanControlLink(socketPath: stalling.path, socketTimeout: 0.3)
        connection = HelperConnection(wire: wire)
        adapter = ChargeHelperAdapter(connection: connection, isInstalled: { true })
        client.state = NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: true)
        let c = holdingALimitOnlyTheHelperSets()
        spin(until: { stalling.commands.contains(.setChargeLimit(63)) })
        stalling.commandDelay = 0.9
        settings.chargeLimit = 62
        Thread.sleep(forTimeInterval: 0.3)
        c.shutdown()
        XCTAssertNotNil(settings.chargeRestoreRecord, "the record was cleared behind a limit nobody had answered")
        XCTAssertTrue(lines.contains { $0.contains("may land after this") }, lines.joined(separator: "\n"))
        // The helper does apply it afterwards.
        spin(until: { stalling.commands.contains(.setChargeLimit(62)) })
        XCTAssertTrue(stalling.commands.contains(.setChargeLimit(62)))
    }

    /// The lift at the top of the program has the same bounds: it runs before the window exists, and a debt left over
    /// with a helper that has stopped answering must not hold the launch longer than a switch-off does.
    func testTheLiftAtTheTopOfTheProgramDoesNotHoldTheMainThread() {
        settings.chargeRestoreRecord = ChargeController.encodeRecord(
            NativeChargeState(mclEnabled: true, mclLimit: 63, optimizedChargingEnabled: true))
        settings.chargeCutUnconfirmed = true
        settings.chargeControlEnabled = true
        stalling.answering = false
        var lifted = false
        let took = measured {
            lifted = ChargeController.liftAtLaunch(settings: settings, makeClient: { [client] in client },
                                                   helper: { [adapter] in adapter! },
                                                   log: { [weak self] in self?.lines.append($0) })
        }
        XCTAssertTrue(lifted)
        XCTAssertLessThan(took, Self.bound, "the lift at launch held the main thread \(took) s")
        XCTAssertTrue(settings.chargeStartPending)
        XCTAssertTrue(settings.chargeCutUnconfirmed, "a stop nobody answered settled the debt")
    }

    /// A helper that answers is still waited for: nothing above cut a healthy one short.
    func testAHealthyHelperIsStillWaitedForOnTheWayOff() {
        let c = holdingALimitOnlyTheHelperSets()
        c.pressDrain()
        spin(until: { c.dischargeInForce != nil })
        settings.chargeControlEnabled = false
        XCTAssertFalse(settings.chargeCutUnconfirmed, "the helper's yes to the stop was not heard")
        XCTAssertNil(settings.chargeRestoreRecord, "the helper's yes to the limit was not heard")
        XCTAssertTrue(stalling.commands.contains(.stopDischarge))
        XCTAssertEqual(stalling.commands.last, .setChargeLimit(63))
    }
}

/// A helper on a temporary socket that answers like the real one (hello: version 2; every command: ok) until
/// `answering` is turned off. From then on it keeps every connection open, reads what comes and answers nothing.
///
/// With `commandDelay` set it is a slow one instead: it reads a command, takes that long over it (it serves one
/// connection at a time, like the real one), and only then applies it (`commands`) and answers it. A client whose
/// own timeout is shorter has given up on the answer by then, and the command lands all the same.
final class StallingHelper {
    let path: String
    private let listener: Int32
    private let lock = NSLock()
    private var _answering = true
    private var _commandDelay: TimeInterval = 0
    private var _stopping = false
    private var _commands: [FanCommand] = []
    private var _dropClients = false
    private var _unsolicited: [Data] = []
    private let finished = DispatchSemaphore(value: 0)

    struct Failure: Error {}

    init() throws {
        path = NSTemporaryDirectory() + "cc-stall-\(UUID().uuidString.prefix(8)).sock"
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = FanSocketIO.address(path) else { throw Failure() }
        let bound = FanSocketIO.withAddress(&addr) { Darwin.bind(fd, $0, $1) }
        guard bound == 0, listen(fd, 64) == 0 else {
            close(fd)
            throw Failure()
        }
        listener = fd
        Thread.detachNewThread { [self] in serve() }
    }

    var answering: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _answering }
        set { lock.lock(); _answering = newValue; lock.unlock() }
    }

    /// How long a command takes before it is applied and answered; hello is answered at once.
    var commandDelay: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _commandDelay }
        set { lock.lock(); _commandDelay = newValue; lock.unlock() }
    }

    /// Close every client's connection, as a helper that dies or is stopped does; the listener stays.
    func dropClients() { lock.lock(); _dropClients = true; lock.unlock() }

    /// Send every client these bytes without being asked, as a late answer to something long given up on would.
    func sendUnsolicited(_ data: Data) { lock.lock(); _unsolicited.append(data); lock.unlock() }

    /// Every command it answered, in order.
    var commands: [FanCommand] { lock.lock(); defer { lock.unlock() }; return _commands }

    /// Sleeps `seconds`, or until `dropClients` is called; true in that case (and the request is used up).
    private func sleepUnlessDropped(_ seconds: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            lock.lock()
            let drop = _dropClients
            if drop { _dropClients = false }
            lock.unlock()
            if drop { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    private var stopping: Bool { lock.lock(); defer { lock.unlock() }; return _stopping }

    /// Close every connection and the socket, and wait for that.
    func stop() {
        lock.lock(); _stopping = true; lock.unlock()
        _ = finished.wait(timeout: .now() + 5)
        unlink(path)
    }

    private func serve() {
        var clients: [Int32: Data] = [:]
        defer {
            for fd in clients.keys { close(fd) }
            close(listener)
            finished.signal()
        }
        serving: while !stopping {
            lock.lock()
            let drop = _dropClients, unsolicited = _unsolicited
            _dropClients = false
            _unsolicited = []
            lock.unlock()
            if drop {
                for fd in clients.keys { close(fd) }
                clients = [:]
            }
            for data in unsolicited { for fd in clients.keys { _ = FanSocketIO.writeAll(fd, data) } }
            var fds = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0)]
            fds += clients.keys.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            guard poll(&fds, nfds_t(fds.count), 20) > 0 else { continue }
            if fds[0].revents & Int16(POLLIN) != 0 {
                let c = accept(listener, nil, nil)
                if c >= 0 {
                    var on: Int32 = 1
                    setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                    clients[c] = Data()
                }
            }
            for p in fds.dropFirst() where p.revents != 0 {
                var chunk = [UInt8](repeating: 0, count: 1024)
                let n = read(p.fd, &chunk, chunk.count)
                guard n > 0, var buffer = clients[p.fd] else {
                    close(p.fd)
                    clients[p.fd] = nil
                    continue
                }
                buffer.append(contentsOf: chunk[0..<n])
                while let i = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<i])
                    buffer.removeSubrange(buffer.startIndex...i)
                    guard answering, let request = try? FanWire.decode(FanRequest.self, from: line) else { continue }
                    let reply: FanReply
                    switch request {
                    case .hello:
                        reply = FanReply(ok: true, message: "hello", fanCount: 0, version: 2)
                    case .command(let c):
                        let delay = commandDelay
                        if delay > 0, sleepUnlessDropped(delay) {
                            // Dropped while it was on the command: gone, with nothing answered or applied.
                            for fd in clients.keys { close(fd) }
                            clients = [:]
                            continue serving
                        }
                        lock.lock(); _commands.append(c); lock.unlock()
                        reply = FanReply(ok: true, message: "ok")
                    }
                    if let data = try? FanWire.encode(reply) { _ = FanSocketIO.writeAll(p.fd, data) }
                }
                clients[p.fd] = buffer
            }
        }
    }
}

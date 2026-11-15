import AppKit
import XCTest
@testable import AnodeApp
@testable import PowerKit

/// Hard Drain: how much work there is, when it runs, and when it ends. Nothing here starts a process, reads the Mac's
/// processor or warms anything: the engine's view of the Mac is a set of closures the test gives, and in the
/// controller's tests the engine itself is a fake.
final class HardDrainTests: XCTestCase {

    // ── How much work ───────────────────────────────────────────────────────

    func testAnIdleMacGetsAWorkerForEveryCoreButTheTwoLeftFree() {
        XCTAssertEqual(HardDrainRule.coresLeftFree, 2)
        XCTAssertEqual(HardDrainRule.workers(cores: 15, busyWithOthers: 0, hot: false, thermalPressure: false, lowPowerMode: false), 13)
        XCTAssertEqual(HardDrainRule.workers(cores: 8, busyWithOthers: 0.4, hot: false, thermalPressure: false, lowPowerMode: false), 5)
    }

    /// The more other programs use, the less work there is, down to none: they come first, and keep the heat and the
    /// fans to themselves.
    func testThereIsLessWorkTheBusierOtherProgramsAre() {
        func w(_ others: Double) -> Int {
            HardDrainRule.workers(cores: 10, busyWithOthers: others, hot: false, thermalPressure: false, lowPowerMode: false)
        }
        XCTAssertEqual(w(0), 8)
        XCTAssertEqual(w(1.2), 6, "a core partly used counts as a whole one")
        XCTAssertEqual(w(4), 4)
        XCTAssertEqual(w(8), 0)
        XCTAssertEqual(w(10), 0)
        XCTAssertEqual(w(-3), 8, "a reading below nothing is nothing")
        XCTAssertEqual(w(.nan), 0, "a reading that is not a number adds no work")
    }

    func testThereIsNoWorkWhileTheBatteryIsWarmTheMacIsHotOrLowPowerModeIsOn() {
        XCTAssertEqual(HardDrainRule.workers(cores: 10, busyWithOthers: 0, hot: true, thermalPressure: false, lowPowerMode: false), 0)
        XCTAssertEqual(HardDrainRule.workers(cores: 10, busyWithOthers: 0, hot: false, thermalPressure: true, lowPowerMode: false), 0)
        XCTAssertEqual(HardDrainRule.workers(cores: 10, busyWithOthers: 0, hot: false, thermalPressure: false, lowPowerMode: true), 0)
        XCTAssertEqual(HardDrainRule.workers(cores: 2, busyWithOthers: 0, hot: false, thermalPressure: false, lowPowerMode: false), 0,
                       "a Mac with no core to spare gets none")
    }

    /// Warm at the threshold, and cool again only two degrees below it, so that a battery at the threshold does not
    /// start and stop the work at every look.
    func testTheBatteryIsWarmAtTheThresholdAndCoolAgainTwoDegreesBelowIt() {
        XCTAssertEqual(HardDrainRule.coolBy, 2)
        XCTAssertFalse(HardDrainRule.isHot(temperature: 39.9, threshold: 40, wasHot: false))
        XCTAssertTrue(HardDrainRule.isHot(temperature: 40, threshold: 40, wasHot: false))
        XCTAssertTrue(HardDrainRule.isHot(temperature: 38.5, threshold: 40, wasHot: true), "not cool yet")
        XCTAssertFalse(HardDrainRule.isHot(temperature: 38, threshold: 40, wasHot: true))
        XCTAssertTrue(HardDrainRule.isHot(temperature: nil, threshold: 40, wasHot: true), "no reading changes nothing")
        XCTAssertFalse(HardDrainRule.isHot(temperature: nil, threshold: 40, wasHot: false))
        XCTAssertFalse(HardDrainRule.isHot(temperature: .nan, threshold: 40, wasHot: false))
    }

    func testBusyCoresFromTwoReadings() {
        typealias T = ProcessorTime.HostTicks
        XCTAssertEqual(ProcessorTime.busyCores(from: T(busy: 100, total: 1000), to: T(busy: 400, total: 2000), cores: 10) ?? -1, 3, accuracy: 1e-9)
        XCTAssertNil(ProcessorTime.busyCores(from: T(busy: 100, total: 1000), to: T(busy: 100, total: 1000), cores: 10), "no time passed")
        XCTAssertNil(ProcessorTime.busyCores(from: T(busy: 400, total: 2000), to: T(busy: 100, total: 3000), cores: 10), "the counter went back")
    }

    // ── A worker's command line ─────────────────────────────────────────────

    func testAWorkersArgumentsAreParsed() {
        XCTAssertEqual(HardDrainWorker.parse(["Anode", "--hard-drain-worker", "123", "cpu", "full"]),
                       HardDrainWorker.Request(parent: 123, kind: .cpu, intensity: .full))
        XCTAssertEqual(HardDrainWorker.parse(["Anode"] + HardDrainWorker.arguments(parent: 777, kind: .gpu, intensity: .gentle)),
                       HardDrainWorker.Request(parent: 777, kind: .gpu, intensity: .gentle))
        for bad in [["Anode"], ["Anode", "--hard-drain-worker"], ["Anode", "--hard-drain-worker", "x", "cpu", "full"],
                    ["Anode", "--hard-drain-worker", "1", "cpu", "full"], ["Anode", "--hard-drain-worker", "12"],
                    ["Anode", "--hard-drain-worker", "12", "disk", "full"], ["Anode", "--hard-drain-worker", "12", "cpu", "max"],
                    ["Anode", "--hard-drain-worker", "12", "cpu", "full", "extra"], ["Anode", "--charge-watchdog", "12"]] {
            XCTAssertNil(HardDrainWorker.parse(bad), "\(bad)")
        }
    }

    // ── How hard ────────────────────────────────────────────────────────────

    /// All out only once nobody has touched the Mac for a minute and macOS does not say it is hot (serious). Fair is
    /// not enough to back off: it came and went every minute of a real run with the battery under 37 °C.
    func testItGoesAllOutOnlyWhenNobodyIsUsingTheMacAndItIsNotHot() {
        XCTAssertEqual(HardDrainRule.awayAfter, 60)
        XCTAssertEqual(HardDrainRule.intensity(secondsSinceInput: 59, thermalSerious: false), .gentle)
        XCTAssertEqual(HardDrainRule.intensity(secondsSinceInput: 60, thermalSerious: false), .full)
        XCTAssertEqual(HardDrainRule.intensity(secondsSinceInput: 3600, thermalSerious: true), .gentle)
        XCTAssertEqual(HardDrainRule.intensity(secondsSinceInput: 0, thermalSerious: true), .gentle)
    }

    /// The GPU's command buffers are sized to a few milliseconds whatever the GPU is doing, and never run away.
    func testTheGPUsCommandBuffersAreKeptShort() {
        XCTAssertEqual(HardDrainWorker.gpuSlice, 0.004)
        XCTAssertEqual(HardDrainWorker.nextIterations(256, took: 0.008), 128, "twice as long: half the work")
        XCTAssertEqual(HardDrainWorker.nextIterations(256, took: 0.002), 512)
        XCTAssertEqual(HardDrainWorker.nextIterations(256, took: 0), 256, "no reading changes nothing")
        XCTAssertEqual(HardDrainWorker.nextIterations(256, took: .nan), 256)
        XCTAssertEqual(HardDrainWorker.nextIterations(256, took: 100), 16, "never below 16")
        XCTAssertEqual(HardDrainWorker.nextIterations(65536, took: 0.0000001), 65536, "never above 65536")
    }

    func testTheSignalsAreTheTwoUserOnes() {
        XCTAssertEqual(HardDrainWorker.fullSignal, SIGUSR2)
        XCTAssertEqual(HardDrainWorker.gentleSignal, SIGUSR1)
        XCTAssertNotEqual(HardDrainWorker.fullSignal, ChargeWatchdog.stopSignal == SIGUSR1 ? SIGUSR1 : -1,
                          "the watchdog's stop signal is SIGUSR1 too, but it is another process: nothing to fear")
    }

    /// `main.swift` runs it before anything of the app: a worker must never build an app.
    func testMainRunsAWorkerBeforeAnythingOfTheApp() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let main = try String(contentsOf: root.appendingPathComponent("Sources/AnodeApp/main.swift"), encoding: .utf8)
        func at(_ s: String) throws -> String.Index { try XCTUnwrap(main.range(of: s)?.lowerBound, s) }
        let run = try at("HardDrainWorker.runIfRequested(CommandLine.arguments)")
        XCTAssertLessThan(run, try at("let chargeRecords = ChargeRecords.live()"))
        XCTAssertLessThan(run, try at("let app = NSApplication.shared"))
        XCTAssertTrue(main.contains("hardDrain: LiveHardDrain()"), "the app's controller has no Hard Drain")
    }

    // ── The engine ──────────────────────────────────────────────────────────

    private final class FakeProcess: WatchdogProcess {
        let pid: pid_t
        var isRunning = true
        init(pid: pid_t) { self.pid = pid }
        func terminate() { isRunning = false }
    }

    /// The Mac as the engine sees it.
    private final class Mac {
        var cores = 10
        var busy: UInt64 = 0, total: UInt64 = 0
        var workerSeconds: [pid_t: Double] = [:]
        var thermal = false, serious = false, lowPower = false, ultra = false
        var idle: TimeInterval = 600
        var signals: [(pid_t, Int32)] = []
        var awake = 0
        var released = 0
        var ultraChanged: (() -> Void)?
        var stoppedFollowing = false
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var launched: [FakeProcess] = []
        var launchedWith: [[String]] = []
        var launchFails = false
        var tick: (() -> Void)?
        var timerCancelled = false
        var temperature: Double? = 30
        var lines: [String] = []

        struct Refused: Error {}

        var system: LiveHardDrain.System {
            LiveHardDrain.System(
                cores: { [unowned self] in cores },
                hostTicks: { [unowned self] in ProcessorTime.HostTicks(busy: busy, total: total) },
                seconds: { [unowned self] in workerSeconds[$0] },
                thermalPressure: { [unowned self] in thermal },
                thermalSerious: { [unowned self] in serious },
                lowPowerMode: { [unowned self] in lowPower },
                ultraLowPower: { [unowned self] in ultra },
                followUltraLowPower: { [unowned self] changed in
                    ultraChanged = changed
                    return { [unowned self] in stoppedFollowing = true }
                },
                secondsSinceInput: { [unowned self] in idle },
                launch: { [unowned self] arguments in
                    if launchFails { throw Refused() }
                    let p = FakeProcess(pid: pid_t(5000 + launched.count))
                    launched.append(p)
                    launchedWith.append(arguments)
                    return p
                },
                signal: { [unowned self] in signals.append(($0, $1)) },
                holdAwake: { [unowned self] in
                    awake += 1
                    return { [unowned self] in released += 1 }
                },
                now: { [unowned self] in now },
                every: { [unowned self] _, work in
                    tick = work
                    return { [unowned self] in timerCancelled = true }
                })
        }

        var running: [FakeProcess] { launched.filter(\.isRunning) }
        /// The running workers of each kind, by the arguments they were started with.
        func running(_ kind: String) -> [FakeProcess] {
            zip(launched, launchedWith).filter { $0.0.isRunning && $0.1.count > 2 && $0.1[2] == kind }.map(\.0)
        }

        /// Two seconds pass, in which other programs kept `others` cores busy, each processor worker one, and the GPU
        /// worker almost nothing of the processor.
        func pass(others: Double) {
            now += 2
            let cpu = running("cpu")
            for w in cpu { workerSeconds[w.pid, default: 0] += 2 }
            for w in running("gpu") { workerSeconds[w.pid, default: 0] += 0.02 }
            // 100 ticks a second for each core.
            total += UInt64(cores) * 200
            busy += UInt64((others + Double(cpu.count) + Double(running("gpu").count) * 0.01) * 200)
            tick?()
        }
    }

    private func engine(_ mac: Mac) -> LiveHardDrain {
        let e = LiveHardDrain(system: mac.system, log: { [unowned mac] in mac.lines.append($0) })
        e.start(temperature: { [unowned mac] in mac.temperature }, hotAt: { 40 })
        return e
    }

    func testItStartsWithWhatAnIdleMacGetsAndEveryWorkerIsStartedForThisProcess() {
        let mac = Mac()
        let e = engine(mac)
        XCTAssertTrue(e.isRunning)
        XCTAssertEqual(mac.running("cpu").count, 8)
        XCTAssertEqual(mac.running("gpu").count, 1, "the GPU is not worked")
        XCTAssertEqual(e.workers, 9)
        for args in mac.launchedWith {
            XCTAssertEqual(HardDrainWorker.parse(["Anode"] + args)?.parent, getpid())
        }
    }

    /// Nobody at the Mac: every worker starts all out. Someone at it: gently.
    func testWorkersStartAllOutWhenNobodyIsAtTheMacAndGentlyWhenSomebodyIs() {
        let away = Mac()
        _ = engine(away)
        XCTAssertTrue(away.launchedWith.allSatisfy { $0.last == "full" }, "\(away.launchedWith)")
        let here = Mac()
        here.idle = 5
        _ = engine(here)
        XCTAssertTrue(here.launchedWith.allSatisfy { $0.last == "gentle" }, "\(here.launchedWith)")
    }

    /// The person comes back: every worker is told to be gentle at the next look, with a signal, not restarted; and all
    /// out again once they have been away a minute.
    func testWhenThePersonComesBackEveryWorkerIsToldToBeGentle() {
        let mac = Mac()
        let e = engine(mac)
        let started = mac.launched.count
        mac.idle = 1
        mac.pass(others: 0)
        XCTAssertEqual(e.currentIntensity, .gentle)
        XCTAssertEqual(Set(mac.signals.map(\.0)), Set(mac.running.map(\.pid)), "a worker was not told")
        XCTAssertTrue(mac.signals.allSatisfy { $0.1 == HardDrainWorker.gentleSignal })
        XCTAssertEqual(mac.launched.count, started, "workers were restarted rather than told")
        mac.signals = []
        mac.pass(others: 0)
        XCTAssertTrue(mac.signals.isEmpty, "told again with nothing changed")
        mac.idle = 61
        mac.pass(others: 0)
        XCTAssertEqual(e.currentIntensity, .full)
        XCTAssertTrue(mac.signals.allSatisfy { $0.1 == HardDrainWorker.fullSignal })
        // macOS saying the Mac is hot makes it gentle too, with nobody at it.
        mac.signals = []
        mac.serious = true
        mac.pass(others: 0)
        XCTAssertEqual(e.currentIntensity, .gentle)
        XCTAssertFalse(mac.signals.isEmpty)
    }

    /// The Mac is kept from sleeping by itself while it runs, and let sleep again when it stops.
    func testTheMacIsKeptAwakeWhileItRunsAndLetGoAfter() {
        let mac = Mac()
        let e = engine(mac)
        XCTAssertEqual(mac.awake, 1)
        XCTAssertEqual(mac.released, 0)
        e.stop()
        XCTAssertEqual(mac.released, 1)
        e.stop()
        XCTAssertEqual(mac.released, 1, "let go twice")
    }

    /// Waiting for Ultra Low Power Mode or Low Power Mode, nothing is drained and the battery is to last: the Mac is let
    /// sleep. Through a pause for heat it is kept awake, so the drain goes on once the battery has cooled.
    func testTheMacIsLetSleepWhileItWaitsForAPowerSavingModeButNotForHeat() {
        let mac = Mac()
        let e = engine(mac)
        mac.ultra = true
        mac.ultraChanged?()
        XCTAssertEqual(mac.released, 1, "Ultra Low Power Mode is on and the Mac is still kept awake")
        mac.ultra = false
        mac.ultraChanged?()
        XCTAssertEqual(mac.awake, 2, "not kept awake again when the mode ended")
        mac.lowPower = true
        mac.pass(others: 0)
        XCTAssertEqual(mac.released, 2)
        mac.lowPower = false
        mac.pass(others: 0)
        XCTAssertEqual(mac.awake, 3)
        mac.temperature = 41
        mac.pass(others: 0)
        XCTAssertEqual(e.workers, 0)
        XCTAssertEqual(mac.released, 2, "let sleep during a pause for heat, which would end the drain")
        e.stop()
        XCTAssertEqual(mac.released, 3)
    }

    /// The GPU is stopped for everything that stops the processor work, and only for those: its work takes no core.
    func testTheGPUIsStoppedWhenTheWorkMustStopAndNotWhenOtherAppsAreBusy() {
        let mac = Mac()
        let e = engine(mac)
        mac.pass(others: 10)
        XCTAssertEqual(mac.running("cpu").count, 0)
        XCTAssertEqual(mac.running("gpu").count, 1, "other apps on the processor stopped the GPU")
        mac.temperature = 41
        mac.pass(others: 0)
        XCTAssertEqual(mac.running("gpu").count, 0, "the GPU went on on a warm battery")
        mac.temperature = 30
        mac.pass(others: 0)
        XCTAssertEqual(mac.running("gpu").count, 1)
        withExtendedLifetime(e) {}
    }

    /// A line a minute in the log: what it is doing and how warm the battery is.
    func testItLogsWhatItIsDoingAndTheBatterysTemperatureOnceAMinute() {
        let mac = Mac()
        let e = engine(mac)
        XCTAssertEqual(mac.lines.filter { $0.hasPrefix("Hard Drain: ") }.count, 1)
        XCTAssertTrue(mac.lines.contains("Hard Drain: 8 processor workers, the GPU working, all out; battery 30.0 °C"),
                      mac.lines.joined(separator: "\n"))
        for _ in 0..<29 { mac.pass(others: 0) }
        XCTAssertEqual(mac.lines.filter { $0.hasPrefix("Hard Drain: ") }.count, 1, "more than one a minute")
        mac.pass(others: 0)
        XCTAssertEqual(mac.lines.filter { $0.hasPrefix("Hard Drain: ") }.count, 2)
        XCTAssertEqual(LiveHardDrain.logEvery, 60)
        withExtendedLifetime(e) {}
    }

    /// The bug it must not have: the workers' own time is the Mac's busiest thing, and counted as other programs'
    /// it would talk the engine out of every worker it has just started.
    func testItsOwnWorkersAreNotCountedAsOtherPrograms() {
        let mac = Mac()
        let e = engine(mac)
        mac.pass(others: 0)
        XCTAssertEqual(mac.running("cpu").count, 8, "its own work was taken for other programs' and stopped")
        mac.pass(others: 0)
        XCTAssertEqual(mac.running("cpu").count, 8)
        _ = e
    }

    func testItGivesWayWhenOtherProgramsGetBusyAndComesBackWhenTheyStop() {
        let mac = Mac()
        let e = engine(mac)
        mac.pass(others: 3)
        XCTAssertEqual(mac.running("cpu").count, 5)
        mac.pass(others: 7.5)
        XCTAssertEqual(mac.running("cpu").count, 0)
        XCTAssertTrue(e.isRunning, "waiting is not ended")
        mac.pass(others: 0.2)
        XCTAssertEqual(mac.running("cpu").count, 7, "the ones it let go were ended")
    }

    func testAWarmBatteryStopsTheWorkUntilItHasCooled() {
        let mac = Mac()
        let e = engine(mac)
        mac.temperature = 40.5
        mac.pass(others: 0)
        XCTAssertEqual(e.workers, 0, "the GPU went on on a warm battery too")
        XCTAssertTrue(mac.lines.contains("Hard Drain is waiting: the battery is warm"), mac.lines.joined(separator: "\n"))
        mac.temperature = 39
        mac.pass(others: 0)
        XCTAssertEqual(e.workers, 0, "a degree cooler is not cool")
        mac.temperature = 37.5
        mac.pass(others: 0)
        XCTAssertEqual(e.workers, 9)
        XCTAssertTrue(mac.lines.contains("Hard Drain is working again"))
        XCTAssertEqual(mac.lines.filter { $0.contains("waiting") }.count, 1, "said once, not at every look")
    }

    func testThermalPressureAndLowPowerModeStopTheWork() {
        let mac = Mac()
        let e = engine(mac)
        mac.thermal = true
        mac.pass(others: 0)
        XCTAssertEqual(e.workers, 0)
        mac.thermal = false
        mac.lowPower = true
        mac.pass(others: 0)
        XCTAssertEqual(e.workers, 0)
        mac.lowPower = false
        mac.pass(others: 0)
        XCTAssertEqual(e.workers, 9)
    }

    /// Ultra Low Power Mode is there to make a low battery last, does not always switch Low Power Mode on, and while
    /// it starts it watches the processor for something spinning. The work stops the moment the mode starts, not at
    /// the next look, and comes back when it ends.
    func testUltraLowPowerModeStopsTheWorkAtOnceAndItComesBackAfter() {
        let mac = Mac()
        let e = engine(mac)
        XCTAssertNil(e.waitingBecause)
        mac.ultra = true
        mac.ultraChanged?()
        XCTAssertEqual(e.workers, 0, "the work went on into the mode")
        XCTAssertTrue(mac.running.isEmpty)
        XCTAssertEqual(e.waitingBecause, "Ultra Low Power Mode is on")
        XCTAssertTrue(mac.lines.contains("Hard Drain is waiting: Ultra Low Power Mode is on"))
        mac.pass(others: 0)
        XCTAssertEqual(e.workers, 0, "a look during the mode started it again")
        mac.ultra = false
        mac.ultraChanged?()
        XCTAssertEqual(e.workers, 9)
        XCTAssertNil(e.waitingBecause)
    }

    /// The section says why there is no work: the reason that holds it, or that other apps have the processor.
    func testItSaysWhyItIsWaiting() {
        let mac = Mac()
        let e = engine(mac)
        mac.temperature = 41
        mac.pass(others: 0)
        XCTAssertEqual(e.waitingBecause, "the battery is warm")
        mac.temperature = 30
        mac.thermal = true
        mac.pass(others: 0)
        XCTAssertEqual(e.waitingBecause, "the Mac is hot")
        mac.thermal = false
        mac.lowPower = true
        mac.pass(others: 0)
        XCTAssertEqual(e.waitingBecause, "Low Power Mode is on")
        mac.lowPower = false
        mac.pass(others: 9)
        XCTAssertNil(e.waitingBecause, "the GPU is still working, so it is not waiting")
        mac.pass(others: 0)
        XCTAssertNil(e.waitingBecause)
    }

    func testStoppingEndsEveryWorkerAndTheLooking() {
        let mac = Mac()
        let e = engine(mac)
        e.stop()
        XCTAssertFalse(e.isRunning)
        XCTAssertEqual(e.workers, 0)
        XCTAssertTrue(mac.running.isEmpty, "a worker was left running")
        XCTAssertTrue(mac.timerCancelled)
        XCTAssertTrue(mac.stoppedFollowing)
        XCTAssertNil(e.waitingBecause)
        // A change of the mode after it has stopped starts nothing.
        mac.ultraChanged?()
        XCTAssertTrue(mac.running.isEmpty)
        e.stop()
    }

    func testItEndsByItselfAfterItsLongestTime() {
        let mac = Mac()
        let e = engine(mac)
        mac.now += HardDrainRule.longest
        mac.pass(others: 0)
        XCTAssertEqual(mac.released, 1, "the Mac was kept awake after it ended")
        XCTAssertFalse(e.isRunning)
        XCTAssertTrue(mac.running.isEmpty)
        XCTAssertTrue(mac.lines.contains { $0.contains("Hard Drain ended: it had run for 3 hours") })
    }

    func testAWorkerThatEndedByItselfIsReplaced() {
        let mac = Mac()
        let e = engine(mac)
        mac.launched[0].isRunning = false
        mac.pass(others: 0)
        XCTAssertEqual(e.workers, 9)
        XCTAssertEqual(mac.launched.count, 10)
    }

    func testAWorkerThatCannotBeStartedIsSaidAndNotTriedInALoop() {
        let mac = Mac()
        mac.launchFails = true
        let e = engine(mac)
        XCTAssertEqual(e.workers, 0)
        XCTAssertEqual(mac.lines.filter { $0.contains("could not be started") }.count, 2, "once for the processor, once for the GPU")
    }

    func testAReadingThatCannotBeTakenAddsNoWork() {
        let mac = Mac()
        let e = engine(mac)
        // No time passes on the Mac's counters: nothing can be said about other programs.
        mac.now += 5
        mac.tick?()
        XCTAssertEqual(mac.running("cpu").count, 0)
        _ = e
    }
}

/// Hard Drain in the controller: when it may be pressed, and what ends it.
final class HardDrainControllerTests: XCTestCase {

    private final class FakeEngine: HardDraining {
        var starts = 0, stops = 0
        var isRunning = false
        var workers = 0
        var hotAt: (() -> Double)?
        var temperature: (() -> Double?)?
        var waitingBecause: String?
        func start(temperature: @escaping () -> Double?, hotAt: @escaping () -> Double) {
            starts += 1; isRunning = true; workers = 6
            self.temperature = temperature; self.hotAt = hotAt
        }
        func stop() { stops += 1; isRunning = false; workers = 0 }
    }

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var settings: Settings!
    private var client: FakeChargeLimitClient!
    private var helper: FakeHelperLink!
    private var battery: Battery.State?
    private var lines: [String] = []
    private var engine: FakeEngine!
    private var controller: ChargeController?

    override func setUpWithError() throws {
        (defaults, suiteName) = try TestDefaults.make(owner: "HardDrain", test: name)
        settings = Settings(defaults: defaults)
        client = FakeChargeLimitClient()
        helper = FakeHelperLink()
        helper.landsOn = client
        engine = FakeEngine()
        lines = []
        settings.chargeLimit = 80
        battery = ReadyByControllerTests.plugged(92)
    }

    override func tearDownWithError() throws {
        controller?.shutdown()
        controller = nil
        settings = nil
        TestDefaults.destroy(defaults, suiteName)
    }

    @discardableResult
    private func make() -> ChargeController {
        settings.chargeControlEnabled = true
        let c = ChargeController(settings: settings, makeClient: { [weak self] in self?.client }, helper: helper,
                                 battery: { [weak self] in self?.battery }, chargerSwitch: { nil },
                                 log: { [weak self] in self?.lines.append($0) }, workspace: NotificationCenter(),
                                 limitInForce: ChargeLimitInForce(), onConsole: { true }, rateStore: MemoryRateStore(),
                                 now: { ISO8601DateFormatter().date(from: "2026-11-12T23:00:00Z")! },
                                 calendar: {
                                     var utc = Calendar(identifier: .gregorian)
                                     utc.timeZone = TimeZone(identifier: "UTC")!
                                     return utc
                                 },
                                 hardDrain: engine)
        controller = c
        return c
    }

    private func section(_ c: ChargeController) -> ChargeControlFeature {
        let f = ChargeControlFeature(settings: settings, controller: { c }, installHelper: { _ in })
        view = f.makeView()
        return f
    }
    private var view: NSView?

    private func press(_ button: NSButton) { _ = button.target?.perform(button.action, with: button) }

    // ── The button ──────────────────────────────────────────────────────────

    /// Beside Drain to Limit. Offered while the battery is coming down, and it says so and stops when pressed again.
    func testTheButtonSitsBesideDrainToLimitAndStartsAndStopsIt() throws {
        let c = make()
        let f = section(c)
        XCTAssertEqual(f.hardDrainButton.title, "Hard Drain")
        XCTAssertTrue(f.hardDrainButton.isEnabled)
        XCTAssertEqual(f.hardDrainButton.toolTip, ChargeControlFeature.hardDrainTip)
        let row = try XCTUnwrap(f.hardDrainButton.superview as? NSStackView)
        XCTAssertTrue(row === f.drainButton.superview, "it is not in the row of Drain to Limit")
        let order = row.arrangedSubviews
        XCTAssertEqual(order.firstIndex(of: f.hardDrainButton), order.firstIndex(of: f.drainButton).map { $0 + 1 })
        press(f.hardDrainButton)
        XCTAssertTrue(c.isHardDrainRequested)
        XCTAssertEqual(f.hardDrainButton.title, "Stop Hard Drain")
        XCTAssertTrue(f.statusLabel.stringValue.hasSuffix(" Hard Drain is running, down to 80%."), f.statusLabel.stringValue)
        engine.workers = 0
        engine.waitingBecause = "Ultra Low Power Mode is on"
        f.refresh()
        XCTAssertTrue(f.statusLabel.stringValue.hasSuffix(" Hard Drain is waiting: Ultra Low Power Mode is on."),
                      f.statusLabel.stringValue)
        press(f.hardDrainButton)
        XCTAssertFalse(c.isHardDrainRequested)
        XCTAssertEqual(f.hardDrainButton.title, "Hard Drain")
        XCTAssertFalse(f.statusLabel.stringValue.contains("Hard Drain"))
    }

    /// Not offered when there is nothing to hurry, and the tip says what it needs.
    func testTheButtonIsNotOfferedWhenTheBatteryIsNotComingDown() {
        battery = ReadyByControllerTests.plugged(70)
        let c = make()
        let f = section(c)
        XCTAssertFalse(f.hardDrainButton.isEnabled)
        XCTAssertEqual(f.hardDrainButton.toolTip, ChargeControlFeature.hardDrainBlockedTip)
    }

    /// The tip says what a person has to know before pressing it: it is the processor that is put to work, other apps
    /// come first, the Mac gets warm, and what stops it. No watts.
    func testTheTipSaysWhatItDoesAndWhatStopsIt() {
        let tip = ChargeControlFeature.hardDrainTip
        for part in ["processor and the GPU", "extra work", "on battery", "never below 30%", "all out when nobody",
                     "gently while you are using it", "behind your apps", "gets warm", "fans", "stays awake",
                     "stops by itself at the level", "sleeps", "three hours", "battery is warm"] {
            XCTAssertTrue(tip.contains(part), "\(part) is not in: \(tip)")
        }
        XCTAssertNil(tip.range(of: #"\d\s?W\b"#, options: .regularExpression))
    }

    /// Above the limit in force with the charger in, the battery is coming down by itself: that is what Hard Drain
    /// hurries. It starts the work, with the battery's temperature and the Pause When Hot temperature to go by.
    func testPressedWhileTheBatteryIsComingDownItStartsTheWork() {
        let c = make()
        XCTAssertEqual(c.hardDrainLevel, 80)
        c.pressHardDrain()
        XCTAssertTrue(c.isHardDrainRequested)
        XCTAssertEqual(engine.starts, 1)
        XCTAssertEqual(c.hardDrainWorkers, 6)
        XCTAssertTrue(lines.contains("Hard Drain pressed: bringing the battery down to 80% faster"), lines.joined(separator: "\n"))
        battery?.temperature_C = 36.5
        XCTAssertEqual(engine.temperature?(), 36.5)
        XCTAssertEqual(engine.hotAt?(), 40)
        settings.chargeMaxTemperatureC = 38
        XCTAssertEqual(engine.hotAt?(), 38, "the temperature it stops at is the one chosen for Pause When Hot")
        // It changes nothing about the limit or the charger.
        XCTAssertEqual(client.state?.mclLimit, 80)
        XCTAssertFalse(helper.commands.contains { if case .discharge = $0 { return true } else { return false } })
    }

    func testItCannotBePressedWhenTheBatteryIsNotComingDown() {
        battery = ReadyByControllerTests.plugged(70)     // below the limit: it is charging
        let c = make()
        XCTAssertNil(c.hardDrainLevel)
        c.pressHardDrain()
        XCTAssertFalse(c.isHardDrainRequested)
        XCTAssertEqual(engine.starts, 0)
        battery = ReadyByControllerTests.plugged(80)     // at the limit: held
        c.tick()
        XCTAssertNil(c.hardDrainLevel)
        battery = ReadyByControllerTests.plugged(81, ac: false)     // on battery, a point above the limit: nothing
        c.tick()
        XCTAssertNil(c.hardDrainLevel)
    }

    func testPressedAgainItStops() {
        let c = make()
        c.pressHardDrain()
        c.pressHardDrain()
        XCTAssertFalse(c.isHardDrainRequested)
        XCTAssertEqual(engine.stops, 1)
        XCTAssertTrue(lines.contains("Hard Drain ended: pressed again"))
    }

    func testItEndsWhenTheBatteryIsDownToTheLevel() {
        let c = make()
        c.pressHardDrain()
        battery = ReadyByControllerTests.plugged(81)
        c.tick()
        XCTAssertTrue(c.isHardDrainRequested, "a point above the level it is still coming down")
        battery = ReadyByControllerTests.plugged(80)
        c.tick()
        XCTAssertFalse(c.isHardDrainRequested)
        XCTAssertEqual(engine.stops, 1)
        XCTAssertTrue(lines.contains { $0.hasPrefix("Hard Drain ended: the battery is down to the level") })
    }

    /// Unplugging does not end it: on battery it goes on, to the level the battery is held at on the charger. Sleep
    /// ends it.
    func testUnpluggingDoesNotEndItAndSleepDoes() {
        let c = make()
        c.pressHardDrain()
        battery = ReadyByControllerTests.plugged(91, ac: false)
        c.tick()
        XCTAssertTrue(c.isHardDrainRequested, "unplugging ended it")
        XCTAssertEqual(c.hardDrainLevel, 80)
        XCTAssertEqual(engine.stops, 0)
        c.willSleep()
        XCTAssertFalse(c.isHardDrainRequested)
        XCTAssertEqual(engine.stops, 1)
        XCTAssertTrue(lines.contains("Hard Drain ended: the Mac is going to sleep"))
    }

    // ── On battery ──────────────────────────────────────────────────────────

    /// The owner's case: Hold No Higher Than at 40 and a limit of 100, unplugged at 95%. On battery the level is 40,
    /// the level it would be held at on the charger; it can be pressed, and it ends a point above it.
    func testOnBatteryItDrainsToTheLevelItWouldBeHeldAt() {
        settings.chargeLimit = 100
        settings.chargeReadyByEnabled = true
        settings.chargeReadyByHoldAtMost = 40
        battery = ReadyByControllerTests.plugged(95, ac: false)
        let c = make()
        XCTAssertEqual(c.hardDrainLevel, 40)
        c.pressHardDrain()
        XCTAssertTrue(c.isHardDrainRequested)
        XCTAssertTrue(lines.contains("Hard Drain pressed: bringing the battery down to 40% faster"), lines.joined(separator: "\n"))
        battery = ReadyByControllerTests.plugged(42, ac: false)
        c.tick()
        XCTAssertTrue(c.isHardDrainRequested)
        battery = ReadyByControllerTests.plugged(41, ac: false)
        c.tick()
        XCTAssertFalse(c.isHardDrainRequested, "it went on to the level itself, and could have gone under it")
        XCTAssertTrue(lines.contains { $0.hasPrefix("Hard Drain ended: on battery, the battery is down to a point above") },
                      lines.joined(separator: "\n"))
    }

    /// Without Ready By coming down first, the level on battery is the person's limit.
    func testOnBatteryWithoutReadyByTheLevelIsTheLimit() {
        settings.chargeLimit = 70
        battery = ReadyByControllerTests.plugged(90, ac: false)
        let c = make()
        XCTAssertEqual(c.hardDrainLevel, 70)
        settings.chargeLimit = 100
        c.tick()
        XCTAssertNil(c.hardDrainLevel, "a limit of 100 leaves nothing to drain to on battery")
    }

    /// Never below 30% on battery, whatever the limit: a Mac draining with nobody near it must not go flat.
    func testOnBatteryItNeverGoesBelowThirty() {
        settings.chargeLimit = 20
        battery = ReadyByControllerTests.plugged(60, ac: false)
        let c = make()
        XCTAssertEqual(c.hardDrainLevel, 30)
        XCTAssertEqual(ChargeController.hardDrainFloorOnBattery, 30)
        battery = ReadyByControllerTests.plugged(31, ac: false)
        c.tick()
        XCTAssertNil(c.hardDrainLevel)
        // On the charger the limit is the limit: macOS holds it there.
        battery = ReadyByControllerTests.plugged(60)
        c.tick()
        XCTAssertEqual(c.hardDrainLevel, 20)
    }

    /// Plugged back in, it follows the charger's rule again: with nothing coming down (the limit is 100 and the time is
    /// far off), it is over.
    func testPluggedBackInItFollowsTheChargersRule() {
        settings.chargeLimit = 100
        settings.chargeReadyByEnabled = true
        settings.chargeReadyByHoldAtMost = 40
        battery = ReadyByControllerTests.plugged(95, ac: false)
        let c = make()
        c.pressHardDrain()
        battery = ReadyByControllerTests.plugged(90)
        c.tick()
        XCTAssertEqual(c.lastDecision?.reason, .readyBy, "the fixture: Ready By holds at 40")
        XCTAssertTrue(c.isHardDrainRequested)
        XCTAssertEqual(c.hardDrainLevel, 40)
    }

    func testItEndsWhenChargeControlIsSwitchedOffOrAnodeQuits() {
        let c = make()
        c.pressHardDrain()
        settings.chargeControlEnabled = false
        XCTAssertFalse(c.isHardDrainRequested)
        XCTAssertEqual(engine.stops, 1)
        settings.chargeControlEnabled = true
        c.pressHardDrain()
        c.shutdown()
        XCTAssertEqual(engine.stops, 2, "a worker would be left running after a quit")
    }

    func testWhenTheEngineEndsItselfThePressIsOver() {
        let c = make()
        c.pressHardDrain()
        engine.isRunning = false        // its longest time
        c.tick()
        XCTAssertFalse(c.isHardDrainRequested)
    }

    /// With Ready By letting the battery come down, the level is Ready By's, not the person's limit.
    func testWithReadyByComingDownTheLevelIsTheOneItComesDownTo() {
        settings.chargeLimit = 100
        settings.chargeReadyByEnabled = true
        battery = ReadyByControllerTests.plugged(97)
        let c = make()
        XCTAssertEqual(c.lastDecision?.reason, .readyBy)
        XCTAssertEqual(c.hardDrainLevel, 50)
        c.pressHardDrain()
        XCTAssertTrue(lines.contains("Hard Drain pressed: bringing the battery down to 50% faster"))
    }
}

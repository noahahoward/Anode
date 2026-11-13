import XCTest
@testable import AnodeApp
@testable import PowerKit

/// Ultra Low Power Mode's controller with every part of the Mac faked: nothing here signals a process, hides an app, sets
/// the brightness, the refresh rate, the keyboard light or the power mode, starts a watchdog or touches the real record.
/// `work` runs inline and `schedule` keeps what it is given, so a test fires "the 5 s check" or "the 30 s sweep" by hand.
final class UltraLowPowerControllerTests: XCTestCase {

    // ── Fakes ───────────────────────────────────────────────────────────────

    /// One log that every fake writes to, so a test can say which call came before which.
    final class Calls { var list: [String] = []; func add(_ call: String) { list.append(call) } }

    final class FakeProcesses: ProcessListing {
        var list: [UltraProcess]?
        var snapshots = 0
        /// Whether each read was asked for at the owner's priority (`urgent`), in order.
        private(set) var urgentFlags: [Bool] = []
        /// Keep the completions instead of calling them: a list that takes its time to be read.
        var hold = false
        private(set) var held: [([UltraProcess]?) -> Void] = []
        init(_ list: [UltraProcess]?) { self.list = list }
        func snapshot(urgent: Bool, completion: @escaping ([UltraProcess]?) -> Void) {
            snapshots += 1
            urgentFlags.append(urgent)
            if hold { held.append(completion) } else { completion(list) }
        }
        /// The read finally returns, with the list as it is now.
        func answerHeld() {
            hold = false
            let waiting = held
            held = []
            for completion in waiting { completion(list) }
        }
    }

    final class FakeFreezer: ProcessFreezing {
        let calls: Calls
        var refuse: Set<pid_t> = []
        var refuseResume: Set<pid_t> = []
        /// Called as a process is stopped, before the answer: lets a test look at the record at that moment.
        var onStop: ((pid_t) -> Void)?
        private(set) var stops: [pid_t] = []
        private(set) var resumes: [pid_t] = []
        init(_ calls: Calls) { self.calls = calls }
        func stop(pid: pid_t, startTime: UInt64) -> Bool {
            calls.add("stop \(pid)"); stops.append(pid); onStop?(pid)
            return !refuse.contains(pid)
        }
        func resume(pid: pid_t, startTime: UInt64) -> Bool {
            calls.add("resume \(pid)"); resumes.append(pid)
            return !refuseResume.contains(pid)
        }
    }

    final class FakeThrottler: ProcessThrottling {
        let calls: Calls
        /// Pids the system will not put under the policy (gone, or it said no).
        var refuse: Set<pid_t> = []
        var refuseLift: Set<pid_t> = []
        /// Called as a process is put under the policy, before the answer: lets a test look at the record at that moment.
        var onThrottle: ((pid_t) -> Void)?
        /// Called as the policy is lifted from a process, before the answer.
        var onLift: ((pid_t) -> Void)?
        private(set) var throttled: [pid_t] = []
        private(set) var lifted: [pid_t] = []
        /// The start time each call carried, by pid: the one the snapshot saw.
        private(set) var startTimes: [pid_t: UInt64] = [:]
        private(set) var liftStartTimes: [pid_t: UInt64] = [:]
        init(_ calls: Calls) { self.calls = calls }
        func throttle(pid: pid_t, startTime: UInt64) -> Bool {
            calls.add("throttle \(pid)"); throttled.append(pid); startTimes[pid] = startTime; onThrottle?(pid)
            return !refuse.contains(pid)
        }
        func unthrottle(pid: pid_t, startTime: UInt64) -> Bool {
            calls.add("unthrottle \(pid)"); lifted.append(pid); liftStartTimes[pid] = startTime; onLift?(pid)
            return !refuseLift.contains(pid)
        }
    }

    final class FakeHider: AppHiding {
        let calls: Calls
        /// Keep the completions instead of calling them: an app that takes its time to hide.
        var hold = false
        /// Apps the owner had hidden before the mode: Anode does not hide those, and says so.
        var alreadyHidden: Set<pid_t> = []
        /// Called as an app is asked to hide, before anything is answered: lets a test look at the record at that moment.
        var onHide: ((pid_t) -> Void)?
        private(set) var held: [() -> Void] = []
        private(set) var hidden: [pid_t] = []
        private(set) var unhidden: [pid_t] = []
        init(_ calls: Calls) { self.calls = calls }
        func hide(pid: pid_t, completion: @escaping (Bool) -> Void) {
            calls.add("hide \(pid)"); hidden.append(pid); onHide?(pid)
            let hidByUs = !alreadyHidden.contains(pid)
            if hold { held.append { completion(hidByUs) } } else { completion(hidByUs) }
        }
        func unhide(pid: pid_t) { calls.add("unhide \(pid)"); unhidden.append(pid) }
    }

    final class FakeBacklight: BacklightControl {
        let calls: Calls
        var value: Float? = 0.8
        var refuseSet = false
        /// Called as the brightness is set, before the answer: lets a test look at the record at that moment.
        var onSet: ((Float) -> Void)?
        private(set) var sets: [Float] = []
        init(_ calls: Calls) { self.calls = calls }
        func brightness() -> Float? { calls.add("brightness read"); return value }
        func setBrightness(_ v: Float) -> Bool {
            calls.add("brightness set \(v)"); sets.append(v); onSet?(v)
            if refuseSet { return false }
            value = v
            return true
        }
    }

    final class FakeRate: DisplayRateControlling {
        let calls: Calls
        var canLower = true
        var lowerResult = true
        private(set) var lowered = 0
        private(set) var restored = 0
        init(_ calls: Calls) { self.calls = calls }
        func lower() -> Bool { calls.add("rate lower"); lowered += 1; return lowerResult }
        func restore() { calls.add("rate restore"); restored += 1 }
    }

    final class FakeKeyboard: KeyboardBacklightControlling {
        let calls: Calls
        var current: Float? = 0.6
        var refuseSet = false
        /// Called as the light is set, before the answer: lets a test look at the record at that moment.
        var onSet: ((Float) -> Void)?
        private(set) var sets: [Float] = []
        init(_ calls: Calls) { self.calls = calls }
        func level() -> Float? { current }
        func set(_ level: Float) -> Bool {
            calls.add("keyboard set \(level)"); sets.append(level); onSet?(level)
            return !refuseSet
        }
    }

    final class FakePower: PowerModeControlling {
        let calls: Calls
        var availability: PowerModeAvailability = .ready
        var modeBefore: Int? = 0
        /// What `availability` reads from the moment an enter has been answered: a helper whose answer taught what it is
        /// (an installed helper that had not been heard from, and says it speaks 3).
        var availabilityAfterEnter: PowerModeAvailability?
        /// Keep the completion: a helper that takes its time to answer.
        var hold = false
        private(set) var held: [(Int?) -> Void] = []
        private(set) var entered = 0
        private(set) var restored: [Int] = []
        init(_ calls: Calls) { self.calls = calls }
        func enterLowPower(_ done: @escaping (Int?) -> Void) {
            calls.add("power enter"); entered += 1
            let answer: (Int?) -> Void = { [unowned self] mode in
                if let learned = availabilityAfterEnter { availability = learned }
                done(mode)
            }
            if hold { held.append(answer) } else { answer(modeBefore) }
        }
        func restore(_ mode: Int, _ done: @escaping (Bool) -> Void) { calls.add("power restore \(mode)"); restored.append(mode); done(true) }
    }

    final class FakeWatchdog: UltraWatchdogging {
        let calls: Calls
        var startResult = true
        var pid: pid_t?
        private(set) var started = 0
        private(set) var stopped = 0
        init(_ calls: Calls) { self.calls = calls }
        func start() -> Bool {
            calls.add("watchdog start"); started += 1
            // A watchdog that started is running, under a pid of its own; one already running is left as it is.
            if startResult, pid == nil { pid = pid_t(1000 + started) }
            return startResult
        }
        func stop() { calls.add("watchdog stop"); stopped += 1 }
    }

    final class FakeStore: UltraRecordStoring {
        let calls: Calls
        var record: UltraRecord?
        /// A save this answers true for does not reach the disk.
        var refuseSave: (UltraRecord) -> Bool = { _ in false }
        private(set) var saves: [UltraRecord] = []
        private(set) var cleared = 0
        init(_ calls: Calls) { self.calls = calls }
        func load() -> UltraRecord? { record }
        func save(_ record: UltraRecord) -> Bool {
            calls.add("save")
            if refuseSave(record) { return false }
            saves.append(record); self.record = record
            return true
        }
        func clear() { calls.add("store clear"); cleared += 1; record = nil }
    }

    final class FakeConfirm: UltraConfirming {
        private(set) var keptNames: [[String]] = []
        private(set) var frozenNames: [[String]] = []
        private var answer: ((Bool) -> Void)?
        /// How many times the box was put away while a question was up (as the real box: a no-op with none up).
        private(set) var dismissals = 0
        /// A question is up: nothing has answered it yet.
        var isUp: Bool { answer != nil }
        func ask(kept: [String], frozen: [String], answer: @escaping (Bool) -> Void) {
            keptNames.append(kept); frozenNames.append(frozen); self.answer = answer
        }
        /// The owner's press on Confirm (true) or Cancel (false). One answer to each question, as the real box gives.
        func press(_ yes: Bool) {
            guard let current = answer else { return }
            answer = nil
            current(yes)
        }
        /// The box goes away with its question answered No, once.
        func dismiss() {
            guard let current = answer else { return }
            answer = nil
            dismissals += 1
            current(false)
        }
    }

    final class FakeBackdrop: BackdropPresenting {
        let calls: Calls
        /// Called as the backdrop is shown: lets a test look at the controller at that moment.
        var onShow: (() -> Void)?
        private(set) var shown = false
        private(set) var shows = 0
        private(set) var hides = 0
        init(_ calls: Calls) { self.calls = calls }
        /// Only the show is on the shared log, to say where it came in the order; a hide is counted and not logged, since it is
        /// asked for on every path that ends a session, a start that never began included.
        func show() { calls.add("backdrop show"); shows += 1; shown = true; onShow?() }
        func hide() { hides += 1; shown = false }
    }

    final class FakeLoad: LoadReading {
        let calls: Calls
        /// What the next reads answer, in order; `fallback` after that.
        var queue: [LoadSample?] = []
        var fallback: LoadSample? = LoadSample(busyCores: 1.0, byProcess: [10: 0.2])
        /// Keep the completions of this many of the next reads instead of calling them: a reading that takes its time.
        var holdNext = 0
        private(set) var held: [(LoadSample?) -> Void] = []
        private(set) var reads = 0
        init(_ calls: Calls) { self.calls = calls }
        private func next() -> LoadSample? { queue.isEmpty ? fallback : queue.removeFirst() }
        func read(completion: @escaping (LoadSample?) -> Void) {
            calls.add("load read"); reads += 1
            if holdNext > 0 { holdNext -= 1; held.append(completion) } else { completion(next()) }
        }
        /// The held readings finally return.
        func answerHeld() {
            let waiting = held
            held = []
            for completion in waiting { completion(next()) }
        }
    }

    // ── The rig ─────────────────────────────────────────────────────────────

    private let calls = Calls()
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: Settings!
    private var processes: FakeProcesses!
    private var freezer: FakeFreezer!
    private var throttler: FakeThrottler!
    private var hider: FakeHider!
    private var backlight: FakeBacklight!
    private var own: OwnBrightness!
    private var rate: FakeRate!
    private var keyboard: FakeKeyboard!
    private var power: FakePower!
    private var watchdog: FakeWatchdog!
    private var store: FakeStore!
    private var confirm: FakeConfirm!
    private var backdrop: FakeBackdrop!
    private var load: FakeLoad!
    private var controller: UltraLowPowerController!

    /// The process table the controller reads at the end of a session, fresh each time: what the fake system holds, unless a test
    /// gives its own reader (one that cannot read the table, say). `tableReads` says how often it was read.
    private var tableReader: (() -> [UltraProcess]?)?
    private var tableReads = 0
    /// What the fake system says a pid's start time is: `proc` gives each process pid * 10. A pid in `recycled` is another process
    /// now (a different start time); one in `gone` is not there.
    private var recycled: [pid_t: UInt64] = [:]
    private var gone: Set<pid_t> = []
    /// Whether this Mac has efficiency cores, as the controller is told when it is made.
    private var hasEfficiencyCores = true
    /// What the fake system answers to "who is in front" and "which processes are Anode's".
    private var front: pid_t? = 10
    private var ownPIDs: Set<pid_t> = [1000]
    private var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
    /// What the controller scheduled while the start was running (the deadline of each step that had not finished), kept apart
    /// so that the sweep's and the guard's timers are found by their own delays.
    private var startDeadlines: [(delay: TimeInterval, work: () -> Void)] = []
    private var logged: [String] = []
    /// What the controller says out loud (the beep), and what its wait for the work queue is told and answers.
    private var alerts = 0
    private var waitedFor: [TimeInterval] = []
    private var waitAnswers: Bool?
    private var workRuns = 0
    /// Keep what is handed to `work` instead of running it: a display or a keyboard light that is slow to answer.
    private var holdWork = false
    /// Keep what is handed to `work` once this many jobs have run: the next one is on the queue when a test acts.
    private var workLimit: Int?
    private var heldWork: [() -> Void] = []

    override func setUpWithError() throws {
        (defaults, suiteName) = try TestDefaults.make(owner: "UltraLowPowerController", test: name)
        settings = Settings(defaults: defaults)
        processes = FakeProcesses(world)
        freezer = FakeFreezer(calls); throttler = FakeThrottler(calls); hider = FakeHider(calls)
        backlight = FakeBacklight(calls); own = OwnBrightness()
        rate = FakeRate(calls); keyboard = FakeKeyboard(calls); power = FakePower(calls); watchdog = FakeWatchdog(calls)
        store = FakeStore(calls); confirm = FakeConfirm(); backdrop = FakeBackdrop(calls); load = FakeLoad(calls)
        controller = makeController()
    }

    /// A controller over the fakes above. A test that wants a Mac without efficiency cores sets `hasEfficiencyCores` and makes
    /// another.
    private func makeController() -> UltraLowPowerController {
        UltraLowPowerController(
            settings: settings, processes: processes, freezer: freezer, throttler: throttler,
            processTable: { [unowned self] in
                self.tableReads += 1
                if let reader = self.tableReader { return reader() }
                return self.processes.list
            },
            startTime: { [unowned self] pid in self.gone.contains(pid) ? nil : (self.recycled[pid] ?? UInt64(pid) * 10) },
            hasEfficiencyCores: hasEfficiencyCores, hider: hider, backlight: backlight,
            ownBrightness: own, rate: rate, keyboard: keyboard, power: power, watchdog: watchdog, store: store,
            confirm: confirm, backdrop: backdrop, load: load,
            lastOtherFrontApp: { [unowned self] in self.front }, ownPIDs: { [unowned self] in self.ownPIDs }, user: 501,
            work: { [unowned self] job in
                if self.holdWork || self.workLimit.map({ self.workRuns >= $0 }) == true {
                    self.heldWork.append(job)
                } else {
                    self.workRuns += 1; job()
                }
            },
            // The queue as a quit finds it: idle when nothing is being held, unless a test says what it answers.
            waitForWork: { [unowned self] limit in
                self.waitedFor.append(limit)
                self.calls.add("wait for work \(limit)")
                return self.waitAnswers ?? self.heldWork.isEmpty
            },
            schedule: { [unowned self] delay, job in
                if self.controller?.state == .confirming {
                    self.startDeadlines.append((delay, job))
                } else {
                    self.scheduled.append((delay, job))
                }
            },
            alert: { [unowned self] in self.alerts += 1 },
            log: { [unowned self] in self.logged.append($0) })
    }

    override func tearDownWithError() throws {
        controller = nil
        TestDefaults.destroy(defaults, suiteName)
    }

    // ── A made-up Mac ───────────────────────────────────────────────────────

    private func proc(_ pid: pid_t, parent: pid_t = 1, uid: uid_t = 501, path: String, app: AppKind = .none,
                      bundle: String? = nil, name: String? = nil) -> UltraProcess {
        UltraProcess(pid: pid, parent: parent, uid: uid, startTime: UInt64(pid) * 10, path: path, app: app, bundleID: bundle,
                     name: name ?? path.split(separator: "/").last.map(String.init) ?? "p\(pid)")
    }

    /// Anode (1000); the editor in front (10) with the shell it runs; a browser (20) with a helper; a sync agent (30)
    /// with an extension macOS hosts for it (31); one service of the system. Kept: the editor. Frozen: the browser, sync.
    private var world: [UltraProcess] {
        [proc(1000, path: "/Applications/Anode.app/Contents/MacOS/Anode", app: .regular, bundle: "dev.example.self", name: "Anode"),
         proc(10, path: "/Applications/Editor.app/Contents/MacOS/Editor", app: .regular, bundle: "com.example.editor", name: "Editor"),
         proc(11, parent: 10, path: "/bin/zsh"),
         proc(20, path: "/Applications/Browser.app/Contents/MacOS/Browser", app: .regular, bundle: "com.example.browser", name: "Browser"),
         proc(21, parent: 20, path: "/Applications/Browser.app/Contents/Frameworks/Browser Helper.app/Contents/MacOS/Browser Helper"),
         proc(30, path: "/Applications/Sync.app/Contents/MacOS/Sync", app: .accessory, bundle: "com.example.sync", name: "Sync"),
         proc(31, parent: 30, path: "/Applications/Sync.app/Contents/PlugIns/Partner.appex/Contents/MacOS/Partner"),
         proc(50, path: "/usr/libexec/syslogd")]
    }

    /// An app with a part that belongs to the root user: Anode cannot stop that part, so the app is left running whole.
    private var cloud: [UltraProcess] {
        [proc(40, path: "/Applications/Cloud.app/Contents/MacOS/Cloud", app: .regular, bundle: "com.example.cloud", name: "Cloud"),
         proc(41, uid: 0, path: "/Applications/Cloud.app/Contents/Library/clouddaemon")]
    }

    private func sample(_ busy: Double = 1.0, _ byProcess: [pid_t: Double] = [10: 0.2]) -> LoadSample {
        LoadSample(busyCores: busy, byProcess: byProcess)
    }

    // ── Doing things ────────────────────────────────────────────────────────

    /// Asks for the mode and presses Confirm.
    private func start() {
        controller.request()
        confirm.press(true)
    }

    /// Runs what was scheduled for `delay` seconds from now (the first such item).
    private func fire(_ delay: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        guard let i = scheduled.firstIndex(where: { $0.delay == delay }) else {
            return XCTFail("nothing is scheduled \(delay) s ahead; pending: \(scheduled.map(\.delay))", file: file, line: line)
        }
        scheduled.remove(at: i).work()
    }

    /// Runs the deadline of the step of the start that is waiting now (the first such item scheduled for `delay` seconds).
    private func fireStartDeadline(_ delay: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        guard let i = startDeadlines.firstIndex(where: { $0.delay == delay }) else {
            return XCTFail("no step of the start waits \(delay) s; pending: \(startDeadlines.map(\.delay))", file: file, line: line)
        }
        startDeadlines.remove(at: i).work()
    }

    /// One pass over what is pending now (a sweep schedules the next one, so this does not loop until nothing is left).
    private func fireEverythingPending() {
        let pending = scheduled
        scheduled = []
        pending.forEach { $0.work() }
    }

    private func firstIndex(_ prefix: String) -> Int? { calls.list.firstIndex { $0.hasPrefix(prefix) } }
    private func lastIndex(_ prefix: String) -> Int? { calls.list.lastIndex { $0.hasPrefix(prefix) } }

    /// Every call that starts with `first` came before every call that starts with `then`.
    private func assertAllBefore(_ first: String, _ then: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let a = lastIndex(first), let b = firstIndex(then) else {
            return XCTFail("expected calls \"\(first)\" and \"\(then)\" in \(calls.list)", file: file, line: line)
        }
        XCTAssertLessThan(a, b, "\"\(first)\" must all come before \"\(then)\": \(calls.list)", file: file, line: line)
    }

    /// The queue gets round to what it was given.
    private func runHeldWork() {
        holdWork = false
        workLimit = nil
        let jobs = heldWork
        heldWork = []
        for job in jobs { workRuns += 1; job() }
    }

    private func groupIDs(_ groups: [FreezeGroup]) -> [String] { groups.map(\.id) }

    // ── Asking ──────────────────────────────────────────────────────────────

    func testRequestShowsWhatWillBeKeptAndFrozenByName() {
        controller.request()
        XCTAssertEqual(controller.state, .confirming)
        XCTAssertEqual(confirm.keptNames, [["Editor"]])
        XCTAssertEqual(confirm.frozenNames, [["Browser", "Sync"]])
        XCTAssertEqual(freezer.stops, [], "nothing is touched before Confirm")
        XCTAssertNil(store.record)
    }

    func testTheAppInFrontWhenTheModeWasAskedForIsTheOneKept() {
        controller.request()
        front = 20   // the request itself, or the owner, moved on while the box was open
        confirm.press(true)
        XCTAssertFalse(freezer.stops.contains(10))
        XCTAssertTrue(freezer.stops.contains(20), "what the box listed is what happens")
    }

    func testTheAlwaysKeepListIsKept() {
        settings.ultraLowPowerAlwaysKeep = ["com.example.browser"]
        controller.request()
        XCTAssertEqual(confirm.keptNames.last?.sorted(), ["Browser", "Editor"])
        XCTAssertEqual(confirm.frozenNames, [["Sync"]])
    }

    func testCancelChangesNothing() {
        controller.request()
        confirm.press(false)
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(freezer.stops, [])
        XCTAssertEqual(store.saves.count, 0)
        XCTAssertNil(store.record)
        XCTAssertEqual(watchdog.started, 0)
        XCTAssertEqual(backlight.sets, [])
        XCTAssertEqual(power.entered, 0)
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testAFailedSnapshotStartsNothing() {
        processes.list = nil
        controller.request()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(confirm.keptNames.count, 0, "the owner is not asked about a list nobody could read")
        XCTAssertTrue(logged.contains { $0.contains("process list") }, "\(logged)")
        // And it can be asked again.
        processes.list = world
        controller.request()
        XCTAssertEqual(controller.state, .confirming)
    }

    func testRequestWhileOnOrConfirmingDoesNothing() {
        controller.request()
        controller.request()
        XCTAssertEqual(confirm.keptNames.count, 1)
        XCTAssertEqual(processes.snapshots, 1)
        confirm.press(true)
        XCTAssertEqual(controller.state, .on)
        controller.request()
        XCTAssertEqual(confirm.keptNames.count, 1)
        XCTAssertEqual(processes.snapshots, 1)
        XCTAssertEqual(controller.state, .on)
    }

    func testTheLoadIsReadWhenTheBoxOpensSoTheReadingAtConfirmHasSomethingToCompareWith() {
        controller.request()
        XCTAssertEqual(load.reads, 1)
        confirm.press(true)
        XCTAssertEqual(load.reads, 2, "the 'before' reading")
    }

    // ── Confirm: the order, and what stops a start ──────────────────────────

    func testConfirmWritesTheRecordBeforeAnythingIsStopped() throws {
        var recordedWhenStopped: [pid_t: Bool] = [:]
        freezer.onStop = { [unowned self] pid in
            recordedWhenStopped[pid] = self.store.record?.groups.flatMap(\.members).contains { $0.pid == pid } ?? false
        }
        start()
        XCTAssertEqual(controller.state, .on)
        XCTAssertEqual(recordedWhenStopped, [20: true, 21: true, 30: true], "a process is named on disk before it is stopped")
        // The order across the parts.
        XCTAssertLessThan(try XCTUnwrap(lastIndex("load read")), try XCTUnwrap(firstIndex("save")), "the load is read first")
        XCTAssertLessThan(try XCTUnwrap(firstIndex("save")), try XCTUnwrap(firstIndex("watchdog start")))
        XCTAssertLessThan(try XCTUnwrap(firstIndex("watchdog start")), try XCTUnwrap(firstIndex("hide")))
        XCTAssertLessThan(try XCTUnwrap(firstIndex("watchdog start")), try XCTUnwrap(firstIndex("stop")))
        // The first record names every group that is about to be stopped.
        let first = store.saves.first
        XCTAssertEqual(first?.groups.map(\.id), ["com.example.browser", "com.example.sync"])
        XCTAssertEqual(first?.groups.map(\.appPID), [nil, nil], "an app is named just before its own hide, not before")
        XCTAssertEqual(first?.groups.first?.members, [.init(pid: 20, startTime: 200), .init(pid: 21, startTime: 210)])
        XCTAssertEqual(first?.groups.map(\.released), [false, false])
    }

    func testARecordThatCannotBeSavedStartsNothing() {
        store.refuseSave = { _ in true }
        start()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(freezer.stops, [])
        XCTAssertEqual(hider.hidden, [])
        XCTAssertEqual(watchdog.started, 0)
        XCTAssertEqual(backlight.sets, [])
        XCTAssertEqual(rate.lowered, 0)
        XCTAssertEqual(keyboard.sets, [])
        XCTAssertEqual(power.entered, 0)
        XCTAssertTrue(scheduled.isEmpty)
        XCTAssertTrue(logged.contains { $0.contains("record") }, "\(logged)")
    }

    func testAWatchdogThatDidNotStartStartsNothing() {
        watchdog.startResult = false
        start()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(freezer.stops, [])
        XCTAssertEqual(hider.hidden, [])
        XCTAssertEqual(backlight.sets, [])
        XCTAssertEqual(rate.lowered, 0)
        XCTAssertEqual(power.entered, 0)
        XCTAssertNil(store.record, "the record it wrote is taken back: nothing was done")
        XCTAssertGreaterThan(store.cleared, 0)
        XCTAssertTrue(scheduled.isEmpty)
        XCTAssertTrue(logged.contains { $0.contains("watchdog") }, "\(logged)")
    }

    func testTheWatchdogIsNeverFrozenOrBlamed() {
        // The watchdog is a copy of Anode's own program; here its file sits in the browser's folder, so that nothing but
        // being Anode's own keeps it out of the browser's group.
        watchdog.pid = 900
        processes.list = world + [proc(900, path: "/Applications/Browser.app/Contents/MacOS/Watchdog")]
        load.queue = [nil, sample(), sample(1.0, [10: 0.2, 900: 1.0])]
        start()
        XCTAssertFalse(freezer.stops.contains(900), "stopped: \(freezer.stops)")
        XCTAssertEqual(confirm.frozenNames, [["Browser", "Sync"]])
        fire(5)   // it reads 1 core: as the browser's it would be a process the freeze made burn
        XCTAssertEqual(controller.releasedForLoad, [])
        XCTAssertEqual(freezer.resumes, [])
        // A later sweep does not take it for a new process of the browser either.
        fire(30)
        XCTAssertFalse(freezer.stops.contains(900), "stopped: \(freezer.stops)")
    }

    func testConfirmHidesThenStopsEachGroup() {
        start()
        let moves = calls.list.filter { $0.hasPrefix("hide") || $0.hasPrefix("stop") }
        // Only the app with windows is hidden; the sync agent has none.
        XCTAssertEqual(moves, ["hide 20", "stop 20", "stop 21", "stop 30"])
        XCTAssertEqual(controller.frozen.map(\.id), ["com.example.browser", "com.example.sync"])
        XCTAssertEqual(controller.frozen.first?.members.map(\.pid), [20, 21])
        XCTAssertEqual(controller.state, .on)
    }

    // ── Hiding: what Anode hid, and only that, is unhidden ──────────────────

    func testTheAppIsOnTheRecordBeforeItIsHidden() {
        var named: [Int32?] = []
        hider.onHide = { [unowned self] _ in named.append(self.store.record?.groups.first { $0.id == "com.example.browser" }?.appPID) }
        start()
        XCTAssertEqual(named, [20], "a crash while the app is being hidden still finds it on the record")
        XCTAssertEqual(store.record?.groups.first?.appPID, 20, "and it stays there: Anode hid it")
    }

    func testAnAppWhoseMembersAllRefusedToStopIsUnhiddenAtOnce() {
        freezer.refuse = [20, 21]
        start()
        XCTAssertEqual(hider.unhidden, [20], "nothing was stopped behind that hide, so nothing else will ever unhide it")
        XCTAssertEqual(groupIDs(controller.frozen), ["com.example.sync"])
        XCTAssertEqual(store.record?.groups.map(\.id), ["com.example.sync"])
        controller.turnOff()
        XCTAssertEqual(hider.unhidden, [20], "once")
        XCTAssertEqual(freezer.resumes, [30])
    }

    func testAnAppTheOwnerHadHiddenIsNotNamedAsHiddenByUs() {
        hider.alreadyHidden = [20]
        start()
        XCTAssertNil(store.record?.groups.first?.appPID, "it was named for the hide, and taken off when Anode did not hide it")
        let named = store.saves.firstIndex { $0.groups.first?.appPID == 20 }
        let cleared = store.saves.lastIndex { $0.groups.first?.appPID == nil }
        XCTAssertNotNil(named)
        XCTAssertLessThan(named ?? 99, cleared ?? -1, "written ahead, then taken back")
        XCTAssertEqual(freezer.stops, [20, 21, 30], "it is stopped all the same")
    }

    func testAFailedWriteWhenTakingAnAppOffTheRecordDoesNotStopTheStep() {
        hider.alreadyHidden = [20]
        hider.onHide = { [unowned self] _ in self.store.refuseSave = { $0.groups.first?.appPID == nil } }
        start()
        XCTAssertEqual(freezer.stops, [20, 21, 30])
        XCTAssertTrue(logged.contains { $0.contains("record") }, "\(logged)")
        controller.turnOff()
        XCTAssertEqual(hider.unhidden, [], "the in-memory record no longer names it, whatever the disk says")
    }

    func testAnAppTheOwnerHadHiddenIsStillHiddenAfterTurningOff() {
        hider.alreadyHidden = [20]
        start()
        controller.turnOff()
        XCTAssertEqual(freezer.resumes, [20, 21, 30])
        XCTAssertEqual(hider.unhidden, [])
    }

    func testAnAppTheOwnerHadHiddenIsStillHiddenAfterAReleaseAndAnActivation() {
        hider.alreadyHidden = [20]
        start()
        controller.release(groupID: "com.example.browser")
        XCTAssertEqual(freezer.resumes, [20, 21])
        XCTAssertEqual(hider.unhidden, [])
        controller.appActivated(pid: 30)   // the sync agent: no app of its own to unhide either
        XCTAssertEqual(hider.unhidden, [])
    }

    func testActivatingAnAppTheOwnerHadHiddenReleasesItsGroupAndUnhidesNothing() {
        hider.alreadyHidden = [20]
        start()
        controller.appActivated(pid: 20)
        XCTAssertEqual(freezer.resumes, [20, 21], "the group is released")
        XCTAssertEqual(groupIDs(controller.frozen), ["com.example.sync"])
        XCTAssertEqual(hider.unhidden, [], "it was the owner's hiding, and the owner just showed it")
    }

    func testActivatingAnAppTheOwnerHadHiddenAndWhoseOwnStopFailedStillReleasesItsHelpers() {
        // Neither a member (its stop failed) nor named as hidden by Anode (it was not): the app's pid still has to find
        // its group, or its stopped helpers would stay stopped behind a window the owner has just opened.
        hider.alreadyHidden = [20]
        freezer.refuse = [20]
        start()
        XCTAssertEqual(controller.frozen.first?.members.map(\.pid), [21])
        XCTAssertNil(store.record?.groups.first?.appPID)
        controller.appActivated(pid: 20)
        XCTAssertEqual(freezer.resumes, [21])
        XCTAssertEqual(groupIDs(controller.frozen), ["com.example.sync"])
        XCTAssertEqual(hider.unhidden, [])
    }

    func testAnAppThatWasSlowToHideIsStillUnhiddenAtTheEnd() {
        hider.hold = true
        start()
        hider.held.forEach { $0() }   // the hide was taken and reported after the wait: Anode did it
        XCTAssertEqual(controller.state, .on)
        controller.turnOff()
        XCTAssertEqual(hider.unhidden, [20])
    }

    func testAnAppTheOwnerHadHiddenIsStillHiddenAfterQuitting() {
        hider.alreadyHidden = [20]
        start()
        controller.shutdown()
        XCTAssertEqual(freezer.resumes, [20, 21, 30])
        XCTAssertEqual(hider.unhidden, [])
    }

    func testRecoveryUnhidesOnlyWhatTheRecordNames() {
        var record = UltraRecord()
        record.groups = [UltraRecord.Group(id: "com.example.browser", name: "Browser", members: [.init(pid: 20, startTime: 200)]),
                         UltraRecord.Group(id: "com.example.other", name: "Other", members: [.init(pid: 60, startTime: 600)], appPID: 60)]
        store.record = record
        controller.recoverAtLaunch()
        XCTAssertEqual(freezer.resumes, [20, 60])
        XCTAssertEqual(hider.unhidden, [60], "the browser was hidden by the owner, so the record never named it")
    }

    // ── Confirm: the screen, the keyboard light, the power mode ─────────────

    func testConfirmAppliesCeilingRateKeyboardAndLowPower() {
        start()
        XCTAssertEqual(backlight.sets, [0.25])
        XCTAssertEqual(backlight.value, 0.25)
        XCTAssertEqual(rate.lowered, 1)
        XCTAssertEqual(keyboard.sets, [0])
        XCTAssertEqual(power.entered, 1)
        XCTAssertEqual(controller.skipped, [])
        let record = store.record
        XCTAssertEqual(record?.brightnessBefore, 0.8)
        XCTAssertEqual(record?.rateLowered, true)
        XCTAssertEqual(record?.keyboardBefore, 0.6)
        XCTAssertEqual(record?.powerModeBefore, 0)
        XCTAssertEqual(own.forget("ultra"), 0.8, "the owner's brightness is noted where every feature that dims the screen can see it")
    }

    func testTheSettingsAreRecordedBeforeTheyAreChanged() {
        // A crash between a change and its record would leave the screen dim with nothing to put it back.
        var brightnessOnDisk: Float?
        var keyboardOnDisk: Float?
        backlight.onSet = { [unowned self] _ in brightnessOnDisk = self.store.record?.brightnessBefore }
        keyboard.onSet = { [unowned self] _ in keyboardOnDisk = self.store.record?.keyboardBefore }
        start()
        XCTAssertEqual(brightnessOnDisk, 0.8)
        XCTAssertEqual(keyboardOnDisk, 0.6)
    }

    func testBrightnessBelowTheCeilingIsNotTouchedOrRemembered() {
        backlight.value = 0.2
        start()
        XCTAssertEqual(backlight.sets, [])
        XCTAssertNil(store.record?.brightnessBefore)
        controller.turnOff()
        XCTAssertEqual(backlight.sets, [], "nothing was lowered, so nothing is put back")
        XCTAssertNil(own.forget("ultra"), "never noted")
    }

    func testAScreenThatCannotBeReadOrSetIsLeftAloneAndSaid() {
        backlight.value = nil
        start()
        XCTAssertEqual(backlight.sets, [])
        XCTAssertEqual(controller.state, .on)
        XCTAssertEqual(controller.skipped, [.ceilingRefused], "the owner is told the limit is not held")
        XCTAssertTrue(logged.contains { $0.contains("brightness") }, "\(logged)")
        controller.turnOff()

        // One that refuses: what was written ahead is taken back, and nothing is put back at the end.
        backlight.value = 0.8
        backlight.refuseSet = true
        logged = []
        own.remember(0.9, for: "lid")
        start()
        XCTAssertEqual(controller.state, .on)
        XCTAssertEqual(controller.skipped, [.ceilingRefused])
        XCTAssertNil(store.record?.brightnessBefore)
        XCTAssertTrue(logged.contains { $0.contains("brightness") }, "\(logged)")
        XCTAssertEqual(own.forget("lid"), 0.9, "this feature lowered nothing, so it does not hold the screen: the lid is the last one out")
        controller.turnOff()
        XCTAssertEqual(backlight.sets, [0.25], "the one refused try; nothing 'restored'")
        XCTAssertNil(own.forget("ultra"))
    }

    func testNoHelperSkipsLowPowerAndSaysSo() {
        power.availability = .noHelper
        start()
        XCTAssertEqual(controller.skipped, [.lowPowerNoHelper])
        XCTAssertEqual(power.entered, 0)
        XCTAssertNil(store.record?.powerModeBefore)
        // Everything else is done.
        XCTAssertEqual(controller.state, .on)
        XCTAssertEqual(backlight.value, 0.25)
        XCTAssertEqual(rate.lowered, 1)
        XCTAssertEqual(keyboard.sets, [0])
        XCTAssertEqual(freezer.stops, [20, 21, 30])
    }

    func testAnOldHelperSkipsLowPowerAndSaysSo() {
        power.availability = .oldHelper
        start()
        XCTAssertEqual(controller.skipped, [.lowPowerOldHelper])
        XCTAssertEqual(power.entered, 0)
        XCTAssertEqual(controller.state, .on)
    }

    func testOneRateScreenIsSkippedAndSaid() {
        rate.canLower = false
        start()
        XCTAssertEqual(controller.skipped, [.oneRefreshRate])
        XCTAssertEqual(rate.lowered, 0)
        XCTAssertEqual(store.record?.rateLowered, false)
        XCTAssertEqual(controller.state, .on)
    }

    func testAMacWithoutAKeyboardLightSkipsItAndEverySkipIsSaidInTheOrderItWasMet() {
        keyboard.current = nil
        rate.canLower = false
        power.availability = .noHelper
        start()
        XCTAssertEqual(controller.skipped, [.oneRefreshRate, .keyboardLight, .lowPowerNoHelper])
        XCTAssertEqual(keyboard.sets, [])
        XCTAssertNil(store.record?.keyboardBefore)
    }

    func testAKeyboardLightThatIsOffAlreadyIsNotTouched() {
        keyboard.current = 0
        start()
        XCTAssertEqual(keyboard.sets, [], "putting a 0 back over a light the owner turned on later would not be this feature's to do")
        XCTAssertNil(store.record?.keyboardBefore)
        XCTAssertEqual(controller.skipped, [], "nothing to skip: it is off")
    }

    func testAKeyboardLightThatRefusesIsLeftAloneAndSaid() {
        keyboard.refuseSet = true
        start()
        XCTAssertEqual(controller.skipped, [.keyboardLight])
        XCTAssertNil(store.record?.keyboardBefore, "what was written ahead is taken back")
    }

    /// An installed helper that had not been heard from reads ready, and the answer to the enter is what teaches that it is
    /// an older one: the nil is then said as that, with the way to install the newer, and not as a refusal.
    func testAnEnterThatTaughtTheHelperIsOldIsSaidAsOldAndNotAsRefused() {
        power.modeBefore = nil
        power.availabilityAfterEnter = .oldHelper
        start()
        XCTAssertEqual(controller.state, .on)
        XCTAssertEqual(controller.skipped, [.lowPowerOldHelper])
        XCTAssertNil(store.record?.powerModeBefore)
        XCTAssertEqual(power.entered, 1)
    }

    func testAnEnterThatTaughtThereIsNoHelperIsSaidAsNoHelper() {
        power.modeBefore = nil
        power.availabilityAfterEnter = .noHelper
        start()
        XCTAssertEqual(controller.skipped, [.lowPowerNoHelper])
    }

    /// Only a no is read again: a yes records the mode and says nothing, whatever the helper is said to be afterwards.
    func testAnEnterThatWasTakenSaysNothingEvenIfTheHelperReadsOldAfterwards() {
        power.modeBefore = 2
        power.availabilityAfterEnter = .oldHelper
        start()
        XCTAssertEqual(controller.skipped, [])
        XCTAssertEqual(store.record?.powerModeBefore, 2)
    }

    func testARefreshRateTheDisplayRefusedIsSaidInTheLogAndNotRecorded() {
        rate.lowerResult = false
        start()
        XCTAssertEqual(controller.skipped, [.rateRefused])
        XCTAssertEqual(store.record?.rateLowered, false)
        XCTAssertTrue(logged.contains { $0.contains("refresh") }, "\(logged)")
    }

    /// The helper is still there and still ready after it said no: it refused, and that is what the section says.
    func testALowPowerModeThatCouldNotBeEnteredIsSaidInTheLogAndNotRecorded() {
        power.modeBefore = nil
        start()
        XCTAssertEqual(controller.state, .on)
        XCTAssertEqual(controller.skipped, [.lowPowerRefused])
        XCTAssertNil(store.record?.powerModeBefore)
        XCTAssertTrue(logged.contains { $0.contains("power") }, "\(logged)")
        controller.turnOff()
        XCTAssertEqual(power.restored, [])
    }

    func testARefreshRateTheRecordCannotNameIsNotLowered() {
        store.refuseSave = { $0.rateLowered }
        start()
        XCTAssertEqual(rate.lowered, 0)
        XCTAssertEqual(controller.skipped, [.rateRefused])
        XCTAssertEqual(controller.state, .on)
    }

    func testASettingTheRecordCannotNameIsNotChanged() {
        // From the first save that carries a setting on, the disk refuses: nothing that could not be undone after a crash is done.
        store.refuseSave = { $0.brightnessBefore != nil || $0.keyboardBefore != nil }
        start()
        XCTAssertEqual(controller.state, .on)
        XCTAssertEqual(backlight.sets, [])
        XCTAssertEqual(keyboard.sets, [])
        XCTAssertEqual(freezer.stops, [20, 21, 30], "the groups were on the record, so they were stopped")
        XCTAssertEqual(controller.skipped, [.ceilingRefused, .keyboardLight], "and the owner is told what was not done")
        XCTAssertTrue(logged.contains { $0.contains("record") }, "\(logged)")
        XCTAssertNil(own.forget("ultra"), "what was noted is taken back too")
    }

    // ── Turning off ─────────────────────────────────────────────────────────

    func testTurnOffPutsEverythingBack() {
        start()
        let workBefore = workRuns
        calls.list.removeAll()
        controller.turnOff()

        XCTAssertEqual(freezer.resumes, [20, 21, 30])
        XCTAssertEqual(hider.unhidden, [20])
        XCTAssertEqual(backlight.value, 0.8)
        XCTAssertEqual(rate.restored, 1)
        XCTAssertEqual(keyboard.sets, [0, 0.6])
        XCTAssertEqual(power.restored, [0])
        XCTAssertNil(store.record)
        XCTAssertEqual(watchdog.stopped, 1)
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(controller.frozen, [])
        XCTAssertEqual(controller.skipped, [])
        XCTAssertEqual(controller.leftRunning, [])
        XCTAssertFalse(controller.isFrozen(pid: 20))
        XCTAssertGreaterThan(workRuns, workBefore, "the settings that can block are put back off the main thread")

        // Processes first, then the screen, the rate, the keyboard light, the power mode; then the safety net comes down.
        assertAllBefore("resume", "unhide")
        assertAllBefore("unhide", "brightness")
        assertAllBefore("brightness", "rate restore")
        assertAllBefore("rate restore", "keyboard set")
        assertAllBefore("keyboard set", "power restore")
        assertAllBefore("power restore", "watchdog stop")
        assertAllBefore("watchdog stop", "store clear")
    }

    func testAContinueThatFailedIsLoggedWithTheGroupAndThePid() {
        start()
        freezer.refuseResume = [21]
        controller.turnOff()
        XCTAssertEqual(freezer.resumes, [20, 21, 30], "the others are continued all the same")
        XCTAssertEqual(logged.filter { $0.contains("Browser") && $0.contains("21") }.count, 1, "\(logged)")
        XCTAssertEqual(controller.state, .off)
    }

    func testAContinueThatFailedWhileQuittingOrRecoveringIsLoggedToo() {
        start()
        freezer.refuseResume = [30]
        controller.shutdown()
        XCTAssertEqual(logged.filter { $0.contains("Sync") && $0.contains("30") }.count, 1, "\(logged)")

        logged = []
        var record = UltraRecord()
        record.groups = [UltraRecord.Group(id: "com.example.browser", name: "Browser", members: [.init(pid: 20, startTime: 200)])]
        store.record = record
        controller.recoverAtLaunch()
        XCTAssertEqual(logged.filter { $0.contains("Browser") && $0.contains("20") }.count, 0, "it answered: nothing failed")
        freezer.refuseResume = [20]
        store.record = record
        controller.recoverAtLaunch()
        XCTAssertEqual(logged.filter { $0.contains("Browser") && $0.contains("20") }.count, 1, "\(logged)")
    }

    func testARestoreThatFailedIsLoggedOnce() {
        start()
        backlight.refuseSet = true
        keyboard.refuseSet = true
        logged = []
        controller.turnOff()
        XCTAssertEqual(logged.filter { $0.contains("brightness") }.count, 1, "\(logged)")
        XCTAssertEqual(logged.filter { $0.contains("keyboard") }.count, 1, "\(logged)")
        XCTAssertEqual(controller.state, .off, "and the rest is done all the same")
        XCTAssertEqual(power.restored, [0])
    }

    func testAScreenThatCannotBeReadAtTheEndIsLoggedOnce() {
        start()
        backlight.value = nil
        logged = []
        controller.turnOff()
        XCTAssertEqual(logged.filter { $0.contains("brightness") }.count, 1, "\(logged)")
        XCTAssertEqual(backlight.sets, [0.25], "nothing was set at the end")
        XCTAssertEqual(controller.state, .off, "and the rest is done all the same")

        // Nothing lowered, so nothing to put back and nothing to say.
        backlight.value = 0.2
        start()
        backlight.value = nil
        logged = []
        controller.turnOff()
        XCTAssertEqual(logged.filter { $0.contains("brightness") }.count, 0, "\(logged)")
    }

    func testTurnOffLeavesAScreenTheOwnerChangedAlone() {
        start()
        backlight.value = 0.15   // the owner went dimmer
        controller.turnOff()
        XCTAssertEqual(backlight.sets, [0.25], "only the ceiling; 0.15 is the owner's")
        XCTAssertEqual(backlight.value, 0.15)
    }

    func testAnotherFeatureHoldingTheScreenDownKeepsItDown() {
        own.remember(0.9, for: "lid")   // the lid dimmer got there first and holds the owner's brightness
        start()
        XCTAssertEqual(backlight.value, 0.25)
        controller.turnOff()
        XCTAssertEqual(backlight.sets, [0.25], "the value is the lid's to put back, when it lets go")
        XCTAssertEqual(own.forget("lid"), 0.9)
    }

    func testTurnOffWhenNothingIsOnDoesNothing() {
        controller.turnOff()
        XCTAssertEqual(calls.list, [])
        XCTAssertEqual(controller.state, .off)
    }

    func testTurnOffWhileTheBoxIsOpenCancelsTheAskAndALateAnswerStartsNothing() {
        controller.request()
        controller.turnOff()
        XCTAssertEqual(controller.state, .off)
        confirm.press(true)
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(freezer.stops, [])
        XCTAssertNil(store.record)
    }

    func testTurnOffIsIgnoredWhileItIsBeingDoneAndThenStartingIsToo() {
        start()
        holdWork = true
        controller.turnOff()
        XCTAssertEqual(controller.state, .on, "the screen and the rest are still being put back")
        XCTAssertEqual(freezer.resumes, [20, 21, 30], "but every process is running again already")
        XCTAssertEqual(controller.frozen, [])
        XCTAssertFalse(controller.isFrozen(pid: 20))
        controller.turnOff()
        controller.request()
        XCTAssertEqual(confirm.keptNames.count, 1, "no new ask while the mode is being put back")
        runHeldWork()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(freezer.resumes, [20, 21, 30], "once")
        XCTAssertEqual(watchdog.stopped, 1)
        XCTAssertEqual(backlight.value, 0.8)
        XCTAssertNil(store.record)
    }

    func testQuittingWhileTheModeIsBeingTurnedOffPutsTheScreenBackWhenTheQueueGetsRoundToIt() {
        start()
        holdWork = true
        controller.turnOff()
        XCTAssertEqual(backlight.value, 0.25, "queued, not done")
        controller.shutdown()
        // The quit's own settings are queued behind the turn-off's, so its wait runs out: every process runs again, and the record
        // and the watchdog are left for what finishes the job.
        XCTAssertEqual(freezer.resumes, [20, 21, 30, 20, 21, 30], "continued again by the quit: a continue of a running process is harmless")
        XCTAssertEqual(backlight.value, 0.25)
        XCTAssertNotNil(store.record)
        XCTAssertEqual(watchdog.stopped, 0)
        XCTAssertFalse(backdrop.shown)
        // The queue gets round to the turn-off's job first: its session was ended by the quit, so it does nothing. The quit's own
        // job puts everything back, once, and finishes the end.
        runHeldWork()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(backlight.value, 0.8, "the owner's brightness was taken only once")
        XCTAssertEqual(backlight.sets, [0.25, 0.8])
        XCTAssertEqual(power.restored, [0])
        XCTAssertEqual(watchdog.stopped, 1)
        XCTAssertNil(store.record)
        XCTAssertEqual(keyboard.sets, [0, 0.6], "the keyboard light is not written twice")
        XCTAssertEqual(rate.restored, 1, "nor the refresh rate")
    }

    /// Quit while a job that LOWERS something is on the queue, not started: when the queue gets round to it, it does
    /// nothing, because the session it belongs to is over. (A job already inside a system call when the quit comes is
    /// not stopped by this; the restore behind it on the queue and Task 11's ordering are what cover that.)
    private func quitWhileTheNthCallIsOnTheQueue(_ n: Int, file: StaticString = #filePath, line: UInt = #line) {
        workLimit = n - 1
        start()
        XCTAssertEqual(heldWork.count, 1, file: file, line: line)
        controller.shutdown()
        // The quit's settings are behind the jammed job on the queue, so its wait runs out and the record is left for the watchdog.
        XCTAssertEqual(heldWork.count, 2, file: file, line: line)
        XCTAssertNotNil(store.record, file: file, line: line)
        runHeldWork()
        XCTAssertEqual(controller.state, .off, file: file, line: line)
        XCTAssertNil(store.record, file: file, line: line)
    }

    func testAHeldBrightnessCheckThatComesAfterQuittingLowersNothing() {
        start()
        backlight.value = 0.9
        holdWork = true
        controller.brightnessMayHaveChanged()
        XCTAssertEqual(heldWork.count, 1)
        controller.shutdown()
        runHeldWork()
        XCTAssertEqual(backlight.sets, [0.25], "the check was for a mode that is over: the screen is not held down after the quit")
        XCTAssertEqual(backlight.value, 0.9)
    }

    func testQuittingWhileTheScreenIsBeingLoweredLowersNothingLater() {
        quitWhileTheNthCallIsOnTheQueue(2)
        XCTAssertEqual(backlight.sets, [])
        XCTAssertEqual(backlight.value, 0.8)
    }

    func testQuittingWhileTheRefreshRateIsBeingLoweredLowersNothingLater() {
        quitWhileTheNthCallIsOnTheQueue(3)
        XCTAssertEqual(rate.lowered, 0)
    }

    func testQuittingWhileTheKeyboardLightIsBeingSwitchedOffSwitchesNothingLater() {
        quitWhileTheNthCallIsOnTheQueue(5)
        XCTAssertEqual(keyboard.sets, [0.6], "the earlier level, once, by the quit; the held 0 never happens")
    }

    func testNothingStartsWhileALeftoverRecordIsBeingUndone() {
        var record = UltraRecord()
        record.groups = [UltraRecord.Group(id: "com.example.browser", name: "Browser", members: [.init(pid: 20, startTime: 200)])]
        store.record = record
        holdWork = true
        controller.recoverAtLaunch()
        XCTAssertEqual(freezer.resumes, [20], "processes do not wait for the queue")
        controller.request()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(confirm.keptNames.count, 0)
        XCTAssertNotNil(store.record, "the record stays until the rest is put back")
        runHeldWork()
        XCTAssertNil(store.record)
        controller.request()
        XCTAssertEqual(controller.state, .confirming)
    }

    func testBrightnessIsCheckedOneAtATime() {
        start()
        holdWork = true
        controller.brightnessMayHaveChanged()
        controller.brightnessMayHaveChanged()
        controller.brightnessMayHaveChanged()
        XCTAssertEqual(heldWork.count, 1, "a display that is slow to answer is not asked again and again")
        backlight.value = 0.9
        runHeldWork()
        XCTAssertEqual(backlight.sets, [0.25, 0.25], "the one check pulled it back")
        // And when that one is done, the next is taken.
        backlight.value = 0.9
        controller.brightnessMayHaveChanged()
        XCTAssertEqual(backlight.sets, [0.25, 0.25, 0.25])
    }

    // ── Hide that takes its time; power that takes its time ─────────────────

    /// The app is still being hidden, so groups are already on the record and none is stopped yet.
    private func startAndStopWhileAnAppIsBeingHidden(_ end: () -> Void) {
        hider.hold = true
        start()
        XCTAssertEqual(freezer.stops, [], "waiting for the app to hide")
        XCTAssertEqual(controller.state, .confirming)
        end()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(freezer.resumes, [20, 21, 30], "everything the record names is continued")
        XCTAssertEqual(hider.unhidden, [20])
        XCTAssertNil(store.record)
        XCTAssertEqual(watchdog.stopped, 1)
        // The app answers late: the mode is over, so that starts nothing.
        hider.held.forEach { $0() }
        XCTAssertEqual(freezer.stops, [])
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(controller.frozen, [])
        XCTAssertEqual(backlight.sets, [])
        XCTAssertEqual(power.entered, 0)
    }

    func testACompletionThatArrivesAfterTurningOffDoesNothing() {
        startAndStopWhileAnAppIsBeingHidden { controller.turnOff() }
    }

    func testACompletionThatArrivesAfterQuittingDoesNothing() {
        startAndStopWhileAnAppIsBeingHidden { controller.shutdown() }
    }

    /// The mode is turned off while one call of the start is still on the work queue: a call that has already been handed
    /// over cannot be taken back, so what it does has to be put back after it. (The calls, in order: the brightness read
    /// 1, set 2; the refresh rate 3; the keyboard light read 4, set 5.)
    private func turnOffWhileTheNthCallIsOnTheQueue(_ n: Int, file: StaticString = #filePath, line: UInt = #line) {
        workLimit = n - 1
        start()
        XCTAssertEqual(controller.state, .confirming, "waiting on the queue", file: file, line: line)
        XCTAssertEqual(heldWork.count, 1, file: file, line: line)
        controller.turnOff()
        XCTAssertEqual(freezer.resumes, [20, 21, 30], file: file, line: line)
        runHeldWork()
        XCTAssertEqual(controller.state, .off, file: file, line: line)
        XCTAssertNil(store.record, file: file, line: line)
        XCTAssertEqual(watchdog.stopped, 1, file: file, line: line)
    }

    func testTurnOffWhileTheScreenIsBeingLoweredLeavesItWhereItWas() {
        turnOffWhileTheNthCallIsOnTheQueue(2)
        XCTAssertEqual(backlight.sets, [], "the job had not started when the mode ended, so it lowered nothing")
        XCTAssertEqual(backlight.value, 0.8)
    }

    func testTurnOffWhileTheRefreshRateIsBeingLoweredLeavesItWhereItWas() {
        turnOffWhileTheNthCallIsOnTheQueue(3)
        XCTAssertEqual(rate.lowered, 0)
        XCTAssertEqual(rate.restored, 1, "put back all the same: the record named it, and a restore of nothing is nothing")
    }

    func testTurnOffWhileTheKeyboardLightIsBeingSwitchedOffLeavesItWhereItWas() {
        turnOffWhileTheNthCallIsOnTheQueue(5)
        XCTAssertEqual(keyboard.sets, [0.6], "never switched off; the earlier level is written back, which changes nothing")
    }

    func testTurnOffBeforeAnythingWasHandedToTheQueueChangesNoSetting() {
        turnOffWhileTheNthCallIsOnTheQueue(1)   // the brightness is still being read
        XCTAssertEqual(backlight.sets, [])
        XCTAssertEqual(rate.lowered, 0)
        XCTAssertEqual(keyboard.sets, [])
    }

    // ── Answers that come late ──────────────────────────────────────────────

    func testConfirmThenTurnOffBeforeTheLoadReturnsStartsNothing() {
        controller.request()
        load.holdNext = 1
        confirm.press(true)
        XCTAssertEqual(load.held.count, 1, "waiting for the reading")
        controller.turnOff()
        load.answerHeld()
        XCTAssertEqual(store.saves.count, 0)
        XCTAssertEqual(watchdog.started, 0)
        XCTAssertEqual(hider.hidden, [])
        XCTAssertEqual(freezer.stops, [])
        XCTAssertEqual(controller.state, .off)
    }

    func testConfirmThenQuitBeforeTheLoadReturnsStartsNothing() {
        controller.request()
        load.holdNext = 1
        confirm.press(true)
        controller.shutdown()
        load.answerHeld()
        XCTAssertEqual(store.saves.count, 0)
        XCTAssertEqual(watchdog.started, 0)
        XCTAssertEqual(hider.hidden, [])
        XCTAssertEqual(controller.state, .off)
    }

    func testTurnOffBeforeTheProcessListReturnsAsksNothing() {
        processes.hold = true
        controller.request()
        controller.turnOff()
        processes.answerHeld()
        XCTAssertEqual(confirm.keptNames.count, 0)
        XCTAssertEqual(controller.state, .off)
    }

    func testASweepPendingAcrossTurnOffAndANewStartStopsNothing() {
        start()
        processes.list = world + [helper(22, of: 20, in: "Browser")]
        processes.hold = true
        fire(30)
        XCTAssertEqual(processes.held.count, 1, "waiting for the list")
        controller.turnOff()
        processes.hold = false
        processes.list = world
        start()   // the new session has frozen groups the old sweep could stop things in; its own sweep has not run
        let stops = freezer.stops, reads = load.reads
        processes.list = world + [helper(22, of: 20, in: "Browser")]
        processes.answerHeld()
        XCTAssertEqual(freezer.stops, stops, "the old sweep stops nothing")
        XCTAssertEqual(load.reads, reads, "and does not go on to read the load")
        XCTAssertFalse(controller.isFrozen(pid: 22))
    }

    func testASweepWhoseReadingIsPendingAcrossTurnOffAndANewStartStopsNothing() {
        start()
        processes.list = world + [helper(22, of: 20, in: "Browser")]
        load.holdNext = 1
        fire(30)
        XCTAssertEqual(load.held.count, 1, "waiting for the reading, with 22 as the new part")
        controller.turnOff()
        processes.list = world
        start()
        let stops = freezer.stops
        load.answerHeld()
        XCTAssertEqual(freezer.stops, stops, "the old sweep stops nothing in the new session")
        XCTAssertFalse(controller.isFrozen(pid: 22))
        XCTAssertEqual(controller.state, .on)
    }

    func testASweepPendingAcrossTurnOffAloneStopsNothing() {
        start()
        processes.list = world + [helper(22, of: 20, in: "Browser")]
        processes.hold = true
        fire(30)
        controller.turnOff()
        processes.answerHeld()
        XCTAssertFalse(freezer.stops.contains(22))
        XCTAssertEqual(controller.state, .off)
    }

    func testAGroupReleasedBetweenASweepsListAndItsReadingIsNotStopped() {
        start()
        processes.list = world + [helper(22, of: 20, in: "Browser")]
        load.holdNext = 1
        fire(30)
        controller.release(groupID: "com.example.browser")   // the owner took it back while the load was being read
        load.answerHeld()
        XCTAssertFalse(freezer.stops.contains(22), "a released group is never stopped again")
        XCTAssertFalse(controller.isFrozen(pid: 22))
        XCTAssertEqual(store.record?.groups.first?.members.map(\.pid), [20, 21], "nor named")
    }

    func testAGuardReadingPendingAcrossTurnOffAndANewStartLeavesTheNewSessionAlone() {
        start()
        load.holdNext = 1
        fire(5)
        XCTAssertEqual(load.held.count, 1, "the first session's check is waiting for its reading")
        controller.turnOff()
        start()
        let resumes = freezer.resumes
        // The old check's reading comes in: a core and a half on the sync agent's extension, which would release it.
        load.queue = [sample(2.6, [10: 0.2, 31: 1.4])]
        let snapshots = processes.snapshots
        load.answerHeld()
        XCTAssertEqual(processes.snapshots, snapshots, "the old check does not go on to ask for the list")
        XCTAssertEqual(controller.releasedForLoad, [])
        XCTAssertEqual(freezer.resumes, resumes, "the new session's groups are untouched")
        XCTAssertEqual(controller.frozen.count, 2)
    }

    func testAGuardListPendingAcrossTurnOffAndANewStartLeavesTheNewSessionAlone() {
        load.queue = [nil, sample(1.0), sample(2.6, [10: 0.2, 31: 1.4])]
        start()
        processes.hold = true
        fire(5)
        XCTAssertEqual(processes.held.count, 1, "the first session's check has its reading and waits for the list")
        controller.turnOff()
        processes.hold = false
        start()
        let resumes = freezer.resumes
        processes.answerHeld()
        XCTAssertEqual(controller.releasedForLoad, [])
        XCTAssertEqual(freezer.resumes, resumes, "the new session's groups are untouched")
        XCTAssertEqual(controller.frozen.count, 2)
    }

    func testALowPowerModeEnteredAfterTheModeEndedIsPutBack() {
        power.hold = true
        start()
        XCTAssertEqual(controller.state, .confirming, "waiting for the helper")
        controller.turnOff()
        XCTAssertEqual(power.restored, [])
        power.held.forEach { $0(0) }   // the helper switched it on and now says what it was
        XCTAssertEqual(power.restored, [0], "otherwise Low Power Mode would stay on with nothing to end it")
        XCTAssertEqual(controller.state, .off)
    }

    // ── Getting one group back ──────────────────────────────────────────────

    func testReleaseOneGroupLeavesTheRestFrozen() {
        start()
        controller.release(groupID: "com.example.browser")
        XCTAssertEqual(freezer.resumes, [20, 21])
        XCTAssertEqual(hider.unhidden, [20])
        XCTAssertEqual(groupIDs(controller.frozen), ["com.example.sync"])
        XCTAssertFalse(controller.isFrozen(pid: 20))
        XCTAssertTrue(controller.isFrozen(pid: 30))
        XCTAssertEqual(controller.releasedForLoad, [], "the owner's choice is not the guard's")
        XCTAssertEqual(store.record?.groups.map(\.released), [true, false])
        // At the end only what is still frozen is continued: the released group was continued already.
        controller.turnOff()
        XCTAssertEqual(freezer.resumes, [20, 21, 30])
        XCTAssertEqual(hider.unhidden, [20])
    }

    func testAReleaseWhoseContinueFailedStillMarksTheGroupReleasedAndSaysSo() {
        start()
        freezer.refuseResume = [21]
        controller.release(groupID: "com.example.browser")
        XCTAssertEqual(freezer.resumes, [20, 21])
        XCTAssertEqual(groupIDs(controller.frozen), ["com.example.sync"], "gone, or not that process any more: nothing to keep stopped")
        XCTAssertEqual(store.record?.groups.map(\.released), [true, false])
        XCTAssertEqual(logged.filter { $0.contains("Browser") && $0.contains("21") && $0.contains("released") }.count, 1, "\(logged)")
        XCTAssertEqual(hider.unhidden, [20])
    }

    func testReleasingAGroupThatIsNotFrozenDoesNothing() {
        start()
        controller.release(groupID: "com.example.editor")
        controller.release(groupID: "nothing.like.it")
        XCTAssertEqual(freezer.resumes, [])
        XCTAssertEqual(controller.frozen.count, 2)
    }

    func testAReleaseGoesAheadWhenTheRecordCannotBeSaved() {
        start()
        store.refuseSave = { _ in true }
        controller.release(groupID: "com.example.sync")
        XCTAssertEqual(freezer.resumes, [30], "continue first; the record can only be out of date in the safe direction")
        XCTAssertFalse(controller.isFrozen(pid: 30))
        XCTAssertTrue(logged.contains { $0.contains("record") }, "\(logged)")
    }

    func testActivatingAFrozenAppReleasesIt() {
        start()
        controller.appActivated(pid: 10)   // the editor: not frozen, nothing to do
        XCTAssertEqual(freezer.resumes, [])
        controller.appActivated(pid: 21)   // a part of the browser
        XCTAssertEqual(freezer.resumes, [20, 21])
        XCTAssertEqual(groupIDs(controller.frozen), ["com.example.sync"])
        XCTAssertEqual(controller.releasedForLoad, [])
    }

    func testActivatingTheHiddenAppReleasesItsGroupEvenWhenItsOwnStopFailed() {
        freezer.refuse = [20]   // the window process refused; its helper was stopped
        start()
        XCTAssertEqual(controller.frozen.first?.members.map(\.pid), [21])
        controller.appActivated(pid: 20)
        XCTAssertEqual(freezer.resumes, [21])
        XCTAssertEqual(hider.unhidden, [20])
        XCTAssertEqual(groupIDs(controller.frozen), ["com.example.sync"])
    }

    // ── What starts later ───────────────────────────────────────────────────

    private func helper(_ pid: pid_t, of parent: pid_t, in bundle: String) -> UltraProcess {
        proc(pid, parent: parent, path: "/Applications/\(bundle).app/Contents/Frameworks/\(bundle) Helper.app/Contents/MacOS/\(bundle) Helper")
    }

    func testSweepFreezesANewHelperOfAFrozenGroup() {
        start()
        processes.list = world + [helper(22, of: 20, in: "Browser"),                                   // a new part of the browser
                                  proc(12, parent: 10, path: "/bin/zsh"),                              // a new tool of the editor
                                  proc(60, path: "/Applications/Other.app/Contents/MacOS/Other", app: .regular,
                                       bundle: "com.example.other", name: "Other")]                    // an app opened since
        let readsBefore = load.reads
        fire(30)
        XCTAssertEqual(freezer.stops, [20, 21, 30, 22], "only the new part of a frozen group")
        XCTAssertEqual(controller.frozen.first?.members.map(\.pid), [20, 21, 22])
        XCTAssertTrue(controller.isFrozen(pid: 22))
        XCTAssertEqual(store.record?.groups.first?.members.map(\.pid), [20, 21, 22])
        XCTAssertEqual(hider.hidden, [20], "no hiding for a part that joins a frozen group")
        XCTAssertEqual(load.reads, readsBefore + 1, "the 'before' reading of this step")
        // It is looked at again in 30 s, and the step is guarded like the first.
        XCTAssertTrue(scheduled.contains { $0.delay == 30 })
        XCTAssertTrue(scheduled.contains { $0.delay == 5 })
        // What was stopped is not stopped again.
        fire(30)
        XCTAssertEqual(freezer.stops, [20, 21, 30, 22])
    }

    func testASweepThatFindsNothingNewFreezesAndReadsNothing() {
        start()
        let readsBefore = load.reads
        fire(30)
        XCTAssertEqual(freezer.stops, [20, 21, 30])
        XCTAssertEqual(load.reads, readsBefore)
        XCTAssertTrue(scheduled.contains { $0.delay == 30 }, "and goes on looking")
    }

    func testARefusedStopIsNotRetriedByEverySweep() {
        start()
        freezer.refuse = [22]
        processes.list = world + [helper(22, of: 20, in: "Browser")]
        fire(30)
        fire(30)
        XCTAssertEqual(freezer.stops.filter { $0 == 22 }.count, 1)
        XCTAssertEqual(controller.frozen.first?.members.map(\.pid), [20, 21], "not listed as frozen")
        XCTAssertEqual(store.record?.groups.first?.members.map(\.pid), [20, 21], "nor on the record")
    }

    func testASweepThatCannotRecordWhatItWouldStopStopsNothing() {
        start()
        store.refuseSave = { $0.groups.flatMap(\.members).count > 3 }
        processes.list = world + [helper(22, of: 20, in: "Browser")]
        fire(30)
        XCTAssertEqual(freezer.stops, [20, 21, 30])
        XCTAssertFalse(controller.isFrozen(pid: 22))
        XCTAssertTrue(logged.contains { $0.contains("record") }, "\(logged)")
        controller.turnOff()
        XCTAssertEqual(freezer.resumes, [20, 21, 30], "never stopped, so never continued")
    }

    func testAFailedSnapshotInASweepChangesNothing() {
        start()
        processes.list = nil
        fire(30)
        XCTAssertEqual(freezer.stops, [20, 21, 30])
        XCTAssertEqual(controller.state, .on)
        XCTAssertTrue(scheduled.contains { $0.delay == 30 }, "and tries again")
    }

    func testAReleasedGroupIsNotRefrozenByTheSweep() {
        start()
        controller.release(groupID: "com.example.browser")
        processes.list = world + [helper(22, of: 20, in: "Browser")]
        fire(30)
        XCTAssertEqual(freezer.stops, [20, 21, 30])
        XCTAssertFalse(controller.isFrozen(pid: 22))
    }

    func testSweepRunsOnlyWhileOn() {
        XCTAssertTrue(scheduled.isEmpty)
        controller.request()
        XCTAssertTrue(scheduled.isEmpty, "nothing is scheduled while asking")
        confirm.press(true)
        XCTAssertTrue(scheduled.contains { $0.delay == UltraLowPowerController.sweepSeconds })
        XCTAssertEqual(UltraLowPowerController.sweepSeconds, 30)
        controller.turnOff()
        // What was left pending does nothing, and does not schedule anything.
        let snapshots = processes.snapshots, reads = load.reads, stops = freezer.stops
        fireEverythingPending()
        XCTAssertEqual(processes.snapshots, snapshots)
        XCTAssertEqual(load.reads, reads)
        XCTAssertEqual(freezer.stops, stops)
        XCTAssertTrue(scheduled.isEmpty, "nothing is scheduled in .off")
        // A direct call is no better.
        controller.sweep()
        XCTAssertEqual(processes.snapshots, snapshots)
    }

    func testPendingWorkOfAnEndedSessionDoesNotTouchTheNextOne() {
        start()
        controller.turnOff()
        start()
        XCTAssertEqual(controller.state, .on)
        // Both sessions' sweeps and checks are pending now; only the second session's may do anything.
        let reads = load.reads, snapshots = processes.snapshots
        fireEverythingPending()
        XCTAssertEqual(load.reads, reads + 2, "the second session's two checks, not the first's")
        XCTAssertEqual(processes.snapshots, snapshots + 3, "its two checks and its sweep")
        XCTAssertEqual(controller.state, .on)
        XCTAssertEqual(scheduled.filter { $0.delay == 30 }.count, 1, "one sweep chain, not two")
    }

    // ── The screen is held down ─────────────────────────────────────────────

    func testBrightnessRaisedDuringTheSessionIsPulledBack() {
        start()
        backlight.value = 0.9   // the keys, or auto-brightness
        controller.brightnessMayHaveChanged()
        XCTAssertEqual(backlight.sets, [0.25, 0.25])
        XCTAssertEqual(backlight.value, 0.25)
        // Going dimmer is always allowed, and a reading within the panel's rounding is not a rise.
        backlight.value = 0.15
        controller.brightnessMayHaveChanged()
        backlight.value = 0.255
        controller.brightnessMayHaveChanged()
        XCTAssertEqual(backlight.sets, [0.25, 0.25])
        // At the end the earlier brightness comes back: the screen is where the mode held it.
        backlight.value = 0.25
        controller.turnOff()
        XCTAssertEqual(backlight.value, 0.8)
    }

    func testTheCeilingIsNotHeldOutsideTheMode() {
        backlight.value = 0.9
        controller.brightnessMayHaveChanged()
        XCTAssertEqual(backlight.sets, [])
        start()
        controller.turnOff()
        backlight.value = 0.9
        controller.brightnessMayHaveChanged()
        XCTAssertEqual(backlight.sets, [0.25, 0.9], "lowered, then put back; the later 0.9 was not held")
    }

    // ── Quitting, and a session nobody ended ────────────────────────────────

    func testShutdownEndsTheSession() {
        start()
        let workBefore = workRuns
        calls.list.removeAll()
        controller.shutdown()

        XCTAssertEqual(freezer.resumes, [20, 21, 30])
        XCTAssertEqual(hider.unhidden, [20])
        XCTAssertEqual(backlight.value, 0.8)
        XCTAssertEqual(rate.restored, 1)
        XCTAssertEqual(keyboard.sets, [0, 0.6])
        XCTAssertEqual(power.restored, [0])
        XCTAssertNil(store.record)
        XCTAssertEqual(watchdog.stopped, 1)
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(workRuns, workBefore + 1, "the quit gives the queue one job, the settings: the continues and the lifts are here")
        assertAllBefore("resume", "unhide")
        assertAllBefore("unhide", "brightness")
        assertAllBefore("brightness", "power restore")
        assertAllBefore("power restore", "watchdog stop")

        // Nothing left to end: again changes nothing.
        let seen = calls.list
        controller.shutdown()
        XCTAssertEqual(calls.list, seen)
    }

    func testShutdownWhileAskingCancelsTheAsk() {
        controller.request()
        controller.shutdown()
        XCTAssertEqual(controller.state, .off)
        confirm.press(true)
        XCTAssertEqual(freezer.stops, [])
    }

    func testRecoverAtLaunchUndoesALeftoverRecordAndStaysOff() {
        var record = UltraRecord()
        record.groups = [UltraRecord.Group(id: "com.example.browser", name: "Browser",
                                           members: [.init(pid: 20, startTime: 200), .init(pid: 21, startTime: 210)], appPID: 20),
                         UltraRecord.Group(id: "com.example.sync", name: "Sync", members: [.init(pid: 30, startTime: 300)],
                                           released: true)]
        record.brightnessBefore = 0.8
        record.rateLowered = true
        record.keyboardBefore = 0.6
        record.powerModeBefore = 1
        store.record = record
        backlight.value = 0.25

        controller.recoverAtLaunch()

        XCTAssertEqual(freezer.resumes, [20, 21], "only what the record names, and not what was released already")
        XCTAssertEqual(hider.unhidden, [20])
        XCTAssertEqual(backlight.value, 0.8, "from the record: a new process has noted nothing")
        XCTAssertEqual(rate.restored, 1)
        XCTAssertEqual(keyboard.sets, [0.6])
        XCTAssertEqual(power.restored, [1])
        XCTAssertNil(store.record)
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(freezer.stops, [])
        XCTAssertTrue(scheduled.isEmpty)
        assertAllBefore("resume", "unhide")
        assertAllBefore("unhide", "brightness")
    }

    func testRecoverAtLaunchWithNoRecordDoesNothing() {
        controller.recoverAtLaunch()
        XCTAssertEqual(calls.list, [])
        XCTAssertEqual(controller.state, .off)
    }

    // ── What is listed as frozen ────────────────────────────────────────────

    func testAGroupWhoseStopFailedIsNotListedAsFrozen() {
        freezer.refuse = [30]
        start()
        XCTAssertEqual(groupIDs(controller.frozen), ["com.example.browser"])
        XCTAssertFalse(controller.isFrozen(pid: 30))
        XCTAssertEqual(store.record?.groups.map(\.id), ["com.example.browser"], "nor on the record: nothing of it was stopped")
        controller.turnOff()
        XCTAssertEqual(freezer.resumes, [20, 21], "only what was stopped is continued")
    }

    func testAMemberWhoseStopFailedIsNotListedAsFrozen() {
        freezer.refuse = [21]
        start()
        XCTAssertEqual(controller.frozen.first?.members.map(\.pid), [20])
        XCTAssertEqual(store.record?.groups.first?.members.map(\.pid), [20])
        controller.turnOff()
        XCTAssertEqual(freezer.resumes, [20, 30])
    }

    func testGroupsThatCannotBeFrozenWholeAreLeftRunningAndListed() {
        processes.list = world + cloud
        start()
        XCTAssertEqual(controller.leftRunning.map(\.id), ["com.example.cloud"])
        XCTAssertFalse(freezer.stops.contains(40), "stopping the user's part would make the root part spin")
        XCTAssertEqual(confirm.frozenNames, [["Browser", "Sync"]])
        controller.turnOff()
        XCTAssertEqual(controller.leftRunning, [])
    }

    // ── The efficiency cores ────────────────────────────────────────────────

    /// What the record names as put under the policy, by pid.
    private var namedThrottled: [pid_t]? { store.record?.throttled?.map(\.pid) }

    /// The world with the editor's own process (10) on a call.
    private var worldOnACall: [UltraProcess] {
        var list = world
        let editor = list.firstIndex { $0.pid == 10 }!
        list[editor].usesMicOrCamera = true
        return list
    }

    func testTheAppsThatKeepRunningAreKeptOnTheEfficiencyCores() {
        start()
        // The editor and its shell: the kept app. Not the frozen ones (20, 21, 30), not the extension macOS hosts (31), not the
        // system's (50), and not Anode (1000).
        XCTAssertEqual(throttler.throttled, [10, 11])
        XCTAssertEqual(store.record?.throttled, [.init(pid: 10, startTime: 100), .init(pid: 11, startTime: 110)])
        XCTAssertEqual(throttler.startTimes, [10: 100, 11: 110], "by the start time the snapshot saw")
        XCTAssertEqual(controller.skipped, [])
    }

    func testAnAppLeftRunningBecauseItHasAPartAnodeCannotFreezeIsKeptOnTheEfficiencyCoresToo() {
        processes.list = world + cloud
        start()
        XCTAssertEqual(throttler.throttled, [10, 11, 40], "40 is the cloud app's part Anode can signal; 41 is root's")
    }

    /// A crash between the policy and its record would leave a process slowed with nothing to speed it up again.
    func testAProcessIsNamedOnTheRecordBeforeItIsThrottled() {
        var named: [pid_t: Bool] = [:]
        throttler.onThrottle = { [unowned self] pid in named[pid] = self.namedThrottled?.contains(pid) ?? false }
        start()
        XCTAssertEqual(named, [10: true, 11: true])
    }

    func testTheEfficiencyCoresComeAfterTheFreezeAndBeforeTheScreen() {
        start()
        assertAllBefore("stop", "throttle")
        assertAllBefore("throttle", "brightness")
        assertAllBefore("throttle", "rate lower")
        assertAllBefore("throttle", "power enter")
    }

    func testARecordThatCannotNameThemThrottlesNothing() {
        store.refuseSave = { $0.throttled != nil }
        start()
        XCTAssertEqual(controller.state, .on, "the rest of the mode is done")
        XCTAssertEqual(throttler.throttled, [])
        XCTAssertNil(store.record?.throttled)
        XCTAssertTrue(logged.contains { $0.contains("record") }, "\(logged)")
        XCTAssertEqual(freezer.stops, [20, 21, 30])
        XCTAssertEqual(rate.lowered, 1, "the screen's parts still follow")
        controller.turnOff()
        XCTAssertEqual(throttler.lifted, [10, 11],
                       "never put under it, so the record does not name it; the end lifts every member of the kept group all the same, which changes nothing")
    }

    func testAProcessTheSystemRefusedIsTakenOffTheRecordAndReachedAtTheEndOnlyAsAChild() {
        throttler.refuse = [11]
        start()
        XCTAssertEqual(throttler.throttled, [10, 11], "both were asked")
        XCTAssertEqual(namedThrottled, [10], "the record names only what was done")
        controller.turnOff()
        // 11 is a child of 10, which was put under the policy, so the end's walk down the children asks about it too: a process
        // that follows its parent's policy has to be lifted with it. (It never had the policy from this mode: nothing changes.)
        XCTAssertEqual(throttler.lifted, [10, 11])
    }

    func testWithTheSettingOffNothingIsThrottledAndNothingIsSaid() {
        settings.ultraLowPowerEfficiencyCores = false
        start()
        XCTAssertEqual(throttler.throttled, [])
        XCTAssertNil(store.record?.throttled)
        XCTAssertEqual(controller.skipped, [], "the owner asked for nothing, so nothing was skipped")
        // The sweep and a release follow the choice made at the start.
        processes.list = world + [proc(12, parent: 10, path: "/bin/zsh")]
        fire(30)
        controller.release(groupID: "com.example.sync")
        XCTAssertEqual(throttler.throttled, [])
        controller.turnOff()
        XCTAssertEqual(throttler.lifted, [])
    }

    func testAMacWithoutEfficiencyCoresSaysSoAndThrottlesNothing() {
        hasEfficiencyCores = false
        controller = makeController()
        start()
        XCTAssertEqual(controller.skipped, [.noEfficiencyCores])
        XCTAssertEqual(throttler.throttled, [])
        XCTAssertNil(store.record?.throttled)
        XCTAssertEqual(controller.state, .on, "everything else is done")
        XCTAssertEqual(freezer.stops, [20, 21, 30])
        processes.list = world + [proc(12, parent: 10, path: "/bin/zsh")]
        fire(30)
        controller.release(groupID: "com.example.sync")
        XCTAssertEqual(throttler.throttled, [])
        controller.turnOff()
        XCTAssertEqual(controller.skipped, [], "a session's lines go with it")
    }

    func testAMacWithoutEfficiencyCoresIsNotToldSoWhenTheSettingIsOff() {
        hasEfficiencyCores = false
        controller = makeController()
        settings.ultraLowPowerEfficiencyCores = false
        start()
        XCTAssertEqual(controller.skipped, [])
    }

    /// The part is said first: it is done first, before the screen's own parts.
    func testTheMissingCoresAreSaidBeforeTheScreensParts() {
        hasEfficiencyCores = false
        controller = makeController()
        rate.canLower = false
        start()
        XCTAssertEqual(controller.skipped, [.noEfficiencyCores, .oneRefreshRate])
    }

    func testTheChoiceIsMadeAtConfirmAndNotChangedByTheSettingAfterwards() {
        start()
        settings.ultraLowPowerEfficiencyCores = false
        processes.list = world + [proc(12, parent: 10, path: "/bin/zsh")]
        fire(30)
        XCTAssertEqual(throttler.throttled, [10, 11, 12], "the session was started with it on")
        controller.turnOff()
        XCTAssertEqual(throttler.lifted, [10, 11, 12], "and what the record names is lifted whatever the setting says now")
    }

    // An app the owner brings back

    func testAnAppBroughtBackIsThrottledAfterItIsContinuedAndNamedFirst() throws {
        start()
        var named = false
        throttler.onThrottle = { [unowned self] pid in if pid == 20 { named = self.namedThrottled?.contains(20) ?? false } }
        controller.release(groupID: "com.example.browser")
        XCTAssertEqual(throttler.throttled, [10, 11, 20, 21])
        XCTAssertTrue(named)
        XCTAssertEqual(namedThrottled, [10, 11, 20, 21])
        XCTAssertLessThan(try XCTUnwrap(lastIndex("resume 21")), try XCTUnwrap(firstIndex("throttle 20")), "it runs first")
        // It is lifted at the end like the rest, though its group was released and is not continued again.
        controller.turnOff()
        XCTAssertEqual(freezer.resumes, [20, 21, 30])
        XCTAssertEqual(throttler.lifted, [10, 11, 20, 21])
    }

    func testAnAppActivatedFromTheDockIsThrottledToo() {
        start()
        controller.appActivated(pid: 21)
        XCTAssertEqual(throttler.throttled, [10, 11, 20, 21])
    }

    /// Only a process that was continued is put under the policy: one that is gone, or not that process any more, is not.
    func testAMemberThatCouldNotBeContinuedIsNotThrottled() {
        start()
        freezer.refuseResume = [21]
        controller.release(groupID: "com.example.browser")
        XCTAssertEqual(throttler.throttled, [10, 11, 20])
    }

    func testAGroupTheGuardReleasedIsKeptOnTheEfficiencyCoresToo() {
        load.queue = [nil, sample(1.0, [10: 0.2]), sample(2.6, [10: 0.2, 31: 1.4])]
        start()
        fire(5)
        XCTAssertEqual(controller.releasedForLoad, ["com.example.sync"])
        XCTAssertEqual(throttler.throttled, [10, 11, 30], "what started to burn after its peers were stopped is the one to slow")
    }

    func testAReleaseWhoseRecordCannotNameTheProcessesStillContinuesThemAndThrottlesNothing() {
        start()
        store.refuseSave = { ($0.throttled?.count ?? 0) > 2 }
        controller.release(groupID: "com.example.browser")
        XCTAssertEqual(freezer.resumes, [20, 21], "continued first: the record can only be out of date in the safe direction")
        XCTAssertEqual(throttler.throttled, [10, 11])
        XCTAssertTrue(logged.contains { $0.contains("record") }, "\(logged)")
        controller.turnOff()
        XCTAssertEqual(throttler.lifted, [10, 11, 20, 21], "what the record names, then the members of the group that came back, which it could not name")
    }

    // What starts later

    func testTheSweepKeepsANewPartOfTheKeptAppOnTheEfficiencyCoresWithoutReadingTheLoad() {
        start()
        processes.list = world + [proc(12, parent: 10, path: "/bin/zsh")]          // a new tool of the editor
        let reads = load.reads, stops = freezer.stops
        fire(30)
        XCTAssertEqual(throttler.throttled, [10, 11, 12])
        XCTAssertEqual(namedThrottled, [10, 11, 12])
        XCTAssertEqual(throttler.startTimes[12], 120)
        XCTAssertEqual(load.reads, reads, "nothing was stopped, so nothing is guarded")
        XCTAssertEqual(freezer.stops, stops)
        fire(30)
        XCTAssertEqual(throttler.throttled, [10, 11, 12], "once")
    }

    func testTheSweepNamesANewPartBeforeItIsThrottled() {
        start()
        var named = false
        throttler.onThrottle = { [unowned self] pid in if pid == 12 { named = self.namedThrottled?.contains(12) ?? false } }
        processes.list = world + [proc(12, parent: 10, path: "/bin/zsh")]
        fire(30)
        XCTAssertTrue(named)
    }

    /// What the sweep stops is still stopped, and is not put under the policy: a stopped process does not run.
    func testTheSweepStopsANewPartOfAFrozenGroupAndThrottlesOnlyWhatKeepsRunning() {
        start()
        processes.list = world + [helper(22, of: 20, in: "Browser"),                                   // a new part of the browser
                                  proc(12, parent: 10, path: "/bin/zsh"),                              // a new tool of the editor
                                  proc(60, path: "/Applications/Other.app/Contents/MacOS/Other", app: .regular,
                                       bundle: "com.example.other", name: "Other")]                    // an app opened since
        fire(30)
        XCTAssertEqual(freezer.stops, [20, 21, 30, 22])
        XCTAssertEqual(throttler.throttled, [10, 11, 12], "an app that came after the start is neither kept nor frozen: left as it is")
    }

    func testTheSweepKeepsANewPartOfAnAppLeftRunningOnTheEfficiencyCores() {
        processes.list = world + cloud
        start()
        processes.list = world + cloud + [helper(42, of: 40, in: "Cloud")]
        fire(30)
        XCTAssertEqual(throttler.throttled, [10, 11, 40, 42])
    }

    func testTheSweepKeepsANewPartOfAnAppTheOwnerBroughtBackOnTheEfficiencyCores() {
        start()
        controller.release(groupID: "com.example.browser")
        processes.list = world + [helper(22, of: 20, in: "Browser")]
        fire(30)
        XCTAssertEqual(throttler.throttled, [10, 11, 20, 21, 22])
        XCTAssertEqual(freezer.stops, [20, 21, 30], "a released group is not frozen again")
        controller.turnOff()
        XCTAssertEqual(throttler.lifted, [10, 11, 20, 21, 22])
    }

    /// While the call lasts a new part of the app is left at full speed too, and once it is over the next sweep puts all of the
    /// app on the efficiency cores again: what was lifted for the call, and what started during it.
    func testANewPartOfAGroupOnACallIsLeftAloneWhileItLastsAndKeptOnTheEfficiencyCoresAfter() {
        start()
        processes.list = worldOnACall + [proc(12, parent: 10, path: "/bin/zsh")]
        fire(30)
        XCTAssertEqual(throttler.throttled, [10, 11], "12 is new, but its app is on a call: a call's audio and video must not stutter")
        processes.list = world + [proc(12, parent: 10, path: "/bin/zsh")]
        fire(30)
        XCTAssertEqual(throttler.throttled, [10, 11, 10, 11, 12], "the call is over: all of the app, new part included")
        XCTAssertEqual(namedThrottled, [10, 11, 12])
    }

    /// A group that was on a call when the mode began was left at full speed. It is not left so for the rest of the session: the
    /// sweep after the call is over puts it on the efficiency cores.
    func testAGroupOnACallAtTheStartIsKeptOnTheEfficiencyCoresByASweepOnceTheCallEnds() {
        processes.list = worldOnACall
        start()
        XCTAssertEqual(throttler.throttled, [], "the only kept app is on a call")
        XCTAssertNil(namedThrottled)
        fire(30)
        XCTAssertEqual(throttler.throttled, [], "still on the call")
        XCTAssertEqual(throttler.lifted, [], "and nothing was under the policy to lift")
        processes.list = world
        fire(30)
        XCTAssertEqual(throttler.throttled, [10, 11])
        XCTAssertEqual(namedThrottled, [10, 11])
        controller.turnOff()
        XCTAssertEqual(throttler.lifted, [10, 11])
    }

    // A call that starts and stops during the session

    func testAKeptGroupThatStartsACallIsLiftedAtTheNextSweepAndTakenOffTheRecordAfterTheLift() {
        start()
        var namedWhenLifted: [pid_t: Bool] = [:]
        throttler.onLift = { [unowned self] pid in namedWhenLifted[pid] = self.namedThrottled?.contains(pid) ?? false }
        processes.list = worldOnACall
        fire(30)
        XCTAssertEqual(throttler.lifted, [10, 11], "the app's own processes, each by the start time the record has")
        XCTAssertEqual(throttler.liftStartTimes, [10: 100, 11: 110])
        XCTAssertEqual(namedWhenLifted, [10: true, 11: true], "still named when the lift is done: the record changes after it")
        XCTAssertEqual(namedThrottled, [], "and not any more once it is")
        XCTAssertEqual(controller.state, .on)
    }

    func testItIsNotPutBackUnderThePolicyWhileItStillUsesTheMicrophoneOrCamera() {
        start()
        processes.list = worldOnACall
        fire(30)
        fire(30)
        fire(30)
        XCTAssertEqual(throttler.throttled, [10, 11], "not again while the call lasts")
        XCTAssertEqual(throttler.lifted, [10, 11], "and nothing to lift a second time")
        XCTAssertEqual(namedThrottled, [])
    }

    func testWhenTheCallStopsALaterSweepKeepsItOnTheEfficiencyCoresAgain() {
        start()
        processes.list = worldOnACall
        fire(30)
        processes.list = world
        fire(30)
        XCTAssertEqual(throttler.throttled, [10, 11, 10, 11])
        XCTAssertEqual(namedThrottled, [10, 11])
        // And the next call is lifted again.
        processes.list = worldOnACall
        fire(30)
        XCTAssertEqual(throttler.lifted, [10, 11, 10, 11])
        XCTAssertEqual(namedThrottled, [])
        controller.turnOff()
        XCTAssertEqual(throttler.lifted, [10, 11, 10, 11, 10, 11], "nothing is named at the end; the members of the kept group are lifted all the same")
    }

    /// A part of the app that started after the last sweep followed the policy and is on no record. It is the likeliest one to be
    /// the part on the call (a new tab's process), so it is lifted with the app.
    func testAChildOfTheAppThatInheritedThePolicyIsLiftedWhenTheAppStartsACall() {
        start()
        processes.list = worldOnACall + [proc(12, parent: 10, path: "/bin/zsh"), proc(13, parent: 12, path: "/bin/zsh")]
        fire(30)
        XCTAssertEqual(throttler.lifted, [10, 11, 12, 13])
        XCTAssertEqual(throttler.throttled, [10, 11], "and none of the new parts is put under it during the call")
        XCTAssertEqual(namedThrottled, [])
    }

    /// Only the app on a call is lifted: the others stay under the policy.
    func testAnotherAppThatIsNotOnACallStaysUnderThePolicy() {
        processes.list = world + cloud
        start()
        XCTAssertEqual(throttler.throttled, [10, 11, 40])
        processes.list = worldOnACall + cloud
        fire(30)
        XCTAssertEqual(throttler.lifted, [10, 11])
        XCTAssertEqual(namedThrottled, [40])
    }

    /// A lift the system refused leaves the process on the record, so that the end lifts it again and the next sweep tries.
    func testAProcessWhoseLiftWasRefusedStaysOnTheRecordAndIsTriedAgain() {
        start()
        throttler.refuseLift = [11]
        processes.list = worldOnACall
        fire(30)
        XCTAssertEqual(throttler.lifted, [10, 11])
        XCTAssertEqual(namedThrottled, [11])
        fire(30)
        XCTAssertEqual(throttler.lifted, [10, 11, 11])
        throttler.refuseLift = []
        controller.turnOff()
        XCTAssertEqual(throttler.lifted, [10, 11, 11, 11, 10], "11 as the record names it, then 10, a member of the kept group")
    }

    /// A pid on the record that is not the recorded process now (recycled) is not the app's, whatever it is doing.
    func testARecycledPidOnTheRecordIsNotLiftedBecauseOfWhatThePidDoesNow() {
        start()
        var other = worldOnACall
        let editor = other.firstIndex { $0.pid == 11 }!
        other[editor] = UltraProcess(pid: 11, parent: 1, uid: 501, startTime: 99_999, path: "/bin/zsh", name: "zsh")
        processes.list = other
        fire(30)
        XCTAssertEqual(throttler.lifted, [10], "11 is another process now: not lifted, and still on the record as it was")
        XCTAssertEqual(namedThrottled, [11])
    }

    func testARefusedThrottleIsNotRetriedByEverySweep() {
        start()
        throttler.refuse = [12]
        processes.list = world + [proc(12, parent: 10, path: "/bin/zsh")]
        fire(30)
        fire(30)
        XCTAssertEqual(throttler.throttled.filter { $0 == 12 }.count, 1)
        XCTAssertEqual(namedThrottled, [10, 11], "not on the record: nothing was done to it")
    }

    func testASweepThatCannotRecordWhatItWouldThrottleThrottlesNothingAndTriesAgainLater() {
        start()
        store.refuseSave = { ($0.throttled?.count ?? 0) > 2 }
        processes.list = world + [proc(12, parent: 10, path: "/bin/zsh")]
        fire(30)
        XCTAssertEqual(throttler.throttled, [10, 11])
        XCTAssertTrue(logged.contains { $0.contains("record") }, "\(logged)")
        store.refuseSave = { _ in false }
        fire(30)
        XCTAssertEqual(throttler.throttled, [10, 11, 12])
    }

    func testASweepAlsoLooksAtANewPartWhenAPartIsStoppedInTheSameSweep() {
        start()
        processes.list = world + [helper(22, of: 20, in: "Browser"), proc(12, parent: 10, path: "/bin/zsh")]
        let reads = load.reads
        fire(30)
        XCTAssertEqual(load.reads, reads + 1, "the freeze is guarded as before")
        XCTAssertEqual(throttler.throttled, [10, 11, 12])
    }

    // The end

    func testTurnOffLiftsThePolicyFromEveryRecordedProcessAfterTheContinuesAndBeforeTheUnhide() {
        start()
        processes.list = world + [proc(12, parent: 10, path: "/bin/zsh")]
        fire(30)
        controller.release(groupID: "com.example.sync")
        calls.list.removeAll()
        controller.turnOff()
        XCTAssertEqual(throttler.lifted, [10, 11, 12, 30, 31],
                       "what the record names, then the extension (31), a child of 30 that the table shows at the end")
        XCTAssertEqual(freezer.resumes, [30, 20, 21], "the released group was continued by the release, the rest at the end")
        assertAllBefore("resume", "unthrottle")
        assertAllBefore("unthrottle", "unhide")
        assertAllBefore("unthrottle", "brightness")
        XCTAssertEqual(controller.state, .off)
    }

    func testShutdownLiftsThePolicyOnTheCallingThread() {
        start()
        let workBefore = workRuns
        calls.list.removeAll()
        controller.shutdown()
        XCTAssertEqual(throttler.lifted, [10, 11])
        XCTAssertEqual(workRuns, workBefore + 1, "the lifts are on this thread; the one job the queue gets is the settings")
        assertAllBefore("resume", "unthrottle")
        assertAllBefore("unthrottle", "unhide")
    }

    func testRecoveryAtLaunchLiftsThePolicyFromWhatTheRecordNamesWhateverTheSettingIsNow() {
        // The box was unticked, and this Mac says it has no efficiency cores: the record is what is undone.
        settings.ultraLowPowerEfficiencyCores = false
        hasEfficiencyCores = false
        controller = makeController()
        var record = UltraRecord()
        record.groups = [UltraRecord.Group(id: "com.example.browser", name: "Browser", members: [.init(pid: 20, startTime: 200)])]
        record.throttled = [.init(pid: 10, startTime: 100), .init(pid: 11, startTime: 110)]
        store.record = record
        controller.recoverAtLaunch()
        XCTAssertEqual(throttler.lifted, [10, 11])
        XCTAssertEqual(freezer.resumes, [20])
        assertAllBefore("resume", "unthrottle")
        XCTAssertNil(store.record)
        XCTAssertEqual(throttler.throttled, [])
    }

    func testARecordFromBeforeThePartLiftsNothing() {
        var record = UltraRecord()
        record.groups = [UltraRecord.Group(id: "com.example.browser", name: "Browser", members: [.init(pid: 20, startTime: 200)])]
        store.record = record
        controller.recoverAtLaunch()
        XCTAssertEqual(freezer.resumes, [20])
        XCTAssertEqual(throttler.lifted, [])
    }

    func testALiftThatFailedIsLoggedOncePerProcessAndTheRestAreLifted() {
        var record = UltraRecord()
        record.throttled = [.init(pid: 10, startTime: 100), .init(pid: 11, startTime: 110), .init(pid: 11, startTime: 111),
                            .init(pid: 12, startTime: 120)]
        store.record = record
        throttler.refuseLift = [11]
        controller.recoverAtLaunch()
        XCTAssertEqual(throttler.lifted, [10, 11, 11, 12], "each named process is asked")
        XCTAssertEqual(logged.filter { $0.contains("11") }.count, 1, "\(logged)")
        XCTAssertEqual(logged.filter { $0.contains("10") || $0.contains("12") }.count, 0, "they answered: nothing failed")
    }

    func testAProcessThatEndedDuringTheSessionIsLoggedOnTurnOffAndTheModeStillEnds() {
        start()
        throttler.refuseLift = [11]
        controller.turnOff()
        XCTAssertEqual(throttler.lifted, [10, 11])
        XCTAssertEqual(logged.filter { $0.contains("11") }.count, 1, "\(logged)")
        XCTAssertEqual(controller.state, .off)
        XCTAssertNil(store.record)
    }

    // A start that does not finish

    func testAStartCancelledWhileAnAppIsBeingHiddenThrottlesNothingWhenTheAppAnswersLate() {
        hider.hold = true
        start()
        controller.turnOff()
        hider.held.forEach { $0() }
        XCTAssertEqual(throttler.throttled, [])
        XCTAssertEqual(controller.state, .off)
        XCTAssertNil(store.record)
    }

    func testAStartThatIsQuitBeforeTheLoadReturnsThrottlesNothing() {
        controller.request()
        load.holdNext = 1
        confirm.press(true)
        controller.shutdown()
        load.answerHeld()
        XCTAssertEqual(throttler.throttled, [])
        XCTAssertEqual(throttler.lifted, [])
    }

    /// The mode is turned off while the screen is being lowered: the processes were put under the policy before that step, and
    /// ending the mode lifts it from them.
    func testTurnOffWhileTheScreenIsBeingLoweredLiftsWhatWasThrottled() {
        workLimit = 1
        start()
        XCTAssertEqual(throttler.throttled, [10, 11])
        controller.turnOff()
        runHeldWork()
        XCTAssertEqual(throttler.lifted, [10, 11])
        XCTAssertEqual(controller.state, .off)
    }

    func testANewSessionNamesItsOwnProcessesAndNotTheLastOnes() {
        // Turn off, and a second session after it: the second starts from nothing.
        start()
        controller.turnOff()
        XCTAssertEqual(throttler.lifted, [10, 11])
        start()
        XCTAssertEqual(namedThrottled, [10, 11], "the new session's record starts empty and names its own")
        XCTAssertEqual(throttler.throttled, [10, 11, 10, 11])
    }

    // ── The black backdrop ──────────────────────────────────────────────────

    func testTheBackdropIsShownOnceTheModeIsOnAndAfterTheScreensParts() {
        var stateWhenShown: UltraLowPowerController.State?
        backdrop.onShow = { [unowned self] in stateWhenShown = self.controller.state }
        start()
        XCTAssertEqual(backdrop.shows, 1)
        XCTAssertTrue(backdrop.shown)
        XCTAssertEqual(stateWhenShown, .on, "not while the mode is still being started")
        assertAllBefore("rate lower", "backdrop show")
        assertAllBefore("power enter", "backdrop show")
    }

    func testNothingIsShownWhileTheBoxIsUpOrBeforeConfirm() {
        controller.request()
        XCTAssertEqual(backdrop.shows, 0)
        confirm.press(false)
        XCTAssertEqual(backdrop.shows, 0)
        XCTAssertEqual(controller.state, .off)
    }

    func testWithTheSettingOffTheBackdropIsNeverShown() {
        settings.ultraLowPowerBlackBackdrop = false
        start()
        XCTAssertEqual(controller.state, .on)
        XCTAssertEqual(backdrop.shows, 0)
        controller.turnOff()
        XCTAssertFalse(backdrop.shown)
    }

    func testTurnOffTakesTheBackdropAway() {
        start()
        XCTAssertTrue(backdrop.shown)
        controller.turnOff()
        XCTAssertEqual(controller.state, .off)
        XCTAssertFalse(backdrop.shown)
    }

    func testShutdownTakesTheBackdropAway() {
        start()
        controller.shutdown()
        XCTAssertFalse(backdrop.shown)
        XCTAssertGreaterThan(backdrop.hides, 0)
    }

    /// A turn-off whose settings are still being put back leaves the state on, and the backdrop with it: it goes when the
    /// state does, and a quit that overtakes it takes it away at once.
    func testAQuitThatOvertakesATurnOffStillTakesItAway() {
        start()
        holdWork = true
        controller.turnOff()
        XCTAssertEqual(controller.state, .on, "still being put back")
        controller.shutdown()
        XCTAssertFalse(backdrop.shown)
        runHeldWork()
        XCTAssertFalse(backdrop.shown)
    }

    func testAStartThatFailedNeverShowsTheBackdrop() {
        store.refuseSave = { _ in true }
        start()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(backdrop.shows, 0)

        // The watchdog did not start.
        store.refuseSave = { _ in false }
        watchdog.startResult = false
        start()
        XCTAssertEqual(backdrop.shows, 0)

        // The process list could not be read.
        processes.list = nil
        controller.request()
        XCTAssertEqual(backdrop.shows, 0)
        XCTAssertFalse(backdrop.shown)
    }

    func testAStartThatWasCancelledNeverShowsTheBackdropWhenTheLateAnswersArrive() {
        // While an app is being hidden.
        hider.hold = true
        start()
        controller.turnOff()
        hider.held.forEach { $0() }
        XCTAssertEqual(backdrop.shows, 0)

        // While the helper is answering.
        hider.hold = false
        power.hold = true
        start()
        XCTAssertEqual(controller.state, .confirming)
        controller.turnOff()
        power.held.forEach { $0(0) }
        XCTAssertEqual(backdrop.shows, 0)
        XCTAssertEqual(controller.state, .off)
        XCTAssertFalse(backdrop.shown)

        // Quit before the load comes back.
        power.hold = false
        controller.request()
        load.holdNext = 1
        confirm.press(true)
        controller.shutdown()
        load.answerHeld()
        XCTAssertEqual(backdrop.shows, 0)
    }

    func testAStartTurnedOffWhileTheScreenIsBeingLoweredNeverShowsTheBackdrop() {
        for n in [1, 2, 3, 4, 5] {
            workLimit = n - 1
            heldWork = []
            workRuns = 0
            start()
            controller.turnOff()
            runHeldWork()
            XCTAssertEqual(backdrop.shows, 0, "call \(n) was on the queue")
            XCTAssertFalse(backdrop.shown, "call \(n) was on the queue")
            XCTAssertEqual(controller.state, .off)
        }
    }

    func testARecoveryOfALeftoverRecordNeverShowsTheBackdrop() {
        var record = UltraRecord()
        record.groups = [UltraRecord.Group(id: "com.example.browser", name: "Browser", members: [.init(pid: 20, startTime: 200)])]
        store.record = record
        controller.recoverAtLaunch()
        XCTAssertEqual(backdrop.shows, 0)
    }

    func testASecondSessionShowsTheBackdropAgain() {
        start()
        controller.turnOff()
        start()
        XCTAssertEqual(backdrop.shows, 2)
        XCTAssertTrue(backdrop.shown)
    }

    // ── Children of what was put under the policy ───────────────────────────

    /// The world, and after the last sweep a tool the editor started (12) with a tool of its own (13): both inherited the policy
    /// and are on no record.
    private var worldWithChildren: [UltraProcess] {
        world + [proc(12, parent: 10, path: "/bin/zsh"), proc(13, parent: 12, path: "/bin/zsh")]
    }

    func testAChildBornAfterTheLastSweepIsLiftedAtTurnOff() {
        start()
        processes.list = worldWithChildren
        XCTAssertEqual(tableReads, 0, "nothing reads the table before the end")
        calls.list.removeAll()
        controller.turnOff()
        XCTAssertEqual(throttler.lifted, [10, 11, 12, 13], "what the record names, then every living descendant of one of them")
        XCTAssertEqual(throttler.liftStartTimes[12], 120, "by the start time the table has now")
        XCTAssertEqual(tableReads, 1)
        assertAllBefore("resume", "unthrottle")
        assertAllBefore("unthrottle", "unhide")
        assertAllBefore("unthrottle", "brightness")
        XCTAssertEqual(controller.state, .off)
    }

    func testAChildBornAfterTheLastSweepIsLiftedAtShutdownOnTheCallingThread() {
        start()
        processes.list = worldWithChildren
        let workBefore = workRuns
        calls.list.removeAll()
        controller.shutdown()
        XCTAssertEqual(throttler.lifted, [10, 11, 12, 13])
        XCTAssertEqual(workRuns, workBefore + 1, "the lifts are on this thread; the one job the queue gets is the settings")
        assertAllBefore("resume", "unthrottle")
        assertAllBefore("unthrottle", "unhide")
    }

    func testAChildBornAfterTheLastSweepIsLiftedAtRecoveryFromTheRecord() {
        // A session that was not ended: the record names the editor's processes, and a tool it started since is in the table.
        var record = UltraRecord()
        record.groups = [UltraRecord.Group(id: "com.example.browser", name: "Browser", members: [.init(pid: 20, startTime: 200)])]
        record.throttled = [.init(pid: 10, startTime: 100), .init(pid: 11, startTime: 110)]
        store.record = record
        processes.list = worldWithChildren
        // Whatever the settings are now, and whether or not this Mac says it has the cores: the record is what is undone.
        settings.ultraLowPowerEfficiencyCores = false
        hasEfficiencyCores = false
        controller = makeController()
        controller.recoverAtLaunch()
        XCTAssertEqual(throttler.lifted, [10, 11, 12, 13])
        XCTAssertEqual(freezer.resumes, [20])
        assertAllBefore("resume", "unthrottle")
        XCTAssertNil(store.record)
    }

    /// Only what started under something the mode put under the policy inherited it: a child of an app that was frozen, a stranger
    /// and anything under launchd are none of it.
    func testAProcessThatIsNoDescendantOfARecordedProcessIsNeverTouched() {
        start()
        processes.list = worldWithChildren + [proc(60, parent: 20, path: "/usr/bin/helper-of-the-frozen-browser"),
                                             proc(61, parent: 1, path: "/usr/bin/stranger"),
                                             proc(62, parent: 61, path: "/usr/bin/stranger-child")]
        controller.turnOff()
        XCTAssertEqual(throttler.lifted, [10, 11, 12, 13])
    }

    /// A recorded pid that is not the recorded process any more has no children of the recorded one to find.
    func testTheChildrenOfARecycledRecordedPidAreNotWalked() {
        var record = UltraRecord()
        record.throttled = [.init(pid: 10, startTime: 999), .init(pid: 20, startTime: 200)]   // 10 started at 100: it is another process
        store.record = record
        processes.list = worldWithChildren
        controller.recoverAtLaunch()
        XCTAssertEqual(throttler.lifted, [10, 20, 21],
                       "10 is asked about as the record has it (the throttler refuses it); its tools are not walked, 20's helper is")
        XCTAssertFalse(throttler.lifted.contains(12))
        XCTAssertFalse(throttler.lifted.contains(13))
    }

    func testAnodeAndItsWatchdogAreNeverTakenForChildren() {
        start()
        watchdog.pid = 900
        // Anode was run from a terminal that is under the policy, and the watchdog is Anode's child.
        processes.list = world.filter { $0.pid != 1000 } + [proc(1000, parent: 10, path: "/Applications/Anode.app/Contents/MacOS/Anode"),
                                                            proc(900, parent: 1000, path: "/var/tmp/watchdog-copy")]
        controller.turnOff()
        XCTAssertEqual(throttler.lifted, [10, 11])
    }

    func testATableThatCannotBeReadStillLiftsWhatTheRecordNamesAndSaysSoOnce() {
        start()
        tableReader = { nil }
        controller.turnOff()
        XCTAssertEqual(throttler.lifted, [10, 11])
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(logged.filter { $0.contains("process table") }.count, 1, "\(logged)")
    }

    func testTheTableIsNotReadWhenNothingWasPutUnderThePolicy() {
        settings.ultraLowPowerEfficiencyCores = false
        start()
        controller.turnOff()
        XCTAssertEqual(tableReads, 0)
        start()
        controller.shutdown()
        XCTAssertEqual(tableReads, 0)
    }

    func testAChildWhoseLiftFailedIsLoggedOnce() {
        start()
        processes.list = worldWithChildren
        throttler.refuseLift = [12]
        controller.turnOff()
        XCTAssertEqual(throttler.lifted, [10, 11, 12, 13])
        XCTAssertEqual(logged.filter { $0.contains("12") }.count, 1, "\(logged)")
        XCTAssertEqual(controller.state, .off)
    }

    // ── Every member of what was kept, at the end ───────────────────────────

    /// A table as the live reader gives it: pid, parent, start time, path and the process held responsible, and none of what an app
    /// lookup adds (no app, no bundle id).
    private func light(_ process: UltraProcess) -> UltraProcess {
        UltraProcess(pid: process.pid, parent: process.parent, uid: process.uid, startTime: process.startTime, path: process.path,
                     responsible: process.responsible, name: process.name)
    }

    /// A build daemon a script of the editor started after the last sweep: the script has gone, so the daemon belongs to launchd
    /// (no child of anything the walk can reach), and only the process held responsible for it ties it to the editor.
    private func orphan(_ pid: pid_t, of responsible: pid_t, path: String = "/Users/someone/bin/build-daemon") -> UltraProcess {
        UltraProcess(pid: pid, parent: 1, uid: 501, startTime: UInt64(pid) * 10, path: path, responsible: responsible,
                     name: "build-daemon")
    }

    func testAnOrphanedMemberOfTheKeptAppBornAfterTheLastSweepIsLiftedAtTurnOff() {
        start()
        processes.list = world + [orphan(15, of: 10)]
        tableReader = { [unowned self] in self.processes.list?.map(self.light) }
        calls.list.removeAll()
        controller.turnOff()
        XCTAssertEqual(throttler.lifted, [10, 11, 15], "the walk cannot reach it; the group it belongs to can")
        XCTAssertEqual(throttler.liftStartTimes[15], 150)
        assertAllBefore("resume", "unthrottle")
        assertAllBefore("unthrottle", "unhide")
        XCTAssertEqual(controller.state, .off)
    }

    func testAnOrphanedMemberOfTheKeptAppBornAfterTheLastSweepIsLiftedAtShutdown() {
        start()
        processes.list = world + [orphan(15, of: 10)]
        tableReader = { [unowned self] in self.processes.list?.map(self.light) }
        let workBefore = workRuns
        controller.shutdown()
        XCTAssertEqual(throttler.lifted, [10, 11, 15])
        XCTAssertEqual(workRuns, workBefore + 1, "the lifts are on this thread; the one job the queue gets is the settings")
    }

    /// The groups are placed with what the last snapshot knew of the apps (a bundle id is not in a light read of the table).
    func testTheGroupsAreFoundFromALightTableAndTheLastSnapshot() {
        start()
        // A sweep reads a newer snapshot; the apps in it are the ones the end knows.
        processes.list = world + [proc(12, parent: 10, path: "/bin/zsh")]
        fire(30)
        processes.list = world + [proc(12, parent: 10, path: "/bin/zsh"), orphan(15, of: 12)]
        tableReader = { [unowned self] in self.processes.list?.map(self.light) }
        controller.turnOff()
        XCTAssertEqual(throttler.lifted, [10, 11, 12, 15])
    }

    /// An app the mode never put under the policy (a frozen one, one opened since, the system's) has nothing of its to lift.
    func testAProcessOfAGroupThatWasNeverThrottledIsNotTouched() {
        start()
        processes.list = world + [orphan(25, of: 20),                                              // the frozen browser's
                                  orphan(26, of: 30),                                              // the frozen sync agent's
                                  proc(70, path: "/usr/libexec/newd"),                              // the system's
                                  proc(60, path: "/Applications/Other.app/Contents/MacOS/Other", app: .regular,
                                       bundle: "com.example.other", name: "Other"),                // an app opened since
                                  orphan(61, of: 60)]
        tableReader = { [unowned self] in self.processes.list?.map(self.light) }
        controller.turnOff()
        XCTAssertEqual(throttler.lifted, [10, 11])
    }

    /// Descendant and member both: lifted once. (12 and 13 are the editor's tools, children of what was named, and also in its
    /// group; 15 is only in its group.)
    func testAProcessThatIsBothADescendantAndAMemberIsLiftedOnce() {
        start()
        processes.list = worldWithChildren + [orphan(15, of: 10)]
        tableReader = { [unowned self] in self.processes.list?.map(self.light) }
        controller.turnOff()
        XCTAssertEqual(throttler.lifted, [10, 11, 12, 13, 15])
        XCTAssertEqual(throttler.lifted.count, Set(throttler.lifted).count, "no repeats")
    }

    func testAnOrphanedMemberOfAnAppBroughtBackAndOfAnAppLeftRunningIsLifted() {
        processes.list = world + cloud
        start()
        controller.release(groupID: "com.example.browser")
        processes.list = world + cloud + [orphan(25, of: 20), orphan(45, of: 40)]
        tableReader = { [unowned self] in self.processes.list?.map(self.light) }
        controller.turnOff()
        XCTAssertEqual(throttler.lifted, [10, 11, 40, 20, 21, 25, 45], "what the record names, then the orphans of the groups")
    }

    /// Whether or not the record could name them: lifting a process that was never set changes nothing, so the end lifts every
    /// member of the groups the session meant to throttle.
    func testTheEndLiftsFromTheMembersOfTheKeptGroupsEvenWhenTheRecordNamedNothing() {
        store.refuseSave = { $0.throttled != nil }
        start()
        XCTAssertEqual(throttler.throttled, [])
        processes.list = world + [orphan(15, of: 10)]
        tableReader = { [unowned self] in self.processes.list?.map(self.light) }
        controller.turnOff()
        XCTAssertEqual(throttler.lifted, [10, 11, 15])
    }

    /// A recovery at launch has the record and nothing else: it does not know which groups were kept, and a fresh launch has no
    /// snapshot to place a process in a group with, so it lifts what the record names and what those started, and no more.
    func testRecoveryAtLaunchDoesNotLiftFromGroupsItCannotKnow() {
        var record = UltraRecord()
        record.throttled = [.init(pid: 10, startTime: 100)]
        store.record = record
        processes.list = world + [orphan(15, of: 10)]
        tableReader = { [unowned self] in self.processes.list?.map(self.light) }
        controller.recoverAtLaunch()
        XCTAssertEqual(throttler.lifted, [10, 11], "named, and its child 11; not 15, which only its group could name")
    }

    /// With the part off nothing was put under the policy and nothing is looked for.
    func testWithTheSettingOffTheEndLiftsAndReadsNothing() {
        settings.ultraLowPowerEfficiencyCores = false
        start()
        processes.list = world + [orphan(15, of: 10)]
        controller.turnOff()
        XCTAssertEqual(throttler.lifted, [])
        XCTAssertEqual(tableReads, 0)
    }

    // ── The spin guard ──────────────────────────────────────────────────────

    func testTheGuardIsScheduledAfterTheFreezeAtBothDelays() {
        XCTAssertEqual(UltraLowPowerController.guardDelays, [5, 15])
        start()
        XCTAssertTrue(scheduled.contains { $0.delay == 5 })
        XCTAssertTrue(scheduled.contains { $0.delay == 15 })
    }

    func testTheGuardReleasesAGroupThatMadeSomethingBurnAndRemembersIt() {
        // The sync agent's extension (31) was quiet; 5 s after the agent was stopped it burns a core and a half.
        load.queue = [nil, sample(1.0, [10: 0.2]), sample(2.6, [10: 0.2, 31: 1.4])]
        start()
        fire(5)
        XCTAssertEqual(controller.releasedForLoad, ["com.example.sync"])
        XCTAssertEqual(freezer.resumes, [30])
        XCTAssertEqual(groupIDs(controller.frozen), ["com.example.browser"])
        XCTAssertFalse(controller.isFrozen(pid: 30))
        XCTAssertTrue(controller.isFrozen(pid: 20), "the browser did nothing wrong")
        XCTAssertEqual(store.record?.groups.map(\.released), [false, true])
        XCTAssertTrue(logged.contains { $0.contains("Sync") || $0.contains("sync") }, "\(logged)")
    }

    func testAnUnexplainedRiseReleasesEverythingFrozenInThatStep() {
        // Nothing of the user's burns, yet the Mac does and the owner's own apps do not account for it: it needs both
        // delays to agree.
        load.queue = [nil, sample(1.0), sample(2.0), sample(2.0)]
        start()
        fire(5)
        XCTAssertEqual(controller.releasedForLoad, [], "one reading is not enough")
        XCTAssertEqual(freezer.resumes, [])
        fire(15)
        XCTAssertEqual(controller.releasedForLoad, ["com.example.browser", "com.example.sync"])
        XCTAssertEqual(freezer.resumes, [20, 21, 30])
        XCTAssertEqual(controller.frozen, [])
        XCTAssertFalse(freezer.resumes.contains(10), "the editor was never stopped")
    }

    func testOneUnexplainedReadingAloneReleasesNothing() {
        load.queue = [nil, sample(1.0), sample(2.0), sample(1.0)]
        start()
        fire(5)
        fire(15)
        XCTAssertEqual(controller.releasedForLoad, [])
        XCTAssertEqual(freezer.resumes, [])
        XCTAssertEqual(controller.frozen.count, 2)
    }

    func testAnUnexplainedReadingAtTheSecondDelayAloneReleasesNothing() {
        load.queue = [nil, sample(1.0), sample(1.0), sample(2.0)]
        start()
        fire(5)
        fire(15)
        XCTAssertEqual(controller.releasedForLoad, [])
        XCTAssertEqual(freezer.resumes, [])
    }

    func testAnUnexplainedRiseReleasesOnlyWhatIsStillFrozen() {
        load.queue = [nil, sample(1.0), sample(2.0), sample(2.0)]
        start()
        controller.release(groupID: "com.example.browser")   // the owner took the browser back in between
        fire(5)
        fire(15)
        XCTAssertEqual(controller.releasedForLoad, ["com.example.sync"])
        XCTAssertEqual(freezer.resumes, [20, 21, 30], "the browser once, by the owner")
    }

    func testAGroupReleasedForLoadIsNotFrozenAgainByTheSweep() {
        load.queue = [nil, sample(1.0, [10: 0.2]), sample(2.6, [10: 0.2, 31: 1.4])]
        start()
        fire(5)
        XCTAssertEqual(controller.releasedForLoad, ["com.example.sync"])
        // The agent starts an updater of its own; the sweep must leave the group alone for the rest of the session.
        processes.list = world + [proc(32, parent: 30, path: "/Applications/Sync.app/Contents/MacOS/Updater")]
        fire(30)
        XCTAssertEqual(freezer.stops, [20, 21, 30])
        XCTAssertFalse(controller.isFrozen(pid: 32))
    }

    func testTheGuardJudgesAfterASweepFreezeToo() {
        load.queue = [nil, sample(1.0),                                     // the box opens; the start's 'before'
                      sample(1.0), sample(1.0),                             // 5 s and 15 s after the start: quiet
                      sample(1.0),                                          // the sweep's own 'before'
                      sample(3.0, [10: 0.2, 31: 2.0])]                      // 5 s after the sweep: the extension burns
        start()
        fire(5); fire(15)
        processes.list = world + [helper(22, of: 20, in: "Browser")]
        fire(30)
        XCTAssertEqual(freezer.stops, [20, 21, 30, 22])
        // The extension (31) is the sync agent's: that group is released, whichever step the freeze was in.
        fire(5)
        XCTAssertEqual(controller.releasedForLoad, ["com.example.sync"])
    }

    func testWhatTheOwnerIsDoingIsNotBlamedOnTheFreeze() {
        // The editor starts a build after the freeze and the Mac gets busier: that is the owner's work, and the
        // owner's apps are kept on purpose, so it is not something a freeze made burn.
        let building = sample(3.0, [10: 1.8, 11: 1.0])
        load.queue = [nil, sample(1.0), building, building]
        start()
        fire(5)
        fire(15)
        XCTAssertEqual(controller.releasedForLoad, [])
        XCTAssertEqual(freezer.resumes, [])
        XCTAssertEqual(controller.frozen.count, 2)
    }

    func testAFailedLoadReadingChangesNothing() {
        load.queue = [nil, sample(1.0), nil, nil]
        start()
        fire(5)
        fire(15)
        XCTAssertEqual(controller.releasedForLoad, [])
        XCTAssertEqual(freezer.resumes, [])
        XCTAssertEqual(controller.state, .on)
        XCTAssertTrue(logged.contains { $0.contains("load") }, "\(logged)")
    }

    func testAFailedSnapshotDuringTheGuardChangesNothing() {
        load.queue = [nil, sample(1.0), sample(4.0), sample(4.0)]
        start()
        processes.list = nil
        fire(5)
        fire(15)
        XCTAssertEqual(controller.releasedForLoad, [])
        XCTAssertEqual(freezer.resumes, [])
        XCTAssertTrue(logged.contains { $0.contains("process list") }, "\(logged)")
    }

    func testWithNoReadingFromBeforeTheFreezeTheGuardCannotJudgeAndSaysSo() {
        load.queue = [nil, nil, sample(4.0, [10: 0.2, 31: 3.0]), sample(4.0, [10: 0.2, 31: 3.0])]
        start()
        let reads = load.reads
        fire(5)
        fire(15)
        XCTAssertEqual(controller.releasedForLoad, [], "nothing to compare with")
        XCTAssertEqual(freezer.resumes, [])
        XCTAssertEqual(load.reads, reads)
        XCTAssertTrue(logged.contains { $0.contains("before") }, "\(logged)")
    }

    // ── Nothing in the start waits for ever ─────────────────────────────────

    /// The start with the work queue jammed after `jobs` jobs have gone through: the call that is waiting never answers. The
    /// brightness takes two jobs (a read, a set), the refresh rate one, the keyboard light two.
    private func startWithTheQueueJammedAfter(_ jobs: Int) {
        workLimit = jobs
        start()
    }

    func testABrightnessReadThatNeverAnswersIsSkippedAtItsDeadlineAndTheModeComesOn() {
        startWithTheQueueJammedAfter(0)
        XCTAssertEqual(controller.state, .confirming, "waiting for the display")
        XCTAssertEqual(startDeadlines.map(\.delay), [UltraLowPowerController.displayStepSeconds])
        fireStartDeadline(3)
        XCTAssertEqual(controller.skipped, [.ceilingRefused])
        XCTAssertEqual(logged.filter { $0.contains("brightness") && $0.contains("answer") }.count, 1, "\(logged)")
        // The queue is still jammed, so the refresh rate and the keyboard light go the same way, each at its own deadline.
        fireStartDeadline(3)
        fireStartDeadline(3)
        XCTAssertEqual(controller.state, .on, "the helper's step is not on the queue")
        XCTAssertEqual(controller.skipped, [.ceilingRefused, .rateRefused, .keyboardLight])
        XCTAssertEqual(power.entered, 1)
        XCTAssertNil(store.record?.brightnessBefore, "nothing was lowered, so nothing is owed")
        // The queue gets round to what was given it: none of it was started in time, so none of it changes anything now.
        runHeldWork()
        XCTAssertEqual(backlight.sets, [])
        XCTAssertEqual(rate.lowered, 0)
        XCTAssertEqual(keyboard.sets, [])
        XCTAssertEqual(controller.skipped, [.ceilingRefused, .rateRefused, .keyboardLight])
        XCTAssertEqual(controller.state, .on)
    }

    func testABrightnessSetThatNeverAnswersIsSkippedAndWhatIsNamedStaysNamed() {
        startWithTheQueueJammedAfter(1)         // the read went through, the set is on the queue
        XCTAssertEqual(controller.state, .confirming)
        XCTAssertEqual(store.record?.brightnessBefore, 0.8, "named before it is asked for")
        fireStartDeadline(3)
        XCTAssertEqual(controller.skipped, [.ceilingRefused])
        XCTAssertEqual(store.record?.brightnessBefore, 0.8, "the call may still land: the record keeps naming it")
        fireStartDeadline(3)
        fireStartDeadline(3)
        runHeldWork()
        XCTAssertEqual(backlight.sets, [], "a set that had not started when its time was up does not start now")
        XCTAssertEqual(controller.skipped, [.ceilingRefused, .rateRefused, .keyboardLight])
    }

    func testARefreshRateThatNeverAnswersIsSkippedAtItsDeadlineAndTheModeComesOn() {
        startWithTheQueueJammedAfter(2)         // the brightness is done
        XCTAssertEqual(controller.state, .confirming)
        XCTAssertEqual(backlight.value, 0.25)
        XCTAssertEqual(store.record?.rateLowered, true, "named before it is asked for")
        fireStartDeadline(3)
        XCTAssertEqual(controller.skipped, [.rateRefused])
        XCTAssertEqual(store.record?.rateLowered, true, "the call may still land")
        fireStartDeadline(3)                    // the keyboard light is behind it on the same queue
        XCTAssertEqual(controller.state, .on)
        XCTAssertEqual(controller.skipped, [.rateRefused, .keyboardLight])
        runHeldWork()
        XCTAssertEqual(rate.lowered, 0, "its job had not started when its time was up")
        XCTAssertEqual(controller.skipped, [.rateRefused, .keyboardLight])
        controller.turnOff()
        XCTAssertEqual(rate.restored, 1, "what the record named is put back whether or not the call landed")
    }

    func testAKeyboardLightThatNeverAnswersIsSkippedAtItsDeadlineAndTheModeComesOn() {
        startWithTheQueueJammedAfter(3)         // the brightness and the rate are done; the light's read is jammed
        XCTAssertEqual(controller.state, .confirming)
        fireStartDeadline(3)
        XCTAssertEqual(controller.skipped, [.keyboardLight])
        XCTAssertEqual(controller.state, .on)
        XCTAssertEqual(power.entered, 1, "and the helper is still asked")
        runHeldWork()
        XCTAssertEqual(keyboard.sets, [])
        XCTAssertEqual(controller.skipped, [.keyboardLight])
    }

    func testEachDeadlineGoesOnToTheNextStepExactlyOnce() throws {
        startWithTheQueueJammedAfter(0)
        let brightnessDeadline = try XCTUnwrap(startDeadlines.first).work
        brightnessDeadline()
        XCTAssertEqual(startDeadlines.count, 2, "the refresh rate's step began, and waits")
        // The same deadline again (a timer that ran twice): it does not skip the part twice or begin the next step twice.
        brightnessDeadline()
        XCTAssertEqual(controller.skipped, [.ceilingRefused])
        XCTAssertEqual(startDeadlines.count, 2)
    }

    func testAStepThatAnswersInTimeLeavesNoDeadlineBehindThatDoesAnything() {
        start()
        XCTAssertEqual(controller.state, .on)
        XCTAssertEqual(startDeadlines.count, 0, "every step finished before it was waited for")
        XCTAssertEqual(controller.skipped, [])
    }

    func testAHelperThatDoesNotAnswerIsSkippedAtItsDeadlineAndTheModeComesOn() {
        power.hold = true
        start()
        XCTAssertEqual(controller.state, .confirming, "waiting for the helper")
        XCTAssertEqual(startDeadlines.map(\.delay), [UltraLowPowerController.helperStepSeconds])
        fireStartDeadline(5)
        XCTAssertEqual(controller.state, .on)
        XCTAssertEqual(controller.skipped, [.lowPowerRefused])
        XCTAssertTrue(logged.contains { $0.contains("helper") && $0.contains("answer") }, "\(logged)")
        XCTAssertNil(store.record?.powerModeBefore)
        // The answer comes after all: Low Power Mode is on and nothing recorded it, so it is put back, as when the session has
        // ended. Nothing else changes.
        power.held.forEach { $0(0) }
        XCTAssertEqual(power.restored, [0])
        XCTAssertEqual(controller.skipped, [.lowPowerRefused])
        XCTAssertEqual(controller.state, .on)
        XCTAssertNil(store.record?.powerModeBefore)
        controller.turnOff()
        XCTAssertEqual(power.restored, [0], "and not put back a second time at the end")
    }

    func testAHelperThatAnswersNoAfterItsDeadlineChangesNothing() {
        power.hold = true
        start()
        fireStartDeadline(5)
        power.held.forEach { $0(nil) }
        XCTAssertEqual(power.restored, [])
        XCTAssertEqual(controller.skipped, [.lowPowerRefused], "named once")
    }

    func testTheDeadlinesOfAnEndedStartDoNothing() {
        startWithTheQueueJammedAfter(0)
        controller.turnOff()
        startDeadlines.forEach { $0.work() }
        runHeldWork()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(controller.skipped, [])
        XCTAssertEqual(power.entered, 0, "a start that was cancelled does not go on to the helper")
    }

    // ── A start can be cancelled ────────────────────────────────────────────

    func testIsStartingIsTrueOnlyBetweenConfirmAndOnOrOff() {
        XCTAssertFalse(controller.isStarting)
        controller.request()
        XCTAssertEqual(controller.state, .confirming)
        XCTAssertFalse(controller.isStarting, "the box is up: nothing has started")
        power.hold = true
        confirm.press(true)
        XCTAssertEqual(controller.state, .confirming)
        XCTAssertTrue(controller.isStarting)
        fireStartDeadline(5)
        XCTAssertEqual(controller.state, .on)
        XCTAssertFalse(controller.isStarting)
        controller.turnOff()
        XCTAssertFalse(controller.isStarting)
    }

    func testIsStartingEndsWithACancelAndWithAStartThatCameToNothing() {
        power.hold = true
        start()
        XCTAssertTrue(controller.isStarting)
        controller.turnOff()
        XCTAssertFalse(controller.isStarting, "once the cancel is being done there is nothing left to cancel")
        XCTAssertEqual(controller.state, .off)

        power.hold = false
        store.refuseSave = { _ in true }
        start()
        XCTAssertFalse(controller.isStarting, "the record could not be written: nothing started")
        store.refuseSave = { _ in false }

        controller.request()
        confirm.press(false)
        XCTAssertFalse(controller.isStarting)
    }

    func testTellsTheMenusWhenTheStartBeginsAndWhenItEnds() {
        var seen: [Bool] = []
        controller.onChange = { [unowned self] in seen.append(self.controller.isStarting) }
        power.hold = true
        start()
        XCTAssertTrue(seen.contains(true), "the button must be redrawn as Cancel: \(seen)")
        fireStartDeadline(5)
        XCTAssertEqual(seen.last, false)
    }

    func testCancellingAStartThatIsWaitingForTheHelperPutsEverythingBack() {
        power.hold = true
        start()
        XCTAssertTrue(controller.isStarting)
        XCTAssertEqual(backlight.value, 0.25)
        controller.turnOff()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(freezer.resumes, [20, 21, 30])
        XCTAssertEqual(backlight.value, 0.8)
        XCTAssertEqual(rate.restored, 1)
        XCTAssertEqual(keyboard.sets.last, 0.6)
        XCTAssertEqual(watchdog.stopped, 1)
        XCTAssertNil(store.record)
    }

    func testCancellingAStartThatIsWaitingForTheDisplayPutsEverythingBack() {
        startWithTheQueueJammedAfter(1)         // the brightness read went through; the set is jammed
        XCTAssertTrue(controller.isStarting)
        controller.turnOff()
        XCTAssertEqual(freezer.resumes, [20, 21, 30], "every process runs again at once")
        runHeldWork()
        XCTAssertEqual(controller.state, .off)
        XCTAssertNil(store.record)
        XCTAssertEqual(watchdog.stopped, 1)
        XCTAssertEqual(backlight.value, 0.8)
    }

    func testCancellingWhileTheBoxIsUpStartsNothingAndAConfirmAfterwardsDoesNothing() {
        controller.request()
        XCTAssertFalse(controller.isStarting)
        controller.turnOff()
        XCTAssertEqual(controller.state, .off)
        confirm.press(true)
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(freezer.stops, [])
    }

    // ── The box goes away with the session ──────────────────────────────────

    func testTurningOffWhileTheBoxIsUpPutsTheBoxAway() {
        controller.request()
        XCTAssertTrue(confirm.isUp)
        controller.turnOff()
        XCTAssertEqual(confirm.dismissals, 1)
        XCTAssertFalse(confirm.isUp)
        XCTAssertEqual(controller.state, .off)
    }

    func testAShutdownWhileTheBoxIsUpPutsTheBoxAway() {
        controller.request()
        controller.shutdown()
        XCTAssertEqual(confirm.dismissals, 1)
        XCTAssertEqual(controller.state, .off)
    }

    func testTheBoxIsNotPutAwayTwiceWhenTheOwnerAnsweredIt() {
        controller.request()
        confirm.press(false)
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(confirm.dismissals, 0, "it was answered; nothing was left up")
        start()
        controller.turnOff()
        XCTAssertEqual(confirm.dismissals, 0)
    }

    func testTheBoxThatWasPutAwayAnsweringNoLaterDoesNotUndoANewSession() {
        controller.request()
        controller.turnOff()
        controller.request()                // a new session, a new question
        XCTAssertEqual(controller.state, .confirming)
        XCTAssertEqual(confirm.keptNames.count, 2)
        confirm.press(true)
        XCTAssertEqual(controller.state, .on)
    }

    // ── The owner's ask, when the apps cannot be listed ─────────────────────

    func testAnAskIsReadAtTheOwnersPriorityAndTheSweepAtTheBackgroundOne() {
        start()
        XCTAssertEqual(processes.urgentFlags, [true])
        fire(30)
        XCTAssertEqual(processes.urgentFlags, [true, false])
    }

    func testAListThatCannotBeReadSaysSoOnceAndStartsNothing() {
        processes.list = nil
        var changes = 0
        controller.onChange = { changes += 1 }
        let center = NotificationCenter.default
        var posted = 0
        let token = center.addObserver(forName: UltraLowPowerController.didChange, object: nil, queue: nil) { _ in posted += 1 }
        defer { center.removeObserver(token) }
        controller.request()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(controller.lastFailure, "Anode could not read the running apps. Try again.")
        XCTAssertEqual(alerts, 1)
        XCTAssertGreaterThan(changes, 0)
        XCTAssertGreaterThan(posted, 0)
        XCTAssertEqual(confirm.keptNames.count, 0)
        XCTAssertEqual(freezer.stops, [])
        XCTAssertNil(store.record)
        XCTAssertEqual(watchdog.started, 0)
        XCTAssertFalse(controller.isStarting)
    }

    func testTheFailureStaysUntilTheNextAskAndTheNextAskClearsIt() {
        processes.list = nil
        controller.request()
        XCTAssertNotNil(controller.lastFailure)
        // It is still said after the state came back to off and the section was redrawn.
        XCTAssertEqual(controller.state, .off)
        XCTAssertNotNil(controller.lastFailure)
        processes.list = world
        controller.request()
        XCTAssertNil(controller.lastFailure)
        XCTAssertEqual(alerts, 1, "a good ask makes no sound")
        XCTAssertEqual(controller.state, .confirming)
        controller.turnOff()
        XCTAssertNil(controller.lastFailure, "and a session that came to an end does not bring it back")
    }

    func testAFailedAskIsSaidAgainWhenItFailsAgain() {
        processes.list = nil
        controller.request()
        controller.request()
        XCTAssertEqual(alerts, 2)
        XCTAssertNotNil(controller.lastFailure)
    }

    func testAnAskThatFailsAfterTheOwnerWentAwayMakesNoSound() {
        processes.list = world
        processes.hold = true
        controller.request()
        controller.turnOff()
        processes.list = nil
        processes.answerHeld()
        XCTAssertEqual(alerts, 0, "the owner had cancelled; a late answer is for nobody")
        XCTAssertNil(controller.lastFailure)
    }

    // ── A quit does not wait for ever, and does not call the display itself ─

    func testAQuitPutsTheScreenBackOnTheQueueAndWaitsForItWithinTwoSeconds() {
        start()
        controller.shutdown()
        XCTAssertEqual(waitedFor, [2])
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(watchdog.stopped, 1)
        XCTAssertNil(store.record)
        XCTAssertEqual(backlight.value, 0.8)
        XCTAssertEqual(rate.restored, 1)
        XCTAssertEqual(keyboard.sets.last, 0.6)
        XCTAssertEqual(power.restored, [0])
    }

    func testAQuitDoesTheContinuesAndTheLiftsBeforeItWaitsAndTheSettingsAfterwards() {
        start()
        calls.list = []
        controller.shutdown()
        // (The fake queue runs a job as it is given, so the settings come before the wait in this log; what must come after the wait
        // is the end of the record and of the watchdog.)
        assertAllBefore("resume", "brightness set")
        assertAllBefore("unthrottle", "brightness set")
        assertAllBefore("unhide", "brightness set")
        assertAllBefore("wait for work", "store clear")
        assertAllBefore("wait for work", "watchdog stop")
    }

    func testAQuitWhoseWaitRunsOutKeepsTheRecordAndTheWatchdogAndHasContinuedEverything() {
        start()
        holdWork = true
        calls.list = []
        controller.shutdown()
        XCTAssertEqual(waitedFor, [2])
        assertAllBefore("resume", "wait for work")
        XCTAssertEqual(freezer.resumes, [20, 21, 30])
        XCTAssertEqual(hider.unhidden, [20])
        XCTAssertNotNil(store.record, "the record stays: the watchdog and the next launch finish what was not put back")
        XCTAssertEqual(store.cleared, 0)
        XCTAssertEqual(watchdog.stopped, 0)
        XCTAssertEqual(backlight.value, 0.25, "the display was not called from here")
        XCTAssertEqual(rate.restored, 0)
        XCTAssertEqual(logged.filter { $0.contains("put back in time") }.count, 1, "\(logged)")
        XCTAssertEqual(backdrop.shown, false)
    }

    func testASettingsJobThatFinishesAfterTheQuitGaveUpFinishesTheJob() {
        // The logout was cancelled after the notice, so the app is still here when the queue gets round to it.
        start()
        holdWork = true
        controller.shutdown()
        XCTAssertNotNil(store.record)
        runHeldWork()
        XCTAssertEqual(backlight.value, 0.8)
        XCTAssertEqual(rate.restored, 1)
        XCTAssertNil(store.record)
        XCTAssertEqual(watchdog.stopped, 1)
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(power.restored, [0])
        XCTAssertEqual(freezer.resumes, [20, 21, 30], "and nothing is continued a second time")
    }

    func testAQuitWhenTheQueueIsBusyWithAJobInsideACallStillContinuesFirst() {
        startWithTheQueueJammedAfter(1)
        calls.list = []
        controller.shutdown()
        assertAllBefore("resume", "wait for work")
        XCTAssertEqual(controller.state, .confirming)
        XCTAssertNotNil(store.record)
        XCTAssertEqual(watchdog.stopped, 0)
    }

    // ── What the mode leaves alone: a reopened app, an activation by group, a recycled pid, the watchdog ─

    /// The browser quit (killed) and opened again since the start: a new app process, and a helper of it.
    private var worldWithTheBrowserReopened: [UltraProcess] {
        world.filter { ![20, 21].contains($0.pid) } + [
            proc(22, path: "/Applications/Browser.app/Contents/MacOS/Browser", app: .regular, bundle: "com.example.browser", name: "Browser"),
            helper(23, of: 22, in: "Browser")]
    }

    func testAFrozenAppThatWasQuitAndOpenedAgainIsReleasedAtTheSweepAndNotFrozenAgain() {
        start()
        processes.list = worldWithTheBrowserReopened
        fire(30)
        XCTAssertEqual(groupIDs(controller.frozen), ["com.example.sync"], "the browser is the owner's again")
        XCTAssertEqual(freezer.stops, [20, 21, 30], "neither the new app nor its new helper is stopped")
        XCTAssertEqual(freezer.resumes, [20, 21], "its old members are continued, as a release does")
        XCTAssertEqual(store.record?.groups.first { $0.id == "com.example.browser" }?.released, true)
        XCTAssertFalse(controller.isFrozen(pid: 22))
        XCTAssertFalse(controller.isFrozen(pid: 23))
        XCTAssertEqual(controller.releasedForLoad, [], "the owner did this, not the guard")
        XCTAssertTrue(logged.contains { $0.contains("Browser") && $0.contains("opened again") }, "\(logged)")
    }

    func testAReopenedAppIsKeptOnTheEfficiencyCoresInTheSameSweep() {
        start()
        processes.list = worldWithTheBrowserReopened
        fire(30)
        XCTAssertTrue(throttler.throttled.contains(22), "the new app is what keeps running now: \(throttler.throttled)")
        XCTAssertTrue(throttler.throttled.contains(23))
        XCTAssertEqual(namedThrottled?.contains(22), true, "named before it was slowed")
    }

    func testAReopenedAppIsNotLoadedAgainOrGuardedAsAFreezeStep() {
        start()
        processes.list = worldWithTheBrowserReopened
        let reads = load.reads
        fire(30)
        XCTAssertEqual(load.reads, reads, "nothing was stopped, so no 'before' reading")
    }

    func testANewHelperOfAFrozenAppThatWasNotReopenedIsStillStopped() {
        start()
        processes.list = world + [helper(22, of: 20, in: "Browser")]
        fire(30)
        XCTAssertEqual(freezer.stops, [20, 21, 30, 22])
        XCTAssertEqual(groupIDs(controller.frozen), ["com.example.browser", "com.example.sync"])
        XCTAssertEqual(freezer.resumes, [])
    }

    func testAReopenedAppAndANewHelperOfAnotherFrozenAppAreEachDealtWithAtTheSameSweep() {
        start()
        processes.list = worldWithTheBrowserReopened + [helper(32, of: 30, in: "Sync")]
        fire(30)
        XCTAssertEqual(groupIDs(controller.frozen), ["com.example.sync"])
        XCTAssertEqual(freezer.stops, [20, 21, 30, 32], "the sync agent's new part is stopped; the browser's is not")
    }

    func testActivationUnderANewPidReleasesTheGroupByItsBundleId() {
        start()
        controller.appActivated(pid: 22, bundleID: "com.example.browser")   // the reopened browser, which no list has seen
        XCTAssertEqual(groupIDs(controller.frozen), ["com.example.sync"])
        XCTAssertEqual(freezer.resumes, [20, 21])
        XCTAssertEqual(store.record?.groups.first { $0.id == "com.example.browser" }?.released, true)
    }

    func testActivationUnderAPidTheLastListPlacedInAFrozenGroupReleasesItWhateverThePid() {
        start()
        // 31 is an extension macOS hosts for the sync agent: in its group, never stopped, so not one of its members.
        XCTAssertFalse(controller.isFrozen(pid: 31))
        controller.appActivated(pid: 31)
        XCTAssertEqual(groupIDs(controller.frozen), ["com.example.browser"])
        XCTAssertEqual(freezer.resumes, [30])
    }

    func testActivationUnderAPidNobodyKnowsAndNoBundleIdReleasesNothing() {
        start()
        controller.appActivated(pid: 22)
        controller.appActivated(pid: 22, bundleID: "com.example.unrelated")
        controller.appActivated(pid: 10, bundleID: "com.example.editor")   // the kept editor: not frozen
        XCTAssertEqual(groupIDs(controller.frozen), ["com.example.browser", "com.example.sync"])
        XCTAssertEqual(freezer.resumes, [])
    }

    func testActivationIsPlacedWithTheLatestListTheSweepRead() {
        start()
        processes.list = world + [helper(22, of: 20, in: "Browser")]
        fire(30)        // 22 was stopped and is a member now; the next one is a part the sweep read but did not stop
        freezer.refuse = [24]
        processes.list = world + [helper(22, of: 20, in: "Browser"), helper(24, of: 30, in: "Sync")]
        fire(30)
        controller.appActivated(pid: 24)
        XCTAssertEqual(groupIDs(controller.frozen), ["com.example.browser"], "24 belongs to the sync agent, which is released")
    }

    func testAnAppWhosePidWasReusedSinceThePlanWasMadeIsNotHidden() {
        controller.request()
        recycled[20] = 999          // the box was up for minutes; the browser quit and another process took its pid
        confirm.press(true)
        XCTAssertEqual(hider.hidden, [], "an app that is not the one that was planned is not hidden")
        XCTAssertNil(store.record?.groups.first { $0.id == "com.example.browser" }?.appPID)
        XCTAssertEqual(controller.state, .on, "and the start goes on")
        XCTAssertTrue(logged.contains { $0.contains("not hidden") && $0.contains("20") }, "\(logged)")
        controller.turnOff()
        XCTAssertEqual(hider.unhidden, [], "only what Anode hid is ever unhidden")
    }

    func testAnAppThatIsGoneBeforeItWouldBeHiddenIsNotHidden() {
        controller.request()
        gone = [20]
        confirm.press(true)
        XCTAssertEqual(hider.hidden, [])
        XCTAssertEqual(controller.state, .on)
    }

    func testAnAppThatIsStillTheSameProcessIsHidden() {
        start()
        XCTAssertEqual(hider.hidden, [20])
        XCTAssertEqual(store.record?.groups.first { $0.id == "com.example.browser" }?.appPID, 20)
    }

    func testAWatchdogThatEndedIsStartedAgainAtTheNextSweepAndOnlyThen() {
        start()
        XCTAssertEqual(watchdog.started, 1)
        fire(30)
        XCTAssertEqual(watchdog.started, 1, "it is running: nothing to do")
        watchdog.pid = nil          // it died
        XCTAssertEqual(watchdog.started, 1, "nothing looks until the sweep does")
        fire(30)
        XCTAssertEqual(watchdog.started, 2)
        XCTAssertNotNil(watchdog.pid)
        XCTAssertEqual(logged.filter { $0.contains("watchdog") }.count, 1, "one line for the one restart: \(logged)")
        fire(30)
        XCTAssertEqual(watchdog.started, 2)
        XCTAssertEqual(logged.filter { $0.contains("watchdog") }.count, 1)
    }

    func testTheNewWatchdogIsAnodesOwnAndIsNeverStopped() {
        start()
        watchdog.pid = nil
        fire(30)                    // restarted, under a pid of its own
        guard let pid = watchdog.pid else { return XCTFail("no watchdog") }
        processes.list = world + [proc(pid, parent: 20, path: "/var/tmp/watchdog-copy")]
        fire(30)
        XCTAssertFalse(freezer.stops.contains(pid), "a child of a frozen app that is Anode's own watchdog is not frozen")
    }

    func testAWatchdogThatCannotBeStartedAgainIsSaidAndTheSessionGoesOn() {
        start()
        watchdog.pid = nil
        watchdog.startResult = false
        processes.list = world + [helper(22, of: 20, in: "Browser")]
        fire(30)
        XCTAssertEqual(watchdog.started, 2, "it was tried")
        XCTAssertTrue(logged.contains { $0.contains("watchdog") && $0.contains("could not") }, "\(logged)")
        XCTAssertEqual(controller.state, .on)
        XCTAssertTrue(freezer.stops.contains(22), "the sweep did the rest of its work")
        XCTAssertTrue(scheduled.contains { $0.delay == 30 }, "and goes on looking")
    }

    func testTheSweepOfAnEndedModeDoesNotLookAtTheWatchdog() {
        start()
        watchdog.pid = nil
        controller.turnOff()
        let started = watchdog.started
        controller.sweep()
        XCTAssertEqual(watchdog.started, started)
    }
}

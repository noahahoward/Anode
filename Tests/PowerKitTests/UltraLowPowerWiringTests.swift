import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The runtime that joins Ultra Low Power Mode to the app: nothing exists while the box is unticked, and what the mode
/// needs from the app (the shortcut, the front app, the readings, the icon, the power-off notice) is there exactly as long
/// as it is wanted. Every part is a fake from the controller's tests; the notification centres count their observers; no
/// timer, status item, queue, menu or setting of the real app is made or touched.
final class UltraLowPowerWiringTests: XCTestCase {

    typealias Fakes = UltraLowPowerControllerTests

    // ── Fakes ───────────────────────────────────────────────────────────────

    /// A notification centre that knows how many observers it holds, so "no observers" is something a test can read.
    final class CountingCenter: NotificationCenter, @unchecked Sendable {
        private(set) var observers = 0
        override func addObserver(forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?,
                                  using block: @escaping @Sendable (Notification) -> Void) -> NSObjectProtocol {
            observers += 1
            return super.addObserver(forName: name, object: obj, queue: queue, using: block)
        }
        override func removeObserver(_ observer: Any) {
            observers -= 1
            super.removeObserver(observer)
        }
    }

    final class FakeWidgets: UltraReadingHosting {
        var isPaused: () -> Bool = { false } { didSet { pausedSets += 1 } }
        var onPausedClick: ((NSStatusBarButton) -> Void)?
        var hasReadingsOnBar = true
        private(set) var pausedSets = 0
    }

    final class FakeIcon: UltraIconPresenting {
        private(set) var installed = false
        private(set) var installs = 0
        private(set) var removals = 0
        func install() { installed = true; installs += 1 }
        func remove() { installed = false; removals += 1 }
    }

    /// The queue for slow calls: runs a job at once, or keeps it until the test lets it go. Says when the runtime asks to
    /// wait for it, in the same log as the controller's fakes, so a test can say what came before what.
    final class FakeWork: UltraWorkRunning {
        let calls: Fakes.Calls
        var hold = false
        var idle = true
        private(set) var jobs = 0
        private(set) var held: [() -> Void] = []
        init(_ calls: Fakes.Calls) { self.calls = calls }
        func run(_ job: @escaping () -> Void) {
            jobs += 1
            if hold { held.append(job) } else { job() }
        }
        func waitUntilIdle(limit: TimeInterval) -> Bool {
            calls.add("wait for work \(limit)")
            return idle
        }
        func runHeld() {
            hold = false
            let waiting = held
            held = []
            waiting.forEach { $0() }
        }
    }

    final class FakeTicker {
        struct Running { let id: Int; let every: TimeInterval; let fire: () -> Void }
        private(set) var active: [Running] = []
        private(set) var started = 0
        func start(_ every: TimeInterval, _ fire: @escaping () -> Void) -> () -> Void {
            started += 1
            let id = started
            active.append(Running(id: id, every: every, fire: fire))
            return { [weak self] in self?.active.removeAll { $0.id == id } }
        }
    }

    final class Shortcut {
        var registered = false
        var fire: (() -> Void)?
        private(set) var registrations = 0
        func register(_ fire: @escaping () -> Void) { registered = true; registrations += 1; self.fire = fire }
        func unregister() { registered = false; fire = nil }
    }

    /// What the fake system says and what the runtime asked of it.
    final class Env {
        var frontmost: pid_t? = 10
        /// The windows on screen, front to back, and how many times they were read.
        var windows: [UltraWindow] = []
        private(set) var windowReads = 0
        func readWindows() -> [UltraWindow] { windowReads += 1; return windows }
        var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
        var logged: [String] = []
        var menus: [(menu: NSMenu, button: NSStatusBarButton)] = []
        var betaOpened = 0
        var alerts = 0
    }

    private struct Rig {
        let runtime: UltraLowPowerRuntime
        let settings: Settings
        let defaults: UserDefaults
        let suite: String
        let calls: Fakes.Calls
        let processes: Fakes.FakeProcesses
        let freezer: Fakes.FakeFreezer
        let backlight: Fakes.FakeBacklight
        let watchdog: Fakes.FakeWatchdog
        let store: Fakes.FakeStore
        let confirm: Fakes.FakeConfirm
        let widgets: FakeWidgets
        let icon: FakeIcon
        let work: FakeWork
        let ticker: FakeTicker
        let shortcut: Shortcut
        let workspace: CountingCenter
        let center: CountingCenter
        let env: Env
        var controller: UltraLowPowerController { runtime.controller }
    }

    // ── A made-up Mac ───────────────────────────────────────────────────────

    private static func proc(_ pid: pid_t, parent: pid_t = 1, uid: uid_t = 501, path: String, app: AppKind = .none,
                             bundle: String? = nil, name: String) -> UltraProcess {
        UltraProcess(pid: pid, parent: parent, uid: uid, startTime: UInt64(pid) * 10, path: path, app: app, bundleID: bundle,
                     name: name)
    }

    /// Anode (1000) and its watchdog (1001, a copy outside any app, so only its pid says whose it is); the editor (10) with
    /// its shell; a browser (20) with a helper; a sync agent (30); an app with a part that belongs to root (40, 41); a
    /// service of the system.
    private static let world: [UltraProcess] = [
        proc(1000, path: "/Applications/Anode.app/Contents/MacOS/Anode", app: .regular, bundle: "dev.example.self", name: "Anode"),
        proc(1001, path: "/var/tmp/watchdog-copy", name: "watchdog-copy"),
        proc(10, path: "/Applications/Editor.app/Contents/MacOS/Editor", app: .regular, bundle: "com.example.editor", name: "Editor"),
        proc(11, parent: 10, path: "/bin/zsh", name: "zsh"),
        proc(20, path: "/Applications/Browser.app/Contents/MacOS/Browser", app: .regular, bundle: "com.example.browser", name: "Browser"),
        proc(21, parent: 20, path: "/Applications/Browser.app/Contents/Frameworks/Browser Helper.app/Contents/MacOS/Browser Helper",
             name: "Browser Helper"),
        proc(30, path: "/Applications/Sync.app/Contents/MacOS/Sync", app: .accessory, bundle: "com.example.sync", name: "Sync"),
        proc(40, path: "/Applications/Cloud.app/Contents/MacOS/Cloud", app: .regular, bundle: "com.example.cloud", name: "Cloud"),
        proc(41, uid: 0, path: "/Applications/Cloud.app/Contents/Library/clouddaemon", name: "clouddaemon"),
        proc(50, path: "/usr/libexec/syslogd", name: "syslogd")]

    private func rig(ticked: Bool, leftover: UltraRecord? = nil) throws -> Rig {
        let (defaults, suite) = try TestDefaults.make(owner: "UltraLowPowerWiring", test: name)
        let settings = Settings(defaults: defaults)
        settings.ultraLowPowerEnabled = ticked
        let calls = Fakes.Calls()
        let processes = Fakes.FakeProcesses(Self.world)
        let freezer = Fakes.FakeFreezer(calls), backlight = Fakes.FakeBacklight(calls), watchdog = Fakes.FakeWatchdog(calls)
        watchdog.pid = 1001
        let store = Fakes.FakeStore(calls)
        store.record = leftover
        let confirm = Fakes.FakeConfirm()
        let widgets = FakeWidgets(), icon = FakeIcon(), work = FakeWork(calls), ticker = FakeTicker(), shortcut = Shortcut()
        let workspace = CountingCenter(), center = CountingCenter(), env = Env()
        let runtime = UltraLowPowerRuntime(
            settings: settings, processes: processes, freezer: freezer, throttler: Fakes.FakeThrottler(calls),
            processTable: { Self.world }, startTime: { UInt64($0) * 10 }, hasEfficiencyCores: true, hider: Fakes.FakeHider(calls), backlight: backlight,
            ownBrightness: OwnBrightness(), rate: Fakes.FakeRate(calls), keyboard: Fakes.FakeKeyboard(calls),
            power: Fakes.FakePower(calls), watchdog: watchdog, store: store, confirm: confirm,
            backdrop: Fakes.FakeBackdrop(calls), load: Fakes.FakeLoad(calls), widgets: widgets, icon: icon,
            presentMenu: { menu, button in env.menus.append((menu, button)) },
            openBetaFeatures: { env.betaOpened += 1 },
            registerShortcut: { fire in calls.add("shortcut register"); shortcut.register(fire) },
            unregisterShortcut: { calls.add("shortcut unregister"); shortcut.unregister() },
            work: work, startTicker: ticker.start,
            workspace: workspace, center: center, appPID: { $0.userInfo?["pid"] as? pid_t },
            appBundleID: { $0.userInfo?["bundle"] as? String },
            frontmostPID: { env.frontmost }, windows: { env.readWindows() }, ownPID: 1000, user: 501,
            log: { env.logged.append($0) },
            schedule: { delay, job in env.scheduled.append((delay, job)) },
            alert: { env.alerts += 1 })
        return Rig(runtime: runtime, settings: settings, defaults: defaults, suite: suite, calls: calls, processes: processes,
                   freezer: freezer, backlight: backlight, watchdog: watchdog, store: store, confirm: confirm, widgets: widgets,
                   icon: icon, work: work, ticker: ticker, shortcut: shortcut, workspace: workspace, center: center, env: env)
    }

    private func done(_ r: Rig) { r.runtime.shutdown(); TestDefaults.destroy(r.defaults, r.suite) }

    // ── Doing things ────────────────────────────────────────────────────────

    /// Asks for the mode and presses Confirm.
    private func start(_ r: Rig) {
        r.controller.request()
        r.confirm.press(true)
    }

    private func activate(_ pid: pid_t, bundle: String? = nil, in r: Rig) {
        var info: [String: Any] = ["pid": pid]
        if let bundle { info["bundle"] = bundle }
        r.workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil, userInfo: info)
    }

    private func powerOff(_ r: Rig) {
        r.workspace.post(name: NSWorkspace.willPowerOffNotification, object: nil)
    }

    private func barChanged(_ r: Rig) {
        r.center.post(name: MenuBarWidgetController.itemsDidRebuild, object: r.widgets)
    }

    private func index(of prefix: String, in r: Rig, last: Bool = false) -> Int? {
        last ? r.calls.list.lastIndex { $0.hasPrefix(prefix) } : r.calls.list.firstIndex { $0.hasPrefix(prefix) }
    }

    /// The first call that starts with `first` came before the first that starts with `then`.
    private func assertBefore(_ first: String, _ then: String, in r: Rig, file: StaticString = #filePath, line: UInt = #line) {
        guard let a = index(of: first, in: r), let b = index(of: then, in: r) else {
            return XCTFail("expected calls \"\(first)\" and \"\(then)\" in \(r.calls.list)", file: file, line: line)
        }
        XCTAssertLessThan(a, b, "\"\(first)\" must come before \"\(then)\": \(r.calls.list)", file: file, line: line)
    }

    private func titles(_ menu: NSMenu) -> [String] { menu.items.map { $0.isSeparatorItem ? "-" : $0.title } }

    /// What a click on a menu item does.
    private func fire(_ menu: NSMenu, titled title: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let item = menu.items.first(where: { $0.title == title }), let action = item.action else {
            return XCTFail("no item \"\(title)\" in \(titles(menu))", file: file, line: line)
        }
        _ = (item.target as? NSObject)?.perform(action)
    }

    // ── Unticked ────────────────────────────────────────────────────────────

    func testNothingExistsWhileUnticked() throws {
        let r = try rig(ticked: false); defer { done(r) }
        XCTAssertFalse(r.shortcut.registered)
        XCTAssertEqual(r.shortcut.registrations, 0)
        XCTAssertEqual(r.workspace.observers, 0, "no workspace observers")
        XCTAssertEqual(r.center.observers, 0)
        XCTAssertEqual(r.ticker.started, 0, "no timers")
        XCTAssertFalse(r.runtime.isWatchingBrightness)
        XCTAssertEqual(r.icon.installs, 0, "no status item")
        XCTAssertEqual(r.work.jobs, 0, "no queue work")
        XCTAssertEqual(r.processes.snapshots, 0)
        XCTAssertTrue(r.env.scheduled.isEmpty)
        XCTAssertEqual(r.widgets.pausedSets, 0, "the readings are left as they were")
        XCTAssertNil(r.widgets.onPausedClick)
        XCTAssertEqual(r.controller.state, .off)
        XCTAssertEqual(r.calls.list, [])
    }

    func testTickingRegistersTheShortcutAndNothingStarts() throws {
        let r = try rig(ticked: false); defer { done(r) }
        r.settings.ultraLowPowerEnabled = true
        XCTAssertTrue(r.shortcut.registered)
        XCTAssertEqual(r.controller.state, .off)
        XCTAssertEqual(r.ticker.started, 0, "nothing runs until the mode is on")
        XCTAssertEqual(r.icon.installs, 0)
        XCTAssertEqual(r.work.jobs, 0)
        XCTAssertEqual(r.processes.snapshots, 0)
        XCTAssertTrue(r.env.scheduled.isEmpty)
        XCTAssertEqual(r.center.observers, 0, "the bar is not watched while there is no icon to decide on")
        XCTAssertEqual(r.calls.list, ["shortcut register"], "no process, screen or helper is touched")
    }

    func testATickedBoxAtLaunchIsAvailableAtOnce() throws {
        let r = try rig(ticked: true); defer { done(r) }
        XCTAssertTrue(r.shortcut.registered)
        XCTAssertEqual(r.controller.state, .off)
    }

    func testUntickingRemovesWhatTickingAdded() throws {
        let r = try rig(ticked: false); defer { done(r) }
        r.settings.ultraLowPowerEnabled = true
        XCTAssertEqual(r.workspace.observers, 1, "the front app is tracked")
        XCTAssertEqual(r.widgets.pausedSets, 1)
        XCTAssertNotNil(r.widgets.onPausedClick)
        r.settings.ultraLowPowerEnabled = false
        XCTAssertFalse(r.shortcut.registered)
        XCTAssertEqual(r.workspace.observers, 0)
        XCTAssertEqual(r.center.observers, 0)
        XCTAssertNil(r.widgets.onPausedClick)
        XCTAssertFalse(r.widgets.isPaused())
        // And a second tick starts from nothing again.
        r.settings.ultraLowPowerEnabled = true
        XCTAssertTrue(r.shortcut.registered)
        XCTAssertEqual(r.workspace.observers, 1)
    }

    // ── The shortcut ────────────────────────────────────────────────────────

    func testTheShortcutAsksForTheMode() throws {
        let r = try rig(ticked: true); defer { done(r) }
        r.shortcut.fire?()
        XCTAssertEqual(r.controller.state, .confirming)
        XCTAssertEqual(r.confirm.keptNames.count, 1, "the box is asked")
        XCTAssertEqual(r.freezer.stops, [], "nothing is frozen before Confirm")
    }

    func testThePressedShortcutTurnsTheModeOffWhenOnAndIsIgnoredWhileTheBoxIsUp() throws {
        let r = try rig(ticked: true); defer { done(r) }
        r.shortcut.fire?()
        r.shortcut.fire?()
        XCTAssertEqual(r.confirm.keptNames.count, 1, "a second press does not ask again")
        r.confirm.press(true)
        XCTAssertEqual(r.controller.state, .on)
        r.shortcut.fire?()
        XCTAssertEqual(r.controller.state, .off)
        XCTAssertEqual(r.freezer.resumes.sorted(), [20, 21, 30])
    }

    // ── The front app ───────────────────────────────────────────────────────

    func testTheKeptAppIsTheLastFrontAppOtherThanAnode() throws {
        let r = try rig(ticked: true); defer { done(r) }
        r.env.frontmost = 1000   // Anode itself was in front when the box was ticked
        r.settings.ultraLowPowerEnabled = false
        r.settings.ultraLowPowerEnabled = true
        activate(30, in: r)
        activate(10, in: r)   // the editor
        activate(1000, in: r) // then Anode's own window
        r.shortcut.fire?()
        XCTAssertEqual(r.confirm.keptNames, [["Editor"]], "the editor is what was in front before Anode")
        XCTAssertEqual(r.confirm.frozenNames, [["Browser", "Sync"]])
    }

    func testTheAppInFrontWhenTheBoxIsTickedCountsUnlessItIsAnode() throws {
        let r = try rig(ticked: false); defer { done(r) }
        r.env.frontmost = 20
        r.settings.ultraLowPowerEnabled = true
        r.shortcut.fire?()
        XCTAssertEqual(r.confirm.keptNames, [["Browser"]])
        r.controller.turnOff()
        r.settings.ultraLowPowerEnabled = false
        r.env.frontmost = 1000
        r.settings.ultraLowPowerEnabled = true
        r.shortcut.fire?()
        XCTAssertEqual(r.confirm.keptNames.last, [], "Anode in front keeps nothing in particular, and the earlier app is forgotten")
    }

    func testTheWatchdogIsNeverTheAppThatWasInFront() throws {
        let r = try rig(ticked: true); defer { done(r) }
        activate(1001, in: r)   // the watchdog's pid: Anode's own
        r.shortcut.fire?()
        XCTAssertEqual(r.confirm.keptNames, [["Editor"]], "the earlier front app stays")
    }

    // ── The first Start, with Anode in front ────────────────────────────────

    private func window(_ pid: pid_t, layer: Int = 0, onScreen: Bool = true) -> UltraWindow {
        UltraWindow(ownerPID: pid, layer: layer, onScreen: onScreen)
    }

    func testTheAppBehindAnodesWindowIsTheOneToKeep() {
        let own: Set<pid_t> = [1000, 1001]
        XCTAssertEqual(UltraLowPowerRuntime.frontOtherApp(in: [window(1000), window(10)], excluding: own), 10,
                       "Anode's window in front and the editor's behind")
        XCTAssertEqual(UltraLowPowerRuntime.frontOtherApp(in: [window(10), window(1000), window(20)], excluding: own), 10,
                       "the frontmost of the others")
    }

    func testOnlyAnodesWindowsKeepNothing() {
        let own: Set<pid_t> = [1000, 1001]
        XCTAssertNil(UltraLowPowerRuntime.frontOtherApp(in: [window(1000), window(1000), window(1001)], excluding: own))
        XCTAssertNil(UltraLowPowerRuntime.frontOtherApp(in: [], excluding: own))
    }

    func testAPanelAboveTheOrdinaryWindowsIsSkipped() {
        let own: Set<pid_t> = [1000]
        // A menu, the Dock, a floating panel: not the layer of an app's window.
        XCTAssertEqual(UltraLowPowerRuntime.frontOtherApp(in: [window(30, layer: 25), window(20, layer: 3), window(1000),
                                                              window(10)], excluding: own), 10)
        XCTAssertNil(UltraLowPowerRuntime.frontOtherApp(in: [window(30, layer: 25), window(1000)], excluding: own))
        XCTAssertNil(UltraLowPowerRuntime.frontOtherApp(in: [window(20, layer: -1)], excluding: own),
                     "nor one below: the desktop")
    }

    func testAWindowThatIsNotOnScreenIsSkippedAndTheWatchdogIsAnodes() {
        let own: Set<pid_t> = [1000, 1001]
        XCTAssertEqual(UltraLowPowerRuntime.frontOtherApp(in: [window(20, onScreen: false), window(1001), window(10)],
                                                          excluding: own), 10)
    }

    func testTheFirstStartFromAnodesOwnWindowKeepsTheAppBehindIt() throws {
        let r = try rig(ticked: false); defer { done(r) }
        r.env.frontmost = 1000   // the box is ticked in Anode's own window
        r.env.windows = [window(1000), window(10), window(20)]
        r.settings.ultraLowPowerEnabled = true
        XCTAssertEqual(r.env.windowReads, 0, "not read at tick time")
        r.shortcut.fire?()
        XCTAssertEqual(r.confirm.keptNames, [["Editor"]], "the editor was behind Anode's window")
        XCTAssertEqual(r.env.windowReads, 1, "read once, when asked")
    }

    func testAnAppThatCameForwardIsKeptWhateverTheWindowsSay() throws {
        let r = try rig(ticked: false); defer { done(r) }
        r.env.frontmost = 1000
        r.env.windows = [window(1000), window(20)]   // the browser's window is the next one behind
        r.settings.ultraLowPowerEnabled = true
        activate(10, in: r)   // but the editor really came forward
        r.shortcut.fire?()
        XCTAssertEqual(r.confirm.keptNames, [["Editor"]])
        XCTAssertEqual(r.env.windowReads, 0, "the windows are not read when an activation is remembered")
    }

    func testWithNoWindowBehindAnodeNothingIsKept() throws {
        let r = try rig(ticked: false); defer { done(r) }
        r.env.frontmost = 1000
        r.env.windows = [window(1000)]
        r.settings.ultraLowPowerEnabled = true
        r.shortcut.fire?()
        XCTAssertEqual(r.confirm.keptNames, [[]])
    }

    func testThePickerKeepsTheSameAppTheFirstStartWould() throws {
        let r = try rig(ticked: false); defer { done(r) }
        r.env.frontmost = 1000
        r.env.windows = [window(1000), window(10)]
        r.settings.ultraLowPowerEnabled = true
        var answer: [String]?
        r.runtime.candidates { answer = $0.map(\.name) }
        XCTAssertEqual(answer, ["Editor", "Browser", "Sync", "Cloud"], "the editor is first: it is the one that is kept")
    }

    func testTheLiveReaderTakesThePidFromTheNotification() {
        let note = Notification(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                                userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        XCTAssertEqual(UltraLowPowerRuntime.liveAppPID(note), getpid())
        XCTAssertNil(UltraLowPowerRuntime.liveAppPID(Notification(name: NSWorkspace.didActivateApplicationNotification)))
    }

    // ── Turning off ─────────────────────────────────────────────────────────

    func testUntickingWhileOnTurnsTheModeOffFirst() throws {
        let r = try rig(ticked: true); defer { done(r) }
        start(r)
        XCTAssertEqual(r.controller.state, .on)
        r.settings.ultraLowPowerEnabled = false
        XCTAssertEqual(r.controller.state, .off)
        XCTAssertEqual(r.freezer.resumes.sorted(), [20, 21, 30], "everything is continued")
        XCTAssertEqual(r.store.cleared, 1)
        XCTAssertFalse(r.shortcut.registered)
        assertBefore("resume", "shortcut unregister", in: r)
        XCTAssertEqual(r.workspace.observers, 0)
        XCTAssertEqual(r.center.observers, 0)
        XCTAssertFalse(r.runtime.isWatchingBrightness)
        XCTAssertFalse(r.icon.installed)
    }

    func testUntickingWhileTheBoxIsUpDropsTheQuestion() throws {
        let r = try rig(ticked: true); defer { done(r) }
        r.shortcut.fire?()
        XCTAssertEqual(r.controller.state, .confirming)
        r.settings.ultraLowPowerEnabled = false
        XCTAssertEqual(r.controller.state, .off)
        r.confirm.press(true)   // the box was still on screen
        XCTAssertEqual(r.controller.state, .off, "a late Confirm starts nothing")
        XCTAssertEqual(r.freezer.stops, [])
    }

    /// The put-back of the screen is on the queue when the box is unticked: the session is still on until it has run, and the
    /// power-off notice is still heard for as long as that is so. The quit's own settings queue up behind it: the processes
    /// are continued at once, and the end is finished when the queue gets round to them.
    func testAPowerOffStillEndsASessionThatWasUntickedWhileItsPutBackWasQueued() throws {
        let r = try rig(ticked: true); defer { done(r) }
        start(r)
        r.work.hold = true
        r.work.idle = false
        r.settings.ultraLowPowerEnabled = false
        XCTAssertEqual(r.controller.state, .on, "the state stays until the settings are back")
        XCTAssertFalse(r.shortcut.registered)
        XCTAssertEqual(r.freezer.resumes.sorted(), [20, 21, 30])
        powerOff(r)
        XCTAssertEqual(r.controller.state, .on, "the quit's settings are behind the turn-off's, and the wait ran out")
        XCTAssertEqual(r.store.cleared, 0, "so the record is left for the watchdog")
        XCTAssertEqual(r.workspace.observers, 1, "and the notice is still heard")
        r.work.runHeld()
        XCTAssertEqual(r.controller.state, .off)
        XCTAssertEqual(r.store.cleared, 1, "the turn-off's put-back finds the session over and does nothing; the quit's finishes it")
        XCTAssertEqual(r.workspace.observers, 0)
    }

    func testPowerOffAndQuitEndTheSession() throws {
        let r = try rig(ticked: true); defer { done(r) }
        start(r)
        XCTAssertEqual(r.controller.state, .on)
        powerOff(r)
        XCTAssertEqual(r.controller.state, .off)
        XCTAssertEqual(r.freezer.resumes.sorted(), [20, 21, 30], "everything is resumed")
        XCTAssertEqual(r.watchdog.stopped, 1)
        XCTAssertEqual(r.store.cleared, 1)
        XCTAssertFalse(r.icon.installed)
        XCTAssertFalse(r.runtime.isWatchingBrightness)
        // AppKit then quits the app: the end that has happened is not done twice.
        let resumed = r.freezer.resumes.count
        r.runtime.shutdown()
        XCTAssertEqual(r.freezer.resumes.count, resumed)
        XCTAssertEqual(r.store.cleared, 1)
    }

    func testQuitEndsTheSessionToo() throws {
        let r = try rig(ticked: true); defer { done(r) }
        start(r)
        r.runtime.shutdown()
        XCTAssertEqual(r.controller.state, .off)
        XCTAssertEqual(r.freezer.resumes.sorted(), [20, 21, 30])
        XCTAssertEqual(r.store.cleared, 1)
        XCTAssertFalse(r.shortcut.registered)
        XCTAssertEqual(r.workspace.observers, 0)
        XCTAssertEqual(r.center.observers, 0)
        XCTAssertFalse(r.icon.installed)
        XCTAssertFalse(r.runtime.isWatchingBrightness)
    }

    /// A quit does the continues first, then gives the screen and the rest to the queue and waits for it once, for two seconds. A
    /// job already inside a display or keyboard call is not lowering something after the put-back: the queue is serial, so the
    /// put-back comes after it.
    func testPowerOffContinuesFirstThenWaitsForTheSettingsOnTheQueue() throws {
        let r = try rig(ticked: true); defer { done(r) }
        start(r)
        r.calls.list.removeAll()
        powerOff(r)
        XCTAssertEqual(r.calls.list.filter { $0.hasPrefix("wait for work") }, ["wait for work 2.0"], "\(r.calls.list)")
        assertBefore("resume", "wait for work", in: r)
        assertBefore("wait for work", "watchdog stop", in: r)
    }

    func testQuitContinuesFirstThenWaitsForTheSettingsOnTheQueue() throws {
        let r = try rig(ticked: true); defer { done(r) }
        start(r)
        r.calls.list.removeAll()
        r.runtime.shutdown()
        XCTAssertEqual(r.calls.list.filter { $0.hasPrefix("wait for work") }, ["wait for work 2.0"], "\(r.calls.list)")
        XCTAssertEqual(r.calls.list.first, "resume 20", "nothing waits before the processes are running again: \(r.calls.list)")
        assertBefore("resume", "wait for work", in: r)
        XCTAssertEqual(r.controller.state, .off)
    }

    func testAQueueThatDoesNotFinishInTimeIsSaidInTheLogAndTheRecordIsLeftForTheWatchdog() throws {
        let r = try rig(ticked: true); defer { done(r) }
        start(r)
        r.work.hold = true
        r.work.idle = false
        r.runtime.shutdown()
        XCTAssertEqual(r.freezer.resumes.sorted(), [20, 21, 30], "the processes were continued before the wait")
        XCTAssertNotEqual(r.controller.state, .off)
        XCTAssertEqual(r.store.cleared, 0)
        XCTAssertEqual(r.watchdog.stopped, 0)
        XCTAssertEqual(r.env.logged.filter { $0.contains("not put back in time") }.count, 1, "\(r.env.logged)")
    }

    /// A logout can be cancelled after the notice has been posted: the app goes on, and the owner can use the mode again.
    func testAPowerOffThatIsCancelledLeavesTheRuntimeWorking() throws {
        let r = try rig(ticked: true); defer { done(r) }
        start(r)
        powerOff(r)
        XCTAssertEqual(r.controller.state, .off)
        XCTAssertTrue(r.shortcut.registered, "the box is still ticked, so the shortcut still works")
        r.shortcut.fire?()
        XCTAssertEqual(r.controller.state, .confirming)
        r.confirm.press(true)
        XCTAssertEqual(r.controller.state, .on)
        XCTAssertTrue(r.runtime.isWatchingBrightness)
        r.settings.ultraLowPowerEnabled = false
        XCTAssertEqual(r.controller.state, .off, "and so does the box")
    }

    /// From Confirm until the mode is on the apps are already stopped (the record is saved and the watchdog started first), and
    /// turning Low Power Mode on may wait on the helper for seconds: a logout in that window is heard all the same.
    func testALogoutBetweenConfirmAndOnIsHeard() throws {
        let r = try rig(ticked: true); defer { done(r) }
        r.work.hold = true   // the screen's first call is on the queue and does not come back
        r.controller.request()
        r.confirm.press(true)
        XCTAssertEqual(r.controller.state, .confirming, "not on yet")
        XCTAssertFalse(r.freezer.stops.isEmpty, "but the apps are stopped")
        XCTAssertFalse(r.runtime.isWatchingBrightness, "the timer and the icon wait for the mode to be on")
        r.work.idle = false
        powerOff(r)
        XCTAssertFalse(r.freezer.resumes.isEmpty, "everything that was stopped is continued")
        XCTAssertEqual(r.controller.state, .confirming, "the screen is behind the queued call: the wait ran out")
        XCTAssertEqual(r.store.cleared, 0, "the record stays for the watchdog")
        r.work.runHeld()   // the queued call finds the session over; the quit's own settings finish the end
        XCTAssertEqual(r.controller.state, .off)
        XCTAssertEqual(r.store.cleared, 1)
        XCTAssertEqual(r.watchdog.stopped, 1)
        XCTAssertEqual(r.workspace.observers, 1, "only the front app is still tracked: the box is ticked")
    }

    func testThePowerOffNoticeIsHeardFromTheQuestionUntilTheModeIsOffAndNotBefore() throws {
        let r = try rig(ticked: true); defer { done(r) }
        XCTAssertEqual(r.workspace.observers, 1, "off: the front app only")
        r.controller.request()
        XCTAssertEqual(r.workspace.observers, 2, "asked: the notice too")
        r.confirm.press(false)
        XCTAssertEqual(r.workspace.observers, 1, "answered no: gone again")
        start(r)
        XCTAssertEqual(r.workspace.observers, 2)
        XCTAssertTrue(r.runtime.isWatchingBrightness)
        r.controller.turnOff()
        XCTAssertEqual(r.workspace.observers, 1)
    }

    func testShutdownRemovesEverythingAndStopsListening() throws {
        let r = try rig(ticked: true); defer { done(r) }
        r.runtime.shutdown()
        XCTAssertFalse(r.shortcut.registered)
        XCTAssertEqual(r.workspace.observers, 0)
        // It no longer listens to the box: ticking it again does nothing.
        r.settings.ultraLowPowerEnabled = false
        r.settings.ultraLowPowerEnabled = true
        XCTAssertFalse(r.shortcut.registered)
        XCTAssertEqual(r.workspace.observers, 0)
    }

    // ── Starting, cancelling and quitting ───────────────────────────────────

    func testUntickingTheBoxWhileTheBoxIsUpPutsTheBoxAway() throws {
        let r = try rig(ticked: true); defer { done(r) }
        r.controller.request()
        XCTAssertTrue(r.confirm.isUp)
        r.settings.ultraLowPowerEnabled = false
        XCTAssertFalse(r.confirm.isUp)
        XCTAssertEqual(r.confirm.dismissals, 1)
        XCTAssertEqual(r.controller.state, .off)
    }

    /// The readings' menu and the icon's menu carry Cancel while the start is running.
    func testTheMenuOffersCancelWhileTheStartIsRunning() throws {
        let r = try rig(ticked: true); defer { done(r) }
        r.work.hold = true
        start(r)
        XCTAssertTrue(r.controller.isStarting)
        let menu = r.runtime.menu()
        XCTAssertEqual(menu.items.map(\.title), ["Cancel"])
        XCTAssertTrue(menu.items[0].isEnabled)
        _ = (menu.items[0].target as? NSObject)?.perform(menu.items[0].action!)
        XCTAssertFalse(r.controller.isStarting)
        r.work.runHeld()
        XCTAssertEqual(r.controller.state, .off)
    }

    func testTheStartedMenuStillOffersTurnOff() throws {
        let r = try rig(ticked: true); defer { done(r) }
        start(r)
        XCTAssertEqual(r.controller.state, .on)
        XCTAssertEqual(r.runtime.menu().items.first?.title, "Turn off")
    }

    func testAListOfAppsThatCannotBeReadMakesTheOneSoundAndStartsNothing() throws {
        let r = try rig(ticked: true); defer { done(r) }
        r.processes.list = nil
        r.controller.request()
        XCTAssertEqual(r.env.alerts, 1)
        XCTAssertEqual(r.controller.lastFailure, "Anode could not read the running apps. Try again.")
        XCTAssertEqual(r.controller.state, .off)
    }

    // ── While on ────────────────────────────────────────────────────────────

    func testActivationOfAFrozenAppReleasesIt() throws {
        let r = try rig(ticked: true); defer { done(r) }
        start(r)
        XCTAssertEqual(r.controller.frozen.map(\.id), ["com.example.browser", "com.example.sync"])
        activate(20, in: r)   // the browser comes forward (its Dock icon)
        XCTAssertEqual(r.controller.frozen.map(\.id), ["com.example.sync"])
        XCTAssertEqual(r.freezer.resumes, [20, 21], "its parts are continued")
        activate(1000, in: r)
        activate(10, in: r)   // the editor was never frozen
        XCTAssertEqual(r.controller.frozen.map(\.id), ["com.example.sync"])
    }

    /// The app was quit and opened again: its new pid is in no list yet, and the notification's bundle id is what names its group.
    func testActivationOfAnAppUnderANewPidReleasesItsFrozenGroupByTheBundleIdTheNotificationCarries() throws {
        let r = try rig(ticked: true); defer { done(r) }
        start(r)
        activate(22, in: r)
        XCTAssertEqual(r.controller.frozen.map(\.id), ["com.example.browser", "com.example.sync"], "a pid nobody knows, and no bundle id")
        activate(22, bundle: "com.example.browser", in: r)
        XCTAssertEqual(r.controller.frozen.map(\.id), ["com.example.sync"])
        XCTAssertEqual(r.freezer.resumes, [20, 21])
    }

    func testTheSweepAndBrightnessWatchRunOnlyWhileOn() throws {
        let r = try rig(ticked: true); defer { done(r) }
        // Off, and then only asked: nothing.
        XCTAssertTrue(r.ticker.active.isEmpty)
        XCTAssertTrue(r.env.scheduled.isEmpty)
        r.controller.request()
        XCTAssertTrue(r.ticker.active.isEmpty, "a question is not the mode")
        r.confirm.press(true)
        XCTAssertEqual(r.controller.state, .on)

        // On: the watch every 2 seconds, and the sweep every 30.
        XCTAssertEqual(r.ticker.active.map(\.every), [2])
        XCTAssertTrue(r.runtime.isWatchingBrightness)
        let sweep = try XCTUnwrap(r.env.scheduled.first { $0.delay == 30 }, "\(r.env.scheduled.map(\.delay))")
        let snapshots = r.processes.snapshots
        sweep.work()
        XCTAssertEqual(r.processes.snapshots, snapshots + 1, "the sweep looked at the processes")

        let reads = r.calls.list.filter { $0 == "brightness read" }.count
        r.ticker.active[0].fire()
        XCTAssertEqual(r.calls.list.filter { $0 == "brightness read" }.count, reads + 1, "each tick looks at the brightness")

        // Off: both stop. A sweep that was already waiting finds the mode over and does nothing.
        let pending = r.env.scheduled.last { $0.delay == 30 }
        r.controller.turnOff()
        XCTAssertTrue(r.ticker.active.isEmpty)
        XCTAssertFalse(r.runtime.isWatchingBrightness)
        let after = r.processes.snapshots
        pending?.work()
        XCTAssertEqual(r.processes.snapshots, after)
    }

    func testTheBrightnessIsHeldAtTheCeilingWhenAPullBackIsAsked() throws {
        let r = try rig(ticked: true); defer { done(r) }
        r.backlight.value = 0.9
        start(r)
        XCTAssertEqual(r.backlight.value, 0.25)
        r.backlight.value = 0.8   // a key press
        r.ticker.active[0].fire()
        XCTAssertEqual(r.backlight.value, 0.25, "pulled back by the watch")
    }

    // ── The readings and the icon ───────────────────────────────────────────

    func testEveryReadingSaysPausedWhileOnAndItsClickOpensTheMenu() throws {
        let r = try rig(ticked: true); defer { done(r) }
        UltraLowPowerController.current = r.controller
        addTeardownBlock { UltraLowPowerController.current = nil }
        XCTAssertFalse(r.widgets.isPaused(), "not while it is off")
        start(r)
        XCTAssertTrue(r.widgets.isPaused(), "for as long as the mode is on")
        let click = try XCTUnwrap(r.widgets.onPausedClick)
        let button = NSStatusBarButton()
        click(button)
        let shown = try XCTUnwrap(r.env.menus.first)
        XCTAssertTrue(shown.button === button, "the menu opens under the reading that was clicked")
        XCTAssertEqual(titles(shown.menu), ["Turn off", "-", "Frozen (click to bring back):", "Browser", "Sync",
                                            "Left running: Cloud (it has a part Anode cannot freeze).", "-", "Open Beta Features\u{2026}"])
    }

    func testTheMenuReleasesAGroupOpensTheSettingsAndTurnsTheModeOff() throws {
        let r = try rig(ticked: true); defer { done(r) }
        start(r)
        r.widgets.onPausedClick?(NSStatusBarButton())
        fire(r.env.menus[0].menu, titled: "Browser")
        XCTAssertEqual(r.controller.frozen.map(\.id), ["com.example.sync"])
        r.widgets.onPausedClick?(NSStatusBarButton())
        XCTAssertEqual(titles(r.env.menus[1].menu), ["Turn off", "-", "Frozen (click to bring back):", "Sync",
                                                     "Left running: Cloud (it has a part Anode cannot freeze).", "-",
                                                     "Open Beta Features\u{2026}"])
        fire(r.env.menus[1].menu, titled: "Open Beta Features\u{2026}")
        XCTAssertEqual(r.env.betaOpened, 1)
        fire(r.env.menus[1].menu, titled: "Turn off")
        XCTAssertEqual(r.controller.state, .off)
    }

    func testTheMenuStillNamesAGroupThatWasLetGo() throws {
        let r = try rig(ticked: true); defer { done(r) }
        start(r)
        XCTAssertEqual(r.runtime.groupNames["com.example.browser"], "Browser")
        r.controller.release(groupID: "com.example.browser")
        XCTAssertEqual(r.runtime.groupNames["com.example.browser"], "Browser", "it is not frozen any more, and still has its name")
        r.controller.turnOff()
        XCTAssertEqual(r.runtime.groupNames, [:], "names are for one session")
    }

    func testTheIconAppearsOnlyWhenNoReadingIsOnTheBar() throws {
        let r = try rig(ticked: true); defer { done(r) }
        // A reading on the bar: no icon.
        r.widgets.hasReadingsOnBar = true
        start(r)
        XCTAssertFalse(r.icon.installed)
        XCTAssertEqual(r.center.observers, 1, "the bar is watched while the mode is on")
        // The readings are folded away (or switched off): the icon takes their place.
        r.widgets.hasReadingsOnBar = false
        barChanged(r)
        XCTAssertTrue(r.icon.installed)
        // They come back: the icon goes.
        r.widgets.hasReadingsOnBar = true
        barChanged(r)
        XCTAssertFalse(r.icon.installed)
        XCTAssertEqual(r.icon.installs, 1)
        // And a bar with none, then the mode off: the icon goes with it.
        r.widgets.hasReadingsOnBar = false
        barChanged(r)
        XCTAssertTrue(r.icon.installed)
        r.controller.turnOff()
        XCTAssertFalse(r.icon.installed)
        XCTAssertEqual(r.center.observers, 0)
        // Off, the bar changing means nothing.
        barChanged(r)
        XCTAssertFalse(r.icon.installed)
    }

    func testTheIconIsThereAtOnceOnABarWithNoReadingsAndNeverWhileOff() throws {
        let r = try rig(ticked: true); defer { done(r) }
        r.widgets.hasReadingsOnBar = false
        XCTAssertFalse(r.icon.installed, "off")
        r.controller.request()
        XCTAssertFalse(r.icon.installed, "only asking")
        r.confirm.press(true)
        XCTAssertTrue(r.icon.installed)
        XCTAssertEqual(r.icon.installs, 1, "each change is acted on once")
        r.controller.release(groupID: "com.example.sync")
        XCTAssertEqual(r.icon.installs, 1)
    }

    func testOnlyTheWidgetControllerThatWasGivenCanChangeTheIcon() throws {
        let r = try rig(ticked: true); defer { done(r) }
        r.widgets.hasReadingsOnBar = true
        start(r)
        r.widgets.hasReadingsOnBar = false
        r.center.post(name: MenuBarWidgetController.itemsDidRebuild, object: FakeWidgets())
        XCTAssertFalse(r.icon.installed, "another widget controller's rebuild says nothing about this bar")
        barChanged(r)
        XCTAssertTrue(r.icon.installed)
    }

    // ── Launch ──────────────────────────────────────────────────────────────

    private var leftover: UltraRecord {
        var record = UltraRecord()
        record.groups = [UltraRecord.Group(id: "com.example.browser", name: "Browser",
                                           members: [UltraRecord.Member(pid: 20, startTime: 200)])]
        record.brightnessBefore = 0.8
        return record
    }

    func testLaunchRecoversALeftoverRecord() throws {
        let r = try rig(ticked: false, leftover: leftover); defer { done(r) }
        XCTAssertEqual(r.freezer.resumes, [20], "what the record names is continued")
        XCTAssertEqual(r.store.cleared, 1)
        XCTAssertNil(r.store.record)
        XCTAssertEqual(r.controller.state, .off)
    }

    /// A record left by a crash is undone even when the owner has unticked the box since.
    func testALeftoverRecordIsUndoneWithTheBoxUntickedAndStillNothingElseExists() throws {
        let r = try rig(ticked: false, leftover: leftover); defer { done(r) }
        XCTAssertEqual(r.store.cleared, 1)
        XCTAssertFalse(r.shortcut.registered)
        XCTAssertEqual(r.workspace.observers, 0)
        XCTAssertEqual(r.ticker.started, 0)
        XCTAssertEqual(r.icon.installs, 0)
    }

    func testLaunchRecoversBeforeAnythingElseOfTheFeature() throws {
        let r = try rig(ticked: true, leftover: leftover); defer { done(r) }
        assertBefore("resume", "shortcut register", in: r)
        XCTAssertTrue(r.shortcut.registered)
    }

    func testWithNoLeftoverRecordLaunchDoesNotTouchTheMac() throws {
        let r = try rig(ticked: true); defer { done(r) }
        XCTAssertEqual(r.freezer.resumes, [])
        XCTAssertEqual(r.store.cleared, 0)
        XCTAssertEqual(r.calls.list, ["shortcut register"])
    }

    // ── The section ─────────────────────────────────────────────────────────

    func testTheCandidatesAreEveryGroupTheModeKnowsOf() throws {
        let r = try rig(ticked: true); defer { done(r) }
        r.settings.ultraLowPowerAlwaysKeep = ["com.example.sync"]
        activate(10, in: r)
        var answer: [String]?
        r.runtime.candidates { answer = $0.map(\.name) }
        // Kept (the editor in front, the app the owner keeps), then frozen, then left running whole. Not Anode, not its
        // watchdog, not the system.
        XCTAssertEqual(answer, ["Editor", "Sync", "Browser", "Cloud"])
    }

    func testNoCandidatesWhenTheProcessesCannotBeRead() throws {
        let r = try rig(ticked: true); defer { done(r) }
        r.processes.list = nil
        var answer: [String]?
        r.runtime.candidates { answer = $0.map(\.name) }
        XCTAssertEqual(answer, [])
    }

    func testTheBetaSectionAsksTheRuntimeThatIsThereWhenItAsks() throws {
        let r = try rig(ticked: true); defer { done(r) }
        let sectionSettings = try throwawaySettings(owner: "UltraLowPowerWiringSection", test: name)
        let list = BetaFeaturesWindowController.defaultFeatures(hasLidSensor: false, settings: sectionSettings)
        let section = try XCTUnwrap(list.first { $0 is UltraLowPowerFeature } as? UltraLowPowerFeature)
        // Built before any runtime existed: it answers nothing, and then looks the runtime up each time it is asked.
        section.refresh()
        XCTAssertEqual(section.addChoices, [])
        XCTAssertEqual(r.processes.snapshots, 0)
        UltraLowPowerRuntime.current = r.runtime
        addTeardownBlock { UltraLowPowerRuntime.current = nil }
        activate(10, in: r)
        section.refresh()
        XCTAssertEqual(r.processes.snapshots, 1)
        XCTAssertEqual(section.addChoices, ["Editor", "Browser", "Sync", "Cloud"], "every running group the owner has not added yet")
    }

    func testShutdownLetsGoOfTheStatics() throws {
        let r = try rig(ticked: true); defer { done(r) }
        UltraLowPowerController.current = r.controller
        UltraLowPowerRuntime.current = r.runtime
        addTeardownBlock { UltraLowPowerController.current = nil; UltraLowPowerRuntime.current = nil }
        r.runtime.shutdown()
        XCTAssertNil(UltraLowPowerController.current)
        XCTAssertNil(UltraLowPowerRuntime.current)
    }

    func testShutdownLeavesAnotherRuntimesStaticsAlone() throws {
        let r = try rig(ticked: true); defer { done(r) }
        let other = try rig(ticked: false); defer { done(other) }
        UltraLowPowerController.current = other.controller
        UltraLowPowerRuntime.current = other.runtime
        addTeardownBlock { UltraLowPowerController.current = nil; UltraLowPowerRuntime.current = nil }
        r.runtime.shutdown()
        XCTAssertTrue(UltraLowPowerController.current === other.controller)
        XCTAssertTrue(UltraLowPowerRuntime.current === other.runtime)
    }

    // ── The work queue ──────────────────────────────────────────────────────

    private final class Seen { var list: [Int] = [] }

    func testTheWorkQueueRunsJobsOneAfterAnotherAndTheWaitReturnsWhenTheyAreDone() {
        let queue = UltraWorkQueue()
        let seen = Seen()
        queue.run { Thread.sleep(forTimeInterval: 0.05); seen.list.append(1) }
        queue.run { seen.list.append(2) }
        XCTAssertTrue(queue.waitUntilIdle(limit: 5))
        XCTAssertEqual(seen.list, [1, 2], "in the order they were given, and finished when the wait returned")
    }

    func testTheWaitGivesUpAtItsLimitAndDoesNotCancelTheJob() {
        let queue = UltraWorkQueue()
        let release = DispatchSemaphore(value: 0)
        let seen = Seen()
        queue.run { release.wait(); seen.list.append(1) }
        XCTAssertFalse(queue.waitUntilIdle(limit: 0.05), "a job that is still inside a call is not waited for for ever")
        release.signal()
        XCTAssertTrue(queue.waitUntilIdle(limit: 5))
        XCTAssertEqual(seen.list, [1])
    }

    // ── What the app hands it ───────────────────────────────────────────────

    /// The real widget controller is what the app hands the runtime. Switched off, nothing is on its bar, and no status item
    /// is made to find that out.
    func testTheWidgetControllerHostsTheHooksAndSaysWhenNothingIsOnTheBar() throws {
        let (defaults, suite) = try TestDefaults.make(owner: "UltraLowPowerWiringWidgets", test: name)
        addTeardownBlock { TestDefaults.destroy(defaults, suite) }
        let controller = MenuBarWidgetController(onClick: { _ in }, defaults: defaults, enabled: false)
        let host: UltraReadingHosting = controller
        XCTAssertFalse(host.hasReadingsOnBar)
        XCTAssertFalse(controller.isPaused())
        host.isPaused = { true }
        XCTAssertTrue(controller.isPaused(), "what the runtime sets is what the readings ask")
    }

    func testTheRecordIsAFileInAnodesSupportFolder() {
        let url = UltraLowPowerRuntime.recordURL
        XCTAssertEqual(url.lastPathComponent, "ultra-session.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Anode")
        XCTAssertTrue(url.path.contains("Application Support"), url.path)
    }

    /// `live()` is not made in a test, so what it connects is read from its text: a connection dropped or swapped there
    /// would leave every other test passing and the feature dead in the app.
    func testLiveHandsTheControllerTheRealPartsAndOneRecordFile() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AnodeApp/UltraLowPowerRuntime.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "static func live("))
        let end = try XCTUnwrap(source.range(of: "static var recordURL"))
        // The code of the function: comments taken out, white space made one space.
        let body = source[start.lowerBound..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        for needed in ["workspace: NSWorkspace.shared.notificationCenter",   // the front app and the power-off notice
                       "center: .default",                                    // the bar's rebuilds
                       "ownBrightness: OwnBrightness.shared",                 // shared with Keep Awake, which holds the screen too
                       "UltraLowPowerController.current = runtime.controller",
                       "UltraLowPowerRuntime.current = runtime",
                       "icon.onClick =",
                       "KeybindCenter.shared.register(owner: shortcutOwner, commands: ShortcutCommands.ultra)",
                       "KeybindCenter.shared.unregister(owner: shortcutOwner)",
                       "widgets: widgets, icon: icon",
                       "backdrop: LiveUltraBackdrop()",                       // the black desktop behind the windows
                       "UltraConfirmPanel(screenText: {",                     // the box says what will happen
                       "backdrop: Settings.shared.ultraLowPowerBlackBackdrop",
                       "efficiencyCores: Settings.shared.ultraLowPowerEfficiencyCores, hasEfficiencyCores: LiveProcessThrottler.hasEfficiencyCores",
                       "throttler: LiveProcessThrottler()",                   // what still runs is kept on the efficiency cores
                       "processTable: LiveProcessList.processTable",          // and its children are found when it is lifted
                       "hasEfficiencyCores: LiveProcessThrottler.hasEfficiencyCores",
                       "windows: liveWindows"] {
            XCTAssertTrue(body.contains(needed), "live() no longer has: \(needed)")
        }
        // The controller and the confirm box are each told whether this Mac has efficiency cores: the box must not say the cores
        // are used on a Mac that has none, and the controller must not say it skipped a part the box named.
        XCTAssertEqual(body.components(separatedBy: "hasEfficiencyCores: LiveProcessThrottler.hasEfficiencyCores").count - 1, 2)
        // One file for the record: the store reads and writes it, and the watchdog is told where it is.
        XCTAssertEqual(body.components(separatedBy: "let url = recordURL").count - 1, 1)
        XCTAssertTrue(body.contains("UltraRecordFile(url: url)"), "the store is on the record's url")
        XCTAssertTrue(body.contains("LiveUltraWatchdog(recordURL: url"), "the watchdog is given the same url")
    }

    /// The watchdog is the one that lifts the policy when Anode dies, and it is never run in a test, so its call is read from its
    /// text: a throttler left out of it would leave every kept app on the efficiency cores for good after a crash.
    func testTheWatchdogsRealUndoLiftsThePolicyThroughTheRealThrottler() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AnodeApp/UltraWatchdog.swift"), encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let call = try XCTUnwrap(code.range(of: "undo(from: UltraRecordFile("), "the watchdog undoes from the record file")
        let rest = code[call.lowerBound...]
        let end = try XCTUnwrap(rest.range(of: "exit(0)"))
        let text = rest[..<end.lowerBound]
        XCTAssertTrue(text.contains("freezer: LiveProcessFreezer()"), "\(text)")
        XCTAssertTrue(text.contains("throttler: LiveProcessThrottler()"), "\(text)")
        XCTAssertTrue(text.contains("processTable: LiveProcessList.processTable"), "its own read of the process table: \(text)")
    }

    func testMainWiresTheRuntimeAndShutsItDown() throws {
        let main = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AnodeApp/main.swift"), encoding: .utf8)
        let create = try XCTUnwrap(main.range(of: "UltraLowPowerRuntime.live(widgets:"), "the runtime is made")
        let keepAwake = try XCTUnwrap(main.range(of: "keepAwake = KeepAwakeController()"))
        XCTAssertLessThan(keepAwake.lowerBound, create.lowerBound,
                          "after the lid dimmer's own recovery, which Keep Awake does when it is made")
        let terminate = try XCTUnwrap(main.range(of: "func applicationWillTerminate"))
        let stop = try XCTUnwrap(main.range(of: "ultraLowPower?.shutdown()"))
        let cleanExit = try XCTUnwrap(main.range(of: "RunTrace.cleanExit()"))
        let teardown = try XCTUnwrap(main.range(of: "fansPane.teardown()"))
        XCTAssertLessThan(terminate.lowerBound, stop.lowerBound)
        XCTAssertLessThan(stop.lowerBound, cleanExit.lowerBound, "before the rest of the app tears down")
        XCTAssertLessThan(stop.lowerBound, teardown.lowerBound, "before the helper link is let go")
    }
}

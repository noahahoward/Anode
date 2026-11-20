import XCTest
@testable import AnodeApp
@testable import PowerKit

// Fakes for Memory Watch's app side, shared with the section's tests in this target.

/// A notification centre that only counts what it is asked. Authorization answers are given at once.
final class FakeLeakNotifier: LeakNotifying {
    var status: LeakAuthorization = .authorized
    /// What the person answers when asked.
    var answer: LeakAuthorization = .authorized
    var statusCalls = 0
    var requestCalls = 0
    var posted: [Finding] = []
    var removedKeys: [String] = []
    var removeAllCalls = 0
    var installs = 0
    var removals = 0
    private(set) var onOpen: ((String) -> Void)?

    /// Every call of any kind.
    var totalCalls: Int { statusCalls + requestCalls + posted.count + removedKeys.count + removeAllCalls + installs + removals }

    func authorizationStatus(completion: @escaping (LeakAuthorization) -> Void) {
        statusCalls += 1
        completion(status)
    }
    func requestAuthorization(completion: @escaping (LeakAuthorization) -> Void) {
        requestCalls += 1
        status = answer
        completion(answer)
    }
    func post(_ finding: Finding) { posted.append(finding) }
    func removeDelivered(forKey key: String) { removedKeys.append(key) }
    func removeAllDelivered() { removeAllCalls += 1 }
    func installDelegate(onOpen: @escaping (String) -> Void) { installs += 1; self.onOpen = onOpen }
    func removeDelegate() { removals += 1; onOpen = nil }
}

/// A diagnostic window that only records what it is told.
final class FakeLeakWindow: MemoryWatchWindowing {
    var onClose: (() -> Void)?
    var shows = 0
    var closes = 0
    var updates: [Finding] = []
    var live: [MemorySample] = []
    func show() { shows += 1 }
    func update(with finding: Finding) { updates.append(finding) }
    func appendLive(_ sample: MemorySample) { live.append(sample) }
    var histories: [[MemorySample]] = []
    func setHistory(_ samples: [MemorySample]) { histories.append(samples) }
    func close() { closes += 1 }
}

/// A watch that only records what it is told.
final class FakeLeakWatch: MemoryWatching {
    var onFinding: (Finding) -> Void = { _ in }
    var onLivePoint: ((ProcessKey, MemorySample) -> Void)?
    var pinned: Set<ProcessKey> = []
    var live: Set<ProcessKey> = []
    var ignored: [String] = []
    var ingests = 0
    var probes = 0
    /// One `setModes` call.
    struct Modes: Equatable {
        var leaks: Bool
        var pressure: Bool
    }
    /// Every `setModes` call, in order.
    var modes: [Modes] = []
    /// What the tick would read the system for; set by `setModes`, or directly by a test.
    var watchesPressure = false
    /// Every system reading handed over (nil: the Mac could not be read).
    var systemReadings: [SystemMemoryReading?] = []
    /// The order of the tick's calls: "ingest", "probe", "system".
    var order: [String] = []
    func ingest(sweep: ProcessSampler.Sweep, awake: TimeInterval) { ingests += 1; order.append("ingest") }
    func probe(awake: TimeInterval, wall: Date) { probes += 1; order.append("probe") }
    func setModes(leaks: Bool, pressure: Bool) {
        modes.append(Modes(leaks: leaks, pressure: pressure))
        watchesPressure = pressure
    }
    func ingestSystem(_ reading: SystemMemoryReading?, awake: TimeInterval, wall: Date) {
        systemReadings.append(reading)
        order.append("system")
    }
    func pin(_ key: ProcessKey) { pinned.insert(key) }
    func unpin(_ key: ProcessKey) { pinned.remove(key) }
    func setLive(_ keys: Set<ProcessKey>) { live = keys }
    func ignore(identityKey: String) { ignored.append(identityKey) }
    var recorded: [ProcessKey: [MemorySample]] = [:]
    func samples(of key: ProcessKey) -> [MemorySample] { recorded[key] ?? [] }
}

/// A finding for tests: an app by its bundle path, or a tool by its executable path.
func makeLeakFinding(_ name: String = "Safari", app: Bool = true, pid: pid_t = 100, start: UInt64 = 1,
                     notify: Bool = true, at wall: Date = Date(timeIntervalSince1970: 1_000_000)) -> Finding {
    let identity = app ? "/Applications/\(name).app" : "/usr/local/bin/\(name)"
    let executable = app ? identity + "/Contents/MacOS/\(name)" : identity
    return Finding(processKey: ProcessKey(pid: pid, startAbsTime: start), pid: pid, name: name, path: executable,
                   identityKey: identity, isApp: app, startBytes: 200 << 20, nowBytes: 300 << 20, netGrowthBytes: 100 << 20,
                   windowSeconds: 64, bucketSeconds: 16, flaggedAtWall: wall, flaggedAtAwake: 1000,
                   risingSamples: 30, totalSamples: 32, largestDipBytes: 0, history: [], shouldNotify: notify)
}

/// A low-memory finding for tests: the same app as `makeLeakFinding`, with the whole Mac's numbers (12 of 16 GB in use, 3 GB
/// of swap) and the rule that fired.
func makePressureFinding(_ name: String = "Chrome", app: Bool = true, pid: pid_t = 100, start: UInt64 = 1,
                         notify: Bool = true, at wall: Date = Date(timeIntervalSince1970: 1_000_000)) -> Finding {
    var finding = makeLeakFinding(name, app: app, pid: pid, start: start, notify: notify, at: wall)
    finding.tier = .pressure
    finding.reason = .oneAppDominates
    finding.system = SystemMemoryReading(totalBytes: 16 << 30, usedBytes: 12 << 30, swapUsedBytes: 3 << 30, pressureLevel: 2)
    return finding
}

/// The controller on fakes: the notification centre, the windows, the watch and both queues (they run at once). Nothing
/// here reaches the real notification centre, a real window, the real settings or a real process.
final class MemoryWatchControllerTests: XCTestCase {

    private final class WeakWatch { weak var watch: FakeLeakWatch?; init(_ w: FakeLeakWatch) { watch = w } }

    private final class Rig {
        let settings: Settings
        let notifier = FakeLeakNotifier()
        /// What the sampling tick holds (the app's `leakWatch`).
        var attached: MemoryWatching?
        var madeWatches = 0
        /// Weak, so a test can tell whether the controller let go.
        var weakWatches: [WeakWatch] = []
        var windows: [FakeLeakWindow] = []
        var windowKeys: [String] = []
        var forwards = 0
        var controller: MemoryWatchController!

        init(settings: Settings, sandboxed: Bool) {
            self.settings = settings
            controller = MemoryWatchController(
                settings: settings, notifier: notifier,
                makeWatch: { [unowned self] in
                    let watch = FakeLeakWatch()
                    self.madeWatches += 1
                    self.weakWatches.append(WeakWatch(watch))
                    return watch
                },
                onSampling: { $0() },
                attach: { [unowned self] in self.attached = $0 },
                makeWindow: { [unowned self] finding in
                    let window = FakeLeakWindow()
                    self.windows.append(window)
                    self.windowKeys.append(finding.windowKey)
                    return window
                },
                isSandboxed: { sandboxed },
                bringForward: { [unowned self] in self.forwards += 1 },
                onMain: { $0() })
        }

        /// The newest watch the controller made, if it still holds it.
        var latest: FakeLeakWatch? { weakWatches.last?.watch }
        var latestIsGone: Bool { weakWatches.last.map { $0.watch == nil } ?? true }
    }

    /// `tag` tells apart the second rig of one test: the same test name is the same throwaway store.
    private func rig(enabled: Bool = false, pressure: Bool = false, sandboxed: Bool = false, tag: String = "") throws -> Rig {
        let settings = try throwawaySettings(owner: "MemoryWatchController", test: name + tag)
        if enabled { settings.memoryWatchEnabled = true }
        if pressure { settings.memoryWatchPressureWarning = true }
        return Rig(settings: settings, sandboxed: sandboxed)
    }

    // ── Off ─────────────────────────────────────────────────────────────────

    func testOffBuildsNothingAndCallsNoOne() throws {
        let r = try rig()
        XCTAssertFalse(r.controller.isEnabled)
        XCTAssertEqual(r.madeWatches, 0, "no watch, so no rings and no tables")
        XCTAssertNil(r.attached, "and the sampling tick has nothing to feed")
        XCTAssertEqual(r.notifier.totalCalls, 0, "the notification centre is not touched, delegate included")
        // Everything the app could still ask of it does nothing.
        r.controller.refreshAuthorization()
        r.controller.requestAuthorization()
        r.controller.handle(finding: makeLeakFinding())
        r.controller.open(windowKey: "/Applications/Safari.app")
        XCTAssertEqual(r.notifier.totalCalls, 0)
        XCTAssertTrue(r.controller.findings.isEmpty)
        XCTAssertTrue(r.windows.isEmpty)
        XCTAssertEqual(r.forwards, 0)
        XCTAssertNil(r.controller.authorization)
    }

    // ── On ──────────────────────────────────────────────────────────────────

    func testEnablingBuildsTheWatchAndInstallsTheDelegate() throws {
        let r = try rig()
        r.settings.memoryWatchEnabled = true
        XCTAssertTrue(r.controller.isEnabled)
        XCTAssertEqual(r.madeWatches, 1)
        XCTAssertNotNil(r.attached, "the sampling tick feeds it")
        XCTAssertEqual(r.notifier.installs, 1)
        XCTAssertEqual(r.notifier.statusCalls, 1, "the status is read")
        XCTAssertEqual(r.notifier.requestCalls, 0, "and macOS is not asked: only the box being ticked in the section asks")
        XCTAssertEqual(r.controller.authorization, .authorized)
    }

    func testLeftOnAtLaunchItIsBuiltAndTheDelegateIsSetButNothingIsAsked() throws {
        let r = try rig(enabled: true)
        XCTAssertEqual(r.madeWatches, 1)
        XCTAssertEqual(r.notifier.installs, 1, "a click on a banner that launched Anode must be delivered")
        XCTAssertEqual(r.notifier.requestCalls, 0)
    }

    func testTurningItOnTwiceBuildsOnce() throws {
        let r = try rig(enabled: true)
        r.settings.memoryWatchIgnoredApps = ["/x"]       // another setting changing is not a reason to rebuild
        r.settings.memoryWatchEnabled = true
        XCTAssertEqual(r.madeWatches, 1)
        XCTAssertEqual(r.notifier.installs, 1)
    }

    // ── Off again ───────────────────────────────────────────────────────────

    func testDisablingReleasesTheWatchAndCleansUp() throws {
        let r = try rig(enabled: true)
        r.controller.handle(finding: makeLeakFinding())
        r.controller.open(windowKey: "/Applications/Safari.app")
        let window = try XCTUnwrap(r.windows.first)
        XCTAssertFalse(r.latestIsGone)

        r.settings.memoryWatchEnabled = false

        XCTAssertTrue(r.latestIsGone, "nothing holds the watch any more: its tables and rings are freed")
        XCTAssertNil(r.attached, "the sampling tick let go of it")
        XCTAssertEqual(r.notifier.removeAllCalls, 1, "delivered banners are taken away")
        XCTAssertEqual(r.notifier.removals, 1, "the delegate is cleared")
        XCTAssertEqual(window.closes, 1, "the window closes")
        XCTAssertNil(window.onClose, "and cannot reach back into a watch that is gone")
        XCTAssertTrue(r.controller.findings.isEmpty)
        XCTAssertTrue(r.controller.openWindowKeys.isEmpty)
        XCTAssertNil(r.controller.authorization)
    }

    func testAFindingThatArrivesAfterTurningOffIsDropped() throws {
        let r = try rig(enabled: true)
        r.settings.memoryWatchEnabled = false
        let calls = r.notifier.totalCalls
        r.controller.handle(finding: makeLeakFinding())
        XCTAssertTrue(r.controller.findings.isEmpty)
        XCTAssertEqual(r.notifier.totalCalls, calls, "no banner for a feature that is off")
    }

    func testOnOffOnBuildsAFreshWatch() throws {
        let r = try rig(enabled: true)
        r.settings.memoryWatchEnabled = false
        r.settings.memoryWatchEnabled = true
        XCTAssertEqual(r.madeWatches, 2)
        XCTAssertEqual(r.notifier.installs, 2)
        XCTAssertNotNil(r.attached)
    }

    func testShutdownClosesTheWindowsAndLeavesTheBannersAlone() throws {
        let r = try rig(enabled: true)
        r.controller.handle(finding: makeLeakFinding())
        r.controller.open(windowKey: "/Applications/Safari.app")
        r.controller.shutdown()
        XCTAssertEqual(r.windows.first?.closes, 1)
        XCTAssertEqual(r.notifier.removeAllCalls, 0, "a banner still on screen can be clicked after the next launch")
        r.settings.memoryWatchEnabled = false       // the token is gone: the controller no longer follows the setting
        XCTAssertEqual(r.notifier.removals, 0)
    }

    // ── Findings and banners ────────────────────────────────────────────────

    func testTheListKeepsTheLastTenNewestFirst() throws {
        let r = try rig(enabled: true)
        for pid in 1...12 { r.controller.handle(finding: makeLeakFinding("node", app: false, pid: pid_t(pid))) }
        XCTAssertEqual(r.controller.findings.count, 10)
        XCTAssertEqual(r.controller.findings.first?.pid, 12)
        XCTAssertEqual(r.controller.findings.last?.pid, 3)
    }

    func testAFindingThatShouldNotNotifyIsListedAndNotPosted() throws {
        let r = try rig(enabled: true)
        r.controller.handle(finding: makeLeakFinding(notify: false))
        XCTAssertEqual(r.controller.findings.count, 1)
        XCTAssertTrue(r.notifier.posted.isEmpty)
    }

    func testAFindingThatShouldNotifyIsPostedWhenAllowed() throws {
        let r = try rig(enabled: true)
        let finding = makeLeakFinding()
        r.controller.handle(finding: finding)
        XCTAssertEqual(r.notifier.posted, [finding])
    }

    func testNotPostedWhenNotAllowedButStillListed() throws {
        for status in [LeakAuthorization.denied, .notDetermined] {
            let r = try rig(enabled: true, tag: "\(status)")
            r.notifier.status = status
            r.controller.handle(finding: makeLeakFinding())
            XCTAssertTrue(r.notifier.posted.isEmpty, "\(status): no banner macOS would not show")
            XCTAssertEqual(r.controller.findings.count, 1, "\(status): but it is in the list")
            XCTAssertEqual(r.controller.authorization, status)
        }
    }

    func testPermissionGivenLaterIsNoticedAtTheNextFinding() throws {
        let r = try rig(enabled: true)
        r.notifier.status = .denied
        r.controller.handle(finding: makeLeakFinding("Safari", pid: 1))
        r.notifier.status = .authorized          // switched on in System Settings, with no refresh in between
        r.controller.handle(finding: makeLeakFinding("Mail", pid: 2))
        XCTAssertEqual(r.notifier.posted.map(\.name), ["Mail"])
    }


    // ── The two boxes ───────────────────────────────────────────────────────

    func testOnlyTheLowMemoryBoxBuildsTheWatchAndSendsItsMode() throws {
        let r = try rig(pressure: true)
        XCTAssertTrue(r.controller.isEnabled, "either box is enough")
        XCTAssertEqual(r.madeWatches, 1)
        XCTAssertEqual(r.latest?.modes, [FakeLeakWatch.Modes(leaks: false, pressure: true)])
        XCTAssertEqual(r.notifier.installs, 1, "the delegate is installed")
        XCTAssertEqual(r.notifier.requestCalls, 0, "and nothing is asked until the box is ticked in the section")

        let finding = makePressureFinding()
        r.controller.handle(finding: finding)
        XCTAssertEqual(r.controller.findings, [finding])
        XCTAssertEqual(r.notifier.posted, [finding])
        XCTAssertEqual(r.notifier.posted.first?.notificationTitle, "Memory is running low", "the title of its own kind")
    }

    func testTickingTheLowMemoryBoxLaterBuildsTheWatch() throws {
        let r = try rig()
        XCTAssertEqual(r.madeWatches, 0)
        r.settings.memoryWatchPressureWarning = true
        XCTAssertTrue(r.controller.isEnabled)
        XCTAssertEqual(r.madeWatches, 1)
        XCTAssertEqual(r.latest?.modes, [FakeLeakWatch.Modes(leaks: false, pressure: true)])
        XCTAssertNotNil(r.attached)
        XCTAssertEqual(r.notifier.installs, 1)
    }

    func testOnlyTheLeakBoxSendsLeaksAndNotPressure() throws {
        let r = try rig(enabled: true)
        XCTAssertEqual(r.latest?.modes, [FakeLeakWatch.Modes(leaks: true, pressure: false)])
        XCTAssertEqual(r.latest?.watchesPressure, false, "so the tick reads nothing of the system's memory")
    }

    func testBothBoxesBuildOneWatchWithBothModes() throws {
        let r = try rig(enabled: true, pressure: true)
        XCTAssertEqual(r.madeWatches, 1)
        XCTAssertEqual(r.latest?.modes, [FakeLeakWatch.Modes(leaks: true, pressure: true)])
        XCTAssertEqual(r.notifier.installs, 1)
    }

    func testTickingTheSecondBoxTellsTheSameWatchAndDoesNotRebuildIt() throws {
        let r = try rig(enabled: true)
        let first = try XCTUnwrap(r.latest)
        r.settings.memoryWatchPressureWarning = true
        XCTAssertEqual(r.madeWatches, 1, "one watch serves both")
        XCTAssertTrue(r.attached === first)
        XCTAssertEqual(first.modes, [FakeLeakWatch.Modes(leaks: true, pressure: false), FakeLeakWatch.Modes(leaks: true, pressure: true)])
        XCTAssertEqual(r.notifier.installs, 1)
        XCTAssertEqual(r.notifier.removeAllCalls, 0)
    }

    func testUntickingOneBoxWhileTheOtherStaysOnNeitherRebuildsNorTearsDown() throws {
        // The low-memory box goes, the leak box stays.
        let r = try rig(enabled: true, pressure: true)
        let leakFinding = makeLeakFinding()
        r.controller.handle(finding: leakFinding)
        r.controller.open(windowKey: leakFinding.windowKey)
        let first = try XCTUnwrap(r.latest)
        r.settings.memoryWatchPressureWarning = false
        XCTAssertEqual(r.madeWatches, 1)
        XCTAssertTrue(r.attached === first)
        XCTAssertEqual(first.modes.last, FakeLeakWatch.Modes(leaks: true, pressure: false))
        XCTAssertFalse(first.watchesPressure)
        XCTAssertTrue(r.controller.isEnabled)
        XCTAssertEqual(r.notifier.removeAllCalls, 0, "no delivered banner is taken away")
        XCTAssertEqual(r.notifier.removals, 0, "the delegate stays")
        XCTAssertEqual(r.windows.first?.closes, 0, "the window stays open")
        XCTAssertEqual(r.controller.findings, [leakFinding])

        // The leak box goes, the low-memory box stays.
        let other = try rig(enabled: true, pressure: true, tag: "Other")
        let second = try XCTUnwrap(other.latest)
        other.settings.memoryWatchEnabled = false
        XCTAssertEqual(other.madeWatches, 1)
        XCTAssertTrue(other.attached === second)
        XCTAssertEqual(second.modes.last, FakeLeakWatch.Modes(leaks: false, pressure: true))
        XCTAssertTrue(other.controller.isEnabled)
        XCTAssertEqual(other.notifier.removeAllCalls, 0)
        XCTAssertEqual(other.notifier.removals, 0)
    }

    func testUntickingBothReleasesEverythingAndClearsTheBanners() throws {
        let r = try rig(enabled: true, pressure: true)
        let finding = makePressureFinding()
        r.controller.handle(finding: finding)
        r.controller.open(windowKey: finding.windowKey)
        let window = try XCTUnwrap(r.windows.first)
        XCTAssertFalse(r.latestIsGone)

        r.settings.memoryWatchEnabled = false
        XCTAssertFalse(r.latestIsGone, "one box is still ticked")
        r.settings.memoryWatchPressureWarning = false

        XCTAssertTrue(r.latestIsGone, "nothing holds the watch any more")
        XCTAssertNil(r.attached, "the sampling tick let go of it")
        XCTAssertEqual(r.notifier.removeAllCalls, 1, "delivered banners are taken away")
        XCTAssertEqual(r.notifier.removals, 1, "the delegate is cleared")
        XCTAssertEqual(window.closes, 1)
        XCTAssertNil(window.onClose)
        XCTAssertTrue(r.controller.findings.isEmpty)
        XCTAssertTrue(r.controller.openWindowKeys.isEmpty)
        XCTAssertFalse(r.controller.isEnabled)
        XCTAssertNil(r.controller.authorization)
    }

    func testAFindingOfAKindWhoseBoxIsOffIsDropped() throws {
        let leaksOnly = try rig(enabled: true)
        leaksOnly.controller.handle(finding: makePressureFinding())
        XCTAssertTrue(leaksOnly.controller.findings.isEmpty, "a hop that landed after the low-memory box was unticked")
        XCTAssertTrue(leaksOnly.notifier.posted.isEmpty)

        let pressureOnly = try rig(pressure: true, tag: "Pressure")
        pressureOnly.controller.handle(finding: makeLeakFinding())
        XCTAssertTrue(pressureOnly.controller.findings.isEmpty)
        XCTAssertTrue(pressureOnly.notifier.posted.isEmpty)
    }

    func testBothKindsShareTheListTheCapAndTheWindows() throws {
        let r = try rig(enabled: true, pressure: true)
        r.controller.handle(finding: makeLeakFinding("Safari", pid: 1))
        r.controller.handle(finding: makePressureFinding("Chrome", pid: 2))
        XCTAssertEqual(r.controller.findings.map(\.tier), [.pressure, .fast])
        XCTAssertEqual(r.notifier.posted.map(\.name), ["Safari", "Chrome"])

        // A window for a low-memory finding is keyed as a leak's is.
        r.notifier.onOpen?("/Applications/Chrome.app")
        XCTAssertEqual(r.windowKeys, ["/Applications/Chrome.app"])
        XCTAssertEqual(r.latest?.pinned, [ProcessKey(pid: 2, startAbsTime: 1)])

        for pid in 10...25 { r.controller.handle(finding: makePressureFinding("node", app: false, pid: pid_t(pid))) }
        XCTAssertEqual(r.controller.findings.count, MemoryWatchController.maxFindings)
    }

    func testAPressureFindingThatShouldNotNotifyIsListedAndNotPosted() throws {
        let r = try rig(pressure: true)
        r.controller.handle(finding: makePressureFinding(notify: false))
        XCTAssertEqual(r.controller.findings.count, 1)
        XCTAssertTrue(r.notifier.posted.isEmpty)
    }

    func testEitherBoxMayAskForPermissionAndItIsAskedOnce() throws {
        let r = try rig(pressure: true)
        r.notifier.status = .notDetermined
        r.notifier.answer = .authorized
        r.controller.requestAuthorization()
        r.controller.requestAuthorization()
        XCTAssertEqual(r.notifier.requestCalls, 1)
        XCTAssertEqual(r.controller.authorization, .authorized)

        let sandboxed = try rig(pressure: true, sandboxed: true, tag: "Sandboxed")
        sandboxed.notifier.status = .notDetermined
        sandboxed.controller.requestAuthorization()
        XCTAssertEqual(sandboxed.notifier.requestCalls, 0, "never in the install-test copy")
    }

    func testAFreshWatchKeepsBothModes() throws {
        let r = try rig(enabled: true, pressure: true)
        r.controller.removeIgnored(identityKey: "/Applications/Other.app")
        XCTAssertEqual(r.madeWatches, 2)
        XCTAssertEqual(r.latest?.modes, [FakeLeakWatch.Modes(leaks: true, pressure: true)], "a rebuilt watch is told what it is for")
    }

    // ── Windows ─────────────────────────────────────────────────────────────

    func testAClickOpensTheRightWindowAndASecondClickReusesIt() throws {
        let r = try rig(enabled: true)
        r.controller.handle(finding: makeLeakFinding("Safari", pid: 1))
        r.controller.handle(finding: makeLeakFinding("Chrome", pid: 2))
        let onOpen = try XCTUnwrap(r.notifier.onOpen, "the delegate has somewhere to send a click")

        onOpen("/Applications/Safari.app")
        XCTAssertEqual(r.windowKeys, ["/Applications/Safari.app"])
        XCTAssertEqual(r.windows[0].shows, 1)
        XCTAssertEqual(r.notifier.removedKeys, ["/Applications/Safari.app"], "its banner is cleared")

        onOpen("/Applications/Safari.app")
        XCTAssertEqual(r.windows.count, 1, "the same window")
        XCTAssertEqual(r.windows[0].shows, 2)

        onOpen("/Applications/Chrome.app")
        XCTAssertEqual(r.windows.count, 2)
        XCTAssertEqual(r.windowKeys.last, "/Applications/Chrome.app")
        XCTAssertEqual(r.windows[1].shows, 1)
    }

    func testAToolIsKeyedByItsProcessNotItsName() throws {
        let r = try rig(enabled: true)
        r.controller.handle(finding: makeLeakFinding("node", app: false, pid: 55, start: 9))
        r.controller.handle(finding: makeLeakFinding("node", app: false, pid: 56, start: 3))
        XCTAssertEqual(makeLeakFinding("node", app: false, pid: 55, start: 9).windowKey, "55:9")
        r.controller.open(windowKey: "55:9")
        r.controller.open(windowKey: "56:3")
        XCTAssertEqual(r.windowKeys, ["55:9", "56:3"], "two tools called node are two windows")
        XCTAssertEqual(r.latest?.pinned, [ProcessKey(pid: 55, startAbsTime: 9), ProcessKey(pid: 56, startAbsTime: 3)])
    }

    func testAKeyWithNothingBehindItBringsAnodeForwardAndNothingElse() throws {
        let r = try rig(enabled: true)
        r.controller.open(windowKey: "/Applications/Gone.app")      // a banner from before a relaunch
        XCTAssertEqual(r.forwards, 1)
        XCTAssertTrue(r.windows.isEmpty)
    }

    func testOpeningAWindowPinsTheProcessAndStartsTheLiveFeed() throws {
        let r = try rig(enabled: true)
        let finding = makeLeakFinding()
        r.controller.handle(finding: finding)
        XCTAssertNil(r.latest?.onLivePoint, "no window: nothing is relayed")
        XCTAssertEqual(r.latest?.live, [])

        r.controller.open(windowKey: finding.windowKey)
        XCTAssertEqual(r.latest?.pinned, [finding.processKey])
        XCTAssertEqual(r.latest?.live, [finding.processKey])
        let relay = try XCTUnwrap(r.latest?.onLivePoint)

        relay(finding.processKey, MemorySample(seconds: 5, bytes: 123))
        XCTAssertEqual(r.windows[0].live, [MemorySample(seconds: 5, bytes: 123)])
        relay(ProcessKey(pid: 999, startAbsTime: 1), MemorySample(seconds: 6, bytes: 1))
        XCTAssertEqual(r.windows[0].live.count, 1, "a point for a process no window follows goes nowhere")
    }

    /// A window opened minutes after the finding showed a gap between the finding's history and its first live point. The
    /// watch's own record since then is handed to the window when it opens.
    func testOpeningAWindowHandsItWhatTheWatchRecordedSinceTheFinding() throws {
        let r = try rig(enabled: true)
        let finding = makeLeakFinding()
        r.controller.handle(finding: finding)
        let since = [MemorySample(seconds: 50, bytes: 100), MemorySample(seconds: 58, bytes: 200)]
        r.latest?.recorded[finding.processKey] = since
        r.controller.open(windowKey: finding.windowKey)
        XCTAssertEqual(r.windows[0].histories, [since])
    }

    /// A watch that has let the process go has nothing to add; the window keeps what the finding carried.
    func testAnEmptyRecordIsNotHandedOver() throws {
        let r = try rig(enabled: true)
        let finding = makeLeakFinding()
        r.controller.handle(finding: finding)
        r.controller.open(windowKey: finding.windowKey)
        XCTAssertEqual(r.windows[0].histories.flatMap { $0 }.count, 0)
    }

    func testClosingTheWindowUnpinsAndStopsTheFeed() throws {
        let r = try rig(enabled: true)
        let finding = makeLeakFinding()
        r.controller.handle(finding: finding)
        r.controller.open(windowKey: finding.windowKey)
        let window = r.windows[0]

        window.onClose?()

        XCTAssertEqual(r.latest?.pinned, [])
        XCTAssertEqual(r.latest?.live, [])
        XCTAssertNil(r.latest?.onLivePoint)
        XCTAssertTrue(r.controller.openWindowKeys.isEmpty)
        // The same app opens a new window afterwards.
        r.controller.open(windowKey: finding.windowKey)
        XCTAssertEqual(r.windows.count, 2)
    }

    func testTheLivePointOfAClosedWindowGoesNowhere() throws {
        let r = try rig(enabled: true)
        let finding = makeLeakFinding()
        r.controller.handle(finding: finding)
        r.controller.livePointArrived(finding.processKey, MemorySample(seconds: 1, bytes: 1))
        XCTAssertTrue(r.windows.isEmpty, "no window is opened by a point, and there is none to receive it")
    }

    func testANewerFindingOfTheSameAppUpdatesItsWindowAndFollowsTheNewProcess() throws {
        let r = try rig(enabled: true)
        let first = makeLeakFinding("Chrome", pid: 1)
        let second = makeLeakFinding("Chrome", pid: 2)
        r.controller.handle(finding: first)
        r.controller.open(windowKey: first.windowKey)
        r.controller.handle(finding: second)
        XCTAssertEqual(r.windows[0].updates, [second])
        XCTAssertEqual(r.latest?.pinned, [first.processKey, second.processKey])
        XCTAssertEqual(r.latest?.live, [first.processKey, second.processKey])
    }

    // ── The ignore list ─────────────────────────────────────────────────────

    func testIgnoringWritesTheSettingAndInformsTheWatch() throws {
        let r = try rig(enabled: true)
        r.controller.handle(finding: makeLeakFinding("Safari", pid: 1))
        r.controller.handle(finding: makeLeakFinding("Mail", pid: 2))
        r.controller.ignore(identityKey: "/Applications/Safari.app")
        r.controller.ignore(identityKey: "/Applications/Safari.app")
        XCTAssertEqual(r.settings.memoryWatchIgnoredApps, ["/Applications/Safari.app"], "once")
        XCTAssertEqual(r.latest?.ignored, ["/Applications/Safari.app", "/Applications/Safari.app"])
        XCTAssertEqual(r.controller.findings.map(\.name), ["Mail"], "its findings leave the list")
    }

    func testRemovingAnIgnoredAppWarnsAboutItAgainWithAFreshWatch() throws {
        let r = try rig(enabled: true)
        r.controller.ignore(identityKey: "/Applications/Safari.app")
        r.controller.ignore(identityKey: "/Applications/Mail.app")
        r.controller.removeIgnored(identityKey: "/Applications/Safari.app")
        XCTAssertEqual(r.settings.memoryWatchIgnoredApps, ["/Applications/Mail.app"])
        XCTAssertEqual(r.madeWatches, 2, "a watch forgets what it was told this session only by being made again")
        XCTAssertTrue(r.attached === r.latest)
    }

    func testAFreshWatchIsGivenTheOpenWindowsPins() throws {
        let r = try rig(enabled: true)
        let finding = makeLeakFinding()
        r.controller.handle(finding: finding)
        r.controller.open(windowKey: finding.windowKey)
        r.controller.removeIgnored(identityKey: "/Applications/Other.app")
        XCTAssertEqual(r.madeWatches, 2)
        XCTAssertEqual(r.latest?.pinned, [finding.processKey])
        XCTAssertEqual(r.latest?.live, [finding.processKey])
        XCTAssertNotNil(r.latest?.onLivePoint)
    }

    // ── Asking macOS ────────────────────────────────────────────────────────

    func testTheQuestionIsAskedOnlyWhenNotYetAsked() throws {
        let r = try rig(enabled: true)
        r.notifier.status = .notDetermined
        r.notifier.answer = .authorized
        r.controller.requestAuthorization()
        XCTAssertEqual(r.notifier.requestCalls, 1)
        XCTAssertEqual(r.controller.authorization, .authorized)

        r.controller.requestAuthorization()         // already answered
        XCTAssertEqual(r.notifier.requestCalls, 1)

        let denied = try rig(enabled: true, tag: "Denied")
        denied.notifier.status = .denied
        denied.controller.requestAuthorization()
        XCTAssertEqual(denied.notifier.requestCalls, 0, "a no is not asked again: the section points at System Settings")
        XCTAssertEqual(denied.controller.authorization, .denied)
    }

    func testTheInstallTestCopyNeverAsksMacOSForAnything() throws {
        let r = try rig(enabled: true, sandboxed: true)
        r.notifier.status = .notDetermined
        r.controller.requestAuthorization()
        r.controller.refreshAuthorization()
        r.controller.handle(finding: makeLeakFinding())
        XCTAssertEqual(r.notifier.requestCalls, 0, "never a question in the test copy")
        XCTAssertEqual(r.notifier.statusCalls, 0, "and it does not even read the person's answer")
        XCTAssertTrue(r.notifier.posted.isEmpty)
        XCTAssertEqual(r.controller.findings.count, 1, "the finding is still listed")
    }

    func testTheStatusIsAnnouncedOnlyWhenItChanges() throws {
        let r = try rig(enabled: true)
        var posts = 0
        let observer = NotificationCenter.default.addObserver(forName: MemoryWatchController.didChange, object: r.controller,
                                                              queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        r.controller.refreshAuthorization()
        r.controller.refreshAuthorization()
        XCTAssertEqual(posts, 0, "the answer was already known, and it did not change: no change to announce, no loop")
        r.notifier.status = .denied
        r.controller.refreshAuthorization()
        XCTAssertEqual(posts, 1)
    }
}

import XCTest
@testable import AnodeApp
@testable import PowerKit

/// How Memory Watch is joined to the app: the one call the sampling tick makes, that nothing of it has a clock of its own,
/// that the notification framework is reached from one file only, and that none of it exists while the setting is off.
/// Mostly source assertions, as `MenuBarHiderWiringTests` and `GameModeSamplingTests` make them: they read the files and
/// run nothing.
final class MemoryWatchWiringTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The text with comments taken out (a comment says what is not done) and string literals blanked.
    private func code(_ path: String) throws -> String {
        NoSharedSettingsInTestsTests.codeOnly(try source(path), keepStrings: false)
    }

    /// The files that are Memory Watch's own and run on the app's behalf. Listed, not found by a pattern: the diagnostic
    /// window (`MemoryWatchWindow.swift`) has its own redraw and one-shot checks and is read by its own tests.
    private let ownFiles = ["Sources/AnodeApp/LeakNotifier.swift",
                            "Sources/AnodeApp/MemoryWatchController.swift",
                            "Sources/AnodeApp/MemoryWatchRuntime.swift",
                            "Sources/AnodeApp/MemoryWatchFeature.swift",
                            "Sources/PowerKit/MemoryWatch.swift",
                            "Sources/PowerKit/MemoryGrowth.swift"]

    // ── The sampling tick ───────────────────────────────────────────────────

    func testTheSamplingTickMakesExactlyOneCallAndItIsAfterTheMonitorTicks() throws {
        let main = try code("Sources/AnodeApp/main.swift")
        XCTAssertEqual(main.components(separatedBy: "MemoryWatchHook.feed(").count - 1, 1, "one call site")
        XCTAssertFalse(main.contains(".ingest(sweep"), "the tick does not talk to the watch itself")
        XCTAssertFalse(main.contains(".probe(awake"))
        let submit = try XCTUnwrap(main.range(of: "sampleGate.submit(on: sampling)"))
        let tick = try XCTUnwrap(main.range(of: "m.tick(full: wantFull"))
        let hook = try XCTUnwrap(main.range(of: "MemoryWatchHook.feed("))
        let cost = try XCTUnwrap(main.range(of: "TickCost.log(kind: wantFull"))
        XCTAssertLessThan(submit.lowerBound, tick.lowerBound)
        XCTAssertLessThan(tick.lowerBound, hook.lowerBound, "after the monitor's tick succeeded")
        XCTAssertLessThan(hook.lowerBound, cost.lowerBound, "inside the same tick, so its cost is in the tick's")
    }

    func testTheHookIsGivenTheSweepOnlyOnAFullTick() throws {
        let main = try code("Sources/AnodeApp/main.swift")
        XCTAssertTrue(main.contains("sweep: wantFull ? m.latestSweep : nil"), "a light tick re-reads the candidates instead")
        XCTAssertTrue(main.contains("if let leak = self.leakWatch"), "and nothing at all runs while the watch does not exist")
    }

    func testTheWatchIsOwnedByTheSamplingQueue() throws {
        let main = try code("Sources/AnodeApp/main.swift")
        // The declaration, the read in the tick, and the one assignment: inside `attach`, which runs on the sampling queue.
        XCTAssertEqual(main.components(separatedBy: "leakWatch").count - 1, 3)
        XCTAssertTrue(main.contains("attach: { [weak self] in self?.leakWatch = $0 }"))
        let controller = try code("Sources/AnodeApp/MemoryWatchController.swift")
        XCTAssertTrue(controller.contains("onSampling {"), "the controller reaches the watch only through the queue")
        XCTAssertTrue(try source("Sources/AnodeApp/MemoryWatchRuntime.swift").contains("onSampling: { sampling.async(execute: $0) }"))
    }

    func testMainMakesTheRuntimeAtLaunchAndShutsItDown() throws {
        let main = try code("Sources/AnodeApp/main.swift")
        XCTAssertEqual(main.components(separatedBy: "MemoryWatchRuntime.live(").count - 1, 1)
        let launch = try XCTUnwrap(main.range(of: "func applicationDidFinishLaunching"))
        let make = try XCTUnwrap(main.range(of: "MemoryWatchRuntime.live("))
        let terminate = try XCTUnwrap(main.range(of: "func applicationWillTerminate"))
        let stop = try XCTUnwrap(main.range(of: "memoryWatch?.shutdown()"))
        XCTAssertLessThan(launch.lowerBound, make.lowerBound)
        XCTAssertLessThan(make.lowerBound, terminate.lowerBound, "made at launch")
        XCTAssertLessThan(terminate.lowerBound, stop.lowerBound, "shut down at quit")
    }

    // ── No clock of its own ─────────────────────────────────────────────────

    func testNothingOfMemoryWatchHasATimerAThreadOrADispatchSource() throws {
        let banned = ["Timer", "scheduledTimer", "DispatchSource", "Thread(", "asyncAfter", "Operation(", "RunLoop"]
        for path in ownFiles {
            let text = try code(path)
            for word in banned {
                XCTAssertFalse(text.contains(word), "\(path) mentions \(word): the feature rides the app's sampling tick")
            }
        }
    }

    /// No process is started, no administrator privilege asked for and no helper used by anything of Memory Watch, the
    /// high-memory warning included: the app files that run it, the diagnostic window and the quitter, and the PowerKit files
    /// that do the detecting. Comments and string literals are not read (the section's own text says it uses none).
    func testNothingOfMemoryWatchStartsAProcessOrAsksForAdministratorPrivileges() throws {
        let banned: [(pattern: String, name: String)] = [
            (#"(?<![A-Za-z0-9_])Process\("#, "Process("), (#"\bsudo\b"#, "sudo"), ("osascript", "osascript"),
            ("NSAppleScript", "NSAppleScript"), ("NSUserScriptTask", "NSUserScriptTask"), ("posix_spawn", "posix_spawn"),
            (#"\bpopen\("#, "popen("), (#"\bexecv[ep]?\("#, "execv("), ("NSXPCConnection", "NSXPCConnection"),
            ("SMJobBless", "SMJobBless"), ("SMAppService", "SMAppService"), ("AuthorizationCreate", "AuthorizationCreate"),
        ]
        let paths = ownFiles + ["Sources/AnodeApp/MemoryWatchWindow.swift", "Sources/AnodeApp/MemoryWatchQuitter.swift",
                                "Sources/PowerKit/MemoryPressure.swift"]
        for path in paths {
            let text = try code(path)
            let ns = text as NSString
            for (pattern, name) in banned {
                let regex = try NSRegularExpression(pattern: pattern)
                let hits = regex.numberOfMatches(in: text, range: NSRange(location: 0, length: ns.length))
                XCTAssertEqual(hits, 0, "\(path) uses \(name): Memory Watch reads and notifies, it starts nothing")
            }
        }
    }

    /// The one system reading is made in one place, the hook, and only for a watch that asks for it.
    func testTheSystemMemoryIsReadFromTheHookOnly() throws {
        let sources = root.appendingPathComponent("Sources/AnodeApp")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var readers: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = NoSharedSettingsInTestsTests.codeOnly(try String(contentsOf: url, encoding: .utf8), keepStrings: false)
            if text.contains("SystemMemoryReader.read") { readers.append(url.lastPathComponent) }
        }
        XCTAssertEqual(readers, ["MemoryWatchController.swift"])
        let controller = try code("Sources/AnodeApp/MemoryWatchController.swift")
        XCTAssertEqual(controller.components(separatedBy: "SystemMemoryReader.read").count - 1, 1)
        XCTAssertTrue(controller.contains("if watch.watchesPressure"), "and only while the warning is switched on")
    }

    // ── The notification framework ──────────────────────────────────────────

    func testUserNotificationsIsImportedByOneFileOnly() throws {
        let sources = root.appendingPathComponent("Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var importers: [String] = []
        var users: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = NoSharedSettingsInTestsTests.codeOnly(try String(contentsOf: url, encoding: .utf8), keepStrings: false)
            if text.contains("import UserNotifications") { importers.append(url.lastPathComponent) }
            if text.contains("UNUserNotificationCenter") { users.append(url.lastPathComponent) }
        }
        XCTAssertEqual(importers, ["LeakNotifier.swift"])
        XCTAssertEqual(users, ["LeakNotifier.swift"], "the real centre is reached from the one class that wraps it")
    }

    func testTheRealNotifierNeverTouchesTheCentreInTheTestCopyOrAnUnbundledProcess() throws {
        let text = try code("Sources/AnodeApp/LeakNotifier.swift")
        XCTAssertTrue(text.contains("!AppSandbox.isOn"))
        XCTAssertTrue(text.contains("Bundle.main.bundleIdentifier != nil"))
        XCTAssertEqual(text.components(separatedBy: "UNUserNotificationCenter.current()").count - 1, 1,
                       "one place gets the centre, and it is the guarded one")
        XCTAssertTrue(text.contains("options: [.alert]"), "a banner and nothing else: no sound, no badge")
        XCTAssertFalse(text.contains(".sound"))
        // The words come from the finding (a leak and a low-memory warning have their own title), not from this file.
        let raw = try source("Sources/AnodeApp/LeakNotifier.swift")
        XCTAssertTrue(raw.contains("finding.notificationTitle"))
        XCTAssertFalse(raw.contains("Possible memory leak detected"))
    }

    func testTheBannerSaysWhatTheFindingSaysAndHasNoSound() {
        let leak = UNLeakNotifier.payload(for: makeLeakFinding())
        XCTAssertEqual(leak.title, "Possible memory leak detected")
        XCTAssertEqual(leak.body, makeLeakFinding().notificationBody)
        XCTAssertFalse(leak.timeSensitive)

        let low = makePressureFinding()
        let banner = UNLeakNotifier.payload(for: low)
        XCTAssertEqual(banner.title, "Memory is running low")
        XCTAssertEqual(banner.body, low.notificationBody)
        XCTAssertTrue(banner.body.contains("Chrome"), "it names the app")
        XCTAssertTrue(banner.timeSensitive, "urgent in feel, and still no sound (the file has no `.sound`)")
    }

    // ── The hook, run ───────────────────────────────────────────────────────

    func testAFullTickHandsOverTheSweepAndALightTickProbes() {
        let watch = FakeLeakWatch()
        MemoryWatchHook.feed(watch, sweep: makeSweep(at: 1, []), awake: 100, wall: Date())
        XCTAssertEqual(watch.ingests, 1)
        XCTAssertEqual(watch.probes, 0)
        MemoryWatchHook.feed(watch, sweep: nil, awake: 102, wall: Date())
        XCTAssertEqual(watch.ingests, 1)
        XCTAssertEqual(watch.probes, 1)
    }

    func testTheHookReadsTheSystemOnlyWhileThePressureWarningIsOn() {
        let reading = SystemMemoryReading(totalBytes: 16 << 30, usedBytes: 12 << 30, swapUsedBytes: 1 << 30, pressureLevel: 2)
        var reads = 0
        let watch = FakeLeakWatch()
        XCTAssertFalse(watch.watchesPressure)

        MemoryWatchHook.feed(watch, sweep: nil, awake: 10, wall: Date(), readSystem: { reads += 1; return reading })
        MemoryWatchHook.feed(watch, sweep: makeSweep(at: 1, []), awake: 12, wall: Date(), readSystem: { reads += 1; return reading })
        XCTAssertEqual(reads, 0, "with the option off the system is never read")
        XCTAssertTrue(watch.systemReadings.isEmpty, "and the watch is not called")

        watch.watchesPressure = true
        MemoryWatchHook.feed(watch, sweep: nil, awake: 14, wall: Date(), readSystem: { reads += 1; return reading })
        XCTAssertEqual(reads, 1, "one reading per tick")
        XCTAssertEqual(watch.systemReadings, [reading])
        MemoryWatchHook.feed(watch, sweep: makeSweep(at: 2, []), awake: 16, wall: Date(), readSystem: { reads += 1; return reading })
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(watch.order, ["probe", "ingest", "probe", "system", "ingest", "system"],
                       "the leak feed first, then the one reading")
    }

    func testAReadingThatFailedIsHandedOverAsNil() {
        let watch = FakeLeakWatch()
        watch.watchesPressure = true
        MemoryWatchHook.feed(watch, sweep: nil, awake: 10, wall: Date(), readSystem: { nil })
        XCTAssertEqual(watch.systemReadings.count, 1)
        XCTAssertNil(watch.systemReadings[0])
    }

    func testTheRealWatchIsAWatch() {
        // `MemoryWatch` is what the controller is given in the app; the protocol is satisfied by it as it stands.
        let watch: MemoryWatching = MemoryWatch(ownPID: 1, pathOf: { _ in "" }, footprintOf: { _ in nil }, discover: { [] })
        MemoryWatchHook.feed(watch, sweep: nil, awake: 10, wall: Date())
        XCTAssertNil(watch.onLivePoint)
    }

    // ── Off means nothing exists ────────────────────────────────────────────

    func testTheLiveRuntimeWithTheSettingOffBuildsNoWatchAndTouchesNothing() throws {
        let settings = try throwawaySettings(owner: "MemoryWatchWiring", test: name)
        var attached = 0
        let queue = DispatchQueue(label: "test.memorywatch.wiring")
        let controller = MemoryWatchRuntime.live(settings: settings, sampling: queue,
                                                 attach: { _ in attached += 1 },
                                                 openProcesses: { _ in }, bringForward: {})
        queue.sync {}
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(attached, 0, "no watch, so nothing was handed to the sampling tick")
        XCTAssertNil(controller.authorization, "and nothing was asked of macOS")
        XCTAssertTrue(controller.findings.isEmpty)
        XCTAssertTrue(controller.openWindowKeys.isEmpty)
        XCTAssertTrue(MemoryWatchController.current === controller)
    }

    func testAnodesOwnCopiesAreNeverCandidates() {
        let app = "/Applications/Anode.app"
        let exe = app + "/Contents/MacOS/Anode"
        let excluded = MemoryWatchRuntime.excludedPaths(bundlePath: app, executablePath: exe)
        // A worker (`--hard-drain-worker` and the other two) is this same executable, so its path and its identity key are
        // the program's own.
        XCTAssertTrue(excluded.contains(exe))
        XCTAssertTrue(excluded.contains(app))
        XCTAssertTrue(excluded.contains(IdentityKey.key(forExecutablePath: exe).key))
        XCTAssertFalse(excluded.contains("/Applications/Safari.app"))
    }
}

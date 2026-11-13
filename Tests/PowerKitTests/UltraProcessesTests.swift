import CoreGraphics
import XCTest
@testable import AnodeApp
@testable import PowerKit

/// Reading, stopping and hiding processes for Ultra Low Power Mode. Everything real is injected: the signal is a
/// recorder, the process start times are a table, the app to hide is a counter. Nothing here signals a process, hides an
/// app or changes the Mac. The one test that reads the live system is skipped unless `ANODE_ULTRA_LIVE=1`, and it only reads.
final class UltraProcessesTests: XCTestCase {

    private let user: uid_t = 501

    // ── Fixtures ────────────────────────────────────────────────────────────

    private func kernel(_ pid: pid_t, parent: pid_t = 1, uid: uid_t = 501, start: UInt64? = nil, command: String = "",
                        path: String = "", responsible: pid_t? = nil) -> LiveProcessList.KernelRow {
        LiveProcessList.KernelRow(pid: pid, parent: parent, uid: uid, startTime: start ?? UInt64(pid) * 10,
                                  command: command, path: path, responsible: responsible)
    }

    private func assemble(_ rows: [LiveProcessList.KernelRow], apps: [pid_t: LiveProcessList.AppRow] = [:],
                          tapOwners: Set<pid_t> = [], audioInput: Set<pid_t> = [], labels: [pid_t: String] = [:],
                          teams: [pid_t: String] = [:]) -> [UltraProcess] {
        LiveProcessList.assemble(kernel: rows, apps: apps, tapOwners: tapOwners, audioInput: audioInput, labels: labels,
                                 teams: teams, user: user)
    }

    private let editorPath = "/Applications/Editor.app/Contents/MacOS/Editor"

    // ── Assembling the list ─────────────────────────────────────────────────

    func testAssembleJoinsKernelFactsWithAppFacts() {
        let rows = [
            kernel(10, parent: 1, path: editorPath),
            kernel(11, parent: 10, path: "/Applications/Editor.app/Contents/Frameworks/Editor Helper", responsible: 10),
            kernel(12, parent: 1, path: "/usr/local/bin/devserver"),
        ]
        let list = assemble(rows,
                            apps: [10: .init(kind: .regular, bundleID: "com.example.editor", name: "Editor")],
                            tapOwners: [10], audioInput: [11], labels: [12: "com.example.devserver"],
                            teams: [10: "TEAM1", 12: "TEAM2"])
        XCTAssertEqual(list, [
            UltraProcess(pid: 10, parent: 1, uid: 501, startTime: 100, path: editorPath, responsible: nil,
                         app: .regular, bundleID: "com.example.editor", name: "Editor", launchdLabel: nil,
                         team: "TEAM1", ownsEventTap: true, usesMicOrCamera: false),
            UltraProcess(pid: 11, parent: 10, uid: 501, startTime: 110,
                         path: "/Applications/Editor.app/Contents/Frameworks/Editor Helper", responsible: 10,
                         app: .none, bundleID: nil, name: "Editor Helper", launchdLabel: nil,
                         team: nil, ownsEventTap: false, usesMicOrCamera: true),
            UltraProcess(pid: 12, parent: 1, uid: 501, startTime: 120, path: "/usr/local/bin/devserver", responsible: nil,
                         app: .none, bundleID: nil, name: "devserver", launchdLabel: "com.example.devserver",
                         team: "TEAM2", ownsEventTap: false, usesMicOrCamera: false),
        ])
    }

    func testAProcessWithNoReadablePathStillAppears() {
        let list = assemble([kernel(40, command: "mystery")])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].path, "")
        // The kernel's short name stands in for the executable's, so the confirm box can still name it.
        XCTAssertEqual(list[0].name, "mystery")
        XCTAssertEqual(assemble([kernel(41)])[0].name, "pid 41")
    }

    func testResponsibleEqualToItselfIsNil() {
        let rows = [
            kernel(20, responsible: 20),   // itself
            kernel(21, responsible: 0),
            kernel(22, responsible: 1),
            kernel(23, responsible: -1),   // the call failed
            kernel(24, responsible: nil),  // not asked
            kernel(25, responsible: 10),
        ]
        XCTAssertEqual(assemble(rows).map(\.responsible), [nil, nil, nil, nil, nil, 10])
    }

    func testOtherUsersProcessesAreListedWithTheirTeam() {
        let rootPath = "/Applications/Sync.app/Contents/Library/SyncDaemon"
        // Offered every fact, as if somebody asked the system about a root process: none of it is believed.
        let list = assemble([kernel(30, uid: 0, path: rootPath, responsible: 5), kernel(31, uid: 501, path: editorPath)],
                            apps: [30: .init(kind: .regular, bundleID: "com.example.sync", name: "Sync")],
                            tapOwners: [30], audioInput: [30], labels: [30: "com.example.syncd"],
                            teams: [30: "TEAMSYNC"])
        XCTAssertEqual(list.map(\.pid), [30, 31])
        XCTAssertEqual(list[0], UltraProcess(pid: 30, parent: 1, uid: 0, startTime: 300, path: rootPath, responsible: nil,
                                              app: .none, bundleID: nil, name: "SyncDaemon", launchdLabel: nil,
                                              team: "TEAMSYNC", ownsEventTap: false, usesMicOrCamera: false))
        XCTAssertEqual(list[1].uid, 501)
    }

    func testADisabledOrListenOnlyTapIsNotAnOwner() {
        func tap(_ pid: pid_t, enabled: Bool, _ options: CGEventTapOptions) -> CGEventTapInformation {
            var info = CGEventTapInformation()
            info.tappingProcess = pid
            info.enabled = enabled
            info.options = options
            return info
        }
        let owners = LiveProcessList.tapOwners(from: [
            tap(100, enabled: true, .defaultTap),     // can change or hold events: an owner
            tap(101, enabled: false, .defaultTap),    // disabled: stopping it stalls nothing
            tap(102, enabled: true, .listenOnly),     // only watches
            tap(103, enabled: false, .listenOnly),
            tap(100, enabled: false, .defaultTap),    // a second, disabled tap of the same app changes nothing
        ])
        XCTAssertEqual(owners, [100])
    }

    // ── The signing team ────────────────────────────────────────────────────

    func testSystemCodeHasNoTeam() {
        XCTAssertNil(LiveProcessList.signingTeam(.init(identifier: "com.apple.Safari", team: "ABCDE12345")))
        XCTAssertNil(LiveProcessList.signingTeam(.init(identifier: "launchd", team: nil)))
        XCTAssertNil(LiveProcessList.signingTeam(.init(identifier: "com.example.tool", team: "")))
        XCTAssertEqual(LiveProcessList.signingTeam(.init(identifier: "com.example.tool", team: "TEAM1")), "TEAM1")
        XCTAssertEqual(LiveProcessList.signingTeam(.init(identifier: nil, team: "TEAM1")), "TEAM1")
        // Only an identifier that BEGINS with Apple's prefix counts.
        XCTAssertEqual(LiveProcessList.signingTeam(.init(identifier: "org.com.apple.fake", team: "TEAM1")), "TEAM1")
    }

    func testATeamIsReadOncePerPathAndNoTeamIsRemembered() {
        let cache = LiveProcessList.TeamCache()
        var reads: [String] = []
        func team(_ path: String, _ facts: LiveProcessList.SigningFacts?) -> String? {
            cache.team(ofPath: path) { reads.append(path); return facts }
        }
        XCTAssertEqual(team("/Applications/A.app/Contents/MacOS/A", .init(identifier: "com.example.a", team: "TEAMA")), "TEAMA")
        XCTAssertEqual(team("/Applications/A.app/Contents/MacOS/A", .init(identifier: "x", team: "OTHER")), "TEAMA")
        // Unsigned code has no team, and that answer is kept too: the file is not checked again.
        XCTAssertNil(team("/opt/tool", .init(identifier: "tool", team: nil)))
        XCTAssertNil(team("/opt/tool", .init(identifier: "tool", team: "LATE")))
        XCTAssertEqual(reads, ["/Applications/A.app/Contents/MacOS/A", "/opt/tool"])
    }

    func testAFailedSigningReadIsNotRemembered() {
        let cache = LiveProcessList.TeamCache()
        var reads = 0
        // The process ended between the list and the check: unknown, not "no team".
        XCTAssertNil(cache.team(ofPath: "/Applications/Sync.app/Contents/Library/SyncDaemon") { reads += 1; return nil })
        // The next snapshot asks again, and a root daemon's team is not lost for the session.
        XCTAssertEqual(cache.team(ofPath: "/Applications/Sync.app/Contents/Library/SyncDaemon") {
            reads += 1
            return .init(identifier: "com.example.syncd", team: "TEAMSYNC")
        }, "TEAMSYNC")
        XCTAssertEqual(reads, 2)
    }

    func testApplesOwnFilesAndAnUnreadablePathAreNeverChecked() {
        let cache = LiveProcessList.TeamCache()
        var reads = 0
        for path in ["", "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", "/usr/libexec/syslogd",
                     "/usr/sbin/cfprefsd", "/bin/zsh", "/sbin/launchd", "/Library/Apple/usr/libexec/oah/x"] {
            XCTAssertNil(cache.team(ofPath: path) { reads += 1; return .init(identifier: "x", team: "T") }, path)
        }
        XCTAssertEqual(reads, 0)
        // /usr/local is the owner's to fill: it can hold anybody's code.
        XCTAssertEqual(cache.team(ofPath: "/usr/local/bin/tool") { reads += 1; return .init(identifier: "tool", team: "T") }, "T")
        XCTAssertEqual(reads, 1)
    }

    // ── launchd labels ──────────────────────────────────────────────────────

    func testLaunchctlLabelsKeepToolsAndDropApps() {
        let output = """
        PID\tStatus\tLabel
        812\t0\tapplication.com.example.editor.1234567.7654321
        -\t0\tcom.example.notrunning
        913\t0\tcom.example.devserver
        914\t-9\tapplication.com.example.browser.99.100.Helper
        1020\t0\tapplication.not.numbered
        1021\t0\tcom.example.b
        1021\t0\tcom.example.a
        """
        XCTAssertEqual(LiveProcessList.toolLabels(fromLaunchctl: output),
                       [913: "com.example.devserver", 1020: "application.not.numbered", 1021: "com.example.a"])
    }

    func testAnonymousLaunchctlLabelsAreDropped() {
        // A label made for a process that checked in with launchd without a job of its own embeds an address: a group
        // named by it would be a different group for every process and every boot, and no keep list could name it.
        let output = "PID\tStatus\tLabel\n"
            + "1030\t0\t0x600002f4c000.anonymous.zsh\n"
            + "1031\t0\tcom.example.anonymous.service\n"      // a word in a real label is not the address form
            + "1032\t0\t0x600002f4c000.anonymous.zsh\n"
            + "1032\t0\tcom.example.shell\n"                  // a process with a real label besides keeps that one
        XCTAssertEqual(LiveProcessList.toolLabels(fromLaunchctl: output),
                       [1031: "com.example.anonymous.service", 1032: "com.example.shell"])
    }

    // ── A process's start time ──────────────────────────────────────────────

    func testStartTimeIsTheSameNumberTheSnapshotReports() {
        let me = getpid()
        let listed = LiveProcessList.kernelRows()?.first { $0.pid == me }
        XCTAssertNotNil(listed)
        XCTAssertNotNil(LiveProcessList.startTime(me))
        XCTAssertEqual(LiveProcessList.startTime(me), listed?.startTime)
        XCTAssertEqual(LiveProcessList.combinedStartTime(seconds: 5, microseconds: 250), 5_000_250)
        XCTAssertNil(LiveProcessList.startTime(Int32.max), "a pid nobody has")
    }

    // ── The snapshot's time budget ──────────────────────────────────────────

    func testASnapshotThatFinishesInTimeIsDeliveredOnTheMainQueue() {
        let one = UltraProcess(pid: 9, parent: 1, uid: 501, startTime: 1, path: "/x", name: "x")
        let list = LiveProcessList(budget: 5, read: { _ in [one] })
        let done = expectation(description: "snapshot")
        list.snapshot {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual($0, [one])
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }

    func testASnapshotThatTakesTooLongCallsBackNilOnceAndTheLateListIsDropped() {
        let release = DispatchSemaphore(value: 0)
        let one = UltraProcess(pid: 9, parent: 1, uid: 501, startTime: 1, path: "/x", name: "x")
        let list = LiveProcessList(budget: 0.2, read: { _ in release.wait(); return [one] })
        var answers: [[UltraProcess]?] = []
        let done = expectation(description: "snapshot")
        list.snapshot {
            XCTAssertTrue(Thread.isMainThread)
            answers.append($0)
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        release.signal()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(answers.count, 1)
        if let answer = answers.first { XCTAssertNil(answer) }
    }

    // ── Stopping and continuing ─────────────────────────────────────────────

    private struct Sent: Equatable { let pid: pid_t; let signal: Int32 }

    private final class SignalRecorder {
        var sent: [Sent] = []
        var result: Int32 = 0
        func send(_ pid: pid_t, _ signal: Int32) -> Int32 { sent.append(Sent(pid: pid, signal: signal)); return result }
    }

    private func freezer(_ recorder: SignalRecorder, startTimes: [pid_t: UInt64]) -> LiveProcessFreezer {
        LiveProcessFreezer(startTimeOf: { startTimes[$0] }, signal: { recorder.send($0, $1) })
    }

    func testARecycledPidIsNeverSignalled() {
        let recorder = SignalRecorder()
        // The snapshot saw pid 4242 start at 100; now 4242 is another process that started at 200.
        let f = freezer(recorder, startTimes: [4242: 200])
        XCTAssertFalse(f.stop(pid: 4242, startTime: 100))
        XCTAssertFalse(f.resume(pid: 4242, startTime: 100))
        XCTAssertEqual(recorder.sent, [])
    }

    func testStopSendsStopAndResumeSendsContinue() {
        let recorder = SignalRecorder()
        let f = freezer(recorder, startTimes: [4242: 100, 4243: 101])
        XCTAssertTrue(f.stop(pid: 4242, startTime: 100))
        XCTAssertTrue(f.resume(pid: 4242, startTime: 100))
        XCTAssertEqual(recorder.sent, [Sent(pid: 4242, signal: SIGSTOP), Sent(pid: 4242, signal: SIGCONT)])
        // A signal the system refuses (the process is another user's) is a failure, not a success.
        recorder.result = -1
        XCTAssertFalse(f.stop(pid: 4243, startTime: 101))
        XCTAssertFalse(f.resume(pid: 4243, startTime: 101))
    }

    func testAGonePidIsNotSignalled() {
        let recorder = SignalRecorder()
        let f = freezer(recorder, startTimes: [:])
        XCTAssertFalse(f.stop(pid: 4242, startTime: 100))
        XCTAssertFalse(f.resume(pid: 4242, startTime: 100))
        XCTAssertEqual(recorder.sent, [])
    }

    func testAProcessGroupEveryProcessAndAnodeItselfAreNeverSignalled() {
        let recorder = SignalRecorder()
        // Even when the table claims a matching start time: kill(0) is Anode's own group, kill(-1) is everything the
        // owner runs, and a stopped Anode could not continue anything.
        let f = freezer(recorder, startTimes: [0: 5, 1: 5, -1: 5, getpid(): 5])
        for pid in [0, 1, -1, getpid()] {
            XCTAssertFalse(f.stop(pid: pid, startTime: 5))
            XCTAssertFalse(f.resume(pid: pid, startTime: 5))
        }
        XCTAssertEqual(recorder.sent, [])
    }

    // ── Hiding ──────────────────────────────────────────────────────────────

    /// A hider whose app, clock and hiding are all made up. `schedule` runs the next check at once and adds the wait to
    /// a clock that is only a number, so these tests never sleep.
    private final class FakeHiding {
        var hidden: (Int) -> Bool = { _ in false }   // is it hidden at this check (1-based)? Check 1 is the one before hiding.
        var found = true
        var checks = 0
        var clock: TimeInterval = 0
        var hides: [pid_t] = []
        var unhides: [pid_t] = []
        var results: [Bool] = []
        var clockAtCompletion: TimeInterval?
        var completions: Int { results.count }

        func make() -> LiveAppHider {
            LiveAppHider(
                hideApp: { self.hides.append($0); return self.found },
                isHidden: { _ in self.checks += 1; return self.hidden(self.checks) },
                unhideApp: { self.unhides.append($0) },
                schedule: { delay, work in self.clock += delay; work() })
        }
        func hide(_ hider: LiveAppHider, pid: pid_t = 4242) {
            hider.hide(pid: pid) { hidByUs in self.results.append(hidByUs); self.clockAtCompletion = self.clock }
        }
    }

    func testHideCallsBackAsSoonAsTheAppIsHiddenAndSaysItDidIt() {
        let fake = FakeHiding()
        fake.hidden = { $0 >= 3 }   // not hidden before; not at the first look after; hidden at the second
        fake.hide(fake.make())
        XCTAssertEqual(fake.hides, [4242])
        XCTAssertEqual(fake.checks, 3, "one before, then until it was hidden, not for the whole wait")
        XCTAssertEqual(fake.results, [true], "it was not hidden before and is now: Anode hid it")
        XCTAssertEqual(fake.clockAtCompletion ?? -1, LiveAppHider.pollInterval, accuracy: 1e-9)
    }

    func testAnAppThatWasHiddenAlreadyIsNotHiddenAgainAndIsNotOurs() {
        let fake = FakeHiding()
        fake.hidden = { _ in true }
        fake.hide(fake.make())
        XCTAssertEqual(fake.hides, [], "nothing to do to it")
        XCTAssertEqual(fake.checks, 1)
        XCTAssertEqual(fake.clock, 0, "an app that is hidden already is not waited for")
        XCTAssertEqual(fake.results, [false], "the owner hid it, so it is not Anode's to unhide at the end")
    }

    func testHideGivesUpAfterTheWaitAndDoesNotClaimIt() {
        let fake = FakeHiding()
        fake.hide(fake.make())
        XCTAssertEqual(fake.results, [false], "not hidden after the call: not Anode's")
        XCTAssertEqual(fake.clockAtCompletion ?? -1, LiveAppHider.hideWait, accuracy: 1e-9)
        XCTAssertEqual(fake.checks, 22, "one before, one at once after, then one every 50 ms for a second")
        XCTAssertEqual(LiveAppHider.hideWait, 1.0)
        XCTAssertEqual(LiveAppHider.pollInterval, 0.05)
    }

    func testHideOfAnAppThatIsGoneCallsBackAtOnceAndUnhideIsPassedOn() {
        let fake = FakeHiding()
        fake.found = false
        let hider = fake.make()
        fake.hide(hider)
        XCTAssertEqual(fake.results, [false])
        XCTAssertEqual(fake.checks, 1, "only the look before")
        XCTAssertEqual(fake.clock, 0)
        hider.unhide(pid: 4242)
        XCTAssertEqual(fake.unhides, [4242])
    }

    // ── Load ────────────────────────────────────────────────────────────────

    private typealias Reading = LiveLoadReader.Reading

    private func ticks(_ user: UInt32, _ system: UInt32, _ idle: UInt32, _ nice: UInt32 = 0) -> LiveLoadReader.HostTicks {
        .init(user: user, system: system, idle: idle, nice: nice)
    }

    func testBusyCoresAndAProcessAtHalfACore() {
        let key = ProcessKey(pid: 77, startAbsTime: 9)
        // 2 s on 10 cores. The user ticks wrap past the top of their 32 bits, which a plain subtraction would not survive.
        let previous = Reading(ticks: ticks(UInt32.max - 50, 40, 5_000, 10), cores: 10, takenAt: 1_000, cpuSeconds: [key: 10.0])
        let current = Reading(ticks: ticks(49, 90, 5_850, 10), cores: 10, takenAt: 3_000, cpuSeconds: [key: 11.0])
        // busy: user 100 + system 50 + nice 0 of 1000 ticks = 15%, of 10 cores = 1.5 cores
        let sample = LiveLoadReader.delta(previous: previous, current: current, elapsed: 2)
        XCTAssertEqual(sample?.busyCores ?? -1, 1.5, accuracy: 1e-9)
        // one second of CPU in two seconds is half a core
        XCTAssertEqual(sample?.byProcess[77] ?? -1, 0.5, accuracy: 1e-9)
    }

    func testAProcessThatAppearedBetweenReadsCountsFromZero() {
        let old = ProcessKey(pid: 77, startAbsTime: 9)
        let recycled = ProcessKey(pid: 80, startAbsTime: 500)
        // The previous reading was taken at 450: both new keys started after it.
        let previous = Reading(ticks: ticks(0, 0, 0), cores: 4, takenAt: 450,
                               cpuSeconds: [old: 5.0, ProcessKey(pid: 80, startAbsTime: 400): 900.0, ProcessKey(pid: 99, startAbsTime: 1): 1.0])
        let current = Reading(ticks: ticks(100, 0, 100), cores: 4, takenAt: 700,
                              cpuSeconds: [old: 5.0, recycled: 1.5, ProcessKey(pid: 81, startAbsTime: 600): 3.0])
        let sample = LiveLoadReader.delta(previous: previous, current: current, elapsed: 2)
        XCTAssertEqual(sample?.busyCores ?? -1, 2.0, accuracy: 1e-9)
        XCTAssertEqual(sample?.byProcess[77] ?? -1, 0, accuracy: 1e-9)
        // never seen before, and started after the last reading: all of its CPU time happened in this interval
        XCTAssertEqual(sample?.byProcess[81] ?? -1, 1.5, accuracy: 1e-9)
        // the same pid under a new start time is another process, not 900 s of the old one taken away
        XCTAssertEqual(sample?.byProcess[80] ?? -1, 0.75, accuracy: 1e-9)
        // a process that ended is simply not there
        XCTAssertNil(sample?.byProcess[99])
    }

    func testALongLivedProcessMissingFromTheLastReadingIsLeftOut() {
        let steady = ProcessKey(pid: 77, startAbsTime: 9)
        // Running since long before the last reading (taken at 450), but that reading did not get it (a read that failed
        // once): its lifetime of CPU is not this interval's, and 4000 s over 2 s would be a burner of 2000 cores.
        let missed = ProcessKey(pid: 90, startAbsTime: 100)
        let previous = Reading(ticks: ticks(0, 0, 0), cores: 4, takenAt: 450, cpuSeconds: [steady: 5.0])
        let current = Reading(ticks: ticks(100, 0, 100), cores: 4, takenAt: 700,
                              cpuSeconds: [steady: 6.0, missed: 4_000.0])
        let sample = LiveLoadReader.delta(previous: previous, current: current, elapsed: 2)
        XCTAssertNil(sample?.byProcess[90], "left out for this interval; the next one has it")
        XCTAssertEqual(sample?.byProcess[77] ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(sample?.byProcess.count, 1)
        // Started at the very moment of the last reading is not after it: left out too, never counted too high.
        let edge = ProcessKey(pid: 91, startAbsTime: 450)
        let atEdge = Reading(ticks: ticks(100, 0, 100), cores: 4, takenAt: 700, cpuSeconds: [steady: 6.0, edge: 0.4])
        XCTAssertNil(LiveLoadReader.delta(previous: previous, current: atEdge, elapsed: 2)?.byProcess[91])
    }

    func testNoLoadWhenNoTimeOrNoTicksPassed() {
        let r = Reading(ticks: ticks(1, 1, 1), cores: 4, takenAt: 1, cpuSeconds: [:])
        XCTAssertNil(LiveLoadReader.delta(previous: r, current: r, elapsed: 2), "no tick passed")
        let later = Reading(ticks: ticks(5, 5, 5), cores: 4, takenAt: 2, cpuSeconds: [:])
        XCTAssertNil(LiveLoadReader.delta(previous: r, current: later, elapsed: 0))
    }

    // ── The real Mac, read only ─────────────────────────────────────────────

    /// Reads every process and the load on this Mac, runs the planner on the list, and prints what it found. It sends no
    /// signal and changes nothing. Skipped unless `ANODE_ULTRA_LIVE=1`: it is the only check of the real system calls.
    func testLiveSnapshotSmoke() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ANODE_ULTRA_LIVE"] == "1",
                          "set ANODE_ULTRA_LIVE=1 to read the real process list (read only)")

        let list = LiveProcessList()
        let listed = expectation(description: "snapshot")
        var snapshot: [UltraProcess]?
        let began = Date()
        list.snapshot { snapshot = $0; listed.fulfill() }
        wait(for: [listed], timeout: LiveProcessList.budget + 3)
        print("ULTRA LIVE: snapshot took \(String(format: "%.2f", Date().timeIntervalSince(began))) s")
        let processes = try XCTUnwrap(snapshot, "the list could not be read within the budget")
        XCTAssertGreaterThan(processes.count, 100)
        let me = try XCTUnwrap(processes.first { $0.pid == getpid() }, "this process is not in the list")
        XCTAssertFalse(me.path.isEmpty)
        print("ULTRA LIVE: \(processes.count) processes, \(processes.filter { $0.uid == getuid() }.count) the user's, "
              + "\(processes.filter { $0.team != nil }.count) with a team, \(processes.filter { $0.app != .none }.count) apps, "
              + "\(processes.filter(\.ownsEventTap).count) tap owners, \(processes.filter(\.usesMicOrCamera).count) on the microphone")

        let plan = FreezePlanner.plan(processes: processes, user: getuid(), front: nil, alwaysKeep: [], ownPIDs: [getpid()])
        for (title, groups) in [("kept", plan.kept), ("frozen", plan.frozen), ("leftRunning", plan.leftRunning)] {
            print("ULTRA LIVE: \(title) (\(groups.count) groups): "
                  + groups.map { "\($0.name) [\($0.id)] x\($0.members.count)" }.joined(separator: "; "))
        }

        let reader = LiveLoadReader()
        let first = expectation(description: "first read")
        var firstSample: LoadSample?
        reader.read { firstSample = $0; first.fulfill() }
        wait(for: [first], timeout: 5)
        XCTAssertNil(firstSample, "nothing to compare with the first time")
        let pause = expectation(description: "two seconds")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { pause.fulfill() }
        wait(for: [pause], timeout: 5)
        let second = expectation(description: "second read")
        var secondSample: LoadSample?
        reader.read { secondSample = $0; second.fulfill() }
        wait(for: [second], timeout: 5)
        let sample = try XCTUnwrap(secondSample)
        let busiest = sample.byProcess.sorted { $0.value > $1.value }.prefix(3)
            .map { "\($0.key) \(String(format: "%.2f", $0.value))" }.joined(separator: ", ")
        print("ULTRA LIVE: busy cores \(String(format: "%.2f", sample.busyCores)) of \(ProcessInfo.processInfo.activeProcessorCount); "
              + "\(sample.byProcess.count) processes measured; busiest (pid cores): \(busiest)")
        XCTAssertGreaterThanOrEqual(sample.busyCores, 0)
        XCTAssertFalse(sample.byProcess.isEmpty)
    }
}

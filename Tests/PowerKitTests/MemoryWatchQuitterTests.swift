import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// What Quit and Force Quit may reach, played against a pretend process table. Nothing here reads a real process, sends a
/// signal, asks the real frontmost app, or shows a box: every step that touches the Mac is a closure.
final class MemoryWatchQuitterTests: XCTestCase {

    private let me: uid_t = 501
    private let selfPID: pid_t = 9000

    private struct Proc {
        var start: UInt64
        var path: String
        var uid: uid_t = 501
    }

    private final class Recorder {
        var signalled: [[pid_t]] = []
        var forces: [Bool] = []
        var confirmCalls = 0
        var confirmed: [MemoryWatchQuitPlan] = []
        var answer = true
    }

    private func makeQuitter(_ table: [pid_t: Proc],
                             recorder: Recorder = Recorder(),
                             ownPIDs: Set<pid_t> = [],
                             ownPaths: Set<String> = [],
                             bundle: (id: String?, kind: AppKind) = (nil, .regular)) -> MemoryWatchQuitter {
        MemoryWatchQuitter(
            probe: { pid in table[pid].map { (start: $0.start, footprint: 1 << 30) } },
            allPIDs: { table.keys.sorted() },
            pathOf: { table[$0]?.path ?? "" },
            candidates: { pids in
                pids.compactMap { pid in
                    table[pid].map {
                        ProcessActions.Candidate(pid: pid, uid: $0.uid, owner: $0.uid == 0 ? "root" : "me")
                    }
                }
            },
            bundleInfo: { _, _ in bundle },
            selfPID: selfPID,
            currentUID: me,
            ownPIDs: { ownPIDs },
            ownPaths: ownPaths,
            signal: { plan, force in
                recorder.signalled.append(plan.signalable)
                recorder.forces.append(force)
                let n = plan.signalable.count
                let subject = n == 1 ? "1 process" : "\(n) processes"
                return force ? "Force quit \(subject)" : "Quit requested for \(subject)"
            },
            confirm: { plan in
                recorder.confirmCalls += 1
                recorder.confirmed.append(plan)
                return recorder.answer
            },
            runOffMain: { $0() },
            runOnMain: { $0() })
    }

    private let safari = "/Applications/Safari.app"
    private var safariMain: String { safari + "/Contents/MacOS/Safari" }
    private var safariHelper: String { safari + "/Contents/Frameworks/Safari Helper.app/Contents/MacOS/Safari Helper" }

    /// Safari: main 200, helpers 201 and 202, plus things that only look like it.
    private func safariTable(flaggedStart: UInt64 = 777) -> [pid_t: Proc] {
        [200: Proc(start: 1, path: safariMain),
         201: Proc(start: flaggedStart, path: safariHelper),
         202: Proc(start: 3, path: safari + "/Contents/XPCServices/Network.xpc/Contents/MacOS/Network"),
         203: Proc(start: 4, path: "/Applications/Safari.app.backup/Contents/MacOS/Safari"),
         204: Proc(start: 5, path: "/Applications/Other.app/Contents/MacOS/Other"),
         205: Proc(start: 6, path: "")]
    }

    private func safariFinding(pid: pid_t = 201, start: UInt64 = 777) -> Finding {
        MemoryWatchFixtures.finding(pid: pid, start: start, path: safariHelper)
    }

    // MARK: Start time

    func testAStartTimeMismatchSignalsNothing() {
        let rec = Recorder()
        let q = makeQuitter(safariTable(flaggedStart: 999), recorder: rec)   // the pid now belongs to another process
        let plan = q.resolve(safariFinding(start: 777))
        XCTAssertTrue(plan.alreadyGone)
        XCTAssertFalse(plan.canAct)
        XCTAssertTrue(plan.signalable.isEmpty)
        XCTAssertEqual(plan.explanation, "That process already exited")
        XCTAssertEqual(q.perform(plan, force: false), "That process already exited")
        XCTAssertEqual(q.perform(plan, force: true), "That process already exited")
        XCTAssertTrue(rec.signalled.isEmpty)
        XCTAssertEqual(rec.confirmCalls, 0, "nothing to confirm when nothing will be killed")
    }

    func testAProcessThatIsGoneSignalsNothing() {
        let rec = Recorder()
        var table = safariTable()
        table[201] = nil
        let q = makeQuitter(table, recorder: rec)
        let plan = q.resolve(safariFinding())
        XCTAssertTrue(plan.alreadyGone)
        _ = q.perform(plan, force: false)
        XCTAssertTrue(rec.signalled.isEmpty)
    }

    // MARK: Who is reached

    func testANonAppFindingSignalsExactlyTheFlaggedPidNotItsNamesakes() {
        let rec = Recorder()
        let node = "/opt/homebrew/bin/node"
        let table: [pid_t: Proc] = [100: Proc(start: 5, path: node), 101: Proc(start: 6, path: node),
                                    102: Proc(start: 7, path: node), 103: Proc(start: 8, path: node)]
        let q = makeQuitter(table, recorder: rec)
        let plan = q.resolve(MemoryWatchFixtures.nodeFinding(pid: 100, start: 5))
        XCTAssertFalse(plan.wholeApp)
        XCTAssertEqual(plan.signalable, [100])
        XCTAssertEqual(plan.processCount, 1)
        XCTAssertEqual(q.perform(plan, force: false), "Quit requested, waiting for it to close")
        _ = q.perform(plan, force: true)
        XCTAssertEqual(rec.signalled, [[100], [100]])
        XCTAssertFalse(rec.signalled.flatMap { $0 }.contains(101))
    }

    func testAnAppFindingSignalsOnlyThePidsUnderItsBundle() {
        let rec = Recorder()
        let q = makeQuitter(safariTable(), recorder: rec)
        let plan = q.resolve(safariFinding())
        XCTAssertTrue(plan.wholeApp)
        // 203 sits under "Safari.app.backup", 204 under another app, 205 has no readable path.
        XCTAssertEqual(plan.signalable, [200, 201, 202])
        XCTAssertEqual(plan.processCount, 3)
        _ = q.perform(plan, force: false)
        XCTAssertEqual(rec.signalled, [[200, 201, 202]])
    }

    /// The reported incident: a python3 that ships inside Xcode.app leaked, the window said "Xcode", and Force Quit App
    /// offered to kill every process under /Applications/Xcode.app. The finding is built the way the watch builds it, from
    /// the executable path, so this goes through `IdentityKey`.
    func testAToolShippedInsideAnAppIsKilledAloneNeverTheWholeApp() {
        let xcode = "/Applications/Xcode.app"
        let python = xcode + "/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/bin/python3"
        let lsp = xcode + "/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp"
        let table: [pid_t: Proc] = [300: Proc(start: 9, path: python),
                                    301: Proc(start: 2, path: xcode + "/Contents/MacOS/Xcode"),
                                    302: Proc(start: 3, path: lsp),
                                    303: Proc(start: 4, path: python)]
        let key = IdentityKey.key(forExecutablePath: python)
        let finding = MemoryWatchFixtures.finding(pid: 300, start: 9, name: IdentityKey.name(forExecutablePath: python),
                                                  path: python, identityKey: key.key, isApp: key.isApp)
        let rec = Recorder()
        let q = makeQuitter(table, recorder: rec)
        let plan = q.resolve(finding)
        XCTAssertFalse(plan.wholeApp)
        XCTAssertEqual(plan.signalable, [300])
        _ = q.perform(plan, force: true)
        XCTAssertEqual(rec.signalled, [[300]])
    }

    /// The other direction: Quit App on a real Xcode finding reaches Xcode's own processes and not the tools in its folder.
    func testAnAppFindingDoesNotReachToolsThatLiveUnderItsFolder() {
        let xcode = "/Applications/Xcode.app"
        let table: [pid_t: Proc] = [
            400: Proc(start: 5, path: xcode + "/Contents/MacOS/Xcode"),
            401: Proc(start: 6, path: xcode + "/Contents/XPCServices/Build.xpc/Contents/MacOS/Build"),
            402: Proc(start: 7, path: xcode + "/Contents/Developer/usr/bin/swift-frontend"),
            403: Proc(start: 8, path: xcode + "/Contents/Developer/Library/Frameworks/Python3.framework/bin/python3")]
        let q = makeQuitter(table)
        let plan = q.resolve(MemoryWatchFixtures.finding(pid: 400, start: 5, name: "Xcode",
                                                         path: xcode + "/Contents/MacOS/Xcode",
                                                         identityKey: xcode, isApp: true))
        XCTAssertTrue(plan.wholeApp)
        XCTAssertEqual(plan.signalable, [400, 401])
    }

    // MARK: Anode itself

    func testAnodesOwnPidIsNeverOffered() {
        var table = safariTable()
        table[selfPID] = Proc(start: 50, path: safariMain + "/own")   // under the same bundle path, by contrivance
        let q = makeQuitter(table)
        let plan = q.resolve(safariFinding())
        XCTAssertFalse(plan.signalable.contains(selfPID))
        XCTAssertTrue(plan.includesSelf)
        XCTAssertEqual(plan.signalable, [200, 201, 202])
    }

    func testAWorkerCopyOfAnodeIsNeverOffered() {
        var table = safariTable()
        table[210] = Proc(start: 60, path: safari + "/Contents/MacOS/worker")
        let q = makeQuitter(table, ownPIDs: [210])
        let plan = q.resolve(safariFinding())
        XCTAssertFalse(plan.signalable.contains(210))
        XCTAssertTrue(plan.includesSelf)
    }

    func testAFindingOnAnodeItselfOffersNothing() {
        let anode = "/Applications/Anode.app"
        let table: [pid_t: Proc] = [selfPID: Proc(start: 9, path: anode + "/Contents/MacOS/Anode"),
                                    9001: Proc(start: 10, path: anode + "/Contents/Frameworks/Helper")]
        let q = makeQuitter(table, ownPaths: [anode])
        let finding = MemoryWatchFixtures.finding(pid: selfPID, start: 9, name: "Anode",
                                                  path: anode + "/Contents/MacOS/Anode", identityKey: anode)
        let plan = q.resolve(finding)
        XCTAssertFalse(plan.canAct)
        XCTAssertTrue(plan.includesSelf)
        XCTAssertEqual(plan.explanation, "This is Anode")
    }

    // MARK: Other users' processes

    func testARootOwnedProcessIsRefusedWithAnExplanation() {
        let rec = Recorder()
        let table: [pid_t: Proc] = [300: Proc(start: 5, path: "/opt/homebrew/bin/node", uid: 0)]
        let q = makeQuitter(table, recorder: rec)
        let plan = q.resolve(MemoryWatchFixtures.nodeFinding(pid: 300, start: 5))
        XCTAssertFalse(plan.canAct)
        XCTAssertTrue(plan.signalable.isEmpty)
        XCTAssertEqual(plan.refused.map(\.pid), [300])
        XCTAssertEqual(plan.refused.first?.owner, "root")
        XCTAssertEqual(plan.explanation, "Owned by root — Anode cannot signal it")
        _ = q.perform(plan, force: true)
        XCTAssertTrue(rec.signalled.isEmpty)
        XCTAssertEqual(rec.confirmCalls, 0)
    }

    func testAnAppWithOneRootHelperIsPartlyRefused() {
        var table = safariTable()
        table[202]?.uid = 0
        let plan = makeQuitter(table).resolve(safariFinding())
        XCTAssertEqual(plan.signalable, [200, 201])
        XCTAssertEqual(plan.refused.map(\.pid), [202])
        XCTAssertTrue(plan.canAct)
        XCTAssertEqual(plan.explanation, "1 of 3 owned by root and cannot be signalled")
        XCTAssertEqual(plan.totalProcessCount, 3)
    }

    // MARK: macOS's own

    func testAFinderLikeFindingCarriesASystemWarning() {
        let finder = "/System/Library/CoreServices/Finder.app"
        let path = finder + "/Contents/MacOS/Finder"
        let table: [pid_t: Proc] = [400: Proc(start: 11, path: path)]
        let q = makeQuitter(table, bundle: ("com.apple.finder", .regular))
        let finding = MemoryWatchFixtures.finding(pid: 400, start: 11, name: "Finder", path: path, identityKey: finder)
        let plan = q.resolve(finding)
        XCTAssertEqual(plan.systemProcessWarning,
                       "Finder is part of macOS. Quitting it can disturb the desktop or other apps.")
        XCTAssertTrue(plan.canAct, "a warning, not a refusal")
    }

    func testAnAppleDaemonThatIsNotAnAppAlsoCarriesTheWarning() {
        let path = "/usr/libexec/someagentd"
        let q = makeQuitter([410: Proc(start: 12, path: path)])
        let finding = MemoryWatchFixtures.finding(pid: 410, start: 12, name: "someagentd", path: path,
                                                  identityKey: path, isApp: false)
        XCTAssertNotNil(q.resolve(finding).systemProcessWarning)
    }

    func testAnOrdinaryAppHasNoSystemWarning() {
        let q = makeQuitter(safariTable(), bundle: ("com.apple.Safari", .regular))
        XCTAssertNil(q.resolve(safariFinding()).systemProcessWarning, "a regular app of Apple's is the owner's own")
        let node = makeQuitter([100: Proc(start: 5, path: "/opt/homebrew/bin/node")])
        XCTAssertNil(node.resolve(MemoryWatchFixtures.nodeFinding()).systemProcessWarning)
        let local = "/usr/local/bin/mytool"
        let tool = makeQuitter([101: Proc(start: 6, path: local)])
        let finding = MemoryWatchFixtures.finding(pid: 101, start: 6, name: "mytool", path: local,
                                                  identityKey: local, isApp: false)
        XCTAssertNil(tool.resolve(finding).systemProcessWarning, "/usr/local is people's own tools")
    }

    // MARK: Force Quit and its confirmation

    func testForceQuitDoesNothingWhenTheConfirmationSaysNo() {
        let rec = Recorder()
        rec.answer = false
        let q = makeQuitter(safariTable(), recorder: rec)
        let plan = q.resolve(safariFinding())
        XCTAssertEqual(q.perform(plan, force: true), MemoryWatchQuitter.cancelledLine)
        XCTAssertEqual(rec.confirmCalls, 1)
        XCTAssertTrue(rec.signalled.isEmpty)
    }

    func testForceQuitSignalsWhenTheConfirmationSaysYes() {
        let rec = Recorder()
        let q = makeQuitter(safariTable(), recorder: rec)
        let plan = q.resolve(safariFinding())
        XCTAssertEqual(q.perform(plan, force: true), "Force quit 3 processes")
        XCTAssertEqual(rec.confirmCalls, 1)
        XCTAssertEqual(rec.confirmed.first?.processCount, 3, "the box is told how many processes it is about")
        XCTAssertEqual(rec.signalled, [[200, 201, 202]])
        XCTAssertEqual(rec.forces, [true])
    }

    func testAPoliteQuitIsNeverConfirmed() {
        let rec = Recorder()
        let q = makeQuitter(safariTable(), recorder: rec)
        let plan = q.resolve(safariFinding())
        XCTAssertEqual(q.perform(plan, force: false), "Quit requested, waiting for it to close")
        XCTAssertEqual(rec.confirmCalls, 0)
        XCTAssertEqual(rec.forces, [false])
    }

    func testAFailedQuitKeepsTheExistingWording() {
        let q = MemoryWatchQuitter(probe: { _ in (start: 777, footprint: 1) },
                                   allPIDs: { [] }, pathOf: { _ in "" },
                                   candidates: { pids in pids.map { ProcessActions.Candidate(pid: $0, uid: 501, owner: "me") } },
                                   bundleInfo: { _, _ in (nil, .regular) },
                                   selfPID: selfPID, currentUID: me,
                                   signal: { _, _ in "0 of 1 — Failed (errno 0)" },
                                   confirm: { _ in true }, runOffMain: { $0() }, runOnMain: { $0() })
        let plan = q.resolve(MemoryWatchFixtures.nodeFinding(pid: 100, start: 777))
        XCTAssertEqual(q.perform(plan, force: false), "0 of 1 — Failed (errno 0)")
    }

    func testTheConfirmationStatesTheCountAndUnsavedWork() {
        let many = MemoryWatchQuitter.confirmationText(appName: "Safari", processCount: 7, wholeApp: true)
        XCTAssertEqual(many.title, "Force quit Safari?")
        XCTAssertTrue(many.detail.contains("This will kill 7 processes."))
        XCTAssertTrue(many.detail.contains("unsaved work may be lost"))
        XCTAssertTrue(many.detail.contains("whole app"))

        let one = MemoryWatchQuitter.confirmationText(appName: "node", processCount: 1, wholeApp: false)
        XCTAssertTrue(one.detail.contains("This will kill 1 process."))
        XCTAssertFalse(one.detail.contains("1 processes"))
        XCTAssertTrue(one.detail.contains("only this one process"))
        XCTAssertFalse(one.detail.contains("whole app"))
        XCTAssertTrue(one.detail.contains("unsaved work may be lost"))
    }

    func testTheConfirmationAddsTheSystemWarning() {
        let text = MemoryWatchQuitter.confirmationText(appName: "Finder", processCount: 1, wholeApp: true,
                                                       systemWarning: "Finder is part of macOS.")
        XCTAssertTrue(text.detail.contains("Finder is part of macOS."))
    }

    // MARK: Still running

    func testTheStillRunningCheckSeesALiveProcessAndAGoneOne() {
        var table = safariTable()
        let plan = makeQuitter(table).resolve(safariFinding())
        XCTAssertTrue(makeQuitter(table).stillRunning(plan))
        // Only a recycled pid is left under the flagged pid: not the same process.
        table = [201: Proc(start: 999, path: "/bin/other")]
        XCTAssertFalse(makeQuitter(table).stillRunning(plan))
        XCTAssertFalse(makeQuitter([:]).stillRunning(plan))
        // The app's main process is still there even though the flagged helper is not.
        table = [200: Proc(start: 1, path: safariMain)]
        XCTAssertTrue(makeQuitter(table).stillRunning(plan))
    }

    func testPlanAndCheckComeBackThroughTheInjectedHandOff() {
        var hops: [String] = []
        let table = safariTable()
        let q = MemoryWatchQuitter(probe: { pid in table[pid].map { (start: $0.start, footprint: 1) } },
                                   allPIDs: { table.keys.sorted() }, pathOf: { table[$0]?.path ?? "" },
                                   candidates: { pids in pids.map { ProcessActions.Candidate(pid: $0, uid: 501, owner: "me") } },
                                   bundleInfo: { _, _ in (nil, .regular) },
                                   selfPID: selfPID, currentUID: me,
                                   runOffMain: { hops.append("off"); $0() }, runOnMain: { hops.append("main"); $0() })
        var got: MemoryWatchQuitPlan?
        q.plan(for: safariFinding()) { got = $0 }
        XCTAssertEqual(hops, ["off", "main"])
        XCTAssertEqual(got?.signalable, [200, 201, 202])
        var alive: Bool?
        q.isStillRunning(got!) { alive = $0 }
        XCTAssertEqual(alive, true)
    }

    // MARK: Nothing timed

    func testTheQuitterAndTheWindowCreateNoTimerThreadOrObserver() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AnodeApp")
        for file in ["MemoryWatchQuitter.swift", "MemoryWatchWindow.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for banned in ["Timer", "DispatchSource", "NotificationCenter", "addObserver", "Thread(", "OperationQueue"] {
                XCTAssertFalse(text.contains(banned), "\(file) must not use \(banned)")
            }
        }
    }
}

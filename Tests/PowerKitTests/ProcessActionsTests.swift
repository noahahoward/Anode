import XCTest
@testable import BetterStatsApp
@testable import PowerKit

/// Deciding what a Quit button may do, without signalling anything.
///
/// The plan is deliberately separate from `kill(2)` precisely so this file can
/// exist: the part that has to be right is which pids are ours, and that part
/// cannot be tested at all if it is entangled with actually killing processes.
final class ProcessActionsTests: XCTestCase {

    private let me: uid_t = 501
    private let selfPID: pid_t = 4242

    private func candidate(_ pid: pid_t, uid: uid_t, owner: String) -> ProcessActions.Candidate {
        ProcessActions.Candidate(pid: pid, uid: uid, owner: owner)
    }

    private func plan(_ candidates: [ProcessActions.Candidate]) -> ProcessActions.Plan {
        ProcessActions.plan(for: candidates, currentUID: me, selfPID: selfPID)
    }

    func testOurOwnProcessesAreSignalable() {
        let p = plan([candidate(10, uid: me, owner: "noah"),
                      candidate(11, uid: me, owner: "noah")])
        XCTAssertEqual(p.signalable, [10, 11])
        XCTAssertTrue(p.refused.isEmpty)
        XCTAssertTrue(p.canAct)
        XCTAssertEqual(p.explanation, "")
    }

    /// A button guaranteed to fail with EPERM is worse than no button — it implies
    /// the app could do it and chose not to. A root-owned process is never offered,
    /// and the reason is stated instead of waiting for the click to fail.
    func testARootOwnedProcessIsRefusedAndSaysWhy() {
        let p = plan([candidate(1, uid: 0, owner: "root")])
        XCTAssertTrue(p.signalable.isEmpty)
        XCTAssertFalse(p.canAct, "a control that can only fail must not be enabled")
        XCTAssertEqual(p.refused.map(\.pid), [1])
        XCTAssertTrue(p.explanation.contains("root"), p.explanation)
        XCTAssertTrue(p.explanation.contains("cannot signal"), p.explanation)
    }

    /// An app that is partly ours and partly root's — a helper running as the user
    /// beside a privileged daemon. The button works, and the status line says how
    /// much of the app it will not reach, so a "quit" that leaves something running
    /// is not a surprise.
    func testAMixedAppActsOnWhatItCanAndSaysWhatItCannot() {
        let p = plan([candidate(10, uid: me, owner: "noah"),
                      candidate(11, uid: 0, owner: "root")])
        XCTAssertEqual(p.signalable, [10])
        XCTAssertTrue(p.canAct)
        XCTAssertTrue(p.explanation.contains("1 of 2"), p.explanation)
        XCTAssertTrue(p.explanation.contains("root"), p.explanation)
    }

    /// Quitting the monitor from inside its own process list is almost certainly a
    /// misclick, and the app cannot report the outcome of its own death.
    func testBetterStatsNeverOffersToQuitItself() {
        let p = plan([candidate(selfPID, uid: me, owner: "noah")])
        XCTAssertTrue(p.signalable.isEmpty)
        XCTAssertTrue(p.refused.isEmpty, "our own pid is not an EPERM case")
        XCTAssertTrue(p.includesSelf)
        XCTAssertEqual(p.explanation, "This is BetterStats")
    }

    /// Selecting BetterStats in a list that also contains our other processes must
    /// still skip only our own pid.
    func testOnlyOurOwnPIDIsSkipped() {
        let p = plan([candidate(selfPID, uid: me, owner: "noah"),
                      candidate(99, uid: me, owner: "noah")])
        XCTAssertEqual(p.signalable, [99])
    }

    /// A process that has already exited is not a process we failed to signal —
    /// `ProcessInspector.details` returns nil for it and it is simply dropped.
    /// Driven against this test process, which is the one pid guaranteed to exist
    /// and to be ours, beside a pid that cannot.
    func testCandidatesAreReadFromLiveProcessesOnly() {
        let mine = getpid()
        let candidates = ProcessActions.candidates(pids: [mine, 999_999])
        XCTAssertEqual(candidates.map(\.pid), [mine])
        XCTAssertEqual(candidates.first?.uid, getuid())
    }

    /// The signalling path refuses to run at all when the plan says it cannot,
    /// rather than firing a kill and reporting the failure afterwards.
    func testPerformDoesNothingWhenTheresNothingItMayDo() {
        let p = plan([candidate(1, uid: 0, owner: "root")])
        XCTAssertEqual(ProcessActions.perform(p, force: false), p.explanation)
        XCTAssertEqual(ProcessActions.perform(p, force: true), p.explanation)
    }
}

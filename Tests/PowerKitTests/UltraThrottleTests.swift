import XCTest
@testable import PowerKit

/// Which processes Ultra Low Power Mode puts under the background policy. Pure: made-up groups and processes go in, a list of
/// processes comes out, and nothing is read from or changed on the Mac.
final class UltraThrottleTests: XCTestCase {

    // ── Fixtures ────────────────────────────────────────────────────────────

    private func member(_ pid: pid_t) -> FreezeGroup.Member {
        FreezeGroup.Member(pid: pid, startTime: UInt64(pid) * 10)
    }

    private func group(_ id: String, _ pids: [pid_t]) -> FreezeGroup {
        FreezeGroup(id: id, name: id, members: pids.map(member))
    }

    /// A process as the list reads it: its start time follows its pid, as in `member`.
    private func process(_ pid: pid_t, onCall: Bool = false, startTime: UInt64? = nil) -> UltraProcess {
        UltraProcess(pid: pid, parent: 1, uid: 501, startTime: startTime ?? UInt64(pid) * 10, path: "/Applications/X.app/Contents/MacOS/X",
                     name: "X", usesMicOrCamera: onCall)
    }

    private func pids(_ members: [FreezeGroup.Member]) -> [pid_t] { members.map(\.pid) }

    // ── Efficiency cores ────────────────────────────────────────────────────

    /// More than one performance level means there are cores of another kind. An Intel Mac has one level, or none to read.
    func testAMacHasEfficiencyCoresWhenItHasMoreThanOnePerformanceLevel() {
        XCTAssertFalse(UltraThrottle.hasEfficiencyCores(performanceLevels: 0))
        XCTAssertFalse(UltraThrottle.hasEfficiencyCores(performanceLevels: 1))
        XCTAssertTrue(UltraThrottle.hasEfficiencyCores(performanceLevels: 2))
        XCTAssertTrue(UltraThrottle.hasEfficiencyCores(performanceLevels: 3), "a Mac with a third level is not judged by its model")
    }

    // ── Who is put under it ─────────────────────────────────────────────────

    func testEveryMemberOfTheKeptGroupsAndTheGroupsLeftRunningIsPutUnderIt() {
        let members = UltraThrottle.members(kept: [group("com.example.editor", [10, 11])],
                                            leftRunning: [group("com.example.cloud", [40])],
                                            processes: [process(10), process(11), process(40)])
        XCTAssertEqual(members, [member(10), member(11), member(40)])
    }

    func testGroupsLeftRunningAreIncluded() {
        let members = UltraThrottle.members(kept: [], leftRunning: [group("com.example.cloud", [40, 42])], processes: [])
        XCTAssertEqual(pids(members), [40, 42], "an app with a part Anode cannot freeze still runs, so it is kept to the efficiency cores")
    }

    func testAGroupInWhichAnyProcessIsOnTheMicrophoneOrCameraIsLeftOut() {
        let members = UltraThrottle.members(
            kept: [group("com.example.editor", [10, 11]), group("com.example.calls", [60, 61, 62])],
            leftRunning: [group("com.example.cloud", [40]), group("com.example.recorder", [70, 71])],
            processes: [process(10), process(11), process(60), process(61, onCall: true), process(62),
                        process(40), process(70), process(71, onCall: true)])
        XCTAssertEqual(pids(members), [10, 11, 40],
                       "one process on a call keeps the whole group at full speed, helpers included: a call's audio and video must not stutter")
    }

    /// A group that is not on a call is not left out because another group is.
    func testOnlyTheGroupOnACallIsLeftOut() {
        let members = UltraThrottle.members(kept: [group("a", [1]), group("b", [2])], leftRunning: [],
                                            processes: [process(1, onCall: true), process(2)])
        XCTAssertEqual(pids(members), [2])
    }

    /// Whether a process is on a call is read by pid AND start time: a pid that was recycled since is another process, and what
    /// it is doing says nothing about the group.
    func testACallOnARecycledPidDoesNotLeaveTheGroupOut() {
        let members = UltraThrottle.members(kept: [group("a", [1, 2])], leftRunning: [],
                                            processes: [process(1, onCall: true, startTime: 99_999), process(2)])
        XCTAssertEqual(pids(members), [1, 2], "pid 1 on the call is not the process the group named")
    }

    /// A group member the list does not hold (it ended since) is no evidence either way.
    func testAMemberTheListDoesNotHoldChangesNothing() {
        let members = UltraThrottle.members(kept: [group("a", [1, 2])], leftRunning: [], processes: [process(2)])
        XCTAssertEqual(pids(members), [1, 2])
    }

    func testSortedByPidWithNoRepeats() {
        // The same group named twice, and a process that is in both lists: it is put under the policy once.
        let members = UltraThrottle.members(kept: [group("b", [30, 10]), group("b", [10, 30])], leftRunning: [group("c", [20, 10])],
                                            processes: [])
        XCTAssertEqual(members, [member(10), member(20), member(30)])
    }

    func testNothingKeptAndNothingLeftRunningIsNothing() {
        XCTAssertEqual(UltraThrottle.members(kept: [], leftRunning: [], processes: [process(1)]), [])
    }
}

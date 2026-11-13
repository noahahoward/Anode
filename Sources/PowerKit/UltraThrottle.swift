import Foundation

/// Which processes Ultra Low Power Mode puts under the system's background policy, which on Apple silicon confines all of a
/// process's threads to the efficiency cores. No system calls: it is given the plan's groups and the process list.
public enum UltraThrottle {

    /// Whether this Mac has efficiency cores: more than one performance level. Read from the processor's levels and not from
    /// a model list, so a Mac that is not known yet is still judged right.
    public static func hasEfficiencyCores(performanceLevels: Int) -> Bool {
        performanceLevels >= 2
    }

    /// The processes to put under the background policy: every member of the kept groups and of the groups left running,
    /// except a group in which any process is using the microphone or camera (a call's audio and video must not stutter).
    /// Sorted by pid, no repeats.
    ///
    /// Whether a process is on a call is read from `processes`, by pid AND start time: a pid that was recycled since says
    /// nothing about the group.
    public static func members(kept: [FreezeGroup], leftRunning: [FreezeGroup], processes: [UltraProcess]) -> [FreezeGroup.Member] {
        let onACall = Set(processes.filter(\.usesMicOrCamera).map { Identity(pid: $0.pid, startTime: $0.startTime) })
        var seen: Set<Identity> = []
        var members: [FreezeGroup.Member] = []
        for group in kept + leftRunning {
            // One process on a call keeps its whole group at full speed: the helpers carry the audio and the video too.
            if group.members.contains(where: { onACall.contains(Identity($0)) }) { continue }
            for member in group.members where seen.insert(Identity(member)).inserted { members.append(member) }
        }
        return members.sorted { ($0.pid, $0.startTime) < ($1.pid, $1.startTime) }
    }

    /// A process is its pid with its start time: a recycled pid is another process.
    private struct Identity: Hashable {
        let pid: pid_t
        let startTime: UInt64
        init(pid: pid_t, startTime: UInt64) {
            self.pid = pid
            self.startTime = startTime
        }
        init(_ member: FreezeGroup.Member) { self.init(pid: member.pid, startTime: member.startTime) }
    }
}

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

    /// Every living descendant of `roots`, found by parent pid in one read of the process table: what a process under the
    /// background policy started has inherited the policy (a child follows its parent), and is on no record, so left alone it
    /// stays on the efficiency cores until it exits.
    ///
    /// A root counts only if the table holds that pid with that start time: a recorded pid that was recycled since is another
    /// process, and what it started is nobody's the mode knows. A root that has ended has no children to find (the system gave
    /// them to launchd). The roots themselves are not in the answer, however they are related: the caller has them. Sorted by pid,
    /// no repeats, and a table that loops (a process its own parent, two the parent of each other) ends the walk.
    public static func descendants(of roots: [FreezeGroup.Member], in processes: [UltraProcess]) -> [FreezeGroup.Member] {
        var held: [pid_t: UltraProcess] = [:]
        for process in processes where held[process.pid] == nil { held[process.pid] = process }
        var children: [pid_t: [UltraProcess]] = [:]
        for process in held.values { children[process.parent, default: []].append(process) }

        // Every root that is still the recorded process is seen before the walk begins, so a root that is also the child of another
        // is not in the answer, and a loop in the table runs into a pid already seen.
        var seen: Set<pid_t> = []
        var pending: [pid_t] = []
        for root in roots where held[root.pid]?.startTime == root.startTime {
            if seen.insert(root.pid).inserted { pending.append(root.pid) }
        }
        var found: [FreezeGroup.Member] = []
        while let next = pending.popLast() {
            for child in children[next] ?? [] where child.pid > 1 && seen.insert(child.pid).inserted {
                pending.append(child.pid)
                found.append(FreezeGroup.Member(pid: child.pid, startTime: child.startTime))
            }
        }
        return found.sorted { $0.pid < $1.pid }
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

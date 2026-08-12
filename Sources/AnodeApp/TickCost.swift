import Foundation
import PowerKit

/// What one sampling tick cost, in CPU rather than wall time.
///
/// The app's background floor — what it costs all day with the window shut or
/// covered — is a light tick every 8 s plus one full tick a minute. Total CPU
/// over a minute cannot tell those apart, and they differ by more than an order
/// of magnitude, so the number that decides where to spend effort is the one an
/// outside measurement cannot see. Wall time is no good either: this queue
/// blocks on syscalls and IOKit round trips, and time spent asleep is time the
/// battery does not pay for.
///
/// Off unless `ANODE_LOG_TICKS=1`, so it costs one environment read per tick
/// when nobody has asked. The same shape as `ANODE_LOG_VISIBILITY` — the two
/// questions this app cannot answer about itself from outside.
enum TickCost {

    static let enabled = ProcessInfo.processInfo.environment["ANODE_LOG_TICKS"] == "1"

    /// CPU consumed by the CALLING THREAD. The sampling queue is serial, so a
    /// block stays on the thread it started on and the difference is this tick's
    /// own work — not the machine's, and not another queue's.
    static func now() -> UInt64 {
        guard enabled else { return 0 }
        return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    }

    static func log(kind: String, visible: Bool,
                    needs: SystemMetrics.Needs, since start: UInt64) {
        guard enabled, start != 0 else { return }
        let ms = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- start) / 1e6
        NSLog(String(format: "anode.tick %@ %@ needs=%@ cpu=%.1fms",
                     kind, visible ? "visible" : "hidden", describe(needs), ms))
    }

    /// Which subsystems this tick actually paid for — the thing `Needs` exists to
    /// keep small, and therefore the thing worth printing beside the cost.
    private static func describe(_ n: SystemMetrics.Needs) -> String {
        let names: [(SystemMetrics.Needs, String)] = [
            (.cpu, "cpu"), (.memory, "mem"), (.gpu, "gpu"),
            (.network, "net"), (.sensors, "sensors"), (.disk, "disk"),
        ]
        let on = names.filter { n.contains($0.0) }.map(\.1)
        return on.isEmpty ? "none" : on.joined(separator: "+")
    }
}

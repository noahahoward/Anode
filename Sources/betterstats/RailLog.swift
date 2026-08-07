import Foundation
import CoreGraphics
import PowerKit

/// Passive rail recorder. Emits CSV of every P* float rail at a fixed cadence.
///
/// The point is structural rather than experimental: if some subset of rails sums
/// to the system total across hundreds of independent samples spanning a wide
/// range of load, that identity is a decomposition of the total — and unlike a
/// driven experiment it costs nothing, disturbs nothing, and cannot be confounded
/// by waking the very subsystem it is trying to hold still.
///
/// Rails are enumerated once and then read by key. A full `scan()` walks every SMC
/// key by index, which is hundreds of IOKit round trips; at a multi-second cadence
/// over hours that would put this tool into its own measurements.
enum RailLog {

    static func run(seconds: Double, interval: Double) {
        guard let smc = SMC() else { FileHandle.standardError.write("SMC unavailable\n".data(using: .utf8)!); exit(1) }

        let keys = smc.scan()
            .filter { $0.key.hasPrefix("P") && $0.type == "flt" && $0.value.isFinite }
            .map(\.key).sorted()
        guard !keys.isEmpty else { FileHandle.standardError.write("no P* rails\n".data(using: .utf8)!); exit(1) }

        // Display state is the reason this log runs overnight rather than for a
        // few minutes. An idle Mac blanks its own screen, which is a large, clean,
        // zero-intervention step change in exactly the subsystem we cannot
        // otherwise isolate — provided something is recording when it happens.
        print((["t", "soc", "onBattery", "displayOff"] + keys).joined(separator: ","))

        let t0 = Date()
        let end = t0.addingTimeInterval(seconds)
        while Date() < end {
            let b = Battery.state()
            var row = [String(format: "%.1f", Date().timeIntervalSince(t0)),
                       b.map { String($0.percent) } ?? "",
                       b.map { $0.onAC ? "0" : "1" } ?? "",
                       CGDisplayIsAsleep(CGMainDisplayID()) != 0 ? "1" : "0"]
            for k in keys {
                let v = smc.read(k)?.value
                row.append(v.map { $0.isFinite ? String(format: "%.4f", $0) : "" } ?? "")
            }
            print(row.joined(separator: ","))
            // Flushed every row so an interrupted run still yields usable data —
            // an overnight log that dies with the machine should not lose the night.
            fflush(stdout)
            Thread.sleep(forTimeInterval: interval)
        }
    }
}

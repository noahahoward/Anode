import Foundation

/// What Anode measures about an app that macOS lists under "Using Significant Energy": the drain, the processor and the memory it
/// holds, and the minutes of battery quitting it would buy back (the same figures as the Processes table).
public struct EnergyStats: Equatable {
    /// Percent of a full battery per hour, from the app's measured CPU energy.
    public var pctPerHour: Double
    /// Percent of the whole processor, across every core.
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public var minutesBack: Double?

    public init(pctPerHour: Double, cpuPercent: Double, memoryBytes: UInt64, minutesBack: Double?) {
        self.pctPerHour = pctPerHour; self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes; self.minutesBack = minutesBack
    }

    private var drainText: String { pctPerHour < 0.01 ? "<0.01" : String(format: "%.2f", pctPerHour) }
    private var cpuText: String { cpuPercent < 10 ? String(format: "%.1f", cpuPercent) : String(format: "%.0f", cpuPercent) }

    /// The line on the right of the app's row.
    public var rowText: String { "\(drainText) %/hr · \(cpuText)% CPU" }

    /// Everything, for the tooltip.
    public var tooltip: String {
        var lines = ["\(drainText) %/hr of a full battery", "\(cpuText)% of the CPU"]
        if memoryBytes > 0 { lines.append(String(format: "%.1f GB memory", Double(memoryBytes) / 1e9)) }
        if let m = minutesBack {
            let time = m >= 60 ? String(format: "%dh %02dm", Int(m / 60), Int(m) % 60) : String(format: "%.0f min", m)
            lines.append("Quitting it would add about \(time) of battery")
        }
        return lines.joined(separator: "\n")
    }
}

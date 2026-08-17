import Foundation

/// Which metrics the stats panel shows, and in what order.
///
/// Three inputs and one rule. The inputs: the user's saved arrangement (empty
/// until they touch the editor), their hidden set, and whatever metrics this
/// build actually registered. The rule: the user's arrangement wins wherever it
/// speaks, the default below speaks everywhere else, and nothing is silently
/// dropped — a saved ID this build doesn't know is carried (it may belong to a
/// module that isn't loaded), and a registered metric the saved order has never
/// seen slots in at its DEFAULT position rather than dangling at the end.
public enum PanelOrder {

    /// The default arrangement: grouped by SUBJECT, not by data source.
    ///
    /// The registry's categories put every temperature in a "Sensors" block at
    /// the bottom of the panel, three groups away from the load each one
    /// belongs to — CPU usage near the top, CPU temperature far below it,
    /// answering one question ("what is the CPU doing?") in two places.
    /// Requested from the field: each temperature directly under its load, the
    /// fan (the machine's RESPONSE to those temperatures) riding with them.
    ///
    /// GPU drain stays in the battery block: it is an attribution of drain,
    /// not a reading of load, and it answers "where is the charge going?"
    /// alongside the rest of the battery answers.
    public static let defaultOrder: [MetricID] = [
        .batteryDrain, .batteryPercent, .batteryTimeLeft,
        .gpuDrain, .unattributedShare, .processCoverage,
        .cpuUsage, .cpuTemperature,
        .memoryUsage,
        .gpuUsage, .gpuTemperature, .fanSpeed,
        .networkThroughput, .networkDown, .networkUp,
        .diskActivity, .diskRead, .diskWrite,
        .samplerDrops,
    ]

    /// The full editing order, hidden rows included: everything the saved order
    /// says, in its words, plus every available metric it has never seen,
    /// inserted where the default would put it.
    ///
    /// Insertion is "after the nearest default-order predecessor the list
    /// already contains": if the user moved Memory above CPU before CPU
    /// temperature existed, CPU temperature still lands directly under CPU
    /// usage, because that is the relationship the default encodes and the user
    /// never said otherwise.
    public static func fullOrder(saved: [String], available: [MetricID]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for raw in saved where seen.insert(raw).inserted { out.append(raw) }

        let availableSet = Set(available.map(\.rawValue))
        // Default-known metrics first, in default order, so each insertion can
        // anchor on neighbours that are already placed…
        for id in defaultOrder {
            let raw = id.rawValue
            guard availableSet.contains(raw), seen.insert(raw).inserted else { continue }
            let defaultIndex = defaultOrder.firstIndex(of: id)!
            let predecessors = defaultOrder[..<defaultIndex].reversed().map(\.rawValue)
            if let anchor = predecessors.compactMap({ out.firstIndex(of: $0) }).first {
                out.insert(raw, at: anchor + 1)
            } else {
                out.insert(raw, at: 0)
            }
        }
        // …then metrics the default has never heard of (a future subsystem),
        // appended in the registry's own order rather than lost.
        for id in available where seen.insert(id.rawValue).inserted {
            out.append(id.rawValue)
        }
        return out
    }

    /// What the panel actually renders: the full order, minus hidden rows,
    /// minus IDs this build cannot render.
    public static func visible(saved: [String], hidden: [String],
                               available: [MetricID]) -> [String] {
        let availableSet = Set(available.map(\.rawValue))
        let hiddenSet = Set(hidden)
        return fullOrder(saved: saved, available: available)
            .filter { availableSet.contains($0) && !hiddenSet.contains($0) }
    }
}

import Foundation

/// Whole-system power draw — the conservation anchor.
///
/// Source: `AppleSmartBattery` -> `PowerTelemetryData`. No root, no entitlement,
/// and unlike `InstantAmperage` it keeps working while on AC.
///
/// TWO TRAPS, both measured on this hardware:
///
/// 1. The IORegistry publishes ONE BATCH OF 60 TICKS ROUGHLY EVERY 60 SECONDS.
///    The internal counter runs at 1 Hz but you only ever observe it in 60-tick
///    jumps. Detect a new window by watching `accumulatorCount` CHANGE — never by
///    dividing by wall-clock time between polls. 60 s is the honest resolution
///    floor for battery-measured watts; IOReport covers sub-second needs.
///
/// 2. The cumulative ratio is the machine's LIFETIME average (~1880 mW here), not
///    current draw. Only deltas mean anything.
public struct PowerTelemetry {
    public let accumulatedSystemLoad: UInt64
    public let accumulatorCount: UInt64
    /// Scalar snapshot taken at publish time. Cross-check only; the delta ratio is
    /// the true 60 s mean and the two have been observed to disagree by 2-13%.
    public let systemLoad_mW: Double
    public let timestamp: Date

    public static func sample() -> PowerTelemetry? {
        guard let props = Battery.properties(),
              let t = props["PowerTelemetryData"] as? [String: Any] else { return nil }

        func u64(_ key: String) -> UInt64 {
            (t[key] as? NSNumber)?.uint64Value ?? 0
        }

        let count = u64("SystemLoadAccumulatorCount")
        guard count > 0 else { return nil }

        return PowerTelemetry(
            accumulatedSystemLoad: u64("AccumulatedSystemLoad"),
            accumulatorCount: count,
            systemLoad_mW: Double(u64("SystemLoad")),
            timestamp: Date()
        )
    }
}

public struct SystemPowerWindow {
    public let power_mW: Double
    public let ticks: UInt64
    public let span: TimeInterval

    /// Returns nil when no new batch has been published yet — the correct answer is
    /// "not yet known", never a number derived from wall-clock division.
    public static func between(_ a: PowerTelemetry, _ b: PowerTelemetry) -> SystemPowerWindow? {
        // Counters wrap. `AdapterEfficiencyLoss` has been observed at 2^64-119 in a
        // live sample, so every monotonic counter uses wrapping arithmetic.
        let dCount = b.accumulatorCount &- a.accumulatorCount
        guard dCount > 0 else { return nil }
        let dLoad = b.accumulatedSystemLoad &- a.accumulatedSystemLoad

        return SystemPowerWindow(
            power_mW: Double(dLoad) / Double(dCount),
            ticks: dCount,
            span: b.timestamp.timeIntervalSince(a.timestamp)
        )
    }
}

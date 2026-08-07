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
    /// 200 W. Above this is a counter artefact, not a measurement.
    public static let maxPlausible_mW = 200_000.0
    /// The accumulator ticks at 1 Hz, so more than a day of them between two
    /// samples means the counter restarted rather than that we slept for a week.
    public static let maxPlausibleTicks: UInt64 = 86_400

    public let power_mW: Double
    public let ticks: UInt64
    public let span: TimeInterval

    /// Returns nil when no new batch has been published yet — the correct answer is
    /// "not yet known", never a number derived from wall-clock division.
    public static func between(_ a: PowerTelemetry, _ b: PowerTelemetry) -> SystemPowerWindow? {
        // Counters wrap. `AdapterEfficiencyLoss` has been observed at 2^64-119 in a
        // live sample, so every monotonic counter uses wrapping arithmetic.
        let dCount = b.accumulatorCount &- a.accumulatorCount
        guard dCount > 0, dCount < maxPlausibleTicks else { return nil }

        let dLoad = b.accumulatedSystemLoad &- a.accumulatedSystemLoad

        // Plausibility, not sign, is what separates a wrap from a reset — and the
        // distinction matters because `&-` renders them identically.
        //
        // A genuine 2^64 wrap leaves a SMALL delta: the counter passed the top and
        // came back round, so the wrapped subtraction is the true energy and the
        // mean is an ordinary number. A RESET to near zero leaves a delta of
        // almost 2^64, which is ~3e14 W over 60 ticks.
        //
        // So the rule is not "reject a decrease" — that would throw away real
        // wraps — but "reject an impossible answer". Whatever produced it.
        //
        // This is not hypothetical. Four rows reached the history store holding
        // energies around 1.8e16 J, one of them 2^63 scaled, and a single such row
        // dominates every SUM it lands in. The graph drew 1e+15 %/hr before anyone
        // noticed, and the stored totals were wrong for as long as they sat there.
        let mW = Double(dLoad) / Double(dCount)
        guard mW.isFinite, mW >= 0, mW <= maxPlausible_mW else { return nil }

        return SystemPowerWindow(
            power_mW: mW,
            ticks: dCount,
            span: b.timestamp.timeIntervalSince(a.timestamp)
        )
    }
}

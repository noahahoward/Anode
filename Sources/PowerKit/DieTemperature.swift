import Foundation

// ── Steadying the die temperatures ──────────────────────────────────────────
//
// The CPU figure is a mean over the core sensors that read as a real die (>= 15 °C), swept
// every few seconds. On a big chip with dozens of sensors that is steady. Reported from a
// MacBook Neo (a small fanless chip with few sensors): the figure swung between 62 and 76 °C
// from one reading to the next, and the sidebar's red alarm pulsed as soon as the app opened.
// Both follow from the same property of a MEAN OVER A CHANGING SET: a power-gated core that
// reads cold on one sweep and warm on the next, or a sensor that flickers across the 15 °C
// floor, moves the mean by several degrees on its own, and with only a handful of sensors one
// of them is a large share of it. A single transient high reading is enough for the alarm.
//
// What is done about it here, none of which changes what a steady machine shows:
// - a sensor that was a die a moment ago and is missing, or reads as a dead slot, keeps its last
//   good value for `holdSeconds`, so the set the mean is taken over stops changing on every sweep;
// - the mean and the peak are each smoothed with a time constant, so one odd sweep moves them a
//   little, not all the way;
// - the alarm (`TemperatureAlarm`) needs the smoothed peak to stay hot for a while, and clears
//   with a margin, so it neither fires on a transient nor flickers at the threshold.
// The real sensor values were not available when this was written: `anode --temps` prints them,
// each second, so the cause on that machine can be confirmed rather than assumed.

public struct DieTemperatureFilter {

    /// How long a sensor that has gone missing or dead keeps its last good value.
    public static let holdSeconds: TimeInterval = 12
    /// The smoothing time constant: about two thirds of a step change shows after this long.
    public static let timeConstant: TimeInterval = 8
    /// Below this a reading is a dead slot, not a die (see `Sensors.Inventory.dieFloor`).
    public static let dieFloor: Double = 15
    /// A silicon die is never above this; a reading past it is a decode error, not a temperature.
    public static let dieCeiling: Double = 130

    private var held: [String: (value: Double, at: Date)] = [:]
    private var smoothedMean: Double?
    private var smoothedPeak: Double?
    private var lastUpdate: Date?

    public init() {}

    /// Take one sweep's `readings` (every sensor of the family, whatever it read) and return the
    /// steadied mean and peak, or nil when no sensor has been a die within `holdSeconds`.
    public mutating func update(_ readings: [(key: String, value: Double)],
                                now: Date = Date()) -> (mean: Double, peak: Double)? {
        for r in readings where r.value >= Self.dieFloor && r.value <= Self.dieCeiling {
            held[r.key] = (r.value, now)
        }
        held = held.filter { now.timeIntervalSince($0.value.at) <= Self.holdSeconds }
        let values = held.values.map(\.value)
        guard !values.isEmpty else {
            smoothedMean = nil; smoothedPeak = nil; lastUpdate = nil
            return nil
        }
        let mean = values.reduce(0, +) / Double(values.count), peak = values.max()!
        // The first reading, and one after a gap, start the average where the reading is.
        let dt = lastUpdate.map { now.timeIntervalSince($0) } ?? .infinity
        let alpha = dt.isFinite && dt < 5 * Self.timeConstant ? 1 - exp(-dt / Self.timeConstant) : 1
        smoothedMean = smoothedMean.map { $0 + alpha * (mean - $0) } ?? mean
        smoothedPeak = smoothedPeak.map { $0 + alpha * (peak - $0) } ?? peak
        lastUpdate = now
        return (smoothedMean!, smoothedPeak!)
    }
}

/// Decides whether the heat alarm is on. Pure state, no clock of its own, for tests.
public struct TemperatureAlarm {
    /// On at or above this, held for `sustain` seconds.
    public static let threshold: Double = 90
    /// Off again only below this, so a reading at the threshold does not flicker.
    public static let clearBelow: Double = 85
    public static let sustain: TimeInterval = 10

    public private(set) var isOn = false
    private var hotSince: Date?

    public init() {}

    /// Feed the latest (already smoothed) peak; returns whether the alarm should be on.
    @discardableResult
    public mutating func update(_ celsius: Double?, now: Date = Date()) -> Bool {
        guard let celsius else { hotSince = nil; isOn = false; return false }
        if isOn {
            if celsius < Self.clearBelow { isOn = false; hotSince = nil }
        } else if celsius >= Self.threshold {
            let since = hotSince ?? now
            hotSince = since
            if now.timeIntervalSince(since) >= Self.sustain { isOn = true }
        } else {
            hotSince = nil
        }
        return isOn
    }
}

import Foundation

/// The person's charge settings as the policy sees them, read once per decision so a change
/// mid-decision cannot split it.
public struct ChargeSettingsSnapshot: Equatable {
    /// The person's charge limit, 20…100.
    public var limit: Int
    public var driftEnabled: Bool
    /// How far below the limit Drift Below the Limit rests before charging again, 1…30.
    public var driftGap: Int
    public var pauseWhenHotEnabled: Bool
    public var maxTemperatureC: Double
    public var holdDuringSleep: Bool
    public var drainAutomatically: Bool

    public init(limit: Int,
                driftEnabled: Bool, driftGap: Int,
                pauseWhenHotEnabled: Bool, maxTemperatureC: Double,
                holdDuringSleep: Bool, drainAutomatically: Bool) {
        self.limit = limit
        self.driftEnabled = driftEnabled
        self.driftGap = driftGap
        self.pauseWhenHotEnabled = pauseWhenHotEnabled
        self.maxTemperatureC = maxTemperatureC
        self.holdDuringSleep = holdDuringSleep
        self.drainAutomatically = drainAutomatically
    }
}

public struct ChargeInputs: Equatable {
    public var percent: Int
    public var onAC: Bool
    /// nil when the pack's temperature could not be read.
    public var temperatureC: Double?
    /// True between willSleep and didWake.
    public var sleeping: Bool
    /// The person pressed Charge to Full and has not unplugged since.
    public var fullCharge: Bool
    /// The person pressed Drain to Limit and it has not finished.
    public var manualDrain: Bool
    public var now: Date

    public init(percent: Int, onAC: Bool, temperatureC: Double?,
                sleeping: Bool, fullCharge: Bool, manualDrain: Bool, now: Date) {
        self.percent = percent
        self.onAC = onAC
        self.temperatureC = temperatureC
        self.sleeping = sleeping
        self.fullCharge = fullCharge
        self.manualDrain = manualDrain
        self.now = now
    }
}

/// What the policy must remember between calls. The controller carries it; the policy only
/// reads and updates it, so it never keeps hidden state of its own.
public struct ChargeMemory: Equatable {
    /// True = resting inside the drift band. Needed because "rest until the charge falls to the
    /// bottom of the band" cannot be read off one percentage.
    public var driftPhase: Bool = false
    /// Set while Pause When Hot is holding the charge.
    public var heatPausedSince: Date? = nil
    /// When the pack was first seen cool again after a pause; the five minutes run from here.
    public var coolSince: Date? = nil
    public init() {}
}

public enum ChargeReason: String {
    case limit, fullCharge, heat, sleeping, drift, draining, drained
}

public struct ChargeDecision: Equatable {
    /// What macOS's charge limit should be, 20…100.
    public var osLimit: Int
    /// Drain to this percent through the helper. nil = adapter connected, no discharge.
    public var dischargeTo: Int?
    public var reason: ChargeReason
    /// The controller should clear its Charge to Full flag.
    public var endFullCharge: Bool
    /// The controller should clear its manual-drain flag.
    public var endManualDrain: Bool

    public init(osLimit: Int, dischargeTo: Int?, reason: ChargeReason,
                endFullCharge: Bool = false, endManualDrain: Bool = false) {
        self.osLimit = osLimit
        self.dischargeTo = dischargeTo
        self.reason = reason
        self.endFullCharge = endFullCharge
        self.endManualDrain = endManualDrain
    }
}

/// What Charge Control wants from the charger right now, for every charge feature at once.
///
/// ONE pure function decides this (the limit, Charge to Full, Pause When Hot, Hold Level During Sleep, Drain to
/// Limit and Drain Automatically Above the Limit, Drift Below the Limit) so the features cannot disagree and the
/// whole matrix of them is testable without a Mac. The controller that applies the answer to macOS's charge limit
/// and the root helper never re-decides anything.
///
/// Rules, first match wins:
///
///  1. Unplugged: Charge to Full and a manual drain both end; back to the user's limit.
///  2. Charge to Full: charge to 100 until the adapter is unplugged.
///  3. Heat: while the pack is hot, and for five minutes after it cools, hold the charge where it is, or at the
///     limit if it is above it.
///  4. Sleeping with Hold Level During Sleep: hold at the current charge.
///  5. A drain (pressed, or automatic above the limit): drain to the limit.
///  6. Drift: once the limit is reached, rest inside the band below it.
///  7. Otherwise: the user's limit.
///
/// Heat sits above a drain on purpose: a drain runs the machine from the pack, and that
/// current heats a pack that is already hot, so nothing that adds heat may run while it is.
/// Charge to Full sits above Heat because it is an explicit request for this one charge; it ends on unplug.
public enum ChargePolicy {
    /// macOS's charge limit never goes below 20 or above 100, whatever the person asked for.
    public static let osLimitRange = 20...100
    /// How long the pack must stay cool before Pause When Hot lets charging resume. Without
    /// it a pack hovering at the threshold would flip the charger on and off every reading.
    public static let heatResumeAfter: TimeInterval = 300
    public static let defaultDriftGap = 5
    public static let driftGapRange = 1...30
    public static let defaultMaxTemperatureC = 35.0
    /// A discharge never drains below this, whatever the limit.
    public static let dischargeFloor = 10

    /// Where a discharge stops. The floor only bites if the limit is ever allowed below 10; the
    /// limit's own minimum is 20, so it is a separate function to be pinned directly.
    public static func dischargeTarget(limit: Int) -> Int {
        max(limit, dischargeFloor)
    }

    public static func decide(_ s: ChargeSettingsSnapshot, _ i: ChargeInputs, _ m: inout ChargeMemory) -> ChargeDecision {
        func clamped(_ p: Int) -> Int { min(max(p, osLimitRange.lowerBound), osLimitRange.upperBound) }
        // Every holding rule below passes the raw charge or limit; this is where the 20…100 range is enforced.
        func decision(_ osLimit: Int, _ reason: ChargeReason, dischargeTo: Int? = nil,
                      endManualDrain: Bool = false) -> ChargeDecision {
            ChargeDecision(osLimit: clamped(osLimit), dischargeTo: dischargeTo, reason: reason,
                           endManualDrain: endManualDrain)
        }

        // 1. Unplugged. Nothing can charge or discharge through the adapter, and both requests
        //    were for this connection only.
        guard i.onAC else {
            return ChargeDecision(osLimit: clamped(s.limit), dischargeTo: nil, reason: .limit,
                                  endFullCharge: true, endManualDrain: true)
        }

        // 2. Charge to Full.
        if i.fullCharge {
            return decision(100, .fullCharge)
        }

        // 3. Heat. A paused state must not outlive the setting, or turning it back on later
        //    would resume a stale pause on a pack that is cool.
        if s.pauseWhenHotEnabled {
            if let t = i.temperatureC {
                if t >= s.maxTemperatureC {
                    if m.heatPausedSince == nil { m.heatPausedSince = i.now }
                    m.coolSince = nil
                } else if m.heatPausedSince != nil {
                    if m.coolSince == nil { m.coolSince = i.now }
                    if let cool = m.coolSince, i.now.timeIntervalSince(cool) >= heatResumeAfter {
                        m.heatPausedSince = nil
                        m.coolSince = nil
                    }
                }
            }
            // No reading: neither hot nor confirmed cool, so a pause holds and its clock stands still. Held where
            // the charge is, but never above the person's own limit: above it, the pause would let the Mac charge
            // further while hot (and without the helper macOS rounds a held 91 up to 95).
            if m.heatPausedSince != nil {
                return decision(min(s.limit, i.percent), .heat)
            }
        } else {
            m.heatPausedSince = nil
            m.coolSince = nil
        }

        // 4. Sleeping.
        if s.holdDuringSleep && i.sleeping {
            return decision(min(s.limit, i.percent), .sleeping)
        }

        // 5. Drain.
        if i.manualDrain || (s.drainAutomatically && i.percent > s.limit) {
            let target = dischargeTarget(limit: s.limit)
            if i.percent > target {
                return decision(s.limit, .draining, dischargeTo: target)
            }
            return decision(s.limit, .drained, endManualDrain: true)
        }

        // 6. Drift. The gap is clamped so a bad setting cannot make the band empty or endless.
        if s.driftEnabled {
            let gap = min(max(s.driftGap, driftGapRange.lowerBound), driftGapRange.upperBound)
            if i.percent >= s.limit {
                m.driftPhase = true
            } else if i.percent <= s.limit - gap {
                m.driftPhase = false
            }
            if m.driftPhase {
                return decision(min(s.limit, i.percent), .drift)
            }
        } else {
            m.driftPhase = false
        }

        // 7. Otherwise.
        return decision(s.limit, .limit)
    }
}

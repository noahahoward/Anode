import Foundation

/// The person's charge settings as the policy sees them, read once per decision so a change
/// mid-decision cannot split it.
public struct ChargeSettingsSnapshot: Equatable {
    /// The person's charge limit, 20…100.
    public var limit: Int
    public var sailingEnabled: Bool
    /// How far below the limit Sailing Mode rests before charging again, 1…30.
    public var sailingGap: Int
    public var heatProtectionEnabled: Bool
    public var maxTemperatureC: Double
    public var stopWhenSleeping: Bool
    public var automaticDischarge: Bool

    public init(limit: Int,
                sailingEnabled: Bool, sailingGap: Int,
                heatProtectionEnabled: Bool, maxTemperatureC: Double,
                stopWhenSleeping: Bool, automaticDischarge: Bool) {
        self.limit = limit
        self.sailingEnabled = sailingEnabled
        self.sailingGap = sailingGap
        self.heatProtectionEnabled = heatProtectionEnabled
        self.maxTemperatureC = maxTemperatureC
        self.stopWhenSleeping = stopWhenSleeping
        self.automaticDischarge = automaticDischarge
    }
}

public struct ChargeInputs: Equatable {
    public var percent: Int
    public var onAC: Bool
    /// nil when the pack's temperature could not be read.
    public var temperatureC: Double?
    /// True between willSleep and didWake.
    public var sleeping: Bool
    /// The person pressed Top Up and has not unplugged since.
    public var topUp: Bool
    /// The person pressed Discharge and it has not finished.
    public var manualDischarge: Bool
    public var now: Date

    public init(percent: Int, onAC: Bool, temperatureC: Double?,
                sleeping: Bool, topUp: Bool, manualDischarge: Bool, now: Date) {
        self.percent = percent
        self.onAC = onAC
        self.temperatureC = temperatureC
        self.sleeping = sleeping
        self.topUp = topUp
        self.manualDischarge = manualDischarge
        self.now = now
    }
}

/// What the policy must remember between calls. The controller carries it; the policy only
/// reads and updates it, so it never keeps hidden state of its own.
public struct ChargeMemory: Equatable {
    /// True = resting inside the sail band. Needed because "rest until the charge falls to the
    /// bottom of the band" cannot be read off one percentage.
    public var sailingPhase: Bool = false
    /// Set while Heat Protection is holding the charge.
    public var heatPausedSince: Date? = nil
    /// When the pack was first seen cool again after a pause; the five minutes run from here.
    public var coolSince: Date? = nil
    public init() {}
}

public enum ChargeReason: String {
    case limit, topUp, heat, sleeping, sailing, discharging, discharged
}

public struct ChargeDecision: Equatable {
    /// What macOS's charge limit should be, 20…100.
    public var osLimit: Int
    /// Drain to this percent through the helper. nil = adapter connected, no discharge.
    public var dischargeTo: Int?
    public var reason: ChargeReason
    /// The controller should clear its Top Up flag.
    public var endTopUp: Bool
    /// The controller should clear its manual-discharge flag.
    public var endManualDischarge: Bool

    public init(osLimit: Int, dischargeTo: Int?, reason: ChargeReason,
                endTopUp: Bool = false, endManualDischarge: Bool = false) {
        self.osLimit = osLimit
        self.dischargeTo = dischargeTo
        self.reason = reason
        self.endTopUp = endTopUp
        self.endManualDischarge = endManualDischarge
    }
}

/// What Charge Control wants from the charger right now, for every charge feature at once.
///
/// ONE pure function decides this (the limit, Top Up, Heat Protection, Stop Charging when
/// Sleeping, Discharge and Automatic Discharge, Sailing Mode) so the features cannot disagree
/// and the whole matrix of them is testable without a Mac. The controller that applies the
/// answer to macOS's charge limit and the root helper never re-decides anything.
///
/// Rules, first match wins:
///
///  1. Unplugged: Top Up and a manual discharge both end; back to the user's limit.
///  2. Top Up: charge to 100 until the adapter is unplugged.
///  3. Heat: while the pack is hot, and for five minutes after it cools, hold the charge where it is.
///  4. Sleeping with Stop Charging when Sleeping: hold at the current charge.
///  5. Discharge (manual, or automatic above the limit): drain to the limit.
///  6. Sailing: once the limit is reached, rest inside the band below it.
///  7. Otherwise: the user's limit.
///
/// Heat sits above Discharge on purpose: a discharge runs the machine from the pack, and that
/// current heats a pack that is already hot, so nothing that adds heat may run while it is.
/// Top Up sits above Heat because it is an explicit request for this one charge; it ends on unplug.
public enum ChargePolicy {
    /// macOS's charge limit never goes below 20 or above 100, whatever the person asked for.
    public static let osLimitRange = 20...100
    /// How long the pack must stay cool before Heat Protection lets charging resume. Without
    /// it a pack hovering at the threshold would flip the charger on and off every reading.
    public static let heatResumeAfter: TimeInterval = 300
    public static let defaultSailingGap = 5
    public static let sailingGapRange = 1...30
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
                      endManualDischarge: Bool = false) -> ChargeDecision {
            ChargeDecision(osLimit: clamped(osLimit), dischargeTo: dischargeTo, reason: reason,
                           endManualDischarge: endManualDischarge)
        }

        // 1. Unplugged. Nothing can charge or discharge through the adapter, and both requests
        //    were for this connection only.
        guard i.onAC else {
            return ChargeDecision(osLimit: clamped(s.limit), dischargeTo: nil, reason: .limit,
                                  endTopUp: true, endManualDischarge: true)
        }

        // 2. Top Up.
        if i.topUp {
            return decision(100, .topUp)
        }

        // 3. Heat. A paused state must not outlive the setting, or turning it back on later
        //    would resume a stale pause on a pack that is cool.
        if s.heatProtectionEnabled {
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
            // No reading: neither hot nor confirmed cool, so a pause holds and its clock stands still.
            if m.heatPausedSince != nil {
                return decision(i.percent, .heat)
            }
        } else {
            m.heatPausedSince = nil
            m.coolSince = nil
        }

        // 4. Sleeping.
        if s.stopWhenSleeping && i.sleeping {
            return decision(min(s.limit, i.percent), .sleeping)
        }

        // 5. Discharge.
        if i.manualDischarge || (s.automaticDischarge && i.percent > s.limit) {
            let target = dischargeTarget(limit: s.limit)
            if i.percent > target {
                return decision(s.limit, .discharging, dischargeTo: target)
            }
            return decision(s.limit, .discharged, endManualDischarge: true)
        }

        // 6. Sailing. The gap is clamped so a bad setting cannot make the band empty or endless.
        if s.sailingEnabled {
            let gap = min(max(s.sailingGap, sailingGapRange.lowerBound), sailingGapRange.upperBound)
            if i.percent >= s.limit {
                m.sailingPhase = true
            } else if i.percent <= s.limit - gap {
                m.sailingPhase = false
            }
            if m.sailingPhase {
                return decision(min(s.limit, i.percent), .sailing)
            }
        } else {
            m.sailingPhase = false
        }

        // 7. Otherwise.
        return decision(s.limit, .limit)
    }
}

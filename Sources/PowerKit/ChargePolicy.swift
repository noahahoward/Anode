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
    /// Ready By: hold the battery where it is until it has to charge to be at the limit by a time of day.
    public var readyByEnabled: Bool
    /// The time of day, in minutes after local midnight, 0…1439. The policy never reads it: the controller turns it
    /// into the next moment (`ChargeInputs.readyBy`), with the calendar, and the policy only sees that moment.
    public var readyByMinutes: Int
    /// The highest level Ready By holds at, when it lets the battery come down before it holds
    /// (`Settings.chargeReadyByLowerEnabled`); nil when it holds the battery wherever it is.
    public var readyByHoldAtMost: Int?

    public init(limit: Int,
                driftEnabled: Bool, driftGap: Int,
                pauseWhenHotEnabled: Bool, maxTemperatureC: Double,
                holdDuringSleep: Bool, drainAutomatically: Bool,
                readyByEnabled: Bool = false, readyByMinutes: Int = ChargePolicy.defaultReadyByMinutes,
                readyByHoldAtMost: Int? = nil) {
        self.limit = limit
        self.driftEnabled = driftEnabled
        self.driftGap = driftGap
        self.pauseWhenHotEnabled = pauseWhenHotEnabled
        self.maxTemperatureC = maxTemperatureC
        self.holdDuringSleep = holdDuringSleep
        self.drainAutomatically = drainAutomatically
        self.readyByEnabled = readyByEnabled
        self.readyByMinutes = readyByMinutes
        self.readyByHoldAtMost = readyByHoldAtMost
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
    /// The next moment the person wants to be ready by, after `now`; nil when there is none to go by (Ready By is
    /// off, or the helper that wakes the Mac is missing). Computed by the controller, with the calendar: the policy
    /// never does date arithmetic of its own.
    public var readyBy: Date?
    /// How fast this charger charges this Mac, in percent per minute (`ChargeRate`), between 20 and 80%. Taken as
    /// given inside `ChargePolicy.chargeRateRange`; anything else counts as the slowest.
    public var chargeRate: Double
    /// How fast it charges above 80%, in percent per minute, when that has been learned for this charger; nil until
    /// then, and the policy counts a share of `chargeRate` (`ChargePolicy.chargeTaperFactor`).
    public var chargeRateAbove80: Double?
    /// How far ahead the moment may be for Ready By to hold: `ChargePolicy.readyByWindow`, or less with a helper that
    /// cannot plan a wake that far ahead.
    public var readyByWindow: TimeInterval

    public init(percent: Int, onAC: Bool, temperatureC: Double?,
                sleeping: Bool, fullCharge: Bool, manualDrain: Bool, now: Date,
                readyBy: Date? = nil, chargeRate: Double = ChargePolicy.chargeRateRange.lowerBound,
                chargeRateAbove80: Double? = nil, readyByWindow: TimeInterval = ChargePolicy.readyByWindow) {
        self.percent = percent
        self.onAC = onAC
        self.temperatureC = temperatureC
        self.sleeping = sleeping
        self.fullCharge = fullCharge
        self.manualDrain = manualDrain
        self.now = now
        self.readyBy = readyBy
        self.chargeRate = chargeRate
        self.chargeRateAbove80 = chargeRateAbove80
        self.readyByWindow = readyByWindow
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
    /// Ready By's memory for the moment it is working towards; nil when it is not working towards one.
    public var readyBy: ReadyByMemory? = nil
    public init() {}
}

/// What Ready By remembers about one moment: the level it holds at, and whether charging has started for it.
///
/// The level is remembered so that it does not follow the charge about: a battery that sags a point on a busy Mac
/// would otherwise take the hold, and the start moment with it, down a point at a time. The start is remembered so
/// that it is final: once the time to charge has come, a better estimate a few minutes later never stops the charge
/// again.
public struct ReadyByMemory: Equatable {
    /// The moment this is for. A different moment is a different plan, and the memory goes.
    public var moment: Date
    /// Where the battery is held, in percent.
    public var level: Int
    /// Charging has started for `moment` and stays started until it has passed or the charger is unplugged.
    public var started: Bool

    public init(moment: Date, level: Int, started: Bool = false) {
        self.moment = moment
        self.level = level
        self.started = started
    }
}

public enum ChargeReason: String {
    case limit, fullCharge, heat, sleeping, drift, draining, drained, readyBy
}

/// What Ready By is doing, when it is what decided.
public struct ReadyByState: Equatable {
    /// The moment the battery is to be at the limit by.
    public var by: Date
    /// While holding: when to start charging, and so when the helper is to raise the limit if the Mac is asleep. nil
    /// once charging has started.
    public var raiseAt: Date?
    /// The level charging goes to: the person's limit.
    public var raiseTo: Int

    public init(by: Date, raiseAt: Date?, raiseTo: Int) {
        self.by = by
        self.raiseAt = raiseAt
        self.raiseTo = raiseTo
    }

    /// Holding, with charging still to start (as opposed to charging for the moment).
    public var isHolding: Bool { raiseAt != nil }
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
    /// Set exactly when `reason` is `.readyBy`.
    public var readyBy: ReadyByState?

    public init(osLimit: Int, dischargeTo: Int?, reason: ChargeReason,
                endFullCharge: Bool = false, endManualDrain: Bool = false, readyBy: ReadyByState? = nil) {
        self.osLimit = osLimit
        self.dischargeTo = dischargeTo
        self.reason = reason
        self.endFullCharge = endFullCharge
        self.endManualDrain = endManualDrain
        self.readyBy = readyBy
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
///  4. Ready By: below the limit and no more than `readyByWindow` before the moment the person wants to be ready by,
///     hold the charge where it is until it has to charge to be at the limit by then, and then charge. See
///     `readyBy(_:_:_:)`.
///  5. Sleeping with Hold Level During Sleep: hold at the current charge.
///  6. A drain (pressed, or automatic above the limit): drain to the limit.
///  7. Drift: once the limit is reached, rest inside the band below it.
///  8. Otherwise: the user's limit.
///
/// Heat sits above a drain on purpose: a drain runs the machine from the pack, and that
/// current heats a pack that is already hot, so nothing that adds heat may run while it is.
/// Charge to Full sits above Heat because it is an explicit request for this one charge; it ends on unplug.
///
/// Ready By sits below Heat (a hot pack matters more than the time) and above Hold Level During Sleep, which it
/// outranks inside its window: its hold before the start is the same hold, and after the start the battery has to
/// charge while the Mac sleeps. It does nothing at or above the limit, so a drain and Drift Below the Limit are
/// reached as before.
public enum ChargePolicy {
    /// macOS's charge limit never goes below 20 or above 100, whatever the person asked for.
    public static let osLimitRange = 20...100
    /// How long the pack must stay cool before Pause When Hot lets charging resume. Without
    /// it a pack hovering at the threshold would flip the charger on and off every reading.
    public static let heatResumeAfter: TimeInterval = 300
    public static let defaultDriftGap = 5
    public static let driftGapRange = 1...30
    /// The battery temperature Pause When Hot pauses at until the person chooses one, and why it is this number.
    ///
    /// Lithium-ion cells are specified to charge up to 45 °C: the cell makers' datasheets and the JEITA charging
    /// guideline both end normal charging there (above it the charge is reduced or refused, and many chargers stop
    /// at 50 °C), and macOS has its own protection at that end. Charging is at its best between 10 and 30 °C, and
    /// the warmer a cell is while it charges, and the fuller it is while warm, the faster it ages. Apple gives 35 °C
    /// as the warmest surroundings a MacBook should be used in, but that is the air around the Mac: the pack runs
    /// well above it (31.8 °C was read on a Mac17,9 at light load in an ordinary room, and 35 °C and more under
    /// load).
    ///
    /// So 35 °C, which this was until 1.18.3, paused charging in everyday use on a pack that was only doing its job,
    /// and 45 °C would do nothing macOS does not do already. 40 °C sits between them: 5 °C under the limit the cells
    /// are specified to, and above what the pack reaches in ordinary use, so the pause is for real heat (a hot room,
    /// the sun, heavy work while charging).
    ///
    /// Sources: Apple, "Maximizing Battery Life and Lifespan" (MacBook works best at 10 to 35 °C ambient; charging in
    /// high ambient temperatures can damage the battery further); Battery University BU-410 (Li-ion charge 0 to 45 °C,
    /// best results 10 to 30 °C, many chargers prohibit charging above 50 °C); Texas Instruments SLYT365 on the JEITA
    /// guideline (charging prohibited or reduced above 45 °C cell temperature).
    public static let defaultMaxTemperatureC = 40.0
    /// Where the cells' own specification ends normal charging (see `defaultMaxTemperatureC`). The default has to
    /// stay under it to be of any use.
    public static let cellChargeLimitC = 45.0
    /// A discharge never drains below this, whatever the limit.
    public static let dischargeFloor = 10

    // Ready By. Every number the rule uses, named once.

    /// Ready By holds only when the moment is no further off than this. Further off than that, it does nothing and
    /// the battery charges to the limit as usual: a Mac plugged in at 8:00 with a 7:00 moment must not sit at 30%
    /// all day.
    ///
    /// It was 12 hours, which missed the ordinary case: a Mac plugged in in the evening for a time late the next
    /// morning (13:00, set at 23:49) is more than 12 hours from it, so nothing was held and the battery charged
    /// straight to the limit. 16 hours takes in an evening and the night after it, and still leaves a morning plug-in
    /// for the next morning's time alone.
    public static let readyByWindow: TimeInterval = 16 * 3600
    /// The window with a helper that takes a plan no more than 13 hours ahead (one that speaks less than protocol 5,
    /// `FanHelperServer.chargePlanReach`): a hold begun further off than this could not be given its wake if the Mac
    /// went to sleep at once, and a hold with no wake lasts until somebody opens the Mac.
    public static let readyByWindowWithAnOlderHelper: TimeInterval = 12 * 3600
    /// It never holds lower than this: below it the battery charges up to it first, and then holds. (The person's own
    /// limit, when that is lower still.)
    public static let readyByFloor = 30
    /// The level Ready By lets the battery come down to before it holds, until the person chooses one: the middle,
    /// where a lithium battery ages slowest. Ready By is there so the battery spends less time at a high charge, and
    /// one plugged in at 97% was held at 97% for the night.
    public static let defaultReadyByHoldAtMost = 50
    /// What that level may be: not below the floor it never holds under, and not so high that it is no different
    /// from holding where the battery is.
    public static let readyByHoldAtMostRange = 30...95
    /// How fast a battery that is above the hold is taken to come down while the Mac sleeps, in percent an hour: the
    /// charger supplies nothing then (macOS runs the Mac from the battery whenever its limit is below the charge),
    /// and a plan made as the Mac goes to sleep has to allow for where the battery will be when it is woken. A guess
    /// on the fast side, so the charge starts early and not late; awake, the estimate is made again from where the
    /// battery really is at every look.
    public static let readyByComingDownPerHour = 1.5
    /// How much earlier than the estimate charging starts, to cover the estimate being wrong.
    public static let readyByMargin: TimeInterval = 15 * 60
    /// Above this charge a battery takes its charge slower.
    public static let chargeTaperAbove = 80
    /// How much of its usual rate it charges at above `chargeTaperAbove`, until that has been learned for the charger
    /// (`ChargeRate`, `ChargeInputs.chargeRateAbove80`). Measured on a Mac17,9 with a charger of over 65 W: 81 to 98%
    /// took 27 minutes where 62 to 75% had gone at 1.58 a minute, which is 0.40 of it. It was 0.5, a guess, and on
    /// that night the climb to a limit of 100% was estimated at 29 minutes and took at least 35 to reach 98%: the whole
    /// margin went, and the battery was at 98% nine minutes before the time.
    public static let chargeTaperFactor = 0.4
    /// The last few points go slower again: from here up, at `chargeTopOffFactor` of the rate above
    /// `chargeTaperAbove`. Not measured as closely as the taper (the same night has no reading between 98 and 100%,
    /// which took somewhere up to a quarter of an hour): a guess on the slow side, so the charge starts early.
    public static let chargeTopOffAbove = 95
    public static let chargeTopOffFactor = 0.5
    /// What the person's time is until they choose one: 7:00, in minutes after midnight.
    public static let defaultReadyByMinutes = 420
    /// The charge rates `ChargeRate` learns and the policy believes, in percent per minute. A rate outside it is a
    /// misreading, not a charger.
    public static let chargeRateRange: ClosedRange<Double> = 0.1...3.0

    /// How long the battery takes to charge from `from` to `to` percent at `rate` percent per minute: the part above
    /// `chargeTaperAbove` at `rateAbove80` when that has been learned and at `chargeTaperFactor` of `rate` when it has
    /// not, and the part above `chargeTopOffAbove` at `chargeTopOffFactor` of that. A learned rate above 80 that says
    /// the taper is faster than the charge below it is a misreading, and is taken for the rate below it. 0 when `to`
    /// is not above `from`.
    public static func minutesToCharge(from: Int, to: Int, rate: Double, rateAbove80: Double? = nil) -> Double {
        guard to > from else { return 0 }
        let r = rate.isFinite && rate > 0 ? min(max(rate, chargeRateRange.lowerBound), chargeRateRange.upperBound)
                                          : chargeRateRange.lowerBound
        let learned = rateAbove80.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let top = max(min(learned ?? r * chargeTaperFactor, r), chargeRateRange.lowerBound * chargeTaperFactor)
        let straight = max(0, min(to, chargeTaperAbove) - from)
        let tapered = max(0, min(to, chargeTopOffAbove) - max(from, chargeTaperAbove))
        let toppedOff = max(0, to - max(from, chargeTopOffAbove))
        return Double(straight) / r + Double(tapered) / top + Double(toppedOff) / (top * chargeTopOffFactor)
    }

    /// Where a discharge stops. The floor only bites if the limit is ever allowed below 10; the
    /// limit's own minimum is 20, so it is a separate function to be pinned directly.
    public static func dischargeTarget(limit: Int) -> Int {
        max(limit, dischargeFloor)
    }

    public static func decide(_ s: ChargeSettingsSnapshot, _ i: ChargeInputs, _ m: inout ChargeMemory) -> ChargeDecision {
        let d = decideByRules(s, i, &m)
        // A hold is a hold only for as long as Ready By is what decides. If anything else did (Charge to Full, a hot
        // pack, the battery at the limit), the next hold starts from where the battery is then, and not from a level
        // remembered from before. What has been started is not forgotten here: only a passed moment, an unplug or
        // switching Ready By off does that.
        if d.reason != .readyBy, m.readyBy?.started == false { m.readyBy = nil }
        return d
    }

    private static func decideByRules(_ s: ChargeSettingsSnapshot, _ i: ChargeInputs,
                                      _ m: inout ChargeMemory) -> ChargeDecision {
        func clamped(_ p: Int) -> Int { min(max(p, osLimitRange.lowerBound), osLimitRange.upperBound) }
        // Every holding rule below passes the raw charge or limit; this is where the 20…100 range is enforced.
        func decision(_ osLimit: Int, _ reason: ChargeReason, dischargeTo: Int? = nil,
                      endManualDrain: Bool = false, readyBy: ReadyByState? = nil) -> ChargeDecision {
            ChargeDecision(osLimit: clamped(osLimit), dischargeTo: dischargeTo, reason: reason,
                           endManualDrain: endManualDrain, readyBy: readyBy)
        }

        // 1. Unplugged. Nothing can charge or discharge through the adapter, and both requests
        //    were for this connection only.
        guard i.onAC else {
            // Ready By is for this connection too: what it had started, or was holding, is over.
            m.readyBy = nil
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

        // 4. Ready By.
        if let d = readyBy(s, i, &m) { return d }

        // 5. Sleeping.
        if s.holdDuringSleep && i.sleeping {
            return decision(min(s.limit, i.percent), .sleeping)
        }

        // 6. Drain.
        if i.manualDrain || (s.drainAutomatically && i.percent > s.limit) {
            let target = dischargeTarget(limit: s.limit)
            if i.percent > target {
                return decision(s.limit, .draining, dischargeTo: target)
            }
            return decision(s.limit, .drained, endManualDrain: true)
        }

        // 7. Drift. The gap is clamped so a bad setting cannot make the band empty or endless.
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

        // 8. Otherwise.
        return decision(s.limit, .limit)
    }

    /// Rule 4. nil when it has nothing to say, and the rules below it go on as before.
    ///
    /// It has something to say only when it is switched on, there is a moment to be ready by that is still to come,
    /// and the battery is below the limit. Then:
    ///
    ///  * Charging that has started for this moment goes on until the moment has passed (`ReadyByMemory.started`),
    ///    whatever the estimate does and whether or not the moment is still inside the window.
    ///  * More than the window before the moment (`ChargeInputs.readyByWindow`), it does nothing.
    ///  * Otherwise the battery is held at its level (`ReadyByMemory.level`: where it was when the hold began, and
    ///    never below `readyByFloor`, or above the limit when that is lower) until `raiseAt`, which is the moment less
    ///    the time the climb to the limit takes at `chargeRate` (`minutesToCharge`) and `readyByMargin`. From `raiseAt`
    ///    on it is charging, and stays so. With no time to wait, that is at once.
    private static func readyBy(_ s: ChargeSettingsSnapshot, _ i: ChargeInputs, _ m: inout ChargeMemory)
        -> ChargeDecision? {
        func decision(_ osLimit: Int, _ state: ReadyByState) -> ChargeDecision {
            // A manual drain that has got down to the limit is over: Ready By's hold must not leave it pressed.
            ChargeDecision(osLimit: min(max(osLimit, osLimitRange.lowerBound), osLimitRange.upperBound), dischargeTo: nil,
                           reason: .readyBy, endManualDrain: i.manualDrain, readyBy: state)
        }
        guard s.readyByEnabled, let by = i.readyBy, by > i.now else {
            m.readyBy = nil
            return nil
        }
        // A different moment is a different plan: the one remembered has passed, or the time was changed.
        if let r = m.readyBy, r.moment != by { m.readyBy = nil }
        // The highest level it holds at: the person's limit, or lower when the battery is let come down first.
        let cap = min(s.limit, s.readyByHoldAtMost ?? s.limit)
        // At or above the limit there is nothing to charge towards, and nothing to hold below unless the battery is to
        // come down first.
        guard i.percent < s.limit || cap < s.limit else { return nil }

        let charging = ReadyByState(by: by, raiseAt: nil, raiseTo: s.limit)
        if m.readyBy?.started == true {
            return decision(s.limit, charging)
        }
        guard by.timeIntervalSince(i.now) <= i.readyByWindow else { return nil }

        let floor = min(readyByFloor, s.limit)
        // Never above the limit that is in force (a level remembered while the limit was higher is not held above one
        // that was lowered since), and never above the level the battery is to come down to. A battery above the level
        // it is held at is not charged, and macOS runs the Mac from it until it is there: that is the coming down.
        //
        // The level it remembers is where the hold began, so that a battery that sags a point does not take the hold
        // down with it. A battery well above it is another matter: nothing charges a battery to above its hold, so it
        // is one that was coming down to a lower level which has since been raised or switched off, and the hold is
        // then where the battery is now (or the level it comes down to, when that is lower).
        var remembered = m.readyBy?.level ?? max(i.percent, floor)
        if i.percent > remembered + 1 { remembered = i.percent }
        let level = min(cap, remembered)
        // The climb is counted from the level it holds at, which is where the battery is heading: a battery below it
        // (on its way up to the floor, or sagged a point under load) is charged back to it, and holds there. One that is
        // still above it is counted from where it will have come down to by the moment, which is never below the
        // level, and never above the limit.
        var from = level
        if i.percent > level {
            let hours = by.timeIntervalSince(i.now) / 3600
            let fallen = i.percent - Int((readyByComingDownPerHour * hours).rounded(.up))
            from = min(s.limit, max(level, fallen))
        }
        let lead = minutesToCharge(from: from, to: s.limit, rate: i.chargeRate,
                                   rateAbove80: i.chargeRateAbove80) * 60 + readyByMargin
        let raiseAt = by.addingTimeInterval(-lead)
        if i.now >= raiseAt {
            m.readyBy = ReadyByMemory(moment: by, level: level, started: true)
            return decision(s.limit, charging)
        }
        m.readyBy = ReadyByMemory(moment: by, level: level, started: false)
        return decision(level, ReadyByState(by: by, raiseAt: raiseAt, raiseTo: s.limit))
    }
}

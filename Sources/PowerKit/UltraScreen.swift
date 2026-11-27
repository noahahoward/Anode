import Foundation

// The screen rules of Ultra Low Power Mode, the rule for when Anode measures, and the guard that asks whether a freeze
// made something burn. Pure: numbers and lists go in, a decision comes out, and nothing is read from or set on the Mac.

// ── Brightness ──────────────────────────────────────────────────────────────

/// The most the mode lets the screen be: a ceiling the owner sets, half of the slider unless they lower it. Measured, whole Mac,
/// with the slider at 0.5: about 4.3 W; at 0.375: 3.2 W; at 0.25: 2.8 W; at 0.125: 2.65 W; and no gain below that.
///
/// The ceiling is a parameter of every decision below, and a session writes the one it used on its record, so the watchdog and a
/// launch after a crash put the screen back against the number the session held it to, not against whatever the setting says now.
public enum BrightnessCeiling {
    /// What a new Mac holds the screen to until the owner lowers it: half the slider.
    public static let defaultCeiling: Float = Float(Settings.ultraLowPowerBrightnessCapDefault)
    /// What a record that does not name its ceiling was made under: the mode held the screen to a quarter before the ceiling was a setting.
    public static let legacyCeiling: Float = 0.25
    /// What the display's own rounding can add or take away when brightness is read back.
    public static let slack: Float = 0.01

    /// What to set the screen to, when it is brighter than the ceiling; nil when it is at or below it. Going dimmer is
    /// always allowed, so only the way up is held.
    public static func clamp(_ current: Float, ceiling: Float) -> Float? {
        current > ceiling + slack ? ceiling : nil
    }

    /// The cap in words for a sentence ("held at half brightness or lower"): half and a quarter by name, anything else as a percent.
    public static func words(for cap: Double) -> String {
        switch cap {
        case 0.5: return "half"
        case 0.25: return "a quarter"
        default: return "\(Int((cap * 100).rounded()))%"
        }
    }

    /// What the end of a session does about the screen, and why: the decision and the reason for the log in one value.
    public enum Restoration: Equatable {
        /// Set the screen to this.
        case putBack(Float)
        /// The mode did not lower it, so it has nothing to put back.
        case nothingWasLowered
        case couldNotBeRead
        /// Somebody else raised it past the ceiling since: not the mode's to change.
        case aboveTheCeiling
        /// It is at or above the earlier level already: the end never lowers the screen.
        case alreadyAtTheEarlierLevel
        /// Left on purpose: it is at or under the lid dimmer's dark threshold, and the caller cannot ask who holds it down.
        case screenIsDark
    }

    /// At or under this the screen is dark: the lid dimmer holds it at 0 with the lid shut and calls anything under it nothing to save.
    public static let darkAtOrBelow: Float = LidDimmer.darkThreshold

    /// What the end of a session does about the screen, from the level before the mode (`before`; nil when the mode did not
    /// lower it) and the level now. The ceiling is what the mode left it at, so:
    ///
    ///  · at or under the ceiling, and under `before`: put back to `before`. A screen dimmer than the ceiling was dimmed further
    ///    during the mode, by the owner or by macOS (it lowers the screen a little more when Low Power Mode comes on: 0.25 became
    ///    0.2184, measured), and the owner's own level is what they get back;
    ///  · above the ceiling: somebody else raised it since, and it is not the mode's to change;
    ///  · at or above `before` already: the end never lowers the screen;
    ///  · unreadable: no way to tell where it is;
    ///  · dark, when `leavingADarkScreen`: the lid dimmer holds the screen at 0 with the lid shut. The mode's own turning off asks
    ///    `OwnBrightness` whether another feature holds the screen; the watchdog and a launch after a crash cannot (a new process has
    ///    noted nothing), so they leave a dark screen to whatever put it there.
    public static func decide(before: Float?, now: Float?, ceiling: Float, leavingADarkScreen: Bool = false) -> Restoration {
        guard let before else { return .nothingWasLowered }
        guard let now else { return .couldNotBeRead }
        if leavingADarkScreen, now <= darkAtOrBelow { return .screenIsDark }
        guard now <= ceiling + slack else { return .aboveTheCeiling }
        return before > now ? .putBack(before) : .alreadyAtTheEarlierLevel
    }

    /// The brightness to put back at the end, or nil when the screen is to be left as it is (see `decide`).
    public static func restore(before: Float?, now: Float?, ceiling: Float, leavingADarkScreen: Bool = false) -> Float? {
        if case .putBack(let level) = decide(before: before, now: now, ceiling: ceiling, leavingADarkScreen: leavingADarkScreen) { return level }
        return nil
    }
}

// ── Refresh rate ────────────────────────────────────────────────────────────

/// One mode a display offers, as plain values.
public struct DisplayModeInfo: Equatable {
    public var index: Int
    /// In points; with the pixel size, what tells a scaled mode from a native one.
    public var width, height: Int
    public var pixelWidth, pixelHeight: Int
    /// In hertz. 0 when the display does not say.
    public var rate: Double
    /// The display will take this mode.
    public var usable: Bool

    public init(index: Int, width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, rate: Double, usable: Bool) {
        self.index = index
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.rate = rate
        self.usable = usable
    }
}

public enum RefreshRatePicker {
    /// The mode with the lowest rate that has the current resolution (size and pixels both: the owner's picture must
    /// not change), or nil when `current` is already as low as it goes. Nothing is assumed about which rates a Mac
    /// offers, so a model with a lower one needs no update.
    public static func lowest(of modes: [DisplayModeInfo], current: DisplayModeInfo) -> DisplayModeInfo? {
        let candidates = modes.filter {
            // A rate of 0 is "not said", not "slowest".
            $0.usable && $0.rate > 0 && $0.width == current.width && $0.height == current.height
                && $0.pixelWidth == current.pixelWidth && $0.pixelHeight == current.pixelHeight
        }
        // Equal rates: the lower index, so the same mode is chosen whatever order the system lists them in.
        guard let lowest = candidates.min(by: { ($0.rate, $0.index) < ($1.rate, $1.index) }),
              lowest.rate < current.rate else { return nil }
        return lowest
    }
}

// ── Anode's own measuring ───────────────────────────────────────────────────

public enum MeasurementPause {
    /// While the mode is on the sampling tick still runs, once a minute, and each tick reads only the battery: the drain figure is
    /// the one thing the owner is still shown, so they can see whether the mode is worth it.
    public static let interval: TimeInterval = 60
    /// The first reading after the mode comes on, from a cleared average.
    public static let firstReading: TimeInterval = 30

    /// The tick's interval: the owner's own sample interval, or the minute the mode holds it to.
    public static func tickInterval(ultraOn: Bool, setting: TimeInterval) -> TimeInterval {
        ultraOn ? interval : setting
    }

    /// Whole seconds until the next reading, for the countdown beside the reading's name: rounded up, never below 0 and
    /// never above the interval. nil when the mode is off (there is no countdown then) or no reading is scheduled.
    public static func secondsUntil(_ next: Date?, now: Date, ultraOn: Bool) -> Int? {
        guard ultraOn, let next else { return nil }
        return Int(min(max(next.timeIntervalSince(now), 0), interval).rounded(.up))
    }

    /// How long the gauge's own average covers: it publishes the mean of its last minute.
    public static let gaugeWindow: TimeInterval = 60

    /// The gauge's age to give the battery-watts rule, or nil to have it read the pack's live current instead. The gauge's figure is
    /// the mean of the minute before it was published, so one published less than a minute into the mode still holds some of the
    /// draw from before it (the first reading, thirty seconds in, always does): that figure would make the mode look as if it
    /// saved less than it does. The live current reads about 9% high against the gauge, a smaller error than half a minute of the
    /// old draw, and it is only used until a whole window of the mode has been published.
    public static func gaugeAge(_ age: TimeInterval?, sinceModeStart: TimeInterval) -> TimeInterval? {
        guard let age, age <= sinceModeStart - gaugeWindow else { return nil }
        return age
    }

    /// When the reading after the one at `due` falls: a minute on, kept on the schedule even when the tick ran late, and never in
    /// the past (a Mac that slept through some of them reads once, then goes on from here).
    public static func nextReading(after due: Date, now: Date) -> Date {
        var next = due.addingTimeInterval(interval)
        if next <= now { next = now.addingTimeInterval(interval) }
        return next
    }
}

// ── After a freeze ──────────────────────────────────────────────────────────

/// After a freeze: did it make something burn? The mode must never make the Mac draw more than before.
///
/// Measured, stopping the user's part of a product left its other part with nobody to talk to, and that part spun.
/// So after each freeze the load is read again and compared with the reading from before it.
public enum SpinGuard {
    public enum Verdict: Equatable {
        case fine
        /// Continue these groups (sorted by id) and keep them running for the session.
        case release([String])
        /// Continue everything frozen in this step.
        case releaseAll
    }

    /// Cores a process has to use to count as burning.
    public static let burning = 0.5
    /// Cores above its reading before the freeze, so a process that was already busy is not blamed for the freeze.
    public static let rise = 0.4

    /// `ownBefore` and `ownAfter`: load of the user's own processes, in cores. `busyCoresBefore` and `busyCoresAfter`:
    /// the whole Mac. `kept`: every process the mode left running by choice. `frozen`: the groups still stopped
    /// (a released group is not in it).
    ///
    /// Anything of the user's that is running and is in neither `kept` nor a stopped group is judged as a possible
    /// burner. So the caller must put Anode's own pids, its watchdog child and the processes of groups already
    /// released in `kept` (or leave them out of `ownAfter`): their ordinary work would read as a spin and undo the
    /// freeze for nothing.
    public static func verdict(ownBefore: [pid_t: Double], ownAfter: [pid_t: Double], busyCoresBefore: Double,
                               busyCoresAfter: Double, kept: Set<pid_t>, frozen: [FreezeGroup],
                               processes: [UltraProcess]) -> Verdict {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let stillStopped = Set(frozen.flatMap { $0.members.map(\.pid) })

        // 1. A process that was quiet and now burns lost something it needs. Kept processes are the owner's work, and
        //    stopped ones do not run.
        let burners = ownAfter.filter { pid, load in
            !kept.contains(pid) && !stillStopped.contains(pid)
                && load >= burning && load - (ownBefore[pid] ?? 0) >= rise
        }.keys
        if !burners.isEmpty {
            var release: Set<String> = []
            for pid in burners {
                let ofItsProduct = byPID[pid].map { burner in
                    frozen.filter { shareAProduct(burner, $0, byPID: byPID) }.map(\.id)
                } ?? []
                // One tied to no stopped group: nothing says which freeze did it, so all of them are undone.
                if ofItsProduct.isEmpty { return .releaseAll }
                release.formUnion(ofItsProduct)
            }
            return .release(release.sorted())
        }

        // 2. Nothing of the user's burns, yet the Mac does, and the apps the owner is using do not account for it:
        //    something Anode cannot see (another user's process) is burning.
        let busyRise = busyCoresAfter - busyCoresBefore
        if busyRise >= burning {
            let keptRise = kept.reduce(0.0) { $0 + (ownAfter[$1] ?? 0) - (ownBefore[$1] ?? 0) }
            if keptRise < busyRise / 2 { return .releaseAll }
        }
        return .fine
    }

    /// The same product: a member of `group` sits in the same app bundle as `burner`, or has the same signing team.
    /// A member is taken from the process list only if it is the process that was frozen (same start time): a pid
    /// that has been recycled says nothing about the group. No team never matches, as in the planner.
    private static func shareAProduct(_ burner: UltraProcess, _ group: FreezeGroup, byPID: [pid_t: UltraProcess]) -> Bool {
        let bundle = FreezePlanner.bundlePrefixes(of: burner.path).first
        let team = burner.team.flatMap { $0.isEmpty ? nil : $0 }
        return group.members.contains { member in
            guard let process = byPID[member.pid], process.startTime == member.startTime else { return false }
            if let bundle, FreezePlanner.bundlePrefixes(of: process.path).first == bundle { return true }
            if let team, process.team == team { return true }
            return false
        }
    }
}

import Foundation

// The screen rules of Ultra Low Power Mode, the rule for when Anode measures, and the guard that asks whether a freeze
// made something burn. Pure: numbers and lists go in, a decision comes out, and nothing is read from or set on the Mac.

// ── Brightness ──────────────────────────────────────────────────────────────

/// The most the mode lets the screen be: a quarter of the slider. Measured, whole Mac, with the slider at 0.375: about 3.2 W;
/// at 0.25: 2.8 W; at 0.125: 2.65 W; and no gain below that.
public enum BrightnessCeiling {
    public static let ceiling: Float = 0.25
    /// What the display's own rounding can add or take away when brightness is read back.
    public static let slack: Float = 0.01

    /// What to set the screen to, when it is brighter than the ceiling; nil when it is at or below it. Going dimmer is
    /// always allowed, so only the way up is held.
    public static func clamp(_ current: Float) -> Float? {
        current > ceiling + slack ? ceiling : nil
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
    }

    /// What the end of a session does about the screen, from the level before the mode (`before`; nil when the mode did not
    /// lower it) and the level now. The ceiling is what the mode left it at, so:
    ///
    ///  · at or under the ceiling, and under `before`: put back to `before`. A screen dimmer than the ceiling was dimmed further
    ///    during the mode, by the owner or by macOS (it lowers the screen a little more when Low Power Mode comes on: 0.25 became
    ///    0.2184, measured), and the owner's own level is what they get back;
    ///  · above the ceiling: somebody else raised it since, and it is not the mode's to change;
    ///  · at or above `before` already: the end never lowers the screen;
    ///  · unreadable: no way to tell where it is.
    public static func decide(before: Float?, now: Float?) -> Restoration {
        guard let before else { return .nothingWasLowered }
        guard let now else { return .couldNotBeRead }
        guard now <= ceiling + slack else { return .aboveTheCeiling }
        return before > now ? .putBack(before) : .alreadyAtTheEarlierLevel
    }

    /// The brightness to put back at the end, or nil when the screen is to be left as it is (see `decide`).
    public static func restore(before: Float?, now: Float?) -> Float? {
        if case .putBack(let level) = decide(before: before, now: now) { return level }
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
    /// Whether Anode's sampling tick runs. It stops while the mode is on and nothing is on screen to read it, and
    /// never while fans are driven or the charge floor is being watched: those are safety, not measuring.
    public static func ticks(ultraOn: Bool, windowWorthDrawing: Bool, drivingFans: Bool, chargeWatching: Bool) -> Bool {
        !ultraOn || windowWorthDrawing || drivingFans || chargeWatching
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

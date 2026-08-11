import Foundation

/// Fan control policy and the SMC write path behind it.
///
/// SAFETY IS THE WHOLE DESIGN HERE. A fan target is one of the very few things
/// this app can write to hardware, and getting it wrong cooks the machine — a
/// fan pinned low under sustained load is a thermal problem the user will not
/// see coming, because the fan being quiet is exactly what "everything is fine"
/// sounds like.
///
/// So the rules are:
///
///  * `.native` is the default and writes NOTHING. Not a "set it back to auto"
///    write — literally no SMC write ever happens in this mode. A user who never
///    opts in is on a machine this code has never touched.
///  * Manual targets are clamped to the fan's own reported `Mn`/`Mx`. Those come
///    from the SMC, not from us, so the clamp is the hardware's opinion.
///  * A minimum is never below the reported minimum. "Silent" is not a feature
///    worth shipping if it means 0 rpm on a hot SoC.
///  * Releasing control restores automatic behaviour explicitly rather than
///    leaving the last forced value latched.
///
/// On this hardware `F0Md` does not exist — the Intel-era "set mode to manual,
/// then set target" sequence does not apply. Control is a direct `F<n>Tg` write.
public enum FanMode: String, Codable, CaseIterable {
    /// macOS decides. No writes. The default, and the only mode that needs no
    /// privileged helper at all.
    case native
    /// The user has explicitly taken control of one or more fans.
    case manual
}

public struct FanTarget: Codable, Equatable {
    public let index: Int
    /// Requested rpm. Always clamped against the fan's reported range before it
    /// reaches the SMC.
    public let rpm: Double

    public init(index: Int, rpm: Double) {
        self.index = index
        self.rpm = rpm
    }
}

/// What the helper is allowed to be asked to do. Deliberately tiny: the whole
/// privileged surface is "set this fan to this speed" and "stop controlling".
public enum FanCommand: Codable, Equatable {
    case setTarget(FanTarget)
    case releaseAll
}

// ─────────────────────────────────────────────────────────────────────────────

/// Validates a requested fan speed against what the hardware says it can do.
///
/// Split out from anything privileged so it can be tested exhaustively without a
/// helper, a password, or a machine that has fans. The daemon runs this too —
/// the caller is not trusted to have clamped anything.
public enum FanPolicy {

    public struct Limits: Equatable {
        public let minRPM: Double
        public let maxRPM: Double
        public init(minRPM: Double, maxRPM: Double) {
            self.minRPM = minRPM
            self.maxRPM = maxRPM
        }
    }

    public enum Rejection: Error, Equatable {
        case unknownFan
        case limitsImplausible
        case notFinite
    }

    /// The rpm that may actually be written, or a reason it may not be.
    ///
    /// Clamping rather than rejecting out-of-range values is deliberate: a
    /// slider dragged to its end should mean "as fast as this fan goes", not an
    /// error dialog. But a NaN or a fan we have no limits for is a bug upstream,
    /// and silently substituting a number for it would hide that.
    public static func resolve(rpm: Double, limits: Limits?) -> Result<Double, Rejection> {
        guard let l = limits else { return .failure(.unknownFan) }
        guard rpm.isFinite else { return .failure(.notFinite) }
        // A fan reporting max <= min is a misread key, not a fan with one speed.
        // Writing to it on the strength of that reading is not defensible.
        guard l.minRPM > 0, l.maxRPM > l.minRPM, l.maxRPM < 20000 else {
            return .failure(.limitsImplausible)
        }
        // ZERO PASSES THROUGH. It is the only value below the minimum that is not
        // clamped up to it, and it is how the slider's dead zone asks for a fan to
        // stop rather than idle.
        //
        // The same number means something else in `FanRelease`, and the
        // difference is the MODE, not the target: 0 with the mode handed back to
        // the firmware is "no forced target, you decide", while 0 with the mode
        // still ours is "stay stopped". Reading a target of 0 tells you nothing on
        // its own — always read `F<n>md` beside it.
        if rpm == 0 { return .success(0) }
        return .success(min(max(rpm, l.minRPM), l.maxRPM))
    }

    /// Fraction of the fan's range. 0 = minimum, 1 = maximum. This is the fan's
    /// OWN range and has no notion of stopped; `FanKnob` is the slider's space,
    /// which does.
    public static func fraction(rpm: Double, limits: Limits) -> Double {
        guard limits.maxRPM > limits.minRPM else { return 0 }
        return min(max((rpm - limits.minRPM) / (limits.maxRPM - limits.minRPM), 0), 1)
    }

    public static func rpm(fraction: Double, limits: Limits) -> Double {
        let f = min(max(fraction, 0), 1)
        return limits.minRPM + f * (limits.maxRPM - limits.minRPM)
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// The slider's own coordinate space, 0 to 1, and how it maps to a fan speed.
///
/// A fan's range starts at its minimum — 2317 rpm on this hardware — so a bar
/// scaled straight onto that range has NOWHERE TO PUT ZERO. A stopped fan parked
/// the knob at the minimum, which reads as "set to 2317" and was reported as
/// exactly that confusion by a user watching a silent machine.
///
/// So the bottom of the bar is a dead zone that means OFF, and the fan's range
/// starts above it:
///
///     0 ────────────── 0.05 ──────────────────────────────────── 1
///     off              minRPM                                maxRPM
///     └── snaps ──┘
///
/// Inside the dead zone there are only two answers, so a knob released there
/// takes the nearer one. Above it the knob is continuous and snaps to nothing —
/// a user aiming for 4000 rpm should get 4000 rpm.
public enum FanKnob {

    /// Where "off" ends and the fan's own range begins.
    public static let offZone: Double = 0.05

    /// The requested speed for a knob position, or nil for "off".
    ///
    /// nil is not zero. Zero is a number this project writes to mean "no forced
    /// target"; nil here means the user asked for the fan to stop, and what that
    /// costs on the wire is `FanPolicy`'s problem, not the slider's.
    public static func rpm(atPosition position: Double,
                           limits: FanPolicy.Limits) -> Double? {
        let p = clamped(position)
        guard p >= offZone else { return nil }
        let span = (p - offZone) / (1 - offZone)
        return limits.minRPM + span * (limits.maxRPM - limits.minRPM)
    }

    /// Where the knob sits to show a speed. nil means the fan is off or stopped.
    public static func position(forRPM rpm: Double?, limits: FanPolicy.Limits) -> Double {
        guard let rpm, rpm.isFinite, rpm > 0 else { return 0 }
        guard limits.maxRPM > limits.minRPM else { return offZone }
        let span = (rpm - limits.minRPM) / (limits.maxRPM - limits.minRPM)
        return clamped(offZone + min(max(span, 0), 1) * (1 - offZone))
    }

    /// Where a released knob lands.
    ///
    /// ONLY inside the dead zone, and to whichever end is nearer. Above it
    /// nothing snaps: rounding a deliberate 4000 to some tidier number is the
    /// control disagreeing with the person holding it.
    public static func snapped(_ position: Double) -> Double {
        let p = clamped(position)
        guard p < offZone else { return p }
        return p < offZone / 2 ? 0 : offZone
    }

    /// Is this position asking for the fan to stop?
    public static func isOff(_ position: Double) -> Bool { clamped(position) < offZone }

    private static func clamped(_ p: Double) -> Double { min(max(p, 0), 1) }
}

/// Where a fan slider's knob sits, and what the number beside it says.
///
/// Pulled out of the view because the interesting case is the one that looks like
/// nothing: in automatic mode the slider is a LIVE GAUGE of the fan's actual
/// speed. A control that looks disabled AND reads zero is indistinguishable from
/// a broken pane — and this pane has been mistaken for one before, when a skipped
/// SMC sweep made a two-fan machine print "this machine reports no fans".
public enum FanGauge {

    /// The knob's position, in rpm.
    ///
    /// `asked` is what THIS app has requested for the fan, and nil means it has
    /// requested nothing — so the knob follows the hardware instead. Once
    /// something has been asked for the knob holds it: yanking it back to the
    /// current reading mid-spin-up reads as the control fighting the user, and a
    /// fan takes seconds to arrive.
    ///
    /// The result is never below the fan's own minimum, whatever it is handed. A
    /// parked fan reads 0 rpm, which is below its minimum and simply not on this
    /// slider's scale, so the knob sits at the bottom of its travel rather than
    /// off the end of it.
    public static func knobRPM(current: Double, asked: Double?,
                               limits: FanPolicy.Limits) -> Double {
        guard limits.maxRPM > limits.minRPM else { return limits.minRPM }
        let v = asked ?? current
        guard v.isFinite else { return limits.minRPM }
        return min(max(v, limits.minRPM), limits.maxRPM)
    }

    /// The range one slider can drive every fan over: no lower than the highest
    /// minimum, no higher than the lowest maximum.
    ///
    /// The INTERSECTION, not the union or an average. A single knob has one
    /// number on it, and that number has to be legal for every fan it commands —
    /// offering a speed one fan would refuse means a drag that half works, with
    /// the refusal arriving as an error message about a fan the user was not
    /// thinking about.
    ///
    /// nil when the fans have no speed in common, which is the honest answer for
    /// a machine whose fans do not overlap: there, one slider cannot exist and
    /// the strip stays split. Also nil for no fans at all.
    public static func sharedLimits(_ limits: [FanPolicy.Limits]) -> FanPolicy.Limits? {
        guard let first = limits.first else { return nil }
        var low = first.minRPM, high = first.maxRPM
        for l in limits.dropFirst() {
            low = max(low, l.minRPM)
            high = min(high, l.maxRPM)
        }
        guard high > low else { return nil }
        return FanPolicy.Limits(minRPM: low, maxRPM: high)
    }

    /// The reading beside a synced slider: what every fan is doing, then the one
    /// thing they were all told.
    ///
    /// Every fan's current speed is shown rather than an average, because two
    /// fans given the same target do not run at the same rpm — the SMC arbitrates
    /// per fan, and on this hardware 2317 written to both produced 2320 and 2502.
    /// An average would hide exactly the disagreement worth seeing.
    public static func syncedReadout(currents: [Double], asked: Double?) -> String {
        let shown = currents.map { $0.isFinite ? String(format: "%.0f", $0) : "—" }
        let now = shown.isEmpty ? "—" : shown.joined(separator: " · ")
        guard let asked, asked.isFinite else { return "\(now) rpm" }
        return String(format: "%@ → %.0f rpm", now, asked)
    }

    /// The reading beside the knob.
    ///
    /// Two numbers only when there are two facts: what the fan is doing, and what
    /// it was told to do. In automatic mode there is no target of ours to show,
    /// and printing the knob's position as one would claim this app had asked for
    /// a speed it never asked for.
    public static func readout(current: Double, asked: Double?) -> String {
        let now = current.isFinite ? String(format: "%.0f", current) : "—"
        guard let asked, asked.isFinite else { return "\(now) rpm" }
        return String(format: "%@ → %.0f rpm", now, asked)
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// The Fans tab's state machine: what a gesture on the control strip means, and
/// what the strip is entitled to claim afterwards.
///
/// Lifted out of the view and away from the socket ON PURPOSE. Every branch below
/// decides one of the only two consequential things this app can do — start a
/// root process, or write a fan target — and both have to be provable without
/// root, without a running helper, and without spinning a fan to find out.
///
/// THE STATES, and every way between them:
///
///   off ────────── the feature is switched off. No gesture does anything and no
///                  socket is opened. The shipped default.
///   automatic ──── macOS is deciding. EITHER no helper is running, OR one is and
///                  this app is holding no fan: the handshake writes nothing, so
///                  a connected helper with nothing held is still automatic.
///   starting ───── the user grabbed a knob and there was no helper to hear it.
///                  Nothing has been written; the request is remembered and sent
///                  if and when a helper answers, and dropped if none does.
///   manual(n) ──── n fans are held at a target this app asked for.
///   blocked(why) ─ a helper is running and refuses this build (the ordinary
///                  cause is a rebuild). Gestures repeat its reason rather than
///                  pretending to drive anything.
///
///   automatic ──grab/❄︎──▶ starting ──helper answers──▶ manual
///        ▲                    │                            │
///        └──✕, or no helper────┘                           │
///        └──────────────✕, or the helper goes away─────────┘
///
/// Every edge OUT of `manual` empties what is held, including the ones nobody
/// chose. A helper that goes away has ALREADY handed the fans back — it releases
/// when its client disappears and again on its own way out — so a knob still
/// claiming a target would be the only thing on screen that had not noticed.
public struct FanSession: Equatable {

    /// As much of the privileged half as the app can see.
    public enum Helper: Equatable {
        /// Nothing is listening. The ordinary state, because the helper only runs
        /// while the user is running it.
        case absent
        /// A helper has been asked for and is not up yet. Set by this session
        /// when a gesture needs one, never by the link.
        case starting
        case connected(fanCount: Int)
        /// A helper is there and would not have us; its reason, verbatim.
        case refused(String)
    }

    public enum Mode: Equatable {
        case off
        case automatic
        case starting
        case manual(fans: Int)
        case blocked(String)
    }

    /// What a user did to the strip. Limits travel with the gesture because the
    /// clamp is the hardware's opinion and the session has no other way to know
    /// it.
    public enum Gesture: Equatable {
        /// The knob was dragged and let go.
        case setSpeed(index: Int, rpm: Double, limits: FanPolicy.Limits)
        /// ❄︎ — the same privileged step as a grab, and then this fan's own
        /// maximum. "100%" is the top of the fan's reported range, not a number
        /// this app chose.
        case fullSpeed(index: Int, limits: FanPolicy.Limits)
        /// ✕ — the undo for the only destructive thing this app can do.
        case release
    }

    public enum Effect: Equatable {
        /// Nothing to do, and the sentence that says why.
        case nothing(String)
        /// A helper has to be started, visibly, before anything can be sent. What
        /// to send afterwards is remembered here rather than by the caller.
        case startHelper
        case send(FanCommand)
        /// Stop waiting for a helper that is not coming. Nothing was ever
        /// written, so there is nothing to undo.
        case abandonStart
    }

    /// Mirrors `Settings.fanControlEnabled`.
    public var enabled: Bool
    public private(set) var helper: Helper
    /// Fans held at a target this app asked for, and the rpm asked. EMPTY IS
    /// AUTOMATIC, even while connected.
    public private(set) var held: [Int: Double] = [:]
    /// Asked for while there was no helper to ask. Sent the moment one answers.
    public private(set) var pending: [Int: Double] = [:]

    public init(enabled: Bool, helper: Helper = .absent) {
        self.enabled = enabled
        self.helper = helper
    }

    public var mode: Mode {
        guard enabled else { return .off }
        switch helper {
        case .refused(let why):  return .blocked(why)
        case .starting:          return .starting
        case .absent:            return .automatic
        case .connected:         return held.isEmpty ? .automatic : .manual(fans: held.count)
        }
    }

    /// The rpm this app has asked of fan `index`, or nil to read the fan itself.
    /// A pending request counts: the user has moved that knob and it should stay
    /// where they left it while the helper starts.
    public func asked(_ index: Int) -> Double? { held[index] ?? pending[index] }

    /// Is there anything for ✕ to undo?
    public var isDriving: Bool { !held.isEmpty || !pending.isEmpty }

    // ── Gestures ────────────────────────────────────────────────────────────

    public mutating func apply(_ gesture: Gesture) -> Effect {
        guard enabled else { return .nothing("Fan control is off — macOS is deciding.") }
        switch gesture {
        case .setSpeed(let i, let rpm, let limits):
            return want(index: i, rpm: rpm, limits: limits)
        case .fullSpeed(let i, let limits):
            return want(index: i, rpm: limits.maxRPM, limits: limits)
        case .release:
            return releaseEverything()
        }
    }

    private mutating func want(index: Int, rpm: Double, limits: FanPolicy.Limits) -> Effect {
        // Clamped HERE, before a privileged process is even STARTED. The helper
        // clamps again against limits it reads itself, and that is the boundary
        // that counts — but a request the hardware's own numbers refuse should
        // never get as far as asking a user to authenticate for it.
        guard case .success(let safe) = FanPolicy.resolve(rpm: rpm, limits: limits) else {
            return .nothing("Fan \(index + 1) does not report a usable speed range, "
                          + "so it is left on automatic.")
        }
        switch helper {
        case .connected:
            held[index] = safe
            return .send(.setTarget(FanTarget(index: index, rpm: safe)))
        case .absent:
            pending[index] = safe
            helper = .starting
            return .startHelper
        case .starting:
            // Kept per fan rather than replaced. On a two-fan machine a user can
            // easily set both while the password prompt is still up, and dropping
            // the first one would leave a knob sitting at a speed nothing was
            // ever told about.
            pending[index] = safe
            return .nothing("Waiting for the fan helper — finish the prompt in Terminal.")
        case .refused(let why):
            return .nothing(why)
        }
    }

    private mutating func releaseEverything() -> Effect {
        switch helper {
        case .starting:
            // Nothing was written, so this is a cancel rather than a release: drop
            // the request, stop waiting, and be back on automatic with no trace.
            pending.removeAll()
            held.removeAll()
            helper = .absent
            return .abandonStart
        case .connected where isDriving:
            // What is held stays held until the helper says it took the release.
            // A release that half-failed leaves fans pinned, and a strip that had
            // already gone quiet would be the one place a user could not see it.
            pending.removeAll()
            return .send(.releaseAll)
        case .connected, .absent, .refused:
            pending.removeAll()
            held.removeAll()
            return .nothing("The fans are already on automatic.")
        }
    }

    // ── What the world did back ─────────────────────────────────────────────

    /// The link's latest answer. Returns whatever was waiting on a helper, in fan
    /// order, for the caller to send.
    @discardableResult
    public mutating func helperBecame(_ h: Helper) -> [FanCommand] {
        helper = h
        guard case .connected = h else {
            // Not connected is not driving. See the note at the top: a helper
            // that has gone has already handed the fans back.
            held.removeAll()
            // `.starting` is this session's own state and keeps what was asked
            // for; anything else means the start did not happen.
            if case .starting = h { return [] }
            pending.removeAll()
            return []
        }
        guard !pending.isEmpty else { return [] }
        let queued = pending.sorted { $0.key < $1.key }
        pending.removeAll()
        for (index, rpm) in queued { held[index] = rpm }
        return queued.map { .setTarget(FanTarget(index: $0.key, rpm: $0.value)) }
    }

    /// The helper's answer to one command.
    public mutating func completed(_ command: FanCommand, ok: Bool) {
        switch command {
        case .setTarget(let t):
            // A refusal means the helper is gone or said no; either way the strip
            // has to stop claiming the fan is where the knob is.
            if !ok { held[t.index] = nil }
        case .releaseAll:
            if ok { held.removeAll() }
        }
    }
}

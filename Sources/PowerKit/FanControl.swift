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
        return .success(min(max(rpm, l.minRPM), l.maxRPM))
    }

    /// Fraction of the fan's range, for a slider. 0 = minimum, 1 = maximum —
    /// NOT 0 = stopped, because stopping a fan is not on this slider.
    public static func fraction(rpm: Double, limits: Limits) -> Double {
        guard limits.maxRPM > limits.minRPM else { return 0 }
        return min(max((rpm - limits.minRPM) / (limits.maxRPM - limits.minRPM), 0), 1)
    }

    public static func rpm(fraction: Double, limits: Limits) -> Double {
        let f = min(max(fraction, 0), 1)
        return limits.minRPM + f * (limits.maxRPM - limits.minRPM)
    }
}

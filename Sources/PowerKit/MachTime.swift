import Foundation

/// Converts mach absolute time units to seconds.
///
/// `proc_pid_rusage`'s `ri_user_time` and `ri_system_time` are NOT nanoseconds,
/// however much their names suggest it — XNU fills them from
/// `task_absolutetime_info`, whose unit is the mach timebase. On Apple Silicon
/// that timebase is 125/3, so one unit is 41.667 ns and treating it as one
/// nanosecond under-reports CPU by 41.667x.
///
/// That is not theoretical. Measured against a process pegging one core:
///
///     treated as nanoseconds  ->   2.397 % of one core
///     treated as mach ticks   ->  99.872 % of one core   (ps agreed: 98.3 %)
///
/// The consequence was worse than a mis-scaled column. Two display floors sit on
/// this value, so a process genuinely using 2% of a core computed to 0.048% and
/// was filtered out of the CPU lens entirely — the lens was not merely wrong, it
/// was close to empty, and it is the one number a user can trivially check
/// against Activity Monitor.
///
/// `ri_energy_nj` really is nanojoules, so the joule path — the app's actual
/// subject — was never affected.
public enum MachTime {

    /// Nanoseconds per mach absolute time unit. Read once: `mach_timebase_info`
    /// is a syscall, and this is consulted per process per tick.
    public static let nanosPerUnit: Double = {
        var tb = mach_timebase_info_data_t()
        guard mach_timebase_info(&tb) == KERN_SUCCESS, tb.denom != 0 else { return 1 }
        return Double(tb.numer) / Double(tb.denom)
    }()

    /// Seconds of CPU represented by a delta of mach absolute time units.
    public static func seconds(units: UInt64) -> Double {
        Double(units) * nanosPerUnit / 1e9
    }

    /// Percent of ONE core, Activity Monitor's convention: a fully busy
    /// four-thread process reads 400%, not 100%.
    ///
    /// Rarely what you want to SHOW — see `machinePercent`. It is the honest
    /// intermediate, kept separate so the two units cannot be confused for each
    /// other by anyone reading a call site.
    public static func corePercent(units: UInt64, over dt: TimeInterval) -> Double {
        guard dt > 0 else { return 0 }
        return seconds(units: units) / dt * 100
    }

    /// Percent of the WHOLE machine's CPU: everything busy reads 100, and
    /// nothing can exceed it.
    ///
    /// This is the unit the app displays, because the other one cannot be read
    /// against anything else on screen. A process at "30%" beside a utilisation
    /// figure of 9% invites exactly one conclusion — that the two disagree —
    /// when in fact 30% of one core out of fifteen IS 2% of the machine. Two
    /// units with the same "%" sign, in the same window, is a bug in the units
    /// rather than in the arithmetic.
    ///
    /// `cores` is a parameter rather than a lookup so it can be pinned in tests;
    /// with `cores: 1` this is exactly `corePercent`.
    public static func machinePercent(units: UInt64, over dt: TimeInterval, cores: Int) -> Double {
        guard cores > 0 else { return 0 }
        return corePercent(units: units, over: dt) / Double(cores)
    }

    /// The divisor `machinePercent` needs, for callers that have no reason to
    /// care where it comes from.
    public static var activeCores: Int { ProcessInfo.processInfo.activeProcessorCount }
}
